import AppKit

enum NotesSaveState: Equatable { case saved, saving, failed, demo }

/// Stable notes surface. The shared editor owns native text Undo/IME/selection; Presentation
/// owns coalescing and durability. Parking this controller never replaces either session.
@MainActor final class NotesPanelController: PanelController {
    let panelID: PanelID = .notes
    let surface: NotesPanelView
    var view: NSView { surface }
    let scroll = OverflowScrollView(frame: .zero)
    private(set) var saveState: NotesSaveState = .saved
    private let context: BoardScreenContext
    private let lifetime = ScreenLifetime()
    private var variant: SlotVariant = .tall
    private var heightStep: PanelSizeStep = .regular
    private var slot: SlotID?
    private var rendering = false
    private var disposed = false
    private var parked = false
    private var retrying = false
    private var notesFailure: AppFailure?

    init(context: BoardScreenContext) {
        self.context = context
        surface = NotesPanelView(focus: context.focus)
        surface.setAccessibilityIdentifier("notes-panel")
        context.bindPanelMenus(to: surface)
        scroll.setAccessibilityIdentifier("notes-scroll")
        scroll.hasHorizontalScroller = false
        surface.addSubview(scroll)
        surface.onLayout = { [weak self] in self?.layout() }
        surface.onVisibilityChanged = { [weak self] hidden in
            guard let self else { return }
            if hidden { self.context.focus.unregister(owner: self); self.clearEditorCommand() } else { self.layout() }
        }
        surface.onAction = { [weak self] id in
            guard id == "notes-retry", let self, !self.retrying else { return }
            Task { @MainActor [weak self] in _ = await self?.retry() }
        }
        lifetime.own(context.presentation.subscribe { [weak self] change in
            guard let self else { return }
            guard !change.domains.isDisjoint(with: [.board, .environment, .drafts, .pending, .error, .activity]) else { return }
            if change.domains.contains(.error), change.affected.contains(.notes) || self.context.presentation.state.lastError?.field == .notes {
                self.notesFailure = self.context.presentation.state.lastError
            }
            if !self.parked { self.render() }
        })
    }
    func setVariant(_ variant: SlotVariant) { guard self.variant != variant else { return }; self.variant = variant; if !parked { layout() } }
    func setPlacement(slot: SlotID?, variant: SlotVariant) {
        self.slot = slot
        parked = slot == nil
        if parked { context.focus.unregister(owner: self); clearEditorCommand() }
        setVariant(variant); surface.isHidden = slot == nil
        if slot != nil { refresh() }
    }
    func setPlacement(_ placement: PanelPlacement) {
        heightStep = placement.heightStep
        variant = placement.shape == .wide ? .wide : .tall
        setPlacement(slot: placement.slot, variant: variant)
    }
    func reveal(_ target: PanelReveal) {
        if case .scrollTo(let id) = target, id.rawValue != "notes-input" { return }
        parked = false; surface.isHidden = false; refresh()
        context.editors.textView.window?.makeFirstResponder(context.editors.textView)
    }
    func refresh() { render() }
    private func render() {
        guard !disposed, !rendering, !parked else { return }
        let state = context.presentation.state
        let draft = state.drafts[.notes]?.textValue
        let pending = state.pending.contains { $0.affected.contains(.notes) }
        let unknown = state.pending.contains { $0.affected.contains(.notes) && $0.phase == .unknown }
        let failure = notesFailure
        if unknown { saveState = .failed }
        else if failure != nil, !retrying, !pending { saveState = .failed }
        else if draft != nil || pending || retrying { saveState = .saving }
        else if state.snapshot.storage == .demoMemory { saveState = .demo }
        else if state.snapshot.storage == .protected || state.snapshot.storage == .unavailable { saveState = .failed }
        else { saveState = .saved }
        if surface.theme.appearance != state.snapshot.environment.resolvedAppearance { surface.theme = NativeTheme(appearance: state.snapshot.environment.resolvedAppearance) }
        surface.setAccessibilityLabel(context.text("notes.title"))
        layout()
    }
    private func layout() {
        guard !disposed, !rendering, !parked else { return }
        rendering = true; defer { rendering = false }
        // Programmatic mounting/geometry can notify the native selection delegate. Those
        // notifications are not user edits; keep the existing publisher for actual input.
        let publishDraft = context.editors.onDraft
        context.editors.onDraft = nil
        defer { context.editors.onDraft = publishDraft }
        let state = context.presentation.state
        let width = surface.bounds.width, height = surface.bounds.height
        let metrics = NativePanelStepMetrics(panel: panelID, shape: variant == .wide ? .wide : .rail, step: heightStep)
        let tiny = heightStep == .tiny
        // Notes' approved 46pt header/18pt sides/12pt bottom apply to both shapes.
        let header = tiny || heightStep == .small ? metrics.headerHeight : NativeSize.toolbarHeight + NativeSpace.lg
        let headerTop = tiny ? 0 : NativeSpace.sm
        let controlHeight = min(NativeSize.compactTarget, header)
        let inset = metrics.horizontalPadding, usable = max(0, width - inset * 2)
        let retryWidth = saveState == .failed ? min(usable / 3, (context.text("error.retry_action") as NSString).size(withAttributes: [.font: NativeFont.toolbar]).width + NativeSpace.lg) : 0
        let statusKey: String
        switch saveState { case .saved: statusKey = "notes.saved"; case .saving: statusKey = "notes.saving"; case .failed: statusKey = "notes.retry"; case .demo: statusKey = "notes.demo_saved" }
        let status = context.text(statusKey)
        let statusWidth = min(usable / 2, (status as NSString).size(withAttributes: [.font: NativeFont.badge]).width + NativeSpace.sm)
        var items = [
            NativeRenderItem(id: "notes-title", rect: CGRect(x: inset, y: headerTop, width: max(0, usable - statusWidth - retryWidth - NativeSpace.sm), height: controlHeight), label: context.text("notes.title"), kind: .text),
            NativeRenderItem(id: "notes-status", rect: CGRect(x: width - inset - retryWidth - statusWidth, y: headerTop, width: statusWidth, height: controlHeight), label: status, kind: .text, color: saveState == .failed ? .danger : .textSecondary)
        ]
        if saveState == .failed {
            items.append(NativeRenderItem(id: "notes-retry", rect: CGRect(x: width - inset - retryWidth, y: headerTop, width: retryWidth, height: controlHeight), label: context.text("error.retry_action"), kind: .button, enabled: !retrying, color: .accentBlue, minimumTarget: controlHeight))
        }
        if let slot {
            items[0] = NativePanelHeader.decorate(items[0], geometry: PanelHeaderGeometry(slot: slot, titleRect: items[0].rect,
                headerRect: metrics.regions(in: surface.bounds, headerHeight: header).headerRect,
                excludedRects: items.filter { $0.id == "notes-status" || $0.id == "notes-retry" }.map(\.hitRect)))
        }
        var errorHeight: CGFloat = 0
        if saveState == .failed, let failure = notesFailure {
            errorHeight = NativeSize.toolbarHeight
            items.append(NativeRenderItem(id: "notes-error", rect: CGRect(x: inset, y: max(header, height - errorHeight - NativeSpace.xs), width: usable, height: errorHeight), label: context.text(failure.messageKey, values: failure.values), kind: .text, color: .danger))
        }
        scroll.frame = CGRect(x: inset, y: header, width: usable, height: max(0, height - header - errorHeight - (tiny ? metrics.bottomPadding : NativeSpace.md)))
        let editor = context.editors.textView
        let text = state.drafts[.notes]?.textValue?.text ?? state.snapshot.board.notes
        if context.editors.key != .notes || editor.superview !== scroll.contentView {
            context.editors.attach(to: scroll.contentView, rect: CGRect(origin: .zero, size: scroll.contentSize), key: .notes, text: text)
            // attach defers during marked text. Do not force a reparent around the shared IME guard.
            if editor.superview === scroll.contentView { scroll.documentView = editor }
        }
        if editor.superview === scroll.contentView {
            context.editors.onCommand = { [weak self] key, command in
                guard let self, key == .notes, !self.disposed, !self.parked, !self.surface.isHiddenOrHasHiddenAncestor,
                      self.context.editors.key == .notes, self.context.editors.textView.superview === self.scroll.contentView else { return false }
                guard command == #selector(NSResponder.insertTab(_:)) || command == #selector(NSResponder.insertBacktab(_:)) else { return false }
                let id = FocusID("notes-input")
                self.context.focus.focus(id)
                self.context.focus.move(forward: command == #selector(NSResponder.insertTab(_:)))
                return self.context.focus.focusedID != id
            }
            editor.setAccessibilityLabel(context.text("notes.title"))
            editor.setAccessibilityHelp(context.text("notes.placeholder"))
            let textColor = surface.theme.color(.textPrimary)
            if editor.textColor != textColor { editor.textColor = textColor }
            if editor.insertionPointColor != textColor { editor.insertionPointColor = textColor }
            editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
            editor.autoresizingMask = [.width]
            editor.minSize = NSSize(width: 0, height: scroll.contentSize.height)
            editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            editor.textContainer?.widthTracksTextView = true
            editor.textContainer?.heightTracksTextView = false
            let lineHeight = metrics.notesLineHeight
            let changedLineHeight = !editor.hasMarkedText() && editor.defaultParagraphStyle?.minimumLineHeight != lineHeight
            if changedLineHeight {
                let paragraph = (editor.defaultParagraphStyle?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
                paragraph.minimumLineHeight = lineHeight; paragraph.maximumLineHeight = lineHeight
                editor.defaultParagraphStyle = paragraph
                if let storage = editor.textStorage, storage.length > 0 {
                    storage.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: storage.length))
                }
            }
            let currentWidth = max(0, scroll.contentSize.width)
            let resized = editor.frame.width != currentWidth
            if resized { editor.setFrameSize(NSSize(width: currentWidth, height: max(editor.frame.height, scroll.contentSize.height))) }
            // Exact source bytes, native Undo and selection survive every active/marked session.
            let changedBase = state.drafts[.notes] == nil && editor.string != state.snapshot.board.notes
            if state.drafts[.notes] == nil { context.editors.setTextIfIdle(state.snapshot.board.notes) }
            if resized || changedBase || changedLineHeight { editor.sizeToFit() }
            if editor.frame.height < scroll.contentSize.height { editor.setFrameSize(NSSize(width: currentWidth, height: scroll.contentSize.height)) }
            if editor.string.isEmpty {
                items.append(NativeRenderItem(id: "notes-placeholder", rect: scroll.frame.insetBy(dx: NativeSpace.xxs, dy: NativeSpace.xxs), label: context.text("notes.placeholder"), kind: .text, color: .textQuiet))
            }
        }
        surface.update(items: items); scroll.updateFade(); registerEditorFocus()
    }
    private func registerEditorFocus() {
        let editor = context.editors.textView
        guard !disposed, !parked, !surface.isHiddenOrHasHiddenAncestor, editor.window != nil,
              context.editors.key == .notes, editor.superview === scroll.contentView else {
            context.focus.unregister(owner: self); return
        }
        let id = FocusID("notes-input")
        var target = FocusCoordinator.Target(id: id, rect: scroll.frame, activate: { [weak editor] in editor?.window?.makeFirstResponder(editor) })
        target.reveal = { [weak self] in if let self { self.surface.scrollToVisible(self.scroll.frame) } }
        target.focusChanged = { [weak self, weak editor] in
            guard let self, let editor, self.context.focus.focusedID == id, editor.window?.firstResponder !== editor else { return }
            editor.window?.makeFirstResponder(editor)
        }
        context.focus.register(owner: self, targets: [target])
    }
    private func clearEditorCommand() {
        if context.editors.key == .notes, context.editors.textView.superview === scroll.contentView { context.editors.onCommand = nil }
    }
    /// Caller keeps the controller parked on failure/BUSY_RETRY and may retry after composition commits.
    /// The same method is awaited before board hide, slot parking and application termination.
    @discardableResult func prepareForHiding() async -> CommandReceipt {
        let receipt = await context.presentation.flushNotes()
        if case .failure(let failure, _) = receipt, failure.code != .busyRetry { notesFailure = failure }
        render(); return receipt
    }
    @discardableResult func retry() async -> CommandReceipt {
        guard !retrying else { return .failure(AppFailure(code: .busyRetry, field: .notes, retryable: true), snapshot: nil) }
        retrying = true; render()
        if let unknown = context.presentation.state.pending.first(where: { $0.affected.contains(.notes) && $0.phase == .unknown }) {
            context.presentation.send(.reconcile(unknown.id))
        }
        let receipt = await context.presentation.flushNotes()
        retrying = false; render(); return receipt
    }
    func dispose() {
        guard !disposed else { return }; disposed = true
        context.focus.unregister(owner: self); clearEditorCommand()
        lifetime.dispose(); surface.onLayout = nil; surface.onVisibilityChanged = nil; surface.dispose(); scroll.dispose()
        if context.editors.textView.superview === scroll.contentView { context.editors.detach() }
    }
}

