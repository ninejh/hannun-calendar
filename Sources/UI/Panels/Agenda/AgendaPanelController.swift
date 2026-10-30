import AppKit

struct AgendaProjection: Equatable {
    var day: DateOnly
    var rows: [EventRecord]
    var next: EventRecord?
    var todayRows: [EventRecord]

    init(state: PresentationState, day: DateOnly? = nil) {
        let snapshot = state.snapshot
        self.day = day ?? state.view.selectedDay
        let zone = TimeZone(identifier: snapshot.clock.timeZone) ?? TimeZone(secondsFromGMT: 0)!
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let visible = snapshot.calendar.records.filter { !snapshot.board.hiddenCalendarIDs.contains($0.item.calendarID) }
        func on(_ day: DateOnly) -> [EventRecord] {
            // DateOnly's bridge accessor intentionally returns noon. Agenda needs civil-day
            // boundaries, including 23/25-hour DST days and the last representable DateOnly.
            let start = calendar.startOfDay(for: day.date(in: zone))
            let end = calendar.date(byAdding: .day, value: 1, to: start)!
            return visible.filter { $0.item.start < end && ($0.item.end > start || $0.item.start == start) }
                .sorted {
                    let a = $0.item.allDay || $0.item.start < start ? start : $0.item.start
                    let b = $1.item.allDay || $1.item.start < start ? start : $1.item.start
                    return a == b ? $0.id < $1.id : a < b
                }
        }
        rows = on(self.day)
        todayRows = on(snapshot.clock.today)
        next = todayRows.first { !$0.item.allDay && $0.item.start >= snapshot.clock.now.date }
    }
}

/// Same rows and root routes for the stable Today panel and the independent fallback surface.
/// readOnly disables local mutations; original-calendar edits always belong to the root event overlay.
@MainActor final class AgendaPanelController: PanelController {
    let panelID: PanelID = .today
    let surface: AgendaPanelView
    var view: NSView { surface }
    let list: AgendaListView
    let scroll = OverflowScrollView(frame: .zero)
    private(set) var projection: AgendaProjection
    private let context: BoardScreenContext
    private let lifetime = ScreenLifetime()
    private var fixedDay: DateOnly?
    private let readOnly: Bool
    private var variant: SlotVariant = .tall
    private var heightStep: PanelSizeStep = .regular
    private var slot: SlotID?
    private var editLeading: CGFloat = 0
    private var editBottom: CGFloat = 0
    private var editExclusions: [CGRect] = []
    private var lastMinute: Int64 = -1
    private var lastClockDay: DateOnly?
    private var lastClockZone: String?
    private var disposed = false
    private var parked = false
    private let timeFormatter = DateFormatter()
    private let dayFormatter = DateFormatter()

