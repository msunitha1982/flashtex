import SwiftUI
import AppKit

// MARK: - Palette Data Models

public struct PaletteItem: Identifiable, Hashable {
    public let id = UUID()
    public let title: String
    public let subtitle: String
    public let category: String
    public let insertText: String
    public let cursorOffset: Int?

    public func hash(into hasher: inout Hasher) {
        hasher.combine(title)
        hasher.combine(category)
    }

    public static func == (lhs: PaletteItem, rhs: PaletteItem) -> Bool {
        lhs.title == rhs.title && lhs.category == rhs.category
    }
}

public class CommandPaletteStore {
    public static let items: [PaletteItem] = [
        // Environments
        PaletteItem(title: "matrix (Bracket Matrix)", subtitle: "\\begin{bmatrix} ... \\end{bmatrix}", category: "Environment", insertText: "\\begin{bmatrix}\n    \n\\end{bmatrix}", cursorOffset: 21),
        PaletteItem(title: "pmatrix (Parenthesis Matrix)", subtitle: "\\begin{pmatrix} ... \\end{pmatrix}", category: "Environment", insertText: "\\begin{pmatrix}\n    \n\\end{pmatrix}", cursorOffset: 21),
        PaletteItem(title: "vmatrix (Determinant Matrix)", subtitle: "\\begin{vmatrix} ... \\end{vmatrix}", category: "Environment", insertText: "\\begin{vmatrix}\n    \n\\end{vmatrix}", cursorOffset: 21),
        PaletteItem(title: "equation (Numbered Math)", subtitle: "\\begin{equation} ... \\end{equation}", category: "Environment", insertText: "\\begin{equation}\n    \n\\end{equation}", cursorOffset: 22),
        PaletteItem(title: "equation* (Unnumbered Math)", subtitle: "\\begin{equation*} ... \\end{equation*}", category: "Environment", insertText: "\\begin{equation*}\n    \n\\end{equation*}", cursorOffset: 23),
        PaletteItem(title: "align (Multi-line Aligned Math)", subtitle: "\\begin{align} ... \\end{align}", category: "Environment", insertText: "\\begin{align}\n    \n\\end{align}", cursorOffset: 19),
        PaletteItem(title: "align* (Unnumbered Aligned)", subtitle: "\\begin{align*} ... \\end{align*}", category: "Environment", insertText: "\\begin{align*}\n    \n\\end{align*}", cursorOffset: 20),
        PaletteItem(title: "cases (Piecewise Function)", subtitle: "\\begin{cases} ... \\end{cases}", category: "Environment", insertText: "\\begin{cases}\n    \n\\end{cases}", cursorOffset: 19),
        PaletteItem(title: "figure (Centered Image Block)", subtitle: "\\begin{figure}[h] ... \\end{figure}", category: "Environment", insertText: "\\begin{figure}[h]\n    \\centering\n    \\includegraphics[width=0.8\\textwidth]{}\n    \\caption{}\n    \\label{fig:}\n\\end{figure}", cursorOffset: 65),
        PaletteItem(title: "table (Centred Grid)", subtitle: "\\begin{table}[h] ... \\end{table}", category: "Environment", insertText: "\\begin{table}[h]\n    \\centering\n    \\begin{tabular}{|c|c|}\n        \\hline\n        \n        \\hline\n    \\end{tabular}\n    \\caption{}\n    \\label{tab:}\n\\end{table}", cursorOffset: 77),
        PaletteItem(title: "itemize (Bullet List)", subtitle: "\\begin{itemize} \\item ... \\end{itemize}", category: "Environment", insertText: "\\begin{itemize}\n    \\item \n\\end{itemize}", cursorOffset: 23),
        PaletteItem(title: "enumerate (Numbered List)", subtitle: "\\begin{enumerate} \\item ... \\end{enumerate}", category: "Environment", insertText: "\\begin{enumerate}\n    \\item \n\\end{enumerate}", cursorOffset: 25),
        PaletteItem(title: "theorem (Theorem Block)", subtitle: "\\begin{theorem} ... \\end{theorem}", category: "Environment", insertText: "\\begin{theorem}\n    \n\\end{theorem}", cursorOffset: 21),
        PaletteItem(title: "proof (Proof Block)", subtitle: "\\begin{proof} ... \\end{proof}", category: "Environment", insertText: "\\begin{proof}\n    \n\\end{proof}", cursorOffset: 19),

        // Math Commands
        PaletteItem(title: "Fraction (\\frac)", subtitle: "\\frac{num}{den}", category: "Command", insertText: "\\frac{}{}", cursorOffset: 6),
        PaletteItem(title: "Square Root (\\sqrt)", subtitle: "\\sqrt{x}", category: "Command", insertText: "\\sqrt{}", cursorOffset: 6),
        PaletteItem(title: "N-th Root (\\sqrt[n])", subtitle: "\\sqrt[n]{x}", category: "Command", insertText: "\\sqrt[]{}", cursorOffset: 6),
        PaletteItem(title: "Sum (\\sum)", subtitle: "\\sum_{i=1}^{n}", category: "Command", insertText: "\\sum_{i=1}^{n}", cursorOffset: 14),
        PaletteItem(title: "Product (\\prod)", subtitle: "\\prod_{i=1}^{n}", category: "Command", insertText: "\\prod_{i=1}^{n}", cursorOffset: 15),
        PaletteItem(title: "Integral (\\int)", subtitle: "\\int_{a}^{b}", category: "Command", insertText: "\\int_{a}^{b}", cursorOffset: 12),
        PaletteItem(title: "Double Integral (\\iint)", subtitle: "\\iint", category: "Command", insertText: "\\iint", cursorOffset: 5),
        PaletteItem(title: "Limit (\\lim)", subtitle: "\\lim_{x \\to \\infty}", category: "Command", insertText: "\\lim_{x \\to \\infty}", cursorOffset: 20),
        PaletteItem(title: "Partial Derivative (\\partial)", subtitle: "\\partial", category: "Command", insertText: "\\partial", cursorOffset: 8),
        PaletteItem(title: "Bold Math (\\mathbf)", subtitle: "\\mathbf{x}", category: "Command", insertText: "\\mathbf{}", cursorOffset: 8),
        PaletteItem(title: "Calligraphic (\\mathcal)", subtitle: "\\mathcal{A}", category: "Command", insertText: "\\mathcal{}", cursorOffset: 10),
        PaletteItem(title: "Blackboard Bold (\\mathbb)", subtitle: "\\mathbb{R}", category: "Command", insertText: "\\mathbb{R}", cursorOffset: 10),

        // Greek Letters
        PaletteItem(title: "alpha (α)", subtitle: "\\alpha", category: "Greek", insertText: "\\alpha ", cursorOffset: 7),
        PaletteItem(title: "beta (β)", subtitle: "\\beta", category: "Greek", insertText: "\\beta ", cursorOffset: 6),
        PaletteItem(title: "gamma (γ)", subtitle: "\\gamma", category: "Greek", insertText: "\\gamma ", cursorOffset: 7),
        PaletteItem(title: "delta (δ)", subtitle: "\\delta", category: "Greek", insertText: "\\delta ", cursorOffset: 7),
        PaletteItem(title: "epsilon (ε)", subtitle: "\\epsilon", category: "Greek", insertText: "\\epsilon ", cursorOffset: 9),
        PaletteItem(title: "theta (θ)", subtitle: "\\theta", category: "Greek", insertText: "\\theta ", cursorOffset: 7),
        PaletteItem(title: "lambda (λ)", subtitle: "\\lambda", category: "Greek", insertText: "\\lambda ", cursorOffset: 8),
        PaletteItem(title: "mu (μ)", subtitle: "\\mu", category: "Greek", insertText: "\\mu ", cursorOffset: 4),
        PaletteItem(title: "pi (π)", subtitle: "\\pi", category: "Greek", insertText: "\\pi ", cursorOffset: 4),
        PaletteItem(title: "sigma (σ)", subtitle: "\\sigma", category: "Greek", insertText: "\\sigma ", cursorOffset: 7),
        PaletteItem(title: "phi (φ)", subtitle: "\\phi", category: "Greek", insertText: "\\phi ", cursorOffset: 5),
        PaletteItem(title: "omega (ω)", subtitle: "\\omega", category: "Greek", insertText: "\\omega ", cursorOffset: 7),
        PaletteItem(title: "Gamma (Γ)", subtitle: "\\Gamma", category: "Greek", insertText: "\\Gamma ", cursorOffset: 7),
        PaletteItem(title: "Delta (Δ)", subtitle: "\\Delta", category: "Greek", insertText: "\\Delta ", cursorOffset: 7),
        PaletteItem(title: "Theta (Θ)", subtitle: "\\Theta", category: "Greek", insertText: "\\Theta ", cursorOffset: 7),
        PaletteItem(title: "Lambda (Λ)", subtitle: "\\Lambda", category: "Greek", insertText: "\\Lambda ", cursorOffset: 8),
        PaletteItem(title: "Sigma (Σ)", subtitle: "\\Sigma", category: "Greek", insertText: "\\Sigma ", cursorOffset: 7),
        PaletteItem(title: "Omega (Ω)", subtitle: "\\Omega", category: "Greek", insertText: "\\Omega ", cursorOffset: 7),

        // Operators & Symbols
        PaletteItem(title: "Infinity (∞)", subtitle: "\\infty", category: "Symbol", insertText: "\\infty ", cursorOffset: 7),
        PaletteItem(title: "Nabla / Gradient (∇)", subtitle: "\\nabla", category: "Symbol", insertText: "\\nabla ", cursorOffset: 7),
        PaletteItem(title: "Right Arrow (→)", subtitle: "\\to", category: "Symbol", insertText: "\\to ", cursorOffset: 4),
        PaletteItem(title: "Implies (⟹)", subtitle: "\\implies", category: "Symbol", insertText: "\\implies ", cursorOffset: 9),
        PaletteItem(title: "If and Only If (⟺)", subtitle: "\\iff", category: "Symbol", insertText: "\\iff ", cursorOffset: 5),
        PaletteItem(title: "Element Of (∈)", subtitle: "\\in", category: "Symbol", insertText: "\\in ", cursorOffset: 4),
        PaletteItem(title: "Subset (⊂)", subtitle: "\\subset", category: "Symbol", insertText: "\\subset ", cursorOffset: 8),
        PaletteItem(title: "Subset or Equal (⊆)", subtitle: "\\subseteq", category: "Symbol", insertText: "\\subseteq ", cursorOffset: 10),
        PaletteItem(title: "For All (∀)", subtitle: "\\forall", category: "Symbol", insertText: "\\forall ", cursorOffset: 8),
        PaletteItem(title: "Exists (∃)", subtitle: "\\exists", category: "Symbol", insertText: "\\exists ", cursorOffset: 8),
        PaletteItem(title: "Approximately Equal (≈)", subtitle: "\\approx", category: "Symbol", insertText: "\\approx ", cursorOffset: 8),
        PaletteItem(title: "Not Equal (≠)", subtitle: "\\neq", category: "Symbol", insertText: "\\neq ", cursorOffset: 5),
        PaletteItem(title: "Less Than or Equal (≤)", subtitle: "\\leq", category: "Symbol", insertText: "\\leq ", cursorOffset: 5),
        PaletteItem(title: "Greater Than or Equal (≥)", subtitle: "\\geq", category: "Symbol", insertText: "\\geq ", cursorOffset: 5),
        PaletteItem(title: "Times (×)", subtitle: "\\times", category: "Symbol", insertText: "\\times ", cursorOffset: 7),
        PaletteItem(title: "Dot Product (⋅)", subtitle: "\\cdot", category: "Symbol", insertText: "\\cdot ", cursorOffset: 6),
        PaletteItem(title: "Plus/Minus (±)", subtitle: "\\pm", category: "Symbol", insertText: "\\pm ", cursorOffset: 4)
    ]
}

