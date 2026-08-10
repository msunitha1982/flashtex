#include "pdfviewerwidget.h"

#include <poppler-qt6.h>

#include <QPainter>
#include <QPaintEvent>
#include <QWheelEvent>
#include <QMouseEvent>
#include <QKeyEvent>
#include <QResizeEvent>
#include <QtMath>
#include <algorithm>
#include <cmath>

/* ---------------------------------------------------------------------------
 * Construction
 * ------------------------------------------------------------------------- */

PdfViewerWidget::PdfViewerWidget(QWidget *parent)
    : QWidget(parent)
{
    setAttribute(Qt::WA_OpaquePaintEvent, true);  // we fill the entire rect ourselves
    setFocusPolicy(Qt::StrongFocus);              // receive PageUp/PageDown/Space keys
    setMouseTracking(true);
    setContextMenuPolicy(Qt::NoContextMenu);
}

PdfViewerWidget::~PdfViewerWidget() = default;

/* ---------------------------------------------------------------------------
 * Public document control
 * ------------------------------------------------------------------------- */

bool PdfViewerWidget::loadPdf(const QString &filePath, QString *errorMessage)
{
    std::unique_ptr<Poppler::Document> doc(Poppler::Document::load(filePath));

    if (!doc || doc->isLocked()) {
        if (errorMessage)
            *errorMessage = QStringLiteral("PDF could not be opened: %1").arg(filePath);
        clear();
        return false;
    }
    if (doc->numPages() <= 0) {
        if (errorMessage)
            *errorMessage = QStringLiteral("PDF contains no pages: %1").arg(filePath);
        clear();
        return false;
    }

    m_document  = std::move(doc);
    m_pageCount = m_document->numPages();
    m_page      = 0;
    m_zoom      = 1.0;
    m_vertScroll = 0.0;
    m_cache      = QImage();

    refreshMetrics();       // compute fit-to-width for the current pane size
    update();
    return true;
}

void PdfViewerWidget::clear()
{
    m_document.reset();
    m_pageCount = 0;
    m_page      = -1;
    m_cache      = QImage();
    update();
}

void PdfViewerWidget::nextPage()
{
    if (m_page >= 0 && m_page < m_pageCount - 1)
        jumpToPage(m_page + 1);
}

void PdfViewerWidget::previousPage()
{
    if (m_page > 0)
        jumpToPage(m_page - 1);
}

void PdfViewerWidget::jumpToPage(int pageIndex)
{
    if (!m_document || pageIndex < 0 || pageIndex >= m_pageCount)
        return;

    m_page        = pageIndex;
    m_cache       = QImage();
    m_vertScroll  = 0.0;          // snap to the top of the new page
    refreshMetrics();
    update();
}

void PdfViewerWidget::setZoomFactor(double factor)
{
    factor = std::fmax(kMinZoom, std::fmin(kMaxZoom, factor));
    if (qFuzzyCompare(factor, m_zoom))
        return;

    m_zoom  = factor;
    m_cache = QImage();           // render resolution must change with zoom
    refreshMetrics();
    update();
}

void PdfViewerWidget::resetZoom()
{
    m_zoom = 1.0;
    m_cache = QImage();
    refreshMetrics();
    update();
}

/* ---------------------------------------------------------------------------
 * Internal geometry helpers
 * ------------------------------------------------------------------------- */

QSize PdfViewerWidget::sizeHint() const            { return { 640, 720 }; }
QSize PdfViewerWidget::minimumSizeHint() const     { return { 220, 200 }; }

void PdfViewerWidget::refreshMetrics()
{
    if (!m_document || m_page < 0) {
        m_fitScale = 1.0;
        m_scale    = 1.0;
        return;
    }

    const std::unique_ptr<Poppler::Page> page(m_document->page(m_page));
    if (!page) {
        m_fitScale = 1.0;
        m_scale    = 1.0;
        return;
    }

    const double pageW    = page->pageSizeF().width();          // points (72/inch)
    const double viewW    = std::fmax(1.0, width() - 2 * kMargin);

    m_fitScale = pageW > 0.0 ? viewW / pageW : 1.0;
    m_scale    = m_fitScale * m_zoom;

    // Keep the scroll position inside the valid page-overflow range.
    m_vertScroll = std::clamp(m_vertScroll, -overflow(), 0.0);
}

