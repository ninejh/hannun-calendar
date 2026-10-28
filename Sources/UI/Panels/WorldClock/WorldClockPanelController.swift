import AppKit

@MainActor final class WorldClockPanelController: NSObject, NSTextFieldDelegate, PanelController {
    let panelID: PanelID = .worldClock
    private let context: BoardScreenContext
    private let surface: ClockFocusPanelSurface
    let content: ClockFocusCanvas
    private let viewport = OverflowScrollView(frame: .zero)
    private let search: NativeTextField
    private let limitNotice = ClockFocusInlineNoticeView(frame: .zero)
    private let lifetime = ScreenLifetime()
    private var slot: SlotID?
    private var variant: SlotVariant = .tall
    private var placement: PanelPlacement?
    private(set) var timeViews: [String: WorldClockTimeView] = [:]
    private var cities: [String: CatalogCity] = [:]
    private var results: [CatalogCity] = []
    private var searching = false
    private var loading = true
    private var queryGeneration = 0
    private var noticeKey: String?
    private var failedOperation: UUID?
    private var failedCommitted: Commitment = .no
    private var disposed = false
    private var windowObserver: NSObjectProtocol?
    private(set) var renderPassCount = 0
    private(set) var lastTickDirtyIDs: [String] = []
    var view: NSView { surface }
    var isRendering: Bool { !disposed && slot != nil && !surface.isHiddenOrHasHiddenAncestor && (surface.window?.isVisible ?? true) }

