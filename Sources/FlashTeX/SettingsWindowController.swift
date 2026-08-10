import AppKit

// SettingsWindowController — the Preferences window (⌘,).
//
// Four panes: Appearance, Editor, Flash Mode, Vim Mode. Every control writes
// straight through to SettingsStore, which posts a change notification; the
// editors, highlighter and Flash folding view re-apply live.

final class SettingsWindowController: NSWindowController {

    /// Strong reference — `present()`'s controller is otherwise released as
    /// soon as the method returns and the window would go blank/close.
    private static var current: SettingsWindowController?

    private let settings = SettingsStore.shared

    private var flavourPopup: NSPopUpButton!
    private var appearanceSegment: NSSegmentedControl!
    private var lineIndicatorWell: NSColorWell!
    private var backgroundOverrideWell: NSColorWell!
    private var backgroundUsePalette: NSButton!
    private var syntaxPopups: [String: NSPopUpButton] = [:]

    private var fontPopup: NSPopUpButton!
    private var lineHeightSlider: NSSlider!
    private var lineHeightLabel: NSTextField!
    private var ligaturesCheck: NSButton!
    private var columnPopup: NSPopUpButton!
    private var gutterPopup: NSPopUpButton!

    private var mathScaleSlider: NSSlider!
    private var mathScaleLabel: NSTextField!
    private var chipFillPopup: NSPopUpButton!
    private var chipPaddingSlider: NSSlider!
    private var chipPaddingLabel: NSTextField!
    private var chipRadiusSlider: NSSlider!
    private var chipRadiusLabel: NSTextField!
    private var debounceSlider: NSSlider!
    private var debounceLabel: NSTextField!
    private var unfoldPopup: NSPopUpButton!

    private var vimCheck: NSButton!

