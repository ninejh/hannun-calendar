import Foundation
import AppKit
import Combine

private enum CalendarRefreshContext {
    @TaskLocal static var id: UUID?
}

private final class CalendarRefreshCapture {
    var value: Date?
    var order = 0
}

/// Composition injects logical bounds before the first load and may supply them on a later Retry.
/// The provider returns Foundation values only; persistence never queries screens or UI objects.
struct NativeViewportStateFile: BoardPersistence {
    let url: URL
    var defaultWeatherCityID: String? = nil
    var viewport: (() -> LayoutViewport?)? = nil
    private var file: LocalStateFile {
        LocalStateFile(url: url, defaultWeatherCityID: defaultWeatherCityID, layoutViewport: viewport?())
    }
    func load() throws -> BoardState { try file.load() }
    func save(_ state: BoardState) throws { try file.save(state) }
}

/// Application boundary shared by the native UI, test host and normal-clock private preflight.
/// Every durable service uses this instance's store/write lane; no UI/host/WK dependency exists.
@MainActor final class NativeBoardApplication: BoardApplication, RuntimeLifecycle {
    let sessionID = UUID()
    let configuration: ValidatedRuntimeConfiguration
    let store: BoardStore
    let calendars: CalendarService
    let preferences: NativePreferences
    let clock: NativeApplicationClock
    let panels: NativePanelServices
    let writeLane = NativeWriteLane()
    private(set) var current: BoardSnapshot
    private var ledger: [UUID: NativeOperationRecord] = [:]
    private var completedOrder: [UUID] = []
    private var observers: [(UUID, @MainActor (BoardUpdate) -> Void)] = []
    private var updates: [BoardUpdate] = []
    private var publishing = false
    private var serviceWarning: AppFailure?
    private var projectionWarning: AppFailure?
    private var tokens: [UndoToken: UUID] = [:]
    private var createdIDs = Set<String>()
    private var initialized = false
    private var budgetInitialized = false
    private var initialization: Task<Void, Never>?
    private var lastRollover: (DateOnly, Int)?
    private var networkMonitor: NetworkClockMonitor
    private var networkJump = false
    private var lastExternalTick: Instant?
    private var lastMinute: Int64?
    private var lastSecond: Int64?
    private var reconciling = false
    private var lastCalendarRefresh: Date = .distantPast
    private var calendarRefreshOrder = 0
    private var adoptedCalendarRefreshOrder = 0
    private var loaded = false
    private var ready = false
    private var pendingSettings: UUID?
    private var sentActions = Set<UUID>()
    private lazy var scheduler = NativeRuntimeScheduler(application: self)
    private var nonactivating = false, stationary = false, desktopLevel = false
    private(set) var lastAttribution: AttributionKind?
#if HANNUN_TESTING
    let testControls = NativeRuntimeTestControls()
    private var postCommitFailure: AppFailure?
#endif
    var observerCount: Int { observers.count }
    var isRunning: Bool { scheduler.isRunning }
    var schedulerTimerCount: Int { scheduler.timerCount }
    var cachedReceiptCount: Int { ledger.values.filter { $0.cell?.receipt != nil }.count }
    var retainedPayloadBytes: Int { ledger.values.reduce(0) { $0 + ($1.inverse?.payloadBytes ?? 0) } }

    /// Inject a synthetic store/adapters only in fake modes. Production construction is centralized
    /// in make; UI consumers receive any BoardApplication rather than these dependencies.
    init(configuration: ValidatedRuntimeConfiguration, store: BoardStore, calendars suppliedCalendars: CalendarService? = nil,
         preferences suppliedPreferences: NativePreferences? = nil, catalog: CityCatalog? = nil) throws {
        let demo = configuration.adapterMode == .fake
        let preferences = suppliedPreferences ?? NativePreferences(demo: demo)
        guard preferences.demo == demo, suppliedCalendars == nil || suppliedCalendars!.demo == demo else {
            throw AppFailure(code: .invalidRequest, field: .configuration)
        }
        guard DateOnly(date: preferences.now, timeZone: preferences.timeZone) != nil else { throw AppFailure(code: .invalidDate) }
#if HANNUN_TESTING
        guard configuration.clock == .manual || preferences.testNow == nil else {
            throw AppFailure(code: .invalidRequest, field: .configuration)
        }
#endif
        self.configuration = configuration; self.store = store; self.preferences = preferences
        calendars = suppliedCalendars ?? CalendarService(demo: demo)
        clock = NativeApplicationClock(configuration: configuration, preferences: preferences)
        panels = NativePanelServices(store: store, preferences: preferences, lane: writeLane,
                                     scratchRoot: configuration.scratchDirectory, clock: clock.panelClock, catalog: catalog)
        networkMonitor = NetworkClockMonitor(now: clock.snapshot.now, elapsedMilliseconds: clock.snapshot.continuousMilliseconds)
        current = try Self.snapshot(sessionID: sessionID, sequence: 0, configuration: configuration, store: store,
                                    calendars: calendars, preferences: preferences, clock: clock, panels: panels)
        current.calendarRefreshedAt = calendars.refreshedAt
        let previousPublish = store.didPublish
        store.didPublish = { [weak self] old, next in
            previousPublish?(old, next)
            guard let self else { return }
            self.panels.notifications.boardDidCommit(previous: old)
            self.panels.external.configure(ExternalConfiguration(board: next), refresh: false)
            self.publishSnapshot()
        }
        let previousIntercept = store.interceptCommit
        store.interceptCommit = { [weak self] committed in
            try previousIntercept?(committed)
            guard let self else { return }
            guard self.writeLane.ownsCurrentTask else { throw AppFailure(code: .busyRetry) }
#if HANNUN_TESTING
            if committed {
                if let error = self.postCommitFailure { self.postCommitFailure = nil; throw error }
            } else {
                self.postCommitFailure = nil
                if let failure = self.testControls.nextStorageFailure {
                    self.testControls.nextStorageFailure = nil
                    if failure.committed == .yes { self.postCommitFailure = failure } else { throw failure }
                }
            }
#endif
        }
        panels.notifications.didCommitPreference = { [weak self] id, before, after in
            guard let self, let id = UUID(uuidString: id), let source = self.ledger[id], source.undoable else { return }
            source.inverse = NativeBoardInverse(before: before, after: after)
        }
        panels.external.didChange = { [weak self] in self?.publishExternal() }
    }

