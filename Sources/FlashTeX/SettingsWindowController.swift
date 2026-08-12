import AppKit
import SwiftUI

// MARK: - Settings Window Controller (Host for SwiftUI SettingsView)

final class SettingsWindowController: NSWindowController {

    private static var current: SettingsWindowController?

    static func present() {
        let controller: SettingsWindowController
        if let existing = current {
            controller = existing
        } else {
            let hostingController = NSHostingController(rootView: SettingsView())
            let window = NSWindow(contentViewController: hostingController)
            window.title = "FlashTeX Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 580, height: 520))
            
            controller = SettingsWindowController(window: window)
            window.delegate = controller
            current = controller
        }
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.center()
        controller.window?.makeKeyAndOrderFront(nil)
    }

    override init(window: NSWindow?) {
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

extension SettingsWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if Self.current === self { Self.current = nil }
    }
}

// MARK: - Standard Label-Aligned Form Row Helper

struct FormRow<Content: View>: View {
    let label: String
    let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.body)
                .frame(width: 140, alignment: .trailing)
            content
                .frame(maxWidth: 240, alignment: .leading)
        }
    }
}

// MARK: - Main SwiftUI Settings View

struct SettingsView: View {
    @ObservedObject var settings = SettingsStore.shared

    var body: some View {
        TabView {
            AppearanceSettingsView(settings: settings)
                .tabItem {
                    Label("Appearance", systemImage: "paintbrush")
                }

            EditorSettingsView(settings: settings)
                .tabItem {
                    Label("Editor", systemImage: "doc.text")
                }

            FlashModeSettingsView(settings: settings)
                .tabItem {
                    Label("Flash Mode", systemImage: "bolt.fill")
                }

            VimSettingsView(settings: settings)
                .tabItem {
                    Label("Vim Mode", systemImage: "keyboard")
                }
        }
        .frame(width: 580, height: 500)
        .padding(16)
    }
}

// MARK: - Tab 1: Appearance Settings View

struct AppearanceSettingsView: View {
    @ObservedObject var settings: SettingsStore
    @State private var usePaletteBg: Bool = true
    @State private var customBgColor: Color = .clear
    @State private var lineIndicatorColor: Color = .blue

