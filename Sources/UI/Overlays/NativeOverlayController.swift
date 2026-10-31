import AppKit

@MainActor final class OverlaySurfaceView: NativeCanvasView {
    override func draw(_ dirtyRect: NSRect) {
        theme.color(.popoverBg).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: NativeRadius.popover, yRadius: NativeRadius.popover).fill()
        super.draw(dirtyRect)
    }
    override func paint(_ item: NativeRenderItem) {
        if item.id == "overlay.close" {
            var background = item; background.label = ""; super.paint(background)
            let center = item.rect.center, radius = NativeSpace.xs
            theme.color(.textSecondary).setStroke()
            let path = NSBezierPath(); path.lineWidth = NativeSize.focusWidth
            path.move(to: CGPoint(x: center.x - radius, y: center.y - radius)); path.line(to: CGPoint(x: center.x + radius, y: center.y + radius))
            path.move(to: CGPoint(x: center.x - radius, y: center.y + radius)); path.line(to: CGPoint(x: center.x + radius, y: center.y - radius)); path.stroke()
        } else if item.id == "overlay.heading" {
            (item.label as NSString).draw(in: item.rect.insetBy(dx: NativeSpace.xs, dy: NativeSpace.xs), withAttributes: NativeFont.attributes(font: NativeFont.sectionHead, color: theme.color(.textPrimary), truncation: item.value == "wrapped-date" ? .byWordWrapping : .byTruncatingTail))
        } else if item.id == "overlay.error" {
            (item.label as NSString).draw(in: item.rect.insetBy(dx: NativeSpace.sm, dy: NativeSpace.xs), withAttributes: NativeFont.attributes(font: NativeFont.body, color: theme.color(.danger), truncation: .byWordWrapping))
        } else { super.paint(item) }
    }
}
@MainActor private final class OverlayContentView: NativeCanvasView {
    var onSelectionMenu: (@MainActor (String) -> Bool)?
    override func showMenu(for id: String) -> Bool { onSelectionMenu?(id) ?? false }
    override func rightMouseDown(with event: NSEvent) {
        if let item = item(at: convert(event.locationInWindow, from: nil)), showMenu(for: item.id) { return }
        super.rightMouseDown(with: event)
    }
    override func paint(_ item: NativeRenderItem) {
        guard item.kind == .text else { super.paint(item); return }
        let rect = item.rect.insetBy(dx: NativeSpace.sm, dy: NativeSpace.xs)
        (item.label as NSString).draw(in: rect, withAttributes: NativeFont.attributes(font: NativeFont.body, color: theme.color(item.color), truncation: .byWordWrapping))
    }
}

@MainActor private final class OverlayHostView: NSView {
    var onLayout: (@MainActor () -> Void)?
    override var isFlipped: Bool { true }
    override func layout() { super.layout(); onLayout?() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override init(frame: NSRect) { super.init(frame: frame); setAccessibilityElement(false) }
    // Empty board space must continue to receive the root's outside-click handling.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let result = super.hitTest(point); return result === self ? nil : result
    }
}

/// Only the root mounts this controller. No calendar/store/OS adapter is constructed here.
@MainActor final class NativeOverlayController: NSObject, OverlayController, NSTextFieldDelegate, NSTextViewDelegate {
    let context: BoardScreenContext
    private(set) var route: OverlayRoute
    private let host = OverlayHostView(frame: .zero)
    private let shadowHost = NSView(frame: .zero)
    private let shadow = NativeSurfaceShadow()
    var view: NSView { host }
    let surface: OverlaySurfaceView
    private let content: OverlayContentView
    private let scroll = OverflowScrollView(frame: .zero)
    private var choiceMenu: NativeMenu?
    private var choiceSession: NativePanelMenuSession?
    private let lifetime = ScreenLifetime()
    private(set) var textFields: [String: NativeTextField] = [:]
    private(set) var datePickers: [String: NativeDatePicker] = [:]
    private let notes = NSTextView(frame: .zero)
    private let notesScroll = OverflowScrollView(frame: .zero)
    private(set) var moreDetails = false
    private(set) var inlineMessage: String? {
        didSet { presentationOwnsInlineFailure = false }
    }
    private var presentationOwnsInlineFailure = false
    private(set) var editor: EventOverlayDraft?
    private var searchResults: [OverlaySearchResult] = []
    private var searchIndex = 0
    private var pickerYear: Int
    private var quickKind = "event"
    private var projectHasTarget = false
    private var quickID = UUID()
    private var anchor: CGRect?
    private var placed = false
    private var disposed = false
    private var busy = false
    private var unknownOperation: UUID?
    private enum DeleteStage { case discardDraft, confirm }
    private var deleteStage: DeleteStage?
    private var deleteOperation: UUID?
    private var ownsDeleteReceipt = false
    private var deleteFinished = false
    private var connecting = false
    private var connectionReturnFocus = false
    private var cityGeneration = 0
    private var cities: [City] = []
    private var cityPickerExpanded = false
    private var itemActions: [String: @MainActor () -> Void] = [:]
    private var returningFocus: FocusID?
    private var usedFields: Set<String> = []
    private var usedDates: Set<String> = []
    private var renderItems: [NativeRenderItem] = []
    private var y: CGFloat = 0
    private var bodyWidth: CGFloat = 0
    private var layingOut = false
    private var focusOrder: [FocusID] = []
    private let spinner = CAShapeLayer()
    private var spinnerReducedMotion: Bool?
    private var presentedRoute: BoardRoute?
    private var deferredPresentation: BoardRoute?
    private var draftCommitted = false
    var kind: OverlayKind {
        switch route { case .event: .event; case .newEvent: .add; case .search: .search; case .settings: .settings; case .monthPicker: .monthPicker; case .calendars: .calendars; case .agenda: .agenda }
    }

