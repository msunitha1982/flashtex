import Foundation

// SettingsStore — every user-tunable setting, persisted in UserDefaults.
//
// The Preferences window (⌘,) reads and writes through this store. Every
// mutation posts `SettingsStore.changedNotification` on the main thread with
// the changed key in `userInfo`, so the editor, highlighter, preview and Flash
// folding view can re-apply just the parts that matter without restarting.

final class SettingsStore: ObservableObject {

    static let shared = SettingsStore()

    /// Posted (main thread) after any setting changes. `userInfo["key"]` is the
    /// `Key` that changed; a nil key means "everything" (e.g. theme profile).
    static let changedNotification = Notification.Name("FlashTeX.SettingsChanged")

    // MARK: - Keys

    enum Key: String {
        case appearanceMode     // "light" | "dark"
        case flavor             // "latte" | "frappe" | "macchiato" | "mocha"
        case lineIndicatorHex
        case backgroundHex      // "" = use palette
        case syntaxOverrides    // [role: hex]

        case fontFamily         // display name ("" = system default)
        case lineHeight         // 1.2…1.6
        case ligatures
        case maxColumnChars     // 0 = full width, else centered column
        case gutterMode         // "none" | "absolute" | "relative"
        case permanentMacros    // [String] \newcommand-style definitions injected into new documents

        case mathScale          // 0.85…1.25
        case chipFill           // "solid" | "transparent"
        case chipPadding
        case chipRadius
        case renderDebounceMs   // 50…500
        case unfoldTrigger      // "click" | "hover" | "caret"

        case vimMode
    }

    // MARK: - Enums

    enum AppearanceMode: String {
        case light, dark
    }

    enum Flavor: String, CaseIterable {
        case latte, frappe, macchiato, mocha
        var displayName: String {
            switch self {
            case .latte: return "Latte (light)"
            case .frappe: return "Frappé (dark)"
            case .macchiato: return "Macchiato (dark)"
            case .mocha: return "Mocha (dark)"
            }
        }
        var isDark: Bool { self != .latte }
    }

    enum GutterMode: String, CaseIterable {
        case none, absolute, relative
        var displayName: String {
            switch self {
            case .none: return "None"
            case .absolute: return "Absolute (1, 2, 3…)"
            case .relative: return "Relative (Vim-style)"
            }
        }
    }

    enum ChipFill: String, CaseIterable {
        case solid, transparent
        var displayName: String {
            switch self {
            case .solid: return "Solid"
            case .transparent: return "Transparent"
            }
        }
    }

    enum UnfoldTrigger: String, CaseIterable {
        case click, hover, caret
        var displayName: String {
            switch self {
            case .click: return "Click"
            case .hover: return "Hover"
            case .caret: return "Cursor placement"
            }
        }
    }

