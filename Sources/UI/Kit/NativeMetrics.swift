import AppKit

@MainActor enum NativeFont {
    static let monthTitleCompact = NSFont.systemFont(ofSize: 20, weight: .bold)
    static let monthTitle = NSFont.systemFont(ofSize: 22, weight: .bold)
    static let yearTitle = NSFont.systemFont(ofSize: 15, weight: .regular)
    static let sectionHead = NSFont.systemFont(ofSize: 14, weight: .semibold)
    static let body = NSFont.systemFont(ofSize: 13, weight: .regular)
    static let bodyStrong = NSFont.systemFont(ofSize: 14, weight: .semibold)
    static let bodyStrongCompact = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let meta = NSFont.systemFont(ofSize: 11, weight: .regular)
    static let agendaTime = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    static let toolbar = NSFont.systemFont(ofSize: 11, weight: .medium)
    static let primary = NSFont.systemFont(ofSize: 12, weight: .semibold)
    static let eventChip = NSFont.systemFont(ofSize: 12, weight: .medium)
    static let eventTime = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
    static let day = NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
    static let dayCompact = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
    static let countdown = NSFont.monospacedDigitSystemFont(ofSize: 20, weight: .bold)
    static let timer = NSFont.monospacedDigitSystemFont(ofSize: 32, weight: .semibold)
    static let timerCompact = NSFont.monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
    static let clockTime = NSFont.monospacedDigitSystemFont(ofSize: 18, weight: .bold)
    static let badge = NSFont.systemFont(ofSize: 10, weight: .medium)
    static let weekday = NSFont.systemFont(ofSize: 10, weight: .semibold)
    static func attributes(font: NSFont, color: NSColor, lineHeight: CGFloat? = nil, tracking: CGFloat = 0, truncation: NSLineBreakMode = .byTruncatingTail) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = truncation
        if let lineHeight { paragraph.minimumLineHeight = lineHeight; paragraph.maximumLineHeight = lineHeight }
        return [.font: font, .foregroundColor: color, .kern: tracking, .paragraphStyle: paragraph]
    }
}
enum NativeTracking {
    static let monthTitle: CGFloat = -0.7
    static let weekday: CGFloat = 0.8
}
enum NativeSpace {
    static let xxs: CGFloat = 2, xs: CGFloat = 4, sm: CGFloat = 8, md: CGFloat = 12, lg: CGFloat = 16, xl: CGFloat = 18, xxl: CGFloat = 24
}
enum NativeRadius {
    static let input: CGFloat = 8, chip: CGFloat = 5, button: CGFloat = 9, segment: CGFloat = 10, card: CGFloat = 14, panel: CGFloat = 24, popover: CGFloat = 20
}
enum NativeSize {
    static let compactTarget: CGFloat = 26, dividerHit: CGFloat = 6, focusWidth: CGFloat = 2, focusOffset: CGFloat = 2
    static let toolbarHeight: CGFloat = 30, controlGroupHeight: CGFloat = 25, eventChipHeight: CGFloat = 21
    static let eventChipComfortableHeight: CGFloat = 24
    static let dayNumberCompact: CGFloat = 24, dayNumber: CGFloat = 27, popoverWidth: CGFloat = 360
    static let monthPickerWidth: CGFloat = 276, searchWidth: CGFloat = 460, agendaMaxHeight: CGFloat = 344
    static let notesCompactLineHeight: CGFloat = 13 * 1.4
    static let habitTodayDot: CGFloat = 14, habitHistoryDot: CGFloat = 8, habitCheckMark: CGFloat = 8
    static let projectMinWidth: CGFloat = 290, notesLineHeight: CGFloat = 13 * 1.65, overflowEdge: CGFloat = 20
}
enum NativeGeometry {
    static func grid(in bounds: CGRect, columns: Int, rows: Int) -> [CGRect] {
        guard columns > 0, rows > 0, bounds.width > 0, bounds.height > 0 else { return [] }
        return (0..<(rows * columns)).map { i in
            let x = bounds.minX + CGFloat(i % columns) * bounds.width / CGFloat(columns)
            let y = bounds.minY + CGFloat(i / columns) * bounds.height / CGFloat(rows)
            return CGRect(x: x, y: y, width: bounds.width / CGFloat(columns), height: bounds.height / CGFloat(rows))
        }
    }
    static func target(_ rect: CGRect, minimum: CGFloat = NativeSize.compactTarget) -> CGRect {
        rect.insetBy(dx: -max(0, minimum - rect.width) / 2, dy: -max(0, minimum - rect.height) / 2)
    }
    static func clamp(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        CGRect(x: min(max(rect.minX, bounds.minX), max(bounds.minX, bounds.maxX - rect.width)),
               y: min(max(rect.minY, bounds.minY), max(bounds.minY, bounds.maxY - rect.height)),
               width: min(rect.width, bounds.width), height: min(rect.height, bounds.height))
    }
    static func dirtyRects(old: [NativeRenderItem], new: [NativeRenderItem]) -> [CGRect] {
        let previous = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
        let current = Dictionary(uniqueKeysWithValues: new.map { ($0.id, $0) })
        var result: [CGRect] = []
        for item in old where current[item.id] != item { result.append(item.rect) }
        for item in new where previous[item.id] != item && !result.contains(item.rect) { result.append(item.rect) }
        return result
    }
}
extension CGRect { var center: CGPoint { CGPoint(x: midX, y: midY) } }
extension NativeStrings {
    init(url: URL) throws {
        self.init(dictionaries: try JSONDecoder().decode([String: [String: String]].self, from: Data(contentsOf: url)))
    }
    func text(_ key: String, language: BoardLanguage, values: [String: String] = [:]) -> String {
        text(key, language: language.rawValue, values: values)
    }
}
