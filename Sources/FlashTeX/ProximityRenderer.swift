import AppKit
import PDFKit
#if canImport(FlashTeXCore)
import FlashTeXCore
#endif

// ProximityRenderer — "proximity" preview rendering (redesign v2).
//
// A full document recompile is overkill when the user tweaks a single math
// block (e.g. `E = mc^2` → `E = mc^3` inside \begin{equation}…\end{equation}).
// The pure decision logic lives in FlashTeXCore.InvalidationEngine; this class
// is the host: it owns the isolated TeX compile, the bounded result cache, the
// block → PDF-region map (from syncTeX), stale-render protection, and metrics.
//
//   * LOCAL  — the engine says the edit is inside one safe display-math block.
//              The block is recompiled alone (real documentclass + preamble,
//              equation number injected) and the resulting TeX PDF fragment is
//              applied as a *vector* patch: a custom annotation streams the
//              fragment's CGPDFPage into the preview context via
//              CGContext.drawPDFPage — crisp at every zoom, no rasterization.
//   * REGIONAL / GLOBAL — a full compile. The host can restore the viewport
//              around the edit after a regional compile (content-anchored via
//              `anchorTarget(afterLine:source:)`).
//
// Safety:
//   * docVersion — bumped on every full compile; a local render is only applied
//     if the version it started under is still current.
//   * epoch — bumped whenever pending local work is invalidated (full compile
//     starting, document replaced); only the latest job may apply.
//   * block identity — re-scanned at completion; if the block's text changed
//     while rendering, the patch is discarded.
//   * geometry rule — patch only if the natural (1:1 point-space) size matches
//     the mapped region (height ±1 pt, width ≤ old+2 pt); otherwise the page
//     may have reflowed and a full compile is needed.
//
// There is no persistent TeX daemon (pdflatex & friends are batch compilers), so
// "fast" comes from the LRU fragment cache + a stable per-preamble workspace,
// never a warm process.

final class ProximityRenderer {

    /// A block's rendered region in the preview PDF (page 0-based, points).
    struct MappedRegion {
        let page: Int
        let rect: CGRect
    }

    // MARK: - Host callbacks

    /// Deliver a finished local patch (page index, region, vector fragment).
    var onApplyPatch: ((Int, CGRect, PDFDocument) -> Void)?
    /// The geometry rule failed or the isolated render failed: full compile.
    var onFallbackToFullCompile: ((String) -> Void)?

    // MARK: - State

    let engine = InvalidationEngine()
    let metrics = IncrementalMetrics()

    private var map: [Int: MappedRegion] = [:]
    private var localTimer: Timer?
    private var epoch = 0          // bumped on any invalidation / full-compile start
    private var docVersion = 0     // bumped on every successful full compile
    private var lastFullCompileSeconds: TimeInterval?
    private var lastPreamble = ""

    // MARK: - Fragment cache (bounded LRU)

    private struct CacheEntry {
        let pdf: PDFDocument
        let naturalSize: CGSize
    }
    private var cache: [String: CacheEntry] = [:]
    private var cacheOrder: [String] = []
    private let cacheLimit = 64

    // MARK: - Full-compile bookkeeping

    /// Reset everything tied to a document (document replaced).
    func reset() {
        invalidatePendingLocal()
        engine.reset()
        map = [:]
        lastPreamble = ""
        lastFullCompileSeconds = nil
    }

    /// Called by the host after a successful full compile: bumps the version,
    /// records the dependency baseline and measures the compile.
    func noteFullCompile(source: String, duration: TimeInterval) {
        let model = DocumentModelParser().parse(source)
        engine.noteFullCompile(model: model)
        docVersion += 1
        lastFullCompileSeconds = duration
        lastPreamble = model.preambleText
        metrics.recordFullCompile(time: duration)
    }

    /// Rebuild the block → PDF-region map from the document's .synctex.gz
    /// after a successful full compile.
    func remap(pdfURL: URL, document: PDFDocument?, source: String) {
        map = [:]
        guard let dir = pdfURL.deletingLastPathComponent() as URL?,
              let synctexURL = findSynctexFile(in: dir),
              let text = decompress(synctexURL),
              let parsed = SynctexParser.parse(text, sourceName: (pdfURL.lastPathComponent as NSString).deletingPathExtension) else { return }

        let blocks = BlockScanner().blocks(in: source as NSString)
        for block in blocks {
            guard let region = parsed.region(input: parsed.mainInput,
                                             lineStart: block.lineStart,
                                             lineEnd: block.lineEnd,
                                             document: document) else { continue }
            map[block.index] = region
        }
    }

