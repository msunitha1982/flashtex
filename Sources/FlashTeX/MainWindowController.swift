import AppKit
import UniformTypeIdentifiers

// MainWindowController — the app shell.
//
// Owns the split layout (editor | preview), the compile worker, the toolbar,
// the native menu bar, the error viewer and Flash Mode. Everything is wired
// here.

final class MainWindowController: NSWindowController {

    private let editor = EditorTextView.makeEditor()
    private let preview = PreviewView()
    private let compiler = Compiler()
    private let highlighter = LaTeXSyntaxHighlighter()
    private let scrollView = NSScrollView()

    private var splitVC: NSSplitViewController!
    private var previewItem: NSSplitViewItem!

    private var currentFileURL: URL?
    private var autoCompile = true
    private var isLoading = false
    private var isFlashActive = false
    private var lastPdfURL: URL?
    private var currentErrors: [LatexIssue] = []
    private var scrollObserver: NSObjectProtocol?
    private var errorSheet: NSWindow?
    private var flashController: FlashWindowController?
    private var isCompiling = false
    private var compilingDelay: Timer?

    private weak var enginePopup: NSPopUpButton?
    private weak var autoSwitch: NSSwitch?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1360, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "FlashTeX"
        window.minSize = NSSize(width: 900, height: 560)
        window.setFrameAutosaveName("FlashTeX.Window")
        super.init(window: window)

        window.delegate = self
        buildUI()
        buildToolbar()
        applyToolbarState()
        wireCompiler()
        loadWelcomeDocument()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - UI assembly

    private func buildUI() {
        splitVC = NSSplitViewController()
        splitVC.splitView.autosaveName = "FlashTeX.Split"

        let editorItem = NSSplitViewItem(viewController: makeEditorViewController())
        editorItem.minimumThickness = 300
        let previewItem = NSSplitViewItem(viewController: makePreviewViewController())
        previewItem.minimumThickness = 240
        self.previewItem = previewItem

        splitVC.addSplitViewItem(editorItem)
        splitVC.addSplitViewItem(previewItem)
        splitVC.splitView.setPosition(560, ofDividerAt: 0)

        window?.contentViewController = splitVC
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
            if self.autoCompile && !self.isFlashActive {
                self.compiler.scheduleCompile(source: self.editor.string)
            }
        }

        editor.onFontSizeChanged = { [weak self] in
            self?.applyEditorFont()
        }

        compiler.onStatusStarted = { [weak self] in
            self?.beginCompilingIndicator()
        }

        compiler.onFinished = { [weak self] report in
            self?.handleCompileFinished(report)
        }
    }

    private func applyEditorFont() {
        editor.font = Theme.editorFont
        editor.updateGutter()
        highlighter.rehighlightNow(editor: editor, scrollView: scrollView)
    }

    private func handleCompileFinished(_ report: LatexReport) {
        endCompilingIndicator()
        if report.success, let pdfURL = report.pdfURL {
            lastPdfURL = pdfURL
            currentErrors = []
            preview.load(pdfURL: pdfURL)
            removeErrorToolbarItem()
            return
        }

        currentErrors = report.errors
        insertErrorToolbarItem()
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
        isFlashActive = true
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
            compiler.compileNow(source: editor.string)
        } catch {
            presentError(NSError(domain: "FlashTeX", code: 1,
                                 userInfo: [NSLocalizedDescriptionKey: "Could not open \(url.lastPathComponent)."]))
        }
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

    @objc func toggleAutoCompile() {
        autoCompile.toggle()
        autoSwitch?.state = autoCompile ? .on : .off
        if autoCompile {
            compiler.compileNow(source: editor.string)
        }
    }

    @objc func chooseEngine(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        compiler.engine = name
        enginePopup?.selectItem(withTitle: name)
    }

    @objc func enginePopupChanged(_ sender: NSPopUpButton) {
        if let name = sender.titleOfSelectedItem {
            compiler.engine = name
        }
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

    /// Show the spinner after a short grace period so fast compiles never
    /// flash the toolbar — it only appears "when necessary".
    private func beginCompilingIndicator() {
        isCompiling = true
        compilingDelay?.invalidate()
        let t = Timer(timeInterval: 0.25, repeats: false) { [weak self] _ in
            guard let self = self, self.isCompiling else { return }
            self.insertProgressItem()
        }
        compilingDelay = t
        // `.common` so the spinner still appears while the run loop is busy
        // tracking an event (typing, scroll tracking).
        RunLoop.main.add(t, forMode: .common)
    }

    private func endCompilingIndicator() {
        isCompiling = false
        compilingDelay?.invalidate()
        compilingDelay = nil
        removeProgressItem()
    }

    // MARK: - Shutdown

    func shutdown() {
        compiler.shutdown()
        highlighter.shutdown()
        if let scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
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

        case ToolbarID.engine:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Engine"
            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 130, height: 26),
                                      pullsDown: false)
            popup.addItems(withTitles: ["pdflatex", "xelatex", "lualatex"])
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
            return true
        case #selector(togglePreview):
            menuItem.state = previewItem?.isCollapsed == false ? .on : .off
            return true
        case #selector(toggleFlashMode):
            menuItem.state = flashController != nil ? .on : .off
            return true
        case #selector(toggleToolbar(_:)):
            menuItem.state = isToolbarMinimized ? .on : .off
            return true
        case #selector(exportPDF), #selector(revealPdfInFinder):
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
            isFlashActive = false
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
