import AppKit

@MainActor final class SubscriptionsPanelView: EditingPanelView {
    private(set) var editor: PanelEditingForm?
    private var editingID: UUID?
    private var draftID: UUID?
    private var formPending: UUID?
    private var cachedEditor: PanelEditingForm?
    private var cachedID: UUID?
    private var creationID: UUID?
    private var notificationRequests: Set<UUID> = []
    private var latestNotification: [UUID: UUID] = [:]
    private var deniedPreference = false
    private(set) var partialMessage = ""
    private(set) var rateDetails = ""
    private var rateFooter = ""
    var summary: SubscriptionSummary { snapshot.subscriptionSummary }
    override var panelPrefix: String { "subscriptions" }
    private var totalLabel: String {
        let total = summary.krwMonthlyAmount.map { Self.money($0, currency: "KRW", locale: snapshot.environment.localeIdentifier) } ?? ""
        return snapshot.board.subscriptions.contains { $0.currency != "KRW" } && !total.isEmpty ? context.text("sub.total_approx", values: ["0": total]) : total
    }
    private var totalWidth: CGFloat {
        // Match the painted kerning; font-only measurement can ellipsize the final digits.
        (totalLabel as NSString).size(withAttributes: NativeFont.attributes(font: NativeFont.primary, color: .labelColor)).width + NativeSpace.lg
    }
    var summaryFont: NSFont {
        let paintedWidth = (totalLabel as NSString).size(withAttributes: NativeFont.attributes(font: NativeFont.primary, color: .labelColor)).width + NativeSpace.lg
        return paintedWidth > bounds.width - horizontalPadding * 2 ? NativeFont.eventTime : NativeFont.primary
    }
    private var unitLabel: String { context.text("sub.monthly_equivalent") }
    private var unitWidth: CGFloat {
        (unitLabel as NSString).size(withAttributes: NativeFont.attributes(font: NativeFont.primary, color: .labelColor)).width + NativeSpace.lg
    }
    private var unitInContent: Bool { totalWidth + unitWidth > bounds.width - horizontalPadding * 2 }
    private var totalOnSecondRow: Bool { totalWidth + unitWidth + NativeSize.compactTarget * 3 > bounds.width - horizontalPadding * 2 }
    private var totalRowHeight: CGFloat { totalOnSecondRow ? NativeSize.compactTarget : 0 }
    private var partialHeight: CGFloat {
        partialMessage.isEmpty ? 0 : isCompactStep ? EditingPanelCanvas.wrappedHeight(partialMessage, width: bounds.width - horizontalPadding * 2) : NativeSize.toolbarHeight * 2
    }
    private var rateFooterHeight: CGFloat {
        rateFooter.isEmpty ? 0 : EditingPanelCanvas.wrappedHeight(rateFooter, width: bounds.width - horizontalPadding * 2)
    }
    private var scrollsSupplement: Bool {
        stepMetrics.step == .tiny || headerRowHeight + totalRowHeight + partialHeight + rateFooterHeight +
            (statusMessage.isEmpty ? 0 : NativeSize.compactTarget) + (stepMetrics.listRow?.height ?? NativeSize.toolbarHeight) + NativeSpace.xs > bounds.height
    }
    override var scrollsStatus: Bool { super.scrollsStatus || scrollsSupplement }
    override var headerHeight: CGFloat { super.headerHeight + totalRowHeight + (scrollsSupplement ? 0 : partialHeight) }
    override var bottomInset: CGFloat {
        scrollsSupplement || rateFooter.isEmpty ? super.bottomInset : rateFooterHeight
    }
    override init(context: BoardScreenContext) {
        super.init(context: context)
        setAccessibilityIdentifier(panelPrefix); setAccessibilityLabel(context.text("sub.title"))
        onAction = { [weak self] id in
            if self?.commonAction(id) == true { return }
            if id == "subscriptions.add" { self?.openEditor(id: nil) }
            if id == "subscriptions.credit" { self?.send(.command(.openAttribution(.rates))) }
        }
        contentCanvas.onAction = { [weak self] key in
            if self?.commonAction(key) == true { return }
            if key == "subscriptions.credit" { self?.send(.command(.openAttribution(.rates))); return }
            guard let self, let id = self.id(from: key) else { return }
            if key.hasSuffix(".more") { self.showMenu(key) } else { self.openEditor(id: id) }
        }
        contentCanvas.contextMenu = { [weak self] key in
            guard let self, let id = self.id(from: key), let value = self.snapshot.board.subscriptions.first(where: { $0.id == id }) else { return nil }
            return self.menu(entries: [
                NativeMenuEntry(id: "notify", title: self.context.text(value.notify ? "sub.notify_turn_off" : "sub.notify_turn_on"), checked: value.notify),
                NativeMenuEntry(id: "edit", title: self.context.text("item.edit_label", values: ["0": value.name])),
                NativeMenuEntry(id: "delete", title: self.context.text("item.delete_label", values: ["0": value.name]))
            ]) { [weak self] action in
                if action == "delete" { self?.edit(.deleteSubscription(id)) }
                if action == "edit" { self?.openEditor(id: id) }
                if action == "notify" { self?.toggleNotification(id) }
            }
        }
        start()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    private func id(from key: String) -> UUID? { key.split(separator: ".").dropFirst().first.flatMap { UUID(uuidString: String($0)) } }
    override func render() {
        let mismatch = snapshot.notification.subscriptions.contains { $0.desired && !$0.effective }
        statusKey = !notificationRequests.isEmpty ? "sub.notify_pending" : (deniedPreference || mismatch ? "sub.notify_denied" : nil)
        super.render()
        let summary = summary
        let missing = summary.byCurrency.filter { summary.missingCurrencies.contains($0.currency) }.map { Self.money($0.monthlyAmount, currency: $0.currency, locale: snapshot.environment.localeIdentifier) }.joined(separator: " + ")
        if summary.complete && summary.missingCurrencies.isEmpty { partialMessage = "" }
        else if let amount = summary.krwMonthlyAmount {
            partialMessage = context.text("sub.fx_partial", values: ["0": context.text("sub.total_approx", values: ["0": Self.money(amount, currency: "KRW", locale: snapshot.environment.localeIdentifier)]), "1": missing])
        } else { partialMessage = context.text("sub.fx_pending", values: ["0": missing]) }
        let currencies = Set(snapshot.board.subscriptions.map(\.currency))
        let pairs = snapshot.external.rates.entries.filter { currencies.contains($0.currency) }.sorted { $0.currency < $1.currency }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: snapshot.environment.localeIdentifier)
        formatter.timeZone = TimeZone(identifier: snapshot.clock.timeZone); formatter.dateStyle = .short; formatter.timeStyle = .short
        rateDetails = pairs.map { pair in
            pair.currency + "/KRW " + pair.krwPerUnit + " · " + context.text("sub.fx_rate_date", values: ["date": pair.rateDate.description]) + " · " +
            context.text("sub.fx_fetched_at", values: ["time": formatter.string(from: pair.fetchedAt.date)])
        }.joined(separator: " · ")
        rateFooter = ""
        if !pairs.isEmpty {
            rateFooter = context.text("rates.credit_label") + " · " + pairs.map { $0.currency + " " + context.text("sub.rate_date_short", values: ["0": $0.rateDate.description]) }.joined(separator: " · ") + " · " + context.text("rates.transformation")
            rateDetails = context.text("rates.credit_label") + " · " + rateDetails + " · " + context.text("rates.transformation")
            if summary.state == .off { rateDetails += " · " + context.text("status.fx_off") }
            else if snapshot.external.rates.reasonCode == .offline { rateDetails += " · " + context.text("status.fx_offline") }
            else if summary.state == .stale { rateDetails += " · " + context.text("status.fx_stale") }
            if summary.state == .off { rateFooter += " · " + context.text("status.fx_off") }
            else if snapshot.external.rates.reasonCode == .offline { rateFooter += " · " + context.text("status.fx_offline") }
            else if summary.state == .stale { rateFooter += " · " + context.text("status.fx_stale") }
        }
        needsLayout = true
        editor?.refresh()
    }
    override func layoutContent() {
        let width = max(0, bounds.width - horizontalPadding * 2)
        let label = totalLabel
        let details = summary.byCurrency.map { Self.money($0.monthlyAmount, currency: $0.currency, locale: snapshot.environment.localeIdentifier) }.joined(separator: " + ")
        let totalWidth = min(width, self.totalWidth)
        let unitWidth = min(width, self.unitWidth)
        let titleWidth = max(0, width - (totalOnSecondRow ? (unitInContent ? unitWidth : 0) : totalWidth + unitWidth) - NativeSize.compactTarget)
        var header = [
            NativeRenderItem(id: "subscriptions.title", rect: CGRect(x: horizontalPadding, y: headerItemY, width: titleWidth, height: headerItemHeight), label: context.text("sub.title"), kind: .text),
            NativeRenderItem(id: "subscriptions.add", rect: CGRect(x: bounds.width - horizontalPadding - NativeSize.compactTarget, y: headerItemY, width: NativeSize.compactTarget, height: headerItemHeight), label: context.text("sub.add_btn"), kind: .button),
            NativeRenderItem(id: "subscriptions.total", rect: CGRect(x: bounds.width - horizontalPadding - totalWidth - (totalOnSecondRow ? 0 : NativeSize.compactTarget), y: totalOnSecondRow ? super.headerHeight : headerItemY, width: totalWidth, height: totalOnSecondRow ? totalRowHeight : headerItemHeight), label: label, kind: .text, value: unitLabel + (details.isEmpty ? "" : " · " + details))
        ]
        let unitX = unitInContent ? bounds.width - horizontalPadding - NativeSize.compactTarget - unitWidth : (totalOnSecondRow ? horizontalPadding : bounds.width - horizontalPadding - NativeSize.compactTarget - totalWidth - unitWidth)
        header.append(NativeRenderItem(id: "subscriptions.unit", rect: CGRect(x: unitX, y: totalOnSecondRow && !unitInContent ? super.headerHeight : headerItemY, width: unitWidth, height: totalOnSecondRow && !unitInContent ? totalRowHeight : headerItemHeight), label: unitLabel, kind: .text, color: .textSecondary))
        if !scrollsSupplement, !partialMessage.isEmpty { header.append(NativeRenderItem(id: "subscriptions.partial", rect: CGRect(x: horizontalPadding, y: super.headerHeight + totalRowHeight, width: width, height: partialHeight), label: partialMessage, kind: .text, color: .textQuiet)) }
        if !scrollsSupplement, !rateDetails.isEmpty { header.append(NativeRenderItem(id: "subscriptions.credit", rect: CGRect(x: horizontalPadding, y: bounds.height - bottomInset, width: width, height: bottomInset), label: rateDetails, kind: .button, color: .textQuiet)) }
        updateHeader(header + statusItems())
        var items: [NativeRenderItem] = []
        contentCanvas.displayText = [:]; contentCanvas.fonts = [:]; contentCanvas.textRects = [:]; contentCanvas.wrappedText = [:]
        let values = PanelDomain.displaySubscriptions(snapshot.board.subscriptions)
        let rowHeight = isCompactStep ? (stepMetrics.listRow?.height ?? NativeSize.toolbarHeight) : NativeSize.toolbarHeight
        var y = NativeSpace.xs
        for value in values {
            let key = "subscription.\(value.id)"
            let originalMoney = Self.money(value.amount, currency: value.currency, locale: snapshot.environment.localeIdentifier)
            let cycle = context.text("sub.cycle_" + value.cycle.rawValue)
            let money = originalMoney + " / " + cycle
            let days = value.nextDate.ordinal - snapshot.clock.today.ordinal
            let badge = context.text(days == 0 ? "deadlines.day" : days > 0 ? "deadlines.remaining" : "deadlines.elapsed", values: ["0": String(abs(days))])
            let priceWidth = (money as NSString).size(withAttributes: [.font: NativeFont.eventTime]).width + NativeSpace.lg
            let badgeWidth = (badge as NSString).size(withAttributes: [.font: NativeFont.badge]).width + NativeSpace.lg
            let available = scroll.contentSize.width
            let stacked = priceWidth + badgeWidth + NativeSize.compactTarget * 2 > available
            let separateCycle = priceWidth > available
            let height = rowHeight * CGFloat(stacked ? (separateCycle ? 3 : 2) : 1)
            let nameWidth = max(0, available - (stacked ? 0 : priceWidth) - badgeWidth - NativeSize.compactTarget)
            let notify = context.text(value.notify ? "sub.notify_on" : "sub.notify_off")
            let full = value.name + " · " + money + " · " + value.nextDate.description + " · " + value.paymentMemo + " · " + notify
            items.append(NativeRenderItem(id: key + ".row", rect: CGRect(x: 0, y: y, width: available, height: height), label: full, kind: .row))
            contentCanvas.displayText[key + ".row"] = value.name
            contentCanvas.fonts[key + ".row"] = NativeFont.primary
            contentCanvas.textRects[key + ".row"] = CGRect(x: 0, y: y, width: nameWidth, height: rowHeight)
            items.append(NativeRenderItem(id: key + ".amount", rect: CGRect(x: stacked ? 0 : nameWidth, y: y + (stacked ? rowHeight : 0), width: stacked ? available : priceWidth, height: rowHeight), label: separateCycle ? originalMoney : money, kind: .text))
            contentCanvas.fonts[key + ".amount"] = NativeFont.eventTime
            items.append(NativeRenderItem(id: key + ".due", rect: CGRect(x: available - NativeSize.compactTarget - badgeWidth, y: y, width: badgeWidth, height: rowHeight), label: badge, kind: .badge, color: .textSecondary))
            contentCanvas.fonts[key + ".due"] = NativeFont.badge
            items.append(NativeRenderItem(id: key + ".more", rect: CGRect(x: scroll.contentSize.width - NativeSize.compactTarget, y: y, width: NativeSize.compactTarget, height: rowHeight), label: full, kind: .button))
            contentCanvas.displayText[key + ".more"] = "···"
            if separateCycle {
                items.append(NativeRenderItem(id: key + ".cycle", rect: CGRect(x: 0, y: y + rowHeight * 2, width: available, height: rowHeight), label: cycle, kind: .text, color: .textSecondary))
                contentCanvas.fonts[key + ".cycle"] = NativeFont.eventTime
            }
            y += height
        }
        if values.isEmpty {
            let message = context.text("sub.empty")
            let height = EditingPanelCanvas.wrappedHeight(message, width: scroll.contentSize.width)
            items.append(NativeRenderItem(id: "subscriptions.empty", rect: CGRect(x: 0, y: y, width: scroll.contentSize.width, height: height), label: message, kind: .text, color: .textQuiet))
            contentCanvas.wrappedText["subscriptions.empty"] = message
            y += height
        }
        if scrollsSupplement, !partialMessage.isEmpty {
            let height = EditingPanelCanvas.wrappedHeight(partialMessage, width: scroll.contentSize.width)
            items.append(NativeRenderItem(id: "subscriptions.partial", rect: CGRect(x: 0, y: y, width: scroll.contentSize.width, height: height), label: partialMessage, kind: .text, color: .textQuiet))
            contentCanvas.wrappedText["subscriptions.partial"] = partialMessage; y += height
        }
        let status = contentStatusItems(at: y); items += status
        y = max(y, status.map(\.rect.maxY).max() ?? y)
        if scrollsSupplement, !rateDetails.isEmpty {
            let height = EditingPanelCanvas.wrappedHeight(rateFooter, width: scroll.contentSize.width)
            items.append(NativeRenderItem(id: "subscriptions.credit", rect: CGRect(x: 0, y: y, width: scroll.contentSize.width, height: height), label: rateDetails, kind: .button, color: .textQuiet))
            contentCanvas.wrappedText["subscriptions.credit"] = rateFooter; y += height
        }
        contentCanvas.frame.size = CGSize(width: scroll.contentSize.width, height: max(scroll.contentSize.height, y + NativeSpace.xs))
        contentCanvas.update(items: items)
    }
    static func money(_ amount: String, currency: String, locale: String) -> String {
        let formatter = NumberFormatter(); formatter.locale = Locale(identifier: locale); formatter.numberStyle = .currency
        formatter.roundingMode = .halfUp
        formatter.currencyCode = currency; formatter.minimumFractionDigits = PanelCurrency.minorUnits[currency] ?? 2; formatter.maximumFractionDigits = formatter.minimumFractionDigits
        let value = NSDecimalNumber(string: amount, locale: Locale(identifier: "en_US_POSIX"))
        return formatter.string(from: value).map { currency == "KRW" ? $0 : currency + " " + $0 } ?? currency + " " + amount
    }
    override func paint(_ item: NativeRenderItem) {
        if item.id == "subscriptions.total", summaryFont != NativeFont.primary {
            var background = item; background.label = ""; super.paint(background)
            let height = summaryFont.pointSize * 1.4
            (item.label as NSString).draw(in: CGRect(x: item.rect.minX + NativeSpace.sm, y: item.rect.midY - height / 2,
                width: max(0, item.rect.width - NativeSpace.lg), height: height),
                withAttributes: NativeFont.attributes(font: summaryFont, color: theme.color(.textPrimary)))
            return
        }
        guard item.id == "subscriptions.partial" || item.id == "subscriptions.credit" else { super.paint(item); return }
        var background = item; background.label = ""; super.paint(background)
        let text = item.id == "subscriptions.credit" ? rateFooter : item.label
        NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect: item.rect).addClip()
        (text as NSString).draw(in: item.rect.insetBy(dx: NativeSpace.sm, dy: NativeSpace.xxs),
                               withAttributes: NativeFont.attributes(font: NativeFont.toolbar, color: theme.color(.textQuiet), truncation: .byWordWrapping))
        NSGraphicsContext.restoreGraphicsState()
    }
    func toggleNotification(_ id: UUID) {
        guard let value = snapshot.board.subscriptions.first(where: { $0.id == id }) else { return }
        guard let handle = send(.command(.notification(.subscription(id), enabled: !value.notify))) else { return }
        notificationRequests.insert(handle.id); latestNotification[id] = handle.id; render()
        Task { @MainActor [weak self] in
            let receipt = await handle.settled.value
            guard let self else { return }
            self.notificationRequests.remove(handle.id)
            if self.latestNotification[id] == handle.id {
                self.latestNotification.removeValue(forKey: id)
                if case .success(.notification(let result), _) = receipt { self.deniedPreference = !value.notify && !result.effective }
            }
            self.render()
        }
    }
    func openEditor(id: UUID?) {
        if editor != nil { return }
        let existing = id.flatMap { id in snapshot.board.subscriptions.first { $0.id == id } }
        guard id == nil || existing != nil else { return }
        let key = id ?? creationID ?? UUID(); editingID = id; draftID = key
        if id == nil { creationID = key }
        if cachedID == key, let cachedEditor {
            editor = cachedEditor; self.cachedEditor = nil; cachedID = nil
            cachedEditor.present(from: self); return
        }
        // A settled create may have newer unsaved edits; those now belong to its saved record.
        if let cachedID, !snapshot.board.subscriptions.contains(where: { $0.id == cachedID }) {
            context.presentation.clearDraft(.subscription(cachedID))
        }
        cachedEditor?.dispose(); cachedEditor = nil; cachedID = nil
        let stored: SubscriptionInput?
        if case .subscription(let input) = context.presentation.state.drafts[.subscription(key)] { stored = input } else { stored = nil }
        let input = stored ?? SubscriptionInput(id: key, name: existing?.name ?? "", nextDate: existing?.nextDate ?? snapshot.clock.today,
                                               cycle: existing?.cycle ?? .monthly, amount: existing?.amount ?? "", currency: existing?.currency ?? "KRW", paymentMemo: existing?.paymentMemo ?? "")
        let form = PanelEditingForm(context: context, id: "subscription.form", titleKey: id == nil ? "sub.add_btn" : "sub.edit_btn",
                                    fields: [("name", "sub.field_name", input.name), ("amount", "sub.field_amount_only", input.amount), ("memo", "sub.field_memo", input.paymentMemo)], day: input.nextDate)
        editor = form; form.cycle = input.cycle; form.currency = input.currency
        form.noticeKey = id == nil ? "sub.notify_after_add" : nil
        form.onClose = { [weak self] in self?.closeEditor() }
        form.onChange = { [weak self] in guard let self, let input = self.formInput else { return }; self.context.presentation.setDraft(.subscription(input.id), value: .subscription(input)) }
        form.onSave = { [weak self] in self?.saveForm() }
        form.present(from: self)
    }
    private var formInput: SubscriptionInput? {
        guard let editor, let id = draftID else { return nil }
        return subscriptionInput(from: editor, id: id)
    }
    private func subscriptionInput(from form: PanelEditingForm, id: UUID) -> SubscriptionInput? {
        guard let day = form.datePicker?.day else { return nil }
        return SubscriptionInput(id: id, name: form.fields["name"]?.stringValue ?? "", nextDate: day, cycle: form.cycle,
                                 amount: form.fields["amount"]?.stringValue ?? "", currency: form.currency, paymentMemo: form.fields["memo"]?.stringValue ?? "")
    }
    private func saveForm() {
        guard formPending == nil, let input = formInput else { return }
        let creating = editingID == nil
        let intent: PanelIntent = editingID.map { .updateSubscription($0, SubscriptionPatch(name: input.name, nextDate: input.nextDate, cycle: input.cycle, amount: input.amount, currency: input.currency, paymentMemo: input.paymentMemo)) } ?? .createSubscription(input)
        do { _ = try PanelDomain.apply(intent, to: snapshot.board, now: snapshot.clock.now, today: snapshot.clock.today) }
        catch { editor?.errorKey = "error.validation"; editor?.refresh(); return }
        guard let handle = edit(intent) else { return }; formPending = handle.id
        Task { @MainActor [weak self] in
            let receipt = await handle.settled.value
            guard let self else { return }
            switch receipt {
            case .success:
                self.formPending = nil
                if creating {
                    if self.creationID == input.id { self.creationID = nil }
                    if self.draftID == input.id { self.editingID = input.id }
                }
                if self.formInput == input {
                    self.context.presentation.clearDraft(.subscription(input.id)); self.closeEditor()
                    self.cachedEditor?.dispose(); self.cachedEditor = nil; self.cachedID = nil
                } else if creating, self.cachedID == input.id, let cached = self.cachedEditor,
                          self.subscriptionInput(from: cached, id: input.id) == input {
                    self.context.presentation.clearDraft(.subscription(input.id))
                    cached.dispose(); self.cachedEditor = nil; self.cachedID = nil
                }
            case .failure(let failure, _):
                if failure.committed != .unknown { self.formPending = nil }
                self.editor?.errorKey = failure.messageKey; self.editor?.refresh()
            }
            self.render()
        }
    }
    func closeEditor() {
        guard let editor else { return }
        editor.dismiss()
        guard editor.superview == nil else { return }
        cachedEditor?.dispose(); cachedEditor = editor; cachedID = draftID
        self.editor = nil; editingID = nil; draftID = nil
    }
    override func editorVisibilityChanged(isHidden: Bool) { editor?.isHidden = isHidden }
    override func dispose() { editor?.dispose(); editor = nil; cachedEditor?.dispose(); cachedEditor = nil; super.dispose() }
}
