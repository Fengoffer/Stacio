import AppKit
import XCTest
@testable import StacioApp

@MainActor
final class LicenseCertificateLifecycleTests: XCTestCase {
    func testReturnAndCloseAreBlockedUntilLicenseCommitCompletes() async throws {
        try await assertCommitLifecycle(failStateWrite: false)
    }

    func testFailedCommitRestoresControlsAndRollsBackActivation() async throws {
        try await assertCommitLifecycle(failStateWrite: true)
    }

    func testReturnDuringValidationDiscardsLateResponseAndPreservesNewRun() async throws {
        _ = NSApplication.shared
        let fixture = makeFixture(gatedValidation: true)
        let controller = fixture.controller
        defer { controller.close() }
        let root = try XCTUnwrap(controller.window?.contentView)
        let reimport: NSButton = try control(root, "reimport")
        let cancel: NSButton = try control(root, "cancelReimport")
        let validate: NSButton = try control(root, "validateOnline")
        let key: NSSecureTextField = try control(root, "licenseKey")
        reimport.performClick(nil)
        key.stringValue = "first-test-key"
        validate.performClick(nil)
        try await waitUntil { await fixture.validator.requestCount == 1 }
        XCTAssertTrue(cancel.isEnabled)
        cancel.performClick(nil)
        let form: NSStackView = try control(root, "activationForm")
        XCTAssertTrue(form.isHidden)

        reimport.performClick(nil)
        key.stringValue = "second-test-key"
        validate.performClick(nil)
        try await waitUntil { await fixture.validator.requestCount == 2 }
        await fixture.validator.release("first-test-key")
        try await waitUntil { await fixture.validator.completedCount == 1 }
        // Give the canceled controller task time to consume its late response.
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertFalse(validate.isEnabled)
        XCTAssertFalse(form.isHidden)
        XCTAssertEqual(fixture.activationStore.saves, 0)
        XCTAssertEqual(fixture.stateStore.saves, 0)

        cancel.performClick(nil)
        await fixture.validator.release("second-test-key")
        try await waitUntil { await fixture.validator.completedCount == 2 }
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(form.isHidden)
        XCTAssertEqual(fixture.activationStore.saves, 0)
        XCTAssertEqual(fixture.stateStore.saves, 0)
    }

    private func assertCommitLifecycle(failStateWrite: Bool) async throws {
        _ = NSApplication.shared
        let fixture = makeFixture(failStateWrite: failStateWrite)
        let controller = fixture.controller
        defer {
            fixture.activationStore.release.signal()
            controller.close()
        }
        let window = try XCTUnwrap(controller.window)
        let root = try XCTUnwrap(window.contentView)
        try await waitUntil { fixture.activationStore.hasLoaded }
        let reimport: NSButton = try control(root, "reimport")
        let cancel: NSButton = try control(root, "cancelReimport")
        let validate: NSButton = try control(root, "validateOnline")
        let key: NSSecureTextField = try control(root, "licenseKey")
        let form: NSStackView = try control(root, "activationForm")
        let actionStatus: NSTextField = try control(root, "actionStatus")
        reimport.performClick(nil)
        key.stringValue = "commit-test-key"
        fixture.activationStore.arm()
        validate.performClick(nil)
        try await waitUntil { fixture.activationStore.isWaiting }

        let actionIDs = ["cancelReimport", "reimport", "importOfflineLicenseFile", "validateOnline", "refresh"]
        for id in actionIDs {
            let button: NSButton = try control(root, id)
            XCTAssertFalse(button.isEnabled, id)
        }
        XCTAssertEqual(window.standardWindowButton(.closeButton)?.isEnabled, false)
        XCTAssertFalse(controller.windowShouldClose(window))
        XCTAssertTrue(actionStatus.stringValue.contains("正在保存"))
        cancel.performClick(nil)
        reimport.performClick(nil)
        XCTAssertFalse(form.isHidden)
        XCTAssertEqual(fixture.activationStore.saves, 0)
        XCTAssertEqual(fixture.stateStore.saves, 0)

        fixture.activationStore.release.signal()
        try await waitUntil { cancel.isEnabled && fixture.stateStore.attempts == 1 }
        for id in actionIDs {
            let button: NSButton = try control(root, id)
            XCTAssertTrue(button.isEnabled, id)
        }
        XCTAssertEqual(window.standardWindowButton(.closeButton)?.isEnabled, true)
        XCTAssertTrue(controller.windowShouldClose(window))
        XCTAssertFalse(fixture.activationStore.wroteWhileCancelled)
        if failStateWrite {
            XCTAssertNil(fixture.activationStore.record)
            XCTAssertEqual(fixture.stateStore.saves, 0)
            XCTAssertFalse(form.isHidden)
            XCTAssertTrue(actionStatus.stringValue.contains(L10n.ProductOps.licenseOnlineFailedPrefix))
            cancel.performClick(nil)
            XCTAssertTrue(form.isHidden)
        } else {
            XCTAssertEqual(fixture.activationStore.saves, 1)
            XCTAssertEqual(fixture.stateStore.saves, 1)
            XCTAssertEqual(fixture.activationStore.record?.licenseKey, "commit-test-key")
            XCTAssertTrue(form.isHidden)
            XCTAssertTrue(actionStatus.stringValue.contains(L10n.ProductOps.licenseOnlineValidated))
        }
    }

