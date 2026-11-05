import AppKit
import XCTest
@testable import StacioApp

final class LicenseCertificatePresentationTests: XCTestCase {
    func testPermanentExpiryUsesBackendSentinelAndMissingDateIsNotPermanent() throws {
        let parser = ISO8601DateFormatter()
        XCTAssertEqual(LicenseCertificateContent.validityText(parser.date(from: "9999-12-31T23:59:59Z")), "永久授权")
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertEqual(LicenseCertificateContent.validityText(parser.date(from: "9999-12-31T23:59:59.999Z")), "永久授权")
        XCTAssertEqual(LicenseCertificateContent.validityText(nil), "—")
        XCTAssertNotEqual(LicenseCertificateContent.validityText(Date(timeIntervalSince1970: 2_000_000_000)), "永久授权")
        XCTAssertEqual(LicenseCertificateContent.validityDetail(nil), "—")
        XCTAssertEqual(LicenseCertificateContent.validityDetail(parser.date(from: "9999-12-31T23:59:59.999Z")), "永久授权")
    }

    func testFiniteExpiryPreservesTimeAndUnambiguousTimezoneAcrossDateBoundary() throws {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = try XCTUnwrap(parser.date(from: "2026-09-26T04:30:45.123Z"))
        let shanghai = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let losAngeles = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        XCTAssertEqual(LicenseCertificateContent.validityText(date, timeZone: shanghai), "2026-09-26 12:30")
        XCTAssertEqual(LicenseCertificateContent.validityDetail(date, timeZone: shanghai), "2026-09-26 12:30:45.123 GMT+08:00")
        XCTAssertEqual(LicenseCertificateContent.validityText(date, timeZone: losAngeles), "2026-09-25 21:30")
        XCTAssertEqual(LicenseCertificateContent.validityDetail(date, timeZone: losAngeles), "2026-09-25 21:30:45.123 GMT-07:00")
    }

    func testServiceImportedSignedTokenIsDisplayedAsOfflineWithoutClaimingDeviceBinding() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let claims = SignedLicenseClaims(licenseID: "", productID: "stacio", email: "review@example.com", username: "Review", plan: "professional", entitlements: [], expiresAt: now.addingTimeInterval(86_400), offlineGraceSeconds: 3_600, issuedAt: now)
        let verifier = CertificateClaimsVerifier(claims: claims)
        let service = LicenseService(store: CertificateStateStore(), signedTokenVerifier: verifier)
        let state = try service.state(applyingOfflineSignedToken: "test-token", expectedUsername: claims.username, expectedEmail: claims.email, now: now)
        XCTAssertEqual(state.status, .offlineActive)
        XCTAssertNil(state.offlineToken)
        XCTAssertNil(state.offlineDeviceAuthorization)
        let offline = LicenseCertificateContent.make(state: state, verifier: verifier)
        XCTAssertEqual(offline.metadataValue, "离线授权")
        XCTAssertTrue(offline.verification.contains("离线授权"))
        XCTAssertFalse(offline.verification.contains("在线激活"))

