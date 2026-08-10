#include "mainwindow.h"

#include "codeeditor.h"
#include "latexhighlighter.h"
#include "latexworker.h"
#include "pdfviewerwidget.h"

#include <QSplitter>
#include <QTimer>
#include <QThread>
#include <QLabel>
#include <QAction>
#include <QMenuBar>
#include <QMenu>
#include <QFileDialog>
#include <QMessageBox>
#include <QFile>
#include <QFileInfo>
#include <QTextStream>
#include <QTextCursor>
#include <QCloseEvent>

namespace {

// ---------- bundled stylesheet (distraction-free dark theme) ----------
const char *const kAppStyleSheet = R"SS(
    /* Root — deep matte charcoal everywhere. */
    QMainWindow { background:#1e1e24; color:#e3e3e6; }

    /* ---- Editor ---------------------------------------------------------- */
    QPlainTextEdit#texEditor {
        background:#1e1e24;
        color:#e3e3e6;
        border:none;
        padding:20px;                       /* generous gutter so code never hugs the edges */
        selection-background-color: rgba(82,139,255,0.35);
        selection-color:#ffffff;
        font-family:"SF Mono","Menlo","Consolas","Fira Code",monospace;
        font-size:13px;
    }
    QPlainTextEdit#texEditor:focus { border:none; }

    /* ---- Custom scrollbars: 6px, flat, arrow-less ------------------------ */
    QScrollBar:vertical {
        background:transparent; width:6px; margin:3px 1px 3px 1px; border:none;
    }
    QScrollBar::handle:vertical {
        background:#404452; border-radius:3px; min-height:28px;
    }
    QScrollBar::handle:vertical:hover { background:#55596a; }
    QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical {
        width:0; height:0; background:none; border:none;
    }
    QScrollBar::add-page:vertical, QScrollBar::sub-page:vertical {
        background:transparent;
    }

    QScrollBar:horizontal {
        background:transparent; height:6px; margin:1px 3px 1px 3px; border:none;
    }
    QScrollBar::handle:horizontal {
        background:#404452; border-radius:3px; min-width:28px;
    }
    QScrollBar::handle:horizontal:hover { background:#55596a; }
    QScrollBar::add-line:horizontal, QScrollBar::sub-line:horizontal {
        width:0; height:0; background:none; border:none;
    }
    QScrollBar::add-page:horizontal, QScrollBar::sub-page:horizontal {
        background:transparent;
    }

    /* ---- Splitter: hairline handle that glows on hover ------------------- */
    QSplitter#appSplitter { background:#1e1e24; }
    QSplitter#appSplitter::handle { background:#33363f; width:1px; height:1px; }
    QSplitter#appSplitter::handle:hover { background:#528bff; }

    /* ---- PDF pane (widget paints its own background, this is the fallback) - */
    QWidget#viewerPane { background:#2a2a30; border:none; }

    /* ---- Floating status capsule ---------------------------------------- */
    QLabel#statusCapsule {
        background-color: rgba(30,30,36,0.92);
        color:#a0a5b0;
        border:1px solid rgba(0,0,0,0.4);
        border-radius:6px;
        padding:5px 10px;
        font-family:"Menlo","SF Mono",monospace;
        font-size:11px;
    }
    QLabel#statusCapsule[phase="compiling"] { color:#c7cbd4; }
    QLabel#statusCapsule[phase="success"]   { color:#7ed8a7; border-color:rgba(126,216,167,0.35); }
    QLabel#statusCapsule[phase="error"]     { color:#ff8b8b; border-color:rgba(255,139,139,0.35); }

    /* ---- Native-quality tooltips ---------------------------------------- */
    QToolTip {
        background:#2a2a30; color:#e3e3e6;
        border:1px solid #3a3d46; padding:4px 8px;
    }
)SS";

// Welcome document — instantly demonstrates the live pipeline out of the box.
const char *const kWelcomeDoc = R"TEX(%  FlashTeX — live LaTeX at native speed

\documentclass[11pt]{article}
\usepackage[margin=1in]{geometry}
\usepackage{amsmath, amssymb}

\title{FlashTeX}
\author{native C++ / Qt build}
\date{}

\begin{document}
\maketitle

\section{Welcome}
You are editing on the left. When you pause typing, a background worker
spawns \texttt{pdflatex}, parses the log, and this pane refreshes.

\begin{equation}
e^{i\pi} + 1 = 0
\end{equation}

\begin{itemize}
\item Zero UI latency
\item Isolated thread-pool compiler
\item Absolutely no web tech
\end{itemize}

\end{document}
)TEX";

