import AppKit
import UniformTypeIdentifiers
import PDFKit
#if canImport(FlashTeXCore)
import FlashTeXCore
#endif

// MainWindowController — the app shell.
//
// Owns the split layout (editor | preview), the compile worker, the toolbar,
// the native menu bar, the error viewer and Flash Mode. Everything is wired
// here.

final class MainWindowController: NSWindowController {

    private let editor = EditorTextView.makeEditor()
    private let preview = PreviewView()
    private let compiler = Compiler()
    private let proximity = ProximityRenderer()
    private let highlighter = LaTeXSyntaxHighlighter()
    private let scrollView = NSScrollView()

    private var splitVC: NSSplitViewController!
    private var previewItem: NSSplitViewItem!
    private var outlineItem: NSSplitViewItem?
    private var outlineVC: OutlineViewController?

    private var currentFileURL: URL?
    private var autoCompile = true
    private var isLoading = false
    private var lastPdfURL: URL?
    private var currentErrors: [LatexIssue] = []
    private var scrollObserver: NSObjectProtocol?
    private var settingsObserver: NSObjectProtocol?
    private var errorSheet: NSWindow?
    private var flashController: FlashWindowController?
    private var isCompiling = false
    private var compilingDelay: Timer?
    private var compileStart: Date?
    /// Source line at the top of the editor when an auto-compile began, used to
    /// restore the preview viewport around the edit after the recompile.
    private var pendingAnchor: Int?

    private weak var enginePopup: NSPopUpButton?
    private weak var autoSwitch: NSSwitch?
    private var gutterView: GutterView?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1360, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "FlashTeX"
        window.minSize = NSSize(width: 900, height: 560)
        super.init(window: window)

        window.delegate = self
        buildUI()
        buildToolbar()
        applyToolbarState()
        wireCompiler()
        loadWelcomeDocument()
        window.initialFirstResponder = editor
        window.makeFirstResponder(editor)