// MARK: - Command Palette View

public struct CommandPaletteView: View {
    @State private var query = ""
    @State private var selectedIndex = 0
    let onSelect: (PaletteItem) -> Void
    let onCancel: () -> Void

    var filteredItems: [PaletteItem] {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            return CommandPaletteStore.items
        }
        let q = query.lowercased()
        return CommandPaletteStore.items.filter {
            $0.title.lowercased().contains(q) ||
            $0.subtitle.lowercased().contains(q) ||
            $0.category.lowercased().contains(q) ||
            $0.insertText.lowercased().contains(q)
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Search Input Field
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Color(NSColor.secondaryLabelColor))

                PaletteSearchField(text: $query, onKeyDown: handleKeyDown)
                    .frame(height: 24)

                if !query.isEmpty {
                    Button(action: { query = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(Color(NSColor.tertiaryLabelColor))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Results List
            let items = filteredItems
            if items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 24))
                        .foregroundColor(Color(NSColor.tertiaryLabelColor))
                    Text("No matching LaTeX commands or snippets")
                        .font(.subheadline)
                        .foregroundColor(Color(NSColor.secondaryLabelColor))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                let isSelected = index == selectedIndex
                                HStack(spacing: 10) {
                                    Text(item.category.uppercased())
                                        .font(.system(size: 9, weight: .bold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background(isSelected ? Color.white.opacity(0.25) : Color(NSColor.quaternaryLabelColor))
                                        .foregroundColor(isSelected ? .white : Color(NSColor.secondaryLabelColor))
                                        .cornerRadius(4)

                                    Text(item.title)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(isSelected ? .white : Color(NSColor.labelColor))

                                    Spacer()

                                    Text(item.subtitle)
                                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                                        .foregroundColor(isSelected ? Color.white.opacity(0.8) : Color(NSColor.secondaryLabelColor))
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(isSelected ? Color(NSColor.controlAccentColor) : Color.clear)
                                .cornerRadius(6)
                                .id(index)
                                .onTapGesture {
                                    onSelect(item)
                                }
                            }
                        }
                        .padding(6)
                    }
                    .onChange(of: selectedIndex) { newIndex in
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
                }
            }
        }
        .frame(width: 520, height: 320)
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(10)
        .shadow(radius: 12)
        .onChange(of: query) { _ in
            selectedIndex = 0
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        let items = filteredItems
        switch event.keyCode {
        case 125: // Down arrow
            if !items.isEmpty {
                selectedIndex = min(items.count - 1, selectedIndex + 1)
            }
            return true
        case 126: // Up arrow
            if !items.isEmpty {
                selectedIndex = max(0, selectedIndex - 1)
            }
            return true
        case 36, 76: // Return / Enter
            if !items.isEmpty && selectedIndex < items.count {
                onSelect(items[selectedIndex])
            }
            return true
        case 53: // Escape
            onCancel()
            return true
        default:
            return false
        }
    }
}

