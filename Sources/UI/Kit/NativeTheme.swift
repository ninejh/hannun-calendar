import AppKit

enum NativeColorToken: String, CaseIterable {
    case bg = "color.bg"
    case panel = "color.panel"
    case panelNativeBorder = "color.panel.native.border"
    case cardProjectBg = "color.card.project.bg"
    case cardProjectBorder = "color.card.project.border"
    case projectStatusBg = "color.project.status.bg"
    case projectStatusBorder = "color.project.status.border"
    case raised = "color.raised"
    case hover = "color.hover"
    case selected = "color.selected"
    case line = "color.line"
    case lineSubtle = "color.line.subtle"
    case lineStrong = "color.line.strong"
    case textPrimary = "color.text"
    case textSecondary = "color.text.secondary"
    case textQuiet = "color.text.quiet"
    case fill = "color.fill"
    case fillHover = "color.fill.hover"
    case accentBlue = "color.accent.blue"
    case danger = "color.danger"
    case warning = "color.warning"
    case success = "color.success"
    case popoverBg = "color.popover.bg"
    case toastBg = "color.toast.bg"
    case toastText = "color.toast.text"
    case slotMenuBg = "color.slot.menu.bg"
    case slotMenuBorder = "color.slot.menu.border"
    case focusSlot = "color.focus.slot"
    case badgeOfflineBg = "color.badge.offline.bg"
    case badgeOfflineText = "color.badge.offline.text"
    case badgeOfflineDot = "color.badge.offline.dot"
    case habitDoneBg = "color.habit.done.bg"
    case habitDoneText = "color.habit.done.text"
    case habitEmptyBorder = "color.habit.empty.border"
    case checkboxBorder = "color.checkbox.border"
    case habitStreak = "color.habit.streak"
    case timerFocus = "color.timer.focus"
    case timerBreak = "color.timer.break"
    case timerBreakText = "color.timer.break.text"
    case timerTrack = "color.timer.track"
    case weatherCredit = "color.weather.credit"
}
@MainActor struct NativeTheme {
    var appearance: ResolvedAppearance
    func color(_ token: NativeColorToken) -> NSColor {
        let hex: String
        switch token {
        case .bg: hex = appearance == .dark ? "111315" : "f4f6f8"
        case .panel: hex = appearance == .dark ? "1b1e22" : "ffffff"
        case .panelNativeBorder: hex = appearance == .dark ? "ffffff1a" : "00000014"
        case .cardProjectBg: hex = appearance == .dark ? "272b32" : "f0f3f7"
        case .cardProjectBorder: hex = appearance == .dark ? "ffffff10" : "00000010"
        case .projectStatusBg: hex = appearance == .dark ? "2b323c" : "e4e8ee"
        case .projectStatusBorder: hex = appearance == .dark ? "3d4653" : "b0b8c4"
        case .raised: hex = appearance == .dark ? "24282e" : "edf0f4"
        case .hover: hex = appearance == .dark ? "2a2f37" : "e4e7ed"
        case .selected: hex = appearance == .dark ? "26354c" : "e3ecfa"
        case .line: hex = appearance == .dark ? "30353c" : "d5dae2"
        case .lineSubtle: hex = appearance == .dark ? "ffffff0c" : "0000000e"
        case .lineStrong: hex = appearance == .dark ? "ffffff24" : "b8c0cc"
        case .textPrimary: hex = appearance == .dark ? "edf0f5" : "181b1f"
        case .textSecondary: hex = appearance == .dark ? "a6aebc" : "535c6a"
        case .textQuiet: hex = appearance == .dark ? "909dac" : "586271"
        case .fill: hex = appearance == .dark ? "396ed7" : "2c6ee8"
        case .fillHover: hex = appearance == .dark ? "2b5ec4" : "205dc9"
        case .accentBlue: hex = appearance == .dark ? "9bb7ee" : "1c5ed2"
        case .danger: hex = appearance == .dark ? "e2a0a7" : "be2b3a"
        case .warning: hex = appearance == .dark ? "dbbd8e" : "8e5900"
        case .success: hex = appearance == .dark ? "98c8b2" : "0f734c"
        case .popoverBg: hex = appearance == .dark ? "252930" : "ffffff"
        case .toastBg: hex = appearance == .dark ? "303844" : "252a32"
        case .toastText: hex = appearance == .dark ? "edf0f5" : "ffffff"
        case .slotMenuBg: hex = appearance == .dark ? "252930" : "ffffff"
        case .slotMenuBorder: hex = appearance == .dark ? "ffffff24" : "00000018"
        case .focusSlot: hex = appearance == .dark ? "9bb7ee" : "1c5ed2"
        case .badgeOfflineBg: hex = appearance == .dark ? "262a32" : "eceef2"
        case .badgeOfflineText: hex = appearance == .dark ? "9aa6b8" : "545d6c"
        case .badgeOfflineDot: hex = appearance == .dark ? "828f9f" : "738092"
        case .habitDoneBg: hex = appearance == .dark ? "2ed573" : "0f734c"
        case .habitDoneText: hex = appearance == .dark ? "111315" : "ffffff"
        case .habitEmptyBorder: hex = appearance == .dark ? "768497" : "738092"
        case .checkboxBorder: hex = appearance == .dark ? "768497" : "738092"
        case .habitStreak: hex = appearance == .dark ? "f59e0b" : "8e5900"
        case .timerFocus: hex = appearance == .dark ? "9bb7ee" : "1c5ed2"
        case .timerBreak: hex = appearance == .dark ? "2ed573" : "0f734c"
        case .timerBreakText: hex = appearance == .dark ? "111315" : "ffffff"
        case .timerTrack: hex = appearance == .dark ? "768497" : "738092"
        case .weatherCredit: hex = appearance == .dark ? "909dac" : "586271"
        }
        return NSColor(nativeHex: hex)
    }
    var panelGradient: NSGradient {
        NSGradient(starting: NSColor(nativeHex: appearance == .dark ? "252930f2" : "ffffffea"),
                   ending: NSColor(nativeHex: appearance == .dark ? "1c1f25f2" : "f5f7faea"))!
    }
}
extension NSColor {
    convenience init(nativeHex: String) {
        let value = UInt64(nativeHex, radix: 16) ?? 0
        let hasAlpha = nativeHex.count == 8
        let rgb = hasAlpha ? value >> 8 : value
        self.init(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
                  blue: CGFloat(rgb & 255) / 255, alpha: hasAlpha ? CGFloat(value & 255) / 255 : 1)
    }
}

