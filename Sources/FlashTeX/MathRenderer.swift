import AppKit
import PDFKit

// MathRenderer — fast off-thread LaTeX math rendering for inline folding.
//
// Renders a raw math snippet (the body of `$…$` or `$$…$$`) to a tightly
// cropped, transparent NSImage using TeX itself:
//
//     article + preview[tightpage]  →  pdflatex  →  PDFKit rasterize
//
// (Note: the `standalone` class in TeX Live 2026 regressed on display math
// — `$$…$$` with sub/superscripts or commands fails with "Missing $ inserted"
// — so we use the `preview` package directly, which crops just as tightly.)
//
// Every heavy step (pdflatex + rasterization) happens off the main thread and
// results are cached in an NSCache keyed by the snippet, so identical or
// unchanged equations render instantly. Rendering uses the theme text colour
// so the image blends into the editor surface in both Light and Dark mode.

final class MathRenderer {

    static let shared = MathRenderer()

    /// TeX renders at this logical point size; the editor scales the result to
    /// match its own font (`font.pointSize / renderPointSize`).
    static let renderPointSize: CGFloat = 10

    /// Pixel density of the rasterization. Renders at 6x so that scaling the
    /// image up to a 13pt editor font keeps ≥2x density even on 1x (non-Retina)
    /// displays, and stays sharp when the editor zooms.
    static let rasterScale: CGFloat = 6

    private let cache = NSCache<NSString, NSImage>()
    private let cgCache = NSCache<NSString, CGImage>()
    private let pdfCache = NSCache<NSString, PDFDocument>()

    /// Concurrent rendering queue: each equation launches its own pdflatex, so
    /// several can run at once. A semaphore caps the burst so a document full
    /// of equations doesn't saturate the CPU (startup, not rasterization, is
    /// the dominant cost — overlapping N process launches is the win).
    private let work = DispatchQueue(label: "flashtex.math", qos: .userInitiated,
                                     attributes: .concurrent)
    private let renderSlots = DispatchSemaphore(value: 3)

    init() {
        cache.countLimit = 256
        cgCache.countLimit = 256
        pdfCache.countLimit = 128
    }

    /// Stable cache key for a math snippet, its display mode and the target
    /// text colour (theme-aware).
    static func key(for math: String, display: Bool, colorHex: String) -> String {
        "\(display ? "D" : "I")|\(colorHex)|\(math)"
    }

    /// Hex RGB string matching `Theme.editorText` for the active palette.
    /// The `appearance` argument is ignored — the palette is a user setting.
    static func textColorHex(for appearance: NSAppearance) -> String {
        Theme.editorTextHex
    }

    /// Hex RGB string for the app-wide effective appearance.
    static func currentTextColorHex() -> String {
        Theme.editorTextHex
    }

    func cachedImage(forKey key: String) -> NSImage? {
        cache.object(forKey: key as NSString)
    }

    /// The full-resolution backing CGImage for a cached render, so the editor
    /// can draw it with an explicit flip transform (AppKit's `NSImage.draw`
    /// ignores the flipped coordinate system of an NSTextView and would render
    /// math upside-down).
    func cachedCGImage(forKey key: String) -> CGImage? {
        cgCache.object(forKey: key as NSString)
    }

    /// The cached PDF page (if the original raster render is still warm), so
    /// the editor can draw the equation as crisp vector text at any zoom.
    func cachedPDF(forKey key: String) -> PDFDocument? {
        pdfCache.object(forKey: key as NSString)
    }

    func clearCache() {
        cache.removeAllObjects()
        cgCache.removeAllObjects()
        pdfCache.removeAllObjects()
    }

    /// Render `math` (the body between `$…$` / `$$…$$` / environments) to an
    /// image tinted `colorHex` (default: the app-wide theme text colour).
    /// Cache hits call `completion` synchronously on the calling thread;
    /// misses render off-thread and complete on the main thread.
    func renderMath(_ math: String, display: Bool,
                    colorHex: String? = nil,
                    completion: @escaping (NSImage?) -> Void) {
        let hex = colorHex ?? Self.currentTextColorHex()
        let key = Self.key(for: math, display: display, colorHex: hex)
        if let image = cachedImage(forKey: key) {
            completion(image)
            return
        }
        work.async { [weak self] in
            guard let self else { return }
            self.renderSlots.wait()
            defer { self.renderSlots.signal() }
            var image: NSImage?
            if let (rendered, cg, pdf) = self._render(math, display: display, colorHex: hex) {
                image = rendered
                self.cache.setObject(rendered, forKey: key as NSString)
                self.cgCache.setObject(cg, forKey: key as NSString)
                self.pdfCache.setObject(pdf, forKey: key as NSString)
            }
            DispatchQueue.main.async { completion(image) }
        }
    }

