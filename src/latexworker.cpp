#include "latexworker.h"

#include <QProcess>
#include <QTemporaryDir>
#include <QFile>
#include <QFileInfo>
#include <QTextStream>
#include <QRegularExpression>
#include <QElapsedTimer>
#include <QTimer>

#include <memory>

/* ---------------------------------------------------------------------------
 * Lifecycle
 * ------------------------------------------------------------------------- */

LatexWorker::LatexWorker(QObject *parent)
    : QObject(parent)
    , m_process(new QProcess(this))
    , m_watchdog(new QTimer(this))
    , m_timer(new QElapsedTimer())
{
    // Merge stdout/stderr and funnel them into a file: keeps the app console
    // clean while we still parse the authoritative document.log afterwards.
    m_process->setProcessChannelMode(QProcess::MergedChannels);

    // Watchdog: some LaTeX packages enter interactive prompt loops even with
    // -nonstopmode; kill those hard so the pipeline never wedges.
    m_watchdog->setSingleShot(true);
    m_watchdog->setInterval(kEngineTimeoutMs);
    connect(m_watchdog, &QTimer::timeout, this, &LatexWorker::onWatchdogTimeout);

    connect(m_process, &QProcess::finished, this, &LatexWorker::onProcessFinished);
    connect(m_process, &QProcess::errorOccurred, this,
            [this](QProcess::ProcessError err) {
                if (err == QProcess::FailedToStart)
                    m_startFailed = true;
            });
}

LatexWorker::~LatexWorker()
{
    if (m_process && m_process->state() != QProcess::NotRunning) {
        m_process->kill();
        m_process->waitForFinished(2000);
    }
}

/* ---------------------------------------------------------------------------
 * Step B + C — isolated workspace, then run the engine
 * ------------------------------------------------------------------------- */

void LatexWorker::compileSource(const QString &latexSource)
{
    // New generation. IMPORTANT: the old process keeps its *own* older value
    // of m_runGeneration until we are done cancelling it below, so its stale
    // `finished` callback will fail `m_generation != m_runGeneration` and is
    // discarded. Only after the old run is fully gone do we rebind the fresh
    // generation to *this* process.
    const quint64 generation = ++m_generation;

    // Cancel an engine still chewing CPU so the new request starts instantly.
    if (m_process->state() != QProcess::NotRunning) {
        m_process->kill();                       // immediate, no graceful drain
        m_process->waitForFinished(4000);        // consumes the stale `finished` (discarded)
    }

    // From here on this process owns the new generation.
    m_runGeneration  = generation;
    m_running        = true;
    m_startFailed    = false;
    m_timer->restart();
    emit compileStarted();

    // Fresh, isolated workspace for this request (spec Step B). Recreating
    // the directory guarantees a pristine compile — no stale .aux/.toc/.pdf.
    m_tempDir = std::make_unique<QTemporaryDir>();
    if (!m_tempDir->isValid()) {
        emitFailure(QStringLiteral(
            "Could not create an isolated workspace in the system temp folder."));
        return;
    }
    m_workspaceDir = m_tempDir->path();
    m_pdfPath      = m_workspaceDir + QStringLiteral("/document.pdf");

    const QString texPath = m_workspaceDir + QStringLiteral("/document.tex");

    // Flush the raw QString into document.tex (UTF-8 — modern TeX default).
    {
        QFile tex(texPath);
        if (!tex.open(QIODevice::WriteOnly | QIODevice::Truncate | QIODevice::Text)) {
            emitFailure(QStringLiteral("Could not write %1").arg(texPath));
            return;
        }
        tex.write(latexSource.toUtf8());
        tex.close();
    }

    startEngine(m_workspaceDir, QStringLiteral("document.tex"));
}

void LatexWorker::startEngine(const QString &workingDir, const QString &texFileName)
{
    m_process->setWorkingDirectory(workingDir);

    QStringList args;
    args << QStringLiteral("-interaction=nonstopmode") // keep going past recoverable errors
         << QStringLiteral("-halt-on-error")           // stop at the first fatal error
         << QStringLiteral("-file-line-error")         // produce `file:line: msg` for parsing
         << texFileName;

    m_process->start(QStringLiteral("pdflatex"), args);
    m_watchdog->start();

    if (!m_process->waitForStarted(3000)) {
        m_watchdog->stop();
        emitFailure(QStringLiteral(
            "Could not start `pdflatex`. Install a TeX distribution (MacTeX/"
            "BasicTeX) and make sure it is on your PATH."));
        return;
    }
}

/* ---------------------------------------------------------------------------
 * Step D — completion, log parsing, thread return
 * ------------------------------------------------------------------------- */

