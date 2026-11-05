import XCTest
@testable import StacioApp

@MainActor
final class LicenseSessionSettingsTests: XCTestCase {
    func testProxyJumpControlsAreDisabledWithoutLicense() {
        let controller = makeController(enabled: false)

        controller.loadView()

        XCTAssertFalse(controller.isProxyJumpLicensedForTesting)
    }

    func testProxyJumpControlsRefreshAfterLicenseImport() {
        let access = MutableSessionSettingsLicenseAccess(enabled: false)
        let controller = SessionSettingsViewController(
            existingSession: nil,
            selectedFolderID: nil,
            draftFactory: SessionSidebarSessionDraftFactory(defaultUsername: { "local" }),
            licenseAccess: access
        )
        controller.loadView()
        XCTAssertFalse(controller.isProxyJumpLicensedForTesting)

        access.enabled = true
        NotificationCenter.default.post(name: .stacioLicenseAuthorizationDidChange, object: nil)

        XCTAssertTrue(controller.isProxyJumpLicensedForTesting)
    }

    private func makeController(enabled: Bool) -> SessionSettingsViewController {
        SessionSettingsViewController(
            existingSession: nil,
            selectedFolderID: nil,
            draftFactory: SessionSidebarSessionDraftFactory(defaultUsername: { "local" }),
            licenseAccess: MutableSessionSettingsLicenseAccess(enabled: enabled)
        )
    }
}

private final class MutableSessionSettingsLicenseAccess: LicenseFeatureAccessProviding {
    var enabled: Bool

    init(enabled: Bool) {
        self.enabled = enabled
    }

    func isEnabled(_ feature: StacioLicensedFeature) -> Bool {
        enabled
    }
}
