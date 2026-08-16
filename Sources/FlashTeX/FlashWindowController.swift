import AppKit

// FlashWindowController — "Flash Mode".
//
// An Obsidian Live-Preview-style scratch panel: math blocks (`$…$`, `$$…$$`,
// `\[…\]`, display environments) render directly inside the editor as images;
// the block under the caret unfolds to its raw LaTeX for editing. Everything
// lives in MathFoldingTextView + MathRenderer, so the main window's preview
// pane and compile worker are never involved.
//
// The panel deliberately uses a *normal* window level: a floating panel would
// stay above every other app's windows and break Command-Tab. At normal level
// it still fronts within FlashTeX, but drops behind other apps when you
// switch away.

final class FlashWindowController: NSWindowController {

    private let editor = MathFoldingTextView.makeEditor()
    private var statusBar: StatusBarView?

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        panel.title = "Flash Mode"
        panel.isFloatingPanel = false
        panel.level = .normal
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace]
        panel.minSize = NSSize(width: 560, height: 380)
        super.init(window: panel)

        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func currentSnippet() -> String { editor.string }

    func focusEditor() {
        window?.makeFirstResponder(editor)
    }

    func shutdown() {
        editor.shutdown()
    }

    // MARK: - UI

    private func buildUI() {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.documentView = editor
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let statusBar = StatusBarView()
        self.statusBar = statusBar
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        wireStatusBar(statusBar)

        let container = NSView()
        container.addSubview(scroll)
        container.addSubview(statusBar)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 24),
        ])

        container.frame = NSRect(x: 0, y: 0, width: 820, height: 640)
        window?.contentView = container

        editor.string = sampleSnippet
    }

    // MARK: - Status bar & Vim command line

    private func wireStatusBar(_ statusBar: StatusBarView) {
        let refresh = { [weak self] in
            guard let self else { return }
            statusBar.update(mode: self.editor.vim.modeLabel)
            statusBar.update(position: self.editor.caretPosition(),
                             encoding: "UTF-8",
                             engine: "LaTeX")
        }

        editor.vim.onModeChange = { [weak self] in
            self?.statusBar?.update(mode: self?.editor.vim.modeLabel ?? "NORMAL")
        }
        editor.onCursorMoved = { [weak self] in
            guard let self else { return }
            statusBar.update(position: self.editor.caretPosition(),
                             encoding: "UTF-8",
                             engine: "LaTeX")
        }
        editor.vim.onCommandLineStart = { [weak self] prompt in
            self?.statusBar?.beginCommandLine(prompt: prompt)
        }
        editor.vim.onCommandLineEnd = { [weak self] in
            guard let self else { return }
            self.statusBar?.endCommandLine()
            self.editor.focusWithoutInsert()
            refresh()
        }
        editor.vim.onColonCommand = { [weak self] command in
            self?.executeColonCommand(command)
        }
        editor.vim.onMessage = { [weak self] text in
            self?.statusBar?.showMessage(text)
        }
        refresh()
    }

    private func executeColonCommand(_ raw: String) {
        let cmd = raw.trimmingCharacters(in: .whitespaces).lowercased()
        switch cmd {
        case "q", "q!", "quit", "quit!":
            window?.close()
        case "w", "wq", "wq!", "x", "e", "e!", "wa", "wqa":
            statusBar?.showMessage("E32: No file name")
        case "noh", "nohlsearch":
            statusBar?.showMessage("")
        case "":
            break
        default:
            statusBar?.showMessage("E492: Not an editor command: \(raw.trimmingCharacters(in: .whitespaces))")
        }
    }

    private let sampleSnippet = """
    Paste a bare snippet — math blocks render right here in place.

    Inline math: the identity $e^{i\\pi} + 1 = 0$ is famous.

    Display math sits on its own lines:

    $$
    \\int_{-\\infty}^{\\infty} e^{-x^2}\\,dx = \\sqrt{\\pi}
    $$

    Or as a numbered environment:

    \\begin{equation}
    E = mc^2
    \\end{equation}

    Click a rendered block to unfold it and edit the LaTeX. ⌘= / ⌘- / ⌘0 zoom.
    """
}
