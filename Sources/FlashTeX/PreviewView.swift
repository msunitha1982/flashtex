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
    private var keepPage = 0
    private var keepPointInPage = CGPoint.zero

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
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        rescaleToFit()
    }

    func load(pdfURL: URL) {
        guard let doc = PDFDocument(url: pdfURL) else { return }
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
