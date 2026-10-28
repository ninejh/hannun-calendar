import Foundation
import CryptoKit

enum NativeOperation: Hashable, Sendable {
    case load, refresh, connect, saveBoard, saveEvent, requestUndo, undoCreate, undoEvent, invalidateUndo
    case open, diagnostics, readAudit, setLogin, uiReady, focus, notification, refreshExternal, listCities, openAttribution
    init(_ command: BoardCommand) {
        switch command {
        case .refresh: self = .refresh
        case .connect: self = .connect
        case .edit: self = .saveBoard
        case .saveEvent: self = .saveEvent
        case .undoCreate: self = .undoCreate
        case .undoEvent: self = .undoEvent
        case .invalidateUndo: self = .invalidateUndo
        case .open: self = .open
        case .diagnostics: self = .diagnostics
        case .readAudit: self = .readAudit
        case .setLogin: self = .setLogin
        case .uiReady: self = .uiReady
        case .focus: self = .focus
        case .notification: self = .notification
        case .refreshExternal: self = .refreshExternal
        case .listCities: self = .listCities
        case .openAttribution: self = .openAttribution
        }
    }
    var writes: Bool {
        switch self {
        case .saveBoard, .saveEvent, .requestUndo, .undoCreate, .undoEvent, .setLogin, .focus, .notification: true
        default: false
        }
    }
}

@MainActor final class NativeReceiptCell {
    private(set) var receipt: CommandReceipt?
    private var waiters: [CheckedContinuation<CommandReceipt, Never>] = []
    func wait() async -> CommandReceipt {
        if let receipt { return receipt }
        return await withCheckedContinuation { waiters.append($0) }
    }
    func resolve(_ receipt: CommandReceipt) {
        guard self.receipt == nil else { return }
        let compact = receipt.compact
        self.receipt = compact
        let waiting = waiters
        waiters.removeAll()
        for waiter in waiting { waiter.resume(returning: compact) }
    }
}

@MainActor final class NativeOperationRecord {
    let context: OperationContext
    let fingerprint: Data
    let operation: NativeOperation
    let received: ClockSnapshot
    let undoable: Bool
    var cell: NativeReceiptCell?
    var handle: OperationHandle?
    var retired = false
    var undoAccepted = false
    var invalidated = false
    var undoReceipt: CommandReceipt?
    var undoOperationID: UUID?
    var inverse: NativeBoardInverse?
    var beforeEvent: EventRecord?
    var afterEvent: EventRecord?
    var token: UndoToken?
    var externalSuspension: UUID?
    init(context: OperationContext, fingerprint: Data, operation: NativeOperation, received: ClockSnapshot,
         undoable: Bool, observationDelay: Int = 0) {
        self.context = context; self.fingerprint = fingerprint; self.operation = operation
        self.received = received; self.undoable = undoable
        let cell = NativeReceiptCell()
        self.cell = cell
        handle = OperationHandle(id: context.id, settled: Task {
            let receipt = await cell.wait()
            if observationDelay > 0 { try? await Task.sleep(for: .milliseconds(observationDelay)) }
            return receipt
        })
    }
    func expired(at clock: ClockSnapshot) -> Bool {
        let elapsed = clock.continuousMilliseconds.subtractingReportingOverflow(received.continuousMilliseconds)
        return elapsed.overflow || elapsed.partialValue < 0 || elapsed.partialValue >= 8000
    }
    var commitment: Commitment {
        if afterEvent != nil { return .yes }
        switch cell?.receipt {
        case .success: return .yes
        case .failure(let failure, _): return failure.committed
        case nil: return .unknown
        }
    }
    func releaseInverse() { inverse = nil; beforeEvent = nil; afterEvent = nil; token = nil }
    /// Full results remain replayable in the bounded cache. A retired ID keeps only
    /// execution/deduplication facts; its compensation result can contain a large event.
    func retire() {
        releaseInverse()
        cell = nil; handle = nil; undoReceipt = nil; undoOperationID = nil
        retired = true
    }
}

