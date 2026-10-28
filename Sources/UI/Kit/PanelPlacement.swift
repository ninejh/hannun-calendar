import AppKit

/// Steps belong to physical slots. Geometry is logical points, never inferred from panel height.
enum PanelShape: String, Sendable { case wide, rail }
struct PanelPlacement: Equatable, Sendable {
    var slot: SlotID?
    var shape: PanelShape
    var heightStep: PanelSizeStep
    var railWidthStep: PanelSizeStep
    var frame: CGRect
    var headerRect: CGRect
    var contentRect: CGRect
}
struct PanelContentRegions: Equatable, Sendable {
    var headerRect: CGRect
    var contentRect: CGRect
}
/// Complete visible rows only. Long subscription rows supply their measured heights separately.
struct NativePanelRowMetrics: Equatable, Sendable {
    var height: CGFloat
    var gap: CGFloat = 0
    func capacity(in availableHeight: CGFloat) -> Int {
        guard availableHeight.isFinite, availableHeight >= height, height > 0, gap >= 0 else { return 0 }
        return Int(floor((availableHeight + gap) / (height + gap)))
    }
}
/// DS4.4 / SCR01.5.G. Regular/Large preserve the approved panel's actual header override.
struct NativePanelStepMetrics: Equatable, Sendable {
    var panel: PanelID
    var shape: PanelShape
    var step: PanelSizeStep
    var headerHeight: CGFloat {
        switch step { case .tiny: shape == .wide ? 28 : 24; case .small: 38; default: shape == .wide ? 46 : 38 }
    }
    var horizontalPadding: CGFloat {
        switch step { case .tiny: 12; case .small: 14; default: panel == .notes || shape == .wide ? 18 : 14 }
    }
    var bottomPadding: CGFloat { switch step { case .tiny: 8; case .small: 12; default: 14 } }
    var itemGap: CGFloat { switch step { case .tiny: 4; case .small: 6; default: 12 } }
    var notesLineHeight: CGFloat { step == .tiny ? NativeSize.notesCompactLineHeight : NativeSize.notesLineHeight }
    @MainActor var headerFont: NSFont { NativeFont.sectionHead }
    @MainActor var notesFont: NSFont { NativeFont.body }
    @MainActor var bodyFont: NSFont {
        switch panel {
        case .today, .projects: NativeFont.bodyStrong
        case .deadlines: NativeFont.bodyStrongCompact
        default: NativeFont.body
        }
    }
    @MainActor var metadataFont: NSFont {
        switch panel {
        case .projects, .todos, .habits: NativeFont.badge
        case .focusTimer: NativeFont.primary
        default: NativeFont.meta
        }
    }
    @MainActor var numericFont: NSFont {
        switch panel {
        case .worldClock: NativeFont.clockTime
        case .focusTimer: shape == .rail && step == .tiny ? NativeFont.timerCompact : NativeFont.timer
        case .deadlines: NativeFont.countdown
        default: NativeFont.body
        }
    }
    /// Nil for variable-height content and wide card decks; callers keep their actual card geometry.
    var listRow: NativePanelRowMetrics? {
        switch panel {
        case .today:
            return NativePanelRowMetrics(height: step == .tiny ? 24 : step == .small ? 32 : 48,
                                         gap: step == .small && shape == .rail ? 4 : 0)
        case .deadlines:
            return shape == .wide && (step == .tiny || step == .small) ? nil :
                NativePanelRowMetrics(height: step == .tiny ? 26 : step == .small ? 32 : 48)
        case .subscriptions:
            return NativePanelRowMetrics(height: step == .tiny || step == .small ? 28 : 32)
        case .todos:
            return NativePanelRowMetrics(height: step == .tiny ? 26 : step == .small ? 28 : 32, gap: step == .small ? 4 : 0)
        case .projects where shape == .rail:
            return NativePanelRowMetrics(height: step == .tiny ? 54 : step == .small ? 112 : 160,
                                         gap: step == .tiny ? 0 : step == .small ? 8 : 12)
        case .habits where shape == .rail:
            return NativePanelRowMetrics(height: step == .tiny ? 46 : step == .small ? 52 : 60, gap: step == .small ? 6 : 0)
        case .worldClock where shape == .rail:
            return NativePanelRowMetrics(height: step == .tiny ? 44 : step == .small ? 56 : 64, gap: step == .tiny ? 0 : 6)
        default: return nil
        }
    }
    var settingsRow: NativePanelRowMetrics? {
        guard panel == .focusTimer, step == .tiny || step == .small else { return nil }
        return NativePanelRowMetrics(height: step == .tiny ? 26 : 28)
    }
    var minimumCardWidth: CGFloat? {
        switch panel {
        case .projects: NativeSize.projectMinWidth
        case .deadlines: 140
        case .habits: 180
        case .worldClock: 130
        default: nil
        }
    }
    var cardGap: CGFloat { panel == .deadlines ? 8 : 12 }
    func columnCapacity(in width: CGFloat) -> Int {
        guard shape == .wide, let minimumCardWidth, width.isFinite else { return 1 }
        let count = max(1, Int(floor((max(0, width - horizontalPadding * 2) + cardGap) / (minimumCardWidth + cardGap))))
        return panel == .worldClock ? min(4, count) : count
    }
    func regions(in bounds: CGRect, headerHeight actualHeader: CGFloat? = nil) -> PanelContentRegions {
        let header = min(max(0, actualHeader ?? headerHeight), max(0, bounds.height))
        return PanelContentRegions(headerRect: CGRect(x: bounds.minX, y: bounds.minY, width: max(0, bounds.width), height: header),
            contentRect: CGRect(x: bounds.minX + horizontalPadding, y: bounds.minY + header,
                                width: max(0, bounds.width - horizontalPadding * 2), height: max(0, bounds.height - header - bottomPadding)))
    }
}
/// Metadata on the existing painted title; this creates no view, layer or second AX node.
struct PanelHeaderGeometry: Equatable, Sendable {
    var slot: SlotID
    var titleRect: CGRect
    var headerRect: CGRect
    var excludedRects: [CGRect]
    static func identifier(for slot: SlotID) -> String { "slot.\(slot.rawValue).header" }
    var identifier: String { Self.identifier(for: slot) }
    func contains(_ point: CGPoint) -> Bool {
        headerRect.contains(point) && !excludedRects.contains { $0.contains(point) }
    }
}
enum NativePanelHeader {
    static func decorate(_ item: NativeRenderItem, geometry: PanelHeaderGeometry) -> NativeRenderItem {
        var header = item; header.panelHeader = geometry; return header
    }
}
