// main.cpp — FlashTeX application entry point.
//
// Native macOS integration notes (Monterey+):
//   * Standard .app bundle (CMake MACOSX_BUNDLE) with LSUIElement off, so a
//     regular dock + title-bar app with the native menu bar.
//   * Fusion + an explicit dark QPalette gives deterministic, high-contrast
//     rendering across macOS / Linux while keeping the native menu bar.
//   * Qt 6 enables High-DPI (Retina) automatically; the PDF viewer renders at
//     the devicePixelRatio, so text stays crisp.

#include <QApplication>
#include <QPalette>
#include <QColor>
#include <QMetaType>

#include "mainwindow.h"
#include "latexworker.h"   // registers custom cross-thread result types

namespace {

// App-wide dark palette so native pieces (menus, tooltips) match the theme.
void applyDarkPalette(QApplication &app)
{
    QPalette palette;
    const QColor bg(0x1e, 0x1e, 0x24);
    const QColor fg(0xe3, 0xe3, 0xe6);
    const QColor mid(0x2a, 0x2a, 0x30);
    const QColor faint(0x60, 0x65, 0x70);
    const QColor accent(0x52, 0x8b, 0xff);

    palette.setColor(QPalette::Window,          bg);
    palette.setColor(QPalette::WindowText,      fg);
    palette.setColor(QPalette::Base,            bg);
    palette.setColor(QPalette::AlternateBase,   mid);
    palette.setColor(QPalette::Text,            fg);
    palette.setColor(QPalette::Button,          mid);
    palette.setColor(QPalette::ButtonText,      fg);
    palette.setColor(QPalette::Highlight,       accent);
    palette.setColor(QPalette::HighlightedText, Qt::white);
    palette.setColor(QPalette::ToolTipBase,     mid);
    palette.setColor(QPalette::ToolTipText,     fg);
    palette.setColor(QPalette::PlaceholderText, faint);

    app.setPalette(palette);
}

} // namespace

int main(int argc, char *argv[])
{
    QApplication app(argc, argv);

    QCoreApplication::setOrganizationName(QStringLiteral("FlashTeX"));
    QCoreApplication::setApplicationName(QStringLiteral("FlashTeX"));
    QCoreApplication::setApplicationVersion(QStringLiteral("1.0.0"));

    // Deterministic widget painting underneath all the custom style sheets —
    // still native look via the Coco/Cocoa platform theme.
    app.setStyle(QStringLiteral("Fusion"));
    applyDarkPalette(app);

    // Custom cross-thread result payloads used by the worker -> UI signals.
    QMetaType::typeOf<LatexIssue>();                // triggers registry of the struct
    QMetaType::typeOf<LatexReport>();

    MainWindow window;
    window.resize(1360, 860);
    window.show();

    return app.exec();
}