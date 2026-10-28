import AppKit

extension NSColor {
    convenience init(hex: String) {
        let value = UInt64(hex, radix: 16) ?? 0x557C68
        self.init(srgbRed: Double((value >> 16) & 255) / 255,
                  green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, alpha: 1)
    }
}

extension AppAppearance {
    var nsAppearance: NSAppearance? {
        self == .system ? nil : NSAppearance(named: self == .dark ? .darkAqua : .aqua)
    }
}