double PdfViewerWidget::overflow() const
{
    if (!m_document || m_page < 0)
        return 0.0;

    const std::unique_ptr<Poppler::Page> page(m_document->page(m_page));
    if (!page)
        return 0.0;

    const double pageH = page->pageSizeF().height() * m_scale;   // logical px
    return std::fmax(0.0, pageH - (height() - kMargin - kHudH));
}

QRectF PdfViewerWidget::pageRect() const
{
    if (!m_document || m_page < 0)
        return QRectF();

    const std::unique_ptr<Poppler::Page> page(m_document->page(m_page));
    const QSizeF size = page ? page->pageSizeF() : QSizeF(0, 0);
    const double w = size.width()  * m_scale;
    const double h = size.height() * m_scale;

    const double x = (width() - w) / 2.0;      // horizontally centered
    const double y = kMargin + m_vertScroll;   // top-aligned, vertically scrollable

    return QRectF(x, y, w, h);
}

/* ---------------------------------------------------------------------------
 * Step E — rasterize current page (cached) + repaint
 * ------------------------------------------------------------------------- */

void PdfViewerWidget::ensureRendered()
{
    if (!m_document || m_page < 0)
        return;

    const double dpr = devicePixelRatioF();
    if (m_cachePage == m_page
        && qFuzzyCompare(m_cacheZoom, m_scale)
        && qFuzzyCompare(m_cacheDpr, dpr))
        return;                                         // cache is warm

    const std::unique_ptr<Poppler::Page> page(m_document->page(m_page));
    if (!page)
        return;

    // Render at the exact resolution we will display (physical pixels), so
    // text stays razor-sharp on Retina displays while Poppler does a single
    // pass for this (page, zoom, dpr) triple.
    const double ppi = 72.0 * m_scale * dpr;            // physical px/inch

    QImage raw = page->renderToImage(ppi, ppi,
                                     -1, -1, -1, -1,
                                     Poppler::Page::Rotate0,
                                     QColor(255, 255, 255));
    if (raw.isNull())
        return;                                         // keep the previous frame

    raw.setDevicePixelRatio(dpr);                       // draw at logical size

    m_cache     = raw;
    m_cachePage = m_page;
    m_cacheZoom = m_scale;
    m_cacheDpr  = dpr;
}

void PdfViewerWidget::paintEvent(QPaintEvent *event)
{
    QPainter painter(this);

    // Entire pane background — slightly lighter slate than the editor.
    painter.fillRect(event->rect(), QColor(0x2a, 0x2a, 0x30));

    if (!m_document || m_page < 0) {
        // Empty-state placeholder, harmless visual.
        painter.setPen(QColor(0x7a, 0x7f, 0x8a));
        QFont font = painter.font();
        font.setPixelSize(15);
        font.setFamilies({QStringLiteral("SF Pro"), QStringLiteral(".SF NS Text"),
                          QStringLiteral("Helvetica Neue")});
        painter.setFont(font);
        painter.drawText(rect(), Qt::AlignCenter,
                         tr("Live preview\n\nType on the left — this pane "
                            "renders your compiled PDF."));
        return;
    }

    ensureRendered();                                    // decode the current page

    const QRectF page = pageRect();

    // Subtle raised-page shadow (just enough depth, no border).
    painter.fillRect(page.adjusted(0, 3, 0, 3), QColor(0x16, 0x16, 0x1b));
    painter.fillRect(page, QColor(0xff, 0xff, 0xff));

    if (!m_cache.isNull()) {
        // Draw the cached image at its DPR-correct logical size.
        painter.drawImage(page.topLeft(), m_cache);
    } else {
        painter.setPen(QColor(0x8a, 0x8f, 0x9a));
        painter.drawText(page, Qt::AlignCenter, tr("Rendering…"));
    }

    // Minimal page HUD at the bottom-right corner.
    painter.setPen(QColor(0x8a, 0x8f, 0x9a));
    painter.drawText(rect().adjusted(0, 0, -10, -6),
                     Qt::AlignRight | Qt::AlignBottom,
                     QStringLiteral("%1 / %2").arg(m_page + 1).arg(m_pageCount));
}

