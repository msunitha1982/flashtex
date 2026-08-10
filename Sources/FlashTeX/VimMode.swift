import AppKit

// VimMode — a modal editing engine for the text views.
//
// A pragmatic subset of Vim's normal / insert / visual modes that covers
// everyday editing: motions (h j k l w b e 0 ^ $ gg G), line ops (dd yy cc),
// operators (d/y/c + motion), put, undo, and text-object-free change. Motions
// reuse AppKit's own movement semantics where possible so selection and fold
// interactions stay consistent.
//
// Enabled via Settings (SettingsStore.vimMode). When off, keyDown passes
// straight through to NSTextView.

final class VimEngine {

    enum Mode: Equatable {
        case normal, insert, visual
    }

    private(set) var mode: Mode = .insert

    private enum Operator { case delete, change, yank }

    private var pendingCount = ""
    private var pendingOperator: Operator?
    private var pendingG = false          // waiting for the second `g` of `gg`
    private var pendingReplace = false    // waiting for the replacement char of `r`
    private var register = ""
    private var visualStart: Int?

    var modeLabel: String {
        switch mode {
        case .normal: return "NORMAL"
        case .insert: return "INSERT"
        case .visual: return "VISUAL"
        }
    }

    func enterInsert() {
        mode = .insert
        pendingOperator = nil
        pendingCount = ""
        pendingG = false
        pendingReplace = false
    }

    func resetState() {
        enterInsert()
        visualStart = nil
    }

    /// Handle a key event. Returns true if consumed (nothing reaches NSTextView).
    func handle(_ event: NSEvent, in tv: NSTextView) -> Bool {
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
            return false                    // ⌘/⌃ shortcuts pass through (undo, copy…)
        }
        let keyCode = Int(event.keyCode)
        let chars = event.charactersIgnoringModifiers ?? ""
        let key = chars.isEmpty ? "" : String(chars.prefix(1))

        if keyCode == 53 {                  // Esc
            escape(tv)
            return true
        }

