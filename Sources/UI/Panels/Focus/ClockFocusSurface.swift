import AppKit

/// Shared by the two T-028 panels. The kit still owns hit testing, AX and keyboard routing.
@MainActor class ClockFocusCanvas: NativeCanvasView {
    var excludedPaintIDs: Set<String> = []
    var fonts: [String: NSFont] = [:]
    var visibleLabels: [String: String] = [:]
    var dayNight: [String: Bool] = [:]
    var gaugeFraction: Double = 0
    var gaugeColor: NativeColorToken = .timerFocus
    override func paint(_ item: NativeRenderItem) {
        guard !excludedPaintIDs.contains(item.id) else { return }
        if item.id == "focusTimer.gauge" {
            let center = item.rect.center
            let radius = max(0, min(item.rect.width, item.rect.height) / 2 - NativeSpace.xs)
            let track = NSBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            track.lineWidth = NativeSpace.xs; theme.color(.timerTrack).setStroke(); track.stroke()
            if gaugeFraction > 0 {
                let arc = NSBezierPath(); arc.appendArc(withCenter: center, radius: radius, startAngle: -90,
                    endAngle: -90 + CGFloat(min(1, max(0, gaugeFraction))) * 360, clockwise: false)
                arc.lineWidth = NativeSpace.xs; arc.lineCapStyle = .round; theme.color(gaugeColor).setStroke(); arc.stroke()
            }
            return
        }
        guard let font = fonts[item.id] else {
            var visual = item; visual.label = visibleLabels[item.id] ?? item.label
            super.paint(visual); return
        }
        if let fill = item.fill {
            theme.color(fill).setFill(); NSBezierPath(roundedRect: item.rect, xRadius: item.radius, yRadius: item.radius).fill()
        }
        let text = visibleLabels[item.id] ?? item.label
        let height = ceil(font.ascender - font.descender + font.leading)
        var rect = item.rect.insetBy(dx: NativeSpace.sm, dy: 0)
        rect.origin.y = item.rect.midY - height / 2; rect.size.height = height
        if let isDay = dayNight[item.id] {
            let iconSize = NativeSpace.md
            let iconRect = CGRect(x: rect.minX, y: item.rect.midY - iconSize / 2, width: iconSize, height: iconSize)
            let symbol = NSImage(systemSymbolName: isDay ? "sun.max" : "moon", accessibilityDescription: nil)
            symbol?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [theme.color(item.color)]))?.draw(in: iconRect)
            rect.origin.x += iconSize + NativeSpace.xs; rect.size.width = max(0, rect.width - iconSize - NativeSpace.xs)
        }
        NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect: item.rect).addClip()
        var attributes = NativeFont.attributes(font: font, color: theme.color(item.color), lineHeight: height)
        if item.id == "focusTimer.time", let paragraph = attributes[.paragraphStyle] as? NSParagraphStyle,
           let centered = paragraph.mutableCopy() as? NSMutableParagraphStyle {
            centered.alignment = .center; attributes[.paragraphStyle] = centered
        }
        (text as NSString).draw(in: rect, withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Visual-only bounded backing; the original content canvas remains the sole AX owner.
@MainActor final class ClockFocusDialCanvas: ClockFocusCanvas {
    override init(frame: NSRect = .zero, focus: FocusCoordinator = FocusCoordinator(), accessibilityNotifications: any NativeAccessibilityNotifications = SystemNativeAccessibilityNotifications()) {
        super.init(frame: frame, focus: focus, accessibilityNotifications: accessibilityNotifications)
        wantsLayer = true; setAccessibilityElement(false); setAccessibilityHidden(true)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func accessibilityChildren() -> [Any]? { [] }
}

@MainActor final class ClockFocusPanelSurface: PanelContainerView {
    var onLayout: (@MainActor () -> Void)?
    var onVisibility: (@MainActor () -> Void)?
    override func layout() { super.layout(); onLayout?() }
    override func viewDidHide() { super.viewDidHide(); onVisibility?() }
    override func viewDidUnhide() { super.viewDidUnhide(); onVisibility?() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); onVisibility?() }
    override func dispose() { onLayout = nil; onVisibility = nil; super.dispose() }
}

/// A bounded dial-sized feedback surface, avoiding a second bitmap-backed panel layer.
@MainActor final class ClockFocusPulseView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true; setAccessibilityElement(false); setAccessibilityHidden(true)
        layer?.opacity = 0
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// One small feedback layer for the limit message; AX remains on the canvas's static text.
@MainActor final class ClockFocusInlineNoticeView: NSView {
    var text = "" { didSet { if text != oldValue { needsDisplay = true } } }
    var theme = NativeTheme(appearance: .dark)
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true; isHidden = true
        setAccessibilityElement(false); setAccessibilityHidden(true)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        (text as NSString).draw(in: bounds.insetBy(dx: NativeSpace.sm, dy: NativeSpace.sm), withAttributes:
            NativeFont.attributes(font: NativeFont.primary, color: theme.color(.danger), truncation: .byWordWrapping))
    }
}