    init(settings: SettingsStore) {
        self.settings = settings
        _usePaletteBg = State(initialValue: settings.backgroundHex.isEmpty)
        _customBgColor = State(initialValue: Theme.nsColor(from: settings.backgroundHex).map { Color($0) } ?? Color(Theme.editorBackground))
        _lineIndicatorColor = State(initialValue: Color(Theme.currentLine))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Main Appearance Section
                themeSection

                Divider()

                // Syntax Colors Section
                syntaxHeader
                syntaxGrid

                // Reset Action
                resetButtonRow
            }
            .padding()
        }
    }

    private var themeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            FormRow("Catppuccin Flavour") {
                Picker("", selection: Binding(
                    get: { settings.flavor },
                    set: { settings.flavor = $0 }
                )) {
                    ForEach(SettingsStore.Flavor.allCases, id: \.self) { flavor in
                        Text(flavor.displayName).tag(flavor)
                    }
                }
                .labelsHidden()
            }

            FormRow("Appearance") {
                Picker("", selection: Binding(
                    get: { settings.isDarkMode ? 1 : 0 },
                    set: { settings.isDarkMode = ($0 == 1) }
                )) {
                    Text("Light").tag(0)
                    Text("Dark").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            FormRow("Line Indicator") {
                ColorPicker("", selection: $lineIndicatorColor, supportsOpacity: true)
                    .labelsHidden()
                    .onChange(of: lineIndicatorColor) { newColor in
                        settings.lineIndicatorHex = hexString(from: newColor)
                    }
            }

            FormRow("Background") {
                HStack(spacing: 10) {
                    Toggle("Use palette default", isOn: $usePaletteBg)
                        .onChange(of: usePaletteBg) { isDefault in
                            if isDefault {
                                settings.backgroundHex = ""
                            } else {
                                settings.backgroundHex = hexString(from: customBgColor)
                            }
                        }

                    if !usePaletteBg {
                        ColorPicker("", selection: $customBgColor)
                            .labelsHidden()
                            .onChange(of: customBgColor) { newColor in
                                settings.backgroundHex = hexString(from: newColor)
                            }
                    }
                }
            }
        }
    }

    private var syntaxHeader: some View {
        Text("SYNTAX COLORS")
            .font(.caption)
            .fontWeight(.bold)
            .foregroundColor(.secondary)
    }

    private var syntaxGrid: some View {
        let roles = Theme.syntaxRoles
        return VStack(spacing: 10) {
            ForEach(0..<((roles.count + 1) / 2), id: \.self) { rowIdx in
                HStack(spacing: 16) {
                    let left = roles[rowIdx * 2]
                    HStack(spacing: 8) {
                        Text(left.displayName)
                            .font(.subheadline)
                            .frame(width: 120, alignment: .trailing)
                        syntaxPicker(for: left.role)
                    }

                    if rowIdx * 2 + 1 < roles.count {
                        let right = roles[rowIdx * 2 + 1]
                        HStack(spacing: 8) {
                            Text(right.displayName)
                                .font(.subheadline)
                                .frame(width: 120, alignment: .trailing)
                            syntaxPicker(for: right.role)
                        }
                    }
                }
            }
        }
    }

    private var resetButtonRow: some View {
        HStack {
            Spacer()
            Button("Reset Colors to Palette") {
                settings.backgroundHex = ""
                settings.lineIndicatorHex = ""
                settings.syntaxOverrides = [:]
                usePaletteBg = true
                lineIndicatorColor = Color(Theme.currentLine)
            }
            .buttonStyle(.bordered)
            Spacer()
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private func syntaxPicker(for role: String) -> some View {
        let currentAccent = currentAccentName(for: role)
        Picker("", selection: Binding(
            get: { currentAccent ?? "default" },
            set: { selected in
                var overrides = settings.syntaxOverrides
                if selected == "default" {
                    overrides.removeValue(forKey: role)
                } else {
                    overrides[role] = selected
                }
                settings.syntaxOverrides = overrides
            }
        )) {
            Text("Default (palette)").tag("default")
            ForEach(Theme.accentNames, id: \.self) { accent in
                Text(Theme.accentDisplayName(accent)).tag(accent)
            }
        }
        .labelsHidden()
        .frame(width: 130, alignment: .leading)
    }

    private func currentAccentName(for role: String) -> String? {
        guard let override = settings.syntaxOverride(for: role) else { return nil }
        if Theme.accentNames.contains(override) { return override }
        let lower = override.lowercased()
        for name in Theme.accentNames {
            if let hex = Theme.palette.color(name), hex.lowercased() == lower {
                return name
            }
        }
        return nil
    }

    private func hexString(from color: Color) -> String {
        guard let nsColor = NSColor(color).usingColorSpace(.sRGB) else { return "" }
        let r = Int((nsColor.redComponent * 255).rounded())
        let g = Int((nsColor.greenComponent * 255).rounded())
        let b = Int((nsColor.blueComponent * 255).rounded())
        return String(format: "%02X%02X%02X", r, g, b)
    }
}

// MARK: - Tab 2: Editor Settings View

struct EditorSettingsView: View {
    @ObservedObject var settings: SettingsStore

    private let availableFonts = [
        "System (SF Mono)", "Menlo", "Monaco", "Courier New",
        "JetBrains Mono", "Fira Code", "Latin Modern Mono", "Latin Modern Roman"
    ]

    var body: some View {
        Form {
            VStack(alignment: .leading, spacing: 14) {
                FormRow("Font Family") {
                    Picker("", selection: Binding(
                        get: {
                            let current = settings.fontFamily
                            return current.isEmpty ? "System (SF Mono)" : current
                        },
                        set: {
                            settings.fontFamily = $0 == "System (SF Mono)" ? "" : $0
                        }
                    )) {
                        ForEach(availableFonts, id: \.self) { font in
                            Text(font).tag(font)
                        }
                    }
                    .labelsHidden()
                }

                FormRow("Line Height") {
                    HStack(spacing: 8) {
                        Slider(value: Binding(
                            get: { settings.lineHeight },
                            set: { settings.lineHeight = $0 }
                        ), in: 1.2...1.6)
                        .frame(width: 150)

                        Text(String(format: "%.2fx", settings.lineHeight))
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(width: 50, alignment: .leading)
                    }
                }

                FormRow("Font Ligatures") {
                    Toggle("Enable font ligatures", isOn: Binding(
                        get: { settings.ligatures },
                        set: { settings.ligatures = $0 }
                    ))
                    .labelsHidden()
                }

                FormRow("Max Column Width") {
                    Picker("", selection: Binding(
                        get: { settings.maxColumnChars > 0 ? 1 : 0 },
                        set: { settings.maxColumnChars = ($0 == 0 ? 0 : 80) }
                    )) {
                        Text("Full width").tag(0)
                        Text("80 characters (centered)").tag(1)
                    }
                    .labelsHidden()
                }

                FormRow("Line Numbers") {
                    Picker("", selection: Binding(
                        get: { settings.gutterMode },
                        set: { settings.gutterMode = $0 }
                    )) {
                        ForEach(SettingsStore.GutterMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                }
            }
            .padding()
        }
    }
}

// MARK: - Tab 3: Flash Mode Settings View

struct FlashModeSettingsView: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Section: Rendering
                Group {
                    Text("RENDERING")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.secondary)

                    FormRow("Math Scale") {
                        HStack(spacing: 8) {
                            Slider(value: Binding(
                                get: { settings.mathScale },
                                set: { settings.mathScale = $0 }
                            ), in: 0.85...1.25)
                            .frame(width: 150)

                            Text(String(format: "%.0f%%", settings.mathScale * 100))
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.secondary)
                                .frame(width: 50, alignment: .leading)
                        }
                    }
                }

                Divider()

                // Section: Chip Overlay
                Group {
                    Text("CHIP OVERLAY")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.secondary)

                    FormRow("Background") {
                        Picker("", selection: Binding(
                            get: { settings.chipFill },
                            set: { settings.chipFill = $0 }
                        )) {
                            ForEach(SettingsStore.ChipFill.allCases, id: \.self) { fill in
                                Text(fill.displayName).tag(fill)
                            }
                        }
                        .labelsHidden()
                    }

                    FormRow("Padding") {
                        HStack(spacing: 8) {
                            Slider(value: Binding(
                                get: { settings.chipPadding },
                                set: { settings.chipPadding = $0 }
                            ), in: 0...12)
                            .frame(width: 150)

                            Text(String(format: "%.0f pt", settings.chipPadding))
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.secondary)
                                .frame(width: 50, alignment: .leading)
                        }
                    }

                    FormRow("Corner Radius") {
                        HStack(spacing: 8) {
                            Slider(value: Binding(
                                get: { settings.chipRadius },
                                set: { settings.chipRadius = $0 }
                            ), in: 2...8)
                            .frame(width: 150)

                            Text(String(format: "%.0f pt", settings.chipRadius))
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.secondary)
                                .frame(width: 50, alignment: .leading)
                        }
                    }
                }

                Divider()

                // Section: Compile & Render
                Group {
                    Text("COMPILE & RENDER")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.secondary)

                    FormRow("Debounce") {
                        HStack(spacing: 8) {
                            Slider(value: Binding(
                                get: { settings.renderDebounceMs },
                                set: { settings.renderDebounceMs = $0 }
                            ), in: 50...500)
                            .frame(width: 150)

                            Text(String(format: "%.0f ms", settings.renderDebounceMs))
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.secondary)
                                .frame(width: 50, alignment: .leading)
                        }
                    }

                    FormRow("Unfold Trigger") {
                        Picker("", selection: Binding(
                            get: { settings.unfoldTrigger },
                            set: { settings.unfoldTrigger = $0 }
                        )) {
                            ForEach(SettingsStore.UnfoldTrigger.allCases, id: \.self) { trigger in
                                Text(trigger.displayName).tag(trigger)
                            }
                        }
                        .labelsHidden()
                    }
                }
            }
            .padding()
        }
    }
}

