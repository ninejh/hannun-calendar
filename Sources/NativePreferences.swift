import AppKit
import ServiceManagement
import Darwin

/// Safe, transport-independent failures. Raw framework errors never cross the wire.
struct NativeFailure: Error, Sendable {
    enum Commitment: Sendable { case no, yes, unknown }
    let code: String
    var field: String? = nil
    var messageKey: String? = nil
    var retryable = false
    var committed: Commitment = .no
}


@MainActor
final class NativePreferences {
    let demo: Bool
    let strings: NativeStrings
    var didChange: (() -> Void)?
#if HANNUN_TESTING
    var testNow: Date?
    var testTimeZone: TimeZone?
    var testAppearance: String?
    var testWeekStart: Int?
    var testReduceMotion: Bool?
#endif
    var lastLoginFailure: String?
    private var fakeLoginStatus = "notRegistered"
    private(set) var lastOpenedTarget: String?
    init(demo: Bool, strings: NativeStrings = NativeStrings()) { self.demo = demo; self.strings = strings }
    var now: Date {
#if HANNUN_TESTING
        if let testNow { return testNow }
#endif
        return Date()
    }
    var timeZone: TimeZone {
#if HANNUN_TESTING
        if let testTimeZone { return testTimeZone }
#endif
        return .current
    }
    var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.locale = .current; value.timeZone = timeZone
        return value
    }
    var today: String { DateOnly(date: now, timeZone: timeZone)!.description }
    static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    var clock: [String: Any] { ["now": Self.iso(now), "today": today, "timeZone": timeZone.identifier] }
    func environment(_ settings: BoardSettings) -> [String: Any] {
        var dark = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        var first = calendar.firstWeekday
        var reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
#if HANNUN_TESTING
        if let testAppearance { dark = testAppearance == "dark" }
        if let testWeekStart { first = testWeekStart }
        if let testReduceMotion { reduced = testReduceMotion }
#endif
        return ["resolvedAppearance": settings.appearance == .system ? (dark ? "dark" : "light") : settings.appearance.rawValue,
                "resolvedWeekStart": settings.weekStart == .system ? first : settings.weekStart == .sunday ? 1 : 2,
                "reduceMotion": reduced, "timeZone": timeZone.identifier]
    }
    var login: [String: Any] {
        let status: String
        if demo { status = fakeLoginStatus }
        else {
            switch SMAppService.mainApp.status {
            case .enabled: status = "enabled"
            case .notRegistered: status = "notRegistered"
            case .requiresApproval: status = "requiresApproval"
            case .notFound: status = "notFound"
            @unknown default: status = "notFound"
            }
        }
        return ["status": status, "enabled": status == "enabled", "warningCode": lastLoginFailure as Any? ?? NSNull()]
    }
    func setLogin(_ enabled: Bool) async throws {
        if demo {
            if fakeLoginStatus == "notFound" { throw NativeFailure(code: "LOGIN_REGISTRATION_FAILED") }
            // A pending approval must never be optimistically checked.
            if fakeLoginStatus == "requiresApproval", enabled { throw NativeFailure(code: "LOGIN_APPROVAL_REQUIRED") }
            fakeLoginStatus = enabled ? "enabled" : "notRegistered"
            didChange?(); return
        }
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else { try await SMAppService.mainApp.unregister() }
        } catch {
            // SMAppServiceErrorDomain is macOS 15+. Derive behavior from status on macOS 14.
            didChange?()
            throw NativeFailure(code: SMAppService.mainApp.status == .requiresApproval ? "LOGIN_APPROVAL_REQUIRED" : "LOGIN_REGISTRATION_FAILED")
        }
        didChange?()
        if enabled && SMAppService.mainApp.status == .requiresApproval { throw NativeFailure(code: "LOGIN_APPROVAL_REQUIRED") }
        if (login["enabled"] as? Bool) != enabled { throw NativeFailure(code: "LOGIN_REGISTRATION_FAILED") }
    }
    func open(_ target: String) throws {
        lastOpenedTarget = target
        if demo { return }
        switch target {
        case "login": SMAppService.openSystemSettingsLoginItems() // void: actual arrival is a manual OS check.
        case "privacy":
            guard NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!) else { throw NativeFailure(code: "OS_OPEN_FAILED") }
        case "accounts":
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal"), NSWorkspace.shared.open(url) else { throw NativeFailure(code: "OS_OPEN_FAILED") }
        default: throw NativeFailure(code: "INVALID_REQUEST")
        }
    }
