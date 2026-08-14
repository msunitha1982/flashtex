import AppKit

// LaTeXSyntaxHighlighter — advanced, high-performance LaTeX syntax coloring.
//
// * **Non-mutating:** coloring goes through layout-manager *temporary*
//   attributes, so NSTextStorage (and therefore undo/redo history, copy and
//   selection) is never touched.
// * **Asynchronous & debounced:** token parsing runs on a background queue,
//   debounced by ~80 ms, and the results are applied back on the main thread.
// * **Viewport-aware:** tokens are cached once; only the visible character
//   range (plus a small slack) is applied to the layout manager, and scrolling
//   just re-applies the cached tokens to the new range — so scrolling large
//   files never re-parses.
// * **Appearance adaptive:** all colours are dynamic NSColors (Catppuccin
//   Mocha in dark mode, Latte in light mode), resolved at draw time.

final class LaTeXSyntaxHighlighter {

    // MARK: - Public API

    /// Debounce and re-parse the whole buffer, then apply to the visible area.
    func scheduleRehighlight(editor: NSTextView, scrollView: NSScrollView?) {
        debounce?.invalidate()
        debounce = Timer(timeInterval: 0.08, repeats: false) { [weak self] _ in
            self?.rehighlightNow(editor: editor, scrollView: scrollView)
        }
        RunLoop.main.add(debounce!, forMode: .common)
    }

    /// Parse immediately (still on the background queue) and apply.
    func rehighlightNow(editor: NSTextView, scrollView: NSScrollView?) {
        let text = editor.string
        workQueue.async { [weak self] in
            guard let self else { return }
            let tokens = self.tokenize(text)
            DispatchQueue.main.async {
                guard editor.textStorage?.string == text else { return }
                self.clearTemporaryAttributes(editor: editor)
                self.tokens = tokens
                self.lastAppliedVisible = nil
                self.applyVisible(editor: editor, scrollView: scrollView)
            }
        }
    }

    /// Re-apply the cached tokens to the current visible area (e.g. on scroll,
    /// or after a font-size change). Cheap: does nothing if the range moved by
    /// less than the slack already applied.
    func scrollChanged(editor: NSTextView, scrollView: NSScrollView?) {
        applyVisible(editor: editor, scrollView: scrollView)
    }

    func shutdown() {
        debounce?.invalidate()
        debounce = nil
    }

    // MARK: - State

    private var debounce: Timer?
    private let workQueue = DispatchQueue(label: "flashtex.highlight", qos: .userInitiated)
    private var tokens: [Token] = []
    private var lastAppliedVisible: NSRange?

    private struct Token {
        let range: NSRange
        let color: NSColor
        let italic: Bool
    }

    // MARK: - Visible range

    /// Drop every temporary colour/font attribute we may have left behind.
    /// Temporary attributes are per-glyph-range, so after a document load or
    /// undo the previously applied ranges must be wiped explicitly.
    private func clearTemporaryAttributes(editor: NSTextView) {
        guard let lm = editor.layoutManager else { return }
        let len = (editor.string as NSString).length
        guard len > 0 else { return }
        let full = NSRange(location: 0, length: len)
        lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
        lm.removeTemporaryAttribute(.font, forCharacterRange: full)
    }

    private func applyVisible(editor: NSTextView, scrollView: NSScrollView?) {
        guard let lm = editor.layoutManager else { return }
        let ns = editor.string as NSString
        let length = ns.length
        guard length > 0 else { return }
        let full = NSRange(location: 0, length: length)

        let visible = visibleRange(editor: editor, scrollView: scrollView)
        if let last = lastAppliedVisible,
           visible.location >= last.location,
           visible.location + visible.length <= last.location + last.length {
            return        // still inside the previously applied window
        }
        lastAppliedVisible = visible

        // Base: reset to the theme font/colour, then layer tokens on top.
        lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: visible)
        lm.removeTemporaryAttribute(.font, forCharacterRange: visible)
        lm.addTemporaryAttribute(.foregroundColor, value: SyntaxTheme.text,
                                 forCharacterRange: visible)
        lm.addTemporaryAttribute(.font, value: Theme.editorFont,
                                 forCharacterRange: visible)