        let onlineState = try service.state(applyingOnlineValidation: LicenseValidationResponse(
            username: claims.username, email: claims.email, signedLicenseToken: "test-token",
            plan: claims.plan, expiresAt: claims.expiresAt,
            offlineGraceSeconds: claims.offlineGraceSeconds, status: .active
        ), now: now)
        XCTAssertEqual(onlineState.activationSource, .online)
        let online = LicenseCertificateContent.make(state: onlineState, verifier: verifier)
        XCTAssertEqual(online.metadataValue, "在线激活")
        XCTAssertTrue(online.verification.contains("在线激活"))
    }

    func testSignedOfflineSourceSurvivesExpiryAndStorageRoundTrip() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let claims = SignedLicenseClaims(licenseID: "", productID: "stacio", email: "review@example.com", username: "Review", plan: "professional", entitlements: [], expiresAt: now.addingTimeInterval(86_400), offlineGraceSeconds: 3_600, issuedAt: now)
        let verifier = CertificateClaimsVerifier(claims: claims)
        let service = LicenseService(store: CertificateStateStore(), signedTokenVerifier: verifier)
        let imported = try service.state(applyingOfflineSignedToken: "test-token", expectedUsername: claims.username, expectedEmail: claims.email, now: now)
        let expired = service.evaluate(state: imported, now: now.addingTimeInterval(3_601))
        XCTAssertEqual(expired.status, .expired)
        let restored = try JSONDecoder().decode(LicenseState.self, from: JSONEncoder().encode(expired))
        XCTAssertEqual(restored.activationSource, .offline)
        XCTAssertEqual(LicenseCertificateContent.make(state: restored, verifier: verifier).metadataValue, "离线授权")

        // Old persisted licenses have no source field. Preserve known offline
        // provenance before their active status transitions to expired.
        var legacyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(imported)) as? [String: Any])
        legacyJSON.removeValue(forKey: "activationSource")
        let legacy = try JSONDecoder().decode(LicenseState.self, from: JSONSerialization.data(withJSONObject: legacyJSON))
        XCTAssertNil(legacy.activationSource)
        let migrated = service.evaluate(state: legacy, now: now.addingTimeInterval(3_601))
        XCTAssertEqual(migrated.status, .expired)
        XCTAssertEqual(migrated.activationSource, .offline)
        XCTAssertEqual(LicenseCertificateContent.make(state: migrated, verifier: verifier).metadataValue, "离线授权")
    }

    func testLegacyTerminalStatesDoNotInventOnlineActivation() {
        for status in [LicenseStatus.expired, .revoked, .suspended, .invalid] {
            var state = LicenseState(signedLicenseToken: "historical-token", status: status)
            XCTAssertEqual(LicenseCertificateContent.make(state: state, verifier: CertificateRejectingVerifier()).metadataValue, "签名许可")
            state.activationSource = .offline
            XCTAssertEqual(LicenseCertificateContent.make(state: state, verifier: CertificateRejectingVerifier()).metadataValue, "离线授权")
            state.activationSource = .online
            XCTAssertEqual(LicenseCertificateContent.make(state: state, verifier: CertificateRejectingVerifier()).metadataValue, "在线激活")
        }
    }

    func testUnavailableStatesNeverClaimTheUserHasAValidProfessionalLicense() {
        for status in [LicenseStatus.inactive, .expired, .suspended, .revoked, .invalid, .networkUnavailable] {
            let content = LicenseCertificateContent.make(state: LicenseState(plan: "professional", status: status), verifier: CertificateRejectingVerifier())
            XCTAssertFalse(content.statement.contains("已获得"), "\(status)")
            XCTAssertFalse(content.verification.contains("许可已在本机验证"), "\(status)")
            XCTAssertFalse(content.tone == .valid, "\(status)")
        }
        let inactive = LicenseCertificateContent.make(state: LicenseState(), verifier: CertificateRejectingVerifier())
        XCTAssertEqual(inactive.title, "激活软件许可证")
    }

    func testEnterpriseAndTrialCopyDescribesTheActualEntitlement() {
        let enterprise = LicenseCertificateContent.make(state: LicenseState(plan: "enterprise", status: .active), verifier: CertificateRejectingVerifier())
        XCTAssertTrue(enterprise.statement.contains("企业版"))
        XCTAssertFalse(enterprise.statement.contains("专业版"))
        let trial = LicenseCertificateContent.make(state: LicenseState(plan: "professional", status: .trial), verifier: CertificateRejectingVerifier())
        XCTAssertEqual(trial.title, "软件试用许可")
        XCTAssertFalse(trial.statement.contains("已获得"))
        XCTAssertTrue(trial.tone == .trial)
    }

    func testOnlyVerifiedMatchingClaimsSupplyCertificateIdentity() {
        let expiration = Date(timeIntervalSince1970: 2_000_000_000)
        let state = LicenseState(username: "Demo", email: "demo@example.com", signedLicenseToken: "untrusted.payload", plan: "professional", expiresAt: expiration, status: .active)
        let rejected = LicenseCertificateContent.make(state: state, verifier: CertificateRejectingVerifier())
        XCTAssertEqual(rejected.metadataTitle, "授权方式")
        XCTAssertEqual(rejected.issueTitle, "签发方")
        var claims = SignedLicenseClaims(licenseID: "verified-license-id", productID: "stacio", email: state.email, username: state.username, plan: state.plan, entitlements: [], expiresAt: expiration, offlineGraceSeconds: 0, issuedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let matching = LicenseCertificateContent.make(state: state, verifier: CertificateClaimsVerifier(claims: claims))
        XCTAssertEqual(matching.metadataValue, "verified-license-id")
        XCTAssertEqual(matching.issueTitle, "本次签发")
        claims.email = "someone-else@example.com"
        let mismatch = LicenseCertificateContent.make(state: state, verifier: CertificateClaimsVerifier(claims: claims))
        XCTAssertEqual(mismatch.metadataTitle, "授权方式")
        XCTAssertEqual(mismatch.issueTitle, "签发方")
    }

    func testOfflineCertificateHasNoInventedLicenseNumberAndGraceRemainsVisible() {
        let offline = OfflineDeviceAuthorization(productID: "stacio", deviceID: "test-device", username: "Demo", email: "demo@example.com", plan: "professional", issuedAt: "2026-09-01T00:00:00.000Z", expiresAt: "2027-09-01T00:00:00.000Z", signatureKeyID: "test", status: .active, signature: "test-only")
        let content = LicenseCertificateContent.make(state: LicenseState(plan: "professional", status: .offlineActive, offlineDeviceAuthorization: offline), verifier: CertificateRejectingVerifier())
        XCTAssertEqual(content.metadataTitle, "授权方式")
        XCTAssertTrue(content.metadataValue.contains("离线文件"))
        XCTAssertEqual(content.issueTitle, "本次签发")
        let grace = LicenseCertificateContent.make(state: LicenseState(plan: "professional", graceUntil: Date(timeIntervalSince1970: 2_000_000_000), status: .offlineGrace), verifier: CertificateRejectingVerifier())
        XCTAssertTrue(grace.note.contains("宽限截止"))
        XCTAssertFalse(grace.tone == .valid)
    }
}