/// Streaming, tagged canonical encoding of the typed input, not a board/JSON copy.
/// Only the 32-byte digest survives completion; arbitrary notes never stay in the ledger.
@MainActor struct NativeCommandDigest {
    private var hash = SHA256()
    mutating func text(_ value: String) {
        var count = UInt64(value.utf8.count).bigEndian
        withUnsafeBytes(of: &count) { hash.update(data: Data($0)) }
        hash.update(data: Data(value.utf8))
    }
    mutating func scalar<T>(_ value: T) { text(String(describing: value)) }
    mutating func optional<T>(_ value: T?, _ body: (inout Self, T) -> Void) {
        scalar(value != nil)
        if let value { body(&self, value) }
    }
    mutating func field<T>(_ value: FieldChange<T>, _ body: (inout Self, T) -> Void) {
        switch value { case .unchanged: text("unchanged"); case .set(let value): text("set"); body(&self, value) }
    }
    mutating func encoded<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        // Existing domain DTOs used here are finite validated enum/string/date records.
        let data = try! encoder.encode(value)
        scalar(data.count); hash.update(data: data)
    }
    mutating func event(_ draft: EventDraft) {
        text(draft.title); scalar(draft.start.timeIntervalSinceReferenceDate); scalar(draft.end.timeIntervalSinceReferenceDate)
        scalar(draft.allDay); text(draft.calendarID); text(draft.location); text(draft.notes)
    }
    mutating func metadata(_ patch: MetadataPatch) {
        field(patch.projectID) { $0.optional($1) { $0.scalar($1) } }
        field(patch.pinned) { $0.scalar($1) }
    }
    mutating func settings(_ patch: SettingsPatch) {
        field(patch.desktopMode) { $0.scalar($1) }; field(patch.fontScale) { $0.scalar($1) }
        field(patch.opacity) { $0.scalar($1) }; field(patch.importantOnly) { $0.scalar($1) }
        field(patch.showCompletedProjects) { $0.scalar($1) }; field(patch.appearance) { $0.text($1.rawValue) }
        field(patch.compact) { $0.scalar($1) }; field(patch.language) { $0.text($1.rawValue) }
        field(patch.weekStart) { $0.text($1.rawValue) }; field(patch.networkEnabled) { $0.scalar($1) }
        field(patch.ratesEnabled) { $0.scalar($1) }; field(patch.weather) { $0.encoded($1) }
        field(patch.todosCompletedCollapsed) { $0.scalar($1) }; field(patch.focus) { $0.encoded($1) }
    }
    mutating func project(_ edit: ProjectEdit) {
        switch edit {
        case .create(let input):
            text("create"); scalar(input.id); text(input.title); text(input.focus); text(input.nextStep)
            text(input.status.rawValue); optional(input.targetDay) { $0.scalar($1) }; text(input.colorHex); scalar(input.progress)
        case .update(let id, let patch):
            text("update"); scalar(id); field(patch.title) { $0.text($1) }; field(patch.focus) { $0.text($1) }
            field(patch.nextStep) { $0.text($1) }; field(patch.status) { $0.text($1.rawValue) }
            field(patch.targetDay) { $0.optional($1) { $0.scalar($1) } }; field(patch.colorHex) { $0.text($1) }
            field(patch.progress) { $0.scalar($1) }
        case .delete(let id): text("delete"); scalar(id)
        }
    }
    mutating func countdown(_ edit: CountdownEdit) {
        switch edit {
        case .create(let input): text("create"); scalar(input.id); text(input.title); scalar(input.day); text(input.colorHex)
        case .update(let id, let patch):
            text("update"); scalar(id); field(patch.title) { $0.text($1) }; field(patch.day) { $0.scalar($1) }
            field(patch.colorHex) { $0.text($1) }
        case .delete(let id): text("delete"); scalar(id)
        }
    }
    mutating func panel(_ intent: PanelIntent) {
        switch intent {
        case .selectSlot(let slot, let panel): text("slot"); text(slot.rawValue); text(panel.rawValue)
        case .setSlotVisible(let slot, let visible): text("slotVisible"); text(slot.rawValue); scalar(visible)
        case .setPanelVisible(let panel, let visible): text("panelVisible"); text(panel.rawValue); scalar(visible)
        case .revealAgenda: text("agenda")
        case .resetLayout: text("reset")
        case .createSubscription(let input):
            text("subscriptionCreate"); scalar(input.id); text(input.name); scalar(input.nextDate); text(input.cycle.rawValue)
            text(input.amount); text(input.currency); text(input.paymentMemo)
        case .updateSubscription(let id, let patch):
            text("subscriptionUpdate"); scalar(id); optional(patch.name) { $0.text($1) }; optional(patch.nextDate) { $0.scalar($1) }
            optional(patch.cycle) { $0.text($1.rawValue) }; optional(patch.amount) { $0.text($1) }
            optional(patch.currency) { $0.text($1) }; optional(patch.paymentMemo) { $0.text($1) }
        case .deleteSubscription(let id): text("subscriptionDelete"); scalar(id)
        case .createTodo(let id, let title): text("todoCreate"); scalar(id); text(title)
        case .updateTodo(let id, let patch): text("todoUpdate"); scalar(id); optional(patch.title) { $0.text($1) }; optional(patch.completed) { $0.scalar($1) }
        case .deleteTodo(let id): text("todoDelete"); scalar(id)
        case .createHabit(let id, let title): text("habitCreate"); scalar(id); text(title)
        case .updateHabit(let id, let title): text("habitUpdate"); scalar(id); text(title)
        case .setHabitToday(let id, let checked, let day): text("habitToday"); scalar(id); scalar(checked); scalar(day)
        case .deleteHabit(let id): text("habitDelete"); scalar(id)
        case .addCity(let id): text("cityAdd"); text(id)
        case .deleteCity(let id): text("cityDelete"); text(id)
        }
    }
    mutating func atomic(_ edit: AtomicBoardEdit) {
        switch edit {
        case .notes(let value): text("notes"); text(value)
        case .project(let value): text("project"); project(value)
        case .countdown(let value): text("countdown"); countdown(value)
        case .pin(let id, let value): text("pin"); text(id.id); scalar(value)
        case .eventProject(let id, let value): text("eventProject"); text(id.id); optional(value) { $0.scalar($1) }
        case .calendarVisibility(let id, let hidden): text("calendarVisibility"); text(id); scalar(hidden)
        case .settings(let patch): text("settings"); settings(patch)
        case .layout(let value):
            text("layout")
            switch value {
            case .select(let slot, let panel): text("select"); text(slot.rawValue); text(panel.rawValue)
            case .setSplit(let split, let ratio): text("split"); text(split.rawValue); optional(ratio) { $0.scalar($1) }
            case .setStep(let split, let step, let viewport):
                text("step"); text(split.rawValue); scalar(step.rawValue); scalar(viewport.width); scalar(viewport.height)
            case .setHidden(let slot, let hidden): text("hidden"); text(slot.rawValue); scalar(hidden)
            case .reset: text("reset")
            }
        case .panel(let value): text("panel"); panel(value)
        }
    }
    static func command(_ command: BoardCommand, revision: Int) -> Data {
        var writer = Self(); writer.scalar(revision)
        switch command {
        case .edit(let edit, let undoable):
            writer.text("edit"); writer.scalar(undoable)
            let atoms = NativeBoardMutator.atoms(edit)
            // Preserve the semantic transaction boundary as well as its ordered atoms.
            if case .transaction = edit { writer.text("transaction") } else { writer.text("single") }
            writer.scalar(atoms.count); for atom in atoms { writer.atomic(atom) }
        case .saveEvent(let input):
            writer.text("saveEvent")
            switch input {
            case .calendarCreate(let draft, let patch): writer.text("create"); writer.event(draft); writer.metadata(patch)
            case .calendarEdit(let id, let version, let draft, let patch):
                writer.text("edit"); writer.text(id.id); writer.text(version); writer.event(draft); writer.metadata(patch)
            case .metadataOnly(let id, let patch): writer.text("metadata"); writer.text(id.id); writer.metadata(patch)
            }
        case .refresh(let range, let sources):
            writer.text("refresh"); writer.scalar(range.month); writer.scalar(range.visibleStart); writer.scalar(range.endExclusive)
            writer.optional(range.selectedDay) { $0.scalar($1) }; writer.text(range.mode.rawValue); writer.scalar(sources)
        case .connect: writer.text("connect")
        case .undoCreate(let token): writer.text("undoCreate"); writer.scalar(token.value)
        case .undoEvent(let token): writer.text("undoEvent"); writer.scalar(token.value)
        case .invalidateUndo(let token): writer.text("invalidate"); writer.scalar(token.value)
        case .open(let target): writer.text("open"); writer.text(target.rawValue)
        case .diagnostics: writer.text("diagnostics")
        case .readAudit: writer.text("audit")
        case .setLogin(let enabled): writer.text("login"); writer.scalar(enabled)
        case .uiReady: writer.text("ready")
        case .focus(let value):
            writer.text("focus")
            switch value {
            case .start: writer.text("start")
            case .pause: writer.text("pause")
            case .resume: writer.text("resume")
            case .stop: writer.text("stop")
            case .selectProject(let id): writer.text("project"); writer.optional(id) { $0.scalar($1) }
            case .setMode(let mode): writer.text("mode"); writer.text(mode.rawValue)
            }
        case .notification(let target, let enabled):
            writer.text("notification"); writer.scalar(enabled)
            switch target { case .focus: writer.text("focus"); case .subscription(let id): writer.text("subscription"); writer.scalar(id) }
        case .refreshExternal(let kind):
            writer.text("external"); switch kind { case .weather: writer.text("weather"); case .rates: writer.text("rates"); case .all: writer.text("all") }
        case .listCities(let query): writer.text("cities"); writer.text(query)
        case .openAttribution(let kind): writer.text("attribution"); writer.text(kind.rawValue)
        }
        return Data(writer.hash.finalize())
    }
    static func undo(_ source: UUID, revision: Int) -> Data {
        var writer = Self(); writer.text("requestUndo"); writer.scalar(source); writer.scalar(revision)
        return Data(writer.hash.finalize())
    }
}

