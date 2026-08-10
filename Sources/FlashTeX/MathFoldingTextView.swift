import AppKit

// MathFoldingTextView — an Obsidian Live-Preview-style NSTextView.
//
// Math blocks render as images while the cursor is elsewhere; moving the caret
// into a block "unfolds" it back to the raw LaTeX for editing. The source text
// is never mutated — folding uses temporary layout-manager attributes (clear
// the glyphs) plus a chip and the rendered image drawn on top — so undo/redo,
// copy/paste, selection and the caret all keep the real source intact.
//
// Recognised blocks (inline and display):
//   $…$            inline math
//   $$…$$          display math
//   \[…\]          display math
//   \begin{equation|equation*|displaymath}…\end{…}
//   \begin{align|gather|multline}*…\end{…}   (wrapped in `aligned` to render)
//
// Rendered images come from MathRenderer: they render off the main thread,
// are cached, and are drawn scaled so their height matches the editor font
// (`font.pointSize / MathRenderer.renderPointSize`). Display blocks are drawn
// centred on their paragraph.

final class MathFoldingTextView: VimTextView {

    var foldEnabled = true {
        didSet { refreshFolds() }
    }

    private let parser = MathFoldParser()
    private var mathBlocks: [MathBlock] = []
    private var activeBlock: MathBlock?
    private var hoverBlock: MathBlock?
    private var appliedHiddenRanges: [NSRange] = []
    private var pendingKeys: Set<String> = []
    private var unrenderableKeys: Set<String> = []
    private var refreshTimer: Timer?
    private var textSnapshot = ""
    /// True while a fold pass is mutating the storage (permanent kern
    /// attributes). Prevents `didChangeText` feedback loops.
    private var isUpdatingFolds = false
    private var settingsObserver: NSObjectProtocol?
    private var trackingArea: NSTrackingArea?

    /// Flash Mode zoom — independent of the main editor's font size.
    private(set) var zoomScale: CGFloat = 1
    private let minZoomScale: CGFloat = 0.5
    private let maxZoomScale: CGFloat = 3

    static func makeEditor() -> MathFoldingTextView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(containerSize:
            NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        let view = MathFoldingTextView(frame: NSRect(x: 0, y: 0, width: 0, height: 600),
                                       textContainer: container)
        view.configure()
        return view
    }

    /// Keep the editor exactly as wide as the scroll view's clip view. Starting
    /// the frame at width 0 avoids NSTextView's inflation of the document width
    /// (clip width + initial frame width), which would otherwise push display
    /// math to the far right of a container twice as wide as the panel.
    override func layout() {
        super.layout()
        if let scroll = enclosingScrollView {
            let width = scroll.contentSize.width
            if frame.width != width {
                frame.size.width = width
            }
        }
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        configure()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configure() {
        drawsBackground = true
        backgroundColor = Theme.editorBackground
        isRichText = false
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        minSize = NSSize(width: 0, height: 0)
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                         height: CGFloat.greatestFiniteMagnitude)
        textContainerInset = NSSize(width: 16, height: 12)

        allowsUndo = true
        smartInsertDeleteEnabled = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isGrammarCheckingEnabled = false
        isContinuousSpellCheckingEnabled = false

        applySettings()

        settingsObserver = NotificationCenter.default.addObserver(
            forName: SettingsStore.changedNotification,
            object: nil, queue: .main) { [weak self] _ in
                self?.applySettings()
            }
    }