        let italicFont = NSFontManager.shared.convert(Theme.editorFont,
                                                      toHaveTrait: .italicFontMask)
        for token in tokens {
            let r = NSIntersectionRange(token.range, full)
            guard r.length > 0, r.location + r.length >= visible.location,
                  r.location <= visible.location + visible.length else { continue }
            let clipped = NSIntersectionRange(r, visible)
            guard clipped.length > 0 else { continue }
            if token.italic {
                lm.addTemporaryAttribute(.font, value: italicFont, forCharacterRange: clipped)
            }
            lm.addTemporaryAttribute(.foregroundColor, value: token.color,
                                     forCharacterRange: clipped)
        }
    }

    private func visibleRange(editor: NSTextView, scrollView: NSScrollView?) -> NSRange {
        let length = (editor.string as NSString).length
        let full = NSRange(location: 0, length: length)
        guard let lm = editor.layoutManager, let tc = editor.textContainer,
              let scroll = scrollView, scroll.documentView === editor else { return full }

        let origin = editor.textContainerOrigin
        let containerRect = scroll.contentView.bounds.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphs = lm.glyphRange(forBoundingRect: containerRect, in: tc)
        guard glyphs.location != NSNotFound else { return full }
        let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)

        let slack = 2000
        let start = max(0, chars.location - slack)
        let end = min(length, chars.location + chars.length + slack)
        return NSRange(location: start, length: max(0, end - start))
    }

    // MARK: - Tokenizer

    private var theme: SyntaxTheme { SyntaxTheme.current }

    private func tokenize(_ text: String) -> [Token] {
        let ns = text as NSString
        let n = ns.length
        guard n > 0 else { return [] }

        var out: [Token] = []

        // Priority, low → high (later tokens override earlier overlaps):
        // delimiters < commands < references < args < optional params <
        // environment tags < math < comments < embedded code.

        // 1. Delimiters + escaped specials.
        delimRe.enumerateMatches(in: text, range: NSRange(location: 0, length: n)) { m, _, _ in
            guard let m, m.range.length > 0 else { return }
            out.append(Token(range: m.range, color: theme.delimiter, italic: false))
        }
        specialRe.enumerateMatches(in: text, range: NSRange(location: 0, length: n)) { m, _, _ in
            guard let m, m.range.length > 0 else { return }
            out.append(Token(range: m.range, color: theme.delimiter, italic: false))
        }

        // 2. Commands.
        commandRe.enumerateMatches(in: text, range: NSRange(location: 0, length: n)) { m, _, _ in
            guard let m, m.range.length > 0 else { return }
            out.append(Token(range: m.range, color: theme.command, italic: false))
        }

        // 3. References & labels.
        refRe.enumerateMatches(in: text, range: NSRange(location: 0, length: n)) { m, _, _ in
            guard let m, m.range.length > 0 else { return }
            out.append(Token(range: m.range, color: theme.reference, italic: false))
        }

        // 4. Mandatory arguments `{…}`.
        argRe.enumerateMatches(in: text, range: NSRange(location: 0, length: n)) { m, _, _ in
            guard let m, m.range.length > 0 else { return }
            out.append(Token(range: m.range, color: theme.mandatoryArg, italic: false))
        }

        // 5. Optional parameters `[…]`.
        paramRe.enumerateMatches(in: text, range: NSRange(location: 0, length: n)) { m, _, _ in
            guard let m, m.range.length > 0 else { return }
            out.append(Token(range: m.range, color: theme.optionalParam, italic: false))
        }

        // 6. Environment tags.
        envRe.enumerateMatches(in: text, range: NSRange(location: 0, length: n)) { m, _, _ in
            guard let m, m.range.length > 0 else { return }
            out.append(Token(range: m.range, color: theme.environment, italic: false))
        }

        // 7. Math mode.
        scanMath(in: ns, into: &out)

        // 8. Comments (escaped `\%` handled).
        scanComments(in: ns, into: &out)

        // 9. Embedded code blocks.
        scanEmbedded(in: ns, into: &out)

        return out
    }

    // MARK: - Regexes

    private let delimRe = try! NSRegularExpression(pattern: "[{}\\[\\]]")
    private let specialRe = try! NSRegularExpression(pattern: #"\\[^A-Za-z@\s]"#)
    private let commandRe = try! NSRegularExpression(pattern: #"\\[A-Za-z@]+"#)
    private let refRe = try! NSRegularExpression(
        pattern: #"\\(?:ref|eqref|pageref|autoref|label|cite|citet|citep|cref|Cref|vref|nref|noteref)\b"#)
    private let argRe = try! NSRegularExpression(pattern: #"\{[^{}]*\}"#)
    private let paramRe = try! NSRegularExpression(pattern: #"\[[^\]\n]*\]"#)
    private let envRe = try! NSRegularExpression(pattern: #"\\(?:begin|end)\s*\{[^{}]*\}"#)

    private let mathEnvs: Set<String> = [
        "equation", "equation*", "displaymath",
        "align", "align*", "gather", "gather*",
        "multline", "multline*", "alignat", "alignat*",
        "flalign", "flalign*",
    ]

    // MARK: - Scanners

    private func scanMath(in ns: NSString, into out: inout [Token]) {
        let n = ns.length
        var i = 0
        while i < n {
            let c = ns.character(at: i)
            if c == 36 {        // `$`
                let display = i + 1 < n && ns.character(at: i + 1) == 36
                let open = display ? 2 : 1
                var j = i + open
                var end = NSNotFound
                while j < n {
                    let c2 = ns.character(at: j)
                    if c2 == 36 && !isEscaped(ns, j) {
                        if display {
                            if j + 1 < n && ns.character(at: j + 1) == 36 {
                                end = j + 1
                                break
                            }
                        } else {
                            if j + 1 < n && ns.character(at: j + 1) == 36 {
                                j += 1
                                continue
                            }
                            end = j
                            break
                        }
                    }
                    j += 1
                }
                if end != NSNotFound {
                    out.append(Token(range: NSRange(location: i, length: end - i + 1),
                                     color: theme.math, italic: false))
                    i = end + 1
                    continue
                }
                i += 1
                continue
            }
            if c == 92 {        // `\`
                if i + 1 < n && ns.character(at: i + 1) == 91 {      // `\[`
                    var j = i + 2
                    var end = NSNotFound
                    while j + 1 < n {
                        if ns.character(at: j) == 92 && ns.character(at: j + 1) == 93 {   // `\]`
                            end = j + 1
                            break
                        }
                        j += 1
                    }
                    if end != NSNotFound {
                        out.append(Token(range: NSRange(location: i, length: end - i + 1),
                                         color: theme.math, italic: false))
                        i = end + 1
                        continue
                    }
                    i += 2
                    continue
                }
                if let body = scanMathEnvironment(ns, at: i) {
                    out.append(Token(range: body, color: theme.math, italic: false))
                    i = body.location + body.length
                    continue
                }
            }
            i += 1
        }
    }

    /// Finds `\begin{env}…\end{env}` for the display-math environments and
    /// returns the *body* range (the tags themselves stay yellow).
    private func scanMathEnvironment(_ ns: NSString, at start: Int) -> NSRange? {
        let n = ns.length
        guard start + 7 <= n,
              ns.substring(with: NSRange(location: start, length: 7)) == "\\begin{" else { return nil }
        var k = start + 7
        let nameStart = k
        while k < n && ns.character(at: k) != 125 { k += 1 }      // `}`
        guard k < n, k > nameStart else { return nil }
        let name = ns.substring(with: NSRange(location: nameStart, length: k - nameStart))
        guard mathEnvs.contains(name) else { return nil }
        let bodyStart = k + 1
        let search = NSRange(location: bodyStart, length: n - bodyStart)
        let marker = "\\end{\(name)}"
        let endLoc = ns.range(of: marker, options: [], range: search).location
        guard endLoc != NSNotFound, endLoc > bodyStart else { return nil }
        return NSRange(location: bodyStart, length: endLoc - bodyStart)
    }

    private func scanComments(in ns: NSString, into out: inout [Token]) {
        let n = ns.length
        var i = 0
        while i < n {
            if ns.character(at: i) == 37 && !isEscaped(ns, i) {    // `%`
                var end = i
                while end < n && ns.character(at: end) != 10 { end += 1 }
                out.append(Token(range: NSRange(location: i, length: end - i),
                                 color: theme.comment, italic: true))
                i = end
                continue
            }
            i += 1
        }
    }

    private func scanEmbedded(in ns: NSString, into out: inout [Token]) {
        let n = ns.length
        let envs = ["asy", "tikzpicture"]
        for env in envs {
            let beginMarker = "\\begin{\(env)}"
            var search = NSRange(location: 0, length: n)
            while search.location != NSNotFound {
                let beginLoc = ns.range(of: beginMarker, options: [], range: search).location
                guard beginLoc != NSNotFound else { break }
                let endMarker = "\\end{\(env)}"
                let rest = NSRange(location: beginLoc, length: n - beginLoc)
                let endLoc = ns.range(of: endMarker, options: [], range: rest).location
                let block: NSRange
                if endLoc != NSNotFound {
                    block = NSRange(location: beginLoc,
                                    length: endLoc + endMarker.count - beginLoc)
                    search = NSRange(location: block.location + block.length, length: n - (block.location + block.length))
                } else {
                    block = NSRange(location: beginLoc, length: n - beginLoc)
                    search = NSRange(location: NSNotFound, length: 0)
                }
                out.append(Token(range: block, color: theme.embedded, italic: false))
            }
        }
    }

    private func isEscaped(_ ns: NSString, _ index: Int) -> Bool {
        var count = 0
        var k = index - 1
        while k >= 0 && ns.character(at: k) == 92 { count += 1; k -= 1 }
        return count % 2 == 1
    }
}

// MARK: - SyntaxTheme

/// Palette for syntax highlighting, resolved from the active Theme (which in
/// turn reads SettingsStore: flavour + per-role overrides). The highlighter
/// re-applies tokens after a settings change, so colours stay in sync.
struct SyntaxTheme {

    let command: NSColor
    let environment: NSColor
    let math: NSColor
    let mandatoryArg: NSColor
    let optionalParam: NSColor
    let reference: NSColor
    let comment: NSColor
    let embedded: NSColor
    let delimiter: NSColor

    static var text: NSColor { Theme.editorText }
    static var background: NSColor { Theme.editorBackground }

    /// Resolved at call time so syntax overrides apply immediately.
    static var current: SyntaxTheme {
        SyntaxTheme(
            command:       Theme.syntaxCommand,
            environment:   Theme.syntaxEnvironment,
            math:          Theme.syntaxMath,
            mandatoryArg:  Theme.syntaxMandatoryArg,
            optionalParam: Theme.syntaxOptionalParam,
            reference:     Theme.syntaxReference,
            comment:       Theme.syntaxComment,
            embedded:      Theme.syntaxEmbedded,
            delimiter:     Theme.syntaxDelimiter)
    }
}
