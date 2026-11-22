import AppKit

/// A small animated indicator shown at the tail of the transcript while the
/// assistant is working. Two captions share one flowing gradient so the cue
/// reads as alive whether the turn is thinking or running a tool.
public final class AIThinkingIndicatorView: NSView {
    private static let palette: [NSColor] = [
        NSColor.systemBlue,
        NSColor.systemPurple,
        NSColor.systemPink,
        NSColor.systemOrange,
    ]

    private let label = NSTextField(labelWithString: "")
    private let dotStack = NSStackView()
    private var dots: [NSView] = []
    private var animationTimer: Timer?
    private var currentCaption = ""
    private var captionTick  = 0

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    deinit { stopAnimating() }
    // MARK: - Configuration

    private func configure() {
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("Stacio.AI.thinkingIndicator")
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel("助手正在思考")

        dotStack.translatesAutoresizingMaskIntoConstraints = false
        dotStack.orientation = .horizontal
        dotStack.alignment = .centerY
        dotStack.spacing  = 4
        dots = (0..<3).map { _ in
            let dot = NSView(frame: .zero)
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 2.5
            dot.layer?.cornerCurve = .continuous
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 5),
                dot.heightAnchor.constraint(equalToConstant: 5)
            ])
            return dot
        }
        dots.forEach { dotStack.addArrangedSubview($0) }

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: StacioDesignSystem.theme.fontSizeFootnote, weight: .medium)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setAccessibilityElement(false)

        addSubview(dotStack)
        addSubview(label)
        NSLayoutConstraint.activate([
            dotStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            dotStack.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: dotStack.trailingAnchor, constant:8),
            label.topAnchor.constraint(equalTo: topAnchor, constant:2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor)
        ])
    }
    // MARK: - Content

    /// Applies a caption such as思考中 and restarts the pulse if it changed.
    public func apply(caption: String) {
        guard caption != currentCaption else { return }
        currentCaption = caption
        captionTick  = 0
        updateLabelText()
        setAccessibilityLabel("助手正在\(caption)")
    }

    private func updateLabelText() {
        guard currentCaption.isEmpty == false else {
            label.stringValue = ""
            return
        }
        let suffix = String(repeating: ".", count: captionTick % 4)
        label.attributedStringValue = gradientText(for: currentCaption + suffix)
    }

    // MARK: - Flowing gradient

    /// Paints every character from a moving palette. The phase advances once per
    /// animation frame, so colour travels along the text instead of sitting still.
    private func gradientText(for text: String) -> NSAttributedString {
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [.font: label.font as Any]
        )
        let length = attributed.length
        guard length > 0 else { return attributed }

        for index in 0..<length {
            let phase = Double(index) / Double(max(length, 1))
            let shift = Double(captionTick) * 0.06
            let position = (phase + shift).truncatingRemainder(dividingBy: 1)
            attributed.addAttribute(
                .foregroundColor,
                value: Self.interpolatedColor(position: position),
                range: NSRange(location: index, length: 1)
            )
        }
        return attributed
    }
    private static func interpolatedColor(position: Double) -> NSColor {
        guard palette.isEmpty == false else { return .secondaryLabelColor }
        let scaled = position * Double(palette.count)
        let lower = Int(scaled) % palette.count
        let upper = (lower + 1) % palette.count
        let fraction = scaled - Double(Int(scaled))

        guard let from = palette[lower].usingColorSpace(.sRGB),
        let to = palette[upper].usingColorSpace(.sRGB)
        else {
            return palette[lower]
        }
        return NSColor(
            srgbRed: from.redComponent + (to.redComponent - from.redComponent) * fraction,
            green: from.greenComponent + (to.greenComponent - from.greenComponent) * fraction,
            blue: from.blueComponent + (to.blueComponent - from.blueComponent) * fraction,
            alpha: 1
        )
    }

    // MARK: - Animation

    public func startAnimating() {
        guard animationTimer == nil else { return }
        let timer = Timer(timeInterval: 0.18, repeats: true) { [weak self] _ in
            self?.advanceFrame()
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
        advanceFrame()
    }

    public func stopAnimating() {
        animationTimer?.invalidate()
        animationTimer = nil
        applyDotHighlight(highlightIndex: nil)
    }

    private func advanceFrame() {
        captionTick += 1
        updateLabelText()
        applyDotHighlight(highlightIndex: captionTick % max(1, dots.count))
    }

    private func applyDotHighlight(highlightIndex: Int?) {
        for (index, dot) in dots.enumerated() {
            let isActive = highlightIndex == index
            let color = Self.palette[index % Self.palette.count]
                .withAlphaComponent(isActive ? 0.95 : 0.25)
            StacioDesignSystem.setLayerBackgroundColor(dot, color: color)
        }
    }

    // MARK: - Test seams

    public var captionForTesting: String { label.stringValue }
    public var isAnimatingForTesting: Bool { animationTimer != nil }
    public func advanceFrameForTesting() { advanceFrame() }
}