// Custom NSTextField wrapper to intercept Arrow Up/Down and Enter keys cleanly
struct PaletteSearchField: NSViewRepresentable {
    @Binding var text: String
    var onKeyDown: (NSEvent) -> Bool

    func makeNSView(context: Context) -> NSTextField {
        let tf = KeyCatchingTextField()
        tf.isBordered = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.font = NSFont.systemFont(ofSize: 14)
        tf.placeholderString = "Search LaTeX commands, Greek letters, or snippets… (e.g. matrix, frac)"
        tf.delegate = context.coordinator
        tf.onKeyDown = onKeyDown
        DispatchQueue.main.async {
            tf.window?.makeFirstResponder(tf)
        }
        return tf
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PaletteSearchField

        init(_ parent: PaletteSearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            if let tf = obj.object as? NSTextField {
                parent.text = tf.stringValue
            }
        }
    }
}

final class KeyCatchingTextField: NSTextField {
    var onKeyDown: ((NSEvent) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let onKeyDown = onKeyDown, onKeyDown(event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if let onKeyDown = onKeyDown, onKeyDown(event) {
            return
        }
        super.keyDown(with: event)
    }
}

// MARK: - Command Palette Window Controller

public final class CommandPaletteWindowController: NSWindowController {
    private static var instance: CommandPaletteWindowController?

