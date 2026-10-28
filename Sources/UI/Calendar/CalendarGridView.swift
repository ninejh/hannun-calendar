import AppKit

enum CalendarMetrics {
    static let toolbarPadding: CGFloat = 14, toolbarBottom: CGFloat = 13, weekdayHeight: CGFloat = 26
    static let weatherHeight: CGFloat = 26, cellInset: CGFloat = 6, chipGap: CGFloat = 3
    static let compactChip = NativeSize.eventChipHeight, comfortableChip = NativeSize.eventChipComfortableHeight
    static let weatherCompact: CGFloat = 12, weatherComfortable: CGFloat = 14
}
private struct CalendarRenderKey: Equatable {
    var month: DateOnly; var selected: DateOnly; var today: DateOnly; var mode: DisplayMode
    var settings: BoardSettings; var environment: EnvironmentSnapshot; var records: [EventRecord]
    var projectColors: [String: String]; var links: [String: String]; var pins: Set<String>
    var weather: ExternalWeatherProjection; var authorization: CalendarAuthorization
    var loading: Bool; var refreshing: Bool; var error: AppFailure?
    var size: CGSize; var viewportWidth: CGFloat
}
/// A single canvas owns the toolbar, 7-column grid, event bars and weather strokes.
/// Its immutable render key excludes seconds, notes, timer progress and unrelated panel content.
@MainActor final class CalendarGridView: PanelContainerView {
    private(set) var renderCount = 0
    private let context: BoardScreenContext
    private let lifetime = ScreenLifetime()
    private var renderKey: CalendarRenderKey?
    private(set) var cellRects: [DateOnly: CGRect] = [:]
    private var cellDays: [String: DateOnly] = [:], addDays: [String: DateOnly] = [:], moreDays: [String: DateOnly] = [:]
    private var eventIDs: [String: String] = [:], tints: [String: NativeCalendarTint] = [:]
    private var eventTimes: [String: String] = [:]
    private var weatherIcons: [(CGRect, String)] = []
    private var dayNumbers: [String: (DateOnly, Bool, Bool)] = [:]
    private var gridRect = CGRect.zero
    private var gridRows = 5
    private var pointerEvent: (id: String, origin: CGPoint)?
    private var dropDay: DateOnly?
    private var hoveredDay: DateOnly?
    private var hoveredItemID: String?
    private var monthParts = (month: "", year: "")
    private(set) var visibleRange: DisplayRange?
    private var rangeGeneration = 0
    private let feedbackSurfaces = (0..<8).map { _ in NativeCanvasPaintSurface(frame: .zero) }
    private let staticMask = CAShapeLayer()
    private var feedbackRects: [CGRect] = []
    private var paintingFeedback = false
    private struct FeedbackKey: Equatable {
        var render: Int; var hoveredDay: DateOnly?; var hoveredItem: String?; var dropDay: DateOnly?
        var focused: FocusID?; var keyboard: Bool; var pressed: String?; var reduced: Bool; var rectangles: [CGRect]
    }
    private var feedbackKey: FeedbackKey?
    // Calendar alone combines its immutable gradient and content. Focus retains its small dynamic dial.
    override var separatesBackgroundPlane: Bool { false }
    override var drawsInteractionFeedback: Bool { paintingFeedback }
    override func updateLayer() { refreshFeedback() }
    override func setNeedsDisplay(_ invalidRect: NSRect) { refreshFeedback() }
    private let spinner = CAShapeLayer()
    private var spinnerState: (active: Bool, reduced: Bool)?
    // Measure once for each supported locale and title size, including the widest four-digit year.
    private static let titleWidths: [BoardLanguage: [CGFloat]] = {
        var widths: [BoardLanguage: [CGFloat]] = [:]
        let yearDigit = (0...9).map { (String($0) as NSString).size(withAttributes: [.font: NativeFont.yearTitle]).width }.max()!
        for language in [BoardLanguage.en, .ko] {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: language == .ko ? "ko_KR" : "en_US")
            widths[language] = [NativeFont.monthTitle, NativeFont.monthTitleCompact].map { font in
                let month = formatter.monthSymbols.map { ($0 as NSString).size(withAttributes: [.font: font, .kern: NativeTracking.monthTitle]).width }.max()!
                return ceil(month) + ceil(yearDigit * 4) + NativeSpace.lg
            }
        }
        return widths
    }()
    private var titleFont: NSFont { (boardViewportWidth ?? bounds.width) <= BoardLayoutMetrics.mediumBreakpoint ? NativeFont.monthTitleCompact : NativeFont.monthTitle }
    var boardViewportWidth: CGFloat? { didSet { if oldValue != boardViewportWidth { needsLayout = true } } }
    var boardShortcut: (@MainActor (NSEvent) -> Bool)?
    init(context: BoardScreenContext) {
        self.context = context; super.init(frame: .zero, focus: context.focus)
        spinner.fillColor = nil; spinner.lineWidth = NativeSize.focusWidth; spinner.isHidden = true; layer?.addSublayer(spinner)
        for surface in feedbackSurfaces {
            surface.isHidden = true; addSubview(surface)
            surface.painter = { [weak self] dirty in
                guard let self else { return }; self.paintingFeedback = true
                defer { self.paintingFeedback = false }
                self.draw(dirty)
            }
        }
        staticMask.fillColor = NSColor.black.cgColor; staticMask.fillRule = .evenOdd
        setAccessibilityElement(true); setAccessibilityRole(.group)
        setAccessibilityIdentifier("board.calendar"); setAccessibilityLabel(context.text("a11y.calendar"))
        onAction = { [weak self] id in self?.perform(id) }
        onShortcut = { [weak self] event in self?.shortcut(event) ?? false }
        lifetime.own(context.presentation.subscribe { [weak self] change in self?.receive(change) })
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func layout() { super.layout(); render(); refreshFeedback() }
    private func receive(_ change: PresentationChange) {
        guard !lifetime.isDisposed else { return }
        if change.domains == [.clock], renderKey?.today == context.presentation.state.snapshot.clock.today { return }
        guard !change.domains.isDisjoint(with: [.board, .calendar, .view, .clock, .environment, .external, .activity, .error]) else { return }
        render()
    }
    private func render() {
        guard !lifetime.isDisposed, bounds.width > 0, bounds.height > 0 else { return }
        let state = context.presentation.state, snapshot = state.snapshot, board = snapshot.board
        let visible = snapshot.calendar.records.filter { !board.hiddenCalendarIDs.contains($0.item.calendarID) }.sorted {
            $0.item.start == $1.item.start ? $0.id < $1.id : $0.item.start < $1.item.start
        }
        let colors = Dictionary(uniqueKeysWithValues: board.projects.map { ($0.id.uuidString.lowercased(), $0.colorHex) })
        let next = CalendarRenderKey(month: state.view.month, selected: state.view.selectedDay, today: snapshot.clock.today, mode: state.view.mode, settings: board.settings, environment: snapshot.environment, records: visible, projectColors: colors, links: board.eventProjectLinks, pins: board.pinnedEventKeys, weather: snapshot.external.weather, authorization: snapshot.calendarAuthorization, loading: state.activity.loading, refreshing: state.activity.refreshing, error: state.lastError, size: bounds.size, viewportWidth: boardViewportWidth ?? bounds.width)
        guard next != renderKey else { return }
        let oldVisibleDays = Set(cellRects.keys)
        var comparablePrevious = renderKey
        comparablePrevious?.selected = next.selected
        let staticKeyChanged = comparablePrevious != next
        let previousTheme = renderKey?.environment.resolvedAppearance
        renderKey = next; renderCount += 1
        reduceMotion = next.environment.reduceMotion
        if previousTheme != next.environment.resolvedAppearance { theme = NativeTheme(appearance: next.environment.resolvedAppearance) }
        setAccessibilityLabel(context.text("a11y.calendar"))
        cellRects = [:]; cellDays = [:]; addDays = [:]; moreDays = [:]; eventIDs = [:]; tints = [:]; eventTimes = [:]; weatherIcons = []; dayNumbers = [:]
        var output: [NativeRenderItem] = []
        let toolbarBottom = toolbar(into: &output, key: next)
        // The footer belongs to the setting, so data arrival/offline changes never resize the grid.
        let weatherEnabled = board.settings.weather.enabled
        let footer = weatherEnabled ? CalendarMetrics.weatherHeight : 0
        let bannerHeight: CGFloat = snapshot.calendarAuthorization == .authorized ? 0 : NativeSize.toolbarHeight + NativeSpace.md
        if bannerHeight > 0 {
            let authorization = snapshot.calendarAuthorization
            let key: String = switch authorization { case .denied: "banner.permission_denied"; case .restricted: "banner.permission_restricted"; case .writeOnly: "banner.permission_write_only"; case .unavailable: "banner.permission_unavailable"; default: "banner.connect" }
            let action: String = switch authorization { case .denied, .restricted: "banner.open_system_settings"; case .writeOnly: "accounts.upgrade_access"; case .unavailable: "accounts.retry"; default: "accounts.connect" }
            output.append(NativeRenderItem(id: "calendar.permission", rect: CGRect(x: NativeSpace.xl, y: toolbarBottom, width: max(0, bounds.width - NativeSpace.xl * 2 - NativeSize.popoverWidth / 2), height: bannerHeight), label: context.text(key), kind: .text, color: .textSecondary))
            output.append(NativeRenderItem(id: "action.connectCalendars", rect: CGRect(x: max(NativeSpace.xl, bounds.width - NativeSize.popoverWidth / 2), y: toolbarBottom + NativeSpace.xs, width: NativeSize.popoverWidth / 2 - NativeSpace.xl, height: NativeSize.toolbarHeight), label: context.text(action), kind: .button, color: .accentBlue))
        }
        let weekdayY = toolbarBottom + bannerHeight
        gridRect = CGRect(x: 0, y: weekdayY + CalendarMetrics.weekdayHeight, width: bounds.width, height: max(0, bounds.height - weekdayY - CalendarMetrics.weekdayHeight - footer))
        let weekStart: Int
        switch board.settings.weekStart { case .sunday: weekStart = 1; case .monday: weekStart = 2; case .system: weekStart = snapshot.environment.resolvedWeekStart }
        let days = NativeCalendarLayout.days(month: next.month, selected: next.selected, mode: next.mode, weekStart: weekStart)
        gridRows = max(1, days.count / 7)
        let rects = NativeGeometry.grid(in: gridRect, columns: 7, rows: gridRows)
        let zone = TimeZone(identifier: snapshot.clock.timeZone) ?? TimeZone(secondsFromGMT: 0)!
        let locale = Locale(identifier: board.settings.language == .ko ? "ko_KR" : "en_US")
        for column in 0..<7 {
            let weekday = ((weekStart - 1 + column) % 7)
            let reference = DateOnly("2026-10-25")!.addingDays(weekday)!
            output.append(NativeRenderItem(id: "calendar.weekday.\(weekday)", rect: CGRect(x: CGFloat(column) * bounds.width / 7, y: weekdayY, width: bounds.width / 7, height: CalendarMetrics.weekdayHeight), label: DayMath.text(reference.date(in: zone), format: "EEE", timeZone: zone, locale: locale).uppercased(with: locale), kind: .text, color: weekday == 0 ? .danger : .textQuiet))
        }
        let numberSize = board.settings.compact ? NativeSize.dayNumberCompact : NativeSize.dayNumber
        let chipHeight = board.settings.compact ? CalendarMetrics.compactChip : CalendarMetrics.comfortableChip
        let pitch = chipHeight + CalendarMetrics.chipGap
        var byDay: [DateOnly: [EventRecord]] = [:], eventRanges: [String: ClosedRange<DateOnly>] = [:]
        for event in visible {
            if let range = NativeCalendarLayout.eventDays(event, timeZone: zone) {
                eventRanges[event.id] = range
                if range.lowerBound == range.upperBound { byDay[range.lowerBound, default: []].append(event) }
            }
        }
        for (index, value) in days.enumerated() {
            guard let day = value, index < rects.count else { continue }
            let rect = rects[index]; cellRects[day] = rect
            let dateLabel = DayMath.text(day.date(in: zone), format: "EEEE, MMMM d, yyyy", timeZone: zone, locale: locale)
            let count = eventRanges.values.filter { $0.contains(day) }.count
            let id = "calendar.day.\(day)"
            // The date's number target and AX enclosure coincide; the remaining cell selects through mouse handling.
            let number = CGRect(x: rect.minX + CalendarMetrics.cellInset, y: rect.minY + NativeSpace.xs, width: numberSize, height: numberSize)
            output.append(NativeRenderItem(id: id, rect: number, label: context.text("a11y.day", values: ["date": dateLabel, "count": String(count)]), kind: .row, value: day.description))
            cellDays[id] = day; dayNumbers[id] = (day, day == next.today, day.month == next.month.month && day.year == next.month.year)
            let addID = "action.add.\(day)"
            output.append(NativeRenderItem(id: addID, rect: CGRect(x: rect.maxX - NativeSize.compactTarget - NativeSpace.xs, y: number.minY, width: NativeSize.compactTarget, height: NativeSize.compactTarget), label: context.text("a11y.new_on_date", values: ["date": dateLabel]), kind: .button, color: .textQuiet))
            addDays[addID] = day
            if weatherEnabled, let weather = snapshot.external.weather.days.first(where: { $0.date == day }), let key = Self.weatherKey(weather.code) {
                let size = board.settings.compact ? CalendarMetrics.weatherCompact : CalendarMetrics.weatherComfortable
                let icon = CGRect(x: number.maxX + NativeSpace.xxs, y: number.midY - size / 2, width: size, height: size)
                if icon.maxX < rect.maxX - NativeSize.compactTarget - NativeSpace.xs {
                    weatherIcons.append((icon, key))
                    output.append(NativeRenderItem(id: "calendar.weather.\(day)", rect: icon, label: context.text(key), kind: .image, color: .textQuiet))
                }
            }
        }
        let weeks = NativeCalendarLayout.weeks(records: visible, days: days, timeZone: zone)
        let eventLookup = Dictionary(uniqueKeysWithValues: visible.map { ($0.id, $0) })
        var seenEvents: Set<String> = []
        for (row, week) in weeks.enumerated() {
            let firstIndex = row * 7; guard firstIndex < rects.count else { continue }
            let rowRect = rects[firstIndex]
            let eventTop = rowRect.minY + NativeSpace.xs + numberSize + NativeSpace.xs
            let capacity = max(0, Int((rowRect.maxY - eventTop - NativeSpace.xs) / pitch))
            let daily = (0..<7).map { column in days[firstIndex + column].flatMap { byDay[$0] } ?? [] }
            let packed = NativeCalendarLayout.pack(week, dailyCounts: daily.map(\.count), capacity: capacity)
            for segment in packed.segments {
                guard let event = eventLookup[segment.eventID] else { continue }
                let first = rects[firstIndex + segment.startColumn], last = rects[firstIndex + segment.endColumn]
                let rect = CGRect(x: first.minX + CalendarMetrics.cellInset, y: eventTop + CGFloat(segment.lane) * pitch, width: last.maxX - first.minX - CalendarMetrics.cellInset * 2, height: chipHeight)
                let id = seenEvents.insert(event.id).inserted ? "calendar.event.\(event.id)" : "calendar.event.\(event.id).segment.\(row)"
                appendEvent(event, id: id, rect: rect, continuation: (segment.continuesBefore, segment.continuesAfter), key: next, zone: zone, output: &output)
            }
            for column in 0..<7 {
                let index = firstIndex + column; guard let day = days[index] else { continue }
                let rect = rects[index], packedDay = packed.days[column]
                for (i, lane) in packedDay.eventLanes.enumerated() {
                    let event = daily[column][i]
                    appendEvent(event, id: "calendar.event.\(event.id)", rect: CGRect(x: rect.minX + CalendarMetrics.cellInset, y: eventTop + CGFloat(lane) * pitch, width: max(0, rect.width - CalendarMetrics.cellInset * 2), height: chipHeight), continuation: (false, false), key: next, zone: zone, output: &output)
                }
                if packedDay.hiddenCount > 0 {
                    let id = "calendar.more.\(day)"
                    let y = packedDay.moreLane.map { eventTop + CGFloat($0) * pitch } ?? (rect.maxY - NativeSize.compactTarget)
                    output.append(NativeRenderItem(id: id, rect: CGRect(x: rect.minX + CalendarMetrics.cellInset, y: y, width: max(0, rect.width - CalendarMetrics.cellInset * 2), height: max(chipHeight, NativeSize.compactTarget)), label: context.text("toolbar.more_events", values: ["0": String(packedDay.hiddenCount)]), kind: .button, value: String(packedDay.hiddenCount), color: .textQuiet))
                    moreDays[id] = day
                }
            }
        }
        if weatherEnabled {
            var x = NativeSpace.xl
            for (id, label) in [("action.weatherProvider", context.text("weather.provider_name")), ("action.weatherLicense", context.text("weather.license_name"))] {
                let width = (label as NSString).size(withAttributes: [.font: NativeFont.toolbar]).width + NativeSpace.lg
                output.append(NativeRenderItem(id: id, rect: CGRect(x: x, y: bounds.maxY - footer, width: width, height: footer), label: label, kind: .button, color: .weatherCredit)); x += width + NativeSpace.xs
                output.append(NativeRenderItem(id: "calendar.separator.\(id)", rect: CGRect(x: x, y: bounds.maxY - footer, width: NativeSpace.sm, height: footer), label: "·", kind: .text, color: .weatherCredit)); x += NativeSpace.sm + NativeSpace.xs
            }
            let status = snapshot.external.weather.state == .stale || snapshot.external.weather.state == .unavailable ? " · " + context.text("status.weather_offline") : ""
            output.append(NativeRenderItem(id: "calendar.weatherCredit", rect: CGRect(x: x, y: bounds.maxY - footer, width: max(0, bounds.width - x - NativeSpace.xl), height: footer), label: context.text("weather.transformation").trimmingCharacters(in: CharacterSet(charactersIn: ".")) + status, kind: .text, color: .weatherCredit))
        }
        update(items: output, invalidatingDisplay: false)
        if staticKeyChanged || oldVisibleDays != Set(cellRects.keys) { super.setNeedsDisplay(bounds) }
        refreshFeedback()
        if let first = days.compactMap({ $0 }).first, let last = days.compactMap({ $0 }).last, let end = last.addingDays(1), next.month.year < 9999 {
            let range = DisplayRange(month: next.month, visibleStart: first, endExclusive: end, mode: next.mode)
            if visibleRange != range {
                visibleRange = range; rangeGeneration += 1; let generation = rangeGeneration
                // Coalesce rapid period/week-start changes without blocking pointer/keyboard feedback.
                Task { @MainActor [weak self] in
                    await Task.yield()
                    guard let self, !self.lifetime.isDisposed, self.rangeGeneration == generation else { return }
                    self.context.presentation.send(.command(.refresh(range, refreshSources: false)))
                }
            }
        }
    }
    private func toolbar(into output: inout [NativeRenderItem], key: CalendarRenderKey) -> CGFloat {
        let zone = TimeZone(identifier: key.environment.timeZone) ?? TimeZone(secondsFromGMT: 0)!
        let locale = Locale(identifier: key.settings.language == .ko ? "ko_KR" : "en_US")
        let month = DayMath.text(key.month.date(in: zone), format: key.settings.language == .ko ? "yyyy년 M월" : "MMMM yyyy", timeZone: zone, locale: locale)
        monthParts = (DayMath.text(key.month.date(in: zone), format: "MMMM", timeZone: zone, locale: locale), DayMath.text(key.month.date(in: zone), format: "yyyy", timeZone: zone, locale: locale))
        let h = NativeSize.toolbarHeight, rowHeight: CGFloat = 44, gap = NativeSpace.sm
        let titleWidth = Self.titleWidths[key.settings.language]![(key.viewportWidth <= BoardLayoutMetrics.mediumBreakpoint) ? 1 : 0]
        var x = NativeSpace.xl, y = CalendarMetrics.toolbarPadding
        output.append(NativeRenderItem(id: "calendar.logo", rect: CGRect(x: x, y: y + (h - NativeSize.compactTarget) / 2, width: NativeSize.compactTarget, height: NativeSize.compactTarget), label: context.text("a11y.calendar"), kind: .image))
        let busy = key.loading || key.refreshing
        if busy { output[output.count - 1].label = context.text(key.loading ? "board.loading" : "refresh.loading") }
        spinner.frame = output.last!.rect.insetBy(dx: NativeSpace.xs, dy: NativeSpace.xs)
        let path = CGMutablePath(); path.addArc(center: CGPoint(x: spinner.bounds.midX, y: spinner.bounds.midY), radius: max(0, spinner.bounds.width / 2 - NativeSize.focusWidth), startAngle: 0, endAngle: .pi * 1.5, clockwise: false)
        spinner.path = path; spinner.strokeColor = theme.color(.toastText).cgColor; spinner.isHidden = !busy
        if spinnerState?.active != busy || spinnerState?.reduced != key.environment.reduceMotion {
            spinnerState = (busy, key.environment.reduceMotion)
            if busy { NativeMotion.apply(.spinner, to: spinner, reduceMotion: key.environment.reduceMotion) } else { NativeMotion.stop(spinner) }
        }
        x += NativeSize.compactTarget + gap
        func button(_ id: String, _ text: String, width: CGFloat, height: CGFloat = NativeSize.toolbarHeight, fill: NativeColorToken? = nil, value: String? = nil) {
            if x + width > bounds.width - NativeSpace.xl { x = NativeSpace.xl; y += rowHeight + NativeSpace.sm }
            output.append(NativeRenderItem(id: id, rect: CGRect(x: x, y: y + (h - height) / 2, width: width, height: height), label: text, kind: .button, value: value, fill: fill)); x += width + gap
        }
        button("action.chooseMonth", month, width: titleWidth)
        button("action.previousPeriod", context.text(key.mode == .week ? "a11y.prev_week" : "a11y.prev_month"), width: h)
        let today = context.text("toolbar.today")
        button("action.today", today, width: max(h, ceil((today as NSString).size(withAttributes: [.font: NativeFont.toolbar]).width) + NativeSpace.lg + NativeSpace.xs))
        button("action.nextPeriod", context.text(key.mode == .week ? "a11y.next_week" : "a11y.next_month"), width: h)
        for (id, text, selected) in [("action.monthView", "toolbar.month_view", key.mode == .month), ("action.weekView", "toolbar.week_view", key.mode == .week)] {
            let label = context.text(text); button(id, label, width: ceil((label as NSString).size(withAttributes: [.font: NativeFont.toolbar]).width) + NativeSpace.lg + NativeSpace.xs, height: NativeSize.controlGroupHeight, fill: selected ? .hover : nil, value: selected ? "1" : "0")
        }
        button("action.calendars", context.text("toolbar.calendars"), width: key.viewportWidth <= BoardLayoutMetrics.mediumBreakpoint ? h : ceil((context.text("toolbar.calendars") as NSString).size(withAttributes: [.font: NativeFont.toolbar]).width) + NativeSpace.lg)
        button("action.search", context.text("toolbar.search"), width: key.viewportWidth <= BoardLayoutMetrics.mediumBreakpoint ? h : ceil((context.text("toolbar.search") as NSString).size(withAttributes: [.font: NativeFont.toolbar]).width) + NativeSpace.lg)
        let layout = context.text("layout.menu.title")
        button("action.layout", layout, width: max(44, ceil(((layout + " ⌄") as NSString).size(withAttributes: [.font: NativeFont.toolbar]).width) + NativeSpace.lg), height: h)
        output[output.count - 1].kind = .menuButton; output[output.count - 1].minimumTarget = 44
        let density = context.text(key.settings.compact ? "toolbar.density_label_compact" : "toolbar.density_label_comfortable")
        button("action.density", density, width: ceil((density as NSString).size(withAttributes: [.font: NativeFont.toolbar]).width) + NativeSpace.lg)
        let newTitle = context.text("toolbar.new_event")
        button("action.newEvent", newTitle, width: ceil((newTitle as NSString).size(withAttributes: [.font: NativeFont.primary]).width) + NativeSpace.xxl + NativeSpace.lg + NativeSpace.xs, fill: .fill)
        return y + rowHeight + CalendarMetrics.toolbarBottom
    }
    private func appendEvent(_ record: EventRecord, id: String, rect: CGRect, continuation: (Bool, Bool), key: CalendarRenderKey, zone: TimeZone, output: inout [NativeRenderItem]) {
        let event = record.item, title = event.title.isEmpty ? context.text("calendar.untitled_event") : event.title
        let time = event.allDay ? "" : DayMath.text(event.start, format: "HH:mm", timeZone: zone)
        let label = (continuation.0 ? "‹ " : "") + title + (continuation.1 ? " ›" : "")
        let accessible = title + (time.isEmpty ? "" : " · " + time) + (event.writable ? "" : " · " + context.text("calendar.readonly"))
        output.append(NativeRenderItem(id: id, rect: rect, label: accessible, kind: .chip, value: label))
        eventIDs[id] = record.id
        if key.viewportWidth > BoardLayoutMetrics.compactBreakpoint, !event.allDay, !continuation.0 { eventTimes[id] = time }
        let color = key.links[record.pinKey].flatMap { key.projectColors[$0.lowercased()] } ?? event.colorHex
        tints[id] = Self.tint(color)
    }
    func anchorRect(for id: String) -> CGRect? {
        if let day = DateOnly(id) { return cellRects[day] }
        return items.first { $0.id == id || eventIDs[$0.id] == id }?.rect
    }
    private func anchor(_ id: String, target: AnchorTarget) -> StableAnchor {
        let rect = items.first { $0.id == id }?.rect ?? .zero
        var root: NSView = self
        while let parent = root.superview { root = parent; if root.identifier?.rawValue == "board.root" { break } }
        return StableAnchor(target: target, boardRect: convert(rect, to: root), returnFocusID: FocusID(id))
    }
    private func perform(_ id: String) {
        if let day = cellDays[id] { context.presentation.send(.selectDay(day)); return }
        if let day = moreDays[id] { context.routing.route(.revealAgenda(day: day, anchor: anchor(id, target: .day(day)))); return }
        if let day = addDays[id] { context.routing.route(.openAdd(AddRequest(kind: .event, day: day, anchor: anchor(id, target: .day(day))))); return }
        if let event = eventIDs[id] { context.routing.route(.openEvent(eventID: event, anchor: anchor(id, target: .event(event)))); return }
        switch id {
        case "action.previousPeriod": context.presentation.send(.movePeriod(-1))
        case "action.nextPeriod": context.presentation.send(.movePeriod(1))
        case "action.today": context.presentation.send(.followToday)
        case "action.monthView": context.presentation.send(.setMode(.month))
        case "action.weekView": context.presentation.send(.setMode(.week))
        case "action.chooseMonth": context.routing.route(.openMonthPicker(anchor: anchor(id, target: .control(id))))
        case "action.calendars": context.routing.route(.openCalendars(anchor: anchor(id, target: .control(id))))
        case "action.search": context.routing.route(.openSearch(initialQuery: "", anchor: anchor(id, target: .control(id))))
        case "action.newEvent": context.routing.route(.openAdd(AddRequest(kind: .event, day: context.presentation.state.view.selectedDay, anchor: anchor(id, target: .control(id)))))
        case "action.layout": _ = showMenu(for: id)
        case "action.density": var patch = SettingsPatch(); patch.compact = .set(!context.presentation.state.snapshot.board.settings.compact); context.presentation.send(.edit(.settings(patch), undoable: false))
        case "action.connectCalendars":
            if context.presentation.state.snapshot.calendarAuthorization == .denied || context.presentation.state.snapshot.calendarAuthorization == .restricted { context.presentation.send(.command(.open(.privacy))) }
            else { context.presentation.send(.command(.connect)) }
        case "action.weatherProvider": context.presentation.send(.command(.openAttribution(.weather)))
        case "action.weatherLicense": context.presentation.send(.command(.openAttribution(.weatherLicense)))
        default: break
        }
    }
    private func shortcut(_ event: NSEvent) -> Bool {
        if let focused = focus.focusedID?.rawValue, let day = cellDays[focused], !event.modifierFlags.contains(.command), let delta = [123: -1, 124: 1, 125: 7, 126: -7][Int(event.keyCode)], let next = day.addingDays(delta) {
            context.presentation.send(.selectDay(next)); focus.focus(FocusID("calendar.day.\(next)")); return true
        }
        return boardShortcut?(event) ?? false
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let item = item(at: point), let id = eventIDs[item.id], let record = context.presentation.state.snapshot.calendar.records.first(where: { $0.id == id }), record.item.writable, !id.hasPrefix("pending:") { pointerEvent = (id, point) }
        else if item(at: point) == nil, let day = cellRects.first(where: { $0.value.contains(point) })?.key {
            context.presentation.send(.selectDay(day))
            if event.clickCount == 2 { context.routing.route(.openAdd(AddRequest(kind: .event, day: day, anchor: anchor("calendar.day.\(day)", target: .day(day))))) }
        }
        super.mouseDown(with: event)
    }
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil), previous = hoveredDay
        hoveredItemID = item(at: point)?.id; hoveredDay = cellRects.first(where: { $0.value.contains(point) })?.key
        if previous != hoveredDay {
            if let previous, let rect = cellRects[previous] { setNeedsDisplay(rect) }
            if let hoveredDay, let rect = cellRects[hoveredDay] { setNeedsDisplay(rect) }
        }
        super.mouseMoved(with: event)
    }
    override func mouseExited(with event: NSEvent) {
        if let hoveredDay, let rect = cellRects[hoveredDay] { setNeedsDisplay(rect) }
        hoveredDay = nil; hoveredItemID = nil; super.mouseExited(with: event); refreshFeedback()
    }
    override func mouseDragged(with event: NSEvent) {
        guard let pointerEvent else { super.mouseDragged(with: event); return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - pointerEvent.origin.x, point.y - pointerEvent.origin.y) >= NativeSpace.xs else { return }
        let old = dropDay; dropDay = cellRects.first(where: { $0.value.contains(point) })?.key
        if old != dropDay { if let old, let rect = cellRects[old] { setNeedsDisplay(rect) }; if let day = dropDay, let rect = cellRects[day] { setNeedsDisplay(rect) } }
    }
    override func mouseUp(with event: NSEvent) {
        if let dragged = pointerEvent, let target = dropDay {
            pointerEvent = nil; dropDay = nil
            if let record = context.presentation.state.snapshot.calendar.records.first(where: { $0.id == dragged.id }), record.item.writable,
               let zone = TimeZone(identifier: context.presentation.state.snapshot.clock.timeZone), let draft = NativeCalendarLayout.shift(record, to: target, timeZone: zone) {
                context.presentation.send(.command(.saveEvent(.calendarEdit(EventIdentity(id: record.id), expectedVersion: record.version, draft, MetadataPatch())), feedback: PresentationFeedback(messageKey: "toast.event_moving", values: ["date": DayMath.text(target.date(in: zone), format: "MMM d", timeZone: zone)])))
                context.presentation.send(.selectDay(target))
            }
            needsDisplay = true; return
        }
        pointerEvent = nil; super.mouseUp(with: event)
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        theme.color(.line).setStroke(); let lines = NSBezierPath(); lines.lineWidth = 1
        for column in 1..<7 { let x = gridRect.minX + CGFloat(column) * gridRect.width / 7; lines.move(to: CGPoint(x: x, y: gridRect.minY)); lines.line(to: CGPoint(x: x, y: gridRect.maxY)) }
        for row in 0...gridRows { let y = gridRect.minY + CGFloat(row) * gridRect.height / CGFloat(gridRows); lines.move(to: CGPoint(x: gridRect.minX, y: y)); lines.line(to: CGPoint(x: gridRect.maxX, y: y)) }
        lines.stroke()
        for (rect, key) in weatherIcons where rect.intersects(dirtyRect) { CalendarWeatherPainter.draw(key, in: rect, color: theme.color(.textQuiet), appearance: theme.appearance) }
    }
    override func paint(_ item: NativeRenderItem) {
        if item.id == "calendar.logo" {
            theme.color(.fill).setFill(); NSBezierPath(roundedRect: item.rect, xRadius: NativeRadius.input, yRadius: NativeRadius.input).fill()
            if renderKey?.loading == true || renderKey?.refreshing == true { return }
            let icon = item.rect.insetBy(dx: NativeSpace.sm, dy: NativeSpace.sm)
            theme.color(.toastText).setStroke(); let path = NSBezierPath(roundedRect: icon, xRadius: NativeSpace.xxs, yRadius: NativeSpace.xxs); path.lineWidth = 1; path.stroke()
            let line = NSBezierPath(); line.move(to: CGPoint(x: icon.minX, y: icon.minY + NativeSpace.xs)); line.line(to: CGPoint(x: icon.maxX, y: icon.minY + NativeSpace.xs)); line.lineWidth = 1; line.stroke(); return
        }
        if let (day, today, inMonth) = dayNumbers[item.id] {
            if paintingFeedback, (day == renderKey?.selected || day == dropDay), let cell = cellRects[day] {
                theme.color(.selected).setFill(); NSBezierPath(rect: cell.insetBy(dx: 1, dy: 1)).fill()
            }
            if today { theme.color(.fill).setFill(); NSBezierPath(ovalIn: item.rect).fill() }
            let text = String(day.day)
            let color = today ? NSColor.white : theme.color(inMonth ? .textPrimary : .textQuiet)
            let font = renderKey?.settings.compact == true ? NativeFont.dayCompact : NativeFont.day
            let size = (text as NSString).size(withAttributes: [.font: font])
            (text as NSString).draw(at: CGPoint(x: item.rect.midX - size.width / 2, y: item.rect.midY - size.height / 2), withAttributes: NativeFont.attributes(font: font, color: color))
            paintFocus(item); return
        }
        if item.id.hasPrefix("calendar.weather.") { return }
        if let tint = tints[item.id] {
            (paintingFeedback && hoveredItemID == item.id ? theme.color(.hover) : theme.tint(tint, background: true)).setFill(); NSBezierPath(roundedRect: item.rect, xRadius: NativeRadius.chip, yRadius: NativeRadius.chip).fill()
            var text = item.rect.insetBy(dx: NativeSpace.xs, dy: NativeSpace.xxs)
            if let time = eventTimes[item.id] {
                let width = (time as NSString).size(withAttributes: [.font: NativeFont.eventTime]).width
                drawText(time, in: CGRect(x: text.minX, y: text.minY, width: min(width, text.width), height: text.height), font: NativeFont.eventTime, color: theme.tint(tint))
                text.origin.x += width + NativeSpace.xs; text.size.width = max(0, item.rect.maxX - NativeSpace.xs - text.minX)
            }
            drawText(item.value ?? item.label, in: text, font: NativeFont.eventChip, color: theme.tint(tint)); paintFocus(item); return
        }
        if let day = addDays[item.id] {
            if paintingFeedback && (hoveredDay == day || focus.focusedID == FocusID(item.id) || focus.focusedID == FocusID("calendar.day.\(day)")) { drawText("+", in: item.rect.insetBy(dx: NativeSpace.sm, dy: NativeSpace.xs), font: NativeFont.body, color: theme.color(.textQuiet)) }
            paintFocus(item); return
        }
        let outlined = ["action.calendars", "action.search", "action.layout", "action.density"].contains(item.id)
        if outlined {
            let pressed = paintingFeedback && pressedItemID == item.id
            let hovered = paintingFeedback && hoveredItemID == item.id
            theme.color(pressed ? .selected : hovered ? .hover : .raised).setFill()
            NSBezierPath(roundedRect: item.rect, xRadius: item.radius, yRadius: item.radius).fill()
            theme.color(.lineStrong).setStroke()
            let outline = NSBezierPath(roundedRect: item.rect.insetBy(dx: 0.5, dy: 0.5), xRadius: NativeRadius.button, yRadius: NativeRadius.button)
            outline.lineWidth = 1; outline.stroke()
            let icon = item.rect.width <= NativeSize.toolbarHeight && (item.id == "action.calendars" || item.id == "action.search")
            let label = icon ? (item.id == "action.calendars" ? "▦" : "⌕") : item.id == "action.layout" ? item.label + " ⌄" : item.label
            drawCentered(label, in: item.rect.insetBy(dx: NativeSpace.sm, dy: 0), font: icon ? NativeFont.primary : NativeFont.toolbar, color: theme.color(item.color))
            paintFocus(item); return
        }
        let symbol: String?
        switch item.id { case "action.previousPeriod": symbol = "‹"; case "action.nextPeriod": symbol = "›"; case "action.search": symbol = "⌕"; case "action.calendars": symbol = "▦"; default: symbol = nil }
        if let symbol, item.rect.width <= NativeSize.toolbarHeight { var visual = item; visual.label = symbol; super.paint(visual); return }
        if item.id == "action.chooseMonth" {
            let width = ceil((monthParts.month as NSString).size(withAttributes: [.font: titleFont, .kern: NativeTracking.monthTitle]).width)
            drawCentered(monthParts.month, in: CGRect(x: item.rect.minX, y: item.rect.minY, width: width, height: item.rect.height), font: titleFont, color: theme.color(.textPrimary), tracking: NativeTracking.monthTitle)
            drawCentered(monthParts.year, in: CGRect(x: item.rect.minX + width + NativeSpace.sm, y: item.rect.minY, width: max(0, item.rect.width - width - NativeSpace.sm), height: item.rect.height), font: NativeFont.yearTitle, color: theme.color(.textSecondary)); paintFocus(item); return
        }
        if item.id.hasPrefix("calendar.weekday") { drawText(item.label, in: item.rect.insetBy(dx: NativeSpace.md, dy: NativeSpace.sm), font: NativeFont.weekday, color: theme.color(item.color), tracking: NativeTracking.weekday); return }
        if item.id.hasPrefix("action.") || item.id == "calendar.weatherCredit" || item.id.hasPrefix("calendar.separator.") {
            var background = item; background.label = ""; super.paint(background)
            if item.id == "action.newEvent" { theme.color(paintingFeedback && hoveredItemID == item.id ? .fillHover : .fill).setFill(); NSBezierPath(roundedRect: item.rect, xRadius: NativeRadius.button, yRadius: NativeRadius.button).fill() }
            let color = item.id == "action.newEvent" ? theme.color(.toastText) : theme.color(item.color)
            var textRect = item.rect.insetBy(dx: item.id.hasPrefix("calendar.separator") ? 0 : NativeSpace.sm, dy: 0)
            if item.id == "action.newEvent" {
                let center = CGPoint(x: item.rect.minX + NativeSpace.md + NativeSpace.sm, y: item.rect.midY)
                color.setStroke(); let plus = NSBezierPath(); plus.lineWidth = NativeSize.focusWidth
                plus.move(to: CGPoint(x: center.x - NativeSpace.xs, y: center.y)); plus.line(to: CGPoint(x: center.x + NativeSpace.xs, y: center.y)); plus.move(to: CGPoint(x: center.x, y: center.y - NativeSpace.xs)); plus.line(to: CGPoint(x: center.x, y: center.y + NativeSpace.xs)); plus.stroke()
                textRect.origin.x = item.rect.minX + NativeSpace.md + NativeSpace.lg + NativeSpace.xs; textRect.size.width = max(0, item.rect.maxX - NativeSpace.md - textRect.minX)
            }
            let visibleLabel = item.id == "action.layout" ? item.label + " ⌄" : item.label
            drawCentered(visibleLabel, in: textRect, font: item.id == "action.newEvent" ? NativeFont.primary : NativeFont.toolbar, color: color); paintFocus(item); return
        }
        super.paint(item)
    }
    private func drawText(_ text: String, in rect: CGRect, font: NSFont, color: NSColor, tracking: CGFloat = 0) {
        NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect: rect).addClip()
        (text as NSString).draw(in: rect, withAttributes: NativeFont.attributes(font: font, color: color, tracking: tracking)); NSGraphicsContext.restoreGraphicsState()
    }
    private func drawCentered(_ text: String, in rect: CGRect, font: NSFont, color: NSColor, tracking: CGFloat = 0) {
        let size = (text as NSString).size(withAttributes: [.font: font, .kern: tracking])
        drawText(text, in: CGRect(x: rect.minX, y: rect.midY - size.height / 2, width: rect.width, height: size.height), font: font, color: color, tracking: tracking)
    }
    private func paintFocus(_ item: NativeRenderItem) {
        guard paintingFeedback, focus.keyboardFocus, focus.focusedID == FocusID(item.id) else { return }
        theme.color(.accentBlue).setStroke(); let ring = NSBezierPath(roundedRect: item.rect.insetBy(dx: -NativeSize.focusOffset, dy: -NativeSize.focusOffset), xRadius: NativeRadius.chip, yRadius: NativeRadius.chip); ring.lineWidth = NativeSize.focusWidth; ring.stroke()
    }
    private func refreshFeedback() {
        guard !lifetime.isDisposed, renderKey != nil, bounds.width > 0, bounds.height > 0 else { return }
        var rectangles: [CGRect] = []
        for day in [renderKey?.selected, hoveredDay, dropDay].compactMap({ $0 }) {
            if let rect = cellRects[day] { rectangles.append(rect.insetBy(dx: -NativeSpace.xs, dy: -NativeSpace.xs).integral.intersection(bounds)) }
        }
        for id in interactionFeedbackIDs {
            if let day = cellDays[id], let rect = cellRects[day] { rectangles.append(rect.insetBy(dx: -NativeSpace.xs, dy: -NativeSpace.xs).integral.intersection(bounds)) }
            else if let item = items.first(where: { $0.id == id }) { rectangles.append(item.rect.insetBy(dx: -NativeSpace.sm, dy: -NativeSpace.sm).integral.intersection(bounds)) }
        }
        rectangles.removeAll { $0.isEmpty }
        // Keep disjoint patches so translucent pixels are composited exactly once.
        var merged: [CGRect] = []
        for rectangle in rectangles {
            var value = rectangle, index = 0
            while index < merged.count {
                if merged[index].intersects(value) { value = value.union(merged.remove(at: index)); index = 0 }
                else { index += 1 }
            }
            merged.append(value)
        }
        merged.sort { $0.minY == $1.minY ? $0.minX < $1.minX : $0.minY < $1.minY }
        let key = FeedbackKey(render: renderCount, hoveredDay: hoveredDay, hoveredItem: hoveredItemID, dropDay: dropDay, focused: focus.focusedID, keyboard: focus.keyboardFocus, pressed: pressedItemID, reduced: reduceMotion, rectangles: merged)
        guard key != feedbackKey else { return }; feedbackKey = key
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if merged != feedbackRects || staticMask.frame != bounds {
            feedbackRects = merged
            if merged.isEmpty { staticRasterLayer?.mask = nil }
            else {
                staticMask.frame = bounds; staticMask.isGeometryFlipped = false
                staticMask.contentsScale = window?.backingScaleFactor ?? 2
                // Replace these pixels with bounded feedback instead of blending the translucent panel twice.
                let path = CGMutablePath(); path.addRect(bounds)
                for rect in merged { path.addRect(rect) }
                staticMask.path = path; staticRasterLayer?.mask = staticMask
            }
        }
        for (index, surface) in feedbackSurfaces.enumerated() {
            guard merged.indices.contains(index) else { surface.isHidden = true; surface.layer?.contents = nil; continue }
            let rect = merged[index]; surface.backgroundTheme = theme; surface.isHidden = false
            if surface.frame != rect { surface.frame = rect }
            let localBounds = CGRect(origin: .zero, size: rect.size)
            if surface.bounds != localBounds { surface.bounds = localBounds }
            surface.drawingOrigin = rect.origin
            surface.needsDisplay = true
        }
        CATransaction.commit()
    }
    static func weatherKey(_ code: Int) -> String? {
        switch code { case 0: "weather.clear"; case 1...2: "weather.partly_cloudy"; case 3: "weather.overcast"; case 45, 48: "weather.fog"; case 51...57: "weather.drizzle"; case 61...67, 80...82: "weather.rain"; case 71...77, 85...86: "weather.snow"; case 95...99: "weather.thunderstorm"; default: nil }
    }
    private static func tint(_ hex: String) -> NativeCalendarTint {
        // Category identities survive appearance changes and color-space conversion.
        // These are accepted category inputs; their paint colors remain Kit tokens.
        let normalized = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")).lowercased()
        switch normalized {
        case "98c8b2", "0f734c": return .mint
        case "b8a7df", "6f42c1": return .purple
        case "dbbd8e", "8e5900": return .amber
        case "e2a0a7", "be2b3a": return .red
        case "dca891", "a64918": return .peach
        case "97bbd3", "126a9f": return .sky
        case "d2a2bc", "a4376c": return .rose
        case "9bb7ee", "1c5ed2": return .blue
        default: break
        }
        let color = NSColor(nativeHex: normalized).usingColorSpace(.deviceRGB) ?? .gray
        let hue = color.hueComponent
        switch hue { case 0.05..<0.12: return .amber; case 0.12..<0.45: return .mint; case 0.45..<0.58: return .sky; case 0.58..<0.68: return .blue; case 0.68..<0.81: return .purple; case 0.81..<0.95: return .rose; default: return .red }
    }
    override func dispose() {
        staticRasterLayer?.mask = nil; staticMask.path = nil
        for surface in feedbackSurfaces { surface.painter = nil; surface.layer?.contents = nil; surface.removeFromSuperview() }
        lifetime.dispose(); NativeMotion.stop(spinner); spinner.removeFromSuperlayer(); rangeGeneration += 1; visibleRange = nil; renderKey = nil; boardShortcut = nil; cellRects = [:]; eventIDs = [:]; pointerEvent = nil; dropDay = nil
        super.dispose()
    }
}
