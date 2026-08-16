import AppKit
import PDFKit

// ProximityRenderer — "proximity-based" preview rendering.
//
// A full document recompile is overkill when the user tweaks a single math
// block (e.g. `E = mc^2` → `E = mc^3` inside \begin{equation}…\end{equation}).
// ProximityRenderer detects such LOCAL edits, re-renders just the affected
// block in isolation (reusing the document's real preamble so packages and
// macros behave identically), and patches that block's region in the existing
// PDF preview instead of swapping in a freshly compiled document.
//
//   * LOCAL  — the edit lies strictly inside one display-math block of a
//              supported kind with no cross-references, counter games or
//              graphics; only that block is compiled and patched.
//   * GLOBAL — anything else (and every case the conservative classifier is
//              unsure about) falls back to the full Compiler.
//
// Source → PDF mapping comes from the .synctex.gz every engine already writes
// (`-synctex=1`): pdfTeX tags each glyph with the (input, line) that produced
// it, so a display block's rendered region is the union of the glyphs whose
// line falls inside the block's source line span. Inline math is not patched
// because syncTeX carries no column information — a local edit inside `$…$`
// is classified GLOBAL and full-compiled.
//
// The preview patch is a single custom PDF annotation over the old region: it
// paints a paper-white square (hides the stale equation) then draws the newly
// rendered raster on top. If the new equation's natural size drifts too far
// from the old region the patch is abandoned for a full compile (layout has
// probably reflowed).

final class ProximityRenderer {

    /// Kind of math block, derived from its delimiters/environment.
    enum Kind: Equatable {
        case inline              // $…$  (never patched locally: no column info)
        case dollarDisplay       // $$…$$
        case bracket             // \[…\]
        case environment(String) // \begin{…}…\end{…} — the environment name
    }

    struct Block {
        let index: Int
        let kind: Kind
        let range: NSRange       // full range including the delimiters
        let display: Bool
        let body: String         // trimmed inner source (no delimiters)
        let raw: String          // exact source substring (delimiters included)
        let lineStart: Int       // 1-based source lines spanned by the block
        let lineEnd: Int
    }

    /// A block's rendered region in the preview PDF (page 0-based, points).
    struct MappedRegion {
        let page: Int
        let rect: CGRect
    }

    // MARK: - Host callbacks

    /// Deliver a finished local patch (page index, region, image) on the main
    /// thread.
    var onApplyPatch: ((Int, CGRect, NSImage) -> Void)?
    /// The classifier decided a full compile is needed instead (or the local
    /// render failed); the host re-arms the real Compiler with the source.
    var onFallbackToFullCompile: ((String) -> Void)?

    // MARK: - Local edit classification

    /// The single math block a character edit is strictly inside, if that
    /// block is safe to re-render in isolation. Nil means "full compile".
    func localBlock(editRange: NSRange, source: String) -> Block? {
        guard editRange.location != NSNotFound else { return nil }
        let ns = source as NSString
        let blocks = ProximityBlockScanner().blocks(in: ns)
        var hit: Block?
        for b in blocks {
            let inside = editRange.location > b.range.location
                && NSMaxRange(editRange) < NSMaxRange(b.range)
            guard inside else { continue }
            if hit != nil { return nil }   // spans two blocks → global
            hit = b
        }
        guard let block = hit else { return nil }
        return isLocalSafe(block, source: source) ? block : nil
    }

    /// The conservative LOCAL gate. Anything uncertain → GLOBAL.
    private func isLocalSafe(_ block: Block, source: String) -> Bool {
        switch block.kind {
        case .inline:
            return false
        case .dollarDisplay, .bracket:
            break
        case .environment(let name):
            guard ProximityBlockScanner.localEnvs.contains(name) else { return false }
        }

        let body = block.body
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
        if globalMarkers.contains(where: { body.contains($0) }) { return false }

        // Counter games anywhere in the document break the assumption that
        // equation numbers follow the sequential \begin{equation} count, so the
        // isolated render could show the wrong number.
        let counterMarkers = ["\\numberwithin", "\\counterwithin", "\\counterwithout",
                              "\\setcounter{equation}", "\\addtocounter{equation}",
                              "\\renewcommand{\\theequation}", "\\newcommand{\\theequation}"]
        if counterMarkers.contains(where: { source.contains($0) }) { return false }

        // A preamble that pulls in external files isn't self-contained: the
        // isolated compile may differ from the real document.
        let preamble = preambleOf(source)
        if ["\\input{", "\\include{", "\\includegraphics{"]
            .contains(where: { preamble.contains($0) }) { return false }

        return true
    }

