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

    /// Colour for a Catppuccin role, honouring per-role syntax overrides.
    static func c(_ role: String, overrideKey: String? = nil) -> NSColor {
        if let key = overrideKey, let hex = settings.syntaxOverride(for: key) {
            return nsColor(from: hex) ?? nsColor(role)
        }
        return nsColor(role)
    }

    static func nsColor(_ role: String) -> NSColor {
        guard let hex = palette.color(role) else {
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

    static let gutterFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

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

    static var editorText: NSColor { nsColor("text") }
    static var editorTextHex: String { hex("text") }
    static var gutterBackground: NSColor { nsColor("mantle") }
    static var gutterText: NSColor { nsColor("overlay1") }
    static var mathFoldBackground: NSColor { nsColor("surface0") }
    static var previewBackground: NSColor { nsColor("mantle") }
    static var accent: NSColor { nsColor("blue") }
    static var secondaryText: NSColor { nsColor("overlay2") }
    static var separator: NSColor { nsColor("surface1") }

    /// Mode-aware current-line highlight. The two modes get visibly different
    /// tints (a soft gray on light Catppuccin, a deep gray on dark), drawn at
    /// partial opacity so the line is only hinted at, never painted solid.
    static var currentLine: NSColor {
        let hex = settings.lineIndicatorHex.isEmpty ? defaultCurrentLineHex
                                                    : settings.lineIndicatorHex
        let base = nsColor(from: hex) ?? nsColor("blue")
        let alpha: CGFloat = settings.isDarkMode ? 0.5 : 0.45
        return base.withAlphaComponent(alpha)
    }

    /// Per-mode default line-indicator tint when the user hasn't overridden it.
    static var defaultCurrentLineHex: String {
        settings.isDarkMode ? "2A2F41" : "C4C8D3"
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

    static let welcomeDocument = """
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
