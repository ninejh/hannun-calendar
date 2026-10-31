import Foundation

enum FieldChange<Value: Sendable>: Sendable {
    case unchanged
    case set(Value)
}
extension FieldChange: Equatable where Value: Equatable {}

struct ProjectInput: Sendable, Equatable {
    var id: UUID
    var title: String
    var focus: String = ""
    var nextStep: String = ""
    var status: ProjectStatus = .active
    var targetDay: DateOnly? = nil
    var colorHex: String = "D46E48"
    var progress: Int = 0
}
struct ProjectPatch: Sendable, Equatable {
    var title: FieldChange<String> = .unchanged
    var focus: FieldChange<String> = .unchanged
    var nextStep: FieldChange<String> = .unchanged
    var status: FieldChange<ProjectStatus> = .unchanged
    var targetDay: FieldChange<DateOnly?> = .unchanged
    var colorHex: FieldChange<String> = .unchanged
    var progress: FieldChange<Int> = .unchanged
}
enum ProjectEdit: Sendable, Equatable {
    case create(ProjectInput), update(id: UUID, patch: ProjectPatch), delete(id: UUID)
}
struct CountdownInput: Sendable, Equatable {
    var id: UUID
    var title: String
    var day: DateOnly
    var colorHex: String = "D46E48"
}
struct CountdownPatch: Sendable, Equatable {
    var title: FieldChange<String> = .unchanged
    var day: FieldChange<DateOnly> = .unchanged
    var colorHex: FieldChange<String> = .unchanged
}
enum CountdownEdit: Sendable, Equatable {
    case create(CountdownInput), update(id: UUID, patch: CountdownPatch), delete(id: UUID)
}
enum LayoutEdit: Sendable, Equatable {
    case select(slot: SlotID, panel: PanelID), setSplit(LayoutSplit, Double?)
    case setStep(LayoutSplit, PanelSizeStep, viewport: LayoutViewport)
    case place(item: GridItemID, rect: GridRect), dismissMigrationNotice
    case setHidden(slot: SlotID, Bool), reset
}
struct SettingsPatch: Sendable, Equatable {
    var desktopMode: FieldChange<Bool> = .unchanged
    var fontScale: FieldChange<Double> = .unchanged
    var opacity: FieldChange<Double> = .unchanged
    var importantOnly: FieldChange<Bool> = .unchanged
    var showCompletedProjects: FieldChange<Bool> = .unchanged
    var appearance: FieldChange<AppAppearance> = .unchanged
    var compact: FieldChange<Bool> = .unchanged
    var language: FieldChange<BoardLanguage> = .unchanged
    var weekStart: FieldChange<WeekStart> = .unchanged
    var networkEnabled: FieldChange<Bool> = .unchanged
    var ratesEnabled: FieldChange<Bool> = .unchanged
    var weather: FieldChange<WeatherSettings> = .unchanged
    var todosCompletedCollapsed: FieldChange<Bool> = .unchanged
    var focus: FieldChange<FocusSettings> = .unchanged
}
struct EventIdentity: Sendable, Equatable, Hashable {
    /// The existing EventRecord.id, including occurrence identity; never a caller-derived version.
    var id: String
}
struct MetadataPatch: Sendable, Equatable {
    var projectID: FieldChange<UUID?> = .unchanged
    var pinned: FieldChange<Bool> = .unchanged
}
enum EventSaveInput: Sendable, Equatable {
    case calendarCreate(EventDraft, MetadataPatch)
    case calendarEdit(EventIdentity, expectedVersion: String, EventDraft, MetadataPatch)
    case metadataOnly(EventIdentity, MetadataPatch)
}

