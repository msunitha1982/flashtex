import SwiftUI
import AppKit

// MARK: - Custom Inline Look Up Panel
public struct InlineLookUpPanel: View {
    let title: String
    let text: String
    @Binding var isPinned: Bool
    var onDismiss: (() -> Void)?
    
    public init(title: String, text: String, isPinned: Binding<Bool> = .constant(false), onDismiss: (() -> Void)? = nil) {
        self.title = title
        self.text = text
        self._isPinned = isPinned
        self.onDismiss = onDismiss
    }
    
    public var body: some View {
        HStack(spacing: 8) {
            Button(action: {
                isPinned.toggle()
            }) {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(isPinned ? Color(NSColor.controlAccentColor) : Color(NSColor.tertiaryLabelColor))
            }
            .buttonStyle(.plain)
            .help(isPinned ? "Unpin popup" : "Pin popup to screen")

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
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .fixedSize()
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
