import AppKit

// CompletionPanel — a Sublime-style LaTeX autocomplete popup.
//
// The native NSTextView completion window is semi-transparent, narrow,
// unstylable, auto-inserts the first match while the user keeps typing, and
// double-inserts on accept — so we draw our own. The design follows the
// production reference implementations (krzyzanowskim/STTextView and
// CodeEditApp/CodeEditSourceEditor):
//
//   * a borderless, NON-KEY child NSWindow (level .popUpMenu) attached to the
//     editor's window — the editor keeps key status, so the caret stays
//     active, the Edit menu and undo stay live, and nothing grays out
//   * positioned with explicit screen-coordinate math from the caret's
//     screen rect (firstRect(forCharacterRange:)) via setFrameTopLeftPoint /
//     setFrameOrigin, with screen-edge clamping and a below/above-caret flip —
//     no reliance on NSPopover's private positioning (which mis-placed the
//     list when the caret rect was converted through the wrong coordinate
//     space)
//   * sized exactly from the row count and the widest row: every visible row
//     is fully drawn (never half-clipped)
//   * keyboard handled by a local NSEvent keyDown monitor installed while the
//     panel is visible: up/down move the selection, tab/return/enter accept,
//     escape dismisses, and every other key is returned untouched so it flows
//     through the normal NSTextView machinery and refilters the list
//   * the panel auto-dismisses when the editor window resigns key status, and
//     the editor dismisses it when the document scrolls away
//   * the first match is pre-selected, so tab/return immediately accept it
//   * the row highlight is drawn by the cell view using the Catppuccin blue
//     accent with a readable contrast colour (a non-key window would draw the
//     system selection gray)
//   * each row shows the command (typed prefix bolded) plus a gray preview of
//     the snippet it inserts

final class CompletionPanel: NSWindow, NSTableViewDataSource, NSTableViewDelegate {

    struct Item {
        let command: String
        let preview: String
        /// The typed partial — its leading prefix is bolded in the command.
        let highlight: String
    }

    private static let rowHeight: CGFloat = 26
    private static let maxVisibleRows = 8
    static let textPadding: CGFloat = 12
    private static let verticalInset: CGFloat = 4

    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let cellId = NSUserInterfaceItemIdentifier("completionCell")

