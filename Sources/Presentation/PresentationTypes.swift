import Foundation

struct TextDraft: Equatable, Sendable {
    var text: String
    var selection: NSRange = NSRange(location: 0, length: 0)
    var markedRange: NSRange? = nil
    var scrollOrigin: CGPoint = .zero
    var isComposing: Bool { markedRange.map { $0.location != NSNotFound } ?? false }
}
enum DraftKey: Hashable, Sendable {
    case notes, search, project(UUID), countdown(UUID), event(String), subscription(UUID), todo(UUID), habit(UUID)
}
struct EventEditorDraft: Equatable, Sendable {
    var event: EventDraft
    var metadata: MetadataPatch = MetadataPatch()
    var expectedVersion: String? = nil
}
enum DraftValue: Equatable, Sendable {
    case text(TextDraft), event(EventDraft), eventEditor(EventEditorDraft), project(ProjectInput), countdown(CountdownInput), subscription(SubscriptionInput)
    var eventEditorValue: EventEditorDraft? { if case .eventEditor(let value) = self { value } else { nil } }
    var textValue: TextDraft? { if case .text(let value) = self { value } else { nil } }
}
enum AffectedID: Hashable, Sendable {
    case notes, settings, project(UUID), countdown(UUID), subscription(UUID), todo(UUID), habit(UUID), city(String), slot(SlotID), event(String), calendar(String)
}
enum PendingPhase: String, Sendable { case queued, running, unknown, settled }
struct PendingOperation: Sendable {
    var id: UUID
    var kind: String
    var phase: PendingPhase
    var affected: [AffectedID]
}
enum PresentationDomain: Hashable, Sendable { case board, calendar, clock, environment, external, view, drafts, pending, activity, toast, error }
struct PresentationChange: Sendable {
    var domains: Set<PresentationDomain>
    var affected: Set<AffectedID> = []
}
enum SlotVariant: String, Sendable { case wide, tall }
struct LayoutStepPreview: Equatable, Sendable {
    var split: LayoutSplit
    var viewport: LayoutViewport
    var startingLayout: BoardLayout
    var step: PanelSizeStep
    var layout: BoardLayout
}
struct PresentationViewState: Sendable {
    var stepPreview: LayoutStepPreview? = nil
    var month: DateOnly
    var selectedDay: DateOnly
    var followingToday = true
    var mode: DisplayMode = .month
    var query = ""
    var slotVariants: [SlotID: SlotVariant] = [.wide: .wide, .railTop: .tall, .railMiddle: .tall, .railBottom: .tall]
    var overlay: OverlayRoute? = nil
}
struct PresentationAnchor: Equatable, Sendable {
    var id: String
    var rect: CGRect
}
enum OverlayRoute: Equatable, Sendable {
    case settings, search, newEvent, event(String, PresentationAnchor?), monthPicker, calendars
    case agenda(DateOnly, PresentationAnchor?)
}
struct PresentationActivity: Sendable { var loading = false; var refreshing = false; var saving = false }
struct PresentationToast: Sendable {
    var source: UUID
    var messageKey: String
    var values: [String: String] = [:]
    var continuousDeadlineMilliseconds: Int64
    var undoable: Bool
}
struct PresentationState: Sendable {
    /// Authoritative snapshot with the ordered optimistic projection applied. Never save this whole value.
    var snapshot: BoardSnapshot
    var view: PresentationViewState
    var drafts: [DraftKey: DraftValue] = [:]
    var pending: [PendingOperation] = []
    var activity = PresentationActivity()
    var toast: PresentationToast? = nil
    var lastError: AppFailure? = nil
}
struct PresentationFeedback: Sendable {
    var messageKey: String
    var values: [String: String] = [:]
}
enum UserIntent: Sendable {
    case command(BoardCommand, feedback: PresentationFeedback? = nil)
    case edit(BoardEdit, undoable: Bool, feedback: PresentationFeedback? = nil)
    case beginStepPreview(LayoutSplit, viewport: LayoutViewport)
    case previewStep(PanelSizeStep), commitStepPreview, cancelStepPreview
    case undo, retry(UUID), reconcile(UUID)
    case selectDay(DateOnly), movePeriod(Int), setMode(DisplayMode), searchQuery(String), overlayOpen(OverlayRoute?), followToday
    case revealAgenda(DateOnly, PresentationAnchor?)
}
@MainActor protocol BoardPresentation: AnyObject {
    var state: PresentationState { get }
    @discardableResult func send(_ intent: UserIntent) -> OperationHandle?
    func subscribe(_ receive: @escaping @MainActor (PresentationChange) -> Void) -> ObservationToken
    func setDraft(_ key: DraftKey, value: DraftValue)
    func clearDraft(_ key: DraftKey)
    func flushNotes() async -> CommandReceipt
}
@MainActor protocol PresentationScheduler: AnyObject {
    func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) -> ObservationToken
}
@MainActor final class RunLoopPresentationScheduler: PresentationScheduler {
    func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) -> ObservationToken {
        let timer = Timer(timeInterval: seconds, repeats: false) { _ in MainActor.assumeIsolated { action() } }
        RunLoop.main.add(timer, forMode: .common)
        return ObservationToken { timer.invalidate() }
    }
}
