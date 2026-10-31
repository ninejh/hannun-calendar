import AppKit
import CryptoKit
import Darwin
import ImageIO

struct NativeLaunchFailure: Error, CustomStringConvertible {
    var description: String { "INVALID_CONFIGURATION" }
}

struct NativeSnapshotFailure: Error {
    let stage: String
    let domain: String
    let code: String
    static func wrapping(_ stage: String, _ error: Error) -> Self {
        if error is NativeLaunchFailure { return Self(stage: stage, domain: "NativeLaunch", code: "INVALID_CONFIGURATION") }
        let value = error as NSError
        let domain = value.domain
        let safe = !domain.isEmpty && domain.utf8.count <= 100 && domain.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0)
        }
        return Self(stage: stage, domain: safe ? domain : "Unknown", code: String(value.code))
    }
    var diagnostic: String { "SNAPSHOT_DIAGNOSTIC stage=\(stage) domain=\(domain) code=\(code)" }
}

enum NativeSnapshotPNG {
    private static let crcTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb88320 : crc >> 1 }
        return crc
    }
    static func validate(_ png: Data, width: Int, height: Int) throws {
        func invalid() -> NativeSnapshotFailure { NativeSnapshotFailure(stage: "capture.render", domain: "NativeSnapshot", code: "PNG_INVALID") }
        guard !png.isEmpty, png.count <= 33554432, width > 0, height > 0, width <= 8192, height <= 8192,
              width * height <= 33554432 else { throw invalid() }
        try png.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard raw.count >= 8, Array(raw[0..<8]) == [137,80,78,71,13,10,26,10] else { throw invalid() }
            func uint32(_ offset: Int) -> UInt32 {
                (UInt32(raw[offset]) << 24) | (UInt32(raw[offset + 1]) << 16) | (UInt32(raw[offset + 2]) << 8) | UInt32(raw[offset + 3])
            }
            var offset = 8, sawHeader = false, sawData = false, dataEnded = false, sawEnd = false
            while offset < raw.count {
                guard raw.count - offset >= 12 else { throw invalid() }
                let length = Int(uint32(offset)), start = offset + 8
                guard length <= raw.count - offset - 12 else { throw invalid() }
                let end = start + length, kind = Array(raw[(offset + 4)..<start])
                guard kind.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }) else { throw invalid() }
                var crc: UInt32 = 0xffffffff
                for index in (offset + 4)..<end { crc = crcTable[Int((crc ^ UInt32(raw[index])) & 0xff)] ^ (crc >> 8) }
                guard crc ^ 0xffffffff == uint32(end) else { throw invalid() }
                if !sawHeader {
                    guard kind == [73,72,68,82], length == 13, Int(uint32(start)) == width, Int(uint32(start + 4)) == height else { throw invalid() }
                    sawHeader = true
                } else if kind == [73,72,68,82] { throw invalid() }
                if kind == [73,68,65,84] {
                    guard !dataEnded else { throw invalid() }; sawData = true
                } else if sawData { dataEnded = true }
                if kind[0] & 0x20 == 0 && ![[73,72,68,82], [80,76,84,69], [73,68,65,84], [73,69,78,68]].contains(kind) { throw invalid() }
                offset = end + 4
                if kind == [73,69,78,68] {
                    guard sawData, length == 0, offset == raw.count else { throw invalid() }
                    sawEnd = true
                }
                if sawEnd { break }
            }
            guard sawHeader, sawData, sawEnd else { throw invalid() }
        }
        guard let source = CGImageSourceCreateWithData(png as CFData, nil), CGImageSourceGetCount(source) == 1,
              CGImageSourceGetStatus(source) == .statusComplete,
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil), decoded.width == width, decoded.height == height,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let provider = decoded.dataProvider, let decodedBytes = provider.data, CFDataGetLength(decodedBytes) > 0,
              let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw invalid() }
        context.draw(decoded, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { throw invalid() }
    }
}

