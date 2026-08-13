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
        HStack(spacing: 8) {
            if let onDismiss = onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Color(NSColor.tertiaryLabelColor))
                }
                .buttonStyle(.plain)
                .help("Dismiss popup")
            }

            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(Color(NSColor.labelColor))

            Divider()
                .frame(height: 16)

            Text(text)
                .font(.subheadline)
                .foregroundColor(Color(NSColor.secondaryLabelColor))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: Color.black.opacity(0.35), radius: 6, x: 0, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .fixedSize()
    }
}

/// An in-editor error popup pane: an `NSTextView` subview that hosts the
/// `InlineLookUpPanel`. Living inside the document view means it scrolls with the
/// text and is positioned in the editor's own coordinate space — no NSPopover, no
/// screen-coordinate conversion, none of the placement bugs that plague popovers.
final class ErrorPopoverPane: NSView {
    private let hostingView: NSHostingView<InlineLookUpPanel>

    var fittingContentSize: NSSize {
        let fitted = hostingView.fittingSize
        return NSSize(width: min(max(fitted.width, 180), 480), height: max(fitted.height, 32))
    }

    init(title: String, text: String, onDismiss: @escaping () -> Void) {
        hostingView = NSHostingView(rootView: InlineLookUpPanel(title: title, text: text, onDismiss: onDismiss))
        super.init(frame: .zero)
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
