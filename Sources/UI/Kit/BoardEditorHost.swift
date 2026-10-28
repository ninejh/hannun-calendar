import AppKit

/// A stable owner for each active editing session. Keep this object while parking a panel.
/// Incoming snapshots never assign string/selection into an already attached same-key editor.
@MainActor final class BoardEditorHost: NSObject, NSTextViewDelegate {
    let textView = NSTextView(frame: .zero)
    var onDraft: (@MainActor (DraftKey, TextDraft) -> Void)?
    /// Consume only native Tab/Backtab focus commands; return false to retain AppKit behavior.
    /// Install after attachment. Parking/disposal or a different editing key clears this callback.
    var onCommand: (@MainActor (DraftKey, Selector) -> Bool)?
    private(set) var key: DraftKey?
    private final class Attachment {
        weak var view: NSView?
        let rect: CGRect
        let key: DraftKey
        let text: String
        init(view: NSView, rect: CGRect, key: DraftKey, text: String) { self.view = view; self.rect = rect; self.key = key; self.text = text }
    }
    private var deferred: Attachment?
    private var detachPending = false
    private var disposed = false
    override init() {
        super.init()
        textView.delegate = self; textView.isRichText = false; textView.importsGraphics = false
        textView.allowsUndo = true; textView.isAutomaticQuoteSubstitutionEnabled = false; textView.isAutomaticDashSubstitutionEnabled = false
        textView.font = NativeFont.body; textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: NativeSpace.xxs, height: NativeSpace.xxs)
        let paragraph = NSMutableParagraphStyle(); paragraph.minimumLineHeight = NativeSize.notesLineHeight; paragraph.maximumLineHeight = NativeSize.notesLineHeight
        textView.defaultParagraphStyle = paragraph; textView.setAccessibilityIdentifier("board-editor")
    }
    func attach(to view: NSView, rect: CGRect, key: DraftKey, text: String) {
        guard !disposed else { return }
        if textView.hasMarkedText() {
            deferred = Attachment(view: view, rect: rect, key: key, text: text); return
        }
        let sameKey = self.key == key
        self.key = key
        if !sameKey {
            onCommand = nil
            textView.string = text; textView.undoManager?.removeAllActions()
            textView.setSelectedRange(NSRange(location: 0, length: 0))
        }
        if textView.superview !== view {
            let selection = textView.selectedRanges
            let responder = textView.window?.firstResponder === textView
            textView.removeFromSuperview(); view.addSubview(textView); textView.selectedRanges = selection
            if responder { view.window?.makeFirstResponder(textView) }
        }
        textView.frame = rect; textView.autoresizingMask = [.width, .height]
        textView.setAccessibilityIdentifier(key == .notes ? "notes-input" : "board-editor")
    }
    func setTextIfIdle(_ text: String) {
        guard !textView.hasMarkedText(), textView.window?.firstResponder !== textView else { return }
        guard textView.string != text else { return }
        textView.string = text
    }
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard textView === self.textView, !disposed, !detachPending, textView.superview != nil,
              !textView.hasMarkedText(), let key,
              commandSelector == #selector(NSResponder.insertTab(_:)) || commandSelector == #selector(NSResponder.insertBacktab(_:))
        else { return false }
        return onCommand?(key, commandSelector) ?? false
    }
    func textDidChange(_ notification: Notification) {
        guard let key else { return }
        onDraft?(key, currentDraft)
        if !textView.hasMarkedText() { compositionDidEnd() }
    }
    func textViewDidChangeSelection(_ notification: Notification) {
        guard let key else { return }; onDraft?(key, currentDraft)
    }
    var currentDraft: TextDraft {
        TextDraft(text: textView.string, selection: textView.selectedRange(), markedRange: textView.hasMarkedText() ? textView.markedRange() : nil,
                  scrollOrigin: textView.enclosingScrollView?.contentView.bounds.origin ?? .zero)
    }
    func compositionDidEnd() {
        guard !textView.hasMarkedText() else { return }
        if let next = deferred, let view = next.view {
            deferred = nil; attach(to: view, rect: next.rect, key: next.key, text: next.text)
        }
        if detachPending { detachPending = false; textView.removeFromSuperview() }
    }
    /// Parking detaches only after composition. It keeps draft, native Undo, selection and scroll state.
    func detach() {
        onCommand = nil
        if textView.hasMarkedText() { detachPending = true; return }
        textView.removeFromSuperview()
    }
    func dispose() {
        guard !disposed else { return }; disposed = true
        onDraft = nil; onCommand = nil; deferred = nil; textView.delegate = nil; textView.removeFromSuperview(); textView.undoManager?.removeAllActions(); key = nil
    }
}
@MainActor final class NativeTextField: NSTextField {
    init(label: String, identifier: String) {
        super.init(frame: .zero); font = NativeFont.body; isEditable = true; isSelectable = true; setAccessibilityRole(.textField); setAccessibilityLabel(label); setAccessibilityIdentifier(identifier)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    /// Preserve the shared AppKit field editor and its marked text/Undo during refreshes.
    func updateFromBase(_ value: String) {
        guard currentEditor() == nil, stringValue != value else { return }; stringValue = value
    }
}
@MainActor final class NativeDatePicker: NSDatePicker {
    init(label: String, identifier: String, timeZone: TimeZone) {
        super.init(frame: .zero); datePickerStyle = .textFieldAndStepper
        datePickerElements = [.yearMonthDay]; self.timeZone = timeZone
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone; self.calendar = calendar
        font = NativeFont.body; setAccessibilityLabel(label); setAccessibilityIdentifier(identifier)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    var day: DateOnly? {
        get { DateOnly(date: dateValue, timeZone: timeZone ?? .current) }
        set { if let newValue { dateValue = newValue.date(in: timeZone ?? .current) } }
    }
}
