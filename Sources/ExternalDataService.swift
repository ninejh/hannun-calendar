import Foundation

enum ExternalKind: String, Codable, CaseIterable, Sendable { case weather, rates }
enum ExternalRefreshKind: Sendable { case weather, rates, all }
enum ExternalFailure: String, Error, Codable, Sendable {
    case offline = "OFFLINE", timeout = "TIMEOUT", rateLimited = "RATE_LIMITED", serviceUnavailable = "SERVICE_UNAVAILABLE"
    case invalidResponse = "INVALID_RESPONSE", unsupportedCurrency = "UNSUPPORTED_CURRENCY", requestBudgetUnavailable = "REQUEST_BUDGET_UNAVAILABLE"
    case cancelled = "CANCELLED"
}
struct ExternalHeaders: Codable, Equatable, Sendable {
    var retryAfter: String? = nil
    var etag: String? = nil
    var lastModified: String? = nil
    static func safe(_ value: String?) -> String? {
        guard let value, value.utf8.count <= 1024, !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return value
    }
    init(retryAfter: String? = nil, etag: String? = nil, lastModified: String? = nil) {
        self.retryAfter = Self.safe(retryAfter); self.etag = Self.safe(etag); self.lastModified = Self.safe(lastModified)
    }
}
struct ExternalAttribution: Codable, Equatable, Sendable {
    var providerID: String
    var labelKey: String
    var sourceURL: String
    var licenseURL: String?
    var transformationKey: String
}
struct ExternalHTTPResponse: Sendable {
    var status: Int
    var headers: ExternalHeaders
    var body: Data
}
struct ExternalRequest: Sendable {
    var id = UUID()
    let kind: ExternalKind
    let key: String
    let url: URL
    let allowedHost: String
    let allowedPath: String
    var headers = ExternalHeaders()
    func validate(url: URL) throws {
        guard let c = URLComponents(url:url,resolvingAgainstBaseURL:false), c.scheme == "https", c.host == allowedHost,
              c.port == nil || c.port == 443, c.user == nil, c.password == nil, c.fragment == nil,
              c.percentEncodedPath == allowedPath else { throw ExternalFailure.invalidResponse }
    }
}
struct ExternalBodyBuffer: Sendable {
    static let maximumBytes = 262144
    private(set) var data = Data()
    mutating func append(_ bytes: Data) throws {
        guard bytes.count <= Self.maximumBytes - data.count else { throw ExternalFailure.invalidResponse }
        data.append(bytes)
    }
}
@MainActor protocol ExternalCancellation: AnyObject { func cancel() }
@MainActor protocol ExternalTransport: AnyObject {
    func start(_ request:ExternalRequest, completion:@escaping @MainActor @Sendable (Result<ExternalHTTPResponse,ExternalFailure>)->Void) throws -> any ExternalCancellation
}

