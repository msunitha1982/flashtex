import Foundation
import XCTest
@testable import FlashTeXCore

// Correctness tests for the incremental invalidation engine: classification
// (LOCAL / REGIONAL / GLOBAL), dependency deltas, the geometry rule and the
// fragment cache key. All pure — no TeX required.

let invalidationTestDocument = """
    \\documentclass{article}
    \\usepackage{amsmath, amssymb}
    \\begin{document}
    A paragraph of body text.

    \\begin{equation}
    E = mc^2
    \\end{equation}

    More text after the math.
    \\end{document}
    """

final class InvalidationEngineTests: XCTestCase {

    private var source: String { invalidationTestDocument }

    /// An engine whose baseline matches `src` (as if it had just compiled).
    private func compiledEngine(_ src: String) -> InvalidationEngine {
        let engine = InvalidationEngine()
        engine.noteFullCompile(model: DocumentModelParser().parse(src))
        return engine
    }

    private func range(of needle: String, in src: String) -> NSRange {
        (src as NSString).range(of: needle)
    }

    private func classify(_ engine: InvalidationEngine, edit: NSRange,
                          src: String, balanced: Bool = true) -> LocalizeDecision {
        engine.classify(editRange: edit, source: src, isBalanced: balanced)
    }

    // MARK: - LOCAL

    func testEditInsideNumberedEquationIsLocal() {
        let engine = compiledEngine(invalidationTestDocument)
        let edit = range(of: "mc^2", in: source)
        let d = classify(engine, edit: edit, src: source)
        XCTAssertTrue(d.isLocal, "reason: \(d.reasons)")
    }

    func testEditInsideDollarDisplayIsLocal() {
        let src = """
        \\documentclass{article}
        \\begin{document}
        $$
        x + y
        $$
        \\end{document}
        """
        let engine = compiledEngine(src)
        let edit = range(of: "x + y", in: src)
        XCTAssertTrue(classify(engine, edit: edit, src: src).isLocal)
    }

    func testEditInsideBracketIsLocal() {
        let src = """
        \\documentclass{article}
        \\begin{document}
        \\[
        a^2 + b^2 = c^2
        \\]
        \\end{document}
        """
        let engine = compiledEngine(src)
        let edit = range(of: "a^2", in: src)
        XCTAssertTrue(classify(engine, edit: edit, src: src).isLocal)
    }

    func testEditInsideStarredAlignIsLocal() {
        let src = """
        \\documentclass{article}
        \\usepackage{amsmath}
        \\begin{document}
        \\begin{align*}
        a &= b\\\\
        c &= d
        \\end{align*}
        \\end{document}
        """
        let engine = compiledEngine(src)
        let edit = range(of: "c &= d", in: src)
        XCTAssertTrue(classify(engine, edit: edit, src: src).isLocal)
    }

    // MARK: - NOT LOCAL (promoted)

    func testEditInsideInlineMathIsGlobal() {
        let src = """
        \\documentclass{article}
        \\begin{document}
        Inline $x^2$ math.
        \\end{document}
        """
        let engine = compiledEngine(src)
        let edit = range(of: "x^2", in: src)
        let d = classify(engine, edit: edit, src: src)
        XCTAssertEqual(d.scope, .global)
        XCTAssertTrue(d.reasons.contains { $0.contains("no syncTeX column") })
    }

    func testEditInsideNumberedAlignIsGlobal() {
        let src = """
        \\documentclass{article}
        \\usepackage{amsmath}
        \\begin{document}
        \\begin{align}
        a &= b
        \\end{align}
        \\end{document}
        """
        let engine = compiledEngine(src)
        let edit = range(of: "a &= b", in: src)
        let d = classify(engine, edit: edit, src: src)
        XCTAssertEqual(d.scope, .global)
        XCTAssertTrue(d.reasons.contains { $0.contains("unsupported env") })
    }

    func testEditInBodyTextIsRegional() {
        let engine = compiledEngine(invalidationTestDocument)
        let edit = range(of: "body text", in: source)
        let d = classify(engine, edit: edit, src: source)
        XCTAssertEqual(d.scope, .regional)
    }

    func testEditAtBlockStartIsNotLocal() {
        let engine = compiledEngine(invalidationTestDocument)
        // Editing the opening `\begin{equation}` itself: not strictly inside.
        let edit = range(of: "\\begin{equation}", in: source)
        let d = classify(engine, edit: edit, src: source)
        XCTAssertFalse(d.isLocal)
    }

    func testEditSpanningTwoBlocksIsNotLocal() {
        let src = """
        \\documentclass{article}
        \\begin{document}
        $$a$$
        $$b$$
        \\end{document}
        """
        let engine = compiledEngine(src)
        let first = range(of: "$$a$$", in: src)
        let second = range(of: "$$b$$", in: src)
        // A range that begins inside the first block and ends inside the second
        // is not strictly inside any single block → must never patch locally.
        let edit = NSRange(location: first.location + 1,
                           length: NSMaxRange(second) - first.location - 2)
        let d = classify(engine, edit: edit, src: src)
        XCTAssertFalse(d.isLocal)
    }

