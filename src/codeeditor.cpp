#include "codeeditor.h"

#include <QPainter>
#include <QPaintEvent>
#include <QResizeEvent>
#include <QKeyEvent>
#include <QTextCursor>
#include <QTextBlock>
#include <QTextFormat>
#include <QLabel>

/* =====================================================================
 * Line-number gutter widget (child of the editor)
 * ==================================================================== */

class CodeEditor::LineNumberArea : public QWidget
{
public:
    explicit LineNumberArea(CodeEditor *editor)
        : QWidget(editor)
        , m_editor(editor)
    {
        setAttribute(Qt::WA_OpaquePaintEvent);
    }

    QSize sizeHint() const override
    {
        return QSize(m_editor->lineNumberAreaWidth(), 0);
    }

protected:
    void paintEvent(QPaintEvent *event) override
    {
        m_editor->updateLineNumberArea(event->rect(), 0);
    }

private:
    CodeEditor *m_editor;
};

/* =====================================================================
 * CodeEditor
 * ==================================================================== */

CodeEditor::CodeEditor(QWidget *parent)
    : QPlainTextEdit(parent)
{
    m_lineNumber = new LineNumberArea(this);

    setTabStopDistance(fontMetrics().horizontalAdvance(QLatin1Char(' ')) * 4);
    setCursorWidth(2);

    // Keep the gutter and margins in sync with the block layout.
    connect(this, &CodeEditor::blockCountChanged,
            this, &CodeEditor::updateLineNumberAreaWidth);
    connect(this, &CodeEditor::updateRequest,
            this, &CodeEditor::updateLineNumberArea);
    connect(this, &CodeEditor::cursorPositionChanged,
            this, &CodeEditor::highlightCurrentLine);

    updateLineNumberAreaWidth();
    highlightCurrentLine();
}

void CodeEditor::setStatusOverlay(QLabel *label)
{
    m_statusLabel = label;
    if (!label)
        return;

    label->setParent(this);
    label->setAttribute(Qt::WA_TransparentForMouseEvents, true); // keep text selectable
    label->raise();
    positionStatusOverlay();
}

/* ------------------------------------------------------------------ *
 * Geometry
 * ------------------------------------------------------------------ */

void CodeEditor::resizeEvent(QResizeEvent *event)
{
    QPlainTextEdit::resizeEvent(event);

    const QRect content = contentsRect();
    m_lineNumber->setGeometry(QRect(content.left(), content.top(),
                                    lineNumberAreaWidth(), content.height()));
    positionStatusOverlay();
}

void CodeEditor::positionStatusOverlay()
{
    if (!m_statusLabel)
        return;

    const QSize hint = m_statusLabel->sizeHint();
    const int margin = 12;
    m_statusLabel->resize(hint);
    m_statusLabel->move(width()  - hint.width()  - margin,
                        height() - hint.height() - margin);
    m_statusLabel->raise();
}

void CodeEditor::updateLineNumberAreaWidth()
{
    setViewportMargins(lineNumberAreaWidth(), 0, 0, 0);
    m_lineNumber->update();
}

int CodeEditor::lineNumberAreaWidth() const
{
    int digits = 1;
    int max = qMax(1, blockCount());
    while (max >= 10) { max /= 10; ++digits; }

    // gutter padding (left) + digit width + breathing room (right)
    return 12 + fontMetrics().horizontalAdvance(QLatin1Char('9')) * digits + 12;
}

/* ------------------------------------------------------------------ *
 * Gutter drawing
 * ------------------------------------------------------------------ */

void CodeEditor::updateLineNumberArea(const QRect &rect, int verticalDelta)
{
    Q_UNUSED(verticalDelta); // single-page painting fixes correctness; scroll is cosmetic.

    QPainter painter(m_lineNumber);
    painter.fillRect(rect, QColor(0x1c, 0x1f, 0x26));

    painter.setPen(QColor(0x60, 0x65, 0x70));
    painter.setFont(font());

    int number = 0;
    for (QTextBlock block = firstVisibleBlock();
         block.isValid();
         block = block.next(), ++number) {

        const QRectF geometry = blockBoundingGeometry(block)
                                    .translated(contentOffset());
        const int top    = qRound(geometry.top());
        const int bottom = top + qRound(blockBoundingRect(block).height());

        // Cheap culling: skip lines outside the damaged rect.
        if (top > rect.bottom())
            break;
        if (bottom < rect.top())
            continue;

        painter.drawText(0, top, m_lineNumber->width() - 8,
                         fontMetrics().height(),
                         Qt::AlignRight,
                         QString::number(block.blockNumber() + 1));
    }
}

/* ------------------------------------------------------------------ *
 * Current-line accent — a single full-width extra selection, near-free
 * ------------------------------------------------------------------ */

void CodeEditor::highlightCurrentLine()
{
    QTextEdit::ExtraSelection sel;
    QColor wash(0x28, 0x2e, 0x3a);          // subtle blue-slate; [#528bff] at low alpha
    sel.format.setBackground(wash);
    sel.format.setProperty(QTextFormat::FullWidthSelection, true);
    sel.cursor = textCursor();
    sel.cursor.clearSelection();

    setExtraSelections({ sel });
}

/* ------------------------------------------------------------------ *
 * Smart typing: auto-matching delimiters + skip when pair already there
 * ------------------------------------------------------------------ */

void CodeEditor::keyPressEvent(QKeyEvent *event)
{
    static const QPair<QChar, QChar> kPairs[] = {
        { QLatin1Char('('), QLatin1Char(')') },
        { QLatin1Char('['), QLatin1Char(']') },
        { QLatin1Char('{'), QLatin1Char('}') },
        { QLatin1Char('$'), QLatin1Char('$') },
    };

    const QChar typed = event->text().isEmpty() ? QChar() : event->text().front();

    for (const auto &pair : kPairs) {
        const QChar &open  = pair.first;
        const QChar &close = pair.second;

        if (typed == open) {
            // Insert the pair, park the caret between them.
            insertPlainText(QString(open) + close);
            QTextCursor c = textCursor();
            c.movePosition(QTextCursor::Left, QTextCursor::MoveAnchor, 1);
            setTextCursor(c);
            return;
        }

        if (typed == close) {
            // Already on a matching closer? Just step over it.
            const int pos = textCursor().position();
            if (pos < document()->characterCount()
                && document()->character(pos) == close) {
                moveCursor(QTextCursor::Right);
                return;
            }
            break; // not a balanced context root — fall through
        }
    }

    QPlainTextEdit::keyPressEvent(event);
}