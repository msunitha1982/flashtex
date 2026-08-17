import Foundation

// DocumentModel — a lightweight structural model of the LaTeX document.
//
// Not a full LaTeX parser: enough structure to classify the blast radius of an
// edit. The body is scanned into nodes (sections, display math, floats,
// graphics, code, text runs) each with a source range and line span, and a set
// of dependency facts (labels, references, macro definitions, counter games,
// external inputs, document-wide markers) is extracted. Unknown or unparsable
// content is simply not given a node, which makes the classifier conservative
// (an edit in an unknown region defaults to a full compile).

public enum DocNodeKind: Equatable {
    case preamble
    case section(Int)       // depth: part=0 chapter=1 section=2 subsection=3 …
    case textBlock          // a run of body text (paragraph-ish)
    case equation           // display math: $$…$$, \[…\], equation, align*, …
    case inlineMath         // $…$
    case figure
    case table
    case graphics           // tikzpicture / tikzcd / asy / pgfplots
    case codeBlock          // lstlisting / minted / verbatim
    case boxed              // tcolorbox / minipage / other containers
}

public struct DocNode {
    public let id: Int
    public let kind: DocNodeKind
    public let range: NSRange
    public let lineStart: Int      // 1-based
    public let lineEnd: Int
    /// Depth of the innermost section containing this node (0 = preamble,
    /// 1 = body before the first section).
    public let sectionDepth: Int

    public var isLocalRenderCandidate: Bool {
        switch kind {
        case .equation: return true
        case .inlineMath, .figure, .table, .graphics, .codeBlock,
             .boxed, .preamble, .textBlock, .section: return false
        }
    }
}

/// Dependency facts extracted from the whole document. These are the things an
/// edit can disturb beyond its own node.
public struct DocFacts: Equatable {
    public var labels: [String: NSRange] = [:]
    public var refs: [String: [NSRange]] = [:]
    public var macroDefs: [String: NSRange] = [:]
    public var counterTouchers: [NSRange] = []
    public var externalInputs: [NSRange] = []
    public var globalMarkers: [NSRange] = []

    public init() {}
}

public struct DocumentModel {
    public let source: String
    public let sourceHash: UInt64
    /// Range of the preamble (up to and including `\begin{document}`).
    public let preambleRange: NSRange
    /// All nodes in source order.
    public let nodes: [DocNode]
    public let facts: DocFacts

    public var preambleText: String {
        (source as NSString).substring(with: preambleRange)
    }

    /// The node whose range strictly contains `charIndex`, if any.
    public func node(containing charIndex: Int) -> DocNode? {
        for node in nodes where node.range.location <= charIndex && NSMaxRange(node.range) > charIndex {
            return node
        }
        return nil
    }
}

public final class DocumentModelParser {

    private static let sectionDepthMap: [String: Int] = [
        "part": 0, "chapter": 1, "section": 2, "subsection": 3,
        "subsubsection": 4, "paragraph": 5, "subparagraph": 6,
    ]

    private static let floatEnvs: Set<String> = ["figure", "figure*", "table", "table*"]
    private static let graphicsEnvs: Set<String> = ["tikzpicture", "tikzcd", "asy", "pgfplots", "axis"]
    private static let codeEnvs: Set<String> = ["lstlisting", "minted", "verbatim", "verbatim*"]
    private static let boxEnvs: Set<String> = ["tcolorbox", "minipage", "quote", "quotation", "center"]

    public init() {}

    public func parse(_ source: String) -> DocumentModel {
        let ns = source as NSString
        let hash = Self.djb2(source)

        // Split preamble / body.
        var bodyStart = ns.length
        var preambleRange = NSRange(location: 0, length: ns.length)
        let begin = ns.range(of: "\\begin{document}").location
        if begin != NSNotFound {
            bodyStart = begin
            preambleRange = NSRange(location: 0, length: begin)
        }

        var nodes: [DocNode] = []
        var facts = DocFacts()
        var id = 0

        if preambleRange.length > 0 {
            nodes.append(DocNode(id: id, kind: .preamble,
                                 range: preambleRange,
                                 lineStart: 1,
                                 lineEnd: max(1, lineNumber(at: begin == NSNotFound ? max(ns.length - 1, 0) : begin, in: ns)),
                                 sectionDepth: 0))
            id += 1
            collectFacts(in: preambleRange, ns: ns, facts: &facts)
        }

        if bodyStart < ns.length {
            let bodyRange = NSRange(location: bodyStart, length: ns.length - bodyStart)
            let bodyNodes = parseBody(bodyRange, ns: ns, startID: id, facts: &facts)
            nodes.append(contentsOf: bodyNodes)
        }

        return DocumentModel(source: source, sourceHash: hash,
                             preambleRange: preambleRange, nodes: nodes, facts: facts)
    }

