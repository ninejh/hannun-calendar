import AppKit

private enum ProjectStepLayout { static let tinyWideCardHeight: CGFloat = 64 }

@MainActor final class ProjectDeckCanvas: ManagementCanvas {
    var schedules: [String: CGRect] = [:]
    var onScheduleScroll: (@MainActor (String, Int) -> Void)?
    // Directly painted card viewports keep one canvas, including in a 1,000-card deck.
    var cardViewports: [String: CGRect] = [:]
    var itemViewports: [String: CGRect] = [:]
    var onCardScroll: (@MainActor (String, CGFloat) -> Void)?
    var onRevealCardItem: (@MainActor (String) -> CGRect?)?
    override func paint(_ item: NativeRenderItem) {
        guard let clip = itemViewports[item.id] else { super.paint(item); return }
        guard item.rect.intersects(clip) else { return }
        NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect: clip).addClip()
        super.paint(item); NSGraphicsContext.restoreGraphicsState()
    }
    override func item(at point: CGPoint) -> NativeRenderItem? {
        items.reversed().first { item in
            item.enabled && item.isInteractive && item.hitRect.contains(point) && (itemViewports[item.id]?.contains(point) ?? true)
        }
    }
    @discardableResult override func scrollToVisible(_ rect: CGRect) -> Bool {
        let outset = NativeSize.focusOffset + NativeSize.focusWidth
        let focused = items.first { $0.focusID == focus.focusedID && $0.hitRect.insetBy(dx: -outset, dy: -outset) == rect }
        let requested = items.first { $0.rect == rect && itemViewports[$0.id] != nil } ?? focused
        if let id = requested?.id, let viewport = onRevealCardItem?(id) { return super.scrollToVisible(viewport) }
        return super.scrollToVisible(rect)
    }
    override func activate(_ id: String) { _ = onRevealCardItem?(id); super.activate(id) }
    override func screenRect(_ rect: CGRect) -> CGRect {
        if let item = items.first(where: { $0.hitRect == rect }), let clip = itemViewports[item.id] {
            let visible = rect.intersection(clip)
            return visible.isNull ? .zero : super.screenRect(visible)
        }
        return super.screenRect(rect)
    }
    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX), let card = cardViewports.first(where: { $0.value.contains(point) }) {
            onCardScroll?(card.key, -event.scrollingDeltaY); return
        }
        if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX), let region = schedules.first(where: { $0.value.contains(point) }), abs(event.scrollingDeltaY) > 0 {
            onScheduleScroll?(region.key, event.scrollingDeltaY > 0 ? -1 : 1); return
        }
        super.scrollWheel(with: event)
    }
}