enum StatusKind { StatusIdle = 0, StatusCompiling = 1, StatusOk = 2, StatusError = 3 };

} // namespace

/* ---------------------------------------------------------------------------
 * Construction
 * ------------------------------------------------------------------------- */

MainWindow::MainWindow(QWidget *parent)
    : QMainWindow(parent)
{
    setWindowTitle(QStringLiteral("FlashTeX — untitled"));
    resize(1360, 860);

    // Radical risk: apply the unified QSS bundle to the whole instance.
    setStyleSheet(QString::fromLatin1(kAppStyleSheet));

    buildUi();
    buildWorkerThread();

    // ---- Debounce (Step A) -------------------------------------------------
    // Every keystroke pushes the deadline back; the compilation request fires
    // only when 400 ms of silence elapse.
    m_debounce = new QTimer(this);
    m_debounce->setSingleShot(true);
    m_debounce->setInterval(400);
    connect(m_debounce, &QTimer::timeout, this, &MainWindow::forceCompile);
    connect(m_editor, &QPlainTextEdit::textChanged, this, [this] {
        m_debounce->start();
        setStatus(QString::fromUtf8("●"), StatusIdle);   // fresh typing = idle
    });

    // Seed with the welcome document and run a first render shortly after.
    m_editor->setPlainText(QString::fromUtf8(kWelcomeDoc));
    QTimer::singleShot(350, this, &MainWindow::forceCompile);
}

MainWindow::~MainWindow()
{
    // Worker lifecycle is handled via ~QThread (parented) + deleteLater chain.
    if (m_debounce) m_debounce->stop();
    if (m_workerThread && m_workerThread->isRunning()) {
        m_workerThread->quit();
        m_workerThread->wait(3000);
    }
}

/* ---------------------------------------------------------------------------
 * UI assembly
 * ------------------------------------------------------------------------- */

void MainWindow::buildUi()
{
    auto *central = new QWidget(this);
    central->setObjectName(QStringLiteral("centralPane"));
    auto *layout  = new QVBoxLayout(central);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(0);

    // ---- Split screen -------------------------------------------------------
    m_splitter = new QSplitter(Qt::Horizontal, central);
    m_splitter->setObjectName(QStringLiteral("appSplitter"));
    m_splitter->setChildrenCollapsible(false);
    m_splitter->setHandleWidth(1);

    // Editor
    m_editor = new CodeEditor;
    m_editor->setObjectName(QStringLiteral("texEditor"));
    {
        QFont font = m_editor->font();
        font.setFamilies({ QStringLiteral("SF Mono"), QStringLiteral("Menlo"),
                           QStringLiteral("Consolas"), QStringLiteral("Fira Code"),
                           QStringLiteral("monospace") });
        font.setPixelSize(13);
        m_editor->setFont(font);
    }
    (void) new LatexHighlighter(m_editor->document());  // lifetime bound to document

    // PDF viewer pane
    m_viewer = new PdfViewerWidget;
    m_viewer->setObjectName(QStringLiteral("viewerPane"));

    m_splitter->addWidget(m_editor);
    m_splitter->addWidget(m_viewer);
    m_splitter->setStretchFactor(0, 5);
    m_splitter->setStretchFactor(1, 5);
    m_splitter->setSizes({ 560, 640 });

    layout->addWidget(m_splitter);
    setCentralWidget(central);

    // ---- Floating status capsule -------------------------------------------
    m_statusLabel = new QLabel(QString(), central);
    m_statusLabel->setObjectName(QStringLiteral("statusCapsule"));
    m_editor->setStatusOverlay(m_statusLabel);
    setStatus(QStringLiteral("ready"), StatusIdle);

    // ---- Menu bar (native macOS) -------------------------------------------
    QMenu *fileMenu = menuBar()->addMenu(QStringLiteral("File"));
    QAction *newAct = fileMenu->addAction(QStringLiteral("New Document"),
                                          this, &MainWindow::newDocument);
    newAct->setShortcut(QKeySequence::New);

    QAction *openAct = fileMenu->addAction(QStringLiteral("Open…"),
                                           this, &MainWindow::openFile);
    openAct->setShortcut(QKeySequence::Open);

    m_saveAction = fileMenu->addAction(QStringLiteral("Save"), this, &MainWindow::saveFile);
    m_saveAction->setShortcut(QKeySequence::Save);

    QAction *saveAsAct = fileMenu->addAction(QStringLiteral("Save As…"),
                                             this, &MainWindow::saveFileAs);
    saveAsAct->setShortcut(QKeySequence::SaveAs);

    fileMenu->addSeparator();

    QAction *compileAct = fileMenu->addAction(QStringLiteral("Compile Now"),
                                              this, &MainWindow::forceCompile);
    compileAct->setShortcut(QKeySequence(QStringLiteral("Ctrl+R")));
}

