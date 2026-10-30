import Foundation

/// Existing Calendar/slot-focus tokens. Step dimensions are owned by Core's profile.
enum BoardLayoutMetrics {
    static let gap: CGFloat = CGFloat(PanelStepProfile.gap)
    static let padding: CGFloat = CGFloat(PanelStepProfile.padding)
    static let mediumBreakpoint: CGFloat = 1350, compactBreakpoint: CGFloat = 1250
    static let slotFocusWidth: CGFloat = 3
}
struct BoardLayoutGeometry {
    var contentSize: CGSize = .zero
    var calendar: CGRect = .zero
    var slots: [SlotID: CGRect] = [:]
    var dividers: [LayoutSplit: CGRect] = [:]
    var candidates: [LayoutSplit: [LayoutStepCandidate]] = [:]
    var effectiveSteps = LayoutSteps()
    var profile: PanelStepProfile?
    /// Transparent space only: never rendered or registered for hit, focus or AX.
    var railBlank: CGRect?

    var gridProfile: GridGeometryProfile?
    var pitchX: CGFloat { CGFloat(gridProfile?.pitchX ?? 0) }
    var pitchY: CGFloat = 0
    func frame(for rect: GridRect) -> CGRect {
        guard let profile = gridProfile else { return .zero }
        var frame = profile.frame(for: rect)
        frame.origin.y = CGFloat(GridGeometryProfile.padding) + CGFloat(rect.row) * pitchY
        frame.size.height = CGFloat(rect.height) * pitchY - CGFloat(GridGeometryProfile.gap)
        return frame
    }
    static func make(viewport: CGSize, layout: BoardLayout) -> BoardLayoutGeometry {
        var result = BoardLayoutGeometry()
        guard let profile = try? GridGeometryProfile(viewport: LayoutViewport(width: viewport.width, height: viewport.height)) else { return result }
        result.gridProfile = profile
        let visible = layout.placements.filter { $0.key == .calendar || !layout.hiddenSlots.contains($0.key.rawValue) }
        let lastRow = visible.values.map { $0.row + $0.height }.max() ?? 0
        result.pitchY = CGFloat(profile.pitchY)
        // Project saved geometry only as far as every visible panel's minimum permits.
        // The stored grid remains untouched; impossible layouts retain necessary overflow.
        if viewport.width >= CGFloat(2 * GridGeometryProfile.padding - GridGeometryProfile.gap + Double(GridGeometryProfile.columns) * 52), viewport.height >= 600, lastRow > 0 {
            let minimumPitch = visible.map { item, rect in
                CGFloat((item == .calendar ? 13.0 : 4.0) * profile.pitchY) / CGFloat(rect.height)
            }.max() ?? CGFloat(profile.pitchY)
            let fitPitch = (viewport.height - CGFloat(2 * GridGeometryProfile.padding - GridGeometryProfile.gap)) / CGFloat(lastRow)
            result.pitchY = min(CGFloat(profile.pitchY), max(minimumPitch, fitPitch))
        }
        result.contentSize = CGSize(width: max(viewport.width, CGFloat(2 * GridGeometryProfile.padding - GridGeometryProfile.gap) + CGFloat(GridGeometryProfile.columns) * result.pitchX),
                                    height: max(viewport.height, CGFloat(2 * GridGeometryProfile.padding - GridGeometryProfile.gap) + CGFloat(lastRow) * result.pitchY))
        if let rect = visible[.calendar] { result.calendar = result.frame(for: rect) }
        for slot in SlotID.allCases {
            if let item = GridItemID(rawValue: slot.rawValue), let rect = visible[item] { result.slots[slot] = result.frame(for: rect) }
        }
        result.profile = try? PanelStepProfile(viewport: LayoutViewport(width: viewport.width, height: viewport.height))
        return result
    }
}