/* ---------------------------------------------------------------------------
 * Interaction: wheel = scroll/pages, Cmd+wheel = zoom, drag = pan
 * ------------------------------------------------------------------------- */

void PdfViewerWidget::resizeEvent(QResizeEvent *event)
{
    QWidget::resizeEvent(event);
    refreshMetrics();             // fit-scale depends on the pane width
    update();
}

void PdfViewerWidget::wheelEvent(QWheelEvent *event)
{
    // ---- Zoom (Command / Control + scroll) -------------------------------
    if (event->modifiers() & Qt::ControlModifier) {
        const double steps = event->angleDelta().y() / 120.0;
        if (qFuzzyIsNull(steps)) { event->accept(); return; }

        // Keep the point under the cursor anchored while zooming.
        const double ratioY = (event->position().y() - kMargin - m_vertScroll)
                            / std::fmax(1.0, pageRect().height());
        const double heroScale = m_scale;

        setZoomFactor(m_zoom * std::pow(1.1, steps));

        if (!qFuzzyCompare(heroScale, m_scale) && overflow() > 0.0) {
            const double newTop = event->position().y() - kMargin
                                - ratioY * pageRect().height();
            m_vertScroll = std::clamp(newTop, -overflow(), 0.0);
        }
        event->accept();
        return;
    }

    // ---- Normal scroll ----------------------------------------------------
    const double dy = event->pixelDelta().isNull()
                        ? event->angleDelta().y() / 3.0
                        : event->pixelDelta().y();

    if (dy == 0.0) { event->accept(); return; }

    if (overflow() > 0.0) {
        const double before = m_vertScroll;
        m_vertScroll = std::clamp(m_vertScroll + dy, -overflow(), 0.0);
        if (!qFuzzyCompare(before, m_vertScroll)) {
            update();
            event->accept();
            return;
        }
    }

    // Page boundary reached → flip through the document with momentum feel.
    if (dy > 0.0) previousPage(); else nextPage();
    event->accept();
}

void PdfViewerWidget::mousePressEvent(QMouseEvent *event)
{
    if (event->button() == Qt::LeftButton) {
        m_dragging = true;
        m_dragLast = event->pos();
        m_dragScrollBase = m_vertScroll;
        setCursor(Qt::ClosedHandCursor);
        event->accept();
        return;
    }
    QWidget::mousePressEvent(event);
}

void PdfViewerWidget::mouseMoveEvent(QMouseEvent *event)
{
    if (m_dragging) {
        const QPoint delta = event->pos() - m_dragLast;
        m_vertScroll = std::clamp(m_dragScrollBase + delta.y(), -overflow(), 0.0);
        update();
        event->accept();
        return;
    }
    QWidget::mouseMoveEvent(event);
}

void PdfViewerWidget::mouseReleaseEvent(QMouseEvent *event)
{
    if (event->button() == Qt::LeftButton && m_dragging) {
        m_dragging = false;
        unsetCursor();
        event->accept();
        return;
    }
    QWidget::mouseReleaseEvent(event);
}

void PdfViewerWidget::keyPressEvent(QKeyEvent *event)
{
    switch (event->key()) {
    case Qt::Key_PageUp:
    case Qt::Key_Backspace:
        previousPage();   event->accept(); return;
    case Qt::Key_PageDown:
    case Qt::Key_Space:
        nextPage();       event->accept(); return;
    case Qt::Key_Home:
        jumpToPage(0);    event->accept(); return;
    case Qt::Key_End:
        jumpToPage(m_pageCount - 1); event->accept(); return;
    case Qt::Key_Plus:
    case Qt::Key_Equal:
        zoomIn();         event->accept(); return;
    case Qt::Key_Minus:
        zoomOut();        event->accept(); return;
    default:
        break;
    }
    QWidget::keyPressEvent(event);
}