    /// Re-apply fonts, colours, line height and ligatures from settings, then
    /// re-fold. Math is re-tinted by clearing the render cache.
    func applySettings() {
        let font = Theme.editorFont(ofSize: Theme.editorFontSize * zoomScale)
        self.font = font
        textColor = Theme.editorText
        insertionPointColor = Theme.accent
        backgroundColor = Theme.editorBackground

        let ligature: Int = SettingsStore.shared.ligatures ? 1 : 0
        let para = NSMutableParagraphStyle()
        para.minimumLineHeight = Theme.lineHeight(forFont: font)

        let len = (string as NSString).length
        if let storage = textStorage, len > 0 {
            storage.beginEditing()
            storage.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: len))
            storage.addAttribute(.ligature, value: ligature, range: NSRange(location: 0, length: len))
            storage.endEditing()
        }
        defaultParagraphStyle = para
        typingAttributes[.font] = font
        typingAttributes[.paragraphStyle] = para
        typingAttributes[.ligature] = ligature

        MathRenderer.shared.clearCache()
        unrenderableKeys.removeAll()
        refreshFolds()
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        let ta = NSTrackingArea(rect: .zero,
                                options: [.mouseMoved, .mouseEnteredAndExited,
                                          .activeInKeyWindow, .inVisibleRect],
                                owner: self, userInfo: nil)
        addTrackingArea(ta)
        trackingArea = ta
    }

    func shutdown() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        pendingKeys.removeAll()
    }

    // MARK: - Fold state

    /// Blocks that should be folded right now (everything except the one the
    /// caret sits inside).
    private var hiddenBlocks: [MathBlock] {
        guard let active = activeBlock else { return mathBlocks }
        return mathBlocks.filter { $0.range.location != active.range.location }
    }

    private func scheduleRefresh() {
        refreshTimer?.invalidate()
        let delay = max(0.01, SettingsStore.shared.renderDebounceMs / 1000.0)
        let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            self?.refreshFolds()
        }
        refreshTimer = t
        // `.common` so the fold refresh also runs while typing/scroll tracking.
        RunLoop.main.add(t, forMode: .common)
    }

    /// Which block should stay unfolded right now, per the unfold trigger.
    private func computeActiveBlock() -> MathBlock? {
        let caret = selectedRange().location
        switch SettingsStore.shared.unfoldTrigger {
        case .hover: return hoverBlock
        case .click, .caret: return parser.activeBlock(at: caret, in: mathBlocks)
        }
    }

    /// Re-scan the buffer, figure out which block the caret sits in, hide the
    /// folded blocks and redraw. Cheap enough to run on every selection change.
    func refreshFolds() {
        refreshTimer?.invalidate()
        refreshTimer = nil

        guard foldEnabled else {
            clearHiddenAttributes()
            return
        }

        let text = string as NSString
        mathBlocks = parser.mathBlocks(in: text)
        activeBlock = computeActiveBlock()
        textSnapshot = text as String
        applyHiddenAttributes()
        needsDisplay = true
    }

    private func clearHiddenAttributes() {
        guard let lm = layoutManager else { return }
        let len = (string as NSString).length
        isUpdatingFolds = true
        defer { isUpdatingFolds = false }
        for range in appliedHiddenRanges {
            removeTemporaryAttribute(for: range, length: len, on: lm)
        }
        textStorage?.removeAttribute(.kern,
                                     range: NSRange(location: 0, length: len))
        appliedHiddenRanges = []
    }

    private func applyHiddenAttributes() {
        guard let lm = layoutManager else { return }
        let len = (string as NSString).length

        for range in appliedHiddenRanges {
            removeTemporaryAttribute(for: range, length: len, on: lm)
        }

        var newHidden: [NSRange] = []
        let colorHex = currentColorHex()
        isUpdatingFolds = true
        defer { isUpdatingFolds = false }

        // Clear any kern applied by an earlier fold pass. Block ranges shift as
        // the user edits, so removing over the whole buffer is the only safe
        // way to guarantee no stale compression survives on an unfolded block.
        textStorage?.removeAttribute(.kern,
                                     range: NSRange(location: 0, length: len))

        for block in hiddenBlocks where !isUnrenderable(block, colorHex: colorHex) {
            let range = block.range
            guard range.location != NSNotFound,
                  range.location + range.length <= len else { continue }
            lm.addTemporaryAttribute(.foregroundColor,
                                     value: NSColor.clear,
                                     forCharacterRange: range)
            newHidden.append(range)

            // Compress the hidden glyphs' advance so the laid-out width of the
            // range equals the rendered image's width. The layout manager will
            // not reflow from temporary attributes, so this uses a permanent
            // kern (the layout machinery lays it out like any other
            // attribute). Without it the following text starts a whole
            // equation-width too far right, leaving a visible trailing gap.
            if !block.display,
               let image = MathRenderer.shared.cachedImage(forKey:
                   MathRenderer.key(for: block.body, display: block.display,
                                    colorHex: colorHex)) {
                applyInlineKern(for: block.range, imageWidth: image.size.width)
            }
        }
        appliedHiddenRanges = newHidden
    }

    /// Spread a uniform negative kern across a folded inline block's glyph
    /// range so its laid-out width shrinks to the rendered image's width.
    /// Measured on the real layout manager: a kern over an N-glyph range
    /// shifts the following text by kern×N, and the range's bounding box
    /// starts at count×advance, so kern = (target − count×advance) / count.
    private func applyInlineKern(for range: NSRange, imageWidth: CGFloat) {
        guard let lm = layoutManager,
              let advance = font?.maximumAdvancement.width,
              advance > 0 else { return }
        let glyphCount = lm.glyphRange(forCharacterRange: range,
                                       actualCharacterRange: nil).length
        guard glyphCount > 0 else { return }
        let natural = CGFloat(glyphCount) * advance
        let target = imageWidth * fontScaling
        let kern = (target - natural) / CGFloat(glyphCount)
        textStorage?.addAttribute(.kern,
                                  value: NSNumber(value: kern),
                                  range: range)
    }

    private func removeTemporaryAttribute(for range: NSRange, length: Int, on lm: NSLayoutManager) {
        guard range.location != NSNotFound else { return }
        let loc = min(max(range.location, 0), length)
        let len = min(range.length, length - loc)
        guard len > 0 else { return }
        lm.removeTemporaryAttribute(.foregroundColor,
                                    forCharacterRange: NSRange(location: loc, length: len))
    }

    private func isUnrenderable(_ block: MathBlock, colorHex: String) -> Bool {
        guard block.range.location != NSNotFound,
              block.range.location + block.range.length <= (string as NSString).length else { return false }
        let key = MathRenderer.key(for: block.body,
                                   display: block.display,
                                   colorHex: colorHex)
        return unrenderableKeys.contains(key)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawFolds(in: dirtyRect)
    }

    private func drawFolds(in dirtyRect: NSRect) {
        guard foldEnabled, let lm = layoutManager, let tc = textContainer else { return }
        let text = string as NSString
        let colorHex = currentColorHex()

        for block in hiddenBlocks {
            let range = block.range
            guard range.location != NSNotFound,
                  range.location + range.length <= text.length else { continue }
            let glyphRange = lm.glyphRange(forCharacterRange: range,
                                           actualCharacterRange: nil)
            guard glyphRange.location != NSNotFound else { continue }
            let rect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
                .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
            guard rect.intersects(dirtyRect) else { continue }

            let key = MathRenderer.key(for: block.body,
                                       display: block.display,
                                       colorHex: colorHex)
            if unrenderableKeys.contains(key) { continue }
            guard let image = MathRenderer.shared.cachedImage(forKey: key) else {
                requestRender(block: block, key: key, colorHex: colorHex)
                continue
            }
            if ProcessInfo.processInfo.environment["FLASHTEX_DEBUG_DRAW"] != nil {
                let gctx = NSGraphicsContext.current
                let ctm = gctx?.cgContext.ctm
                print("DRAW block loc=\(range.location) display=\(block.display) rect=\(rect) imageSize=\(image.size) origin=\(textContainerOrigin) tc=\(tc.size.width) bounds=\(bounds.width) font=\(font?.pointSize ?? -1) isFlipped=\(gctx?.isFlipped ?? false) ctm=\(String(describing: ctm))")
            }

            // Scale the rendered math so its height matches the editor font
            // (which already includes the Flash zoom factor) and draw it
            // directly on the canvas — no box around it.
            let scale = fontScaling
            let imageSize = NSSize(width: image.size.width * scale,
                                   height: image.size.height * scale)
            // Inline math sits where its source glyphs are — flush against the
            // preceding text. Centering it on the (wide) empty glyph range
            // would leave a visible gap on both sides. Display math is centred
            // within the text container, not on the (narrow) glyph box that the
            // layout manager reports for the hidden block.
            var drawX = rect.minX
            if block.display {
                let containerWidth = tc.size.width
                drawX = textContainerOrigin.x
                    + max(0, (containerWidth - imageSize.width) / 2)
            }
            let drawRect = NSRect(x: drawX,
                                  y: rect.midY - imageSize.height / 2,
                                  width: imageSize.width,
                                  height: imageSize.height)

            // Chip behind the rendered math (Obsidian-style). The chip hugs
            // the image; padding and corner radius come from settings.
            if SettingsStore.shared.chipFill == .solid {
                let pad = SettingsStore.shared.chipPadding
                let chipRect = drawRect.insetBy(dx: -pad, dy: -pad)
                let radius = SettingsStore.shared.chipRadius
                let path = NSBezierPath(roundedRect: chipRect,
                                        xRadius: radius, yRadius: radius)
                Theme.mathFoldBackground.setFill()
                path.fill()
            }

            if ProcessInfo.processInfo.environment["FLASHTEX_DEBUG_DRAW"] != nil {
                print("  scaled=\(imageSize) drawRect=\(drawRect) containerCenter=\(textContainerOrigin.x + tc.size.width / 2)")
            }

            // NSTextView is flipped, and AppKit's image drawing (NSImage.draw
            // and CGContext.draw alike) maps the image's first row to the
            // rect's bottom in that coordinate system, so math would render
            // upside-down. Flip the CTM about the rect's bottom edge, then
            // draw either the original vector PDF (crisp at any zoom) or the
            // raw raster CGImage as a fallback.
            NSGraphicsContext.current?.saveGraphicsState()
            if let cgContext = NSGraphicsContext.current?.cgContext {
                cgContext.translateBy(x: 0, y: drawRect.maxY)
                cgContext.scaleBy(x: 1, y: -1)

                if let pdf = MathRenderer.shared.cachedPDF(forKey: key),
                   let page = pdf.page(at: 0) {
                    let media = page.bounds(for: .mediaBox)
                    let sx = drawRect.width / media.width
                    let sy = drawRect.height / media.height
                    if sx > 0, sy > 0, media.width > 0, media.height > 0 {
                        if ProcessInfo.processInfo.environment["FLASHTEX_DEBUG_DRAW"] != nil {
                            print("  VECTOR draw media=\(media) sx=\(sx) sy=\(sy)")
                        }
                        cgContext.saveGState()
                        cgContext.translateBy(x: drawRect.minX - media.minX * sx,
                                              y: -media.minY * sy)
                        cgContext.scaleBy(x: sx, y: sy)
                        page.draw(with: .mediaBox, to: cgContext)
                        cgContext.restoreGState()
                    }
                } else if let cg = MathRenderer.shared.cachedCGImage(forKey: key)
                    ?? image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    cgContext.draw(cg, in: CGRect(x: drawRect.minX, y: 0,
                                                  width: drawRect.width,
                                                  height: drawRect.height))
                }
            }
            NSGraphicsContext.current?.restoreGraphicsState()
        }
    }


    /// Editor font size relative to the fixed TeX size the math was rendered
    /// at. Math is rendered at `MathRenderer.renderPointSize`; scaling the
    /// image by this factor matches the equation's x-height to the text. The
    /// user's math scale factor (Flash preferences) applies on top.
    private var fontScaling: CGFloat {
        guard let font else { return 1 }
        let base = MathRenderer.renderPointSize
        guard base > 0 else { return 1 }
        return (font.pointSize / base) * SettingsStore.shared.mathScale
    }

    // MARK: - Zoom (independent of the main editor)

    @objc func zoomIn(_ sender: Any?) { setZoomScale(zoomScale * 1.15) }
    @objc func zoomOut(_ sender: Any?) { setZoomScale(zoomScale / 1.15) }
    @objc func resetZoom(_ sender: Any?) { setZoomScale(1) }

    private func setZoomScale(_ newScale: CGFloat) {
        zoomScale = min(max(newScale, minZoomScale), maxZoomScale)
        let newFont = Theme.editorFont(ofSize: Theme.editorFontSize * zoomScale)
        font = newFont
        if let storage = textStorage {
            storage.beginEditing()
            storage.addAttribute(.font, value: newFont,
                                 range: NSRange(location: 0, length: storage.length))
            storage.endEditing()
        }
        refreshFolds()
    }

    private func currentColorHex() -> String {
        MathRenderer.textColorHex(for: effectiveAppearance)
    }

    private func requestRender(block: MathBlock, key: String, colorHex: String) {
        guard !pendingKeys.contains(key) else { return }
        pendingKeys.insert(key)
        let snapshot = textSnapshot
        MathRenderer.shared.renderMath(block.body, display: block.display,
                                       colorHex: colorHex) { [weak self] image in
            guard let self else { return }
            self.pendingKeys.remove(key)
            guard self.string == snapshot else { return }
            if image == nil {
                // Couldn't render — leave the raw source visible.
                self.unrenderableKeys.insert(key)
            }
            self.applyHiddenAttributes()
            self.needsDisplay = true
        }
    }

    // MARK: - Interaction

    /// Clicking a folded block puts the caret inside it (at the position under
    /// the pointer, mapped proportionally across the rendered image) so it
    /// unfolds.
    override func mouseDown(with event: NSEvent) {
        if foldEnabled {
            let point = convert(event.locationInWindow, from: nil)
            if let block = block(at: point) {
                if SettingsStore.shared.unfoldTrigger == .hover {
                    // Unfold-on-hover: the clicked block becomes the hovered one.
                    hoverBlock = block
                }
                let text = string as NSString
                let caret = caretLocation(for: point, in: block, text: text)
                setSelectedRange(NSRange(location: caret, length: 0))
                window?.makeFirstResponder(self)
                return
            }
        }
        super.mouseDown(with: event)
    }

    /// The folded block whose rendered image (or hidden glyph box, before the
    /// image is ready) contains `point`.
    private func block(at point: NSPoint) -> MathBlock? {
        for block in hiddenBlocks {
            guard let rect = imageRect(for: block) else { continue }
            if rect.insetBy(dx: -3, dy: -2).contains(point) { return block }
        }
        return nil
    }

    /// Map a click position inside a folded block's image to a character index
    /// in the raw LaTeX. The horizontal fraction of the click within the image
    /// is mapped onto the block's body (between the delimiters), so clicking
    /// the middle of a rendered fraction drops the caret at the middle of its
    /// source text rather than always at the start.
    private func caretLocation(for point: NSPoint, in block: MathBlock, text: NSString) -> Int {
        let rect = imageRect(for: block)
        let minX = rect?.minX ?? point.x
        let width = rect?.width ?? 10
        let fraction = width > 0 ? min(max((point.x - minX) / width, 0), 1) : 0.5
        let bodyStart = bodyStartOffset(for: block, text: text)
        let blockEnd = min(block.range.location + block.range.length, text.length)
        let span = max(1, blockEnd - 1 - bodyStart)
        let caret = bodyStart + Int((fraction * CGFloat(span)).rounded())
        return min(max(caret, bodyStart), max(bodyStart, blockEnd - 1))
    }

    /// Character index just past the opening delimiter of a block.
    private func bodyStartOffset(for block: MathBlock, text: NSString) -> Int {
        let loc = block.range.location
        guard loc < text.length else { return 1 }
        let c = text.character(at: loc)
        if c == 36 {   // `$`
            return (loc + 1 < text.length && text.character(at: loc + 1) == 36) ? 2 : 1
        }
        if c == 92 {   // `\`
            if loc + 1 < text.length, text.character(at: loc + 1) == 91 { return 2 }   // `\[`
            if loc + 7 <= text.length,
               text.substring(with: NSRange(location: loc, length: 7)) == "\\begin{" {
                var k = loc + 7
                while k < text.length && text.character(at: k) != 125 { k += 1 }   // `}`
                k += 1
                if k < text.length && text.character(at: k) == 10 { k += 1 }       // newline
                return k - loc
            }
        }
        return 1
    }

    /// The draw rect (same geometry as `drawFolds`) of a folded block's image,
    /// or of its hidden glyph box while the image is still rendering.
    private func imageRect(for block: MathBlock) -> NSRect? {
        guard foldEnabled, let lm = layoutManager, let tc = textContainer else { return nil }
        let text = string as NSString
        let range = block.range
        guard range.location != NSNotFound,
              range.location + range.length <= text.length else { return nil }
        let glyphRange = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphRange.location != NSNotFound else { return nil }
        let rect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
            .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)

        var imageSize: NSSize = rect.size
        let colorHex = currentColorHex()
        let key = MathRenderer.key(for: block.body, display: block.display, colorHex: colorHex)
        if !unrenderableKeys.contains(key),
           let image = MathRenderer.shared.cachedImage(forKey: key) {
            let scale = fontScaling
            imageSize = NSSize(width: image.size.width * scale,
                               height: image.size.height * scale)
        }

        var drawX = rect.minX
        if block.display {
            let containerWidth = tc.size.width
            drawX = textContainerOrigin.x + max(0, (containerWidth - imageSize.width) / 2)
        }
        return NSRect(x: drawX, y: rect.midY - imageSize.height / 2,
                      width: imageSize.width, height: imageSize.height)
    }

    /// Unfold-on-hover: keep the block under the mouse visible so the caret can
    /// land in it. Changing the hovered block re-folds the previous one.
    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard foldEnabled, SettingsStore.shared.unfoldTrigger == .hover else { return }
        let point = convert(event.locationInWindow, from: nil)
        let block = block(at: point)
        if block?.range.location != hoverBlock?.range.location {
            hoverBlock = block
            scheduleRefresh()
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guard foldEnabled, SettingsStore.shared.unfoldTrigger == .hover,
              hoverBlock != nil else { return }
        hoverBlock = nil
        scheduleRefresh()
    }

    // MARK: - Notifications

    override func setSelectedRange(_ charRange: NSRange,
                                   affinity: NSSelectionAffinity,
                                   stillSelecting: Bool) {
        super.setSelectedRange(charRange, affinity: affinity, stillSelecting: stillSelecting)
        if foldEnabled { scheduleRefresh() }
    }

    override func didChangeText() {
        super.didChangeText()
        // Fold passes mutate the storage (permanent kern attributes) and must
        // not re-trigger the refresh timer.
        if foldEnabled && !isUpdatingFolds { scheduleRefresh() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // The rendered math is tinted to the theme text colour.
        MathRenderer.shared.clearCache()
        unrenderableKeys.removeAll()
        scheduleRefresh()
    }
}

