import AppKit

// VimMode — a modal editing layer over the existing AppKit text engine.
//
// Vim is implemented as an input/state layer, not a second text engine. The
// editor's NSTextView remains the single source of truth for text, selection,
// caret position, undo/redo and scrolling; this controller translates keys
// into operations on that text view.
//
// Architecture (per the design brief):
//
//   NSEvent → VimController (router)
//                ├── normal / visual / replace  → command parser
//                ├── insert                     → AppKit text input
//                │
//                ▼
//             Command executor
//                ├── motions      (h j k l w b e 0 ^ $ gg G f F t T ; ,)
//                ├── operators    (d c y  +  iw/aw, dd/cc/yy, D C x X r)
//                ├── registers    (unnamed "" + named "a–z)
//                ├── counts       (parsed before every command)
//                └── search       (/ ? n N)
//                ▼
//             NSTextView text model (AppKit undo-aware edits)
//
// Single source of truth: every bit of derived UI (mode label, cursor style)
// is computed from `mode` — never stored alongside it.

// MARK: - State machine

enum VimMode: Equatable {
    case normal, insert, replace, visual, visualLine
}

enum VimOperator: Equatable {
    case delete, change, yank
}

enum VimRegisterType {
    case character, line
}

struct VimRegister {
    var text: String
    var type: VimRegisterType
}

// MARK: - Motions

enum VimMotion: Equatable {
    case left, right, up, down
    case wordForward, wordBackward, wordEnd
    case lineStart, lineFirstNonBlank, lineEnd
    case docStart, docEnd, goToLine
    case findNext, findPrev, tillNext, tillPrev       // f F t T — target char follows
}

// MARK: - Controller

final class VimController {

    // MARK: State (single source of truth)

    private(set) var mode: VimMode = .insert

    private var pendingCountDigits = ""
    private var pendingOperator: VimOperator?
    private var pendingG = false               // waiting for the second `g` of `gg`
    private var pendingR = false               // waiting for the replacement char of `r`
    private var pendingFind: VimMotion?        // waiting for the target char of f/F/t/T
    private var pendingTextObjectInner: Bool?  // operator/visual + i/a awaiting iw/aw
    private var pendingRegisterName: String?   // `"` then a register name
    private var lastFind: (VimMotion, Character)?
    private var visualAnchor = 0
    private var registers: [String: VimRegister] = [:]   // "" = unnamed register
    private var searching = false
    private var searchForward = true
    private var searchQuery = ""
    private var lastSearch = ""
    private var lastSearchForward = true

    /// Fired whenever the mode (or search state) changes, so the host can
    /// update the cursor, the gutter badge and dismiss autocomplete.
    var onModeChange: (() -> Void)?

    // MARK: Derived UI state

    var modeLabel: String {
        if searching { return (searchForward ? "/" : "?") + searchQuery }
        switch mode {
        case .normal: return "NORMAL"
        case .insert: return "INSERT"
        case .replace: return "REPLACE"
        case .visual: return "VISUAL"
        case .visualLine: return "VISUAL LINE"
        }
    }

    /// Normal and replace modes draw a block cursor over the caret character.
    var usesBlockCursor: Bool { mode == .normal || mode == .replace }

    /// Insert and replace accept ordinary text input through AppKit.
    func isInserting() -> Bool { mode == .insert || mode == .replace }

    // MARK: - Event routing

    /// Handle a key event. Returns true when Vim consumed it (nothing reaches
    /// NSTextView). Returns false to let AppKit text input proceed — the
    /// normal case in insert mode.
    func handle(_ event: NSEvent, in tv: NSTextView) -> Bool {
        // ⌘ shortcuts (undo, copy, zoom…) always pass through.
        if event.modifierFlags.contains(.command) { return false }

        let keyCode = Int(event.keyCode)
        let chars = event.charactersIgnoringModifiers ?? ""
        let key = chars.isEmpty ? "" : String(chars.prefix(1))

        // ⌃ shortcuts pass through too, except ⌃R (redo) which normal mode owns
        // (Vim's redo; AppKit's Emacs bindings are irrelevant in normal mode).
        if event.modifierFlags.contains(.control) {
            if !isInserting(), keyCode == 15 { redo(tv); return true }
            return false
        }

        if keyCode == 53 {              // Esc
            escape(tv)
            return true
        }

        if searching {
            handleSearch(key: key, keyCode: keyCode, in: tv)
            return true
        }

        switch mode {
        case .insert:
            return false                // plain typing goes to NSTextView
        case .replace:
            handleReplace(event, in: tv)
            return true
        case .normal:
            handleNormal(key: key, keyCode: keyCode, in: tv)
            return true
        case .visual, .visualLine:
            handleVisual(key: key, keyCode: keyCode, in: tv)
            return true
        }
    }