    private var items: [Item] = []
    private weak var host: EditorTextView?
    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var isChildAttached = false
    private var isAbove = false
    private var isDismissing = false

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 360, height: 100),
                   styleMask: [.borderless],
                   backing: .buffered, defer: false)
        level = .popUpMenu
        hidesOnDeactivate = true
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 100))
        content.wantsLayer = true
        content.layer?.backgroundColor = Theme.nsColor("surface0").cgColor
        content.layer?.cornerRadius = 8
        content.layer?.borderWidth = 1
        content.layer?.borderColor = Theme.nsColor("surface1").cgColor
        content.layer?.masksToBounds = true
        contentView = content

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("col"))
        col.resizingMask = .autoresizingMask
        tableView.addTableColumn(col)
        tableView.headerView = nil
        tableView.rowHeight = Self.rowHeight
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
        tableView.autoresizingMask = [.width]

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: Self.verticalInset, left: 0,
                                                bottom: Self.verticalInset, right: 0)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.frame = content.bounds
        content.addSubview(scrollView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let observer = resignObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Presentation

    /// Show the popup with an initial item list. `anchor` is the caret rect in
    /// screen coordinates (from the editor's caret rect).
    func show(items: [Item], anchor: NSRect, in host: EditorTextView) {
        self.host = host
        self.items = items
        tableView.reloadData()
        selectFirst()
        sizeToFit()

        guard let parent = host.window else { return }
        if !isChildAttached {
            parent.addChildWindow(self, ordered: .above)
            isChildAttached = true
        }
        installResignObserver(on: parent)
        positionWindow(anchor: anchor)
        orderFrontRegardless()
        installKeyMonitor()
    }

    /// Refilter: replace the item list (same selection index if possible),
    /// resize, and re-anchor to the caret.
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
        positionWindow(anchor: anchor)
        if isVisible { orderFront(nil) }
    }

    /// Accept the highlighted row: hand the command to the editor (which owns
    /// the snippet insertion) and hide. Returns false when there was nothing
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
        guard !isDismissing else { return }
        isDismissing = true
        cleanup()
        if isChildAttached, let parent = host?.window {
            parent.removeChildWindow(self)
            isChildAttached = false
        }
        orderOut(nil)
        host = nil
        items = []
        isDismissing = false
    }

    /// Dismiss when the editor window stops being key — the user clicked
    /// another window or switched apps.
    private func installResignObserver(on parent: NSWindow) {
        guard resignObserver == nil else { return }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: parent, queue: .main) { [weak self] _ in
                self?.dismiss()
            }
    }

    private func cleanup() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        if let observer = resignObserver {
            NotificationCenter.default.removeObserver(observer)
            resignObserver = nil
        }
    }

    // MARK: - Keyboard (local event monitor — the panel is never key)

    /// Intercept keys only while the panel is visible. Everything except the
    /// navigation keys is returned untouched so it reaches the editor, whose
    /// normal insertion path refilters the list via `didChangeText`.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible else { return event }
            switch Int(event.keyCode) {
            case 125:                       // ↓
                self.moveSelection(1)
                return nil
            case 126:                       // ↑
                self.moveSelection(-1)
                return nil
            case 121:                       // page down
                self.moveSelection(Self.maxVisibleRows)
                return nil
            case 116:                       // page up
                self.moveSelection(-Self.maxVisibleRows)
                return nil
            case 115:                       // home
                self.moveSelection(-self.items.count)
                return nil
            case 119:                       // end
                self.moveSelection(self.items.count)
                return nil
            case 36, 76, 48:                // return / enter / tab
                if self.acceptSelection() { return nil }
                return event
            case 53:                        // esc
                self.dismiss()
                return nil
            case 49:                        // space
                self.dismiss()
                return event                // let the editor type the space
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
        row = row < 0 ? 0 : min(max(row + delta, 0), count - 1)
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    private func selectFirst() {
        guard !items.isEmpty else { return }
        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        tableView.scrollRowToVisible(0)
    }

    // MARK: - Layout

    private func sizeToFit() {
        let font = Theme.editorFont
        var maxW: CGFloat = 0
        for item in items {
            let str = (item.command + "  " + item.preview) as NSString
            maxW = max(maxW, str.size(withAttributes: [.font: font]).width)
        }
        let width = min(max(maxW + Self.textPadding * 2 + 2, 360), 520)
        let visible = min(items.count, Self.maxVisibleRows)
        let height = CGFloat(max(visible, 1)) * Self.rowHeight + Self.verticalInset * 2
        setContentSize(NSSize(width: width, height: height))
        contentView?.frame = NSRect(x: 0, y: 0, width: width, height: height)
        scrollView.frame = contentView?.bounds ?? NSRect(x: 0, y: 0, width: width, height: height)
        scrollView.hasVerticalScroller = items.count > Self.maxVisibleRows
    }

    /// Place the window relative to the caret (screen coordinates), hanging
    /// below it by default and flipping above when there isn't enough room.
    private func positionWindow(anchor: NSRect) {
        let screen = host?.window?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let w = frame.width
        let h = frame.height
        let pad: CGFloat = 6

        var x = anchor.minX - Self.textPadding
        x = min(max(x, visible.minX + pad), visible.maxX - w - pad)

        // Hang below the caret (the window's top sits just under the caret).
        let topY = anchor.minY - 2
        if topY - h >= visible.minY + pad {
            isAbove = false
            setFrameTopLeftPoint(NSPoint(x: x, y: topY))
        } else {
            // Not enough room below — place above the caret instead.
            var bottomY = anchor.maxY + 6
            bottomY = min(max(bottomY, visible.minY + pad), visible.maxY - h - pad)
            isAbove = true
            setFrameOrigin(NSPoint(x: x, y: bottomY))
        }
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
        let x: CGFloat = CompletionPanel.textPadding

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