import AppKit

/// Warning/error feedback needs its full text, including a second operation's error.
@MainActor private final class BoardFeedbackView: NativeCanvasView {
    static func wraps(_ item: NativeRenderItem) -> Bool { item.id == "board.error" || item.id == "board.toast" }
    private static func attributes(color: NSColor) -> [NSAttributedString.Key: Any] {
        NativeFont.attributes(font: NativeFont.primary, color: color, truncation: .byWordWrapping)
    }
    static func height(for message: String, width: CGFloat) -> CGFloat {
        let text = (message as NSString).boundingRect(with: CGSize(width: max(1, width - 2 * NativeSpace.sm), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes(color: .labelColor))
        return max(NativeSize.toolbarHeight + NativeSpace.lg, ceil(text.height) + 2 * NativeSpace.sm)
    }
    override func paint(_ item: NativeRenderItem) {
        guard Self.wraps(item) else { super.paint(item); return }
        (item.label as NSString).draw(with: item.rect.insetBy(dx: NativeSpace.sm, dy: NativeSpace.sm), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: Self.attributes(color: theme.color(item.color)))
    }
}

@MainActor final class BoardRootView: NSView, BoardRouting, PanelMenuProviding {
    let calendarView: CalendarGridView
    let workspace: BoardWorkspaceView
    let context: BoardScreenContext
    let editorHost: BoardEditorHost
    private let routingProxy: WeakBoardRoutingProxy
    private let viewport = NSScrollView()
    private var observedViewportBounds: CGRect?
    private let parking = NSView()
    private let feedback: NativeCanvasView
    private var feedbackBaseItems: [NativeRenderItem] = []
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
    private var restoredPanelNotice = false
    private var editingGrid = false
    private var gridHandles: [GridHandleView] = []
    private var gridExitViews: [GridHandleExitView] = []
    private var gridEditingBorders: [GridItemID: CAShapeLayer] = [:]
    private let gridGhost = GridGhostView(frame: .zero)
    private var ghostSettleGeneration: UUID?
    private let gridDots = GridDotsView(frame: .zero)
    private struct GridInteraction {
        var item: GridItemID; var resizing: Bool; var original: GridRect; var candidate: GridRect
        var start: CGPoint; var layout: BoardLayout; var viewport: CGSize; var active = false; var valid = true
    }
    private var gridInteraction: GridInteraction?
    private struct DirectMoveContact {
        let item: GridItemID
        let start: CGPoint
        var active = false
    }
    private var directMoveContact: DirectMoveContact?
    private var gridScrollTimer: Timer?
    private var gridPointer: CGPoint?
    private(set) var gridTool: GridToolPopover?
    private weak var gridToolHandle: GridHandleView?
    private var drag: (split: LayoutSplit, offset: Double, viewport: LayoutViewport, candidates: [LayoutStepCandidate])?
    private(set) var layoutFailure: AppFailure?
    private enum DeferredOverlayAction { case route(BoardRoute), present(OverlayKind, BoardRoute), dismissOutside, toggleGrid }
    private var deferredOverlayAction: DeferredOverlayAction?
    private var deferredDrainScheduled = false
    private var inputObservations: [NSObjectProtocol] = []
    private var mouseMonitor: Any?
    private var outsideMouseMonitor: Any?
    private var windowVisibilityObservation: NSKeyValueObservation?
    private var outsideMonitorGeneration: UUID?
    private var trackingMenus: Set<ObjectIdentifier> = []
    private var consumeGridMouseUp = false
    private var surfaceTimer: Timer?
    private struct InteractionState: Equatable {
        let layout: BoardLayout
        let environment: EnvironmentSnapshot
        let overlay: OverlayRoute?
        let stepPreview: LayoutStepPreview?
        let month: DateOnly
        let selectedDay: DateOnly
        let mode: DisplayMode
        init(_ state: PresentationState) {
            layout = state.snapshot.board.layout; environment = state.snapshot.environment
            overlay = state.view.overlay; stepPreview = state.view.stepPreview
            month = state.view.month; selectedDay = state.view.selectedDay; mode = state.view.mode
        }
    }
    private struct SurfaceContact {
        let view: NativeCanvasView
        let start: CGPoint
        let state: InteractionState
    }
    private var surfaceContact: SurfaceContact?
    private var lastInteractionState: InteractionState?
    private var consumeSurfaceMouseUp = false
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
        calendarView = CalendarGridView(context: context); workspace = BoardWorkspaceView(focus: focus); feedback = BoardFeedbackView(focus: focus)
        super.init(frame: .zero)
        lastInteractionState = InteractionState(context.presentation.state)
        identifier = NSUserInterfaceItemIdentifier("board.root"); setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityIdentifier("board.root"); setAccessibilityLabel("Hannun Calendar")
        proxy.target = self; context.kit.panelMenus.target = self
        viewport.drawsBackground = false; viewport.verticalScrollElasticity = .none; viewport.horizontalScrollElasticity = .none; viewport.hasHorizontalScroller = true; viewport.hasVerticalScroller = true; viewport.autohidesScrollers = true; viewport.scrollerStyle = .overlay
        viewport.documentView = workspace; addSubview(viewport); gridDots.isHidden = true; workspace.addSubview(gridDots); workspace.addSubview(calendarView)
        parking.isHidden = true; workspace.addSubview(parking)
        for slot in SlotID.allCases {
            let host = BoardSlotHostView(slot: slot, focus: focus); slotHosts[slot] = host; workspace.addSubview(host)
        }
        workspace.promoteFeedbackSurfaces()
        feedback.wantsLayer = true; feedback.layer?.cornerRadius = NativeRadius.button; feedback.layer?.masksToBounds = true
        addSubview(feedback); feedback.isHidden = true
        feedback.onAction = { [weak presentation] id in
            if id == "action.undo" { presentation?.send(.undo) }
            if id == "action.dismissMigration" { presentation?.send(.edit(.layout(.dismissMigrationNotice), undoable: false)) }
        }
        feedback.onShortcut = { [weak self] in self?.handleShortcut($0) ?? false }
        calendarView.toggleLayoutEditing = { [weak self] in self?.toggleGridEditing() }
        gridGhost.isHidden = true; workspace.addSubview(gridGhost)
        calendarView.boardShortcut = { [weak self] in self?.handleShortcut($0) ?? false }
        workspace.onShortcut = { [weak self] in self?.handleShortcut($0) ?? false }
        workspace.backgroundHit = { [weak self] point in self?.isEmptyBackground(point) ?? false }
        workspace.backgroundAvailable = { [weak self] in
            guard let self else { return false }
            return !self.lifetime.isDisposed && self.composingEditor == nil && self.activeOverlay == nil
        }
        workspace.backgroundEdit = { [weak self] in
            guard let self, !self.lifetime.isDisposed, self.composingEditor == nil, self.activeOverlay == nil else { return false }
            self.toggleGridEditing(); return true
        }
        configureSurfaceHolds(in: calendarView)
        workspace.onAdjust = { [weak self] id, amount in if let split = BoardWorkspaceView.split(id) { self?.adjust(split, amount: amount) } }
        workspace.beginSplit = { [weak self] split, position in self?.begin(split, position: position) }
        workspace.moveSplit = { [weak self] in self?.move(position: $0) }
        workspace.endSplit = { [weak self] in self?.finish(cancel: $0) }
        context.focus.onFocusChange = { [weak self] _ in self?.updateSlotFocus() }
        viewport.contentView.postsBoundsChangedNotifications = true
        inputObservations.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: viewport.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let bounds = self.viewport.contentView.bounds
                guard self.observedViewportBounds != bounds else { return }
                self.observedViewportBounds = bounds
                self.workspace.cancelBackgroundContact(); self.cancelSurfaceHold(); if self.directMoveContact?.active == false { self.cancelDirectMove() }; if self.editingGrid { self.updateGridDots(); self.layoutFeedback() }
            }
        })
        for name in [NSText.didChangeNotification, NSText.didEndEditingNotification, NSTextView.didChangeSelectionNotification, NSControl.textDidChangeNotification, NSControl.textDidEndEditingNotification] {
            inputObservations.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleDeferredOverlayAction() }
            })
        }
        for name in [NSMenu.didBeginTrackingNotification, NSMenu.didEndTrackingNotification] {
            inputObservations.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let menu = notification.object as? NSMenu else { return }
                let identity = ObjectIdentifier(menu), began = notification.name == NSMenu.didBeginTrackingNotification
                MainActor.assumeIsolated {
                    if began { self?.trackingMenus.insert(identity) }
                    else { self?.trackingMenus.remove(identity) }
                }
            })
        }
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification, NSWindow.didChangeScreenNotification, NSWindow.didChangeBackingPropertiesNotification] {
            inputObservations.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let source = (notification.object as? NSWindow).map(ObjectIdentifier.init), closing = notification.name == NSWindow.willCloseNotification
                MainActor.assumeIsolated {
                    guard let self, let source, self.window.map(ObjectIdentifier.init) == source else { return }
                    if closing { self.stopOutsideMouseMonitor(); self.clearGridEditingBorders() }
                    self.workspace.cancelSplit(); self.workspace.cancelBackgroundContact(); self.cancelSurfaceHold(); self.consumeSurfaceMouseUp = false; self.cancelDirectMove(); self.cancelGridInteraction()
                }
            })
        }
        inputObservations.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.workspace.cancelBackgroundContact(); self?.cancelSurfaceHold(); self?.consumeSurfaceMouseUp = false }
        })
        lifetime.own(presentation.subscribe { [weak self] in self?.receive($0) })
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowVisibilityObservation?.invalidate(); windowVisibilityObservation = nil
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }; mouseMonitor = nil
        guard let window, !lifetime.isDisposed else { suspendHiddenBoard(); return }
        windowVisibilityObservation = window.observe(\.isVisible, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.syncBoardVisibility() }
        }
        syncBoardVisibility()
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .scrollWheel, .keyDown]) { [weak self] event in
            guard let self else { return event }; return self.filterMouseEvent(event)
        }
    }
    override func viewDidHide() { super.viewDidHide(); syncBoardVisibility() }
    override func viewDidUnhide() { super.viewDidUnhide(); syncBoardVisibility() }
    private var boardIsVisible: Bool { !lifetime.isDisposed && window?.isVisible == true && !isHiddenOrHasHiddenAncestor }
    private func syncBoardVisibility() {
        guard boardIsVisible else { suspendHiddenBoard(); return }
        if editingGrid { startOutsideMouseMonitor(); updateGridEditingBorders() }
    }
    private func suspendHiddenBoard() {
        stopOutsideMouseMonitor(); clearGridEditingBorders(); clearGridExitViews()
        for handle in gridHandles { if let layer = handle.layer { NativeMotion.stop(layer) } }
        workspace.cancelSplit(); workspace.cancelBackgroundContact(); cancelSurfaceHold(); consumeSurfaceMouseUp = false
        cancelDirectMove(); cancelGridInteraction()
    }
    override func layout() {
        super.layout(); guard !lifetime.isDisposed else { return }
        viewport.frame = bounds
        observedViewportBounds = viewport.contentView.bounds
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
        if !change.domains.isDisjoint(with: [.board, .environment, .view]) {
            let state = InteractionState(context.presentation.state)
            if lastInteractionState != state { workspace.cancelBackgroundContact(); cancelDirectMove() }
            if let contact = surfaceContact, contact.state != state { cancelSurfaceHold() }
            lastInteractionState = state
        }
        if let interaction = gridInteraction, !change.domains.isDisjoint(with: [.board]), context.presentation.state.snapshot.board.layout != interaction.layout { cancelGridInteraction() }
        if drag != nil, context.presentation.state.view.stepPreview == nil { workspace.cancelSplit() }
        if !change.domains.isDisjoint(with: [.board, .environment]) {
            let rejectedSlotEdit = change.domains.contains(.error) && context.presentation.state.lastError?.committed == .no && change.affected.contains { if case .slot = $0 { return true }; return false }
            applyLayout(rollbackSlots: rejectedSlotEdit)
        }
        if change.domains.contains(.view) { syncOverlay() }
        if !change.domains.isDisjoint(with: [.toast, .error, .environment, .board]) { updateFeedback() }
        if change.domains.contains(.board) { updateGridTool() }
    }
    private func applyLayout(rollbackSlots: Bool = false) {
        let viewportSize = bounds.size
        if let lastViewport, lastViewport != viewportSize { workspace.cancelBackgroundContact(); cancelSurfaceHold(); cancelDirectMove() }
        if let interaction = gridInteraction, interaction.viewport != viewportSize { cancelGridInteraction() }
        if let drag, drag.viewport != LayoutViewport(width: viewportSize.width, height: viewportSize.height) {
            workspace.cancelSplit(); return
        }
        let state = context.presentation.state, current = state.snapshot.board.layout
        let structural = current != lastLayout || lastViewport != viewportSize || lastLanguage != state.snapshot.board.settings.language || layoutFailure != nil
        let theme = NativeTheme(appearance: state.snapshot.environment.resolvedAppearance)
        context.kit.theme = theme
        workspace.reduceMotion = state.snapshot.environment.reduceMotion
        if workspace.reduceMotion {
            clearGridExitViews(); for handle in gridHandles { if let layer = handle.layer { NativeMotion.stop(layer) } }
            if ghostSettleGeneration != nil { ghostSettleGeneration = nil; gridGhost.layer?.removeAnimation(forKey: "grid.settle"); gridGhost.isHidden = true }
        }
        if !structural { updateGridEditingBorders() }
        calendarView.showsEditingBorder = editingGrid
        for controller in controllers.values { (controller.view as? PanelContainerView)?.showsEditingBorder = editingGrid }
        workspace.backgroundMenuTitle = context.text("grid.edit")
        workspace.setAccessibilityLabel(context.text("grid.background"))
        workspace.setAccessibilityHelp(context.text("grid.background_help"))
        workspace.setAccessibilityValue(context.text(editingGrid ? "grid.editing_state" : "grid.browsing_state"))
        gridTool?.popover.animates = !state.snapshot.environment.reduceMotion
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

        if layoutFailure != nil { layoutFailure = nil; updateFeedback() }
        let before = lastLayout
        if let before {
            restoredPanelNotice = SlotID.allCases.contains { slot in
                guard before.hiddenSlots.contains(slot.rawValue), !current.hiddenSlots.contains(slot.rawValue), let item = GridItemID(rawValue: slot.rawValue) else { return false }
                return before.placements[item] != current.placements[item]
            }
        }
        lastLayout = current; lastViewport = viewportSize; layoutCount += 1
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
            (controller.view as? PanelContainerView)?.showsEditingBorder = editingGrid
            let shape: PanelShape = frame.width >= 600 ? .wide : .rail
            let step: PanelSizeStep = frame.height < 160 ? .tiny : frame.height < 240 ? .small : frame.height < 360 ? .regular : .large
            let widthStep: PanelSizeStep = frame.width < 350 ? .tiny : frame.width < 450 ? .small : frame.width < 600 ? .regular : .large
            let regions = NativePanelStepMetrics(panel: panel, shape: shape, step: step).regions(in: CGRect(origin: .zero, size: frame.size))
            let exclusions = editingGrid ? [CGRect(x: frame.width - 32, y: frame.height - 32, width: 28, height: 28)] : []
            controller.setPlacement(PanelPlacement(slot: slot, shape: shape, heightStep: step, railWidthStep: widthStep, frame: frame, headerRect: regions.headerRect, contentRect: regions.contentRect, editExclusions: exclusions))
            configureSurfaceHolds(in: controller.view)
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
        updateSlotFocus(); updateGridDots(); rebuildGridHandles(); updateGridEditingBorders()
        if let before, before.hiddenSlots != current.hiddenSlots, !editorHost.textView.hasMarkedText() { requestNotesFlush() }
        if let activeRoute { activeOverlay?.present(resolved(activeRoute)) }
    }
    private func toggleGridEditing() {
        guard composingEditor == nil else { return }
        cancelSurfaceHold()
        if editingGrid { for menu in menus.values { menu.dispose() }; menus.removeAll() }
        cancelDirectMove(); cancelGridInteraction(); gridTool?.close(); gridTool = nil
        if editingGrid { fadeGridHandlesOut() } else { clearGridExitViews() }
        editingGrid.toggle(); workspace.backgroundEditing = editingGrid; calendarView.layoutEditing = editingGrid
        if editingGrid { startOutsideMouseMonitor() } else { stopOutsideMouseMonitor() }
        gridDots.isHidden = !editingGrid; lastLayout = nil; applyLayout(); updateGridDots(); rebuildGridHandles(); layoutFeedback()
        if editingGrid && boardIsVisible && !workspace.reduceMotion {
            for handle in gridHandles { if let layer = handle.layer { NativeMotion.apply(.popover, to: layer, reduceMotion: false) } }
        }
    }
    private func startOutsideMouseMonitor() {
        guard editingGrid, boardIsVisible, outsideMouseMonitor == nil else { return }
        let generation = UUID(); outsideMonitorGeneration = generation
        outsideMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.outsideMonitorGeneration == generation else { return }
                self.handleOutsideMouseDown()
            }
        }
        if outsideMouseMonitor == nil { outsideMonitorGeneration = nil }
    }
    private func stopOutsideMouseMonitor() {
        outsideMonitorGeneration = nil
        if let monitor = outsideMouseMonitor { NSEvent.removeMonitor(monitor) }
        outsideMouseMonitor = nil
    }
    /// AppKit's global monitor observes events sent to other apps and never consumes them.
    func handleOutsideMouseDown() {
        guard editingGrid, boardIsVisible, composingEditor == nil,
              activeOverlay == nil, gridInteraction == nil, trackingMenus.isEmpty,
              gridTool?.popover.isShown != true else { return }
        if case .toggleGrid? = deferredOverlayAction { deferredOverlayAction = nil }
        toggleGridEditing()
    }
    private func updateGridEditingBorders() {
        guard editingGrid, boardIsVisible, let parent = workspace.layer else { clearGridEditingBorders(); return }
        let layout = context.presentation.state.snapshot.board.layout
        let visible = GridItemID.allCases.filter { layout.placements[$0] != nil && ($0 == .calendar || !layout.hiddenSlots.contains($0.rawValue)) }
        for (id, layer) in gridEditingBorders where !visible.contains(id) { layer.removeFromSuperlayer(); gridEditingBorders.removeValue(forKey: id) }
        for id in visible {
            guard let rect = layout.placements[id] else { continue }
            let frame = geometry.frame(for: rect)
            let layer = gridEditingBorders[id] ?? CAShapeLayer()
            if layer.superlayer == nil { layer.name = "grid.edit.border"; parent.addSublayer(layer); gridEditingBorders[id] = layer }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layer.zPosition = 1; layer.frame = frame; layer.path = CGPath(roundedRect: CGRect(origin: .zero, size: frame.size).insetBy(dx: 1, dy: 1), cornerWidth: NativeRadius.panel, cornerHeight: NativeRadius.panel, transform: nil)
            layer.fillColor = NSColor.clear.cgColor; layer.strokeColor = context.kit.theme.color(.accentBlue).withAlphaComponent(0.9).cgColor; layer.lineWidth = 2
            layer.removeAllAnimations(); CATransaction.commit()
        }
    }
    private func clearGridEditingBorders() {
        for layer in gridEditingBorders.values { layer.removeAllAnimations(); layer.removeFromSuperlayer() }
        gridEditingBorders.removeAll()
    }
    private func clearGridExitViews() {
        for view in gridExitViews { view.layer?.removeAllAnimations(); view.removeFromSuperview() }
        gridExitViews.removeAll()
    }
    private func fadeGridHandlesOut() {
        clearGridExitViews()
        guard boardIsVisible, !workspace.reduceMotion else { return }
        for handle in gridHandles {
            guard let bitmap = handle.bitmapImageRepForCachingDisplay(in: handle.bounds) else { continue }
            handle.cacheDisplay(in: handle.bounds, to: bitmap)
            let image = NSImage(size: handle.bounds.size); image.addRepresentation(bitmap)
            let view = GridHandleExitView(frame: handle.frame, image: image)
            workspace.addSubview(view, positioned: .above, relativeTo: nil); gridExitViews.append(view)
            guard let layer = view.layer else { continue }
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = handle.layer?.presentation()?.opacity ?? 1; animation.toValue = 0
            animation.duration = MotionDuration.fast; animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            CATransaction.begin(); CATransaction.setDisableActions(true); layer.opacity = 0; CATransaction.commit()
            layer.add(animation, forKey: "grid.exit")
        }
        let departing = gridExitViews
        DispatchQueue.main.asyncAfter(deadline: .now() + MotionDuration.fast) { [weak self] in
            MainActor.assumeIsolated {
                for view in departing { view.layer?.removeAllAnimations(); view.removeFromSuperview() }
                self?.gridExitViews.removeAll { view in departing.contains { $0 === view } }
            }
        }
    }
    private func isEmptyBackground(_ point: CGPoint) -> Bool {
        guard !lifetime.isDisposed, composingEditor == nil, activeOverlay == nil, workspace.visibleRect.contains(point) else { return false }
        let local = workspace.convert(point, to: self)
        if !feedback.isHidden && feedback.frame.contains(local) { return false }
        if calendarView.frame.contains(point) || slotHosts.values.contains(where: { !$0.isHidden && $0.frame.contains(point) }) { return false }
        return hitTest(superview.map { convert(local, to: $0) } ?? local) === workspace
    }
    private func configureSurfaceHolds(in view: NSView) {
        if let canvas = view as? NativeCanvasView {
            canvas.acceptsSurfaceFirstMouse = { [weak self, weak canvas] event in
                guard let self, let canvas else { return false }
                return self.isSafeSurface(canvas, at: event.locationInWindow) || self.directMoveItem(at: event.locationInWindow) != nil
            }
        }
        for child in view.subviews { configureSurfaceHolds(in: child) }
    }
    /// Only native, noninteractive painted surfaces may start direct movement.
    private func directMoveItem(at windowPoint: CGPoint, allowComposing: Bool = false) -> GridItemID? {
        guard editingGrid, !lifetime.isDisposed, window != nil, (allowComposing || composingEditor == nil), activeOverlay == nil,
              trackingMenus.isEmpty, gridTool?.popover.isShown != true, gridInteraction == nil else { return nil }
        let point = workspace.convert(windowPoint, from: nil)
        guard workspace.visibleRect.contains(point) else { return nil }
        let rootPoint = convert(windowPoint, from: nil)
        guard let target = hitTest(superview.map { convert(rootPoint, to: $0) } ?? rootPoint) as? NativeCanvasView,
              target !== workspace, target.visibleRect.contains(target.convert(windowPoint, from: nil)) else { return nil }
        var ancestor: NSView? = target
        while let view = ancestor, view !== workspace {
            if let canvas = view as? NativeCanvasView {
                let local = canvas.convert(windowPoint, from: nil)
                if canvas.items.contains(where: { $0.isInteractive && ($0.panelHeader?.contains(local) ?? $0.hitRect.contains(local)) }) { return nil }
            }
            if view is NSTextView || view is NSControl || view is NSScroller { return nil }
            ancestor = view.superview
        }
        if target === calendarView {
            let local = calendarView.convert(windowPoint, from: nil)
            guard local.y < CalendarMetrics.toolbarPadding + NativeSize.toolbarHeight,
                  !calendarView.cellRects.values.contains(where: { $0.contains(local) }) else { return nil }
            return .calendar
        }
        for (slot, host) in slotHosts where !host.isHidden && host.frame.contains(point) {
            if target === host || target.isDescendant(of: host) { return GridItemID(rawValue: slot.rawValue) }
        }
        return nil
    }
    private func cancelDirectMove() {
        guard let contact = directMoveContact else { return }
        directMoveContact = nil
        if contact.active { cancelGridInteraction() }
    }
    private func filterDirectMove(_ event: NSEvent) -> NSEvent? {
        if event.type == .leftMouseDown {
            cancelDirectMove()
            guard event.clickCount == 1, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                  let item = directMoveItem(at: event.locationInWindow) else { return event }
            directMoveContact = DirectMoveContact(item: item, start: workspace.convert(event.locationInWindow, from: nil))
            return event
        }
        guard var contact = directMoveContact else { return event }
        if event.type == .leftMouseDragged {
            let point = workspace.convert(event.locationInWindow, from: nil)
            if !contact.active {
                guard hypot(point.x - contact.start.x, point.y - contact.start.y) >= 4,
                      let handle = gridHandles.first(where: { $0.item == contact.item && !$0.resizing }) else { return event }
                beginGrid(handle, point: contact.start, focusHandle: false)
                guard gridInteraction != nil else { cancelDirectMove(); return event }
                contact.active = true; directMoveContact = contact
            }
            moveGrid(point: point); return nil
        }
        if event.type == .leftMouseUp {
            directMoveContact = nil
            guard contact.active else { return event }
            finishGrid(point: workspace.convert(event.locationInWindow, from: nil), handle: nil); return nil
        }
        if [.rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown].contains(event.type) { cancelDirectMove() }
        return event
    }
    private func isSafeSurface(_ canvas: NativeCanvasView, at windowPoint: CGPoint, allowComposing: Bool = false) -> Bool {
        guard !lifetime.isDisposed, !editingGrid, (allowComposing || composingEditor == nil), activeOverlay == nil,
              canvas.window === window else { return false }
        let rootPoint = convert(windowPoint, from: nil)
        guard hitTest(superview.map { convert(rootPoint, to: $0) } ?? rootPoint) === canvas else { return false }
        let point = canvas.convert(windowPoint, from: nil)
        guard canvas.visibleRect.contains(point), canvas.item(at: point) == nil,
              !canvas.items.contains(where: { $0.isInteractive && $0.hitRect.contains(point) }) else { return false }
        if canvas === calendarView {
            return point.y < CalendarMetrics.toolbarPadding + NativeSize.toolbarHeight &&
                !calendarView.cellRects.values.contains(where: { $0.contains(point) })
        }
        var ancestor = canvas.superview
        var inSlot = false
        while let view = ancestor {
            if view is BoardSlotHostView { inSlot = true; break }
            ancestor = view.superview
        }
        // Painted noninteractive content is still panel surface. Interactive hit
        // regions and native input views were excluded above.
        return inSlot
    }
    private func cancelSurfaceHold() {
        surfaceTimer?.invalidate(); surfaceTimer = nil; surfaceContact = nil
    }
    private func beginSurfaceHold(_ canvas: NativeCanvasView, event: NSEvent) {
        guard event.clickCount == 1, isSafeSurface(canvas, at: event.locationInWindow) else { return }
        surfaceContact = SurfaceContact(view: canvas, start: event.locationInWindow, state: InteractionState(context.presentation.state))
        let timer = Timer(timeInterval: 0.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let contact = self.surfaceContact,
                      self.isSafeSurface(contact.view, at: contact.start) else { self?.cancelSurfaceHold(); return }
                self.cancelSurfaceHold(); self.consumeSurfaceMouseUp = true; self.toggleGridEditing()
            }
        }
        surfaceTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func updateGridDots() {
        let layout = context.presentation.state.snapshot.board.layout
        let visible = workspace.visibleRect.intersection(workspace.bounds)
        gridDots.profile = geometry.gridProfile; gridDots.pitchY = geometry.pitchY; gridDots.frame = visible; gridDots.bounds = visible
        gridDots.occupied = layout.placements.filter { $0.key == .calendar || !layout.hiddenSlots.contains($0.key.rawValue) }.map(\.value)
        gridDots.theme = NativeTheme(appearance: context.presentation.state.snapshot.environment.resolvedAppearance); gridDots.needsDisplay = true
    }
    private func removeGridHandles() {
        for handle in gridHandles { if let layer = handle.layer { NativeMotion.stop(layer) }; handle.removeFromSuperview() }
        gridHandles.removeAll(); context.focus.unregister(owner: self)
    }
    private func rebuildGridHandles() {
        guard editingGrid else { removeGridHandles(); return }
        var unused = gridHandles
        var nextHandles: [GridHandleView] = []
        let layout = context.presentation.state.snapshot.board.layout
        let theme = NativeTheme(appearance: context.presentation.state.snapshot.environment.resolvedAppearance)
        for item in GridItemID.allCases {
            guard let rect = layout.placements[item], item == .calendar || !layout.hiddenSlots.contains(item.rawValue) else { continue }
            let frame = geometry.frame(for: rect)
            let name = item == .calendar ? context.text("a11y.calendar") : layout.slots[item.rawValue].map { context.text(Self.panelKey($0)) } ?? item.rawValue
            for resizing in [false, true] {
                let handle = unused.first(where: { $0.item == item && $0.resizing == resizing }) ?? GridHandleView(item: item, resizing: resizing)
                unused.removeAll { $0 === handle }; nextHandles.append(handle); handle.theme = theme
                handle.frame = resizing ? CGRect(x: frame.maxX - 32, y: frame.maxY - 32, width: 28, height: 28) : CGRect(x: frame.minX + 4, y: frame.minY + 4, width: 28, height: 28)
                handle.setAccessibilityLabel(name + ", " + context.text(resizing ? "grid.resize" : "grid.move"))
                handle.setAccessibilityHelp(context.text("grid.help"))
                handle.setAccessibilityValue(context.text("grid.position", values: ["column": String(rect.column + 1), "row": String(rect.row + 1), "width": String(rect.width), "height": String(rect.height)]))
                handle.shouldBegin = { [weak self] in self?.composingEditor == nil }
                handle.onDown = { [weak self] handle, point in self?.beginGrid(handle, point: point) }
                handle.onDrag = { [weak self] point in self?.moveGrid(point: point) }
                handle.onUp = { [weak self, weak handle] point in self?.finishGrid(point: point, handle: handle) }
                handle.onClick = { [weak self] handle in self?.showGridMenu(handle) }
                handle.onResign = { [weak self] in self?.cancelGridInteraction() }
                handle.onKey = { [weak self] handle, event in self?.gridKey(handle, event: event) ?? false }
                if handle.superview !== workspace { workspace.addSubview(handle, positioned: .above, relativeTo: nil) }
            }
        }
        for handle in unused { handle.removeFromSuperview() }
        gridHandles = nextHandles
        context.focus.register(owner: self, targets: nextHandles.map { handle in
            let id = FocusID(handle.identifier!.rawValue)
            var target = FocusCoordinator.Target(id: id, rect: handle.frame, activate: { [weak self, weak handle] in if let handle { self?.showGridMenu(handle) } })
            target.reveal = { [weak handle] in guard let handle else { return }; handle.window?.makeFirstResponder(handle); handle.scrollToVisible(handle.bounds) }
            target.handleKey = { [weak self, weak handle] event in guard let self, let handle else { return false }; return self.gridKey(handle, event: event) }
            return target
        })
    }
    private func beginGrid(_ handle: GridHandleView, point: CGPoint, focusHandle: Bool = true) {
        cancelGridInteraction()
        if focusHandle, let id = handle.identifier?.rawValue { context.focus.focus(FocusID(id), keyboard: window?.firstResponder === handle) }
        let layout = context.presentation.state.snapshot.board.layout
        guard let rect = layout.placements[handle.item] else { return }
        gridInteraction = GridInteraction(item: handle.item, resizing: handle.resizing, original: rect, candidate: rect, start: point, layout: layout, viewport: bounds.size)
    }
    // Pointer, keyboard, and popover commands must all enforce the same viewport policy.
    func gridCandidateRejection(item: GridItemID, original: GridRect, candidate: GridRect, layout: BoardLayout) -> String? {
        let reason: String?
        do {
            try GridResolver.validate(item, rect: candidate, in: layout)
            if hasNormalGridViewport {
                var proposed = layout; proposed.placements[item] = candidate
                let projected = BoardLayoutGeometry.make(viewport: bounds.size, layout: proposed)
                let exceeds: Bool
                if geometry.contentSize.height > bounds.height + 0.01 {
                    let originalBottom = geometry.frame(for: original).maxY
                    exceeds = originalBottom > bounds.height + 0.01
                        ? candidate.row + candidate.height > original.row + original.height
                        : projected.frame(for: candidate).maxY > bounds.height + 0.01
                } else { exceeds = projected.contentSize.height > bounds.height + 0.01 }
                reason = exceeds ? context.text("grid.bounds") : nil
            } else { reason = nil }
        }
        catch let error as GridValidationError { reason = context.text(error == .minimum ? "grid.minimum" : error == .collision ? "grid.collision" : "grid.bounds") }
        catch { reason = context.text("grid.bounds") }
        return reason
    }
    private func updateGridCandidate(_ rect: GridRect, pointerDelta: CGPoint? = nil) {
        guard var interaction = gridInteraction else { return }
        let changed = interaction.candidate != rect
        interaction.candidate = rect
        let reason = gridCandidateRejection(item: interaction.item, original: interaction.original, candidate: rect, layout: interaction.layout)
        interaction.valid = reason == nil; gridInteraction = interaction
        var candidateFrame = geometry.frame(for: rect)
        if let pointerDelta {
            let originFrame = geometry.frame(for: interaction.original)
            if interaction.resizing {
                let minimum = GridRect(column: interaction.original.column, row: interaction.original.row, width: interaction.item == .calendar ? 12 : 6, height: interaction.item == .calendar ? 13 : 4)
                let minFrame = geometry.frame(for: minimum)
                candidateFrame = CGRect(x: originFrame.minX, y: originFrame.minY, width: max(minFrame.width, originFrame.width + pointerDelta.x), height: max(minFrame.height, originFrame.height + pointerDelta.y))
            } else { candidateFrame = originFrame.offsetBy(dx: pointerDelta.x, dy: pointerDelta.y) }
        }
        if let handle = gridHandles.first(where: { $0.item == interaction.item && $0.resizing == interaction.resizing }) {
            handle.frame = interaction.resizing ? CGRect(x: candidateFrame.maxX - 32, y: candidateFrame.maxY - 32, width: 28, height: 28) : CGRect(x: candidateFrame.minX + 4, y: candidateFrame.minY + 4, width: 28, height: 28)
            let value = context.text("grid.position", values: ["column": String(rect.column + 1), "row": String(rect.row + 1), "width": String(rect.width), "height": String(rect.height)])
            handle.setAccessibilityValue(value + (reason.map { " · " + $0 } ?? ""))
            if changed { NSAccessibility.post(element: handle, notification: .valueChanged) }
            if editingGrid && !feedback.isHidden { layoutFeedback() }
        }
        let requiredRows = min(GridGeometryProfile.rows, max(0, rect.row + rect.height + 4))
        let requiredHeight = max(geometry.contentSize.height, CGFloat(2 * GridGeometryProfile.padding - GridGeometryProfile.gap) + CGFloat(requiredRows) * geometry.pitchY)
        if !hasNormalGridViewport && workspace.frame.height < requiredHeight { workspace.setFrameSize(CGSize(width: workspace.frame.width, height: requiredHeight)); updateGridDots() }
        gridGhost.frame = candidateFrame; gridGhost.valid = interaction.valid
        gridGhost.label = context.text("grid.invalid"); gridGhost.theme = NativeTheme(appearance: context.presentation.state.snapshot.environment.resolvedAppearance)
        gridGhost.isHidden = false; workspace.addSubview(gridGhost, positioned: .above, relativeTo: nil)
    }
    private var hasNormalGridViewport: Bool {
        bounds.width >= CGFloat(2 * GridGeometryProfile.padding - GridGeometryProfile.gap + Double(GridGeometryProfile.columns) * 52) && bounds.height >= 600
    }
    private func moveGrid(point: CGPoint) {
        guard var interaction = gridInteraction else { return }
        let dx = point.x - interaction.start.x, dy = point.y - interaction.start.y
        if !interaction.active && hypot(dx, dy) < 4 { return }
        interaction.active = true; gridInteraction = interaction; gridPointer = point
        if gridScrollTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.scrollGridAtPointer() } }
            gridScrollTimer = timer; RunLoop.main.add(timer, forMode: .common)
        }
        guard let profile = geometry.gridProfile, geometry.pitchY > 0, let snapped = try? profile.snapDelta(x: Double(dx), y: Double(dy / geometry.pitchY) * profile.pitchY) else { cancelGridInteraction(); return }
        let x = snapped.column, y = snapped.row
        let original = interaction.original
        let candidate: GridRect
        if interaction.resizing {
            candidate = GridRect(column: original.column, row: original.row, width: min(GridGeometryProfile.columns - original.column, max(interaction.item == .calendar ? 12 : 6, original.width + x)), height: min(GridGeometryProfile.rows - original.row, max(interaction.item == .calendar ? 13 : 4, original.height + y)))
        } else { candidate = GridRect(column: original.column + x, row: original.row + y, width: original.width, height: original.height) }
        updateGridCandidate(candidate, pointerDelta: CGPoint(x: dx, y: dy))
    }
    func scrollGridAtPointer() {
        guard gridInteraction?.active == true, let point = gridPointer else { return }
        let clip = viewport.contentView, visible = clip.bounds
        func velocity(_ position: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
            if position < low + 24 { return -4 * min(1, max(0, (low + 24 - position) / 24)) }
            if position > high - 24 { return 4 * min(1, max(0, (position - high + 24) / 24)) }
            return 0
        }
        let dx = velocity(point.x, visible.minX, visible.maxX), dy = velocity(point.y, visible.minY, visible.maxY)
        if !hasNormalGridViewport && dy > 0 && visible.maxY + geometry.pitchY > workspace.frame.height {
            let maxHeight = CGFloat(2 * GridGeometryProfile.padding - GridGeometryProfile.gap) + CGFloat(GridGeometryProfile.rows) * geometry.pitchY
            workspace.setFrameSize(CGSize(width: workspace.frame.width, height: min(maxHeight, workspace.frame.height + geometry.pitchY))); updateGridDots()
        }
        let origin = CGPoint(x: min(max(0, workspace.frame.width - visible.width), max(0, visible.minX + dx)), y: min(max(0, workspace.frame.height - visible.height), max(0, visible.minY + dy)))
        guard origin != visible.origin else { return }
        clip.scroll(to: origin); viewport.reflectScrolledClipView(clip)
        moveGrid(point: CGPoint(x: point.x + origin.x - visible.minX, y: point.y + origin.y - visible.minY))
    }
    private func finishGrid(point: CGPoint, handle: GridHandleView?) {
        guard let interaction = gridInteraction else { return }
        if !interaction.active { cancelGridInteraction(); if let handle { showGridMenu(handle) }; return }
        moveGrid(point: point)
        guard let final = gridInteraction else { return }
        let previewFrame = gridGhost.frame
        cancelGridInteraction()
        if final.valid && final.candidate != final.original {
            context.presentation.send(.edit(.layout(.place(item: final.item, rect: final.candidate)), undoable: true))
        }
        if final.valid && context.presentation.state.snapshot.board.layout.placements[final.item] == final.candidate {
            settleGridGhost(from: previewFrame, to: geometry.frame(for: final.candidate))
        }
    }
    private func settleGridGhost(from: CGRect, to: CGRect) {
        guard boardIsVisible, !workspace.reduceMotion, from != to, let layer = gridGhost.layer else { return }
        gridGhost.frame = from; gridGhost.isHidden = false
        let startPosition = layer.position, startBounds = layer.bounds
        gridGhost.frame = to
        let position = CABasicAnimation(keyPath: "position"); position.fromValue = NSValue(point: startPosition); position.toValue = NSValue(point: layer.position)
        let bounds = CABasicAnimation(keyPath: "bounds"); bounds.fromValue = NSValue(rect: startBounds); bounds.toValue = NSValue(rect: layer.bounds)
        let animation = CAAnimationGroup(); animation.animations = [position, bounds]; animation.duration = MotionDuration.fast
        animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
        let generation = UUID(); ghostSettleGeneration = generation; layer.add(animation, forKey: "grid.settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + MotionDuration.fast) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.ghostSettleGeneration == generation else { return }
                self.ghostSettleGeneration = nil; self.gridGhost.layer?.removeAnimation(forKey: "grid.settle"); self.gridGhost.isHidden = true
            }
        }
    }
    private func cancelGridInteraction() {
        ghostSettleGeneration = nil; gridGhost.layer?.removeAnimation(forKey: "grid.settle")
        if let interaction = gridInteraction,
           let handle = gridHandles.first(where: { $0.item == interaction.item && $0.resizing == interaction.resizing }),
           let rect = context.presentation.state.snapshot.board.layout.placements[interaction.item] {
            let frame = geometry.frame(for: rect)
            handle.frame = interaction.resizing ? CGRect(x: frame.maxX - 32, y: frame.maxY - 32, width: 28, height: 28) : CGRect(x: frame.minX + 4, y: frame.minY + 4, width: 28, height: 28)
            let value = context.text("grid.position", values: ["column": String(rect.column + 1), "row": String(rect.row + 1), "width": String(rect.width), "height": String(rect.height)])
            handle.setAccessibilityValue(value); NSAccessibility.post(element: handle, notification: .valueChanged)
        }
        gridInteraction = nil; gridGhost.isHidden = true; gridScrollTimer?.invalidate(); gridScrollTimer = nil; gridPointer = nil
        if workspace.frame.size != geometry.contentSize, geometry.contentSize != .zero { workspace.setFrameSize(geometry.contentSize); updateGridDots() }
        if editingGrid, boardIsVisible { updateGridEditingBorders() }
    }
    private func gridKey(_ handle: GridHandleView, event: NSEvent) -> Bool {
        if event.keyCode == 48 { cancelGridInteraction(); context.focus.move(forward: !event.modifierFlags.contains(.shift)); return true }
        if event.keyCode == 53 { cancelGridInteraction(); return true }
        if event.keyCode == 49 { cancelGridInteraction(); showGridMenu(handle); return true }
        if event.keyCode == 36 {
            if let interaction = gridInteraction, interaction.item == handle.item && interaction.resizing == handle.resizing {
                cancelGridInteraction()
                if interaction.valid && interaction.candidate != interaction.original { context.presentation.send(.edit(.layout(.place(item: interaction.item, rect: interaction.candidate)), undoable: true)) }
            } else { beginGrid(handle, point: .zero); if let interaction = gridInteraction { updateGridCandidate(interaction.original) } }
            return true
        }
        guard var interaction = gridInteraction, interaction.item == handle.item, interaction.resizing == handle.resizing else { return false }
        let dx = event.keyCode == 123 ? -1 : event.keyCode == 124 ? 1 : 0
        let dy = event.keyCode == 126 ? -1 : event.keyCode == 125 ? 1 : 0
        guard dx != 0 || dy != 0 else { return false }
        let r = interaction.candidate
        let candidate: GridRect
        if interaction.resizing {
            let minWidth = interaction.item == .calendar ? 12 : 6, minHeight = interaction.item == .calendar ? 13 : 4
            candidate = GridRect(column: r.column, row: r.row,
                                 width: min(GridGeometryProfile.columns - r.column, max(minWidth, r.width + dx)),
                                 height: min(GridGeometryProfile.rows - r.row, max(minHeight, r.height + dy)))
        } else { candidate = GridRect(column: r.column + dx, row: r.row + dy, width: r.width, height: r.height) }
        guard candidate != r else { return true }
        interaction.active = true; gridInteraction = interaction; updateGridCandidate(candidate); gridGhost.scrollToVisible(gridGhost.bounds); return true
    }
    private static let gridDirections: [(Int, Int)] = [(-1, 0), (1, 0), (0, -1), (0, 1)]
    private func gridToolCandidate(_ rect: GridRect, resizing: Bool, index: Int) -> GridRect {
        let (dx, dy) = Self.gridDirections[index]
        return resizing ? GridRect(column: rect.column, row: rect.row, width: rect.width + dx, height: rect.height + dy) : GridRect(column: rect.column + dx, row: rect.row + dy, width: rect.width, height: rect.height)
    }
    private func updateGridTool() {
        guard let handle = gridToolHandle, let tool = gridTool else { return }
        let layout = context.presentation.state.snapshot.board.layout
        guard let rect = layout.placements[handle.item] else { tool.close(); return }
        let keys = handle.resizing ? ["grid.narrower", "grid.wider", "grid.shorter", "grid.taller"] : ["grid.left", "grid.right", "grid.up", "grid.down"]
        let options: [(String, String?)] = keys.enumerated().map { index, key in
            let candidate = gridToolCandidate(rect, resizing: handle.resizing, index: index)
            return (context.text(key), gridCandidateRejection(item: handle.item, original: rect, candidate: candidate, layout: layout))
        }
        let position = context.text("grid.position", values: ["column": String(rect.column + 1), "row": String(rect.row + 1), "width": String(rect.width), "height": String(rect.height)])
        tool.update(title: (handle.accessibilityLabel() ?? "") + " · " + position, options: options)
    }
    private func showGridMenu(_ handle: GridHandleView) {
        guard handle.window != nil, composingEditor == nil else { return }
        gridTool?.close(); let tool = GridToolPopover(handle: handle); gridTool = tool; gridToolHandle = handle
        tool.popover.animates = !context.presentation.state.snapshot.environment.reduceMotion
        tool.choose = { [weak self, weak handle] index in
            guard let self, let handle, Self.gridDirections.indices.contains(index) else { return }
            let layout = self.context.presentation.state.snapshot.board.layout
            guard let rect = layout.placements[handle.item] else { return }
            let target = self.gridToolCandidate(rect, resizing: handle.resizing, index: index)
            guard self.gridCandidateRejection(item: handle.item, original: rect, candidate: target, layout: layout) == nil else { return }
            self.context.presentation.send(.edit(.layout(.place(item: handle.item, rect: target)), undoable: true))
            self.updateGridTool()
        }
        updateGridTool(); tool.show()
    }
    private func updateSlotFocus() {
        guard context.focus.keyboardFocus, let id = context.focus.focusedID?.rawValue else { workspace.slotFocusRect = nil; return }
        workspace.slotFocusRect = SlotID.allCases.first(where: { id == PanelHeaderGeometry.identifier(for: $0) }).flatMap { geometry.slots[$0] }
    }
    func select(panel: PanelID, in slot: SlotID) {
        guard !lifetime.isDisposed, context.presentation.state.snapshot.board.layout.slots[slot.rawValue] != panel else { return }
        context.presentation.send(.edit(.layout(.select(slot: slot, panel: panel)), undoable: true))
    }
    func panelMenu(for slot: SlotID) -> NSMenu? { editingGrid ? menu(for: slot) : nil }
    func menu(for slot: SlotID) -> NSMenu {
        guard editingGrid else { return NSMenu() }
        menus[slot]?.dispose()
        let assigned = context.presentation.state.snapshot.board.layout.slots[slot.rawValue]
        let entries = PanelID.allCases.map { NativeMenuEntry(id: "slot.\(slot.rawValue).select.\($0.rawValue)", title: context.text(Self.panelKey($0)), checked: $0 == assigned) }
        let wrapper = NativeMenu(items: entries) { [weak self] id in
            guard let self, self.editingGrid, let raw = id.split(separator: ".").last, let panel = PanelID(rawValue: String(raw)) else { return }; self.select(panel: panel, in: slot)
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
        if event.keyCode == 97, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
           !(window?.firstResponder is NSTextView), activeOverlay == nil, composingEditor == nil {
            window?.makeFirstResponder(workspace); return true
        }
        if event.keyCode == 53 {
            if gridInteraction != nil { cancelGridInteraction(); return true }
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
        guard !lifetime.isDisposed else { return event }
        if event.window !== window || [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown].contains(event.type) { workspace.cancelBackgroundContact(); cancelSurfaceHold() }
        guard event.window === window else {
            cancelDirectMove()
            if [.leftMouseUp, .rightMouseUp, .otherMouseUp].contains(event.type) {
                consumeSurfaceMouseUp = false
            }
            return event
        }
        if filterDirectMove(event) == nil { return nil }
        if event.type == .leftMouseUp, consumeSurfaceMouseUp { consumeSurfaceMouseUp = false; return nil }
        if event.type == .leftMouseUp { cancelSurfaceHold() }
        if event.type == .leftMouseDragged, let contact = surfaceContact,
           hypot(event.locationInWindow.x - contact.start.x, event.locationInWindow.y - contact.start.y) >= 4 || !isSafeSurface(contact.view, at: event.locationInWindow) { cancelSurfaceHold() }
        if event.type == .leftMouseUp && consumeGridMouseUp { consumeGridMouseUp = false; return nil }
        let point = convert(event.locationInWindow, from: nil)
        if event.type == .leftMouseDown, composingEditor != nil {
            let target = hitTest(superview.map { convert(point, to: $0) } ?? point)
            let isHandle = target is GridHandleView
            let calendarPoint = calendarView.convert(point, from: self)
            let isToggle = target === calendarView && calendarView.item(at: calendarPoint)?.id == "action.layout"
            let isBackground = target === workspace && activeOverlay == nil
            let isPanelHeader = (target as? NativeCanvasView).flatMap { canvas in canvas.item(at: canvas.convert(event.locationInWindow, from: nil))?.panelHeader } != nil
            let isHoldSurface = (target as? NativeCanvasView).map { $0 !== workspace && isSafeSurface($0, at: event.locationInWindow, allowComposing: true) } ?? false
            let isDirectSurface = directMoveItem(at: event.locationInWindow, allowComposing: true) != nil
            if isHandle || isToggle || isBackground || isPanelHeader || isHoldSurface || isDirectSurface {
                consumeGridMouseUp = true
                if isToggle { deferredOverlayAction = .toggleGrid }
                return nil
            }
        }
        guard event.type == .leftMouseDown || event.type == .rightMouseDown else { return event }
        if event.type == .leftMouseDown, activeOverlay == nil,
           let canvas = hitTest(superview.map { convert(point, to: $0) } ?? point) as? NativeCanvasView,
           canvas !== workspace { beginSurfaceHold(canvas, event: event) }
        guard let overlay = activeOverlay else { return event }
        guard bounds.contains(point) else { return event }
        let target = hitTest(superview.map { convert(point, to: $0) } ?? point)
        if let target, target === overlay.view || target.isDescendant(of: overlay.view) { return event }
        if composingEditor != nil { deferredOverlayAction = .dismissOutside; return nil }
        if event.type == .leftMouseDown, target === workspace { workspace.ignoreBackgroundDown(event) }
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
            case .toggleGrid: self.toggleGridEditing()
            }
        }
    }
    func route(_ request: BoardRoute) {
        guard !lifetime.isDisposed else { return }
        workspace.cancelBackgroundContact(); cancelDirectMove()
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
    // Hide routine completion feedback without retiring Presentation's checked Undo.
    // Unknown messages remain visible so warnings and actionable notices survive.
    private static let routineFeedbackKeys: Set<String> = [
        "success.label", "toast.event_saved", "toast.event_moved", "toast.event_moving",
        "toast.event_saving", "toast.event_added", "toast.project_deleted", "toast.dday_deleted",
        "toast.project_added", "toast.countdown_added", "toast.project_status", "toast.project_done",
        "toast.project_progress", "toast.project_target", "toast.project_linked", "toast.pinned",
        "toast.unpinned", "toast.selected", "toast.renamed", "toast.sub_deleted", "toast.todo_deleted",
        "toast.habit_deleted", "toast.undo_hint", "toast.undo_action"
    ]
    private func updateFeedback() {
        let state = context.presentation.state
        let key = String(describing: state.toast?.source) + "|" + (state.toast?.messageKey ?? "") + "|" + String(describing: state.toast?.values) + "|" + String(describing: state.toast?.undoable) + "|" + String(describing: state.lastError ?? layoutFailure ?? state.snapshot.storageWarning) + "|" + state.snapshot.board.settings.language.rawValue + state.snapshot.environment.resolvedAppearance.rawValue + String(state.snapshot.board.layout.migrationNoticePending) + String(restoredPanelNotice)
        guard feedbackKey != key else { return }; feedbackKey = key
        var items: [NativeRenderItem] = []
        feedback.theme = NativeTheme(appearance: state.snapshot.environment.resolvedAppearance)
        feedback.layer?.backgroundColor = feedback.theme.color(.toastBg).cgColor
        let error = state.lastError ?? layoutFailure ?? state.snapshot.storageWarning
        if let error {
            let messageKey: String
            if error.messageKey == "error.generic" {
                messageKey = switch error.code {
                case .calendarPermission: "error.calendar_permission"
                case .calendarUnavailable: "error.calendar_unavailable"
                default: error.messageKey
                }
            } else { messageKey = error.messageKey }
            var message = context.text(messageKey, values: error.values)
            // Presentation retains partial success while independent non-undoable
            // work settles. Preserve both messages without guessing error provenance.
            if let toast = state.toast, toast.messageKey == "error.partial_eventkit" {
                message = context.text(toast.messageKey, values: toast.values) + "\n" + message
            }
            items.append(NativeRenderItem(id: "board.error", rect: CGRect(x: 0, y: 0, width: NativeSize.searchWidth, height: NativeSize.toolbarHeight + NativeSpace.lg), label: message, kind: .text, fill: .toastBg, color: .danger))
        } else if let toast = state.toast, !Self.routineFeedbackKeys.contains(toast.messageKey) {
            let message = context.text(toast.messageKey, values: toast.values)
            items.append(NativeRenderItem(id: "board.toast", rect: CGRect(x: 0, y: 0, width: NativeSize.searchWidth, height: NativeSize.toolbarHeight + NativeSpace.lg), label: message, kind: .text, fill: .toastBg, color: .toastText))
        }
        if items.isEmpty && restoredPanelNotice {
            items.append(NativeRenderItem(id: "board.restored", rect: CGRect(x: 0, y: 0, width: NativeSize.searchWidth, height: NativeSize.toolbarHeight + NativeSpace.lg), label: context.text("grid.restored"), kind: .text, fill: .toastBg, color: .toastText))
        }
        if items.isEmpty && state.snapshot.board.layout.migrationNoticePending {
            items.append(NativeRenderItem(id: "board.migration", rect: CGRect(x: 0, y: 0, width: NativeSize.searchWidth, height: NativeSize.toolbarHeight + NativeSpace.lg), label: context.text("grid.migration"), kind: .text, fill: .toastBg, color: .toastText))
            items.append(NativeRenderItem(id: "action.dismissMigration", rect: CGRect(x: NativeSize.searchWidth - NativeSize.popoverWidth / 3, y: NativeSpace.sm, width: NativeSize.popoverWidth / 3 - NativeSpace.sm, height: NativeSize.toolbarHeight), label: context.text("grid.dismiss"), kind: .button, color: .accentBlue))
        }
        feedbackBaseItems = items; layoutFeedback()
        if !items.isEmpty { NSAccessibility.post(element: feedback, notification: .valueChanged) }
    }
    private func layoutFeedback() {
        guard !feedbackBaseItems.isEmpty else {
            feedback.isHidden = true; feedback.update(items: [])
            setAccessibilityHelp(nil); setAccessibilityCustomActions(nil); return
        }
        let height = NativeSize.toolbarHeight + NativeSpace.lg
        let action = feedbackBaseItems.first(where: { $0.isInteractive })
        let actionWidth = action.map { max(CGFloat(44), ceil(($0.label as NSString).size(withAttributes: [.font: NativeFont.primary]).width) + 2 * NativeSpace.sm) } ?? 0
        let minimumWidth = max(CGFloat(44), actionWidth)
        let grips = editingGrid ? gridHandles.filter { $0.resizing && !$0.isHidden }.map { $0.convert($0.bounds, to: self).insetBy(dx: -4, dy: -4) }.filter { $0.intersects(bounds) } : []
        let panels = editingGrid ? ([calendarView.frame] + slotHosts.values.filter { !$0.isHidden }.map(\.frame)).map { workspace.convert($0, to: self).intersection(bounds) }.filter { !$0.isNull && !$0.isEmpty } : []
        var placement: CGRect?
        if let item = feedbackBaseItems.first, BoardFeedbackView.wraps(item) {
            // Measure each candidate width before placement so narrowing never clips
            // a later line or the independent error appended after partial success.
            for width in [min(bounds.width, NativeSize.searchWidth), min(bounds.width, 240), min(bounds.width, 160), min(bounds.width, 96), minimumWidth] where width >= minimumWidth {
                let requiredHeight = BoardFeedbackView.height(for: item.label, width: width)
                placement = BoardFeedbackPlacement.find(in: bounds, avoiding: grips, panels: panels, preferredWidth: width, minimumWidth: width, height: requiredHeight)
                if placement != nil { break }
            }
        } else {
            placement = BoardFeedbackPlacement.find(in: bounds, avoiding: grips, panels: panels, preferredWidth: NativeSize.searchWidth, minimumWidth: minimumWidth, height: height)
        }
        guard let frame = placement else {
            // Extremely small or fully obstructed viewports cannot hold the full notice.
            // Keep the notice and its action on the root accessibility element.
            feedback.isHidden = true; feedback.update(items: [])
            let message = feedbackBaseItems.first(where: { !$0.isInteractive })?.label ?? ""
            setAccessibilityHelp(message)
            if let action {
                let name = action.label + (message.isEmpty ? "" : " · " + message)
                setAccessibilityCustomActions([NSAccessibilityCustomAction(name: name, target: self, selector: #selector(performFallbackFeedbackAction(_:)))])
            } else { setAccessibilityCustomActions(nil) }
            return
        }
        setAccessibilityHelp(nil); setAccessibilityCustomActions(nil)
        feedback.frame = frame; feedback.isHidden = false
        let message = feedbackBaseItems.first(where: { !$0.isInteractive })?.label ?? ""
        var displayed = feedbackBaseItems
        for index in displayed.indices {
            displayed[index].fill = nil
            if displayed[index].isInteractive {
                displayed[index].rect = CGRect(x: frame.width - actionWidth, y: NativeSpace.sm, width: actionWidth, height: NativeSize.toolbarHeight)
                displayed[index].minimumTarget = 44
                displayed[index].value = message
            } else {
                displayed[index].rect = CGRect(x: 0, y: 0, width: max(0, frame.width - actionWidth), height: frame.height)
            }
        }
        feedback.update(items: displayed)
    }
    @objc private func performFallbackFeedbackAction(_ action: NSAccessibilityCustomAction) -> Bool {
        guard let item = feedbackBaseItems.first(where: { $0.isInteractive }) else { return false }
        if item.id == "action.undo" { context.presentation.send(.undo); return true }
        if item.id == "action.dismissMigration" { context.presentation.send(.edit(.layout(.dismissMigrationNotice), undoable: false)); return true }
        return false
    }
    private func requestNotesFlush() {
        let presentation = context.presentation
        Task { @MainActor [weak self] in let receipt = await presentation.flushNotes(); self?.lastFlushReceipt = receipt.compact }
    }
    /// Called after the application observes flushNotes; does not cancel accepted mutations or Undo work.
    func dispose() {
        guard !lifetime.isDisposed else { return }
        cancelSurfaceHold(); consumeSurfaceMouseUp = false
        windowVisibilityObservation?.invalidate(); windowVisibilityObservation = nil
        stopOutsideMouseMonitor(); cancelDirectMove(); cancelGridInteraction(); gridTool?.close(); gridTool = nil; clearGridEditingBorders(); clearGridExitViews(); removeGridHandles()
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