// MARK: - Tab 4: Vim Settings View

struct VimSettingsView: View {
    @ObservedObject var settings: SettingsStore
    @State private var showCheatsheet = false

    var body: some View {
        Form {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Toggle("Enable Vim-style editing", isOn: Binding(
                        get: { settings.vimMode },
                        set: { settings.vimMode = $0 }
                    ))

                    Button(action: { showCheatsheet.toggle() }) {
                        Image(systemName: "questionmark.circle")
                            .font(.body)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Show Vim keyboard shortcuts")
                    .popover(isPresented: $showCheatsheet, arrowEdge: .trailing) {
                        VimCheatsheetPopover()
                    }
                }

                Text("Modal editing in the main editor and Flash Mode with motions, line operations, put, and undo.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding()
        }
    }
}

// MARK: - Structured Vim Cheatsheet Popover

struct VimCheatsheetPopover: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Vim Editor Shortcuts")
                    .font(.headline)
                    .padding(.bottom, 4)

                Group {
                    CategoryHeader("Modes & Basic Navigation")
                    ShortcutGrid([
                        (["Esc"], "Normal mode"),
                        (["i", "I", "a", "A"], "Insert: after cursor / line start / after char / line end"),
                        (["o", "O"], "New line below / above"),
                        (["h", "j", "k", "l"], "Cursor motions"),
                        (["w", "b", "e"], "Word motions"),
                        (["0", "^", "$"], "Line start / first non-blank / line end")
                    ])
                }

