import AppKit

@MainActor protocol NativeAccessibilityNotifications {
    func postLayoutChanged(_ view: NSView)
}
@MainActor struct SystemNativeAccessibilityNotifications: NativeAccessibilityNotifications {
    func postLayoutChanged(_ view: NSView) { NSAccessibility.post(element: view, notification: .layoutChanged) }
}
struct NativeSliderMetadata: Equatable {
    var orientation: NativeAxis
    var minimumValue: Double
    var maximumValue: Double
    var value: Double
}
struct NativeRenderItem: Equatable {
    enum Kind: Equatable { case button, checkBox, slider, row, group, text, chip, badge, image }
    var id: String
    /// Shared interaction/AX/drawing enclosure; content is inset inside this rect.
    var rect: CGRect
    var label: String
    var kind: Kind
    var value: String? = nil
    var enabled = true
    var checked = false
    var fill: NativeColorToken? = nil
    var color: NativeColorToken = .textPrimary
    var radius: CGFloat = NativeRadius.button
    var interactionRect: CGRect? = nil
    var minimumTarget: CGFloat = NativeSize.compactTarget
    var slider: NativeSliderMetadata? = nil
    var panelHeader: PanelHeaderGeometry? = nil
    var splitter: NativeSplitterMetadata? = nil
    var focusID: FocusID { FocusID(panelHeader?.identifier ?? id) }
    var hitRect: CGRect { panelHeader?.titleRect ?? interactionRect ?? NativeGeometry.target(rect, minimum: minimumTarget) }
    var isInteractive: Bool { panelHeader != nil || [.button, .checkBox, .slider, .row, .chip].contains(kind) }
    var role: NSAccessibility.Role {
        if panelHeader != nil { return .group }
        if splitter != nil { return .splitter }
        return switch kind { case .button, .chip: .button; case .checkBox: .checkBox; case .slider: .slider; case .row: .row; case .group: .group; case .text, .badge: .staticText; case .image: .image }
    }
}
/// AppKit exposes AX callbacks as nonisolated. Immutable Sendable routing closures enter
/// the main actor synchronously; no NSAccessibilityElement crosses an actor boundary.
final class NativeAXElement: NSAccessibilityElement {
    let modelID: String
    private let frameProvider: @MainActor @Sendable () -> CGRect
    private let press: @MainActor @Sendable () -> Bool
    private let focused: @MainActor @Sendable () -> Bool
    private let setFocus: @MainActor @Sendable (Bool) -> Void
    private let adjustValue: @MainActor @Sendable (Int) -> Bool
    private let showMenu: @MainActor @Sendable () -> Bool
    private let scroll: @MainActor @Sendable () -> Bool
    @MainActor init(id: String, canvas: NativeCanvasView) {
        modelID = id
        frameProvider = { [weak canvas] in guard let canvas, let item = canvas.items.first(where: { $0.id == id }) else { return .zero }; return canvas.screenRect(item.hitRect) }
        press = { [weak canvas] in
            guard let canvas, let item = canvas.items.first(where: { $0.id == id && $0.enabled && $0.isInteractive }) else { return false }
            if item.panelHeader != nil { return canvas.showMenu(for: id) }
            canvas.activate(id); return true
        }
        focused = { [weak canvas] in guard let canvas, let item = canvas.items.first(where: { $0.id == id }) else { return false }; return canvas.focus.focusedID == item.focusID }
        setFocus = { [weak canvas] value in guard value, let canvas else { return }; canvas.window?.makeFirstResponder(canvas); if let item = canvas.items.first(where: { $0.id == id }) { canvas.focus.focus(item.focusID) }; canvas.needsDisplay = true }
        adjustValue = { [weak canvas] amount in
            guard let canvas, let item = canvas.items.first(where: { $0.id == id && $0.enabled && $0.kind == .slider }) else { return false }
            if let metadata = item.splitter, !(1...4).contains(metadata.step.rawValue + amount) { return false }
            canvas.onAdjust?(id, amount); return true
        }
        showMenu = { [weak canvas] in canvas?.showMenu(for: id) ?? false }
        scroll = { [weak canvas] in guard let canvas, let item = canvas.items.first(where: { $0.id == id }) else { return false }; canvas.scrollToVisible(item.rect); return true }
        super.init()
    }
    override func accessibilityFrame() -> NSRect { let action = frameProvider; return MainActor.assumeIsolated { action() } }
    override func isAccessibilityFocused() -> Bool { let action = focused; return MainActor.assumeIsolated { action() } }
    override func setAccessibilityFocused(_ value: Bool) { let action = setFocus; MainActor.assumeIsolated { action(value) } }
    override func accessibilityPerformPick() -> Bool { false }
    override func accessibilityPerformCancel() -> Bool { false }
    override func accessibilityPerformConfirm() -> Bool { false }
    override func accessibilityPerformDelete() -> Bool { false }
    override func accessibilityPerformRaise() -> Bool { false }
    override func accessibilityPerformPress() -> Bool { let action = press; return MainActor.assumeIsolated { action() } }
    override func accessibilityPerformIncrement() -> Bool { let action = adjustValue; return MainActor.assumeIsolated { action(1) } }
    override func accessibilityPerformDecrement() -> Bool { let action = adjustValue; return MainActor.assumeIsolated { action(-1) } }
    override func accessibilityPerformShowMenu() -> Bool { let action = showMenu; return MainActor.assumeIsolated { action() } }
    @objc func accessibilityPerformScrollToVisible() -> Bool { let action = scroll; return MainActor.assumeIsolated { action() } }
}
/// One canvas paints many items. No NSView/CALayer is allocated for each calendar cell or list row.
@MainActor class NativeCanvasView: NSView {
    let focus: FocusCoordinator
    private(set) var items: [NativeRenderItem] = []
    private(set) var paintPassCount = 0
    private(set) var virtualElements: [NativeAXElement] = []
    var theme = NativeTheme(appearance: .dark) {
        didSet {
            guard oldValue.appearance != theme.appearance else { return }
            needsDisplay = true; themeDidChange()
        }
    }
    func themeDidChange() {}
    var onAction: (@MainActor (String) -> Void)?
    var onAdjust: (@MainActor (String, Int) -> Void)?
    var onShortcut: (@MainActor (NSEvent) -> Bool)?
    var contextMenu: (@MainActor (String) -> NSMenu?)?
    var panelMenu: (@MainActor (SlotID) -> NSMenu?)?
    var panelMenuPresenter: any NativePanelMenuPresenting = SystemNativePanelMenuPresenter()
    private var panelMenuSession: NativePanelMenuSession?
    private var hoverID: String?
    private var pressedID: String?
    private struct ReleaseFeedback {
        var id: String
        var began: TimeInterval
        var from: Double
    }
    private var releaseFeedback: ReleaseFeedback?
    private var releaseTimer: Timer?
    private var tracking: NSTrackingArea?
    private var disposed = false
    private let accessibilityNotifications: any NativeAccessibilityNotifications
    var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
        didSet { if reduceMotion { stopReleaseFeedback() }; if oldValue != reduceMotion { invalidate(pressedID) } }
    }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    init(frame: NSRect = .zero, focus: FocusCoordinator = FocusCoordinator(), accessibilityNotifications: any NativeAccessibilityNotifications = SystemNativeAccessibilityNotifications()) {
        self.focus = focus; self.accessibilityNotifications = accessibilityNotifications; super.init(frame: frame); focusRingType = .none
        setAccessibilityElement(false); setAccessibilityRole(.group)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    func update(items newItems: [NativeRenderItem], announceLayout: Bool = true, invalidatingDisplay: Bool = true) {
        precondition(Set(newItems.map(\.id)).count == newItems.count, "Render IDs must be unique within a canvas")
        guard items != newItems else { return }
        let structureChanged = items.count != newItems.count || zip(items, newItems).contains { $0.id != $1.id || $0.kind != $1.kind }
        let previousItems = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let dirty = NativeGeometry.dirtyRects(old: items, new: newItems)
        items = newItems
        if let releaseFeedback, !items.contains(where: { $0.id == releaseFeedback.id }) { stopReleaseFeedback() }
        let previous = Dictionary(uniqueKeysWithValues: virtualElements.map { ($0.modelID, $0) })
        virtualElements = items.map { item in
            let element = previous[item.id] ?? NativeAXElement(id: item.id, canvas: self)
            if previousItems[item.id] == item { return element }
            element.setAccessibilityParent(self); element.setAccessibilityIdentifier(item.panelHeader?.identifier ?? item.id)
            element.setAccessibilityRole(item.role); element.setAccessibilityLabel(item.splitter.flatMap { $0.label.isEmpty ? nil : $0.label } ?? item.label)
            element.setAccessibilityEnabled(item.enabled)
            element.setAccessibilityValueDescription(item.splitter?.valueDescription)
            element.setAccessibilityHelp(item.splitter?.help)
            if let splitter = item.splitter {
                element.setAccessibilityValue(NSNumber(value: splitter.step.rawValue))
                element.setAccessibilityMinValue(NSNumber(value: 1)); element.setAccessibilityMaxValue(NSNumber(value: 4))
                element.setAccessibilityOrientation(splitter.split == .column ? .vertical : .horizontal)
            } else if let slider = item.slider {
                element.setAccessibilityValue(NSNumber(value: slider.value))
                element.setAccessibilityMinValue(NSNumber(value: slider.minimumValue)); element.setAccessibilityMaxValue(NSNumber(value: slider.maximumValue))
                element.setAccessibilityOrientation(slider.orientation == .horizontal ? .horizontal : .vertical)
            } else {
                element.setAccessibilityMinValue(nil); element.setAccessibilityMaxValue(nil); element.setAccessibilityOrientation(.unknown)
                if item.kind == .checkBox { element.setAccessibilityValue(NSNumber(value: item.checked)) } else { element.setAccessibilityValue(item.value) }
            }
            return element
        }
        syncFocusTargets()
        if invalidatingDisplay { for rect in dirty { setNeedsDisplay(rect.insetBy(dx: -NativeSize.focusOffset - NativeSize.focusWidth, dy: -NativeSize.focusOffset - NativeSize.focusWidth)) } }
        if announceLayout && structureChanged { accessibilityNotifications.postLayoutChanged(self) }
    }
    private func syncFocusTargets() {
        guard !isHiddenOrHasHiddenAncestor, !disposed else { focus.unregister(owner: self); return }
        var targets: [FocusCoordinator.Target] = []
        for item in items where item.isInteractive {
            let id = item.id, rect = item.hitRect
            var target = FocusCoordinator.Target(id: item.focusID, rect: rect, enabled: item.enabled, activate: { [weak self] in self?.activate(id) })
            if item.kind == .slider { target.increment = { [weak self] amount in self?.onAdjust?(id, amount) } }
            if item.panelHeader != nil { target.showMenu = { [weak self] in _ = self?.showMenu(for: id) } }
            if item.splitter != nil { target.handleKey = { [weak self] event in self?.handleSplitterKey(event, id: id) } }
            target.reveal = { [weak self] in
                guard let self else { return }
                self.window?.makeFirstResponder(self)
                _ = self.scrollToVisible(rect.insetBy(dx: -NativeSize.focusOffset - NativeSize.focusWidth, dy: -NativeSize.focusOffset - NativeSize.focusWidth))
            }
            target.focusChanged = { [weak self] in self?.invalidate(id) }
            targets.append(target)
        }
        focus.register(owner: self, targets: targets)
    }
    override func viewDidHide() { super.viewDidHide(); focus.unregister(owner: self); hoverID = nil; pressedID = nil; stopReleaseFeedback() }
    override func viewDidUnhide() { super.viewDidUnhide(); syncFocusTargets(); needsDisplay = true }
    func item(at point: CGPoint) -> NativeRenderItem? {
        items.reversed().first { $0.enabled && $0.isInteractive && ($0.panelHeader?.contains(point) ?? $0.hitRect.contains(point)) }
    }
    func screenRect(_ rect: CGRect) -> CGRect {
        guard let window else { return .zero }; return window.convertToScreen(convert(rect, to: nil))
    }
    override func accessibilityChildren() -> [Any]? {
        nonisolated(unsafe) var result: [Any] = []
        MainActor.assumeIsolated { result = isHiddenOrHasHiddenAncestor ? [] : virtualElements + subviews.filter { !$0.isHidden && !$0.isAccessibilityHidden() } as [Any] }
        return result
    }
    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        // ObjC AX has a nonisolated Any return. This local never escapes the synchronous,
        // asserted-main-thread callback; no AppKit object is sent to another executor.
        nonisolated(unsafe) var result: Any?
        MainActor.assumeIsolated {
            guard let window else { return }
            let local = convert(window.convertFromScreen(NSRect(origin: point, size: .zero)).origin, from: nil)
            if let native = hitTest(local), native !== self { result = native.accessibilityHitTest(point); return }
            result = virtualElements.first { $0.modelID == item(at: local)?.id }
        }
        return result ?? self
    }
    override func draw(_ dirtyRect: NSRect) {
        paintPassCount += 1
        super.draw(dirtyRect)
        for item in items where item.rect.intersects(dirtyRect) && item.rect.intersects(visibleRect) {
            drawItem(item)
        }
    }
    var pressedItemID: String? { pressedID }
    var interactionFeedbackIDs: Set<String> {
        Set([hoverID, pressedID, releaseFeedback?.id, focus.keyboardFocus ? focus.focusedID?.rawValue : nil].compactMap { $0 })
    }
    var drawsInteractionFeedback: Bool { true }
    func drawItem(_ item: NativeRenderItem) {
        NSGraphicsContext.saveGraphicsState()
        let scale = CGFloat(feedbackScale(for: item.id))
        if drawsInteractionFeedback, scale != 1, !reduceMotion, let context = NSGraphicsContext.current?.cgContext {
            context.translateBy(x: item.rect.midX, y: item.rect.midY); context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -item.rect.midX, y: -item.rect.midY)
        }
        paint(item); NSGraphicsContext.restoreGraphicsState()
    }
    private func feedbackScale(for id: String) -> Double {
        guard !reduceMotion else { return 1 }
        if pressedID == id { return NativeMotion.plan(.press, reduceMotion: false).to }
        guard let feedback = releaseFeedback, feedback.id == id else { return 1 }
        let plan = NativeMotion.plan(.release, reduceMotion: false)
        let elapsed = ProcessInfo.processInfo.systemUptime - feedback.began
        guard elapsed < plan.duration else { return plan.to }
        return feedback.from + (plan.to - feedback.from) * NativeMotion.easeOutProgress(elapsed / plan.duration)
    }
    private func beginReleaseFeedback(_ id: String, from scale: Double) {
        stopReleaseFeedback()
        guard !reduceMotion, drawsInteractionFeedback, !disposed,
              items.contains(where: { $0.id == id }) else { return }
        releaseFeedback = ReleaseFeedback(id: id, began: ProcessInfo.processInfo.systemUptime, from: scale)
        // One finite scalar timer per canvas. Only this item's bounded dirty rect is repainted;
        // no bitmap snapshot, raster layer, or retained panel image is created.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            let active = MainActor.assumeIsolated {
                guard let self, let feedback = self.releaseFeedback else { return false }
                if self.reduceMotion || self.disposed || self.isHiddenOrHasHiddenAncestor ||
                    ProcessInfo.processInfo.systemUptime - feedback.began >= NativeMotion.plan(.release, reduceMotion: false).duration {
                    self.stopReleaseFeedback()
                } else { self.invalidate(feedback.id) }
                return self.releaseFeedback != nil
            }
            if !active { timer.invalidate() }
        }
        releaseTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func stopReleaseFeedback() {
        let previous = releaseFeedback?.id
        releaseTimer?.invalidate(); releaseTimer = nil; releaseFeedback = nil
        invalidate(previous)
    }
    func paint(_ item: NativeRenderItem) {
        let highlighted = drawsInteractionFeedback && (item.id == hoverID || item.id == pressedID)
        let fill = highlighted ? (item.fill == .fill ? NativeColorToken.fillHover : .hover) : item.fill
        if let fill { theme.color(fill).setFill(); NSBezierPath(roundedRect: item.rect, xRadius: item.radius, yRadius: item.radius).fill() }
        var textRect = item.rect.insetBy(dx: NativeSpace.sm, dy: 0)
        if item.kind == .checkBox {
            let box = CGRect(x: item.rect.minX + NativeSpace.xs, y: item.rect.midY - NativeSpace.sm, width: NativeSpace.lg, height: NativeSpace.lg)
            let path = NSBezierPath(roundedRect: box, xRadius: NativeRadius.chip, yRadius: NativeRadius.chip)
            theme.color(item.checked ? .fill : .checkboxBorder).set(); if item.checked { path.fill() } else { path.lineWidth = 1; path.stroke() }
            if item.checked {
                NSColor.white.setStroke(); let check = NSBezierPath(); check.move(to: CGPoint(x: box.minX + 3, y: box.midY)); check.line(to: CGPoint(x: box.midX - 1, y: box.maxY - 4)); check.line(to: CGPoint(x: box.maxX - 3, y: box.minY + 4)); check.lineWidth = 2; check.stroke()
            }
            textRect.origin.x = box.maxX + NativeSpace.sm; textRect.size.width = max(0, item.rect.maxX - NativeSpace.sm - textRect.minX)
        }
        guard item.kind != .image else { return }
        let font = item.kind == .chip ? NativeFont.eventChip : NativeFont.primary
        let height = font.pointSize * 1.2
        textRect.origin.y = item.rect.midY - height / 2; textRect.size.height = height
        NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect: item.rect).addClip()
        (item.label as NSString).draw(in: textRect, withAttributes: NativeFont.attributes(font: font, color: theme.color(item.enabled ? item.color : .textQuiet), lineHeight: height))
        NSGraphicsContext.restoreGraphicsState()
        if drawsInteractionFeedback, focus.keyboardFocus, focus.focusedID == item.focusID {
            theme.color(.accentBlue).setStroke()
            let ring = NSBezierPath(roundedRect: item.rect.insetBy(dx: -NativeSize.focusOffset, dy: -NativeSize.focusOffset), xRadius: item.radius, yRadius: item.radius)
            ring.lineWidth = NativeSize.focusWidth; ring.stroke()
        }
    }
    func activate(_ id: String) {
        guard let item = items.first(where: { $0.id == id && $0.enabled && $0.isInteractive }) else { return }
        if item.panelHeader != nil { _ = showMenu(for: id) } else { onAction?(id) }
    }
    private func preparePanelMenu(for item: NativeRenderItem) -> NSMenu? {
        guard let header = item.panelHeader, window != nil, let menu = panelMenu?(header.slot) else { return nil }
        panelMenuSession?.finish(restoreFocus: false)
        window?.makeFirstResponder(self); focus.focus(item.focusID)
        panelMenuSession = NativePanelMenuSession(menu: menu, focus: focus, returnID: item.focusID)
        return menu
    }
    func showMenu(for id: String) -> Bool {
        guard let item = items.first(where: { $0.id == id && $0.enabled }) else { return false }
        if item.panelHeader != nil {
            guard let menu = preparePanelMenu(for: item) else { return false }
            let shown = panelMenuPresenter.present(menu, at: CGPoint(x: item.hitRect.minX, y: item.hitRect.maxY), in: self)
            panelMenuSession?.finish(); return shown
        }
        guard let menu = contextMenu?(id) else { return false }
        menu.popUp(positioning: nil, at: CGPoint(x: item.rect.minX, y: item.rect.maxY), in: self); return true
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); if let tracking { removeTrackingArea(tracking) }
        let next = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(next); tracking = next
    }
    override func mouseMoved(with event: NSEvent) { let id = item(at: convert(event.locationInWindow, from: nil))?.id; guard hoverID != id else { return }; invalidate(hoverID); hoverID = id; toolTip = items.first { $0.id == id }?.label; invalidate(id) }
    override func mouseExited(with event: NSEvent) { invalidate(hoverID); hoverID = nil }
    override func mouseDown(with event: NSEvent) {
        stopReleaseFeedback()
        let point = convert(event.locationInWindow, from: nil); pressedID = item(at: point)?.id
        if let pressedID { window?.makeFirstResponder(self); if let item = items.first(where: { $0.id == pressedID }) { focus.focus(item.focusID, keyboard: false) }; invalidate(pressedID) }
    }
    override func mouseDragged(with event: NSEvent) { invalidate(pressedID); hoverID = item(at: convert(event.locationInWindow, from: nil))?.id }
    override func mouseUp(with event: NSEvent) {
        let released = item(at: convert(event.locationInWindow, from: nil))?.id
        let pressed = pressedID
        let scale = pressed.map { feedbackScale(for: $0) } ?? 1
        pressedID = nil
        if let pressed { beginReleaseFeedback(pressed, from: scale); invalidate(pressed) }
        if let pressed, released == pressed { activate(pressed) }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let item = item(at: convert(event.locationInWindow, from: nil)) else { return nil }
        return item.panelHeader != nil ? preparePanelMenu(for: item) : contextMenu?(item.id)
    }
    private func handleSplitterKey(_ event: NSEvent, id: String) -> Bool? {
        guard [123, 124, 125, 126, 115, 119].contains(event.keyCode) else { return nil }
        guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return false }
        guard let metadata = items.first(where: { $0.id == id })?.splitter else { return nil }
        guard let step = metadata.requestedStep(forKeyCode: event.keyCode) else { return true }
        if step != metadata.step { onAdjust?(id, step.rawValue - metadata.step.rawValue) }
        return true
    }
    override func keyDown(with event: NSEvent) {
        if onShortcut?(event) == true { return }
        if focus.handle(event) { needsDisplay = true } else { super.keyDown(with: event) }
    }
    private func invalidate(_ id: String?) { if let rect = items.first(where: { $0.id == id })?.rect { setNeedsDisplay(rect.insetBy(dx: -NativeSize.focusWidth - NativeSize.focusOffset, dy: -NativeSize.focusWidth - NativeSize.focusOffset)) } }
    func dispose() {
        guard !disposed else { return }; disposed = true
        stopReleaseFeedback()
        focus.unregister(owner: self); onAction = nil; onAdjust = nil; onShortcut = nil; contextMenu = nil
        panelMenuSession?.finish(restoreFocus: false); panelMenuSession = nil; panelMenu = nil
        panelMenuPresenter = SystemNativePanelMenuPresenter()
        if let tracking { removeTrackingArea(tracking) }; tracking = nil
        for element in virtualElements { element.setAccessibilityParent(nil) }
        virtualElements = []; items = []
    }
}
/// A single immutable background plane per panel; dynamic items stay in the original canvas.
@MainActor private final class NativePanelBackgroundView: NSView {
    private(set) var paintPassCount = 0
    var theme = NativeTheme(appearance: .dark) {
        didSet { if oldValue.appearance != theme.appearance { needsDisplay = true } }
    }
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        setAccessibilityElement(false); setAccessibilityHidden(true)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        paintPassCount += 1
        theme.panelGradient.draw(in: bounds, angle: 150)
    }
}
@MainActor final class NativeCanvasPaintSurface: NSView {
    private(set) var paintPassCount = 0
    weak var canvas: NativeCanvasView?
    var painter: (@MainActor (NSRect) -> Void)?
    var backgroundTheme: NativeTheme?
    var drawingOrigin = CGPoint.zero
    var isolatesBacking = false
    private var renderingBacking = false
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        setAccessibilityElement(false); setAccessibilityHidden(true)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var wantsUpdateLayer: Bool { isolatesBacking }
    override func updateLayer() {
        guard isolatesBacking, !isHidden, bounds.width > 0, bounds.height > 0 else { layer?.contents = nil; return }
        let scale = window?.backingScaleFactor ?? 1
        let width = Int(ceil(bounds.width * scale)), height = Int(ceil(bounds.height * scale))
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { layer?.contents = nil; return }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
        graphics.cgContext.translateBy(x: 0, y: CGFloat(height)); graphics.cgContext.scaleBy(x: scale, y: -scale)
        renderingBacking = true; draw(bounds); renderingBacking = false
        NSGraphicsContext.restoreGraphicsState()
        layer?.contentsScale = scale; layer?.contents = bitmap.cgImage
    }
    override func draw(_ dirtyRect: NSRect) {
        paintPassCount += 1
        let paintRect = dirtyRect.intersection(bounds)
        guard !paintRect.isEmpty else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        if (painter != nil || backgroundTheme != nil), (!isolatesBacking || renderingBacking), let context = NSGraphicsContext.current?.cgContext {
            // Clear without the ancestor's antialiased corner clip, then restore that clip for paint.
            // Clearing through partial corner coverage leaves old translucent pixels behind.
            context.saveGState(); context.resetClip(); context.clear(paintRect); context.restoreGState()
        }
        NSBezierPath(rect: paintRect).addClip()
        if drawingOrigin != .zero {
            let translation = NSAffineTransform()
            translation.translateX(by: -drawingOrigin.x, yBy: -drawingOrigin.y); translation.concat()
        }
        backgroundTheme?.panelGradient.draw(in: canvas?.bounds ?? superview?.bounds ?? bounds, angle: 150)
        let ownerDirty = paintRect.offsetBy(dx: drawingOrigin.x, dy: drawingOrigin.y)
        if let painter { painter(ownerDirty) } else { canvas?.draw(ownerDirty) }
    }
}
@MainActor class PanelContainerView: NativeCanvasView {
    private var background: NativePanelBackgroundView?
    private let contentPaint = NativeCanvasPaintSurface(frame: .zero)
    var separatesBackgroundPlane: Bool { true }
    var backgroundPaintPassCount: Int { background?.paintPassCount ?? contentPaint.paintPassCount }
    var staticRasterPaintPassCount: Int { contentPaint.paintPassCount }
    var staticRasterLayer: CALayer? { contentPaint.layer }
    override init(frame: NSRect = .zero, focus: FocusCoordinator = FocusCoordinator(), accessibilityNotifications: any NativeAccessibilityNotifications = SystemNativeAccessibilityNotifications()) {
        super.init(frame: frame, focus: focus, accessibilityNotifications: accessibilityNotifications)
        setAccessibilityElement(true); setAccessibilityRole(.group)
        wantsLayer = true; layer?.cornerCurve = .continuous; layer?.cornerRadius = NativeRadius.panel; layer?.masksToBounds = true
        if separatesBackgroundPlane {
            let plane = NativePanelBackgroundView(frame: bounds); plane.autoresizingMask = [.width, .height]
            background = plane; addSubview(plane, positioned: .below, relativeTo: nil)
        }
        contentPaint.canvas = self; contentPaint.backgroundTheme = separatesBackgroundPlane ? nil : theme; contentPaint.frame = bounds; contentPaint.autoresizingMask = [.width, .height]
        addSubview(contentPaint, positioned: .above, relativeTo: background)
        updateBorder()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    // The container itself owns geometry, AX and the border, with no raster contents.
    // Existing draw/paint overrides execute in the content plane's context.
    // Only an explicit opt-in combines the stable background with that plane.
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { contentPaint.needsDisplay = true }
    override func setNeedsDisplay(_ invalidRect: NSRect) { contentPaint.setNeedsDisplay(invalidRect) }
    override func layout() {
        super.layout()
        for plane in [background, contentPaint].compactMap({ $0 }) {
            if plane.frame != bounds { plane.frame = bounds }
            if plane.bounds != bounds { plane.bounds = bounds }
        }
    }
    override func themeDidChange() {
        background?.theme = theme
        if !separatesBackgroundPlane { contentPaint.backgroundTheme = theme }
        updateBorder()
    }
    private func updateBorder() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.borderColor = theme.color(.panelNativeBorder).cgColor; layer?.borderWidth = 1
        CATransaction.commit()
    }
}