    init(context: BoardScreenContext, day: DateOnly? = nil, readOnly: Bool = false) {
        self.context = context; fixedDay = day; self.readOnly = readOnly
        projection = AgendaProjection(state: context.presentation.state, day: day)
        surface = AgendaPanelView(focus: context.focus); list = AgendaListView(focus: context.focus)
        surface.setAccessibilityIdentifier(readOnly ? "agenda-fallback" : "agenda-panel")
        context.bindPanelMenus(to: surface)
        list.setAccessibilityIdentifier(readOnly ? "agenda-fallback-list" : "agenda-list")
        scroll.documentView = list; surface.addSubview(scroll)
        surface.onLayout = { [weak self] in self?.layout() }
        surface.onAction = { [weak self] id in self?.act(id) }
        list.onAction = { [weak self] id in self?.act(id) }
        lifetime.own(context.presentation.subscribe { [weak self] change in
            guard let self, !self.disposed, !self.parked else { return }
            let domains: Set<PresentationDomain> = [.board, .calendar, .view, .clock, .environment, .activity, .error]
            guard !change.domains.isDisjoint(with: domains) else { return }
            if change.domains == [.clock] {
                let minute = Int64(self.context.presentation.state.snapshot.clock.now.date.timeIntervalSince1970 / 60)
                let clock = self.context.presentation.state.snapshot.clock
                guard minute != self.lastMinute || clock.today != self.lastClockDay || clock.timeZone != self.lastClockZone else { return }
            }
            self.render()
        })
    }
    func setVariant(_ variant: SlotVariant) { guard self.variant != variant else { return }; self.variant = variant; if !parked { layout() } }
    func setPlacement(slot: SlotID?, variant: SlotVariant) {
        self.slot = slot
        parked = slot == nil
        setVariant(variant); surface.isHidden = slot == nil
        if slot != nil { refresh() }
    }
    func setPlacement(_ placement: PanelPlacement) {
        heightStep = placement.heightStep
        editLeading = placement.editLeading; editBottom = placement.editBottom; editExclusions = placement.editExclusions
        variant = placement.shape == .wide ? .wide : .tall
        setPlacement(slot: placement.slot, variant: variant)
    }
    func reveal(_ target: PanelReveal) {
        switch target {
        case .day(let day):
            if fixedDay != nil { fixedDay = day }
            else if context.presentation.state.view.selectedDay != day { context.presentation.send(.selectDay(day)) }
            scroll.contentView.scroll(to: .zero); render()
        case .item(let id):
            if let rect = list.items.first(where: { $0.id == prefix + "open-" + id })?.rect { list.scrollToVisible(rect) }
        case .scrollTo(let id): context.focus.focus(id)
        }
    }
    func refresh() { guard !disposed else { return }; render() }
    private func render() {
        let state = context.presentation.state
        let previous = projection.day
        projection = AgendaProjection(state: state, day: fixedDay)
        lastMinute = Int64(state.snapshot.clock.now.date.timeIntervalSince1970 / 60)
        lastClockDay = state.snapshot.clock.today; lastClockZone = state.snapshot.clock.timeZone
        if surface.theme.appearance != state.snapshot.environment.resolvedAppearance { surface.theme = NativeTheme(appearance: state.snapshot.environment.resolvedAppearance) }
        if list.theme.appearance != surface.theme.appearance { list.theme = surface.theme }
        let locale = Locale(identifier: state.snapshot.board.settings.language == .ko ? "ko_KR" : state.snapshot.environment.localeIdentifier)
        timeFormatter.locale = locale; timeFormatter.timeZone = zone; timeFormatter.dateFormat = "HH:mm"
        dayFormatter.locale = Locale(identifier: state.snapshot.board.settings.language == .ko ? "ko_KR" : "en_US")
        dayFormatter.calendar = Calendar(identifier: .gregorian); dayFormatter.timeZone = zone
        dayFormatter.setLocalizedDateFormatFromTemplate("MMM d EEE")
        surface.setAccessibilityLabel(context.text("a11y.agenda")); list.setAccessibilityLabel(context.text("a11y.agenda"))
        if previous != projection.day { scroll.contentView.scroll(to: .zero) }
        layout()
    }
    private func layout() {
        guard !disposed, !parked else { return }
        let state = context.presentation.state, width = surface.bounds.width, height = surface.bounds.height
        let metrics = NativePanelStepMetrics(panel: panelID, shape: variant == .wide ? .wide : .rail, step: heightStep)
        let compact = heightStep == .tiny || heightStep == .small
        let baseHeader = compact ? metrics.headerHeight : NativeSize.toolbarHeight + NativeSpace.lg
        let inset = compact ? metrics.horizontalPadding : NativeSpace.xl
        let contentWidth = max(0, width - inset * 2)
        let wide = variant == .wide
        let summaryWidth = wide ? contentWidth / 3 : contentWidth
        let nextHeight = heightStep == .tiny ? NativeSpace.xl : heightStep == .small ? NativeSize.compactTarget + NativeSpace.xxs : NativeSize.compactTarget + NativeSpace.sm
        let selected = projection.day != state.snapshot.clock.today
        let useSelectedHeader = selected && !readOnly
        let backLabel = context.text("today.back_to_today")
        let backWidth = max(44, ceil((backLabel as NSString).size(withAttributes: [.font: NativeFont.primary]).width) + NativeSpace.sm * 2)
        let controlHeight: CGFloat = useSelectedHeader ? 44 : min(NativeSize.compactTarget, baseHeader)
        let addWidth: CGFloat = readOnly ? 0 : controlHeight
        let headerTop = heightStep == .tiny ? 0 : NativeSpace.xs
        let titleX = max(inset, editLeading)
        let titleWidth = max(0, (useSelectedHeader ? contentWidth : contentWidth - addWidth - NativeSpace.sm) - (titleX - inset))
        let dateFormatter = DateFormatter(); dateFormatter.locale = dayFormatter.locale; dateFormatter.calendar = dayFormatter.calendar; dateFormatter.timeZone = zone
        dateFormatter.setLocalizedDateFormatFromTemplate(projection.day.year == state.snapshot.clock.today.year ? "EEEE MMMM d" : "y EEEE MMMM d")
        let heading = selected ? dateFormatter.string(from: projection.day.date(in: zone)) : context.text("today.title")
        let attrs = NativeFont.attributes(font: NativeFont.sectionHead, color: surface.theme.color(.textPrimary), truncation: .byWordWrapping)
        let measured = ceil((heading as NSString).boundingRect(with: CGSize(width: max(1, titleWidth), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs).height) + NativeSpace.xs
        let otherYear = projection.day.year != state.snapshot.clock.today.year
        let sample = state.snapshot.board.settings.language == .ko ? (otherYear ? "8888년 12월 30일 수요일" : "12월 30일 수요일") : (otherYear ? "Wednesday, September 30, 8888" : "Wednesday, September 30")
        let reserved = ceil((sample as NSString).boundingRect(with: CGSize(width: max(1, titleWidth), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs).height) + NativeSpace.xs
        let canReserve = headerTop + reserved + controlHeight + NativeSize.compactTarget + NativeSpace.sm <= height
        let titleHeight = useSelectedHeader ? (canReserve ? max(measured, reserved) : measured) : controlHeight
        let header = useSelectedHeader ? headerTop + titleHeight + controlHeight : baseHeader
        let titleRect = CGRect(x: titleX, y: headerTop, width: titleWidth, height: titleHeight)
        var items = [NativeRenderItem(id: prefix + "title", rect: titleRect, label: heading, kind: .text)]
        let count = context.text(projection.rows.count == 1 ? "calendar.events.one" : "calendar.events.other", values: ["0": String(projection.rows.count)])
        let meta = dayFormatter.string(from: projection.day.date(in: zone)) + " · " + count
        if !compact && !useSelectedHeader {
            items.append(NativeRenderItem(id: prefix + "date", rect: CGRect(x: header - NativeSpace.lg < 32 ? titleX : inset, y: header - NativeSpace.lg, width: header - NativeSpace.lg < 32 ? max(0, width - inset - titleX) : contentWidth, height: NativeSpace.lg), label: meta, kind: .text, color: .textSecondary))
        } else { items[0].value = useSelectedHeader ? count : meta }
        if useSelectedHeader {
            let backX = headerTop + titleHeight < 32 ? titleX : inset
            items.append(NativeRenderItem(id: "agenda-back-today", rect: CGRect(x: backX, y: headerTop + titleHeight, width: backWidth, height: controlHeight), label: backLabel, kind: .button, value: backLabel, color: .accentBlue, minimumTarget: 44))
            let countWidth = ceil((count as NSString).size(withAttributes: [.font: NativeFont.badge]).width)
            let countX = backX + backWidth + NativeSpace.sm
            if countX + countWidth + NativeSpace.sm <= width - inset - addWidth {
                items.append(NativeRenderItem(id: prefix + "date", rect: CGRect(x: countX, y: headerTop + titleHeight + (controlHeight - NativeSpace.lg) / 2, width: countWidth, height: NativeSpace.lg), label: count, kind: .text, color: .textSecondary))
            }
        }
        if !readOnly {
            items.append(NativeRenderItem(id: "agenda-add", rect: CGRect(x: width - inset - addWidth, y: useSelectedHeader ? headerTop + titleHeight : headerTop, width: addWidth, height: controlHeight), label: context.text("toolbar.new_event"), kind: .button, minimumTarget: controlHeight))
        }
        if let slot, !readOnly, !editExclusions.isEmpty {
            items[0] = NativePanelHeader.decorate(items[0], geometry: PanelHeaderGeometry(slot: slot, titleRect: titleRect,
                headerRect: metrics.regions(in: surface.bounds, headerHeight: header).headerRect,
                excludedRects: items.filter { $0.id == "agenda-add" || $0.id == "agenda-back-today" }.map(\.hitRect) + editExclusions, actionLabel: context.text("slot_menu.title")))
        }
        let showNext = fixedDay == nil && !projection.todayRows.isEmpty
        let summaryInScroll = showNext && useSelectedHeader && !wide && heightStep == .tiny
        var scrolledSummary: NativeRenderItem?
        if showNext {
            let next = projection.next
            let title = next.map { context.text(selected ? "today.next_today_label" : "today.next_label", values: ["0": $0.item.title]) } ?? context.text("today.no_more_timed")
            let remaining = next.map { max(0, Int(ceil($0.item.start.timeIntervalSince(state.snapshot.clock.now.date) / 60))) } ?? 0
            let time = next.map { remaining < 60 ? context.text("today.in_minutes", values: ["0": String(remaining)]) : context.text("today.at_time", values: ["0": timeFormatter.string(from: $0.item.start)]) } ?? ""
            let summaryX = !summaryInScroll && header + NativeSpace.xs < 32 ? titleX : inset
            let summary = NativeRenderItem(id: "agenda-next", rect: CGRect(x: summaryX, y: summaryInScroll ? 0 : header + NativeSpace.xs, width: max(0, summaryWidth - (wide ? NativeSpace.md : 0) - (summaryX - inset)), height: nextHeight), label: title, kind: .badge, value: time, fill: .raised, radius: NativeRadius.input)
            if summaryInScroll { scrolledSummary = summary } else { items.append(summary) }
        }
        let listY = max(editLeading, !showNext || wide || summaryInScroll ? header + NativeSpace.xs : header + nextHeight + NativeSpace.sm)
        let listX = wide ? inset + summaryWidth : 0
        let rowMetrics = metrics.listRow!
        let rowHeight = rowMetrics.height, rowGap = rowMetrics.gap
        let normalBottom = heightStep == .small ? metrics.bottomPadding : NativeSpace.sm
        let narrowForHandle = editBottom > 0 && height - listY - max(editBottom, normalBottom) < NativeSize.compactTarget
        let availableHeight = max(0, height - listY - (narrowForHandle ? normalBottom : max(editBottom, normalBottom)))
        let rowLimit = heightStep == .tiny ? 1 : heightStep == .small ? (wide ? 2 : 3) : Int.max
        let rowBudget = CGFloat(rowLimit == Int.max ? 0 : rowLimit) * rowHeight + CGFloat(rowLimit == Int.max ? 0 : rowLimit - 1) * rowGap
        let viewportHeight = rowLimit == Int.max ? availableHeight : min(availableHeight, editBottom > 0 ? max(NativeSize.compactTarget, rowBudget) : rowBudget)
        scroll.frame = CGRect(x: listX, y: listY, width: max(0, width - listX - (narrowForHandle ? editBottom : 0)), height: viewportHeight)
        let columns = wide ? 2 : 1
        let documentWidth = scroll.contentSize.width
        let available = max(0, documentWidth - inset * 2 - (columns == 2 ? NativeSpace.md : 0))
        let columnWidth = available / CGFloat(columns)
        let listOffset = scrolledSummary.map { $0.rect.height + NativeSpace.xs } ?? 0
        var counters = [0, 0], rowItems: [NativeRenderItem] = []
        var details: [String: AgendaRowPaint] = [:]
        for (index, event) in projection.rows.enumerated() {
            let hour = Calendar(identifier: .gregorian).dateComponents(in: zone, from: event.item.start).hour ?? 0
            // Tiny shows two chronological events; larger steps retain morning/afternoon columns.
            let column = wide && heightStep == .tiny ? index % columns : columns == 2 && !event.item.allDay && event.item.start >= dayStart && hour >= 12 ? 1 : 0
            let rect = CGRect(x: inset + CGFloat(column) * (columnWidth + NativeSpace.md), y: listOffset + CGFloat(counters[column]) * (rowHeight + rowGap), width: columnWidth, height: rowHeight)
            counters[column] += 1
            let pinned = state.snapshot.board.pinnedEventKeys.contains(event.pinKey)
            let projectID = state.snapshot.board.eventProjectLinks[event.pinKey] ?? state.snapshot.board.eventProjectLinks[event.id]
            let project = state.snapshot.board.projects.first { $0.id.uuidString.lowercased() == projectID?.lowercased() }
            let source = event.item.calendarTitle + (event.item.writable ? "" : " · " + context.text("event.readonly_calendar_help"))
            let label = [timeLabel(event), event.item.title, project?.title, source].compactMap { $0 }.joined(separator: " · ")
            let id = prefix + "open-" + event.id
            let pinWidth = readOnly ? 0 : NativeSize.compactTarget + NativeSpace.xs
            let open = CGRect(x: rect.minX, y: rect.minY, width: max(0, rect.width - pinWidth), height: rowHeight)
            rowItems.append(NativeRenderItem(id: id, rect: open, label: label, kind: .button, minimumTarget: min(rowHeight, NativeSize.compactTarget)))
            details[id] = AgendaRowPaint(event: event, time: timeLabel(event), source: source, project: project?.title, colorHex: project?.colorHex ?? event.item.colorHex, compact: compact)
            if !readOnly {
                let pinHeight = min(rowHeight, NativeSize.compactTarget)
                rowItems.append(NativeRenderItem(id: "agenda-pin-" + event.id, rect: CGRect(x: rect.maxX - NativeSize.compactTarget, y: rect.midY - pinHeight / 2, width: NativeSize.compactTarget, height: pinHeight), label: context.text(pinned ? "a11y.unpin" : "a11y.pin", values: ["title": event.item.title]), kind: .button, value: pinned ? "★" : "☆", checked: pinned, color: pinned ? .warning : .textQuiet, minimumTarget: pinHeight))
            }
        }
        let loading = state.activity.loading || state.activity.refreshing
        if rowItems.isEmpty {
            let error = state.lastError
            let label = loading ? context.text("loading.label") : error.map { context.text($0.messageKey, values: $0.values) } ?? context.text("today.empty")
            rowItems.append(NativeRenderItem(id: prefix + "status", rect: CGRect(x: inset, y: listOffset + (compact ? 0 : NativeSpace.sm), width: max(0, documentWidth - inset * 2), height: rowHeight * 2), label: label, kind: .text, color: error == nil ? .textQuiet : .danger))
        }
        if let scrolledSummary { rowItems.insert(scrolledSummary, at: 0) }
        let contentHeight = rowItems.map(\.rect.maxY).max() ?? 0
        list.frame = CGRect(x: 0, y: 0, width: documentWidth, height: max(scroll.contentSize.height, contentHeight + NativeSpace.xs))
        list.details = details; list.update(items: rowItems); surface.update(items: items); scroll.updateFade()
    }
    private var prefix: String { readOnly ? "agenda-fallback-" : "agenda-" }
    private var zone: TimeZone { TimeZone(identifier: context.presentation.state.snapshot.clock.timeZone) ?? TimeZone(secondsFromGMT: 0)! }
    private var dayStart: Date {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        return calendar.startOfDay(for: projection.day.date(in: zone))
    }
    private func timeLabel(_ event: EventRecord) -> String {
        if event.item.allDay { return context.text("calendar.all_day") }
        let start = dayStart
        if event.item.start < start {
            if DateOnly(date: event.item.end, timeZone: zone) != projection.day { return context.text("calendar.continues") }
            return context.text("calendar.until", values: ["0": timeFormatter.string(from: event.item.end)])
        }
        return timeFormatter.string(from: event.item.start)
    }
    private func act(_ id: String) {
        if id == "agenda-back-today" { context.presentation.send(.followToday); return }
        if id == "agenda-add", !readOnly {
            let rect = surface.items.first { $0.id == id }?.rect ?? .zero
            let anchor = StableAnchor(target: .control(id), boardRect: boardRect(rect, from: surface), returnFocusID: FocusID(id))
            context.routing.route(.openAdd(AddRequest(kind: .event, day: projection.day, anchor: anchor))); return
        }
        if let event = projection.rows.first(where: { prefix + "open-" + $0.id == id }), let item = list.items.first(where: { $0.id == id }) {
            let anchor = StableAnchor(target: .event(event.id), boardRect: boardRect(item.rect, from: list), returnFocusID: FocusID(id))
            context.routing.route(.openEvent(eventID: event.id, anchor: anchor))
        } else if !readOnly, let event = projection.rows.first(where: { "agenda-pin-" + $0.id == id }) {
            let pinned = context.presentation.state.snapshot.board.pinnedEventKeys.contains(event.pinKey)
            context.presentation.send(.edit(.pin(EventIdentity(id: event.id), !pinned), undoable: true, feedback: PresentationFeedback(messageKey: pinned ? "toast.unpinned" : "toast.pinned")))
        }
    }
    private func boardRect(_ rect: CGRect, from source: NSView) -> CGRect {
        guard let board = source.window?.contentView else { return source.convert(rect, to: nil) }
        return source.convert(rect, to: board)
    }
    func dispose() {
        guard !disposed else { return }; disposed = true
        lifetime.dispose(); surface.onLayout = nil; surface.dispose(); list.dispose(); scroll.dispose()
    }
}

/// Composition may inject this for OverlayKind.agenda without coupling Calendar or Overlay screens.
@MainActor final class AgendaFallbackController: OverlayController {
    let kind: OverlayKind = .agenda
    let agenda: AgendaPanelController
    var view: NSView { agenda.view }
    init(context: BoardScreenContext) {
        agenda = AgendaPanelController(context: context, day: context.presentation.state.view.selectedDay, readOnly: true)
    }
    func present(_ request: BoardRoute) {
        if case .revealAgenda(let day, _) = request { agenda.reveal(.day(day)) }
        view.isHidden = false; agenda.refresh()
    }
    func dismiss() { view.isHidden = true }
    func dispose() { agenda.dispose() }
}

@MainActor private func paintAgendaSummary(_ item: NativeRenderItem, theme: NativeTheme) {
    if let fill = item.fill { theme.color(fill).setFill(); NSBezierPath(roundedRect: item.rect, xRadius: item.radius, yRadius: item.radius).fill() }
    let time = item.value ?? ""
    let timeWidth = (time as NSString).size(withAttributes: [.font: NativeFont.badge]).width
    let y = item.rect.midY - NativeSpace.sm
    theme.color(.accentBlue).setFill()
    NSBezierPath(ovalIn: CGRect(x: item.rect.minX + NativeSpace.sm, y: item.rect.midY - NativeSpace.xxs, width: NativeSpace.xs, height: NativeSpace.xs)).fill()
    let titleX = item.rect.minX + NativeSpace.xxl
    (item.label as NSString).draw(in: CGRect(x: titleX, y: y, width: max(0, item.rect.maxX - NativeSpace.sm * 2 - timeWidth - titleX), height: NativeSpace.lg), withAttributes: NativeFont.attributes(font: NativeFont.primary, color: theme.color(.textPrimary)))
    (time as NSString).draw(in: CGRect(x: item.rect.maxX - NativeSpace.sm - timeWidth, y: y + NativeSpace.xxs, width: timeWidth, height: NativeSpace.lg), withAttributes: NativeFont.attributes(font: NativeFont.badge, color: theme.color(.textSecondary)))
}
@MainActor final class AgendaPanelView: PanelContainerView {
    var onLayout: (@MainActor () -> Void)?
    override func panelHeaderTitleMetrics(_ item: NativeRenderItem) -> (font: NSFont, leading: CGFloat) { (NativeFont.sectionHead, 0) }
    override func layout() { super.layout(); onLayout?() }
    override func paint(_ item: NativeRenderItem) {
        if item.panelHeader != nil { var feedback = item; feedback.label = ""; super.paint(feedback) }
        if item.id == "agenda-add" || item.id == "agenda-back-today" { var visual = item; visual.label = item.id == "agenda-add" ? "+" : (item.value ?? item.label); super.paint(visual); return }
        if item.kind == .button { super.paint(item); return }
        if item.id == "agenda-next" { paintAgendaSummary(item, theme: theme); return }
        if let fill = item.fill { theme.color(fill).setFill(); NSBezierPath(roundedRect: item.rect, xRadius: item.radius, yRadius: item.radius).fill() }
        let font = item.id.hasSuffix("title") ? NativeFont.sectionHead : NativeFont.badge
        let text = item.label
        let rect = item.rect.insetBy(dx: item.fill == nil ? 0 : NativeSpace.sm, dy: NativeSpace.xxs)
        (text as NSString).draw(in: rect, withAttributes: NativeFont.attributes(font: font, color: theme.color(item.color), truncation: item.id.hasSuffix("title") ? .byWordWrapping : .byTruncatingTail))
    }
}
struct AgendaRowPaint {
    var event: EventRecord
    var time: String
    var source: String
    var project: String?
    var colorHex: String
    var compact: Bool
}
@MainActor final class AgendaListView: NativeCanvasView {
    var details: [String: AgendaRowPaint] = [:]
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 116 || event.keyCode == 121, let scroll = enclosingScrollView, let document = scroll.documentView {
            let clip = scroll.contentView, viewport = clip.bounds
            let delta = event.keyCode == 116 ? -viewport.height : viewport.height
            let lastOrigin = max(document.bounds.minY, document.bounds.maxY - viewport.height)
            clip.scroll(to: CGPoint(x: viewport.minX, y: min(lastOrigin, max(document.bounds.minY, viewport.minY + delta))))
            scroll.reflectScrolledClipView(clip)
            return
        }
        super.keyDown(with: event)
    }
    override func paint(_ item: NativeRenderItem) {
        guard let row = details[item.id] else {
            if item.id == "agenda-next" { paintAgendaSummary(item, theme: theme); return }
            if item.kind == .text {
                (item.label as NSString).draw(in: item.rect.insetBy(dx: 0, dy: NativeSpace.sm), withAttributes: NativeFont.attributes(font: NativeFont.body, color: theme.color(item.color), truncation: .byWordWrapping))
                return
            }
            var visual = item
            if item.id.hasPrefix("agenda-pin-") { visual.label = item.value ?? "☆" }
            super.paint(visual); return
        }
        // Shared canvas paints press/hover/focus enclosure. Full label remains on the AX item.
        var enclosure = item; enclosure.label = ""; super.paint(enclosure)
        theme.color(.line).setFill(); NSRect(x: item.rect.minX, y: item.rect.minY, width: item.rect.width, height: 1).fill()
        let timeFont = row.compact ? NativeFont.agendaTime : NativeFont.eventTime
        let timeWidth = max(NativeSize.compactTarget + NativeSpace.md, (row.time as NSString).size(withAttributes: [.font: timeFont]).width + NativeSpace.xs)
        let top = item.rect.minY + (row.compact ? max(0, (item.rect.height - NativeSpace.xxl) / 2) : NativeSpace.sm)
        (row.time as NSString).draw(in: CGRect(x: item.rect.minX, y: top + NativeSpace.xxs, width: timeWidth, height: NativeSpace.lg), withAttributes: NativeFont.attributes(font: timeFont, color: theme.color(.textSecondary)))
        let x = item.rect.minX + timeWidth + NativeSpace.sm
        let color = NSColor(nativeHex: row.colorHex.trimmingCharacters(in: CharacterSet(charactersIn: "#")))
        color.setFill(); NSBezierPath(ovalIn: CGRect(x: x, y: top + NativeSpace.sm, width: NativeSpace.xs + NativeSpace.xxs, height: NativeSpace.xs + NativeSpace.xxs)).fill()
        let textX = x + NativeSpace.md
        (row.event.item.title as NSString).draw(in: CGRect(x: textX, y: top, width: max(0, item.rect.maxX - textX), height: NativeSpace.xxl), withAttributes: NativeFont.attributes(font: NativeFont.bodyStrong, color: theme.color(.textPrimary)))
        if !row.compact {
            let metadata = [row.project, row.source].compactMap { $0 }.joined(separator: " · ")
            (metadata as NSString).draw(in: CGRect(x: textX, y: top + NativeSpace.xl, width: max(0, item.rect.maxX - textX), height: NativeSpace.lg), withAttributes: NativeFont.attributes(font: NativeFont.toolbar, color: theme.color(.textSecondary)))
        }
    }
}
