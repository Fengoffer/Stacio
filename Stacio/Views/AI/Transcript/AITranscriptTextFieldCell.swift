import AppKit

/// Shares one TextKit layout between measurement, drawing and selection. The
/// default cell's NSStringDrawing path reshapes an entire long CJK answer for
/// each of those operations, even when only the visible tail is being painted.
final class AITranscriptTextFieldCell: NSTextFieldCell {
    private let textStorage = NSTextStorage()
    private let textLayoutManager = NSLayoutManager()
    private let textContainer = NSTextContainer(containerSize: .zero)
    private var cachedText: NSAttributedString?
    private var cachedWidth: CGFloat = -1
    private var cachedLineBreakMode: NSLineBreakMode?
    private var cachedSize = NSSize.zero
    private var layoutNeedsRefresh = false
    private var hasConfiguredFieldEditor = false
    private lazy var selectionEditor: NSTextView = {
        let editor = NSTextView(frame: .zero, textContainer: textContainer)
        editor.isFieldEditor = true
        return editor
    }()
    private(set) var layoutPassCountForTesting = 0

    override init(textCell string: String) {
        super.init(textCell: string)
        configureTextLayout()
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        configureTextLayout()
    }

    private func configureTextLayout() {
        textContainer.lineFragmentPadding = 0
        textStorage.addLayoutManager(textLayoutManager)
        textLayoutManager.addTextContainer(textContainer)
    }

    private func prepareLayout(width: CGFloat) {
        let width = max(1, width)
        let text = attributedStringValue
        let textChanged = cachedText?.isEqual(to: text) != true
        guard textChanged || layoutNeedsRefresh || abs(width - cachedWidth) > 0.5
            || cachedLineBreakMode != lineBreakMode else { return }
        if textChanged {
            let isSelecting = selectionEditor.superview != nil
            let selection = isSelecting ? selectionEditor.selectedRanges : []
            // AppKit's field-editor setup affects font metrics. Do it before
            // the first measurement, so beginning a selection cannot reflow
            // an answer that was measured with different typesetter settings.
            if hasConfiguredFieldEditor == false {
                _ = super.setUpFieldEditorAttributes(selectionEditor)
                hasConfiguredFieldEditor = true
            }
            cachedText = NSAttributedString(attributedString: text)
            // Replacing the whole storage invalidates every laid-out glyph, so
            // a streamed answer re-typesets from the top each frame. When the
            // new text only extends the old one, append the tail instead: the
            // paragraphs already on screen keep their layout.
            if appendOnlyTail(of: text) == false {
                textStorage.setAttributedString(text)
            }
            if isSelecting {
                selectionEditor.selectedRanges = selection.map { value in
                    let range = value.rangeValue
                    let location = min(range.location, text.length)
                    return NSValue(range: NSRange(location: location, length: min(range.length, text.length - location)))
                }
            }
        }
        cachedWidth = width
        cachedLineBreakMode = lineBreakMode
        configureContainer(width: width)
        textLayoutManager.ensureLayout(for: textContainer)
        let used = textLayoutManager.usedRect(for: textContainer)
        cachedSize = NSSize(width: ceil(used.maxX), height: ceil(used.maxY))
        layoutNeedsRefresh = false
        layoutPassCountForTesting += 1
    }

    /// Appends only the new suffix when `text` extends what is already laid
    /// out, and reports whether it could. Appending keeps the earlier
    /// paragraphs valid, so a growing answer no longer re-typesets from the
    /// first character on every frame.
    private func appendOnlyTail(of text: NSAttributedString) -> Bool {
        let existing = textStorage.string
        let incoming = text.string
        guard incoming.hasPrefix(existing), incoming.count > existing.count else {
            return false
        }
        let tail = text.attributedSubstring(from: NSRange(
            location: (existing as NSString).length,
            length: text.length - (existing as NSString).length
        ))
        textStorage.append(tail)
        return true
    }

    private func configureContainer(width: CGFloat) {
        selectionEditor.textContainerInset = NSSize(width: 2, height: 0)
        textContainer.lineFragmentPadding = 0
        textContainer.widthTracksTextView = false
        textContainer.heightTracksTextView = false
        textContainer.containerSize = NSSize(width: max(1, width), height: .greatestFiniteMagnitude)
        textContainer.lineBreakMode = lineBreakMode
    }

