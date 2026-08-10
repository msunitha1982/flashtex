// codeeditor.h — the optimized LaTeX editing surface.
//
// Thin specialization of QPlainTextEdit:
//   * an efficient painted line-number gutter
//   * brace auto-pairing + soft-indent tab (snappy typing feel)
//   * current-line highlighting using a single ExtraSelection
//   * a floating compile-status overlay label pinned to the bottom-right
//
// All overlay/label pointer handling happens on the UI thread only.

#ifndef CODEEDITOR_H
#define CODEEDITOR_H

#include <QPlainTextEdit>

class QLabel;

class CodeEditor : public QPlainTextEdit
{
    Q_OBJECT

public:
    explicit CodeEditor(QWidget *parent = nullptr);

    /** Attach the floating status capsule (the app positions it per resize). */
    void setStatusOverlay(QLabel *label);

protected:
    void resizeEvent(QResizeEvent *event) override;
    void keyPressEvent(QKeyEvent *event) override;

private:
    class LineNumberArea;

    void updateLineNumberArea(const QRect &rect, int verticalDelta);
    void updateLineNumberAreaWidth();
    int  lineNumberAreaWidth() const;
    void highlightCurrentLine();
    void positionStatusOverlay();

    LineNumberArea *m_lineNumber = nullptr;
    QLabel         *m_statusLabel = nullptr;
};

#endif // CODEEDITOR_H