    init(context: BoardScreenContext, route: OverlayRoute) {
        self.context = context; self.route = route
        surface = OverlaySurfaceView(focus: context.focus); content = OverlayContentView(focus: context.focus)
        pickerYear = context.presentation.state.view.month.year
        returningFocus = context.focus.focusedID
        super.init()
        // Only this bounded, nonpainting sibling is layer backed for shadow geometry.
        // The board-sized transparent host allocates no drawing/cache layer.
        shadowHost.wantsLayer = true; shadowHost.clipsToBounds = false
        shadowHost.layerContentsRedrawPolicy = .never; shadowHost.layer?.masksToBounds = false
        shadowHost.setAccessibilityElement(false)
        host.addSubview(shadowHost); host.addSubview(surface); surface.addSubview(scroll); scroll.documentView = content
        surface.wantsLayer = true; surface.layer?.cornerRadius = NativeRadius.popover; surface.layer?.cornerCurve = .continuous
        spinner.fillColor = nil; spinner.lineWidth = NativeSize.focusWidth; spinner.isHidden = true; surface.layer?.addSublayer(spinner)
        host.onLayout = { [weak self] in guard let self else { return }; self.layout(in: self.host.bounds) }
        content.onSelectionMenu = { [weak self] id in self?.showSelectionMenu(id) ?? false }
        for canvas in [surface, content] {
            canvas.onAction = { [weak self] id in self?.activate(id) }
            canvas.onShortcut = { [weak self] event in self?.handleKey(event) ?? false }
        }
        notes.isRichText = false; notes.importsGraphics = false; notes.allowsUndo = true
        notes.drawsBackground = false; notes.font = NativeFont.body; notes.delegate = self
        notes.setAccessibilityIdentifier("overlay.event.notes"); notesScroll.documentView = notes; notesScroll.isHidden = true
        content.addSubview(notesScroll)
        let state = context.presentation.state
        switch route {
        case .event(let id, let source):
            anchor = source?.rect
            if let record = state.snapshot.calendar.records.first(where: { $0.id == id }) { editor = EventOverlayDraft(record: record, snapshot: state.snapshot) }
            else { inlineMessage = context.text("error.missing_event") }
        case .newEvent: editor = EventOverlayDraft(day: state.view.selectedDay, snapshot: state.snapshot)
        default: break
        }
        restoreDraft()
        surface.setAccessibilityIdentifier("overlay.surface")
        lifetime.own(context.presentation.subscribe { [weak self] change in
            guard !change.domains.isDisjoint(with: [.board, .calendar, .environment, .external, .activity, .error, .pending, .view]) else { return }
            guard let self else { return }
            if let id = self.deleteOperation, !self.ownsDeleteReceipt, !self.state.pending.contains(where: { $0.id == id }) {
                // A global error may belong to another operation; only this deletion's
                // receipt can establish whether the source was actually deleted.
                guard case .success(.completed(let receipt)) = self.context.presentation.reconcile(id) else {
                    self.inlineMessage = self.text("event.delete_unknown"); self.render(); return
                }
                switch receipt {
                case .success(.eventDeleted(let result), _):
                    self.deleteOperation = nil; self.busy = false; self.draftCommitted = true
                    if result.metadataStatus == .failed {
                        self.deleteFinished = true; self.inlineMessage = self.text("event.delete_partial"); self.render()
                    } else { self.requestDismiss() }
                case .failure(let failure, _):
                    if failure.committed == .unknown {
                        self.inlineMessage = self.text("event.delete_unknown"); self.render()
                    } else {
                        self.deleteOperation = nil; self.busy = false; self.showFailure(failure)
                    }
                default:
                    self.inlineMessage = self.text("event.delete_unknown"); self.render()
                }
                return
            }
            if let id = self.unknownOperation, !self.state.pending.contains(where: { $0.id == id }) {
                self.unknownOperation = nil; self.busy = false
                if let failure = self.state.lastError { self.showFailure(failure, presentationOwned: true) }
                else { self.draftCommitted = true; if let key = self.editor?.key { self.context.presentation.clearDraft(key) }; self.requestDismiss() }
            }
            if change.domains.contains(.error) {
                if let failure = self.state.lastError { self.showFailure(failure, presentationOwned: true) }
                else {
                    // Presentation owns read ordering and restores independent errors.
                    // Follow its reconciliation without clearing local validation or warnings.
                    if self.presentationOwnsInlineFailure { self.inlineMessage = nil }
                    self.render()
                }
            } else { self.render() }
        })
        bindExistingPending()
    }
    func present(_ request: BoardRoute) {
        guard !disposed else { return }
        if composing, !sameContent(request, presentedRoute) { deferredPresentation = request; return }
        let firstPresentation = presentedRoute == nil
        let replacesContent = !sameContent(request, presentedRoute)
        if replacesContent, presentedRoute != nil {
            closeChoices(restoreFocus: false)
            saveDraft(); host.window?.makeFirstResponder(content)
            for input in textFields.values { input.stringValue = "" }
            datePickers.values.forEach { $0.removeFromSuperview() }; datePickers = [:]
            inlineMessage = nil; moreDetails = false; quickID = UUID(); draftCommitted = false
            deleteStage = nil; deleteOperation = nil; ownsDeleteReceipt = false; deleteFinished = false; unknownOperation = nil; busy = false
        }
        var incomingAnchor: StableAnchor?
        switch request {
        case .openEvent(let id, let source):
            route = .event(id, PresentationAnchor(id: id, rect: source.boardRect)); incomingAnchor = source
            if replacesContent {
                editor = state.snapshot.calendar.records.first { $0.id == id }.map { EventOverlayDraft(record: $0, snapshot: state.snapshot) }
                inlineMessage = editor == nil ? text("error.missing_event") : nil; restoreDraft()
            }
        case .openAdd(let add):
            route = .newEvent; incomingAnchor = add.anchor
            if replacesContent {
                quickKind = add.kind.rawValue
                projectHasTarget = add.kind == .project && add.day != nil
                editor = EventOverlayDraft(day: add.day ?? state.view.selectedDay, snapshot: state.snapshot, projectID: add.projectID)
                restoreDraft()
            }
        case .openSearch(let query, let source):
            route = .search; incomingAnchor = source
            if replacesContent { context.presentation.setDraft(.search, value: .text(TextDraft(text: query))); context.presentation.send(.searchQuery(query)) }
        case .openSettings:
            route = .settings
            if firstPresentation { requestCities("") }
        case .openMonthPicker(let source): route = .monthPicker; incomingAnchor = source
        case .openCalendars(let source): route = .calendars; incomingAnchor = source
        case .revealAgenda(let day, let source): route = .agenda(day, PresentationAnchor(id: day.description, rect: source.boardRect)); incomingAnchor = source
        case .dismissOverlay: dismiss(); return
        case .revealPanel: return
        }
        presentedRoute = request; host.isHidden = false
        if firstPresentation || replacesContent { bindExistingPending() }
        if let focus = incomingAnchor?.returnFocusID { returningFocus = focus }
        let nextAnchor = incomingAnchor?.boardRect
        if anchor != nextAnchor { anchor = nextAnchor; placed = false }
        layout(in: host.bounds)
        if firstPresentation {
            focusInitialInput()
            if kind != .search, let layer = surface.layer { NativeMotion.apply(.popover, to: layer, reduceMotion: state.snapshot.environment.reduceMotion) }
        }
    }
    private func sameContent(_ a: BoardRoute, _ b: BoardRoute?) -> Bool {
        switch (a, b) {
        case (.openEvent(let a, _), .openEvent(let b, _)): a == b
        case (.openAdd(let a), .openAdd(let b)): a.kind == b.kind && a.day == b.day && a.projectID == b.projectID
        case (.openSearch, .openSearch), (.openSettings, .openSettings), (.openMonthPicker, .openMonthPicker), (.openCalendars, .openCalendars): true
        case (.revealAgenda(let a, _), .revealAgenda(let b, _)): a == b
        default: false
        }
    }
    private func restoreDraft() {
        guard let key = editor?.key else { return }
        if let saved = state.drafts[key]?.eventEditorValue { editor?.restore(saved) }
        else if case .event(let saved) = state.drafts[key] { editor?.event = saved }
    }
    private func bindExistingPending() {
        let eventID: String?
        if case .event(let id, _) = route { eventID = id } else { eventID = editor?.original?.id }
        let pending = state.pending.first { operation in
            operation.affected.contains { affected in
                if case .event(let id) = affected {
                    return eventID.map { $0 == id } ?? id.hasPrefix("pending:")
                }
                return false
            }
        }
        if let pending {
            busy = true
            if pending.kind == "deleteEvent" {
                deleteOperation = pending.id
                inlineMessage = text(pending.phase == .unknown ? "event.delete_unknown" : "notes.saving")
            } else {
                unknownOperation = pending.id
                inlineMessage = text(pending.phase == .unknown ? "error.transport_unknown" : "notes.saving")
            }
        }
    }
    var preferredSize: CGSize {
        switch route {
        case .settings: CGSize(width: NativeSize.searchWidth, height: NativeSize.agendaMaxHeight * 2)
        case .search: CGSize(width: NativeSize.searchWidth, height: NativeSize.agendaMaxHeight + NativeSpace.xxl * 2)
        case .monthPicker: CGSize(width: NativeSize.monthPickerWidth, height: NativeSize.compactTarget * 6 + NativeSpace.xxl * 2)
        case .event, .newEvent: CGSize(width: route == .newEvent ? NativeSize.searchWidth : NativeSize.popoverWidth, height: NativeSize.agendaMaxHeight + NativeSpace.xxl * (moreDetails ? 12 : 7))
        default: CGSize(width: NativeSize.popoverWidth, height: NativeSize.agendaMaxHeight + NativeSpace.xxl * 2)
        }
    }
    func layout(in bounds: CGRect) {
        guard !disposed, !layingOut, bounds.width > 0, bounds.height > 0 else { return }
        layingOut = true; defer { layingOut = false }
        surface.frame = OverlayPlacement.frame(size: preferredSize, anchor: anchor, within: bounds, previousOrigin: placed ? surface.frame.origin : nil)
        placed = true
        let inset = NativeSpace.lg, header = NativeSize.compactTarget + NativeSpace.sm * 2
        scroll.frame = CGRect(x: inset, y: header, width: max(0, surface.bounds.width - inset * 2), height: max(0, surface.bounds.height - header - inset))
        render()
    }
    func reanchor(_ rect: CGRect?) { anchor = rect; placed = false; layout(in: host.bounds) }
    func focusInitialInput() {
        if let field = textFields[route == .search ? "search" : "title"] { host.window?.makeFirstResponder(field) }
        else { host.window?.makeFirstResponder(content); context.focus.focus(FocusID("overlay.close")) }
    }
    private var state: PresentationState { context.presentation.state }
    private func text(_ key: String, _ values: [String: String] = [:]) -> String { context.text(key, values: values) }
    private func render() {
        guard !disposed else { return }
        if surface.bounds.width <= 0 { return }
        let theme = NativeTheme(appearance: state.snapshot.environment.resolvedAppearance)
        for canvas in [surface, content] where canvas.theme.appearance != theme.appearance { canvas.theme = theme }
        for canvas in [surface, content] { canvas.reduceMotion = state.snapshot.environment.reduceMotion }
        let nativeAppearance: NSAppearance.Name = theme.appearance == .dark ? .darkAqua : .aqua
        if surface.appearance?.name != nativeAppearance { surface.appearance = NSAppearance(named: nativeAppearance) }
        if shadowHost.frame != surface.frame { shadowHost.frame = surface.frame }
        if let layer = shadowHost.layer { shadow.update(in: layer, surfaceRect: shadowHost.bounds, appearance: theme.appearance, isFlipped: shadowHost.isFlipped) }
        notes.textColor = theme.color(.textPrimary); notes.insertionPointColor = theme.color(.textPrimary)
        let heading = title, headingWidth = max(0, surface.bounds.width - NativeSpace.lg * 4)
        let isAgenda: Bool = if case .agenda = route { true } else { false }
        let attributes = NativeFont.attributes(font: NativeFont.sectionHead, color: theme.color(.textPrimary), truncation: .byWordWrapping)
        let measured = ceil((heading as NSString).boundingRect(with: CGSize(width: max(1, headingWidth - NativeSpace.xs * 2), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes).height) + NativeSpace.xs * 2
        let headingHeight = isAgenda ? max(NativeSize.compactTarget, measured) : NativeSize.compactTarget
        var headerItems = [NativeRenderItem(id: "overlay.heading", rect: CGRect(x: NativeSpace.lg, y: NativeSpace.sm, width: headingWidth, height: headingHeight), label: heading, kind: .text, value: isAgenda ? "wrapped-date" : nil),
                           NativeRenderItem(id: "overlay.close", rect: CGRect(x: surface.bounds.width - NativeSize.compactTarget - NativeSpace.sm, y: NativeSpace.sm, width: NativeSize.compactTarget, height: NativeSize.compactTarget), label: text("event.cancel"), kind: .button)]
        var headerHeight = headingHeight + NativeSpace.sm * 2
        if let inlineMessage {
            let width = max(0, surface.bounds.width - NativeSpace.lg * 2)
            let attributes = NativeFont.attributes(font: NativeFont.body, color: theme.color(.danger), truncation: .byWordWrapping)
            let height = max(NativeSize.compactTarget, (inlineMessage as NSString).boundingRect(with: CGSize(width: max(1, width - NativeSpace.lg), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes).height + NativeSpace.sm)
            headerItems.append(NativeRenderItem(id: "overlay.error", rect: CGRect(x: NativeSpace.lg, y: headerHeight, width: width, height: height), label: inlineMessage, kind: .text, color: .danger))
            headerHeight += height + NativeSpace.xs
        }
        let fixedCancel: Bool = if case .event = route { editor != nil && deleteStage == nil } else { false }
        let footerHeight = NativeSize.compactTarget + NativeSpace.xs
        let footerY = max(headerHeight, surface.bounds.height - NativeSpace.lg - footerHeight)
        if fixedCancel {
            headerItems.append(NativeRenderItem(id: "overlay.cancel", rect: CGRect(x: NativeSpace.lg, y: footerY, width: max(0, surface.bounds.width - NativeSpace.lg * 2), height: footerHeight), label: text("event.cancel"), kind: .button))
        }
        surface.update(items: headerItems)
        let scrollBottom = fixedCancel ? footerY : surface.bounds.height - NativeSpace.lg
        scroll.frame = CGRect(x: NativeSpace.lg, y: headerHeight, width: max(0, surface.bounds.width - NativeSpace.lg * 2), height: max(0, scrollBottom - headerHeight))
        renderItems = []; itemActions = [:]; usedFields = []; usedDates = []; y = 0; bodyWidth = scroll.contentSize.width
        notesScroll.isHidden = true
        switch route {
        case .event, .newEvent: renderEvent()
        case .search: renderSearch()
        case .monthPicker: renderMonths()
        case .settings: renderSettings()
        case .calendars: renderCalendars()
        case .agenda(let day, _): renderAgenda(day)
        }
        for (id, field) in textFields { field.isHidden = !usedFields.contains(id); field.textColor = theme.color(.textPrimary); field.backgroundColor = theme.color(.raised) }
        for (id, picker) in datePickers { picker.isHidden = !usedDates.contains(id) }
        content.frame = CGRect(x: 0, y: 0, width: bodyWidth, height: max(y, scroll.contentSize.height))
        content.update(items: renderItems); scroll.updateFade(); registerNativeFocus()
        let isRefreshing = connecting || state.activity.refreshing
        if connectionReturnFocus, !isRefreshing, !state.activity.loading {
            connectionReturnFocus = false
            if context.focus.focusedID == nil, host.window?.firstResponder === content {
                let authorization = state.snapshot.calendarAuthorization
                let recoveryID = authorization == .denied || authorization == .restricted ? "overlay.privacy" : "overlay.refresh"
                context.focus.focus(FocusID(recoveryID))
            }
        }
        spinner.strokeColor = theme.color(.textSecondary).cgColor
        let side = NativeSpace.lg
        spinner.frame = CGRect(x: surface.bounds.width - NativeSize.compactTarget * 2 - NativeSpace.sm, y: NativeSpace.md, width: side, height: side)
        spinner.path = CGPath(ellipseIn: CGRect(x: NativeSpace.xxs, y: NativeSpace.xxs, width: side - NativeSpace.xs, height: side - NativeSpace.xs), transform: nil)
        spinner.strokeEnd = 0.75
        if spinner.isHidden == isRefreshing || (isRefreshing && spinnerReducedMotion != state.snapshot.environment.reduceMotion) {
            spinner.isHidden = !isRefreshing
            if isRefreshing { NativeMotion.apply(.spinner, to: spinner, reduceMotion: state.snapshot.environment.reduceMotion) }
            else { NativeMotion.stop(spinner) }
            spinnerReducedMotion = state.snapshot.environment.reduceMotion
        }
    }
    private var title: String {
        switch route {
        case .newEvent: return text("quick.title_" + quickKind)
        case .event: return text("event.title_edit")
        case .settings: return text("settings.title")
        case .search: return text("search.title")
        case .monthPicker: return String(pickerYear)
        case .calendars: return text("toolbar.calendars")
        case .agenda(let day, _):
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: state.snapshot.board.settings.language == .ko ? "ko_KR" : "en_US")
            formatter.calendar = Calendar(identifier: .gregorian)
            let zone = TimeZone(identifier: state.snapshot.clock.timeZone) ?? .current
            formatter.timeZone = zone
            formatter.setLocalizedDateFormatFromTemplate(day.year == state.snapshot.clock.today.year ? "EEEE MMMM d" : "y EEEE MMMM d")
            return formatter.string(from: day.date(in: zone))
        }
    }
    private func row(_ id: String, label: String, kind: NativeRenderItem.Kind = .button, enabled: Bool = true, checked: Bool = false, fill: NativeColorToken? = nil, height: CGFloat = NativeSize.compactTarget + NativeSpace.xs, action: (@MainActor () -> Void)? = nil) {
        renderItems.append(NativeRenderItem(id: id, rect: CGRect(x: 0, y: y, width: bodyWidth, height: height), label: label, kind: kind, enabled: enabled, checked: checked, fill: fill, color: fill == .fill ? .toastText : .textPrimary))
        if let action { itemActions[id] = action }; y += height + NativeSpace.xs
    }
    private func paragraph(_ id: String, _ value: String, color: NativeColorToken = .textSecondary) {
        let attrs = NativeFont.attributes(font: NativeFont.body, color: content.theme.color(color), truncation: .byWordWrapping)
        let height = max(NativeSize.compactTarget, (value as NSString).boundingRect(with: CGSize(width: max(1, bodyWidth - NativeSpace.lg), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs).height + NativeSpace.sm)
        // Separate accessible full text and wrapped painting through the specialized canvas below.
        renderItems.append(NativeRenderItem(id: id, rect: CGRect(x: 0, y: y, width: bodyWidth, height: height), label: value, kind: .text, color: color))
        y += height + NativeSpace.xs
    }
    private func label(_ id: String, _ key: String) { row(id + ".label", label: text(key), kind: .text) }
    @discardableResult private func field(_ id: String, key: String, value: String, enabled: Bool = true) -> NativeTextField {
        label(id, key)
        let input: NativeTextField
        if let existing = textFields[id] { input = existing } else {
            input = NativeTextField(label: text(key), identifier: "overlay." + id); input.delegate = self
            content.addSubview(input); textFields[id] = input
        }
        usedFields.insert(id); input.setAccessibilityLabel(text(key)); input.isEnabled = enabled
        input.frame = CGRect(x: NativeSpace.xs, y: y, width: max(0, bodyWidth - NativeSpace.sm), height: NativeSize.compactTarget)
        input.updateFromBase(value); input.placeholderString = id == "search" ? text("search.placeholder") : nil
        // AppKit's window provider can expose the native cell instead of the control view.
        input.cell?.setAccessibilityLabel(text(key)); input.cell?.setAccessibilityIdentifier("overlay." + id)
        y += NativeSize.compactTarget + NativeSpace.sm
        return input
    }
    private func date(_ id: String, key: String, value: Date, enabled: Bool = true, time: Bool = true) {
        label(id, key)
        let picker: NativeDatePicker
        if let existing = datePickers[id] { picker = existing } else {
            picker = NativeDatePicker(label: text(key), identifier: "overlay." + id, timeZone: TimeZone(identifier: state.snapshot.clock.timeZone) ?? .current)
            picker.target = self; picker.action = #selector(dateChanged(_:)); datePickers[id] = picker; content.addSubview(picker)
            picker.dateValue = value
        }
        usedDates.insert(id); picker.setAccessibilityLabel(text(key)); picker.isEnabled = enabled
        picker.datePickerElements = time ? [.yearMonthDay, .hourMinute] : [.yearMonthDay]
        picker.cell?.setAccessibilityLabel(text(key)); picker.cell?.setAccessibilityIdentifier("overlay." + id)
        picker.frame = CGRect(x: NativeSpace.xs, y: y, width: max(0, bodyWidth - NativeSpace.sm), height: NativeSize.compactTarget)
        y += NativeSize.compactTarget + NativeSpace.sm
    }
    private func renderEvent() {
        guard let editor else {
            if let id = deleteOperation, state.pending.contains(where: { $0.id == id && $0.phase == .unknown }) {
                paragraph("overlay.delete.unknown", text("event.delete_unknown")); row("overlay.delete.refresh", label: text("accounts.refresh"))
            }
            return
        }
        if let stage = deleteStage {
            switch stage {
            case .discardDraft:
                paragraph("overlay.delete.explanation", text("event.delete_discard_prompt"))
                row("overlay.delete.cancel", label: text("event.delete_keep"))
                row("overlay.delete.discard", label: text("event.delete_discard"))
            case .confirm:
                let occurrence = editor.original.map { $0.item.recurring || $0.detached } ?? false
                paragraph("overlay.delete.explanation", text(occurrence ? "event.delete_confirm_occurrence" : "event.delete_confirm"))
                row("overlay.delete.cancel", label: text("event.delete_cancel"))
                row("overlay.delete.confirm", label: text(occurrence ? "event.delete_occurrence" : "event.delete"), enabled: !busy && canDelete(editor))
                renderItems[renderItems.count - 1].color = .danger
            }
            return
        }
        if deleteFinished { paragraph("overlay.delete.partial", text("event.delete_partial")); return }
        if let id = deleteOperation, state.pending.contains(where: { $0.id == id && $0.phase == .unknown }) {
            paragraph("overlay.delete.unknown", text("event.delete_unknown"))
            row("overlay.delete.refresh", label: text("accounts.refresh"))
            return
        }
        let sourceEditable = !editor.isReadOnly && editor.metadataRetryID == nil && !busy
        if case .newEvent = route { row("overlay.kind", label: text("quick.kind") + ": " + text("quick.kind_" + quickKind), enabled: !busy) }
        if editor.isReadOnly { paragraph("overlay.readonly", text("event.readonly_hint")) }
        field("title", key: "event.field_title", value: editor.event.title, enabled: sourceEditable)
        if quickKind == "event" {
            let calendar = state.snapshot.calendar.calendars.first { $0.id == editor.event.calendarID }
            row("overlay.calendar", label: text("event.calendar") + ": " + (calendar?.title ?? text("error.no_writable")), enabled: sourceEditable)
            if state.snapshot.board.hiddenCalendarIDs.contains(editor.event.calendarID) { paragraph("overlay.hidden", text("event.hidden_calendar_help")) }
            date("start", key: "event.field_start", value: editor.event.start, enabled: sourceEditable, time: !editor.event.allDay)
            date("end", key: "event.field_end", value: editor.event.end, enabled: sourceEditable, time: !editor.event.allDay)
            row("overlay.allday", label: text("event.all_day"), kind: .checkBox, enabled: sourceEditable, checked: editor.event.allDay)
            let project = state.snapshot.board.projects.first { $0.id == editor.projectID }
            row("overlay.project", label: text("event.project") + ": " + (project?.title ?? text("event.project_none")), enabled: !busy)
            row("overlay.pin", label: text("event.pin"), kind: .checkBox, enabled: !busy, checked: editor.pinned)
            row("overlay.more", label: text(moreDetails ? "event.fewer_details" : "event.more_details"))
            if moreDetails {
                field("location", key: "event.location", value: editor.event.location, enabled: sourceEditable)
                label("notes", "event.notes"); notesScroll.isHidden = false
                notes.setAccessibilityLabel(text("event.notes"))
                notesScroll.frame = CGRect(x: NativeSpace.xs, y: y, width: max(0, bodyWidth - NativeSpace.sm), height: NativeSize.compactTarget * 3)
                notes.isEditable = sourceEditable
                if notes.window?.firstResponder !== notes, !notes.hasMarkedText(), notes.string != editor.event.notes { notes.string = editor.event.notes }
                notes.frame.size = CGSize(width: notesScroll.contentSize.width, height: max(notesScroll.contentSize.height, notes.layoutManager?.usedRect(for: notes.textContainer!).height ?? 0))
                y += NativeSize.compactTarget * 3 + NativeSpace.sm
            }
            if editor.original?.item.recurring == true { paragraph("overlay.occurrence", text("event.this_occurrence")) }
            if editor.externalChange(in: state.snapshot) { paragraph("overlay.changed", text("error.stale_conflict")) }
        } else {
            if quickKind == "project" { row("overlay.project.target", label: text("projects.target_date_optional"), kind: .checkBox, enabled: !busy, checked: projectHasTarget) }
            date("start", key: "calendar.date", value: editor.event.start, enabled: !busy && (quickKind != "project" || projectHasTarget), time: false)
        }
        let saveKey = editor.metadataRetryID != nil ? "error.partial_retry" : quickKind == "project" ? "projects.submit_add" : quickKind == "countdown" ? "deadlines.submit_add" : editor.isReadOnly ? "event.save_link" : editor.original == nil ? "event.submit_add" : "event.save_changes"
        if canDelete(editor) { row("overlay.delete", label: text("event.delete"), enabled: !busy); renderItems[renderItems.count - 1].color = .danger }
        row("overlay.save", label: text(busy ? "toast.event_saving" : saveKey), enabled: !busy, fill: .fill)
        if unknownOperation != nil { row("overlay.reconcile", label: text("error.retry_action")) }
        if case .newEvent = route { row("overlay.cancel", label: text("event.cancel")) }
        else { y += NativeSize.overflowEdge }
    }
    private func renderSearch() {
        let value = state.drafts[.search]?.textValue?.text ?? state.view.query
        field("search", key: "search.input_label", value: value)
        let matches = state.activity.loading ? [] : OverlaySearch.results(query: value, snapshot: state.snapshot, limit: 13)
        searchResults = Array(matches.prefix(12))
        searchIndex = min(max(0, searchIndex), max(0, searchResults.count - 1))
        paragraph("overlay.search.scope", text("search.scope"))
        if state.activity.loading { paragraph("overlay.search.loading", text("loading.label")) }
        else if searchResults.isEmpty { paragraph("overlay.search.empty", text("search.empty_results")) }
        if matches.count > 12 { paragraph("overlay.search.limit", text("search.limit")) }
        for (index, result) in searchResults.enumerated() {
            row("overlay.result." + result.id, label: result.title, kind: .row, fill: index == searchIndex ? .selected : nil)
            paragraph("overlay.meta." + result.id, text(result.kindKey) + (result.day.map { " · " + $0.description } ?? ""))
        }
        paragraph("overlay.search.hint", text("search.hint"))
    }
    private func renderMonths() {
        row("overlay.year.previous", label: "‹ " + String(pickerYear - 1))
        row("overlay.year.next", label: String(pickerYear + 1) + " ›")
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: state.snapshot.environment.localeIdentifier)
        let months = formatter.shortMonthSymbols ?? []
        for (index, rect) in NativeGeometry.grid(in: CGRect(x: 0, y: y, width: bodyWidth, height: NativeSize.compactTarget * 4 + NativeSpace.sm * 4), columns: 3, rows: 4).enumerated() {
            renderItems.append(NativeRenderItem(id: "overlay.month.\(index + 1)", rect: rect.insetBy(dx: NativeSpace.xxs, dy: NativeSpace.xxs), label: months.indices.contains(index) ? months[index] : String(index + 1), kind: .button,
                                              fill: state.view.month.year == pickerYear && state.view.month.month == index + 1 ? .selected : nil))
        }
        y += NativeSize.compactTarget * 4 + NativeSpace.sm * 4
    }
    private func renderCalendars() {
        let snapshot = state.snapshot
        paragraph("overlay.calendar.count", text("accounts.count", ["0": String(snapshot.calendar.calendars.count)]) + " · " + (snapshot.board.hiddenCalendarIDs.isEmpty ? text("accounts.all_shown") : text("accounts.hidden", ["0": String(snapshot.board.hiddenCalendarIDs.count)])))
        if let refreshedAt = snapshot.calendarRefreshedAt { let formatter = DateFormatter(); formatter.timeStyle = .short; paragraph("overlay.updated", text("accounts.updated", ["0": formatter.string(from: refreshedAt)])) }
        if snapshot.calendar.calendars.isEmpty, snapshot.calendarAuthorization == .authorized { paragraph("overlay.calendar.empty", text("accounts.empty")) }
        var account: String?
        for calendar in snapshot.calendar.calendars.sorted(by: { ($0.account, $0.title, $0.id) < ($1.account, $1.title, $1.id) }) {
            if account != calendar.account { row("overlay.account." + calendar.id, label: calendar.account, kind: .text); account = calendar.account }
            row("overlay.calendar.visibility." + calendar.id, label: calendar.title, kind: .checkBox, checked: !snapshot.board.hiddenCalendarIDs.contains(calendar.id))
            let count = snapshot.calendar.records.filter { $0.item.calendarID == calendar.id }.count
            paragraph("overlay.calendar.meta." + calendar.id, text("accounts.in_view", ["0": String(count)]) + (calendar.writable ? "" : " · " + text("calendar.readonly")))
        }
        let isRefreshing = connecting || state.activity.loading || state.activity.refreshing
        let authorization = snapshot.calendarAuthorization
        let recovery = authorization == .denied || authorization == .restricted
        if recovery {
            paragraph("overlay.permission", text(authorization == .denied ? "banner.permission_denied" : "banner.permission_restricted"))
            row("overlay.privacy", label: text("banner.open_system_settings"), enabled: !isRefreshing, height: 44)
        } else {
            if authorization == .notDetermined { paragraph("overlay.permission", text("banner.connect")) }
            if authorization == .writeOnly { paragraph("overlay.permission", text("banner.permission_write_only")) }
            if authorization == .unavailable { paragraph("overlay.permission", text("banner.permission_unavailable")) }
            let action: String = switch authorization { case .authorized: "accounts.refresh"; case .writeOnly: "accounts.upgrade_access"; case .unavailable: "accounts.retry"; default: "accounts.connect" }
            let progress: String = switch authorization { case .notDetermined, .writeOnly: "accounts.connecting"; case .unavailable: "accounts.retrying"; default: "accounts.refreshing" }
            row("overlay.refresh", label: text(isRefreshing ? progress : action), enabled: !isRefreshing, height: 44)
        }
        row("overlay.accounts", label: text("accounts.manage"))
    }
    private func renderAgenda(_ day: DateOnly) {
        let zone = TimeZone(identifier: state.snapshot.clock.timeZone) ?? .current
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let records = state.snapshot.calendar.records.filter {
            !state.snapshot.board.hiddenCalendarIDs.contains($0.item.calendarID) &&
                DayMath.intersects(start: $0.item.start, end: $0.item.end, day: day.date(in: zone), calendar: calendar)
        }
        if records.isEmpty { paragraph("overlay.agenda.empty", text("today.empty")) }
        for record in records {
            row("overlay.agenda." + record.id, label: record.item.title, kind: .row)
            paragraph("overlay.agenda.meta." + record.id, record.item.calendarTitle + (record.item.writable ? "" : " · " + text("calendar.readonly")))
        }
    }
    private func renderSettings() {
        let snapshot = state.snapshot, settings = snapshot.board.settings
        for (id, key, current, options) in [
            ("appearance", "settings.appearance", settings.appearance.rawValue, [("dark", "settings.theme_dark"), ("light", "settings.theme_light"), ("system", "settings.theme_system")]),
            ("week", "settings.week_start", settings.weekStart.rawValue, [("system", "settings.start_system"), ("sunday", "settings.start_sun"), ("monday", "settings.start_mon")]),
            ("language", "settings.language", settings.language.rawValue, [("en", "settings.lang_en"), ("ko", "settings.lang_ko")])
        ] {
            label("settings." + id, key)
            for (value, optionKey) in options { row("overlay.settings.\(id).\(value)", label: text(optionKey), kind: .checkBox, checked: value == current) }
        }
        label("network", "settings.network_section")
        row("overlay.settings.network", label: text("settings.network_master"), kind: .checkBox, checked: settings.networkEnabled)
        row("overlay.settings.rates", label: text("settings.rates_toggle"), kind: .checkBox, checked: settings.ratesEnabled)
        if !settings.networkEnabled { paragraph("overlay.fx.preference", text("settings.rates_network_hint")) }
        if !settings.networkEnabled { paragraph("overlay.fx.state", text("status.network_disabled")) }
        else if !settings.ratesEnabled { paragraph("overlay.fx.state", text("status.fx_off")) }
        else if snapshot.external.rates.state == .stale { paragraph("overlay.fx.state", text("status.fx_stale")) }
        else if snapshot.external.rates.state == .unavailable { paragraph("overlay.fx.state", text("status.fx_offline")) }
        for (index, day) in snapshot.subscriptionSummary.rateDates.enumerated() { paragraph("overlay.fx.date.\(index)", text("sub.fx_rate_date", ["date": day.description])) }
        if !snapshot.subscriptionSummary.complete {
            let totals = snapshot.subscriptionSummary.byCurrency.filter { snapshot.subscriptionSummary.missingCurrencies.contains($0.currency) }.map { $0.monthlyAmount + " " + $0.currency }.joined(separator: " + ")
            paragraph("overlay.fx.partial", text("sub.fx_partial", ["0": snapshot.subscriptionSummary.krwMonthlyAmount ?? "0", "1": totals]))
        }
        row("overlay.settings.weather", label: text("settings.weather_toggle"), kind: .checkBox, checked: settings.weather.enabled)
        row("overlay.city", label: text("settings.weather_city") + ": " + (cities.first { $0.id == settings.weather.cityID }.map { settings.language == .ko ? $0.nameKO : $0.nameEN } ?? settings.weather.cityID ?? text("settings.start_system")))
        field("citySearch", key: "settings.weather_city_search", value: textFields["citySearch"]?.stringValue ?? "")
        if cityPickerExpanded {
            if cities.isEmpty { paragraph("overlay.city.empty", text("weather.city_not_found")) }
            for city in cities.prefix(12) {
                row("overlay.city." + city.id, label: settings.language == .ko ? city.nameKO : city.nameEN, action: { [weak self] in self?.setCity(city.id) })
            }
        }
        row("overlay.credit.weather", label: text("weather.credit_label")); row("overlay.credit.weatherLicense", label: text("weather.license_name"))
        paragraph("overlay.credit.change", text("weather.transformation"))
        row("overlay.credit.rates", label: text("rates.credit_label"))
        label("notifications", "settings.notify_section")
        paragraph("overlay.notification.policy", text("settings.sub_notify_expl"))
        if snapshot.notification.focusDesired, !snapshot.notification.focusEffective, state.pending.contains(where: { $0.affected.contains(.settings) }) { paragraph("overlay.notification.pending", text("sub.notify_pending")) }
        else if snapshot.notification.permission.authorization == .denied || (snapshot.notification.focusDesired && !snapshot.notification.focusEffective) { paragraph("overlay.notification.denied", text("sub.notify_denied")) }
        label("slots", "settings.panels")
        for (slot, key) in [(SlotID.wide, "wide"), (.railTop, "rail_top"), (.railMiddle, "rail_middle"), (.railBottom, "rail_bottom")] {
            let panel = snapshot.board.layout.slots[slot.rawValue] ?? .today
            row("overlay.slot." + slot.rawValue, label: text("settings.slot_" + key, ["0": text(panelTitleKey(panel))]), kind: .checkBox, checked: !snapshot.board.layout.hiddenSlots.contains(slot.rawValue))
        }
        paragraph("overlay.calendar.fixed", text("settings.calendar_fixed")); row("overlay.reset", label: text("settings.reset_layout")); paragraph("overlay.reset.hint", text("settings.reset_layout_hint"))
        label("focus", "timer.title")
        row("overlay.focus.duration", label: text("timer.mode_focus", ["0": minutes(settings.focus.focusSeconds)]))
        row("overlay.break.duration", label: text("timer.mode_break", ["0": minutes(settings.focus.breakSeconds)]))
        row("overlay.focus.notify", label: text("timer.notify_finish"), kind: .checkBox, checked: snapshot.notification.focusDesired)
        label("system", "settings.system")
        row("overlay.login", label: text("menu.launch_at_login"), kind: .checkBox, checked: OverlaySettings.loginChecked(snapshot))
        if snapshot.login == .requiresApproval || snapshot.login == .notFound { paragraph("overlay.login.approval", text(snapshot.login == .requiresApproval ? "error.login_item" : "error.login_registration")); row("overlay.login.settings", label: text("settings.open_login")) }
        if state.pending.contains(where: { $0.affected.contains(.settings) }) { paragraph("overlay.settings.saving", text("notes.saving")) }
    }
    private func panelTitleKey(_ panel: PanelID) -> String {
        switch panel { case .worldClock: "world_clock.title"; case .focusTimer: "timer.title"; case .notes: "notes.title"; case .deadlines: "deadlines.title"; case .subscriptions: "sub.title"; default: panel.rawValue + ".title" }
    }
    private func minutes(_ seconds: Int) -> String {
        let formatter = NumberFormatter(); formatter.locale = Locale(identifier: state.snapshot.board.settings.language == .ko ? "ko_KR" : "en_US")
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: Double(seconds) / 60)) ?? String(seconds / 60)
    }
    func activate(_ id: String) {
        guard !disposed else { return }
        if let stage = deleteStage {
            let allowed = id == "overlay.close" || id == "overlay.delete.cancel" ||
                (stage == .discardDraft && id == "overlay.delete.discard") ||
                (stage == .confirm && id == "overlay.delete.confirm")
            guard allowed else { return }
        }
        if let action = itemActions[id] { action(); return }
        switch id {
        case "overlay.close": if deleteStage != nil { cancelDelete() } else { requestDismiss() }
        case "overlay.cancel": cancelDraft()
        case "overlay.delete": beginDelete()
        case "overlay.delete.cancel": cancelDelete()
        case "overlay.delete.discard": discardForDelete()
        case "overlay.delete.confirm": confirmDelete()
        case "overlay.delete.refresh": refresh()
        case "overlay.more": moreDetails.toggle(); layout(in: host.bounds)
        case "overlay.allday":
            guard editor?.isReadOnly == false, !busy else { return }; editor?.event.allDay.toggle()
            if editor?.event.allDay == true, var value = editor?.event {
                var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: state.snapshot.clock.timeZone) ?? .current
                value.start = calendar.startOfDay(for: value.start); value.end = calendar.startOfDay(for: value.end)
                if value.end <= value.start { value.end = calendar.date(byAdding: .day, value: 1, to: value.start)! }; editor?.event = value
                datePickers["start"]?.dateValue = value.start; datePickers["end"]?.dateValue = value.end
            }
            saveDraft(); render()
        case "overlay.pin": guard !busy else { return }; editor?.pinned.toggle(); saveDraft(); render()
        case "overlay.calendar", "overlay.project", "overlay.kind", "overlay.focus.duration", "overlay.break.duration":
            _ = showSelectionMenu(id)
        case "overlay.project.target": projectHasTarget.toggle(); render()
        case "overlay.save": save()
        case "overlay.reconcile": if let unknownOperation { context.presentation.send(.reconcile(unknownOperation)) }
        case "overlay.refresh": refresh()
        case "overlay.accounts": perform(.open(.accounts))
        case "overlay.privacy": perform(.open(.privacy))
        case "overlay.login.settings": perform(.open(.login))
        case "overlay.login": perform(.setLogin(!OverlaySettings.loginChecked(state.snapshot)))
        case "overlay.reset": context.presentation.send(.edit(.layout(.reset), undoable: false))
        case "overlay.year.previous": pickerYear = max(1, pickerYear - 1); render()
        case "overlay.year.next": pickerYear = min(9999, pickerYear + 1); render()
        case "overlay.city": cityPickerExpanded.toggle(); if cityPickerExpanded { requestCities("") }; render()
        case "overlay.credit.weather": perform(.openAttribution(.weather))
        case "overlay.credit.weatherLicense": perform(.openAttribution(.weatherLicense))
        case "overlay.credit.rates": perform(.openAttribution(.rates))
        case "overlay.focus.notify": perform(.notification(.focus, enabled: !state.snapshot.notification.focusDesired))
        default:
            if id.hasPrefix("overlay.result."), let result = searchResults.first(where: { "overlay.result." + $0.id == id }) { openSearchResult(result) }
            else if id.hasPrefix("overlay.month."), let month = Int(id.dropFirst("overlay.month.".count)), let day = DateOnly(String(format: "%04d-%02d-01", pickerYear, month)) {
                let delta = (day.year - state.view.month.year) * 12 + day.month - state.view.month.month
                let previousMode = state.view.mode
                if previousMode == .week { context.presentation.send(.setMode(.month)) }
                context.presentation.send(.movePeriod(delta))
                if previousMode == .week { context.presentation.send(.selectDay(day)); context.presentation.send(.setMode(.week)) }
                requestDismiss()
            } else if id.hasPrefix("overlay.calendar.visibility.") {
                let calendarID = String(id.dropFirst("overlay.calendar.visibility.".count))
                context.presentation.send(.edit(.calendarVisibility(id: calendarID, isHidden: !state.snapshot.board.hiddenCalendarIDs.contains(calendarID)), undoable: false))
            } else if id.hasPrefix("overlay.slot."), let slot = SlotID(rawValue: String(id.dropFirst("overlay.slot.".count))) {
                context.presentation.send(.edit(.layout(.setHidden(slot: slot, !state.snapshot.board.layout.hiddenSlots.contains(slot.rawValue))), undoable: false))
            } else if id.hasPrefix("overlay.agenda.") { openEvent(String(id.dropFirst("overlay.agenda.".count))) }
            else { settingsAction(id) }
        }
    }
    private func showSelectionMenu(_ id: String) -> Bool {
        guard !disposed, !composing, !host.isHidden, host.window != nil,
              let item = content.items.first(where: { $0.id == id && $0.enabled }) else { return false }
        switch id {
        case "overlay.calendar":
            return showChoices(at: item, selected: editor?.event.calendarID, options: state.snapshot.calendar.calendars.filter(\.writable).map { ($0.id, $0.title) }) { [weak self] value in self?.editor?.event.calendarID = value; self?.saveDraft() }
        case "overlay.project":
            return showChoices(at: item, selected: editor?.projectID?.uuidString ?? "", options: [("", text("event.project_none"))] + state.snapshot.board.projects.map { ($0.id.uuidString, $0.title) }) { [weak self] value in self?.editor?.projectID = UUID(uuidString: value); self?.saveDraft() }
        case "overlay.kind":
            return showChoices(at: item, selected: quickKind, options: ["event", "countdown", "project"].map { ($0, text("quick.kind_" + $0)) }) { [weak self] in self?.quickKind = $0 }
        case "overlay.focus.duration", "overlay.break.duration":
            let focus = id == "overlay.focus.duration"
            let options = (focus ? Array(stride(from: 15, through: 60, by: 5)) : Array(stride(from: 5, through: 15, by: 5))).map { (String($0 * 60), String($0)) }
            return showChoices(at: item, selected: String(focus ? state.snapshot.board.settings.focus.focusSeconds : state.snapshot.board.settings.focus.breakSeconds), options: options) { [weak self] seconds in
                guard let self, let value = Int(seconds) else { return }; var settings = self.state.snapshot.board.settings.focus
                if focus { settings.focusSeconds = value } else { settings.breakSeconds = value }
                var patch = SettingsPatch(); patch.focus = .set(settings); self.saveSettings(patch)
            }
        default: return false
        }
    }
    private func showChoices(at item: NativeRenderItem, selected: String?, options: [(String, String)], select: @escaping @MainActor (String) -> Void) -> Bool {
        closeChoices(restoreFocus: false)
        let entries = options.enumerated().map { NativeMenuEntry(id: "overlay.choice.\($0.offset)", title: $0.element.1, checked: $0.element.0 == selected) }
        let menu = NativeMenu(items: entries) { [weak self] id in
            guard let self, !self.disposed, !self.host.isHidden,
                  self.content.items.contains(where: { $0.id == item.id && $0.enabled }),
                  let index = entries.firstIndex(where: { $0.id == id }) else { return }
            select(options[index].0); self.render()
        }
        choiceMenu = menu
        context.focus.focus(item.focusID)
        let session = NativePanelMenuSession(menu: menu.menu, focus: context.focus, returnID: item.focusID)
        choiceSession = session
        defer {
            session.finish(restoreFocus: !disposed && !host.isHidden)
            if choiceMenu === menu { choiceMenu = nil; choiceSession = nil }
            menu.dispose()
        }
        return SystemNativePanelMenuPresenter().present(menu.menu, at: CGPoint(x: item.rect.minX, y: item.rect.maxY), in: content)
    }
    private func closeChoices(restoreFocus: Bool = true) {
        choiceSession?.finish(restoreFocus: restoreFocus); choiceSession = nil
        choiceMenu?.dispose(); choiceMenu = nil
    }
    private func settingsAction(_ id: String) {
        var patch = SettingsPatch()
        if id.hasPrefix("overlay.settings.appearance."), let value = AppAppearance(rawValue: String(id.dropFirst("overlay.settings.appearance.".count))) { patch.appearance = .set(value) }
        else if id.hasPrefix("overlay.settings.week."), let value = WeekStart(rawValue: String(id.dropFirst("overlay.settings.week.".count))) { patch.weekStart = .set(value) }
        else if id.hasPrefix("overlay.settings.language."), let value = BoardLanguage(rawValue: String(id.dropFirst("overlay.settings.language.".count))) { patch.language = .set(value) }
        else if id == "overlay.settings.network" { patch.networkEnabled = .set(!state.snapshot.board.settings.networkEnabled) }
        else if id == "overlay.settings.rates" { patch.ratesEnabled = .set(!state.snapshot.board.settings.ratesEnabled) }
        else if id == "overlay.settings.weather" { var weather = state.snapshot.board.settings.weather; weather.enabled.toggle(); patch.weather = .set(weather) }
        else { return }
        saveSettings(patch)
    }
    private func saveSettings(_ patch: SettingsPatch) { perform(.edit(.settings(patch), undoable: false)) }
    private func setCity(_ id: String) { cityPickerExpanded = false; var patch = SettingsPatch(); var weather = state.snapshot.board.settings.weather; weather.cityID = id; patch.weather = .set(weather); saveSettings(patch) }
    private func requestCities(_ query: String) {
        cityGeneration += 1; let generation = cityGeneration
        guard query.count <= 100 else { cities = []; render(); return }
        guard let handle = context.presentation.send(.command(.listCities(query: query))) else { return }
        Task { [weak self] in
            let receipt = await handle.settled.value
            guard let self, !self.disposed, generation == self.cityGeneration else { return }
            if case .success(.cities(let values), _) = receipt { self.cities = values; self.render() }
            else if case .failure(let failure, _) = receipt { self.showFailure(failure) }
        }
    }
    private func refresh() {
        guard !connecting && !state.activity.loading && !state.activity.refreshing else { return }
        let isConnect = state.snapshot.calendarAuthorization == .notDetermined || state.snapshot.calendarAuthorization == .writeOnly
        connectionReturnFocus = context.focus.focusedID == FocusID("overlay.refresh")
        if isConnect { connecting = true; render() }
        let command: BoardCommand = isConnect ? .connect : .refresh(OverlaySettings.range(state), refreshSources: true)
        if !perform(command, completed: { [weak self] _ in
            guard let self, isConnect else { return }; self.connecting = false; self.render()
        }), isConnect {
            connecting = false; render()
        }
    }
    @discardableResult private func perform(_ command: BoardCommand, completed: (@MainActor (CommandReceipt) -> Void)? = nil) -> Bool {
        inlineMessage = nil
        guard let handle = context.presentation.send(.command(command)) else { return false }
        Task { [weak self] in
            let receipt = await handle.settled.value
            guard let self, !self.disposed else { return }
            // Read/connect failures are projected by the subscription above. A late
            // receipt must not resurrect an error retired by a newer calendar read.
            switch command {
            case .connect, .refresh: break
            default: if case .failure(let failure, _) = receipt { self.showFailure(failure) }
            }
            completed?(receipt)
        }
        return true
    }
    private func showFailure(_ failure: AppFailure, presentationOwned: Bool = false) {
        let key = failure.code == .commitOutcomeUnknown ? "error.transport_unknown" : failure.messageKey == "error.generic" ? "error." + failure.code.rawValue.lowercased() : failure.messageKey
        inlineMessage = text(key, failure.values); presentationOwnsInlineFailure = presentationOwned; render()
        if !composing, let field = failure.field, case .event(let path) = field {
            let id: String? = switch path { case .title: "title"; case .location: "location"; case .notes: "notes"; case .start: "start"; case .end: "end"; default: nil }
            if let id { context.focus.focus(FocusID("overlay." + id)) }
        }
    }
    private var composing: Bool {
        notes.hasMarkedText() || textFields.values.contains { ($0.currentEditor() as? NSTextView)?.hasMarkedText() == true }
    }
    private func canDelete(_ draft: EventOverlayDraft) -> Bool {
        guard case .event = route, let original = draft.original, !deleteFinished,
              state.snapshot.calendarAuthorization == .authorized,
              let current = state.snapshot.calendar.records.first(where: { $0.id == original.id }), current.item.writable,
              state.snapshot.calendar.calendars.contains(where: { $0.id == current.item.calendarID && $0.writable }) else { return false }
        return true
    }
    private func setDeleteStage(_ stage: DeleteStage, focus id: String) {
        deleteStage = stage; inlineMessage = nil; render()
        host.window?.makeFirstResponder(content); context.focus.focus(FocusID(id))
    }
    private func beginDelete() {
        guard !busy, !composing, let draft = editor, let original = draft.original, canDelete(draft) else { return }
        let baseline = EventOverlayDraft(record: original, snapshot: state.snapshot)
        let changed = draft.event != original.draft || draft.projectID != baseline.projectID || draft.pinned != baseline.pinned
        setDeleteStage(changed ? .discardDraft : .confirm, focus: "overlay.delete.cancel")
    }
    private func cancelDelete() {
        guard deleteStage != nil else { return }
        deleteStage = nil; render(); host.window?.makeFirstResponder(content); context.focus.focus(FocusID("overlay.delete"))
    }
    private func discardForDelete() {
        guard deleteStage == .discardDraft, !busy, !composing, let original = editor?.original, let draft = editor, canDelete(draft) else { return }
        context.presentation.clearDraft(draft.key)
        editor = EventOverlayDraft(record: original, snapshot: state.snapshot)
        setDeleteStage(.confirm, focus: "overlay.delete.cancel")
    }
    private func confirmDelete() {
        guard deleteStage == .confirm, !busy, !composing, let draft = editor, let original = draft.original, canDelete(draft) else { return }
        busy = true; deleteStage = nil; inlineMessage = nil; render()
        guard let handle = context.presentation.send(.command(.deleteEvent(EventIdentity(id: original.id), expectedVersion: original.version))) else { busy = false; render(); return }
        deleteOperation = handle.id; ownsDeleteReceipt = true
        let presentation = context.presentation
        let submittedDraft = draft.savedDraft
        Task { [weak self, weak presentation] in
            let receipt = await handle.settled.value
            if case .success(.eventDeleted, _) = receipt, let presentation,
               presentation.state.drafts[draft.key]?.eventEditorValue == submittedDraft { presentation.clearDraft(draft.key) }
            guard let self, !self.disposed, case .event(let currentID, _) = self.route, currentID == original.id else { return }
            self.ownsDeleteReceipt = false
            switch receipt {
            case .success(.eventDeleted(let result), _):
                self.deleteOperation = nil; self.busy = false; self.draftCommitted = true
                if result.metadataStatus == .failed { self.deleteFinished = true; self.inlineMessage = self.text("event.delete_partial"); self.render() }
                else { self.requestDismiss() }
            case .failure(let failure, _):
                if failure.committed == .unknown {
                    self.deleteOperation = handle.id; self.busy = true; self.inlineMessage = self.text("event.delete_unknown"); self.render()
                } else { self.deleteOperation = nil; self.busy = false; self.showFailure(failure) }
            default:
                self.deleteOperation = nil; self.busy = false; self.showFailure(AppFailure(code: .invalidResponse))
            }
        }
    }
    private func saveDraft() { if !draftCommitted, let editor { context.presentation.setDraft(editor.key, value: .eventEditor(editor.savedDraft)) } }
    private func cancelDraft() {
        guard !composing else { return }
        draftCommitted = true
        if let key = editor?.key { context.presentation.clearDraft(key) }
        requestDismiss()
    }
    private func save() {
        guard deleteStage == nil, !busy, !composing, let editor else { return }
        let command: BoardCommand
        if quickKind != "event" {
            guard !editor.event.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { showFailure(AppFailure(code: .validationFailed, messageKey: "error.empty_name")); return }
            let zone = TimeZone(identifier: state.snapshot.clock.timeZone) ?? .current
            guard let day = DateOnly(date: editor.event.start, timeZone: zone) else { return }
            command = quickKind == "project" ? .edit(.project(.create(ProjectInput(id: quickID, title: editor.event.title, targetDay: projectHasTarget ? day : nil))), undoable: true)
                : .edit(.countdown(.create(CountdownInput(id: quickID, title: editor.event.title, day: day))), undoable: true)
        } else {
            switch editor.saveInput(snapshot: state.snapshot) {
            case .success(let input): command = .saveEvent(input)
            case .failure(let failure): showFailure(failure); return
            }
        }
        let feedback = quickKind == "project" ? "toast.project_added" : quickKind == "countdown" ? "toast.countdown_added" : "toast.event_saving"
        busy = true; inlineMessage = nil; render()
        guard let handle = context.presentation.send(.command(command, feedback: PresentationFeedback(messageKey: feedback))) else { busy = false; render(); return }
        let presentation = context.presentation
        let submittedDraft = editor.savedDraft
        Task { [weak self, weak presentation] in
            let receipt = await handle.settled.value
            // Accepted writes settle shared drafts even after root disposes the surface.
            if case .success(let result, _) = receipt, let presentation,
               presentation.state.drafts[editor.key]?.eventEditorValue == submittedDraft {
                presentation.clearDraft(editor.key)
                if case .eventSaved(let saved) = result, saved.metadataStatus == .failed {
                    presentation.setDraft(.event(saved.savedEvent.id), value: .eventEditor(EventEditorDraft(event: saved.savedEvent.draft, metadata: submittedDraft.metadata, expectedVersion: saved.savedEvent.version)))
                }
            }
            guard let self, !self.disposed else { return }
            self.busy = false
            switch receipt {
            case .success(.eventSaved(let result), _):
                if result.metadataStatus == .failed {
                    var retry = EventOverlayDraft(record: result.savedEvent, snapshot: self.state.snapshot)
                    retry.restore(EventEditorDraft(event: result.savedEvent.draft, metadata: submittedDraft.metadata, expectedVersion: result.savedEvent.version))
                    retry.metadataRetryID = result.savedEvent.id; self.editor = retry
                    self.saveDraft()
                    self.inlineMessage = self.text("error.partial_eventkit"); self.render()
                } else { self.draftCommitted = true; self.context.presentation.clearDraft(editor.key); self.requestDismiss() }
            case .success: self.draftCommitted = true; self.context.presentation.clearDraft(editor.key); self.requestDismiss()
            case .failure(let failure, _):
                if failure.committed == .unknown { self.unknownOperation = handle.id; self.busy = true }
                self.showFailure(failure)
            }
        }
    }
    func controlTextDidChange(_ notification: Notification) {
        guard let input = notification.object as? NativeTextField, let id = textFields.first(where: { $0.value === input })?.key else { return }
        switch id {
        case "title": editor?.event.title = input.stringValue; saveDraft()
        case "location": editor?.event.location = input.stringValue; saveDraft()
        case "search":
            let native = input.currentEditor() as? NSTextView
            context.presentation.setDraft(.search, value: .text(TextDraft(text: input.stringValue, selection: native?.selectedRange() ?? NSRange(location: 0, length: 0), markedRange: native?.hasMarkedText() == true ? native?.markedRange() : nil)))
            context.presentation.send(.searchQuery(input.stringValue)); searchIndex = 0; render()
        case "citySearch": if !composing { cityPickerExpanded = true; requestCities(input.stringValue) }
        default: break
        }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if textView.hasMarkedText() { return false }
        if selector == #selector(NSResponder.cancelOperation(_:)) { requestDismiss(); return true }
        if selector == #selector(NSResponder.insertTab(_:)) { moveFocus(forward: true); return true }
        if selector == #selector(NSResponder.insertBacktab(_:)) { moveFocus(forward: false); return true }
        if route == .search {
            if selector == #selector(NSResponder.moveDown(_:)) { moveSearch(1); return true }
            if selector == #selector(NSResponder.moveUp(_:)) { moveSearch(-1); return true }
            if selector == #selector(NSResponder.insertNewline(_:)), searchResults.indices.contains(searchIndex) { openSearchResult(searchResults[searchIndex]); return true }
        }
        if selector == #selector(NSResponder.insertNewline(_:)) { save(); return true }
        return false
    }
    func textDidChange(_ notification: Notification) { editor?.event.notes = notes.string; saveDraft(); resumePresentation() }
    func controlTextDidEndEditing(_ notification: Notification) { resumePresentation() }
    private func resumePresentation() { if !composing, let request = deferredPresentation { deferredPresentation = nil; present(request) } }
    func controlTextDidBeginEditing(_ notification: Notification) {
        if let input = notification.object as? NativeTextField, let id = textFields.first(where: { $0.value === input })?.key { context.focus.focus(FocusID("overlay." + id)) }
    }
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        if selector == #selector(NSResponder.cancelOperation(_:)) { requestDismiss(); return true }
        if selector == #selector(NSResponder.insertTab(_:)) { moveFocus(forward: true); return true }
        if selector == #selector(NSResponder.insertBacktab(_:)) { moveFocus(forward: false); return true }
        if selector == #selector(NSResponder.insertNewline(_:)), NSApp.currentEvent?.modifierFlags.contains(.command) == true { save(); return true }
        return false
    }
    private func registerNativeFocus() {
        var targets: [FocusCoordinator.Target] = []
        var ordering: [(CGFloat, FocusID)] = content.items.filter { $0.isInteractive && $0.enabled }.map { ($0.rect.minY, FocusID($0.id)) }
        var native: [(String, NSView)] = textFields.filter { usedFields.contains($0.key) && $0.value.isEnabled }.map { ($0.key, $0.value) }
        native += datePickers.filter { usedDates.contains($0.key) && $0.value.isEnabled }.map { ($0.key, $0.value) }
        if !notesScroll.isHidden, notes.isEditable { native.append(("notes", notes)) }
        for (key, input) in native {
            let id = FocusID("overlay." + key)
            let rect = input === notes ? notesScroll.frame : input.frame
            ordering.append((rect.minY, id))
            var target = FocusCoordinator.Target(id: id, rect: rect, activate: { [weak input] in input?.window?.makeFirstResponder(input) })
            target.reveal = { [weak input] in if let input { input.scrollToVisible(input.bounds) } }
            target.focusChanged = { [weak self, weak input] in
                guard let self, let input, self.context.focus.focusedID == id else { return }
                if let field = input as? NSTextField, field.currentEditor() != nil { return }
                input.window?.makeFirstResponder(input)
            }
            targets.append(target)
        }
        focusOrder = [FocusID("overlay.close")] + ordering.sorted { $0.0 < $1.0 }.map(\.1)
        if surface.items.contains(where: { $0.id == "overlay.cancel" }) { focusOrder.append(FocusID("overlay.cancel")) }
        context.focus.register(owner: self, targets: targets)
    }
    private func moveFocus(forward: Bool) {
        guard !focusOrder.isEmpty else { return }
        let index = context.focus.focusedID.flatMap { focusOrder.firstIndex(of: $0) }
        let next = index.map { $0 + (forward ? 1 : -1) } ?? (forward ? 0 : focusOrder.count - 1)
        guard focusOrder.indices.contains(next) else {
            // Settings remains nonmodal: at its boundary the shared board order takes over.
            context.focus.move(forward: forward); return
        }
        let id = focusOrder[next]
        if content.items.contains(where: { $0.id == id.rawValue }) { host.window?.makeFirstResponder(content) }
        else if surface.items.contains(where: { $0.id == id.rawValue }) { host.window?.makeFirstResponder(surface) }
        context.focus.focus(id)
    }
    @objc private func dateChanged(_ picker: NativeDatePicker) {
        guard editor?.isReadOnly == false else { return }
        if datePickers["start"] === picker { editor?.event.start = picker.dateValue } else { editor?.event.end = picker.dateValue }
        saveDraft()
    }
    private func moveSearch(_ delta: Int) { guard !searchResults.isEmpty else { return }; searchIndex = (searchIndex + delta + searchResults.count) % searchResults.count; render(); if let rect = content.items.first(where: { $0.id == "overlay.result." + searchResults[searchIndex].id })?.rect { content.scrollToVisible(rect) } }
    private func openSearchResult(_ result: OverlaySearchResult) {
        if let day = result.day { context.presentation.send(.selectDay(day)) }
        switch result.target {
        case .event(let id): openEvent(id)
        case .project(let id): context.routing.route(.revealPanel(.projects, .item(id.uuidString.lowercased())))
        }
    }
    private func openEvent(_ id: String) {
        let rect = content.items.first { $0.id == "overlay.result.event." + id || $0.id == "overlay.agenda." + id }?.rect
        let boardRect = rect.map { host.convert($0, from: content) } ?? surface.frame
        context.routing.route(.openEvent(eventID: id, anchor: StableAnchor(target: .event(id), boardRect: boardRect, returnFocusID: returningFocus)))
    }
    private func handleKey(_ event: NSEvent) -> Bool {
        guard !composing else { return false }
        if event.keyCode == 109, event.modifierFlags.contains(.shift), let id = context.focus.focusedID {
            return showSelectionMenu(id.rawValue)
        }
        if event.keyCode == 48 { moveFocus(forward: !event.modifierFlags.contains(.shift)); return true }
        if event.keyCode == 53 { if deleteStage != nil { cancelDelete() } else { requestDismiss() }; return true }
        if event.modifierFlags.contains(.command), event.keyCode == 36 { save(); return true }
        if route == .search {
            if event.keyCode == 125 { moveSearch(1); return true }
            if event.keyCode == 126 { moveSearch(-1); return true }
            if event.keyCode == 36, searchResults.indices.contains(searchIndex) { openSearchResult(searchResults[searchIndex]); return true }
        }
        return false
    }
    func dismiss() {
        guard !composing else { return }
        saveDraft(); closeChoices(restoreFocus: false); host.isHidden = true
    }
    private func requestDismiss() {
        guard !composing else { return }
        saveDraft(); context.routing.route(.dismissOverlay)
    }
    func dispose() {
        guard !disposed else { return }; disposed = true; lifetime.dispose(); host.onLayout = nil
        closeChoices(restoreFocus: false); content.onSelectionMenu = nil
        shadow.dispose()
        context.focus.unregister(owner: self); focusOrder = []; NativeMotion.stop(spinner); spinner.removeFromSuperlayer()
        for input in textFields.values { input.delegate = nil; input.removeFromSuperview() }; textFields = [:]
        for input in datePickers.values { input.target = nil; input.removeFromSuperview() }; datePickers = [:]
        notes.delegate = nil; notes.string = ""; notes.undoManager?.removeAllActions()
        editor = nil; itemActions = [:]; cities = []; searchResults = []
        surface.dispose(); content.dispose(); scroll.dispose(); notesScroll.dispose()
        host.removeFromSuperview()
    }
}
