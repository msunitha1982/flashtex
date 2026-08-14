import AppKit

// Theme — the app's colour and typography theme.
//
// Unlike the old design (dynamic NSColors that followed the system
// appearance), the appearance is now a user setting (light by default) and the
// palette is a user-chosen Catppuccin flavour. All colours here resolve at
// call time from `SettingsStore`, so views that repaint after a settings
// change automatically reflect the new theme without restarting.

enum Theme {

    static let settings = SettingsStore.shared

    // =====================================================================
    //  Active palette
    // =====================================================================

    static var palette: CatppuccinFlavor {
        CatppuccinPalette.load(settings.flavor)
    }

    /// The 14 Catppuccin accents (palette order) offered in the syntax
    /// colour pickers. Values are palette role names, not hexes, so a chosen
    /// accent tracks the active flavour.
    static let accentNames = [
        "rosewater", "flamingo", "pink", "mauve", "red", "maroon",
        "peach", "yellow", "green", "teal", "sky", "sapphire", "blue", "lavender",
    ]

    static func accentDisplayName(_ name: String) -> String {
        name.capitalized
    }

    /// Resolve a palette role for the current mode. Catppuccin's `overlay`
    /// tones are for muted UI chrome, not text — in light mode they're far too
    /// faint against `base`, so text roles use the readable `subtext0` instead.
    /// Orange (peach) is also avoided for default syntax in light mode.
    private static func roleForMode(_ role: String) -> String {
        guard !settings.isDarkMode else { return role }
        switch role {
        case "overlay0", "overlay1", "overlay2": return "subtext0"
        case "peach": return "sapphire"
        default: return role
        }
    }

    /// Colour for a Catppuccin role, honouring per-role overrides. An override
    /// is either a palette accent name (e.g. "rosewater") or an absolute
    /// "RRGGBB" hex.
    static func c(_ role: String, overrideKey: String? = nil) -> NSColor {
        if let key = overrideKey, let override = settings.syntaxOverride(for: key) {
            if accentNames.contains(override),
               let accentHex = palette.color(override),
               let c = nsColor(from: accentHex) { return c }
            if let c = nsColor(from: override) { return c }
        }
        return nsColor(role)
    }

    static func nsColor(_ role: String) -> NSColor {
        let resolved = roleForMode(role)
        guard let hex = palette.color(resolved) else {
            return NSColor.labelColor
        }
        return nsColor(from: hex) ?? NSColor.labelColor
    }

    /// Hex "RRGGBB" of a palette role (used to tint the rendered math images).
    static func hex(_ role: String) -> String {
        palette.color(role) ?? "4C4F69"
    }