enum NativeCalendarTint: String, CaseIterable { case mint, purple, amber, red, peach, sky, rose, blue }
@MainActor extension NativeTheme {
    func tint(_ tint: NativeCalendarTint, background: Bool = false) -> NSColor {
        let hex: String
        switch tint {
        case .mint: hex = appearance == .dark ? (background ? "1f2824" : "98c8b2") : (background ? "edf7f2" : "0f734c")
        case .purple: hex = appearance == .dark ? (background ? "27232e" : "b8a7df") : (background ? "f4f0fa" : "6f42c1")
        case .amber: hex = appearance == .dark ? (background ? "2c2720" : "dbbd8e") : (background ? "faf5eb" : "8e5900")
        case .red: hex = appearance == .dark ? (background ? "2d2325" : "e2a0a7") : (background ? "fdf0f2" : "be2b3a")
        case .peach: hex = appearance == .dark ? (background ? "2c2421" : "dca891") : (background ? "fcf2ed" : "a64918")
        case .sky: hex = appearance == .dark ? (background ? "21272c" : "97bbd3") : (background ? "eff6fa" : "126a9f")
        case .rose: hex = appearance == .dark ? (background ? "2a2327" : "d2a2bc") : (background ? "faeef4" : "a4376c")
        case .blue: hex = appearance == .dark ? (background ? "21252d" : "9bb7ee") : (background ? "eff4fd" : "1c5ed2")
        }
        return NSColor(nativeHex: hex)
    }
}
