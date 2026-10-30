import AppKit

@MainActor final class BoardWorkspaceView: NativeCanvasView {
    var beginSplit: (@MainActor (LayoutSplit, CGFloat) -> Void)?
    var moveSplit: (@MainActor (CGFloat) -> Void)?
    var endSplit: (@MainActor (Bool) -> Void)?
    var backgroundHit: (@MainActor (CGPoint) -> Bool)?
    var backgroundEdit: (@MainActor () -> Bool)?
    var backgroundAvailable: (@MainActor () -> Bool)?
    var backgroundEditing = false
    var backgroundMenuTitle = ""
    private(set) var presentedBackgroundMenu: NSMenu?
    private var backgroundTimer: Timer?
    private var backgroundContact: (start: CGPoint, editing: Bool, entered: Bool)?
    private var ignoredBackgroundEvent: NSEvent?
    private let feedbackSurfaces = (0..<9).map { _ in NativeCanvasPaintSurface(frame: .zero) }
    private enum Feedback { case divider(String), slotEdge }
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
        setAccessibilityElement(true); setAccessibilityIdentifier("board.background")
        wantsLayer = true
        for (index, surface) in feedbackSurfaces.enumerated() {
            surface.isolatesBacking = true
            surface.isHidden = true; addSubview(surface)
            surface.painter = { [weak self] _ in
                guard let self, self.feedbackPlans.indices.contains(index) else { return }
                switch self.feedbackPlans[index] {
                case .divider(let id): if let item = self.items.first(where: { $0.id == id }) { self.drawItem(item) }
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
            guard Self.split(item.id) != nil else { continue }
            plans.append(.divider(item.id)); rectangles.append(item.rect.insetBy(dx: -NativeSize.focusOffset - NativeSize.focusWidth, dy: -NativeSize.focusOffset - NativeSize.focusWidth).integral)
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
        let point = convert(event.locationInWindow, from: nil)
        if let contact = backgroundContact, hypot(point.x - contact.start.x, point.y - contact.start.y) >= 4 || backgroundHit?(point) != true { cancelBackgroundContact() }
        hoveredSplit = item(at: point).flatMap { Self.split($0.id) }; super.mouseMoved(with: event)
    }
    override func mouseExited(with event: NSEvent) { cancelBackgroundContact(); hoveredSplit = nil; super.mouseExited(with: event) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        guard let event else { return false }
        return backgroundHit?(convert(event.locationInWindow, from: nil)) == true
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let ignored = ignoredBackgroundEvent === event; ignoredBackgroundEvent = nil
        if ignored { super.mouseDown(with: event); return }
        if backgroundHit?(point) == true {
            cancelBackgroundContact()
            guard backgroundEditing || event.clickCount == 1 else { return }
            backgroundContact = (point, backgroundEditing, false)
            if !backgroundEditing {
                let timer = Timer(timeInterval: 0.5, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, var contact = self.backgroundContact, !contact.editing,
                              self.backgroundHit?(contact.start) == true else { return }
                        contact.entered = true; self.backgroundContact = contact
                        if self.backgroundEdit?() != true { self.cancelBackgroundContact() }
                    }
                }
                backgroundTimer = timer; RunLoop.main.add(timer, forMode: .common)
            }
            return
        }
        if let item = item(at: point), let split = Self.split(item.id) {
            dragging = split; beginSplit?(split, split == .column ? point.x : point.y); refreshFeedback()
        }
        super.mouseDown(with: event)
    }
    override func mouseDragged(with event: NSEvent) {
        if let contact = backgroundContact {
            let point = convert(event.locationInWindow, from: nil)
            if hypot(point.x - contact.start.x, point.y - contact.start.y) >= 4 || backgroundHit?(point) != true { cancelBackgroundContact() }
            return
        }
        guard let dragging else { super.mouseDragged(with: event); return }
        let point = convert(event.locationInWindow, from: nil); moveSplit?(dragging == .column ? point.x : point.y)
    }
    override func mouseUp(with event: NSEvent) {
        if let contact = backgroundContact {
            let point = convert(event.locationInWindow, from: nil)
            let click = hypot(point.x - contact.start.x, point.y - contact.start.y) < 4 && backgroundHit?(point) == true
            cancelBackgroundContact()
            if click && contact.editing && !contact.entered { _ = backgroundEdit?() }
            else if click && !contact.entered { window?.makeFirstResponder(self) }
            return
        }
        guard let dragging else { super.mouseUp(with: event); return }
        let point = convert(event.locationInWindow, from: nil); moveSplit?(dragging == .column ? point.x : point.y)
        self.dragging = nil; endSplit?(false); super.mouseUp(with: event)
    }
    func cancelSplit() { guard dragging != nil else { return }; dragging = nil; endSplit?(true); refreshFeedback() }
    func cancelBackgroundContact() { backgroundTimer?.invalidate(); backgroundTimer = nil; backgroundContact = nil }
    func ignoreBackgroundDown(_ event: NSEvent) { cancelBackgroundContact(); ignoredBackgroundEvent = event }
    override func scrollWheel(with event: NSEvent) { cancelBackgroundContact(); super.scrollWheel(with: event) }
    override func rightMouseDown(with event: NSEvent) { cancelBackgroundContact(); super.rightMouseDown(with: event) }
    override func otherMouseDown(with event: NSEvent) { cancelBackgroundContact(); super.otherMouseDown(with: event) }
    private func backgroundMenu() -> NSMenu {
        let menu = NSMenu(); let entry = NSMenuItem(title: backgroundMenuTitle, action: #selector(selectBackgroundEdit(_:)), keyEquivalent: "")
        entry.target = self; menu.addItem(entry); return menu
    }
    @objc private func selectBackgroundEdit(_ sender: NSMenuItem) { cancelBackgroundContact(); _ = backgroundEdit?() }
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard !backgroundEditing, backgroundHit?(point) == true else { return super.menu(for: event) }
        return backgroundMenu()
    }
    override func accessibilityPerformPress() -> Bool {
        cancelBackgroundContact()
        return backgroundEditing || backgroundAvailable?() != true ? false : (backgroundEdit?() ?? false)
    }
    override func accessibilityPerformShowMenu() -> Bool {
        guard !backgroundEditing, backgroundAvailable?() == true, let window else { return false }
        let priorResponder = window.firstResponder
        let menu = backgroundMenu(); presentedBackgroundMenu = menu
        menu.popUp(positioning: nil, at: CGPoint(x: visibleRect.midX, y: visibleRect.midY), in: self)
        presentedBackgroundMenu = nil
        if !feedbackDisposed, self.window === window, let view = priorResponder as? NSView, view.window === window {
            window.makeFirstResponder(view)
        }
        return true
    }
    override func keyDown(with event: NSEvent) {
        cancelBackgroundContact()
        if event.keyCode == 109, event.modifierFlags.contains(.shift), !backgroundEditing {
            _ = accessibilityPerformShowMenu(); return
        }
        super.keyDown(with: event)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { cancelSplit(); cancelBackgroundContact() }
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
        let width = active ? NativeSpace.xs : NativeSpace.xxs, length = min(NativeSize.toolbarHeight, split == .column ? item.rect.height : item.rect.width)
        let rect = split == .column ? CGRect(x: item.rect.midX - width / 2, y: item.rect.midY - length / 2, width: width, height: length) : CGRect(x: item.rect.midX - length / 2, y: item.rect.midY - width / 2, width: length, height: width)
        NSBezierPath(roundedRect: rect, xRadius: width / 2, yRadius: width / 2).fill()
        if selected {
            theme.color(.accentBlue).setStroke(); let path = NSBezierPath(roundedRect: rect.insetBy(dx: -NativeSize.focusOffset, dy: -NativeSize.focusOffset), xRadius: NativeSpace.xxs, yRadius: NativeSpace.xxs); path.lineWidth = NativeSize.focusWidth; path.stroke()
        }
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
        feedbackDisposed = true; cancelSplit(); cancelBackgroundContact(); presentedBackgroundMenu?.cancelTracking(); presentedBackgroundMenu = nil; beginSplit = nil; moveSplit = nil; endSplit = nil; backgroundHit = nil; backgroundEdit = nil; backgroundAvailable = nil; slotFocusRect = nil
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

/// A small native hit surface above panel content; the panel itself remains mounted in place.
@MainActor final class GridHandleView: NSView {
    let item: GridItemID
    let resizing: Bool
    var shouldBegin: (() -> Bool)?
    private var acceptsContact = false
    var onDown: ((GridHandleView, CGPoint) -> Void)?
    var onDrag: ((CGPoint) -> Void)?
    var onUp: ((CGPoint) -> Void)?
    var onKey: ((GridHandleView, NSEvent) -> Bool)?
    var onClick: ((GridHandleView) -> Void)?
    var onResign: (() -> Void)?
    var theme = NativeTheme(appearance: .dark)
    private var hover = false
    private var tracking: NSTrackingArea?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    init(item: GridItemID, resizing: Bool) {
        self.item = item; self.resizing = resizing; super.init(frame: .zero)
        wantsLayer = true
        identifier = NSUserInterfaceItemIdentifier("grid.handle.\(item.rawValue).\(resizing ? "resize" : "move")")
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityEnabled(true); setAccessibilityIdentifier(identifier!.rawValue)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func hitTest(_ point: NSPoint) -> NSView? { resizing ? super.hitTest(point) : nil }
    override func draw(_ dirtyRect: NSRect) {
        if resizing {
            theme.color(hover ? .accentBlue : .textQuiet).setStroke()
            let grip = NSBezierPath(); grip.lineWidth = 1.5; grip.lineCapStyle = .round
            grip.move(to: CGPoint(x: 15, y: 22)); grip.line(to: CGPoint(x: 22, y: 15))
            grip.move(to: CGPoint(x: 19, y: 23)); grip.line(to: CGPoint(x: 23, y: 19)); grip.stroke()
        }
        if window?.firstResponder === self {
            theme.color(.accentBlue).setStroke()
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 3, dy: 3)); ring.lineWidth = 2; ring.stroke()
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); if let tracking { removeTrackingArea(tracking) }
        let next = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(next); tracking = next
    }
    override func mouseEntered(with event: NSEvent) { hover = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hover = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) {
        acceptsContact = shouldBegin?() ?? true
        guard acceptsContact else { return }
        window?.makeFirstResponder(self); onDown?(self, superview?.convert(event.locationInWindow, from: nil) ?? .zero)
    }
    override func mouseDragged(with event: NSEvent) { if acceptsContact { onDrag?(superview?.convert(event.locationInWindow, from: nil) ?? .zero) } }
    override func mouseUp(with event: NSEvent) { if acceptsContact { onUp?(superview?.convert(event.locationInWindow, from: nil) ?? .zero) }; acceptsContact = false }
    override func keyDown(with event: NSEvent) { if onKey?(self, event) != true { super.keyDown(with: event) } }
    override func accessibilityPerformPress() -> Bool { onClick?(self); return true }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; onResign?(); return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: resizing ? .crosshair : .openHand) }
}

