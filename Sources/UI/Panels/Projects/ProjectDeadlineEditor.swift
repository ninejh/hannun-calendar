import AppKit

/// Nonmodal form: the platform owns text/IME/date editing; the kit owns the surface/actions.
@MainActor final class ProjectDeadlineEditor: NSObject, NSTextFieldDelegate, NSPopoverDelegate {
    enum Kind { case project, countdown }
    let context: BoardScreenContext
    let kind: Kind
    let id: UUID
    let titleField: NativeTextField
    let datePicker: NativeDatePicker
    let surface: PanelContainerView
    let popover = NSPopover()
    private let host = NSViewController()
    private var commit: (@MainActor (String, DateOnly?, ProjectStatus) -> OperationHandle?)?
    var onClose: (@MainActor () -> Void)?
    private(set) var validationKey: String?
    private var failure: AppFailure?
    private var operation: UUID?
    private var pending = false
    private var targetEnabled: Bool
    private var status: ProjectStatus
    private let creating: Bool
    private var statusMenu: NativeMenu?
    private var disposed = false
    var draftKey: DraftKey { kind == .project ? .project(id) : .countdown(id) }
    init(context: BoardScreenContext, kind: Kind, id: UUID, title: String, day: DateOnly?, status: ProjectStatus = .active, creating: Bool,
         commit: @escaping @MainActor (String, DateOnly?, ProjectStatus) -> OperationHandle?) {
        self.context = context; self.kind = kind; self.id = id; self.creating = creating; self.commit = commit
        self.status = status; targetEnabled = day != nil || kind == .countdown
        let titleKey = kind == .project ? "projects.field_name" : "deadlines.field_title"
        let dateKey = kind == .project ? "projects.field_target" : "deadlines.field_date"
        titleField = NativeTextField(label: context.text(titleKey), identifier: "management.\(id).title")
        datePicker = NativeDatePicker(label: context.text(dateKey), identifier: "management.\(id).date", timeZone: TimeZone(identifier: context.presentation.state.snapshot.environment.timeZone) ?? .current)
        surface = PanelContainerView(frame: CGRect(x: 0, y: 0, width: NativeSize.popoverWidth, height: NativeSize.popoverWidth - NativeSpace.xxl), focus: context.focus)
        super.init()
        titleField.stringValue = context.presentation.state.drafts[draftKey]?.textValue?.text ?? title
        datePicker.day = day ?? ManagementCopy.tomorrow(context.presentation.state.snapshot.clock.today)
        titleField.delegate = self; titleField.target = self; titleField.action = #selector(submitAction)
        datePicker.target = self; datePicker.action = #selector(dateChanged)
        surface.addSubview(titleField); surface.addSubview(datePicker)
        surface.onAction = { [weak self] action in self?.act(action) }
        surface.onShortcut = { [weak self] event in
            guard event.keyCode == 53 else { return false }; self?.close(); return true
        }
        host.view = surface; popover.contentViewController = host; popover.behavior = .transient; popover.delegate = self
        popover.animates = false // Kit opacity supplies the approved fade; no system zoom.
        render()
    }
    func show(relativeTo rect: CGRect, of view: NSView) {
        guard view.window != nil else { return }
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        surface.window?.makeFirstResponder(titleField); titleField.selectText(nil)
        if let layer = surface.layer { NativeMotion.apply(.popover, to: layer, reduceMotion: context.presentation.state.snapshot.environment.reduceMotion) }
    }
    func refreshEnvironment() {
        if datePicker.currentEditor() == nil {
            let day = datePicker.day
            let zone = TimeZone(identifier: context.presentation.state.snapshot.environment.timeZone) ?? .current
            datePicker.timeZone = zone
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone; datePicker.calendar = calendar
            datePicker.day = day
        }
        render()
    }
    private func render() {
        let environment = context.presentation.state.snapshot.environment
        if surface.theme.appearance != environment.resolvedAppearance { surface.theme = NativeTheme(appearance: environment.resolvedAppearance) }
        surface.reduceMotion = environment.reduceMotion
        let width = surface.bounds.width, inset = NativeSpace.xl, line = NativeSize.compactTarget
        titleField.setAccessibilityLabel(context.text(kind == .project ? "projects.field_name" : "deadlines.field_title"))
        datePicker.setAccessibilityLabel(context.text(kind == .project ? "projects.field_target" : "deadlines.field_date"))
        titleField.frame = CGRect(x: inset, y: line * 2, width: width - inset * 2, height: line)
        datePicker.frame = CGRect(x: inset, y: line * 4, width: width - inset * 2, height: line)
        datePicker.isHidden = !targetEnabled
        let headline = creating ? (kind == .project ? "projects.new_title" : "deadlines.new_title") : (kind == .project ? "projects.rename" : "deadlines.rename")
        let titleKey = kind == .project ? "projects.field_name" : "deadlines.field_title"
        var items = [NativeRenderItem(id: "management.heading", rect: CGRect(x: inset, y: NativeSpace.sm, width: width - inset * 2, height: line), label: context.text(headline), kind: .text),
                     NativeRenderItem(id: "management.title.label", rect: CGRect(x: inset, y: line, width: width - inset * 2, height: line), label: context.text(titleKey), kind: .text),
                     NativeRenderItem(id: "management.date.toggle", rect: CGRect(x: inset, y: line * 3, width: width - inset * 2, height: line), label: context.text(kind == .project ? "projects.target_date_optional" : "deadlines.field_date"), kind: kind == .project ? .checkBox : .text, checked: targetEnabled)]
        if creating && kind == .project {
            items.append(NativeRenderItem(id: "management.status", rect: CGRect(x: inset, y: line * 5 + NativeSpace.xs, width: width - inset * 2, height: line), label: context.text(ManagementCopy.status(status)), kind: .button, fill: .projectStatusBg))
        }
        if let key = validationKey ?? failure?.messageKey {
            items.append(NativeRenderItem(id: "management.error", rect: CGRect(x: inset, y: line * 6 + NativeSpace.sm, width: width - inset * 2, height: line * 2), label: context.text(key), kind: .text, color: .danger))
        }
        let buttonY = surface.bounds.height - line - inset
        items.append(NativeRenderItem(id: "management.cancel", rect: CGRect(x: inset, y: buttonY, width: line * 3, height: line), label: context.text("event.cancel"), kind: .button))
        let key = pending ? "loading.label" : failure != nil ? "error.retry_action" : creating ? (kind == .project ? "projects.submit_add" : "deadlines.submit_add") : "event.save_changes"
        items.append(NativeRenderItem(id: "management.submit", rect: CGRect(x: width / 2, y: buttonY, width: width / 2 - inset, height: line), label: context.text(key), kind: .button, enabled: !pending, fill: .fill, color: .toastText))
        surface.update(items: items)
    }
    private func act(_ action: String) {
        switch action {
        case "management.cancel": close()
        case "management.submit": submit()
        case "management.date.toggle" where kind == .project: targetEnabled.toggle(); render()
        case "management.status":
            statusMenu?.dispose()
            let menu = NativeMenu(items: ProjectStatus.allCases.map { NativeMenuEntry(id: $0.rawValue, title: context.text(ManagementCopy.status($0)), checked: $0 == status) }) { [weak self] raw in
                guard let self, let value = ProjectStatus(rawValue: raw) else { return }; self.status = value; self.render()
            }
            statusMenu = menu
            if let item = surface.items.first(where: { $0.id == action }), surface.window != nil { menu.menu.popUp(positioning: nil, at: CGPoint(x: item.rect.minX, y: item.rect.maxY), in: surface) }
        default: break
        }
    }
    @objc private func submitAction() { submit() }
    @objc private func dateChanged() { validationKey = nil; render() }
    func controlTextDidChange(_ obj: Notification) {
        validationKey = nil
        let editor = titleField.currentEditor() as? NSTextView
        context.presentation.setDraft(draftKey, value: .text(TextDraft(text: titleField.stringValue, selection: editor?.selectedRange() ?? NSRange(location: 0, length: 0), markedRange: editor?.hasMarkedText() == true ? editor?.markedRange() : nil)))
        render()
    }
    func submit() {
        guard !pending, !disposed else { return }
        guard (titleField.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        let title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { validationKey = "error.empty_name"; render(); return }
        guard title.count <= 500 else { validationKey = "error.validation_failed"; render(); return }
        let day = targetEnabled ? datePicker.day : nil
        guard kind != .countdown || day != nil else { validationKey = "error.invalid_date"; render(); return }
        if failure?.committed == .unknown, let operation { context.presentation.send(.reconcile(operation)); return }
        guard let handle = commit?(title, day, status) else { failure = context.presentation.state.lastError; render(); return }
        operation = handle.id; pending = true; failure = nil; validationKey = nil; render()
        Task { [weak self] in
            let receipt = await handle.settled.value
            guard let self, !self.disposed else { return }
            self.pending = false
            switch receipt {
            case .success: self.context.presentation.clearDraft(self.draftKey); self.close()
            case .failure(let failure, _):
                self.failure = failure
                if failure.committed == .yes { self.context.presentation.clearDraft(self.draftKey); self.close() } else { self.render() }
            }
        }
    }
    func popoverDidClose(_ notification: Notification) { onClose?() }
    func close() { popover.close(); onClose?() }
    func dispose() {
        guard !disposed else { return }; disposed = true
        popover.delegate = nil; popover.close(); onClose = nil; commit = nil; statusMenu?.dispose(); statusMenu = nil
        titleField.delegate = nil; titleField.target = nil; datePicker.target = nil; surface.dispose()
    }
}
