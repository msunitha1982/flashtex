// latexworker.h — Background compilation worker for FlashTeX (live LaTeX editor).
//
// This object is *designed* to live in a dedicated QThread. It is moved there
// by MainWindow before any compile request is delivered, so no heavy work
// (file I/O, process execution, log parsing) ever touches the UI thread —
// the "non-negotiable" isolation requirement.
//
// Lifecycle contract:
//   * Created on the UI thread, then `moveToThread(workerThread)`.
//   * Public slots are only ever triggered from other threads via queued
//     signal/slot connections (auto-delivered by Qt).
//   * It never touches any QWidget. It reports back purely via signals.
//
// Concurrency model:
//   A single QProcess member, serialized execution inside the worker thread.
//   If a new request arrives while a previous process is still running, the
//   running process is killed *immediately* to reclaim CPU and the new
//   request replaces it. A monotonically increasing generation counter
//   (`m_generation` vs the captured `m_runGeneration`) guarantees a stale,
//   cancelled process `finished` callback can never emit a result.

#ifndef LATEXWORKER_H
#define LATEXWORKER_H

#include <QObject>
#include <QProcess>
#include <QString>
#include <QStringList>
#include <QList>
#include <memory>

class QElapsedTimer;
class QTemporaryDir;
class QTimer;

/* ---------------------------------------------------------------------------
 * Result types — plain value structs, safe to ship across threads through
 * queued signal/slot connections.
 * ------------------------------------------------------------------------ */

struct LatexIssue
{
    int line = -1;          // 1-based line inside document.tex; -1 when unknown
    QString message;        // human-readable TeX error
    QString context;        // the offending source line, when available
    QString hint;           // LaTeX's own "l.<line>"/advice line, else empty
};

struct LatexReport
{
    bool success = false;   // true == a PDF was produced
    QString pdfPath;        // absolute path to the compiled PDF (in the temp dir)
    QString engineMessage;  // human status, e.g. "No pages of output"
    QList<LatexIssue> errors;
    qint64 elapsedMs = 0;   // wall time of the engine run
};
Q_DECLARE_METATYPE(LatexIssue)
Q_DECLARE_METATYPE(LatexReport)

class LatexWorker : public QObject
{
    Q_OBJECT

public:
    explicit LatexWorker(QObject *parent = nullptr);
    ~LatexWorker() override;

public slots:
    /**
     * Compile the given LaTeX source. Delivered as a queued invocation from
     * the UI thread after the 400 ms debounce.
     *
     * Full pipeline: isolated QTemporaryDir workspace -> write document.tex
     * -> (kill a still-running engine) -> spawn `pdflatex` async -> watch
     * completion -> parse document.log -> emit @c compileFinished().
     */
    void compileSource(const QString &latexSource);

signals:
    /** The worker has begun executing the engine. */
    void compileStarted();

    /** Single completion signal for both outcomes (see report.success). */
    void compileFinished(const LatexReport &report);

private:
    void startEngine(const QString &workingDir, const QString &texFileName);
    void onProcessFinished(int exitCode, QProcess::ExitStatus status);
    void onWatchdogTimeout();
    void emitFailure(const QString &message);
    QList<LatexIssue> parseLogFile(const QString &logFilePath) const;
    QString readFileUtf8(const QString &path) const;

    // -- Engine state -------------------------------------------------------
    QProcess *m_process = nullptr;         // owned child of this QObject
    QTimer   *m_watchdog = nullptr;        // kills runaway engines
    bool      m_startFailed = false;

    std::unique_ptr<QTemporaryDir> m_tempDir;   // fresh isolated workspace per request

    QString m_workspaceDir;                     // temp dir path for this run
    QString m_pdfPath;                         // resolved document.pdf

    bool    m_running = false;
    quint64 m_generation = 0;      // bumped on every compileSource() call
    quint64 m_runGeneration = 0;   // generation that a started process belongs to
    QElapsedTimer *m_timer = nullptr;

    static constexpr int kEngineTimeoutMs = 25000; // runaway-engine watchdog
};

#endif // LATEXWORKER_H