    // MARK: - Rendering

    private func _render(_ math: String, display: Bool, colorHex: String) -> (NSImage, CGImage, PDFDocument)? {
        guard let pdflatex = TeX.findExecutable("pdflatex") else { return nil }

        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("flashtex-math-\(UUID().uuidString)")
        do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { return nil }
        defer { try? fm.removeItem(at: dir) }

        // Trim edge whitespace: multi-line display bodies are pulled verbatim
        // from the buffer and must not smuggle blank lines into the `$$…$$`
        // wrapper (a paragraph break inside math is a hard TeX error).
        let trimmed = math.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = display ? "$$\n\(trimmed)\n$$" : "$\(trimmed)$"
        let document = """
        \\documentclass{article}
        \\usepackage{amsmath, amssymb}
        \\usepackage{xcolor}
        \\usepackage[active,tightpage]{preview}
        \\pagestyle{empty}
        \\begin{document}
        \\begin{preview}
        \\color[HTML]{\(colorHex)}
        \(body)
        \\end{preview}
        \\end{document}
        """
        let texURL = dir.appendingPathComponent("math.tex")
        do { try document.write(to: texURL, atomically: true, encoding: .utf8) }
        catch { return nil }

        let process = Process()
        process.executableURL = pdflatex
        process.currentDirectoryURL = dir
        process.environment = TeX.environment()
        process.arguments = ["-interaction=nonstopmode", "-halt-on-error", "math.tex"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit() } catch { return nil }
        guard process.terminationStatus == 0 else { return nil }

        let pdfURL = dir.appendingPathComponent("math.pdf")
        // Load from data (not URL) so the PDFDocument stays valid after the
        // temp directory is removed in the `defer` below.
        guard let pdfData = try? Data(contentsOf: pdfURL),
              let pdf = PDFDocument(data: pdfData),
              pdf.pageCount > 0,
              let page = pdf.page(at: 0) else { return nil }

        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        // 6x bitmap for sharpness after the editor scales the image up to its
        // own font size. The context starts transparent.
        let scale = Self.rasterScale
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

        guard var cg = ctx.makeImage() else { return nil }
        cg = droppingWhiteBackground(from: cg) ?? cg
        let image = NSImage(cgImage: cg,
                            size: NSSize(width: bounds.width, height: bounds.height))
        return (image, cg, pdf)
    }

    /// If the PDF drew an opaque white page background (some TeX setups do),
    /// drop the near-white pixels so the math floats transparently over the
    /// editor surface. Only kicks in when the page corners are white, so the
    /// (dark, in dark mode) glyphs are never affected.
    private func droppingWhiteBackground(from cg: CGImage) -> CGImage? {
        guard let provider = cg.dataProvider, let data = provider.data else { return cg }
        let bytes = CFDataGetBytePtr(data)
        guard let bytes else { return cg }

        let width = cg.width
        let height = cg.height
        let bpr = cg.bytesPerRow
        guard cg.bitsPerPixel == 32 else { return cg }

        func isWhite(_ x: Int, _ y: Int) -> Bool {
            let off = y * bpr + x * 4
            return bytes[off + 3] > 200
                && bytes[off] > 230
                && bytes[off + 1] > 230
                && bytes[off + 2] > 230
        }

        guard isWhite(0, 0) || isWhite(width - 1, 0)
                || isWhite(0, height - 1) || isWhite(width - 1, height - 1) else {
            return cg
        }

        guard let mutable = CFDataCreateMutableCopy(nil, 0, data),
              let ptr = CFDataGetMutableBytePtr(mutable) else { return cg }

        for y in 0..<height {
            for x in 0..<width {
                let off = y * bpr + x * 4
                if ptr[off + 3] > 180
                    && ptr[off] > 235
                    && ptr[off + 1] > 235
                    && ptr[off + 2] > 235 {
                    ptr[off] = 0
                    ptr[off + 1] = 0
                    ptr[off + 2] = 0
                    ptr[off + 3] = 0
                }
            }
        }

        guard let newProvider = CGDataProvider(data: mutable) else { return cg }
        return CGImage(width: width, height: height,
                       bitsPerComponent: cg.bitsPerComponent,
                       bitsPerPixel: cg.bitsPerPixel,
                       bytesPerRow: bpr,
                       space: cg.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: cg.bitmapInfo,
                       provider: newProvider,
                       decode: nil,
                       shouldInterpolate: true,
                       intent: .defaultIntent)
    }
}
