#include "latexhighlighter.h"

#include <QFont>

namespace {
// Block states for the multi-line math state machine.
constexpr int kBlockInNormal = 0;
constexpr int kBlockInMath   = 1;
constexpr QLatin1String kDisplayMath("$$");
}

LatexHighlighter::LatexHighlighter(QObject *document)
    : QSyntaxHighlighter(document)
{
    // ---- Formats -----------------------------------------------------------
    const QColor accent     (0x52, 0x8b, 0xff);  // digital blue
    const QColor accentSoft (0x8e, 0xb3, 0xff);  // light blue
    const QColor muted      (0x60, 0x65, 0x70);  // comment gray
    const QColor mathColor  (0x9f, 0x7b, 0xff);  // soft violet for math
    const QColor baseText   (0xe3, 0xe3, 0xe6);  // primary code color

    m_commandFormat.setForeground(accentSoft);
    m_commandFormat.setFontWeight(QFont::Medium);

    m_envFormat.setForeground(accent);
    m_envFormat.setFontWeight(QFont::DemiBold);

    m_optionalFormat.setForeground(accentSoft);

    m_commentFormat.setForeground(muted);
    m_commentFormat.setFontItalic(true);

    m_mathFormat.setForeground(mathColor);
    m_mathFormat.setFontItalic(true);

    m_specialFormat.setForeground(baseText);
    m_specialFormat.setFontWeight(QFont::Medium);

    // ---- Rules (order matters; comment runs last so it dominates) ---------
    m_rules.append({
        QRegularExpression(QStringLiteral(R"(\\(?:begin|end)\s*\{[^{}]*\})")),
        m_envFormat
    });

    // Display/inline math delimiters: \( \) \[ \]
    m_rules.append({
        QRegularExpression(QStringLiteral(R"(\\(?:\(|\)|\[|\]))")),
        m_mathFormat
    });

    // Optional [key=value] argument blocks.
    m_rules.append({
        QRegularExpression(QStringLiteral(R"(\[[^\]\n]*\])")),
        m_optionalFormat
    });

    // Escaped special character (e.g. \{ \} \_ \&).
    m_rules.append({
        QRegularExpression(QStringLiteral(R"(\\[\\{}_&%$])")),
        m_specialFormat
    });

    // Control words: \section, \frac, \alpha…
    m_rules.append({
        QRegularExpression(QStringLiteral(R"(\\[A-Za-z@]+)")),
        m_commandFormat
    });

    // Comments: '%' not preceded by a backslash runs to end-of-line.
    m_rules.append({
        QRegularExpression(QStringLiteral(R"((^|[^\\])%.*$)")),
        m_commentFormat
    });
}

void LatexHighlighter::highlightBlock(const QString &text)
{
    const int len = text.length();

    // ---- Multi-line "$$ … $$" display math state machine -------------------
    int start = 0;
    if (previousBlockState() == kBlockInMath) {   // continued from previous line
        const int closeIdx = text.indexOf(kDisplayMath, 0);
        if (closeIdx < 0) {
            setFormat(0, len, m_mathFormat);
            setCurrentBlockState(kBlockInMath);
            return;
        }
        setFormat(0, closeIdx + 2, m_mathFormat);
        start = closeIdx + 2;
    }

    while (start < len) {
        const int openIdx = text.indexOf(kDisplayMath, start);
        if (openIdx < 0)
            break;
        const int closeIdx = text.indexOf(kDisplayMath, openIdx + 2);
        if (closeIdx < 0) {                       // opens and stays open
            setFormat(openIdx, len - openIdx, m_mathFormat);
            setCurrentBlockState(kBlockInMath);
            return;
        }
        setFormat(openIdx, closeIdx - openIdx + 2, m_mathFormat);
        start = closeIdx + 2;
    }

    setCurrentBlockState(kBlockInNormal);

    // ---- Line-local rules ---------------------------------------------------
    for (const HighlightRule &rule : m_rules) {
        const QRegularExpressionMatchIterator it = rule.pattern.globalMatch(text);
        while (it.hasNext()) {
            const QRegularExpressionMatch m = it.next();
            setFormat(m.capturedStart(), m.capturedLength(), rule.format);
        }
    }
}