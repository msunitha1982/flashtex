import AppKit

// CompletionPanel — a Sublime-style LaTeX autocomplete popup.
//
// Replaces the native NSTextView completion window (which is semi-transparent,
// narrow, unstylable, auto-inserts the first match while the user keeps typing,
// and double-inserts on accept). Presentation is a plain NSPopover anchored to
// the caret (the approach used by the well-known NCRAutocompleteTextView
// example), so AppKit handles sizing and positioning:
//
//   * the box height is set exactly via `popover.contentSize` from the number
//     of rows, so the list is never clipped or tiny
//   * `.transient` behavior closes the popover the moment the user clicks
//     anywhere else (editor, another window, another app)
//   * the popover never becomes key: the editor keeps the caret active, the
//     Edit menu and undo stay live, and nothing grays out
//   * keyboard input is captured by a LOCAL event monitor installed while the
//     popover is visible: down/up move the selection, tab/return/enter accept,
//     escape/delete/space dismiss, and every other key is returned untouched so
//     it flows through the normal NSTextView machinery and refilters the list
//   * the first match is pre-selected, so tab/return immediately accept it
//   * the row highlight is drawn by the cell view using the Catppuccin blue
//     accent with a readable contrast colour
//   * each row shows the command (typed prefix bolded) plus a gray preview of
//     the snippet it inserts

final class CompletionPanel: NSObject, NSTableViewDataSource, NSTableViewDelegate {

    struct Item {
        let command: String
        let preview: String
        /// The typed partial — its leading prefix is bolded in the command.
        let highlight: String
    }

    private let popover = NSPopover()
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let cellId = NSUserInterfaceItemIdentifier("completionCell")
    private let rowHeight: CGFloat = 26
    private let maxVisibleRows = 8

    private var items: [Item] = []
    private weak var host: EditorTextView?
    private var keyMonitor: Any?
    private var closeObserver: NSObjectProtocol?

    var isVisible: Bool { popover.isShown }

    override init() {
        super.init()

        popover.behavior = .transient
        popover.animates = false

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 100))
        content.wantsLayer = true
        content.layer?.backgroundColor = Theme.nsColor("surface0").cgColor
        content.layer?.cornerRadius = 8
        content.layer?.masksToBounds = true

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
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.autoresizingMask = [.width, .height]
        scrollView.frame = content.bounds
        content.addSubview(scrollView)

        let vc = NSViewController()
        vc.view = content
        popover.contentViewController = vc

        // The popover can close on its own (`.transient` outside-click, app
        // deactivation): clean up the key monitor so it isn't left installed.
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSPopover.didCloseNotification,
            object: popover, queue: .main) { [weak self] _ in
                self?.cleanup()
            }
    }

    deinit {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let observer = closeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Presentation

    /// Show the popover with an initial item list, anchored to the caret.
    /// `anchor` is in screen coordinates (from the editor's caret rect).
    func show(items: [Item], anchor: NSRect, in host: EditorTextView) {
        self.host = host
        self.items = items
        tableView.reloadData()
        if !items.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
        }
        sizeToFit()

        let local = host.convert(anchor, from: nil)
        installKeyMonitor()
        popover.show(relativeTo: local, of: host, preferredEdge: .maxY)
    }

    /// Refilter: replace the item list (same selection index if possible) and
    /// resize in place. The popover stays anchored where it was first shown.
    func updateItems(_ newItems: [Item], anchor: NSRect) {
        let prev = tableView.selectedRow
        items = newItems
        tableView.reloadData()
        if !items.isEmpty {
            let row = min(max(prev, 0), items.count - 1)
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
        }
        sizeToFit()
    }

    /// Accept the highlighted row: hand the command to the editor (which owns
    /// the snippet insertion) and close. Returns false when there was nothing
    /// to accept, so the caller can forward the key instead.
    @discardableResult
    func acceptSelection() -> Bool {
        let row = tableView.selectedRow
        guard !items.isEmpty, row >= 0, row < items.count else { return false }
        let command = items[row].command
        let editor = host
        dismiss()
        editor?.acceptCompletion(command)
        return true
    }

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < items.count else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        acceptSelection()
    }

    func dismiss() {
        cleanup()
        if popover.isShown {
            popover.close()
        }
    }

    private func cleanup() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        host = nil
        items = []
    }

    // MARK: - Keyboard (local event monitor — the popover is never key)

    /// Intercept keys only while the popover is visible. Everything except the
    /// navigation keys is returned untouched so it reaches the editor, whose
    /// normal insertion path refilters the list via `didChangeText`.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.popover.isShown else { return event }
            switch Int(event.keyCode) {
            case 125:                       // ↓
                self.moveSelection(1)
                return nil
            case 126:                       // ↑
                self.moveSelection(-1)
                return nil
            case 36, 76, 48:                // return / enter / tab
                if self.acceptSelection() { return nil }
                return event
            case 53:                        // esc
                self.dismiss()
                return nil
            case 51, 49:                    // delete / space
                self.dismiss()
                return event                // let the editor handle the delete/space
            default:
                return event
            }
        }
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

    // MARK: - Layout

    private func sizeToFit() {
        let font = Theme.editorFont
        var maxW: CGFloat = 0
        for item in items {
            let str = (item.command + "  " + item.preview) as NSString
            maxW = max(maxW, str.size(withAttributes: [.font: font]).width)
        }
        let width = min(max(maxW + 52, 360), 520)
        let height = max(CGFloat(min(items.count, maxVisibleRows)), 1) * rowHeight + 2
        popover.contentSize = NSSize(width: width, height: height)
        scrollView.hasVerticalScroller = items.count > maxVisibleRows
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
        cell.highlight = item.highlight
        cell.isSelectedRow = tableView.selectedRow == row
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        tableView.enumerateAvailableRowViews { rowView, row in
            guard let cell = rowView.view(atColumn: 0) as? CompletionCellView else { return }
            cell.isSelectedRow = row == tableView.selectedRow
        }
    }
}

// MARK: - Row view

/// A single completion row: the command (typed prefix bolded), then a gray
/// preview of the snippet it would insert. The selected row is filled with the
/// Catppuccin blue accent and the text flips to a readable contrast colour.
final class CompletionCellView: NSTableCellView {

    var command = "" { didSet { needsDisplay = true } }
    var preview = "" { didSet { needsDisplay = true } }
    var highlight = "" { didSet { needsDisplay = true } }
    var isSelectedRow = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

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

        // Vertically centre the text in the row (flipped coordinates).
        let baseline = rect.midY + (font.ascender + font.descender) / 2
        let x: CGFloat = 12

        // Command with the typed prefix bolded.
        var cmdX = x
        let hlCount = min(highlight.count, command.count)
        if hlCount > 0 {
            let boldStr = (command as NSString).substring(to: hlCount) as NSString
            let boldFont = NSFont.monospacedSystemFont(ofSize: Theme.editorFontSize, weight: .bold)
            boldStr.draw(at: NSPoint(x: cmdX, y: baseline),
                         withAttributes: [.font: boldFont, .foregroundColor: commandColor])
            cmdX += boldStr.size(withAttributes: [.font: boldFont]).width
        }
        if hlCount < command.count {
            let restStr = (command as NSString).substring(from: hlCount) as NSString
            restStr.draw(at: NSPoint(x: cmdX, y: baseline),
                         withAttributes: [.font: font, .foregroundColor: commandColor])
        }

        if !preview.isEmpty {
            let cmdW = (command as NSString).size(withAttributes: [.font: font]).width
            (preview as NSString).draw(at: NSPoint(x: x + cmdW + 12, y: baseline),
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