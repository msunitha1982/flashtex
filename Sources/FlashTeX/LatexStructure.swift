import Foundation
import SwiftUI

// LatexStructure — cheap syntactic sanity checks on the document source.
//
// Used to gate the debounced auto-compile: while the document has an open
// `\begin{env}` without its matching `\end{env}`, every keystroke would spawn a
// doomed engine run that fails with "Missing \end". Waiting until the document
// is structurally balanced keeps the preview stable and avoids build churn.

enum LatexStructure {

    /// Tab-triggered block snippets: typing the word then Tab expands to a
    /// full `\begin{env}` / `\end{env}` pair with the caret on the blank line.
    static let snippetEnvironments: [String: String] = [
        "frame": "frame",
        "align": "align",
        "table": "table",
        "matrix": "matrix",
        "itemize": "itemize",
        "enumerate": "enumerate",
        "figure": "figure",
    ]

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

// ===========================================================================
//  Document outline
// ===========================================================================

struct OutlineEntry: Identifiable, Equatable {
    let id = UUID()
    let level: Int        // 0 = \section, 1 = \subsection, 2 = \subsubsection
    let title: String
    let line: Int         // 1-based line number
    let isLabel: Bool

    var depth: Int { level }
}

enum DocumentOutline {

    /// Parse `\section` / `\subsection` / `\subsubsection` / `\label` commands.
    /// Labels are attached at the depth of the nearest preceding heading.
    static func parse(_ source: String) -> [OutlineEntry] {
        var entries: [OutlineEntry] = []
        var currentDepth = 0

        var index = source.startIndex
        var line = 1
        while index < source.endIndex {
            // Skip comment lines so a commented-out \section doesn't show up.
            if source[index] == "%", index == source.startIndex
                || source[source.index(before: index)] != "\\" {
                while index < source.endIndex, source[index] != "\n" {
                    index = source.index(after: index)
                }
                // Consume the newline too so the line counter below doesn't
                // double-count this line.
                if index < source.endIndex {
                    index = source.index(after: index)
                }
                line += 1
                continue
            }

            if source[index] == "\\" {
                var j = source.index(after: index)
                while j < source.endIndex, source[j].isLetter || source[j] == "*" {
                    j = source.index(after: j)
                }
                let command = String(source[index..<j])
                switch command {
                case "\\section":
                    if let name = groupAfter(source, at: j) {
                        entries.append(OutlineEntry(
                            level: 0, title: name, line: line, isLabel: false))
                        currentDepth = 0
                    }
                    index = j
                    continue
                case "\\subsection":
                    if let name = groupAfter(source, at: j) {
                        entries.append(OutlineEntry(
                            level: 1, title: name, line: line, isLabel: false))
                        currentDepth = 1
                    }
                    index = j
                    continue
                case "\\subsubsection":
                    if let name = groupAfter(source, at: j) {
                        entries.append(OutlineEntry(
                            level: 2, title: name, line: line, isLabel: false))
                        currentDepth = 2
                    }
                    index = j
                    continue
                case "\\label":
                    if let name = groupAfter(source, at: j) {
                        entries.append(OutlineEntry(
                            level: currentDepth, title: name, line: line,
                            isLabel: true))
                    }
                    index = j
                    continue
                default:
                    index = j
                    continue
                }
            }
            if source[index] == "\n" {
                line += 1
            }
            index = source.index(after: index)
        }
        return entries
    }

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

/// SwiftUI sidebar listing the document structure. Clicking an entry jumps the
/// editor to that line.
struct DocumentOutlineView: View {
    let entries: [OutlineEntry]
    let onSelect: (OutlineEntry) -> Void

    var body: some View {
        List(entries) { entry in
            Button(action: { onSelect(entry) }) {
                HStack(spacing: 4) {
                    Image(systemName: entry.isLabel
                        ? "tag"
                        : ["1.square", "2.square", "3.square"][min(entry.depth, 2)])
                        .font(.system(size: 9))
                        .foregroundColor(entry.isLabel ? .secondary : .accentColor)
                        .frame(width: 12)
                    Text(entry.title)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundColor(entry.isLabel ? .secondary : .primary)
                        .help(entry.title)
                }
                .padding(.leading, CGFloat(entry.depth) * 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .listStyle(.sidebar)
    }
}

final class OutlineModel: ObservableObject {
    @Published var entries: [OutlineEntry] = []
    var onSelect: ((OutlineEntry) -> Void)?
}

final class OutlineViewController: NSViewController {
    let model = OutlineModel()

    override func loadView() {
        let hosting = NSHostingView(rootView: DocumentOutlineView(
            entries: model.entries,
            onSelect: { [weak self] entry in self?.model.onSelect?(entry) }))
        if #available(macOS 13.0, *) {
            hosting.sizingOptions = [.preferredContentSize]
        }
        view = hosting
    }

    func update(entries: [OutlineEntry], onSelect: @escaping (OutlineEntry) -> Void) {
        model.onSelect = onSelect
        model.entries = entries
        if let hosting = view as? NSHostingView<DocumentOutlineView> {
            hosting.rootView = DocumentOutlineView(
                entries: model.entries,
                onSelect: { [weak self] entry in self?.model.onSelect?(entry) })
        }
    }
}
