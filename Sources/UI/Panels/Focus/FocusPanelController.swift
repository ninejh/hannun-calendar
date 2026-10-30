import AppKit

/// The UI interpolates the native deadline, never credits intervals or submits notifications.
@MainActor final class FocusPanelController: NSObject, NSTextFieldDelegate, PanelController {
    let panelID: PanelID = .focusTimer
    private let context: BoardScreenContext
    private let surface: ClockFocusPanelSurface
    let content: ClockFocusCanvas
    let dialCanvas: ClockFocusDialCanvas
    private let fixedContent: ClockFocusCanvas
    private let viewport = OverflowScrollView(frame: .zero)
    private let focusDuration: NativeTextField
    private let breakDuration: NativeTextField
    private let lifetime = ScreenLifetime()
    private let pulseView = ClockFocusPulseView(frame: .zero)
    private var pulse: CALayer { pulseView.layer! }
    private var projectMenu: NativeMenu?
    private var slot: SlotID?
    private var variant: SlotVariant = .tall
    private var placement: PanelPlacement?
    private var compactHadFailure = false
    private var disposed = false
    private var failedOperation: UUID?
    private var failure: AppFailure?
    private var windowObserver: NSObjectProtocol?
    private var previousClock: ClockSnapshot?
    private var previousFocus: FocusProjection?
    private var observedSession: UUID?
    private var continuity = false
    private(set) var renderPassCount = 0
    private(set) var lastTickDirtyIDs: [String] = []
    private(set) var completionPulseCount = 0
    var view: NSView { surface }
    var isRendering: Bool { !disposed && slot != nil && !surface.isHiddenOrHasHiddenAncestor && (surface.window?.isVisible ?? true) }
    var remainingSeconds: Int {
        let snapshot = context.presentation.state.snapshot, focus = snapshot.focus
        if focus.status == .idle { return focus.mode == .focus ? snapshot.board.settings.focus.focusSeconds : snapshot.board.settings.focus.breakSeconds }
        guard focus.status == .running, let end = focus.endAt else { return max(0, focus.remainingSeconds) }
        return min(max(0, focus.plannedSeconds), max(0, Int(ceil(end.date.timeIntervalSince(snapshot.clock.now.date)))))
    }
    var todaySeconds: Int {
        let focus = context.presentation.state.snapshot.focus
        return focus.projectID.map { id in focus.todayByProject.first(where: { $0.projectID == id })?.seconds ?? 0 } ?? focus.unassignedTodaySeconds
    }
    private var active: Bool { let status = context.presentation.state.snapshot.focus.status; return status == .running || status == .paused }
    private func clearPartialNotice(_ top: CGFloat, height: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        guard top < viewportHeight, top + height > viewportHeight else { return top }
        return viewportHeight + NativeSpace.xs
    }
    init(context: BoardScreenContext, accessibilityNotifications: any NativeAccessibilityNotifications = SystemNativeAccessibilityNotifications()) {
        self.context = context
        surface = ClockFocusPanelSurface(focus: context.focus); content = ClockFocusCanvas(focus: context.focus, accessibilityNotifications: accessibilityNotifications)
        dialCanvas = ClockFocusDialCanvas(focus: context.focus)
        fixedContent = ClockFocusCanvas(focus: context.focus)
        content.excludedPaintIDs = ["focusTimer.time", "focusTimer.gauge"]
        fixedContent.excludedPaintIDs = ["focusTimer.time"]
        focusDuration = NativeTextField(label: context.text("timer.config_focus"), identifier: "focusTimer.duration.focus")
        breakDuration = NativeTextField(label: context.text("timer.config_break"), identifier: "focusTimer.duration.break")
        super.init()
        surface.setAccessibilityIdentifier("panel.focusTimer"); surface.setAccessibilityLabel(context.text("timer.title"))
        viewport.documentView = content; surface.addSubview(viewport); content.addSubview(focusDuration); content.addSubview(breakDuration)
        surface.addSubview(fixedContent); fixedContent.isHidden = true
        context.bindPanelMenus(to: surface)
        focusDuration.delegate = self; breakDuration.delegate = self
        content.addSubview(pulseView); content.addSubview(dialCanvas, positioned: .below, relativeTo: pulseView)
        surface.onLayout = { [weak self] in self?.render() }
        surface.onVisibility = { [weak self] in self?.visibilityChanged() }
        content.onAction = { [weak self] id in self?.activate(id) }
        fixedContent.onAction = { [weak self] id in self?.activate(id) }
        windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.visibilityChanged() }
        }
        lifetime.own(context.presentation.subscribe { [weak self] change in
            guard let self, self.isRendering else { return }
            self.observeCompletion()
            if change.domains == [.clock] { self.render(tick: true) }
            else if !change.domains.isDisjoint(with: [.board, .environment, .activity, .pending, .error]) { self.render() }
        })
    }
    func setPlacement(slot: SlotID?, variant: SlotVariant) {
        placement = nil
        self.slot = slot; self.variant = variant; surface.isHidden = slot == nil
        if !isRendering { resetObservation(); NativeMotion.stop(pulse); context.focus.unregister(owner: self) } else { observeCompletion(); render() }
    }
    func setPlacement(_ placement: PanelPlacement) {
        self.placement = placement; slot = placement.slot; variant = placement.shape == .wide ? .wide : .tall
        surface.isHidden = slot == nil
        if !isRendering { resetObservation(); NativeMotion.stop(pulse); context.focus.unregister(owner: self) }
        else { observeCompletion(); render() }
    }
    func reveal(_ target: PanelReveal) {
        render()
        let id: String
        switch target {
        case .day: content.scroll(.zero); return
        case .item(let value): id = value.hasPrefix("focusTimer.") ? value : "focusTimer.project"
        case .scrollTo(let focusID): id = focusID.rawValue
        }
        if let item = content.items.first(where: { $0.id == id }) { content.scrollToVisible(item.rect) }
        context.focus.focus(FocusID(id))
    }
    private func visibilityChanged() {
        if isRendering { observeCompletion(); render() } else { resetObservation(); NativeMotion.stop(pulse); context.focus.unregister(owner: self) }
    }
    private func resetObservation() { previousClock = nil; previousFocus = nil; observedSession = nil; continuity = false }
    private func observeCompletion() {
        let snapshot = context.presentation.state.snapshot, current = snapshot.focus, clock = snapshot.clock
        defer { previousClock = clock; previousFocus = current; observedSession = current.sessionID }
        guard let before = previousClock, let old = previousFocus else { continuity = current.status == .running; return }
        if observedSession != current.sessionID { continuity = current.status == .running; return }
        let wall = clock.now.date.timeIntervalSince(before.now.date) * 1000
        let awake = clock.awakeMilliseconds - before.awakeMilliseconds
        let continuous = clock.continuousMilliseconds - before.continuousMilliseconds
        if clock.timeZone != before.timeZone || wall < 0 || awake < 0 || abs(wall - Double(awake)) > 1000 || abs(Double(continuous - awake)) > 1000 {
            // An already elapsed deadline is restored quietly. A still-running session
            // can complete normally after wake, so begin a new continuous observation.
            continuity = current.status == .running && current.endAt.map { $0 > clock.now } == true
            return
        }
        if old.status != .running && current.status == .running { continuity = true }
        guard old.status == .running, current.status == .completed, current.completionKind == .finished,
              let end = old.endAt, end <= clock.now, continuity else { return }
        completionPulseCount += 1
        let reduced = snapshot.environment.reduceMotion
        let animation = CAKeyframeAnimation(keyPath: "opacity"); animation.values = [0, 0.4, 0]
        animation.duration = NativeMotion.plan(.timer, reduceMotion: reduced).duration
        animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
        pulse.add(animation, forKey: "focus.completion")
        NSAccessibility.post(element: content, notification: .announcementRequested, userInfo: [
            .announcement: context.text(current.mode == .focus ? "timer.session_done" : "timer.break_done"),
            .priority: NSAccessibilityPriorityLevel.low.rawValue])
    }
    func primaryAction() {
        let status = context.presentation.state.snapshot.focus.status
        send(status == .running ? .pause : status == .paused ? .resume : .start)
    }
    func stop() { send(.stop) }
    func setMode(_ mode: FocusMode) { guard !active else { return }; send(.setMode(mode)) }
    func selectProject(_ id: UUID?) { guard !active else { return }; send(.selectProject(id)) }
    func toggleNotification() {
        watch(context.presentation.send(.command(.notification(.focus, enabled: !context.presentation.state.snapshot.board.settings.focus.notifyOnFinish))))
    }
    func setDuration(mode: FocusMode, minutes: Int) {
        guard (1...(mode == .focus ? 240 : 60)).contains(minutes) else {
            failure = AppFailure(code: .validationFailed, messageKey: "error.validation_failed"); render(); return
        }
        var settings = context.presentation.state.snapshot.board.settings.focus
        if (mode == .focus ? settings.focusSeconds : settings.breakSeconds) == minutes * 60 { return }
        if mode == .focus { settings.focusSeconds = minutes * 60 } else { settings.breakSeconds = minutes * 60 }
        watch(context.presentation.send(.edit(.settings(SettingsPatch(focus: .set(settings))), undoable: true)))
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NativeTextField else { return }
        guard let value = Int(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            failure = AppFailure(code: .validationFailed, messageKey: "error.validation_failed"); render(); return
        }
        setDuration(mode: field === focusDuration ? .focus : .break, minutes: value)
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertTab(_:)) || commandSelector == #selector(NSResponder.insertBacktab(_:)) {
            surface.window?.makeFirstResponder(content)
            context.focus.move(forward: commandSelector == #selector(NSResponder.insertTab(_:))); return true
        }
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        let value = context.presentation.state.snapshot.board.settings.focus
        textView.string = String(control === focusDuration ? value.focusSeconds / 60 : value.breakSeconds / 60)
        surface.window?.makeFirstResponder(content); return true
    }
    private func send(_ command: FocusCommand) { watch(context.presentation.send(.command(.focus(command)))) }
    private func watch(_ handle: OperationHandle?) {
        guard let handle else { return }; failure = nil
        Task { [weak self] in
            let receipt = await handle.settled.value
            guard let self, !self.disposed else { return }
            if case .failure(let error, _) = receipt { self.failure = error; self.failedOperation = handle.id }
            else { self.failure = nil; self.failedOperation = nil }
            self.render()
        }
    }
    private func activate(_ id: String) {
        switch id {
        case "focusTimer.primary": primaryAction()
        case "focusTimer.stop": stop()
        case "focusTimer.mode.focus": setMode(.focus)
        case "focusTimer.mode.break": setMode(.break)
        case "focusTimer.notify": toggleNotification()
        case "focusTimer.project": showProjectMenu()
        case "focusTimer.retry":
            if let failedOperation { watch(context.presentation.send(failure?.committed == .unknown ? .reconcile(failedOperation) : .retry(failedOperation))) }
            else { send(.stop) }
        default: break
        }
    }
    private func showProjectMenu() {
        guard !active else { return }
        let snapshot = context.presentation.state.snapshot
        var entries = [NativeMenuEntry(id: "none", title: context.text("event.project_none"), checked: snapshot.focus.projectID == nil)]
        entries += snapshot.board.projects.filter { $0.status == .active || $0.id == snapshot.focus.projectID }.map {
            NativeMenuEntry(id: $0.id.uuidString, title: $0.title, checked: $0.id == snapshot.focus.projectID)
        }
        projectMenu?.dispose()
        projectMenu = NativeMenu(items: entries) { [weak self] id in self?.selectProject(UUID(uuidString: id)) }
        let owner = fixedContent.items.contains { $0.id == "focusTimer.project" } && !fixedContent.isHidden ? fixedContent : content
        if let rect = owner.items.first(where: { $0.id == "focusTimer.project" })?.rect {
            projectMenu?.menu.popUp(positioning: nil, at: CGPoint(x: rect.minX, y: rect.maxY), in: owner)
        }
    }
    private func render(tick: Bool = false) {
        guard isRendering else { return }
        if let placement, placement.heightStep == .tiny || placement.heightStep == .small {
            renderCompact(placement, tick: tick); return
        }
        let state = context.presentation.state, snapshot = state.snapshot, focus = snapshot.focus, settings = snapshot.board.settings.focus
        let inset = NativeSpace.lg, row = NativeSize.toolbarHeight, gap = NativeSpace.sm
        let width = max(NativeSize.compactTarget, surface.bounds.width - inset * 2)
        if surface.theme.appearance != snapshot.environment.resolvedAppearance { surface.theme = NativeTheme(appearance: snapshot.environment.resolvedAppearance); content.theme = surface.theme; dialCanvas.theme = surface.theme }
        let appearanceName: NSAppearance.Name = snapshot.environment.resolvedAppearance == .light ? .aqua : .darkAqua
        if surface.appearance?.name != appearanceName { surface.appearance = NSAppearance(named: appearanceName) }
        surface.reduceMotion = snapshot.environment.reduceMotion; content.reduceMotion = snapshot.environment.reduceMotion; dialCanvas.reduceMotion = snapshot.environment.reduceMotion
        if !tick {
            fixedContent.isHidden = true
            if pulseView.superview !== content { pulseView.removeFromSuperview(); content.addSubview(pulseView) }
            if dialCanvas.superview !== content { dialCanvas.removeFromSuperview(); content.addSubview(dialCanvas, positioned: .below, relativeTo: pulseView) }
            surface.setAccessibilityLabel(context.text("timer.title"))
            let titleX = max(inset, placement?.editLeading ?? 0)
            var title = NativeRenderItem(id: "focusTimer.title", rect: CGRect(x: titleX, y: inset, width: max(0, inset + width - titleX), height: row), label: context.text("timer.title"), kind: .text)
            if let slot, placement?.editExclusions.isEmpty == false { title = NativePanelHeader.decorate(title, geometry: PanelHeaderGeometry(slot: slot, titleRect: title.rect,
                headerRect: CGRect(x: 0, y: 0, width: surface.bounds.width, height: inset + row + gap), excludedRects: placement?.editExclusions ?? [], actionLabel: context.text("slot_menu.title"))) }
            surface.update(items: [title])
            let top = inset + row + gap
            viewport.frame = CGRect(x: inset, y: top, width: width, height: max(0, surface.bounds.height - top - max(inset, placement?.editBottom ?? 0)))
        }
        let wide = variant == .wide && width >= NativeSize.projectMinWidth * 2
        let seconds = remainingSeconds, time = String(format: "%02d:%02d", seconds / 60, seconds % 60)
        let planned = focus.status == .idle ? (focus.mode == .focus ? settings.focusSeconds : settings.breakSeconds) : focus.plannedSeconds
        let widestTime = String(format: "%02d:%02d", max(0, planned) / 60, max(0, planned) % 60)
        let numberWidth = ceil((widestTime as NSString).size(withAttributes: [.font: NativeFont.timer]).width) + NativeSpace.sm * 2
        let dialSize = max(NativeSize.toolbarHeight * 4, numberWidth)
        let controlX = wide ? dialSize + NativeSpace.lg : 0
        let controlWidth = wide ? (width - controlX - NativeSpace.lg) / 2 : width
        let footerX = wide ? controlX + controlWidth + NativeSpace.lg : 0
        let footerWidth = wide ? width - footerX : width
        let dialY = wide ? 0 : row + gap
        let dial = CGRect(x: wide ? 0 : (width - dialSize) / 2, y: dialY, width: dialSize, height: dialSize)
        let actionsY = wide ? row + gap : dial.maxY + gap
        var items: [NativeRenderItem] = []
        content.fonts.removeAll(keepingCapacity: true)
        content.gaugeColor = focus.mode == .focus ? .timerFocus : .timerBreak
        content.gaugeFraction = focus.plannedSeconds > 0 ? Double(seconds) / Double(focus.plannedSeconds) : 0
        dialCanvas.gaugeColor = content.gaugeColor; dialCanvas.gaugeFraction = content.gaugeFraction
        func add(_ id: String, _ label: String, _ rect: CGRect, kind: NativeRenderItem.Kind = .text, enabled: Bool = true, fill: NativeColorToken? = nil, color: NativeColorToken = .textPrimary) {
            items.append(NativeRenderItem(id: id, rect: rect, label: label, kind: kind, enabled: enabled, fill: fill, color: color))
        }
        add("focusTimer.mode.focus", context.text("timer.mode_focus", values: ["0": String(settings.focusSeconds / 60)]), CGRect(x: controlX, y: 0, width: controlWidth / 2 - gap / 2, height: row), kind: .button, enabled: !active, fill: focus.mode == .focus ? .fill : .raised, color: focus.mode == .focus ? .toastText : .textSecondary)
        add("focusTimer.mode.break", context.text("timer.mode_break", values: ["0": String(settings.breakSeconds / 60)]), CGRect(x: controlX + controlWidth / 2 + gap / 2, y: 0, width: controlWidth / 2 - gap / 2, height: row), kind: .button, enabled: !active, fill: focus.mode == .break ? .timerBreak : .raised, color: focus.mode == .break ? .timerBreakText : .textSecondary)
        add("focusTimer.gauge", "", dial, kind: .group)
        add("focusTimer.time", time, CGRect(x: dial.minX, y: dial.midY - row, width: dial.width, height: row * 2), color: content.gaugeColor); content.fonts["focusTimer.time"] = NativeFont.timer; dialCanvas.fonts = content.fonts
        add("focusTimer.primary", context.text(focus.status == .running ? "timer.pause" : focus.status == .paused ? "timer.resume" : "timer.start"), CGRect(x: controlX, y: actionsY, width: controlWidth / 2 - gap / 2, height: row), kind: .button, fill: .fill, color: .toastText)
        add("focusTimer.stop", context.text("timer.stop"), CGRect(x: controlX + controlWidth / 2 + gap / 2, y: actionsY, width: controlWidth / 2 - gap / 2, height: row), kind: .button, enabled: active, color: .textSecondary)
        let durationY = actionsY + row + gap
        for (field, key, minutes, x) in [(focusDuration, "timer.config_focus", settings.focusSeconds / 60, controlX), (breakDuration, "timer.config_break", settings.breakSeconds / 60, controlX + controlWidth / 2 + gap / 2)] {
            add(field === focusDuration ? "focusTimer.durationLabel.focus" : "focusTimer.durationLabel.break", context.text(key), CGRect(x: x, y: durationY, width: controlWidth / 2 - gap / 2, height: row))
            if !tick {
                field.frame = CGRect(x: x, y: durationY + row, width: controlWidth / 2 - gap / 2, height: row)
                field.updateFromBase(String(minutes)); field.setAccessibilityLabel(context.text(key)); field.toolTip = active ? context.text("timer.locked_running") : nil
            }
        }
        var footerY = wide ? 0 : durationY + row * 2 + NativeSpace.md
        let projectName = focus.projectID.flatMap { id in snapshot.board.projects.first(where: { $0.id == id })?.title } ?? context.text("event.project_none")
        add("focusTimer.projectLabel", context.text("timer.project_label"), CGRect(x: footerX, y: footerY, width: footerWidth, height: row)); footerY += row
        add("focusTimer.project", projectName, CGRect(x: footerX, y: footerY, width: footerWidth, height: row), kind: .button, enabled: !active, fill: .raised); footerY += row + gap
        add("focusTimer.today", context.text("timer.today_focus", values: ["0": String(todaySeconds / 60)]), CGRect(x: footerX, y: footerY, width: footerWidth, height: row), color: .textSecondary); footerY += row
        var notificationItem = NativeRenderItem(id: "focusTimer.notify", rect: CGRect(x: footerX, y: footerY, width: footerWidth, height: row), label: context.text("timer.notify_finish"), kind: .checkBox, checked: settings.notifyOnFinish)
        notificationItem.enabled = true; items.append(notificationItem); footerY += row
        var bottom = max(footerY, durationY + row * 2)
        if active {
            bottom = clearPartialNotice(bottom, height: row * 2, viewportHeight: viewport.contentSize.height)
            add("focusTimer.locked", context.text("timer.locked_running"), CGRect(x: 0, y: bottom, width: width, height: row * 2), color: .textQuiet); bottom += row * 2
        }
        if focus.status == .completed {
            add("focusTimer.completion", context.text(focus.mode == .focus ? "timer.session_done" : "timer.break_done"), CGRect(x: 0, y: bottom, width: width, height: row * 2), color: .success); bottom += row * 2
        }
        let runtimeFailure = (snapshot.storageWarning ?? state.lastError).flatMap { [AppFailureCode.storageWriteFailed, .storageProtected].contains($0.code) ? $0 : nil }
        if let error = failure ?? runtimeFailure {
            add("focusTimer.error", context.text(error.code == .storageWriteFailed ? "timer.save_failed" : error.messageKey), CGRect(x: 0, y: bottom, width: width, height: row * 2), color: .danger); bottom += row * 2
            add("focusTimer.retry", context.text("error.retry_action"), CGRect(x: 0, y: bottom, width: width, height: row), kind: .button); bottom += row
        }
        if state.activity.loading { add("focusTimer.loading", context.text("loading.label"), CGRect(x: 0, y: bottom, width: width, height: row), color: .textQuiet); bottom += row }
        let changed = items.filter { !content.items.contains($0) }.map(\.id)
        // The gauge is drawn from a numeric fraction; its rect and AX description stay stable.
        var dirtyIDs = changed
        if changed.contains("focusTimer.time"), !dirtyIDs.contains("focusTimer.gauge") { dirtyIDs.append("focusTimer.gauge") }
        if tick { lastTickDirtyIDs = dirtyIDs }
        if !tick {
            let contentFrame = CGRect(x: 0, y: 0, width: width, height: max(viewport.contentSize.height, bottom))
            if content.frame != contentFrame { content.frame = contentFrame }
            if dialCanvas.frame != dial { dialCanvas.frame = dial }
            viewport.updateFade()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            pulseView.frame = dial; pulse.cornerRadius = dial.width / 2; pulse.backgroundColor = content.theme.color(content.gaugeColor).cgColor
            CATransaction.commit()
            registerDurationFocus()
        }
        guard !changed.isEmpty || items.count != content.items.count else { return }
        content.update(items: items, announceLayout: !tick, invalidatingDisplay: !tick)
        let liveItems = items.filter { content.excludedPaintIDs.contains($0.id) }.map { item in
            var local = item; local.rect = item.rect.offsetBy(dx: -dial.minX, dy: -dial.minY); return local
        }
        dialCanvas.update(items: liveItems, announceLayout: false)
        if dirtyIDs.contains("focusTimer.gauge") { dialCanvas.setNeedsDisplay(dialCanvas.bounds) }
        renderPassCount += 1
    }

    /// Tiny/Small use the same live deadline and settings fields, with only the primary row fixed.
    private func renderCompact(_ placement: PanelPlacement, tick: Bool) {
        let state = context.presentation.state, snapshot = state.snapshot, focus = snapshot.focus, settings = snapshot.board.settings.focus
        let metrics = NativePanelStepMetrics(panel: panelID, shape: placement.shape, step: placement.heightStep)
        let row = metrics.settingsRow!.height, gap = metrics.itemGap, tinyRail = placement.shape == .rail && placement.heightStep == .tiny
        let primaryHeight = tinyRail ? row : NativeSize.toolbarHeight + NativeSpace.xxs
        let viewportTop = max(metrics.headerHeight, placement.editLeading > 0 ? 32 : 0) + primaryHeight + gap
        let visibleHeight = max(0, surface.bounds.height - viewportTop - max(metrics.bottomPadding, placement.editBottom))
        let width = max(0, surface.bounds.width - metrics.horizontalPadding * 2)
        let font = metrics.numericFont
        let seconds = remainingSeconds, time = String(format: "%02d:%02d", seconds / 60, seconds % 60)
        let numberWidth = ceil(("240:00" as NSString).size(withAttributes: [.font: font]).width) + NativeSpace.sm * 2
        let actionWidth = placement.shape == .wide ? NativeSize.compactTarget : max(NativeSize.compactTarget, (width - numberWidth - gap * 2) / 2)
        let primaryRect = CGRect(x: numberWidth + gap, y: 0, width: actionWidth, height: primaryHeight)
        let stopRect = CGRect(x: primaryRect.maxX + gap, y: 0, width: actionWidth, height: primaryHeight)
        let timeRect = CGRect(x: 0, y: 0, width: numberWidth, height: primaryHeight)
        let projectName = focus.projectID.flatMap { id in snapshot.board.projects.first { $0.id == id }?.title } ?? context.text("event.project_none")
        if surface.theme.appearance != snapshot.environment.resolvedAppearance { surface.theme = NativeTheme(appearance: snapshot.environment.resolvedAppearance) }
        content.theme = surface.theme; fixedContent.theme = surface.theme; dialCanvas.theme = surface.theme
        let appearanceName: NSAppearance.Name = snapshot.environment.resolvedAppearance == .light ? .aqua : .darkAqua
        if surface.appearance?.name != appearanceName { surface.appearance = NSAppearance(named: appearanceName) }
        surface.reduceMotion = snapshot.environment.reduceMotion; content.reduceMotion = surface.reduceMotion
        fixedContent.reduceMotion = surface.reduceMotion; dialCanvas.reduceMotion = surface.reduceMotion
        var fixed = [NativeRenderItem(id: "focusTimer.time", rect: timeRect, label: time, kind: .text, color: focus.mode == .focus ? .timerFocus : .timerBreak),
            NativeRenderItem(id: "focusTimer.primary", rect: primaryRect, label: context.text(focus.status == .running ? "timer.pause" : focus.status == .paused ? "timer.resume" : "timer.start"), kind: .button, fill: .fill, color: .toastText),
            NativeRenderItem(id: "focusTimer.stop", rect: stopRect, label: context.text("timer.stop"), kind: .button, enabled: active, color: .textSecondary)]
        fixedContent.visibleLabels.removeAll(keepingCapacity: true)
        for item in fixed where item.kind == .button {
            let labelWidth = ceil((item.label as NSString).size(withAttributes: [.font: NativeFont.primary]).width) + NativeSpace.sm * 2
            if labelWidth > item.rect.width {
                fixedContent.visibleLabels[item.id] = item.id == "focusTimer.stop" ? "■" : focus.status == .running ? "Ⅱ" : "▶"
            }
        }
        var items: [NativeRenderItem] = [], y = NativeSize.focusWidth / 2
        func add(_ id: String, _ label: String, _ rect: CGRect, kind: NativeRenderItem.Kind = .text, enabled: Bool = true, fill: NativeColorToken? = nil, color: NativeColorToken = .textPrimary) {
            items.append(NativeRenderItem(id: id, rect: rect, label: label, kind: kind, enabled: enabled, fill: fill, color: color))
        }
        let runtimeFailure = (snapshot.storageWarning ?? state.lastError).flatMap { [AppFailureCode.storageWriteFailed, .storageProtected].contains($0.code) ? $0 : nil }
        let error = failure ?? runtimeFailure
        if let error {
            let retryWidth = min(width / 2, max(NativeSize.compactTarget, ceil((context.text("error.retry_action") as NSString).size(withAttributes: [.font: NativeFont.primary]).width) + NativeSpace.sm * 2))
            add("focusTimer.error", context.text(error.code == .storageWriteFailed ? "timer.save_failed" : error.messageKey), CGRect(x: 0, y: y, width: width - retryWidth - gap, height: row), color: .danger)
            add("focusTimer.retry", context.text("error.retry_action"), CGRect(x: width - retryWidth, y: y, width: retryWidth, height: row), kind: .button); y += row + gap
        }
        let wide = placement.shape == .wide
        let projectRect: CGRect
        if wide {
            let start = stopRect.maxX + gap
            let available = max(0, width - start)
            let modeWidth = max(NativeSize.compactTarget, (available - gap * 2) / 4)
            fixed.append(NativeRenderItem(id: "focusTimer.mode.focus", rect: CGRect(x: start, y: 0, width: modeWidth, height: primaryHeight), label: context.text("timer.mode_focus", values: ["0": String(settings.focusSeconds / 60)]), kind: .button, enabled: !active, fill: focus.mode == .focus ? .fill : .raised, color: focus.mode == .focus ? .toastText : .textSecondary))
            fixed.append(NativeRenderItem(id: "focusTimer.mode.break", rect: CGRect(x: start + modeWidth + gap, y: 0, width: modeWidth, height: primaryHeight), label: context.text("timer.mode_break", values: ["0": String(settings.breakSeconds / 60)]), kind: .button, enabled: !active, fill: focus.mode == .break ? .timerBreak : .raised, color: focus.mode == .break ? .timerBreakText : .textSecondary))
            let projectX = start + (modeWidth + gap) * 2
            projectRect = CGRect(x: projectX, y: 0, width: max(NativeSize.compactTarget, width - projectX), height: primaryHeight)
            fixed.append(NativeRenderItem(id: "focusTimer.project", rect: projectRect, label: projectName, kind: .button, enabled: !active, fill: .raised))
        } else {
            projectRect = CGRect(x: 0, y: y, width: width, height: row)
            add("focusTimer.project", projectName, projectRect, kind: .button, enabled: !active, fill: .raised); y += row + gap
            y = clearPartialNotice(y, height: row, viewportHeight: visibleHeight)
            for (index, mode) in [FocusMode.focus, .break].enumerated() {
                let selected = focus.mode == mode
                add("focusTimer.mode.\(mode.rawValue)", context.text(mode == .focus ? "timer.mode_focus" : "timer.mode_break", values: ["0": String((mode == .focus ? settings.focusSeconds : settings.breakSeconds) / 60)]),
                    CGRect(x: CGFloat(index) * (width + gap) / 2, y: y, width: (width - gap) / 2, height: row), kind: .button, enabled: !active,
                    fill: selected ? (mode == .focus ? .fill : .timerBreak) : .raised, color: selected ? (mode == .focus ? .toastText : .timerBreakText) : .textSecondary)
            }
            y += row + gap
        }
        content.fonts.removeAll(keepingCapacity: true)
        for (field, key, minutes, index) in [(focusDuration, "timer.config_focus", settings.focusSeconds / 60, 0), (breakDuration, "timer.config_break", settings.breakSeconds / 60, 1)] {
            let x = CGFloat(index) * (width + gap) / 2, fieldWidth = (width - gap) / 2
            add(field === focusDuration ? "focusTimer.durationLabel.focus" : "focusTimer.durationLabel.break", context.text(key), CGRect(x: x, y: y, width: fieldWidth, height: row))
            if !tick {
                field.frame = CGRect(x: x, y: y + row, width: fieldWidth, height: row)
                field.updateFromBase(String(minutes)); field.setAccessibilityLabel(context.text(key)); field.toolTip = active ? context.text("timer.locked_running") : nil
            }
        }
        y += row * 2 + gap
        add("focusTimer.today", context.text("timer.today_focus", values: ["0": String(todaySeconds / 60)]), CGRect(x: 0, y: y, width: width, height: row), color: .textSecondary); y += row
        items.append(NativeRenderItem(id: "focusTimer.notify", rect: CGRect(x: 0, y: y, width: width, height: row), label: context.text("timer.notify_finish"), kind: .checkBox, checked: settings.notifyOnFinish)); y += row
        if active {
            y = clearPartialNotice(y, height: row, viewportHeight: visibleHeight)
            add("focusTimer.locked", context.text("timer.locked_running"), CGRect(x: 0, y: y, width: width, height: row), color: .textQuiet); y += row
        }
        if focus.status == .completed { add("focusTimer.completion", context.text(focus.mode == .focus ? "timer.session_done" : "timer.break_done"), CGRect(x: 0, y: y, width: width, height: row), color: .success); y += row }
        if state.activity.loading { add("focusTimer.loading", context.text("loading.label"), CGRect(x: 0, y: y, width: width, height: row), color: .textQuiet); y += row }
        let dirty = fixed.filter { !fixedContent.items.contains($0) }.map(\.id) + items.filter { !content.items.contains($0) }.map(\.id)
        if tick { lastTickDirtyIDs = dirty }
        if !tick {
            fixedContent.isHidden = false
            let titleX = max(metrics.horizontalPadding, placement.editLeading)
            var title = NativeRenderItem(id: "focusTimer.title", rect: CGRect(x: titleX, y: 0, width: max(0, metrics.horizontalPadding + width - titleX), height: metrics.headerHeight), label: context.text("timer.title"), kind: .text)
            if let slot, !placement.editExclusions.isEmpty { title = NativePanelHeader.decorate(title, geometry: PanelHeaderGeometry(slot: slot, titleRect: title.rect,
                headerRect: CGRect(x: 0, y: 0, width: surface.bounds.width, height: metrics.headerHeight), excludedRects: placement.editExclusions, actionLabel: context.text("slot_menu.title"))) }
            surface.update(items: [title]); surface.setAccessibilityLabel(title.label)
            fixedContent.frame = CGRect(x: metrics.horizontalPadding, y: max(metrics.headerHeight, placement.editLeading > 0 ? 32 : 0), width: width, height: primaryHeight)
            viewport.frame = CGRect(x: metrics.horizontalPadding, y: viewportTop, width: width, height: visibleHeight)
            content.frame = CGRect(x: 0, y: 0, width: width, height: max(viewport.contentSize.height, y + NativeSize.focusWidth / 2))
            if dialCanvas.superview !== fixedContent { dialCanvas.removeFromSuperview(); fixedContent.addSubview(dialCanvas) }
            dialCanvas.frame = timeRect; dialCanvas.fonts = ["focusTimer.time": font]
            if pulseView.superview !== fixedContent { pulseView.removeFromSuperview(); fixedContent.addSubview(pulseView, positioned: .below, relativeTo: dialCanvas) }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            pulseView.frame = timeRect; pulse.cornerRadius = NativeRadius.input
            pulse.backgroundColor = content.theme.color(focus.mode == .focus ? .timerFocus : .timerBreak).cgColor
            CATransaction.commit()
            registerDurationFocus(); viewport.updateFade()
            if error != nil && !compactHadFailure && focusDuration.currentEditor() == nil && breakDuration.currentEditor() == nil {
                viewport.contentView.scroll(to: .zero); viewport.reflectScrolledClipView(viewport.contentView)
            }
            compactHadFailure = error != nil
        }
        guard !dirty.isEmpty || fixed.count != fixedContent.items.count || items.count != content.items.count else { return }
        fixedContent.update(items: fixed, announceLayout: !tick, invalidatingDisplay: !tick)
        content.update(items: items, announceLayout: !tick, invalidatingDisplay: !tick)
        dialCanvas.update(items: [NativeRenderItem(id: "focusTimer.time", rect: dialCanvas.bounds, label: time, kind: .text, color: focus.mode == .focus ? .timerFocus : .timerBreak)], announceLayout: false)
        renderPassCount += 1
    }
    private func registerDurationFocus() {
        let targets = [focusDuration, breakDuration].map { field in
            let id = FocusID(field === focusDuration ? "focusTimer.duration.focus" : "focusTimer.duration.break")
            var target = FocusCoordinator.Target(id: id, rect: field.frame, activate: { [weak field] in field?.selectText(nil) })
            target.focusChanged = { [weak self, weak field] in
                guard let self, self.context.focus.focusedID == id else { return }; field?.selectText(nil)
            }
            target.reveal = { [weak self, weak field] in if let field { self?.content.scrollToVisible(field.frame) } }
            return target
        }
        context.focus.register(owner: self, targets: targets)
    }
    func dispose() {
        guard !disposed else { return }; disposed = true; lifetime.dispose()
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }; windowObserver = nil
        context.focus.unregister(owner: self)
        projectMenu?.dispose(); projectMenu = nil; focusDuration.delegate = nil; breakDuration.delegate = nil
        NativeMotion.stop(pulse); pulseView.removeFromSuperview(); viewport.dispose(); dialCanvas.dispose(); fixedContent.dispose(); content.dispose(); surface.dispose()
    }
}
