import AppKit
import XCTest
@testable import StacioApp

@MainActor
final class GlassCapabilityAdapterTests: XCTestCase {
    func testSystemGlassRequiresCapabilityAndNormalContrast() {
        XCTAssertEqual(
            GlassCapabilityAdapter.detect(environment: .init(
                supportsSystemGlass: true,
                reduceTransparency: false,
                increaseContrast: false
            )),
            .systemGlass
        )
        XCTAssertEqual(
            GlassCapabilityAdapter.detect(environment: .init(
                supportsSystemGlass: true,
                reduceTransparency: true,
                increaseContrast: false
            )),
            .visualEffectFallback
        )
        XCTAssertEqual(
            GlassCapabilityAdapter.detect(environment: .init(
                supportsSystemGlass: true,
                reduceTransparency: false,
                increaseContrast: true
            )),
            .visualEffectFallback
        )
    }

    func testNoAppKitMaterialFallsBackToOpaqueSurface() {
        let environment = GlassCapabilityEnvironment(
            supportsSystemGlass: false,
            supportsVisualEffectFallback: false,
            reduceTransparency: false,
            increaseContrast: false
        )
        XCTAssertEqual(GlassCapabilityAdapter.detect(environment: environment), .unavailable)
        let surface = GlassCapabilityAdapter.makeInteractiveSurface(
            fallbackMaterial: .popover,
            environment: environment
        )
        XCTAssertEqual(GlassCapabilityAdapter.surfaceKind(of: surface), .opaqueFallback)
    }

    func testVisualEffectFallbackIsARealAppKitSurface() {
        let environment = GlassCapabilityEnvironment(
            supportsSystemGlass: false,
            reduceTransparency: true,
            increaseContrast: false
        )
        let surface = GlassCapabilityAdapter.makeInteractiveSurface(
            fallbackMaterial: .contentBackground,
            environment: environment
        )
        XCTAssertEqual(GlassCapabilityAdapter.surfaceKind(of: surface), .visualEffectFallback)
        XCTAssertTrue(surface is NSVisualEffectView)
    }

    func testCurrentSystemGlassFactoryMatchesDetectedCapability() {
        let surface = GlassCapabilityAdapter.makeInteractiveSurface(
            fallbackMaterial: .headerView
        )
        switch GlassCapabilityAdapter.currentCapability() {
        case .systemGlass:
            XCTAssertEqual(GlassCapabilityAdapter.surfaceKind(of: surface), .systemGlass)
        case .visualEffectFallback:
            XCTAssertEqual(GlassCapabilityAdapter.surfaceKind(of: surface), .visualEffectFallback)
        case .unavailable:
            XCTAssertEqual(GlassCapabilityAdapter.surfaceKind(of: surface), .opaqueFallback)
        }
    }

    func testReduceMotionDisablesOptionalAnimation() {
        XCTAssertFalse(GlassCapabilityAdapter.animationsAllowed(environment: .init(
            supportsSystemGlass: true,
            reduceTransparency: false,
            increaseContrast: false,
            reduceMotion: true
        )))
        XCTAssertTrue(GlassCapabilityAdapter.animationsAllowed(environment: .init(
            supportsSystemGlass: true,
            reduceTransparency: false,
            increaseContrast: false,
            reduceMotion: false
        )))
    }

    func testV2InteractiveControllersUseAdapterSurfaceAndTimelineStaysQuiet() {
        let expected: GlassSurfaceKind
        switch GlassCapabilityAdapter.currentCapability() {
        case .systemGlass: expected = .systemGlass
        case .visualEffectFallback: expected = .visualEffectFallback
        case .unavailable: expected = .opaqueFallback
        }

        let toolbar = ConversationToolbarViewController()
        let composer = AgentComposerViewController()
        let decision = ToolDecisionViewController()
        XCTAssertEqual(GlassCapabilityAdapter.surfaceKind(of: toolbar.view), expected)
        XCTAssertEqual(GlassCapabilityAdapter.surfaceKind(of: composer.view), expected)
        XCTAssertEqual(GlassCapabilityAdapter.surfaceKind(of: decision.view), expected)
        XCTAssertTrue(GlassCapabilityAdapter.timelineIsQuietReadingSurface(noPerCardGlass: true))
        XCTAssertFalse(GlassCapabilityAdapter.timelineIsQuietReadingSurface(noPerCardGlass: false))
    }
}