@MainActor
final class LicenseCertificateWindowTests: XCTestCase {
    func testFiniteExpiryTooltipAndAccessibilityRetainExactDeadline() throws {
        _ = NSApplication.shared
        let expiration = Date(timeIntervalSince1970: 1_800_000_045.123)
        let content = LicenseCertificateContent.make(state: LicenseState(plan: "professional", expiresAt: expiration, status: .trial), verifier: CertificateRejectingVerifier())
        let view = LicenseCertificateView()
        view.render(content)
        XCTAssertEqual(view.validityLabel.stringValue, LicenseCertificateContent.validityText(expiration))
        XCTAssertEqual(view.validityLabel.toolTip, LicenseCertificateContent.validityDetail(expiration))
        XCTAssertEqual(view.validityLabel.accessibilityHelp(), view.validityLabel.toolTip)
        XCTAssertTrue(try XCTUnwrap(view.validityLabel.toolTip).contains(":45.123 GMT"))
    }

    func testReimportCanReturnToExistingLicenseWithoutWritingActivation() throws {
        _ = NSApplication.shared
        let store = CertificateActivationStore()
        let state = Self.exampleState()
        let controller = LicenseWindowController(activationStore: store, persistedStateProvider: { state })
        defer { controller.close() }
        let root = try XCTUnwrap(controller.window?.contentView)
        let reimport = try XCTUnwrap(find(root, "Stacio.License.reimport") as? NSButton)
        reimport.performClick(nil)
        XCTAssertFalse(try XCTUnwrap(find(root, "Stacio.License.activationForm")).isHidden)
        let cancel = try XCTUnwrap(find(root, "Stacio.License.cancelReimport") as? NSButton)
        XCTAssertFalse(cancel.isHidden)
        cancel.performClick(nil)
        XCTAssertTrue(try XCTUnwrap(find(root, "Stacio.License.activationForm")).isHidden)
        XCTAssertFalse(try XCTUnwrap(find(root, "Stacio.License.management")).isHidden)
        XCTAssertEqual(store.writes, 0)
        XCTAssertEqual(controller.window?.title, "许可证")
    }

