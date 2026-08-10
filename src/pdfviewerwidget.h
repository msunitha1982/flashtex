// pdfviewerwidget.h — fast Poppler page viewer.
//
// A single-page PDF viewer built directly on QWidget + QPainter (no QML, no
// web engine). Poppler rasterizes the current page once per (page × zoom)
// into a QImage — a tiny but effective one-entry cache — and QPainter
// composits it onto the screen; Qt's platform abstraction on macOS routes
// these through CoreGraphics-backed accelerated painting, keeping redraws
// cheap while the editor thread is never blocked.
//
// Zero-latency design decisions:
//   * The viewer *owns* the loaded Poppler::Document via std::unique_ptr, so
//     the worker may delete its temp PDF on the next compile without ever
//     invalidating what this widget is displaying.
//   * Render-on-demand with a one-entry cache keyed by (page, zoom, dpr),
//     avoiding repeated, expensive Poppler rasterization on every resize.
//   * Fit-to-width default keeps the document readable with a single glance
//     and changes only on explicit zoom interaction.

#ifndef PDFVIEWERWIDGET_H
#define PDFVIEWERWIDGET_H

#include <QWidget>
#include <QImage>
#include <memory>

namespace Poppler {
class Document;
class Page;
}

class PdfViewerWidget : public QWidget
{
    Q_OBJECT

public:
    explicit PdfViewerWidget(QWidget *parent = nullptr);
    ~PdfViewerWidget() override;

    /** Replace the loaded document from a PDF file on disk. */
    bool loadPdf(const QString &filePath, QString *errorMessage = nullptr);
    /** Drop the document and show the empty-state hint. */
    void clear();

    int pageCount() const { return m_pageCount; }
    int currentPage() const { return m_page; }
    void nextPage();
    void previousPage();
    void jumpToPage(int pageIndex);

    double zoomFactor() const { return m_zoom; }            // multiplier vs fit-to-width
    void setZoomFactor(double factor);                      // clamped [0.25, 8.0]
    void zoomIn()  { setZoomFactor(m_zoom * 1.15); }
    void zoomOut() { setZoomFactor(m_zoom / 1.15); }
    void resetZoom();

    QSize minimumSizeHint() const override;                 // keep the pane usable
    QSize sizeHint() const override;

protected:
    void paintEvent(QPaintEvent *event) override;
    void resizeEvent(QResizeEvent *event) override;
    void wheelEvent(QWheelEvent *event) override;
    void mousePressEvent(QMouseEvent *event) override;
    void mouseMoveEvent(QMouseEvent *event) override;
    void mouseReleaseEvent(QMouseEvent *event) override;
    void keyPressEvent(QKeyEvent *event) override;

private:
    void refreshMetrics();                                // fit scale + clamp scroll
    void ensureRendered();                                // render current page if stale
    QRectF pageRect() const;                             // logical rect of the page
    void scrollBy(int logicalDy);                        // vertical pan within a zoomed page
    double overflow() const;                             // how much the page exceeds viewport

    std::unique_ptr<Poppler::Document> m_document;
    int                     m_page      = -1;
    int                     m_pageCount = 0;

    double m_fitScale   = 1.0;   // px-per-pt for "fit page width to viewport"
    double m_zoom       = 1.0;   // user zoom multiplier on top of fit
    double m_scale      = 1.0;   // effective logical px-per-pt
    double m_vertScroll = 0.0;   // vertical scroll inside a zoomed page (logical px)

    QImage  m_cache;            // rasterized current page
    int     m_cachePage = -1;
    double  m_cacheZoom = 0.0;  // corresponds to m_scale at render time
    double  m_cacheDpr  = 1.0;

    bool    m_dragging      = false;
    QPoint  m_dragLast;
    double  m_dragScrollBase = 0.0;

    static constexpr double kMinZoom = 0.25;
    static constexpr double kMaxZoom = 8.0;
    static constexpr int    kMargin  = 16;   // left/right/top gutter (logical px)
    static constexpr int    kHudH    = 36;   // bottom strip for the page counter
};

#endif // PDFVIEWERWIDGET_H