/// A stable controller moves between slots without replacing its editor, scroll or local disclosure state.
@MainActor final class ProjectsPanelController: PanelController {
    let panelID: PanelID = .projects
    var view: NSView { surface }
    let context: BoardScreenContext
    let surface: ManagementPanelView
    let content: ProjectDeckCanvas
    let scroll = OverflowScrollView(frame: .zero)
    private let lifetime = ScreenLifetime()
    private var retainedMenu: NativeMenu?
    private(set) var variant: SlotVariant = .wide
    private(set) var heightStep: PanelSizeStep = .regular
    private var placement: PanelPlacement?
    private var scrollOrigins: [String: CGPoint] = [:]
    private var cardOffsets: [String: CGFloat] = [:]
    private var logicalCardItems: [String: CGRect] = [:]
    private var cardDocumentHeights: [String: CGFloat] = [:]
    private(set) var visibleProjects: [Project] = []
    private(set) var cardRects: [CGRect] = []
    private(set) var editor: ProjectDeadlineEditor?
    private(set) var inlineError: AppFailure?
    private var failedID: UUID?
    private var schedules: [UUID: Int] = [:]
    private var displayedSchedules: [UUID: (offset: Int, limit: Int)] = [:]
    // Coalesce pointer samples while one durable progress write is accepted.
    // These transient values never replace the authoritative board or an admitted operation.
    private var progressDesired: [UUID: Int] = [:]
    private var progressInFlight: [UUID: UUID] = [:]
    private var progressUnknown: [UUID: UUID] = [:]
    private var lastToday: DateOnly?
    private var lastMinute: Int?
    private var rendering = false
    private var disposed = false
    init(context: BoardScreenContext) {
        self.context = context; surface = ManagementPanelView(focus: context.focus); content = ProjectDeckCanvas(focus: context.focus)
        surface.setAccessibilityIdentifier("panel.projects"); surface.setAccessibilityLabel(context.text("projects.title"))
        content.setAccessibilityIdentifier("projects.deck"); content.setAccessibilityLabel(context.text("a11y.projects"))
        scroll.documentView = content; surface.addSubview(scroll)
        surface.onLayout = { [weak self] in self?.render() }
        surface.onAction = { [weak self] in self?.act($0) }
        content.onAction = { [weak self] in self?.act($0) }
        content.onProgress = { [weak self] id, value in self?.setProgress(id, value: value) }
        content.onAdjust = { [weak self] id, delta in
            guard let self, let project = self.project(for: id) else { return }; self.setProgress(id, value: project.progress + delta)
        }
        content.onScheduleScroll = { [weak self] id, delta in self?.moveSchedule(id, delta: delta) }
        content.onCardScroll = { [weak self] id, delta in self?.scrollCard(id, delta: delta) }
        content.onRevealCardItem = { [weak self] id in self?.revealCardItem(id) }
        context.bindPanelMenus(to: surface)
        content.contextMenu = { [weak self] id in guard let self, let project = self.project(for: id) else { return nil }; return self.menu(for: project.id) }
        content.onShortcut = { [weak self] event in
            guard let self, [116, 121].contains(event.keyCode), let focused = self.context.focus.focusedID?.rawValue, let project = self.project(for: focused) else { return false }
            if self.heightStep == .tiny || self.heightStep == .small {
                self.scrollCard("project." + project.id.uuidString.lowercased(), delta: event.keyCode == 116 ? -NativeSize.compactTarget : NativeSize.compactTarget); return true
            }
            self.moveSchedule("project." + project.id.uuidString.lowercased(), delta: event.keyCode == 116 ? -1 : 1); return true
        }
        lifetime.own(context.presentation.subscribe { [weak self] change in
            guard let self else { return }
            if change.domains.isDisjoint(with: [.board, .calendar, .environment, .pending, .activity, .error, .clock]) { return }
            if change.domains == [.clock] {
                guard !self.surface.isHidden else { return }
                let clock = self.context.presentation.state.snapshot.clock
                let minute = Int(clock.now.date.timeIntervalSince1970 / 60)
                guard self.lastToday != clock.today || self.lastMinute != minute else { return }
            }
            if change.domains.contains(.environment) { self.editor?.refreshEnvironment() }
            let state = self.context.presentation.state
            for operation in state.pending where operation.kind == "undo" {
                for affected in operation.affected { if case .project(let id) = affected { self.progressDesired[id] = nil } }
            }
            for (id, source) in self.progressUnknown where !state.pending.contains(where: { $0.id == source }) {
                self.progressUnknown[id] = nil; self.flushProgress(id)
            }
            self.render()
        })
    }
    func setPlacement(slot: SlotID?, variant: SlotVariant) {
        setPlacement(PanelPlacement(slot: slot, shape: variant == .wide ? .wide : .rail, heightStep: .regular, railWidthStep: .regular, frame: surface.frame, headerRect: .zero, contentRect: .zero))
    }
    func setPlacement(_ placement: PanelPlacement) {
        guard self.placement != placement else { return }
        let nextVariant: SlotVariant = placement.shape == .wide ? .wide : .tall
        let changedShape = variant != nextVariant
        if changedShape { scrollOrigins[variant == .wide ? "wide" : "rail"] = scroll.contentView.bounds.origin }
        self.placement = placement; heightStep = placement.heightStep
        surface.isHidden = placement.slot == nil
        variant = nextVariant
        render()
        if changedShape { restoreScrollOrigin() }
    }
    func reveal(_ target: PanelReveal) {
        let requested: String
        switch target {
        case .scrollTo(let focus): requested = focus.rawValue
        case .item(let value): requested = value.lowercased()
        case .day(let day):
            guard let project = context.presentation.state.snapshot.board.projects.first(where: { $0.targetDay == day }) else { return }
            reveal(.item(project.id.uuidString.lowercased())); return
        }
        if let project = context.presentation.state.snapshot.board.projects.first(where: { $0.id.uuidString.lowercased() == requested }),
           project.status == .done, !context.presentation.state.snapshot.board.settings.showCompletedProjects {
            var patch = SettingsPatch(); patch.showCompletedProjects = .set(true); _ = save(.settings(patch), undoable: false)
        }
        if let item = content.items.first(where: { $0.isInteractive && ($0.id == requested || $0.id == "project." + requested + ".title") }) {
            content.scrollToVisible(item.rect)
            context.focus.focus(FocusID(item.id)); surface.window?.makeFirstResponder(content)
        }
    }
    private func anchor(_ action: String, target: AnchorTarget) -> StableAnchor {
        let rect = content.items.first { $0.id == action }?.rect ?? surface.bounds
        let root = surface.window?.contentView ?? surface
        var boardRect = root.convert(rect, from: content)
        if !root.isFlipped { boardRect.origin.y = root.bounds.maxY - boardRect.maxY }
        return StableAnchor(target: target, boardRect: boardRect, returnFocusID: FocusID(action))
    }
    func setVariant(_ variant: SlotVariant) {
        guard self.variant != variant else { return }; self.variant = variant
        scroll.axis = variant == .wide ? .horizontal : .vertical
        render()
    }
    private func restoreScrollOrigin() {
        let saved = scrollOrigins[variant == .wide ? "wide" : "rail"] ?? .zero
        let origin = CGPoint(x: min(max(0, saved.x), max(0, content.bounds.width - scroll.contentSize.width)), y: min(max(0, saved.y), max(0, content.bounds.height - scroll.contentSize.height)))
        scroll.contentView.scroll(to: origin); scroll.reflectScrolledClipView(scroll.contentView); scroll.updateFade()
    }
    private func project(for action: String) -> Project? {
        visibleProjects.first { action.hasPrefix("project." + $0.id.uuidString.lowercased() + ".") }
    }
    private func events(_ project: Project) -> [EventRecord] {
        let snapshot = context.presentation.state.snapshot, links = snapshot.board.eventProjectLinks
        return snapshot.calendar.records.filter {
            links[$0.pinKey]?.lowercased() == project.id.uuidString.lowercased() && !snapshot.board.hiddenCalendarIDs.contains($0.item.calendarID) && $0.item.end >= snapshot.clock.now.date
        }.sorted { $0.item.start == $1.item.start ? $0.id < $1.id : $0.item.start < $1.item.start }
    }
    private func render() {
        // Parking keeps model subscriptions and admitted write settlement alive. Rebuild
        // paint/layout from the latest state only when setPlacement makes us visible again.
        guard !disposed, !rendering, !surface.isHidden else { return }; rendering = true; defer { rendering = false }
        let state = context.presentation.state, snapshot = state.snapshot
        lastToday = snapshot.clock.today; lastMinute = Int(snapshot.clock.now.date.timeIntervalSince1970 / 60)
        if surface.theme.appearance != snapshot.environment.resolvedAppearance { surface.theme = NativeTheme(appearance: snapshot.environment.resolvedAppearance); content.theme = surface.theme }
        if surface.reduceMotion != snapshot.environment.reduceMotion { surface.reduceMotion = snapshot.environment.reduceMotion; surface.needsDisplay = true }
        if content.reduceMotion != snapshot.environment.reduceMotion { content.reduceMotion = snapshot.environment.reduceMotion; content.needsDisplay = true }
        surface.setAccessibilityLabel(context.text("projects.title")); content.setAccessibilityLabel(context.text("a11y.projects"))
        visibleProjects = snapshot.board.projects.filter { snapshot.board.settings.showCompletedProjects || $0.status != .done }.map { base in
            var value = base; if let progress = progressDesired[base.id] { value.progress = progress }; return value
        }
        let metrics = NativePanelStepMetrics(panel: .projects, shape: variant == .wide ? .wide : .rail, step: heightStep)
        let condensed = heightStep == .tiny || heightStep == .small
        let width = max(0, surface.bounds.width)
        let header = condensed ? metrics.headerHeight : variant == .tall ? NativeSize.compactTarget * 2 + NativeSpace.sm : NativeSize.compactTarget + NativeSpace.md
        let padding = condensed ? metrics.horizontalPadding : NativeSpace.xs
        let contentTop = max(header, (placement?.editLeading ?? 0) > 0 ? 32 : 0)
        let contentBottom = max(placement?.editBottom ?? 0, condensed ? metrics.bottomPadding : NativeSpace.sm)
        scroll.frame = CGRect(x: padding, y: contentTop, width: max(0, width - padding * 2), height: max(0, surface.bounds.height - contentTop - contentBottom))
        if heightStep == .tiny && variant == .tall { scroll.frame.size.height = min(scroll.frame.height, metrics.listRow!.height) }
        scroll.axis = variant == .wide ? .horizontal : .vertical
        let titleWidth = condensed ? max(0, width - NativeSize.compactTarget * 4 - NativeSpace.lg) : variant == .tall ? width / 2 : min(NativeSize.projectMinWidth, max(0, width - NativeSize.compactTarget * 12))
        let controlsY = condensed ? max(0, (header - NativeSize.compactTarget) / 2) : variant == .tall ? NativeSize.compactTarget + NativeSpace.xs : NativeSpace.xs
        let controlStart = condensed ? width - NativeSize.compactTarget * 4 - NativeSpace.sm : variant == .tall ? NativeSpace.sm : max(titleWidth, width - NativeSize.compactTarget * 12)
        let available = max(0, width - controlStart - NativeSpace.sm)
        let nav = NativeSize.compactTarget
        let doneWidth = max(nav, (available - nav * 2) / 2)
        var headerItems = [NativeRenderItem(id: "projects.heading", rect: CGRect(x: NativeSpace.sm, y: NativeSpace.xs, width: max(0, titleWidth), height: nav), label: context.text("projects.title"), kind: .text),
            NativeRenderItem(id: "projects.previous", rect: CGRect(x: controlStart, y: controlsY, width: nav, height: nav), label: context.text("a11y.previous_projects"), kind: .button),
            NativeRenderItem(id: "projects.next", rect: CGRect(x: controlStart + nav, y: controlsY, width: nav, height: nav), label: context.text("a11y.next_projects"), kind: .button),
            NativeRenderItem(id: "projects.showDone", rect: CGRect(x: controlStart + nav * 2, y: controlsY, width: doneWidth, height: nav), label: context.text(snapshot.board.settings.showCompletedProjects ? "projects.hide_done" : "projects.show_done"), kind: .checkBox, checked: snapshot.board.settings.showCompletedProjects),
            NativeRenderItem(id: "projects.add", rect: CGRect(x: controlStart + nav * 2 + doneWidth, y: controlsY, width: max(0, available - nav * 2 - doneWidth), height: nav), label: context.text("projects.add"), kind: .button)]
        let activeCount = snapshot.board.projects.filter { $0.status == .active }.count, waitingCount = snapshot.board.projects.filter { $0.status == .waiting }.count
        if variant == .tall || condensed {
            headerItems[0].value = context.text("projects.count_active", values: ["0": String(activeCount)]) + " · " + context.text("projects.count_waiting", values: ["0": String(waitingCount)])
        } else if titleWidth > NativeSize.compactTarget * 6 {
            headerItems[0].label += "  " + context.text("projects.count_active", values: ["0": String(activeCount)]) + " · " + context.text("projects.count_waiting", values: ["0": String(waitingCount)])
        }
        surface.displayLabels = ["projects.previous": "‹", "projects.next": "›"]
        if condensed { surface.displayLabels["projects.showDone"] = "✓"; surface.displayLabels["projects.add"] = "+" }
        let savingProject = state.pending.contains { operation in operation.affected.contains { if case .project = $0 { true } else { false } } }
        if savingProject { headerItems[0].label += " · " + context.text("toast.event_saving") }
        if condensed {
            for index in headerItems.indices {
                headerItems[index].rect.origin.y = controlsY
                headerItems[index].rect.size.height = min(nav, header)
                headerItems[index].interactionRect = headerItems[index].rect
            }
        }
        if let leading = placement?.editLeading, leading > headerItems[0].rect.minX {
            let right = headerItems[0].rect.maxX
            headerItems[0].rect.origin.x = leading; headerItems[0].rect.size.width = max(0, right - leading)
            headerItems[0].interactionRect = headerItems[0].rect
        }
        if let slot = placement?.slot, placement?.editExclusions.isEmpty == false {
            headerItems[0] = NativePanelHeader.decorate(headerItems[0], geometry: PanelHeaderGeometry(slot: slot, titleRect: headerItems[0].rect, headerRect: CGRect(x: 0, y: 0, width: width, height: header), excludedRects: headerItems.dropFirst().map(\.hitRect) + (placement?.editExclusions ?? []), actionLabel: context.text("slot_menu.title")))
        }
        surface.update(items: headerItems)
        let viewport = scroll.contentSize
        let gap = metrics.cardGap, inset = condensed ? 0 : NativeSpace.sm
        let count = visibleProjects.count
        let slots = max(1, min(3, count))
        let cardWidth = variant == .wide ? max(NativeSize.projectMinWidth, (viewport.width - inset * 2 - gap * CGFloat(slots - 1)) / CGFloat(slots)) : max(0, viewport.width - inset * 2)
        let cardHeight = variant == .wide ? (heightStep == .tiny ? ProjectStepLayout.tinyWideCardHeight : heightStep == .small ? viewport.height : max(NativeSize.compactTarget * 7, viewport.height - inset * 2)) : metrics.listRow!.height
        let rowGap = variant == .tall ? metrics.listRow!.gap : gap
        let errorHeight = condensed && inlineError != nil ? NativeSize.compactTarget : 0
        cardRects = visibleProjects.indices.map { i in
            CGRect(x: inset + (variant == .wide ? CGFloat(i) * (cardWidth + gap) : 0), y: inset + errorHeight + (variant == .tall ? CGFloat(i) * (cardHeight + rowGap) : 0), width: cardWidth, height: cardHeight)
        }
        content.frame.size = CGSize(width: max(viewport.width, variant == .wide ? CGFloat(count) * (cardWidth + gap) + inset * 2 - gap : viewport.width), height: max(viewport.height, errorHeight + (variant == .tall ? CGFloat(count) * (cardHeight + rowGap) + inset * 2 - rowGap : cardHeight + inset * 2)))
        var items: [NativeRenderItem] = []; content.styles = [:]; content.displayLabels = [:]; content.tints = [:]; content.schedules = [:]
        content.cardViewports = [:]; content.itemViewports = [:]; logicalCardItems = [:]; cardDocumentHeights = [:]
        func append(_ item: NativeRenderItem, _ style: ManagementCanvas.Style? = nil) { items.append(item); content.styles[item.id] = style }
        if count == 0 { append(NativeRenderItem(id: "projects.empty", rect: CGRect(x: inset, y: inset, width: max(0, viewport.width - inset * 2), height: NativeSize.compactTarget * 2), label: context.text(state.activity.loading ? "loading.label" : snapshot.board.projects.isEmpty ? "projects.empty" : "projects.hidden_done"), kind: .text, color: .textSecondary), .message) }
        for (index, project) in visibleProjects.enumerated() {
            let rect = cardRects[index], base = "project." + project.id.uuidString.lowercased(), x = rect.minX + NativeSpace.sm, inner = max(0, rect.width - NativeSpace.lg)
            if condensed {
                renderCompact(project, rect: rect, snapshot: snapshot, append: append)
                continue
            }
            append(NativeRenderItem(id: base + ".card", rect: rect, label: project.title, kind: .group), .card)
            append(NativeRenderItem(id: base + ".dot", rect: CGRect(x: x - NativeSpace.xs, y: rect.minY + NativeSpace.sm, width: NativeSize.compactTarget, height: NativeSize.compactTarget), label: "", kind: .text), .dot); content.tints[base + ".dot"] = project.colorHex
            append(NativeRenderItem(id: base + ".title", rect: CGRect(x: x + NativeSpace.lg, y: rect.minY + NativeSpace.xs, width: max(0, inner - NativeSize.compactTarget * 4 - NativeSpace.lg), height: NativeSize.compactTarget * 2), label: project.title, kind: .button), .title)
            append(NativeRenderItem(id: base + ".status", rect: CGRect(x: rect.maxX - NativeSize.compactTarget * 4 - NativeSpace.sm, y: rect.minY + NativeSpace.sm, width: NativeSize.compactTarget * 4, height: NativeSize.compactTarget), label: context.text(ManagementCopy.status(project.status)), kind: .button, fill: .projectStatusBg), .status)
            if let target = project.targetDay { append(NativeRenderItem(id: base + ".badge", rect: CGRect(x: rect.maxX - NativeSize.compactTarget * 4, y: rect.minY + NativeSize.compactTarget + NativeSpace.sm, width: NativeSize.compactTarget * 3, height: NativeSize.compactTarget), label: DeadlineRows.badge(day: target, today: snapshot.clock.today, context: context), kind: .badge, color: target < snapshot.clock.today ? .danger : .textSecondary), .secondary) }
            let scheduleRect = CGRect(x: x, y: rect.minY + NativeSize.compactTarget * 2 + NativeSpace.xs, width: inner, height: max(NativeSize.compactTarget, rect.height - NativeSize.compactTarget * 5 - NativeSpace.sm))
            content.schedules[base] = scheduleRect
            let linked = events(project), rows = max(1, Int(scheduleRect.height / NativeSize.compactTarget)), capacity = max(1, rows - (linked.count > rows ? 1 : 0))
            let limit = max(0, linked.count - capacity)
            let offset = min(max(0, schedules[project.id] ?? 0), limit)
            displayedSchedules[project.id] = (offset, limit)
            if linked.isEmpty { append(NativeRenderItem(id: base + ".events.empty", rect: scheduleRect, label: context.text("projects.no_events"), kind: .text, color: .textQuiet), .secondary) }
            for (i, event) in linked.dropFirst(offset).prefix(capacity).enumerated() {
                let day = DateOnly(date: event.item.start, timeZone: TimeZone(identifier: snapshot.environment.timeZone) ?? .current) ?? snapshot.clock.today
                let dateText = ManagementCopy.date(day, context: context)
                let time = event.item.allDay ? context.text("event.all_day") : DayMath.text(event.item.start, format: "HH:mm", timeZone: TimeZone(identifier: snapshot.environment.timeZone) ?? .current, locale: Locale(identifier: snapshot.environment.localeIdentifier))
                append(NativeRenderItem(id: base + ".event." + event.id, rect: CGRect(x: x, y: scheduleRect.minY + CGFloat(i) * NativeSize.compactTarget, width: inner, height: NativeSize.compactTarget), label: dateText + "  " + time + "  " + event.item.title, kind: .button), .secondary)
            }
            if linked.count > rows {
                content.displayLabels[base + ".events.previous"] = "↑"; content.displayLabels[base + ".events.next"] = "↓"
                let y = scheduleRect.minY + CGFloat(capacity) * NativeSize.compactTarget
                append(NativeRenderItem(id: base + ".events.previous", rect: CGRect(x: x, y: y, width: inner / 2, height: NativeSize.compactTarget), label: context.text("a11y.previous_project_schedule", values: ["0": project.title]), kind: .button, enabled: offset > 0), .plain)
                append(NativeRenderItem(id: base + ".events.next", rect: CGRect(x: x + inner / 2, y: y, width: inner / 2, height: NativeSize.compactTarget), label: context.text("a11y.next_project_schedule", values: ["0": project.title]), kind: .button, enabled: offset + capacity < linked.count), .plain)
            }
            let progressY = rect.maxY - NativeSize.compactTarget * 2 - NativeSpace.md
            append(NativeRenderItem(id: base + ".progress.label", rect: CGRect(x: x, y: progressY, width: NativeSize.compactTarget * 2.5, height: NativeSize.compactTarget), label: context.text("projects.progress"), kind: .text), .secondary)
            let slider = CGRect(x: x + NativeSize.compactTarget * 2.5, y: progressY, width: max(0, inner - NativeSize.compactTarget * 4), height: NativeSize.compactTarget)
            append(NativeRenderItem(id: base + ".progress", rect: slider, label: context.text("a11y.project_progress", values: ["project": project.title]), kind: .slider, value: "\(project.progress)%", slider: NativeSliderMetadata(orientation: .horizontal, minimumValue: 0, maximumValue: 100, value: Double(project.progress))), .progress(project.progress)); content.tints[base + ".progress"] = project.colorHex
            append(NativeRenderItem(id: base + ".percent", rect: CGRect(x: slider.maxX, y: progressY, width: NativeSize.compactTarget * 1.5, height: NativeSize.compactTarget), label: "\(project.progress)%", kind: .text), .secondary)
            let bottom = rect.maxY - NativeSize.compactTarget - NativeSpace.sm
            append(NativeRenderItem(id: base + ".target", rect: CGRect(x: x, y: bottom, width: max(0, inner - NativeSize.compactTarget * 4.5), height: NativeSize.compactTarget), label: context.text("projects.target", values: ["0": project.targetDay.map { ManagementCopy.date($0, context: context) } ?? context.text("projects.set_date")]), kind: .button), .secondary)
            append(NativeRenderItem(id: base + ".add", rect: CGRect(x: rect.maxX - NativeSize.compactTarget * 4.5 - NativeSpace.sm, y: bottom, width: NativeSize.compactTarget * 3.5, height: NativeSize.compactTarget), label: context.text("projects.link_event"), kind: .button), .secondary)
            append(NativeRenderItem(id: base + ".menu", rect: CGRect(x: rect.maxX - NativeSize.compactTarget - NativeSpace.sm, y: bottom, width: NativeSize.compactTarget, height: NativeSize.compactTarget), label: context.text("a11y.item_options", values: ["0": project.title]), kind: .button), .plain); content.displayLabels[base + ".menu"] = "···"
        }

        if let error = inlineError { append(NativeRenderItem(id: "projects.error", rect: CGRect(x: inset, y: 0, width: viewport.width, height: NativeSize.compactTarget), label: context.text(error.messageKey), kind: .button, color: .danger)) }
        content.update(items: items); scroll.updateFade()
    }
    private func renderCompact(_ project: Project, rect: CGRect, snapshot: BoardSnapshot, append: (NativeRenderItem, ManagementCanvas.Style?) -> Void) {
        let base = "project." + project.id.uuidString.lowercased(), row = NativeSize.compactTarget
        let x = rect.minX + NativeSpace.sm, inner = max(0, rect.width - NativeSpace.lg)
        let tiny = heightStep == .tiny, badgeWidth = row * 3, statusWidth = row * 4
        let linked = events(project)
        let scheduleY = tiny ? row * 5 + NativeSpace.xxs : row * 3
        let controlsY = tiny ? row * 4 + NativeSpace.xxs : scheduleY + row * (linked.count > 1 ? 2 : 1)
        let documentHeight = max(rect.height, max(controlsY + row, scheduleY + row * (linked.count > 1 ? 2 : 1)) + NativeSpace.xs)
        cardDocumentHeights[base] = documentHeight
        let offset = min(max(0, cardOffsets[base] ?? 0), max(0, documentHeight - rect.height))
        cardOffsets[base] = offset; content.cardViewports[base] = rect
        append(NativeRenderItem(id: base + ".card", rect: rect, label: project.title, kind: .group), .card)
        func add(_ suffix: String, x itemX: CGFloat = 0, y: CGFloat, width: CGFloat, label: String, kind: NativeRenderItem.Kind = .button, style: ManagementCanvas.Style = .secondary, value: String? = nil, slider: NativeSliderMetadata? = nil, fill: NativeColorToken? = nil, enabled: Bool = true) {
            let logical = CGRect(x: x + itemX, y: rect.minY + y, width: max(0, width), height: row)
            logicalCardItems[base + suffix] = logical
            let painted = logical.offsetBy(dx: 0, dy: -offset)
            var item = NativeRenderItem(id: base + suffix, rect: painted, label: label, kind: kind, value: value, enabled: enabled, fill: fill, slider: slider)
            let hit = painted.intersection(rect); item.interactionRect = hit.isNull ? .zero : hit
            content.itemViewports[item.id] = rect; append(item, style)
        }
        add(".title", y: 0, width: inner - (tiny ? badgeWidth : statusWidth), label: project.title, style: .singleTitle)
        if tiny, let target = project.targetDay {
            add(".badge", x: inner - badgeWidth, y: 0, width: badgeWidth, label: DeadlineRows.badge(day: target, today: snapshot.clock.today, context: context), kind: .badge)
        }
        add(".status", x: tiny ? 0 : inner - statusWidth, y: tiny ? row * 2 + NativeSpace.xxs : 0, width: tiny ? inner : statusWidth, label: context.text(ManagementCopy.status(project.status)), style: .status, fill: .projectStatusBg)
        let progressY = tiny ? row : row * 2
        add(".progress", y: progressY, width: inner - row * 2, label: context.text("a11y.project_progress", values: ["project": project.title]), kind: .slider, style: tiny ? .progressSummary(project.progress) : .progress(project.progress), value: "\(project.progress)%", slider: NativeSliderMetadata(orientation: .horizontal, minimumValue: 0, maximumValue: 100, value: Double(project.progress)))
        content.tints[base + ".progress"] = project.colorHex
        add(".percent", x: inner - row * 2, y: progressY, width: row * 2, label: "\(project.progress)%", kind: .text)
        add(".target", y: tiny ? row * 3 + NativeSpace.xxs : row, width: tiny ? inner : inner - badgeWidth, label: context.text("projects.target", values: ["0": project.targetDay.map { ManagementCopy.date($0, context: context) } ?? context.text("projects.set_date")]))
        if !tiny, let target = project.targetDay {
            add(".badge", x: inner - badgeWidth, y: row, width: badgeWidth, label: DeadlineRows.badge(day: target, today: snapshot.clock.today, context: context), kind: .badge)
        }
        add(".add", y: controlsY, width: inner - row, label: context.text("projects.link_event"))
        add(".menu", x: inner - row, y: controlsY, width: row, label: context.text("a11y.item_options", values: ["0": project.title]), style: .plain)
        content.displayLabels[base + ".menu"] = "···"
        let limit = max(0, linked.count - 1)
        let scheduleOffset = min(max(0, schedules[project.id] ?? 0), limit)
        displayedSchedules[project.id] = (scheduleOffset, limit)
        if let event = linked.dropFirst(scheduleOffset).first {
            let zone = TimeZone(identifier: snapshot.environment.timeZone) ?? .current
            let day = DateOnly(date: event.item.start, timeZone: zone) ?? snapshot.clock.today
            let time = event.item.allDay ? context.text("event.all_day") : DayMath.text(event.item.start, format: "HH:mm", timeZone: zone, locale: Locale(identifier: snapshot.environment.localeIdentifier))
            add(".event." + event.id, y: scheduleY, width: inner, label: ManagementCopy.date(day, context: context) + "  " + time + "  " + event.item.title)
        } else { add(".events.empty", y: scheduleY, width: inner, label: context.text("projects.no_events"), kind: .text) }
        if linked.count > 1 {
            add(".events.previous", y: scheduleY + row, width: inner / 2, label: context.text("a11y.previous_project_schedule", values: ["0": project.title]), style: .plain, enabled: scheduleOffset > 0)
            add(".events.next", x: inner / 2, y: scheduleY + row, width: inner / 2, label: context.text("a11y.next_project_schedule", values: ["0": project.title]), style: .plain, enabled: scheduleOffset + 1 < linked.count)
            content.displayLabels[base + ".events.previous"] = "↑"; content.displayLabels[base + ".events.next"] = "↓"
        }
    }
    private func scrollCard(_ base: String, delta: CGFloat) {
        guard let rect = content.cardViewports[base], let documentHeight = cardDocumentHeights[base] else { return }
        let offset = min(max(0, (cardOffsets[base] ?? 0) + delta), max(0, documentHeight - rect.height))
        guard offset != cardOffsets[base] else { return }; cardOffsets[base] = offset; render()
    }
    private func revealCardItem(_ id: String) -> CGRect? {
        guard let logical = logicalCardItems[id], let rect = content.itemViewports[id],
              let base = content.cardViewports.first(where: { $0.value == rect })?.key else { return nil }
        let current = cardOffsets[base] ?? 0
        let desired = logical.minY < rect.minY + current ? logical.minY - rect.minY : logical.maxY > rect.maxY + current ? logical.maxY - rect.maxY : current
        if desired != current { scrollCard(base, delta: desired - current) }
        return rect
    }
    private func act(_ action: String) {
        if action == "projects.showDone" {
            var patch = SettingsPatch(); patch.showCompletedProjects = .set(!context.presentation.state.snapshot.board.settings.showCompletedProjects)
            if save(.settings(patch), undoable: false) != nil { ManagementCanvas.disclose(in: scroll, reduceMotion: context.presentation.state.snapshot.environment.reduceMotion) }
            return
        }
        if action == "projects.add" { openEditor(project: nil); return }
        if action == "projects.previous" || action == "projects.next" {
            let delta: CGFloat = action == "projects.previous" ? -1 : 1
            var origin = scroll.contentView.bounds.origin
            if variant == .wide { origin.x = min(max(0, content.bounds.width - scroll.contentSize.width), max(0, origin.x + delta * ((cardRects.first?.width ?? NativeSize.projectMinWidth) + NativeSpace.md))) }
            else { origin.y = min(max(0, content.bounds.height - scroll.contentSize.height), max(0, origin.y + delta * ((cardRects.first?.height ?? NativeSize.projectMinWidth) + NativeSpace.md))) }
            scroll.contentView.scroll(to: origin); scroll.reflectScrolledClipView(scroll.contentView); scroll.updateFade(); return
        }
        if action == "projects.error", let failedID { _ = context.presentation.send(inlineError?.committed == .unknown ? .reconcile(failedID) : .retry(failedID)); return }
        guard let project = project(for: action) else { return }
        let prefix = "project." + project.id.uuidString.lowercased()
        switch action {
        case prefix + ".title", prefix + ".target": openEditor(project: project)
        case prefix + ".status", prefix + ".menu":
            let menu = menu(for: project.id)
            if let item = content.items.first(where: { $0.id == action }), content.window != nil { menu.popUp(positioning: nil, at: CGPoint(x: item.rect.minX, y: item.rect.maxY), in: content) }
        case prefix + ".events.previous": moveSchedule(prefix, delta: -1)
        case prefix + ".events.next": moveSchedule(prefix, delta: 1)
        case prefix + ".add": context.routing.route(.openAdd(AddRequest(kind: .event, projectID: project.id, anchor: anchor(action, target: .control(action)))))
        default:
            if let event = events(project).first(where: { action == prefix + ".event." + $0.id }) {
                context.routing.route(.openEvent(eventID: event.id, anchor: anchor(action, target: .event(event.id))))
            }
        }
    }
    private func setProgress(_ action: String, value: Int) {
        guard let project = project(for: action) else { return }; let clamped = min(100, max(0, value)); guard clamped != project.progress else { return }
        progressDesired[project.id] = clamped; render(); flushProgress(project.id)
    }
    private func flushProgress(_ id: UUID) {
        guard !disposed, progressInFlight[id] == nil, progressUnknown[id] == nil, let desired = progressDesired[id] else { return }
        guard let current = context.presentation.state.snapshot.board.projects.first(where: { $0.id == id }) else { progressDesired[id] = nil; return }
        guard desired != current.progress else { progressDesired[id] = nil; render(); return }
        guard let handle = save(.project(.update(id: id, patch: ProjectPatch(progress: .set(desired)))), feedback: "toast.project_progress") else {
            progressDesired[id] = nil; inlineError = context.presentation.state.lastError; render(); return
        }
        progressInFlight[id] = handle.id
        Task { [weak self] in
            let receipt = await handle.settled.value
            guard let self, !self.disposed else { return }
            self.progressInFlight[id] = nil
            if case .failure(let failure, _) = receipt {
                if failure.committed == .unknown { self.progressUnknown[id] = handle.id; self.render(); return }
                if failure.committed == .no, self.progressDesired[id] == desired { self.progressDesired[id] = nil }
            }
            // BoardPresentation consumes the same receipt and publishes the fresh base before the next submission.
            await Task.yield()
            self.flushProgress(id); self.render()
        }
    }
    private func moveSchedule(_ prefix: String, delta: Int) {
        guard let project = visibleProjects.first(where: { prefix == "project." + $0.id.uuidString.lowercased() }) else { return }
        guard let displayed = displayedSchedules[project.id] else { return }
        let next = max(0, min(displayed.limit, displayed.offset + delta))
        guard next != displayed.offset else { return }; schedules[project.id] = next; render()
    }
    func menu(for id: UUID) -> NSMenu {
        retainedMenu?.dispose()
        guard let project = context.presentation.state.snapshot.board.projects.first(where: { $0.id == id }) else { return NSMenu() }
        var entries = [NativeMenuEntry(id: "rename", title: context.text("projects.rename"))]
        entries += ProjectStatus.allCases.map { NativeMenuEntry(id: $0.rawValue, title: context.text(ManagementCopy.status($0)), checked: $0 == project.status) }
        entries.append(NativeMenuEntry(id: "delete", title: context.text("projects.delete")))
        let menu = NativeMenu(items: entries) { [weak self] action in
            guard let self else { return }
            if action == "delete" { guard self.editor?.canDismiss != false else { return }; self.closeEditor(); _ = self.save(.project(.delete(id: id)), feedback: "toast.project_deleted") }
            else if action == "rename" { self.openEditor(project: project) }
            else if let status = ProjectStatus(rawValue: action) { _ = self.save(.project(.update(id: id, patch: ProjectPatch(status: .set(status)))), feedback: status == .done ? "toast.project_done" : "toast.project_status") }
        }
        retainedMenu = menu; return menu.menu
    }
    private func openEditor(project: Project?) {
        guard editor?.canDismiss != false else { return }
        closeEditor(); let id = project?.id ?? UUID()
        let editor = ProjectDeadlineEditor(context: context, kind: .project, id: id, title: project?.title ?? "", day: project?.targetDay, status: project?.status ?? .active, creating: project == nil) { [weak self] title, day, status in
            guard let self else { return nil }
            if project == nil { return self.save(.project(.create(ProjectInput(id: id, title: title, status: status, targetDay: day))), feedback: "toast.project_added") }
            return self.save(.project(.update(id: id, patch: ProjectPatch(title: project?.title == title ? .unchanged : .set(title), targetDay: project?.targetDay == day ? .unchanged : .set(day)))), feedback: project?.targetDay != day ? "toast.project_target" : "toast.renamed")
        }
        self.editor = editor; editor.onClose = { [weak self, weak editor] in if self?.editor === editor { self?.closeEditor() } }
        let action = project.map { "project." + $0.id.uuidString.lowercased() + ".title" }
        if let rect = content.items.first(where: { $0.id == action })?.rect {
            // AppKit will not show a popover anchored outside the scroll viewport.
            // Compact cards may also need to reveal their title inside the card;
            // that can rebuild the item geometry, so resolve the anchor again.
            content.scrollToVisible(rect); scroll.updateFade()
            if let anchor = content.items.first(where: { $0.id == action })?.rect { editor.show(relativeTo: anchor, of: content) }
        }
        else { editor.show(relativeTo: surface.items.first(where: { $0.id == "projects.add" })?.rect ?? surface.bounds, of: surface) }
    }
    func closeEditor() { let old = editor; editor = nil; old?.dispose() }
    @discardableResult private func save(_ edit: BoardEdit, undoable: Bool = true, feedback: String? = nil) -> OperationHandle? {
        inlineError = nil; failedID = nil
        let handle = context.presentation.send(.edit(edit, undoable: undoable, feedback: feedback.map { PresentationFeedback(messageKey: $0) }))
        if let handle { Task { [weak self] in
            let receipt = await handle.settled.value
            guard let self, !self.disposed else { return }
            if case .failure(let error, _) = receipt { self.inlineError = error; self.failedID = handle.id }
            self.render()
        } } else { inlineError = context.presentation.state.lastError; render() }
        return handle
    }
    func dispose() {
        guard !disposed else { return }; disposed = true; lifetime.dispose(); closeEditor(); retainedMenu?.dispose(); retainedMenu = nil
        progressDesired = [:]; progressInFlight = [:]; progressUnknown = [:]
        if let layer = scroll.contentView.layer { NativeMotion.stop(layer) }
        surface.onLayout = nil; content.onScheduleScroll = nil; content.onProgress = nil
        content.onCardScroll = nil; content.onRevealCardItem = nil; content.cardViewports = [:]; content.itemViewports = [:]
        scroll.dispose(); content.dispose(); surface.dispose()
    }
}