    // MARK: - Modes

    /// Enter insert mode without moving the caret (used on focus).
    func enterInsert() {
        setMode(.insert)
        clearPending()
    }

    private func escape(_ tv: NSTextView) {
        if searching {
            searching = false
            searchQuery = ""
            modeChanged()
            return
        }
        switch mode {
        case .insert:
            setMode(.normal)
            // Vim leaves the caret one column back in normal mode.
            let c = tv.selectedRange().location
            tv.setSelectedRange(NSRange(location: max(0, c - 1), length: 0))
        case .replace:
            setMode(.normal)
        case .visual, .visualLine:
            let c = tv.selectedRange().location
            setMode(.normal)
            tv.setSelectedRange(NSRange(location: c, length: 0))
        case .normal:
            break
        }
        clearPending()
    }

    private func setMode(_ m: VimMode) {
        guard mode != m else { return }
        mode = m
        modeChanged()
    }

    private func modeChanged() { onModeChange?() }

    private func clearPending() {
        pendingCountDigits = ""
        pendingOperator = nil
        pendingG = false
        pendingR = false
        pendingFind = nil
        pendingTextObjectInner = nil
        pendingRegisterName = nil
    }

    // MARK: - Normal mode

    private func handleNormal(key: String, keyCode: Int, in tv: NSTextView) {
        // Register prefix: `"` then a name, then a command.
        if key == "\"" {
            pendingRegisterName = ""
            return
        }
        if let name = pendingRegisterName, name.isEmpty {
            pendingRegisterName = key.isEmpty ? nil : key
            return
        }

        // f/F/t/T awaiting their target character.
        if let motion = pendingFind {
            pendingFind = nil
            if key.count == 1 { lastFind = (motion, Character(key)) }
            let c = findPosition(tv, motion, char: lastFind?.1 ?? " ", count: count())
            if let op = pendingOperator {
                applyOperator(op, in: tv, from: tv.selectedRange().location, to: c, register: activeRegister())
                pendingOperator = nil
            } else {
                tv.setSelectedRange(NSRange(location: c, length: 0))
            }
            return
        }

        // `r` awaiting the replacement character.
        if pendingR {
            pendingR = false
            if key.count == 1 { replaceChar(tv, with: key) }
            return
        }

        // Second `g` of `gg`.
        if pendingG {
            pendingG = false
            if key == "g" { performMotion(tv, .docStart, count: count()) }
            return
        }

        // Second key of a text object (operator + i/a, then w).
        if let inner = pendingTextObjectInner {
            pendingTextObjectInner = nil
            if key == "w" { applyTextObject(tv, inner: inner) }
            else if key == "W" { applyTextObject(tv, inner: inner, bigWord: true) }
            return
        }

        // Count digits. A leading `0` is the lineStart motion, not a count.
        if key.rangeOfCharacter(from: .decimalDigits) != nil {
            if !(pendingCountDigits.isEmpty && key == "0") {
                pendingCountDigits += key
                return
            }
        }

        // Operator pending: expect a motion, a doubled letter (dd/cc/yy) or a
        // text object (iw/aw).
        if let op = pendingOperator {
            let doubled: [String: VimOperator] = ["d": .delete, "c": .change, "y": .yank]
            if let dOp = doubled[key] {
                if dOp == op {
                    lineOp(tv, op, count: count(), register: activeRegister())
                    pendingOperator = nil
                } else {
                    pendingOperator = nil       // e.g. y then d cancels the operator
                }
                return
            }
            if key == "i" { pendingTextObjectInner = true; return }
            if key == "a" { pendingTextObjectInner = false; return }
            if let motion = motionKind(key, keyCode: keyCode) {
                if isFind(motion) {
                    pendingFind = motion
                } else {
                    let start = tv.selectedRange().location
                    let end = motionPosition(tv, motion, count: count())
                    applyOperator(op, in: tv, from: start, to: end, register: activeRegister())
                    pendingOperator = nil
                }
                return
            }
            pendingOperator = nil          // an unknown key cancels the operator
            return
        }

        // Plain commands.
        switch key {
        case "i": enterInsert()
        case "a": moveCaret(tv, .right, count: 1); enterInsert()
        case "I":
            tv.setSelectedRange(NSRange(location: lineStartPos(tv, tv.selectedRange().location), length: 0))
            enterInsert()
        case "A":
            tv.setSelectedRange(NSRange(location: lineEndPos(tv, tv.selectedRange().location), length: 0))
            enterInsert()
        case "o": openLine(tv, above: false)
        case "O": openLine(tv, above: true)
        case "v": startVisual(tv, kind: .visual)
        case "V": startVisual(tv, kind: .visualLine)
        case "s":
            deleteChars(tv, before: false, count: count())
            enterInsert()
        case "S":
            lineOp(tv, .delete, count: count(), register: activeRegister())
            enterInsert()
        case "x": deleteChars(tv, before: false, count: count())
        case "X": deleteChars(tv, before: true, count: count())
        case "D": deleteToEndOfLine(tv)
        case "C": changeToEndOfLine(tv)
        case "d": pendingOperator = .delete
        case "c": pendingOperator = .change
        case "y": pendingOperator = .yank
        case "p": put(tv, before: false)
        case "P": put(tv, before: true)
        case "u": tv.undoManager?.undo()
        case "r": pendingR = true
        case "R": setMode(.replace)
        case "g": pendingG = true
        case "/": startSearch(tv, forward: true)
        case "?": startSearch(tv, forward: false)
        case "n": repeatSearch(tv, forward: lastSearchForward)
        case "N": repeatSearch(tv, forward: !lastSearchForward)
        case ";":
            if let f = lastFind { performFind(tv, f.0, char: f.1, count: count()) }
        case ",":
            if let f = lastFind { performFind(tv, flipped(f.0), char: f.1, count: count()) }
        default:
            if let motion = motionKind(key, keyCode: keyCode) {
                if isFind(motion) {
                    pendingFind = motion
                } else {
                    performMotion(tv, motion, count: count())
                }
            }
            // Unknown keys are swallowed so they never leak into the document.
        }
    }