@MainActor
final class URLSessionExternalTransport: ExternalTransport {
    private let injectedConfiguration: URLSessionConfiguration?
    init(configuration: URLSessionConfiguration? = nil) { injectedConfiguration = configuration }
    static func configuration() -> URLSessionConfiguration {
        let value = URLSessionConfiguration.ephemeral
        value.httpCookieStorage = nil; value.httpShouldSetCookies = false; value.urlCredentialStorage = nil; value.urlCache = nil
        value.requestCachePolicy = .reloadIgnoringLocalCacheData
        value.timeoutIntervalForRequest = 10; value.timeoutIntervalForResource = 15
        value.waitsForConnectivity = false
        return value
    }
    func start(_ request:ExternalRequest, completion:@escaping @MainActor @Sendable (Result<ExternalHTTPResponse,ExternalFailure>)->Void) throws -> any ExternalCancellation {
        try request.validate(url:request.url)
        let operation = ExternalSessionOperation(request:request,completion:completion)
        operation.start(configuration:injectedConfiguration ?? Self.configuration())
        return ExternalURLCancellation(operation:operation)
    }
}
@MainActor private final class ExternalURLCancellation: ExternalCancellation {
    let operation: ExternalSessionOperation
    init(operation:ExternalSessionOperation){self.operation=operation}
    func cancel(){operation.cancel()}
}
/// A serial delegate bounds streaming bytes before appending; no data(for:) unbounded buffering.
private final class ExternalSessionOperation: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let request: ExternalRequest
    let completion: @MainActor @Sendable (Result<ExternalHTTPResponse,ExternalFailure>)->Void
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var response: HTTPURLResponse?
    private var buffer = ExternalBodyBuffer()
    private var finished = false
    init(request:ExternalRequest,completion:@escaping @MainActor @Sendable (Result<ExternalHTTPResponse,ExternalFailure>)->Void){self.request=request;self.completion=completion}
    func start(configuration:URLSessionConfiguration) {
        var value = URLRequest(url:request.url,cachePolicy:.reloadIgnoringLocalCacheData,timeoutInterval:10)
        value.httpMethod = "GET"
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let safeVersion = version.flatMap { value in
            !value.isEmpty && value.utf8.count <= 64 && value.utf8.allSatisfy { (48...57).contains($0) || $0 == 46 } ? value : nil
        }
        value.setValue("HannunCalendar" + (safeVersion.map { "/" + $0 } ?? ""), forHTTPHeaderField: "User-Agent")
        if let etag = ExternalHeaders.safe(request.headers.etag) {value.setValue(etag,forHTTPHeaderField:"If-None-Match")}
        if let modified = ExternalHeaders.safe(request.headers.lastModified) {value.setValue(modified,forHTTPHeaderField:"If-Modified-Since")}
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration:configuration,delegate:self,delegateQueue:queue)
        let task = session.dataTask(with:value)
        lock.lock(); self.session=session; self.task=task; lock.unlock()
        task.resume()
    }
    func cancel(){lock.lock();let task=task;lock.unlock();task?.cancel()}
    private func finish(_ result:Result<ExternalHTTPResponse,ExternalFailure>) {
        lock.lock()
        guard !finished else {lock.unlock();return}
        finished=true;let session=session;self.session=nil;self.task=nil
        lock.unlock()
        session?.invalidateAndCancel()
        Task { @MainActor in completion(result) }
    }
    func urlSession(_ session:URLSession, task:URLSessionTask, willPerformHTTPRedirection response:HTTPURLResponse, newRequest:URLRequest, completionHandler:@escaping (URLRequest?)->Void) {
        completionHandler(nil);finish(.failure(.invalidResponse))
    }
    func urlSession(_ session:URLSession, dataTask:URLSessionDataTask, didReceive response:URLResponse, completionHandler:@escaping (URLSession.ResponseDisposition)->Void) {
        guard let http = response as? HTTPURLResponse, let url=http.url, (try? request.validate(url:url)) != nil else {
            completionHandler(.cancel);finish(.failure(.invalidResponse));return
        }
        if http.statusCode==429 {
            let headers=ExternalHeaders(retryAfter:http.value(forHTTPHeaderField:"Retry-After"),etag:http.value(forHTTPHeaderField:"ETag"),lastModified:http.value(forHTTPHeaderField:"Last-Modified"))
            completionHandler(.cancel);finish(.success(ExternalHTTPResponse(status:429,headers:headers,body:Data())));return
        }
        guard response.expectedContentLength <= Int64(ExternalBodyBuffer.maximumBytes) else {
            completionHandler(.cancel);finish(.failure(.invalidResponse));return
        }
        lock.lock();self.response=http;lock.unlock();completionHandler(.allow)
    }
    func urlSession(_ session:URLSession, dataTask:URLSessionDataTask, didReceive data:Data) {
        lock.lock()
        do {if !finished {try buffer.append(data)};lock.unlock()}
        catch {lock.unlock();finish(.failure(.invalidResponse))}
    }
    func urlSession(_ session:URLSession, task:URLSessionTask, didCompleteWithError error:Error?) {
        if let error = error as? URLError {
            let failure:ExternalFailure
            switch error.code {
            case .timedOut:failure = .timeout
            case .notConnectedToInternet,.networkConnectionLost,.cannotFindHost,.cannotConnectToHost:failure = .offline
            case .cancelled:failure = .cancelled
            default:failure = .serviceUnavailable
            }
            finish(.failure(failure));return
        }
        guard error == nil else {finish(.failure(.serviceUnavailable));return}
        lock.lock();let http=response;let body=buffer.data;lock.unlock()
        guard let http else {finish(.failure(.invalidResponse));return}
        let headers=ExternalHeaders(retryAfter:http.value(forHTTPHeaderField:"Retry-After"),etag:http.value(forHTTPHeaderField:"ETag"),lastModified:http.value(forHTTPHeaderField:"Last-Modified"))
        finish(.success(ExternalHTTPResponse(status:http.statusCode,headers:headers,body:body)))
    }
}

