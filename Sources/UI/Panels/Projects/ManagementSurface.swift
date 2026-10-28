import AppKit

/// Domain-specific paint on the shared canvas; cards and rows never own layers or views.
@MainActor class ManagementCanvas: NativeCanvasView {
    enum Style { case heading, title, singleTitle, deadlineTitle, metadata, secondary, countdown, progress(Int), progressSummary(Int), card, status, plain, hitSurface, dot, message }
    var styles: [String: Style] = [:]
    var displayLabels: [String: String] = [:]
    var tints: [String: String] = [:]
    var onLayout: (@MainActor () -> Void)?
    var onProgress: (@MainActor (String, Int) -> Void)?
    private var dragSlider: String?
    override func layout() { super.layout(); onLayout?() }
    override func paint(_ item: NativeRenderItem) {
        guard let style = styles[item.id] else { super.paint(item); return }
        switch style {
        case .dot:
            (tints[item.id].map { NSColor(nativeHex: $0) } ?? theme.color(.accentBlue)).setFill()
            NSBezierPath(ovalIn: item.rect.insetBy(dx: NativeSpace.sm, dy: NativeSpace.sm)).fill()
        case .hitSurface:
            var background = item; background.label = ""; super.paint(background)
        case .card:
            let path = NSBezierPath(roundedRect: item.rect, xRadius: NativeRadius.card, yRadius: NativeRadius.card)
            theme.color(.cardProjectBg).setFill(); path.fill()
            theme.color(.cardProjectBorder).setStroke(); path.lineWidth = 1; path.stroke()
        case .progress(let value), .progressSummary(let value):
            let track = CGRect(x: item.rect.minX + NativeSpace.sm, y: item.rect.midY - NativeSpace.xxs, width: max(0, item.rect.width - NativeSpace.lg), height: NativeSpace.xs)
            theme.color(.lineStrong).setFill(); NSBezierPath(roundedRect: track, xRadius: NativeSpace.xxs, yRadius: NativeSpace.xxs).fill()
            var fill = track; fill.size.width *= CGFloat(value) / 100
            (tints[item.id].map { NSColor(nativeHex: $0) } ?? theme.color(.accentBlue)).setFill()
            NSBezierPath(roundedRect: fill, xRadius: NativeSpace.xxs, yRadius: NativeSpace.xxs).fill()
            if case .progress = style {
                let knob = CGRect(x: track.minX + track.width * CGFloat(value) / 100 - NativeSpace.xs, y: track.midY - NativeSpace.xs, width: NativeSpace.sm, height: NativeSpace.sm)
                NSBezierPath(ovalIn: knob).fill()
            }
            drawFocus(item)
        default:
            // Shared canvas supplies immediate hover/press/focus; specialized typography draws over it.
            var background = item; background.label = ""; super.paint(background)
            if case .status = style {
                theme.color(.projectStatusBorder).setStroke(); let border = NSBezierPath(roundedRect: item.rect, xRadius: item.radius, yRadius: item.radius); border.lineWidth = 1; border.stroke()
            }
            let font: NSFont
            switch style { case .heading: font = NativeFont.sectionHead; case .title, .singleTitle: font = NativeFont.bodyStrong; case .deadlineTitle: font = NativeFont.bodyStrongCompact; case .metadata: font = NativeFont.meta; case .secondary: font = NativeFont.badge; case .countdown: font = NativeFont.countdown; default: font = NativeFont.primary }
            let text = item.rect.insetBy(dx: NativeSpace.sm, dy: 0)
            let height = font.pointSize * 1.3
            var rect = CGRect(x: text.minX, y: text.midY - height / 2, width: max(0, text.width), height: height)
            if styleIsTitle(style) { rect.origin.y = text.minY + NativeSpace.xs; rect.size.height = max(height, text.height - NativeSpace.sm) }
            NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect: item.rect).addClip()
            ((displayLabels[item.id] ?? item.label) as NSString).draw(in: rect, withAttributes: NativeFont.attributes(font: font, color: theme.color(item.color), lineHeight: height, truncation: styleIsTitle(style) ? .byWordWrapping : .byTruncatingTail))
            NSGraphicsContext.restoreGraphicsState()
        }
    }
    /// Fade only the visible clip viewport; never cache a full document or a removed card bitmap.
    static func disclose(in scroll: OverflowScrollView, reduceMotion: Bool) {
        scroll.contentView.wantsLayer = true
        guard let layer = scroll.contentView.layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = layer.presentation()?.opacity ?? 0.6; fade.toValue = 1
        fade.duration = reduceMotion ? MotionDuration.reducedFade : MotionDuration.fast
        fade.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
        layer.add(fade, forKey: "management.disclosure")
    }
    private func styleIsTitle(_ style: Style) -> Bool { switch style { case .title, .message: true; default: false } }
    private func drawFocus(_ item: NativeRenderItem) {
        guard focus.keyboardFocus, focus.focusedID == FocusID(item.id) else { return }
        theme.color(.accentBlue).setStroke(); let path = NSBezierPath(roundedRect: item.rect.insetBy(dx: -NativeSize.focusOffset, dy: -NativeSize.focusOffset), xRadius: NativeRadius.button, yRadius: NativeRadius.button); path.lineWidth = NativeSize.focusWidth; path.stroke()
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let item = item(at: point), item.kind == .slider {
            dragSlider = item.id; window?.makeFirstResponder(self); focus.focus(FocusID(item.id), keyboard: false); trackProgress(point); return
        }
        super.mouseDown(with: event)
    }
    override func mouseDragged(with event: NSEvent) {
        if dragSlider != nil { trackProgress(convert(event.locationInWindow, from: nil)); return }
        super.mouseDragged(with: event)
    }
    override func mouseUp(with event: NSEvent) {
        if dragSlider != nil { trackProgress(convert(event.locationInWindow, from: nil)); dragSlider = nil; return }
        super.mouseUp(with: event)
    }
    private func trackProgress(_ point: CGPoint) {
        guard let id = dragSlider, let item = items.first(where: { $0.id == id }) else { return }
        let fraction = (point.x - item.rect.minX - NativeSpace.sm) / max(1, item.rect.width - NativeSpace.lg)
        onProgress?(id, min(100, max(0, Int((fraction * 100).rounded()))))
    }
}
@MainActor final class ManagementPanelView: PanelContainerView {
    override var separatesBackgroundPlane: Bool { false }
    var onLayout: (@MainActor () -> Void)?
    var displayLabels: [String: String] = [:]
    override func layout() { super.layout(); onLayout?() }
    override func paint(_ item: NativeRenderItem) {
        var visible = item; visible.label = displayLabels[item.id] ?? item.label; super.paint(visible)
    }
}

@MainActor enum ManagementCopy {
    static func date(_ day: DateOnly, context: BoardScreenContext) -> String {
        let language = context.presentation.state.snapshot.board.settings.language
        return DayMath.text(day.date(in: TimeZone(secondsFromGMT: 0)!), format: language == .ko ? "M월 d일" : "MMM d", timeZone: TimeZone(secondsFromGMT: 0)!, locale: Locale(identifier: language == .ko ? "ko_KR" : "en_US"))
    }
    static func tomorrow(_ today: DateOnly) -> DateOnly {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(byAdding: .day, value: 1, to: today.date(in: calendar.timeZone)).flatMap { DateOnly(date: $0, timeZone: calendar.timeZone) } ?? today
    }
    static func status(_ value: ProjectStatus) -> String {
        switch value { case .active: "projects.status_in_progress"; case .waiting: "projects.status_on_hold"; case .done: "projects.status_done" }
    }
}