/// Nonrecursive atomic alternatives prevent nested transactions and whole-array replacement.
enum AtomicBoardEdit: Sendable, Equatable {
    case notes(String), project(ProjectEdit), countdown(CountdownEdit)
    case pin(EventIdentity, Bool), eventProject(EventIdentity, UUID?)
    case calendarVisibility(id: String, isHidden: Bool)
    case settings(SettingsPatch), layout(LayoutEdit), panel(PanelIntent)
}
enum BoardEdit: Sendable, Equatable {
    case notes(String), project(ProjectEdit), countdown(CountdownEdit)
    case pin(EventIdentity, Bool), eventProject(EventIdentity, UUID?)
    case calendarVisibility(id: String, isHidden: Bool)
    case settings(SettingsPatch), layout(LayoutEdit), panel(PanelIntent)
    case transaction([AtomicBoardEdit])
}
enum BoardCommand: Sendable, Equatable {
    case refresh(DisplayRange, refreshSources: Bool)
    case connect
    case edit(BoardEdit, undoable: Bool)
    case saveEvent(EventSaveInput)
    case deleteEvent(EventIdentity, expectedVersion: String)
    case undoCreate(UndoToken), undoEvent(UndoToken), invalidateUndo(UndoToken)
    case open(OSRequestTarget), diagnostics, readAudit, setLogin(Bool), uiReady
    case focus(FocusCommand), notification(NotificationPreferenceTarget, enabled: Bool)
    case refreshExternal(ExternalKindSelection), listCities(query: String), openAttribution(AttributionKind)
}

// Equality is value-based, including hidden domain fields. It gives the ledger an exact
// same-ID/same-command comparison without retaining a second encoded payload or using hashes.
extension EventDraft: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.title == rhs.title && lhs.start == rhs.start && lhs.end == rhs.end && lhs.allDay == rhs.allDay &&
        lhs.calendarID == rhs.calendarID && lhs.location == rhs.location && lhs.notes == rhs.notes
    }
}
extension SubscriptionInput: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.nextDate == rhs.nextDate && lhs.cycle == rhs.cycle &&
        lhs.amount == rhs.amount && lhs.currency == rhs.currency && lhs.paymentMemo == rhs.paymentMemo
    }
}
extension SubscriptionPatch: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.name == rhs.name && lhs.nextDate == rhs.nextDate && lhs.cycle == rhs.cycle &&
        lhs.amount == rhs.amount && lhs.currency == rhs.currency && lhs.paymentMemo == rhs.paymentMemo
    }
}
extension TodoPatch: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.title == rhs.title && lhs.completed == rhs.completed }
}
extension FocusCommand: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.start, .start), (.pause, .pause), (.resume, .resume), (.stop, .stop): true
        case (.selectProject(let a), .selectProject(let b)): a == b
        case (.setMode(let a), .setMode(let b)): a == b
        default: false
        }
    }
}
extension ExternalRefreshKind: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.weather, .weather), (.rates, .rates), (.all, .all): true
        default: false
        }
    }
}
extension PanelIntent: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.selectSlot(let a, let x), .selectSlot(let b, let y)): a == b && x == y
        case (.setSlotVisible(let a, let x), .setSlotVisible(let b, let y)): a == b && x == y
        case (.setPanelVisible(let a, let x), .setPanelVisible(let b, let y)): a == b && x == y
        case (.revealAgenda, .revealAgenda), (.resetLayout, .resetLayout): true
        case (.createSubscription(let a), .createSubscription(let b)): a == b
        case (.updateSubscription(let a, let x), .updateSubscription(let b, let y)): a == b && x == y
        case (.deleteSubscription(let a), .deleteSubscription(let b)),
             (.deleteTodo(let a), .deleteTodo(let b)), (.deleteHabit(let a), .deleteHabit(let b)): a == b
        case (.createTodo(let a, let x), .createTodo(let b, let y)),
             (.createHabit(let a, let x), .createHabit(let b, let y)),
             (.updateHabit(let a, let x), .updateHabit(let b, let y)): a == b && x == y
        case (.updateTodo(let a, let x), .updateTodo(let b, let y)): a == b && x == y
        case (.setHabitToday(let a, let x, let d), .setHabitToday(let b, let y, let e)): a == b && x == y && d == e
        case (.addCity(let a), .addCity(let b)), (.deleteCity(let a), .deleteCity(let b)): a == b
        default: false
        }
    }
}