struct ExternalConfiguration: Equatable, Sendable {
    var networkEnabled:Bool
    var weatherEnabled:Bool
    var cityID:String?
    var ratesEnabled:Bool
    var currencies:Set<String>
    init(networkEnabled:Bool,weatherEnabled:Bool,cityID:String?,ratesEnabled:Bool,currencies:Set<String>){self.networkEnabled=networkEnabled;self.weatherEnabled=weatherEnabled;self.cityID=cityID;self.ratesEnabled=ratesEnabled;self.currencies=currencies}
    init(board:BoardState){self.init(networkEnabled:board.settings.networkEnabled,weatherEnabled:board.settings.weather.enabled,cityID:board.settings.weather.cityID,ratesEnabled:board.settings.ratesEnabled,currencies:Set(board.subscriptions.map(\.currency)))}
}
struct ExternalWeatherDay: Codable, Equatable, Sendable {var date:DateOnly;var code:Int;var emoji:String?;var labelKey:String?}
struct ExternalWeatherProjection: Codable, Equatable, Sendable {
    var state:PanelExternalState
    var reasonCode:ExternalFailure?
    var cityID:String?
    var sourceTimeZone:String?
    var fetchedAt:Instant?
    var expiresAt:Instant?
    var days:[ExternalWeatherDay]
    var attribution:ExternalAttribution
}
struct ExternalRatesProjection: Codable, Equatable, Sendable {
    var state:PanelExternalState
    var reasonCode:ExternalFailure?
    var fetchedAt:Instant?
    var expiresAt:Instant?
    var entries:[PanelRatePair]
    var attribution:ExternalAttribution
    var panelRates:PanelRates {PanelRates(state:state,entries:entries)}
}
struct ExternalRefreshReceipt: Sendable {
    var accepted:Bool
    var states:[String:PanelExternalState]
    var nextAllowedAt:[String:Instant?]
}
struct ExternalPendingRequest: Sendable {var requestID:String;var kind:ExternalKind;var cancelled:Bool}
struct ExternalNetworkEffects: Sendable {
    var weatherAttempts=0,ratesAttempts=0,blockedAttempts=0,realAdapterCreations=0,cancellations=0,acceptedCompletions=0,discardedCompletions=0
    var pending:[ExternalPendingRequest]=[]
    var budgetReservations=0,budgetWriteFailures=0
    var quarantineUntil:Instant?=nil
    var keyBudgetEntries:[String:Int]=[:]
}
@MainActor final class ExternalDataService {
    private let catalog:CityCatalog
    private let cache:ExternalCache
    private let budget:NetworkBudget
    private let transport:any ExternalTransport
    private let now:()->Instant
    private var configuration=ExternalConfiguration(networkEnabled:false,weatherEnabled:false,cityID:nil,ratesEnabled:false,currencies:[])
    private var budgetReady=false
    private var queued=Set<ExternalKind>()
    private var suspensions:[UUID:Set<ExternalKind>]=[:]
    private var suspended:Set<ExternalKind> { Set(suspensions.values.flatMap { $0 }) }
    private var flights:[UUID:Flight]=[:]
    private var activeID:UUID?
    private var failures:[ExternalKind:ExternalFailure]=[:]
    private var counts=ExternalNetworkEffects()
    var didChange:(()->Void)?
    private final class Flight {
        let request:ExternalRequest
        let reservation:BudgetReservation
        let city:CatalogCity?
        let quotes:[String]
        var cancellation:(any ExternalCancellation)?
        var cancelled=false
        init(request:ExternalRequest,reservation:BudgetReservation,city:CatalogCity?,quotes:[String]){self.request=request;self.reservation=reservation;self.city=city;self.quotes=quotes}
    }
    init(catalog:CityCatalog,cache:ExternalCache,budget:NetworkBudget,transport:any ExternalTransport,now:@escaping ()->Instant={Instant(date:Date())}) {
        self.catalog=catalog;self.cache=cache;self.budget=budget;self.transport=transport;self.now=now
        counts.realAdapterCreations=transport is URLSessionExternalTransport ? 1 : 0
    }
    /// Host runs this in its initialization/recovery lane, then publishes the committed board revision.
    func initializeBudget(marker:Bool,commitMarker:()throws->Void)->Bool {
        do {
            try budget.prepare(marker:marker,now:now())
            if !marker {try commitMarker()}
            budgetReady=true
            for kind in ExternalKind.allCases {
                if (budget.state.providers[kind.rawValue]?.quarantineUntil).map({$0>now()}) == true {failures[kind] = .requestBudgetUnavailable}
                else if failures[kind] == .requestBudgetUnavailable {failures[kind]=nil}
            }
            didChange?();return true
        } catch {
            budgetReady=false;failures[.weather] = .requestBudgetUnavailable;failures[.rates] = .requestBudgetUnavailable
            didChange?();return false
        }
    }
    private func enabled(_ kind:ExternalKind)->Bool {
        !suspended.contains(kind) && configuration.networkEnabled && (kind == .weather ? configuration.weatherEnabled : configuration.ratesEnabled)
    }
    private func needed(_ kind:ExternalKind)->Bool {
        if kind == .weather {return configuration.cityID.flatMap{catalog.city($0)} != nil}
        return !configuration.currencies.subtracting(["KRW"]).intersection(RateProviderAdapter.supportedQuotes).isEmpty
    }
    private func request(_ kind:ExternalKind) throws -> ExternalRequest {
        if kind == .weather {
            guard let id=configuration.cityID,let city=catalog.city(id) else {throw ExternalFailure.invalidResponse}
            var value=try WeatherProviderAdapter.request(city:city)
            if let previous=cache.state.weather,previous.key==value.key,previous.cityID==city.id {value.headers=ExternalHeaders(etag:previous.etag,lastModified:previous.lastModified)}
            return value
        }
        var value=try RateProviderAdapter.request(currencies:configuration.currencies)
        if let previous=cache.state.rates,previous.key==value.key {value.headers=ExternalHeaders(etag:previous.etag,lastModified:previous.lastModified)}
        return value
    }
    private func fresh(_ kind:ExternalKind,at instant:Instant)->Bool {
        if kind == .weather {
            guard let id=configuration.cityID,let city=catalog.city(id),let value=cache.state.weather else {return false}
            return value.cityID==id && value.key==WeatherProviderAdapter.cacheKey(latitude:city.latitude,longitude:city.longitude) && instant<value.expiresAt && instant>=value.fetchedAt
        }
        guard let value=cache.state.rates,value.key==RateProviderAdapter.cacheKey(quotes:RateProviderAdapter.quotes(currencies:configuration.currencies)) else {return false}
        return instant<value.expiresAt && instant>=value.fetchedAt
    }
    /// Call with durable settings; suspend() is the immediate off-preview hook before a board ACK.
    func configure(_ next:ExternalConfiguration,refresh:Bool=true) {
        guard configuration != next else { return }
        configuration=next
        for flight in Array(flights.values) where !flight.cancelled {
            let expected=try? request(flight.request.kind)
            let cityChanged=flight.request.kind == .weather && flight.city?.id != next.cityID
            if !enabled(flight.request.kind) || expected?.key != flight.request.key || cityChanged {cancel(flight)}
        }
        queued=queued.filter{enabled($0) && needed($0)}
        didChange?()
        if refresh {_ = self.refresh(.all)}
    }
    @discardableResult func suspend(_ kind:ExternalRefreshKind) -> UUID {
        let kinds:[ExternalKind]=kind == .weather ? [.weather] : kind == .rates ? [.rates] : [.weather,.rates]
        let token = UUID()
        suspensions[token] = Set(kinds)
        for target in kinds {
            queued.remove(target)
            for flight in Array(flights.values) where flight.request.kind==target && !flight.cancelled {cancel(flight)}
        }
        // Only this request's success/failure completion may remove its pending off guard.
        didChange?()
        return token
    }
    func resume(_ token: UUID) {
        guard suspensions.removeValue(forKey: token) != nil else { return }
        _ = refresh(.all)
    }
    @discardableResult func refresh(_ kind:ExternalRefreshKind)->ExternalRefreshReceipt {
        let instant=now(),kinds:[ExternalKind]=kind == .weather ? [.weather] : kind == .rates ? [.rates] : [.weather,.rates]
        if budgetReady { try? budget.reconcileClock(now: instant) }
        var accepted=false
        var admitted=Set<ExternalKind>()
        let attemptsBefore=counts.weatherAttempts+counts.ratesAttempts
        for target in kinds {
            guard enabled(target),needed(target),!fresh(target,at:instant),!queued.contains(target),!flights.values.contains(where:{$0.request.kind==target && !$0.cancelled}) else {continue}
            guard budgetReady,budget.available else {failures[target] = .requestBudgetUnavailable;counts.blockedAttempts+=1;continue}
            do {
                let request=try request(target)
                guard try budget.eligibility(kind:target,key:request.key,now:instant).allowed else {counts.blockedAttempts+=1;continue}
                queued.insert(target);admitted.insert(target);accepted=true
            } catch {failures[target] = .requestBudgetUnavailable;counts.blockedAttempts+=1}
        }
        pump();didChange?()
        accepted=accepted && (counts.weatherAttempts+counts.ratesAttempts>attemptsBefore || admitted.contains(where:loading))
        var next:[String:Instant?]=[:]
        for target in ExternalKind.allCases {
            let eligibility=(try? request(target)).flatMap{try? budget.eligibility(kind:target,key:$0.key,now:instant)}
            next[target.rawValue] = .some(eligibility?.nextAllowedAt)
        }
        return ExternalRefreshReceipt(accepted:accepted,states:["weather":weatherProjection().state,"rates":ratesProjection().state],nextAllowedAt:next)
    }
    private func pump() {
        guard activeID==nil else {return}
        for kind in ExternalKind.allCases where queued.contains(kind) {
            queued.remove(kind)
            guard enabled(kind),needed(kind),budgetReady,budget.available,!fresh(kind,at:now()) else {continue}
            do {
                let request=try request(kind),instant=now()
                guard try budget.eligibility(kind:kind,key:request.key,now:instant).allowed else {continue}
                let reservation=try budget.reserve(kind:kind,key:request.key,now:instant,attemptID:request.id)
                let city=kind == .weather ? configuration.cityID.flatMap{catalog.city($0)} : nil
                let flight=Flight(request:request,reservation:reservation,city:city,quotes:RateProviderAdapter.quotes(currencies:configuration.currencies))
                flights[request.id]=flight;activeID=request.id;failures[kind]=nil
                do {
                    flight.cancellation=try transport.start(request){[weak self] result in self?.complete(request.id,result:result)}
                    if kind == .weather {counts.weatherAttempts+=1} else {counts.ratesAttempts+=1}
                } catch {
                    complete(request.id,result:.failure(.serviceUnavailable))
                }
                return
            } catch {failures[kind] = .requestBudgetUnavailable;counts.blockedAttempts+=1}
        }
    }
    private func cancel(_ flight:Flight) {
        guard !flight.cancelled else {return}
        flight.cancelled=true;flight.cancellation?.cancel();counts.cancellations+=1
        if activeID==flight.request.id {activeID=nil}
        // Release the active permit now, but retain the durable unsettled lease until
        // the transport completion confirms cancellation or supplies a late 429.
    }
    private func complete(_ id:UUID,result:Result<ExternalHTTPResponse,ExternalFailure>) {
        guard let flight=flights.removeValue(forKey:id) else {return}
        if activeID==id {activeID=nil}
        let kind=flight.request.kind,instant=now()
        if flight.cancelled {
            counts.discardedCompletions+=1
            let settlement:BudgetSettlement
            if case let .success(response)=result,response.status==429 {settlement = .rateLimited(retryAfter:response.headers.retryAfter)}
            else {settlement = .cancelled}
            do {try budget.settle(flight.reservation,outcome:settlement,now:instant)}
            catch {failures[kind] = .requestBudgetUnavailable}
            pump();didChange?();return
        }
        var next=cache.state
        var outcome:BudgetSettlement = .success
        var failure:ExternalFailure?
        do {
            let response=try result.get()
            if response.status==429 {outcome = .rateLimited(retryAfter:response.headers.retryAfter);throw ExternalFailure.rateLimited}
            guard response.body.count<=ExternalBodyBuffer.maximumBytes else {throw ExternalFailure.invalidResponse}
            guard response.status==200 || response.status==304 else {throw response.status>=500 ? ExternalFailure.serviceUnavailable : ExternalFailure.invalidResponse}
            if kind == .weather {
                guard let city=flight.city else {throw ExternalFailure.invalidResponse}
                if response.status==304 {
                    guard response.body.isEmpty,let previous=cache.state.weather else {throw ExternalFailure.invalidResponse}
                    next.weather=try WeatherProviderAdapter.revalidate(previous,city:city,now:instant,headers:response.headers)
                } else {next.weather=try WeatherProviderAdapter.parse(response.body,city:city,now:instant,headers:response.headers)}
            } else {
                if response.status==304 {
                    guard response.body.isEmpty,let previous=cache.state.rates else {throw ExternalFailure.invalidResponse}
                    next.rates=try RateProviderAdapter.revalidate(previous,quotes:flight.quotes,now:instant,headers:response.headers)
                } else {next.rates=try RateProviderAdapter.parse(response.body,quotes:flight.quotes,now:instant,headers:response.headers,previous:cache.state.rates)}
            }
        } catch {
            failure=(error as? ExternalFailure) ?? .invalidResponse
            if failure != .rateLimited {outcome=failure == .cancelled ? .cancelled : .failure(failure!)}
        }
        do {try budget.settle(flight.reservation,outcome:outcome,now:instant)}
        catch {failure = .requestBudgetUnavailable}
        if failure==nil {
            do {try cache.commit(next);counts.acceptedCompletions+=1}
            catch {failure = .serviceUnavailable}
        }
        failures[kind]=failure == .cancelled ? nil : failure
        pump();didChange?()
    }
    private func loading(_ kind:ExternalKind)->Bool {queued.contains(kind) || flights.values.contains{$0.request.kind==kind && !$0.cancelled}}
    func weatherProjection()->ExternalWeatherProjection {
        let instant=now(),id=configuration.cityID
        let matching=cache.state.weather.flatMap{value -> CachedWeather? in
            guard let id,let city=catalog.city(id),value.cityID==id,value.key==WeatherProviderAdapter.cacheKey(latitude:city.latitude,longitude:city.longitude) else {return nil};return value
        }
        let visible=enabled(.weather) && matching.map{instant<$0.staleUntil} == true
        let days:[ExternalWeatherDay]=visible ? matching!.days.map{day in let display=WeatherProviderAdapter.display(code:day.code);return ExternalWeatherDay(date:day.date,code:day.code,emoji:display.emoji,labelKey:display.labelKey)} : []
        let state:PanelExternalState = !enabled(.weather) ? .off : loading(.weather) ? .loading : !visible ? .unavailable : fresh(.weather,at:instant) ? .fresh : .stale
        return ExternalWeatherProjection(state:state,reasonCode:enabled(.weather) ? failures[.weather] : nil,cityID:id,sourceTimeZone:visible ? matching?.sourceTimeZone : nil,fetchedAt:matching?.fetchedAt,expiresAt:matching?.expiresAt,days:days,attribution:WeatherProviderAdapter.attribution)
    }
    func ratesProjection()->ExternalRatesProjection {
        let pairs=cache.state.rates?.pairs ?? [],foreign=configuration.currencies.subtracting(["KRW"])
        let used=pairs.filter{foreign.contains($0.currency)},oldest=used.map(\.fetchedAt).min()
        let missing=foreign.subtracting(Set(used.map(\.currency)))
        let expired=oldest.map{now()>=$0.adding(seconds:RateProviderAdapter.freshSeconds) || now()<$0} ?? false
        let state:PanelExternalState = !enabled(.rates) ? .off : loading(.rates) ? .loading : foreign.isEmpty ? .fresh : used.isEmpty ? .unavailable : expired ? .stale : .fresh
        let reason=failures[.rates] ?? (!missing.isEmpty ? ExternalFailure.unsupportedCurrency : nil)
        return ExternalRatesProjection(state:state,reasonCode:enabled(.rates) ? reason : nil,fetchedAt:oldest,expiresAt:oldest?.adding(seconds:RateProviderAdapter.freshSeconds),entries:pairs,attribution:RateProviderAdapter.attribution)
    }
    var effects:ExternalNetworkEffects {
        var result=counts
        result.pending=flights.values.map{ExternalPendingRequest(requestID:$0.request.id.uuidString.lowercased(),kind:$0.request.kind,cancelled:$0.cancelled)}.sorted{$0.requestID<$1.requestID}
        result.budgetReservations=budget.reservations;result.budgetWriteFailures=budget.writeFailures
        result.quarantineUntil=budget.effectiveQuarantineUntil
        result.keyBudgetEntries=budget.state.providers.mapValues{$0.keys.count}
        return result
    }
}
