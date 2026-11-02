import AppKit

@MainActor private final class ProjectDeadlineSurface: PanelContainerView {
    var showSelector: (@MainActor (String) -> Bool)?
    override func showMenu(for id: String) -> Bool { showSelector?(id) ?? false }
    override func paint(_ item: NativeRenderItem) {
        guard item.id == "management.heading" || item.id == "management.error" else { super.paint(item); return }
        let rect = item.rect.insetBy(dx: NativeSpace.sm, dy: 0)
        (item.label as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading],
                                      attributes: NativeFont.attributes(font: NativeFont.primary, color: theme.color(item.color), truncation: .byWordWrapping))
    }
}

/// Nonmodal form: the platform owns text/IME/date editing; the kit owns the surface/actions.
@MainActor final class ProjectDeadlineEditor: NSObject, NSTextFieldDelegate, NSPopoverDelegate {
    enum Kind { case project, countdown }
    let context: BoardScreenContext
    let kind: Kind
    let id: UUID
    let titleField: NativeTextField
    let datePicker: NativeDatePicker
    let colorWell = NSColorWell(frame: .zero)
    let surface: PanelContainerView
    let popover = NSPopover()
    private let host = NSViewController()
    private let scroll = OverflowScrollView(frame: .zero)
    private var availableFrame = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
    private var windowObservations: [NSObjectProtocol] = []
    private var commit: (@MainActor (String, DateOnly?, ProjectStatus) -> OperationHandle?)?
    var onClose: (@MainActor () -> Void)?
    private(set) var validationKey: String?
    private var failure: AppFailure?
    private var operation: UUID?
    private var pending = false
    private var targetEnabled: Bool
    private var status: ProjectStatus
    private let creating: Bool
    private let initialTitle: String
    private let initialDay: DateOnly
    private let initialTargetEnabled: Bool
    private let initialStatus: ProjectStatus
    private let initialColorHex: String
    private(set) var selectedColorHex: String
    var colorWasChanged: Bool { selectedColorHex != initialColorHex }
    private var statusMenu: NativeMenu?
    private var disposed = false
    var draftKey: DraftKey { kind == .project ? .project(id) : .countdown(id) }
    init(context: BoardScreenContext, kind: Kind, id: UUID, title: String, day: DateOnly?, status: ProjectStatus = .active, colorHex: String? = nil, creating: Bool,
         commit: @escaping @MainActor (String, DateOnly?, ProjectStatus) -> OperationHandle?) {
        self.context = context; self.kind = kind; self.id = id; self.creating = creating; self.commit = commit
        let initialColor = colorHex ?? ProjectPalette.next(among: context.presentation.state.snapshot.board.projects)
        initialColorHex = initialColor; selectedColorHex = initialColor
        self.status = status; targetEnabled = day != nil || kind == .countdown
        initialTitle = title; initialStatus = status; initialTargetEnabled = day != nil || kind == .countdown
        initialDay = day ?? ManagementCopy.tomorrow(context.presentation.state.snapshot.clock.today)
        let titleKey = kind == .project ? "projects.field_name" : "deadlines.field_title"
        let dateKey = kind == .project ? "projects.field_target" : "deadlines.field_date"
        titleField = NativeTextField(label: context.text(titleKey), identifier: "management.\(id).title")
        datePicker = NativeDatePicker(label: context.text(dateKey), identifier: "management.\(id).date", timeZone: TimeZone(identifier: context.presentation.state.snapshot.environment.timeZone) ?? .current)
        surface = ProjectDeadlineSurface(frame: CGRect(x: 0, y: 0, width: NativeSize.popoverWidth, height: NativeSize.popoverWidth - NativeSpace.xxl), focus: context.focus)
        super.init()
        titleField.stringValue = context.presentation.state.drafts[draftKey]?.textValue?.text ?? title
        datePicker.day = initialDay
        titleField.delegate = self; titleField.target = self; titleField.action = #selector(submitAction)
        datePicker.target = self; datePicker.action = #selector(dateChanged)
        surface.addSubview(titleField); surface.addSubview(datePicker)
        if kind == .project {
            colorWell.color = NSColor(nativeHex: initialColor); colorWell.target = self; colorWell.action = #selector(colorChanged)
            colorWell.setAccessibilityIdentifier("management.color"); surface.addSubview(colorWell)
        }
        surface.onAction = { [weak self] action in self?.act(action) }
        (surface as? ProjectDeadlineSurface)?.showSelector = { [weak self] action in
            guard let self, action == "management.status", !self.pending, !self.disposed,
                  self.surface.window != nil,
                  self.surface.items.contains(where: { $0.id == action && $0.enabled && $0.isInteractive }),
                  (self.titleField.currentEditor() as? NSTextView)?.hasMarkedText() != true,
                  (self.datePicker.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return false }
            self.act(action)
            return true
        }
        surface.onShortcut = { [weak self] event in
            guard event.keyCode == 53, let self else { return false }
            return self.cancel()
        }
        scroll.allowsBothAxes = true; scroll.documentView = surface; host.view = scroll; popover.contentViewController = host; popover.behavior = .transient; popover.delegate = self
        popover.animates = false // Kit opacity supplies the approved fade; no system zoom.
        render()
    }
    func show(relativeTo rect: CGRect, of view: NSView) {
        guard let window = view.window else { return }
        let anchor = window.convertToScreen(view.convert(rect, to: nil))
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? window.screen
        if let screen { layoutContent(visibleFrame: screen.visibleFrame) }
        for observation in windowObservations { NotificationCenter.default.removeObserver(observation) }
        windowObservations = [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self, weak view] _ in
                MainActor.assumeIsolated {
                    guard let self, let window = view?.window, let screen = window.screen else { return }
                    self.layoutContent(visibleFrame: screen.visibleFrame)
                }
            }
        }
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
    func layoutContent(visibleFrame: CGRect) {
        availableFrame = visibleFrame; render()
    }
    private func render() {
        let environment = context.presentation.state.snapshot.environment
        if surface.theme.appearance != environment.resolvedAppearance { surface.theme = NativeTheme(appearance: environment.resolvedAppearance) }
        surface.reduceMotion = environment.reduceMotion
        let inset = NativeSpace.xl, line = NativeSize.compactTarget
        let headline = creating ? (kind == .project ? "projects.new_title" : "deadlines.new_title") : (kind == .project ? "projects.rename" : "deadlines.rename")
        let titleKey = kind == .project ? "projects.field_name" : "deadlines.field_title"
        let messages = [context.text(headline), context.text(titleKey), context.text(kind == .project ? "projects.target_date_optional" : "deadlines.field_date"),
                        titleField.stringValue, (validationKey ?? failure?.messageKey).map { context.text($0) } ?? ""]
        let naturalWidth = messages.map { ceil(($0 as NSString).size(withAttributes: [.font: NativeFont.primary]).width) }.max() ?? 0
        let availableWidth = max(1, availableFrame.width - NativeSpace.lg * 2)
        let width = min(max(NativeSize.popoverWidth, naturalWidth + inset * 2 + NativeSpace.lg), max(NativeSize.popoverWidth, availableWidth))
        titleField.setAccessibilityLabel(context.text(kind == .project ? "projects.field_name" : "deadlines.field_title"))
        datePicker.setAccessibilityLabel(context.text(kind == .project ? "projects.field_target" : "deadlines.field_date"))
        titleField.isEnabled = !pending; datePicker.isEnabled = !pending
        colorWell.isEnabled = !pending; colorWell.setAccessibilityLabel(context.text("projects.field_color"))
        datePicker.isHidden = !targetEnabled
        let bodyWidth = max(1, width - inset * 2)
        func wrapped(_ value: String) -> CGFloat {
            let attributes = NativeFont.attributes(font: NativeFont.primary, color: .labelColor, truncation: .byWordWrapping)
            return max(line, ceil((value as NSString).boundingRect(with: CGSize(width: max(1, bodyWidth - NativeSpace.lg), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes).height))
        }
        var y = NativeSpace.sm
        let heading = context.text(headline), headingHeight = wrapped(heading)
        var items = [NativeRenderItem(id: "management.heading", rect: CGRect(x: inset, y: y, width: bodyWidth, height: headingHeight), label: heading, kind: .text)]
        y += headingHeight
        items.append(NativeRenderItem(id: "management.title.label", rect: CGRect(x: inset, y: y, width: bodyWidth, height: line), label: context.text(titleKey), kind: .text)); y += line
        titleField.frame = CGRect(x: inset, y: y, width: bodyWidth, height: line); y += line
        items.append(NativeRenderItem(id: "management.date.toggle", rect: CGRect(x: inset, y: y, width: bodyWidth, height: line), label: context.text(kind == .project ? "projects.target_date_optional" : "deadlines.field_date"), kind: kind == .project ? .checkBox : .text, enabled: !pending, checked: targetEnabled)); y += line
        if targetEnabled { datePicker.frame = CGRect(x: inset, y: y, width: bodyWidth, height: line); y += line }
        if creating && kind == .project {
            y += NativeSpace.xs
            items.append(NativeRenderItem(id: "management.status", rect: CGRect(x: inset, y: y, width: bodyWidth, height: line), label: context.text(ManagementCopy.status(status)), kind: .menuButton, enabled: !pending, fill: .projectStatusBg)); y += line
        }
        if kind == .project {
            y += NativeSpace.xs
            colorWell.frame = CGRect(x: width - inset - line * 2, y: y, width: line * 2, height: line)
            items.append(NativeRenderItem(id: "management.color.label", rect: CGRect(x: inset, y: y, width: max(1, bodyWidth - line * 2), height: line), label: context.text("projects.field_color"), kind: .text)); y += line
        }
        if let key = validationKey ?? failure?.messageKey {
            y += NativeSpace.sm
            let message = context.text(key), height = wrapped(message)
            items.append(NativeRenderItem(id: "management.error", rect: CGRect(x: inset, y: y, width: bodyWidth, height: height), label: message, kind: .text, color: .danger)); y += height
        }
        let buttonY = y + NativeSpace.sm
        items.append(NativeRenderItem(id: "management.cancel", rect: CGRect(x: inset, y: buttonY, width: line * 3, height: line), label: context.text("event.cancel"), kind: .button, enabled: !pending))
        let key = pending ? "loading.label" : failure != nil ? "error.retry_action" : creating ? (kind == .project ? "projects.submit_add" : "deadlines.submit_add") : "event.save_changes"
        items.append(NativeRenderItem(id: "management.submit", rect: CGRect(x: width / 2, y: buttonY, width: width / 2 - inset, height: line), label: context.text(key), kind: .button, enabled: !pending, fill: .fill, color: .toastText))
        let contentHeight = buttonY + line + inset
        surface.frame = CGRect(x: 0, y: 0, width: width, height: contentHeight)
        scroll.frame.size = CGSize(width: min(width, availableWidth), height: min(contentHeight, max(1, availableFrame.height - NativeSpace.lg * 2)))
        popover.contentSize = scroll.frame.size
        surface.update(items: items)
        scroll.updateFade()
    }
    private func act(_ action: String) {
        guard !pending else { return }
        switch action {
        case "management.cancel": _ = cancel()
        case "management.submit": submit()
        case "management.date.toggle" where kind == .project: targetEnabled.toggle(); render()
        case "management.status":
            statusMenu?.dispose()
            let menu = NativeMenu(items: ProjectStatus.allCases.map { NativeMenuEntry(id: $0.rawValue, title: context.text(ManagementCopy.status($0)), checked: $0 == status) }) { [weak self] raw in
                guard let self, !self.pending, let value = ProjectStatus(rawValue: raw) else { return }; self.status = value; self.render()
            }
            statusMenu = menu
            if let item = surface.items.first(where: { $0.id == action }), surface.window != nil { menu.menu.popUp(positioning: nil, at: CGPoint(x: item.rect.minX, y: item.rect.maxY), in: surface) }
        default: break
        }
    }
    @objc private func submitAction() { submit() }
    @objc private func dateChanged() { validationKey = nil; render() }
    @objc private func colorChanged() {
        guard !pending, let color = colorWell.color.usingColorSpace(.sRGB) else { return }
        selectedColorHex = String(format: "%02X%02X%02X", Int((color.redComponent * 255).rounded()), Int((color.greenComponent * 255).rounded()), Int((color.blueComponent * 255).rounded()))
        render()
    }
    func controlTextDidChange(_ obj: Notification) {
        validationKey = nil
        let editor = titleField.currentEditor() as? NSTextView
        context.presentation.setDraft(draftKey, value: .text(TextDraft(text: titleField.stringValue, selection: editor?.selectedRange() ?? NSRange(location: 0, length: 0), markedRange: editor?.hasMarkedText() == true ? editor?.markedRange() : nil)))
        render()
    }
    func submit() {
        guard !pending, !disposed else { return }
        guard (titleField.currentEditor() as? NSTextView)?.hasMarkedText() != true,
              (datePicker.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        // End native field editing before capturing the submitted values, so the
        // shared field editor cannot accept keystrokes or start IME while saving.
        if let window = surface.window, !window.makeFirstResponder(surface) { return }
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
            case .success: self.context.presentation.clearDraft(self.draftKey); self.finishClose()
            case .failure(let failure, _):
                self.failure = failure
                if failure.committed == .yes { self.context.presentation.clearDraft(self.draftKey); self.finishClose() } else { self.render() }
            }
        }
    }
    var canDismiss: Bool {
        !pending && failure == nil && context.presentation.state.drafts[draftKey] == nil && !colorWell.isActive &&
        (titleField.currentEditor() as? NSTextView)?.hasMarkedText() != true &&
        (datePicker.currentEditor() as? NSTextView)?.hasMarkedText() != true &&
        titleField.stringValue == initialTitle && datePicker.day == initialDay &&
        targetEnabled == initialTargetEnabled && status == initialStatus && selectedColorHex == initialColorHex
    }
    func popoverShouldClose(_ popover: NSPopover) -> Bool { canDismiss }
    func popoverDidClose(_ notification: Notification) { onClose?() }
    @discardableResult private func cancel() -> Bool {
        // Escape belongs to the input method during composition. An admitted
        // write must settle before cancellation can discard its retry draft.
        guard !pending, (titleField.currentEditor() as? NSTextView)?.hasMarkedText() != true,
              (datePicker.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return false }
        context.presentation.clearDraft(draftKey)
        finishClose()
        return true
    }
    func close() { if canDismiss { finishClose() } }
    private func finishClose() { popover.close(); onClose?() }
    func dispose() {
        guard !disposed else { return }; disposed = true
        for observation in windowObservations { NotificationCenter.default.removeObserver(observation) }; windowObservations.removeAll()
        colorWell.deactivate(); popover.delegate = nil; popover.close(); onClose = nil; commit = nil; statusMenu?.dispose(); statusMenu = nil
        titleField.delegate = nil; titleField.target = nil; datePicker.target = nil; colorWell.target = nil; scroll.dispose(); scroll.documentView = nil; surface.dispose()
    }
}
