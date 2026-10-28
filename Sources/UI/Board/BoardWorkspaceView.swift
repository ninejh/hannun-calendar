import AppKit

@MainActor final class BoardWorkspaceView: NativeCanvasView {
    var beginSplit: (@MainActor (LayoutSplit, CGFloat) -> Void)?
    var moveSplit: (@MainActor (CGFloat) -> Void)?
    var endSplit: (@MainActor (Bool) -> Void)?
    private let feedbackSurfaces = (0..<9).map { _ in NativeCanvasPaintSurface(frame: .zero) }
    private enum Feedback { case divider(String), sizeLabel(String), slotEdge }
    private var feedbackPlans: [Feedback] = []
    private var feedbackDisposed = false
    private struct FeedbackKey: Equatable {
        var items: [NativeRenderItem]; var bounds: CGRect; var appearance: ResolvedAppearance
        var focused: FocusID?; var keyboard: Bool; var dragging: LayoutSplit?; var hovered: LayoutSplit?
        var pressed: String?; var slot: CGRect?; var reduced: Bool
    }
    private var feedbackKey: FeedbackKey?
    override init(frame: NSRect = .zero, focus: FocusCoordinator = FocusCoordinator(), accessibilityNotifications: any NativeAccessibilityNotifications = SystemNativeAccessibilityNotifications()) {
        super.init(frame: frame, focus: focus, accessibilityNotifications: accessibilityNotifications)
        wantsLayer = true
        for (index, surface) in feedbackSurfaces.enumerated() {
            surface.isolatesBacking = true
            surface.isHidden = true; addSubview(surface)
            surface.painter = { [weak self] _ in
                guard let self, self.feedbackPlans.indices.contains(index) else { return }
                switch self.feedbackPlans[index] {
                case .divider(let id): if let item = self.items.first(where: { $0.id == id }) { self.drawItem(item) }
                case .sizeLabel(let id): if let item = self.items.first(where: { $0.id == id }) { self.paintSizeLabel(item) }
                case .slotEdge: self.paintSlotFocus()
                }
            }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    func promoteFeedbackSurfaces() {
        for surface in feedbackSurfaces { addSubview(surface, positioned: .above, relativeTo: nil) }
    }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { refreshFeedback() }
    override func setNeedsDisplay(_ invalidRect: NSRect) { refreshFeedback() }
    override func update(items: [NativeRenderItem], announceLayout: Bool = true, invalidatingDisplay: Bool = true) {
        super.update(items: items, announceLayout: announceLayout, invalidatingDisplay: false); refreshFeedback()
    }
    private func refreshFeedback() {
        guard !feedbackDisposed else { return }
        let key = FeedbackKey(items: items, bounds: bounds, appearance: theme.appearance, focused: focus.focusedID, keyboard: focus.keyboardFocus, dragging: dragging, hovered: hoveredSplit, pressed: pressedItemID, slot: slotFocusRect, reduced: reduceMotion)
        guard key != feedbackKey else { return }; feedbackKey = key
        var plans: [Feedback] = [], rectangles: [CGRect] = []
        for item in items {
            guard let split = Self.split(item.id) else { continue }
            plans.append(.divider(item.id)); rectangles.append(item.rect.insetBy(dx: -NativeSize.focusOffset - NativeSize.focusWidth, dy: -NativeSize.focusOffset - NativeSize.focusWidth).integral)
            if split == dragging { plans.append(.sizeLabel(item.id)); rectangles.append(sizeLabelRect(item).integral) }
        }
        if let slotFocusRect {
            let rect = slotFocusRect.insetBy(dx: -NativeSpace.sm, dy: -NativeSpace.sm).integral
            let edge = min(NativeRadius.panel + NativeSpace.sm, min(rect.width, rect.height) / 2)
            let edges = [CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: edge), CGRect(x: rect.minX, y: rect.maxY - edge, width: rect.width, height: edge), CGRect(x: rect.minX, y: rect.minY + edge, width: edge, height: max(0, rect.height - edge * 2)), CGRect(x: rect.maxX - edge, y: rect.minY + edge, width: edge, height: max(0, rect.height - edge * 2))]
            for edgeRect in edges where !edgeRect.isEmpty { plans.append(.slotEdge); rectangles.append(edgeRect) }
        }
        feedbackPlans = plans
        for (index, surface) in feedbackSurfaces.enumerated() {
            guard rectangles.indices.contains(index) else { surface.isHidden = true; surface.layer?.contents = nil; continue }
            let rect = rectangles[index]; surface.isHidden = false
            if surface.frame != rect { surface.frame = rect }
            let localBounds = CGRect(origin: .zero, size: rect.size)
            if surface.bounds != localBounds { surface.bounds = localBounds }
            surface.drawingOrigin = rect.origin
            surface.needsDisplay = true
        }
    }
    private var dragging: LayoutSplit?
    private var hoveredSplit: LayoutSplit?
    var slotFocusRect: CGRect? {
        didSet {
            if oldValue == slotFocusRect { return }
            if let oldValue { setNeedsDisplay(oldValue.insetBy(dx: -NativeSpace.sm, dy: -NativeSpace.sm)) }
            if let slotFocusRect { setNeedsDisplay(slotFocusRect.insetBy(dx: -NativeSpace.sm, dy: -NativeSpace.sm)) }
        }
    }
    override func mouseMoved(with event: NSEvent) {
        hoveredSplit = item(at: convert(event.locationInWindow, from: nil)).flatMap { Self.split($0.id) }; super.mouseMoved(with: event)
    }
    override func mouseExited(with event: NSEvent) { hoveredSplit = nil; super.mouseExited(with: event) }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let item = item(at: point), let split = Self.split(item.id) {
            dragging = split; beginSplit?(split, split == .column ? point.x : point.y); refreshFeedback()
        }
        super.mouseDown(with: event)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let dragging else { super.mouseDragged(with: event); return }
        let point = convert(event.locationInWindow, from: nil); moveSplit?(dragging == .column ? point.x : point.y)
    }
    override func mouseUp(with event: NSEvent) {
        guard let dragging else { super.mouseUp(with: event); return }
        let point = convert(event.locationInWindow, from: nil); moveSplit?(dragging == .column ? point.x : point.y)
        self.dragging = nil; endSplit?(false); super.mouseUp(with: event)
    }
    func cancelSplit() { guard dragging != nil else { return }; dragging = nil; endSplit?(true); refreshFeedback() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { cancelSplit() }
    }
    static func split(_ id: String) -> LayoutSplit? {
        guard id.hasPrefix("divider.") else { return nil }; return LayoutSplit(rawValue: String(id.dropFirst("divider.".count)))
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        for item in items where Self.split(item.id) != nil { addCursorRect(item.hitRect, cursor: item.id == "divider.column" ? .resizeLeftRight : .resizeUpDown) }
    }
    override func paint(_ item: NativeRenderItem) {
        guard let split = Self.split(item.id) else { super.paint(item); return }
        let selected = focus.keyboardFocus && focus.focusedID == FocusID(item.id)
        let active = selected || split == dragging || split == hoveredSplit
        theme.color(active ? .accentBlue : .textQuiet).setFill()
        let width = NativeSpace.xxs, length = active ? (split == .column ? item.rect.height : item.rect.width) : min(NativeSize.toolbarHeight, split == .column ? item.rect.height : item.rect.width)
        let rect = split == .column ? CGRect(x: item.rect.midX - width / 2, y: item.rect.midY - length / 2, width: width, height: length) : CGRect(x: item.rect.midX - length / 2, y: item.rect.midY - width / 2, width: length, height: width)
        NSBezierPath(roundedRect: rect, xRadius: width / 2, yRadius: width / 2).fill()
        if selected {
            theme.color(.accentBlue).setStroke(); let path = NSBezierPath(roundedRect: item.rect.insetBy(dx: -NativeSize.focusOffset, dy: -NativeSize.focusOffset), xRadius: NativeSpace.xxs, yRadius: NativeSpace.xxs); path.lineWidth = NativeSize.focusWidth; path.stroke()
        }
    }
    private func sizeLabelRect(_ item: NativeRenderItem) -> CGRect {
        let width: CGFloat = 112, height = NativeSize.compactTarget
        let x = min(max(bounds.minX, item.rect.midX + NativeSpace.md), max(bounds.minX, bounds.maxX - width))
        let y = min(max(bounds.minY, item.rect.midY + NativeSpace.md), max(bounds.minY, bounds.maxY - height))
        return CGRect(x: x, y: y, width: width, height: height)
    }
    private func paintSizeLabel(_ item: NativeRenderItem) {
        let rect = sizeLabelRect(item)
        theme.color(.popoverBg).setFill(); NSBezierPath(roundedRect: rect, xRadius: NativeRadius.input, yRadius: NativeRadius.input).fill()
        theme.color(.lineStrong).setStroke(); let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: NativeRadius.input, yRadius: NativeRadius.input); border.lineWidth = 1; border.stroke()
        let text = item.value ?? "", font = NativeFont.primary
        let size = (text as NSString).size(withAttributes: [.font: font])
        (text as NSString).draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: NativeFont.attributes(font: font, color: theme.color(.textPrimary)))
    }
    // The structural workspace paints only through its bounded feedback surfaces.
    override func draw(_ dirtyRect: NSRect) {}
    private func paintSlotFocus() {
        if let slotFocusRect {
            theme.color(.focusSlot).setStroke()
            let path = NSBezierPath(roundedRect: slotFocusRect.insetBy(dx: -NativeSize.focusOffset - BoardLayoutMetrics.slotFocusWidth / 2, dy: -NativeSize.focusOffset - BoardLayoutMetrics.slotFocusWidth / 2), xRadius: NativeRadius.panel, yRadius: NativeRadius.panel)
            path.lineWidth = BoardLayoutMetrics.slotFocusWidth; path.stroke()
        }
    }
    override func dispose() {
        feedbackDisposed = true; cancelSplit(); beginSplit = nil; moveSplit = nil; endSplit = nil; slotFocusRect = nil
        for surface in feedbackSurfaces { surface.painter = nil; surface.layer?.contents = nil; surface.removeFromSuperview() }
        super.dispose()
    }
}

/// Structural slot enclosure; menu interaction belongs to the panel's actual title.
@MainActor final class BoardSlotHostView: NSView {
    let slot: SlotID
    override var isFlipped: Bool { true }
    init(slot: SlotID, focus: FocusCoordinator) {
        self.slot = slot
        super.init(frame: .zero)
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityIdentifier("slot.\(slot.rawValue)")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    func mount(_ view: NSView) {
        if view.superview !== self { view.removeFromSuperview(); addSubview(view) }
        if view.frame != bounds { view.frame = bounds }
    }
    func dispose() {}
}