/// Short-lived, noninteractive rendering of a handle during edit-mode exit.
@MainActor final class GridHandleExitView: NSView {
    let image: NSImage
    override var isFlipped: Bool { true }
    init(frame: CGRect, image: NSImage) {
        self.image = image; super.init(frame: frame); wantsLayer = true
        setAccessibilityElement(false); setAccessibilityHidden(true)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { image.draw(in: bounds) }
}

@MainActor final class GridGhostView: NSView {
    var valid = true { didSet { needsDisplay = true } }
    var label = "" { didSet { needsDisplay = true } }
    var theme = NativeTheme(appearance: .dark)
    override var isFlipped: Bool { true }
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: NativeRadius.panel, yRadius: NativeRadius.panel)
        path.lineWidth = 2; path.setLineDash([6, 4], count: 2, phase: 0)
        theme.color(valid ? .accentBlue : .danger).setStroke(); path.stroke()
        if !valid {
            let attributes: [NSAttributedString.Key: Any] = [.font: NativeFont.bodyStrong, .foregroundColor: theme.color(.danger)]
            ("⊘ " + label as NSString).draw(at: CGPoint(x: 12, y: 12), withAttributes: attributes)
        }
    }
}

@MainActor final class GridToolPopover: NSObject, NSPopoverDelegate {
    let popover = NSPopover()
    private weak var handle: GridHandleView?
    private let title = NSTextField(wrappingLabelWithString: "")
    private var buttons: [NSButton] = []
    private var reasons: [NSTextField] = []
    var choose: ((Int) -> Void)?
    init(handle: GridHandleView) {
        self.handle = handle; super.init()
        let controller = NSViewController(), content = NSView(frame: CGRect(x: 0, y: 0, width: 280, height: 310))
        controller.view = content; popover.contentViewController = controller; popover.behavior = .transient; popover.delegate = self
        title.frame = CGRect(x: 16, y: 264, width: 248, height: 40); content.addSubview(title)
        for index in 0..<4 {
            let y = 214 - CGFloat(index) * 55
            let button = NSButton(title: "", target: self, action: #selector(selected(_:)))
            button.tag = index; button.frame = CGRect(x: 16, y: y, width: 128, height: 44); content.addSubview(button); buttons.append(button)
            let reason = NSTextField(wrappingLabelWithString: ""); reason.frame = CGRect(x: 150, y: y, width: 114, height: 44); content.addSubview(reason); reasons.append(reason)
        }
    }
    func update(title value: String, options: [(String, String?)]) {
        title.stringValue = value
        for (index, option) in options.enumerated() where buttons.indices.contains(index) {
            buttons[index].title = option.0; buttons[index].isEnabled = option.1 == nil
            reasons[index].stringValue = option.1 ?? ""; buttons[index].setAccessibilityHelp(option.1)
        }
    }
    func show() { guard let handle, handle.window != nil else { return }; popover.show(relativeTo: handle.bounds, of: handle, preferredEdge: .maxY) }
    @objc private func selected(_ sender: NSButton) { choose?(sender.tag) }
    func popoverDidClose(_ notification: Notification) { if let handle { handle.window?.makeFirstResponder(handle) } }
    func close() { choose = nil; popover.close(); popover.delegate = nil }
}

@MainActor final class GridDotsView: NSView {
    var profile: GridGeometryProfile?
    var pitchY: CGFloat = 36
    var occupied: [GridRect] = []
    var theme = NativeTheme(appearance: .dark)
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let profile else { return }
        theme.color(.textQuiet).withAlphaComponent(0.3).setFill()
        let firstRow = min(GridGeometryProfile.rows - 1, max(0, Int(floor((dirtyRect.minY - GridGeometryProfile.padding) / pitchY))))
        let lastRow = min(GridGeometryProfile.rows - 1, max(firstRow, Int(ceil((dirtyRect.maxY - GridGeometryProfile.padding) / pitchY))))
        for row in firstRow...lastRow {
            for column in 0..<GridGeometryProfile.columns where !occupied.contains(where: { column >= $0.column && column < $0.column + $0.width && row >= $0.row && row < $0.row + $0.height }) {
                var cell = profile.frame(for: GridRect(column: column, row: row, width: 1, height: 1))
                cell.origin.y = CGFloat(GridGeometryProfile.padding) + CGFloat(row) * pitchY
                cell.size.height = pitchY - CGFloat(GridGeometryProfile.gap)
                NSBezierPath(ovalIn: CGRect(x: cell.midX - 1, y: cell.midY - 1, width: 2, height: 2)).fill()
            }
        }
    }
}
