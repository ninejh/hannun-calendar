import AppKit

/// DESIGN_SYSTEM section 3 shadow.popover. Retain one instance per floating surface.
/// The host must allow overflow and place surfaceRect in its own coordinate space.
@MainActor final class NativeSurfaceShadow {
    private weak var host: CALayer?
    private var layers: [CALayer] = []
    private var previousRect: CGRect?
    private var previousAppearance: ResolvedAppearance?
    private var previousFlipped: Bool?

    func update(in host: CALayer, surfaceRect: CGRect, appearance: ResolvedAppearance, isFlipped: Bool) {
        guard !surfaceRect.isEmpty, !surfaceRect.isInfinite, !surfaceRect.isNull else { dispose(); return }
        guard self.host !== host || previousRect != surfaceRect || previousAppearance != appearance || previousFlipped != isFlipped else { return }
        let components: [(down: CGFloat, blur: CGFloat, hex: String)] = appearance == .dark
            ? [(14, 50, "00000080")]
            : [(12, 40, "0000001f"), (1, 3, "0000000a")]
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if self.host !== host { for layer in layers { layer.removeFromSuperlayer() } }
        self.host = host
        while layers.count > components.count { layers.removeLast().removeFromSuperlayer() }
        while layers.count < components.count { layers.append(CALayer()) }
        let path = CGPath(roundedRect: CGRect(origin: .zero, size: surfaceRect.size),
                          cornerWidth: NativeRadius.popover, cornerHeight: NativeRadius.popover, transform: nil)
        for (index, component) in components.enumerated() {
            let layer = layers[index]
            if layer.superlayer !== host { host.insertSublayer(layer, at: UInt32(index)) }
            layer.frame = surfaceRect
            layer.shadowPath = path
            layer.shadowColor = NSColor(nativeHex: component.hex).cgColor
            layer.shadowOpacity = 1
            layer.shadowRadius = component.blur
            layer.shadowOffset = CGSize(width: 0, height: isFlipped ? component.down : -component.down)
            layer.masksToBounds = false; layer.shouldRasterize = false
        }
        CATransaction.commit()
        previousRect = surfaceRect; previousAppearance = appearance; previousFlipped = isFlipped
    }

    func dispose() {
        for layer in layers { layer.removeFromSuperlayer(); layer.shadowPath = nil }
        layers = []; host = nil
        previousRect = nil; previousAppearance = nil; previousFlipped = nil
    }
}