        switch mode {
        case .insert:
            return false                    // typing goes to NSTextView
        case .normal:
            handleNormal(tv, key: key, keyCode: keyCode)
            return true
        case .visual:
            handleVisual(tv, key: key, keyCode: keyCode)
            return true
        }
    }

    // MARK: - Modes

    private func escape(_ tv: NSTextView) {
        switch mode {
        case .insert:
            mode = .normal
            tv.setSelectedRange(NSRange(location: max(0, tv.selectedRange().location - 1), length: 0))
        case .visual:
            mode = .normal
            visualStart = nil
            let c = tv.selectedRange().location
            tv.setSelectedRange(NSRange(location: c, length: 0))
        case .normal:
            break
        }
        pendingOperator = nil
        pendingCount = ""
        pendingG = false
        pendingReplace = false
    }

    // MARK: - Normal mode

    private func handleNormal(_ tv: NSTextView, key: String, keyCode: Int) {
        // Counts and pending two-key sequences are resolved first.
        if key.rangeOfCharacter(from: .decimalDigits) != nil, pendingOperator == nil, !pendingReplace {
            pendingCount += key
            return
        }
        if pendingReplace {
            replaceChar(tv, with: key)
            pendingReplace = false
            return
        }
        if pendingG {
            pendingG = false
            if key == "g" {
                performMotion(tv, .docStart, count: count())
            }
            return
        }

        if let op = pendingOperator {
            if key == key.uppercased() && ["d", "c", "y"].contains(key) {
                // dd / cc / yy
                lineOp(tv, op, count: count())
                pendingOperator = nil
                return
            }
            if let motion = motionKind(key, keyCode: keyCode) {
                let start = tv.selectedRange().location
                let end = motionPosition(tv, motion, count: count())
                applyOperator(op, in: tv, from: start, to: end)
                pendingOperator = nil
            }
            return
        }

        switch key {
        case "i": enterInsert()
        case "a":
            let c = min(tv.selectedRange().location + 1, tv.string.count)
            tv.setSelectedRange(NSRange(location: c, length: 0))
            enterInsert()
        case "I":
            tv.setSelectedRange(NSRange(location: lineStart(tv, tv.selectedRange().location), length: 0))
            enterInsert()
        case "A":
            tv.setSelectedRange(NSRange(location: lineEnd(tv, tv.selectedRange().location), length: 0))
            enterInsert()
        case "o":
            openLine(tv, above: false)
        case "O":
            openLine(tv, above: true)
        case "v":
            visualStart = tv.selectedRange().location
            mode = .visual
        case "g":
            pendingG = true
        case "d", "c", "y":
            pendingOperator = key == "d" ? .delete : key == "c" ? .change : .yank
        case "x":
            deleteChars(tv, before: false)
        case "X":
            deleteChars(tv, before: true)
        case "D":
            deleteToEndOfLine(tv)
        case "C":
            changeToEndOfLine(tv)
        case "p":
            put(tv, before: false)
        case "P":
            put(tv, before: true)
        case "u":
            tv.undoManager?.undo()
        case "r":
            pendingReplace = true
        default:
            if let motion = motionKind(key, keyCode: keyCode) {
                performMotion(tv, motion, count: count())
            }
            // Unknown keys are swallowed so they never leak into the document.
        }
    }

    // MARK: - Visual mode

    private func handleVisual(_ tv: NSTextView, key: String, keyCode: Int) {
        if key.rangeOfCharacter(from: .decimalDigits) != nil { return }
        if let motion = motionKind(key, keyCode: keyCode) {
            let c = motionPosition(tv, motion, count: count())
            extendSelection(tv, to: c)
            return
        }
        switch key {
        case "v":
            mode = .normal
            let c = tv.selectedRange().location
            tv.setSelectedRange(NSRange(location: c, length: 0))
            visualStart = nil
        case "d":
            applyOperator(.delete, in: tv, from: visualStart ?? tv.selectedRange().location,
                          to: NSMaxRange(tv.selectedRange()))
            mode = .normal
            visualStart = nil
        case "y":
            register = (tv.string as NSString).substring(with: tv.selectedRange())
            mode = .normal
            let c = tv.selectedRange().location
            tv.setSelectedRange(NSRange(location: c, length: 0))
            visualStart = nil
        default:
            break
        }
    }

    // MARK: - Motions

    private enum Motion {
        case left, right, up, down
        case wordForward, wordBackward, wordEnd
        case lineStart, lineFirstNonBlank, lineEnd
        case docStart, docEnd, goToLine
    }

    private func motionKind(_ key: String, keyCode: Int) -> Motion? {
        switch key {
        case "h": return .left
        case "l", " ": return .right
        case "j", "\r": return .down
        case "k": return .up
        case "w": return .wordForward
        case "b": return .wordBackward
        case "e": return .wordEnd
        case "0": return .lineStart
        case "^": return .lineFirstNonBlank
        case "$": return .lineEnd
        case "G": return pendingCount.isEmpty ? .docEnd : .goToLine
        default:
            switch keyCode {
            case 123: return .left
            case 124: return .right
            case 125: return .down
            case 126: return .up
            default: return nil
            }
        }
    }

    private func performMotion(_ tv: NSTextView, _ motion: Motion, count: Int) {
        let c = motionPosition(tv, motion, count: count)
        tv.setSelectedRange(NSRange(location: c, length: 0))
    }

    private func motionPosition(_ tv: NSTextView, _ motion: Motion, count: Int) -> Int {
        let s = tv.string as NSString
        let caret = tv.selectedRange().location
        let n = s.length
        var c = caret
        switch motion {
        case .left:
            for _ in 0..<count {
                if c > lineStart(tv, c) { c -= 1 } else { break }
            }
        case .right:
            for _ in 0..<count {
                if c < lineEnd(tv, c) { c += 1 } else { break }
            }
        case .down:
            for _ in 0..<count { c = lineBelow(tv, c) }
        case .up:
            for _ in 0..<count { c = lineAbove(tv, c) }
        case .wordForward:
            c = wordForward(s, from: caret, count: count)
        case .wordBackward:
            c = wordBackward(s, from: caret, count: count)
        case .wordEnd:
            c = wordEnd(s, from: caret, count: count)
        case .lineStart:
            c = lineStart(tv, caret)
        case .lineFirstNonBlank:
            c = firstNonBlank(s, in: lineRange(tv, caret))
        case .lineEnd:
            c = lineEnd(tv, caret)
        case .docStart:
            c = 0
        case .docEnd:
            c = n
        case .goToLine:
            c = goToLine(s, line: max(1, count))
        }
        return min(max(c, 0), n)
    }

    // MARK: - Operator application

    private func applyOperator(_ op: Operator, in tv: NSTextView, from start: Int, to end: Int) {
        let s = tv.string as NSString
        let range = NSRange(location: min(start, end), length: abs(end - start))
        switch op {
        case .delete:
            edit(tv, range: range, with: "", action: "Delete")
            tv.setSelectedRange(NSRange(location: range.location, length: 0))
        case .yank:
            register = s.substring(with: range)
        case .change:
            edit(tv, range: range, with: "", action: "Change")
            tv.setSelectedRange(NSRange(location: range.location, length: 0))
            enterInsert()
        }
    }

    private func lineOp(_ tv: NSTextView, _ op: Operator, count: Int) {
        let s = tv.string as NSString
        let caret = tv.selectedRange().location
        var r = s.lineRange(for: NSRange(location: caret, length: 0))
        if count > 1 {
            for _ in 1..<count {
                let next = NSMaxRange(r)
                if next >= s.length { break }
                r = s.lineRange(for: NSRange(location: next, length: 0))
            }
        }
        let full = NSRange(location: r.location, length: NSMaxRange(r) - r.location)
        switch op {
        case .delete:
            edit(tv, range: full, with: "", action: "Delete line")
            tv.setSelectedRange(NSRange(location: min(full.location, s.length - full.length), length: 0))
        case .yank:
            register = s.substring(with: full)
        case .change:
            edit(tv, range: full, with: "", action: "Change line")
            tv.setSelectedRange(NSRange(location: full.location, length: 0))
            enterInsert()
        }
    }

    // MARK: - Small edits

    private func replaceChar(_ tv: NSTextView, with key: String) {
        guard !key.isEmpty else { return }
        let c = tv.selectedRange().location
        guard c < tv.string.count else { return }
        edit(tv, range: NSRange(location: c, length: 1), with: key, action: "Replace")
    }

    private func deleteChars(_ tv: NSTextView, before: Bool) {
        let c = tv.selectedRange().location
        if before {
            guard c > 0 else { return }
            edit(tv, range: NSRange(location: c - 1, length: 1), with: "", action: "Delete")
            tv.setSelectedRange(NSRange(location: c - 1, length: 0))
        } else {
            guard c < tv.string.count else { return }
            edit(tv, range: NSRange(location: c, length: 1), with: "", action: "Delete")
        }
    }

    private func deleteToEndOfLine(_ tv: NSTextView) {
        let c = tv.selectedRange().location
        let end = lineEnd(tv, c)
        guard end > c else { return }
        edit(tv, range: NSRange(location: c, length: end - c), with: "", action: "Delete to end of line")
    }

    private func changeToEndOfLine(_ tv: NSTextView) {
        let c = tv.selectedRange().location
        let end = lineEnd(tv, c)
        guard end >= c else { return }
        edit(tv, range: NSRange(location: c, length: end - c), with: "", action: "Change to end of line")
        tv.setSelectedRange(NSRange(location: c, length: 0))
        enterInsert()
    }

    private func openLine(_ tv: NSTextView, above: Bool) {
        let s = tv.string as NSString
        let r = s.lineRange(for: NSRange(location: tv.selectedRange().location, length: 0))
        let insertPos = above ? r.location : NSMaxRange(r)
        edit(tv, range: NSRange(location: insertPos, length: 0), with: "\n", action: above ? "Open line above" : "Open line below")
        tv.setSelectedRange(NSRange(location: insertPos, length: 0))
        enterInsert()
    }

    private func put(_ tv: NSTextView, before: Bool) {
        guard !register.isEmpty else { return }
        let c = tv.selectedRange().location
        let insertPos = before ? c : c + 1
        edit(tv, range: NSRange(location: insertPos, length: 0), with: register, action: "Paste")
        tv.setSelectedRange(NSRange(location: c, length: 0))
    }

    // MARK: - Editing primitive (undo-aware)

    private func edit(_ tv: NSTextView, range: NSRange, with string: String, action: String) {
        tv.undoManager?.setActionName(action)
        if tv.shouldChangeText(in: range, replacementString: string) {
            tv.textStorage?.replaceCharacters(in: range, with: string)
            tv.didChangeText()
        }
    }

    // MARK: - Geometry helpers

    private func count() -> Int {
        defer { pendingCount = "" }
        return Int(pendingCount) ?? 1
    }

    private func lineRange(_ tv: NSTextView, _ pos: Int) -> NSRange {
        let s = tv.string as NSString
        return s.lineRange(for: NSRange(location: min(max(pos, 0), s.length), length: 0))
    }

    private func lineStart(_ tv: NSTextView, _ pos: Int) -> Int {
        lineRange(tv, pos).location
    }

    private func lineEnd(_ tv: NSTextView, _ pos: Int) -> Int {
        let r = lineRange(tv, pos)
        return max(NSMaxRange(r) - 1, r.location)
    }

    private func lineBelow(_ tv: NSTextView, _ pos: Int) -> Int {
        let s = tv.string as NSString
        let r = s.lineRange(for: NSRange(location: pos, length: 0))
        let next = NSMaxRange(r)
        return next >= s.length ? pos : next
    }

    private func lineAbove(_ tv: NSTextView, _ pos: Int) -> Int {
        let s = tv.string as NSString
        let r = s.lineRange(for: NSRange(location: pos, length: 0))
        guard r.location > 0 else { return pos }
        return s.lineRange(for: NSRange(location: r.location - 1, length: 0)).location
    }

    private func firstNonBlank(_ s: NSString, in range: NSRange) -> Int {
        for i in range.location..<NSMaxRange(range) {
            let c = s.character(at: i)
            if c != 32 && c != 9 { return i }       // not space or tab
        }
        return range.location
    }

    private func goToLine(_ s: NSString, line: Int) -> Int {
        let n = s.length
        var current = 1
        var idx = 0
        while idx < n {
            if current == line { break }
            if s.character(at: idx) == 10 { current += 1 }
            idx += 1
        }
        return min(idx, n)
    }

    // MARK: - Word motions

    private let wordSet = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
    private let whitespace = CharacterSet.whitespacesAndNewlines

    private func isWordChar(_ s: NSString, _ i: Int) -> Bool {
        guard i >= 0, i < s.length else { return false }
        guard let scalar = UnicodeScalar(s.character(at: i)) else { return false }
        return wordSet.contains(scalar)
    }

    private func wordForward(_ s: NSString, from pos: Int, count: Int) -> Int {
        let n = s.length
        var i = min(max(pos, 0), n)
        for _ in 0..<count {
            while i < n && isWordChar(s, i) { i += 1 }
            while i < n && !isWordChar(s, i) && !whitespace.contains(UnicodeScalar(s.character(at: i))!) { i += 1 }
            while i < n && whitespace.contains(UnicodeScalar(s.character(at: i))!) { i += 1 }
        }
        return i
    }

    private func wordBackward(_ s: NSString, from pos: Int, count: Int) -> Int {
        var i = min(max(pos, 0), s.length)
        for _ in 0..<count {
            while i > 0 && whitespace.contains(UnicodeScalar(s.character(at: i - 1))!) { i -= 1 }
            guard i > 0 else { break }
            let wasWord = isWordChar(s, i - 1)
            while i > 0 && isWordChar(s, i - 1) == wasWord { i -= 1 }
        }
        return i
    }

    private func wordEnd(_ s: NSString, from pos: Int, count: Int) -> Int {
        let n = s.length
        var i = min(max(pos, 0), n)
        for _ in 0..<count {
            while i < n && whitespace.contains(UnicodeScalar(s.character(at: i))!) { i += 1 }
            guard i < n else { break }
            let isWord = isWordChar(s, i)
            while i < n && isWordChar(s, i) == isWord { i += 1 }
            if i > 0 { i -= 1 }
        }
        return i
    }

    private func extendSelection(_ tv: NSTextView, to pos: Int) {
        let start = visualStart ?? tv.selectedRange().location
        tv.setSelectedRange(NSRange(location: min(start, pos), length: abs(pos - start)))
    }
}

// VimTextView — NSTextView base that routes keys through the Vim engine when
// Vim mode is enabled. Both editor text views inherit from this.
class VimTextView: NSTextView {

    let vim = VimEngine()

    override func keyDown(with event: NSEvent) {
        if SettingsStore.shared.vimMode, vim.handle(event, in: self) {
            needsDisplay = true        // mode badge in the gutter updates
            return
        }
        super.keyDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        // Start in insert mode so typing immediately works on focus.
        if SettingsStore.shared.vimMode { vim.enterInsert() }
        return ok
    }
}
