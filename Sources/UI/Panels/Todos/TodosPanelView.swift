import AppKit

/// Shared native text sessions for the two T-027 inline lists.
@MainActor class TextListPanelView: EditingPanelView, NSTextFieldDelegate {
    let isHabit: Bool
    let input: NativeTextField
    private var inputID = UUID()
    private(set) var editor: PanelEditingForm?
    private var editingID: UUID?
    private var formPending: UUID?
    private var cachedEditor: PanelEditingForm?
    private var cachedID: UUID?
    private var inlineInputExpanded = false
    var titleKey: String { isHabit ? "habits.title" : "todo.title" }
    var placeholderKey: String { isHabit ? "habits.add_inline_placeholder" : "todo.add_placeholder" }
    override var panelPrefix: String { isHabit ? "habits" : "todos" }
    override var panelID: PanelID { isHabit ? .habits : .todos }
    private var inputFocusID: FocusID { FocusID(panelPrefix + ".add.input") }
    var tinyRail: Bool { stepMetrics.step == .tiny && stepMetrics.shape == .rail }
    private var inputHeight: CGFloat {
        isCompactStep ? (NativePanelStepMetrics(panel: .todos, shape: stepMetrics.shape, step: stepMetrics.step).listRow?.height ?? NativeSize.compactTarget) : NativeSize.compactTarget
    }
    override var headerHeight: CGFloat {
        if isCompactStep && variant == .wide { return super.headerHeight }
        if tinyRail && !inlineInputExpanded { return super.headerHeight }
        return super.headerHeight + (isCompactStep ? inputHeight : NativeSize.toolbarHeight) + NativeSpace.xs
    }
    override var headerExcludedRects: [CGRect] { input.isHidden ? [] : [input.frame] }
    var titleRect: CGRect {
        let width = isCompactStep && variant == .wide ? max(0, input.frame.minX - horizontalPadding) : max(0, bounds.width - horizontalPadding * 2 - (tinyRail ? NativeSize.compactTarget : 0))
        return CGRect(x: horizontalPadding, y: headerItemY, width: width, height: headerItemHeight)
    }
    func addItems() -> [NativeRenderItem] {
        guard tinyRail else { return [] }
        return [NativeRenderItem(id: panelPrefix + ".add", rect: CGRect(x: bounds.width - horizontalPadding - NativeSize.compactTarget, y: headerItemY, width: NativeSize.compactTarget, height: headerItemHeight), label: context.text(placeholderKey), kind: .button)]
    }
    init(context: BoardScreenContext, isHabit: Bool) {
        self.isHabit = isHabit
        input = NativeTextField(label: context.text(isHabit ? "habits.add_inline_placeholder" : "todo.add_placeholder"), identifier: isHabit ? "habits.add.input" : "todos.add.input")
        super.init(context: context)
        input.delegate = self; input.placeholderString = context.text(placeholderKey); addSubview(input)
        setAccessibilityIdentifier(panelPrefix); setAccessibilityLabel(context.text(titleKey))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    func draftKey(_ id: UUID) -> DraftKey { isHabit ? .habit(id) : .todo(id) }
    override func layout() {
        if tinyRail && (!input.stringValue.isEmpty || input.currentEditor() != nil) { inlineInputExpanded = true }
        input.isHidden = tinyRail && !inlineInputExpanded
        if isCompactStep {
            let width = variant == .wide ? max(0, bounds.width / 2 - horizontalPadding) : max(0, bounds.width - horizontalPadding * 2)
            input.frame = CGRect(x: variant == .wide ? bounds.width / 2 : horizontalPadding,
                y: variant == .wide ? max(0, (headerRowHeight - inputHeight) / 2) : headerRowHeight + NativeSpace.xxs,
                width: width, height: inputHeight)
        } else {
            input.frame = CGRect(x: NativeSpace.md, y: NativeSize.toolbarHeight + NativeSpace.md, width: max(0, bounds.width - NativeSpace.xxl), height: NativeSize.compactTarget)
        }
        super.layout()
    }
    override func updateHeader(_ items: [NativeRenderItem]) {
        super.updateHeader(items)
        registerInputFocus()
    }
    private func registerInputFocus() {
        guard !isHiddenOrHasHiddenAncestor, !input.isHidden, input.isEnabled, input.window != nil, !lifetime.isDisposed else {
            context.focus.unregister(owner: input); return
        }
        let id = inputFocusID
        var target = FocusCoordinator.Target(id: id, rect: input.frame, activate: { [weak input] in input?.window?.makeFirstResponder(input) })
        target.reveal = { [weak input] in if let input { input.scrollToVisible(input.bounds) } }
        target.focusChanged = { [weak self] in
            guard let self, self.context.focus.focusedID == id, self.input.currentEditor() == nil else { return }
            self.input.window?.makeFirstResponder(self.input)
        }
        // This view already owns the painted header scope. The native control needs its own owner.
        context.focus.register(owner: input, targets: [target])
    }
    override func viewDidHide() { context.focus.unregister(owner: input); super.viewDidHide() }
    override func viewDidUnhide() { super.viewDidUnhide(); registerInputFocus() }
    override func commonAction(_ id: String) -> Bool {
        if id == panelPrefix + ".add" {
            inlineInputExpanded = true; needsLayout = true; layoutSubtreeIfNeeded()
            window?.makeFirstResponder(input); return true
        }
        return super.commonAction(id)
    }
    override func render() {
        super.render()
        input.placeholderString = context.text(placeholderKey); input.setAccessibilityLabel(context.text(placeholderKey))
        editor?.refresh()
    }
    func controlTextDidChange(_ notification: Notification) {
        let text = input.currentEditor() as? NSTextView
        context.presentation.setDraft(draftKey(inputID), value: .text(TextDraft(text: input.stringValue, selection: text?.selectedRange() ?? NSRange(location: 0, length: 0), markedRange: text?.hasMarkedText() == true ? text?.markedRange() : nil)))
    }
    func controlTextDidBeginEditing(_ notification: Notification) {
        if notification.object as? NativeTextField === input { context.focus.focus(inputFocusID) }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if textView.hasMarkedText() { return false }
        if selector == #selector(NSResponder.insertTab(_:)) || selector == #selector(NSResponder.insertBacktab(_:)) {
            context.focus.focus(inputFocusID)
            context.focus.move(forward: selector == #selector(NSResponder.insertTab(_:)))
            return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)) { addInput(); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) { context.presentation.clearDraft(draftKey(inputID)); input.stringValue = ""; return true }
        return false
    }
    func addInput() {
        guard (input.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        let text = input.stringValue
        let id = inputID
        let intent: PanelIntent = isHabit ? .createHabit(id, text) : .createTodo(id, text)
        do { _ = try PanelDomain.apply(intent, to: snapshot.board, now: snapshot.clock.now, today: snapshot.clock.today) }
        catch { showStatus("error.validation"); return }
        statusKey = nil
        context.presentation.setDraft(draftKey(id), value: .text(TextDraft(text: text)))
        guard let handle = edit(intent) else { return }
        input.stringValue = ""; inputID = UUID()
        Task { @MainActor [weak self] in
            let result = await handle.settled.value
            guard let self else { return }
            if case .success = result { self.context.presentation.clearDraft(self.draftKey(id)) }
            else if case .failure(let failure, _) = result, failure.committed == .no, self.input.stringValue.isEmpty,
                    (self.input.currentEditor() as? NSTextView)?.hasMarkedText() != true {
                self.inputID = id; self.input.stringValue = text
            }
            self.render()
        }
    }
    func openTextEditor(id: UUID, title: String) {
        guard editor == nil else { return }
        editingID = id
        if cachedID == id, let cachedEditor {
            editor = cachedEditor; self.cachedEditor = nil; cachedID = nil
            cachedEditor.present(from: self); return
        }
        if let cachedID { context.presentation.clearDraft(draftKey(cachedID)) }
        cachedEditor?.dispose(); cachedEditor = nil; cachedID = nil
        let text = context.presentation.state.drafts[draftKey(id)]?.textValue?.text ?? title
        let form = PanelEditingForm(context: context, id: panelPrefix + ".form", titleKey: titleKey, fields: [("title", isHabit ? "habits.field_name" : "todo.add_placeholder", text)])
        editor = form
        form.onChange = { [weak self, weak form] in
            guard let self, let field = form?.fields["title"] else { return }
            let editor = field.currentEditor() as? NSTextView
            self.context.presentation.setDraft(self.draftKey(id), value: .text(TextDraft(text: field.stringValue, selection: editor?.selectedRange() ?? NSRange(location: 0, length: 0), markedRange: editor?.hasMarkedText() == true ? editor?.markedRange() : nil)))
        }
        form.onSave = { [weak self] in self?.saveTextEditor() }
        form.onClose = { [weak self] in self?.closeTextEditor() }
        form.present(from: self)
    }
    private func saveTextEditor() {
        guard formPending == nil, let id = editingID, let text = editor?.fields["title"]?.stringValue else { return }
        let intent: PanelIntent = isHabit ? .updateHabit(id, text) : .updateTodo(id, TodoPatch(title: text))
        do { _ = try PanelDomain.apply(intent, to: snapshot.board, now: snapshot.clock.now, today: snapshot.clock.today) }
        catch { editor?.errorKey = "error.validation"; editor?.refresh(); return }
        guard let handle = edit(intent) else { return }; formPending = handle.id
        Task { @MainActor [weak self] in
            let receipt = await handle.settled.value
            guard let self else { return }
            if case .success = receipt {
                self.formPending = nil
                if self.editingID == id, self.editor?.fields["title"]?.stringValue == text {
                    self.context.presentation.clearDraft(self.draftKey(id)); self.closeTextEditor()
                }
            } else if case .failure(let failure, _) = receipt {
                if failure.committed != .unknown { self.formPending = nil }
                self.editor?.errorKey = failure.messageKey; self.editor?.refresh()
            }
        }
    }
    func closeTextEditor() {
        guard let editor else { return }; editor.dismiss(); guard editor.superview == nil else { return }
        cachedEditor?.dispose(); cachedEditor = editor; cachedID = editingID
        self.editor = nil; editingID = nil
    }
    override func editorVisibilityChanged(isHidden: Bool) {
        editor?.isHidden = isHidden
        if isHidden { context.focus.unregister(owner: input) }
    }
    override func dispose() {
        context.focus.unregister(owner: input)
        editor?.dispose(); editor = nil; cachedEditor?.dispose(); cachedEditor = nil; input.delegate = nil; super.dispose()
    }
}

@MainActor final class TodosPanelView: TextListPanelView {
    init(context: BoardScreenContext) {
        super.init(context: context, isHabit: false)
        onAction = { [weak self] id in
            if self?.commonAction(id) == true { return }
            guard let self, id == "todos.collapse" else { return }
            self.send(.edit(.settings(SettingsPatch(todosCompletedCollapsed: .set(!self.snapshot.board.settings.todosCompletedCollapsed))), undoable: false))
        }
        contentCanvas.onAction = { [weak self] key in
            if self?.commonAction(key) == true { return }
            guard let self, let id = Self.id(key), let value = self.snapshot.board.todos.first(where: { $0.id == id }) else { return }
            if key.hasSuffix(".check") {
                self.edit(.updateTodo(id, TodoPatch(completed: !value.completed)))
                self.layoutSubtreeIfNeeded()
                if value.completed { self.contentCanvas.stopFeedback() }
                else { self.contentCanvas.checkFeedback(id: key, reduceMotion: self.snapshot.environment.reduceMotion) }
            }
            else if key.hasSuffix(".delete") { self.edit(.deleteTodo(id)) }
            else { self.openTextEditor(id: id, title: value.title) }
        }
        contentCanvas.contextMenu = { [weak self] key in
            guard let self, let id = Self.id(key), let value = self.snapshot.board.todos.first(where: { $0.id == id }) else { return nil }
            return self.menu(entries: [
                NativeMenuEntry(id: "edit", title: self.context.text("item.edit_label", values: ["0": value.title])),
                NativeMenuEntry(id: "delete", title: self.context.text("item.delete_label", values: ["0": value.title]))
            ]) { [weak self] action in
                if action == "delete" { self?.edit(.deleteTodo(id)) } else { self?.openTextEditor(id: id, title: value.title) }
            }
        }
        start()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func commonAction(_ id: String) -> Bool {
        if id == "todos.collapse" {
            send(.edit(.settings(SettingsPatch(todosCompletedCollapsed: .set(!snapshot.board.settings.todosCompletedCollapsed))), undoable: false))
            return true
        }
        return super.commonAction(id)
    }
    private static func id(_ key: String) -> UUID? { key.split(separator: ".").dropFirst().first.flatMap { UUID(uuidString: String($0)) } }
    override func layoutContent() {
        let count = snapshot.board.todos.filter(\.completed).count
        let collapsed = snapshot.board.settings.todosCompletedCollapsed
        let collapse = context.text(collapsed ? "todo.expand_done" : "todo.collapse_done", values: ["0": String(count)])
        let buttonWidth = min(bounds.width * 0.67, (collapse as NSString).size(withAttributes: [.font: NativeFont.primary]).width + NativeSpace.lg)
        let collapseItem = NativeRenderItem(id: "todos.collapse", rect: CGRect(x: bounds.width - NativeSpace.md - buttonWidth, y: NativeSpace.sm, width: buttonWidth, height: NativeSize.toolbarHeight), label: collapse, kind: .button)
        let title = NativeRenderItem(id: "todos.title", rect: isCompactStep ? titleRect : CGRect(x: NativeSpace.md, y: NativeSpace.sm, width: max(0, bounds.width - buttonWidth - NativeSpace.xxl), height: NativeSize.toolbarHeight), label: context.text(titleKey), kind: .text)
        updateHeader([title] + (isCompactStep ? addItems() : [collapseItem]) + statusItems())
        let values = snapshot.board.todos.filter { !$0.completed } + (collapsed ? [] : snapshot.board.todos.filter(\.completed))
        let columns = variant == .wide ? 2 : 1
        let width = scroll.contentSize.width / CGFloat(columns)
        let rowHeight = isCompactStep ? (stepMetrics.listRow?.height ?? NativeSize.compactTarget) : NativeSize.toolbarHeight
        let gap = isCompactStep ? (stepMetrics.listRow?.gap ?? 0) : 0
        var items: [NativeRenderItem] = []
        contentCanvas.fonts = [:]; contentCanvas.struck = []; contentCanvas.displayText = [:]; contentCanvas.wrappedText = [:]
        for (index, value) in values.enumerated() {
            let key = "todo.\(value.id)"
            let x = CGFloat(index % columns) * width, y = NativeSpace.xs + CGFloat(index / columns) * (rowHeight + gap)
            items.append(NativeRenderItem(id: key + ".check", rect: CGRect(x: x, y: y, width: NativeSize.compactTarget, height: rowHeight), label: value.title, kind: .checkBox, checked: value.completed))
            contentCanvas.displayText[key + ".check"] = ""
            items.append(NativeRenderItem(id: key + ".title", rect: CGRect(x: x + NativeSize.compactTarget, y: y, width: max(0, width - NativeSize.compactTarget * 2), height: rowHeight), label: value.title, kind: .row, color: value.completed ? .textQuiet : .textPrimary))
            contentCanvas.fonts[key + ".title"] = isCompactStep ? stepMetrics.bodyFont : NativeFont.primary
            if value.completed { contentCanvas.struck.insert(key + ".title") }
            items.append(NativeRenderItem(id: key + ".delete", rect: CGRect(x: x + width - NativeSize.compactTarget, y: y, width: NativeSize.compactTarget, height: rowHeight), label: context.text("item.delete_label", values: ["0": value.title]), kind: .button, color: .textQuiet))
            contentCanvas.displayText[key + ".delete"] = "×"
        }
        if values.isEmpty { items.append(NativeRenderItem(id: "todos.empty", rect: CGRect(x: 0, y: NativeSpace.sm, width: scroll.contentSize.width, height: NativeSize.toolbarHeight), label: context.text(snapshot.board.todos.isEmpty ? "todo.empty_new" : "todo.empty"), kind: .text, color: .textQuiet)) }
        var height = CGFloat((values.count + columns - 1) / columns) * (rowHeight + gap) + NativeSpace.sm
        if values.isEmpty { height += NativeSize.toolbarHeight }
        if isCompactStep {
            var item = collapseItem; item.rect = CGRect(x: 0, y: height, width: scroll.contentSize.width, height: NativeSize.compactTarget)
            items.append(item); height = item.rect.maxY + stepMetrics.itemGap
        }
        let status = contentStatusItems(at: height); items += status
        height = max(height, status.map(\.rect.maxY).max() ?? height)
        contentCanvas.frame.size = CGSize(width: scroll.contentSize.width, height: max(scroll.contentSize.height, height))
        contentCanvas.update(items: items)
    }
}
