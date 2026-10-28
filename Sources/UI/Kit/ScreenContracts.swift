import AppKit

/// Value anchors use the board's top-left point coordinates and never retain a source view.
enum AnchorTarget: Hashable, Sendable {
    case event(String), day(DateOnly), slot(SlotID), control(String)
}
struct StableAnchor: Equatable, Sendable {
    var target: AnchorTarget
    var boardRect: CGRect
    var returnFocusID: FocusID? = nil
}
struct AddRequest: Equatable, Sendable {
    enum Kind: String, Sendable { case event, countdown, project }
    var kind: Kind
    var day: DateOnly? = nil
    var projectID: UUID? = nil
    var anchor: StableAnchor? = nil
}
enum PanelReveal: Equatable, Sendable {
    case day(DateOnly), item(String), scrollTo(FocusID)
}
enum BoardRoute: Equatable, Sendable {
    case openEvent(eventID: String, anchor: StableAnchor)
    case openAdd(AddRequest)
    case openSearch(initialQuery: String, anchor: StableAnchor? = nil)
    case openSettings
    case openMonthPicker(anchor: StableAnchor? = nil)
    case openCalendars(anchor: StableAnchor? = nil)
    case revealPanel(PanelID, PanelReveal)
    case revealAgenda(day: DateOnly, anchor: StableAnchor)
    case dismissOverlay
}
@MainActor protocol BoardRouting: AnyObject { func route(_ request: BoardRoute) }
/// The context retains this forwarding object, never its root coordinator target.
@MainActor final class WeakBoardRoutingProxy: BoardRouting {
    weak var target: (any BoardRouting)?
    init(target: (any BoardRouting)? = nil) { self.target = target }
    func route(_ request: BoardRoute) { target?.route(request) }
}
@MainActor protocol PanelController: AnyObject {
    var panelID: PanelID { get }
    var view: NSView { get }
    func setPlacement(_ placement: PanelPlacement)
    func setPlacement(slot: SlotID?, variant: SlotVariant)
    func reveal(_ target: PanelReveal)
    func dispose()
}
extension PanelController {
    func setPlacement(_ placement: PanelPlacement) {
        setPlacement(slot: placement.slot, variant: placement.shape == .wide ? .wide : .tall)
    }
}
typealias PanelFactory = @MainActor (BoardScreenContext) -> any PanelController

enum OverlayKind: String, Sendable, CaseIterable { case event, add, search, settings, monthPicker, calendars, agenda }
@MainActor protocol OverlayController: AnyObject {
    var kind: OverlayKind { get }
    var view: NSView { get }
    /// Prepare the route's data/draft; the root owns popover hosting and screen-coordinate conversion.
    func present(_ request: BoardRoute)
    func dismiss()
    func dispose()
}
typealias OverlayFactory = @MainActor (OverlayKind, BoardScreenContext) -> any OverlayController

/// Root-owned toolkit configuration, shared by value contexts and stable controllers.
@MainActor final class NativeUIKit {
    var theme: NativeTheme
    let strings: NativeStrings
    let panelMenus = WeakPanelMenuProxy()
    init(theme: NativeTheme = NativeTheme(appearance: .dark), strings: NativeStrings = NativeStrings()) {
        self.theme = theme; self.strings = strings
    }
}
/// The root owns the stable host. A parked panel/context cannot keep a torn-down root editor alive.
@MainActor final class EditingCoordinator {
    private(set) weak var host: BoardEditorHost?
    init(host: BoardEditorHost) { self.host = host }
    func attach(to view: NSView, rect: CGRect, key: DraftKey, text: String) {
        host?.attach(to: view, rect: rect, key: key, text: text)
    }
    func detach() { host?.detach() }
    func compositionDidEnd() { host?.compositionDidEnd() }
    var currentDraft: TextDraft? { host?.currentDraft }
    func dispose() { host = nil }
}