// MARK: - Math block parsing

/// One foldable math block in the source buffer.
struct MathBlock {
    /// Full range in the text, including the delimiters/environment lines.
    let range: NSRange
    /// True for display math (centred, own paragraph) — false for inline.
    let display: Bool
    /// The LaTeX to hand to the renderer (no surrounding delimiters).
    let body: String
}

/// Pure string scanner for `$…$`, `$$…$$`, `\[…\]` and the display math
/// environments. Understands `\$` escapes and skips the second dollar of a
/// `$$` pair while scanning inline math. Unterminated blocks are left visible.
final class MathFoldParser {

    private let displayEnvs: Set<String> = [
        "equation", "equation*", "displaymath",
        "align", "align*", "gather", "gather*",
        "multline", "multline*",
    ]

    /// Envs whose body needs an `aligned` wrapper to render inside display math.
    private let alignedEnvs: Set<String> = [
        "align", "align*", "gather", "gather*",
        "multline", "multline*",
    ]

    func mathBlocks(in text: NSString) -> [MathBlock] {
        var result: [MathBlock] = []
        let n = text.length
        var i = 0
        while i < n {
            let c = text.character(at: i)
            if c == 36 { // `$`
                if let block = scanDollar(text, from: i) {
                    result.append(block)
                    i = block.range.location + block.range.length
                } else {
                    i += 1
                }
                continue
            }
            if c == 92 { // `\`
                if let block = scanEnvironment(text, from: i) ?? scanBracket(text, from: i) {
                    result.append(block)
                    i = block.range.location + block.range.length
                    continue
                }
            }
            i += 1
        }
        return result
    }

