import AppKit
import QuartzCore

/// Animated status text used while the assistant is actively executing work.
/// The effect is clipped to the glyphs so it stays legible and does not add
/// decorative movement to the surrounding timeline surface.
class FlowingActivityTextField: NSTextField {
    private enum AnimationKey {
        static let gradient = "stacio.activity.gradient"
        static let glow = "stacio.activity.glow"
    }

    private let effectLayer = CALayer()
    private let gradientLayer = CAGradientLayer()
    private let particleLayer = CAEmitterLayer()
    /// A soft specular band that makes the gradient read as a liquid surface
    /// rather than a flat colour sweep.
    private let sheenLayer = CAGradientLayer()
    /// A narrow highlight that travels across the glyphs.
    private let glintLayer = CAGradientLayer()
    private let textMaskLayer = CATextLayer()
    private var fallbackTextColor: NSColor?
    private var displayOptionsObserver: NSObjectProtocol?
    private var animatedWidth: CGFloat = 0

    private(set) var isFlowingActivityEffectEnabled = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        installEffectLayers()
        observeAccessibilityDisplayOptions()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        installEffectLayers()
        observeAccessibilityDisplayOptions()
    }

    deinit {
        if let displayOptionsObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(displayOptionsObserver)
        }
    }

    override func layout() {
        super.layout()
        layoutEffectLayers()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshAnimationState()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updatePalette()
    }

    /// Forces the current attributed content to a colour so the mask can show
    /// through. AppKit prefers attribute colours over `textColor`.
    private func applyTextColor(_ color: NSColor?) {
        guard let color else { return }
        let current = attributedStringValue
        guard current.length > 0 else { return }
        let recolored = NSMutableAttributedString(attributedString: current)
        recolored.addAttribute(
            .foregroundColor,
            value: color,
            range: NSRange(location: 0, length: recolored.length)
        )
        attributedStringValue = recolored
    }

    func setFlowingActivityEffectEnabled(_ enabled: Bool, fallbackColor: NSColor? = nil) {
        if let fallbackColor {
            fallbackTextColor = fallbackColor
        } else if enabled, textColor != .clear {
            fallbackTextColor = textColor
        }

        isFlowingActivityEffectEnabled = enabled
        effectLayer.isHidden = enabled == false
        textColor = enabled ? .clear : (fallbackTextColor ?? StacioDesignSystem.theme.secondaryTextColor)

        // Assigning an attributed string later overrides textColor, so the
        // existing attributes must be cleared too or the glyphs stay opaque
        // and hide the gradient entirely.
        applyTextColor(enabled ? .clear : fallbackTextColor)
        updateTextMask()
        refreshAnimationState()
    }

    private func installEffectLayers() {
        wantsLayer = true
        effectLayer.masksToBounds = false
        effectLayer.isHidden = true
        effectLayer.mask = textMaskLayer
        effectLayer.addSublayer(gradientLayer)
        effectLayer.addSublayer(particleLayer)
        layer?.addSublayer(effectLayer)

        gradientLayer.startPoint = CGPoint(x: 0, y: 0.5)
        gradientLayer.endPoint = CGPoint(x: 1, y: 0.5)
        gradientLayer.locations = [0, 0.18, 0.36, 0.54, 0.72, 0.9, 1]

        // A vertical specular wash sells the liquid surface.
        sheenLayer.startPoint = CGPoint(x: 0.5, y: 0)
        sheenLayer.endPoint = CGPoint(x: 0.5, y: 1)
        sheenLayer.locations = [0,0.42,0.58,1]

        // A short bright band that travels along the text.
        glintLayer.startPoint = CGPoint(x: 0, y: 0.5)
        glintLayer.endPoint = CGPoint(x: 1, y: 0.5)
        glintLayer.locations = [0,0.08,0.16,1]

        particleLayer.emitterShape = .line
        particleLayer.emitterMode = .outline
        particleLayer.renderMode = .additive
        updatePalette()
    }

    private func observeAccessibilityDisplayOptions() {
        displayOptionsObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshAnimationState()
        }
    }

    private func layoutEffectLayers() {
        guard let cell else { return }
        let textRect = cell.drawingRect(forBounds: bounds)
        effectLayer.frame = bounds
        textMaskLayer.frame = textRect
        textMaskLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        gradientLayer.frame = CGRect(
            x: -bounds.width,
            y: 0,
            width: max(bounds.width * 3, 1),
            height: max(bounds.height, 1)
        )
        sheenLayer.frame = CGRect(
            x: 0,
            y: 0,
            width: max(bounds.width,1),
            height: max(bounds.height,1)
        )
        glintLayer.frame = CGRect(
            x: -bounds.width,
            y: 0,
            width: max(bounds.width * 3,1),
            height: max(bounds.height,1)
        )
        particleLayer.frame = bounds
        particleLayer.emitterPosition = CGPoint(x: 0, y: bounds.midY)
        particleLayer.emitterSize = CGSize(width: 1, height: max(bounds.height * 0.8, 1))
        updateTextMask()
        if isFlowingActivityEffectEnabled, abs(animatedWidth - bounds.width) > 0.5 {
            refreshAnimationState()
        }
    }
    private func updateTextMask() {
        textMaskLayer.string = stringValue
        textMaskLayer.font = font?.fontName as CFTypeRef?
        textMaskLayer.fontSize = font?.pointSize ?? NSFont.systemFontSize
        textMaskLayer.alignmentMode = textAlignmentMode
        textMaskLayer.truncationMode = .end
        textMaskLayer.isWrapped = false
    }

    private var textAlignmentMode: CATextLayerAlignmentMode {
        switch alignment {
        case .center: return .center
        case .right: return .right
        case .justified: return .justified
        default: return .left
        }
    }

    private func updatePalette() {
        let colors: [NSColor] = [
            .systemTeal,
            .systemBlue,
            .systemPurple,
            .systemPink,
            .systemOrange,
            .systemYellow,
            .systemTeal
        ]
        gradientLayer.colors = colors.map { resolvedCGColor($0) }
        sheenLayer.colors = [
            resolvedCGColor(NSColor.white.withAlphaComponent(0.30)),
            resolvedCGColor(NSColor.white.withAlphaComponent(0.02)),
            resolvedCGColor(NSColor.white.withAlphaComponent(0.16)),
            resolvedCGColor(NSColor.white.withAlphaComponent(0)),
        ]
        glintLayer.colors = [
            resolvedCGColor(NSColor.white.withAlphaComponent(0)),
            resolvedCGColor(NSColor.white.withAlphaComponent(0.85)),
            resolvedCGColor(NSColor.white.withAlphaComponent(0)),
            resolvedCGColor(NSColor.white.withAlphaComponent(0)),
        ]
        effectLayer.shadowColor = resolvedCGColor(.systemPurple)
        effectLayer.shadowOpacity = 0.34
        effectLayer.shadowRadius = 4
        effectLayer.shadowOffset = .zero
        particleLayer.emitterCells = particleColors(from: colors)
    }

    private func particleColors(from colors: [NSColor]) -> [CAEmitterCell] {
        guard let image = Self.particleImage else { return [] }
        return stride(from: 0, to: colors.count - 1, by: 2).map { index in
            let cell = CAEmitterCell()
            cell.contents = image
            cell.color = resolvedCGColor(colors[index])
            cell.birthRate = 2.2
            cell.lifetime = 2.8
            cell.lifetimeRange = 0.7
            cell.velocity = 34
            cell.velocityRange = 12
            cell.emissionLongitude = 0
            cell.emissionRange = 0.16
            cell.scale = 0.38
            cell.scaleRange = 0.22
            cell.alphaSpeed = -0.22
            return cell
        }
    }

    /// Re-runs the animation setup so tests can assert it after layout.
    func refreshAnimationStateForTesting() { refreshAnimationState() }

    /// Installed gradient animation count, or nil when nothing is animating.
    var gradientAnimationKeyCountForTesting: Int? { gradientLayer.animationKeys()?.count }

    /// The gradient is clipped to this mask; an empty one hides the effect.
    var textMaskFrameForTesting: CGRect { textMaskLayer.frame }

    private func refreshAnimationState() {
        gradientLayer.removeAnimation(forKey: AnimationKey.gradient)
        effectLayer.removeAnimation(forKey: AnimationKey.glow)
        particleLayer.birthRate = 0
        sheenLayer.removeAnimation(forKey: "stacio.activity.sheen")
        glintLayer.removeAnimation(forKey: "stacio.activity.glint")
        animatedWidth = 0

        guard isFlowingActivityEffectEnabled,
              window != nil,
              bounds.width > 1,
              NSWorkspace.shared.accessibilityDisplayShouldReduceMotion == false
        else { return }

        animatedWidth = bounds.width
        particleLayer.birthRate = 1

        let gradientAnimation = CABasicAnimation(keyPath: "transform.translation.x")
        gradientAnimation.fromValue = 0
        gradientAnimation.toValue = bounds.width
        gradientAnimation.duration = 2.65
        gradientAnimation.repeatCount = .infinity
        gradientAnimation.timingFunction = CAMediaTimingFunction(name: .linear)
        gradientLayer.add(gradientAnimation, forKey: AnimationKey.gradient)

        let sheenAnimation = CABasicAnimation(keyPath: "opacity")
        sheenAnimation.fromValue = 0.35
        sheenAnimation.toValue = 0.85
        sheenAnimation.duration = 1.9
        sheenAnimation.autoreverses = true
        sheenAnimation.repeatCount = .infinity
        sheenAnimation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        sheenLayer.add(sheenAnimation, forKey: "stacio.activity.sheen")

        let glintAnimation = CABasicAnimation(keyPath: "transform.translation.x")
        glintAnimation.fromValue = -bounds.width
        glintAnimation.toValue = bounds.width
        glintAnimation.duration = 1.7
        glintAnimation.repeatCount = .infinity
        glintAnimation.timingFunction = CAMediaTimingFunction(name: .easeIn)
        glintLayer.add(glintAnimation, forKey: "stacio.activity.glint")

        let glowAnimation = CABasicAnimation(keyPath: "shadowOpacity")
        glowAnimation.fromValue = 0.2
        glowAnimation.toValue = 0.48
        glowAnimation.duration = 1.15
        glowAnimation.autoreverses = true
        glowAnimation.repeatCount = .infinity
        glowAnimation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        effectLayer.add(glowAnimation, forKey: AnimationKey.glow)
    }

    private func resolvedCGColor(_ color: NSColor) -> CGColor {
        var resolved = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.deviceRGB)?.cgColor ?? color.cgColor
        }
        return resolved
    }

    private static let particleImage: CGImage? = {
        let size = 8
        guard let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(NSColor.white.cgColor)
        context.fillEllipse(in: CGRect(x: 1, y: 1, width: 6, height: 6))
        return context.makeImage()
    }()
}