void LatexWorker::onProcessFinished(int exitCode, QProcess::ExitStatus status)
{
    m_watchdog->stop();

    if (m_runGeneration != m_generation) return; // stale (killed & replaced) run
    if (!m_running) return;                      // already emitted by watchdog/etc.

    m_running = false;

    LatexReport report;
    report.elapsedMs = m_timer->elapsed();

    const bool engineOk = (status == QProcess::NormalExit && exitCode == 0);
    const QFileInfo pdfInfo(m_pdfPath);

    if (m_startFailed) {
        report.engineMessage = QStringLiteral("`pdflatex` could not be launched.");
    } else if (engineOk && pdfInfo.exists() && pdfInfo.size() > 0) {
        // Success path — return the binary path of the compiled PDF.
        report.success = true;
        report.pdfPath = pdfInfo.absoluteFilePath();
        report.engineMessage = QStringLiteral("Synced in %1 ms").arg(report.elapsedMs);
    } else {
        // Failure path — Step D: parse document.log line-by-line.
        report.engineMessage = QStringLiteral("Compilation failed.");
        report.errors = parseLogFile(m_workspaceDir + QStringLiteral("/document.log"));

        if (report.errors.isEmpty()) {
            report.engineMessage = engineOk
                ? QStringLiteral("Finished cleanly but produced no PDF output.")
                : QStringLiteral("Engine exited with code %1 without producing a PDF.")
                      .arg(exitCode);
        }
    }

    emit compileFinished(report);
}

void LatexWorker::onWatchdogTimeout()
{
    // Hard-kill a runaway engine; its `finished` signal will run the normal
    // report path (watchdog stops itself there after the kill).
    if (m_running && m_process->state() != QProcess::NotRunning)
        m_process->kill();
}

void LatexWorker::emitFailure(const QString &message)
{
    if (!m_running) return;
    m_running = false;
    m_watchdog->stop();

    LatexReport report;
    report.engineMessage = message;
    report.elapsedMs     = m_timer->elapsed();
    emit compileFinished(report);
}

/* ---------------------------------------------------------------------------
 * Step D — log parsing (document.log, line by line)
 * ------------------------------------------------------------------------- */

QList<LatexIssue> LatexWorker::parseLogFile(const QString &logFilePath) const
{
    QList<LatexIssue> issues;
    const QString log = readFileUtf8(logFilePath);
    if (log.isEmpty())
        return issues;

    // TeX classic: an error begins with '!' and continues through the
    // `l.<number>` line (the offending source) and sometimes context lines.
    static const QRegularExpression lNumRe(QStringLiteral("^\\s*l[.:]?\\s*(\\d+)"));
    static const QRegularExpression fileLineRe(
        QStringLiteral(R"(^\S*(?:\.[A-Za-z0-9_]+)?\.tex:(\d+):\s*(.*))"));

    const QStringList lines = log.split(QLatin1Char('\n'));

    LatexIssue current;
    bool inBlock = false;
    bool expectSourceLine = false;

    auto flush = [&]{
        if (inBlock && (!current.message.isEmpty() || current.line >= 0))
            issues.append(current);
        current = LatexIssue();
        inBlock = false;
        expectSourceLine = false;
    };

    for (const QString &rawLine : lines) {
        const QString t = rawLine.trimmed();
        if (t.isEmpty())
            continue;

        if (t.startsWith(QLatin1Char('!'))) {
            flush();                                       // close the previous error
            inBlock = true;
            current.message = t.mid(1).trimmed();
            continue;
        }

        if (!inBlock) {
            // Standalone `file:line: message` entries (warnings/errors).
            const auto m = fileLineRe.match(t);
            if (m.hasMatch()) {
                LatexIssue direct;
                direct.line    = m.captured(1).toInt();
                direct.message = m.captured(2).trimmed();
                issues.append(direct);
            }
            continue;
        }

        // Inside a '!' block — hunt for the line number and source context.
        const auto num = lNumRe.match(t);
        if (num.hasMatch() && current.line < 0) {
            current.line = num.captured(1).toInt();
            current.hint = t;
            expectSourceLine = true;   // the line right after `l.N` is the code
            continue;
        }

        const auto fileLine = fileLineRe.match(t);
        if (fileLine.hasMatch()) {
            if (current.line < 0) {
                current.line    = fileLine.captured(1).toInt();
                current.message = fileLine.captured(2).trimmed();
            }
            expectSourceLine = true;
            continue;
        }

        if (expectSourceLine && current.context.isEmpty()
            && !t.startsWith(QLatin1String("..."))
            && !t.contains(QLatin1String("Context:"))) {
            current.context = t;
            expectSourceLine = false;
        }
    }
    flush();

    return issues;
}

QString LatexWorker::readFileUtf8(const QString &path) const
{
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly | QIODevice::Text))
        return QString();
    return QString::fromUtf8(f.readAll());
}