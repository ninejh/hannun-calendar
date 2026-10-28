import AppKit

struct NativeMenuEntry {
    var id: String
    var title: String
    var checked = false
    var enabled = true
    var keyEquivalent = ""
}
@MainActor final class NativeMenu: NSObject {
    let menu = NSMenu()
    private var select: (@MainActor (String) -> Void)?
    init(items: [NativeMenuEntry], onSelect: @escaping @MainActor (String) -> Void) {
        select = onSelect; super.init(); menu.autoenablesItems = false
        for entry in items {
            let item = NSMenuItem(title: entry.title, action: #selector(choose(_:)), keyEquivalent: entry.keyEquivalent)
            item.target = self; item.identifier = NSUserInterfaceItemIdentifier(entry.id); item.state = entry.checked ? .on : .off; item.isEnabled = entry.enabled
            item.setAccessibilityIdentifier(entry.id); menu.addItem(item)
        }
    }
    @objc private func choose(_ sender: NSMenuItem) { guard sender.isEnabled, let id = sender.identifier?.rawValue else { return }; select?(id) }
    func dispose() { select = nil; menu.cancelTracking(); for item in menu.items { item.target = nil }; menu.removeAllItems() }
}

/// Existing root slot menus are reached weakly from each actual painted header.
@MainActor protocol PanelMenuProviding: AnyObject {
    func panelMenu(for slot: SlotID) -> NSMenu?
}
@MainActor final class WeakPanelMenuProxy: PanelMenuProviding {
    weak var target: (any PanelMenuProviding)?
    func panelMenu(for slot: SlotID) -> NSMenu? { target?.panelMenu(for: slot) }
}
@MainActor protocol NativePanelMenuPresenting {
    /// Whether the native menu action was handled, independently of selection or cancellation.
    func present(_ menu: NSMenu, at point: CGPoint, in view: NSView) -> Bool
}
@MainActor private final class NativePanelMenuTracking {
    var began = false
}
@MainActor struct SystemNativePanelMenuPresenter: NativePanelMenuPresenting {
    func present(_ menu: NSMenu, at point: CGPoint, in view: NSView) -> Bool {
        guard view.window != nil, menu.numberOfItems > 0 else { return false }
        let tracking = NativePanelMenuTracking()
        let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: menu, queue: .main) { _ in
            MainActor.assumeIsolated { tracking.began = true }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let selected = menu.popUp(positioning: nil, at: point, in: view)
        // AppKit returns false for cancellation even after a menu successfully opened.
        return tracking.began || selected
    }
}
/// One bounded menu session preserves native context tracking and returns to the physical slot header.
@MainActor final class NativePanelMenuSession: NSObject, NSMenuDelegate {
    private weak var menu: NSMenu?
    private weak var previousDelegate: (any NSMenuDelegate)?
    private weak var focus: FocusCoordinator?
    private let returnID: FocusID
    private var finished = false
    init(menu: NSMenu, focus: FocusCoordinator, returnID: FocusID) {
        self.menu = menu; self.focus = focus; self.returnID = returnID; previousDelegate = menu.delegate
        super.init(); menu.delegate = self
    }
    func menuWillOpen(_ menu: NSMenu) { previousDelegate?.menuWillOpen?(menu) }
    func menuNeedsUpdate(_ menu: NSMenu) { previousDelegate?.menuNeedsUpdate?(menu) }
    func menuDidClose(_ menu: NSMenu) { previousDelegate?.menuDidClose?(menu); finish() }
    func finish(restoreFocus: Bool = true) {
        guard !finished else { return }; finished = true
        if let menu, menu.delegate === self { menu.delegate = previousDelegate }
        if restoreFocus { focus?.focus(returnID) }
    }
}