    init(context: BoardScreenContext, accessibilityNotifications: any NativeAccessibilityNotifications = SystemNativeAccessibilityNotifications()) {
        self.context = context
        surface = ClockFocusPanelSurface(focus: context.focus); content = ClockFocusCanvas(focus: context.focus, accessibilityNotifications: accessibilityNotifications)
        search = NativeTextField(label: context.text("world_clock.search_city"), identifier: "worldClock.search")
        super.init()
        surface.setAccessibilityIdentifier("panel.worldClock"); surface.setAccessibilityLabel(context.text("world_clock.title"))
        viewport.documentView = content; surface.addSubview(viewport); content.addSubview(search); content.addSubview(limitNotice)
        context.bindPanelMenus(to: surface)
        limitNotice.identifier = NSUserInterfaceItemIdentifier("worldClock.limitFeedback")
        search.isHidden = true; search.delegate = self
        surface.onLayout = { [weak self] in self?.render() }; surface.onVisibility = { [weak self] in self?.visibilityChanged() }
        surface.onAction = { [weak self] id in if id == "worldClock.add" { self?.openSearch() } }
        content.onAction = { [weak self] id in self?.activate(id) }
        content.onShortcut = { [weak self] event in
            guard event.keyCode == 53, self?.searching == true else { return false }; self?.closeSearch(); return true
        }
        windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.visibilityChanged() }
        }
        lifetime.own(context.presentation.subscribe { [weak self] change in
            guard let self, self.isRendering else { return }
            if change.domains == [.clock] { self.render(tick: true) }
            else if !change.domains.isDisjoint(with: [.board, .environment, .activity, .error, .pending]) { self.render() }
        })
        loadCities(query: "")
    }
    func setPlacement(slot: SlotID?, variant: SlotVariant) {
        placement = nil
        self.slot = slot; self.variant = variant; surface.isHidden = slot == nil
        if slot == nil { closeSearch() } else { render() }
    }
    func setPlacement(_ placement: PanelPlacement) {
        self.placement = placement; slot = placement.slot; variant = placement.shape == .wide ? .wide : .tall
        surface.isHidden = slot == nil
        if slot == nil { closeSearch() } else { render() }
    }
    func reveal(_ target: PanelReveal) {
        render()
        let id: String
        switch target {
        case .day: content.scroll(.zero); return
        case .item(let value): id = value.hasPrefix("worldClock.") ? value : "worldClock.delete.\(value)"
        case .scrollTo(let focusID): id = focusID.rawValue
        }
        if let item = content.items.first(where: { $0.id == id }) {
            content.scrollToVisible(item.rect); context.focus.focus(FocusID(id))
        }
    }
    private func visibilityChanged() {
        if isRendering { render() } else if let layer = limitNotice.layer { NativeMotion.stop(layer) }
    }
    private func showLimit() {
        noticeKey = "world_clock.max_limit_inline"; searching = false; search.isHidden = true; render()
        viewport.contentView.scroll(to: .zero); viewport.reflectScrolledClipView(viewport.contentView); viewport.updateFade()
        if let layer = limitNotice.layer { NativeMotion.apply(.shake, to: layer, reduceMotion: context.presentation.state.snapshot.environment.reduceMotion) }
    }
    func openSearch() {
        guard context.presentation.state.snapshot.board.worldClockCities.count < 4 else {
            showLimit(); return
        }
        searching = true; noticeKey = nil; search.isHidden = false; render(); search.selectText(nil)
        loadCities(query: search.stringValue)
    }
    private func closeSearch() {
        searching = false; search.isHidden = true
        surface.window?.makeFirstResponder(surface); render(); context.focus.focus(FocusID("worldClock.add"))
    }
    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSTextField === search,
              (search.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        loadCities(query: search.stringValue)
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { closeSearch(); return true }; return false
    }
    private func loadCities(query: String) {
        queryGeneration += 1; let generation = queryGeneration; loading = true
        guard let handle = context.presentation.send(.command(.listCities(query: String(query.prefix(100))))) else { loading = false; return }
        Task { [weak self] in
            let receipt = await handle.settled.value
            guard let self, !self.disposed, self.queryGeneration == generation else { return }
            self.loading = false
            switch receipt {
            case .success(.cities(let values), _):
                for city in values { self.cities[city.id] = city }; self.results = values; self.noticeKey = nil
            case .failure(let error, _): self.noticeKey = error.messageKey
            default: self.noticeKey = "error.generic"
            }
            self.render()
        }
    }
    func addCity(_ id: String) {
        let selected = context.presentation.state.snapshot.board.worldClockCities
        guard !selected.contains(where: { $0.id == id }) else { return }
        guard selected.count < 4 else { showLimit(); return }
        guard cities[id] != nil else { noticeKey = "world_clock.search_no_results"; render(); return }
        searching = false; search.isHidden = true
        watch(context.presentation.send(.edit(.panel(.addCity(id)), undoable: true)))
    }
    func deleteCity(_ id: String) { watch(context.presentation.send(.edit(.panel(.deleteCity(id)), undoable: true))) }
    private func activate(_ id: String) {
        if id.hasPrefix("worldClock.delete.") { deleteCity(String(id.dropFirst("worldClock.delete.".count))) }
        else if id.hasPrefix("worldClock.result.") { addCity(String(id.dropFirst("worldClock.result.".count))) }
        else if id == "worldClock.retry" {
            if let failedOperation { watch(context.presentation.send(failedCommitted == .unknown ? .reconcile(failedOperation) : .retry(failedOperation))) }
            else { loadCities(query: searching ? search.stringValue : "") }
        } else if id == "worldClock.close" { closeSearch() }
    }
    private func watch(_ handle: OperationHandle?) {
        guard let handle else { return }
        Task { [weak self] in
            let receipt = await handle.settled.value
            guard let self, !self.disposed else { return }
            if case .failure(let error, _) = receipt {
                self.noticeKey = error.messageKey; self.failedOperation = handle.id; self.failedCommitted = error.committed
            } else { self.noticeKey = nil; self.failedOperation = nil }
            self.render()
        }
    }
    private func offsetText(_ minutes: Int) -> String {
        if minutes == 0 { return context.text("world_clock.same_time") }
        let format = NumberFormatter(); format.locale = Locale(identifier: context.presentation.state.snapshot.environment.localeIdentifier)
        format.maximumFractionDigits = 2
        let hours = format.string(from: NSNumber(value: Double(abs(minutes)) / 60)) ?? String(Double(abs(minutes)) / 60)
        return context.text(minutes > 0 ? "world_clock.ahead" : "world_clock.behind", values: ["0": hours])
    }
    private func render(tick: Bool = false) {
        guard isRendering else { return }
        let state = context.presentation.state, snapshot = state.snapshot
        let metrics = placement.map { NativePanelStepMetrics(panel: panelID, shape: $0.shape, step: $0.heightStep) }
        let compact = placement?.heightStep == .tiny || placement?.heightStep == .small
        let inset = compact ? metrics!.horizontalPadding : NativeSpace.lg
        let width = max(NativeSize.compactTarget, surface.bounds.width - inset * 2)
        let headerHeight = NativeSize.toolbarHeight
        if surface.theme.appearance != snapshot.environment.resolvedAppearance { surface.theme = NativeTheme(appearance: snapshot.environment.resolvedAppearance); content.theme = surface.theme }
        let appearanceName: NSAppearance.Name = snapshot.environment.resolvedAppearance == .light ? .aqua : .darkAqua
        if surface.appearance?.name != appearanceName { surface.appearance = NSAppearance(named: appearanceName) }
        surface.reduceMotion = snapshot.environment.reduceMotion; content.reduceMotion = snapshot.environment.reduceMotion
        surface.setAccessibilityLabel(context.text("world_clock.title"))
        if !tick {
            let addLabel = context.text("world_clock.add_city")
            let addWidth = min(width / 2, max(NativeSize.compactTarget, ceil((addLabel as NSString).size(withAttributes: [.font: NativeFont.primary]).width) + NativeSpace.sm * 2))
            let headerY: CGFloat = compact ? 0 : inset
            let titleHeight = compact ? metrics!.headerHeight : headerHeight
            let addHeight = compact ? NativeSize.compactTarget : headerHeight
            let actualHeader = compact ? max(titleHeight, addHeight) : inset + headerHeight + NativeSpace.sm
            let addRect = CGRect(x: inset + width - addWidth, y: headerY, width: addWidth, height: addHeight)
            var title = NativeRenderItem(id: "worldClock.title", rect: CGRect(x: inset, y: headerY, width: max(0, width - addWidth - NativeSpace.sm), height: titleHeight), label: context.text("world_clock.title"), kind: .text)
            if let slot { title = NativePanelHeader.decorate(title, geometry: PanelHeaderGeometry(slot: slot, titleRect: title.rect,
                headerRect: CGRect(x: 0, y: 0, width: surface.bounds.width, height: actualHeader), excludedRects: [addRect])) }
            surface.update(items: [title, NativeRenderItem(id: "worldClock.add", rect: addRect, label: addLabel, kind: .button)])
            viewport.frame = CGRect(x: inset, y: actualHeader, width: width, height: max(0, surface.bounds.height - actualHeader - (compact ? metrics!.bottomPadding : inset)))
        }
        var items: [NativeRenderItem] = []; var y: CGFloat = 0
        content.fonts.removeAll(keepingCapacity: true); content.visibleLabels.removeAll(keepingCapacity: true); content.dayNight.removeAll(keepingCapacity: true)
        func text(_ id: String, _ value: String, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, font: NSFont, color: NativeColorToken = .textPrimary) {
            items.append(NativeRenderItem(id: id, rect: CGRect(x: x, y: y, width: max(0, width), height: height), label: value, kind: .text, color: color)); content.fonts[id] = font
        }
        let showingLimit = noticeKey == "world_clock.max_limit_inline"
        if !tick { limitNotice.isHidden = !showingLimit }
        if showingLimit {
            text("worldClock.notice", context.text("world_clock.max_limit_inline"), x: 0, y: 0, width: width, height: headerHeight * 2, font: NativeFont.primary, color: .danger)
            content.visibleLabels["worldClock.notice"] = ""
            if !tick {
                limitNotice.frame = CGRect(x: 0, y: 0, width: width, height: headerHeight * 2)
                limitNotice.theme = content.theme; limitNotice.text = context.text("world_clock.max_limit_inline"); limitNotice.needsDisplay = true
            }
            y += headerHeight * 2 + NativeSpace.sm
        }
        if searching {
            search.placeholderString = context.text("world_clock.search_city"); search.setAccessibilityLabel(context.text("world_clock.search_city"))
            search.frame = CGRect(x: 0, y: 0, width: max(0, width - NativeSize.compactTarget - NativeSpace.sm), height: NativeSize.toolbarHeight)
            items.append(NativeRenderItem(id: "worldClock.close", rect: CGRect(x: width - NativeSize.compactTarget, y: 0, width: NativeSize.compactTarget, height: NativeSize.compactTarget), label: context.text("a11y.close"), kind: .button))
            content.visibleLabels["worldClock.close"] = "×"; y += NativeSize.toolbarHeight + NativeSpace.sm
            let selected = Set(snapshot.board.worldClockCities.map(\.id))
            for city in results {
                items.append(NativeRenderItem(id: "worldClock.result.\(city.id)", rect: CGRect(x: 0, y: y, width: width, height: NativeSize.toolbarHeight), label: snapshot.board.settings.language == .ko ? city.nameKO : city.nameEN, kind: .button, enabled: !selected.contains(city.id)))
                y += NativeSize.toolbarHeight + NativeSpace.xs
            }
            if results.isEmpty && !loading { text("worldClock.noResults", context.text("world_clock.search_no_results"), x: 0, y: y, width: width, height: headerHeight, font: NativeFont.primary); y += headerHeight }
        } else {
            let columns = metrics?.columnCapacity(in: surface.bounds.width) ?? (variant == .wide ? max(1, min(4, Int((width + NativeSpace.md) / (NativeSize.projectMinWidth / 2 + NativeSpace.md)))) : 1)
            let cardWidth = max(0, (width - CGFloat(columns - 1) * NativeSpace.md) / CGFloat(columns))
            let cardHeight = metrics?.listRow?.height ?? (compact ? (placement?.heightStep == .tiny ? NativeSize.compactTarget * 2 + NativeSpace.md : NativeSize.toolbarHeight * 2 + NativeSpace.lg) : NativeSize.toolbarHeight * 3)
            let cardGap = metrics?.listRow?.gap ?? NativeSpace.sm
            let cardsStart = y
            for (index, entry) in snapshot.board.worldClockCities.enumerated() {
                let x = CGFloat(index % columns) * (cardWidth + NativeSpace.md), top = cardsStart + CGFloat(index / columns) * (cardHeight + cardGap)
                let name = cities[entry.id].map { snapshot.board.settings.language == .ko ? $0.nameKO : $0.nameEN } ?? entry.id
                items.append(NativeRenderItem(id: "worldClock.card.\(entry.id)", rect: CGRect(x: x, y: top, width: cardWidth, height: cardHeight), label: name, kind: .group, fill: .raised, radius: NativeRadius.input))
                content.fonts["worldClock.card.\(entry.id)"] = NativeFont.body; content.visibleLabels["worldClock.card.\(entry.id)"] = ""
                let rail = placement?.shape == .rail
                let timeWidth = ceil(("88:88:88" as NSString).size(withAttributes: [.font: metrics?.numericFont ?? NativeFont.countdown]).width) + NativeSpace.sm * 2
                let tinyWide = placement?.shape == .wide && placement?.heightStep == .tiny
                let nameHeight = rail ? min(NativeSize.toolbarHeight + NativeSpace.xxs, cardHeight - NativeSpace.xl) : (tinyWide ? NativeSpace.xl : compact ? NativeSize.compactTarget : headerHeight)
                text("worldClock.name.\(entry.id)", name, x: x, y: top,
                     width: max(0, cardWidth - NativeSize.compactTarget - (rail ? timeWidth : 0)), height: nameHeight,
                     font: metrics?.bodyFont ?? NativeFont.bodyStrong)
                let deleteID = "worldClock.delete.\(entry.id)"
                items.append(NativeRenderItem(id: deleteID, rect: CGRect(x: x + cardWidth - NativeSize.compactTarget, y: top, width: NativeSize.compactTarget, height: NativeSize.compactTarget), label: context.text("item.delete_label", values: ["0": name]), kind: .button, color: .textQuiet))
                content.visibleLabels[deleteID] = "×"
                if let city = cities[entry.id], let reading = WorldClockReading(city: city, now: snapshot.clock.now, macTimeZone: snapshot.clock.timeZone) {
                    let metaY = rail ? top + nameHeight : top + nameHeight
                    let metaHeight = rail ? cardHeight - nameHeight : tinyWide ? NativeSpace.lg + NativeSpace.xs : NativeSize.compactTarget
                    let timeY = rail ? top : metaY + metaHeight
                    text("worldClock.meta.\(entry.id)", context.text(reading.isDay ? "world_clock.day" : "world_clock.night") + " · " + offsetText(reading.offsetMinutes), x: x, y: metaY, width: cardWidth, height: metaHeight, font: NativeFont.toolbar, color: .textSecondary)
                    content.dayNight["worldClock.meta.\(entry.id)"] = reading.isDay
                    text("worldClock.time.\(entry.id)", reading.timeText, x: rail ? x + cardWidth - NativeSize.compactTarget - timeWidth : x,
                         y: timeY, width: rail ? timeWidth : cardWidth, height: rail ? nameHeight : (compact ? cardHeight - nameHeight - metaHeight : headerHeight), font: metrics?.numericFont ?? NativeFont.countdown)
                }
                y = max(y, top + cardHeight + cardGap)
            }
            if snapshot.board.worldClockCities.isEmpty && !loading { text("worldClock.empty", context.text("world_clock.empty"), x: 0, y: y, width: width, height: headerHeight * 2, font: NativeFont.primary, color: .textSecondary); y += headerHeight * 2 }
        }
        if loading { text("worldClock.loading", context.text("loading.label"), x: 0, y: y, width: width, height: headerHeight, font: NativeFont.primary, color: .textQuiet); y += headerHeight }
        if let noticeKey, !showingLimit {
            text("worldClock.notice", context.text(noticeKey), x: 0, y: y, width: width, height: headerHeight * 2, font: NativeFont.primary, color: .danger); y += headerHeight * 2
            if noticeKey != "world_clock.max_limit_inline" {
                items.append(NativeRenderItem(id: "worldClock.retry", rect: CGRect(x: 0, y: y, width: width, height: headerHeight), label: context.text("error.retry_action"), kind: .button)); y += headerHeight
            }
        }
        let changed = items.filter { !content.items.contains($0) }.map(\.id)
        if tick { lastTickDirtyIDs = changed }
        if !tick { content.frame = CGRect(x: 0, y: 0, width: width, height: max(viewport.contentSize.height, y)); viewport.updateFade() }
        let itemsChanged = items != content.items
        let live = items.filter { $0.id.hasPrefix("worldClock.time.") }
        content.excludedPaintIDs = Set(live.map(\.id))
        for id in Array(timeViews.keys) where !content.excludedPaintIDs.contains(id) { timeViews.removeValue(forKey: id)?.removeFromSuperview() }
        for item in live {
            let font = content.fonts[item.id] ?? NativeFont.clockTime
            let child: WorldClockTimeView
            if let existing = timeViews[item.id] { child = existing }
            else { child = WorldClockTimeView(frame: .zero); child.identifier = NSUserInterfaceItemIdentifier("worldClock.timeVisual.\(item.id)"); timeViews[item.id] = child; content.addSubview(child) }
            let textWidth = ceil(("88:88:88" as NSString).size(withAttributes: [.font: font]).width) + NativeSpace.sm * 2
            let frame = CGRect(x: item.rect.minX, y: item.rect.minY, width: min(item.rect.width, textWidth), height: item.rect.height)
            if child.frame != frame { child.frame = frame }
            child.update(text: item.label, font: font, color: content.theme.color(item.color))
        }
        content.update(items: items, announceLayout: !tick, invalidatingDisplay: !tick)
        if tick { for item in items where changed.contains(item.id) && !content.excludedPaintIDs.contains(item.id) { content.setNeedsDisplay(item.rect) } }
        if itemsChanged { renderPassCount += 1 }
    }
    func dispose() {
        guard !disposed else { return }; disposed = true; lifetime.dispose()
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }; windowObserver = nil
        search.delegate = nil; surface.dispose(); content.dispose(); viewport.dispose()
        for child in timeViews.values { child.removeFromSuperview() }; timeViews.removeAll()
        if let layer = limitNotice.layer { NativeMotion.stop(layer) }; limitNotice.removeFromSuperview()
    }
}
