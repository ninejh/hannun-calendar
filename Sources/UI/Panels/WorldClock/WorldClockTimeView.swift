import AppKit

/// Only the eight time glyphs own a live backing; the static canvas owns all AX and actions.
@MainActor final class WorldClockTimeView: NSView {
    private var text = ""
    private var font = NativeFont.clockTime
    private var color = NSColor.labelColor
    private(set) var paintPassCount = 0
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        setAccessibilityElement(false); setAccessibilityHidden(true)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func accessibilityChildren() -> [Any]? { [] }
    func update(text: String, font: NSFont, color: NSColor) {
        guard self.text != text || self.font != font || self.color != color else { return }
        self.text = text; self.font = font; self.color = color; needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        paintPassCount += 1
        let height = ceil(font.ascender - font.descender + font.leading)
        let rect = CGRect(x: NativeSpace.sm, y: bounds.midY - height / 2, width: max(0, bounds.width - NativeSpace.sm * 2), height: height)
        (text as NSString).draw(in: rect, withAttributes: NativeFont.attributes(font: font, color: color, lineHeight: height))
    }
}
