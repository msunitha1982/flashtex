import AppKit

// StatusBarView — the editor's bottom status line (Vim-style).
//
//   NORMAL  Ln 18, Col 21                 UTF-8  pdflatex
//
// Three transient layers share the same strip:
//   1. idle      → mode label + Ln/Col + encoding/engine
//   2. command   → ":" + a borderless text field (the Vim command line)
//   3. message   → transient text ("\"doc.tex\" 42L, 891B", "E32: No file name")
//
// The mode label is the single source of truth for what Vim mode is showing —
// it is fed from the editor's VimController and never stored locally.

final class StatusBarView: NSView {

    var onCommandSubmitted: ((String) -> Void)?
    var onCommandCancelled: (() -> Void)?

    private let modeLabel = NSTextField(labelWithString: "NORMAL")
    private let infoLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(labelWithString: "")
    private let commandField = NSTextField()
    private let topRule = NSBox()

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true

        let infoFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

        modeLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
        modeLabel.textColor = Theme.accent

        infoLabel.font = infoFont
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.alignment = .right

        messageLabel.font = infoFont
        messageLabel.textColor = .secondaryLabelColor

        commandField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        commandField.isBordered = false
        commandField.isBezeled = false
        commandField.drawsBackground = false
        commandField.focusRingType = .none
        commandField.target = self
        commandField.action = #selector(commandSubmitted(_:))
        commandField.delegate = self

        topRule.boxType = .separator

        for v in [modeLabel, infoLabel, messageLabel, commandField, topRule] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        NSLayoutConstraint.activate([
            modeLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            modeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            modeLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),

            infoLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            infoLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            infoLabel.leadingAnchor.constraint(greaterThanOrEqualTo: modeLabel.trailingAnchor, constant: 10),

            messageLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            messageLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            messageLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            commandField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            commandField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            commandField.centerYAnchor.constraint(equalTo: centerYAnchor),
            commandField.heightAnchor.constraint(equalToConstant: 20),

            topRule.leadingAnchor.constraint(equalTo: leadingAnchor),
            topRule.trailingAnchor.constraint(equalTo: trailingAnchor),
            topRule.topAnchor.constraint(equalTo: topAnchor),
            topRule.heightAnchor.constraint(equalToConstant: 1),
        ])

        showIdle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        Theme.editorBackground.blended(withFraction: 0.5, of: .controlBackgroundColor)?
            .setFill()
        dirtyRect.fill()
        super.draw(dirtyRect)
    }

    // MARK: - Public API

    func update(mode: String) {
        modeLabel.stringValue = mode
        modeLabel.textColor = Self.modeColor(for: mode)
        messageLabel.stringValue = ""
        showIdle()
    }

    func update(position: (line: Int, col: Int), encoding: String, engine: String) {
        infoLabel.stringValue = "Ln \(position.line), Col \(position.col)      \(encoding)  \(engine)"
    }

    func beginCommandLine(prompt: String) {
        commandField.stringValue = ""
        commandField.placeholderString = prompt + " "
        commandField.isHidden = false
        modeLabel.isHidden = true
        infoLabel.isHidden = true
        messageLabel.isHidden = true
        window?.makeFirstResponder(commandField)
    }

    func endCommandLine() {
        commandField.isHidden = true
        showIdle()
    }

    func showMessage(_ text: String) {
        messageLabel.stringValue = text
        messageLabel.isHidden = false
        modeLabel.isHidden = true
        infoLabel.isHidden = true
        commandField.isHidden = true
    }

    // MARK: - Internals

    private func showIdle() {
        modeLabel.isHidden = false
        infoLabel.isHidden = false
        messageLabel.isHidden = true
        commandField.isHidden = true
    }

    private static func modeColor(for mode: String) -> NSColor {
        switch mode {
        case "INSERT": return .systemGreen
        case "VISUAL", "VISUAL LINE": return .systemPurple
        case "REPLACE": return .systemOrange
        default: return Theme.accent
        }
    }

    @objc private func commandSubmitted(_ sender: NSTextField) {
        onCommandSubmitted?(sender.stringValue)
    }
}

// MARK: - NSTextFieldDelegate (Esc cancels the command line)

extension StatusBarView: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            onCommandCancelled?()
            return true
        }
        return false
    }
}