import AppKit
import QuartzCore

/// A label that paints a travelling gradient across its own glyphs.
final class ActivityShimmerLabel: NSTextField {
    private let shimmerLayer = CAGradientLayer()
    private let shimmerMask = CATextLayer()
    private(set) var isShimmering = false
    private var fallbackTextColor: NSColor = .labelColor

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        isEditable = false
        isSelectable = false
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        fallbackTextColor = textColor ?? .labelColor
        wantsLayer = true
        shimmerLayer.mask = shimmerMask
        shimmerLayer.startPoint = CGPoint(x: 0, y: 0.5)
        shimmerLayer.endPoint = CGPoint(x: 1, y: 0.5)
        shimmerLayer.locations = [0, 0.35, 0.5, 0.65, 1]
        shimmerLayer.colors = [
            NSColor.systemTeal.cgColor,
            NSColor.systemBlue.cgColor,
            NSColor.white.cgColor,
            NSColor.systemPurple.cgColor,
            NSColor.systemPink.cgColor
        ]
        shimmerLayer.isHidden = true
        shimmerMask.alignmentMode = .left
        shimmerMask.foregroundColor = NSColor.white.cgColor
    }

    func setShimmering(_ enabled: Bool) {
        if enabled {
            if isShimmering == false, textColor != .clear {
                fallbackTextColor = textColor ?? fallbackTextColor
            }
            isShimmering = true
            // Applying a new string can restore opaque attributes even while
            // the running state is unchanged. Keep the native glyphs clear.
            textColor = .clear
            applyAttributeColor(.clear)
            syncShimmerText()
        } else if isShimmering {
            isShimmering = false
            shimmerLayer.removeAllAnimations()
            shimmerLayer.isHidden = true
            textColor = fallbackTextColor
            applyAttributeColor(fallbackTextColor)
        }
    }

    func syncShimmerText() {
        guard isShimmering else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // AppKit may create the backing layer only after the label is mounted.
        // Retry from layout/window callbacks rather than animating an orphan.
        if let layer, shimmerLayer.superlayer !== layer {
            layer.addSublayer(shimmerLayer)
        }
        shimmerLayer.isHidden = false
        shimmerLayer.frame = bounds
        shimmerMask.frame = cell?.drawingRect(forBounds: bounds) ?? bounds
        shimmerMask.contentsScale = window?.backingScaleFactor ?? 2
        shimmerMask.string = stringValue
        shimmerMask.font = font
        shimmerMask.fontSize = font?.pointSize ?? 13
        CATransaction.commit()
        startAnimationIfVisible()
    }

    override func layout() {
        super.layout()
        syncShimmerText()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            shimmerLayer.removeAllAnimations()
        } else {
            syncShimmerText()
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncShimmerText()
    }

    private func applyAttributeColor(_ color: NSColor) {
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

    var hasRunningShimmerAnimationForTesting: Bool {
        shimmerLayer.animation(forKey: "stacio.shimmer") != nil
    }

    private func startAnimationIfVisible() {
        guard window != nil,
              bounds.width > 0,
              bounds.height > 0,
              shimmerLayer.superlayer != nil,
              shimmerLayer.animation(forKey: "stacio.shimmer") == nil
        else { return }
        let travel = CABasicAnimation(keyPath: "locations")
        travel.fromValue = [-1.0, -0.6, -0.5, -0.4, 0.0]
        travel.toValue = [1.0, 1.4, 1.5, 1.6, 2.0]
        travel.duration = 1.6
        travel.repeatCount = .infinity
        travel.timingFunction = CAMediaTimingFunction(name: .linear)
        shimmerLayer.add(travel, forKey: "stacio.shimmer")
    }
}