    override func cellSize(forBounds rect: NSRect) -> NSSize {
        let preferredWidth = (controlView as? NSTextField)?.preferredMaxLayoutWidth ?? 0
        let availableWidth = rect.width > 4 ? rect.width - 4 : preferredWidth
        let width = preferredWidth > 0 ? min(preferredWidth, max(1, availableWidth)) : max(1, availableWidth)
        prepareLayout(width: width)
        return NSSize(width: cachedSize.width + 4, height: cachedSize.height)
    }

    override var cellSize: NSSize {
        cellSize(forBounds: controlView?.bounds ?? .zero)
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        var result = rect.insetBy(dx: 2, dy: 0)
        let preferredWidth = (controlView as? NSTextField)?.preferredMaxLayoutWidth ?? 0
        if preferredWidth > 0 { result.size.width = min(result.width, preferredWidth) }
        return result
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        // AppKit overlays a field editor while the user selects text. The
        // normal cell suppresses its glyphs then; our custom drawing must too.
        guard (controlView as? NSTextField)?.currentEditor() == nil else { return }
        let textRect = drawingRect(forBounds: cellFrame)
        prepareLayout(width: textRect.width)
        let visibleRect = controlView.visibleRect.intersection(textRect)
        guard visibleRect.isEmpty == false else { return }
        let origin = textRect.origin
        let containerRect = visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphs = textLayoutManager.glyphRange(forBoundingRect: containerRect, in: textContainer)
        NSGraphicsContext.saveGraphicsState()
        textRect.clip()
        textLayoutManager.drawBackground(forGlyphRange: glyphs, at: origin)
        textLayoutManager.drawGlyphs(forGlyphRange: glyphs, at: origin)
        NSGraphicsContext.restoreGraphicsState()
    }

    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        return selectionEditor
    }

    override func setUpFieldEditorAttributes(_ textObj: NSText) -> NSText {
        let editor = super.setUpFieldEditorAttributes(textObj)
        hasConfiguredFieldEditor = true
        configureContainer(width: drawingRect(forBounds: controlView?.bounds ?? .zero).width)
        layoutNeedsRefresh = true
        return editor
    }

    override func endEditing(_ textObj: NSText) {
        super.endEditing(textObj)
        // The field editor can reset its storage and container on exit.
        cachedText = nil
        layoutNeedsRefresh = true
    }

    func characterIndex(at point: NSPoint, in bounds: NSRect, isFlipped: Bool) -> Int? {
        let textRect = drawingRect(forBounds: bounds)
        guard attributedStringValue.length > 0, textRect.contains(point) else { return nil }
        prepareLayout(width: textRect.width)
        let localPoint = NSPoint(
            x: point.x - textRect.minX,
            y: isFlipped ? point.y - textRect.minY : textRect.maxY - point.y
        )
        let glyph = textLayoutManager.glyphIndex(for: localPoint, in: textContainer)
        guard glyph < textLayoutManager.numberOfGlyphs,
              textLayoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
                .insetBy(dx: -2, dy: -2).contains(localPoint) else { return nil }
        return textLayoutManager.characterIndexForGlyph(at: glyph)
    }

    /// One rect per laid-out line, covering only the width actually used.
    ///
    /// The field covers its whole bounds with a text cursor otherwise, so
    /// the empty tail beside a short line claimed the pointer too.
    func glyphLineRects(forWidth width: CGFloat) -> [NSRect] {
        prepareLayout(width: width)
        var rects: [NSRect] = []
        var index = 0
        let total = textLayoutManager.numberOfGlyphs
        while index < total {
                var lineRange = NSRange()
                let used = textLayoutManager.lineFragmentUsedRect(
                                forGlyphAt: index,
                                effectiveRange: &lineRange
                )
                if used.isEmpty == false { rects.append(used) }
                let next = NSMaxRange(lineRange)
                guard next > index else { break }
                index = next
        }
        return rects
    }

    func glyphRectForTesting(characterIndex: Int) -> NSRect {
        textLayoutManager.ensureLayout(for: textContainer)
        let glyph = textLayoutManager.glyphIndexForCharacter(at: characterIndex)
        return textLayoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
    }
}
