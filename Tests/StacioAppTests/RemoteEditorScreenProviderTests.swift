import AppKit
import XCTest
@testable import StacioApp

final class RemoteEditorScreenProviderTests: XCTestCase {
    private let screens = [
        RemoteEditorScreenDescriptor(
            identity: .init(
                displayID: 1,
                localizedName: "Studio Display",
                frame: .init(x: 0, y: 0, width: 1_440, height: 900)
            ),
            frame: .init(x: 0, y: 0, width: 1_440, height: 900),
            visibleFrame: .init(x: 0, y: 24, width: 1_440, height: 876)
        ),
        RemoteEditorScreenDescriptor(
            identity: .init(
                displayID: 2,
                localizedName: "Studio Display",
                frame: .init(x: 1_440, y: 0, width: 2_560, height: 1_440)
            ),
            frame: .init(x: 1_440, y: 0, width: 2_560, height: 1_440),
            visibleFrame: .init(x: 1_440, y: 0, width: 2_560, height: 1_415)
        ),
        RemoteEditorScreenDescriptor(
            identity: .init(
                displayID: 3,
                localizedName: "Projector",
                frame: .init(x: -1_920, y: 900, width: 1_920, height: 1_080)
            ),
            frame: .init(x: -1_920, y: 900, width: 1_920, height: 1_080),
            visibleFrame: .init(x: -1_920, y: 900, width: 1_920, height: 1_056)
        )
    ]

    func testResolvesByDisplayIDBeforeDuplicateNameAndGeometry() {
        let saved = RemoteEditorScreenIdentity(
            displayID: 2,
            localizedName: "Studio Display",
            frame: .init(x: 0, y: 0, width: 1_440, height: 900)
        )

        XCTAssertEqual(RemoteEditorScreenResolver.resolve(saved, screens: screens)?.identity.displayID, 2)
    }

    func testResolvesMissingIDToSameNameWithNearestGeometry() {
        let saved = RemoteEditorScreenIdentity(
            displayID: 99,
            localizedName: "Studio Display",
            frame: .init(x: 1_500, y: 0, width: 2_500, height: 1_400)
        )

        XCTAssertEqual(RemoteEditorScreenResolver.resolve(saved, screens: screens)?.identity.displayID, 2)
    }

    func testLabelsDuplicateNamesWithStableScreenNumbers() {
        XCTAssertEqual(
            RemoteEditorScreenResolver.menuLabels(for: screens),
            ["显示器 1 - Studio Display", "显示器 2 - Studio Display", "Projector"]
        )
    }

    func testMenuLabelsUseGeometryOrderInsteadOfInputOrder() {
        XCTAssertEqual(
            RemoteEditorScreenResolver.menuLabels(for: [screens[2], screens[1], screens[0]]),
            ["Projector", "显示器 2 - Studio Display", "显示器 1 - Studio Display"]
        )
    }

    func testClampsOffscreenFrameIntoFallbackVisibleFrame() {
        let visibleFrame = screens[0].visibleFrame
        let result = RemoteEditorScreenResolver.clamp(
            NSRect(x: 8_000, y: -3_000, width: 980, height: 720),
            to: visibleFrame,
            minimumSize: NSSize(width: 720, height: 480)
        )

        XCTAssertTrue(visibleFrame.contains(result))
        XCTAssertGreaterThanOrEqual(result.width, 720)
        XCTAssertGreaterThanOrEqual(result.height, 480)
    }

    func testClampShrinksOversizedFrameToPhysicalVisibleFrame() {
        let visibleFrame = NSRect(x: -1_920, y: 900, width: 800, height: 600)
        let result = RemoteEditorScreenResolver.clamp(
            NSRect(x: -4_000, y: 0, width: 1_800, height: 1_200),
            to: visibleFrame,
            minimumSize: NSSize(width: 720, height: 480)
        )

        XCTAssertEqual(result, visibleFrame)
    }
}