/// Validates all developer launch options before opening storage or constructing adapters.
struct NativeLaunchOptions {
    let mode: RuntimeMode
    let clock: RuntimeClockMode = .system
    let selfTest: Bool
    let snapshot: Bool
    let snapshotStdout: Bool
    let reportDirectory: URL?
    static var buildDirectory: URL {
#if HANNUN_EXECUTABLE_TESTS
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build")
#else
        for origin in [Bundle.main.bundleURL, URL(fileURLWithPath: #filePath)] {
            var cursor = origin
            for _ in 0..<40 {
                if cursor.lastPathComponent == "build" { return cursor }
                let parent = cursor.deletingLastPathComponent(); if parent == cursor { break }; cursor = parent
            }
        }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build")
#endif
    }
    static func reportURL(_ text: String) throws -> URL {
        guard text.hasPrefix("/"), !text.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              !text.contains("\\"), !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw NativeLaunchFailure() }
        let value = URL(fileURLWithPath: text)
        guard value.path.hasPrefix(buildDirectory.path + "/"), value.standardizedFileURL == value.resolvingSymlinksInPath() else { throw NativeLaunchFailure() }
        return value
    }
    init(arguments: [String]) throws {
        var flags = Set<String>(), report: URL?, index = 1
        while index < arguments.count {
            let key = arguments[index]
            if key == "--report-dir" {
                guard report == nil, index + 1 < arguments.count else { throw NativeLaunchFailure() }
                report = try Self.reportURL(arguments[index + 1]); index += 2
            } else {
                guard ["--demo", "--snapshot", "--snapshot-stdout", "--self-test"].contains(key), flags.insert(key).inserted else { throw NativeLaunchFailure() }; index += 1
            }
        }
        selfTest = flags.contains("--self-test"); snapshot = flags.contains("--snapshot")
        snapshotStdout = flags.contains("--snapshot-stdout")
        if snapshotStdout { guard flags == ["--demo", "--snapshot-stdout"], report == nil else { throw NativeLaunchFailure() } }
        guard !(selfTest && snapshot), !snapshot || report != nil else { throw NativeLaunchFailure() }
#if HANNUN_TESTING
        mode = .demoMemory
#else
        mode = flags.isEmpty ? .production : .demoMemory
#endif
        guard mode != .production || report == nil else { throw NativeLaunchFailure() }
        reportDirectory = report
    }
    @MainActor func makeComposition() throws -> NativeAppComposition {
        try NativeAppComposition.make(configuration: ValidatedRuntimeConfiguration.validate(mode: mode, clock: clock))
    }
    @MainActor func makeApplication() throws -> NativeBoardApplication {
        let viewport = NativeLayoutViewportContext(frame: NativeAppComposition.initialFrame())
        return try NativeBoardApplication.make(configuration: ValidatedRuntimeConfiguration.validate(mode: mode, clock: clock), layoutViewport: { viewport.value })
    }

}

struct NativeDisplay: Sendable {
    var id: CGDirectDisplayID
    var frame: CGRect
    var visibleFrame: CGRect
    static func retained(id: CGDirectDisplayID?, screens: [Self], mainID: CGDirectDisplayID?) -> Self? {
        screens.first { $0.id == id } ?? screens.first { $0.id == mainID } ?? screens.first
    }
    static func atPointer(_ point: CGPoint, screens: [Self], mainID: CGDirectDisplayID?) -> Self? {
        screens.first { $0.frame.contains(point) } ?? retained(id: mainID, screens: screens, mainID: mainID)
    }
    @MainActor static func descriptor(_ screen: NSScreen) -> Self? {
        guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return nil }
        return Self(id: id, frame: screen.frame, visibleFrame: screen.visibleFrame)
    }
    @MainActor static var screens: [Self] { NSScreen.screens.compactMap(descriptor) }
    @MainActor static var mainID: CGDirectDisplayID? { NSScreen.main.flatMap(descriptor)?.id }
}

/// Only Foundation values cross into persistence; no file read queries AppKit or assumes a display.
final class NativeLayoutViewportContext: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: LayoutViewport?
    init(frame: CGRect?) { update(size: frame?.size) }
    var value: LayoutViewport? { lock.lock(); defer { lock.unlock() }; return stored }
    func update(size: CGSize?) {
        let next = size.flatMap { size -> LayoutViewport? in
            guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
            return LayoutViewport(width: Double(size.width), height: Double(size.height))
        }
        lock.lock(); stored = next; lock.unlock()
    }
}

