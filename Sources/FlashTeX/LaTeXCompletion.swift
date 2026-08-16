import Foundation

// LaTeXCompletion — the autocomplete dictionary for the editor.
//
// Every entry maps a LaTeX command (including the backslash) to a snippet
// template. Templates may contain placeholders, written as
// `\u{E000}default\u{E000}` — the editor strips the markers, inserts the
// literal text, and selects the first placeholder so the user can type
// straight over it. Commands without placeholders insert verbatim.

enum LaTeXCompletion {

    /// The placeholder delimiter used inside snippet templates.
    static let placeholder: Unicode.Scalar = "\u{E000}"

    /// command → snippet template. The command is the completion shown in the
    /// window and matched against what the user typed.
    static let snippets: [String: String] = {
        let P = placeholder
        func ph(_ content: String = "") -> String { "\(P)\(content)\(P)" }

        return [
            // Structural
            "\\documentclass": "\\documentclass{\(ph("article"))}",
            "\\usepackage": "\\usepackage{\(ph(""))}",
            "\\begin": "\\begin{\(ph(""))}",
            "\\end": "\\end{\(ph(""))}",
            "\\section": "\\section{\(ph("Title"))}",
            "\\subsection": "\\subsection{\(ph("Title"))}",
            "\\subsubsection": "\\subsubsection{\(ph("Title"))}",
            "\\paragraph": "\\paragraph{\(ph("Title"))}",
            "\\title": "\\title{\(ph(""))}",
            "\\author": "\\author{\(ph(""))}",
            "\\date": "\\date{\(ph(""))}",

            // Text
            "\\text": "\\text{\(ph(""))}",
            "\\textbf": "\\textbf{\(ph(""))}",
            "\\textit": "\\textit{\(ph(""))}",
            "\\texttt": "\\texttt{\(ph(""))}",
            "\\textrm": "\\textrm{\(ph(""))}",
            "\\emph": "\\emph{\(ph(""))}",
            "\\underline": "\\underline{\(ph(""))}",
            "\\overline": "\\overline{\(ph(""))}",
            "\\mbox": "\\mbox{\(ph(""))}",
            "\\footnote": "\\footnote{\(ph(""))}",
            "\\item": "\\item ",
            "\\label": "\\label{\(ph(""))}",
            "\\ref": "\\ref{\(ph(""))}",
            "\\eqref": "\\eqref{\(ph(""))}",
            "\\cite": "\\cite{\(ph(""))}",
            "\\input": "\\input{\(ph(""))}",
            "\\include": "\\include{\(ph(""))}",
            "\\includegraphics": "\\includegraphics{\(ph(""))}",

            // Math
            "\\frac": "\\frac{\(ph("num"))}{\(ph("den"))}",
            "\\tfrac": "\\tfrac{\(ph(""))}{\(ph(""))}",
            "\\dfrac": "\\dfrac{\(ph(""))}{\(ph(""))}",
            "\\sqrt": "\\sqrt{\(ph(""))}",
            "\\sum": "\\sum_{\(ph("i=1"))}^{\(ph("n"))}",
            "\\prod": "\\prod_{\(ph(""))}^{\(ph(""))}",
            "\\int": "\\int_{\(ph(""))}^{\(ph(""))}",
            "\\lim": "\\lim_{\(ph("x \\to \\infty"))}",
            "\\limsup": "\\limsup_{\(ph(""))}",
            "\\liminf": "\\liminf_{\(ph(""))}",
            "\\sup": "\\sup_{\(ph(""))}",
            "\\inf": "\\inf_{\(ph(""))}",
            "\\min": "\\min_{\(ph(""))}",
            "\\max": "\\max_{\(ph(""))}",
            "\\exp": "\\exp(\(ph(""))",
            "\\log": "\\log(\(ph(""))",
            "\\ln": "\\ln(\(ph(""))",
            "\\sin": "\\sin(\(ph(""))",
            "\\cos": "\\cos(\(ph(""))",
            "\\tan": "\\tan(\(ph(""))",
            "\\arcsin": "\\arcsin(\(ph(""))",
            "\\arccos": "\\arccos(\(ph(""))",
            "\\arctan": "\\arctan(\(ph(""))",
            "\\sinh": "\\sinh(\(ph(""))",
            "\\cosh": "\\cosh(\(ph(""))",
            "\\tanh": "\\tanh(\(ph(""))",
            "\\left": "\\left( \(ph(""))",
            "\\right": "\\right) \(ph(""))",
            "\\begin{cases}": "\\begin{cases}\n\(ph("")) \\\\\n\\end{cases}",
            "\\overset": "\\overset{\(ph(""))}{\(ph(""))}",
            "\\underset": "\\underset{\(ph(""))}{\(ph(""))}",
            "\\hat": "\\hat{\(ph(""))}",
            "\\bar": "\\bar{\(ph(""))}",
            "\\vec": "\\vec{\(ph(""))}",
            "\\dot": "\\dot{\(ph(""))}",
            "\\ddot": "\\ddot{\(ph(""))}",
            "\\partial": "\\partial ",
            "\\nabla": "\\nabla ",
            "\\infty": "\\infty",
            "\\in": "\\in",
            "\\notin": "\\notin",
            "\\subset": "\\subset",
            "\\subseteq": "\\subseteq",
            "\\supset": "\\supset",
            "\\supseteq": "\\supseteq",
            "\\cup": "\\cup",
            "\\cap": "\\cap",
            "\\setminus": "\\setminus",
            "\\emptyset": "\\emptyset",
            "\\mathbb": "\\mathbb{\(ph("R"))}",

            // Relations
            "\\leq": "\\leq",
            "\\geq": "\\geq",
            "\\neq": "\\neq",
            "\\approx": "\\approx",
            "\\equiv": "\\equiv",
            "\\sim": "\\sim",
            "\\propto": "\\propto",
            "\\ll": "\\ll",
            "\\gg": "\\gg",
            "\\pm": "\\pm",
            "\\mp": "\\mp",
            "\\times": "\\times",
            "\\div": "\\div",
            "\\cdot": "\\cdot",
            "\\ast": "\\ast",
            "\\star": "\\star",
            "\\circ": "\\circ",
            "\\bullet": "\\bullet",
            "\\oplus": "\\oplus",
            "\\otimes": "\\otimes",
            "\\to": "\\to",
            "\\rightarrow": "\\rightarrow",
            "\\leftarrow": "\\leftarrow",
            "\\Leftarrow": "\\Leftarrow",
            "\\Rightarrow": "\\Rightarrow",
            "\\Leftrightarrow": "\\Leftrightarrow",
            "\\mapsto": "\\mapsto",

            // Greek (lowercase)
            "\\alpha": "\\alpha",
            "\\beta": "\\beta",
            "\\gamma": "\\gamma",
            "\\delta": "\\delta",
            "\\epsilon": "\\epsilon",
            "\\varepsilon": "\\varepsilon",
            "\\zeta": "\\zeta",
            "\\eta": "\\eta",
            "\\theta": "\\theta",
            "\\vartheta": "\\vartheta",
            "\\iota": "\\iota",
            "\\kappa": "\\kappa",
            "\\lambda": "\\lambda",
            "\\mu": "\\mu",
            "\\nu": "\\nu",
            "\\xi": "\\xi",
            "\\pi": "\\pi",
            "\\rho": "\\rho",
            "\\sigma": "\\sigma",
            "\\tau": "\\tau",
            "\\upsilon": "\\upsilon",
            "\\phi": "\\phi",
            "\\varphi": "\\varphi",
            "\\chi": "\\chi",
            "\\psi": "\\psi",
            "\\omega": "\\omega",

            // Greek (uppercase)
            "\\Gamma": "\\Gamma",
            "\\Delta": "\\Delta",
            "\\Theta": "\\Theta",
            "\\Lambda": "\\Lambda",
            "\\Xi": "\\Xi",
            "\\Pi": "\\Pi",
            "\\Sigma": "\\Sigma",
            "\\Upsilon": "\\Upsilon",
            "\\Phi": "\\Phi",
            "\\Psi": "\\Psi",
            "\\Omega": "\\Omega",

            // Misc
            "\\ldots": "\\ldots",
            "\\cdots": "\\cdots",
            "\\vdots": "\\vdots",
            "\\ddots": "\\ddots",
            "\\quad": "\\quad",
            "\\qquad": "\\qquad",
            "\\enspace": "\\enspace",
            "\\thinspace": "\\thinspace",
            "\\hspace": "\\hspace{\(ph("1cm"))}",
            "\\vspace": "\\vspace{\(ph("1cm"))}",
            "\\newline": "\\newline",
            "\\hline": "\\hline",
            "\\bigskip": "\\bigskip",
            "\\medskip": "\\medskip",
            "\\smallskip": "\\smallskip",
            "\\centering": "\\centering",
            "\\noindent": "\\noindent",
            "\\dots": "\\dots",
        ]
    }()

