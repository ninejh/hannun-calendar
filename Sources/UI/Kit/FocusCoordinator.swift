import AppKit

struct FocusID: Hashable, Sendable { var rawValue: String; init(_ value: String) { rawValue = value } }
@MainActor final class FocusCoordinator {
    struct Target {
        var id: FocusID
        var rect: CGRect
        var enabled = true
        var activate: @MainActor () -> Void
        var increment: (@MainActor (Int) -> Void)? = nil
        var reveal: (@MainActor () -> Void)? = nil
        var focusChanged: (@MainActor () -> Void)? = nil
        var handleKey: (@MainActor (NSEvent) -> Bool?)? = nil
        var showMenu: (@MainActor () -> Void)? = nil
    }
    private struct Scope { var owner: ObjectIdentifier; var targets: [Target] }
    private var scopes: [Scope] = []
    private(set) var focusedID: FocusID?
    private(set) var keyboardFocus = false
    var onFocusChange: (@MainActor (FocusID?) -> Void)?
    private var targets: [Target] { scopes.flatMap(\.targets).filter(\.enabled) }
    func register(owner: AnyObject, targets: [Target]) {
        let id = ObjectIdentifier(owner)
        if let i = scopes.firstIndex(where: { $0.owner == id }) { scopes[i].targets = targets } else { scopes.append(Scope(owner: id, targets: targets)) }
        if let focusedID, !self.targets.contains(where: { $0.id == focusedID }) { self.focusedID = nil; onFocusChange?(nil) }
    }
    func unregister(owner: AnyObject) {
        scopes.removeAll { $0.owner == ObjectIdentifier(owner) }
        if let focusedID, !targets.contains(where: { $0.id == focusedID }) { self.focusedID = nil; onFocusChange?(nil) }
    }
    func focus(_ id: FocusID, keyboard: Bool = true) {
        guard targets.contains(where: { $0.id == id }) else { return }
        let previous = targets.first { $0.id == focusedID }
        keyboardFocus = keyboard; focusedID = id
        previous?.focusChanged?(); targets.first { $0.id == id }?.reveal?()
        targets.first { $0.id == id }?.focusChanged?(); onFocusChange?(id)
    }
    func move(forward: Bool) {
        let values = targets; guard !values.isEmpty else { focusedID = nil; return }
        let index = focusedID.flatMap { id in values.firstIndex { $0.id == id } }
        let next = index.map { ($0 + (forward ? 1 : -1) + values.count) % values.count } ?? (forward ? 0 : values.count - 1)
        focus(values[next].id)
    }
    func activate() { if let target = targets.first(where: { $0.id == focusedID }) { target.activate() } }
    func adjust(_ amount: Int) {
        if let increment = targets.first(where: { $0.id == focusedID })?.increment { increment(amount) }
        else { move(forward: amount > 0) }
    }
    var focusedRect: CGRect? { targets.first { $0.id == focusedID }?.rect }
    /// Return true only after consuming the key; native NSText responders get their text Undo first.
    func handle(_ event: NSEvent) -> Bool {
        if let result = targets.first(where: { $0.id == focusedID })?.handleKey?(event) { return result }
        if event.keyCode == 109, event.modifierFlags.contains(.shift),
           let menu = targets.first(where: { $0.id == focusedID })?.showMenu { menu(); return true }
        switch event.keyCode {
        case 48: move(forward: !event.modifierFlags.contains(.shift)); return true
        case 36, 49: activate(); return true
        case 123: adjust(-1); return true
        case 124: adjust(1); return true
        case 125, 126:
            if let increment = targets.first(where: { $0.id == focusedID })?.increment {
                increment(event.keyCode == 125 ? -1 : 1)
            } else { move(forward: event.keyCode == 125) }
            return true
        default: return false
        }
    }
}
