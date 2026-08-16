import AppKit
#if canImport(FlashTeXCore)
import FlashTeXCore
#endif

// AppDelegate — application lifecycle and the native menu bar.

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var controller: MainWindowController?
    private var settingsObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMainMenu()
        applyAppearance()

        // Follow the light/dark setting (and flavour changes) immediately.
        settingsObserver = NotificationCenter.default.addObserver(
            forName: SettingsStore.changedNotification,
            object: nil, queue: .main) { [weak self] note in
                guard let key = note.userInfo?["key"] as? String else { return }
                if key == SettingsStore.Key.appearanceMode.rawValue {
                    self?.applyAppearance()
                }
            }

        let controller = MainWindowController()
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.controller = controller

        // First-run setup check: no TeX engine installed means nothing can be
        // compiled — point the user at a guided install rather than leaving
        // them to discover it via a cryptic status message.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard TeX.enginesAvailable() == false else { return }
            DispatchQueue.main.async {
                self?.presentMissingTeXAlert()
            }
        }
    }

    private func presentMissingTeXAlert() {
        guard let window = controller?.window else { return }
        let alert = NSAlert()
        alert.messageText = "TeX engine not found"
        alert.informativeText = """
        FlashTeX compiles LaTeX documents with a local TeX engine, but no \
        engine (pdflatex / xelatex / lualatex) could be found on this Mac.

        Install MacTeX from tug.org/mactex/ (large but complete) or BasicTeX \
        for a smaller setup, then relaunch FlashTeX. If you already installed \
        one, make sure its bin directory (usually /Library/TeX/texbin) is on \
        the PATH used to launch FlashTeX.
        """
        alert.addButton(withTitle: "Open MacTeX Page")
        alert.addButton(withTitle: "Later")
        if let url = URL(string: "https://www.tug.org/mactex/"),
           alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(url)
        }
        _ = window
    }

    /// Lock the app-wide appearance to the user's setting so native controls
    /// (menus, toolbars, panels) match the chosen theme.
    private func applyAppearance() {
        let appearance = SettingsStore.shared.isDarkMode
            ? NSAppearance(named: .darkAqua) : NSAppearance(named: .aqua)
        NSApp.appearance = appearance
        if let window = controller?.window {
            window.appearance = appearance
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.shutdown()
        CompletionUsageTracker.shared.flush()
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
    }

    // MARK: - Menu bar

    private func buildMainMenu() -> NSMenu {
        let main = NSMenu()

        // ---- App menu -------------------------------------------------------
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About FlashTeX",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…",
                        action: #selector(showSettings(_:)),
                        keyEquivalent: ",")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                                         action: #selector(NSApplication.hideOtherApplications(_:)),
                                         keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All",
                        action: #selector(NSApplication.unhideAllApplications(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit FlashTeX",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu

        // ---- File menu ------------------------------------------------------
        main.addItem(menu(title: "File", items: [
            item("New", "n", #selector(MainWindowController.newDocument), .command),
            item("Open…", "o", #selector(MainWindowController.openDocument), .command),
            .separator(),
            item("Save", "s", #selector(MainWindowController.saveDocument), .command),
            item("Save As…", "S", #selector(MainWindowController.saveDocumentAs), .command),
            item("Export PDF…", "E", #selector(MainWindowController.exportPDF), .cmdShift),
            item("Export PNG…", "", #selector(MainWindowController.exportPNG)),
            item("Export SVG…", "", #selector(MainWindowController.exportSVG)),
            .separator(),
            item("Open PDF in Preview", "", #selector(MainWindowController.openPdfInPreview)),
            item("Reveal PDF in Finder", "", #selector(MainWindowController.revealPdfInFinder)),
            .separator(),
            item("Close", "w", #selector(NSWindow.performClose(_:)), .command),
        ]))

        // ---- Edit menu (standard responder-chain editing) ------------------
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenu.addItem(.separator())

        let cmdPalette = NSMenuItem(title: "Command Palette / Symbol Search…", action: #selector(MainWindowController.showCommandPalette(_:)), keyEquivalent: "P")
        cmdPalette.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(cmdPalette)

        editMenu.addItem(.separator())

        editMenu.addItem(NSMenuItem(title: "Reset Completion Learning…",
                                    action: #selector(MainWindowController.resetCompletionLearning(_:)),
                                    keyEquivalent: ""))

        editMenu.addItem(.separator())

        let findItem = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        let findMenu = NSMenu(title: "Find")
        for (title, key, tag) in [("Find…", "f", NSTextFinder.Action.showFindInterface.rawValue),
                                  ("Find Next", "g", NSTextFinder.Action.nextMatch.rawValue),
                                  ("Find Previous", "G", NSTextFinder.Action.previousMatch.rawValue),
                                  ("Use Selection for Find", "e", NSTextFinder.Action.setSearchString.rawValue)] {
            let mi = NSMenuItem(title: title,
                                action: #selector(NSTextView.performFindPanelAction(_:)),
                                keyEquivalent: key)
            mi.tag = tag
            findMenu.addItem(mi)
        }
        findItem.submenu = findMenu
        editMenu.addItem(findItem)
        let editItem = NSMenuItem()
        main.addItem(editItem)
        editItem.submenu = editMenu

        // ---- Compile menu ---------------------------------------------------
        let compileItem = NSMenuItem()
        main.addItem(compileItem)
        let compileMenu = NSMenu(title: "Compile")
        compileMenu.addItem(item("Compile Now", "r", #selector(MainWindowController.compileNow), .command))
        compileMenu.addItem(item("Stop Compiling", ".", #selector(MainWindowController.stopCompilation(_:)), .command))
        compileMenu.addItem(item("Pause Live Compile", "", #selector(MainWindowController.toggleAutoCompile)))
        compileMenu.addItem(item("Show Errors…", "", #selector(MainWindowController.showErrorSheet)))
        compileMenu.addItem(.separator())

        let engineItem = NSMenuItem(title: "Engine", action: nil, keyEquivalent: "")
        let engineMenu = NSMenu(title: "Engine")
        for name in ["pdflatex", "xelatex", "lualatex", "tectonic"] {
            let mi = NSMenuItem(title: name,
                                action: #selector(MainWindowController.chooseEngine(_:)),
                                keyEquivalent: "")
            mi.representedObject = name
            mi.target = nil                      // resolved via first responder validation
            engineMenu.addItem(mi)
        }
        engineItem.submenu = engineMenu
        compileMenu.addItem(engineItem)
        compileItem.submenu = compileMenu

        // ---- View menu ------------------------------------------------------
        main.addItem(menu(title: "View", items: [
            item("Toggle PDF Preview", "p", #selector(MainWindowController.togglePreview), [.command, .option]),
            item("Document Outline", "s", #selector(MainWindowController.toggleOutline), [.command, .option]),
            .separator(),
            item("Zoom In Preview", "=", #selector(MainWindowController.zoomPreviewIn), .cmdShift),
            item("Zoom Out Preview", "-", #selector(MainWindowController.zoomPreviewOut), .cmdShift),
            item("Fit Preview to Width", "0", #selector(MainWindowController.fitPreviewWidth), .cmdShift),
            .separator(),
            // Responder-chain zoom: the focused editor (main or Flash) handles
            // ⌘=/⌘-/⌘0 itself; MainWindowController acts as the fallback.
            item("Zoom In", "=", #selector(EditorTextView.zoomIn(_:))),
            item("Zoom Out", "-", #selector(EditorTextView.zoomOut(_:))),
            item("Actual Size", "0", #selector(EditorTextView.resetZoom(_:))),
            .separator(),
            item("Customize Toolbar…", "", #selector(MainWindowController.customizeToolbar)),
            item("Hide Toolbar", "T", #selector(MainWindowController.toggleToolbar(_:)),
                 [.command, .option]),
        ]))

        // ---- Flash menu -----------------------------------------------------
        let flashItem = NSMenuItem()
        main.addItem(flashItem)
        let flashMenu = NSMenu(title: "Flash")
        let flashMode = item("Flash Mode…", "K",
                             #selector(MainWindowController.toggleFlashMode), .cmdShift)
        flashMenu.addItem(flashMode)
        flashItem.submenu = flashMenu

        // ---- Window menu ----------------------------------------------------
        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        // ---- Help menu ------------------------------------------------------
        // The Help menu's search field is native: setting NSApp.helpMenu makes
        // macOS add the magnifier to this menu, and it indexes every item in
        // the main menu automatically — so any command, with its shortcut, is
        // already "searchable help". The reference submenus below exist purely
        // to put Vim-mode and LaTeX knowledge into that same native index.
        let helpItem = NSMenuItem()
        main.addItem(helpItem)
        let helpMenu = NSMenu(title: "Help")
        NSApp.helpMenu = helpMenu

        helpMenu.addItem(helpSubmenu(title: "Vim Mode", entries: [
            "Move left / right / up / down (h l k j)",
            "Next word (w) · back a word (b) · end of word (e)",
            "Start of line (0) · end of line ($) · first non-blank (^)",
            "Top of file (gg) · bottom of file (G) · go to line (5G)",
            "Insert before cursor (i) · after cursor (a)",
            "Insert at line start (I) · end of line (A)",
            "Open line below (o) · above (O)",
            "Delete character (x) · delete line (dd) · delete word (dw)",
            "Delete inner word (diw) · delete to end of line (D)",
            "Change word (cw) · inner word (ciw) · to end of line (C)",
            "Replace character (r) · replace mode (R)",
            "Yank line (yy) · yank word (yw) · paste (p) · paste before (P)",
            "Undo (u) · redo (Ctrl-R)",
            "Visual mode (v) · visual line (V) · visual inner word (viw)",
            "Find character (f) · find backward (F) · till (t) · repeat (; ,)",
            "Search (/) · search backward (?) · next (n) · previous (N)",
            "Count prefix (3w, 5dd, 2dw)",
            "Named register (\"a  then yy / p)",
            "Exit insert mode (Esc)",
            "Enable / disable in Settings → Editing → Vim Mode",
        ]))
        helpMenu.addItem(helpSubmenu(title: "LaTeX", entries: [
            "Start a command with a backslash (\\fra…) and pick from the popup",
            "Environment snippets: type the name, then press Tab",
            "Insert a fraction: \\frac + Tab, then type into the {} slots",
            "Wrap selection in formatting via ⌘B / ⌘I / ⌘K (rebindable in Settings)",
            "Compile on save, or force with ⌘R (Compile → Compile Now)",
            "Find / replace with ⌘F (native find bar)",
        ]))
        helpItem.submenu = helpMenu

        return main
    }

    /// Builds a Help reference submenu. The entries are searchable through the
    /// Help menu's native search field; selecting one is a no-op reference.
    private func helpSubmenu(title: String, entries: [String]) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        for entry in entries {
            let mi = NSMenuItem(title: entry, action: #selector(showHelpReference(_:)), keyEquivalent: "")
            mi.target = self
            menu.addItem(mi)
        }
        parent.submenu = menu
        return parent
    }

    @objc private func showHelpReference(_ sender: Any?) {
        // Reference entries are intentionally inert — the Help search field is
        // their purpose.
    }

    // MARK: - Menu construction helpers

    @objc private func showSettings(_ sender: Any?) {
        SettingsWindowController.present()
    }

    private func item(_ title: String, _ key: String, _ action: Selector,
                      _ mask: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mi.keyEquivalentModifierMask = mask
        return mi
    }

    private func menu(title: String, items: [NSMenuItem]) -> NSMenuItem {
        let parent = NSMenuItem()
        let menu = NSMenu(title: title)
        for it in items { menu.addItem(it) }
        parent.submenu = menu
        return parent
    }
}

private extension NSEvent.ModifierFlags {
    static let cmdShift: NSEvent.ModifierFlags = [.command, .shift]
}
