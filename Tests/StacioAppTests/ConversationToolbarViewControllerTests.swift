import AppKit
import XCTest
@testable import StacioApp

@MainActor
final class ConversationToolbarViewControllerTests: XCTestCase {
    func testIdentityChangeUsesSeparateCollapsibleStatusRow() {
        let controller = ConversationToolbarViewController()
        controller.loadViewIfNeeded()
        controller.configure(
            title: "排查助手",
            targetIdentity: "deploy@example.com · /srv/application",
            runtimeStatus: "Native · Kimi"
        )
        let compactHeight = controller.view.fittingSize.height

        controller.showIdentityChange("目标工作目录已变化，请确认后继续")
        let expandedHeight = controller.view.fittingSize.height
        controller.view.frame = NSRect(x: 0, y: 0, width: 360, height: expandedHeight)
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(expandedHeight, compactHeight)
        XCTAssertFalse(
            controller.primaryRowFrameForTesting.intersects(controller.identityChangeFrameForTesting),
            "内联状态必须占独立行，不能覆盖目标或 Runtime"
        )
        XCTAssertEqual(controller.displayedIdentityChangeMessage, "目标工作目录已变化，请确认后继续")
    }
}