    func testEditBeyondEndIsGlobal() {
        let engine = compiledEngine(invalidationTestDocument)
        let d = classify(engine, edit: NSRange(location: (source as NSString).length, length: 0), src: source)
        XCTAssertEqual(d.scope, .global)
    }

    func testNoEditRangeIsGlobal() {
        let engine = compiledEngine(invalidationTestDocument)
        let d = classify(engine, edit: NSRange(location: NSNotFound, length: 0), src: source)
        XCTAssertEqual(d.scope, .global)
    }

    func testUnbalancedSourceIsGlobal() {
        let engine = compiledEngine(invalidationTestDocument)
        let edit = range(of: "mc^2", in: source)
        XCTAssertEqual(classify(engine, edit: edit, src: source, balanced: false).scope, .global)
    }

    func testBlockWithRefIsGlobal() {
        let src = """
        \\documentclass{article}
        \\begin{document}
        \\begin{equation}
        E = \\eqref{eq:first} + 1
        \\end{equation}
        \\end{document}
        """
        let engine = compiledEngine(src)
        let edit = range(of: "\\eqref{eq:first}", in: src)
        XCTAssertEqual(classify(engine, edit: edit, src: src).scope, .global)
    }

    func testBlockWithMacroDefIsGlobal() {
        let src = """
        \\documentclass{article}
        \\begin{document}
        \\begin{equation}
        \\newcommand{\\foo}{x}
        E = \\foo
        \\end{equation}
        \\end{document}
        """
        let engine = compiledEngine(src)
        let edit = range(of: "\\newcommand", in: src)
        XCTAssertEqual(classify(engine, edit: edit, src: src).scope, .global)
    }

    func testNumberwithinAnywherePromotesToGlobal() {
        let src = """
        \\documentclass{article}
        \\numberwithin{equation}{section}
        \\begin{document}
        \\begin{equation}
        E = mc^2
        \\end{equation}
        \\end{document}
        """
        let engine = compiledEngine(src)
        let edit = range(of: "mc^2", in: src)
        XCTAssertEqual(classify(engine, edit: edit, src: src).scope, .global)
    }

    func testPreambleWithInputIsGlobal() {
        let src = """
        \\documentclass{article}
        \\input{macros}
        \\begin{document}
        \\begin{equation}
        E = mc^2
        \\end{equation}
        \\end{document}
        """
        let engine = compiledEngine(src)
        let edit = range(of: "mc^2", in: src)
        XCTAssertEqual(classify(engine, edit: edit, src: src).scope, .global)
    }

    // MARK: - Dependency deltas

    func testPreambleChangePromotesToGlobal() {
        let engine = compiledEngine(invalidationTestDocument)
        // Same edit, but the preamble gained a package since the last compile.
        let edited = source.replacingOccurrences(
            of: "\\usepackage{amsmath, amssymb}",
            with: "\\usepackage{amsmath, amssymb}\n\\usepackage{xcolor}")
        let edit = range(of: "mc^2", in: edited)
        let d = classify(engine, edit: edit, src: edited)
        XCTAssertEqual(d.scope, .global)
        XCTAssertTrue(d.reasons.contains { $0.contains("preamble") })
    }

    func testNewLabelPromotesToGlobal() {
        let engine = compiledEngine(invalidationTestDocument)
        let edited = source.replacingOccurrences(
            of: "More text after the math.",
            with: "More text after the math.\\label{eq:energy}")
        let edit = range(of: "mc^2", in: edited)
        let d = classify(engine, edit: edit, src: edited)
        XCTAssertEqual(d.scope, .global)
        XCTAssertTrue(d.reasons.contains { $0.contains("labels") })
    }

    func testNewRefPromotesToGlobal() {
        let engine = compiledEngine(invalidationTestDocument)
        let edited = source.replacingOccurrences(
            of: "More text after the math.",
            with: "See \\ref{eq:energy} later.")
        let edit = range(of: "mc^2", in: edited)
        let d = classify(engine, edit: edit, src: edited)
        XCTAssertEqual(d.scope, .global)
        XCTAssertTrue(d.reasons.contains { $0.contains("refs") })
    }

    func testStableBaselineStaysLocalAcrossEdits() {
        let engine = compiledEngine(invalidationTestDocument)
        let first = classify(engine, edit: range(of: "mc^2", in: source), src: source)
        XCTAssertTrue(first.isLocal)
        // Same edit again (undo/redo) still local.
        let second = classify(engine, edit: range(of: "mc^2", in: source), src: source)
        XCTAssertTrue(second.isLocal)
    }

