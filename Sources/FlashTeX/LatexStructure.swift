import Foundation

// LatexStructure — cheap syntactic sanity checks on the document source.
//
// Used to gate the debounced auto-compile: while the document has an open
// `\begin{env}` without its matching `\end{env}`, every keystroke would spawn a
// doomed engine run that fails with "Missing \end". Waiting until the document
// is structurally balanced keeps the preview stable and avoids build churn.

enum LatexStructure {

    /// True when every `\begin{env}` has a matching `\end{env}` in the right
    /// nesting order, ignoring comment lines. Content inside `verbatim`-style
    /// environments is skipped so literal `\begin`/`\end` there can't confuse
    /// the count.
    static func isBalanced(_ source: String) -> Bool {
        var stack: [String] = []
        var inVerbatim = false

        var index = source.startIndex
        while index < source.endIndex {
            let char = source[index]

            // Comments: everything from an unescaped `%` to end of line is
            // invisible to TeX.
            if char == "%", index == source.startIndex
                || source[source.index(before: index)] != "\\" {
                while index < source.endIndex, source[index] != "\n" {
                    index = source.index(after: index)
                }
                continue
            }

            if char == "\\" {
                // verbatim-style environments swallow everything to \end{...},
                // so don't scan for \begin/\end while inside one.
                if inVerbatim {
                    var v = source.index(after: index)
                    while v < source.endIndex, source[v].isLetter { v = source.index(after: v) }
                    let command = String(source[index..<v])
                    if command == "\\end", let name = groupAfter(source, at: v),
                       name == "verbatim" || name == "Verbatim" || name == "lstlisting"
                           || name == "minted" || name == "comment" {
                        inVerbatim = false
                        index = v
                    } else {
                        index = source.index(after: index)
                    }
                    continue
                }

                var j = source.index(after: index)
                while j < source.endIndex, source[j].isLetter {
                    j = source.index(after: j)
                }
                let command = String(source[index..<j])
                let name = groupAfter(source, at: j)
                switch command {
                case "\\begin":
                    if let name {
                        if name == "verbatim" || name == "Verbatim"
                            || name == "lstlisting" || name == "minted"
                            || name == "comment" {
                            inVerbatim = true
                        } else {
                            stack.append(name)
                        }
                    }
                    index = j
                case "\\end":
                    if let name {
                        if name == "verbatim" || name == "Verbatim"
                            || name == "lstlisting" || name == "minted"
                            || name == "comment" {
                            inVerbatim = false
                        } else {
                            guard stack.popLast() == name else { return false }
                        }
                    }
                    index = j
                default:
                    index = j
                }
                continue
            }
            index = source.index(after: index)
        }

        if inVerbatim { return false }        // dangling verbatim block
        return stack.isEmpty
    }

    /// The `{...}` group immediately after `position`, or nil when absent.
    /// Skips whitespace between the command and the opening brace; comment
    /// content inside the group is excluded from the returned name.
    private static func groupAfter(_ source: String, at position: String.Index)
        -> String? {
        var j = position
        while j < source.endIndex, source[j] == " " || source[j] == "\n"
            || source[j] == "\t" {
            j = source.index(after: j)
        }
        guard j < source.endIndex, source[j] == "{" else { return nil }
        var depth = 1
        var k = source.index(after: j)
        var pieces: [String] = []
        var pieceStart = k
        while k < source.endIndex {
            let c = source[k]
            if c == "{" {
                depth += 1
            } else if c == "}" {
                depth -= 1
                if depth == 0 {
                    pieces.append(String(source[pieceStart..<k]))
                    let name = pieces.joined().replacingOccurrences(of: "\n", with: " ")
                        .trimmingCharacters(in: .whitespaces)
                    return name.isEmpty ? "" : name
                }
            } else if c == "%", k == pieceStart
                || source[source.index(before: k)] != "\\" {
                pieces.append(String(source[pieceStart..<k]))
                while k < source.endIndex, source[k] != "\n" {
                    k = source.index(after: k)
                }
                pieceStart = k
                continue
            }
            k = source.index(after: k)
        }
        return nil
    }
}
