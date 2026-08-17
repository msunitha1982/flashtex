import Foundation
import CoreGraphics

// InvalidationEngine — the pure decision logic for the incremental preview.
//
// Given a character edit, decides how to re-render:
//
//   * LOCAL   — the edit lies strictly inside one safe display-math block, the
//               document's dependency facts and preamble are unchanged since the
//               last full compile, and the block contains nothing global. Only
//               that block is compiled and patched (vector).
//   * REGIONAL — the edit disturbs a bounded region (body text, a section, a
//               float) without changing dependencies: full compile, but the
//               host may restore the viewport around the edit (content-anchored).
//   * GLOBAL  — everything else (inline math, preamble, counters, refs, macros,
//               graphics, unbalanced source, edits crossing block boundaries).
//
// Conservative by construction: any doubt promotes to a larger scope. All logic
// here is pure Foundation so the 20+ correctness tests run in FlashTeXCoreTests.

public enum EditScope: Equatable {
    case local(block: TeXMathBlock)
    case regional
    case global
}

public struct LocalizeDecision {
    public let scope: EditScope
    public let reasons: [String]

    public var isLocal: Bool {
        if case .local = scope { return true }
        return false
    }
}

public final class InvalidationEngine {

    public private(set) var lastFacts: DocFacts?
    public private(set) var lastPreambleHash: UInt64?

    public init() {}

    /// Record the facts of a freshly compiled document. Called after every
    /// successful full compile so subsequent edits can be diffed against it.
    public func noteFullCompile(model: DocumentModel) {
        lastFacts = model.facts
        lastPreambleHash = DocumentModelParser.djb2(model.preambleText)
    }

    /// Resets the baseline (a document was replaced or is being opened).
    public func reset() {
        lastFacts = nil
        lastPreambleHash = nil
    }

    /// The full decision for a character edit.
    public func classify(editRange: NSRange, source: String,
                         isBalanced: Bool) -> LocalizeDecision {
        var reasons: [String] = []
        guard editRange.location != NSNotFound, editRange.length >= 0 else {
            return LocalizeDecision(scope: .global, reasons: ["no edit range"])
        }
        guard isBalanced else {
            return LocalizeDecision(scope: .global, reasons: ["unbalanced source"])
        }

        let ns = source as NSString
        guard editRange.location < ns.length else {
            return LocalizeDecision(scope: .global, reasons: ["edit beyond end"])
        }

        // 1. Is the edit strictly inside one math block?
        let blocks = BlockScanner().blocks(in: ns)
        var hit: TeXMathBlock?
        for b in blocks {
            let inside = editRange.location > b.range.location
                && NSMaxRange(editRange) < NSMaxRange(b.range)
            guard inside else { continue }
            if hit != nil {
                return LocalizeDecision(scope: .global, reasons: ["edit spans two blocks"])
            }
            hit = b
        }

        let preambleChanged = preambleChangedSinceCompile(source: source)
        let delta = dependencyDelta(old: lastFacts, new: DocumentModelParser().parse(source).facts)

        guard let block = hit else {
            // Not inside math: REGIONAL if dependencies are untouched, else GLOBAL.
            if preambleChanged { reasons.append("preamble changed") }
            reasons.append(contentsOf: delta)
            let scope: EditScope = (preambleChanged || !delta.isEmpty) ? .global : .regional
            return LocalizeDecision(scope: scope, reasons: reasons.isEmpty ? ["body text"] : reasons)
        }

        // 2. Block kind must be safe to re-render alone.
        switch block.kind {
        case .inline:
            return LocalizeDecision(scope: .global, reasons: ["inline math: no syncTeX column"])
        case .dollarDisplay, .bracket:
            break
        case .environment(let name):
            guard BlockScanner.localEnvs.contains(name) else {
                return LocalizeDecision(scope: .global,
                                        reasons: ["unsupported env \\begin{\(name)}"])
            }
        }

        // 3. The block itself must not contain anything that leaks out.
        let globalMarkers = [
            "\\ref{", "\\eqref{", "\\pageref{", "\\autoref{", "\\cref{", "\\vref{",
            "\\cite{", "\\nocite{", "\\bibliography", "\\printbibliography",
            "\\index{", "\\makeindex", "\\glossary", "\\printglossary",
            "\\footnote{", "\\footnotemark", "\\marginpar{",
            "\\includegraphics{", "\\input{", "\\include{",
            "\\begin{tikzpicture}", "\\begin{asy}", "\\begin{verbatim}",
            "\\begin{minipage}", "\\begin{tabular}", "\\begin{lstlisting}",
            "\\begin{minted}",
            "\\newcommand", "\\renewcommand", "\\newenvironment", "\\def\\",
            "\\usepackage", "\\numberwithin", "\\setcounter", "\\addtocounter",
            "\\theequation", "\\section", "\\subsection", "\\subsubsection",
            "\\chapter", "\\paragraph", "\\tableofcontents", "\\caption",
        ]
        if globalMarkers.contains(where: { block.body.contains($0) }) {
            return LocalizeDecision(scope: .global, reasons: ["block contains a global marker"])
        }

        // 4. The document's dependencies must not have drifted since the last
        //    full compile (labels, refs, macros, counters, inputs, globals).
        if preambleChanged {
            return LocalizeDecision(scope: .global, reasons: ["preamble changed"])
        }
        if !delta.isEmpty {
            return LocalizeDecision(scope: .global, reasons: delta)
        }

        // A preamble that pulls in external files isn't self-contained: the
        // isolated compile may differ from the real document.
        let preamble = DocumentModelParser().parse(source).preambleText
        if ["\\input{", "\\include{", "\\includegraphics{"]
            .contains(where: { preamble.contains($0) }) {
            return LocalizeDecision(scope: .global, reasons: ["preamble has external input"])
        }

        // 5. Numbered equations must have a stable sequential number.
        if Self.isNumberedEquation(block) {
            let counterMarkers = ["\\numberwithin", "\\counterwithin", "\\counterwithout",
                                  "\\setcounter{equation}", "\\addtocounter{equation}",
                                  "\\renewcommand{\\theequation}", "\\newcommand{\\theequation}"]
            if counterMarkers.contains(where: { source.contains($0) }) {
                return LocalizeDecision(scope: .global, reasons: ["counter games present"])
            }
        }

        return LocalizeDecision(scope: .local(block: block), reasons: [])
    }

