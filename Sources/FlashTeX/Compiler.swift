import Foundation

// Compiler — background compilation engine.
//
// * 400 ms debounce (Timer) so live rendering only happens after a pause.
// * Each compile runs in a unique temp directory (document.tex → document.pdf).
// * A new request kills any in-flight engine run immediately (generation
//   counter discards stale callbacks).
// * Every engine run gets `-shell-escape` plus a synthesized PATH (TeX/Brew
//   locations prepended), so \begin{asy} blocks can reach the `asy` binary
//   even though GUI apps never inherit the shell PATH.
// * The pipeline runs multiple passes so references, TOC and labels settle:
//   pdflatex → [asy on any .asy files] → pdflatex → pdflatex. Asymptote
//   environments are compiled through the `asy` binary when present, and any
//   pass that materialises .asy assets or shell-escapes to `asy` triggers the
//   extra pdflatex pass needed to embed the figures.
// * stdout/stderr are captured through pipes (never block the terminal), so a
//   failing engine leaves a trail we can surface in the report.
// * The previous build directory is kept alive until the next successful
//   compile so the PDFView can still display it; it is removed afterwards.
// * document.log is parsed line-by-line into structured issues.

struct LatexIssue {
    var line: Int
    var message: String
    var context: String
    var hint: String
}

struct LatexReport {
    let success: Bool
    let pdfURL: URL?
    let engineMessage: String
    let errors: [LatexIssue]
    let elapsedMs: Int64
    /// Engine that produced this report (may differ from the requested one
    /// after a silent LuaTeX fallback).
    let engineName: String
    /// True when the engine reported a memory/capacity failure (surfaced so
    /// the caller knows a memory-override retry is worthwhile).
    let capacityError: Bool
}

final class Compiler {

    var engine = "pdflatex"

    var onStatusStarted: (() -> Void)?
    var onFinished: ((LatexReport) -> Void)?

    private static let compiledBeforeKey = "FlashTeX.HasCompiledBefore"

    private var debounce: Timer?
    private let lock = NSLock()
    private var currentProcess: Process?
    private var lastBuildDir: URL?
    private let generation = AtomicInt(0)
    /// Build dir reused across compiles so TeX's .aux/.toc/.out survive between
    /// runs — that's what makes the reference/TOC passes incremental instead
    /// of re-deriving everything from scratch each time.
    private var persistentBuildDir: URL?
    /// The source of the most recent request — consulted at pass time to
    /// decide whether `-shell-escape` should be granted.
    private var currentSource: String?
    /// True until the first successful engine run. TeX's first run rebuilds
    /// the kpathsea/font caches and can take minutes, so first runs get a much
    /// more generous watchdog than steady-state compiles.
    private var firstRun = !UserDefaults.standard.bool(forKey: compiledBeforeKey)

    init() {
        sweepStaleBuildDirs()
    }

    // MARK: - Public API