    func testCertificateAndActionsRemainInsideWindowForLongIdentityAtMinimumWidth() throws {
        _ = NSApplication.shared
        var state = Self.exampleState()
        state.username = String(repeating: "长姓名", count: 12)
        state.email = "very.long.enterprise.administrator.address@department.example.com"
        let controller = LicenseWindowController(activationStore: CertificateActivationStore(), persistedStateProvider: { state })
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 820, height: 600))
        window.appearance = NSAppearance(named: .darkAqua)
        let root = try XCTUnwrap(window.contentView)
        root.layoutSubtreeIfNeeded()
        let certificate = try XCTUnwrap(find(root, "Stacio.License.statusCard") as? LicenseCertificateView)
        certificate.layoutSubtreeIfNeeded()
        XCTAssertTrue(root.bounds.contains(certificate.convert(certificate.bounds, to: root)))
        for label in [certificate.userLabel, certificate.emailLabel, certificate.validityLabel, certificate.planLabel] {
            XCTAssertTrue(certificate.bounds.contains(label.frame))
            XCTAssertTrue(label.isSelectable)
            XCTAssertEqual(label.toolTip, label.stringValue)
        }
        for id in ["Stacio.License.refresh", "Stacio.License.reimport"] {
            let button = try XCTUnwrap(find(root, id))
            XCTAssertTrue(root.bounds.contains(button.convert(button.bounds, to: root)))
        }
        XCTAssertEqual(certificate.appearance?.name, .aqua)
    }

    /// Optional render artifacts exercise the actual production controller, with
    /// in-memory example states. They never load or alter a user's real license.
    func testProductionWindowRendersEachAuthorizationState() throws {
        _ = NSApplication.shared
        for (name, status) in [("active", LicenseStatus.active), ("inactive", .inactive), ("expired", .expired), ("trial", .trial), ("grace", .offlineGrace)] {
            var state = Self.exampleState()
            state.status = status
            if status == .inactive { state = LicenseState() }
            if status == .expired { state.expiresAt = Date(timeIntervalSince1970: 1_700_000_000) }
            let controller = LicenseWindowController(activationStore: CertificateActivationStore(), persistedStateProvider: { state })
            let window = try XCTUnwrap(controller.window)
            let root = try XCTUnwrap(window.contentView)
            root.layoutSubtreeIfNeeded()
            let title = try XCTUnwrap(find(root, "Stacio.License.certificateTitle") as? NSTextField)
            XCTAssertFalse(title.stringValue.isEmpty)
            if let directory = ProcessInfo.processInfo.environment["STACIO_LICENSE_PREVIEW_DIR"] {
                let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(root.bounds.width * 2), pixelsHigh: Int(root.bounds.height * 2), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
                bitmap.size = root.bounds.size
                root.cacheDisplay(in: root.bounds, to: bitmap)
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("license-window-\(name).png"))
            }
            controller.close()
        }
    }

    private static func exampleState() -> LicenseState {
        LicenseState(username: "FengLee", email: "Fengoffer@163.com", plan: "professional", expiresAt: ISO8601DateFormatter().date(from: "9999-12-31T23:59:59Z"), status: .active)
    }

    private func find(_ view: NSView, _ identifier: String) -> NSView? {
        if view.accessibilityIdentifier() == identifier { return view }
        return view.subviews.lazy.compactMap { self.find($0, identifier) }.first
    }
}

private struct CertificateRejectingVerifier: SignedLicenseTokenVerifying {
    func verifiedClaims(from token: String) throws -> SignedLicenseClaims { throw ProductOpsError.invalidSignedLicenseToken }
}

private struct CertificateClaimsVerifier: SignedLicenseTokenVerifying {
    let claims: SignedLicenseClaims
    func verifiedClaims(from token: String) throws -> SignedLicenseClaims { claims }
}

private final class CertificateActivationStore: LicenseActivationRecordStoring {
    var writes = 0
    func loadActivationRecord() throws -> LicenseActivationRecord? { nil }
    func saveActivationRecord(_ record: LicenseActivationRecord) throws { writes += 1 }
    func deleteActivationRecord() throws { writes += 1 }
}

private final class CertificateStateStore: LicenseStateStoring {
    private var value: LicenseState?
    func load() throws -> LicenseState? { value }
    func save(_ state: LicenseState) throws { value = state }
}
