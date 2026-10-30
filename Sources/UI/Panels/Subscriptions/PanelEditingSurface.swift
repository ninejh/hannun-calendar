import AppKit

/// T-027's row typography stays on the shared kit's paint/AX/hit geometry.
@MainActor final class EditingPanelCanvas: NativeCanvasView {
    var displayText: [String: String] = [:]
    var fonts: [String: NSFont] = [:]
    var struck: Set<String> = []
    var dots: Set<String> = []
    var textRects: [String: CGRect] = [:]
    var wrappedText: [String: String] = [:]
    private var feedback: CALayer?
    private var feedbackCleanup: ObservationToken?
    func checkFeedback(id: String, reduceMotion: Bool) {
        stopFeedback()
        guard let item = items.first(where: { $0.id == id }), item.checked,
              let bitmap = bitmapImageRepForCachingDisplay(in: item.rect) else { return }
        cacheDisplay(in: item.rect, to: bitmap)
        // One temporary glyph-sized image, released at completion; never a row/full-canvas cache.
        wantsLayer = true
        let overlay = CALayer(); overlay.frame = item.rect; overlay.contents = bitmap.cgImage
        overlay.contentsScale = CGFloat(bitmap.pixelsWide) / max(1, item.rect.width)
        layer?.addSublayer(overlay); feedback = overlay
        NativeMotion.apply(.check, to: overlay, reduceMotion: reduceMotion)
        let duration = NativeMotion.plan(.check, reduceMotion: reduceMotion).duration
        feedbackCleanup = RunLoopPresentationScheduler().schedule(after: duration) { [weak self] in self?.stopFeedback() }
    }
    func stopFeedback() {
        feedbackCleanup?.cancel(); feedbackCleanup = nil
        if let feedback { NativeMotion.stop(feedback); feedback.removeFromSuperlayer() }; feedback = nil
    }
    override func viewDidHide() { stopFeedback(); super.viewDidHide() }
    override func dispose() { stopFeedback(); super.dispose() }
    override func paint(_ item: NativeRenderItem) {
        if let text = wrappedText[item.id] {
            var background = item; background.label = ""; super.paint(background)
            Self.paintWrapped(text, in: item.rect, theme: theme)
            return
        }
        if dots.contains(item.id) {
            let diameter = item.kind == .checkBox ? NativeSize.habitTodayDot : NativeSize.habitHistoryDot
            let circle = CGRect(x: item.rect.midX - diameter / 2, y: item.rect.midY - diameter / 2, width: diameter, height: diameter)
            theme.color(item.checked ? .habitDoneBg : .raised).setFill()
            let path = NSBezierPath(ovalIn: circle)
            path.fill()
            if !item.checked { theme.color(.habitEmptyBorder).setStroke(); path.lineWidth = NativeSize.focusWidth / 2; path.stroke() }
            if item.checked {
                theme.color(.habitDoneText).setStroke()
                let size = NativeSize.habitCheckMark
                let mark = NSBezierPath()
                mark.move(to: CGPoint(x: circle.midX - size / 2, y: circle.midY))
                mark.line(to: CGPoint(x: circle.midX - size / 8, y: circle.midY + size / 3))
                mark.line(to: CGPoint(x: circle.midX + size / 2, y: circle.midY - size / 3))
                mark.lineWidth = NativeSize.focusWidth / 2; mark.stroke()
            }
            if item.kind == .checkBox {
                theme.color(.accentBlue).setStroke()
                let ring = NSBezierPath(ovalIn: item.rect.insetBy(dx: NativeSpace.xs, dy: NativeSpace.xs))
                ring.lineWidth = NativeSize.focusWidth; ring.stroke()
            }
            var focusItem = item; focusItem.label = ""; focusItem.kind = .button; focusItem.fill = nil
            super.paint(focusItem)
            return
        }
        var visible = item; visible.label = displayText[item.id] ?? item.label
        if let font = fonts[item.id] {
            let text = visible.label
            visible.label = ""; super.paint(visible)
            var attributes = NativeFont.attributes(font: font, color: theme.color(item.color))
            if struck.contains(item.id) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            let height = font.pointSize * 1.4
            NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect: item.rect).addClip()
            let textBounds = textRects[item.id] ?? item.rect
            (text as NSString).draw(in: CGRect(x: textBounds.minX + NativeSpace.sm, y: textBounds.midY - height / 2,
                                             width: max(0, textBounds.width - NativeSpace.lg), height: height), withAttributes: attributes)
            NSGraphicsContext.restoreGraphicsState()
        } else { super.paint(visible) }
    }
    static func wrappedHeight(_ text: String, width: CGFloat) -> CGFloat {
        let height = (text as NSString).boundingRect(with: CGSize(width: max(1, width - NativeSpace.lg), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin], attributes: NativeFont.attributes(font: NativeFont.toolbar, color: .labelColor, truncation: .byWordWrapping)).height
        return max(NativeSize.compactTarget, height.rounded(.up) + NativeSpace.sm)
    }
    static func paintWrapped(_ text: String, in rect: CGRect, theme: NativeTheme) {
        NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect: rect).addClip()
        (text as NSString).draw(in: rect.insetBy(dx: NativeSpace.sm, dy: NativeSpace.xxs),
            withAttributes: NativeFont.attributes(font: NativeFont.toolbar, color: theme.color(.textQuiet), truncation: .byWordWrapping))
        NSGraphicsContext.restoreGraphicsState()
    }
}