    /// Configuration has already rejected test/production fallbacks before any adapters are built.
    static func make(configuration: ValidatedRuntimeConfiguration, initialState: BoardState? = nil, layoutViewport: (() -> LayoutViewport?)? = nil) throws -> NativeBoardApplication {
        let store: BoardStore
        switch configuration.mode {
        case .demoMemory: store = BoardStore(initialState: initialState ?? DemoData.state)
        case .demoScratch:
            guard initialState == nil, let root = configuration.scratchDirectory else { throw AppFailure(code: .invalidRequest) }
            store = BoardStore(persistence: NativeViewportStateFile(url: root.appendingPathComponent("board.json"), viewport: layoutViewport))
        case .production:
            guard initialState == nil, let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                throw AppFailure(code: .invalidRequest)
            }
            let defaultCity = (try? CityCatalog())?.defaultCityID(timeZone: .current)
            store = BoardStore(persistence: NativeViewportStateFile(url: support.appendingPathComponent("HannunCalendar/board.json"), defaultWeatherCityID: defaultCity, viewport: layoutViewport))
        }
        return try NativeBoardApplication(configuration: configuration, store: store)
    }
    func start() { scheduler.start() }
    func stop() { scheduler.stop() }

    func observe(_ receive: @escaping @MainActor (BoardUpdate) -> Void) -> ObservationToken {
        let id = UUID(); observers.append((id, receive)); receive(.snapshot(current))
        return ObservationToken { [weak self] in self?.observers.removeAll { $0.0 == id } }
    }
    private func emit(_ update: BoardUpdate) {
        updates.append(update)
        guard !publishing else { return }
        publishing = true
        defer { publishing = false }
        while !updates.isEmpty {
            let update = updates.removeFirst()
            for (id, receive) in observers where observers.contains(where: { $0.0 == id }) { receive(update) }
        }
    }
    func submit(_ command: BoardCommand, context: OperationContext) -> OperationHandle {
        let operation = NativeOperation(command)
        let digest = NativeCommandDigest.command(command, revision: context.baseRevision)
        if let existing = existing(context, fingerprint: digest) { return existing }
        let undoable: Bool
        switch command {
        case .edit(let edit, let value):
            let sizing = NativeBoardMutator.atoms(edit).contains { atom in
                switch atom { case .layout(.setStep), .layout(.setSplit), .layout(.reset), .panel(.resetLayout): true; default: false }
            }
            undoable = value && !sizing
        case .saveEvent(let input): if case .metadataOnly = input { undoable = false } else { undoable = true }
        case .notification: undoable = true
        default: undoable = false
        }
        guard ledger.count < (operation.writes ? 20000 : 21000) else { return rejected(context.id, AppFailure(code: .busyRetry)) }
        let entry = record(context, digest: digest, operation: operation, undoable: undoable)
        do {
            // Off admission is synchronous, validated against this durable revision, and token scoped.
            if case .edit(let edit, _) = command, context.baseRevision == store.state.boardRevision {
                let next = try NativeBoardMutator.apply(edit, to: store.state, calendars: calendars,
                                                        clock: clock.snapshot, cityIDs: panels.catalog.validIDs)
                let old = store.state.settings, new = next.settings
                if old.networkEnabled && !new.networkEnabled { entry.externalSuspension = panels.external.suspend(.all) }
                else {
                    let weather = old.weather.enabled && !new.weather.enabled, rates = old.ratesEnabled && !new.ratesEnabled
                    if weather || rates { entry.externalSuspension = panels.external.suspend(weather && rates ? .all : weather ? .weather : .rates) }
                }
            }
            if case .notification(let target, _) = command {
                try requireRevision(entry)
                guard store.canSave else { throw AppFailure(code: .storageProtected) }
                if case .subscription(let id) = target {
                    guard store.state.subscriptions.contains(where: { $0.id == id }) else { throw AppFailure(code: .boardConflict) }
                }
                entry.inverse = NativeBoardInverse(before: store.state, after: store.state)
                panels.notifications.admitPreference(target, requestID: context.id.uuidString.lowercased())
                Task { await self.execute(command, entry: entry) } // Permission awaits never own the durable lane.
            } else if operation.writes {
                if case .undoCreate(let token) = command { try admitTokenUndo(token, create: true, entry: entry) }
                if case .undoEvent(let token) = command { try admitTokenUndo(token, create: false, entry: entry) }
                writeLane.enqueue { await self.execute(command, entry: entry) }
            } else { Task { await self.execute(command, entry: entry) } }
        } catch { finish(entry, .failure(NativeRuntimeErrors.normalize(error), snapshot: nil)) }
        return entry.handle!
    }
    func result(of id: UUID, sessionID: UUID) -> Result<OperationStatus, AppFailure> {
        guard sessionID == self.sessionID else { return .failure(AppFailure(code: .staleSession)) }
        sweep()
        guard let entry = ledger[id] else { return .success(.notFound) }
        if entry.retired { return .success(.retired) }
        if let receipt = entry.cell?.receipt { return .success(.completed(receipt)) }
        return .success(.pending)
    }
    private func existing(_ context: OperationContext, fingerprint: Data) -> OperationHandle? {
        guard context.sessionID == sessionID else { return rejected(context.id, AppFailure(code: .staleSession)) }
        sweep()
        guard let entry = ledger[context.id] else { return nil }
        guard entry.fingerprint == fingerprint else { return rejected(context.id, AppFailure(code: .duplicateRequest)) }
        guard !entry.retired, let handle = entry.handle else { return rejected(context.id, AppFailure(code: .requestRetired)) }
        return handle
    }
    private func rejected(_ id: UUID, _ error: AppFailure) -> OperationHandle {
        OperationHandle(id: id, settled: Task { .failure(error, snapshot: nil) })
    }
    private func record(_ context: OperationContext, digest: Data, operation: NativeOperation, undoable: Bool) -> NativeOperationRecord {
        var delay = 0
#if HANNUN_TESTING
        delay = testControls.takeDelay(operation, .observation)
#endif
        let entry = NativeOperationRecord(context: context, fingerprint: digest, operation: operation,
                                           received: clock.snapshot, undoable: undoable, observationDelay: delay)
        ledger[context.id] = entry
        return entry
    }
    private func execute(_ command: BoardCommand, entry: NativeOperationRecord) async {
        defer {
            if let suspension = entry.externalSuspension { panels.external.resume(suspension); entry.externalSuspension = nil }
        }
        do {
#if HANNUN_TESTING
            let delay = testControls.takeDelay(entry.operation, .execution)
            if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
            if let failure = testControls.takeFailure(entry.operation) { throw failure }
#endif
            let result = try await perform(command, entry: entry)
            finish(entry, .success(result, snapshot: nil))
        } catch {
            let error = NativeRuntimeErrors.normalize(error)
            if entry.operation != .connect && ([.eventConflict, .eventNotFound, .calendarPermission].contains(error.code) || error.committed == .unknown) {
                await calendars.refresh(ranges: ranges, now: preferences.now, refreshSources: true)
            }
            finish(entry, .failure(error, snapshot: nil))
        }
    }
    private func finish(_ entry: NativeOperationRecord, _ receipt: CommandReceipt) {
        if entry.operation.writes || entry.operation == .refresh || entry.operation == .connect {
            publishSnapshot()
        }
        entry.cell?.resolve(receipt.compact)
        completedOrder.append(entry.context.id)
        sweep()
    }
    private func sweep() {
        let reading = clock.snapshot
        var remaining: [UUID] = []
        var live = completedOrder.count
        for id in completedOrder {
            guard let entry = ledger[id] else { continue }
            let compensationPending = entry.undoAccepted && entry.undoReceipt == nil
            let uncertainUndo: Bool
            if case .failure(let failure, _) = entry.undoReceipt { uncertainUndo = failure.committed == .unknown }
            else { uncertainUndo = false }
            let pinned = compensationPending || entry.commitment == .unknown || uncertainUndo || entry.undoable && !entry.invalidated && !entry.expired(at: reading)
            if !pinned { if let token = entry.token { tokens.removeValue(forKey: token) }; entry.releaseInverse() }
            if live > 32 && !pinned {
                entry.retire(); live -= 1
            } else { remaining.append(id) }
        }
        completedOrder = remaining
    }
    private func requireRevision(_ entry: NativeOperationRecord) throws {
        guard entry.context.baseRevision == store.state.boardRevision else { throw AppFailure(code: .boardConflict) }
    }
    private func perform(_ command: BoardCommand, entry: NativeOperationRecord) async throws -> CommandResult {
        switch command {
        case .refresh(let range, let sources):
            try setRange(range)
            if !store.canSave {
                try await writeLane.run { [self] in
                    _ = try store.retryLoad(); initialized = false; budgetInitialized = false; lastRollover = nil
                }
            }
            await initializeServices()
            let capture = await captureCalendarRefresh {
#if HANNUN_TESTING
                if sources {
                    await calendars.refresh(ranges: ranges, now: preferences.now, refreshSources: sources, explicitUserRefresh: true)
                } else {
                    await calendars.refresh(ranges: ranges, now: preferences.now, refreshSources: sources)
                }
#else
                await calendars.refresh(ranges: ranges, now: preferences.now, refreshSources: sources)
#endif
            }
            if let error = calendars.error {
                let code = AppFailureCode(rawValue: error) ?? .calendarUnavailable
                throw AppFailure(code: code, messageKey: "error." + code.rawValue.lowercased(), retryable: true)
            }
            if !calendars.authorized && !calendars.demo {
                throw AppFailure(code: .calendarPermission, messageKey: "error.calendar_permission")
            }
            adoptCalendarRefresh(capture)
            return .refreshed
        case .connect:
            let capture = try await captureCalendarRefresh {
                try await calendars.connect(ranges: ranges, now: preferences.now)
            }
            guard calendars.authorized else { throw AppFailure(code: .calendarPermission, messageKey: "error.calendar_permission") }
            if let error = calendars.error {
                let code = AppFailureCode(rawValue: error) ?? .calendarUnavailable
                throw AppFailure(code: code, messageKey: "error." + code.rawValue.lowercased(), retryable: true)
            }
            adoptCalendarRefresh(capture)
            return .connected
        case .edit(let edit, _):
            try requireRevision(entry)
            let before = store.state
            let candidate = try NativeBoardMutator.apply(edit, to: before, calendars: calendars, clock: clock.snapshot, cityIDs: panels.catalog.validIDs)
            let changed = candidate != before
            defer { if entry.undoable && changed { entry.inverse = NativeBoardInverse(before: before, after: store.state) } }
            try store.commit(candidate, baseRevision: entry.context.baseRevision)
            if !changed { entry.invalidated = true }
            // The requested user change is already durable. A following reconciliation failure
            // is an inline service warning, never a fabricated uncommitted user failure.
            do { _ = try panels.focus.reconcile(.interaction); publishServiceWarning(nil) }
            catch { publishServiceWarning(NativeRuntimeErrors.normalize(error)) }
            panels.external.configure(ExternalConfiguration(board: store.state))
            let removed = DeletedRefs(projects: deletedIDs(before.projects, store.state.projects),
                                      countdowns: deletedIDs(before.milestones, store.state.milestones),
                                      panels: PanelDeletedRefs(
                                        subscriptions: deletedIDs(before.subscriptions, store.state.subscriptions),
                                        todos: deletedIDs(before.todos, store.state.todos),
                                        habits: deletedIDs(before.habits, store.state.habits),
                                        cityIDs: deletedIDs(before.worldClockCities, store.state.worldClockCities)))
            let revealed = NativeBoardMutator.atoms(edit).contains { if case .panel(.revealAgenda) = $0 { true } else { false } }
                ? candidate.layout.slots.first(where: { $0.value == .today }).flatMap { SlotID(rawValue: $0.key) } : nil
            return .boardSaved(BoardSaveResult(revision: store.state.boardRevision, deletedRefs: removed,
                                                undo: entry.undoable && changed ? descriptor(entry, kind: .board) : nil, revealedSlotID: revealed))
        case .saveEvent(let input): try requireRevision(entry); return .eventSaved(try await saveEvent(input, entry: entry))
        case .focus(let command):
            try requireRevision(entry); _ = try panels.focus.command(command)
            publishServiceWarning(nil)
            return .focus(FocusCommandResult(focus: panels.focus.projection(), boardRevision: store.state.boardRevision))
        case .notification(let target, let enabled):
            let result = try await panels.notifications.setPreference(target, enabled: enabled, baseRevision: entry.context.baseRevision,
                       requestID: entry.context.id.uuidString.lowercased(), alreadyAdmitted: true)
            return .notification(result)
        case .undoCreate(let token), .undoEvent(let token):
            guard let id = tokens[token], let source = ledger[id], !source.invalidated else { throw AppFailure(code: .undoUnavailable) }
            if case .undoCreate = command { guard source.beforeEvent == nil else { throw AppFailure(code: .undoUnavailable) } }
            else { guard source.beforeEvent != nil else { throw AppFailure(code: .undoUnavailable) } }
            try acceptUndo(source)
            if let old = source.undoReceipt {
                switch old { case .success(let result, _): return result; case .failure(let error, _): throw error }
            }
            let result = try await compensate(source)
            source.undoReceipt = .success(.undone(result), snapshot: nil)
            return .undone(result)
        case .invalidateUndo(let token):
            if let id = tokens[token], let source = ledger[id], !source.undoAccepted {
                source.invalidated = true; tokens.removeValue(forKey: token)
                if source.commitment != .unknown { source.releaseInverse() }
            }
            return .undoInvalidated
        case .open(let target): try preferences.open(target.rawValue); return .opened(target)
        case .setLogin(let enabled): try await preferences.setLogin(enabled); return .login(Self.login(preferences))
        case .diagnostics:
            return .diagnostics(Diagnostics(demo: configuration.adapterMode == .fake, authorized: calendars.authorized,
                     nonactivating: nonactivating, stationary: stationary, desktopLevel: desktopLevel,
                     appearance: current.environment.resolvedAppearance, loginItemStatus: Self.login(preferences),
                     storageStatus: current.storage, calendarAdapter: configuration.adapterMode == .fake ? .fake : .eventkit,
                     accountAccessCount: calendars.accountAccessCount, externalNavigationBlockedCount: 0))
        case .readAudit: return .audit(try await calendars.audit(ranges: ranges))
        case .uiReady:
            guard loaded else { throw AppFailure(code: .invalidRequest) }
            ready = true
            if let id = pendingSettings { pendingSettings = nil; requestSettings(actionID: id) }
            return .ready
        case .refreshExternal(let kind): return .externalAccepted(panels.external.refresh(kind))
        case .listCities(let query):
            guard query.count <= 100 else { throw AppFailure(code: .invalidRequest) }
            return .cities(panels.catalog.search(query))
        case .openAttribution(let kind):
            let raw: String?
            switch kind {
            case .weather: raw = WeatherProviderAdapter.attribution.sourceURL
            case .rates: raw = RateProviderAdapter.attribution.sourceURL
            case .weatherLicense: raw = WeatherProviderAdapter.attribution.licenseURL
            case .ratesLicense: raw = RateProviderAdapter.attribution.licenseURL
            }
            guard let raw, let url = URL(string: raw), url.scheme == "https",
                  configuration.adapterMode == .fake || NSWorkspace.shared.open(url) else {
                throw AppFailure(code: .osOpenFailed)
            }
            lastAttribution = kind
            return .attributionOpened
        }
    }

    private func deletedIDs<T: Identifiable & Equatable>(_ original: [T], _ updated: [T]) -> [T.ID] {
        guard original != updated else { return [] }
        let remaining = Set(updated.map(\.id))
        return original.map(\.id).filter { !remaining.contains($0) }
    }

    private var displayRange: DisplayRange?