    static func nsColor(from hex: String) -> NSColor? {
        let s = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                       green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255,
                       alpha: 1)
    }

    // =====================================================================
    //  Typography
    // =====================================================================

    /// Base editor font size in points (also the zoom target).
    static var editorFontSize: CGFloat = 13

    /// The monospaced (or user-selected) editor font at the current size.
    static var editorFont: NSFont {
        editorFont(ofSize: editorFontSize)
    }

    static func editorFont(ofSize size: CGFloat) -> NSFont {
        let family = settings.fontFamily
        if !family.isEmpty,
           let font = NSFontManager.shared.font(withFamily: family,
                                                traits: [],
                                                weight: 5,          // NSFontWeightRegular
                                                size: size) {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static let gutterFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    /// Exact line height for an editor font, scaled by the user's multiplier
    /// (1.2…1.6×). `minimumLineHeight` is set to this so wrapping and gutter
    /// geometry stay consistent while glyphs are never clipped.
    static func lineHeight(forFont font: NSFont) -> CGFloat {
        let natural = font.ascender - font.descender + font.leading
        return natural * settings.lineHeight
    }

    // =====================================================================
    //  Surfaces (from the active flavour, with user overrides)
    // =====================================================================

    static var editorBackground: NSColor {
        if !settings.backgroundHex.isEmpty,
           let c = nsColor(from: settings.backgroundHex) { return c }
        return nsColor("base")
    }

    static var editorText: NSColor {
        let base = nsColor("text")
        guard !settings.isDarkMode else { return base }
        // Light mode: Catppuccin's "text" is a little soft against "base".
        // Darken it toward near-black so normal text has real punch.
        return base.blended(withFraction: 0.3, of: .black) ?? base
    }
    static var editorTextHex: String {
        if settings.isDarkMode { return hex("text") }
        guard let rgb = editorText.usingColorSpace(.sRGB) else { return hex("text") }
        return String(format: "%02X%02X%02X",
                      Int((rgb.redComponent * 255).rounded()),
                      Int((rgb.greenComponent * 255).rounded()),
                      Int((rgb.blueComponent * 255).rounded()))
    }
    static var gutterText: NSColor { nsColor("overlay1") }
    /// Brighter line number for the line the caret is on.
    static var gutterTextActive: NSColor { nsColor("text") }
    static var mathFoldBackground: NSColor { nsColor("surface0") }
    static var previewBackground: NSColor { nsColor("mantle") }
    static var accent: NSColor { nsColor("blue") }
    static var secondaryText: NSColor { nsColor("overlay2") }
    static var separator: NSColor { nsColor("surface1") }

    /// Base tint used by the current-line indicator. When the user hasn't
    /// picked a custom colour the indicator follows the palette accent, so the
    /// highlight feels native and adapts to the current flavour.
    static var currentLineBase: NSColor {
        let hex = settings.lineIndicatorHex.isEmpty ? nil : settings.lineIndicatorHex
        return hex.flatMap { nsColor(from: $0) } ?? accent
    }

    /// Faint, modern full-line highlight behind the caret line — a whisper of
    /// the accent tint, never a solid band.
    static var currentLine: NSColor {
        currentLineBase.withAlphaComponent(0.12)
    }

    static var flashBlockBackground: NSColor {
        nsColor("blue").withAlphaComponent(0.16)
    }

    // =====================================================================
    //  Syntax highlighting (overridable per role)
    // =====================================================================

    static var syntaxCommand: NSColor { c("mauve", overrideKey: "command") }
    static var syntaxKeyword: NSColor { c("yellow", overrideKey: "keyword") }
    static var syntaxComment: NSColor { c("overlay0", overrideKey: "comment") }
    static var syntaxMath: NSColor { c("teal", overrideKey: "math") }
    static var syntaxSpecial: NSColor { c("lavender", overrideKey: "special") }
    static var syntaxEnvironment: NSColor { c("yellow", overrideKey: "environment") }
    static var syntaxMandatoryArg: NSColor { c("peach", overrideKey: "mandatoryArg") }
    static var syntaxOptionalParam: NSColor { c("green", overrideKey: "optionalParam") }
    static var syntaxReference: NSColor { c("sky", overrideKey: "reference") }
    static var syntaxEmbedded: NSColor { c("flamingo", overrideKey: "embedded") }
    static var syntaxDelimiter: NSColor { c("lavender", overrideKey: "delimiter") }

    /// Role names the Settings pane exposes for colour overrides.
    static let syntaxRoles: [(role: String, displayName: String)] = [
        ("command", "Command"),
        ("keyword", "Keyword"),
        ("math", "Math"),
        ("environment", "Environment"),
        ("mandatoryArg", "Mandatory argument"),
        ("optionalParam", "Optional parameter"),
        ("reference", "Reference"),
        ("comment", "Comment"),
        ("embedded", "Embedded code"),
        ("delimiter", "Delimiter"),
    ]

    // =====================================================================
    //  Welcome document shown on first launch
    // =====================================================================

    /// The new-document template. Permanent macros from Settings are injected
    /// into the preamble (after the last `\usepackage`) so they apply to every
    /// document the user creates, without being typed per-file.
    static var welcomeDocument: String {
        let macros = SettingsStore.shared.permanentMacros
        guard !macros.isEmpty else { return baseWelcomeDocument }

        var lines = baseWelcomeDocument.components(separatedBy: "\n")
        // Find where the preamble's package includes end (in the template they
        // sit right before the blank line preceding \title).
        var insertAt: Int?
        for (i, line) in lines.enumerated().reversed() {
            if line.hasPrefix("\\documentclass") || line.hasPrefix("\\usepackage") {
                insertAt = i + 1
                break
            }
        }
        guard let insertAt else { return baseWelcomeDocument }
        // `insertAt` is the template's blank line after the packages. Keep that
        // blank, then the macros, then one blank before \title.
        lines.insert(contentsOf: macros, at: insertAt + 1)
        lines.insert("", at: insertAt + 1 + macros.count)
        return lines.joined(separator: "\n")
    }

    private static let baseWelcomeDocument = """
    % FlashTeX — live LaTeX at native speed
    %
    % Type on the left. When you pause, a background process runs
    % `pdflatex` and this document is previewed on the right.

    \\documentclass[11pt]{article}
    \\usepackage[margin=1in]{geometry}
    \\usepackage{amsmath, amssymb}

    \\title{FlashTeX}
    \\author{native Swift / AppKit build}
    \\date{}

    \\begin{document}
    \\maketitle

    \\section{Welcome}
    You are editing on the left. When you pause typing, a background worker
    spawns \\texttt{pdflatex}, parses the log, and the preview refreshes.

    \\begin{equation}
    e^{i\\pi} + 1 = 0
    \\end{equation}

    \\begin{itemize}
    \\item Zero UI latency
    \\item Native AppKit controls
    \\item Live PDF preview via PDFKit
    \\end{itemize}

    \\end{document}
    """
}
