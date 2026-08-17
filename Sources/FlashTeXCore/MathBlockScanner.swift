import Foundation

// TeXMathBlockScanner — pure structural scanner for math blocks.
//
// Identifies `$…$`, `$$…$$`, `\[…\]` and the display-math environments
// (`equation`, `align*`, …). It records the block kind, its exact source range
// and line span, and the trimmed inner body. Pure Foundation, so the same
// scanner powers both the proximity renderer (app target) and the invalidation
// tests (FlashTeXCoreTests).

public enum TeXMathBlockKind: Equatable {
    case inline              // $…$
    case dollarDisplay       // $$…$$
    case bracket             // \[…\]
    case environment(String) // \begin{…}…\end{…}
}

public struct TeXMathBlock: Equatable {
    public let index: Int
    public let kind: TeXMathBlockKind
    public let range: NSRange       // full range including the delimiters
    public let display: Bool
    public let body: String         // trimmed inner source (no delimiters)
    public let raw: String          // exact source substring (delimiters included)
    public let lineStart: Int       // 1-based source lines spanned by the block
    public let lineEnd: Int
}

public final class BlockScanner {

    /// Environments that are safe to re-render alone. Non-starred multi-row
    /// environments number their rows, so only starred ones qualify.
    public static let localEnvs: Set<String> = [
        "equation", "equation*", "displaymath",
        "align*", "gather*", "multline*", "flalign*", "alignat*",
    ]

    private let displayEnvs: Set<String> = [
        "equation", "equation*", "displaymath",
        "align", "align*", "gather", "gather*",
        "multline", "multline*", "flalign", "flalign*",
        "alignat", "alignat*",
    ]

    public init() {}

    public func blocks(in text: NSString) -> [TeXMathBlock] {
        var result: [TeXMathBlock] = []
        let lineStarts = Self.lineStarts(of: text)
        let n = text.length
        var i = 0
        while i < n {
            let c = text.character(at: i)
            if c == 36 {   // `$`
                if let b = scanDollar(text, from: i, index: result.count,
                                      lineStarts: lineStarts) {
                    result.append(b)
                    i = b.range.location + b.range.length
                } else {
                    i += 1
                }
                continue
            }
            if c == 92 {   // `\`
                if let b = scanEnvironment(text, from: i, index: result.count,
                                           lineStarts: lineStarts)
                    ?? scanBracket(text, from: i, index: result.count,
                                   lineStarts: lineStarts) {
                    result.append(b)
                    i = b.range.location + b.range.length
                    continue
                }
            }
            i += 1
        }
        return result
    }

    /// Number of `\begin{equation}` blocks that start before `location`
    /// (starred variants don't increment the counter and are excluded).
    /// The isolated render injects this + 1 so a numbered equation keeps its
    /// document-wide number.
    public func countNumberedEquations(before location: Int, in source: String) -> Int {
        let pattern = #"\\begin\{equation\}(?!\*)"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return 0 }
        let ns = source as NSString
        var count = 0
        for m in re.matches(in: source, range: NSRange(location: 0, length: ns.length))
            where m.range.location < location {
            count += 1
        }
        return count
    }

    // MARK: - Scanners

    private func scanDollar(_ text: NSString, from i: Int, index: Int,
                            lineStarts: [Int]) -> TeXMathBlock? {
        let n = text.length
        guard !isEscaped(text, i) else { return nil }
        let display = i + 1 < n && text.character(at: i + 1) == 36
        let open = display ? 2 : 1
        var j = i + open
        while j < n {
            let c = text.character(at: j)
            if c == 36 && !isEscaped(text, j) {
                if display {
                    if j + 1 < n && text.character(at: j + 1) == 36 {
                        return makeBlock(text, from: i, open: open, firstClosing: j,
                                         display: true, index: index,
                                         kind: .dollarDisplay,
                                         lineStarts: lineStarts)
                    }
                } else {
                    if j + 1 < n && text.character(at: j + 1) == 36 {
                        j += 1          // part of a $$ pair — keep scanning
                        continue
                    }
                    return makeBlock(text, from: i, open: open, firstClosing: j,
                                     display: false, index: index, kind: .inline,
                                     lineStarts: lineStarts)
                }
            }
            j += 1
        }
        return nil
    }

