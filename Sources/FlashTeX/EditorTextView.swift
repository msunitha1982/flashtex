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

final class EditorTextView: NSTextView {

    var onTextChanged: (() -> Void)?
    var onCursorMoved: (() -> Void)?
    var onFontSizeChanged: (() -> Void)?
    var isLoading = false

    private let padding: CGFloat = 20
    private var gutterDigits = 3

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

        font = Theme.editorFont
        textColor = Theme.editorText
        insertionPointColor = Theme.accent

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

        updateGutter()
    }

    // =====================================================================
    //  Painting — background, current line, gutter, then glyphs
    // =====================================================================

    override func draw(_ dirtyRect: NSRect) {
        Theme.editorBackground.setFill()
        dirtyRect.fill()

        drawCurrentLineHighlight(in: dirtyRect)
        super.draw(dirtyRect)          // glyphs + selection (background off)
        drawGutter(in: dirtyRect)
    }

    private func drawCurrentLineHighlight(in dirtyRect: NSRect) {
        let insertion = selectedRange().location
        guard insertion != NSNotFound,
              let lm = layoutManager, let tc = textContainer else { return }
        let glyphRange = lm.glyphRange(forCharacterRange: NSRange(location: insertion, length: 0),
                                       actualCharacterRange: nil)
        guard glyphRange.location != NSNotFound else { return }
        let origin = textContainerOrigin
        let rect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
            .offsetBy(dx: origin.x, dy: origin.y)
        guard rect.intersects(dirtyRect) else { return }
        Theme.currentLine.setFill()
        NSRect(x: 0, y: rect.minY, width: bounds.width, height: rect.height).fill()
    }

    private func drawGutter(in dirtyRect: NSRect) {
        Theme.gutterBackground.setFill()
        NSRect(x: 0, y: dirtyRect.minY, width: gutterWidth(), height: dirtyRect.height).fill()

        guard let lm = layoutManager, let tc = textContainer else { return }
        let ns = string as NSString
        let origin = textContainerOrigin
        // layout-manager APIs speak in text-container coordinates.
        let containerRect = dirtyRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let visible = lm.glyphRange(forBoundingRect: containerRect, in: tc)
        guard visible.location != NSNotFound else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.gutterFont,
                                                    .foregroundColor: Theme.gutterText]

        lm.enumerateLineFragments(forGlyphRange: visible) { [weak self] fragRect, _, _, glyphRange, _ in
            guard let self = self else { return }
            let rect = fragRect.offsetBy(dx: origin.x, dy: origin.y)
            let charLoc = lm.characterIndexForGlyph(at: glyphRange.location)
            let isLineStart = charLoc == 0 || ns.character(at: charLoc - 1) == 10
            guard isLineStart else { return }      // wrapped continuation lines share a number
            let text = "\(self.lineNumber(at: charLoc))"
            let size = (text as NSString).size(withAttributes: attrs)
            let x = self.gutterWidth() - size.width - 8
            let y = rect.minY + (rect.height - size.height) / 2
            (text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
        }
    }

    private func lineNumber(at charIndex: Int) -> Int {
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
        let digits = max(2, String(lineCount()).count)
        let digitW = ("9" as NSString).size(withAttributes: [.font: Theme.gutterFont]).width
        return 12 + digitW * CGFloat(digits) + 12
    }

    func updateGutter() {
        let newDigits = max(2, String(lineCount()).count)
        if newDigits != gutterDigits {
            gutterDigits = newDigits
            textContainerInset = NSSize(width: gutterWidth() + padding, height: padding)
        }
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