    private func makeFixture(failStateWrite: Bool = false, gatedValidation: Bool = false) -> (
        controller: LicenseWindowController,
        activationStore: CertificateCommitActivationStore,
        stateStore: CertificateCommitStateStore,
        validator: CertificateLifecycleValidator
    ) {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let claims = SignedLicenseClaims(licenseID: "test-license", productID: "stacio", email: "test@example.com", username: "Test", plan: "professional", entitlements: [], expiresAt: now.addingTimeInterval(86_400), offlineGraceSeconds: 3_600, issuedAt: now)
        let stateStore = CertificateCommitStateStore(failWrites: failStateWrite)
        let activationStore = CertificateCommitActivationStore()
        let validator = CertificateLifecycleValidator(claims: claims, gated: gatedValidation)
        let oldState = LicenseState(username: claims.username, email: claims.email, plan: claims.plan, expiresAt: claims.expiresAt, status: .active)
        let controller = LicenseWindowController(
            service: LicenseService(store: stateStore, signedTokenVerifier: CertificateLifecycleVerifier(claims: claims)),
            onlineValidator: validator, activationStore: activationStore,
            persistedStateProvider: { oldState }, nowProvider: { now }
        )
        return (controller, activationStore, stateStore, validator)
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<300 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("License operation did not reach the expected phase")
        throw CertificateLifecycleError.timedOut
    }

    private func control<T: NSView>(_ view: NSView, _ id: String) throws -> T {
        func find(_ view: NSView) -> NSView? {
            if view.accessibilityIdentifier() == "Stacio.License." + id { return view }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        return try XCTUnwrap(find(view) as? T, id)
    }
}

private enum CertificateLifecycleError: Error { case writeFailed, timedOut }

private struct CertificateLifecycleVerifier: SignedLicenseTokenVerifying {
    let claims: SignedLicenseClaims
    func verifiedClaims(from token: String) throws -> SignedLicenseClaims { claims }
}

private actor CertificateLifecycleValidator: LicenseOnlineValidating {
    let claims: SignedLicenseClaims
    let gated: Bool
    private var pending: [String: CheckedContinuation<Void, Never>] = [:]
    private(set) var requestCount = 0
    private(set) var completedCount = 0
    init(claims: SignedLicenseClaims, gated: Bool) { self.claims = claims; self.gated = gated }
    func validate(_ request: LicenseValidationRequest) async throws -> LicenseValidationResponse {
        requestCount += 1
        if gated {
            // Deliberately ignore cancellation, like a late network callback.
            await withCheckedContinuation { pending[request.licenseKey] = $0 }
        }
        completedCount += 1
        return LicenseValidationResponse(username: claims.username, email: claims.email, signedLicenseToken: "test-token", plan: claims.plan, expiresAt: claims.expiresAt, offlineGraceSeconds: claims.offlineGraceSeconds, status: .active)
    }
    func release(_ key: String) { pending.removeValue(forKey: key)?.resume() }
}

private final class CertificateCommitActivationStore: LicenseActivationRecordStoring, @unchecked Sendable {
    private let lock = NSLock()
    let release = DispatchSemaphore(value: 0)
    private var armed = false
    private var loaded = false
    private var waiting = false
    private var saved = 0
    private var canceledWrite = false
    private var value: LicenseActivationRecord?
    var hasLoaded: Bool { lock.withLock { loaded } }
    var isWaiting: Bool { lock.withLock { waiting } }
    var saves: Int { lock.withLock { saved } }
    var wroteWhileCancelled: Bool { lock.withLock { canceledWrite } }
    var record: LicenseActivationRecord? { lock.withLock { value } }
    func arm() { lock.withLock { armed = true } }
    func loadActivationRecord() throws -> LicenseActivationRecord? {
        let shouldWait = lock.withLock { () -> Bool in
            loaded = true
            guard armed else { return false }
            armed = false
            waiting = true
            return true
        }
        if shouldWait, release.wait(timeout: .now() + 5) == .timedOut {
            throw CertificateLifecycleError.timedOut
        }
        return record
    }
    func saveActivationRecord(_ record: LicenseActivationRecord) throws {
        lock.withLock { value = record; saved += 1; canceledWrite = Task.isCancelled }
    }
    func deleteActivationRecord() throws { lock.withLock { value = nil } }
}

private final class CertificateCommitStateStore: LicenseStateStoring, @unchecked Sendable {
    private let lock = NSLock()
    private let failWrites: Bool
    private var value: LicenseState?
    private var saved = 0
    private var attempted = 0
    init(failWrites: Bool) { self.failWrites = failWrites }
    var saves: Int { lock.withLock { saved } }
    var attempts: Int { lock.withLock { attempted } }
    func load() throws -> LicenseState? { lock.withLock { value } }
    func save(_ state: LicenseState) throws {
        try lock.withLock {
            attempted += 1
            if failWrites { throw CertificateLifecycleError.writeFailed }
            value = state
            saved += 1
        }
    }
}