enum NativeRuntimeErrors {
    static func normalize(_ error: Error) -> AppFailure {
        if let value = error as? AppFailure { return value }
        if let value = error as? NativeFailure {
            return AppFailure(code: AppFailureCode(rawValue: value.code) ?? .invalidRequest,
                              messageKey: value.messageKey ?? "error." + value.code.lowercased(), retryable: value.retryable,
                              committed: value.committed == .yes ? .yes : value.committed == .unknown ? .unknown : .no)
        }
        if let value = error as? BoardStorageError {
            return AppFailure(code: value.code == .unsupportedVersion ? .storageProtected : AppFailureCode(rawValue: value.code.rawValue) ?? .validationFailed,
                              committed: value.committed ? .yes : .no)
        }
        if let value = error as? PanelDomainError {
            return AppFailure(code: AppFailureCode(rawValue: value.code.rawValue) ?? .validationFailed)
        }
        if let value = error as? FocusServiceError {
            return AppFailure(code: AppFailureCode(rawValue: value.code.rawValue) ?? .focusStateConflict, committed: value.committed ? .yes : .no)
        }
        if let value = error as? NotificationServiceError { return AppFailure(code: AppFailureCode(rawValue: value.code.rawValue) ?? .notificationUnavailable) }
        return AppFailure(code: .invalidRequest)
    }
}

#if HANNUN_TESTING
enum NativeDelayPhase: Hashable { case execution, observation }
@MainActor final class NativeRuntimeTestControls {
    private var delays: [NativeOperation: [NativeDelayPhase: Int]] = [:]
    private var failures: [NativeOperation: AppFailure] = [:]
    var nextStorageFailure: AppFailure?
    func delayNext(_ method: NativeOperation, phase: NativeDelayPhase, milliseconds: Int) throws {
        guard (0...60000).contains(milliseconds) else { throw AppFailure(code: .invalidRequest) }
        delays[method, default: [:]][phase] = milliseconds
    }
    func takeDelay(_ method: NativeOperation, _ phase: NativeDelayPhase) -> Int { delays[method]?.removeValue(forKey: phase) ?? 0 }
    func failNext(_ method: NativeOperation, _ failure: AppFailure) { failures[method] = failure }
    func takeFailure(_ method: NativeOperation) -> AppFailure? { failures.removeValue(forKey: method) }
}
#endif