    // MARK: - Defaults

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // v1 stored the dark-mode indicator hex as the default for every mode;
        // "" now means "follow the flavour's default for the current mode".
        if defaults.string(forKey: Key.lineIndicatorHex.rawValue) == "2A2F41" {
            defaults.set("", forKey: Key.lineIndicatorHex.rawValue)
        }
        let initial: [String: Any] = [
            Key.appearanceMode.rawValue: AppearanceMode.light.rawValue,
            Key.flavor.rawValue: Flavor.latte.rawValue,
            Key.lineIndicatorHex.rawValue: "",
            Key.backgroundHex.rawValue: "",
            Key.syntaxOverrides.rawValue: [:],
            Key.fontFamily.rawValue: "",
            Key.lineHeight.rawValue: 1.3,
            Key.ligatures.rawValue: false,
            Key.maxColumnChars.rawValue: 0,
            Key.gutterMode.rawValue: GutterMode.absolute.rawValue,
            Key.permanentMacros.rawValue: [],
            Key.mathScale.rawValue: 1.0,
            Key.chipFill.rawValue: ChipFill.solid.rawValue,
            Key.chipPadding.rawValue: 4.0,
            Key.chipRadius.rawValue: 4.0,
            Key.renderDebounceMs.rawValue: 400.0,
            Key.unfoldTrigger.rawValue: UnfoldTrigger.click.rawValue,
            Key.vimMode.rawValue: false,
        ]
        defaults.register(defaults: initial)
    }

    // MARK: - Mutation

    private func set(_ value: Any?, _ key: Key) {
        objectWillChange.send()
        defaults.set(value, forKey: key.rawValue)
        NotificationCenter.default.post(name: Self.changedNotification,
                                        object: self,
                                        userInfo: ["key": key.rawValue])
    }

    private func string(_ key: Key) -> String {
        defaults.string(forKey: key.rawValue) ?? ""
    }

    // MARK: - Appearance

    var appearanceMode: AppearanceMode {
        get { AppearanceMode(rawValue: string(.appearanceMode)) ?? .light }
        set { set(newValue.rawValue, .appearanceMode) }
    }

    /// The active Catppuccin flavor. Picking a flavor in Preferences also
    /// locks the appearance to match it (dark flavors → dark appearance).
    var flavor: Flavor {
        get { Flavor(rawValue: string(.flavor)) ?? .latte }
        set {
            set(newValue.rawValue, .flavor)
            if appearanceMode.rawValue != (newValue.isDark ? "dark" : "light") {
                defaults.set(newValue.isDark ? "dark" : "light",
                             forKey: Key.appearanceMode.rawValue)
                NotificationCenter.default.post(name: Self.changedNotification,
                                                object: self,
                                                userInfo: ["key": Key.appearanceMode.rawValue])
            }
        }
    }

    /// Quick light ⇄ dark switch. Light → Latte, dark → Mocha.
    var isDarkMode: Bool {
        get { appearanceMode == .dark }
        set {
            appearanceMode = newValue ? .dark : .light
            flavor = newValue ? .mocha : .latte
        }
    }

    /// Line indicator (current line) colour as "RRGGBB". "" means "follow the
    /// mode-aware default" (see `Theme.currentLine`).
    var lineIndicatorHex: String {
        get { string(.lineIndicatorHex) }
        set { set(newValue, .lineIndicatorHex) }
    }

    /// Override for the editor background as "RRGGBB", or "" for the palette.
    var backgroundHex: String {
        get { string(.backgroundHex) }
        set { set(newValue, .backgroundHex) }
    }

    /// Syntax colour overrides keyed by role (e.g. "command", "math"). Values
    /// are Catppuccin accent names (e.g. "rosewater") or absolute hex.
    var syntaxOverrides: [String: String] {
        get { defaults.dictionary(forKey: Key.syntaxOverrides.rawValue) as? [String: String] ?? [:] }
        set { set(newValue, .syntaxOverrides) }
    }

    func syntaxOverride(for role: String) -> String? {
        let v = syntaxOverrides[role] ?? ""
        return v.isEmpty ? nil : v
    }

    // MARK: - Editor

    /// Font family display name ("" = system default SF Mono).
    var fontFamily: String {
        get { string(.fontFamily) }
        set { set(newValue, .fontFamily) }
    }

    var lineHeight: CGFloat {
        get { CGFloat(defaults.double(forKey: Key.lineHeight.rawValue).clamped(to: 1.0...1.8)) }
        set { set(Double(newValue), .lineHeight) }
    }

    var ligatures: Bool {
        get { defaults.bool(forKey: Key.ligatures.rawValue) }
        set { set(newValue, .ligatures) }
    }

    /// Centred text column width in characters; 0 = full window width.
    var maxColumnChars: Int {
        get { defaults.integer(forKey: Key.maxColumnChars.rawValue) }
        set { set(newValue, .maxColumnChars) }
    }

    var gutterMode: GutterMode {
        get { GutterMode(rawValue: string(.gutterMode)) ?? .absolute }
        set { set(newValue.rawValue, .gutterMode) }
    }

    /// "Permanent macros" — \newcommand-style definitions that are injected
    /// into the preamble of every new document (see `Theme.welcomeDocument`),
    /// so they apply across all LaTeX files without being typed per-file.
    var permanentMacros: [String] {
        get { defaults.stringArray(forKey: Key.permanentMacros.rawValue) ?? [] }
        set { set(newValue, .permanentMacros) }
    }

    // MARK: - Flash Mode & preview rendering

    /// Scale of rendered math relative to the editor font (0.85…1.25).
    var mathScale: CGFloat {
        get { CGFloat(defaults.double(forKey: Key.mathScale.rawValue).clamped(to: 0.85...1.25)) }
        set { set(Double(newValue), .mathScale) }
    }

    var chipFill: ChipFill {
        get { ChipFill(rawValue: string(.chipFill)) ?? .solid }
        set { set(newValue.rawValue, .chipFill) }
    }

    var chipPadding: CGFloat {
        get { CGFloat(defaults.double(forKey: Key.chipPadding.rawValue).clamped(to: 0...12)) }
        set { set(Double(newValue), .chipPadding) }
    }

    var chipRadius: CGFloat {
        get { CGFloat(defaults.double(forKey: Key.chipRadius.rawValue).clamped(to: 2...8)) }
        set { set(Double(newValue), .chipRadius) }
    }

    /// Debounce before the main document auto-compiles (ms).
    var renderDebounceMs: Double {
        get { defaults.double(forKey: Key.renderDebounceMs.rawValue).clamped(to: 50...500) }
        set { set(newValue, .renderDebounceMs) }
    }

    var unfoldTrigger: UnfoldTrigger {
        get { UnfoldTrigger(rawValue: string(.unfoldTrigger)) ?? .click }
        set { set(newValue.rawValue, .unfoldTrigger) }
    }

    // MARK: - Vim

    var vimMode: Bool {
        get { defaults.bool(forKey: Key.vimMode.rawValue) }
        set { set(newValue, .vimMode) }
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
