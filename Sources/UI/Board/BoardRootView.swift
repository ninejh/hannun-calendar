import AppKit

@MainActor final class BoardRootView: NSView, BoardRouting, PanelMenuProviding {
    let calendarView: CalendarGridView
    let workspace: BoardWorkspaceView
    let context: BoardScreenContext
    let editorHost: BoardEditorHost
    private let routingProxy: WeakBoardRoutingProxy
    private let viewport = NSScrollView()
    private let parking = NSView()
    private let feedback: NativeCanvasView
    private let lifetime = ScreenLifetime()
    private let panelFactories: [PanelID: PanelFactory]
    private let overlayFactory: OverlayFactory
    private var controllers: [PanelID: any PanelController] = [:]
    private var menus: [SlotID: NativeMenu] = [:]
    private var layoutMenus: [NativeMenu] = []
    private var activeOverlay: (any OverlayController)?
    private var activeRoute: BoardRoute?
    private var overlayState: OverlayRoute?
    private var lastLayout: BoardLayout?
    private var lastViewport: CGSize?
    private var lastLanguage: BoardLanguage?
    private var feedbackKey = ""
    private var drag: (split: LayoutSplit, offset: Double, viewport: LayoutViewport, candidates: [LayoutStepCandidate])?
    private(set) var layoutFailure: AppFailure?
    private enum DeferredOverlayAction { case route(BoardRoute), present(OverlayKind, BoardRoute), dismissOutside }
    private var deferredOverlayAction: DeferredOverlayAction?
    private var deferredDrainScheduled = false
    private var inputObservations: [NSObjectProtocol] = []
    private var mouseMonitor: Any?
    private(set) var geometry = BoardLayoutGeometry()
    private(set) var slotHosts: [SlotID: BoardSlotHostView] = [:]
    private(set) var layoutCount = 0
    private(set) var lastFlushReceipt: CommandReceipt?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    init(presentation: any BoardPresentation, strings: NativeStrings, panelFactories: [PanelID: PanelFactory], overlayFactory: @escaping OverlayFactory) {
        precondition(Set(panelFactories.keys) == Set(PanelID.allCases), "The composition root must supply all nine panel factories")
        self.panelFactories = panelFactories; self.overlayFactory = overlayFactory
        let focus = FocusCoordinator(), host = BoardEditorHost(), proxy = WeakBoardRoutingProxy()
        editorHost = host; routingProxy = proxy
        context = BoardScreenContext(presentation: presentation, kit: NativeUIKit(strings: strings), routing: proxy, focus: focus, editing: EditingCoordinator(host: host))
        calendarView = CalendarGridView(context: context); workspace = BoardWorkspaceView(focus: focus); feedback = NativeCanvasView(focus: focus)
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("board.root"); setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityIdentifier("board.root"); setAccessibilityLabel("Hannun Calendar")
        proxy.target = self; context.kit.panelMenus.target = self
        viewport.drawsBackground = false; viewport.hasHorizontalScroller = true; viewport.hasVerticalScroller = true; viewport.autohidesScrollers = true; viewport.scrollerStyle = .overlay
        viewport.documentView = workspace; addSubview(viewport); workspace.addSubview(calendarView)
        parking.isHidden = true; workspace.addSubview(parking)
        for slot in SlotID.allCases {
            let host = BoardSlotHostView(slot: slot, focus: focus); slotHosts[slot] = host; workspace.addSubview(host)
        }
        workspace.promoteFeedbackSurfaces()
        addSubview(feedback); feedback.isHidden = true
        feedback.onAction = { [weak presentation] id in if id == "action.undo" { presentation?.send(.undo) } }
        feedback.onShortcut = { [weak self] in self?.handleShortcut($0) ?? false }
        calendarView.boardShortcut = { [weak self] in self?.handleShortcut($0) ?? false }
        calendarView.contextMenu = { [weak self] id in id == "action.layout" ? self?.layoutMenu() : nil }
        workspace.onShortcut = { [weak self] in self?.handleShortcut($0) ?? false }
        workspace.onAdjust = { [weak self] id, amount in if let split = BoardWorkspaceView.split(id) { self?.adjust(split, amount: amount) } }
        workspace.beginSplit = { [weak self] split, position in self?.begin(split, position: position) }
        workspace.moveSplit = { [weak self] in self?.move(position: $0) }
        workspace.endSplit = { [weak self] in self?.finish(cancel: $0) }
        context.focus.onFocusChange = { [weak self] _ in self?.updateSlotFocus() }
        for name in [NSText.didChangeNotification, NSText.didEndEditingNotification, NSTextView.didChangeSelectionNotification, NSControl.textDidChangeNotification, NSControl.textDidEndEditingNotification] {
            inputObservations.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleDeferredOverlayAction() }
            })
        }
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            inputObservations.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let source = (notification.object as? NSWindow).map(ObjectIdentifier.init)
                MainActor.assumeIsolated {
                    guard let self, let source, self.window.map(ObjectIdentifier.init) == source else { return }
                    self.workspace.cancelSplit()
                }
            })
        }
        lifetime.own(presentation.subscribe { [weak self] in self?.receive($0) })
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }; mouseMonitor = nil
        guard window != nil, !lifetime.isDisposed else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }; return self.filterMouseEvent(event)
        }
    }
    override func layout() {
        super.layout(); guard !lifetime.isDisposed else { return }
        viewport.frame = bounds
        applyLayout(); layoutFeedback()
        activeOverlay?.view.frame = bounds
        if let activeRoute { activeOverlay?.present(resolved(activeRoute)) }
    }
    func controller(for panel: PanelID) -> (any PanelController)? { controllers[panel] }
    private func controller(_ panel: PanelID) -> any PanelController {
        if let controller = controllers[panel] { return controller }
        let controller = panelFactories[panel]!(context)
        precondition(controller.panelID == panel, "Panel factory returned the wrong identity")
        controller.view.setAccessibilityIdentifier("panel.\(panel.rawValue)")
        controller.view.setAccessibilityLabel(context.text(Self.panelKey(panel)))
        controllers[panel] = controller
        if let canvas = controller.view as? NativeCanvasView {
            let existing = canvas.onShortcut
            canvas.onShortcut = { [weak self] event in existing?(event) == true || self?.handleShortcut(event) == true }
        }
        return controller
    }
    private func receive(_ change: PresentationChange) {
        guard !lifetime.isDisposed else { return }
        if drag != nil, context.presentation.state.view.stepPreview == nil { workspace.cancelSplit() }
        if !change.domains.isDisjoint(with: [.board, .environment]) {
            let rejectedSlotEdit = change.domains.contains(.error) && context.presentation.state.lastError?.committed == .no && change.affected.contains { if case .slot = $0 { return true }; return false }
            applyLayout(rollbackSlots: rejectedSlotEdit)
        }
        if change.domains.contains(.view) { syncOverlay() }
        if !change.domains.isDisjoint(with: [.toast, .error, .environment, .board]) { updateFeedback() }
    }
    private func applyLayout(rollbackSlots: Bool = false) {
        let viewportSize = bounds.size
        if let drag, drag.viewport != LayoutViewport(width: viewportSize.width, height: viewportSize.height) {
            workspace.cancelSplit(); return
        }
        let state = context.presentation.state, current = state.snapshot.board.layout
        let structural = current != lastLayout || lastViewport != viewportSize || lastLanguage != state.snapshot.board.settings.language || layoutFailure != nil
        let theme = NativeTheme(appearance: state.snapshot.environment.resolvedAppearance)
        context.kit.theme = theme
        workspace.reduceMotion = state.snapshot.environment.reduceMotion
        for (slot, host) in slotHosts {
            if let panel = current.slots[slot.rawValue] {
                let label = context.text("slot_menu.title") + " · " + context.text(Self.panelKey(panel))
                if host.accessibilityLabel() != label { host.setAccessibilityLabel(label) }
            }
        }
        for (panel, controller) in controllers {
            let label = context.text(Self.panelKey(panel))
            if controller.view.accessibilityLabel() != label { controller.view.setAccessibilityLabel(label) }
        }
        if workspace.theme.appearance != theme.appearance { workspace.theme = theme }
        guard structural else { return }
        // A not-yet-sized root has no profile. An unsupported real viewport keeps the
        // last valid frames and reports the existing inline validation state.
        guard viewportSize.width > 0, viewportSize.height > 0 else { return }
        let next = BoardLayoutGeometry.make(viewport: viewportSize, layout: current)
        guard next.profile != nil else { layoutFailure = AppFailure(code: .validationFailed); updateFeedback(); return }
        if layoutFailure != nil { layoutFailure = nil; updateFeedback() }
        let before = lastLayout; lastLayout = current; lastViewport = viewportSize; layoutCount += 1
        lastLanguage = state.snapshot.board.settings.language
        let motion: NativeMotionKind? = before.map { $0.slots != current.slots ? (rollbackSlots ? .rollback : .swap) : nil } ?? nil
        geometry = next
        workspace.frame = CGRect(origin: .zero, size: geometry.contentSize)
        calendarView.boardViewportWidth = bounds.width; calendarView.frame = geometry.calendar; calendarView.needsLayout = true
        let visiblePanels = Set(geometry.slots.keys.compactMap { current.slots[$0.rawValue] })
        for (panel, controller) in controllers where !visiblePanels.contains(panel) {
            controller.setPlacement(PanelPlacement(slot: nil, shape: .rail, heightStep: .regular, railWidthStep: geometry.effectiveSteps.column, frame: .zero, headerRect: .zero, contentRect: .zero)); controller.view.isHidden = true
            if let layer = controller.view.layer { NativeMotion.stop(layer) }
            if !editorHost.textView.hasMarkedText(), controller.view.superview !== parking { controller.view.removeFromSuperview(); parking.addSubview(controller.view) }
        }
        for slot in SlotID.allCases {
            guard let host = slotHosts[slot], let panel = current.slots[slot.rawValue] else { continue }
            guard let frame = geometry.slots[slot] else { host.isHidden = true; continue }
            host.isHidden = false; host.frame = frame
            let controller = controller(panel); host.mount(controller.view); controller.view.isHidden = false
            let shape: PanelShape = slot == .wide ? .wide : .rail
            let step = geometry.effectiveSteps[slot]
            let regions = NativePanelStepMetrics(panel: panel, shape: shape, step: step).regions(in: CGRect(origin: .zero, size: frame.size))
            controller.setPlacement(PanelPlacement(slot: slot, shape: shape, heightStep: step, railWidthStep: geometry.effectiveSteps.column, frame: frame, headerRect: regions.headerRect, contentRect: regions.contentRect))
            host.needsLayout = true
            if let motion, let layer = controller.view.layer { NativeMotion.apply(motion, to: layer, reduceMotion: state.snapshot.environment.reduceMotion) }
        }
        var items: [NativeRenderItem] = []
        for split in [LayoutSplit.column, .main, .rail, .railBottom] {
            guard let rect = geometry.dividers[split], let candidate = geometry.candidates[split]?.first(where: { $0.step == geometry.effectiveSteps[split] }) else { continue }
            func title(_ slot: SlotID?) -> String { slot.flatMap { current.slots[$0.rawValue] }.map { context.text(Self.panelKey($0)) } ?? "" }
            let metadata = context.splitterMetadata(split: split, step: geometry.effectiveSteps[split], primary: title(candidate.primarySlot), neighbor: title(candidate.neighborSlot), neighborStep: candidate.neighborSlot.map { geometry.effectiveSteps[$0] })
            var item = NativeRenderItem(id: "divider.\(split.rawValue)", rect: rect, label: metadata.label, kind: .slider)
            item.interactionRect = split == .column ? rect.insetBy(dx: -(BoardLayoutMetrics.gap - rect.width) / 2, dy: 0) : rect.insetBy(dx: 0, dy: -(BoardLayoutMetrics.gap - rect.height) / 2)
            let stepKey: String = switch geometry.effectiveSteps[split] { case .tiny: "tiny"; case .small: "small"; case .regular: "regular"; case .large: "large" }
            item.value = context.text("layout.step." + stepKey) + " · \(geometry.effectiveSteps[split].rawValue)/4"; item.splitter = metadata
            items.append(item)
        }
        workspace.update(items: items); workspace.window?.invalidateCursorRects(for: workspace)
        updateSlotFocus()
        if let before, before.hiddenSlots != current.hiddenSlots, !editorHost.textView.hasMarkedText() { requestNotesFlush() }
        if let activeRoute { activeOverlay?.present(resolved(activeRoute)) }
    }
    private func updateSlotFocus() {
        guard context.focus.keyboardFocus, let id = context.focus.focusedID?.rawValue else { workspace.slotFocusRect = nil; return }
        workspace.slotFocusRect = SlotID.allCases.first(where: { id == PanelHeaderGeometry.identifier(for: $0) }).flatMap { geometry.slots[$0] }
    }
    func select(panel: PanelID, in slot: SlotID) {
        guard !lifetime.isDisposed, context.presentation.state.snapshot.board.layout.slots[slot.rawValue] != panel else { return }
        context.presentation.send(.edit(.layout(.select(slot: slot, panel: panel)), undoable: true))
    }
    func panelMenu(for slot: SlotID) -> NSMenu? { menu(for: slot) }
    func menu(for slot: SlotID) -> NSMenu {
        menus[slot]?.dispose()
        let assigned = context.presentation.state.snapshot.board.layout.slots[slot.rawValue]
        let entries = PanelID.allCases.map { NativeMenuEntry(id: "slot.\(slot.rawValue).select.\($0.rawValue)", title: context.text(Self.panelKey($0)), checked: $0 == assigned) }
        let wrapper = NativeMenu(items: entries) { [weak self] id in
            guard let raw = id.split(separator: ".").last, let panel = PanelID(rawValue: String(raw)) else { return }; self?.select(panel: panel, in: slot)
        }
        wrapper.menu.title = context.text("slot_menu.title"); menus[slot] = wrapper; return wrapper.menu
    }
    private func layoutMenu() -> NSMenu {
        for menu in layoutMenus { menu.dispose() }; layoutMenus.removeAll()
        let menu = NSMenu(); menu.autoenablesItems = false
        let layout = context.presentation.state.snapshot.board.layout
        for split in [LayoutSplit.column, .main, .rail, .railBottom] {
            let candidate = geometry.candidates[split]?.first(where: { $0.step == geometry.effectiveSteps[split] })
            let suffix: String = switch split { case .column: "column"; case .main: "main"; case .rail: "upper"; case .railBottom: "lower" }
            func title(_ slot: SlotID?) -> String { slot.flatMap { layout.slots[$0.rawValue] }.map { context.text(Self.panelKey($0)) } ?? "" }
            let base = context.text("layout.menu." + suffix)
            let name = candidate?.primarySlot.map { base + " — " + title($0) } ?? base
            let parent = NSMenuItem(title: name, action: nil, keyEquivalent: "")
            parent.identifier = NSUserInterfaceItemIdentifier("layout.\(split.rawValue)")
            guard let candidate else { parent.isEnabled = false; menu.addItem(parent); continue }
            let entries = PanelSizeStep.allCases.map { step in
                let key: String = switch step { case .tiny: "tiny"; case .small: "small"; case .regular: "regular"; case .large: "large" }
                return NativeMenuEntry(id: "layout.\(split.rawValue).\(step.rawValue)", title: context.text("layout.step." + key), checked: geometry.effectiveSteps[split] == step)
            }
            let wrapper = NativeMenu(items: entries) { [weak self] id in
                guard let raw = id.split(separator: ".").last, let number = Int(raw), let step = PanelSizeStep(rawValue: number) else { return }
                self?.setStep(split, step: step)
            }
            let explanation = NSMenuItem(title: context.text("layout.explain." + suffix, values: ["neighbor": title(candidate.neighborSlot)]), action: nil, keyEquivalent: "")
            explanation.isEnabled = false; wrapper.menu.insertItem(.separator(), at: 0); wrapper.menu.insertItem(explanation, at: 0)
            parent.submenu = wrapper.menu; menu.addItem(parent); layoutMenus.append(wrapper)
        }
        return menu
    }
    private func setStep(_ split: LayoutSplit, step: PanelSizeStep) {
        workspace.cancelSplit()
        guard geometry.dividers[split] != nil, geometry.effectiveSteps[split] != step else { return }
        context.presentation.send(.edit(.layout(.setStep(split, step, viewport: LayoutViewport(width: bounds.width, height: bounds.height))), undoable: false))
    }
    private func begin(_ split: LayoutSplit, position: CGFloat) {
        guard let rect = geometry.dividers[split], let candidates = geometry.candidates[split] else { return }
        let viewport = LayoutViewport(width: bounds.width, height: bounds.height)
        let center = split == .column ? rect.midX : rect.midY
        drag = (split, Double(position - center), viewport, candidates)
        context.presentation.send(.beginStepPreview(split, viewport: viewport))
    }
    private func move(position: CGFloat) {
        guard let drag, context.presentation.state.view.stepPreview != nil,
              let candidate = try? LayoutStepResolver.nearest(drag.candidates, pointer: Double(position), grabOffset: drag.offset) else { return }
        context.presentation.send(.previewStep(candidate.step))
    }
    private func finish(cancel: Bool) {
        guard drag != nil else { return }; drag = nil
        context.presentation.send(cancel ? .cancelStepPreview : .commitStepPreview)
        applyLayout()
    }
    private func adjust(_ split: LayoutSplit, amount: Int) {
        workspace.cancelSplit()
        guard geometry.dividers[split] != nil else { return }
        let previous = geometry.effectiveSteps[split]
        guard let step = PanelSizeStep(rawValue: min(4, max(1, previous.rawValue + amount))), step != previous else { return }
        setStep(split, step: step)
    }
    func handleShortcut(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 {
            if composingEditor != nil { return false }
            if drag != nil { workspace.cancelSplit() } else { route(.dismissOverlay) }; return true
        }
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "k": route(.openSearch(initialQuery: "", anchor: nil)); return true
            case "n": route(.openAdd(AddRequest(kind: .event, day: context.presentation.state.view.selectedDay))); return true
            case "z":
                if let text = window?.firstResponder as? NSTextView, text.undoManager?.canUndo == true { return false }
                context.presentation.send(.undo); return true
            default: return false
            }
        }
        if event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
           let focused = context.focus.focusedID?.rawValue, let split = BoardWorkspaceView.split(focused),
           let metadata = workspace.items.first(where: { $0.id == focused })?.splitter,
           let step = metadata.requestedStep(forKeyCode: event.keyCode) {
            adjust(split, amount: step.rawValue - metadata.step.rawValue); return true
        }
        return false
    }
    override func keyDown(with event: NSEvent) { if !handleShortcut(event), !context.focus.handle(event) { super.keyDown(with: event) } }
    /// Only own-window clicks outside the real overlay's hit region request dismissal.
    /// Holding the event while marked text exists preserves the field editor and its IME session.
    func filterMouseEvent(_ event: NSEvent) -> NSEvent? {
        guard !lifetime.isDisposed, let overlay = activeOverlay, event.window === window else { return event }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return event }
        if let target = hitTest(point), target === overlay.view || target.isDescendant(of: overlay.view) { return event }
        if composingEditor != nil { deferredOverlayAction = .dismissOutside; return nil }
        dismissOverlay(restoreFocus: false); context.presentation.send(.overlayOpen(nil)); return event
    }
    private var composingEditor: NSTextView? {
        if let editor = window?.firstResponder as? NSTextView, editor.hasMarkedText() { return editor }
        return editorHost.textView.hasMarkedText() ? editorHost.textView : nil
    }
    private func scheduleDeferredOverlayAction() {
        guard deferredOverlayAction != nil, !deferredDrainScheduled else { return }
        deferredDrainScheduled = true
        // Let native field/control delegates publish the committed string into the draft first.
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }; self.deferredDrainScheduled = false
            guard !self.lifetime.isDisposed, self.composingEditor == nil, let pending = self.deferredOverlayAction else { return }
            self.deferredOverlayAction = nil
            switch pending {
            case .route(let request): self.route(request)
            case .present(let kind, let request): self.present(kind: kind, request: request)
            case .dismissOutside: self.dismissOverlay(restoreFocus: false); self.context.presentation.send(.overlayOpen(nil))
            }
        }
    }
    func route(_ request: BoardRoute) {
        guard !lifetime.isDisposed else { return }
        if activeOverlay != nil, composingEditor != nil { deferredOverlayAction = .route(request); return }
        switch request {
        case .dismissOverlay: dismissOverlay(); if context.presentation.state.view.overlay != nil { context.presentation.send(.overlayOpen(nil)) }
        case .revealAgenda(let day, let anchor):
            let handle = context.presentation.send(.revealAgenda(day, PresentationAnchor(id: "calendar.day.\(day)", rect: anchor.boardRect)))
            guard let handle else { return }
            Task { @MainActor [weak self] in
                let receipt = await handle.settled.value
                guard let self, !self.lifetime.isDisposed else { return }
                if case .success = receipt { self.controller(.today).reveal(.day(day)) }
                else { self.present(kind: .agenda, request: .revealAgenda(day: day, anchor: anchor)) }
            }
        case .openEvent: present(kind: .event, request: request)
        case .openAdd: present(kind: .add, request: request)
        case .openSearch(let query, _): context.presentation.send(.searchQuery(query)); present(kind: .search, request: request)
        case .openSettings: present(kind: .settings, request: request)
        case .openMonthPicker: present(kind: .monthPicker, request: request)
        case .openCalendars: present(kind: .calendars, request: request)
        case .revealPanel(let panel, let target): reveal(panel: panel, target: target)
        }
    }
    private func syncOverlay() {
        let next = context.presentation.state.view.overlay
        guard overlayState != next else { return }; overlayState = next
        guard let next else { dismissOverlay(); return }
        switch next {
        case .settings: present(kind: .settings, request: .openSettings)
        case .search: present(kind: .search, request: .openSearch(initialQuery: context.presentation.state.view.query, anchor: nil))
        case .newEvent: present(kind: .add, request: .openAdd(AddRequest(kind: .event, day: context.presentation.state.view.selectedDay)))
        case .event(let id, let old): present(kind: .event, request: .openEvent(eventID: id, anchor: legacyAnchor(old, target: .event(id))))
        case .agenda(let day, let old): present(kind: .agenda, request: .revealAgenda(day: day, anchor: legacyAnchor(old, target: .day(day))))
        case .monthPicker: present(kind: .monthPicker, request: .openMonthPicker(anchor: legacyAnchor(nil, target: .control("action.chooseMonth"))))
        case .calendars: present(kind: .calendars, request: .openCalendars(anchor: legacyAnchor(nil, target: .control("action.calendars"))))
        }
    }
    private func present(kind: OverlayKind, request: BoardRoute) {
        if activeOverlay != nil, composingEditor != nil, activeRoute != request { deferredOverlayAction = .present(kind, request); return }
        if activeOverlay?.kind != kind { dismissOverlay(); activeOverlay = overlayFactory(kind, context) }
        guard let overlay = activeOverlay else { return }
        if overlay.view.superview !== self { addSubview(overlay.view) }
        overlay.view.frame = bounds; activeRoute = request; overlay.present(resolved(request))
    }
    private func reveal(panel: PanelID, target: PanelReveal) {
        let layout = context.presentation.state.snapshot.board.layout
        let assigned = layout.slots.first(where: { $0.value == panel }).flatMap { SlotID(rawValue: $0.key) }
        let slot = assigned ?? (panel == .projects ? .wide : .railTop)
        if assigned != nil, !layout.hiddenSlots.contains(slot.rawValue) {
            route(.dismissOverlay); controller(panel).reveal(target); return
        }
        var edits: [AtomicBoardEdit] = []
        if assigned == nil { edits.append(.layout(.select(slot: slot, panel: panel))) }
        edits.append(.layout(.setHidden(slot: slot, false)))
        guard let handle = context.presentation.send(.edit(.transaction(edits), undoable: false)) else { return }
        Task { @MainActor [weak self] in
            let receipt = await handle.settled.value
            guard let self, !self.lifetime.isDisposed, case .success = receipt else { return }
            self.route(.dismissOverlay); self.controller(panel).reveal(target)
        }
    }
    private func dismissOverlay(restoreFocus: Bool = true) {
        if !lifetime.isDisposed, activeOverlay != nil, composingEditor != nil {
            deferredOverlayAction = restoreFocus ? .route(.dismissOverlay) : .dismissOutside; return
        }
        let previous = activeOverlay, anchor = activeRoute.flatMap(Self.anchor)
        activeOverlay = nil; activeRoute = nil
        let first = window?.firstResponder as? NSView
        let fieldOwner = (first as? NSTextView)?.delegate as? NSView
        let wasOverlayEditor = previous.map { fieldOwner?.isDescendant(of: $0.view) == true } ?? false
        let shouldRestore = first == nil || first === workspace || first === calendarView || wasOverlayEditor || (previous.map { first?.isDescendant(of: $0.view) == true } ?? false)
        previous?.dismiss(); previous?.dispose(); previous?.view.removeFromSuperview()
        if restoreFocus, shouldRestore, let id = anchor?.returnFocusID { window?.makeFirstResponder(workspace); context.focus.focus(id) }
    }
    private func legacyAnchor(_ old: PresentationAnchor?, target: AnchorTarget) -> StableAnchor {
        StableAnchor(target: target, boardRect: old?.rect ?? CGRect(x: bounds.midX, y: bounds.midY, width: NativeSize.compactTarget, height: NativeSize.compactTarget), returnFocusID: old.map { FocusID($0.id) })
    }
    func resolve(_ anchor: StableAnchor) -> StableAnchor {
        var result = anchor; var rect: CGRect?
        switch anchor.target {
        case .day(let day): if let local = calendarView.anchorRect(for: day.description) { rect = calendarView.convert(local, to: self) }
        case .event(let id): if let local = calendarView.anchorRect(for: id) { rect = calendarView.convert(local, to: self) }
        case .slot(let slot): if let host = slotHosts[slot], !host.isHidden { rect = host.convert(host.bounds, to: self) }
        case .control(let id): rect = rectForControl(id, in: self)
        }
        result.boardRect = NativeGeometry.clamp(rect ?? anchor.boardRect, to: bounds)
        return result
    }
    private func rectForControl(_ id: String, in view: NSView) -> CGRect? {
        guard !view.isHidden else { return nil }
        if let canvas = view as? NativeCanvasView, let item = canvas.items.first(where: { $0.id == id }) { return canvas.convert(item.rect, to: self) }
        for child in view.subviews { if let rect = rectForControl(id, in: child) { return rect } }; return nil
    }
    func screenRect(for anchor: StableAnchor) -> CGRect {
        guard let window else { return .zero }; return window.convertToScreen(convert(resolve(anchor).boardRect, to: nil))
    }
    private func resolved(_ request: BoardRoute) -> BoardRoute {
        switch request {
        case .openEvent(let id, let anchor): return .openEvent(eventID: id, anchor: resolve(anchor))
        case .openAdd(var add): add.anchor = add.anchor.map(resolve); return .openAdd(add)
        case .openSearch(let query, let anchor): return .openSearch(initialQuery: query, anchor: anchor.map(resolve))
        case .revealAgenda(let day, let anchor): return .revealAgenda(day: day, anchor: resolve(anchor))
        case .openMonthPicker(let anchor): return .openMonthPicker(anchor: anchor.map(resolve))
        case .openCalendars(let anchor): return .openCalendars(anchor: anchor.map(resolve))
        default: return request
        }
    }
    private static func anchor(_ route: BoardRoute) -> StableAnchor? {
        switch route { case .openEvent(_, let anchor), .revealAgenda(_, let anchor): anchor; case .openAdd(let add): add.anchor; case .openSearch(_, let anchor), .openMonthPicker(let anchor), .openCalendars(let anchor): anchor; default: nil }
    }
    private func updateFeedback() {
        let state = context.presentation.state
        let key = String(describing: state.toast?.source) + "|" + (state.toast?.messageKey ?? "") + "|" + String(describing: state.toast?.values) + "|" + String(describing: state.toast?.undoable) + "|" + String(describing: state.lastError ?? layoutFailure) + "|" + state.snapshot.board.settings.language.rawValue + state.snapshot.environment.resolvedAppearance.rawValue
        guard feedbackKey != key else { return }; feedbackKey = key
        var items: [NativeRenderItem] = []
        feedback.theme = NativeTheme(appearance: state.snapshot.environment.resolvedAppearance)
        if let toast = state.toast {
            let message = context.text(toast.messageKey, values: toast.values)
            items.append(NativeRenderItem(id: "board.toast", rect: CGRect(x: 0, y: 0, width: NativeSize.searchWidth, height: NativeSize.toolbarHeight + NativeSpace.lg), label: message, kind: .text, fill: .toastBg, color: .toastText))
            if toast.undoable { items.append(NativeRenderItem(id: "action.undo", rect: CGRect(x: NativeSize.searchWidth - NativeSize.popoverWidth / 3, y: NativeSpace.sm, width: NativeSize.popoverWidth / 3 - NativeSpace.sm, height: NativeSize.toolbarHeight), label: context.text("toast.undo_action"), kind: .button, color: .accentBlue)) }
        } else if let error = state.lastError ?? layoutFailure ?? state.snapshot.storageWarning {
            items.append(NativeRenderItem(id: "board.error", rect: CGRect(x: 0, y: 0, width: NativeSize.searchWidth, height: NativeSize.toolbarHeight + NativeSpace.lg), label: context.text(error.messageKey, values: error.values), kind: .text, fill: .toastBg, color: .danger))
        }
        feedback.update(items: items); feedback.isHidden = items.isEmpty; layoutFeedback()
        if !items.isEmpty { NSAccessibility.post(element: feedback, notification: .valueChanged) }
    }
    private func layoutFeedback() { feedback.frame = CGRect(x: max(NativeSpace.lg, (bounds.width - NativeSize.searchWidth) / 2), y: max(0, bounds.height - NativeSpace.lg - NativeSize.toolbarHeight - NativeSpace.lg), width: min(NativeSize.searchWidth, bounds.width), height: NativeSize.toolbarHeight + NativeSpace.lg) }
    private func requestNotesFlush() {
        let presentation = context.presentation
        Task { @MainActor [weak self] in let receipt = await presentation.flushNotes(); self?.lastFlushReceipt = receipt.compact }
    }
    /// Called after the application observes flushNotes; does not cancel accepted mutations or Undo work.
    func dispose() {
        guard !lifetime.isDisposed else { return }
        workspace.cancelSplit(); context.presentation.send(.cancelStepPreview)
        lifetime.dispose(); drag = nil; routingProxy.target = nil; context.kit.panelMenus.target = nil
        for menu in layoutMenus { menu.dispose() }; layoutMenus.removeAll()
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }; mouseMonitor = nil
        for observation in inputObservations { NotificationCenter.default.removeObserver(observation) }; inputObservations = []
        deferredOverlayAction = nil
        context.focus.onFocusChange = nil
        dismissOverlay(); if let layer = calendarView.layer { NativeMotion.stop(layer) }; calendarView.dispose(); workspace.dispose(); feedback.dispose()
        for controller in controllers.values { if let layer = controller.view.layer { NativeMotion.stop(layer) }; controller.dispose(); controller.view.removeFromSuperview() }; controllers = [:]
        for host in slotHosts.values { host.dispose() }; slotHosts = [:]
        for menu in menus.values { menu.dispose() }; menus = [:]
        editorHost.dispose(); context.editing.dispose(); viewport.documentView = nil
    }
    private static func panelKey(_ panel: PanelID) -> String {
        switch panel { case .todos: "slot_menu.item_todo"; case .worldClock: "slot_menu.item_world_clock"; case .focusTimer: "slot_menu.item_focus_timer"; default: "slot_menu.item_\(panel.rawValue)" }
    }
}