    /// All command names, sorted for a stable completion list.
    static var commands: [String] {
        snippets.keys.sorted { $0.lowercased() < $1.lowercased() }
    }

    /// Commands matching the typed partial (case-insensitive prefix).
    static func matches(partial: String) -> [String] {
        let needle = partial.lowercased()
        return commands.filter { $0.lowercased().hasPrefix(needle) }
    }

    /// A one-line rendering of what the completed snippet will look like, used
    /// as the gray preview shown next to each command in the completion panel.
    /// Placeholders keep their default text so the shape of the insertion is
    /// obvious (`\frac` → `\frac{num}{den}`).
    static func preview(for command: String) -> String {
        guard let template = snippets[command] else { return command }
        let (text, _) = assemble(template)
        return text.isEmpty ? command : text
    }

    /// Split a snippet template into literal text and placeholder ranges.
    /// Placeholder default text (e.g. `num` in `\frac{num}{den}`) is dropped,
    /// so an accepted completion pastes `\frac{}{}` with the parameters left
    /// empty; the editor then places the caret on the first placeholder.
    /// Returns the insertable string and the character ranges (offset within
    /// the returned string) of every placeholder.
    static func assemble(_ template: String) -> (text: String, placeholders: [NSRange]) {
        let scalars = Array(template.unicodeScalars)
        var text = ""
        var placeholders: [NSRange] = []
        var inPlaceholder = false
        var placeholderStart = 0

        for scalar in scalars {
            if scalar == placeholder {
                if inPlaceholder {
                    placeholders.append(NSRange(location: placeholderStart, length: 0))
                } else {
                    placeholderStart = (text as NSString).length
                }
                inPlaceholder.toggle()
            } else if !inPlaceholder {
                text.unicodeScalars.append(scalar)
            }
        }
        return (text, placeholders)
    }
}