        // Default to a full-screen-sized window on launch.
        window.setFrame(window.screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900),
                       display: true)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - UI assembly

    private func buildUI() {
        splitVC = NSSplitViewController()
        splitVC.splitView.autosaveName = "FlashTeX.Split"

        let outline = OutlineViewController()
        let outlineItem = NSSplitViewItem(sidebarWithViewController: outline)
        outlineItem.minimumThickness = 160
        outlineItem.maximumThickness = 320
        outlineItem.canCollapse = true
        outlineItem.isCollapsed = true
        outlineItem.holdingPriority = .defaultHigh
        self.outlineItem = outlineItem
        self.outlineVC = outline

        let editorItem = NSSplitViewItem(viewController: makeEditorViewController())
        editorItem.minimumThickness = 300
        let previewItem = NSSplitViewItem(viewController: makePreviewViewController())
        previewItem.minimumThickness = 240
        self.previewItem = previewItem

        // Equal holding priorities make both panes scale with the window, so
        // maximizing (or full-screening) keeps the editor/preview ratio instead
        // of blowing the preview up to fill everything.
        editorItem.holdingPriority = .defaultLow
        previewItem.holdingPriority = .defaultLow

        splitVC.addSplitViewItem(outlineItem)
        splitVC.addSplitViewItem(editorItem)
        splitVC.addSplitViewItem(previewItem)
        splitVC.splitView.setPosition(560, ofDividerAt: 1)

        // Root container = split view filling the window. Compile status is
        // surfaced through the toolbar progress item, not a bottom bar.
        let rootVC = NSViewController()
        let container = NSView()
        rootVC.view = container
        rootVC.addChild(splitVC)
        splitVC.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(splitVC.view)
        NSLayoutConstraint.activate([
            splitVC.view.topAnchor.constraint(equalTo: container.topAnchor),
            splitVC.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            splitVC.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            splitVC.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        window?.contentViewController = rootVC
    }

    private func makeEditorViewController() -> NSViewController {
        let vc = EditorViewController()
        let container = NSView()

        scrollView.documentView = editor
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        // The line-number strip is a dedicated view so its drawing is never
        // clipped by the text view's layer (see GutterView).
        gutterView = GutterView(editor: editor, scrollView: scrollView)
        editor.onGutterRefresh = { [weak self] in
            self?.gutterView?.refresh()
        }

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // Re-apply the cached highlight tokens as the editor scrolls.
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main) { [weak self] _ in
                guard let self else { return }
                self.highlighter.scrollChanged(editor: self.editor,
                                               scrollView: self.scrollView)
            }

        // Settings changes re-tint the editor's syntax colours (the editor
        // itself re-applies fonts/geometry via its own observer).
        settingsObserver = NotificationCenter.default.addObserver(
            forName: SettingsStore.changedNotification,
            object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.highlighter.rehighlightNow(editor: self.editor,
                                                scrollView: self.scrollView)
            }

        vc.view = container
        vc.onLayout = { [weak self] in
            guard let self else { return }
            self.syncEditorGeometry()
            // First layout has no visible-range highlight yet — apply it now.
            self.highlighter.scrollChanged(editor: self.editor,
                                           scrollView: self.scrollView)
        }
        return vc
    }

    private func makePreviewViewController() -> NSViewController {
        let vc = NSViewController()
        vc.view = preview
        return vc
    }

    private func syncEditorGeometry() {
        let width = max(200, scrollView.contentSize.width)
        if editor.frame.width != width {
            editor.frame.size.width = width
        }
        editor.minSize = NSSize(width: 0, height: max(0, scrollView.contentSize.height))
        editor.updateGutter()
    }

    private func buildToolbar() {
        let toolbar = NSToolbar(identifier: "FlashTeX.Toolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = true
        window?.toolbar = toolbar
    }

    // MARK: - Toolbar minimize (Safari-style)

    /// Collapsed toolbar = a bare title bar with the document title centred;
    /// expanded = the full icon toolbar. Toggled via the View menu (⌥⌘T).
    private var isToolbarMinimized: Bool {
        get { UserDefaults.standard.bool(forKey: "FlashTeX.ToolbarMinimized") }
        set { UserDefaults.standard.set(newValue, forKey: "FlashTeX.ToolbarMinimized") }
    }

    @objc func toggleToolbar(_ sender: Any?) {
        isToolbarMinimized.toggle()
        applyToolbarState()
    }

    @objc func customizeToolbar(_ sender: Any?) {
        window?.toolbar?.runCustomizationPalette(nil)
    }

    private func applyToolbarState() {
        if isToolbarMinimized {
            // Bare title bar — the toolbar (and its icons) disappears, leaving
            // just the document title and the traffic lights.
            window?.toolbar = nil
        } else {
            if window?.toolbar == nil { buildToolbar() }
        }
    }

    // MARK: - Compiler wiring

    private func wireCompiler() {
        editor.onTextChanged = { [weak self] in
            guard let self = self else { return }
            self.window?.isDocumentEdited = true
            self.highlighter.scheduleRehighlight(editor: self.editor,
                                                 scrollView: self.scrollView)
            if !(self.outlineItem?.isCollapsed ?? true) {
                self.refreshOutline()
            }
            guard self.autoCompile else { return }
            let source = self.editor.string
            // The invalidation engine classifies the edit:
            //   LOCAL  — inside one safe display-math block → isolated render
            //            (vector patch) instead of a full compile.
            //   REGIONAL / GLOBAL — full compile; REGIONAL additionally anchors
            //            the preview viewport on the edit.
            let decision = self.proximity.engine.classify(
                editRange: self.editor.lastEditRange, source: source,
                isBalanced: LatexStructure.isBalanced(source))
            self.proximity.metrics.recordDecision(decision.scope,
                                                  reasons: decision.reasons)
            switch decision.scope {
            case .local(let block):
                self.compiler.cancelScheduledCompile()
                self.proximity.scheduleLocalRender(block: block, source: source,
                                                   engineName: self.compiler.engine)
            case .regional:
                self.proximity.invalidatePendingLocal()
                self.pendingAnchor = self.editor.visibleTopLine
                self.compiler.scheduleCompile(source: source)
            case .global:
                self.proximity.invalidatePendingLocal()
                self.compiler.scheduleCompile(source: source)
            }
        }

        editor.onFontSizeChanged = { [weak self] in
            self?.applyEditorFont()
        }

        compiler.onStatusStarted = { [weak self] in
            self?.beginCompilingIndicator()
            // A full compile supersedes any pending local render.
            self?.proximity.invalidatePendingLocal()
            self?.compileStart = Date()
        }

        compiler.onFinished = { [weak self] report in
            self?.handleCompileFinished(report)
        }

        proximity.onApplyPatch = { [weak self] page, rect, pdf in
            self?.preview.applyPatch(page: page, bounds: rect, pdf: pdf)
        }

        proximity.onFallbackToFullCompile = { [weak self] source in
            self?.compiler.scheduleCompile(source: source)
        }
    }

    private func applyEditorFont() {
        editor.font = Theme.editorFont
        editor.updateGutter()
        highlighter.rehighlightNow(editor: editor, scrollView: scrollView)
    }

    private func handleCompileFinished(_ report: LatexReport) {
        endCompilingIndicator()
        if report.engineName != compiler.engine {
            notifyFallback(requested: compiler.engine, used: report.engineName)
        }
        if report.success, let pdfURL = report.pdfURL {
            lastPdfURL = pdfURL
            currentErrors = []
            editor.updateDiagnostics([])
            preview.load(pdfURL: pdfURL)
            // Rebuild the block → region map from the new synctex data so the
            // next local edit knows where to patch.
            proximity.remap(pdfURL: pdfURL, document: preview.document,
                            source: editor.string)
            // Record the new dependency baseline and bump the version guard.
            let duration = compileStart.map { Date().timeIntervalSince($0) } ?? 0
            proximity.noteFullCompile(source: editor.string, duration: duration)
            // A regional compile re-anchors the preview on the edited region
            // (the whole page re-laid-out; the anchor keeps the region in view).
            if let anchor = pendingAnchor,
               let target = proximity.anchorTarget(afterLine: anchor,
                                                   source: editor.string) {
                preview.reveal(page: target.page, rect: target.rect)
            }
            pendingAnchor = nil
            removeErrorToolbarItem()
            return
        }

        currentErrors = report.errors
        // Feed the errors into the editor so problem lines get their dotted
        // underline and the inline error popover is shown at the error line.
        editor.updateDiagnostics(currentErrors)
        insertErrorToolbarItem()
        if currentErrors.isEmpty && !report.engineMessage.isEmpty {
            // A setup-level failure (e.g. engine not installed): surface the
            // guidance through the error viewer instead of a bare status text.
            currentErrors = [LatexIssue(line: -1, message: report.engineMessage,
                                        context: "", hint: "")]
            insertErrorToolbarItem()
            return
        }
    }

    /// Surface a silent engine fallback (e.g. tectonic → lualatex) once, unless
    /// the user checked "don't show again".
    private func notifyFallback(requested: String, used: String) {
        guard !SettingsStore.shared.suppressFallbackNotice else { return }
        let alert = NSAlert()
        alert.messageText = "Fell back to \(used)"
        alert.informativeText = "Compiling with \(requested) hit a limit (usually TeX "
            + "memory), so FlashTeX used \(used) instead. The result may differ slightly."
        let checkbox = NSButton(checkboxWithTitle: "Don't show again", target: nil, action: nil)
        alert.accessoryView = checkbox
        alert.addButton(withTitle: "OK")
        if let window {
            alert.beginSheetModal(for: window) { [weak self] _ in
                if checkbox.state == .on {
                    SettingsStore.shared.suppressFallbackNotice = true
                }
                self?.window?.makeFirstResponder(self?.editor)
            }
        } else {
            if alert.runModal() == .alertFirstButtonReturn, checkbox.state == .on {
                SettingsStore.shared.suppressFallbackNotice = true
            }
        }
    }

    // MARK: - Error viewer

    @objc func showErrorSheet() {
        guard !currentErrors.isEmpty, let window else { return }

        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 360),
                             styleMask: [.titled, .closable, .resizable],
                             backing: .buffered, defer: false)
        sheet.title = "Compile Errors"
        sheet.minSize = NSSize(width: 520, height: 220)

        let table = NSTableView()
        table.delegate = self
        table.dataSource = self
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 20
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.doubleAction = #selector(errorRowDoubleClicked(_:))

        func column(_ id: String, title: String, width: CGFloat) -> NSTableColumn {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title
            c.width = width
            return c
        }
        table.addTableColumn(column("line", title: "Line", width: 56))
        table.addTableColumn(column("msg", title: "Error", width: 440))
        table.addTableColumn(column("ctx", title: "Context", width: 160))

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = table
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let copyButton = NSButton(title: "Copy", target: self, action: #selector(copyErrorList(_:)))
        let jumpButton = NSButton(title: "Jump to First Error", target: self,
                                  action: #selector(jumpToFirstError(_:)))
        let closeButton = NSButton(title: "Close", target: self, action: #selector(closeErrorSheet(_:)))
        closeButton.keyEquivalent = "\r"
        let row = NSStackView(views: [copyButton, jumpButton, closeButton])
        row.orientation = .horizontal
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(scroll)
        content.addSubview(row)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            scroll.bottomAnchor.constraint(equalTo: row.topAnchor, constant: -12),
            row.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            row.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
        sheet.contentView = content

        errorSheet = sheet
        window.beginSheet(sheet)
    }

    @objc private func closeErrorSheet(_ sender: Any?) {
        if let sheet = errorSheet, let window {
            window.endSheet(sheet)
            errorSheet = nil
        }
    }

    @objc private func errorRowDoubleClicked(_ sender: NSTableView) {
        let row = sender.clickedRow
        guard row >= 0, row < currentErrors.count else { return }
        jumpToErrorLine(currentErrors[row].line)
    }

    @objc private func jumpToFirstError(_ sender: Any?) {
        if let first = currentErrors.first { jumpToErrorLine(first.line) }
    }

    private func jumpToErrorLine(_ line: Int) {
        if let sheet = errorSheet, let window {
            window.endSheet(sheet)
            errorSheet = nil
        }
        guard line > 0 else { return }
        editor.scrollToLine(line)
        window?.makeFirstResponder(editor)
    }

    @objc private func copyErrorList(_ sender: Any?) {
        let text = currentErrors.map { issue -> String in
            var s = issue.line > 0 ? "Line \(issue.line): " : ""
            s += issue.message
            if !issue.context.isEmpty { s += "  [\(issue.context)]" }
            return s
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Flash Mode

    @objc func toggleFlashMode() {
        if let fc = flashController {
            fc.close()
            return
        }

        showMainWindow()
        let fc = FlashWindowController()
        flashController = fc
        fc.showWindow(nil)
        fc.window?.makeKeyAndOrderFront(nil)
        fc.focusEditor()
    }

    private func showMainWindow() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Documents

    private func loadWelcomeDocument() {
        isLoading = true
        editor.string = Theme.welcomeDocument
        isLoading = false
        editor.updateGutter()
        highlighter.rehighlightNow(editor: editor, scrollView: scrollView)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self = self else { return }
            self.compiler.compileNow(source: self.editor.string)
        }
    }

    @objc func newDocument() {
        guard confirmDiscardIfNeeded() else { return }
        isLoading = true
        editor.string = Theme.welcomeDocument
        isLoading = false
        currentFileURL = nil
        lastPdfURL = nil
        window?.representedURL = nil
        window?.isDocumentEdited = false
        window?.title = "FlashTeX"
        editor.updateGutter()
        highlighter.rehighlightNow(editor: editor, scrollView: scrollView)
        proximity.reset()
        pendingAnchor = nil
        preview.removePatches()
        compiler.resetIncrementalState()
        compiler.compileNow(source: editor.string)
    }

    @objc func openDocument() {
        guard confirmDiscardIfNeeded() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "tex") ?? .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            isLoading = true
            editor.string = content
            isLoading = false
            currentFileURL = url
            window?.representedURL = url
            window?.isDocumentEdited = false
            window?.title = url.lastPathComponent
            editor.updateGutter()
            highlighter.rehighlightNow(editor: editor, scrollView: scrollView)
            proximity.reset()
            pendingAnchor = nil
            preview.removePatches()
            compiler.resetIncrementalState()
            compiler.compileNow(source: editor.string)
        } catch {
            presentError(NSError(domain: "FlashTeX", code: 1,
                                 userInfo: [NSLocalizedDescriptionKey: "Could not open \(url.lastPathComponent)."]))
        }
    }

    @objc func showCommandPalette(_ sender: Any?) {
        CommandPaletteWindowController.show(onEditor: editor)
    }

    @discardableResult
    @objc func saveDocument() -> Bool {
        if let url = currentFileURL {
            do {
                try editor.string.write(to: url, atomically: true, encoding: .utf8)
                window?.isDocumentEdited = false
                return true
            } catch {
                presentError(NSError(domain: "FlashTeX", code: 2,
                                     userInfo: [NSLocalizedDescriptionKey: "Could not write \(url.lastPathComponent)."]))
                return false
            }
        }
        return saveDocumentAs()
    }

    @discardableResult
    @objc func saveDocumentAs() -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "tex") ?? .plainText]
        panel.nameFieldStringValue = currentFileURL?.lastPathComponent ?? "untitled.tex"
        guard panel.runModal() == .OK, let url = panel.url else { return false }

        do {
            try editor.string.write(to: url, atomically: true, encoding: .utf8)
            currentFileURL = url
            window?.representedURL = url
            window?.isDocumentEdited = false
            window?.title = url.lastPathComponent
            return true
        } catch {
            presentError(NSError(domain: "FlashTeX", code: 3,
                                 userInfo: [NSLocalizedDescriptionKey: "Could not write \(url.lastPathComponent)."]))
            return false
        }
    }

    @objc func exportPDF() {
        guard let url = lastPdfURL else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        let base = currentFileURL?.deletingPathExtension().lastPathComponent ?? "document"
        panel.nameFieldStringValue = "\(base).pdf"
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let dest = panel.url else { return }

        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: url, to: dest)
        } catch {
            presentError(NSError(domain: "FlashTeX", code: 4,
                                 userInfo: [NSLocalizedDescriptionKey: "Could not export the PDF."]))
        }
    }

    // MARK: - PNG / SVG export

    @objc func exportPNG() {
        exportPages(extension: "png") { [weak self] page in
            self?.renderPagePNG(page, scale: 300.0 / 72.0)
        }
    }

    /// Vector SVG export via poppler's `pdftocairo`. pdftocairo writes a
    /// single SVG file (multi-page documents carry one `<page>` per sheet), so
    /// this is always one destination file.
    @objc func exportSVG() {
        guard let src = lastPdfURL else { return }
        guard let tool = TeX.findExecutable("pdftocairo") else {
            presentError(NSError(domain: "FlashTeX", code: 11,
                                 userInfo: [NSLocalizedDescriptionKey:
                                    "Vector SVG export needs pdftocairo from poppler. Install it, e.g. `brew install poppler` or `sudo port install poppler`, then relaunch FlashTeX."]))
            return
        }
        let base = currentFileURL?.deletingPathExtension().lastPathComponent ?? "document"
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.svg]
        panel.nameFieldStringValue = "\(base).svg"
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let dest = panel.url else { return }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlashTeX-SVG-\(UUID().uuidString)")
        let proc = Process()
        proc.executableURL = tool
        proc.arguments = ["-svg", "-q", src.path, tmp.path]
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            presentError(NSError(domain: "FlashTeX", code: 12,
                                 userInfo: [NSLocalizedDescriptionKey: "Could not launch pdftocairo."]))
            return
        }
        guard proc.terminationStatus == 0, FileManager.default.fileExists(atPath: tmp.path) else {
            presentError(NSError(domain: "FlashTeX", code: 13,
                                 userInfo: [NSLocalizedDescriptionKey: "pdftocairo could not convert the PDF to SVG."]))
            return
        }
        do {
            try FileManager.default.copyItem(at: tmp, to: dest)
        } catch {
            presentError(NSError(domain: "FlashTeX", code: 14,
                                 userInfo: [NSLocalizedDescriptionKey: "Could not write the SVG file."]))
        }
        try? FileManager.default.removeItem(at: tmp)
    }

    /// Shared export flow: a single-page document writes one file to the chosen
    /// URL; a multi-page document writes `base-1.ext, base-2.ext, …` into the
    /// chosen folder and reveals it in the Finder.
    private func exportPages(extension ext: String, renderer: (PDFPage) -> Data?) {
        guard let doc = preview.pdfView.document, doc.pageCount > 0 else { return }
        let base = currentFileURL?.deletingPathExtension().lastPathComponent ?? "document"
        let single = doc.pageCount == 1

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .data]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = single ? "\(base).\(ext)" : "\(base)-pages"
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let dest = panel.url else { return }

        var written: [URL] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i), let data = renderer(page) else { continue }
            let url: URL
            if single {
                url = dest
            } else {
                let dir = dest.pathExtension.isEmpty ? dest : dest.deletingPathExtension()
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                url = dir.appendingPathComponent("\(base)-\(i + 1).\(ext)")
            }
            do {
                try data.write(to: url, options: .atomic)
                written.append(url)
            } catch {
                presentError(NSError(domain: "FlashTeX", code: 10,
                                     userInfo: [NSLocalizedDescriptionKey:
                                        "Could not write \(url.lastPathComponent)."]))
            }
        }
        if !single && !written.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(written)
        }
    }

    /// Rasterize one PDF page at `scale` (72pt-based; e.g. 300/72 ≈ 417% for a
    /// crisp print-quality PNG) into upright PNG data.
    private func renderPagePNG(_ page: PDFPage, scale: CGFloat) -> Data? {
        let bounds = page.bounds(for: .mediaBox)
        let w = Int((bounds.width * scale).rounded())
        let h = Int((bounds.height * scale).rounded())
        guard w > 0, h > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: w, pixelsHigh: h,
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let cg = ctx.cgContext
        cg.setFillColor(NSColor.white.cgColor)
        cg.fill(CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        // Flip into top-down page space so the saved image is upright.
        cg.translateBy(x: 0, y: CGFloat(h))
        cg.scaleBy(x: scale, y: -scale)
        cg.interpolationQuality = .high
        page.draw(with: .mediaBox, to: cg)
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - Completion personalization

    @objc func resetCompletionLearning(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Reset completion learning?"
        alert.informativeText = "FlashTeX quietly learns which completions you pick most and orders the autocomplete list accordingly. This clears that history and restores plain alphabetical ordering."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        CompletionUsageTracker.shared.reset()
    }

    private func confirmDiscardIfNeeded() -> Bool {
        guard window?.isDocumentEdited == true else { return true }
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes you made to this document?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don’t Save")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        switch alert.runModal() {
        case .alertFirstButtonReturn:  return saveDocument()
        case .alertSecondButtonReturn: return true
        default:                       return false
        }
    }

    // MARK: - Compile actions

    @objc func compileNow() {
        compiler.compileNow(source: editor.string)
    }

    @objc func stopCompilation(_ sender: Any?) {
        guard isCompiling else { return }
        compiler.stopCompiling()
        endCompilingIndicator()
    }

    /// Live counts for the incremental preview subsystem (classifications,
    /// cache behaviour, render timings, promotion reasons).
    @objc func showIncrementalStats() {
        let alert = NSAlert()
        alert.messageText = "Incremental Preview Statistics"
        alert.informativeText = proximity.metrics.summary()
        alert.addButton(withTitle: "OK")
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    @objc func toggleAutoCompile() {
        autoCompile.toggle()
        autoSwitch?.state = autoCompile ? .on : .off
        if autoCompile {
            compiler.compileNow(source: editor.string)
        }
    }

    @objc func chooseEngine(_ sender: NSMenuItem) {
        guard !isCompiling, let name = sender.representedObject as? String else { return }
        compiler.engine = name
        enginePopup?.selectItem(withTitle: name)
    }

    @objc func enginePopupChanged(_ sender: NSPopUpButton) {
        guard !isCompiling, let name = sender.titleOfSelectedItem else { return }
        compiler.engine = name
    }

    @objc func autoSwitchChanged(_ sender: NSSwitch) {
        autoCompile = (sender.state == .on)
        if autoCompile {
            compiler.compileNow(source: editor.string)
        }
    }

    @objc func togglePreview() {
        previewItem.isCollapsed.toggle()
    }

    // MARK: - Document outline

    @objc func toggleOutline() {
        guard let outlineItem else { return }
        outlineItem.isCollapsed.toggle()
        if !outlineItem.isCollapsed {
            refreshOutline()
            window?.makeFirstResponder(editor)
        }
    }

    private func refreshOutline() {
        let entries = DocumentOutline.parse(editor.string)
        outlineVC?.update(entries: entries) { [weak self] entry in
            self?.jumpToOutlineEntry(entry)
        }
    }

    private func jumpToOutlineEntry(_ entry: OutlineEntry) {
        editor.scrollToLine(entry.line)
        window?.makeFirstResponder(editor)
    }

    // MARK: - Editor font zoom

    /// Responder-chain fallbacks: these only fire when the editor itself isn't
    /// the first responder (e.g. the preview has focus). Otherwise the editor
    /// view's own `zoomIn:`/`zoomOut:`/`resetZoom:` handles the shortcut.
    @objc func zoomIn(_ sender: Any?) { adjustEditorFont(by: 1) }
    @objc func zoomOut(_ sender: Any?) { adjustEditorFont(by: -1) }
    @objc func resetZoom(_ sender: Any?) {
        Theme.editorFontSize = 13
        applyEditorFont()
    }

    private func adjustEditorFont(by delta: CGFloat) {
        Theme.editorFontSize = min(28, max(10, Theme.editorFontSize + delta))
        applyEditorFont()
    }

    // MARK: - PDF actions

    @objc func openPdfInPreview() {
        guard let url = lastPdfURL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc func revealPdfInFinder() {
        guard let url = lastPdfURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Preview zoom

    @objc func zoomPreviewIn() { preview.zoomIn() }
    @objc func zoomPreviewOut() { preview.zoomOut() }
    @objc func fitPreviewWidth() { preview.fitWidth() }
    @objc func resetPreviewZoom() { preview.resetZoom() }

    // MARK: - Compiling indicator

    /// Show the spinner in the toolbar after a short grace period so fast
    /// compiles never flash it — it only appears "when necessary".
    private func beginCompilingIndicator() {
        isCompiling = true
        enginePopup?.isEnabled = false
        compilingDelay?.invalidate()
        let t = Timer(timeInterval: 0.25, repeats: false) { [weak self] _ in
            guard let self = self, self.isCompiling else { return }
            self.insertProgressItem()
            self.insertStopItem()
        }
        compilingDelay = t
        // `.common` so the spinner still appears while the run loop is busy
        // tracking an event (typing, scroll tracking).
        RunLoop.main.add(t, forMode: .common)
    }

    private func endCompilingIndicator() {
        isCompiling = false
        enginePopup?.isEnabled = true
        compilingDelay?.invalidate()
        compilingDelay = nil
        removeProgressItem()
        removeStopItem()
    }

    // MARK: - Shutdown

    func shutdown() {
        compiler.shutdown()
        highlighter.shutdown()
        if let scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
        }
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
        flashController?.shutdown()
    }
}

// MARK: - Toolbar dynamic items

extension MainWindowController {

    private func insertProgressItem() {
        guard let toolbar = window?.toolbar else { return }
        guard !toolbar.items.contains(where: { $0.itemIdentifier == ToolbarID.progress }) else { return }
        toolbar.insertItem(withItemIdentifier: ToolbarID.progress, at: 1)
    }

    private func removeProgressItem() {
        guard let toolbar = window?.toolbar else { return }
        if let idx = toolbar.items.firstIndex(where: { $0.itemIdentifier == ToolbarID.progress }) {
            toolbar.removeItem(at: idx)
        }
    }

    private func insertStopItem() {
        guard let toolbar = window?.toolbar else { return }
        guard !toolbar.items.contains(where: { $0.itemIdentifier == ToolbarID.stop }) else { return }
        toolbar.insertItem(withItemIdentifier: ToolbarID.stop, at: 2)
    }

    private func removeStopItem() {
        guard let toolbar = window?.toolbar else { return }
        if let idx = toolbar.items.firstIndex(where: { $0.itemIdentifier == ToolbarID.stop }) {
            toolbar.removeItem(at: idx)
        }
    }

    private func insertErrorToolbarItem() {
        guard let toolbar = window?.toolbar, !currentErrors.isEmpty else { return }
        guard !toolbar.items.contains(where: { $0.itemIdentifier == ToolbarID.errors }) else { return }
        toolbar.insertItem(withItemIdentifier: ToolbarID.errors, at: 4)
    }

    private func removeErrorToolbarItem() {
        guard let toolbar = window?.toolbar else { return }
        if let idx = toolbar.items.firstIndex(where: { $0.itemIdentifier == ToolbarID.errors }) {
            toolbar.removeItem(at: idx)
        }
    }
}

// MARK: - NSToolbarDelegate

extension MainWindowController: NSToolbarDelegate {

    private enum ToolbarID {
        static let compile = NSToolbarItem.Identifier("FlashTeX.Compile")
        static let progress = NSToolbarItem.Identifier("FlashTeX.Compiling")
        static let stop = NSToolbarItem.Identifier("FlashTeX.Stop")
        static let engine = NSToolbarItem.Identifier("FlashTeX.Engine")
        static let auto = NSToolbarItem.Identifier("FlashTeX.AutoCompile")
        static let flash = NSToolbarItem.Identifier("FlashTeX.Flash")
        static let errors = NSToolbarItem.Identifier("FlashTeX.Errors")
        static let preview = NSToolbarItem.Identifier("FlashTeX.TogglePreview")
        static let zoomOut = NSToolbarItem.Identifier("FlashTeX.ZoomOut")
        static let zoomIn = NSToolbarItem.Identifier("FlashTeX.ZoomIn")
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ToolbarID.compile, ToolbarID.progress, ToolbarID.engine, ToolbarID.auto,
         ToolbarID.flash, ToolbarID.errors, .flexibleSpace, ToolbarID.preview,
         ToolbarID.zoomOut, ToolbarID.zoomIn]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ToolbarID.compile, ToolbarID.engine, ToolbarID.auto, ToolbarID.flash,
         .flexibleSpace, ToolbarID.preview, ToolbarID.zoomOut, ToolbarID.zoomIn]
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case ToolbarID.compile:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Compile"
            item.image = NSImage(systemSymbolName: "arrow.clockwise.circle",
                                 accessibilityDescription: "Compile")
            item.target = self
            item.action = #selector(compileNow)
            return item

        case ToolbarID.progress:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Compiling"
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.startAnimation(nil)
            item.view = spinner
            return item

        case ToolbarID.stop:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Stop"
            item.image = NSImage(systemSymbolName: "stop.fill",
                                 accessibilityDescription: "Stop compilation")
            item.target = self
            item.action = #selector(stopCompilation(_:))
            return item

        case ToolbarID.engine:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Engine"
            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 130, height: 26),
                                      pullsDown: false)
            popup.addItems(withTitles: ["pdflatex", "xelatex", "lualatex", "tectonic"])
            popup.selectItem(withTitle: compiler.engine)
            popup.target = self
            popup.action = #selector(enginePopupChanged(_:))
            item.view = popup
            enginePopup = popup
            return item

        case ToolbarID.auto:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Auto-Compile"
            let switchView = NSSwitch()
            switchView.state = autoCompile ? .on : .off
            switchView.target = self
            switchView.action = #selector(autoSwitchChanged(_:))
            item.view = switchView
            autoSwitch = switchView
            return item

        case ToolbarID.flash:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Flash"
            item.image = NSImage(systemSymbolName: "bolt.fill",
                                 accessibilityDescription: "Flash Mode")
            item.target = self
            item.action = #selector(toggleFlashMode)
            return item

        case ToolbarID.errors:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Errors"
            item.target = self
            item.action = #selector(showErrorSheet)
            if let image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                   accessibilityDescription: "Compile errors"),
               let tinted = image.withSymbolConfiguration(
                   .init(paletteColors: [.systemRed])) {
                item.image = tinted
            }
            return item

        case ToolbarID.preview:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Preview"
            item.image = NSImage(systemSymbolName: "doc.richtext",
                                 accessibilityDescription: "Toggle PDF preview")
            item.target = self
            item.action = #selector(togglePreview)
            return item

        case ToolbarID.zoomIn:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Zoom In"
            item.image = NSImage(systemSymbolName: "plus.magnifyingglass",
                                 accessibilityDescription: "Zoom in preview")
            item.target = self
            item.action = #selector(zoomPreviewIn)
            return item

        case ToolbarID.zoomOut:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Zoom Out"
            item.image = NSImage(systemSymbolName: "minus.magnifyingglass",
                                 accessibilityDescription: "Zoom out preview")
            item.target = self
            item.action = #selector(zoomPreviewOut)
            return item

        default:
            return nil
        }
    }
}

