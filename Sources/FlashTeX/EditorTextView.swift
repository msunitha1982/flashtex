import AppKit
import SwiftUI

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

    /// The text view grows its frame in steps as the layout manager lays out
    /// the document (a pasted block can jump through many intermediate
    /// heights). The gutter must track the final height so its strip covers
    /// the whole document; refreshing on every frame-height change keeps it
    /// in step even when layout runs after the text-change callback.
    override func setFrameSize(_ newSize: NSSize) {
        let oldHeight = frame.height
        super.setFrameSize(newSize)
        if newSize.height != oldHeight {
            onGutterRefresh?()
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

        // A clean, modern indicator: a faint accent-tinted highlight with
        // softly rounded caps, running edge-to-edge (including behind the
        // line numbers) and centred on the line's true centre line — a slight
        // spill into the neighbour below is fine.
        let corner: CGFloat = min(4, lineRect.height * 0.5)
        let bandRect = NSRect(x: 0, y: lineRect.midY - lineRect.height / 2,
                              width: bounds.width,
                              height: lineRect.height)
        Theme.currentLine.setFill()
        NSBezierPath(roundedRect: bandRect, xRadius: corner, yRadius: corner).fill()
    }

    /// Told when the gutter needs a repaint (text edits that change the line
    /// count or layout). The gutter view is refreshed through this instead of
    /// the text view redrawing it.
    var onGutterRefresh: (() -> Void)?

    private var lineStartsCache: [Int]?

    func invalidateLineStartsCache() {
        lineStartsCache = nil
    }

    private func lineStarts() -> [Int] {
        if let cache = lineStartsCache { return cache }
        let ns = string as NSString
        let len = ns.length
        var starts = [0]
        starts.reserveCapacity(max(10, len / 40))
        var i = 0
        while i < len {
            if ns.character(at: i) == 10 {
                starts.append(i + 1)
            }
            i += 1
        }
        lineStartsCache = starts
        return starts
    }

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
        let starts = lineStarts()
        guard !starts.isEmpty else { return 1 }
        var low = 0
        var high = starts.count - 1
        var result = 0
        while low <= high {
            let mid = (low + high) / 2
            if starts[mid] <= charIndex {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result + 1
    }

    func lineCount() -> Int {
        let ns = string as NSString
        guard ns.length > 0 else { return 1 }
        return lineStarts().count
    }

    // MARK: - Inline Error Diagnostics

    private(set) var diagnostics: [Int: LatexIssue] = [:]
    private var dismissedLines = Set<Int>()

    func updateDiagnostics(_ issues: [LatexIssue]) {
        var newMap: [Int: LatexIssue] = [:]
        for issue in issues where issue.line > 0 {
            newMap[issue.line] = issue
        }

        // Forget user-dismissed lines only when the error set actually changes.
        // Otherwise a debounced auto-recompile with identical errors would
        // instantly resurrect a popup the user just dismissed by editing.
        if !sameIssues(newMap, diagnostics) {
            dismissedLines.removeAll()
        }
        diagnostics = newMap

        guard let storage = textStorage else { return }
        let fullRange = NSRange(location: 0, length: storage.length)
        guard fullRange.length > 0 else { return }

        storage.beginEditing()
        storage.removeAttribute(.underlineStyle, range: fullRange)
        storage.removeAttribute(.underlineColor, range: fullRange)

        for (line, issue) in diagnostics {
            let r = lineRange(forLine: line)
            guard r.length > 0, NSMaxRange(r) <= storage.length else { continue }
            let color = issue.message.localizedCaseInsensitiveContains("warning") ? NSColor.systemOrange : NSColor.systemRed
            storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.patternDot.rawValue | NSUnderlineStyle.single.rawValue, range: r)
            storage.addAttribute(.underlineColor, value: color, range: r)
        }
        storage.endEditing()
        updateGutter()
        updateInlinePopover()
    }

    private func sameIssues(_ a: [Int: LatexIssue], _ b: [Int: LatexIssue]) -> Bool {
        guard a.count == b.count else { return false }
        for (line, issue) in a {
            guard let other = b[line], other.message == issue.message else { return false }
        }
        return true
    }

    func lineRange(forLine line: Int) -> NSRange {
        let starts = lineStarts()
        guard line >= 1, line <= starts.count else { return NSRange(location: 0, length: 0) }
        let start = starts[line - 1]
        let end = line < starts.count ? starts[line] - 1 : (string as NSString).length
        return NSRange(location: start, length: max(0, end - start))
    }

    func updateInlinePopover() {
        guard layoutManager != nil else {
            InlineLookUpPopover.dismiss()
            return
        }
        let charIdx = selectedRange().location
        let currentLine = lineNumber(at: charIdx)

        // Show error for current line if it exists; otherwise fall back to first error line in diagnostics
        let lineToShow: Int?
        if diagnostics[currentLine] != nil {
            lineToShow = currentLine
        } else {
            lineToShow = diagnostics.keys.sorted().first
        }

        if let line = lineToShow, let issue = diagnostics[line], !dismissedLines.contains(line) {
            guard let anchorRect = anchorRect(forLine: line) else {
                InlineLookUpPopover.dismiss()
                return
            }

            let title = issue.message.localizedCaseInsensitiveContains("warning") ? "TeX Warning (Line \(line))" : "TeX Error (Line \(line))"
            let text = issue.message + (issue.hint.isEmpty ? "" : " — " + issue.hint)

            let dismissAction: () -> Void = { [weak self] in
                self?.dismissedLines.insert(line)
                InlineLookUpPopover.dismiss()
            }
            InlineLookUpPopover.show(title: title, text: text, line: line, anchorRect: anchorRect, of: self, onDismiss: dismissAction)
            updatePopupVisibilityForCaret()
        } else {
            InlineLookUpPopover.dismiss()
        }
    }

    /// The on-screen frame of the given line, in this text view's own coordinate
    /// space (so subviews of the text view stay glued to the line while scrolling).
    func anchorRect(forLine line: Int) -> NSRect? {
        guard let lm = layoutManager else { return nil }
        let lineR = lineRange(forLine: line)
        guard lineR.length > 0 else { return nil }
        let charLoc = min(lineR.location, (string as NSString).length)
        let glyphIdx = lm.glyphIndexForCharacter(at: charLoc)
        guard glyphIdx != NSNotFound else { return nil }
        let lineFrag = lm.lineFragmentRect(forGlyphAt: glyphIdx, effectiveRange: nil)
        return NSRect(x: textContainerOrigin.x + lineFrag.minX,
                      y: textContainerOrigin.y + lineFrag.minY,
                      width: 20,
                      height: lineFrag.height)
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

    @objc func showCommandPalette(_ sender: Any?) {
        CommandPaletteWindowController.show(onEditor: self)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers ?? ""
        if flags == [.command], let action = SettingsStore.shared.formatAction(forKey: key) {
            applyFormatting(action)
            return true
        }
        if flags == [.command, .shift] && key.lowercased() == "p" {
            CommandPaletteWindowController.show(onEditor: self)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// ⌘B / ⌘I / ⌘K (or the user's rebinding): wrap the selection in the
    /// action's LaTeX construct. With no selection the construct is inserted
    /// and the caret placed between the delimiters.
    private func applyFormatting(_ action: SettingsStore.FormatAction) {
        let wrapper = action.wrapper
        let ns = string as NSString
        let sel = selectedRange()
        let range = NSRange(location: min(sel.location, ns.length),
                            length: min(sel.length, ns.length - min(sel.location, ns.length)))
        let replacement: String
        if range.length > 0 {
            let inner = ns.substring(with: range)
            replacement = wrapper.open + inner + wrapper.close
        } else {
            replacement = wrapper.open + wrapper.close
        }
        undoManager?.setActionName(action.displayName)
        if shouldChangeText(in: range, replacementString: replacement) {
            textStorage?.replaceCharacters(in: range, with: replacement)
            didChangeText()
        }
        // Place the caret just inside the delimiters.
        let caret = range.location + (wrapper.open as NSString).length
        setSelectedRange(NSRange(location: caret, length: 0))
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
        if s == "\t" {                       // soft-indent tab, or snippet trigger
            if expandSnippet() { return }
            super.insertText("    ", replacementRange: replacementRange)
            return
        }
        if s == "\\" {                       // start a LaTeX command → autocomplete
            super.insertText(insertString, replacementRange: replacementRange)
            maybeCloseEnvironment()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil else { return }
                self.complete(nil)
            }
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
            maybeCloseEnvironment()
            return
        }
        if pairs.values.contains(s),
           loc < ns.length,
           ns.character(at: loc) == (s as NSString).character(at: 0) {
            setSelectedRange(NSRange(location: loc + 1, length: 0))   // skip over the pair
            maybeCloseEnvironment()
            return
        }
        super.insertText(insertString, replacementRange: replacementRange)
        maybeCloseEnvironment()
    }

    // =====================================================================
    //  LaTeX autocomplete
    // =====================================================================

    /// The word to complete on. For LaTeX the partial word must include the
    /// leading backslash (`\fra` → complete to `\frac`), so we extend the
    /// default word range backwards across the backslash.
    override var rangeForUserCompletion: NSRange {
        let ns = string as NSString
        let base = super.rangeForUserCompletion
        guard base.location != NSNotFound, base.location > 0 else { return base }
        // If the character before the default word is a backslash, include it.
        let before = ns.character(at: base.location - 1)
        if before == 92 {   // "\"
            return NSRange(location: base.location - 1, length: base.length + 1)
        }
        return base
    }

    override func completions(forPartialWordRange charRange: NSRange,
                              indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String]? {
        let ns = string as NSString
        guard charRange.location != NSNotFound, charRange.length > 0 else { return nil }
        let partial = ns.substring(with: charRange)
        // Only autocomplete when the partial word starts with a backslash —
        // plain words never get LaTeX command suggestions.
        guard partial.hasPrefix("\\") else { return nil }
        let matches = LaTeXCompletion.matches(partial: partial)
        return matches.isEmpty ? nil : matches
    }

    override func insertCompletion(_ word: String, forPartialWordRange charRange: NSRange,
                                   movement: Int, isFinal flag: Bool) {
        // While the user is still navigating the list, let NSTextView render the
        // live preview normally.
        guard flag, let template = LaTeXCompletion.snippets[word] else {
            super.insertCompletion(word, forPartialWordRange: charRange,
                                   movement: movement, isFinal: flag)
            return
        }
        let (text, placeholders) = LaTeXCompletion.assemble(template)
        undoManager?.setActionName("Complete \(word)")
        if shouldChangeText(in: charRange, replacementString: text) {
            textStorage?.replaceCharacters(in: charRange, with: text)
            didChangeText()
        }
        // Select the first placeholder so the user can type straight over it.
        if let first = placeholders.first {
            setSelectedRange(NSRange(location: charRange.location + first.location,
                                     length: first.length))
        } else {
            setSelectedRange(NSRange(location: charRange.location + (text as NSString).length,
                                     length: 0))
        }
    }

    // =====================================================================
    //  Snippet engine
    // =====================================================================

    /// Tab triggers: if the word immediately before the caret is a known
    /// snippet (frame, align, table, matrix, …), replace it with a complete
    /// `\begin{env}` / `\end{env}` block and put the caret on the blank line.
    private func expandSnippet() -> Bool {
        let ns = string as NSString
        let caret = selectedRange().location
        guard caret > 0 else { return false }

        var start = caret
        while start > 0 {
            let c = ns.character(at: start - 1)
            if (c >= 65 && c <= 90) || (c >= 97 && c <= 122) {   // A-Z / a-z
                start -= 1
            } else {
                break
            }
        }
        guard start < caret else { return false }
        let word = ns.substring(with: NSRange(location: start, length: caret - start))
        guard let env = LatexStructure.snippetEnvironments[word] else { return false }

        let block = "\\begin{\(env)}\n\n\\end{\(env)}"
        let range = NSRange(location: start, length: caret - start)
        undoManager?.setActionName("Insert \(env) block")
        if shouldChangeText(in: range, replacementString: block) {
            textStorage?.replaceCharacters(in: range, with: block)
            didChangeText()
        }
        // Caret on the blank line between the delimiters.
        let innerStart = start + ("\\begin{\(env)}\n" as NSString).length
        setSelectedRange(NSRange(location: innerStart, length: 0))
        return true
    }

    /// Auto-close: when the caret lands right after a freshly typed
    /// `\begin{env}` that isn't matched yet, append `\n\end{env}` and place the
    /// caret on the blank line between them.
    private func maybeCloseEnvironment() {
        let ns = string as NSString
        let caret = selectedRange().location
        guard caret >= 8 else { return }
        let prefix = ns.substring(with: NSRange(location: 0, length: caret))
        let pattern = #"\\begin\{([A-Za-z]+)\}$"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: prefix, range: NSRange(location: 0, length: (prefix as NSString).length)) else { return }
        let name = (prefix as NSString).substring(with: m.range(at: 1))

        // Only close when the document still has an unmatched open for this
        // environment — re-opening an already-closed name shouldn't duplicate
        // its \end.
        let full = string as NSString
        let all = full as String
        let beginCount = occurrences(of: "\\begin{\(name)}", in: all)
        let endCount = occurrences(of: "\\end{\(name)}", in: all)
        guard beginCount > endCount else { return }

        let insertion = "\n\\end{\(name)}"
        let at = NSRange(location: caret, length: 0)
        undoManager?.setActionName("Auto-close \(name)")
        if shouldChangeText(in: at, replacementString: insertion) {
            textStorage?.replaceCharacters(in: at, with: insertion)
            didChangeText()
        }
        setSelectedRange(NSRange(location: caret + 1, length: 0))
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        var count = 0
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let r = haystack.range(of: needle, options: [], range: searchRange) {
            count += 1
            searchRange = r.upperBound..<haystack.endIndex
        }
        return count
    }

    override func setSelectedRange(_ charRange: NSRange, affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRange(charRange, affinity: affinity, stillSelecting: stillSelecting)
        needsDisplay = true
        onCursorMoved?()
        // The active line number in the gutter follows the caret, so nudge the
        // gutter view to repaint as the selection moves.
        onGutterRefresh?()
        // While the caret sits on a line the error popup blocks, keep the popup
        // hidden; the moment the caret leaves, bring it back.
        updatePopupVisibilityForCaret()
    }

    override func didChangeText() {
        invalidateLineStartsCache()
        super.didChangeText()
        updateGutter()
        updatePopupVisibilityForCaret()
        if !isLoading {
            onTextChanged?()
        }
    }

    /// Brings a hidden (blocked-by-caret) popup back once the caret leaves the
    /// blocked line, or keeps a visible one hidden if the caret enters a blocked line.
    private func updatePopupVisibilityForCaret() {
        guard let popoverLine = InlineLookUpPopover.currentLine else { return }
        let caretLine = lineNumber(at: selectedRange().location)
        let blocked = isLineBlockedByPopover(caretLine)
        if blocked {
            InlineLookUpPopover.setHidden(true)
        } else {
            InlineLookUpPopover.setHidden(false)
            if let anchor = anchorRect(forLine: popoverLine) {
                InlineLookUpPopover.reposition(anchorRect: anchor, of: self)
            }
        }
    }

    /// Whether the given line is physically blocked/occluded by the popup pane.
    /// The error line itself is never "blocked" — the popup is anchored to it
    /// (arrow touching its edge), so the caret can sit there with the popup
    /// fully visible; only lines the pane actually covers hide it.
    private func isLineBlockedByPopover(_ line: Int) -> Bool {
        guard let pane = InlineLookUpPopover.activePane, let lm = layoutManager else { return false }
        let lineR = lineRange(forLine: line)
        guard lineR.length > 0 else { return false }
        let charLoc = min(lineR.location, (string as NSString).length)
        let glyphIdx = lm.glyphIndexForCharacter(at: charLoc)
        guard glyphIdx != NSNotFound else { return false }
        let frag = lm.lineFragmentRect(forGlyphAt: glyphIdx, effectiveRange: nil)
        let lineRect = NSRect(x: 0, y: textContainerOrigin.y + frag.minY, width: bounds.width, height: frag.height)

        let paneFrame = pane.frame
        // A line is only "blocked" when the pane actually covers most of it.
        // Half-height overlaps (the popup's edge landing mid-line) would
        // otherwise hide the popup on a third line the pane barely touches.
        let overlap = min(lineRect.maxY, paneFrame.maxY) - max(lineRect.minY, paneFrame.minY)
        return overlap > lineRect.height * 0.5
    }
}

// MARK: - AppKit Error Popup Helper

public enum InlineLookUpPopover {
    static var activePane: ErrorPopoverPane?
    private(set) public static var currentLine: Int?

    /// True while a popup exists but has been temporarily hidden (its line is
    /// being edited).
    public static var isHidden: Bool {
        activePane?.isHidden ?? true
    }

    public static func setHidden(_ hidden: Bool) {
        activePane?.isHidden = hidden
    }

    /// Shows a persistent popup pane just above (or below) `anchorRect`.
    public static func show(title: String, text: String, line: Int, anchorRect: NSRect, of host: NSView, onDismiss: (() -> Void)? = nil) {
        if activePane != nil && currentLine == line {
            reposition(anchorRect: anchorRect, of: host)
            return
        }
        dismiss()

        let pane = ErrorPopoverPane(title: title, text: text, onDismiss: {
            onDismiss?()
            dismiss()
        })
        currentLine = line
        activePane = pane
        host.addSubview(pane)
        reposition(anchorRect: anchorRect, of: host)
    }

    /// Re-anchors an active popup pane, e.g. after the text above it changed or on scroll.
    public static func reposition(anchorRect: NSRect, of host: NSView) {
        guard let pane = activePane else { return }
        if pane.superview == nil {
            host.addSubview(pane)
        }
        let size = pane.fittingContentSize
        let (rect, pointsUp) = layout(for: anchorRect, size: size, in: host.bounds)
        // Position arrow tip over the start of the error text
        let arrowX = anchorRect.minX + 8 - rect.minX
        pane.update(pointsUp: pointsUp, arrowX: arrowX)
        pane.frame = rect
    }

    public static func dismiss() {
        activePane?.removeFromSuperview()
        activePane = nil
        currentLine = nil
    }

    /// Places the popup just above the anchor (a rect on the error line), flipping
    /// below the line when there is no room above (e.g. an error on line 1).
    /// When above: bottom of popup (arrow tip) touches anchorRect.minY.
    /// When below: top of popup (arrow tip) touches anchorRect.maxY.
    private static func layout(for anchorRect: NSRect, size: NSSize, in hostBounds: NSRect) -> (rect: NSRect, pointsUp: Bool) {
        let x = min(max(anchorRect.minX - 4, 2), max(hostBounds.width - size.width - 2, 2))
        let aboveY = anchorRect.minY - size.height
        let pointsUp = aboveY < hostBounds.minY
        let y = pointsUp ? anchorRect.maxY : aboveY
        return (NSRect(x: x, y: y, width: size.width, height: size.height), pointsUp)
    }
}