    /// The nearest mapped math block at or after `line` (the source line that
    /// was at the top of the editor's viewport when the compile began). The
    /// host uses this to restore the preview viewport after a regional compile.
    func anchorTarget(afterLine line: Int, source: String) -> MappedRegion? {
        let blocks = BlockScanner().blocks(in: source as NSString)
        for block in blocks {
            guard block.lineEnd >= line else { continue }
            guard let region = map[block.index] else { continue }
            return region
        }
        return nil
    }

    // MARK: - Scheduling

    /// Cancel any pending or in-flight local render (a full compile is taking
    /// over, or the document is being replaced).
    func invalidatePendingLocal() {
        epoch += 1
        localTimer?.invalidate()
        localTimer = nil
    }

    /// Debounce a local render. The delay adapts to how long the last full
    /// compile took and how busy the machine is.
    func scheduleLocalRender(block: TeXMathBlock, source: String, engineName: String) {
        epoch += 1
        let id = epoch
        localTimer?.invalidate()
        let base = SettingsStore.shared.renderDebounceMs
        let delay = AdaptiveDebounce.localDelay(
            baseMs: base,
            lastFullCompileSeconds: lastFullCompileSeconds,
            isBusy: ProcessInfo.processInfo.thermalState == .serious)
        let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            self?.performLocalRender(id: id, block: block, source: source,
                                     engineName: engineName)
        }
        localTimer = t
        RunLoop.main.add(t, forMode: .common)
    }

    // MARK: - Local render

    private struct Snapshot {
        let block: TeXMathBlock
        let source: String
        let engineName: String
        let version: Int
        let key: String
        let equationNumber: Int
    }

    private var snapshot: Snapshot?

    private func performLocalRender(id: Int, block: TeXMathBlock, source: String,
                                    engineName: String) {
        guard id == epoch else { return }
        let equationNumber = BlockScanner().countNumberedEquations(
            before: block.range.location, in: source) + 1
        let preamble = DocumentModelParser().parse(source).preambleText
        let key = InvalidationEngine.cacheKey(block: block, preamble: preamble,
                                              equationNumber: equationNumber,
                                              engine: engineName)
        snapshot = Snapshot(block: block, source: source, engineName: engineName,
                            version: docVersion, key: key, equationNumber: equationNumber)

        let work = DispatchQueue.global(qos: .userInitiated)
        work.async { [weak self] in
            guard let self else { return }
            let start = Date()
            let entry: CacheEntry?
            if let cached = self.cache[key] {
                self.metrics.recordCacheHit()
                entry = cached
            } else {
                self.metrics.recordCacheMiss()
                entry = self.renderFragment(block: block, source: source,
                                            equationNumber: equationNumber,
                                            engineName: engineName)
            }
            let elapsed = Date().timeIntervalSince(start)
            DispatchQueue.main.async {
                guard id == self.epoch else { return }
                self.finishLocalRender(id: id, entry: entry, time: elapsed)
            }
        }
    }

    private func finishLocalRender(id: Int, entry: CacheEntry?, time: TimeInterval) {
        guard id == epoch else { return }
        guard let snapshot, snapshot.version == docVersion else {
            metrics.recordStaleDiscard()
            return
        }
        // Block identity: if the block changed while we were rendering, the
        // patch would target the wrong source. Re-scan the *current* source
        // (the snapshot source is only valid if the user kept typing elsewhere
        // and the document version didn't bump — a full compile would have done
        // so, so compare against the snapshot source).
        let blocks = BlockScanner().blocks(in: snapshot.source as NSString)
        guard blocks.indices.contains(snapshot.block.index),
              blocks[snapshot.block.index].raw == snapshot.block.raw else {
            metrics.recordStaleDiscard()
            return
        }

        metrics.recordLocalRender(time: time)

        guard let entry,
              let mapped = map[snapshot.block.index] else {
            metrics.recordFallback()
            onFallbackToFullCompile?(snapshot.source)
            return
        }

        // Geometry rule: the natural size must match the mapped region.
        guard InvalidationEngine.geometrySafe(naturalSize: entry.naturalSize,
                                              mappedRect: mapped.rect) else {
            metrics.recordFallback()
            onFallbackToFullCompile?(snapshot.source)
            return
        }

        self.cache[snapshot.key] = entry
        metrics.recordLocalApplied(naturalSize: entry.naturalSize)
        onApplyPatch?(mapped.page, mapped.rect, entry.pdf)
    }

    // MARK: - Isolated rendering

    /// Compile the block alone (documentclass + real preamble + block) with a
    /// single engine pass and return the tightly-cropped *vector* PDF page.
    /// The natural size is the page's media box (points, 1:1).
    private func renderFragment(block: TeXMathBlock, source: String,
                                equationNumber: Int,
                                engineName: String) -> CacheEntry? {
        guard let engineURL = TeX.findExecutable(binaryName(for: engineName)) else { return nil }
        let isolated = buildIsolatedSource(block: block, source: source,
                                           equationNumber: equationNumber)

        // Shared workspace per preamble: the same directory across renders so
        // the filesystem stays warm; the real cost (format load) is inherently
        // per-run and covered by the fragment cache.
        let workspace = workspaceURL(preambleHash: DocumentModelParser.djb2(lastPreamble))
        try? FileManager.default.createDirectory(at: workspace,
                                                 withIntermediateDirectories: true)
        let texURL = workspace.appendingPathComponent("local.tex")
        do { try isolated.write(to: texURL, atomically: true, encoding: .utf8) }
        catch { return nil }

        let proc = Process()
        proc.executableURL = engineURL
        proc.currentDirectoryURL = workspace
        proc.environment = TeX.environment()
        proc.arguments = ["-interaction=nonstopmode", "-halt-on-error",
                          "-file-line-error", "local.tex"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }

        let sema = DispatchSemaphore(value: 0)
        var timedOut = false
        proc.terminationHandler = { _ in sema.signal() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 45) { [weak proc] in
            guard let proc else { return }
            if proc.isRunning { timedOut = true; proc.terminate() }
        }
        sema.wait()
        guard !timedOut, proc.terminationStatus == 0 else { return nil }

        let pdfURL = workspace.appendingPathComponent("local.pdf")
        guard let pdfData = try? Data(contentsOf: pdfURL),
              let pdf = PDFDocument(data: pdfData),
              let page = pdf.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        // Keep the vector PDF page; the annotation streams it via drawPDFPage.
        let fragment = PDFDocument()
        fragment.insert(page, at: 0)
        return CacheEntry(pdf: fragment,
                          naturalSize: CGSize(width: bounds.width, height: bounds.height))
    }

    /// The engine's executable name. `engineName` is one of the toolbar's
    /// labels (pdflatex/xelatex/lualatex/tectonic).
    private func binaryName(for engineName: String) -> String {
        engineName == "tectonic" ? "tectonic" : engineName
    }

    /// A stable per-preamble temp workspace (survives between renders of the
    /// same document).
    private func workspaceURL(preambleHash: UInt64) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("flashtex-workspace-\(preambleHash)", isDirectory: true)
    }

    /// Assemble the isolated document: the source's real documentclass and
    /// preamble, tightpage preview so each block becomes one tightly-cropped
    /// page, then the block verbatim. Numbered `equation` blocks get the
    /// document's next equation number injected.
    private func buildIsolatedSource(block: TeXMathBlock, source: String,
                                     equationNumber: Int) -> String {
        let ns = source as NSString
        var docClass = "\\documentclass{article}"
        var preamble = ""
        let beginLoc = ns.range(of: "\\begin{document}").location

        if let m = documentClassMatch(in: source) {
            docClass = ns.substring(with: m.range)
            let afterClass = m.range.location + m.range.length
            if beginLoc != NSNotFound {
                preamble = ns.substring(with: NSRange(location: afterClass,
                                                      length: beginLoc - afterClass))
            } else {
                preamble = ns.substring(from: afterClass)
            }
        } else if beginLoc != NSNotFound {
            preamble = ns.substring(to: beginLoc)
        }

        var injection = ""
        if InvalidationEngine.isNumberedEquation(block) {
            injection = "\\setcounter{equation}{\(equationNumber - 1)}\n"
        }
        return """
        \(docClass)
        \(preamble)
        \\usepackage[active,tightpage]{preview}
        \\pagestyle{empty}
        \\begin{document}
        \(injection)\\begin{preview}
        \(block.raw)
        \\end{preview}
        \\end{document}
        """
    }

    private func documentClassMatch(in source: String) -> NSTextCheckingResult? {
        let pattern = #"\\documentclass(\[[^\]]*\])?\{[^}]*\}"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        return re.firstMatch(in: source, range: NSRange(location: 0, length: (source as NSString).length))
    }

    // MARK: - syncTeX helpers

    /// The .synctex.gz (or .synctex) an engine left in the build directory.
    private func findSynctexFile(in dir: URL) -> URL? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        let candidates = names.filter { $0.contains(".synctex") }
        for name in candidates.sorted() {
            let url = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// Stream a .synctex.gz through `gunzip` (the pipe is drained on a
    /// background queue so large files can't deadlock the caller).
    private func decompress(_ url: URL) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        proc.arguments = ["-c", url.path]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        let io = DispatchQueue(label: "flashtex.synctex.io")
        var data = Data()
        let group = DispatchGroup()
        group.enter()
        io.async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        proc.waitUntilExit()
        group.wait()
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - syncTeX parsing

/// Minimal parser for the syncTeX v1 text format (the uncompressed form of the
/// .synctex.gz that pdfTeX-style engines write with `-synctex=1`).
///
/// We only need one fact: for each glyph, which (input, line) produced it and
/// where it landed on the page. Tags appear as `input,line`; x coordinates are
/// scaled points (65536 sp = 1 pt) measured from the page's left edge, and y
/// increases downward from the page's top edge. There is no column information.
private struct SynctexParser {

    struct Glyph {
        let sheet: Int    // 1-based page ordinal
        let input: Int
        let line: Int
        let x: Int        // scaled points
        let y: Int
    }

    let mainInput: Int
    let glyphs: [Glyph]
    let sheetCount: Int

    /// Returns the union rectangle (PDF points, media-box space) of the glyphs
    /// that belong to the main input whose line falls in `lineStart…lineEnd`,
    /// padded to cover the ink.
    func region(input: Int, lineStart: Int, lineEnd: Int,
                document: PDFDocument?) -> ProximityRenderer.MappedRegion? {
        let gs = glyphs.filter { $0.input == input && $0.line >= lineStart && $0.line <= lineEnd }
        guard let first = gs.first else { return nil }
        guard gs.allSatisfy({ $0.sheet == first.sheet }) else { return nil }

        let scale = 1.0 / 65536.0
        let pageIndex = first.sheet - 1
        let pageHeight = document?.page(at: pageIndex)?.bounds(for: .mediaBox).height ?? 792

        let minX = CGFloat(gs.map(\.x).min()!) * scale
        let maxX = CGFloat(gs.map(\.x).max()!) * scale
        let minY = CGFloat(gs.map(\.y).min()!) * scale   // top edge
        let maxY = CGFloat(gs.map(\.y).max()!) * scale   // baseline

        // Symmetric-ish padding so the mask fully covers the equation's ink
        // (ascenders above a superscript baseline, descenders below it).
        let padLeft: CGFloat = 2
        let padRight: CGFloat = 6
        let padTop: CGFloat = 5
        let padBottom: CGFloat = 3
        let top = max(0, minY - padTop)
        let bottom = min(pageHeight, maxY + padBottom)
        let rect = CGRect(x: minX - padLeft,
                          y: pageHeight - bottom,
                          width: (maxX - minX) + padLeft + padRight,
                          height: bottom - top)
        return ProximityRenderer.MappedRegion(page: pageIndex, rect: rect)
    }

    static func parse(_ text: String, sourceName: String) -> SynctexParser? {
        var mainInput = 0
        var curSheet = 0
        var glyphs: [Glyph] = []

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(line)
            if s.hasPrefix("Postamble:") { break }
            if s.hasPrefix("Input:") {
                let rest = s.dropFirst("Input:".count)
                if let commaIdx = rest.firstIndex(of: ":") {
                    let index = Int(rest[..<commaIdx])
                    let path = String(rest[commaIdx...].dropFirst())
                    if path.hasSuffix("\(sourceName).tex") { mainInput = index ?? 0 }
                }
                continue
            }
            guard let first = s.first else { continue }
            switch first {
            case "{": curSheet += 1
            case "x":   // character start — carries the (input, line) tag
                let fields = s.dropFirst().split(separator: ":")
                guard fields.count >= 2 else { continue }
                let tag = fields[0].split(separator: ",")
                let xy = fields[1].split(separator: ",")
                guard tag.count == 2, xy.count == 2,
                      let input = Int(tag[0]),
                      let line = Int(tag[1]),
                      let x = Int(xy[0]),
                      let y = Int(xy[1]) else { continue }
                glyphs.append(Glyph(sheet: curSheet, input: input, line: line, x: x, y: y))
            default: continue
            }
        }
        guard mainInput > 0, !glyphs.isEmpty else { return nil }
        return SynctexParser(mainInput: mainInput, glyphs: glyphs, sheetCount: curSheet)
    }
}