// MARK: - Menu validation

extension MainWindowController: NSMenuItemValidation {

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleAutoCompile):
            menuItem.state = autoCompile ? .on : .off
            return true
        case #selector(chooseEngine(_:)):
            menuItem.state = (menuItem.representedObject as? String == compiler.engine) ? .on : .off
            return !isCompiling
        case #selector(stopCompilation(_:)):
            return isCompiling
        case #selector(togglePreview):
            menuItem.state = previewItem?.isCollapsed == false ? .on : .off
            return true
        case #selector(toggleOutline):
            menuItem.state = outlineItem?.isCollapsed == false ? .on : .off
            return true
        case #selector(toggleFlashMode):
            menuItem.state = flashController != nil ? .on : .off
            return true
        case #selector(toggleToolbar(_:)):
            menuItem.state = isToolbarMinimized ? .on : .off
            return true
        case #selector(exportPDF), #selector(exportPNG), #selector(exportSVG),
             #selector(revealPdfInFinder):
            return lastPdfURL != nil
        case #selector(openPdfInPreview):
            return lastPdfURL != nil
        case #selector(showErrorSheet):
            return !currentErrors.isEmpty
        case #selector(saveDocument), #selector(saveDocumentAs):
            return true
        default:
            return true
        }
    }
}

// MARK: - Error sheet data source

