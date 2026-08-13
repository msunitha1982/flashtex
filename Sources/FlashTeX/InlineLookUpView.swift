import SwiftUI
import AppKit

// MARK: - Custom Inline Look Up Panel
public struct InlineLookUpPanel: View {
    let title: String
    let text: String
    var onDismiss: (() -> Void)?

    public init(title: String, text: String, onDismiss: (() -> Void)? = nil) {
        self.title = title
        self.text = text
        self.onDismiss = onDismiss
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if let onDismiss = onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(Color(NSColor.tertiaryLabelColor))
                }
                .buttonStyle(.plain)
                .help("Dismiss popup")
                .accessibilityLabel("Dismiss popup")
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(NSColor.labelColor))
                    .fixedSize(horizontal: false, vertical: true)

                Text(text)
                    .font(.system(size: 12))
                    .foregroundColor(Color(NSColor.secondaryLabelColor))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: Color.black.opacity(0.28), radius: 10, x: 0, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.8), lineWidth: 1)
        )
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// An in-editor error popup pane: an `NSTextView` subview that hosts the
/// `InlineLookUpPanel`. Living inside the document view means it scrolls with the
/// text and is positioned in the editor's own coordinate space — no NSPopover, no
/// screen-coordinate conversion, none of the placement bugs that plague popovers.
///
/// The pane is explicitly layer-backed at the window's backing scale so the
/// SwiftUI content renders crisply at Retina (an un-backd subview inside a text
/// view can otherwise draw at 1x and look soft).
final class ErrorPopoverPane: NSView {
    private let hostingView: NSHostingView<InlineLookUpPanel>

    var fittingContentSize: NSSize {
        let fitted = hostingView.fittingSize
        return NSSize(width: min(max(fitted.width, 180), 480), height: max(fitted.height, 32))
    }

    init(title: String, text: String, onDismiss: @escaping () -> Void) {
        hostingView = NSHostingView(rootView: InlineLookUpPanel(title: title, text: text, onDismiss: onDismiss))
        super.init(frame: .zero)
        wantsLayer = true
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Keep the backing layer at the display's pixel density (2x Retina,
        // 3x on the newer screens) instead of AppKit's default 1x for a
        // non-layer-backed parent.
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        layer?.contentsScale = scale
        hostingView.layer?.contentsScale = scale
    }
}

// MARK: - ViewModifier & View Extension
public struct CustomInlineLookUpModifier: ViewModifier {
    @Binding var isPresented: Bool
    let title: String
    let text: String
    let arrowEdge: Edge
    
    public func body(content: Content) -> some View {
        content
            .popover(isPresented: $isPresented, arrowEdge: arrowEdge) {
                InlineLookUpPanel(title: title, text: text)
            }
    }
}

public extension View {
    func customInlineLookUp(
        isPresented: Binding<Bool>,
        title: String,
        text: String,
        arrowEdge: Edge = .bottom
    ) -> some View {
        modifier(CustomInlineLookUpModifier(isPresented: isPresented, title: title, text: text, arrowEdge: arrowEdge))
    }
}

// MARK: - Minimal Example ContentView
public struct ContentView: View {
    @State private var showLookUp = false
    
    public var body: some View {
        VStack(spacing: 20) {
            Text("LaTeX Syntax Diagnostics")
                .font(.headline)
            
            Button("Inspect Error") {
                showLookUp.toggle()
            }
            .buttonStyle(.borderedProminent)
            .customInlineLookUp(
                isPresented: $showLookUp,
                title: "TeX Error",
                text: "Missing $ inserted. A math formula was not properly closed.",
                arrowEdge: .bottom
            )
        }
        .frame(width: 300, height: 200)
        .padding()
    }
}
