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
        // Remember which page the reader was on. A PDF page's exact point does
        // NOT survive a reflow — the old page-space coordinate lands somewhere
        // visually unrelated once figures/lines shift — so only the page index
        // is carried over, and the new document is shown from its natural top.
        keepPage = currentPageIndex()
        pdfView.document = doc
        rescaleToFit()
        // `go(to:)` right after swapping the document doesn't stick (PDFKit
        // hasn't laid the pages out yet, and rescaling resets the scroll), so
        // navigate on the next run-loop turn.
        guard keepPage < doc.pageCount, let page = doc.page(at: keepPage) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.pdfView.go(to: page)
        }
    }

    func clear() {
        pdfView.document = nil
        patchAnnotations.removeAll()
    }

    // MARK: - Proximity patching

    var document: PDFDocument? { pdfView.document }

    /// Overlay the freshly rendered vector fragment onto `bounds` on `page`
    /// (0-based). A paper-white square first hides the stale equation; the
    /// fragment's CGPDFPage is then streamed into the context at its natural
    /// size — a fully vector patch, crisp at any zoom.
    func applyPatch(page: Int, bounds: CGRect, pdf: PDFDocument) {
        removePatches()
        guard let doc = pdfView.document,
              page >= 0, page < doc.pageCount,
              let pdfPage = doc.page(at: page),
              bounds.width > 0, bounds.height > 0 else { return }

        let annotation = VectorPatchAnnotation(bounds: bounds, fragment: pdf)
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

    // MARK: - Viewport restore (content-anchored)

    /// Scroll so that `rect` (page space, points) on `page` (0-based) is at the
    /// top of the visible area. Used after a regional compile to keep the
    /// edited region under the reader's eyes even though the page reflowed.
    func reveal(page: Int, rect: CGRect) {
        guard let doc = pdfView.document,
              page >= 0, page < doc.pageCount,
              let pdfPage = doc.page(at: page) else { return }
        let target = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
        DispatchQueue.main.async { [weak self] in
            self?.pdfView.go(to: target, on: pdfPage)
        }
    }

    // MARK: - Zoom

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

/// Draws a paper-white square plus the freshly rendered vector equation over
/// the stale region of a preview page. PDFKit invokes `draw(with:in:)` for
/// custom annotation subclasses; the fragment's PDF page is streamed in via
/// `CGContext.drawPDFPage` so the glyphs stay vector at every zoom.
private final class VectorPatchAnnotation: PDFAnnotation {
    let fragment: PDFDocument

    init(bounds: CGRect, fragment: PDFDocument) {
        self.fragment = fragment
        super.init(bounds: bounds, forType: .square, withProperties: nil)
        shouldDisplay = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        context.saveGState()
        context.setFillColor(NSColor.white.cgColor)
        context.fill(bounds)

        guard let page = fragment.page(at: 0),
              let pageRef = page.pageRef else {
            context.restoreGState()
            return
        }
        let media = page.bounds(for: .mediaBox)
        guard media.width > 0, media.height > 0 else {
            context.restoreGState()
            return
        }

        // Draw the fragment at its natural size (1:1 points), centered within
        // the old region so a slightly narrower/wider equation still lines up
        // with TeX's horizontal centering. The annotation context is already in
        // page space (origin bottom-left), so map the fragment's media box to
        // the target rect.
        let target = CGRect(x: bounds.minX + max(0, (bounds.width - media.width) / 2),
                            y: bounds.minY + max(0, (bounds.height - media.height) / 2),
                            width: media.width, height: media.height)
        context.translateBy(x: target.minX, y: target.minY)
        context.translateBy(x: -media.minX, y: -media.minY)
        context.drawPDFPage(pageRef)
        context.restoreGState()
    }
}