    /// The set of dependency categories that differ between the last full
    /// compile and the current source. Empty when unchanged (or no baseline).
    public func dependencyDelta(old: DocFacts?, new: DocFacts) -> [String] {
        guard let old else { return [] }
        var changed: [String] = []
        if old.labels.keys != new.labels.keys { changed.append("labels changed") }
        if old.refs.keys != new.refs.keys { changed.append("refs changed") }
        if old.macroDefs.keys != new.macroDefs.keys { changed.append("macros changed") }
        if old.counterTouchers != new.counterTouchers { changed.append("counters changed") }
        if old.externalInputs != new.externalInputs { changed.append("inputs changed") }
        if old.globalMarkers != new.globalMarkers { changed.append("global markers changed") }
        return changed
    }

    /// The principled geometry rule that decides whether a freshly rendered
    /// block can be patched over the old region instead of reflowing the page:
    /// the natural (1:1, point-space) size must match the mapped rect — height
    /// within 1 pt (any real height change means the page may have reflowed)
    /// and width within 2 pt (so the patch can't overflow into the margin).
    /// No arbitrary ratio bands.
    public static func geometrySafe(naturalSize: CGSize, mappedRect: CGRect) -> Bool {
        guard naturalSize.width > 0, naturalSize.height > 0,
              mappedRect.width > 0, mappedRect.height > 0 else { return false }
        return abs(naturalSize.height - mappedRect.height) <= 1.0
            && naturalSize.width <= mappedRect.width + 2.0
    }

    /// Cache key for a rendered block fragment: engine + preamble hash + the
    /// block's own source hash + the equation number it was rendered with.
    /// Any of those changing invalidates the entry.
    public static func cacheKey(block: TeXMathBlock, preamble: String,
                                equationNumber: Int, engine: String) -> String {
        let ph = DocumentModelParser.djb2(preamble)
        let bh = DocumentModelParser.djb2(block.raw)
        return "\(engine)|\(ph)|\(equationNumber)|\(bh)"
    }

    /// Whether a numbered `equation` environment needs its number injected when
    /// rendered in isolation.
    public static func isNumberedEquation(_ block: TeXMathBlock) -> Bool {
        if case .environment(let name) = block.kind { return name == "equation" }
        return false
    }

    private func preambleChangedSinceCompile(source: String) -> Bool {
        guard let lastPreambleHash else { return false }
        let model = DocumentModelParser().parse(source)
        return DocumentModelParser.djb2(model.preambleText) != lastPreambleHash
    }
}