                Group {
                    CategoryHeader("Editing & File Navigation")
                    ShortcutGrid([
                        (["gg", "G", "\\{n\\}G"], "Document start / end / nth line"),
                        (["v"], "Visual mode — move to select, then y / d"),
                        (["x", "X"], "Delete char under / before cursor"),
                        (["D", "C"], "Delete / change to end of line"),
                        (["dd", "yy", "p", "P"], "Delete / yank line, paste after / before"),
                        (["cw", "dw", "d$", "y$"], "Change / delete / yank with a motion"),
                        (["u"], "Undo (⌘Z also works)")
                    ])
                }
            }
            .padding()
        }
        .frame(width: 420, height: 450)
    }

    @ViewBuilder
    private func CategoryHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption)
            .fontWeight(.bold)
            .foregroundColor(.secondary)
    }
}

// MARK: - Grid Alignment Components

struct ShortcutGrid: View {
    let items: [([String], String)]

    init(_ items: [([String], String)]) {
        self.items = items
    }

    var body: some View {
        if #available(macOS 13.0, *) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                ForEach(items, id: \.1) { keys, description in
                    GridRow {
                        keyBadges(keys)
                            .gridColumnAlignment(.trailing)

                        Text(description)
                            .font(.body)
                            .foregroundColor(.primary)
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(items, id: \.1) { keys, description in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        keyBadges(keys)
                            .frame(width: 140, alignment: .trailing)

                        Text(description)
                            .font(.body)
                            .foregroundColor(.primary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func keyBadges(_ keys: [String]) -> some View {
        HStack(spacing: 3) {
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .font(.system(.subheadline, design: .monospaced))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
                    )
            }
        }
    }
}