    private func scanEnvironment(_ text: NSString, from start: Int, index: Int,
                                 lineStarts: [Int]) -> TeXMathBlock? {
        let n = text.length
        guard start + 7 <= n,
              text.substring(with: NSRange(location: start, length: 7)) == "\\begin{" else {
            return nil
        }
        var k = start + 7
        let nameStart = k
        while k < n && text.character(at: k) != 125 { k += 1 }   // `}`
        guard k < n, k > nameStart else { return nil }
        let name = text.substring(with: NSRange(location: nameStart, length: k - nameStart))
        guard displayEnvs.contains(name) else { return nil }

        let bodyStart = k + 1
        let searchRange = NSRange(location: bodyStart, length: n - bodyStart)
        let endMarker = "\\end{\(name)}"
        let endLoc = text.range(of: endMarker, options: [], range: searchRange).location
        guard endLoc != NSNotFound else { return nil }

        let end = endLoc + endMarker.count
        let range = NSRange(location: start, length: end - start)
        let body = text.substring(with: NSRange(location: bodyStart,
                                                length: endLoc - bodyStart))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return makeBlock(text, range: range, display: true, index: index,
                         kind: .environment(name), body: body, lineStarts: lineStarts)
    }

    private func scanBracket(_ text: NSString, from start: Int, index: Int,
                             lineStarts: [Int]) -> TeXMathBlock? {
        let n = text.length
        guard start + 1 < n,
              text.character(at: start) == 92,        // `\`
              text.character(at: start + 1) == 91 else { return nil }   // `[`
        var k = start + 2
        while k + 1 < n {
            if text.character(at: k) == 92, text.character(at: k + 1) == 93 {   // `\]`
                let range = NSRange(location: start, length: (k + 2) - start)
                let body = text.substring(with: NSRange(location: start + 2,
                                                        length: k - (start + 2)))
                return makeBlock(text, range: range, display: true, index: index,
                                 kind: .bracket, body: body, lineStarts: lineStarts)
            }
            k += 1
        }
        return nil
    }

    private func makeBlock(_ text: NSString, from start: Int, open: Int,
                           firstClosing: Int, display: Bool, index: Int,
                           kind: TeXMathBlockKind,
                           lineStarts: [Int]) -> TeXMathBlock {
        let bodyStart = start + open
        let body = text.substring(with: NSRange(location: bodyStart,
                                                length: firstClosing - bodyStart))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(location: start, length: firstClosing - start + open)
        return makeBlock(text, range: range, display: display, index: index,
                         kind: kind, body: body, lineStarts: lineStarts)
    }

    private func makeBlock(_ text: NSString, range: NSRange, display: Bool, index: Int,
                           kind: TeXMathBlockKind, body: String,
                           lineStarts: [Int]) -> TeXMathBlock {
        TeXMathBlock(index: index, kind: kind, range: range,
                  display: display, body: body,
                  raw: text.substring(with: range),
                  lineStart: lineNumber(at: range.location, lineStarts: lineStarts),
                  lineEnd: lineNumber(at: max(NSMaxRange(range) - 1, range.location), lineStarts: lineStarts))
    }

    private func isEscaped(_ text: NSString, _ index: Int) -> Bool {
        var count = 0
        var k = index - 1
        while k >= 0 && text.character(at: k) == 92 { count += 1; k -= 1 }
        return count % 2 == 1
    }

    // MARK: - Line numbers

    private static func lineStarts(of text: NSString) -> [Int] {
        var starts = [0]
        var i = 0
        while i < text.length {
            if text.character(at: i) == 10 { starts.append(i + 1) }
            i += 1
        }
        return starts
    }

    private func lineNumber(at charIndex: Int, lineStarts: [Int]) -> Int {
        guard !lineStarts.isEmpty else { return 1 }
        var low = 0
        var high = lineStarts.count - 1
        var result = 0
        while low <= high {
            let mid = (low + high) / 2
            if lineStarts[mid] <= charIndex {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result + 1
    }
}