    private func parseBody(_ range: NSRange, ns: NSString, startID: Int,
                           facts: inout DocFacts) -> [DocNode] {
        var nodes: [DocNode] = []
        var id = startID

        // Locate every structural element in the body.
        var items: [(kind: DocNodeKind, range: NSRange)] = []

        // Sections.
        let sectionRe = try! NSRegularExpression(
            pattern: #"\\(part|chapter|section|subsection|subsubsection|paragraph|subparagraph)\*?(\[[^\]]*\])?\{([^}]*(?:\{[^}]*\}[^}]*)*)\}"#)
        for m in sectionRe.matches(in: ns as String, range: range) {
            let name = (ns as NSString).substring(with: m.range(at: 1))
            items.append((.section(Self.sectionDepthMap[name] ?? 2), m.range))
        }

        // Display math + inline math.
        let math = BlockScanner().blocks(in: ns)
        for b in math where b.range.location >= range.location && NSMaxRange(b.range) <= NSMaxRange(range) {
            items.append((b.display ? .equation : .inlineMath, b.range))
        }

        // Floats / graphics / code / boxed environments.
        let envRe = try! NSRegularExpression(pattern: #"\\begin\{([a-zA-Z*]+)\}"#)
        var envSpans: [String: [NSRange]] = [:]
        for m in envRe.matches(in: ns as String, range: range) {
            let name = (ns as NSString).substring(with: m.range(at: 1))
            envSpans[name, default: []].append(m.range)
        }
        let kinds: [(Set<String>, DocNodeKind)] = [
            (Self.floatEnvs, .figure), (Self.graphicsEnvs, .graphics),
            (Self.codeEnvs, .codeBlock), (Self.boxEnvs, .boxed),
        ]
        for (envs, kind) in kinds {
            for name in envs {
                guard let opens = envSpans[name] else { continue }
                for open in opens {
                    let endMarker = "\\end{\(name)}"
                    let searchFrom = NSMaxRange(open)
                    guard searchFrom <= ns.length else { continue }
                    let endLoc = ns.range(of: endMarker,
                                          options: [],
                                          range: NSRange(location: searchFrom,
                                                        length: ns.length - searchFrom)).location
                    guard endLoc != NSNotFound else { continue }
                    let end = endLoc + endMarker.count
                    items.append((kind, NSRange(location: open.location,
                                                length: end - open.location)))
                }
            }
        }

        items.sort { $0.range.location < $1.range.location }

        // Merge overlapping items (a math block inside a figure shouldn't create
        // a nested sibling at the same level).
        var merged: [(kind: DocNodeKind, range: NSRange)] = []
        for it in items {
            if let last = merged.last, NSMaxRange(last.range) > it.range.location {
                continue   // contained in (or overlapping) the previous item
            }
            merged.append(it)
        }

        // Assign section depth by tracking the open section stack.
        var depthStack: [Int] = []
        var currentDepth = 0
        var cursor = range.location

        /// Emit a textBlock node for each maximal run of non-whitespace in the
        /// gap between two structural items, tagged with the current depth.
        func emitTextChunks(between start: Int, and end: Int) {
            guard end > start else { return }
            var chunkStart: Int?
            var i = start
            while i <= end {
                let isEnd = i == end
                let isWS: Bool
                if isEnd {
                    isWS = true
                } else {
                    let ch = ns.character(at: i)
                    isWS = ch == 32 || ch == 9 || ch == 10 || ch == 13
                }
                if isWS {
                    if let cs = chunkStart {
                        nodes.append(DocNode(id: id,
                                             kind: .textBlock,
                                             range: NSRange(location: cs, length: i - cs),
                                             lineStart: lineNumber(at: cs, in: ns),
                                             lineEnd: lineNumber(at: max(i - 1, cs), in: ns),
                                             sectionDepth: currentDepth))
                        id += 1
                        chunkStart = nil
                    }
                } else if chunkStart == nil {
                    chunkStart = i
                }
                i += 1
            }
        }

        for it in merged {
            // Text between the cursor and this item belongs to the current depth.
            emitTextChunks(between: cursor, and: it.range.location)
            if case .section(let level) = it.kind {
                // Sections always re-open at their own level; nested sections
                // that are deeper than the new one get closed.
                while let top = depthStack.last, top >= level {
                    depthStack.removeLast()
                }
                depthStack.append(level)
                currentDepth = level
                nodes.append(DocNode(id: id, kind: it.kind, range: it.range,
                                     lineStart: lineNumber(at: it.range.location, in: ns),
                                     lineEnd: lineNumber(at: max(NSMaxRange(it.range) - 1, it.range.location), in: ns),
                                     sectionDepth: level))
                id += 1
            } else {
                nodes.append(DocNode(id: id, kind: it.kind, range: it.range,
                                     lineStart: lineNumber(at: it.range.location, in: ns),
                                     lineEnd: lineNumber(at: max(NSMaxRange(it.range) - 1, it.range.location), in: ns),
                                     sectionDepth: currentDepth))
                id += 1
            }
            cursor = NSMaxRange(it.range)
        }
        emitTextChunks(between: cursor, and: NSMaxRange(range))

        collectFacts(in: range, ns: ns, facts: &facts)
        return nodes
    }

    private func collectFacts(in range: NSRange, ns: NSString, facts: inout DocFacts) {
        let sub = ns.substring(with: range)
        let nsSub = sub as NSString
        let full = NSRange(location: 0, length: nsSub.length)

        if let re = try? NSRegularExpression(pattern: #"\\label\{([^}]*)\}"#) {
            for m in re.matches(in: sub, range: full) {
                let name = nsSub.substring(with: m.range(at: 1))
                facts.labels[name] = NSRange(location: range.location + m.range.location,
                                             length: m.range.length)
            }
        }
        let refPatterns = [#"\\ref\{([^}]*)\}"#, #"\\eqref\{([^}]*)\}"#,
                           #"\\pageref\{([^}]*)\}"#, #"\\autoref\{([^}]*)\}"#,
                           #"\\cref\{([^}]*)\}"#, #"\\vref\{([^}]*)\}"#]
        for pattern in refPatterns {
            if let re = try? NSRegularExpression(pattern: pattern) {
                for m in re.matches(in: sub, range: full) {
                    let name = nsSub.substring(with: m.range(at: 1))
                    facts.refs[name, default: []].append(
                        NSRange(location: range.location + m.range.location, length: m.range.length))
                }
            }
        }
        let macroPatterns = [#"\\newcommand\{\\([^}]*)\}"#, #"\\renewcommand\{\\([^}]*)\}"#,
                             #"\\providecommand\{\\([^}]*)\}"#, #"\\def\\([^ {]+)"#,
                             #"\\newenvironment\{([^}]*)\}"#, #"\\renewenvironment\{([^}]*)\}"#,
                             #"\\DeclareMathOperator\{\\([^}]*)\}"#]
        for pattern in macroPatterns {
            if let re = try? NSRegularExpression(pattern: pattern) {
                for m in re.matches(in: sub, range: full) {
                    let name = nsSub.substring(with: m.range(at: 1))
                    facts.macroDefs[name] = NSRange(location: range.location + m.range.location,
                                                    length: m.range.length)
                }
            }
        }
        if let re = try? NSRegularExpression(pattern: #"\\\(new|addto|set\)counter"#) {
            for m in re.matches(in: sub, range: full) {
                facts.counterTouchers.append(NSRange(location: range.location + m.range.location,
                                                     length: m.range.length))
            }
        }
        let inputPatterns = [#"\\input\{[^}]*\}"#, #"\\include\{[^}]*\}"#,
                             #"\\includegraphics\{[^}]*\}"#]
        for pattern in inputPatterns {
            if let re = try? NSRegularExpression(pattern: pattern) {
                for m in re.matches(in: sub, range: full) {
                    facts.externalInputs.append(NSRange(location: range.location + m.range.location,
                                                        length: m.range.length))
                }
            }
        }
        let globalPatterns = [#"\\tableofcontents"#, #"\\listoffigures"#, #"\\listoftables"#,
                              #"\\printindex"#, #"\\makeindex"#, #"\\printglossary"#,
                              #"\\printbibliography"#, #"\\bibliography\{[^}]*\}"#,
                              #"\\addbibresource\{[^}]*\}"#]
        for pattern in globalPatterns {
            if let re = try? NSRegularExpression(pattern: pattern) {
                for m in re.matches(in: sub, range: full) {
                    facts.globalMarkers.append(NSRange(location: range.location + m.range.location,
                                                       length: m.range.length))
                }
            }
        }
    }

    // MARK: - Helpers

    public static func djb2(_ s: String) -> UInt64 {
        var h = UInt64(5381)
        for b in s.utf8 { h = h &* 33 &+ UInt64(b) }
        return h
    }

    private func lineNumber(at charIndex: Int, in ns: NSString) -> Int {
        guard ns.length > 0 else { return 1 }
        var count = 1
        var i = 0
        while i < charIndex && i < ns.length {
            if ns.character(at: i) == 10 { count += 1 }
            i += 1
        }
        return count
    }
}