    /// The block the caret sits strictly inside (between the delimiters).
    func activeBlock(at caret: Int, in blocks: [MathBlock]) -> MathBlock? {
        for b in blocks
            where caret > b.range.location && caret < b.range.location + b.range.length {
            return b
        }
        return nil
    }

    // MARK: - Scanners

    private func scanDollar(_ text: NSString, from i: Int) -> MathBlock? {
        let n = text.length
        guard !isEscaped(text, i) else { return nil }

        let display = i + 1 < n && text.character(at: i + 1) == 36
        let open = display ? 2 : 1
        var j = i + open
        while j < n {
            let c = text.character(at: j)
            if c == 36 && !isEscaped(text, j) {
                if display {
                    if j + 1 < n && text.character(at: j + 1) == 36 {
                        return makeBlock(text, from: i, open: open,
                                         firstClosing: j, display: true)
                    }
                } else {
                    if j + 1 < n && text.character(at: j + 1) == 36 {
                        j += 1          // part of a $$ pair — keep scanning
                        continue
                    }
                    return makeBlock(text, from: i, open: open,
                                     firstClosing: j, display: false)
                }
            }
            j += 1
        }
        return nil
    }

    private func makeBlock(_ text: NSString, from start: Int, open: Int,
                           firstClosing: Int, display: Bool) -> MathBlock {
        // `firstClosing` is the index of the first closing `$` (for `$$` it is
        // the first of the pair). The body excludes every delimiter, and is
        // trimmed so multi-line display blocks don't smuggle blank lines into
        // the wrapped `$$…$$` the renderer builds.
        let bodyStart = start + open
        let body = text.substring(with: NSRange(location: bodyStart,
                                                length: firstClosing - bodyStart))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Range: [start, firstClosing + 1] for inline, [start, firstClosing + 2]
        // for display (the closing pair) — i.e. length = firstClosing - start + open.
        return MathBlock(range: NSRange(location: start,
                                        length: firstClosing - start + open),
                         display: display, body: body)
    }

