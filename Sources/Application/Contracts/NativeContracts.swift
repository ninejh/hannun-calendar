import Foundation

// Frozen T-034 surface, API_CONTRACT §7. Changes require Commander review.
// All values stay in-process. Domain DTOs are shared, never JSON round-tripped.
struct OperationContext: Sendable, Equatable {
    let id: UUID
    let sessionID: UUID
    let baseRevision: Int
}

struct OperationHandle: Sendable {
    let id: UUID
    let settled: Task<CommandReceipt, Never>
}

enum Commitment: Sendable, Equatable { case no, yes, unknown }

enum AppFailureCode: String, Sendable, CaseIterable {
    case invalidRequest = "INVALID_REQUEST", unsupportedAPI = "UNSUPPORTED_API"
    case staleSession = "STALE_SESSION", validationFailed = "VALIDATION_FAILED"
    case invalidDate = "INVALID_DATE", unknownProject = "UNKNOWN_PROJECT"
    case boardConflict = "BOARD_CONFLICT", eventNotFound = "EVENT_NOT_FOUND"
    case eventConflict = "EVENT_CONFLICT", calendarPermission = "CALENDAR_PERMISSION"
    case calendarNotFound = "CALENDAR_NOT_FOUND", calendarReadOnly = "CALENDAR_READ_ONLY"
    case recurringCalendarChange = "RECURRING_CALENDAR_CHANGE"
    case calendarUnavailable = "CALENDAR_UNAVAILABLE", calendarWriteFailed = "CALENDAR_WRITE_FAILED"
    case storageProtected = "STORAGE_PROTECTED", storageWriteFailed = "STORAGE_WRITE_FAILED"
    case unsupportedSchema = "UNSUPPORTED_SCHEMA", undoExpired = "UNDO_EXPIRED"
    case undoUnavailable = "UNDO_UNAVAILABLE", loginApprovalRequired = "LOGIN_APPROVAL_REQUIRED"
    case loginRegistrationFailed = "LOGIN_REGISTRATION_FAILED", duplicateRequest = "DUPLICATE_REQUEST"
    case requestRetired = "REQUEST_RETIRED", busyRetry = "BUSY_RETRY", osOpenFailed = "OS_OPEN_FAILED"
    case commitOutcomeUnknown = "COMMIT_OUTCOME_UNKNOWN", dayChanged = "DAY_CHANGED"
    case cityLimit = "CITY_LIMIT", cityNotFound = "CITY_NOT_FOUND", panelNotAssigned = "PANEL_NOT_ASSIGNED"
    case invalidResponse = "INVALID_RESPONSE", focusStateConflict = "FOCUS_STATE_CONFLICT"
    case notificationUnavailable = "NOTIFICATION_UNAVAILABLE"
    case notificationSubmissionFailed = "NOTIFICATION_SUBMISSION_FAILED"
    case notificationPermissionRequired = "NOTIFICATION_PERMISSION_REQUIRED"
}

enum ProjectField: String, Sendable { case title, focus, nextStep, status, targetDay, colorHex, progress }
enum CountdownField: String, Sendable { case title, day, colorHex }
enum EventField: String, Sendable { case title, start, end, allDay, calendarID, location, notes, projectID, pinned, version }
enum SettingsField: String, Sendable {
    case desktopMode, fontScale, opacity, importantOnly, showCompletedProjects, appearance, compact
    case language, weekStart, networkEnabled, ratesEnabled, weather, todosCompletedCollapsed, focus
}
enum PanelField: String, Sendable {
    case name, title, nextDate, cycle, amount, currency, paymentMemo, notify, completed, marks, cityID, projectID, mode
}
enum FieldPath: Sendable, Equatable {
    case operation, range, configuration, notes
    case project(UUID?, ProjectField), countdown(UUID?, CountdownField)
    case event(EventField), settings(SettingsField), layout(LayoutSplit)
    case panel(PanelID, id: UUID?, field: PanelField)
}