#if HANNUN_TESTING
    func setTestLogin(_ status: String) throws {
        guard demo, ["enabled", "notRegistered", "requiresApproval", "notFound"].contains(status) else { throw NativeFailure(code: "INVALID_REQUEST") }
        fakeLoginStatus = status
    }
#endif
}

/// Every durable job is admitted synchronously; permission/transport waits run outside it.
enum NativeWriteContext { @TaskLocal static var token: UUID? }
@MainActor
final class NativeWriteLane {
    private let token = UUID()
    private var executingTask: UnsafeCurrentTask?
    private var jobs: [@MainActor () async -> Void] = []
    private var running = false
    var ownsCurrentTask: Bool {
        NativeWriteContext.token == token && withUnsafeCurrentTask { $0 != nil && $0 == executingTask }
    }
    func enqueue(_ job: @escaping @MainActor () async -> Void) {
        jobs.append(job)
        guard !running else { return }
        running = true
        Task { @MainActor in
            await NativeWriteContext.$token.withValue(token) {
                // The unsafe handle stays within this running Task's lifetime, on MainActor.
                executingTask = withUnsafeCurrentTask { $0 }
                defer { executingTask = nil }
                while !jobs.isEmpty { await jobs.removeFirst()() }
            }
            running = false
        }
    }
    func run<T>(_ job: @escaping @MainActor () throws -> T) async throws -> T {
        if ownsCurrentTask { return try job() }
        return try await withCheckedThrowingContinuation { continuation in
            enqueue { do { continuation.resume(returning: try job()) } catch { continuation.resume(throwing: error) } }
        }
    }
}
@MainActor
final class NativePanelClock: PanelClock {
    let preferences: NativePreferences
    var manualMilliseconds: Int64 = 0
    var continuousManualMilliseconds: Int64?
    let manualMode: Bool
    init(_ preferences: NativePreferences, manual: Bool? = nil) {
        self.preferences = preferences
#if HANNUN_TESTING
        manualMode = manual ?? true
#else
        manualMode = false
#endif
    }
    private static let continuousMillisecondsPerTick: Double = {
        var scale = mach_timebase_info_data_t()
        mach_timebase_info(&scale)
        return Double(scale.numer) / Double(scale.denom) / 1_000_000
    }()
    /// Budget continuity includes sleep; focus/notification keep their awake clock below.
    var continuousSnapshot: PanelClockSnapshot {
#if HANNUN_TESTING
        if manualMode {
            return PanelClockSnapshot(now: Instant(date: preferences.now), timeZone: preferences.timeZone,
                                      monotonicMilliseconds: continuousManualMilliseconds ?? manualMilliseconds)
        }
#endif
        let monotonic = Int64(Double(mach_continuous_time()) * Self.continuousMillisecondsPerTick)
        return PanelClockSnapshot(now: Instant(date: preferences.now), timeZone: preferences.timeZone, monotonicMilliseconds: monotonic)
    }
    var snapshot: PanelClockSnapshot {
#if HANNUN_TESTING
        if manualMode {
            return PanelClockSnapshot(now: Instant(date: preferences.now), timeZone: preferences.timeZone,
                                      monotonicMilliseconds: manualMilliseconds)
        }
#endif
        let monotonic = Int64(ProcessInfo.processInfo.systemUptime * 1000)
        return PanelClockSnapshot(now: Instant(date: preferences.now), timeZone: preferences.timeZone, monotonicMilliseconds: monotonic)
    }
}

@MainActor
final class NativeMemorySidecar: SidecarPersistence {
    var bytes: Data?
    func read() throws -> Data? { bytes }
    func write(_ data: Data, exclusive: Bool) throws {
        if exclusive && bytes != nil { throw BoardStorageError(.writeFailed) }
        bytes = data
    }
    func preserveCurrent() throws { bytes = nil }
}