@MainActor class EditingPanelView: PanelContainerView, PanelController {
    let context: BoardScreenContext
    let contentCanvas: EditingPanelCanvas
    let scroll = OverflowScrollView()
    let lifetime = ScreenLifetime()
    private(set) var statusMessage = ""
    var statusKey: String?
    var lastOperationID: UUID?
    private var operationFailure: AppFailure?
    var retainedMenu: NativeMenu?
    var variant: SlotVariant = .tall { didSet { needsLayout = true } }
    private(set) var placement: PanelPlacement?
    private var slot: SlotID?
    var stepMetrics: NativePanelStepMetrics {
        NativePanelStepMetrics(panel: panelID, shape: placement?.shape ?? (variant == .wide ? .wide : .rail), step: placement?.heightStep ?? .regular)
    }
    var isCompactStep: Bool { stepMetrics.step == .tiny || stepMetrics.step == .small }
    var horizontalPadding: CGFloat { isCompactStep ? stepMetrics.horizontalPadding : NativeSpace.md }
    var headerRowHeight: CGFloat { isCompactStep ? stepMetrics.headerHeight : NativeSize.toolbarHeight + NativeSpace.md }
    var headerItemHeight: CGFloat { isCompactStep ? min(NativeSize.toolbarHeight, stepMetrics.headerHeight) : NativeSize.toolbarHeight }
    var headerItemY: CGFloat { isCompactStep ? 0 : NativeSpace.sm }
    var scrollsStatus: Bool { stepMetrics.step == .tiny }
    var panelID: PanelID { .subscriptions }
    var view: NSView { self }
    private var parked = false
    var headerHeight: CGFloat { headerRowHeight }
    var bottomInset: CGFloat { isCompactStep ? stepMetrics.bottomPadding : NativeSpace.md }
    var headerExcludedRects: [CGRect] { [] }
    init(context: BoardScreenContext) {
        self.context = context
        contentCanvas = EditingPanelCanvas(focus: context.focus)
        super.init(focus: context.focus)
        context.bindPanelMenus(to: self)
        scroll.documentView = contentCanvas; addSubview(scroll)
        onAction = { [weak self] id in _ = self?.commonAction(id) }
        onShortcut = { [weak self] event in self?.shortcut(event) ?? false }
        contentCanvas.onShortcut = { [weak self] event in self?.shortcut(event) ?? false }
        lifetime.own(context.presentation.subscribe { [weak self] change in
            guard let self, !self.parked else { return }
            if !change.domains.isDisjoint(with: [.board, .environment, .external, .pending, .activity, .error]) ||
                (change.domains.contains(.clock) && self.dayHasChanged) { self.render() }
        })
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    private var lastDay: DateOnly?
    private var lastZone: String?
    private var dayHasChanged: Bool {
        context.presentation.state.snapshot.clock.today != lastDay ||
        context.presentation.state.snapshot.clock.timeZone != lastZone
    }
    var snapshot: BoardSnapshot { context.presentation.state.snapshot }
    func start() { render() }
    func setPlacement(slot: SlotID?, variant: SlotVariant) {
        placement = nil; self.slot = slot
        self.variant = variant; parked = slot == nil
        isHidden = parked; editorVisibilityChanged(isHidden: parked)
        if parked { contentCanvas.stopFeedback() } else { render() }
    }
    func setPlacement(_ placement: PanelPlacement) {
        self.placement = placement; slot = placement.slot
        variant = placement.shape == .wide ? .wide : .tall
        parked = placement.slot == nil; isHidden = parked; editorVisibilityChanged(isHidden: parked)
        if parked { contentCanvas.stopFeedback() } else { render() }
    }
    func editorVisibilityChanged(isHidden: Bool) {}
    func reveal(_ target: PanelReveal) {
        layoutSubtreeIfNeeded()
        let item: NativeRenderItem?
        switch target {
        case .scrollTo(let id): item = contentCanvas.items.first { $0.id == id.rawValue }
        case .item(let id): item = contentCanvas.items.first { $0.id.localizedCaseInsensitiveContains(id) }
        case .day: item = nil
        }
        if let item { contentCanvas.scrollToVisible(item.rect); context.focus.focus(FocusID(item.id)) }
    }
    func render() {
        lastDay = snapshot.clock.today; lastZone = snapshot.clock.timeZone
        let appearance = snapshot.environment.resolvedAppearance
        if theme.appearance != appearance { theme = NativeTheme(appearance: appearance) }
        if contentCanvas.theme.appearance != appearance { contentCanvas.theme = theme }
        let nativeAppearance: NSAppearance.Name = appearance == .dark ? .darkAqua : .aqua
        if self.appearance?.name != nativeAppearance { self.appearance = NSAppearance(named: nativeAppearance) }
        reduceMotion = snapshot.environment.reduceMotion; contentCanvas.reduceMotion = reduceMotion
        if snapshot.environment.reduceMotion { contentCanvas.stopFeedback() }
        let state = context.presentation.state
        let failure = operationFailure
        statusMessage = failure.map { context.text($0.messageKey, values: $0.values) } ??
            statusKey.map { context.text($0) } ?? (state.activity.loading ? context.text("loading.label") : "")
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let statusHeight = statusMessage.isEmpty || scrollsStatus ? CGFloat.zero : NativeSize.compactTarget
        let top = max(headerHeight + NativeSpace.xxs, (placement?.editLeading ?? 0) > 0 ? 32 : 0)
        let bottom = max(bottomInset, placement?.editBottom ?? 0)
        scroll.frame = CGRect(x: horizontalPadding, y: top,
                              width: max(0, bounds.width - horizontalPadding * 2),
                              height: max(0, bounds.height - top - bottom - statusHeight))
        scroll.tile()
        let previousSize = scroll.contentSize
        layoutContent()
        // Autohiding legacy scrollers can consume width only after the new document height arrives.
        scroll.tile()
        if scroll.contentSize != previousSize { layoutContent() }
        if var actualPlacement = placement {
            actualPlacement.headerRect = CGRect(x: 0, y: 0, width: bounds.width, height: headerHeight)
            actualPlacement.contentRect = scroll.frame
            placement = actualPlacement
        }
        scroll.updateFade()
    }
    func layoutContent() {}
    func updateHeader(_ original: [NativeRenderItem]) {
        let leading = placement?.editLeading ?? 0
        let items = original.map { item -> NativeRenderItem in
            var item = item
            if leading > 0, item.rect.minX < leading, item.rect.minY < 32, item.rect.maxY > 4 {
                let right = item.rect.maxX; item.rect.origin.x = leading; item.rect.size.width = max(0, right - leading)
                if item.interactionRect != nil { item.interactionRect = item.rect }
            }
            return item
        }
        guard let slot, placement?.editExclusions.isEmpty == false else { update(items: items); return }
        let excluded = items.filter { !$0.id.hasSuffix(".title") }.map(\.hitRect) + headerExcludedRects + (placement?.editExclusions ?? [])
        update(items: items.map { item in
            guard item.id == panelPrefix + ".title" else { return item }
            return NativePanelHeader.decorate(item, geometry: PanelHeaderGeometry(slot: slot, titleRect: item.rect,
                headerRect: CGRect(x: 0, y: 0, width: bounds.width, height: headerHeight), excludedRects: excluded, actionLabel: context.text("slot_menu.title")))
        })
    }
    func statusItems() -> [NativeRenderItem] {
        guard !statusMessage.isEmpty, !scrollsStatus else { return [] }
        let canRecover = operationFailure.map { $0.retryable || $0.committed == .unknown || $0.code == .boardConflict } ?? false
        let recoveryWidth = canRecover ? (context.text("error.retry_action") as NSString).size(withAttributes: [.font: NativeFont.primary]).width + NativeSpace.lg : 0
        let y = bounds.height - max(bottomInset, placement?.editBottom ?? 0) - NativeSize.compactTarget
        var result = [NativeRenderItem(id: panelPrefix + ".status", rect: CGRect(x: NativeSpace.md, y: y,
                                                                               width: max(0, bounds.width - NativeSpace.xxl - recoveryWidth), height: NativeSize.compactTarget),
                                      label: statusMessage, kind: .text, color: .textQuiet)]
        if canRecover { result.append(NativeRenderItem(id: panelPrefix + ".recovery", rect: CGRect(x: bounds.width - NativeSpace.md - recoveryWidth, y: y, width: recoveryWidth, height: NativeSize.compactTarget), label: context.text("error.retry_action"), kind: .button)) }
        return result
    }
    func contentStatusItems(at y: CGFloat) -> [NativeRenderItem] {
        guard scrollsStatus, !statusMessage.isEmpty else { return [] }
        let canRecover = operationFailure.map { $0.retryable || $0.committed == .unknown || $0.code == .boardConflict } ?? false
        let recoveryWidth = canRecover ? (context.text("error.retry_action") as NSString).size(withAttributes: [.font: NativeFont.primary]).width + NativeSpace.lg : 0
        let width = max(0, scroll.contentSize.width - recoveryWidth)
        let height = EditingPanelCanvas.wrappedHeight(statusMessage, width: width)
        let id = panelPrefix + ".status"
        contentCanvas.wrappedText[id] = statusMessage
        var result = [NativeRenderItem(id: id, rect: CGRect(x: 0, y: y, width: width, height: height), label: statusMessage, kind: .text, color: .textQuiet)]
        if canRecover { result.append(NativeRenderItem(id: panelPrefix + ".recovery", rect: CGRect(x: width, y: y, width: recoveryWidth, height: NativeSize.compactTarget), label: context.text("error.retry_action"), kind: .button)) }
        return result
    }
    var panelPrefix: String { "panel.editing" }
    override func panelHeaderTitleMetrics(_ item: NativeRenderItem) -> (font: NSFont, leading: CGFloat) { (NativeFont.sectionHead, NativeSpace.sm) }
    override func paint(_ item: NativeRenderItem) {
        var visible = item
        if item.id.hasSuffix(".add") { visible.label = "+" }
        if item.id.hasSuffix(".title") {
            let text = visible.label; visible.label = ""; super.paint(visible)
            let height = NativeFont.sectionHead.pointSize * 1.4
            (text as NSString).draw(in: CGRect(x: item.rect.minX + NativeSpace.sm, y: item.rect.midY - height / 2, width: max(0, item.rect.width - NativeSpace.lg), height: height),
                                   withAttributes: NativeFont.attributes(font: NativeFont.sectionHead, color: theme.color(.textPrimary)))
            return
        }
        super.paint(visible)
    }
    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        if let item = items.reversed().first(where: { $0.rect.contains(point) }) {
            toolTip = item.label + (item.value.map { " · " + $0 } ?? "")
        }
    }
    @discardableResult func send(_ intent: UserIntent) -> OperationHandle? {
        operationFailure = nil
        let handle = context.presentation.send(intent)
        lastOperationID = handle?.id
        if let handle {
            Task { @MainActor [weak self] in
                let receipt = await handle.settled.value
                guard let self, self.lastOperationID == handle.id, !self.lifetime.isDisposed else { return }
                if case .failure(let failure, _) = receipt {
                    self.operationFailure = failure
                    if failure.committed == .no { self.contentCanvas.stopFeedback() }
                }
                self.render()
            }
        }
        render()
        return handle
    }
    @discardableResult func commonAction(_ id: String) -> Bool {
        guard id == panelPrefix + ".recovery", let source = lastOperationID, let failure = operationFailure else { return false }
        if failure.committed == .unknown { _ = context.presentation.send(.reconcile(source)) }
        else { _ = send(.retry(source)) }
        return true
    }
    func showStatus(_ key: String?) {
        operationFailure = nil; lastOperationID = nil; statusKey = key; render()
    }
    @discardableResult func edit(_ intent: PanelIntent) -> OperationHandle? { send(.edit(.panel(intent), undoable: true)) }
    func menu(entries: [NativeMenuEntry], action: @escaping @MainActor (String) -> Void) -> NSMenu {
        retainedMenu?.dispose(); let next = NativeMenu(items: entries, onSelect: action); retainedMenu = next
        return next.menu
    }
    func showMenu(_ id: String) {
        guard let item = contentCanvas.items.first(where: { $0.id == id }), let menu = contentCanvas.contextMenu?(id) else { return }
        menu.popUp(positioning: nil, at: CGPoint(x: item.rect.minX, y: item.rect.maxY), in: contentCanvas)
    }
    private func shortcut(_ event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "z" {
            send(.undo); return true
        }
        return false
    }
    override func dispose() {
        lifetime.dispose(); retainedMenu?.dispose(); retainedMenu = nil; scroll.dispose(); contentCanvas.dispose(); super.dispose()
    }
}