    private func scanEnvironment(_ text: NSString, from start: Int) -> MathBlock? {
        let n = text.length
        guard start + 7 <= n,
              text.substring(with: NSRange(location: start, length: 7)) == "\\begin{" else {
            return nil
        }
        var k = start + 7
        let nameStart = k
        while k < n && text.character(at: k) != 125 { k += 1 }   // `}`
        guard k < n, k > nameStart else { return nil }
        let name = text.substring(with: NSRange(location: nameStart, length: k - nameStart))
        guard displayEnvs.contains(name) else { return nil }

        let bodyStart = k + 1
        let searchRange = NSRange(location: bodyStart, length: n - bodyStart)
        let endMarker = "\\end{\(name)}"
        let endLoc = text.range(of: endMarker, options: [], range: searchRange).location
        guard endLoc != NSNotFound else { return nil }

        let body = text.substring(with: NSRange(location: bodyStart, length: endLoc - bodyStart))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let content = alignedEnvs.contains(name)
            ? "\\begin{aligned}\n\(body)\n\\end{aligned}"
            : body
        let end = endLoc + endMarker.count
        return MathBlock(range: NSRange(location: start, length: end - start),
                         display: true, body: content)
    }

    private func scanBracket(_ text: NSString, from start: Int) -> MathBlock? {
        let n = text.length
        guard start + 1 < n,
              text.character(at: start) == 92,   // `\`
              text.character(at: start + 1) == 91 else { return nil }   // `[`
        var k = start + 2
        while k + 1 < n {
            if text.character(at: k) == 92, text.character(at: k + 1) == 93 {   // `\]`
                let body = text.substring(with: NSRange(location: start + 2,
                                                        length: k - (start + 2)))
                return MathBlock(range: NSRange(location: start, length: (k + 2) - start),
                                 display: true, body: body)
            }
            k += 1
        }
        return nil
    }

    private func isEscaped(_ text: NSString, _ index: Int) -> Bool {
        var count = 0
        var k = index - 1
        while k >= 0 && text.character(at: k) == 92 { count += 1; k -= 1 }
        return count % 2 == 1
    }
}
