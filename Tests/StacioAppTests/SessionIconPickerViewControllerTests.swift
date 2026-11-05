import AppKit
import XCTest
@testable import StacioApp

@MainActor
final class SessionIconPickerViewControllerTests: XCTestCase {
    func testPickerShowsSearchAndThreeSections() {
        let controller = SessionIconPickerViewController(selectedIconID: "ubuntu")
        controller.loadView()

        XCTAssertNotNil(findSubview(in: controller.view, identifier: "Stacio.SessionIconPicker.search"))
        XCTAssertEqual(controller.sectionTitlesForTesting, ["默认", "操作系统", "云平台"])
        XCTAssertEqual(controller.selectedIconIDForTesting, "ubuntu")
    }

    func testCancelDoesNotEmitSelection() {
        let controller = SessionIconPickerViewController(selectedIconID: "ubuntu")
        var didConfirm = false
        var didCancel = false
        controller.onConfirm = { _ in didConfirm = true }
        controller.onCancel = { didCancel = true }

        controller.cancelForTesting()

        XCTAssertFalse(didConfirm)
        XCTAssertTrue(didCancel)
    }

    func testSelectingDefaultEmitsNil() {
        let controller = SessionIconPickerViewController(selectedIconID: "ubuntu")
        var emittedIconID: String? = "sentinel"
        var didConfirm = false
        controller.onConfirm = {
            emittedIconID = $0
            didConfirm = true
        }

        controller.selectForTesting(iconID: nil)
        controller.confirmForTesting()

        XCTAssertTrue(didConfirm)
        XCTAssertNil(emittedIconID)
    }

    func testSearchFiltersByChineseNameAndEnglishAlias() {
        let controller = SessionIconPickerViewController(selectedIconID: nil)
        controller.loadView()

        controller.setSearchQueryForTesting("腾讯")
        XCTAssertEqual(controller.visibleIconIDsForTesting, ["tencent-cloud"])

        controller.setSearchQueryForTesting("ubuntu")
        XCTAssertEqual(controller.visibleIconIDsForTesting, ["ubuntu", "ubuntu-alt"])
    }

    func testPickerUsesFixedCollectionItemSizeAndAccessibleControls() {
        let controller = SessionIconPickerViewController(selectedIconID: nil)
        controller.loadView()

        XCTAssertEqual(controller.itemSizeForTesting, NSSize(width: 76, height: 72))
        XCTAssertNotNil(findSubview(in: controller.view, identifier: "Stacio.SessionIconPicker.collection"))
        XCTAssertNotNil(findSubview(in: controller.view, identifier: "Stacio.SessionIconPicker.confirm"))
        XCTAssertNotNil(findSubview(in: controller.view, identifier: "Stacio.SessionIconPicker.cancel"))
    }

    private func findSubview(in view: NSView, identifier: String) -> NSView? {
        if view.accessibilityIdentifier() == identifier {
            return view
        }
        for subview in view.subviews {
            if let match = findSubview(in: subview, identifier: identifier) {
                return match
            }
        }
        return nil
    }
}
