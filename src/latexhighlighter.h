// latexhighlighter.h — lightweight LaTeX syntax highlighter.
//
// Rules are line-local (regex pipeline + a bit of multi-line math state), so
// re-highlighting long documents stays cheap. However the palette pulls from
// the app-wide dark theme.

#ifndef LATEXHIGHLIGHTER_H
#define LATEXHIGHLIGHTER_H

#include <QSyntaxHighlighter>
#include <QTextCharFormat>
#include <QRegularExpression>

class LatexHighlighter : public QSyntaxHighlighter
{
    Q_OBJECT

public:
    explicit LatexHighlighter(QObject *document);

protected:
    void highlightBlock(const QString &text) override;

private:
    class HighlightRule
    {
    public:
        QRegularExpression pattern;
        QTextCharFormat format;
    };

    QList<HighlightRule> m_rules;
    QTextCharFormat m_commandFormat;
    QTextCharFormat m_envFormat;
    QTextCharFormat m_optionalFormat;
    QTextCharFormat m_commentFormat;
    QTextCharFormat m_mathFormat;
    QTextCharFormat m_specialFormat;
};

#endif // LATEXHIGHLIGHTER_H