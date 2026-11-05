import AppKit

@MainActor
final class TerminalAgentInteractionGlowView: NSView {
    private let glowLayer = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("Stacio.Terminal.agentInteractionGlow")
        setAccessibilityIdentifier("Stacio.Terminal.agentInteractionGlow")
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = false
        isHidden = true

        glowLayer.fillColor = NSColor.clear.cgColor
        glowLayer.strokeColor = NSColor.systemBlue.withAlphaComponent(0.38).cgColor
        glowLayer.lineWidth = 1.5
        glowLayer.shadowColor = NSColor.systemBlue.withAlphaComponent(0.95).cgColor
        glowLayer.shadowOffset = .zero
        glowLayer.shadowRadius = 16
        glowLayer.shadowOpacity = 0.82
        glowLayer.lineJoin = .round
        layer?.addSublayer(glowLayer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        glowLayer.frame = bounds
        let insetBounds = bounds.insetBy(dx: 1.5, dy: 1.5)
        glowLayer.path = CGPath(
            roundedRect: insetBounds,
            cornerWidth: 5,
            cornerHeight: 5,
            transform: nil
        )
        // Let Core Animation shadow the stroked edge only. A closed shadowPath
        // treats the whole rectangle as opaque and washes over terminal content.
        glowLayer.shadowPath = nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func setActive(_ active: Bool) {
        glowLayer.removeAnimation(forKey: "stacio.agentInteractionGlow")
        isHidden = !active
        guard active else { return }

        let pulse = CABasicAnimation(keyPath: "shadowOpacity")
        pulse.fromValue = 0.42
        pulse.toValue = 0.92
        pulse.duration = 1.1
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glowLayer.add(pulse, forKey: "stacio.agentInteractionGlow")
    }

    var isActiveForTesting: Bool {
        isHidden == false && glowLayer.animation(forKey: "stacio.agentInteractionGlow") != nil
    }

    var preservesTransparentCenterForTesting: Bool {
        glowLayer.shadowPath == nil && (glowLayer.fillColor ?? NSColor.clear.cgColor).alpha == 0
    }
}