/* ---------------------------------------------------------------------------
 * Worker thread + signal/slot wiring (Steps A–D)
 * ------------------------------------------------------------------------- */

void MainWindow::buildWorkerThread()
{
    m_workerThread = new QThread(this);
    m_workerThread->setObjectName(QStringLiteral("LaTeXWorker"));

    // QObject constructed here (UI), then dispatched to its own thread.
    m_worker = new LatexWorker;
    m_worker->moveToThread(m_workerThread);

    // One-way arm of the contract: UI signal  ->  worker slot (queued).
    connect(m_workerThread, &QThread::finished, m_worker, &QObject::deleteLater);
    connect(this, &MainWindow::compileRequested, m_worker, &LatexWorker::compileSource);
    connect(m_worker, &LatexWorker::compileStarted, this, &MainWindow::onCompileStarted);
    connect(m_worker, &LatexWorker::compileFinished,
            this, &MainWindow::onCompileFinished);

    m_workerThread->start();
}

/* ---------------------------------------------------------------------------
 * Step E — screen refresh + status capsule
 * ------------------------------------------------------------------------- */

void MainWindow::onCompileStarted()
{
    setStatus(QString::fromUtf8("●  Compiling…"), StatusCompiling);
}

void MainWindow::onCompileFinished(const LatexReport &report)
{
    if (report.success) {
        QString openError;
        if (m_viewer->loadPdf(report.pdfPath, &openError)) {
            setStatus(QString::fromUtf8("✓") + tr("  %1").arg(report.engineMessage), StatusOk);
        } else {
            setStatus(QString::fromUtf8("✗  Preview failed: " ) % openError, StatusError);
        }
        return;
    }

    if (report.errors.isEmpty()) {
        setStatus(QString::fromUtf8("✗  ") + report.engineMessage, StatusError);
        return;
    }

    const LatexIssue &first = report.errors.first();
    QString label = QString::fromUtf8("✗  Error");
    if (first.line > 0)
        label += tr(" on Line %1").arg(first.line);
    setStatus(label, StatusError);

    // Full message + the offending source line in the capsule tooltip.
    m_statusLabel->setToolTip(QStringLiteral("%1%2%3%4%5")
                                  .arg(first.message)
                                  .arg(first.context.isEmpty() ? QString() : QStringLiteral("\n\n"))
                                  .arg(first.context)
                                  .arg(report.errors.size() > 1 ? QStringLiteral("\n\n+ %1 more")
                                          .arg(report.errors.size() - 1) : QString())
                                  .arg(first.hint.isEmpty() ? QString() : QStringLiteral("\n") + first.hint));
    if (first.line > 0)
        jumpToLine(first.line);
}

