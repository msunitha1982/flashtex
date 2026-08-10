// mainwindow.h — application shell tying every subsystem together.
//
// Owns (Qt parent-child memory management where appropriate, unique_ptr-style
// ownership where it makes sense):
//   * A split-pane layout: CodeEditor (left)                 PdfViewer (right)
//   * The 400 ms debounce QTimer for live renders
//   * The dedicated compilation QThread + LatexWorker instance
//   * The floating "status capsule" overlay in the editor corner
//
// Thread contract (non-negotiable):
//   * UI thread touches widgets only.
//   * Worker thread executes `compileSource()` and never touches widgets.
//   * All communication is signal/slot exclusively.

#ifndef MAINWINDOW_H
#define MAINWINDOW_H

#include <QMainWindow>

class QSplitter;
class QTimer;
class QThread;
class QLabel;
class QAction;
class QCloseEvent;
class CodeEditor;
class PdfViewerWidget;
class LatexWorker;
struct LatexReport;

class MainWindow : public QMainWindow
{
    Q_OBJECT

public:
    explicit MainWindow(QWidget *parent = nullptr);
    ~MainWindow() override;

signals:
    /** Queued → LatexWorker::compileSource() in the worker thread. */
    void compileRequested(const QString &latexSource);

protected:
    void closeEvent(QCloseEvent *event) override;

private:
    void buildUi();
    void buildWorkerThread();
    void setStatus(const QString &text, int kind);              // 0 idle,1 comp,2 ok,3 err
    void setCurrentFile(const QString &path);

    void openFile();
    void saveFile();
    void saveFileAs();
    void newDocument();
    void forceCompile();          // debounce bypass (Cmd+R)
    void onCompileStarted();
    void onCompileFinished(const LatexReport &report);
    void jumpToLine(int line);

    // UI members
    CodeEditor      *m_editor       = nullptr;
    PdfViewerWidget *m_viewer       = nullptr;
    QSplitter       *m_splitter     = nullptr;
    QLabel          *m_statusLabel  = nullptr;
    QAction         *m_saveAction   = nullptr;

    // Debounce + threading
    QTimer     *m_debounce = nullptr;
    QThread    *m_workerThread = nullptr;
    LatexWorker *m_worker  = nullptr;

    QString m_currentFile;                       // "" == untitled buffer
};

#endif // MAINWINDOW_H