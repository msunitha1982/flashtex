import AppKit

// GutterView — the line-number strip, drawn as a dedicated view.
//
// The editor previously painted its own gutter inside `EditorTextView.draw`.
// NSTextView is layer-backed, so anything drawn outside the redraw's dirty
// rect is silently clipped away — typing, scrolling and caret blinks only
// dirty the text column, so the numbers vanished after the first edit. This
// view owns the strip instead. It lives inside the scroll view's clip view,
// side by side with the text view, so it scrolls in lockstep, keeps its own
// layer contents (never clipped by text redraws) and repaints on demand.

final class GutterView: NSView {

    weak var editor: EditorTextView?
    weak var scrollView: NSScrollView?

    private var settingsObserver: NSObjectProtocol?

    override var isFlipped: Bool { true }

    init(editor: EditorTextView, scrollView: NSScrollView) {
        self.editor = editor
        self.scrollView = scrollView
        super.init(frame: .zero)
        // Sibling of the text view inside the clip view, so it moves with the
        // document when the user scrolls. Added last so it draws on top.
        scrollView.contentView.addSubview(self)
        settingsObserver = NotificationCenter.default.addObserver(
            forName: SettingsStore.changedNotification,
            object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
            }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
    }

    /// Match the strip to the editor's gutter width and to the full document
    /// height, then repaint. Called on creation, text edits, settings changes
    /// and window resizes.
    func refresh() {
        guard let editor, let scrollView else { return }
        let clip = scrollView.contentView
        let width = editor.gutterWidth()
        let docHeight = max(editor.frame.height, clip.bounds.height)
        frame = NSRect(x: 0, y: 0, width: width, height: docHeight)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let editor, let scrollView else { return }
        let mode = SettingsStore.shared.gutterMode
        guard mode != .none else { return }

        Theme.gutterBackground.setFill()
        bounds.fill()

        guard let lm = editor.layoutManager, let tc = editor.textContainer else { return }
        let ns = editor.string as NSString
        let origin = editor.textContainerOrigin
        // The clip view's bounds is the visible slice of the document; the
        // gutter sits in the same coordinate space as the text view.
        let visibleDoc = scrollView.contentView.bounds
        let containerRect = visibleDoc.offsetBy(dx: -origin.x, dy: -origin.y)
        let visible = lm.glyphRange(forBoundingRect: containerRect, in: tc)
        guard visible.location != NSNotFound else { return }

        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.gutterFont,
                                                    .foregroundColor: Theme.gutterText]
        let width = editor.gutterWidth()
        let editorFont = editor.font ?? Theme.editorFont
        let baselineOffset = editorFont.ascender - Theme.gutterFont.ascender

        lm.enumerateLineFragments(forGlyphRange: visible) { fragRect, _, _, glyphRange, _ in
            let rect = fragRect.offsetBy(dx: origin.x, dy: origin.y)
            let charLoc = lm.characterIndexForGlyph(at: glyphRange.location)
            let isLineStart = charLoc == 0 || ns.character(at: charLoc - 1) == 10
            guard isLineStart else { return }      // wrapped continuation lines share a number
            let text = editor.lineNumberText(at: charLoc)
            guard !text.isEmpty else { return }
            let size = (text as NSString).size(withAttributes: attrs)
            let x = width - size.width - 8
            let y = rect.minY + baselineOffset
            (text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
        }

        // Vim mode indicator pinned to the bottom corner of the gutter.
        if SettingsStore.shared.vimMode {
            let badgeAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .bold),
                .foregroundColor: Theme.accent,
            ]
            let text = editor.vim.modeLabel as NSString
            let size = text.size(withAttributes: badgeAttrs)
            text.draw(at: NSPoint(x: 6, y: bounds.maxY - size.height - 6),
                      withAttributes: badgeAttrs)
        }
    }
}
