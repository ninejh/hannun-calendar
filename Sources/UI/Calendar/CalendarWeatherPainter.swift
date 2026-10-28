import AppKit

/// R4's eight 24-unit weather outlines use the existing theme's semantic accents.
@MainActor enum CalendarWeatherPainter {
    private static let lightSun = NativeTheme(appearance: .light).color(.warning)
    private static let darkSun = NativeTheme(appearance: .dark).color(.warning)
    private static let lightPrecipitation = NativeTheme(appearance: .light).color(.accentBlue)
    private static let darkPrecipitation = NativeTheme(appearance: .dark).color(.accentBlue)

    static func draw(_ key: String, in rect: CGRect, color: NSColor, appearance: ResolvedAppearance = .light) {
        guard rect.width > 0, rect.height > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        let transform = AffineTransform(translationByX: rect.minX, byY: rect.minY)
        (transform as NSAffineTransform).concat()
        let scale = AffineTransform(scaleByX: rect.width / 24, byY: rect.height / 24)
        (scale as NSAffineTransform).concat()
        color.setStroke()
        func line(_ points: [CGPoint]) {
            let path = NSBezierPath(); path.lineWidth = 1.5; path.lineCapStyle = .round; path.lineJoinStyle = .round
            guard let first = points.first else { return }; path.move(to: first); for point in points.dropFirst() { path.line(to: point) }; path.stroke()
        }
        func sun() {
            let path = NSBezierPath(ovalIn: CGRect(x: 7, y: 7, width: 10, height: 10)); path.lineWidth = 1.5; path.stroke()
            for angle in stride(from: 0.0, to: .pi * 2, by: .pi / 4) { line([CGPoint(x: 12 + cos(angle) * 8, y: 12 + sin(angle) * 8), CGPoint(x: 12 + cos(angle) * 10, y: 12 + sin(angle) * 10)]) }
        }
        func cloud() {
            let path = NSBezierPath(); path.lineWidth = 1.5; path.lineCapStyle = .round
            path.move(to: CGPoint(x: 6, y: 16)); path.curve(to: CGPoint(x: 5, y: 9), controlPoint1: CGPoint(x: 0, y: 16), controlPoint2: CGPoint(x: 1, y: 9))
            path.curve(to: CGPoint(x: 17, y: 8), controlPoint1: CGPoint(x: 5, y: 1), controlPoint2: CGPoint(x: 16, y: 1))
            path.curve(to: CGPoint(x: 19, y: 16), controlPoint1: CGPoint(x: 24, y: 7), controlPoint2: CGPoint(x: 24, y: 16)); path.line(to: CGPoint(x: 6, y: 16)); path.stroke()
        }
        switch key {
        case "weather.clear": (appearance == .dark ? darkSun : lightSun).setStroke(); sun()
        case "weather.fog": for y in [8, 12, 16] { line([CGPoint(x: 3, y: y), CGPoint(x: 21, y: y)]) }
        case "weather.partly_cloudy": (appearance == .dark ? darkSun : lightSun).setStroke(); let path = NSBezierPath(ovalIn: CGRect(x: 3, y: 2, width: 9, height: 9)); path.lineWidth = 1.5; path.stroke(); color.setStroke(); cloud()
        default:
            cloud()
            (appearance == .dark ? darkPrecipitation : lightPrecipitation).setStroke()
            if key == "weather.drizzle" || key == "weather.rain" { for x in [7, 12, 17] { line([CGPoint(x: x, y: 19), CGPoint(x: x - (key == "weather.rain" ? 2 : 0), y: 22)]) } }
            if key == "weather.snow" { for x in [8, 16] { line([CGPoint(x: x - 2, y: 21), CGPoint(x: x + 2, y: 21)]); line([CGPoint(x: x, y: 19), CGPoint(x: x, y: 23)]) } }
            if key == "weather.thunderstorm" { line([CGPoint(x: 13, y: 16), CGPoint(x: 10, y: 19), CGPoint(x: 14, y: 19), CGPoint(x: 11, y: 22)]) }
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}
