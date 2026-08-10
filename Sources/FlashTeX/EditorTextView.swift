import AppKit

// EditorTextView — the LaTeX editing surface.
//
// A thin NSTextView specialization that provides:
//   * an efficiently painted line-number gutter
//   * a current-line accent behind the caret
//   * brace / math auto-pairing and soft-indent tabs
//   * the native find bar (NSTextFinder)
//
// It paints its own background so the editor colour adapts to the system
// appearance, and reports edits to the controller through callbacks.

final class EditorTextView: VimTextView {

    var onTextChanged: (() -> Void)?
    var onCursorMoved: (() -> Void)?
    var onFontSizeChanged: (() -> Void)?
    var isLoading = false

    private let padding: CGFloat = 20
    private var gutterDigits = 3
    private var settingsObserver: NSObjectProtocol?

    static func makeEditor() -> EditorTextView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        return EditorTextView(frame: NSRect(x: 0, y: 0, width: 0, height: 600),
                              textContainer: container)
    }

    /// Keep the editor exactly as wide as the scroll view's clip view. A
    /// nonzero initial frame width would inflate the document width to
    /// `clip width + initial width`, pushing long lines past the visible area.
    override func layout() {
        super.layout()
        if let scroll = enclosingScrollView {
            let width = scroll.contentSize.width
            if frame.width != width {
                frame.size.width = width
            }
        }
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        configure()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configure() {
        drawsBackground = false
        isRichText = false
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        minSize = NSSize(width: 0, height: 0)
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        usesFindBar = true
        isIncrementalSearchingEnabled = true
        allowsUndo = true
        smartInsertDeleteEnabled = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isGrammarCheckingEnabled = false
        isContinuousSpellCheckingEnabled = false

        applySettings()

        settingsObserver = NotificationCenter.default.addObserver(
            forName: SettingsStore.changedNotification,
            object: nil, queue: .main) { [weak self] _ in
                self?.applySettings()
            }
    }

    /// Re-apply everything that depends on the current settings: font family,
    /// colours, line height, ligatures, column layout and gutter mode.
    func applySettings() {
        let font = Theme.editorFont
        self.font = font
        textColor = Theme.editorText
        insertionPointColor = Theme.accent

        let ligature: Int = SettingsStore.shared.ligatures ? 1 : 0
        let para = NSMutableParagraphStyle()
        para.minimumLineHeight = Theme.lineHeight(forFont: font)

        let len = (string as NSString).length
        if let storage = textStorage, len > 0 {
            storage.beginEditing()
            storage.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: len))
            storage.addAttribute(.ligature, value: ligature, range: NSRange(location: 0, length: len))
            storage.endEditing()
        }
        defaultParagraphStyle = para
        typingAttributes[.font] = font
        typingAttributes[.paragraphStyle] = para
        typingAttributes[.ligature] = ligature

        updateGutter()
        updateColumnLayout()
        needsDisplay = true
    }

    // =====================================================================
    //  Painting — background, current line, then glyphs
    //
    //  The line-number strip is owned by GutterView (a sibling view in the
    //  scroll view). Drawing it here would be clipped: NSTextView is
    //  layer-backed, so content outside a redraw's dirty rect is discarded,
    //  and typing/scroll/caret redraws only dirty the text column.
    // =====================================================================

    override func draw(_ dirtyRect: NSRect) {
        Theme.editorBackground.setFill()
        dirtyRect.fill()

        drawCurrentLineHighlight(in: dirtyRect)
        super.draw(dirtyRect)          // glyphs + selection (background off)
    }

    private func drawCurrentLineHighlight(in dirtyRect: NSRect) {
        let insertion = selectedRange().location
        guard insertion != NSNotFound,
              let lm = layoutManager else { return }
        let glyphIndex = lm.glyphIndexForCharacter(at: insertion)
        guard glyphIndex != NSNotFound, glyphIndex < lm.numberOfGlyphs else { return }
        // The line-fragment rect is the full line box (centred on the text
        // line, exactly one line tall) — the glyph bounding rect of the
        // insertion point is a stub that can sit at the wrong height and bleed
        // into the neighbouring lines.
        let lineRect = lm.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        guard lineRect.intersects(dirtyRect) else { return }
        Theme.currentLine.setFill()
        NSRect(x: 0, y: lineRect.minY, width: bounds.width, height: lineRect.height).fill()
    }

    /// Told when the gutter needs a repaint (text edits that change the line
    /// count or layout). The gutter view is refreshed through this instead of
    /// the text view redrawing it.
    var onGutterRefresh: (() -> Void)?

    func lineNumberText(at charIndex: Int) -> String {
        let mode = SettingsStore.shared.gutterMode
        switch mode {
        case .none: return ""
        case .absolute: return "\(lineNumber(at: charIndex))"
        case .relative:
            let caretLine = lineNumber(at: selectedRange().location)
            let thisLine = lineNumber(at: charIndex)
            if thisLine == caretLine { return "0" }
            return "\(abs(thisLine - caretLine))"
        }
    }

    func lineNumber(at charIndex: Int) -> Int {
        let ns = string as NSString
        var line = 1
        var i = 0
        while i < charIndex {
            if ns.character(at: i) == 10 { line += 1 }
            i += 1
        }
        return line
    }

    // =====================================================================
    //  Geometry
    // =====================================================================

    func lineCount() -> Int {
        guard !string.isEmpty else { return 1 }
        let ns = string as NSString
        var count = 1
        for i in 0..<ns.length where ns.character(at: i) == 10 { count += 1 }
        return count
    }

    func gutterWidth() -> CGFloat {
        guard SettingsStore.shared.gutterMode != .none else { return 0 }
        let digits = max(2, String(lineCount()).count)
        let digitW = ("9" as NSString).size(withAttributes: [.font: Theme.gutterFont]).width
        return 12 + digitW * CGFloat(digits) + 12
    }

    func updateGutter() {
        let newDigits = max(2, String(lineCount()).count)
        if newDigits != gutterDigits {
            gutterDigits = newDigits
            updateColumnLayout()
        }
        needsDisplay = true
        onGutterRefresh?()
    }

    /// Text column layout: either full-width, or a centred fixed-width column
    /// (e.g. 80 characters) when the user enables a max column width.
    func updateColumnLayout() {
        guard let tc = textContainer else { return }
        let chars = SettingsStore.shared.maxColumnChars
        if chars > 0 {
            tc.widthTracksTextView = false
            let charW = ("0" as NSString).size(withAttributes: [.font: font ?? Theme.editorFont]).width
            let column = charW * CGFloat(chars)
            tc.containerSize = NSSize(width: max(column, 200),
                                      height: CGFloat.greatestFiniteMagnitude)
        } else {
            tc.widthTracksTextView = true
            tc.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                      height: CGFloat.greatestFiniteMagnitude)
        }
        textContainerInset = NSSize(width: gutterWidth() + padding, height: padding)
        needsLayout = true
        needsDisplay = true
    }

    func scrollToLine(_ line: Int) {
        guard line >= 1 else { return }
        let ns = string as NSString
        var idx = 0
        var current = 1
        while current < line && idx < ns.length {
            if ns.character(at: idx) == 10 { current += 1 }
            idx += 1
        }
        let target = NSRange(location: min(idx, ns.length), length: 0)
        setSelectedRange(target)
        scrollRangeToVisible(target)
    }

    // =====================================================================
    //  Font zoom (responder-chain: the View menu routes ⌘=/⌘-/⌘0 here when
    //  this editor is the first responder)
    // =====================================================================

    @objc func zoomIn(_ sender: Any?) { adjustFont(by: 1) }
    @objc func zoomOut(_ sender: Any?) { adjustFont(by: -1) }
    @objc func resetZoom(_ sender: Any?) {
        Theme.editorFontSize = 13
        onFontSizeChanged?()
    }

    private func adjustFont(by delta: CGFloat) {
        Theme.editorFontSize = min(28, max(10, Theme.editorFontSize + delta))
        onFontSizeChanged?()
    }

    // =====================================================================
    //  Editing behaviour
    // =====================================================================

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        guard let s = insertString as? String else {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }
        if s == "\t" {                       // soft-indent tab
            super.insertText("    ", replacementRange: replacementRange)
            return
        }
        guard s.count == 1 else {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }

        let ns = string as NSString
        let loc = replacementRange.location == NSNotFound ? selectedRange().location : replacementRange.location
        let pairs: [String: String] = ["(": ")", "[": "]", "{": "}", "$": "$"]

        if let close = pairs[s] {
            super.insertText(s + close, replacementRange: replacementRange)
            setSelectedRange(NSRange(location: loc + 1, length: 0))
            return
        }
        if pairs.values.contains(s),
           loc < ns.length,
           ns.character(at: loc) == (s as NSString).character(at: 0) {
            setSelectedRange(NSRange(location: loc + 1, length: 0))   // skip over the pair
            return
        }
        super.insertText(insertString, replacementRange: replacementRange)
    }

    override func setSelectedRange(_ charRange: NSRange, affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRange(charRange, affinity: affinity, stillSelecting: stillSelecting)
        needsDisplay = true
        onCursorMoved?()
    }

    override func didChangeText() {
        super.didChangeText()
        updateGutter()
        if !isLoading {
            onTextChanged?()
        }
    }
}