    // MARK: - dependencyDelta

    func testDependencyDeltaUnchanged() {
        let engine = compiledEngine(invalidationTestDocument)
        let model = DocumentModelParser().parse(source)
        XCTAssertTrue(engine.dependencyDelta(old: engine.lastFacts, new: model.facts).isEmpty)
    }

    func testDependencyDeltaNoBaseline() {
        let engine = InvalidationEngine()
        let model = DocumentModelParser().parse(source)
        XCTAssertTrue(engine.dependencyDelta(old: nil, new: model.facts).isEmpty)
    }

    // MARK: - Geometry rule

    func testGeometryRule() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 40)
        // Exact match and sub-point drift → safe.
        XCTAssertTrue(InvalidationEngine.geometrySafe(naturalSize: CGSize(width: 200, height: 40),
                                                      mappedRect: rect))
        XCTAssertTrue(InvalidationEngine.geometrySafe(naturalSize: CGSize(width: 199.5, height: 40.6),
                                                      mappedRect: rect))
        XCTAssertTrue(InvalidationEngine.geometrySafe(naturalSize: CGSize(width: 202, height: 40),
                                                      mappedRect: rect))
        // Real height growth (reflow risk) → unsafe.
        XCTAssertFalse(InvalidationEngine.geometrySafe(naturalSize: CGSize(width: 200, height: 41.5),
                                                       mappedRect: rect))
        // Width overflow → unsafe.
        XCTAssertFalse(InvalidationEngine.geometrySafe(naturalSize: CGSize(width: 203, height: 40),
                                                       mappedRect: rect))
        // Degenerate sizes → unsafe.
        XCTAssertFalse(InvalidationEngine.geometrySafe(naturalSize: .zero, mappedRect: rect))
        XCTAssertFalse(InvalidationEngine.geometrySafe(naturalSize: CGSize(width: 10, height: 10),
                                                       mappedRect: .zero))
    }

    // MARK: - Cache key

    func testCacheKeyStability() {
        let src = """
        \\documentclass{article}
        \\begin{document}
        \\begin{equation}
        E = mc^2
        \\end{equation}
        \\end{document}
        """
        let block = BlockScanner().blocks(in: src as NSString)[0]
        let preamble = "\\documentclass{article}"
        let k1 = InvalidationEngine.cacheKey(block: block, preamble: preamble,
                                             equationNumber: 1, engine: "pdflatex")
        let k2 = InvalidationEngine.cacheKey(block: block, preamble: preamble,
                                             equationNumber: 1, engine: "pdflatex")
        XCTAssertEqual(k1, k2)

        let k3 = InvalidationEngine.cacheKey(block: block, preamble: preamble,
                                             equationNumber: 2, engine: "pdflatex")
        XCTAssertNotEqual(k1, k3, "equation number must be part of the key")

        let k4 = InvalidationEngine.cacheKey(block: block, preamble: "\\documentclass{book}",
                                             equationNumber: 1, engine: "pdflatex")
        XCTAssertNotEqual(k1, k4, "preamble must be part of the key")

        let k5 = InvalidationEngine.cacheKey(block: block, preamble: preamble,
                                             equationNumber: 1, engine: "xelatex")
        XCTAssertNotEqual(k1, k5, "engine must be part of the key")

        let other = BlockScanner().blocks(in: src.replacingOccurrences(of: "mc^2", with: "mc^3") as NSString)[0]
        let k6 = InvalidationEngine.cacheKey(block: other, preamble: preamble,
                                             equationNumber: 1, engine: "pdflatex")
        XCTAssertNotEqual(k1, k6, "block source must be part of the key")
    }

    // MARK: - Numbered equation

    func testIsNumberedEquation() {
        let src = """
        \\documentclass{article}
        \\begin{document}
        \\begin{equation}E=1\\end{equation}
        \\begin{equation*}E=2\\end{equation*}
        \\begin{align*}a&=b\\end{align*}
        \\end{document}
        """
        let blocks = BlockScanner().blocks(in: src as NSString)
        XCTAssertTrue(InvalidationEngine.isNumberedEquation(blocks[0]))
        XCTAssertFalse(InvalidationEngine.isNumberedEquation(blocks[1]))
        XCTAssertFalse(InvalidationEngine.isNumberedEquation(blocks[2]))
    }

    func testCountNumberedEquations() {
        let src = """
        \\begin{equation}A\\end{equation}
        \\begin{equation*}B\\end{equation*}
        \\begin{equation}C\\end{equation}
        """
        let scanner = BlockScanner()
        XCTAssertEqual(scanner.countNumberedEquations(before: 0, in: src), 0)
        let third = range(of: "\\begin{equation}C", in: src)
        XCTAssertEqual(scanner.countNumberedEquations(before: third.location, in: src), 1)
    }
}