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

        let container = NSView()
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        container.frame = NSRect(x: 0, y: 0, width: 820, height: 640)
        window?.contentView = container

        editor.string = sampleSnippet
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
