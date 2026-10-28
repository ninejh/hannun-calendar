import AppKit

/// Value context: only the weak proxy/coordinator can reach root-owned routing and editing.
@MainActor struct BoardScreenContext {
    let presentation: any BoardPresentation
    let kit: NativeUIKit
    let routing: any BoardRouting
    let focus: FocusCoordinator
    let editing: EditingCoordinator
    private let compatibilityEditorHost: BoardEditorHost?
    var strings: NativeStrings { kit.strings }
    /// Legacy convenience access. The root must keep its explicit host alive during the screen lifetime.
    var editors: BoardEditorHost {
        guard let host = editing.host else { preconditionFailure("Editor host has ended its root lifetime") }
        return host
    }
    init(presentation: any BoardPresentation, kit: NativeUIKit, routing: any BoardRouting,
         focus: FocusCoordinator, editing: EditingCoordinator) {
        self.presentation = presentation; self.kit = kit; self.focus = focus; self.editing = editing
        self.routing = (routing as? WeakBoardRoutingProxy) ?? WeakBoardRoutingProxy(target: routing)
        compatibilityEditorHost = nil
        editing.host?.onDraft = { [weak presentation] key, draft in presentation?.setDraft(key, value: .text(draft)) }
    }
    /// Standalone/older consumers can own the host through their context; a composed root uses the initializer above.
    init(presentation: any BoardPresentation, strings: NativeStrings, focus: FocusCoordinator = FocusCoordinator(), editors: BoardEditorHost = BoardEditorHost()) {
        self.presentation = presentation; kit = NativeUIKit(strings: strings); self.focus = focus
        routing = WeakBoardRoutingProxy(); editing = EditingCoordinator(host: editors); compatibilityEditorHost = editors
        editors.onDraft = { [weak presentation] key, draft in presentation?.setDraft(key, value: .text(draft)) }
    }
    func bindPanelMenus(to canvas: NativeCanvasView) {
        let menus = kit.panelMenus
        canvas.panelMenu = { [weak menus] slot in menus?.panelMenu(for: slot) }
    }
    func text(_ key: String, values: [String: String] = [:]) -> String { strings.text(key, language: presentation.state.snapshot.board.settings.language, values: values) }
    func revealAgenda(_ day: DateOnly, anchor: StableAnchor) { routing.route(.revealAgenda(day: day, anchor: anchor)) }
    func revealAgenda(_ day: DateOnly, anchor: PresentationAnchor?) {
        let stable = StableAnchor(target: .day(day), boardRect: anchor?.rect ?? .zero)
        routing.route(.revealAgenda(day: day, anchor: stable))
    }
}
/// A screen owns a scope, adds cancellation tokens and closures capturing its owner weakly, and disposes once.
@MainActor final class ScreenLifetime {
    private var tokens: [ObservationToken] = []
    private var cleanups: [@MainActor () -> Void] = []
    private(set) var isDisposed = false
    func own(_ token: ObservationToken) { if isDisposed { token.cancel() } else { tokens.append(token) } }
    func onDispose(_ cleanup: @escaping @MainActor () -> Void) { if isDisposed { cleanup() } else { cleanups.append(cleanup) } }
    func dispose() {
        guard !isDisposed else { return }; isDisposed = true
        let owned = tokens; tokens = []; for token in owned { token.cancel() }
        let actions = cleanups; cleanups = []; for action in actions { action() }
    }
}
enum NativeAxis: String, Sendable { case horizontal, vertical }
@MainActor class OverflowScrollView: NSScrollView {
    var axis: NativeAxis = .vertical {
        didSet { configureAxis(); updateFade() }
    }
    private let fade = CAGradientLayer()
    private var observation: NSObjectProtocol?
    override init(frame: NSRect) {
        super.init(frame: frame); drawsBackground = false; autohidesScrollers = true; configureAxis()
        contentView.postsBoundsChangedNotifications = true
        observation = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateFade() }
        }
    }
    convenience init(frame: NSRect, axis: NativeAxis) { self.init(frame: frame); self.axis = axis; configureAxis() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    private func configureAxis() { hasVerticalScroller = axis == .vertical; hasHorizontalScroller = axis == .horizontal }
    override func layout() { super.layout(); updateFade() }
    func updateFade() {
        guard let documentView else { contentView.layer?.mask = nil; return }
        let viewport = contentView.bounds, document = documentView.bounds
        let horizontal = axis == .horizontal
        let length = horizontal ? viewport.width : viewport.height
        let documentLength = horizontal ? document.width : document.height
        guard length > 0, documentLength > length else { contentView.layer?.mask = nil; return }
        contentView.wantsLayer = true
        let low = horizontal ? viewport.minX > document.minX : viewport.minY > document.minY
        let high = horizontal ? viewport.maxX < document.maxX : viewport.maxY < document.maxY
        let edge = min(0.5, NativeSize.overflowEdge / length)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fade.frame = contentView.layer?.bounds ?? viewport
        fade.isGeometryFlipped = contentView.isFlipped
        fade.startPoint = horizontal ? CGPoint(x: 0, y: 0.5) : CGPoint(x: 0.5, y: 0)
        fade.endPoint = horizontal ? CGPoint(x: 1, y: 0.5) : CGPoint(x: 0.5, y: 1)
        fade.colors = [NSColor.black.withAlphaComponent(low ? 0 : 1).cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.black.withAlphaComponent(high ? 0 : 1).cgColor]
        fade.locations = [0, NSNumber(value: edge), NSNumber(value: 1 - edge), 1]
        contentView.layer?.mask = fade
        CATransaction.commit()
    }
    func dispose() { if let observation { NotificationCenter.default.removeObserver(observation) }; observation = nil; contentView.layer?.mask = nil }
}
