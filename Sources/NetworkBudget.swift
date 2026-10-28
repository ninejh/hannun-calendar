import Foundation

/// Compare wall time with a sleep-inclusive monotonic source. A wake event alone is
/// not evidence of clock manipulation; small corrections keep existing allowances.
struct NetworkClockMonitor {
    static let toleranceMilliseconds: Int64 = 30000
    private var previousNow: Instant
    private var previousElapsed: Int64
    init(now: Instant, elapsedMilliseconds: Int64) { previousNow = now; previousElapsed = elapsedMilliseconds }
    mutating func observe(now: Instant, elapsedMilliseconds: Int64) -> Bool {
        let elapsed = elapsedMilliseconds.subtractingReportingOverflow(previousElapsed)
        let wall = (now.date.timeIntervalSince(previousNow.date) * 1000).rounded()
        defer { previousNow = now; previousElapsed = elapsedMilliseconds }
        guard !elapsed.overflow, elapsed.partialValue >= 0 else { return true }
        return abs(wall - Double(elapsed.partialValue)) > Double(Self.toleranceMilliseconds)
    }
}

struct NetworkKeyBudget: Codable, Equatable, Sendable {
    var lastAttemptAt:Instant
    var nextAllowedAt:Instant
    var consecutiveFailures:Int
}
struct NetworkUnsettledAttempt: Codable, Equatable, Sendable {
    var attemptID:UUID
    var key:String
    var startedAt:Instant
}
struct NetworkProviderBudget: Codable, Equatable, Sendable {
    var attemptInstants:[Instant]=[]
    var lastAttemptAt:Instant?=nil
    var providerBlockedUntil:Instant?=nil
    var quarantineUntil:Instant?=nil
    var keys:[String:NetworkKeyBudget]=[:]
    var unsettled:[NetworkUnsettledAttempt]=[]
}
struct NetworkBudgetFile: Codable, Equatable, Sendable {
    var budgetVersion=1
    var providers:[String:NetworkProviderBudget]=["weather":NetworkProviderBudget(),"rates":NetworkProviderBudget()]
    static func decode(_ data:Data) throws -> NetworkBudgetFile {
        guard data.count<=1_048_576,let root=try JSONSerialization.jsonObject(with:data) as? [String:Any],Set(root.keys)==["budgetVersion","providers"],
              let providers=root["providers"] as? [String:Any],Set(providers.keys)==["weather","rates"] else {throw ExternalFailure.requestBudgetUnavailable}
        for provider in providers.values {
            guard let object=provider as? [String:Any],Set(object.keys).isSubset(of:["attemptInstants","lastAttemptAt","providerBlockedUntil","quarantineUntil","keys","unsettled"]),
                  let keys=object["keys"] as? [String:Any],let unsettled=object["unsettled"] as? [[String:Any]],
                  keys.values.allSatisfy({ ($0 as? [String:Any]).map{Set($0.keys)==["lastAttemptAt","nextAllowedAt","consecutiveFailures"]} ?? false }),
                  unsettled.allSatisfy({Set($0.keys)==["attemptID","key","startedAt"]}) else {throw ExternalFailure.requestBudgetUnavailable}
        }
        let value=try JSONDecoder().decode(Self.self,from:data);try value.validate();return value
    }
    func validate() throws {
        guard budgetVersion==1,Set(providers.keys)==["weather","rates"] else {throw ExternalFailure.requestBudgetUnavailable}
        for kind in ExternalKind.allCases {
            let provider=providers[kind.rawValue]!
            guard provider.attemptInstants.count <= (kind == .weather ? 24 : 4),provider.keys.count <= (kind == .weather ? 64 : 16),
                  Set(provider.unsettled.map(\.attemptID)).count==provider.unsettled.count,provider.unsettled.count<=provider.attemptInstants.count,
                  provider.keys.allSatisfy({entry in !entry.key.isEmpty && entry.key.utf8.count<=256 && entry.value.consecutiveFailures>=0 && entry.value.consecutiveFailures<=1_000_000 && entry.value.nextAllowedAt >= entry.value.lastAttemptAt.adding(seconds:900) && provider.lastAttemptAt.map{entry.value.lastAttemptAt <= $0} == true}),
                  provider.unsettled.allSatisfy({provider.keys[$0.key] != nil && provider.attemptInstants.contains($0.startedAt)}),
                  provider.lastAttemptAt == provider.attemptInstants.max() || provider.attemptInstants.isEmpty else {throw ExternalFailure.requestBudgetUnavailable}
        }
    }
}
struct BudgetEligibility: Sendable {var allowed:Bool;var nextAllowedAt:Instant?}
struct BudgetReservation: Sendable {let kind:ExternalKind;let key:String;let attemptID:UUID;let startedAt:Instant}
enum BudgetSettlement: Sendable {case success,cancelled,failure(ExternalFailure),rateLimited(retryAfter:String?)}