/// The demo has the same service stack, with no system notification center instance.
@MainActor
final class NativeFakeNotifications: NotificationAdapter {
    var permission = NotificationPermission()
    var requestResult: NotificationAuthorization = .denied
    var submitSucceeds = true
    private(set) var permissionRequests = 0
#if HANNUN_TESTING
    var holdAuthorization = false
    var authorizationWaiter: CheckedContinuation<Void, Never>?
    func resolveAuthorization() { holdAuthorization = false; authorizationWaiter?.resume(); authorizationWaiter = nil }
#endif
    private(set) var submissions: [LocalPanelNotification] = []
    func settings() async throws -> NotificationPermission { permission }
    func requestAlertAuthorization() async throws -> Bool {
        permissionRequests += 1
#if HANNUN_TESTING
        if holdAuthorization { await withCheckedContinuation { authorizationWaiter = $0 } }
#endif
        permission = NotificationPermission(authorization: requestResult, alertsEnabled: requestResult == .authorized)
        return permission.effective
    }
    func submit(_ notification: LocalPanelNotification) async throws {
        submissions.append(notification)
        if !submitSucceeds { throw NotificationServiceError(code: .submissionFailed) }
    }
}

/// A response is captured at admission. Cancellation never mutates a held callback.
@MainActor
final class NativeFakeTransport: ExternalTransport {
    struct Response {
        var result: Result<ExternalHTTPResponse, ExternalFailure>
        var held = false
        var delay = 0
    }
    private final class Cancellation: ExternalCancellation {
        func cancel() {} // The service returns its permit; the immutable response still arrives.
    }
    var replacements: [ExternalKind: Response] = [:]
    private var held: [String: (@MainActor @Sendable () -> Void)] = [:]
    let catalog: CityCatalog
    let now: () -> Instant
    init(catalog: CityCatalog, now: @escaping () -> Instant) { self.catalog = catalog; self.now = now }
    func start(_ request: ExternalRequest, completion: @escaping @MainActor @Sendable (Result<ExternalHTTPResponse, ExternalFailure>) -> Void) throws -> any ExternalCancellation {
        let response = try replacements.removeValue(forKey: request.kind) ?? synthetic(request)
        let result = response.result
        let callback: @MainActor @Sendable () -> Void = {
            do {
                let value = try result.get()
                var reader = ExternalBodyBuffer(); try reader.append(value.body)
                completion(.success(ExternalHTTPResponse(status: value.status, headers: value.headers, body: reader.data)))
            } catch { completion(.failure((error as? ExternalFailure) ?? .invalidResponse)) }
        }
        if response.held { held[request.id.uuidString.lowercased()] = callback }
        else { Task { @MainActor in
            if response.delay > 0 { try? await Task.sleep(for: .milliseconds(response.delay)) }
            callback()
        } }
        return Cancellation()
    }
    func release(_ id: String) throws {
        guard let callback = held.removeValue(forKey: id.lowercased()) else { throw NativeFailure(code: "INVALID_REQUEST") }
        callback()
    }
    private func synthetic(_ request: ExternalRequest) throws -> Response {
        let body: Any
        if request.kind == .weather {
            let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let lat = query.first { $0.name == "latitude" }?.value.flatMap(Double.init)
            let lon = query.first { $0.name == "longitude" }?.value.flatMap(Double.init)
            let city = catalog.cities.first { $0.latitude == lat && $0.longitude == lon } ?? catalog.cities[0]
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: city.timeZone)!
            let firstDay = calendar.startOfDay(for: now().date)
            let days = (0..<16).map { DateOnly(date: calendar.date(byAdding: .day, value: $0, to: firstDay)!, timeZone: calendar.timeZone)!.description }
            body = ["timezone": city.timeZone, "daily": ["time": days, "weather_code": (0..<16).map { $0 % 4 }]]
        } else {
            let quotes = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "quotes" }?.value?.split(separator: ",").map(String.init) ?? ["KRW"]
            let day = DateOnly(date: now().date, timeZone: TimeZone(secondsFromGMT: 0)!)!.description
            body = quotes.map { ["date": day, "base": "EUR", "quote": $0, "rate": $0 == "KRW" ? "1500" : $0 == "JPY" ? "160" : $0 == "EUR" ? "1" : "1.1"] }
        }
        return Response(result: .success(ExternalHTTPResponse(status: 200, headers: ExternalHeaders(), body: try JSONSerialization.data(withJSONObject: body))))
    }
}