    /// Reset the debounce (default 400 ms, from the Flash preferences); the
    /// actual compile fires on the timer. The timer runs in `.common` mode so it
    /// still fires while the run loop is tracking an event (typing, scrolling) —
    /// a default-mode timer can be starved and "auto-compile" appears to miss
    /// the first edit or a paste.
    func scheduleCompile(source: String) {
        debounce?.invalidate()
        currentSource = source
        let delay = max(0.01, SettingsStore.shared.renderDebounceMs / 1000.0)
        let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            self?.compile(source: source, gateOnBalance: true)
        }
        debounce = t
        RunLoop.main.add(t, forMode: .common)
    }

    /// Compile immediately, bypassing the debounce (Cmd+R, on open).
    func compileNow(source: String) {
        debounce?.invalidate()
        currentSource = source
        compile(source: source, gateOnBalance: false)
    }

    func shutdown() {
        debounce?.invalidate()
        lock.lock()
        let proc = currentProcess
        currentProcess = nil
        let dirs = Set<URL?>([lastBuildDir, persistentBuildDir])
        lastBuildDir = nil
        persistentBuildDir = nil
        lock.unlock()
        if let proc, proc.isRunning { proc.terminate() }
        for case let dir? in dirs {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    /// Drop the incremental state when the document is replaced (new/open), so
    /// stale reference data from a previous document can never leak in.
    func resetIncrementalState() {
        lock.lock()
        let dir = persistentBuildDir
        persistentBuildDir = nil
        lastBuildDir = nil
        lock.unlock()
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    // MARK: - Compile orchestration

    private func compile(source: String, gateOnBalance: Bool) {
        // Debounced auto-compiles wait until the document is structurally
        // balanced (every \begin has its \end) so mid-keystroke builds don't
        // churn out "Missing \end" failures. Manual compiles always run.
        if gateOnBalance, !LatexStructure.isBalanced(source) {
            return
        }
        let gen = generation.increment()
        lock.lock()
        let running = currentProcess
        currentProcess = nil
        lock.unlock()
        if let running, running.isRunning {
            running.terminate()
        }

        DispatchQueue.main.async { [weak self] in
            self?.onStatusStarted?()
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.runCompile(source: source, generation: gen)
        }
    }

    private func runCompile(source rawSource: String, generation gen: Int) {
        let source = sanitizeSource(rawSource)

        // The fallback ladder: (1) normal run, (2) the same engine with far
        // larger TeX memory pools when a capacity error is reported, (3) LuaTeX
        // — whose pools are dynamically allocated — as the last resort.
        var outcome = runPipeline(source: source, engineName: engine, gen: gen,
                                  memoryOverride: false)
        if let r = outcome, !r.success, r.capacityError, r.engineName != "lualatex" {
            outcome = runPipeline(source: source, engineName: engine, gen: gen,
                                  memoryOverride: true)
        }
        if let r = outcome, !r.success, r.capacityError,
           r.engineName != "lualatex", TeX.findExecutable("lualatex") != nil {
            outcome = runPipeline(source: source, engineName: "lualatex", gen: gen,
                                  memoryOverride: false)
        }
    }

    private func runPipeline(source: String, engineName: String, gen: Int,
                             memoryOverride: Bool) -> LatexReport? {
        let start = Date()

        // Reuse the persistent build dir when one exists so TeX's reference
        // files (.aux/.toc/.out) carry over between compiles — incremental
        // compilation. It is only (re)created on the first run or after the
        // document changes.
        let buildDir: URL
        if let existing = persistentBuildDir {
            buildDir = existing
        } else if let fresh = makeBuildDir() {
            persistentBuildDir = fresh
            buildDir = fresh
        } else {
            deliverFailure("Could not create a temporary workspace.", gen: gen)
            return nil
        }

        let texURL = buildDir.appendingPathComponent("document.tex")
        do {
            try source.write(to: texURL, atomically: true, encoding: .utf8)
        } catch {
            deliverFailure("Could not write the temporary document: \(error.localizedDescription)", gen: gen)
            cleanup(buildDir)
            persistentBuildDir = nil
            return nil
        }

        guard let engineURL = engineExecutableURL(engineName) else {
            deliverFailure("Could not find `\(engineName)` on your PATH.\n"
                           + "Install MacTeX from https://www.tug.org/mactex/ (or BasicTeX), then try again.\n"
                           + "If it is installed but not on this path, add its bin directory (usually\n"
                           + "/Library/TeX/texbin) to the PATH used to launch FlashTeX.", gen: gen)
            return nil
        }

        // Documents without \label/\ref/\tableofcontents/Asymptote render in a
        // single pass — the common case, and the fastest one. Everything else
        // goes through the settled multi-pass pipeline below.
        let needsMultiplePasses = sourceNeedsMultiplePasses(source)

        var ok: Bool
        var engineOutput = ""
        if needsMultiplePasses {
            // Pass 1 (draft mode skips the PDF — faster). `-shell-escape` lets
            // TeX itself invoke `asy` for \begin{asy} blocks, writing the
            // figure PDFs into this build dir.
            let pass1 = runSinglePass(engineURL: engineURL, buildDir: buildDir,
                                      draftMode: true, memoryOverride: memoryOverride)
            ok = pass1.ok
            engineOutput = pass1.output
            // Explicit fallback: run `asy` ourselves so restricted shell-escape
            // configurations still work (all .asy files processed in parallel).
            if ok { runAsymptoteIfNeeded(buildDir: buildDir) }
            let refsAfter1 = referenceHash(buildDir)
            // Pass 2 writes the final PDF; a third pass only runs if references
            // moved (or an asy figure first appeared in this pass).
            if ok {
                let pass2 = runSinglePass(engineURL: engineURL, buildDir: buildDir,
                                          draftMode: false, memoryOverride: memoryOverride)
                ok = pass2.ok
                engineOutput = pass2.output
            }
            if ok && referenceHash(buildDir) != refsAfter1 {
                let pass3 = runSinglePass(engineURL: engineURL, buildDir: buildDir,
                                          draftMode: false, memoryOverride: memoryOverride)
                ok = pass3.ok
                engineOutput = pass3.output
            }
        } else {
            let pass1 = runSinglePass(engineURL: engineURL, buildDir: buildDir,
                                      draftMode: false, memoryOverride: memoryOverride)
            ok = pass1.ok
            engineOutput = pass1.output
            // Documents with \begin{asy} pulled in via \input — or whose .asy
            // assets only materialise during compilation — need a quick second
            // pass so PDFKit gets the rendered figures immediately.
            if ok && asyWasInvolved(buildDir: buildDir) {
                let pass2 = runSinglePass(engineURL: engineURL, buildDir: buildDir,
                                          draftMode: false, memoryOverride: memoryOverride)
                ok = pass2.ok
                engineOutput = pass2.output
            }
        }

        let elapsedMs = Int64(Date().timeIntervalSince(start) * 1000)
        let pdfURL = buildDir.appendingPathComponent("document.pdf")
        let logURL = buildDir.appendingPathComponent("document.log")

        let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        var errors = parseLog(log)
        // When the engine dies before writing a usable log, surface whatever
        // it printed instead of a bare "Compilation failed.".
        if !ok && errors.isEmpty && !engineOutput.isEmpty {
            let tail = String(engineOutput.suffix(300))
            errors = [LatexIssue(line: -1, message: "Engine error: \(tail)",
                                 context: "", hint: "")]
        }
        let pdfSize = (try? FileManager.default.attributesOfItem(atPath: pdfURL.path)[.size] as? Int) ?? 0
        let success = ok && pdfSize > 0
        let capacity = logContainsCapacityError(log)

        guard generation.load() == gen else {
            return nil   // superseded by a newer request — build dir is reused
        }

        if success {
            lock.lock()
            if let old = lastBuildDir, old != buildDir {
                try? FileManager.default.removeItem(at: old)
            }
            lastBuildDir = buildDir
            lock.unlock()
            if firstRun {
                firstRun = false
                UserDefaults.standard.set(true, forKey: Compiler.compiledBeforeKey)
            }
        }
        // On failure the persistent dir is deliberately kept: the engine's
        // .aux/.toc survive for the next attempt, which keeps reference-heavy
        // documents compiling incrementally even while they're broken.
        let engineTag = memoryOverride ? "\(engineName) +memory" : engineName
        let report = LatexReport(success: success,
                                 pdfURL: success ? pdfURL : nil,
                                 engineMessage: success ? "Rendered in \(elapsedMs) ms (\(engineTag))"
                                                        : "Compilation failed (\(engineTag)).",
                                 errors: errors,
                                 elapsedMs: elapsedMs,
                                 engineName: engineName,
                                 capacityError: capacity)
        DispatchQueue.main.async { [weak self] in
            self?.onFinished?(report)
        }
        return report
    }

    /// Run one `engine` pass over document.tex in the build directory.
    /// `draftMode` skips writing the PDF (faster for intermediate passes).
    /// Returns whether the engine exited cleanly and a PDF was produced, plus
    /// the captured stdout/stderr (for diagnosing wedged or dying runs).
    private func runSinglePass(engineURL: URL, buildDir: URL,
                               draftMode: Bool = false,
                               memoryOverride: Bool = false) -> (ok: Bool, output: String) {
        let process = Process()
        process.executableURL = engineURL
        process.currentDirectoryURL = buildDir
        // GUI apps never inherit the shell PATH — inject the TeX/Brew paths so
        // `-shell-escape` can find `asy` (and kpsewhich finds class files).
        process.environment = TeX.environment()

        var args = ["-interaction=nonstopmode",
                    "-halt-on-error",
                    "-file-line-error",
                    "-synctex=1"]
        // `-shell-escape` is only granted when the source actually uses it
        // (write18, Asymptote, runsystem) — the default otherwise stays off so
        // documents can't run arbitrary shell commands just by mentioning TeX.
        if needsShellEscape() { args.append("-shell-escape") }
        // A capacity error gets a second chance with much larger TeX pools.
        if memoryOverride {
            args += ["-extra-mem-top=4000000",
                     "-extra-mem-bot=4000000",
                     "-pool-size=8000000",
                     "-hash-size=30000",
                     "-max-strings=200000"]
        }
        if draftMode { args.append("-draftmode") }
        args.append("document.tex")
        process.arguments = args

        // Capture stdout/stderr through pipes so a failing engine leaves a
        // trail we can surface, and nothing blocks on the terminal.
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let io = DispatchQueue(label: "flashtex.engine.io", attributes: .concurrent)
        let ioGroup = DispatchGroup()
        var stdout = Data()
        var stderr = Data()
        ioGroup.enter()
        io.async {
            stdout = outPipe.fileHandleForReading.readDataToEndOfFile()
            ioGroup.leave()
        }
        ioGroup.enter()
        io.async {
            stderr = errPipe.fileHandleForReading.readDataToEndOfFile()
            ioGroup.leave()
        }

        lock.lock()
        currentProcess = process
        lock.unlock()

        let sema = DispatchSemaphore(value: 0)
        var exitCode: Int32 = -1
        var timedOut = false
        process.terminationHandler = { proc in
            exitCode = proc.terminationStatus
            sema.signal()
        }

        do {
            try process.run()
        } catch {
            lock.lock()
            if currentProcess === process { currentProcess = nil }
            lock.unlock()
            return (false, "")
        }

        // Watchdog — never let a runaway engine wedge the app. The very first
        // engine run rebuilds TeX's font/kpathsea caches and can legitimately
        // take minutes, so it gets a much longer leash than steady-state runs.
        let timeout: TimeInterval = firstRun ? 240 : 45
        let watchdog = DispatchWorkItem { [weak process] in
            guard let process else { return }
            if process.isRunning {
                timedOut = true
                process.terminate()
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout,
                                                       execute: watchdog)

        sema.wait()
        watchdog.cancel()
        ioGroup.wait()

        lock.lock()
        if currentProcess === process { currentProcess = nil }
        lock.unlock()

        let pdfURL = buildDir.appendingPathComponent("document.pdf")
        let pdfSize = (try? FileManager.default.attributesOfItem(atPath: pdfURL.path)[.size] as? Int) ?? 0
        let output = String(data: stdout.isEmpty ? stderr : stdout, encoding: .utf8) ?? ""
        // Draft passes never write the PDF by design, so they can't be judged
        // by its presence — only by the engine's exit code.
        let ok = exitCode == 0 && (draftMode || pdfSize > 0) && !timedOut
        return (ok, output)
    }

    /// Compile every `*.asy` file in the build dir with the `asy` binary, if
    /// both exist. Asymptote needs this extra pass before pdflatex can embed
    /// the generated figures; files are processed in parallel.
    private func runAsymptoteIfNeeded(buildDir: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: buildDir.path) else { return }
        let asyFiles = files.filter { $0.hasSuffix(".asy") }
        guard !asyFiles.isEmpty, let asyURL = TeX.findExecutable("asy") else { return }

        let group = DispatchGroup()
        let queue = DispatchQueue(label: "flashtex.asy", attributes: .concurrent)
        for file in asyFiles {
            group.enter()
            queue.async {
                defer { group.leave() }
                let process = Process()
                process.executableURL = asyURL
                process.currentDirectoryURL = buildDir
                process.environment = TeX.environment()
                process.arguments = [file]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    process.waitUntilExit()
                } catch {
                    // A failing asy run is surfaced through the next pdflatex pass.
                }
            }
        }
        group.wait()
    }

    /// True when an Asymptote pass happened during compilation: either .asy
    /// files were written to the build dir, or the log shows TeX shell-escaping
    /// out to `asy`. Such documents always need a second pdflatex pass so the
    /// generated figure PDFs actually make it into the preview.
    private func asyWasInvolved(buildDir: URL) -> Bool {
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(atPath: buildDir.path),
           files.contains(where: { $0.hasSuffix(".asy") }) {
            return true
        }
        let logURL = buildDir.appendingPathComponent("document.log")
        guard let log = try? String(contentsOf: logURL, encoding: .utf8) else { return false }
        let markers = ["asymptote", "Asymptote", "asy ", "Shell escape",
                       "Openout", "runsystem"]
        return markers.contains { log.contains($0) }
    }

    /// True when the source uses constructs that require extra engine passes.
    private func sourceNeedsMultiplePasses(_ source: String) -> Bool {
        let markers = ["\\label", "\\ref", "\\eqref", "\\pageref", "\\autoref",
                       "\\cite", "\\nocite", "\\tableofcontents", "\\listoffigures",
                       "\\listoftables", "\\begin{asy}", "\\index", "\\makeindex",
                       "\\printindex", "\\bibitem", "\\bibliography",
                       "\\printbibliography", "\\glossary", "\\printglossary"]
        return markers.contains { source.contains($0) }
    }

    /// A stable-enough fingerprint of the reference files (.aux/.toc/.lof/.lot/.out).
    /// Two consecutive passes with identical fingerprints share the same layout,
    /// so the third pass can be skipped.
    private func referenceHash(_ buildDir: URL) -> String {
        let names = ["document.aux", "document.toc", "document.lof",
                     "document.lot", "document.out"]
        var blob = ""
        for name in names {
            let url = buildDir.appendingPathComponent(name)
            if let data = try? Data(contentsOf: url),
               let text = String(data: data, encoding: .utf8) {
                blob += name + ":" + text + "\n"
            }
        }
        return blob.isEmpty ? "" : String(describing: blob.hashValue)
    }

    private func deliverFailure(_ message: String, gen: Int) {
        let report = LatexReport(success: false, pdfURL: nil, engineMessage: message,
                                 errors: [], elapsedMs: 0, engineName: engine,
                                 capacityError: false)
        guard generation.load() == gen else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onFinished?(report)
        }
    }

    // MARK: - Input sanitization & engine tuning

    /// Normalize hostile/legacy input before it reaches the engine: CRLF and
    /// lone CR become LF, a leading BOM is dropped, NUL bytes are removed
    /// (they'd silently truncate the file in C-string lands) and whitespace-only
    /// garbage is trimmed at the edges.
    private func sanitizeSource(_ source: String) -> String {
        var s = source.replacingOccurrences(of: "\r\n", with: "\n")
                      .replacingOccurrences(of: "\r", with: "\n")
                      .replacingOccurrences(of: "\0", with: "")
        if s.first == "\u{FEFF}" { s.removeFirst() }
        return s
    }

    /// True when the source asks the engine to execute external commands, in
    /// which case `-shell-escape` is granted. Everything else compiles with
    /// restricted \write18 — the safer default.
    private func needsShellEscape() -> Bool {
        guard let current = currentSource else { return false }
        let markers = ["\\write18", "\\begin{asy}", "runsystem", "\\immediate\\write18"]
        return markers.contains { current.contains($0) }
    }

    /// Memory/capacity failure signatures in the engine log — the trigger for
    /// the memory-override retry and the LuaTeX fallback.
    private func logContainsCapacityError(_ log: String) -> Bool {
        let signatures = ["TeX capacity exceeded", "Memory overflow",
                          "Not enough memory", "insufficient memory",
                          "No room for a new", "main memory"]
        return signatures.contains { log.contains($0) }
    }

    /// Remove leftover `flashtex-*` build directories from crashed sessions.
    /// Only stale ones (older than an hour) are touched so a build dir the
    /// preview is currently showing is never deleted out from under it.
    private func sweepStaleBuildDirs() {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory
        DispatchQueue.global(qos: .utility).async {
            guard let names = try? fm.contentsOfDirectory(atPath: temp.path) else { return }
            let cutoff = Date().addingTimeInterval(-3600)
            for name in names where name.hasPrefix("flashtex-") {
                let url = temp.appendingPathComponent(name)
                let created = (try? fm.attributesOfItem(atPath: url.path)[.creationDate] as? Date)
                    ?? Date.distantPast
                if created < cutoff {
                    try? fm.removeItem(at: url)
                }
            }
        }
    }

    // MARK: - Filesystem & engine discovery

    private func makeBuildDir() -> URL? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("flashtex-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        } catch {
            return nil
        }
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func engineExecutableURL(_ engineName: String) -> URL? {
        TeX.findExecutable(engineName)
    }

    // MARK: - Log parsing

    /// Lines that look like problems but are advisory (warnings, summaries).
    private func isNoiseLine(_ message: String) -> Bool {
        message.contains("Warning:") || message.contains("rerun to get")
            || message.contains("Rerun to get")
    }

    private func parseLog(_ log: String) -> [LatexIssue] {
        var issues: [LatexIssue] = []
        let lines = log.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        let lnumRe = try! NSRegularExpression(pattern: #"^\s*l[.:]?\s*(\d+)"#)
        let fileLineRe = try! NSRegularExpression(pattern: #"^[^\s]*\.tex:(\d+):\s*(.*)$"#)

        var current: LatexIssue?
        var inBlock = false
        var expectSource = false

        func flush() {
            if inBlock, let c = current, !c.message.isEmpty || c.line >= 0 {
                issues.append(c)
            }
            current = nil
            inBlock = false
            expectSource = false
        }

        for raw in lines {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            let ns = t as NSString

            if t.hasPrefix("!") {
                flush()
                inBlock = true
                current = LatexIssue(line: -1,
                                     message: String(t.dropFirst()).trimmingCharacters(in: .whitespaces),
                                     context: "", hint: "")
                continue
            }

            if !inBlock {
                if let m = fileLineRe.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)) {
                    let line = Int(ns.substring(with: m.range(at: 1))) ?? -1
                    let msg = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
                    // Advisory warnings aren't compile errors — drop them so the
                    // error list stays focused on things that actually fail.
                    if isNoiseLine(msg) { continue }
                    issues.append(LatexIssue(line: line, message: msg, context: "", hint: ""))
                }
                continue
            }

            if var c = current {
                if c.line < 0,
                   let m = lnumRe.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)) {
                    c.line = Int(ns.substring(with: m.range(at: 1))) ?? -1
                    c.hint = t
                    expectSource = true
                    current = c
                    continue
                }
                if let m = fileLineRe.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)) {
                    if c.line < 0 {
                        c.line = Int(ns.substring(with: m.range(at: 1))) ?? -1
                        c.message = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
                    }
                    expectSource = true
                    current = c
                    continue
                }
                if expectSource && c.context.isEmpty && !t.hasPrefix("...") && !t.contains("Context:") {
                    c.context = t
                    expectSource = false
                    current = c
                }
            }
        }
        flush()
        return issues
    }
}

/// Minimal thread-safe integer used for compile generation tracking.
private final class AtomicInt {
    private let lock = NSLock()
    private var value: Int
    init(_ initial: Int) { value = initial }

    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }

    func load() -> Int {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}