extension MainWindowController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        currentErrors.count
    }
}

extension MainWindowController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, row < currentErrors.count else { return nil }
        let id = tableColumn.identifier
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTextField
            ?? NSTextField(labelWithString: "")
        if cell.identifier == nil {
            cell.identifier = id
            cell.font = Theme.gutterFont
            cell.lineBreakMode = .byTruncatingTail
        }
        let issue = currentErrors[row]
        switch id.rawValue {
        case "line":
            cell.stringValue = issue.line > 0 ? "\(issue.line)" : "—"
            cell.alignment = .right
        case "msg":
            cell.stringValue = issue.message
            cell.alignment = .left
        default:
            cell.stringValue = issue.context
            cell.alignment = .left
        }
        return cell
    }
}

// MARK: - Window delegate

extension MainWindowController: NSWindowDelegate {

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        confirmDiscardIfNeeded()
    }

    func windowWillClose(_ notification: Notification) {
        guard let win = notification.object as? NSWindow else { return }
        if let fc = flashController, win === fc.window {
            flashController = nil
            if !editor.string.isEmpty {
                compiler.compileNow(source: editor.string)
            }
        }
    }
}

// MARK: - Editor pane layout hook

final class EditorViewController: NSViewController {
    var onLayout: (() -> Void)?
    override func viewDidLayout() {
        super.viewDidLayout()
        onLayout?()
    }
}