@MainActor
final class NativeFaultSidecar: SidecarPersistence {
    let base: any SidecarPersistence
    var nextFailure: NativeFailure?
    init(_ base: any SidecarPersistence) { self.base = base }
    func read() throws -> Data? { try base.read() }
    func preserveCurrent() throws { try base.preserveCurrent() }
    func write(_ data: Data, exclusive: Bool) throws {
        if let failure = nextFailure {
            nextFailure = nil
            if failure.committed == .yes { try base.write(data, exclusive: exclusive) }
            throw SidecarStorageError(committed: failure.committed == .yes)
        }
        try base.write(data, exclusive: exclusive)
    }
}
@MainActor
final class NativePanelServices {
    let clock: NativePanelClock
    let catalog: CityCatalog
    let cacheFile: NativeFaultSidecar
    let budgetFile: NativeFaultSidecar
    let budget: NetworkBudget
    let external: ExternalDataService
    let focus: FocusService
    let notifications: NotificationService
    let fakeTransport: NativeFakeTransport?
    let fakeNotifications: NativeFakeNotifications?
    init(store: BoardStore, preferences: NativePreferences, lane: NativeWriteLane, scratchRoot: URL? = nil,
         clock suppliedClock: NativePanelClock? = nil, catalog suppliedCatalog: CityCatalog? = nil) {
        clock = suppliedClock ?? NativePanelClock(preferences)
        // The fallback keeps local storage usable if packaging omitted the catalog.
        catalog = suppliedCatalog ?? (try? CityCatalog()) ?? (try! CityCatalog(data: Data("[{\"id\":\"seoul\",\"nameEN\":\"Seoul\",\"nameKO\":\"서울\",\"timeZone\":\"Asia/Seoul\",\"latitude\":37.5665,\"longitude\":126.978,\"aliases\":[]}]".utf8)))
#if HANNUN_TESTING
        let folder: URL? = scratchRoot
#else
        let folder: URL? = preferences.demo ? scratchRoot : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("HannunCalendar")
#endif
        cacheFile = NativeFaultSidecar(folder.map { PrivateSidecarFile(url: $0.appendingPathComponent("external-cache.json")) as any SidecarPersistence } ?? NativeMemorySidecar())
        budgetFile = NativeFaultSidecar(folder.map { PrivateSidecarFile(url: $0.appendingPathComponent("network-budget.json")) as any SidecarPersistence } ?? NativeMemorySidecar())
        budget = NetworkBudget(persistence: budgetFile, jitter: { preferences.demo ? 0.5 : Double.random(in: 0...1) })
        let (transport, fakeTransport) = Self.transport(catalog: catalog, preferences: preferences)
        self.fakeTransport = fakeTransport
        let (adapter, fakeNotifications) = Self.notificationAdapter(preferences: preferences)
        self.fakeNotifications = fakeNotifications
        external = ExternalDataService(catalog: catalog, cache: ExternalCache(persistence: cacheFile), budget: budget, transport: transport, now: { Instant(date: preferences.now) })
        focus = FocusService(store: store, clock: clock)
        notifications = NotificationService(store: store, clock: clock, adapter: adapter, strings: preferences.strings)
        notifications.writeGate = { job in try await lane.run(job) }
    }
    private static func transport(catalog: CityCatalog, preferences: NativePreferences) -> (any ExternalTransport, NativeFakeTransport?) {
#if !HANNUN_TESTING
        if !preferences.demo { return (URLSessionExternalTransport(), nil) }
#endif
        let fake = NativeFakeTransport(catalog: catalog, now: { Instant(date: preferences.now) })
        return (fake, fake)
    }
    private static func notificationAdapter(preferences: NativePreferences) -> (any NotificationAdapter, NativeFakeNotifications?) {
#if !HANNUN_TESTING
        if !preferences.demo { return (SystemNotificationAdapter(), nil) }
#endif
        let fake = NativeFakeNotifications(); return (fake, fake)
    }

}