    static func present() {
        let controller: SettingsWindowController
        if let existing = current {
            controller = existing
        } else {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
                                  styleMask: [.titled, .closable],
                                  backing: .buffered, defer: false)
            window.title = "FlashTeX Settings"
            window.isReleasedWhenClosed = false
            controller = SettingsWindowController(window: window)
            controller.window?.delegate = controller
            current = controller
        }
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.center()
        controller.window?.makeKeyAndOrderFront(nil)
    }

    override init(window: NSWindow?) {
        super.init(window: window)
        buildContent()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Assembly

    private func buildContent() {
        guard let window else { return }

        let tabs = NSTabView(frame: NSRect(x: 0, y: 0, width: 560, height: 440))
        tabs.addTabViewItem(makeAppearanceTab())
        tabs.addTabViewItem(makeEditorTab())
        tabs.addTabViewItem(makeFlashTab())
        tabs.addTabViewItem(makeVimTab())

        let container = NSView()
        tabs.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(tabs)
        NSLayoutConstraint.activate([
            tabs.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            tabs.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            tabs.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            tabs.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])
        window.contentView = container
        window.setContentSize(NSSize(width: 560, height: 480))
    }

    // MARK: - Control helpers

    private func label(_ text: String, size: CGFloat = 13) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: size)
        return l
    }

    private func row(_ title: String, control: NSView, controlWidth: CGFloat = 180) -> NSStackView {
        let row = NSStackView(views: [label(title), control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.distribution = .fill
        control.translatesAutoresizingMaskIntoConstraints = false
        control.widthAnchor.constraint(equalToConstant: controlWidth).isActive = true
        return row
    }

    private func makePopup(_ titles: [String], action: Selector) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 180, height: 26), pullsDown: false)
        popup.addItems(withTitles: titles)
        popup.target = self
        popup.action = action
        return popup
    }

    private func pane(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 12, bottom: 18, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.autoresizingMask = [.width, .height]
        return stack
    }

    /// A labelled slider row: "title   [slider] [value]".
    private func sliderRow(_ title: String, slider: NSSlider, valueLabel: NSTextField,
                           controlWidth: CGFloat) -> NSStackView {
        let titleLabel = label(title)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.widthAnchor.constraint(equalToConstant: 150).isActive = true
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: controlWidth).isActive = true
        let row = NSStackView(views: [titleLabel, slider, valueLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        return row
    }

    // MARK: - Appearance tab

    private func makeAppearanceTab() -> NSTabViewItem {
        flavourPopup = makePopup(SettingsStore.Flavor.allCases.map { $0.displayName },
                                 action: #selector(flavourChanged(_:)))
        flavourPopup.selectItem(at: SettingsStore.Flavor.allCases.firstIndex(of: settings.flavor) ?? 0)

        appearanceSegment = NSSegmentedControl(labels: ["Light", "Dark"],
                                               trackingMode: .selectOne,
                                               target: self,
                                               action: #selector(appearanceChanged(_:)))
        appearanceSegment.selectedSegment = settings.isDarkMode ? 1 : 0
        appearanceSegment.translatesAutoresizingMaskIntoConstraints = false
        appearanceSegment.widthAnchor.constraint(equalToConstant: 180).isActive = true

        lineIndicatorWell = NSColorWell()
        lineIndicatorWell.color = Theme.currentLine
        lineIndicatorWell.target = self
        lineIndicatorWell.action = #selector(lineIndicatorChanged(_:))
        lineIndicatorWell.translatesAutoresizingMaskIntoConstraints = false
        lineIndicatorWell.widthAnchor.constraint(equalToConstant: 180).isActive = true

        backgroundOverrideWell = NSColorWell()
        backgroundOverrideWell.color = Theme.nsColor(from: settings.backgroundHex)
            ?? Theme.editorBackground
        backgroundOverrideWell.target = self
        backgroundOverrideWell.action = #selector(backgroundOverrideChanged(_:))
        backgroundOverrideWell.isEnabled = !settings.backgroundHex.isEmpty
        backgroundOverrideWell.translatesAutoresizingMaskIntoConstraints = false
        backgroundOverrideWell.widthAnchor.constraint(equalToConstant: 120).isActive = true

        backgroundUsePalette = NSButton(checkboxWithTitle: "Use palette background",
                                        target: self,
                                        action: #selector(backgroundUsePaletteToggled(_:)))
        backgroundUsePalette.state = settings.backgroundHex.isEmpty ? .on : .off

        let bgRow = NSStackView(views: [backgroundUsePalette, backgroundOverrideWell])
        bgRow.orientation = .horizontal
        bgRow.spacing = 10
        bgRow.alignment = .centerY

        let syntaxSection = label("Syntax colors", size: 11)
        syntaxSection.textColor = .secondaryLabelColor
        syntaxSection.font = .systemFont(ofSize: 11, weight: .semibold)

        let grid = NSGridView(views: [])
        grid.rowSpacing = 6
        grid.columnSpacing = 16
        let roles = Theme.syntaxRoles
        for i in stride(from: 0, to: roles.count, by: 2) {
            var cells: [NSView] = []
            for j in i..<min(i + 2, roles.count) {
                let (role, displayName) = roles[j]
                let popup = makePopup(["Default (palette)"]
                                        + Theme.accentNames.map(Theme.accentDisplayName),
                                      action: #selector(syntaxAccentChanged(_:)))
                popup.identifier = NSUserInterfaceItemIdentifier(role)
                if let accent = currentAccent(for: role),
                   let idx = Theme.accentNames.firstIndex(of: accent) {
                    popup.selectItem(at: idx + 1)
                } else {
                    popup.selectItem(at: 0)
                }
                popup.translatesAutoresizingMaskIntoConstraints = false
                popup.widthAnchor.constraint(equalToConstant: 170).isActive = true
                cells.append(label(displayName))
                cells.append(popup)
                syntaxPopups[role] = popup
            }
            grid.addRow(with: cells)
        }

        let resetButton = NSButton(title: "Reset colors to palette", target: self,
                                   action: #selector(resetColors(_:)))

        let views = [
            row("Catppuccin flavour", control: flavourPopup),
            row("Appearance", control: appearanceSegment),
            row("Line indicator", control: lineIndicatorWell),
            bgRow,
            syntaxSection,
            grid,
            resetButton,
        ]
        let item = NSTabViewItem(identifier: "appearance")
        item.label = "Appearance"
        item.view = pane(views)
        return item
    }

    // MARK: - Editor tab

    private func makeEditorTab() -> NSTabViewItem {
        let fonts = ["System (SF Mono)", "Menlo", "Monaco", "Courier New",
                     "JetBrains Mono", "Fira Code", "Latin Modern Mono", "Latin Modern Roman"]
        fontPopup = makePopup(fonts, action: #selector(fontChanged(_:)))
        let currentFamily = settings.fontFamily
        if let idx = fonts.firstIndex(of: currentFamily) {
            fontPopup.selectItem(at: idx)
        } else if !currentFamily.isEmpty {
            fontPopup.addItem(withTitle: currentFamily)
            fontPopup.selectItem(withTitle: currentFamily)
        } else {
            fontPopup.selectItem(at: 0)
        }

        lineHeightSlider = NSSlider(value: settings.lineHeight,
                                    minValue: 1.2, maxValue: 1.6,
                                    target: self, action: #selector(lineHeightChanged(_:)))
        lineHeightSlider.numberOfTickMarks = 9
        lineHeightSlider.allowsTickMarkValuesOnly = false
        lineHeightLabel = label(String(format: "%.2f×", settings.lineHeight))
        lineHeightLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        let lhRow = sliderRow("Line height", slider: lineHeightSlider,
                              valueLabel: lineHeightLabel, controlWidth: 140)

        ligaturesCheck = NSButton(checkboxWithTitle: "Enable font ligatures",
                                  target: self, action: #selector(ligaturesChanged(_:)))
        ligaturesCheck.state = settings.ligatures ? .on : .off

        columnPopup = makePopup(["Full width", "80 characters (centered)"],
                                action: #selector(columnChanged(_:)))
        columnPopup.selectItem(at: settings.maxColumnChars > 0 ? 1 : 0)

        gutterPopup = makePopup(SettingsStore.GutterMode.allCases.map { $0.displayName },
                                action: #selector(gutterChanged(_:)))
        gutterPopup.selectItem(at: SettingsStore.GutterMode.allCases.firstIndex(of: settings.gutterMode) ?? 1)

        let views = [
            row("Font family", control: fontPopup),
            label("Line height", size: 11).settingSecondary(),
            lhRow,
            ligaturesCheck!,
            row("Max column width", control: columnPopup),
            row("Line numbers", control: gutterPopup),
        ]
        let item = NSTabViewItem(identifier: "editor")
        item.label = "Editor"
        item.view = pane(views)
        return item
    }

    // MARK: - Flash Mode tab

    private func makeFlashTab() -> NSTabViewItem {
        mathScaleSlider = NSSlider(value: settings.mathScale,
                                   minValue: 0.85, maxValue: 1.25,
                                   target: self, action: #selector(mathScaleChanged(_:)))
        mathScaleLabel = label(String(format: "%.0f%%", settings.mathScale * 100))
        mathScaleLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        let scaleRow = sliderRow("Math scale", slider: mathScaleSlider,
                                 valueLabel: mathScaleLabel, controlWidth: 140)

        chipFillPopup = makePopup(SettingsStore.ChipFill.allCases.map { $0.displayName },
                                  action: #selector(chipFillChanged(_:)))
        chipFillPopup.selectItem(at: SettingsStore.ChipFill.allCases.firstIndex(of: settings.chipFill) ?? 0)

        chipPaddingSlider = NSSlider(value: settings.chipPadding,
                                     minValue: 0, maxValue: 12,
                                     target: self, action: #selector(chipPaddingChanged(_:)))
        chipPaddingSlider.numberOfTickMarks = 13
        chipPaddingSlider.allowsTickMarkValuesOnly = true
        chipPaddingLabel = label(String(format: "%.0f pt", settings.chipPadding))
        chipPaddingLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        let padRow = sliderRow("Padding", slider: chipPaddingSlider,
                               valueLabel: chipPaddingLabel, controlWidth: 140)

        chipRadiusSlider = NSSlider(value: settings.chipRadius,
                                    minValue: 2, maxValue: 8,
                                    target: self, action: #selector(chipRadiusChanged(_:)))
        chipRadiusSlider.numberOfTickMarks = 7
        chipRadiusSlider.allowsTickMarkValuesOnly = true
        chipRadiusLabel = label(String(format: "%.0f pt", settings.chipRadius))
        chipRadiusLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        let radiusRow = sliderRow("Corner radius", slider: chipRadiusSlider,
                                  valueLabel: chipRadiusLabel, controlWidth: 140)

        debounceSlider = NSSlider(value: settings.renderDebounceMs,
                                  minValue: 50, maxValue: 500,
                                  target: self, action: #selector(debounceChanged(_:)))
        debounceSlider.numberOfTickMarks = 10
        debounceSlider.allowsTickMarkValuesOnly = false
        debounceLabel = label(String(format: "%.0f ms", settings.renderDebounceMs))
        debounceLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        let debounceRow = sliderRow("Debounce", slider: debounceSlider,
                                    valueLabel: debounceLabel, controlWidth: 140)

        unfoldPopup = makePopup(SettingsStore.UnfoldTrigger.allCases.map { $0.displayName },
                                action: #selector(unfoldChanged(_:)))
        unfoldPopup.selectItem(at: SettingsStore.UnfoldTrigger.allCases.firstIndex(of: settings.unfoldTrigger) ?? 0)

        let views = [
            label("Rendering", size: 11).settingSecondary(),
            scaleRow,
            label("Chip overlay", size: 11).settingSecondary(),
            row("Background", control: chipFillPopup),
            padRow,
            radiusRow,
            label("Compile / render", size: 11).settingSecondary(),
            debounceRow,
            row("Unfold trigger", control: unfoldPopup),
        ]
        let item = NSTabViewItem(identifier: "flash")
        item.label = "Flash Mode"
        item.view = pane(views)
        return item
    }

    // MARK: - Vim tab

    private func makeVimTab() -> NSTabViewItem {
        vimCheck = NSButton(checkboxWithTitle: "Enable Vim-style editing",
                            target: self, action: #selector(vimChanged(_:)))
        vimCheck.state = settings.vimMode ? .on : .off

        let info = label("""
        Modal editing in the editor and Flash Mode:

        Esc               normal mode
        i / I / a / A     insert: after cursor / line start / after char / line end
        o / O             new line below / above
        h j k l / w b e   cursor / word motions
        0 ^ $             line start / first non-blank / line end
        gg / G / \\{n}G    document start / end / nth line
        v                 visual mode — move to select, then y / d
        x / X             delete char under / before cursor
        D / C             delete / change to end of line
        dd / yy / p / P   delete / yank line, paste after / before
        cw / dw / d$ / y$ change / delete / yank with a motion
        u                 undo (⌘Z also works)
        """, size: 12)
        info.maximumNumberOfLines = 0
        info.lineBreakMode = .byWordWrapping
        info.preferredMaxLayoutWidth = 480
        info.setContentCompressionResistancePriority(.required, for: .horizontal)

        let views: [NSView] = [vimCheck!, info]
        let item = NSTabViewItem(identifier: "vim")
        item.label = "Vim Mode"
        item.view = pane(views)
        return item
    }

    // MARK: - Actions — Appearance

    @objc private func flavourChanged(_ sender: NSPopUpButton) {
        let flavors = SettingsStore.Flavor.allCases
        guard sender.indexOfSelectedItem >= 0,
              sender.indexOfSelectedItem < flavors.count else { return }
        settings.flavor = flavors[sender.indexOfSelectedItem]
        appearanceSegment.selectedSegment = settings.isDarkMode ? 1 : 0
        refreshLineIndicatorWell()
    }

    @objc private func appearanceChanged(_ sender: NSSegmentedControl) {
        settings.isDarkMode = (sender.selectedSegment == 1)
        if let idx = SettingsStore.Flavor.allCases.firstIndex(of: settings.flavor) {
            flavourPopup.selectItem(at: idx)
        }
        refreshLineIndicatorWell()
    }

    /// The colour well follows the mode-aware default unless the user has set a
    /// custom override.
    private func refreshLineIndicatorWell() {
        lineIndicatorWell.color = Theme.currentLine
    }

    @objc private func lineIndicatorChanged(_ sender: NSColorWell) {
        settings.lineIndicatorHex = SettingsWindowController.hex(sender.color)
    }

    @objc private func backgroundOverrideChanged(_ sender: NSColorWell) {
        settings.backgroundHex = SettingsWindowController.hex(sender.color)
    }

    @objc private func backgroundUsePaletteToggled(_ sender: NSButton) {
        if sender.state == .on {
            settings.backgroundHex = ""
            backgroundOverrideWell.isEnabled = false
        } else {
            settings.backgroundHex = SettingsWindowController.hex(backgroundOverrideWell.color)
            backgroundOverrideWell.isEnabled = true
        }
    }

    @objc private func syntaxAccentChanged(_ sender: NSPopUpButton) {
        guard let role = sender.identifier?.rawValue else { return }
        var overrides = settings.syntaxOverrides
        let idx = sender.indexOfSelectedItem
        if idx <= 0 {
            overrides.removeValue(forKey: role)
        } else if idx - 1 < Theme.accentNames.count {
            overrides[role] = Theme.accentNames[idx - 1]
        }
        settings.syntaxOverrides = overrides
    }

    /// The accent currently applied to a role (nil = palette default).
    private func currentAccent(for role: String) -> String? {
        guard let override = settings.syntaxOverride(for: role) else { return nil }
        if Theme.accentNames.contains(override) { return override }
        // A legacy absolute-hex override: match it to an accent if it is one.
        let lower = override.lowercased()
        for name in Theme.accentNames {
            if let hex = Theme.palette.color(name), hex.lowercased() == lower {
                return name
            }
        }
        return nil
    }

    @objc private func resetColors(_ sender: Any?) {
        settings.backgroundHex = ""
        settings.lineIndicatorHex = ""
        settings.syntaxOverrides = [:]
        backgroundUsePalette.state = .on
        backgroundOverrideWell.isEnabled = false
        backgroundOverrideWell.color = Theme.editorBackground
        refreshLineIndicatorWell()
        for (role, popup) in syntaxPopups {
            popup.selectItem(at: 0)
        }
    }

    // MARK: - Actions — Editor

    @objc private func fontChanged(_ sender: NSPopUpButton) {
        let title = sender.titleOfSelectedItem ?? ""
        settings.fontFamily = title.hasPrefix("System") ? "" : title
    }

    @objc private func lineHeightChanged(_ sender: NSSlider) {
        settings.lineHeight = CGFloat(sender.doubleValue)
        lineHeightLabel.stringValue = String(format: "%.2f×", sender.doubleValue)
    }

    @objc private func ligaturesChanged(_ sender: NSButton) {
        settings.ligatures = (sender.state == .on)
    }

    @objc private func columnChanged(_ sender: NSPopUpButton) {
        settings.maxColumnChars = sender.indexOfSelectedItem == 0 ? 0 : 80
    }

    @objc private func gutterChanged(_ sender: NSPopUpButton) {
        let modes = SettingsStore.GutterMode.allCases
        guard sender.indexOfSelectedItem >= 0,
              sender.indexOfSelectedItem < modes.count else { return }
        settings.gutterMode = modes[sender.indexOfSelectedItem]
    }

    // MARK: - Actions — Flash Mode

    @objc private func mathScaleChanged(_ sender: NSSlider) {
        settings.mathScale = CGFloat(sender.doubleValue)
        mathScaleLabel.stringValue = String(format: "%.0f%%", sender.doubleValue * 100)
    }

    @objc private func chipFillChanged(_ sender: NSPopUpButton) {
        let fills = SettingsStore.ChipFill.allCases
        guard sender.indexOfSelectedItem >= 0,
              sender.indexOfSelectedItem < fills.count else { return }
        settings.chipFill = fills[sender.indexOfSelectedItem]
    }

    @objc private func chipPaddingChanged(_ sender: NSSlider) {
        settings.chipPadding = CGFloat(sender.doubleValue)
        chipPaddingLabel.stringValue = String(format: "%.0f pt", sender.doubleValue)
    }

    @objc private func chipRadiusChanged(_ sender: NSSlider) {
        settings.chipRadius = CGFloat(sender.doubleValue)
        chipRadiusLabel.stringValue = String(format: "%.0f pt", sender.doubleValue)
    }

    @objc private func debounceChanged(_ sender: NSSlider) {
        settings.renderDebounceMs = sender.doubleValue
        debounceLabel.stringValue = String(format: "%.0f ms", sender.doubleValue)
    }

    @objc private func unfoldChanged(_ sender: NSPopUpButton) {
        let triggers = SettingsStore.UnfoldTrigger.allCases
        guard sender.indexOfSelectedItem >= 0,
              sender.indexOfSelectedItem < triggers.count else { return }
        settings.unfoldTrigger = triggers[sender.indexOfSelectedItem]
    }

    // MARK: - Actions — Vim

    @objc private func vimChanged(_ sender: NSButton) {
        settings.vimMode = (sender.state == .on)
    }

    // MARK: - Color utilities

    /// NSColor → "RRGGBB" (in sRGB).
    static func hex(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        let r = Int((c.redComponent * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        return String(format: "%02X%02X%02X", r, g, b)
    }
}

extension SettingsWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if Self.current === self { Self.current = nil }
    }
}

private extension NSTextField {
    /// Smaller secondary-label styling for section headers inside panes.
    func settingSecondary() -> NSTextField {
        textColor = .secondaryLabelColor
        font = .systemFont(ofSize: 11, weight: .semibold)
        return self
    }
}
