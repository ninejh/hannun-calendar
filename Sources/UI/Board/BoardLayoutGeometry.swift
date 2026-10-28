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

    static func make(viewport: CGSize, layout: BoardLayout) -> BoardLayoutGeometry {
        let viewportValue = LayoutViewport(width: viewport.width, height: viewport.height)
        guard let profile = try? PanelStepProfile(viewport: viewportValue),
              let steps = try? LayoutStepResolver.effectiveSteps(layout: layout, profile: profile) else { return BoardLayoutGeometry() }
        let pad = CGFloat(PanelStepProfile.padding), gap = CGFloat(PanelStepProfile.gap)
        let width = CGFloat(profile.contentWidth), height = CGFloat(profile.contentHeight)
        let visibleRail = profile.visibleRailSlots(hiddenSlots: layout.hiddenSlots)
        let railWidth = CGFloat(profile.railWidth(steps.column))
        let leftWidth = visibleRail.isEmpty ? width : width - gap - railWidth
        let wide = !layout.hiddenSlots.contains(SlotID.wide.rawValue)
        let wideHeight = CGFloat(profile.height(.wide, step: steps.main))
        let calendarHeight = wide ? height - gap - wideHeight : height
        var result = BoardLayoutGeometry(contentSize: viewport, calendar: CGRect(x: pad, y: pad, width: leftWidth, height: calendarHeight), effectiveSteps: steps, profile: profile)
        if wide { result.slots[.wide] = CGRect(x: pad, y: pad + calendarHeight + gap, width: leftWidth, height: wideHeight) }
        let railX = pad + leftWidth + gap
        var upperEnd = pad
        for slot in visibleRail where slot != .railBottom {
            let slotHeight = CGFloat(profile.height(slot, step: steps[slot]))
            let y = upperEnd == pad ? pad : upperEnd + gap
            result.slots[slot] = CGRect(x: railX, y: y, width: railWidth, height: slotHeight)
            upperEnd = y + slotHeight
        }
        if visibleRail.contains(.railBottom) {
            let bottomHeight = CGFloat(profile.height(.railBottom, step: steps.railBottom))
            result.slots[.railBottom] = CGRect(x: railX, y: pad + height - bottomHeight, width: railWidth, height: bottomHeight)
        }
        let blank = profile.railBlankHeight(steps: steps, hiddenSlots: layout.hiddenSlots)
        if !visibleRail.isEmpty, blank > PanelStepProfile.tolerance {
            let blankY = upperEnd + (visibleRail.contains(.railBottom) && visibleRail.count > 1 ? gap : 0)
            result.railBlank = CGRect(x: railX, y: blankY, width: railWidth, height: CGFloat(blank))
        }
        for split in LayoutSplit.allCases {
            guard let candidates = try? LayoutStepResolver.candidates(layout: layout, split: split, viewport: viewportValue) else { continue }
            result.candidates[split] = candidates
            let position = CGFloat(profile.dividerPosition(split, steps: steps)), hit = NativeSize.dividerHit
            result.dividers[split] = switch split {
            case .column: CGRect(x: position - hit / 2, y: pad, width: hit, height: height)
            case .main: CGRect(x: pad, y: position - hit / 2, width: leftWidth, height: hit)
            case .rail, .railBottom: CGRect(x: railX, y: position - hit / 2, width: railWidth, height: hit)
            }
        }
        return result
    }
}