@MainActor final class DesktopPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The sole native composition: one application, presentation, editor owner and desktop window.
/// RuntimeLifecycle owns normal clock/midnight/wake/environment observers; no duplicate timer here.
@MainActor final class NativeAppComposition: NSObject, NSWindowDelegate, NSMenuDelegate {
    let application: NativeBoardApplication
    let presentation: BoardViewModel
    let root: BoardRootView
    let panel: DesktopPanel
    private var statusItem: NSStatusItem?
#if HANNUN_TESTING
    var testStatusItem: NSStatusItem? { disposed ? nil : statusItem }
    func testStatusItemProvider() -> @MainActor () -> NSStatusItem? { { [weak self] in self?.testStatusItem } }
#endif
    private(set) var statusMenu = NSMenu()
    private(set) var selectedDisplayID: CGDirectDisplayID?
    private(set) var isReady = false
    private(set) var lastFlushReceipt: CommandReceipt?
    private(set) var lastStartupReceipt: CommandReceipt?
    private var observation: ObservationToken?
    private var starting: Task<Void, Never>?
    private var disposed = false
    private var menuKey: String?
    private var mainMenu: NSMenu?
    private let viewportContext: NativeLayoutViewportContext?
    private let updater: (any AppUpdating)?

    static var panelFactories: [PanelID: PanelFactory] { [
        .today: { AgendaPanelController(context: $0) }, .notes: { NotesPanelController(context: $0) },
        .projects: { ProjectsPanelController(context: $0) }, .deadlines: { DeadlinesPanelController(context: $0) },
        .subscriptions: { SubscriptionsPanelView(context: $0) }, .todos: { TodosPanelView(context: $0) },
        .habits: { HabitsPanelView(context: $0) }, .worldClock: { WorldClockPanelController(context: $0) },
        .focusTimer: { FocusPanelController(context: $0) }
    ] }
    static func initialFrame() -> CGRect? {
        NativeDisplay.retained(id: NativeDisplay.mainID, screens: NativeDisplay.screens, mainID: NativeDisplay.mainID)?.visibleFrame
    }
    static func make(configuration: ValidatedRuntimeConfiguration, frame: CGRect? = nil, createsStatusItem: Bool = true) throws -> NativeAppComposition {
        let actualFrame = frame ?? initialFrame()
        let viewport = NativeLayoutViewportContext(frame: actualFrame)
        let application = try NativeBoardApplication.make(configuration: configuration, layoutViewport: { viewport.value })
        return NativeAppComposition(application: application, frame: actualFrame ?? .zero, createsStatusItem: createsStatusItem, viewportContext: viewport)
    }
    init(application: NativeBoardApplication, frame explicitFrame: CGRect? = nil, createsStatusItem: Bool = true, viewportContext: NativeLayoutViewportContext? = nil, updater: (any AppUpdating)? = nil) {
        self.viewportContext = viewportContext
        self.application = application
        self.updater = updater ?? AppUpdaterFactory.make(configuration: application.configuration)
        presentation = BoardViewModel(application: application)
        root = BoardRootView(presentation: presentation, strings: application.preferences.strings,
                             panelFactories: Self.panelFactories, overlayFactory: makeNativeOverlayFactory())
        let display = NativeDisplay.retained(id: NativeDisplay.mainID, screens: NativeDisplay.screens, mainID: NativeDisplay.mainID)
        selectedDisplayID = display?.id
        let frame = explicitFrame ?? display?.visibleFrame ?? .zero
        panel = DesktopPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.colorSpace = .sRGB
        panel.title = "Hannun Calendar Desktop"; panel.isReleasedWhenClosed = false
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.hidesOnDeactivate = false; panel.isFloatingPanel = false; panel.becomesKeyOnlyIfNeeded = false
        panel.isMovableByWindowBackground = false; panel.animationBehavior = .none
        panel.collectionBehavior = [.stationary, .canJoinAllSpaces, .ignoresCycle]
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        panel.delegate = self
        root.frame = CGRect(origin: .zero, size: frame.size); root.autoresizingMask = [.width, .height]
        panel.contentView = root
        viewportContext?.update(size: root.bounds.size)
        if createsStatusItem {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            statusItem?.button?.image = NSImage(systemSymbolName: "calendar", accessibilityDescription: "Hannun Calendar")
        }
        application.setWindowDiagnostics(nonactivating: panel.styleMask.contains(.nonactivatingPanel), stationary: panel.collectionBehavior.contains(.stationary), desktopLevel: panel.level.rawValue == Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        observation = presentation.subscribe { [weak self] change in
            if !change.domains.isDisjoint(with: [.board, .environment, .error]) { self?.applyPreferences() }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }
    func start() async {
        guard !disposed, !isReady else { return }
        if let starting { await starting.value; return }
        let task = Task { @MainActor in
            self.lastStartupReceipt = await self.presentation.load(nil)
            guard !self.disposed else { return }
            self.root.needsLayout = true; self.root.layoutSubtreeIfNeeded(); self.showBoard(); self.application.start()
            let handle = self.application.submit(.uiReady, context: self.context())
            let ready = await handle.settled.value
            if case .success = ready { self.isReady = true; self.updater?.start() } else { self.lastStartupReceipt = ready }
        }
        starting = task; await task.value; starting = nil
    }
    private func context() -> OperationContext { OperationContext(id: UUID(), sessionID: application.sessionID, baseRevision: application.current.boardRevision) }
    func text(_ key: String) -> String { application.preferences.strings.text(key, language: presentation.state.snapshot.board.settings.language.rawValue) }
    private func applyPreferences() {
        guard !disposed else { return }
        let state = presentation.state.snapshot
        if state.board.settings.appearance == .system && application.configuration.clock != .manual { panel.appearance = nil }
        else { panel.appearance = NSAppearance(named: state.environment.resolvedAppearance == .dark ? .darkAqua : .aqua) }
        let failure = presentation.state.lastError
        let key = "\(state.board.settings.language.rawValue)|\(state.login.rawValue)|\(failure?.code.rawValue ?? "")"
        guard menuKey != key else { return }; menuKey = key
        let menu = NSMenu(); menu.delegate = self; menu.autoenablesItems = false
        for (key, action) in [("show_board", #selector(showAction)), ("hide_board", #selector(hideAction)), ("fit_display", #selector(fitAction)), ("connect_cal", #selector(connectAction)), ("refresh_cal", #selector(refreshAction)), ("settings", #selector(settingsAction))] {
            add(menu, "menu." + key, action)
        }
        let login = add(menu, "menu.launch_at_login", #selector(loginAction)); login.state = state.login == .enabled ? .on : .off
        if state.login == .requiresApproval { login.toolTip = text("error.login_approval_required") }
        if let failure { login.toolTip = text(failure.messageKey) }
        if state.login == .requiresApproval || state.login == .notFound || failure?.code == .loginRegistrationFailed {
            add(menu, "settings.open_login", #selector(loginSettingsAction))
        }
        menu.addItem(.separator())
        let update = add(menu, "menu.check_updates", #selector(checkUpdatesAction))
        update.isEnabled = updater?.canCheckForUpdates == true
        add(menu, "menu.quit", #selector(quitAction), key: "q")
        statusMenu = menu; statusItem?.menu = menu; statusItem?.button?.toolTip = text("menu.tooltip")
        configureMainMenu()
    }
    private func configureMainMenu() {
        let menu = NSMenu(), item = NSMenuItem(), appMenu = NSMenu()
        add(appMenu, "menu.show_board", #selector(showAction), key: "0")
        add(appMenu, "menu.settings", #selector(settingsAction), key: ",")
        add(appMenu, "menu.quit", #selector(quitAction), key: "q")
        item.submenu = appMenu; menu.addItem(item)
        let edit = NSMenu(title: text("menu.edit")), editItem = NSMenuItem()
        for (key, action, shortcut) in [("undo", "undo:", "z"), ("redo", "redo:", "Z"), ("cut", "cut:", "x"), ("copy", "copy:", "c"), ("paste", "paste:", "v"), ("select_all", "selectAll:", "a")] {
            let command = edit.addItem(withTitle: text("menu." + key), action: #selector(editingAction(_:)), keyEquivalent: shortcut)
            command.target = self; command.representedObject = action
        }
        editItem.submenu = edit; menu.addItem(editItem); mainMenu = menu; NSApp.mainMenu = menu
    }
    @discardableResult private func add(_ menu: NSMenu, _ key: String, _ action: Selector, key shortcut: String = "") -> NSMenuItem {
        let item = menu.addItem(withTitle: text(key), action: action, keyEquivalent: shortcut); item.target = self; return item
    }
    private var liveLoginStatus: LoginStatus {
        LoginStatus(rawValue: application.preferences.login["status"] as? String ?? "") ?? .notFound
    }
    func menuWillOpen(_ menu: NSMenu) {
        let status = liveLoginStatus
        for item in menu.items where item.action == #selector(loginAction) {
            item.state = status == .enabled ? .on : .off
            item.toolTip = status == .requiresApproval ? text("error.login_approval_required") : nil
        }
        for item in menu.items where item.action == #selector(checkUpdatesAction) {
            item.isEnabled = updater?.canCheckForUpdates == true
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        Task { @MainActor in _ = await self.hideBoard() }; return false
    }
    func showBoard() { guard !disposed else { return }; panel.orderFrontRegardless(); root.layoutSubtreeIfNeeded() }
    func openSettings() { guard !disposed else { return }; showBoard(); application.requestSettings() }
    @discardableResult func flushForLifecycle() async -> CommandReceipt {
        let result = await presentation.flushNotes()
        // Preserve the notes failure while still joining other admitted writes, as the
        // previous hide/quit path did after attempting its UI save.
        if case .failure = result { _ = await application.flush() }
        lastFlushReceipt = result.compact; return result.compact
    }
    @discardableResult func flushForTermination() async -> CommandReceipt {
        let receipt = await flushForLifecycle()
        if case .failure = receipt { return receipt }
        // A save can finish while another editor or write is still outstanding.
        // Never discard those drafts, including an active marked-text session.
        let marked = (panel.firstResponder as? NSTextView)?.hasMarkedText() == true
        // Management forms also contain date and status edits which do not publish
        // a text draft. Keep an open form until its user resolves it.
        let managementOpen = (root.controller(for: .projects) as? ProjectsPanelController)?.editor != nil ||
            (root.controller(for: .deadlines) as? DeadlinesPanelController)?.editor != nil
        let unresolved = presentation.state.drafts.contains { key, value in
            // Search is a cached navigation query, not an edit to persisted data.
            key != .search || value.textValue?.isComposing == true
        }
        guard !marked, !managementOpen, !unresolved, presentation.state.pending.isEmpty else {
            return .failure(AppFailure(code: .busyRetry, messageKey: "error.quit_unsaved", retryable: true), snapshot: nil)
        }
        return receipt
    }
    func windowDidResize(_ notification: Notification) { viewportContext?.update(size: root.bounds.size); root.needsLayout = true }
    @discardableResult func hideBoard() async -> CommandReceipt {
        let result = await flushForLifecycle(); panel.orderOut(nil); return result
    }
    func undoRespectingText() {
        if let editor = panel.firstResponder as? NSTextView {
            // A text session owns Undo even when its history is empty or IME is composing.
            guard !editor.hasMarkedText(), let undo = editor.undoManager, undo.canUndo else { return }
            undo.undo()
        } else { presentation.send(.undo) }
    }
    @objc private func editingAction(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              ["selectAll:", "copy:", "cut:", "paste:", "undo:", "redo:"].contains(name) else { return }
        let action = Selector(name)
        // A generic canvas responder may consume undo: without board history.
        // Route it through the current text session or semantic board Undo first.
        if name == "undo:" { undoRespectingText(); return }
        // Active windows keep AppKit's standard responder-chain resolution first.
        if NSApp.isActive, NSApp.keyWindow != nil, NSApp.sendAction(action, to: nil, from: sender) { return }
        // An inactive desktop panel may own a field editor while NSApp.keyWindow is nil.
        // Forward the actual menu command to that native responder without activating it.
        guard let editor = panel.firstResponder as? NSTextView else { return }
        if name == "redo:" {
            guard !editor.hasMarkedText(), let undo = editor.undoManager, undo.canRedo else { return }
            undo.redo()
        } else { _ = NSApp.sendAction(action, to: editor, from: sender) }
    }
    @objc private func showAction() { showBoard() }
    @objc private func hideAction() { Task { @MainActor in _ = await self.hideBoard() } }
    @objc private func settingsAction() { openSettings() }
    @objc private func connectAction() { presentation.send(.command(.connect)) }
    @objc private func refreshAction() {
        if !isReady { Task { @MainActor in await self.start() }; return }
        if let range = root.calendarView.visibleRange { presentation.send(.command(.refresh(range, refreshSources: true))) }
    }
    @objc private func loginAction() { presentation.send(.command(.setLogin(liveLoginStatus != .enabled))) }
    @objc private func loginSettingsAction() { presentation.send(.command(.open(.login))) }
    @objc private func quitAction() { NSApp.terminate(nil) }
    @objc private func checkUpdatesAction() {
        guard updater?.canCheckForUpdates == true else { return }
        updater?.checkForUpdates()
    }
    @objc private func fitAction() { fitToPointerDisplay() }
    @objc private func screenChanged() { fitRetainedDisplay() }
    func fitToPointerDisplay() {
        if let display = NativeDisplay.atPointer(NSEvent.mouseLocation, screens: NativeDisplay.screens, mainID: NativeDisplay.mainID) { fit(display) }
    }
    func fitRetainedDisplay() {
        if let display = NativeDisplay.retained(id: selectedDisplayID, screens: NativeDisplay.screens, mainID: NativeDisplay.mainID) { fit(display) }
    }
    private func fit(_ display: NativeDisplay) {
        selectedDisplayID = display.id
        if panel.frame != display.visibleFrame { panel.setFrame(display.visibleFrame, display: true) }
    }
    func capture(to directory: URL) throws {
        do { _ = try NativeLaunchOptions.reportURL(directory.path) }
        catch { throw NativeSnapshotFailure.wrapping("capture.guard", error) }
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { throw NativeSnapshotFailure.wrapping("capture.mkdir", error) }
        root.layoutSubtreeIfNeeded(); root.displayIfNeeded()
        guard let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { throw NativeSnapshotFailure(stage: "capture.render", domain: "NativeSnapshot", code: "BITMAP_UNAVAILABLE") }
        root.cacheDisplay(in: root.bounds, to: bitmap)
        guard let bytes = bitmap.representation(using: .png, properties: [:]) else { throw NativeSnapshotFailure(stage: "capture.render", domain: "NativeSnapshot", code: "PNG_UNAVAILABLE") }
        let file = directory.appendingPathComponent("desktop-preview.png")
        do { try bytes.write(to: file, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        catch { throw NativeSnapshotFailure.wrapping("capture.write", error) }
    }
    func snapshotStdoutFrame() throws -> Data {
        func failure(_ code: String) -> NativeSnapshotFailure { NativeSnapshotFailure(stage: "capture.render", domain: "NativeSnapshot", code: code) }
        let network = application.panels.external.effects.realAdapterCreations
        guard demoCheckPassed, application.configuration.mode == .demoMemory,
              application.configuration.clock == .system || application.configuration.buildMode == .testing,
              network == 0 else { throw failure("ISOLATION_OR_READINESS") }
        root.layoutSubtreeIfNeeded(); root.displayIfNeeded()
        let backing = root.convertToBacking(root.bounds)
        guard backing.width.isFinite, backing.height.isFinite, backing.width > 0, backing.height > 0,
              ceil(backing.width) <= 8192, ceil(backing.height) <= 8192,
              ceil(backing.width) * ceil(backing.height) <= 33554432 else { throw failure("PIXEL_BOUNDS") }
        guard let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { throw failure("BITMAP_UNAVAILABLE") }
        let width = bitmap.pixelsWide, height = bitmap.pixelsHigh
        guard width > 0, height > 0, width <= 8192, height <= 8192, width * height <= 33554432 else { throw failure("PIXEL_BOUNDS") }
        root.cacheDisplay(in: root.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]), !png.isEmpty, png.count <= 33554432,
              png.count >= 24, png.prefix(8) == Data([137,80,78,71,13,10,26,10]),
              png[12..<16] == Data("IHDR".utf8),
              png[16..<20].reduce(0, { ($0 << 8) | Int($1) }) == width,
              png[20..<24].reduce(0, { ($0 << 8) | Int($1) }) == height else { throw failure("PNG_INVALID") }
        try NativeSnapshotPNG.validate(png, width: width, height: height)
        let digest = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
        let metadata: [String: Any] = ["version": 1, "widthPx": width, "heightPx": height, "pngSHA256": digest,
            "compositionReady": isReady, "storageMode": application.configuration.mode == .demoMemory ? "demoMemory" : "invalid",
            "fakeCalendar": application.calendars.demo, "calendarAccountAccessCount": application.calendars.accountAccessCount,
            "fakeNetwork": application.panels.fakeTransport != nil, "networkRealAdapterCreations": network,
            "fakeNotifications": application.panels.fakeNotifications != nil]
        let json: Data
        do { json = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]) }
        catch { throw NativeSnapshotFailure.wrapping("capture.metadata", error) }
        guard !json.isEmpty, json.count <= 4096 else { throw failure("METADATA_BOUNDS") }
        var result = Data("HNSNAP01".utf8), jsonLength = UInt32(json.count).bigEndian, pngLength = UInt64(png.count).bigEndian
        withUnsafeBytes(of: &jsonLength) { result.append(contentsOf: $0) }
        withUnsafeBytes(of: &pngLength) { result.append(contentsOf: $0) }
        result.append(json); result.append(png); return result
    }
    var demoCheckPassed: Bool {
        isReady && application.current.board.version == 3 && root.slotHosts.count == 4 && !root.calendarView.cellRects.isEmpty &&
        application.configuration.adapterMode == .fake && application.calendars.demo && application.calendars.accountAccessCount == 0 &&
        application.panels.fakeTransport != nil && application.panels.fakeNotifications != nil
    }
    func dispose() {
        guard !disposed else { return }; disposed = true; isReady = false
        NotificationCenter.default.removeObserver(self); observation?.cancel(); observation = nil
        application.stop(); root.dispose(); presentation.dispose()
        if NSApp.mainMenu === mainMenu { NSApp.mainMenu = nil }; mainMenu = nil
        for item in statusMenu.items { item.target = nil }; statusMenu.removeAllItems()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }; statusItem = nil
        panel.delegate = nil; panel.orderOut(nil); panel.contentView = nil; panel.close()
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let composition: NativeAppComposition
    private let onReady: (@MainActor (NativeAppComposition) async -> Void)?
    private var terminating = false
    init(composition: NativeAppComposition, onReady: (@MainActor (NativeAppComposition) async -> Void)? = nil) {
        self.composition = composition; self.onReady = onReady; super.init()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in await self.composition.start(); await self.onReady?(self.composition) }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { composition.showBoard(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminating { return .terminateCancel }; terminating = true
        Task { @MainActor in
            let receipt = await self.composition.flushForTermination()
            if case .success = receipt {
                self.composition.dispose(); sender.reply(toApplicationShouldTerminate: true)
            } else {
                self.terminating = false
                sender.reply(toApplicationShouldTerminate: false)
                self.composition.showBoard()
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = self.composition.text("error.quit_unsaved_title")
                alert.informativeText = self.composition.text("error.quit_unsaved")
                alert.addButton(withTitle: self.composition.text("error.quit_unsaved_ok"))
                alert.runModal()
            }
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) { composition.dispose() }
    @objc func undo(_ sender: Any?) { composition.undoRespectingText() }
}

#if !HANNUN_EXECUTABLE_TESTS
@main enum HannunMain {
#if HANNUN_TESTING
    @MainActor static func main() async {
        if CommandLine.arguments.contains("--probe-approved-samples") {
            exit(await NativeApprovedSampleProbe.run(arguments: Array(CommandLine.arguments.dropFirst())))
        }
        launch()
    }
#else
    @MainActor static func main() { launch() }
#endif
    @MainActor private static func launch() {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        do {
            let delegate = try makeDelegate(arguments: CommandLine.arguments)
            app.delegate = delegate
            withExtendedLifetime(delegate) { app.run() }
        } catch {
#if HANNUN_TESTING
            if error is NativeSyntheticProviderInvalid { print("FAIL: PROVIDER_STATE_INVALID"); exit(2) }
#endif
            if CommandLine.arguments.contains("--snapshot-stdout") {
                let message = NativeSnapshotFailure.wrapping("precheck", error).diagnostic + "\n"
                try? FileHandle.standardError.write(contentsOf: Data(message.utf8)); exit(2)
            }
            if CommandLine.arguments.contains("--demo") && CommandLine.arguments.contains("--snapshot") {
                print(NativeSnapshotFailure.wrapping("precheck", error).diagnostic)
            }
            print("FAIL: invalid native application configuration"); exit(2)
        }
    }
    @MainActor private static func makeDelegate(arguments: [String]) throws -> AppDelegate {
#if HANNUN_TESTING
        if arguments.contains("--fixture") || arguments.contains("--suite") || arguments.contains("--scratch-root") {
            let host = try NativeTestHost(arguments: arguments)
            let application = try host.makeApplication()
            let origin = NSScreen.main?.visibleFrame.origin ?? .zero
            let composition = NativeAppComposition(application: application, frame: CGRect(origin: origin, size: host.viewport))
            try host.attach(window: composition.panel, statusItemProvider: composition.testStatusItemProvider())
            host.driver?.eligiblePopoverWindows = { [weak composition] in
                guard let composition, composition.panel.isVisible else { return [] }
                let controllers = [composition.root.controller(for: .projects), composition.root.controller(for: .deadlines)]
                return controllers.compactMap { controller in
                    guard let controller, controller.view.window === composition.panel,
                          !controller.view.isHiddenOrHasHiddenAncestor else { return nil }
                    let editor: ProjectDeadlineEditor?
                    if let projects = controller as? ProjectsPanelController { editor = projects.editor }
                    else if let deadlines = controller as? DeadlinesPanelController { editor = deadlines.editor }
                    else { return nil }
                    guard let editor, editor.popover.isShown,
                          editor.popover.contentViewController?.view === editor.surface,
                          let window = editor.surface.window, window !== composition.panel, window.isVisible else { return nil }
                    return window
                }
            }
            return AppDelegate(composition: composition) { session in
                guard host.suite != "manual" else { return }
                guard session.isReady else { print("FAIL: native UI not ready"); host.dispose(); session.dispose(); exit(2) }
                let result = await host.run()
                let flushed = await session.flushForLifecycle()
                let state = session.presentation.state
                let code = host.finish(result: result, lifecycle: flushed,
                    hasUnsettledUI: !state.drafts.isEmpty || !state.pending.isEmpty, presentationFailure: state.lastError)
                if code != result { print("FAIL: native lifecycle flush") }
                host.dispose(); session.dispose(); exit(code)
            }
        }
#endif
        let options = try NativeLaunchOptions(arguments: arguments)
        return AppDelegate(composition: try options.makeComposition()) { session in
            if options.snapshotStdout {
                do {
                    guard session.demoCheckPassed else { throw NativeSnapshotFailure(stage: "precheck", domain: "NativeSnapshot", code: "COMPOSITION_NOT_READY") }
                    let receipt = await session.flushForLifecycle()
                    if case .failure(let failure, _) = receipt { throw NativeSnapshotFailure(stage: "flush", domain: "NativeApplication", code: failure.code.rawValue) }
                    let frame = try session.snapshotStdoutFrame()
                    signal(SIGPIPE, SIG_IGN)
                    do { try FileHandle.standardOutput.write(contentsOf: frame) }
                    catch { throw NativeSnapshotFailure.wrapping("output", error) }
                    session.dispose(); exit(0)
                } catch {
                    let failure = (error as? NativeSnapshotFailure) ?? NativeSnapshotFailure.wrapping("capture", error)
                    try? FileHandle.standardError.write(contentsOf: Data((failure.diagnostic + "\n").utf8))
                    session.dispose(); exit(1)
                }
            }
            guard options.snapshot || options.selfTest else { return }
            var passed = session.demoCheckPassed
            let diagnostics = options.snapshot && arguments.contains("--demo")
            if diagnostics && !passed { print(NativeSnapshotFailure(stage: "precheck", domain: "NativeSnapshot", code: "COMPOSITION_NOT_READY").diagnostic) }
            if options.snapshot, let directory = options.reportDirectory {
                do { try session.capture(to: directory) }
                catch {
                    passed = false
                    if diagnostics { print(((error as? NativeSnapshotFailure) ?? NativeSnapshotFailure.wrapping("capture", error)).diagnostic) }
                }
            }
            let receipt = await session.flushForLifecycle()
            if case .failure(let failure, _) = receipt {
                passed = false
                if diagnostics { print(NativeSnapshotFailure(stage: "flush", domain: "NativeApplication", code: failure.code.rawValue).diagnostic) }
            }
            print(passed ? "PASS: native composition, schema3 and fake adapters" : "FAIL: native composition self-check")
            session.dispose(); exit(passed ? 0 : 1)
        }
    }
}
#endif