@MainActor final class NotesPanelView: PanelContainerView {
    var onLayout: (@MainActor () -> Void)?
    var onVisibilityChanged: (@MainActor (Bool) -> Void)?
    override func layout() { super.layout(); onLayout?() }
    override func viewDidHide() { super.viewDidHide(); onVisibilityChanged?(true) }
    override func viewDidUnhide() { super.viewDidUnhide(); onVisibilityChanged?(false) }
    override func paint(_ item: NativeRenderItem) {
        guard item.kind != .button else { super.paint(item); return }
        if item.panelHeader != nil { var feedback = item; feedback.label = ""; super.paint(feedback) }
        let font = item.id == "notes-title" ? NativeFont.sectionHead : item.id == "notes-placeholder" ? NativeFont.body : NativeFont.badge
        var rect = item.rect.insetBy(dx: 0, dy: NativeSpace.xxs)
        if item.id == "notes-title" {
            let icon = CGRect(x: rect.minX, y: rect.minY, width: NativeSpace.lg, height: NativeSpace.lg)
            theme.tint(.purple).setStroke()
            let path = NSBezierPath(roundedRect: icon.insetBy(dx: NativeSpace.xxs, dy: NativeSpace.xxs), xRadius: NativeSpace.xxs, yRadius: NativeSpace.xxs)
            path.lineWidth = 1; path.stroke()
            for offset in [NativeSpace.sm, NativeSpace.md] {
                let line = NSBezierPath(); line.move(to: CGPoint(x: icon.minX + NativeSpace.xs, y: icon.minY + offset)); line.line(to: CGPoint(x: icon.maxX - NativeSpace.xs, y: icon.minY + offset)); line.stroke()
            }
            rect.origin.x += NativeSpace.lg + NativeSpace.xs; rect.size.width = max(0, rect.width - NativeSpace.lg - NativeSpace.xs)
        }
        (item.label as NSString).draw(in: rect, withAttributes: NativeFont.attributes(font: font, color: theme.color(item.color)))
    }
}
