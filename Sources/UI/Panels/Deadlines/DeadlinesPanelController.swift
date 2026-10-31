import AppKit

private enum DeadlineStepLayout {
    static let tinyCardHeight: CGFloat = 58
    static let smallCardHeight: CGFloat = 76
}

@MainActor final class DeadlinesPanelController: PanelController {
    let panelID: PanelID = .deadlines
    var view: NSView { surface }
    let context: BoardScreenContext
    let surface: ManagementPanelView
    let content: ManagementCanvas
    let scroll = OverflowScrollView(frame: .zero)
    private let lifetime = ScreenLifetime()
    private var retainedMenu: NativeMenu?
    private(set) var variant: SlotVariant = .tall
    private(set) var heightStep: PanelSizeStep = .regular
    private var placement: PanelPlacement?
    private var scrollOrigins: [String: CGPoint] = [:]
    private(set) var pastExpanded = false
    private(set) var editor: ProjectDeadlineEditor?
    private(set) var inlineError: AppFailure?
    private var failedID: UUID?
    private var rows: [DeadlineRow] = []
    private var lastToday: DateOnly?
    private var rendering = false
    private var disposed = false
    init(context: BoardScreenContext) {
        self.context = context; surface = ManagementPanelView(focus: context.focus); content = ManagementCanvas(focus: context.focus)
        surface.setAccessibilityIdentifier("panel.deadlines"); surface.setAccessibilityLabel(context.text("deadlines.title"))
        content.setAccessibilityIdentifier("deadlines.list")
        scroll.documentView = content; surface.addSubview(scroll)
        surface.onLayout = { [weak self] in self?.render() }
        surface.onAction = { [weak self] in self?.act($0) }
        content.onAction = { [weak self] in self?.act($0) }
        context.bindPanelMenus(to: surface)
        content.contextMenu = { [weak self] action in self?.menu(for: String(action.dropFirst("deadline.".count))) }
        lifetime.own(context.presentation.subscribe { [weak self] change in
            guard let self else { return }
            guard !change.domains.isDisjoint(with: [.board, .calendar, .clock, .environment, .activity, .pending, .error]) else { return }
            if change.domains == [.clock], self.surface.isHidden || self.lastToday == self.context.presentation.state.snapshot.clock.today { return }
            if change.domains.contains(.environment) { self.editor?.refreshEnvironment() }
            self.render()
        })
    }
    func setPlacement(slot: SlotID?, variant: SlotVariant) {
        setPlacement(PanelPlacement(slot: slot, shape: variant == .wide ? .wide : .rail, heightStep: .regular, railWidthStep: .regular, frame: surface.frame, headerRect: .zero, contentRect: .zero))
    }
    func setPlacement(_ placement: PanelPlacement) {
        guard self.placement != placement else { return }
        let nextDeck = placement.shape == .wide && (placement.heightStep == .tiny || placement.heightStep == .small)
        let previousDeck = variant == .wide && (heightStep == .tiny || heightStep == .small)
        if nextDeck != previousDeck { scrollOrigins[previousDeck ? "deck" : "list"] = scroll.contentView.bounds.origin }
        self.placement = placement; heightStep = placement.heightStep
        surface.isHidden = placement.slot == nil
        variant = placement.shape == .wide ? .wide : .tall
        render()
        if nextDeck != previousDeck {
            let saved = scrollOrigins[nextDeck ? "deck" : "list"] ?? .zero
            let origin = CGPoint(x: min(max(0, saved.x), max(0, content.bounds.width - scroll.contentSize.width)), y: min(max(0, saved.y), max(0, content.bounds.height - scroll.contentSize.height)))
            scroll.contentView.scroll(to: origin); scroll.reflectScrolledClipView(scroll.contentView); scroll.updateFade()
        }
    }
    func reveal(_ target: PanelReveal) {
        let requested: String
        switch target {
        case .scrollTo(let focus): requested = focus.rawValue
        case .item(let value): requested = value.lowercased()
        case .day(let day):
            guard let row = rows.first(where: { $0.day == day }) else { return }; reveal(.item(row.id)); return
        }
        if let row = rows.first(where: { $0.id == requested || $0.id.hasSuffix("." + requested) }),
           case .countdown = row.source, row.day < context.presentation.state.snapshot.clock.today, !pastExpanded {
            pastExpanded = true; render()
        }
        if let item = content.items.first(where: { $0.isInteractive && ($0.id == requested || $0.id == "deadline." + requested || $0.id.hasSuffix("." + requested)) }) {
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
    func setVariant(_ variant: SlotVariant) { guard self.variant != variant else { return }; self.variant = variant; render() }
    private func render() {
        // Parking keeps model subscriptions and admitted write settlement alive. Rebuild
        // paint/layout from the latest state only when setPlacement makes us visible again.
        guard !disposed, !rendering, !surface.isHidden else { return }; rendering = true; defer { rendering = false }
        let state = context.presentation.state, snapshot = state.snapshot
        lastToday = snapshot.clock.today
        if surface.theme.appearance != snapshot.environment.resolvedAppearance { surface.theme = NativeTheme(appearance: snapshot.environment.resolvedAppearance); content.theme = surface.theme }
        if surface.reduceMotion != snapshot.environment.reduceMotion { surface.reduceMotion = snapshot.environment.reduceMotion; surface.needsDisplay = true }
        if content.reduceMotion != snapshot.environment.reduceMotion { content.reduceMotion = snapshot.environment.reduceMotion; content.needsDisplay = true }
        surface.setAccessibilityLabel(context.text("deadlines.title"))
        let metrics = NativePanelStepMetrics(panel: .deadlines, shape: variant == .wide ? .wide : .rail, step: heightStep)
        let condensed = heightStep == .tiny || heightStep == .small
        let header = condensed ? metrics.headerHeight : NativeSize.compactTarget + NativeSpace.md, width = max(0, surface.bounds.width)
        let groups = DeadlineRows.group(snapshot); rows = groups.active + groups.past
        let addWidth = NativeSize.compactTarget, filterWidth = min(NativeSize.compactTarget * 6, max(NativeSize.compactTarget * 3, width / 2))
        surface.displayLabels = ["deadlines.add": "+"]
        var headerItems = [
            NativeRenderItem(id: "deadlines.heading", rect: CGRect(x: NativeSpace.sm, y: NativeSpace.xs, width: max(0, width - filterWidth - addWidth - NativeSpace.lg), height: NativeSize.compactTarget), label: context.text("deadlines.title") + "  " + String(rows.count), kind: .text, value: String(rows.count)),
            NativeRenderItem(id: "deadlines.filter", rect: CGRect(x: max(0, width - filterWidth - addWidth - NativeSpace.sm), y: NativeSpace.xs, width: filterWidth, height: NativeSize.compactTarget), label: context.text(snapshot.board.settings.importantOnly ? "deadlines.filter_pinned" : "deadlines.filter_all"), kind: .button, value: context.text("deadlines.filter_label")),
            NativeRenderItem(id: "deadlines.add", rect: CGRect(x: max(0, width - addWidth - NativeSpace.xs), y: NativeSpace.xs, width: addWidth, height: NativeSize.compactTarget), label: context.text("deadlines.add_dday"), kind: .button)]
        if condensed {
            for index in headerItems.indices {
                headerItems[index].rect.origin.y = max(0, (header - NativeSize.compactTarget) / 2)
                headerItems[index].rect.size.height = min(NativeSize.compactTarget, header)
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
        let padding = condensed ? metrics.horizontalPadding : NativeSpace.xs
        let contentTop = max(header, (placement?.editLeading ?? 0) > 0 ? 32 : 0)
        let contentBottom = max(placement?.editBottom ?? 0, condensed ? metrics.bottomPadding : NativeSpace.sm)
        scroll.frame = CGRect(x: padding, y: contentTop, width: max(0, width - padding * 2), height: max(0, surface.bounds.height - contentTop - contentBottom))
        if heightStep == .tiny && variant == .tall { scroll.frame.size.height = min(scroll.frame.height, metrics.listRow!.height + (inlineError == nil ? 0 : NativeSize.compactTarget)) }
        let viewport = scroll.contentSize, inset = condensed ? 0 : NativeSpace.sm
        scroll.axis = variant == .wide && condensed ? .horizontal : .vertical
        if variant == .wide && condensed { renderDeck(groups: groups, viewport: viewport, metrics: metrics); return }
        let compact = condensed || snapshot.board.settings.compact
        let rowHeight = condensed ? metrics.listRow!.height : compact ? NativeSize.compactTarget + NativeSpace.xs : NativeSize.compactTarget * 2
        let columnWidth = max(0, (viewport.width - inset * (variant == .wide ? 3 : 2)) / (variant == .wide ? 2 : 1))
        var items: [NativeRenderItem] = []; content.styles = [:]; content.displayLabels = [:]
        func append(_ item: NativeRenderItem, _ style: ManagementCanvas.Style? = nil) { items.append(item); content.styles[item.id] = style }
        var leftY = inset, rightY = inset
        if inlineError != nil { leftY += NativeSize.compactTarget; rightY += NativeSize.compactTarget }
        for row in groups.active {
            let personal: Bool; if case .countdown = row.source { personal = true } else { personal = false }
            let right = variant == .wide && personal
            let x = right ? columnWidth + inset * 2 : inset, y = right ? rightY : leftY
            render(row, rect: CGRect(x: x, y: y, width: columnWidth, height: rowHeight), compact: compact, append: append)
            if right { rightY += rowHeight } else { leftY += rowHeight }
        }
        if !groups.past.isEmpty {
            let right = variant == .wide, x = right ? columnWidth + inset * 2 : inset, y = right ? rightY : leftY
            content.displayLabels["deadlines.past"] = (pastExpanded ? "▾ " : "▸ ") + context.text("deadlines.past_group", values: ["0": String(groups.past.count)])
            content.styles["deadlines.past"] = .plain
            append(NativeRenderItem(id: "deadlines.past", rect: CGRect(x: x, y: y, width: columnWidth, height: NativeSize.compactTarget), label: context.text("deadlines.past_group", values: ["0": String(groups.past.count)]), kind: .button, value: pastExpanded ? "1" : "0", checked: pastExpanded, color: .textSecondary), .plain)
            var pastY = y + NativeSize.compactTarget
            if pastExpanded {
                for row in groups.past { render(row, rect: CGRect(x: x, y: pastY, width: columnWidth, height: rowHeight), compact: compact, append: append); pastY += rowHeight }
            }
            if right { rightY = pastY } else { leftY = pastY }
        }
        if rows.isEmpty { append(NativeRenderItem(id: "deadlines.empty", rect: CGRect(x: inset, y: inset, width: max(0, viewport.width - inset * 2), height: NativeSize.compactTarget * 2), label: context.text(state.activity.loading ? "loading.label" : "deadlines.empty"), kind: .text, color: .textSecondary), .message) }
        if let error = inlineError { append(NativeRenderItem(id: "deadlines.error", rect: CGRect(x: inset, y: 0, width: max(0, viewport.width - inset * 2), height: NativeSize.compactTarget), label: context.text(error.messageKey), kind: .button, color: .danger)) }
        content.frame.size = CGSize(width: viewport.width, height: max(viewport.height, max(leftY, rightY) + inset))
        content.update(items: items); scroll.updateFade()
    }
    private func render(_ row: DeadlineRow, rect: CGRect, compact: Bool, append: (NativeRenderItem, ManagementCanvas.Style?) -> Void) {
        let prefix = "deadline." + row.id, menuWidth = NativeSize.compactTarget
        let badgeText = DeadlineRows.badge(day: row.day, today: context.presentation.state.snapshot.clock.today, context: context)
        let badgeWidth = heightStep == .tiny || heightStep == .small ? max(NativeSize.compactTarget * 3, (badgeText as NSString).size(withAttributes: [.font: NativeFont.countdown]).width + NativeSpace.lg) : NativeSize.compactTarget * 3
        let titleWidth = max(0, rect.width - badgeWidth - menuWidth)
        let date = ManagementCopy.date(row.day, context: context)
        let origin = row.originKey.map { context.text($0) } ?? row.origin
        append(NativeRenderItem(id: prefix, rect: CGRect(x: rect.minX, y: rect.minY, width: titleWidth, height: rect.height), label: row.title, kind: .button, value: date + (origin.isEmpty ? "" : " · " + origin)), .hitSurface)
        if heightStep == .tiny {
            append(NativeRenderItem(id: prefix + ".compact.title", rect: CGRect(x: rect.minX, y: rect.minY, width: titleWidth, height: rect.height), label: row.title, kind: .text), .deadlineTitle)
        } else if compact {
            // Keep date untruncated in a reserved cell; title yields first.
            let dateWidth = min(titleWidth, NativeSize.compactTarget * 2.5)
            append(NativeRenderItem(id: prefix + ".compact.title", rect: CGRect(x: rect.minX, y: rect.minY, width: max(0, titleWidth - dateWidth), height: rect.height), label: row.title, kind: .text), heightStep == .small ? .deadlineTitle : .plain)
            append(NativeRenderItem(id: prefix + ".date", rect: CGRect(x: rect.minX + max(0, titleWidth - dateWidth), y: rect.minY, width: dateWidth, height: rect.height), label: date, kind: .text, color: .textSecondary), heightStep == .small ? .metadata : .secondary)
        } else {
            // Overlay custom text on the shared action enclosure; its full AX name remains the title.
            append(NativeRenderItem(id: prefix + ".title", rect: CGRect(x: rect.minX, y: rect.minY, width: titleWidth, height: NativeSize.compactTarget), label: row.title, kind: .text), .plain)
            append(NativeRenderItem(id: prefix + ".date", rect: CGRect(x: rect.minX, y: rect.minY + NativeSize.compactTarget, width: titleWidth, height: NativeSize.compactTarget), label: date + (origin.isEmpty ? "" : " · " + origin), kind: .text, color: .textSecondary), .secondary)
        }
        append(NativeRenderItem(id: prefix + ".badge", rect: CGRect(x: rect.maxX - badgeWidth - menuWidth, y: rect.minY, width: badgeWidth, height: rect.height), label: badgeText, kind: .badge, color: row.day < context.presentation.state.snapshot.clock.today ? .danger : .textPrimary), .countdown)
        if case .countdown = row.source { append(NativeRenderItem(id: prefix + ".menu", rect: CGRect(x: rect.maxX - menuWidth, y: rect.midY - NativeSize.compactTarget / 2, width: menuWidth, height: NativeSize.compactTarget), label: context.text("a11y.item_options", values: ["0": row.title]), kind: .button), .plain); content.displayLabels[prefix + ".menu"] = "···" }
    }
    private func renderDeck(groups: (active: [DeadlineRow], past: [DeadlineRow]), viewport: CGSize, metrics: NativePanelStepMetrics) {
        let cardWidth = metrics.minimumCardWidth!, gap = metrics.cardGap
        let height = heightStep == .tiny ? DeadlineStepLayout.tinyCardHeight : DeadlineStepLayout.smallCardHeight
        var items: [NativeRenderItem] = []; content.styles = [:]; content.displayLabels = [:]
        func append(_ item: NativeRenderItem, _ style: ManagementCanvas.Style) { items.append(item); content.styles[item.id] = style }
        var index = 0
        let top = inlineError == nil ? 0 : NativeSize.compactTarget
        func card(_ row: DeadlineRow) {
            let base = "deadline." + row.id, x = CGFloat(index) * (cardWidth + gap)
            let rect = CGRect(x: x, y: top, width: cardWidth, height: height)
            append(NativeRenderItem(id: base + ".card", rect: rect, label: row.title, kind: .group), .card)
            let date = ManagementCopy.date(row.day, context: context), origin = row.originKey.map { context.text($0) } ?? row.origin
            let personal: Bool; if case .countdown = row.source { personal = true } else { personal = false }
            append(NativeRenderItem(id: base, rect: CGRect(x: x, y: top, width: cardWidth - (personal ? NativeSize.compactTarget : 0), height: NativeSize.compactTarget), label: row.title, kind: .button, value: date + (origin.isEmpty ? "" : " · " + origin)), .deadlineTitle)
            append(NativeRenderItem(id: base + ".badge", rect: CGRect(x: x, y: top + NativeSize.compactTarget, width: cardWidth, height: heightStep == .small ? NativeSize.compactTarget : height - NativeSize.compactTarget), label: DeadlineRows.badge(day: row.day, today: context.presentation.state.snapshot.clock.today, context: context), kind: .badge, color: row.day < context.presentation.state.snapshot.clock.today ? .danger : .textPrimary), .countdown)
            if heightStep == .small { append(NativeRenderItem(id: base + ".date", rect: CGRect(x: x, y: top + NativeSize.compactTarget * 2, width: cardWidth, height: height - NativeSize.compactTarget * 2), label: date, kind: .text, color: .textSecondary), .metadata) }
            if personal {
                append(NativeRenderItem(id: base + ".menu", rect: CGRect(x: rect.maxX - NativeSize.compactTarget, y: top, width: NativeSize.compactTarget, height: NativeSize.compactTarget), label: context.text("a11y.item_options", values: ["0": row.title]), kind: .button), .plain)
                content.displayLabels[base + ".menu"] = "···"
            }
            index += 1
        }
        for row in groups.active { card(row) }
        if !groups.past.isEmpty {
            let label = context.text("deadlines.past_group", values: ["0": String(groups.past.count)])
            append(NativeRenderItem(id: "deadlines.past", rect: CGRect(x: CGFloat(index) * (cardWidth + gap), y: top, width: cardWidth, height: NativeSize.compactTarget), label: label, kind: .button, value: pastExpanded ? "1" : "0", checked: pastExpanded, color: .textSecondary), .plain)
            content.displayLabels["deadlines.past"] = (pastExpanded ? "▾ " : "▸ ") + label; index += 1
            if pastExpanded { for row in groups.past { card(row) } }
        }
        if rows.isEmpty { append(NativeRenderItem(id: "deadlines.empty", rect: CGRect(x: 0, y: 0, width: viewport.width, height: max(height, viewport.height)), label: context.text(context.presentation.state.activity.loading ? "loading.label" : "deadlines.empty"), kind: .text, color: .textSecondary), .message) }
        if let error = inlineError { append(NativeRenderItem(id: "deadlines.error", rect: CGRect(x: 0, y: 0, width: viewport.width, height: NativeSize.compactTarget), label: context.text(error.messageKey), kind: .button, color: .danger), .plain) }
        content.frame.size = CGSize(width: max(viewport.width, CGFloat(index) * (cardWidth + gap) - gap), height: max(viewport.height, top + height))
        content.update(items: items); scroll.updateFade()
    }
    private func act(_ action: String) {
        switch action {
        case "deadlines.add": openEditor(item: nil)
        case "deadlines.past": pastExpanded.toggle(); render(); ManagementCanvas.disclose(in: scroll, reduceMotion: context.presentation.state.snapshot.environment.reduceMotion)
        case "deadlines.filter":
            retainedMenu?.dispose()
            let important = context.presentation.state.snapshot.board.settings.importantOnly
            let menu = NativeMenu(items: [NativeMenuEntry(id: "pinned", title: context.text("deadlines.filter_pinned"), checked: important), NativeMenuEntry(id: "all", title: context.text("deadlines.filter_all"), checked: !important)]) { [weak self] value in
                guard let self else { return }; var patch = SettingsPatch(); patch.importantOnly = .set(value == "pinned"); _ = self.save(.settings(patch), undoable: false)
            }
            retainedMenu = menu
            if let rect = surface.items.first(where: { $0.id == action })?.rect, surface.window != nil { menu.menu.popUp(positioning: nil, at: CGPoint(x: rect.minX, y: rect.maxY), in: surface) }
        case "deadlines.error": if let failedID { _ = context.presentation.send(inlineError?.committed == .unknown ? .reconcile(failedID) : .retry(failedID)) }
        default:
            guard let row = rows.first(where: { action == "deadline." + $0.id || action == "deadline." + $0.id + ".menu" }) else { return }
            let rect = content.items.first { $0.id == action }?.rect ?? .zero
            switch row.source {
            case .event(let id): context.routing.route(.openEvent(eventID: id, anchor: anchor(action, target: .event(id))))
            case .project(let id): context.routing.route(.revealPanel(.projects, .item(id.uuidString.lowercased())))
            case .countdown(let id):
                if action.hasSuffix(".menu"), let menu = menu(for: row.id), content.window != nil { menu.popUp(positioning: nil, at: CGPoint(x: rect.minX, y: rect.maxY), in: content) }
                else if let item = context.presentation.state.snapshot.board.milestones.first(where: { $0.id == id }) { openEditor(item: item) }
            }
        }
    }
    func menu(for rowID: String) -> NSMenu? {
        guard let row = rows.first(where: { $0.id == rowID }), case .countdown(let id) = row.source else { return nil }
        retainedMenu?.dispose()
        let menu = NativeMenu(items: [NativeMenuEntry(id: "rename", title: context.text("deadlines.rename")), NativeMenuEntry(id: "delete", title: context.text("deadlines.delete"))]) { [weak self] action in
            guard let self else { return }
            if action == "delete" { guard self.editor?.canDismiss != false else { return }; self.closeEditor(); _ = self.save(.countdown(.delete(id: id)), feedback: "toast.dday_deleted") }
            else if let item = self.context.presentation.state.snapshot.board.milestones.first(where: { $0.id == id }) { self.openEditor(item: item) }
        }
        retainedMenu = menu; return menu.menu
    }
    private func openEditor(item: Milestone?) {
        guard editor?.canDismiss != false else { return }
        closeEditor(); let id = item?.id ?? UUID()
        let editor = ProjectDeadlineEditor(context: context, kind: .countdown, id: id, title: item?.title ?? "", day: item?.day, creating: item == nil) { [weak self] title, day, _ in
            guard let self, let day else { return nil }
            if item == nil { return self.save(.countdown(.create(CountdownInput(id: id, title: title, day: day))), feedback: "toast.countdown_added") }
            return self.save(.countdown(.update(id: id, patch: CountdownPatch(title: item?.title == title ? .unchanged : .set(title), day: item?.day == day ? .unchanged : .set(day)))), feedback: "toast.event_saving")
        }
        self.editor = editor; editor.onClose = { [weak self, weak editor] in if self?.editor === editor { self?.closeEditor() } }
        let action = item.map { "deadline.countdown." + $0.id.uuidString.lowercased() }
        if let rect = content.items.first(where: { $0.id == action })?.rect { editor.show(relativeTo: rect, of: content) }
        else { editor.show(relativeTo: surface.items.first(where: { $0.id == "deadlines.add" })?.rect ?? surface.bounds, of: surface) }
    }
    func closeEditor() { let old = editor; editor = nil; old?.dispose() }
    @discardableResult private func save(_ edit: BoardEdit, undoable: Bool = true, feedback: String? = nil) -> OperationHandle? {
        inlineError = nil; failedID = nil
        let handle = context.presentation.send(.edit(edit, undoable: undoable, feedback: feedback.map { PresentationFeedback(messageKey: $0) }))
        if let handle { Task { [weak self] in
            let receipt = await handle.settled.value
            guard let self, !self.disposed else { return }
            if case .failure(let error, _) = receipt { self.inlineError = error; self.failedID = handle.id }; self.render()
        } } else { inlineError = context.presentation.state.lastError; render() }
        return handle
    }
    func dispose() {
        guard !disposed else { return }; disposed = true; lifetime.dispose(); closeEditor(); retainedMenu?.dispose(); retainedMenu = nil
        if let layer = scroll.contentView.layer { NativeMotion.stop(layer) }
        surface.onLayout = nil; scroll.dispose(); content.dispose(); surface.dispose()
    }
}