#if HANNUN_TESTING
    /// Observes the actual ranges sent to the calendar adapter without accessing an account.
    var testCalendarQueryRanges: [QueryRange] { ranges }
#endif
    private var ranges: [QueryRange] {
        let calendar = preferences.calendar, now = preferences.now
        let today = calendar.startOfDay(for: now)
        var result: [QueryRange] = []
        if let end = calendar.date(byAdding: .day, value: 367, to: today), DateOnly(date: end, timeZone: calendar.timeZone) != nil {
            result.append(QueryRange(start: today, end: end))
        }
        if let range = displayRange {
            result.append(QueryRange(start: calendar.startOfDay(for: range.visibleStart.date(in: calendar.timeZone)),
                                     end: calendar.startOfDay(for: range.endExclusive.date(in: calendar.timeZone))))
        } else if let interval = calendar.dateInterval(of: .month, for: now) {
            result.append(QueryRange(start: interval.start.addingTimeInterval(-7 * 86400), end: interval.end.addingTimeInterval(7 * 86400)))
        }
        return result
    }
    private func setRange(_ range: DisplayRange) throws {
        guard range.month.day == 1, range.month.year < 9999, range.visibleStart < range.endExclusive,
              range.endExclusive.ordinal - range.visibleStart.ordinal <= 366 else { throw AppFailure(code: .invalidDate, field: .range) }
        displayRange = range
    }
    func load(_ range: DisplayRange?) async -> CommandReceipt {
        do {
            if let range { try setRange(range) }
            await initializeServices()
            await panels.notifications.observePermission(.interaction)
            let capture = await captureCalendarRefresh {
                await calendars.refresh(ranges: ranges, now: preferences.now)
            }
            if let error = calendars.error {
                let code = AppFailureCode(rawValue: error) ?? .calendarUnavailable
                throw AppFailure(code: code, messageKey: "error." + code.rawValue.lowercased())
            }
            adoptCalendarRefresh(capture)
            loaded = true; lastCalendarRefresh = preferences.now; publishSnapshot()
            return .success(.loaded, snapshot: current)
        } catch { publishSnapshot(); return .failure(NativeRuntimeErrors.normalize(error), snapshot: current) }
    }
    func flush() async -> CommandReceipt {
        let pending = ledger.values.filter { $0.operation.writes && $0.cell?.receipt == nil }.compactMap(\.cell)
        for cell in pending { _ = await cell.wait() }
        do {
            try await writeLane.run { [self] in if let error = store.lastError { throw error } }
            if let unknown = ledger.values.first(where: { $0.commitment == .unknown && $0.cell?.receipt != nil })?.cell?.receipt { return unknown }
            return .success(.ready, snapshot: nil)
        } catch { return .failure(NativeRuntimeErrors.normalize(error), snapshot: nil) }
    }
    func requestSettings(actionID: UUID = UUID()) {
        guard !sentActions.contains(actionID) else { return }
        guard ready else { pendingSettings = actionID; return }
        sentActions.insert(actionID); emit(.action(.openSettings(actionID: actionID)))
    }
    func setWindowDiagnostics(nonactivating: Bool, stationary: Bool, desktopLevel: Bool) {
        self.nonactivating = nonactivating; self.stationary = stationary; self.desktopLevel = desktopLevel
    }
    func publishEnvironment() {
        let environment = Self.environment(preferences, settings: store.state.settings)
        guard environment != current.environment else { return }
        current.environment = environment; emit(.environment(environment))
    }
    private func publishSnapshot() {
        let nextSequence = current.sequence + 1
        let calendarRefreshedAt = current.calendarRefreshedAt
        do {
#if HANNUN_TESTING
            try testControls.checkSnapshot()
#endif
            current = try Self.snapshot(sessionID: sessionID, sequence: nextSequence, configuration: configuration, store: store,
                                        calendars: calendars, preferences: preferences, clock: clock, panels: panels)
            projectionWarning = nil
        } catch {
            // Preserve the last safe derived summary, but still publish the latest durable
            // board/calendar/focus and the failure; a failed projection cannot silence recovery.
            projectionWarning = NativeRuntimeErrors.normalize(error)
            do {
#if HANNUN_TESTING
                try testControls.checkSnapshot()
#endif
                current = try Self.snapshot(sessionID: sessionID, sequence: nextSequence, configuration: configuration, store: store,
                                      calendars: calendars, preferences: preferences, clock: clock, panels: panels,
                                      fallbackSummary: current.subscriptionSummary)
            } catch {
                // Keep the authoritative durable board even when every projection fails.
                // Mark the partial snapshot protected until a complete projection succeeds.
                current.board = store.state; current.sequence = nextSequence; current.storage = .protected
            }
        }
        current.calendarRefreshedAt = calendarRefreshedAt
        current.storageWarning = effectiveStorageWarning
        clock.didPublish(current.clock); emit(.snapshot(current))
    }
    // @Published emits synchronously in the task which actually adopts the service result.
    // Task-local attribution excludes recovery and stale completions even when calls overlap.
    private func captureCalendarRefresh(_ action: () async throws -> Void) async rethrows -> CalendarRefreshCapture {
        let id = UUID(), capture = CalendarRefreshCapture()
        let observation = calendars.$refreshedAt.sink { [weak self] value in
            guard CalendarRefreshContext.id == id, let self, let value,
                  self.calendars.authorized, self.calendars.error == nil else { return }
            self.calendarRefreshOrder += 1
            capture.order = self.calendarRefreshOrder
            capture.value = value
        }
        defer { observation.cancel() }
        try await CalendarRefreshContext.$id.withValue(id) { try await action() }
        return capture
    }
    private func adoptCalendarRefresh(_ capture: CalendarRefreshCapture) {
        guard !Task.isCancelled, let value = capture.value,
              capture.order > adoptedCalendarRefreshOrder else { return }
        adoptedCalendarRefreshOrder = capture.order
        current.calendarRefreshedAt = value
    }
    private var effectiveStorageWarning: AppFailure? {
        store.lastError.map { NativeRuntimeErrors.normalize($0) } ?? serviceWarning ?? projectionWarning
    }
    private func publishServiceWarning(_ failure: AppFailure?) {
        serviceWarning = failure
        if current.storageWarning != effectiveStorageWarning { publishSnapshot() }
    }
    private func publishExternal() {
        current.external = ExternalProjection(weather: panels.external.weatherProjection(), rates: panels.external.ratesProjection())
        do {
            current.subscriptionSummary = try PanelMath.reduceSubscriptions(store.state.subscriptions, rates: current.external.rates.panelRates, now: clock.snapshot.now)
            projectionWarning = nil
        } catch { projectionWarning = NativeRuntimeErrors.normalize(error) }
        if current.storageWarning != effectiveStorageWarning { publishSnapshot() }
        emit(.external(current.external))
    }
    private static func environment(_ preferences: NativePreferences, settings: BoardSettings) -> EnvironmentSnapshot {
        let value = preferences.environment(settings)
        return EnvironmentSnapshot(resolvedAppearance: (value["resolvedAppearance"] as? String) == "dark" ? .dark : .light,
                     resolvedWeekStart: value["resolvedWeekStart"] as? Int ?? 1, reduceMotion: value["reduceMotion"] as? Bool ?? false,
                     timeZone: preferences.timeZone.identifier, localeIdentifier: Locale.current.identifier)
    }
    private static func calendarAuthorization(_ state: CalendarAccessState) -> CalendarAuthorization {
        switch state {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        case .writeOnly: return .writeOnly
        case .fullAccess: return .authorized
        case .unavailable: return .unavailable
        }
    }
    private static func login(_ preferences: NativePreferences) -> LoginStatus {
        LoginStatus(rawValue: preferences.login["status"] as? String ?? "notFound") ?? .notFound
    }
    private static func snapshot(sessionID: UUID, sequence: Int, configuration: ValidatedRuntimeConfiguration, store: BoardStore,
                                  calendars: CalendarService, preferences: NativePreferences, clock: NativeApplicationClock,
                                  panels: NativePanelServices, fallbackSummary: SubscriptionSummary? = nil) throws -> BoardSnapshot {
        let rates = panels.external.ratesProjection(), weather = panels.external.weatherProjection()
        let permission = panels.notifications.permission, board = store.state
        return BoardSnapshot(sessionID: sessionID, sequence: sequence, board: board,
               calendar: CalendarSnapshot(calendars: calendars.calendars, records: calendars.records, defaultCalendarID: calendars.defaultCalendarID),
               calendarAuthorization: Self.calendarAuthorization(calendars.accessState),
               clock: clock.snapshot, environment: environment(preferences, settings: board.settings),
               storage: !store.canSave ? .protected : configuration.mode == .demoMemory ? .demoMemory : .ready,
               storageWarning: store.lastError.map { NativeRuntimeErrors.normalize($0) }, login: login(preferences), focus: panels.focus.projection(),
               notification: NotificationProjection(permission: permission, focusDesired: board.settings.focus.notifyOnFinish,
                   focusEffective: board.settings.focus.notifyOnFinish && permission.effective,
                   subscriptions: board.subscriptions.map { SubscriptionNotificationState(id: $0.id, desired: $0.notify, effective: $0.notify && permission.effective) }),
               external: ExternalProjection(weather: weather, rates: rates),
               subscriptionSummary: try fallbackSummary ?? PanelMath.reduceSubscriptions(board.subscriptions, rates: rates.panelRates, now: clock.snapshot.now),
               panelMetadata: PanelMetadata())
    }

    func requestUndo(source id: UUID, context: OperationContext) -> OperationHandle {
        let digest = NativeCommandDigest.undo(id, revision: context.baseRevision)
        if let existing = existing(context, fingerprint: digest) { return existing }
        guard ledger.count < 20000 else { return rejected(context.id, AppFailure(code: .busyRetry)) }
        let entry = record(context, digest: digest, operation: .requestUndo, undoable: false)
        do {
            guard let source = ledger[id] else { throw AppFailure(code: .undoUnavailable) }
            try acceptUndo(source)
            if source.operation == .notification { panels.notifications.cancelPendingPreference(requestID: id.uuidString.lowercased()) }
            if let receipt = source.undoReceipt { finish(entry, receipt); return entry.handle! }
            if let undoID = source.undoOperationID, let cell = ledger[undoID]?.cell {
                Task { self.finish(entry, await cell.wait()) }
            } else {
                source.undoOperationID = context.id
                // Waiting for a held permission/source is deliberately outside the write FIFO.
                if let cell = source.cell, cell.receipt == nil {
                    Task {
                        _ = await cell.wait()
                        self.writeLane.enqueue { await self.performCompensation(source, entry: entry) }
                    }
                } else { writeLane.enqueue { await self.performCompensation(source, entry: entry) } }
            }
        } catch { finish(entry, .failure(NativeRuntimeErrors.normalize(error), snapshot: nil)) }
        return entry.handle!
    }
    private func acceptUndo(_ source: NativeOperationRecord) throws {
        guard !source.retired else { throw AppFailure(code: .requestRetired) }
        guard source.undoable, !source.invalidated || source.undoAccepted else { throw AppFailure(code: .undoUnavailable) }
        guard source.undoAccepted || !source.expired(at: clock.snapshot) else { throw AppFailure(code: .undoExpired) }
        source.undoAccepted = true
    }
    private func admitTokenUndo(_ token: UndoToken, create: Bool, entry: NativeOperationRecord) throws {
        guard let id = tokens[token], let source = ledger[id], !source.invalidated,
              (source.beforeEvent == nil) == create else { throw AppFailure(code: .undoUnavailable) }
        try acceptUndo(source)
        if source.undoOperationID == nil { source.undoOperationID = entry.context.id }
    }
    private func performCompensation(_ source: NativeOperationRecord, entry: NativeOperationRecord) async {
        if let receipt = source.undoReceipt { finish(entry, receipt); return }
        let receipt: CommandReceipt
        do {
#if HANNUN_TESTING
            let delay = testControls.takeDelay(.requestUndo, .execution)
            if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
            if let error = testControls.takeFailure(.requestUndo) { throw error }
#endif
            receipt = .success(.undone(try await compensate(source)), snapshot: nil)
        } catch { receipt = .failure(NativeRuntimeErrors.normalize(error), snapshot: nil) }
        source.undoReceipt = receipt
        finish(entry, receipt)
    }
    private func compensate(_ source: NativeOperationRecord) async throws -> UndoResult {
        switch source.commitment {
        case .no:
            source.invalidated = true
            return UndoResult(undone: true, sourceCommitted: .no, calendarWritten: false, metadataStatus: .saved)
        case .unknown: throw AppFailure(code: .commitOutcomeUnknown, committed: .unknown)
        case .yes: break
        }
        guard let inverse = source.inverse else { throw AppFailure(code: .undoUnavailable) }
        if source.operation != .saveEvent {
            let next = try inverse.apply(to: store.state)
            try store.commit(next)
            source.invalidated = true
            panels.external.configure(ExternalConfiguration(board: store.state))
            return UndoResult(undone: true, sourceCommitted: .yes, calendarWritten: false, metadataStatus: .saved)
        }
        guard let saved = source.afterEvent else { throw AppFailure(code: .commitOutcomeUnknown, committed: .unknown) }
        var next: BoardState
        if source.beforeEvent == nil {
            next = store.state
            next.pinnedEventKeys.remove(saved.pinKey); next.eventProjectLinks.removeValue(forKey: saved.pinKey)
        } else { next = try inverse.apply(to: store.state) }
        let restored: EventRecord?
        if let original = source.beforeEvent {
            restored = try await calendars.save(original.draft, original: saved)
            remapCreated(original: saved, saved: restored!)
        } else {
            guard createdIDs.contains(saved.id) else { throw AppFailure(code: .undoUnavailable) }
            try await calendars.removeCreated(saved); createdIDs.remove(saved.id); restored = nil
        }
        // Source write succeeded: consume before the independent metadata transaction.
        source.invalidated = true
        if let token = source.token { tokens.removeValue(forKey: token) }
        if let original = source.beforeEvent, let restored, original.pinKey != restored.pinKey {
            let pinned = next.pinnedEventKeys.remove(original.pinKey) != nil
            let project = next.eventProjectLinks.removeValue(forKey: original.pinKey)
            if pinned { next.pinnedEventKeys.insert(restored.pinKey) }
            if let project { next.eventProjectLinks[restored.pinKey] = project }
        }
        var status = MetadataStatus.saved, warning: AppFailure?
        do { try store.commit(next) }
        catch { status = .failed; warning = NativeRuntimeErrors.normalize(error) }
        return UndoResult(undone: true, sourceCommitted: .yes, calendarWritten: true, metadataStatus: status,
                          warning: warning, savedEvent: restored)
    }
    private func descriptor(_ entry: NativeOperationRecord, kind: UndoKind) -> UndoDescriptor {
        UndoDescriptor(source: entry.context.id, token: entry.token,
                       expiresAt: Instant(date: entry.received.now.date.addingTimeInterval(8)),
                       continuousDeadlineMilliseconds: entry.received.continuousMilliseconds.addingReportingOverflow(8000).partialValue,
                       kind: kind)
    }
    private func saveEvent(_ input: EventSaveInput, entry: NativeOperationRecord) async throws -> EventSaveResult {
        guard store.canSave else { throw AppFailure(code: .storageProtected) }
        let original: EventRecord?, draft: EventDraft?, patch: MetadataPatch
        switch input {
        case .calendarCreate(let value, let metadata): original = nil; draft = value; patch = metadata
        case .calendarEdit(let identity, let version, let value, let metadata):
            guard let record = calendars.find(identity.id) else { throw AppFailure(code: .eventNotFound) }
            guard record.version == version else { throw AppFailure(code: .eventConflict) }
            original = record; draft = value; patch = metadata
        case .metadataOnly(let identity, let metadata):
            guard let record = calendars.find(identity.id) else { throw AppFailure(code: .eventNotFound) }
            original = record; draft = nil; patch = metadata
        }
        if let draft {
            try NativeBoardMutator.title(draft.title, field: .event(.title))
            guard draft.start.timeIntervalSinceReferenceDate.isFinite, draft.end.timeIntervalSinceReferenceDate.isFinite,
                  draft.end > draft.start, DateOnly(date: draft.start, timeZone: preferences.timeZone) != nil,
                  DateOnly(date: draft.end, timeZone: preferences.timeZone) != nil else { throw AppFailure(code: .invalidDate) }
            guard draft.location.count <= 4096, draft.notes.utf8.count <= 1024 * 1024 else { throw AppFailure(code: .validationFailed) }
            if let original {
                guard original.item.writable else { throw AppFailure(code: .calendarReadOnly) }
                guard !(original.item.recurring || original.detached) || draft.calendarID == original.item.calendarID else {
                    throw AppFailure(code: .recurringCalendarChange)
                }
            }
            guard let calendar = calendars.calendars.first(where: { $0.id == draft.calendarID }) else { throw AppFailure(code: .calendarNotFound) }
            guard calendar.writable else { throw AppFailure(code: .calendarReadOnly) }
        }
        if case .set(let project) = patch.projectID {
            guard project == nil || store.state.projects.contains(where: { $0.id == project }) else { throw AppFailure(code: .unknownProject) }
        }
        let before = store.state
        if let draft {
            entry.beforeEvent = original
            let saved = try await calendars.save(draft, original: original)
            entry.afterEvent = saved
            if let original { remapCreated(original: original, saved: saved) } else { createdIDs.insert(saved.id) }
            let token = UndoToken(value: UUID()); entry.token = token; tokens[token] = entry.context.id
            var status = MetadataStatus.saved, warning: AppFailure?
            do { try store.commit(NativeBoardMutator.metadata(patch, on: store.state, old: original, saved: saved)) }
            catch { status = .failed; warning = NativeRuntimeErrors.normalize(error) }
            entry.inverse = NativeBoardInverse(before: before, after: store.state)
            return EventSaveResult(savedEvent: saved, calendarWritten: true, metadataStatus: status, warning: warning,
                                   undo: descriptor(entry, kind: original == nil ? .create : .edit))
        }
        let fresh = try await calendars.current(original!, checkVersion: false)
        try store.commit(NativeBoardMutator.metadata(patch, on: store.state, old: original, saved: fresh))
        return EventSaveResult(savedEvent: fresh, calendarWritten: false, metadataStatus: .saved)
    }
    private func remapCreated(original: EventRecord, saved: EventRecord) {
        guard createdIDs.remove(original.id) != nil else { return }
        createdIDs.insert(saved.id)
        for entry in ledger.values where entry.beforeEvent == nil && entry.afterEvent?.id == original.id { entry.afterEvent = saved }
    }
    private func initializeServices() async {
        guard store.canSave, !initialized || !budgetInitialized else { return }
        if let initialization { await initialization.value; return }
        let task = Task { @MainActor in
            do {
                try await writeLane.run { [self] in
                    if !initialized { _ = try panels.focus.reconcile(.launch) }
                    if !budgetInitialized {
                        budgetInitialized = panels.external.initializeBudget(marker: store.state.networkBudgetInitialized) {
                            var next = self.store.state; next.networkBudgetInitialized = true
                            try self.store.commit(next, baseRevision: next.boardRevision)
                        }
                    }
                    try reconcileRollover(); reconcileNetworkClock()
                    panels.external.configure(ExternalConfiguration(board: store.state), refresh: false)
                    if budgetInitialized { _ = panels.external.refresh(.all) }
                }
                if !initialized {
                    _ = try await panels.notifications.refreshPermission()
                    _ = try await panels.notifications.reconcile(.launch)
                    initialized = true
                }
                publishServiceWarning(nil)
            } catch { publishServiceWarning(NativeRuntimeErrors.normalize(error)) }
        }
        initialization = task
        await task.value
        initialization = nil
    }
    private func reconcileNetworkClock() {
        let reading = clock.snapshot
        if networkMonitor.observe(now: reading.now, elapsedMilliseconds: reading.continuousMilliseconds) { networkJump = true }
        guard networkJump, panels.budget.available else { return }
        do { try panels.budget.quarantineForClockChange(now: reading.now); networkJump = false }
        catch { /* Existing budget remains fail-closed; normal recovery retries the durable quarantine. */ }
    }
    private func reconcileRollover() throws {
        let today = clock.snapshot.today
        guard lastRollover?.0 != today || lastRollover?.1 != store.state.boardRevision else { return }
        let next = try PanelDomain.rolloverSubscriptions(store.state, today: today)
        if next != store.state { try store.commit(next) }
        lastRollover = (today, store.state.boardRevision)
    }
    func reconcile(_ event: PanelClockEvent) async {
        guard !reconciling || event != .tick else { return }
        if event == .tick { reconciling = true }
        defer { if event == .tick { reconciling = false }; publishClock(); sweep() }
        guard store.canSave else { return }
        var completion: UUID?
        do {
            completion = try await writeLane.run { [self] in
                reconcileNetworkClock()
                let result = try panels.focus.reconcile(event)
                try reconcileRollover()
                let now = clock.snapshot.now
                if event != .tick || lastExternalTick.map({ now.date.timeIntervalSince($0.date) >= 60 }) ?? true {
                    panels.external.configure(ExternalConfiguration(board: store.state), refresh: false)
                    _ = panels.external.refresh(.all); lastExternalTick = now
                }
                return result.finishedSessionID
            }
            _ = try await panels.notifications.reconcile(event)
            await panels.notifications.observePermission(event)
            if let completion { await panels.notifications.submitFocusCompletion(completion) }
            publishServiceWarning(nil)
        } catch { publishServiceWarning(NativeRuntimeErrors.normalize(error)) }
        if panels.notifications.permission != current.notification.permission { publishSnapshot() }
    }
    private func publishClock() {
        let reading = clock.snapshot
        current.clock = reading; current.focus = panels.focus.projection()
        clock.didPublish(reading); emit(.clock(reading))
    }
    func processTimerTick() async {
        let now = preferences.now
        let second = Int64(floor(now.timeIntervalSince1970))
        guard second != lastSecond else { return }
        lastSecond = second
        let minute = second / 60
        if store.state.focusTimer.status == .running || lastMinute != minute {
            lastMinute = minute; await reconcile(.tick)
        } else { publishClock(); sweep() }
        await refreshCalendarIfDue()
    }
    func refreshCalendarIfDue(force: Bool = false) async {
        guard loaded, force || preferences.now.timeIntervalSince(lastCalendarRefresh) >= 120 else { return }
        lastCalendarRefresh = preferences.now
        let capture = await captureCalendarRefresh {
            await calendars.refresh(ranges: ranges, now: preferences.now, refreshSources: true)
        }
        adoptCalendarRefresh(capture)
        publishSnapshot()
    }
#if HANNUN_TESTING
    /// Manual awake elapsed time visits the same focus/09:00/midnight boundaries as normal
    /// scheduler ticks. A wall jump or sleep/wake uses clock controls + reconcile instead.
    func advanceClock(milliseconds: Int64) async throws {
        guard configuration.clock == .manual, (0...604800000).contains(milliseconds) else { throw AppFailure(code: .invalidRequest) }
        var remaining = milliseconds
        repeat {
            let start = preferences.now
            var next = start.addingTimeInterval(Double(remaining) / 1000)
            if let end = panels.focus.projection().endAt?.date, end > start, end < next { next = end }
            if let nine = panels.notifications.nextSubscriptionBoundary?.date, nine > start, nine < next { next = nine }
            if let midnight = preferences.calendar.date(byAdding: .day, value: 1, to: preferences.calendar.startOfDay(for: start)), midnight > start, midnight < next {
                next = midnight
            }
            let step = min(remaining, max(0, Int64((next.timeIntervalSince(start) * 1000).rounded())))
            try clock.advance(milliseconds: step)
            remaining -= step
            await reconcile(.tick)
        } while remaining > 0
    }
#endif
}