/// Values must be safe localization substitutions: no body text, paths, OS/provider errors or identifiers.
struct AppFailure: Error, Sendable, Equatable {
    let code: AppFailureCode
    var field: FieldPath? = nil
    var messageKey: String = "error.generic"
    var values: [String: String] = [:]
    var retryable: Bool = false
    var committed: Commitment = .no
}

enum CommandReceipt: Sendable {
    case success(CommandResult, snapshot: BoardSnapshot?)
    case failure(AppFailure, snapshot: BoardSnapshot?)

    /// Mutation handles and the ledger retain only small results, including the original commitment.
    /// Deliver authoritative state to current/observers before settling a compact receipt.
    var compact: CommandReceipt {
        switch self {
        case .success(let result, _): .success(result, snapshot: nil)
        case .failure(let failure, _): .failure(failure, snapshot: nil)
        }
    }
    var snapshot: BoardSnapshot? {
        switch self {
        case .success(_, let snapshot), .failure(_, let snapshot): snapshot
        }
    }
}

enum OperationStatus: Sendable {
    case notFound, pending, completed(CommandReceipt), retired
}

/// Explicit MainActor cancellation is required on teardown; deinit does not cancel actor resources.
@MainActor final class ObservationToken {
    private var cancellation: (@MainActor () -> Void)?
    init(_ cancellation: @escaping @MainActor () -> Void) { self.cancellation = cancellation }
    func cancel() {
        let action = cancellation
        cancellation = nil
        action?()
    }
}

@MainActor protocol BoardApplication: AnyObject {
    var sessionID: UUID { get }
    var current: BoardSnapshot { get }
    func load(_ range: DisplayRange?) async -> CommandReceipt
    /// Admit to the ledger synchronously before returning; cancellation of settled is not cancellation of work.
    func submit(_ command: BoardCommand, context: OperationContext) -> OperationHandle
    func result(of id: UUID, sessionID: UUID) -> Result<OperationStatus, AppFailure>
    /// Admit control intent immediately; only the eventual durable compensation joins the write FIFO.
    func requestUndo(source: UUID, context: OperationContext) -> OperationHandle
    /// Immediately delivers current, then ordered changes. Owners explicitly cancel on MainActor.
    func observe(_ receive: @escaping @MainActor (BoardUpdate) -> Void) -> ObservationToken
    func flush() async -> CommandReceipt
}

enum DisplayMode: String, Sendable { case month, week }
struct DisplayRange: Sendable, Equatable {
    var month: DateOnly
    var visibleStart: DateOnly
    var endExclusive: DateOnly
    var selectedDay: DateOnly? = nil
    var mode: DisplayMode = .month
}

struct ClockSnapshot: Sendable, Equatable {
    var now: Instant
    var today: DateOnly
    var timeZone: String
    var continuousMilliseconds: Int64
    var awakeMilliseconds: Int64
    var dayChanged: Bool = false
}
enum ResolvedAppearance: String, Sendable { case light, dark }
struct EnvironmentSnapshot: Sendable, Equatable {
    var resolvedAppearance: ResolvedAppearance
    var resolvedWeekStart: Int
    var reduceMotion: Bool
    var timeZone: String
    var localeIdentifier: String
}
enum StorageStatus: String, Sendable { case ready, demoMemory, protected, unavailable }
enum LoginStatus: String, Sendable { case enabled, notRegistered, requiresApproval, notFound }
enum CalendarAuthorization: String, Sendable { case notDetermined, denied, restricted, authorized, unavailable }