    private func preambleOf(_ source: String) -> String {
        let ns = source as NSString
        let begin = ns.range(of: "\\begin{document}").location
        guard begin != NSNotFound else { return source }
        return ns.substring(to: begin)
    }

    // MARK: - Scheduled local render

    private var localTimer: Timer?
    private var localID = 0
    private let work = DispatchQueue(label: "flashtex.proximity", qos: .userInitiated)

    /// Cancel any pending or in-flight local render (a full compile is taking
    /// over, or the document is being replaced).
    func invalidatePendingLocal() {
        localID += 1
        localTimer?.invalidate()
        localTimer = nil
    }

    /// Debounce a local render the way the Compiler debounces a full compile.
    func scheduleLocalRender(block: Block, source: String) {
        localID += 1
        let id = localID
        localTimer?.invalidate()
        let delay = max(0.01, SettingsStore.shared.renderDebounceMs / 1000.0)
        let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            self?.performLocalRender(id: id, block: block, source: source)
        }
        localTimer = t
        RunLoop.main.add(t, forMode: .common)
    }

    private func performLocalRender(id: Int, block: Block, source: String) {
        guard id == localID else { return }
        work.async { [weak self] in
            let rendered = self?.renderBlockInIsolation(block: block, source: source)
            DispatchQueue.main.async {
                guard let self, id == self.localID else { return }
                self.finishLocalRender(id: id, rendered: rendered, block: block, source: source)
            }
        }
    }

    private func finishLocalRender(id: Int, rendered: RenderedBlock?, block: Block,
                                   source: String) {
        guard id == localID else { return }
        guard let rendered,
              let mapped = map[block.index],
              rendered.naturalSize.width > 0, rendered.naturalSize.height > 0,
              mapped.rect.width > 0, mapped.rect.height > 0 else {
            onFallbackToFullCompile?(source)
            return
        }
        let widthRatio = rendered.naturalSize.width / mapped.rect.width
        let heightRatio = rendered.naturalSize.height / mapped.rect.height
        // If the equation shrank or grew a lot the page has reflowed — a
        // patch would leave stale artifacts, so do a real compile instead.
        guard (0.85...1.35).contains(widthRatio),
              (0.85...1.30).contains(heightRatio) else {
            onFallbackToFullCompile?(source)
            return
        }
        onApplyPatch?(mapped.page, mapped.rect, rendered.image)
    }

    // MARK: - Isolated rendering

    struct RenderedBlock {
        let image: NSImage
        let naturalSize: CGSize   // the image's logical size in PDF points
    }

    /// Compile the block alone (documentclass + real preamble + block) with a
    /// single pdflatex pass and return a tight transparent raster of it.
    private func renderBlockInIsolation(block: Block, source: String) -> RenderedBlock? {
        let isolated = buildIsolatedSource(block: block, source: source)
        guard let pdflatex = TeX.findExecutable("pdflatex") else { return nil }

        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("flashtex-local-\(UUID().uuidString)")
        do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { return nil }
        defer { try? fm.removeItem(at: dir) }

        let texURL = dir.appendingPathComponent("local.tex")
        do { try isolated.write(to: texURL, atomically: true, encoding: .utf8) }
        catch { return nil }

        let proc = Process()
        proc.executableURL = pdflatex
        proc.currentDirectoryURL = dir
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

        let pdfURL = dir.appendingPathComponent("local.pdf")
        guard let pdfData = try? Data(contentsOf: pdfURL),
              let pdf = PDFDocument(data: pdfData),
              let page = pdf.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        // Rasterize the whole page at 6x on a transparent canvas, then crop to
        // the equation's ink — a tight image that scales crisply in the preview.
        let scale = MathRenderer.rasterScale
        let pxW = Int((bounds.width * scale).rounded())
        let pxH = Int((bounds.height * scale).rounded())
        guard pxW > 0, pxH > 0,
              let ctx = CGContext(data: nil, width: pxW, height: pxH,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .mediaBox, to: ctx)
        guard let full = ctx.makeImage() else { return nil }

        // Locate the ink on a small probe instead of scanning the full 6x
        // raster (millions of pixels, prohibitively slow in debug builds), then
        // crop the full-res image to that box — CG cropping is instant. The
        // box is already in `full`'s pixel space.
        guard let ink = inkBoundingBox(of: full, probeScale: 1.0 / scale),
              let trimmed = full.cropping(to: ink) else { return nil }

        let naturalSize = CGSize(width: CGFloat(trimmed.width) / scale,
                                 height: CGFloat(trimmed.height) / scale)
        // Flatten onto white (the preview paper) so the annotation needs no
        // alpha handling.
        let flat = compositingOnWhite(trimmed, size: naturalSize)
        return RenderedBlock(image: flat, naturalSize: naturalSize)
    }

    /// The bounding box (in `cg`'s pixel space) of the opaque pixels, found by
    /// downsampling the image to a fraction of its size and scanning that. The
    /// probe draw is done by CoreGraphics (fast); only the small probe is
    /// walked in Swift. `probeScale` is the downsample factor (e.g. 1/6 of the
    /// full raster).
    private func inkBoundingBox(of cg: CGImage, probeScale: CGFloat) -> CGRect? {
        let probeW = max(1, Int(CGFloat(cg.width) * probeScale))
        let probeH = max(1, Int(CGFloat(cg.height) * probeScale))
        guard let probeCtx = CGContext(data: nil, width: probeW, height: probeH,
                                       bitsPerComponent: 8, bytesPerRow: 0,
                                       space: CGColorSpaceCreateDeviceRGB(),
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        probeCtx.draw(cg, in: CGRect(x: 0, y: 0, width: probeW, height: probeH))
        guard let probe = probeCtx.makeImage(),
              let provider = probe.dataProvider,
              let data = provider.data,
              let bytes = CFDataGetBytePtr(data),
              probe.bitsPerPixel == 32 else { return nil }

        let w = probe.width, h = probe.height, bpr = probe.bytesPerRow
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            var row = bytes + y * bpr
            for x in 0..<w {
                if row[3] > 16 {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
                row += 4
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let scaleUp = CGFloat(cg.width) / CGFloat(w)
        return CGRect(x: CGFloat(minX) * scaleUp, y: CGFloat(minY) * scaleUp,
                      width: CGFloat(maxX - minX + 1) * scaleUp,
                      height: CGFloat(maxY - minY + 1) * scaleUp)
    }

    /// Assemble the isolated document: the source's real documentclass and
    /// preamble, empty page style, then the block verbatim. Numbered
    /// `equation` blocks get the document's next equation number injected.
    private func buildIsolatedSource(block: Block, source: String) -> String {
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
        if isNumberedEquation(block) {
            let number = equationCount(before: block.range.location, in: source) + 1
            injection = "\\setcounter{equation}{\(number - 1)}\n"
        }
        return """
        \(docClass)
        \(preamble)
        \\pagestyle{empty}
        \\begin{document}
        \(injection)\(block.raw)
        \\end{document}
        """
    }

    private func isNumberedEquation(_ block: Block) -> Bool {
        if case .environment(let name) = block.kind { return name == "equation" }
        return false
    }

    /// Number of `\begin{equation}` blocks that start before `location`
    /// (starred variants don't increment the counter and are excluded).
    private func equationCount(before location: Int, in source: String) -> Int {
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

    private func documentClassMatch(in source: String) -> NSTextCheckingResult? {
        let pattern = #"\\documentclass(\[[^\]]*\])?\{[^}]*\}"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        return re.firstMatch(in: source, range: NSRange(location: 0, length: (source as NSString).length))
    }

    /// Draw the raster onto a white canvas the same logical size, so the patch
    /// image is opaque and needs no alpha handling from PDFKit.
    private func compositingOnWhite(_ cg: CGImage, size: CGSize) -> NSImage {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: cg.width, pixelsHigh: cg.height,
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
            return NSImage(cgImage: cg, size: size)
        }
        let g = ctx.cgContext
        g.setFillColor(NSColor.white.cgColor)
        g.fill(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        g.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard let flat = rep.cgImage else { return NSImage(cgImage: cg, size: size) }
        return NSImage(cgImage: flat, size: size)
    }

    // MARK: - Source → PDF mapping (syncTeX)

    private(set) var map: [Int: MappedRegion] = [:]

    /// Reset the mapping and any pending local work (document replaced).
    func reset() {
        invalidatePendingLocal()
        map = [:]
    }

    /// Rebuild the block → PDF-region map from the document's .synctex.gz
    /// after a successful full compile.
    func remap(pdfURL: URL, document: PDFDocument?, source: String) {
        map = [:]
        guard let dir = pdfURL.deletingLastPathComponent() as URL?,
              let synctexURL = findSynctexFile(in: dir),
              let text = decompress(synctexURL),
              let parsed = SynctexParser.parse(text, sourceName: (pdfURL.lastPathComponent as NSString).deletingPathExtension) else { return }

        let ns = source as NSString
        let blocks = ProximityBlockScanner().blocks(in: ns)
        for block in blocks {
            guard let region = parsed.region(input: parsed.mainInput,
                                             lineStart: block.lineStart,
                                             lineEnd: block.lineEnd,
                                             document: document) else { continue }
            map[block.index] = region
        }
    }

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

// MARK: - Block scanning

/// Pure scanner for `$…$`, `$$…$$`, `\[…\]` and the display-math environments
/// (a sibling of MathFoldParser that also records the block kind and raw text,
/// which the proximity renderer needs).
final class ProximityBlockScanner {

    /// Environments that are safe to re-render alone. Non-starred multi-row
    /// environments number their rows, so only starred ones qualify.
    static let localEnvs: Set<String> = [
        "equation", "equation*", "displaymath",
        "align*", "gather*", "multline*", "flalign*", "alignat*",
    ]

    private let displayEnvs: Set<String> = [
        "equation", "equation*", "displaymath",
        "align", "align*", "gather", "gather*",
        "multline", "multline*", "flalign", "flalign*",
        "alignat", "alignat*",
    ]

    func blocks(in text: NSString) -> [ProximityRenderer.Block] {
        var result: [ProximityRenderer.Block] = []
        let lineStarts = self.lineStarts(of: text)
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

    // MARK: - Scanners

    private func scanDollar(_ text: NSString, from i: Int, index: Int,
                            lineStarts: [Int]) -> ProximityRenderer.Block? {
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
                                 lineStarts: [Int]) -> ProximityRenderer.Block? {
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
                             lineStarts: [Int]) -> ProximityRenderer.Block? {
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
                           kind: ProximityRenderer.Kind,
                           lineStarts: [Int]) -> ProximityRenderer.Block {
        let bodyStart = start + open
        let body = text.substring(with: NSRange(location: bodyStart,
                                                length: firstClosing - bodyStart))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(location: start, length: firstClosing - start + open)
        return makeBlock(text, range: range, display: display, index: index,
                         kind: kind, body: body, lineStarts: lineStarts)
    }

    private func makeBlock(_ text: NSString, range: NSRange, display: Bool, index: Int,
                           kind: ProximityRenderer.Kind, body: String,
                           lineStarts: [Int]) -> ProximityRenderer.Block {
        ProximityRenderer.Block(index: index, kind: kind, range: range,
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

    private func lineStarts(of text: NSString) -> [Int] {
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

// MARK: - syncTeX parsing

/// Minimal parser for the syncTeX v1 text format (the uncompressed form of the
/// .synctex.gz that pdfTeX-style engines write with `-synctex=1`).
///
/// We only need one fact: for each glyph, which (input, line) produced it and
/// where it landed on the page. Tags appear as `input,line`; x coordinates are
/// scaled points (65536 sp = 1 pt) measured from the page's left edge, and y
/// increases downward from the page's top edge.
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