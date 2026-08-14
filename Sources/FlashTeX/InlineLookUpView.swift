import SwiftUI
import AppKit

// MARK: - Custom Inline Look Up Panel

/// A unified speech-bubble / callout shape that renders a rounded rectangle
/// with an integrated triangular arrow extending from either the bottom or top edge.
public struct CalloutBubbleShape: Shape {
    var pointsUp: Bool
    var arrowX: CGFloat
    var cornerRadius: CGFloat = 10
    var arrowWidth: CGFloat = 14
    var arrowHeight: CGFloat = 7

    public func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = cornerRadius
        let aw = arrowWidth
        let ah = arrowHeight
        let tipX = min(max(arrowX, rect.minX + r + aw/2), rect.maxX - r - aw/2)
        let leftBaseX = tipX - aw/2
        let rightBaseX = tipX + aw/2

        if pointsUp {
            // Arrow at top pointing up towards line above
            let bodyTop = rect.minY + ah
            let bodyBottom = rect.maxY
            p.move(to: CGPoint(x: rect.minX + r, y: bodyTop))
            p.addLine(to: CGPoint(x: leftBaseX, y: bodyTop))
            p.addLine(to: CGPoint(x: tipX, y: rect.minY))
            p.addLine(to: CGPoint(x: rightBaseX, y: bodyTop))
            p.addLine(to: CGPoint(x: rect.maxX - r, y: bodyTop))
            p.addArc(center: CGPoint(x: rect.maxX - r, y: bodyTop + r), radius: r,
                     startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
            p.addLine(to: CGPoint(x: rect.maxX, y: bodyBottom - r))
            p.addArc(center: CGPoint(x: rect.maxX - r, y: bodyBottom - r), radius: r,
                     startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
            p.addLine(to: CGPoint(x: rect.minX + r, y: bodyBottom))
            p.addArc(center: CGPoint(x: rect.minX + r, y: bodyBottom - r), radius: r,
                     startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
            p.addLine(to: CGPoint(x: rect.minX, y: bodyTop + r))
            p.addArc(center: CGPoint(x: rect.minX + r, y: bodyTop + r), radius: r,
                     startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
            p.closeSubpath()
        } else {
            // Arrow at bottom pointing down towards error line
            let bodyTop = rect.minY
            let bodyBottom = rect.maxY - ah
            p.move(to: CGPoint(x: rect.minX + r, y: bodyTop))
            p.addLine(to: CGPoint(x: rect.maxX - r, y: bodyTop))
            p.addArc(center: CGPoint(x: rect.maxX - r, y: bodyTop + r), radius: r,
                     startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
            p.addLine(to: CGPoint(x: rect.maxX, y: bodyBottom - r))
            p.addArc(center: CGPoint(x: rect.maxX - r, y: bodyBottom - r), radius: r,
                     startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
            p.addLine(to: CGPoint(x: rightBaseX, y: bodyBottom))
            p.addLine(to: CGPoint(x: tipX, y: rect.maxY))
            p.addLine(to: CGPoint(x: leftBaseX, y: bodyBottom))
            p.addLine(to: CGPoint(x: rect.minX + r, y: bodyBottom))
            p.addArc(center: CGPoint(x: rect.minX + r, y: bodyBottom - r), radius: r,
                     startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
            p.addLine(to: CGPoint(x: rect.minX, y: bodyTop + r))
            p.addArc(center: CGPoint(x: rect.minX + r, y: bodyTop + r), radius: r,
                     startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
            p.closeSubpath()
        }
        return p
    }
}

public struct InlineLookUpPanel: View {
    let title: String
    let text: String
    var onDismiss: (() -> Void)?
    var pointsUp: Bool
    var arrowX: CGFloat

    public init(title: String, text: String, onDismiss: (() -> Void)? = nil, pointsUp: Bool = false, arrowX: CGFloat = 30) {
        self.title = title
        self.text = text
        self.onDismiss = onDismiss
        self.pointsUp = pointsUp
        self.arrowX = arrowX
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if let onDismiss = onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(Color(NSColor.tertiaryLabelColor))
                }
                .buttonStyle(.plain)
                .help("Dismiss popup")
                .accessibilityLabel("Dismiss popup")
            }

            Text(title.isEmpty ? text : "\(title): \(text)")
                .font(.system(size: 11))
                .foregroundColor(Color(NSColor.labelColor))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.top, pointsUp ? 5 + 5 : 5)
        .padding(.bottom, pointsUp ? 5 : 5 + 5)
        .background(
            CalloutBubbleShape(pointsUp: pointsUp, arrowX: arrowX)
                .fill(.ultraThinMaterial)
                .overlay(
                    CalloutBubbleShape(pointsUp: pointsUp, arrowX: arrowX)
                        .fill(Color.red.opacity(0.55))
                )
                .shadow(color: Color.black.opacity(0.28), radius: 8, x: 0, y: 3)
        )
        .overlay(
            CalloutBubbleShape(pointsUp: pointsUp, arrowX: arrowX)
                .stroke(Color.red.opacity(0.65), lineWidth: 1)
        )
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// An in-editor error popup pane: an `NSTextView` subview that hosts the
/// `InlineLookUpPanel`. Living inside the document view means it scrolls with the
/// text and is positioned in the editor's own coordinate space — no NSPopover, no
/// screen-coordinate conversion, none of the placement bugs that plague popovers.
final class ErrorPopoverPane: NSView {
    private let hostingView: NSHostingView<InlineLookUpPanel>
    private let title: String
    private let text: String
    private let onDismiss: () -> Void
    private var pointsUp: Bool = false
    private var arrowX: CGFloat = 30

    var fittingContentSize: NSSize {
        let fitted = hostingView.fittingSize
        return NSSize(width: min(max(fitted.width, 180), 480), height: max(fitted.height, 38))
    }

    init(title: String, text: String, onDismiss: @escaping () -> Void) {
        self.title = title
        self.text = text
        self.onDismiss = onDismiss
        hostingView = NSHostingView(rootView: InlineLookUpPanel(title: title, text: text, onDismiss: onDismiss, pointsUp: false, arrowX: 30))
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

    /// Repoints the popup's callout arrow and offsets the arrow tip to match the error's x position.
    func update(pointsUp: Bool, arrowX: CGFloat) {
        self.pointsUp = pointsUp
        self.arrowX = arrowX
        hostingView.rootView = InlineLookUpPanel(title: title, text: text, onDismiss: onDismiss,
                                                 pointsUp: pointsUp, arrowX: arrowX)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
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