    // MARK: - Replace mode

    private func handleReplace(_ event: NSEvent, in tv: NSTextView) {
        let keyCode = Int(event.keyCode)
        let key = (event.characters ?? "").isEmpty ? "" : String((event.characters ?? "").prefix(1))

        switch keyCode {
        case 51:                             // backspace
            deleteChars(tv, before: true, count: 1)
        case 123: moveCaret(tv, .left, count: 1)     // ←
        case 124: moveCaret(tv, .right, count: 1)    // →
        case 125: moveCaret(tv, .down, count: 1)     // ↓
        case 126: moveCaret(tv, .up, count: 1)       // ↑
        case 36, 76: edit(tv, range: NSRange(location: tv.selectedRange().location, length: 0), with: "\n", action: "Insert line")
        case 48: edit(tv, range: NSRange(location: tv.selectedRange().location, length: 0), with: "\t", action: "Insert tab")
        default:
            guard key.count == 1 else { return }
            replaceCharOverwrite(tv, with: key)
        }
    }

    /// Replace mode: overwrite the character under the caret, or insert at the
    /// end of the line.
    private func replaceCharOverwrite(_ tv: NSTextView, with key: String) {
        let c = tv.selectedRange().location
        let end = lineEndPos(tv, c)
        if c < end {
            edit(tv, range: NSRange(location: c, length: 1), with: key, action: "Replace")
            tv.setSelectedRange(NSRange(location: c + 1, length: 0))
        } else {
            edit(tv, range: NSRange(location: c, length: 0), with: key, action: "Insert")
        }
    }

    // MARK: - Visual mode

    private func startVisual(_ tv: NSTextView, kind: VimMode) {
        visualAnchor = tv.selectedRange().location
        setMode(kind)
        if kind == .visualLine {
            selectVisualRange(tv)
        } else {
            tv.setSelectedRange(NSRange(location: visualAnchor, length: 0))
        }
    }