void MainWindow::jumpToLine(int line)
{
    if (line < 1)
        return;
    QTextBlock block = m_editor->document()->findBlockByNumber(line - 1);
    if (!block.isValid())
        return;
    QTextCursor cursor(block);
    m_editor->setTextCursor(cursor);
    m_editor->centerCursor();
}

void MainWindow::forceCompile()
{
    m_debounce->stop();                       // cancels any pending timer
    onCompileStarted();                       // UI feedback must be immediate
    emit compileRequested(m_editor->toPlainText());
}

/* ---------------------------------------------------------------------------
 * Status capsule
 * ------------------------------------------------------------------------- */

void MainWindow::setStatus(const QString &text, int kind)
{
    if (!m_statusLabel)
        return;

    static const char *kKinds[] = { "idle", "compiling", "success", "error" };
    m_statusLabel->setProperty("status", kind >= 0 && kind <= StatusError
                                            ? QLatin1String(kKinds[kind])
                                            : QLatin1String("idle"));
    m_statusLabel->setText(text);

    // Force Qt to re-resolve the dynamic-property selector.
    m_statusLabel->style()->unpolish(m_statusLabel);
    m_statusLabel->style()->polish(m_statusLabel);
}

/* ---------------------------------------------------------------------------
 * File I/O (edited buffer only; worker handles its own temps)
 * ------------------------------------------------------------------------- */

void MainWindow::newDocument()
{
    m_editor->setPlainText(QString::fromUtf8(kWelcomeDoc));
    setCurrentFile(QString());
    forceCompile();
}

void MainWindow::openFile()
{
    const QString path = QFileDialog::getOpenFileName(
        this, tr("Open LaTeX source"), QString(), tr("LaTeX (*.tex);;All files (*)"));

    if (path.isEmpty())
        return;

    QFile file(path);
    if (!file.open(QIODevice::ReadOnly | QIODevice::Text)) {
        QMessageBox::warning(this, tr("FlashTeX"), tr("Cannot open %1").arg(path));
        return;
    }

    m_debounce->stop();                                 // suppress the auto-compile
    m_editor->setPlainText(QString::fromUtf8(file.readAll()));
    setCurrentFile(path);
    forceCompile();                                     // preview right away
    setStatus(QString::fromUtf8("✓  opened ") + QFileInfo(path).fileName(), StatusOk);
}

void MainWindow::saveFile()
{
    if (m_currentFile.isEmpty()) {
        saveFileAs();
        return;
    }
    QFile file(m_currentFile);
    if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate | QIODevice::Text)) {
        QMessageBox::warning(this, tr("FlashTeX"), tr("Cannot write %1").arg(m_currentFile));
        return;
    }
    file.write(m_editor->toPlainText().toUtf8());
    file.close();
}

void MainWindow::saveFileAs()
{
    const QString path = QFileDialog::getSaveFileName(
        QString(), tr("Save LaTeX"), QString(), tr("LaTeX (*.tex)"));

    if (path.isEmpty())
        return;

    m_currentFile = path;
    if (!m_currentFile.endsWith(QStringLiteral(".tex")))
        m_currentFile += QStringLiteral(".tex");
    saveFile();
    setCurrentFile(m_currentFile);
}

void MainWindow::setCurrentFile(const QString &path)
{
    m_currentFile = path;
    setWindowTitle(m_currentFile.isEmpty()
                       ? QStringLiteral("FlashTeX — untitled")
                       : QStringLiteral("FlashTeX — %1").arg(QFileInfo(m_currentFile).fileName()));
}

void MainWindow::closeEvent(QCloseEvent *event)
{
    if (m_debounce) m_debounce->stop();
    if (m_workerThread && m_workerThread->isRunning()) {
        m_workerThread->quit();
        m_workerThread->wait(3000);
    }
    QMainWindow::closeEvent(event);
}