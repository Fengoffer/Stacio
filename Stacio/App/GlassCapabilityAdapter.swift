import AppKit
import Foundation

// MARK: - System glass capability

public enum GlassCapability: Equatable, Sendable {
    case systemGlass
    case visualEffectFallback
    case unavailable
}

public enum GlassSurfaceKind: Equatable, Sendable {
    case systemGlass
    case visualEffectFallback
    case opaqueFallback
}

/// Injectable snapshot of the AppKit and accessibility state used to choose a
/// surface. Tests inject this value; production reads it from NSWorkspace.
public struct GlassCapabilityEnvironment: Equatable, Sendable {
    public let supportsSystemGlass: Bool
    public let supportsVisualEffectFallback: Bool
    public let reduceTransparency: Bool
    public let increaseContrast: Bool
    public let reduceMotion: Bool

    public init(
        supportsSystemGlass: Bool,
        supportsVisualEffectFallback: Bool = true,
        reduceTransparency: Bool,
        increaseContrast: Bool,
        reduceMotion: Bool = false
    ) {
        self.supportsSystemGlass = supportsSystemGlass
        self.supportsVisualEffectFallback = supportsVisualEffectFallback
        self.reduceTransparency = reduceTransparency
        self.increaseContrast = increaseContrast
        self.reduceMotion = reduceMotion
    }
}

public enum GlassCapabilityAdapter {
    @MainActor
    public static func currentEnvironment(
        workspace: NSWorkspace = .shared
    ) -> GlassCapabilityEnvironment {
        GlassCapabilityEnvironment(
            supportsSystemGlass: NSClassFromString("NSGlassEffectView") != nil,
            supportsVisualEffectFallback: NSClassFromString("NSVisualEffectView") != nil,
            reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
            increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast,
            reduceMotion: workspace.accessibilityDisplayShouldReduceMotion
        )
    }

    public static func detect(environment: GlassCapabilityEnvironment) -> GlassCapability {
        if environment.supportsSystemGlass,
           environment.reduceTransparency == false,
           environment.increaseContrast == false {
            return .systemGlass
        }
        if environment.supportsVisualEffectFallback {
            return .visualEffectFallback
        }
        return .unavailable
    }

    /// Compatibility entry point retained for existing callers and tests.
    public static func detect(
        supportsSDK27Glass: Bool,
        reduceTransparency: Bool,
        increaseContrast: Bool
    ) -> GlassCapability {
        detect(environment: GlassCapabilityEnvironment(
            supportsSystemGlass: supportsSDK27Glass,
            reduceTransparency: reduceTransparency,
            increaseContrast: increaseContrast
        ))
    }

    @MainActor
    public static func currentCapability() -> GlassCapability {
        detect(environment: currentEnvironment())
    }

    /// Creates the system-owned interactive material used by the V2 toolbar,
    /// composer, and decision surface. The timeline deliberately does not call
    /// this API so long-form content remains a quiet reading surface.
    @MainActor
    public static func makeInteractiveSurface(
        frame: NSRect = .zero,
        fallbackMaterial: NSVisualEffectView.Material,
        cornerRadius: CGFloat = 0,
        environment explicitEnvironment: GlassCapabilityEnvironment? = nil
    ) -> NSView {
        let environment = explicitEnvironment ?? currentEnvironment()
        switch detect(environment: environment) {
        case .systemGlass:
            if #available(macOS 26.0, *) {
                let surface = NSGlassEffectView(frame: frame)
                surface.cornerRadius = cornerRadius
                surface.clipsToBounds = cornerRadius > 0
                return surface
            }
            return makeVisualEffectFallback(
                frame: frame,
                material: fallbackMaterial,
                cornerRadius: cornerRadius
            )
        case .visualEffectFallback:
            return makeVisualEffectFallback(
                frame: frame,
                material: fallbackMaterial,
                cornerRadius: cornerRadius
            )
        case .unavailable:
            let surface = NSView(frame: frame)
            surface.wantsLayer = true
            surface.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            surface.layer?.cornerRadius = cornerRadius
            surface.layer?.cornerCurve = .continuous
            return surface
        }
    }

    @MainActor
    public static func surfaceKind(of view: NSView) -> GlassSurfaceKind {
        if #available(macOS 26.0, *), view is NSGlassEffectView {
            return .systemGlass
        }
        if view is NSVisualEffectView {
            return .visualEffectFallback
        }
        return .opaqueFallback
    }

    public static func animationsAllowed(environment: GlassCapabilityEnvironment) -> Bool {
        environment.reduceMotion == false
    }

    public static func timelineIsQuietReadingSurface(noPerCardGlass: Bool) -> Bool {
        noPerCardGlass
    }

    @MainActor
    private static func makeVisualEffectFallback(
        frame: NSRect,
        material: NSVisualEffectView.Material,
        cornerRadius: CGFloat
    ) -> NSVisualEffectView {
        let surface = NSVisualEffectView(frame: frame)
        surface.material = material
        surface.blendingMode = .withinWindow
        surface.state = .active
        if cornerRadius > 0 {
            surface.wantsLayer = true
            surface.layer?.cornerRadius = cornerRadius
            surface.layer?.cornerCurve = .continuous
        }
        return surface
    }
}