    private func exitVisual(_ tv: NSTextView) {
        let c = tv.selectedRange().location
        setMode(.normal)
        tv.setSelectedRange(NSRange(location: c, length: 0))
        visualAnchor = 0
    }

    private func handleVisual(key: String, keyCode: Int, in tv: NSTextView) {
        if key.rangeOfCharacter(from: .decimalDigits) != nil { return }

        if let inner = pendingTextObjectInner {
            pendingTextObjectInner = nil
            if key == "w" {
                selectTextObject(tv, inner: inner, bigWord: false)
            } else if key == "W" {
                selectTextObject(tv, inner: inner, bigWord: true)
            }
            return
        }

        switch key {
        case "v":
            if mode == .visual { exitVisual(tv) } else { setMode(.visual) }
        case "V":
            if mode == .visualLine { exitVisual(tv) } else { setMode(.visualLine) }
        case "i": pendingTextObjectInner = true
        case "a": pendingTextObjectInner = false
        case "d":
            applyVisualOperator(.delete, in: tv)
        case "y":
            applyVisualOperator(.yank, in: tv)
        case "c":
            applyVisualOperator(.change, in: tv)
        default:
            if let motion = motionKind(key, keyCode: keyCode) {
                let c = motionPosition(tv, motion, count: count())
                extendSelection(tv, to: c)
                if mode == .visualLine { selectVisualRange(tv) }
            }
        }
    }

    private func applyVisualOperator(_ op: VimOperator, in tv: NSTextView) {
        let sel = tv.selectedRange()
        let s = tv.string as NSString
        switch op {
        case .delete:
            if sel.length > 0 { registers[activeRegister()] = VimRegister(text: s.substring(with: sel), type: .character) }
            edit(tv, range: sel, with: "", action: "Delete selection")
            tv.setSelectedRange(NSRange(location: sel.location, length: 0))
        case .change:
            if sel.length > 0 { registers[activeRegister()] = VimRegister(text: s.substring(with: sel), type: .character) }
            edit(tv, range: sel, with: "", action: "Change selection")
            tv.setSelectedRange(NSRange(location: sel.location, length: 0))
            enterInsert()
        case .yank:
            if sel.length > 0 { registers[activeRegister()] = VimRegister(text: s.substring(with: sel), type: .character) }
            tv.setSelectedRange(NSRange(location: sel.location, length: 0))
        }
        exitVisual(tv)
    }

    private func selectVisualRange(_ tv: NSTextView) {
        let s = tv.string as NSString
        let caret = tv.selectedRange().location
        let a = s.lineRange(for: NSRange(location: min(max(visualAnchor, 0), s.length), length: 0))
        let b = s.lineRange(for: NSRange(location: min(max(caret, 0), s.length), length: 0))
        let start = min(a.location, b.location)
        let end = max(NSMaxRange(a), NSMaxRange(b))
        tv.setSelectedRange(NSRange(location: start, length: end - start))
    }

    // MARK: - Motions

    private func isFind(_ m: VimMotion) -> Bool {
        switch m {
        case .findNext, .findPrev, .tillNext, .tillPrev: return true
        default: return false
        }
    }

    private func flipped(_ m: VimMotion) -> VimMotion {
        switch m {
        case .findNext: return .findPrev
        case .findPrev: return .findNext
        case .tillNext: return .tillPrev
        case .tillPrev: return .tillNext
        default: return m
        }
    }

