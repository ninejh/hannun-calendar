import AppKit

@MainActor final class HabitsPanelView: TextListPanelView {
    private(set) var streaks: [UUID: Int] = [:]
    init(context: BoardScreenContext) {
        super.init(context: context, isHabit: true)
        contentCanvas.onAction = { [weak self] key in
            if self?.commonAction(key) == true { return }
            guard let self, let id = Self.id(key), let value = self.snapshot.board.habits.first(where: { $0.id == id }) else { return }
            if key.hasSuffix(".today") {
                let checked = value.marks.contains(self.snapshot.clock.today)
                self.edit(.setHabitToday(id, !checked, self.snapshot.clock.today))
                self.layoutSubtreeIfNeeded()
                if checked { self.contentCanvas.stopFeedback() }
                else { self.contentCanvas.checkFeedback(id: key, reduceMotion: self.snapshot.environment.reduceMotion) }
            }
            else if key.hasSuffix(".delete") { self.edit(.deleteHabit(id)) }
            else { self.openTextEditor(id: id, title: value.title) }
        }
        contentCanvas.contextMenu = { [weak self] key in
            guard let self, let id = Self.id(key), let value = self.snapshot.board.habits.first(where: { $0.id == id }) else { return nil }
            return self.menu(entries: [
                NativeMenuEntry(id: "edit", title: self.context.text("item.edit_label", values: ["0": value.title])),
                NativeMenuEntry(id: "delete", title: self.context.text("item.delete_label", values: ["0": value.title]))
            ]) { [weak self] action in
                if action == "delete" { self?.edit(.deleteHabit(id)) } else { self?.openTextEditor(id: id, title: value.title) }
            }
        }
        start()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    private static func id(_ key: String) -> UUID? { key.split(separator: ".").dropFirst().first.flatMap { UUID(uuidString: String($0)) } }
    override func render() {
        super.render()
        streaks = Dictionary(uniqueKeysWithValues: snapshot.board.habits.map { ($0.id, PanelDomain.streak($0.marks, today: snapshot.clock.today)) })
    }
    override func layoutContent() {
        updateHeader([NativeRenderItem(id: "habits.title", rect: titleRect, label: context.text(titleKey), kind: .text)] + addItems() + statusItems())
        if isCompactStep { layoutCompactContent(); return }
        let wide = variant == .wide
        let axis: NativeAxis = wide ? .horizontal : .vertical
        if scroll.axis != axis { scroll.axis = axis }
        scroll.hasVerticalScroller = !wide
        let cardWidth = wide ? NativeSize.projectMinWidth : scroll.contentSize.width
        let cardHeight = NativeSize.toolbarHeight * 3
        let values = snapshot.board.habits
        var items: [NativeRenderItem] = []
        contentCanvas.displayText = [:]; contentCanvas.fonts = [:]; contentCanvas.dots = []; contentCanvas.wrappedText = [:]
        for (index, value) in values.enumerated() {
            let key = "habit.\(value.id)"
            let x = wide ? CGFloat(index) * (cardWidth + NativeSpace.md) : 0
            let y = wide ? NativeSpace.xs : NativeSpace.xs + CGFloat(index) * (cardHeight + NativeSpace.sm)
            items.append(NativeRenderItem(id: key + ".title", rect: CGRect(x: x, y: y, width: max(0, cardWidth - NativeSize.compactTarget), height: NativeSize.toolbarHeight), label: value.title, kind: .row))
            items.append(NativeRenderItem(id: key + ".delete", rect: CGRect(x: x + cardWidth - NativeSize.compactTarget, y: y, width: NativeSize.compactTarget, height: NativeSize.toolbarHeight), label: context.text("item.delete_label", values: ["0": value.title]), kind: .button, color: .textQuiet))
            contentCanvas.displayText[key + ".delete"] = "×"
            items.append(NativeRenderItem(id: key + ".streak", rect: CGRect(x: x, y: y + NativeSize.toolbarHeight, width: cardWidth, height: NativeSize.compactTarget), label: context.text("habits.streak_label", values: ["0": String(streaks[value.id] ?? 0)]), kind: .text, color: .habitStreak))
            let days = PanelDomain.recentDays(today: snapshot.clock.today)
            for day in days {
                let today = day == snapshot.clock.today
                let dotID = today ? key + ".today" : key + ".day." + day.description
                let checked = value.marks.contains(day)
                let label = value.title + " · " + context.text(checked ? "habits.day_done" : "habits.day_todo", values: ["0": day.description])
                items.append(NativeRenderItem(id: dotID, rect: CGRect(x: x + NativeSpace.sm + CGFloat(day.ordinal - days[0].ordinal) * NativeSize.compactTarget,
                                                                    y: y + NativeSize.toolbarHeight * 2, width: NativeSize.compactTarget, height: NativeSize.compactTarget),
                                             label: label, kind: today ? .checkBox : .image, checked: checked))
                contentCanvas.dots.insert(dotID)
            }
        }
        if values.isEmpty { items.append(NativeRenderItem(id: "habits.empty", rect: CGRect(x: 0, y: 0, width: scroll.contentSize.width, height: NativeSize.toolbarHeight * 2), label: context.text("habits.empty"), kind: .text, color: .textQuiet)) }
        contentCanvas.frame.size = CGSize(width: wide ? max(scroll.contentSize.width, CGFloat(values.count) * (cardWidth + NativeSpace.md)) : scroll.contentSize.width,
                                          height: max(scroll.contentSize.height, wide ? cardHeight + NativeSpace.sm : CGFloat(values.count) * (cardHeight + NativeSpace.sm)))
        contentCanvas.update(items: items)
    }
    private func layoutCompactContent() {
        let wide = variant == .wide
        let axis: NativeAxis = wide ? .horizontal : .vertical
        if scroll.axis != axis { scroll.axis = axis }
        let cardWidth = wide ? (stepMetrics.minimumCardWidth ?? NativeSize.projectMinWidth) : scroll.contentSize.width
        let cardHeight = wide ? (stepMetrics.step == .tiny ? NativeSize.toolbarHeight * 2 - NativeSpace.xxs : NativeSize.toolbarHeight * 2 + NativeSpace.xxl) :
            (stepMetrics.listRow?.height ?? NativeSize.toolbarHeight * 2)
        let gap = wide ? stepMetrics.cardGap : (stepMetrics.listRow?.gap ?? 0)
        let values = snapshot.board.habits
        let days = PanelDomain.recentDays(today: snapshot.clock.today)
        var items: [NativeRenderItem] = []
        contentCanvas.displayText = [:]; contentCanvas.fonts = [:]; contentCanvas.dots = []; contentCanvas.wrappedText = [:]
        for (index, value) in values.enumerated() {
            let key = "habit.\(value.id)"
            let x = wide ? CGFloat(index) * (cardWidth + gap) : 0
            let y = NativeSpace.xs + (wide ? 0 : CGFloat(index) * (cardHeight + gap))
            let stacked = wide && stepMetrics.step == .small
            let topHeight = stepMetrics.step == .tiny && !wide ? cardHeight - NativeSize.compactTarget : NativeSize.compactTarget
            let streak = context.text("habits.streak_label", values: ["0": String(streaks[value.id] ?? 0)])
            let streakWidth = min(cardWidth / 2, (streak as NSString).size(withAttributes: [.font: stepMetrics.metadataFont]).width + NativeSpace.lg)
            let titleWidth = stacked ? cardWidth - NativeSize.compactTarget : max(0, cardWidth - streakWidth)
            items.append(NativeRenderItem(id: key + ".title", rect: CGRect(x: x, y: y, width: titleWidth, height: topHeight), label: value.title, kind: .row))
            contentCanvas.fonts[key + ".title"] = stepMetrics.bodyFont
            items.append(NativeRenderItem(id: key + ".streak", rect: CGRect(x: stacked ? x : x + cardWidth - streakWidth, y: y + (stacked ? topHeight : 0), width: stacked ? cardWidth : streakWidth, height: topHeight), label: streak, kind: .text, color: .habitStreak))
            contentCanvas.fonts[key + ".streak"] = stepMetrics.metadataFont
            let dotY = y + topHeight * (stacked ? 2 : 1)
            for (offset, day) in days.enumerated() {
                let today = day == snapshot.clock.today
                let id = today ? key + ".today" : key + ".day." + day.description
                let checked = value.marks.contains(day)
                let label = value.title + " · " + context.text(checked ? "habits.day_done" : "habits.day_todo", values: ["0": day.description])
                items.append(NativeRenderItem(id: id, rect: CGRect(x: x + NativeSpace.sm + CGFloat(offset) * (NativeSize.compactTarget - NativeSpace.sm), y: dotY,
                    width: today ? NativeSize.compactTarget : NativeSize.compactTarget - NativeSpace.sm, height: NativeSize.compactTarget), label: label, kind: today ? .checkBox : .image, checked: checked))
                contentCanvas.dots.insert(id)
            }
            items.append(NativeRenderItem(id: key + ".delete", rect: CGRect(x: x + cardWidth - NativeSize.compactTarget, y: stacked ? y : dotY, width: NativeSize.compactTarget, height: NativeSize.compactTarget), label: context.text("item.delete_label", values: ["0": value.title]), kind: .button, color: .textQuiet))
            contentCanvas.displayText[key + ".delete"] = "×"
        }
        if values.isEmpty { items.append(NativeRenderItem(id: "habits.empty", rect: CGRect(x: 0, y: 0, width: scroll.contentSize.width, height: NativeSize.compactTarget), label: context.text("habits.empty"), kind: .text, color: .textQuiet)) }
        var height = NativeSpace.xs + (wide ? cardHeight : CGFloat(values.count) * (cardHeight + gap))
        let status = contentStatusItems(at: height); items += status
        height = max(height, status.map(\.rect.maxY).max() ?? height)
        scroll.hasVerticalScroller = !wide || height > scroll.contentSize.height
        contentCanvas.frame.size = CGSize(width: wide ? max(scroll.contentSize.width, CGFloat(values.count) * (cardWidth + gap)) : scroll.contentSize.width,
            height: max(scroll.contentSize.height, height + NativeSpace.xs))
        contentCanvas.update(items: items)
    }
}