/// Nonmodal editor drawn with the same kit surface; only text and date are native controls.
@MainActor final class PanelEditingForm: PanelContainerView, NSTextFieldDelegate {
    let context: BoardScreenContext
    let formID: String
    let titleKey: String
    var fields: [String: NativeTextField] = [:]
    var datePicker: NativeDatePicker?
    var cycle: SubscriptionCycle = .monthly { didSet { refresh() } }
    var currency = "KRW" { didSet { refresh() } }
    var onSave: (@MainActor () -> Void)?
    var onClose: (@MainActor () -> Void)?
    var onChange: (@MainActor () -> Void)?
    private var labels: [(String, String)] = []
    private var retainedMenu: NativeMenu?
    private var selections: [String: NSRange] = [:]
    var noticeKey: String?
    var errorKey: String?
    private weak var previousResponder: NSResponder?
    init(context: BoardScreenContext, id: String, titleKey: String, fields definitions: [(String, String, String)], day: DateOnly? = nil) {
        self.context = context; formID = id; self.titleKey = titleKey
        super.init(focus: context.focus)
        layer?.cornerRadius = NativeRadius.popover
        theme = NativeTheme(appearance: context.presentation.state.snapshot.environment.resolvedAppearance)
        for (name, key, value) in definitions {
            let field = NativeTextField(label: context.text(key), identifier: id + "." + name)
            field.stringValue = value; field.delegate = self; fields[name] = field; labels.append((name, key)); addSubview(field)
        }
        if let day {
            let picker = NativeDatePicker(label: context.text("sub.field_next_date"), identifier: id + ".date",
                                          timeZone: TimeZone(identifier: context.presentation.state.snapshot.clock.timeZone) ?? TimeZone(secondsFromGMT: 0)!)
            picker.day = day; picker.target = self; picker.action = #selector(dateChanged)
            datePicker = picker; addSubview(picker)
        }
        onAction = { [weak self] id in self?.activateForm(id) }
        onShortcut = { [weak self] event in
            if event.keyCode == 53 { self?.onClose?(); return true }
            if event.keyCode == 36 { self?.save(); return true }
            return false
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    var preferredSize: CGSize {
        CGSize(width: NativeSize.popoverWidth,
               height: NativeSize.toolbarHeight + NativeSpace.md +
                (NativeSize.toolbarHeight + NativeSpace.xs) * CGFloat(labels.count) +
                (datePicker == nil ? 0 : NativeSize.toolbarHeight * 2 + NativeSpace.xs) +
                NativeSize.toolbarHeight * 3 + NativeSpace.xxl)
    }
    func present(from source: NSView) {
        previousResponder = source.window?.firstResponder
        let host = source.window?.contentView ?? source
        let anchor = host.convert(source.bounds, from: source)
        frame = NativeGeometry.clamp(CGRect(origin: CGPoint(x: anchor.minX, y: anchor.minY), size: preferredSize), to: host.bounds.insetBy(dx: NativeSpace.sm, dy: NativeSpace.sm))
        host.addSubview(self); layoutSubtreeIfNeeded()
        isHidden = false
        let first = labels.first?.0 ?? ""
        window?.makeFirstResponder(fields[first])
        if let selection = selections[first], let editor = fields[first]?.currentEditor() as? NSTextView { editor.setSelectedRange(selection) }
        layer.map { NativeMotion.apply(.popover, to: $0, reduceMotion: context.presentation.state.snapshot.environment.reduceMotion) }
    }
    func dismiss() {
        guard !fields.values.contains(where: { ($0.currentEditor() as? NSTextView)?.hasMarkedText() == true }) else { return }
        for (key, field) in fields {
            if let text = field.currentEditor() as? NSTextView { selections[key] = text.selectedRange() }
        }
        let responder = previousResponder; isHidden = true; layer.map { NativeMotion.stop($0) }; removeFromSuperview()
        if let responder { responderWindow(responder)?.makeFirstResponder(responder) }
        retainedMenu?.dispose(); retainedMenu = nil
    }
    override func dispose() {
        fields.values.forEach { $0.delegate = nil }
        onSave = nil; onClose = nil; onChange = nil; retainedMenu?.dispose(); retainedMenu = nil
        layer.map { NativeMotion.stop($0) }; removeFromSuperview(); super.dispose()
    }
    private func responderWindow(_ responder: NSResponder) -> NSWindow? { (responder as? NSView)?.window }
    override func layout() { super.layout(); refresh() }
    func refresh() {
        let resolved = context.presentation.state.snapshot.environment.resolvedAppearance
        if theme.appearance != resolved { theme = NativeTheme(appearance: resolved) }
        let nativeAppearance: NSAppearance.Name = resolved == .dark ? .darkAqua : .aqua
        if appearance?.name != nativeAppearance { appearance = NSAppearance(named: nativeAppearance) }
        reduceMotion = context.presentation.state.snapshot.environment.reduceMotion
        var items: [NativeRenderItem] = []
        let width = max(0, bounds.width - NativeSpace.xxl)
        items.append(NativeRenderItem(id: formID + ".title", rect: CGRect(x: NativeSpace.md, y: NativeSpace.sm, width: width, height: NativeSize.toolbarHeight), label: context.text(titleKey), kind: .text))
        var y = NativeSize.toolbarHeight + NativeSpace.md
        for (name, key) in labels {
            let field = fields[name]!
            field.setAccessibilityLabel(context.text(key))
            items.append(NativeRenderItem(id: formID + ".label." + name, rect: CGRect(x: NativeSpace.md, y: y, width: width * 0.4, height: NativeSize.toolbarHeight), label: context.text(key), kind: .text))
            field.frame = CGRect(x: NativeSpace.md + width * 0.4, y: y, width: width * 0.6, height: NativeSize.compactTarget)
            y += NativeSize.toolbarHeight + NativeSpace.xs
        }
        if let datePicker {
            datePicker.frame = CGRect(x: NativeSpace.md + width * 0.4, y: y, width: width * 0.6, height: NativeSize.compactTarget)
            items.append(NativeRenderItem(id: formID + ".label.date", rect: CGRect(x: NativeSpace.md, y: y, width: width * 0.4, height: NativeSize.toolbarHeight), label: context.text("sub.field_next_date"), kind: .text))
            y += NativeSize.toolbarHeight + NativeSpace.xs
            items.append(NativeRenderItem(id: formID + ".cycle", rect: CGRect(x: NativeSpace.md, y: y, width: width * 0.6, height: NativeSize.compactTarget), label: context.text("sub.field_cycle") + ": " + context.text("sub.cycle_" + cycle.rawValue), kind: .button))
            items.append(NativeRenderItem(id: formID + ".currency", rect: CGRect(x: NativeSpace.md + width * 0.6, y: y, width: width * 0.4, height: NativeSize.compactTarget), label: context.text("sub.field_currency") + ": " + currency, kind: .button))
            y += NativeSize.toolbarHeight
        }
        if let key = errorKey ?? noticeKey {
            items.append(NativeRenderItem(id: formID + ".notice", rect: CGRect(x: NativeSpace.md, y: y, width: width, height: NativeSize.toolbarHeight * 2), label: context.text(key), kind: .text, color: .textQuiet))
        }
        let actionY = bounds.height - NativeSize.toolbarHeight - NativeSpace.md
        items.append(NativeRenderItem(id: formID + ".save", rect: CGRect(x: NativeSpace.md, y: actionY, width: width / 2 - NativeSpace.xs, height: NativeSize.toolbarHeight), label: context.text("event.save"), kind: .button, fill: .fill))
        items.append(NativeRenderItem(id: formID + ".close", rect: CGRect(x: bounds.midX, y: actionY, width: width / 2 - NativeSpace.xs, height: NativeSize.toolbarHeight), label: context.text("a11y.close"), kind: .button))
        update(items: items)
    }
    func save() {
        guard !fields.values.contains(where: { ($0.currentEditor() as? NSTextView)?.hasMarkedText() == true }) else { return }
        onChange?(); onSave?()
    }
    private func activateForm(_ id: String) {
        if id == formID + ".save" { save() }
        else if id == formID + ".close" { onClose?() }
        else {
            let values = id.hasSuffix(".cycle") ? SubscriptionCycle.allCases.map(\.rawValue) : PanelCurrency.minorUnits.keys.sorted()
            let entries = values.map { value in NativeMenuEntry(id: value, title: id.hasSuffix(".cycle") ? context.text("sub.cycle_" + value) : value, checked: id.hasSuffix(".cycle") ? cycle.rawValue == value : currency == value) }
            retainedMenu?.dispose()
            retainedMenu = NativeMenu(items: entries) { [weak self] selected in
                guard let self else { return }
                if id.hasSuffix(".cycle"), let cycle = SubscriptionCycle(rawValue: selected) { self.cycle = cycle } else { self.currency = selected }
                self.onChange?()
            }
            if let rect = items.first(where: { $0.id == id })?.rect { retainedMenu?.menu.popUp(positioning: nil, at: CGPoint(x: rect.minX, y: rect.maxY), in: self) }
        }
    }
    @objc private func dateChanged() { onChange?() }
    func controlTextDidChange(_ notification: Notification) { onChange?() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) { guard !textView.hasMarkedText() else { return false }; onClose?(); return true }
        if selector == #selector(NSResponder.insertNewline(_:)) { guard !textView.hasMarkedText() else { return false }; save(); return true }
        return false
    }
}