    private func motionKind(_ key: String, keyCode: Int) -> VimMotion? {
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
        case "G": return pendingCountDigits.isEmpty ? .docEnd : .goToLine
        case "f": return .findNext
        case "F": return .findPrev
        case "t": return .tillNext
        case "T": return .tillPrev
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

    private func performMotion(_ tv: NSTextView, _ motion: VimMotion, count: Int) {
        let c = motionPosition(tv, motion, count: count)
        tv.setSelectedRange(NSRange(location: c, length: 0))
    }

    private func moveCaret(_ tv: NSTextView, _ motion: VimMotion, count: Int) {
        performMotion(tv, motion, count: count)
    }

    private func motionPosition(_ tv: NSTextView, _ motion: VimMotion, count: Int) -> Int {
        let s = tv.string as NSString
        let caret = tv.selectedRange().location
        let n = s.length
        var c = caret
        switch motion {
        case .left:
            for _ in 0..<count {
                if c > lineStartPos(tv, c) { c -= 1 } else { break }
            }
        case .right:
            for _ in 0..<count {
                if c < lineEndPos(tv, c) { c += 1 } else { break }
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
            c = lineStartPos(tv, caret)
        case .lineFirstNonBlank:
            c = firstNonBlank(s, in: lineRange(tv, caret))
        case .lineEnd:
            c = lineEndPos(tv, caret)
        case .docStart:
            c = 0
        case .docEnd:
            c = n
        case .goToLine:
            c = goToLine(s, line: max(1, count))
        case .findNext, .findPrev, .tillNext, .tillPrev:
            break                           // handled via findPosition
        }
        return min(max(c, 0), n)
    }

    // MARK: - Find (f F t T)

    private func performFind(_ tv: NSTextView, _ motion: VimMotion, char: Character, count: Int) {
        let c = findPosition(tv, motion, char: char, count: count)
        tv.setSelectedRange(NSRange(location: c, length: 0))
    }

    private func findPosition(_ tv: NSTextView, _ motion: VimMotion, char: Character, count: Int) -> Int {
        let s = tv.string as NSString
        let scalar = String(char).utf16.first ?? 0
        let forward = motion == .findNext || motion == .tillNext
        let till = motion == .tillNext || motion == .tillPrev
        var c = tv.selectedRange().location
        for _ in 0..<count {
            guard let f = findOccurrence(s, char: scalar, from: c, forward: forward, till: till) else { break }
            c = f
        }
        return min(max(c, 0), s.length)
    }

    private func findOccurrence(_ s: NSString, char: unichar, from pos: Int, forward: Bool, till: Bool) -> Int? {
        let n = s.length
        var i = pos
        if forward {
            i += 1
            while i < n {
                if s.character(at: i) == char { return till ? i - 1 : i }
                i += 1
            }
        } else {
            i -= 1
            while i >= 0 {
                if s.character(at: i) == char { return till ? i + 1 : i }
                i -= 1
            }
        }
        return nil
    }

    // MARK: - Operators

    private func activeRegister() -> String {
        defer { pendingRegisterName = nil }
        let name = pendingRegisterName ?? ""
        return name.isEmpty ? "" : name
    }

    private func applyOperator(_ op: VimOperator, in tv: NSTextView, from start: Int, to end: Int, register: String) {
        let s = tv.string as NSString
        let range = NSRange(location: min(start, end), length: abs(end - start))
        switch op {
        case .delete:
            if range.length > 0 { registers[register] = VimRegister(text: s.substring(with: range), type: .character) }
            edit(tv, range: range, with: "", action: "Delete")
            tv.setSelectedRange(NSRange(location: range.location, length: 0))
        case .yank:
            if range.length > 0 { registers[register] = VimRegister(text: s.substring(with: range), type: .character) }
        case .change:
            if range.length > 0 { registers[register] = VimRegister(text: s.substring(with: range), type: .character) }
            edit(tv, range: range, with: "", action: "Change")
            tv.setSelectedRange(NSRange(location: range.location, length: 0))
            enterInsert()
        }
    }

    private func lineOp(_ tv: NSTextView, _ op: VimOperator, count: Int, register: String) {
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
            if full.length > 0 { registers[register] = VimRegister(text: s.substring(with: full), type: .line) }
            edit(tv, range: full, with: "", action: "Delete line")
            tv.setSelectedRange(NSRange(location: min(full.location, s.length - full.length), length: 0))
        case .yank:
            if full.length > 0 { registers[register] = VimRegister(text: s.substring(with: full), type: .line) }
        case .change:
            if full.length > 0 { registers[register] = VimRegister(text: s.substring(with: full), type: .line) }
            edit(tv, range: full, with: "", action: "Change line")
            tv.setSelectedRange(NSRange(location: full.location, length: 0))
            enterInsert()
        }
    }

    private func applyTextObject(_ tv: NSTextView, inner: Bool, bigWord: Bool = false) {
        guard let op = pendingOperator else { return }
        let s = tv.string as NSString
        let (a, b) = wordRange(s, at: tv.selectedRange().location, inner: inner, bigWord: bigWord)
        let range = NSRange(location: a, length: b - a)
        switch op {
        case .delete:
            edit(tv, range: range, with: "", action: "Delete word")
            tv.setSelectedRange(NSRange(location: a, length: 0))
        case .change:
            edit(tv, range: range, with: "", action: "Change word")
            tv.setSelectedRange(NSRange(location: a, length: 0))
            enterInsert()
        case .yank:
            registers[activeRegister()] = VimRegister(text: s.substring(with: range), type: .character)
        }
        pendingOperator = nil
    }

    private func selectTextObject(_ tv: NSTextView, inner: Bool, bigWord: Bool) {
        let s = tv.string as NSString
        let (a, b) = wordRange(s, at: tv.selectedRange().location, inner: inner, bigWord: bigWord)
        tv.setSelectedRange(NSRange(location: a, length: b - a))
    }

    // MARK: - Small edits

    private func replaceChar(_ tv: NSTextView, with key: String) {
        let c = tv.selectedRange().location
        guard c < tv.string.count else { return }
        edit(tv, range: NSRange(location: c, length: 1), with: key, action: "Replace")
    }

    private func deleteChars(_ tv: NSTextView, before: Bool, count: Int) {
        let s = tv.string as NSString
        let c = tv.selectedRange().location
        if before {
            let start = max(0, c - count)
            edit(tv, range: NSRange(location: start, length: c - start), with: "", action: "Delete")
            tv.setSelectedRange(NSRange(location: start, length: 0))
        } else {
            let end = min(c + count, s.length)
            edit(tv, range: NSRange(location: c, length: max(0, end - c)), with: "", action: "Delete")
        }
    }

    private func deleteToEndOfLine(_ tv: NSTextView) {
        let c = tv.selectedRange().location
        let end = lineEndPos(tv, c)
        guard end > c else { return }
        edit(tv, range: NSRange(location: c, length: end - c), with: "", action: "Delete to end of line")
    }

    private func changeToEndOfLine(_ tv: NSTextView) {
        let c = tv.selectedRange().location
        let end = lineEndPos(tv, c)
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
        let name = pendingRegisterName ?? ""
        pendingRegisterName = nil
        guard let reg = registers[name.isEmpty ? "" : name], !reg.text.isEmpty else { return }
        let s = tv.string as NSString
        let caret = tv.selectedRange().location
        if reg.type == .line {
            let r = s.lineRange(for: NSRange(location: min(caret, s.length), length: 0))
            let insertPos = before ? r.location : NSMaxRange(r)
            edit(tv, range: NSRange(location: insertPos, length: 0), with: reg.text, action: "Put")
            tv.setSelectedRange(NSRange(location: insertPos, length: 0))
        } else {
            let insertPos = before ? caret : caret + 1
            edit(tv, range: NSRange(location: insertPos, length: 0), with: reg.text, action: "Put")
            tv.setSelectedRange(NSRange(location: insertPos + (reg.text as NSString).length, length: 0))
        }
    }

    // MARK: - Search (/ ? n N)

    private func startSearch(_ tv: NSTextView, forward: Bool) {
        searchForward = forward
        searchQuery = ""
        searching = true
        modeChanged()
    }

    private func handleSearch(key: String, keyCode: Int, in tv: NSTextView) {
        switch keyCode {
        case 51:                                    // backspace
            if !searchQuery.isEmpty { searchQuery.removeLast() }
        case 36, 76:                                // return/enter → run
            searching = false
            lastSearch = searchQuery
            lastSearchForward = searchForward
            runSearch(tv, query: searchQuery, forward: searchForward)
            searchQuery = ""
        default:
            if key.count == 1 { searchQuery += key }
        }
        modeChanged()
    }

    private func runSearch(_ tv: NSTextView, query: String, forward: Bool) {
        guard !query.isEmpty else { return }
        let s = tv.string as NSString
        let n = s.length
        guard n > 0 else { return }
        let caret = tv.selectedRange().location
        var r: NSRange?
        if forward {
            let start = min(caret + 1, n)
            if start < n {
                r = s.range(of: query, options: [], range: NSRange(location: start, length: n - start))
            }
            if r == nil {                            // wrap to the top
                r = s.range(of: query, options: [], range: NSRange(location: 0, length: n))
            }
        } else {
            let end = max(0, caret)
            if end > 0 {
                r = s.range(of: query, options: [.backwards], range: NSRange(location: 0, length: end))
            }
            if r == nil {                            // wrap to the bottom
                r = s.range(of: query, options: [.backwards], range: NSRange(location: 0, length: n))
            }
        }
        guard let found = r, found.location != NSNotFound else { NSSound.beep(); return }
        tv.setSelectedRange(NSRange(location: found.location, length: found.length))
        tv.scrollRangeToVisible(found)
    }

    private func repeatSearch(_ tv: NSTextView, forward: Bool) {
        guard !lastSearch.isEmpty else { return }
        runSearch(tv, query: lastSearch, forward: forward)
    }

    // MARK: - Undo / redo

    private func redo(_ tv: NSTextView) {
        tv.undoManager?.redo()
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
        defer { pendingCountDigits = "" }
        return Int(pendingCountDigits) ?? 1
    }

    private func lineRange(_ tv: NSTextView, _ pos: Int) -> NSRange {
        let s = tv.string as NSString
        return s.lineRange(for: NSRange(location: min(max(pos, 0), s.length), length: 0))
    }

    private func lineStartPos(_ tv: NSTextView, _ pos: Int) -> Int {
        lineRange(tv, pos).location
    }

    private func lineEndPos(_ tv: NSTextView, _ pos: Int) -> Int {
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

    private func isWhitespace(_ s: NSString, _ i: Int) -> Bool {
        guard i >= 0, i < s.length else { return true }
        guard let scalar = UnicodeScalar(s.character(at: i)) else { return true }
        return whitespace.contains(scalar)
    }

    private func wordForward(_ s: NSString, from pos: Int, count: Int) -> Int {
        let n = s.length
        var i = min(max(pos, 0), n)
        for _ in 0..<count {
            while i < n && isWordChar(s, i) { i += 1 }
            while i < n && !isWordChar(s, i) && !isWhitespace(s, i) { i += 1 }
            while i < n && isWhitespace(s, i) { i += 1 }
        }
        return i
    }

    private func wordBackward(_ s: NSString, from pos: Int, count: Int) -> Int {
        var i = min(max(pos, 0), s.length)
        for _ in 0..<count {
            while i > 0 && isWhitespace(s, i - 1) { i -= 1 }
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
            while i < n && isWhitespace(s, i) { i += 1 }
            guard i < n else { break }
            let isWord = isWordChar(s, i)
            while i < n && isWordChar(s, i) == isWord { i += 1 }
            if i > 0 { i -= 1 }
        }
        return i
    }

    private func wordRange(_ s: NSString, at pos: Int, inner: Bool, bigWord: Bool) -> (Int, Int) {
        let n = s.length
        guard n > 0 else { return (0, 0) }
        let p = min(max(pos, 0), n - 1)

        let tokenIsWord: Bool
        if bigWord {
            tokenIsWord = !isWhitespace(s, p)
        } else {
            tokenIsWord = isWordChar(s, p)
        }

        var start = p
        while start > 0 {
            let prev: Bool
            if bigWord { prev = !isWhitespace(s, start - 1) } else { prev = isWordChar(s, start - 1) }
            if prev == tokenIsWord { start -= 1 } else { break }
        }
        var end = p
        while end < n {
            let cur: Bool
            if bigWord { cur = !isWhitespace(s, end) } else { cur = isWordChar(s, end) }
            if cur == tokenIsWord { end += 1 } else { break }
        }

        if inner {
            return (start, end)
        }
        // Outer (aw/aW): a word plus its trailing whitespace; when starting on
        // whitespace, take the whitespace plus the following word.
        var e = end
        while e < n && isWhitespace(s, e) { e += 1 }
        if !tokenIsWord {
            while e < n && !isWhitespace(s, e) { e += 1 }
        }
        return (start, e)
    }

    private func extendSelection(_ tv: NSTextView, to pos: Int) {
        let start = visualAnchor
        tv.setSelectedRange(NSRange(location: min(start, pos), length: abs(pos - start)))
    }
}

// VimTextView — NSTextView base that routes keys through the Vim controller
// when Vim mode is enabled. Both editor text views inherit from this.
class VimTextView: NSTextView {

    let vim = VimController()

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