struct ExternalProjection: Sendable {
    var weather: ExternalWeatherProjection
    var rates: ExternalRatesProjection
}
struct NotificationProjection: Sendable {
    var permission: NotificationPermission
    var focusDesired: Bool
    var focusEffective: Bool
    var subscriptions: [SubscriptionNotificationState]
}
struct SubscriptionNotificationState: Sendable, Equatable {
    var id: UUID
    var desired: Bool
    var effective: Bool
}
struct BoardSnapshot: Sendable {
    var sessionID: UUID
    var sequence: Int
    var board: BoardState
    var calendar: CalendarSnapshot
    var calendarAuthorization: CalendarAuthorization
    var clock: ClockSnapshot
    var environment: EnvironmentSnapshot
    var storage: StorageStatus
    var storageWarning: AppFailure? = nil
    var login: LoginStatus
    var focus: FocusProjection
    var notification: NotificationProjection
    var external: ExternalProjection
    var subscriptionSummary: SubscriptionSummary
    var panelMetadata: PanelMetadata
    var calendarRefreshedAt: Date? = nil
    var boardRevision: Int { board.boardRevision }
}
enum MenuAction: Sendable, Equatable { case openSettings(actionID: UUID) }
enum BoardUpdate: Sendable {
    case snapshot(BoardSnapshot), clock(ClockSnapshot), environment(EnvironmentSnapshot)
    case external(ExternalProjection), action(MenuAction)
}

struct DeletedRefs: Sendable, Equatable {
    var projects: [UUID] = []
    var countdowns: [UUID] = []
    var panels: PanelDeletedRefs = PanelDeletedRefs()
}
struct BoardSaveResult: Sendable {
    var revision: Int
    var deletedRefs: DeletedRefs = DeletedRefs()
    var undo: UndoDescriptor? = nil
    var revealedSlotID: SlotID? = nil
}
struct UndoToken: Sendable, Hashable { let value: UUID }
enum UndoKind: String, Sendable { case board, create, edit }
struct UndoDescriptor: Sendable {
    var source: UUID
    var token: UndoToken?
    var expiresAt: Instant
    var continuousDeadlineMilliseconds: Int64
    var kind: UndoKind
}
enum MetadataStatus: String, Sendable { case saved, failed }
struct EventSaveResult: Sendable {
    var savedEvent: EventRecord
    var calendarWritten: Bool
    var metadataStatus: MetadataStatus
    var warning: AppFailure? = nil
    var undo: UndoDescriptor? = nil
}
struct UndoResult: Sendable {
    var undone: Bool
    var sourceCommitted: Commitment
    var calendarWritten: Bool
    var metadataStatus: MetadataStatus
    var warning: AppFailure? = nil
    var savedEvent: EventRecord? = nil
}
struct FocusCommandResult: Sendable {
    var focus: FocusProjection
    var boardRevision: Int
}
typealias ExternalRefreshResult = ExternalRefreshReceipt
typealias ExternalKindSelection = ExternalRefreshKind
typealias City = CatalogCity
enum OSRequestTarget: String, Sendable { case accounts, privacy, login }
enum AttributionKind: String, Sendable { case weather, rates, weatherLicense, ratesLicense }
enum CalendarAdapterKind: String, Sendable { case fake, eventkit }
struct Diagnostics: Sendable {
    var demo: Bool
    var authorized: Bool
    var nonactivating: Bool
    var stationary: Bool
    var desktopLevel: Bool
    var appearance: ResolvedAppearance
    var loginItemStatus: LoginStatus
    var storageStatus: StorageStatus
    var calendarAdapter: CalendarAdapterKind
    var accountAccessCount: Int
    var externalNavigationBlockedCount: Int
}
struct ReadAudit: Sendable {
    var demo: Bool
    var calendars: Int
    var loadedEvents: Int
    var freshEvents: Int
    var missingFromLoadedSnapshot: Int
    var onlyInLoadedSnapshot: Int
    var readOnly: Bool { true }
}
enum CommandResult: Sendable {
    case loaded, refreshed, connected
    case boardSaved(BoardSaveResult), eventSaved(EventSaveResult), undone(UndoResult), undoInvalidated
    case opened(OSRequestTarget), diagnostics(Diagnostics), audit(ReadAudit), login(LoginStatus), ready
    case focus(FocusCommandResult), notification(NotificationPreferenceResult)
    case externalAccepted(ExternalRefreshResult), cities([City]), attributionOpened
}
