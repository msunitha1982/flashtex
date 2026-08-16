import AppKit
import PDFKit

// PreviewView — native live preview pane.
//
// Uses PDFKit's PDFView (Preview.app's engine) in continuous mode with a
// manual fit-to-width scale that is recomputed on every layout pass. This
// makes the page grow/shrink smoothly as the splitter or window is dragged,
// instead of PDFView's autoScales lagging behind and leaving the page stuck
// near the center at a stale size.

final class PreviewView: NSView {

    let pdfView = PDFView()
    private var pageObserver: NSObjectProtocol?
    private var settingsObserver: NSObjectProtocol?
    private var keepPage = 0
    private var keepPointInPage = CGPoint.zero

    /// Annotations the proximity renderer has stamped over stale regions of the
    /// current document. Cleared when the document is replaced.
    private var patchAnnotations: [PDFAnnotation] = []

    /// Horizontal inset between the page and the pane edge.
    private let pageInset: CGFloat = 20

    /// Multiplier applied on top of fit-to-width. 1.0 = page exactly fills the
    /// pane width; the default is slightly enlarged for readability.
    private(set) var zoomFactor: CGFloat = 1.15

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        pdfView.translatesAutoresizingMaskIntoConstraints = false
        pdfView.displayMode = .singlePageContinuous
        pdfView.autoScales = false
        pdfView.displaysPageBreaks = true
        pdfView.pageShadowsEnabled = true
        pdfView.backgroundColor = Theme.previewBackground
        pdfView.interpolationQuality = .high
        addSubview(pdfView)

        NSLayoutConstraint.activate([
            pdfView.leadingAnchor.constraint(equalTo: leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: trailingAnchor),
            pdfView.topAnchor.constraint(equalTo: topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        pageObserver = NotificationCenter.default.addObserver(
            forName: .PDFViewPageChanged, object: pdfView, queue: .main) { [weak self] _ in
            self?.rescaleToFit()
        }

        // Re-apply the paper/surround background whenever the theme flips
        // (light/dark) — the background is set once here and would otherwise
        // stay stale (e.g. dark paper in light mode).
        settingsObserver = NotificationCenter.default.addObserver(
            forName: SettingsStore.changedNotification,
            object: nil, queue: .main) { [weak self] _ in
            self?.pdfView.backgroundColor = Theme.previewBackground
        }
    }

    deinit {
        if let pageObserver { NotificationCenter.default.removeObserver(pageObserver) }
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        rescaleToFit()
    }

    func load(pdfURL: URL) {
        guard let doc = PDFDocument(url: pdfURL) else { return }
        // A fresh full compile supersedes any proximity patches: the old
        // document (and its annotations) is replaced wholesale.
        patchAnnotations.removeAll()
        // Remember where the reader was: page index + the exact point on that
        // page (in page space), so a compile that reflows the document lands
        // them back on the same page/spot instead of page one.
        keepPage = currentPageIndex()
        keepPointInPage = pdfView.currentDestination?.point ?? .zero
        pdfView.document = doc
        rescaleToFit()
        // `go(to:)` right after swapping the document doesn't stick (PDFKit
        // hasn't laid the pages out yet, and rescaling resets the scroll), so
        // navigate on the next run-loop turn.
        guard keepPage < doc.pageCount, let page = doc.page(at: keepPage) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pdfView.go(to: PDFDestination(page: page, at: self.keepPointInPage))
        }
    }

    func clear() {
        pdfView.document = nil
        patchAnnotations.removeAll()
    }

    // MARK: - Proximity patching

    var document: PDFDocument? { pdfView.document }

    /// Overlay the freshly rendered image onto `bounds` on `page` (0-based).
    /// A paper-white square first hides the stale equation; the image — aspect
    /// fitted into the old region — is drawn on top, so it floats at roughly
    /// the same place and size as before.
    func applyPatch(page: Int, bounds: CGRect, image: NSImage) {
        removePatches()
        guard let doc = pdfView.document,
              page >= 0, page < doc.pageCount,
              let pdfPage = doc.page(at: page),
              bounds.width > 0, bounds.height > 0 else { return }

        let annotation = PatchAnnotation(bounds: bounds, image: image)
        pdfPage.addAnnotation(annotation)
        patchAnnotations.append(annotation)
    }

    /// Remove every proximity patch from the current document.
    func removePatches() {
        guard let doc = pdfView.document else {
            patchAnnotations.removeAll()
            return
        }
        for annotation in patchAnnotations {
            for page in 0..<doc.pageCount {
                doc.page(at: page)?.removeAnnotation(annotation)
            }
        }
        patchAnnotations.removeAll()
    }

    /// Fit the current page's width to the pane, clamped to sane bounds.
    private func rescaleToFit() {
        guard let page = pdfView.currentPage else { return }
        let pageWidth = page.bounds(for: .mediaBox).width
        guard pageWidth > 0, bounds.width > 0 else { return }
        let target = (bounds.width - pageInset * 2) / pageWidth * zoomFactor
        let scale = min(6.0, max(0.05, target))
        if abs(pdfView.scaleFactor - scale) > 0.0001 {
            pdfView.scaleFactor = scale
        }
    }

    func zoomIn() { setZoom(zoomFactor + 0.1) }
    func zoomOut() { setZoom(zoomFactor - 0.1) }
    func fitWidth() { setZoom(1.0) }
    func resetZoom() { setZoom(1.15) }

    private func setZoom(_ zoom: CGFloat) {
        zoomFactor = min(3.0, max(0.4, zoom))
        rescaleToFit()
    }

    private func currentPageIndex() -> Int {
        guard let doc = pdfView.document, let page = pdfView.currentPage else { return 0 }
        return doc.index(for: page)
    }
}

/// Draws a paper-white square plus the freshly rendered equation image over the
/// stale region of a preview page. PDFKit invokes `draw(with:in:)` for custom
/// annotation subclasses; the mask and image are combined here so they move as
/// one annotation.
private final class PatchAnnotation: PDFAnnotation {
    let image: NSImage

    init(bounds: CGRect, image: NSImage) {
        self.image = image
        super.init(bounds: bounds, forType: .square, withProperties: nil)
        shouldDisplay = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        context.saveGState()
        context.setFillColor(NSColor.white.cgColor)
        context.fill(bounds)

        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            context.restoreGState()
            return
        }
        // The annotation context is in page space (origin bottom-left, y up);
        // flip vertically so the raster, whose rows run top-to-bottom, isn't
        // drawn upside down.
        context.translateBy(x: bounds.minX, y: bounds.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(cg, in: CGRect(x: 0, y: 0,
                                    width: bounds.width, height: bounds.height))
        context.restoreGState()
    }
}
