import AppKit

// CompletionPanel — a Sublime-style LaTeX autocomplete popup.
//
// Replaces the native NSTextView completion window (which is semi-transparent,
// narrow, unstylable, auto-inserts the first match while the user keeps typing,
// and double-inserts on accept). This panel is:
//   * opaque, with a Catppuccin surface background
//   * wider than the system popup, sized to its longest entry
//   * highlight = the Catppuccin blue accent (with a readable text colour)
//   * each row shows the command plus a gray preview of the snippet it inserts
//   * non-activating, so the editor keeps focus while the panel is open
//
// The editor drives it: show/update/accept are called from EditorTextView in
// response to typing. The panel never edits the document itself.

final class CompletionPanel: NSPanel, NSTableViewDataSource, NSTableViewDelegate {

    struct Item {
        let command: String
        let preview: String
    }

    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let cellId = NSUserInterfaceItemIdentifier("completionCell")
    private let rowHeight: CGFloat = 26

    private var items: [Item] = []
    private weak var host: EditorTextView?

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 320, height: 100),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = true
        isReleasedWhenClosed = false
        backgroundColor = Theme.nsColor("surface0")
        isOpaque = true
        hasShadow = true

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("col"))
        col.resizingMask = .autoresizingMask
        tableView.addTableColumn(col)
        tableView.headerView = nil
        tableView.rowHeight = rowHeight
        tableView.selectionHighlightStyle = .none
        tableView.backgroundColor = .clear
        tableView.focusRingType = .none
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.allowsEmptySelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        contentView = scrollView
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Presentation

    /// Show the panel with an initial item list, anchored to the caret.
    func show(items: [Item], anchor: NSRect, in host: EditorTextView) {
        self.host = host
        self.items = items
        tableView.reloadData()
        if !items.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        sizeToFitItems()
        position(anchor: anchor)
        orderFrontRegardless()
    }

    /// Refilter: replace the item list (same selection index if possible) and
    /// keep the panel glued to the caret.
    func updateItems(_ newItems: [Item], anchor: NSRect) {
        let prev = tableView.selectedRow
        items = newItems
        tableView.reloadData()
        if !items.isEmpty {
            let row = min(max(prev, 0), items.count - 1)
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
        }
        sizeToFitItems()
        position(anchor: anchor)
        if isVisible { orderFront(nil) }
    }

    /// Move the selection without touching the document.
    func moveSelection(_ delta: Int) {
        guard !items.isEmpty else { return }
        let count = items.count
        var row = tableView.selectedRow
        row = row < 0 ? 0 : ((row + delta) % count + count) % count
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    /// Accept the highlighted row: hand the command to the editor (which owns
    /// the snippet insertion) and hide. Returns false when there was nothing
    /// to accept, so the caller can fall through to normal handling.
    @discardableResult
    func acceptSelection() -> Bool {
        let row = tableView.selectedRow
        guard !items.isEmpty, row >= 0, row < items.count else { return false }
        let command = items[row].command
        hide()
        host?.acceptCompletion(command)
        return true
    }

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < items.count else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        acceptSelection()
    }

    func hide() {
        orderOut(nil)
        host = nil
    }

    // MARK: - Layout

    private func sizeToFitItems() {
        let font = Theme.editorFont
        var maxW: CGFloat = 0
        for item in items {
            let str = (item.command + "  " + item.preview) as NSString
            maxW = max(maxW, str.size(withAttributes: [.font: font]).width)
        }
        let width = min(max(maxW + 44, 320), 480)
        let maxVisible = 8
        let height = max(CGFloat(min(items.count, maxVisible)), 1) * rowHeight + 2
        setContentSize(NSSize(width: width, height: height))
        tableView.reloadData()
    }

    private func position(anchor: NSRect) {
        let screen = host?.window?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let w = frame.width
        let h = frame.height
        var x = anchor.minX
        x = min(max(x, visible.minX + 4), visible.maxX - w - 4)
        let below = anchor.minY - h - 6
        let y = below >= visible.minY + 4 ? below : anchor.maxY + 6
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: cellId, owner: nil) as? CompletionCellView)
            ?? CompletionCellView()
        cell.identifier = cellId
        let item = items[row]
        cell.command = item.command
        cell.preview = item.preview
        cell.isSelectedRow = tableView.selectedRow == row
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        tableView.reloadData()   // repaint the blue highlight
    }
}

// MARK: - Row view

/// A single completion row: the command, then a gray preview of the snippet
/// it would insert. The selected row is filled with the Catppuccin blue accent
/// and the text flips to a readable contrast colour.
final class CompletionCellView: NSTableCellView {

    var command = "" { didSet { needsDisplay = true } }
    var preview = "" { didSet { needsDisplay = true } }
    var isSelectedRow = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds
        let selected = isSelectedRow

        let bg = selected ? Theme.accent : Theme.nsColor("surface0")
        bg.setFill()
        rect.fill()

        let font = Theme.editorFont
        let contrast = contrastingTextColor(on: Theme.accent)
        let commandColor = selected ? contrast : Theme.editorText
        let previewColor = selected ? contrast.withAlphaComponent(0.72) : Theme.secondaryText

        // Vertically centre the text in the row.
        let baseline = rect.midY + (font.ascender + font.descender) / 2
        let x: CGFloat = 10

        (command as NSString).draw(at: NSPoint(x: x, y: baseline),
                                   withAttributes: [.font: font, .foregroundColor: commandColor])
        if !preview.isEmpty {
            let cmdW = (command as NSString).size(withAttributes: [.font: font]).width
            (preview as NSString).draw(at: NSPoint(x: x + cmdW + 10, y: baseline),
                                       withAttributes: [.font: font, .foregroundColor: previewColor])
        }
    }

    /// Dark text on bright accents (Mocha blue), white text on dark accents
    /// (Latte blue), so the highlighted row always reads clearly.
    private func contrastingTextColor(on bg: NSColor) -> NSColor {
        guard let rgb = bg.usingColorSpace(.sRGB) else { return .white }
        let lum = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        if lum > 0.5 {
            return NSColor(srgbRed: 0.10, green: 0.10, blue: 0.13, alpha: 1)
        }
        return .white
    }
}