    static func show(onEditor editor: EditorTextView) {
        let controller = CommandPaletteWindowController(editor: editor)
        instance = controller
        controller.present()
    }

    private weak var targetEditor: EditorTextView?

    init(editor: EditorTextView) {
        self.targetEditor = editor

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
            styleMask: [.borderless],
            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.hasShadow = true
        panel.backgroundColor = .clear

        super.init(window: panel)

        let contentView = CommandPaletteView(
            onSelect: { [weak self] item in
                self?.insertItem(item)
                self?.closePalette()
            },
            onCancel: { [weak self] in
                self?.closePalette()
            }
        )

        let hosting = NSHostingController(rootView: contentView)
        panel.contentViewController = hosting
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func present() {
        guard let panel = window, let window = targetEditor?.window else { return }
        let parentFrame = window.frame
        let panelSize = panel.frame.size
        let x = parentFrame.midX - (panelSize.width / 2)
        let y = parentFrame.maxY - panelSize.height - 80

        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.makeKeyAndOrderFront(nil)
    }

    private func insertItem(_ item: PaletteItem) {
        guard let editor = targetEditor else { return }
        let selectedRange = editor.selectedRange()

        if selectedRange.location != NSNotFound {
            editor.insertText(item.insertText, replacementRange: selectedRange)
            if let offset = item.cursorOffset {
                let newPos = selectedRange.location + offset
                if newPos <= (editor.string as NSString).length {
                    editor.setSelectedRange(NSRange(location: newPos, length: 0))
                }
            }
        }
    }

    private func closePalette() {
        window?.close()
        CommandPaletteWindowController.instance = nil
    }
}