@MainActor final class NetworkBudget {
    private let persistence:any SidecarPersistence
    private let jitter:()->Double
    private(set) var state=NetworkBudgetFile()
    private(set) var available=false
    private(set) var reservations=0
    private(set) var writeFailures=0
    private var memoryBlockedUntil:Instant?
    private var handledRewind:Instant?
    var effectiveQuarantineUntil:Instant? {(state.providers.values.compactMap(\.quarantineUntil) + (memoryBlockedUntil.map{[$0]} ?? [])).max()}
    init(persistence:any SidecarPersistence,jitter:@escaping ()->Double={Double.random(in:0...1)}){self.persistence=persistence;self.jitter=jitter}
    private func publish(_ next:NetworkBudgetFile,exclusive:Bool=false,now:Instant) throws {
        do {
            try next.validate()
            let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
            let data=try encoder.encode(next)
            try persistence.write(data,exclusive:exclusive)
            guard let bytes=try persistence.read(),bytes==data,try NetworkBudgetFile.decode(bytes)==next else {throw ExternalFailure.requestBudgetUnavailable}
            state=next
        } catch {
            writeFailures+=1;available=false;memoryBlockedUntil=max(memoryBlockedUntil ?? now,now.adding(seconds:86400))
            throw ExternalFailure.requestBudgetUnavailable
        }
    }
    /// Separate from API-21: the host must commit the board marker after this returns.
    func prepare(marker:Bool,now:Instant) throws {
        let data:Data?
        do {data=try persistence.read()}
        catch {
            // If bytes cannot safely be preserved, keep the original artifact and stop all transport.
            available=false;memoryBlockedUntil=now.adding(seconds:86400);throw ExternalFailure.requestBudgetUnavailable
        }
        if data==nil && !marker {
            try publish(NetworkBudgetFile(),exclusive:true,now:now);available=true;memoryBlockedUntil=nil;return
        }
        let decoded=data.flatMap{try? NetworkBudgetFile.decode($0)}
        guard var next=decoded else {
            do {if data != nil {try persistence.preserveCurrent()}}
            catch {available=false;memoryBlockedUntil=now.adding(seconds:86400);throw ExternalFailure.requestBudgetUnavailable}
            var quarantine=NetworkBudgetFile()
            for kind in ExternalKind.allCases {quarantine.providers[kind.rawValue]!.quarantineUntil=now.adding(seconds:86400)}
            try publish(quarantine,exclusive:data==nil,now:now);available=true;memoryBlockedUntil=nil;return
        }
        var changed=false
        let future = now.adding(seconds: Double(NetworkClockMonitor.toleranceMilliseconds) / 1000)
        let rewound = next.providers.values.contains { provider in
            provider.attemptInstants.contains(where: { $0 > future }) || (provider.lastAttemptAt.map { $0 > future } ?? false)
        }
        for kind in ExternalKind.allCases {
            var provider=next.providers[kind.rawValue]!
            if !provider.unsettled.isEmpty {
                provider.quarantineUntil=max(provider.quarantineUntil ?? now,now.adding(seconds:86400))
                // This is an explicit durable quarantine, not a guessed successful settlement.
                provider.unsettled=[];next.providers[kind.rawValue]=provider;changed=true
            }
        }
        if rewound {
            // The read-only eligibility path cannot repair the other provider later.
            // Persist both here, reusing an existing horizon instead of sliding it on restart.
            let until = next.providers.values.compactMap(\.quarantineUntil).filter { $0 > now }.max() ?? now.adding(seconds:86400)
            for kind in ExternalKind.allCases where next.providers[kind.rawValue]!.quarantineUntil != until {
                next.providers[kind.rawValue]!.quarantineUntil = until; changed = true
            }
        }
        if changed {try publish(next,now:now)} else {state=next}
        available=true;memoryBlockedUntil=nil
        handledRewind = futureAttempt(now: now)
    }
    private func cleaned(_ value:NetworkProviderBudget,now:Instant)->NetworkProviderBudget {
        var value=value
        let unsettledTimes=Set(value.unsettled.map(\.startedAt))
        value.attemptInstants.removeAll { $0.adding(seconds:86400)<=now && !unsettledTimes.contains($0) }
        // An unsettled attempt may outlive 24h; it cannot be silently pruned before quarantine/settlement.
        value.keys=value.keys.filter { entry in
            let unsettled=value.unsettled.contains {$0.key==entry.key}
            return unsettled || !(entry.value.lastAttemptAt.adding(seconds:86400)<now && entry.value.nextAllowedAt<now)
        }
        return value
    }
    func eligibility(kind:ExternalKind,key:String,now:Instant) throws -> BudgetEligibility {
        guard available else {return BudgetEligibility(allowed:false,nextAllowedAt:memoryBlockedUntil)}
        guard !key.isEmpty,key.utf8.count<=256 else {throw ExternalFailure.requestBudgetUnavailable}
        if let future = futureAttempt(now: now) {
            // Observation must not fsync or extend quarantine. Admission performs the durable reconciliation.
            return BudgetEligibility(allowed: false, nextAllowedAt: max(effectiveQuarantineUntil ?? now.adding(seconds: 86400), future.adding(seconds: -Double(NetworkClockMonitor.toleranceMilliseconds) / 1000)))
        }
        let provider=cleaned(state.providers[kind.rawValue]!,now:now)
        var lower=now
        if let value=provider.keys[key]?.nextAllowedAt {lower=max(lower,value)}
        if let value=provider.providerBlockedUntil {lower=max(lower,value)}
        if let value=provider.quarantineUntil {lower=max(lower,value)}
        let cap=kind == .weather ? 24 : 4
        if provider.attemptInstants.count>=cap,let first=provider.attemptInstants.min(){lower=max(lower,first.adding(seconds:86400))}
        let maximumKeys=kind == .weather ? 64 : 16
        if provider.keys[key]==nil && provider.keys.count>=maximumKeys {
            let release=provider.keys.values.map{max($0.lastAttemptAt.adding(seconds:86400),$0.nextAllowedAt).adding(seconds:0.001)}.min()!
            lower=max(lower,release)
        }
        let capped=provider.attemptInstants.count>=cap
        let full=provider.keys[key]==nil && provider.keys.count>=maximumKeys
        return BudgetEligibility(allowed:lower<=now && !capped && !full,nextAllowedAt:lower>now ? lower : nil)
    }
    private func futureAttempt(now: Instant) -> Instant? {
        let tolerance = now.adding(seconds: Double(NetworkClockMonitor.toleranceMilliseconds) / 1000)
        return state.providers.values.compactMap(\.lastAttemptAt).filter { $0 > tolerance }.max()
    }
    /// Explicit mutation boundary: one durable quarantine per observed rewind episode.
    func reconcileClock(now: Instant) throws {
        guard available else { throw ExternalFailure.requestBudgetUnavailable }
        guard let future = futureAttempt(now: now) else { handledRewind = nil; return }
        guard handledRewind != future else { return }
        if !state.providers.values.allSatisfy({ ($0.quarantineUntil ?? now) > now }) {
            try quarantineForClockChange(now: now)
        }
        handledRewind = future
    }
    func reserve(kind:ExternalKind,key:String,now:Instant,attemptID:UUID=UUID()) throws -> BudgetReservation {
        try reconcileClock(now: now)
        guard try eligibility(kind:kind,key:key,now:now).allowed else {throw ExternalFailure.requestBudgetUnavailable}
        var next=state,provider=cleaned(state.providers[kind.rawValue]!,now:now)
        guard !next.providers.values.contains(where:{$0.unsettled.contains(where:{$0.attemptID==attemptID})}) else {throw ExternalFailure.requestBudgetUnavailable}
        provider.attemptInstants.append(now);provider.lastAttemptAt=max(provider.lastAttemptAt ?? now,now)
        let old=provider.keys[key]
        provider.keys[key]=NetworkKeyBudget(lastAttemptAt:now,nextAllowedAt:max(old?.nextAllowedAt ?? now,now.adding(seconds:900)),consecutiveFailures:old?.consecutiveFailures ?? 0)
        provider.unsettled.append(NetworkUnsettledAttempt(attemptID:attemptID,key:key,startedAt:now));next.providers[kind.rawValue]=provider
        try publish(next,now:now);reservations+=1
        return BudgetReservation(kind:kind,key:key,attemptID:attemptID,startedAt:now)
    }
    static func retryAfter(_ value:String?,now:Instant)->Instant? {
        guard let value=ExternalHeaders.safe(value) else {return nil}
        if !value.isEmpty,value.utf8.allSatisfy({(48...57).contains($0)}),let seconds=Double(value),seconds.isFinite {return now.adding(seconds:min(86400,seconds))}
        let formatter=DateFormatter();formatter.locale=Locale(identifier:"en_US_POSIX");formatter.timeZone=TimeZone(secondsFromGMT:0);formatter.dateFormat="EEE, dd MMM yyyy HH:mm:ss zzz";formatter.isLenient=false
        guard let date=formatter.date(from:value),date>now.date else {return nil}
        return min(Instant(date:date), now.adding(seconds:86400))
    }
    func settle(_ token:BudgetReservation,outcome:BudgetSettlement,now:Instant) throws {
        guard available else {throw ExternalFailure.requestBudgetUnavailable}
        var next=state,provider=state.providers[token.kind.rawValue]!
        guard provider.unsettled.contains(where:{$0.attemptID==token.attemptID && $0.key==token.key && $0.startedAt==token.startedAt}),var key=provider.keys[token.key] else {throw ExternalFailure.requestBudgetUnavailable}
        switch outcome {
        case .success:key.consecutiveFailures=0
        case .cancelled:break
        case .failure,.rateLimited:
            key.consecutiveFailures=min(1_000_000,key.consecutiveFailures+1)
            let base:Double=key.consecutiveFailures==1 ? 900 : key.consecutiveFailures==2 ? 3600 : 10800
            let noise=min(1,max(0,jitter()))
            let backoff=now.adding(seconds:base*(1+0.1*noise))
            key.nextAllowedAt=max(key.nextAllowedAt,backoff)
            if case let .rateLimited(value)=outcome {
                let block=max(backoff,Self.retryAfter(value,now:now) ?? now)
                provider.providerBlockedUntil=max(provider.providerBlockedUntil ?? now,block);key.nextAllowedAt=max(key.nextAllowedAt,block)
            }
        }
        provider.keys[token.key]=key;provider.unsettled.removeAll{$0.attemptID==token.attemptID};next.providers[token.kind.rawValue]=provider
        try publish(next,now:now)
    }
    func quarantineForClockChange(now:Instant) throws {
        guard available else {throw ExternalFailure.requestBudgetUnavailable}
        var next=state
        for kind in ExternalKind.allCases {next.providers[kind.rawValue]!.quarantineUntil=max(next.providers[kind.rawValue]!.quarantineUntil ?? now,now.adding(seconds:86400))}
        if next != state { try publish(next,now:now) }
    }
}
