import Foundation
import XCTest
@testable import StacioApp

final class ProductOpsCompletionTests: XCTestCase {
    func testFeedbackValidationRejectsBackendLengthLimitViolations() {
        let report = FeedbackReport(
            title: String(repeating: "T", count: FeedbackReport.maximumTitleLength + 1),
            type: .bug,
            description: String(repeating: "D", count: FeedbackReport.maximumDescriptionLength + 1),
            contact: "user@example.com"
        )

        XCTAssertEqual(report.validationErrors, [.titleTooLong, .descriptionTooLong])
        XCTAssertTrue(FeedbackReportValidationError.titleTooLong.displayName.contains("240"))
        XCTAssertTrue(FeedbackReportValidationError.descriptionTooLong.displayName.contains("50000"))
    }

    func testDiagnosticSanitizerRejectsSecretShapedValuesEvenForAllowedKeys() {
        let diagnostics = ProductOpsDiagnosticSanitizer.sanitized([
            "productID": "stacio",
            "configuredUpdateChannel": "stable",
            "betaUpdatesEnabled": "false",
            "unknownMetric": "2",
            "configuredUpdateChannelJWT": "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.signature",
            "productIDToken": "ghp_1234567890abcdefghijklmnopqrstuvwxyz"
        ])

        XCTAssertEqual(diagnostics["productID"], "stacio")
        XCTAssertEqual(diagnostics["configuredUpdateChannel"], "stable")
        XCTAssertEqual(diagnostics["betaUpdatesEnabled"], "false")
        XCTAssertNil(diagnostics["unknownMetric"])
        XCTAssertNil(diagnostics["configuredUpdateChannelJWT"])
        XCTAssertNil(diagnostics["productIDToken"])
    }

    func testStoredOnlineLicenseRemainsActiveOrTrialWhenLicenseAndOfflineGraceAreValid() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for status in [LicenseStatus.active, .trial] {
            let state = makeOnlineState(
                now: now,
                expiresAt: now.addingTimeInterval(30 * 24 * 60 * 60),
                graceUntil: now.addingTimeInterval(60),
                status: status
            )
            let service = makeLicenseService(state: state)

            XCTAssertEqual(service.loadState(now: now).status, status)
        }
    }

    func testStoredOnlineLicenseExpiresWhenLicenseExpiresEvenIfOfflineGraceRemains() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let state = makeOnlineState(
            now: now,
            expiresAt: now.addingTimeInterval(-1),
            graceUntil: now.addingTimeInterval(60)
        )
        let service = makeLicenseService(state: state)

        XCTAssertEqual(service.evaluate(state: state, now: now).status, .expired)
    }

    func testStoredOfflineActiveLicenseExpiresWhenOfflineGraceEndsBeforeLicenseExpiry() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let state = makeOnlineState(
            now: now,
            expiresAt: now.addingTimeInterval(30 * 24 * 60 * 60),
            graceUntil: now.addingTimeInterval(-1),
            status: .offlineActive
        )
        let service = makeLicenseService(state: state)

        XCTAssertEqual(service.evaluate(state: state, now: now).status, .expired)
    }

    func testTerminalStoredLicenseIsNotReactivatedByOlderOfflineToken() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let token = OfflineLicenseToken(
            productID: "stacio",
            username: "Ada",
            email: "ada@example.com",
            plan: "pro",
            permissions: ["remote_sessions"],
            issuedAt: now.addingTimeInterval(-60),
            expiresAt: now.addingTimeInterval(86_400),
            signatureKeyID: "primary",
            signature: "valid"
        )
        let service = LicenseService(
            store: CompletionLicenseStateStore(state: nil),
            verifier: CompletionValidOfflineVerifier(),
            signedTokenVerifier: CompletionSignedVerifier(claims: nil)
        )

        for terminalStatus in [LicenseStatus.revoked, .suspended] {
            let state = LicenseState(
                username: token.username,
                email: token.email,
                signedLicenseToken: token.signedLicenseToken,
                plan: token.plan,
                permissions: token.permissions,
                expiresAt: token.expiresAt,
                status: terminalStatus,
                lastValidatedAt: now,
                offlineToken: token
            )

            XCTAssertEqual(service.evaluate(state: state, now: now).status, terminalStatus)
        }
    }

    func testOfflineSignedLicenseImportRejectsExpiredGraceWithoutSaving() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let claims = SignedLicenseClaims(
            licenseID: "license-1",
            productID: "stacio",
            email: "ada@example.com",
            username: "Ada",
            plan: "pro",
            entitlements: ["remote_sessions"],
            expiresAt: now.addingTimeInterval(24 * 60 * 60),
            offlineGraceSeconds: 60,
            issuedAt: now.addingTimeInterval(-120)
        )
        let store = CompletionLicenseStateStore(state: nil)
        let service = LicenseService(
            store: store,
            verifier: CompletionOfflineVerifier(),
            signedTokenVerifier: CompletionSignedVerifier(claims: claims)
        )

        XCTAssertThrowsError(
            try service.state(
                applyingOfflineSignedToken: "v1.payload.signature",
                expectedUsername: claims.username,
                expectedEmail: claims.email,
                now: now
            )
        ) { error in
            XCTAssertEqual(error as? ProductOpsError, .invalidOfflineLicenseToken)
        }
        XCTAssertNil(store.state)
    }

    func testInactiveStoredLicenseWithSignedTokenStillRequiresValidSignatureBeforeActivation() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let state = LicenseState(
            username: "Ada",
            email: "ada@example.com",
            signedLicenseToken: "invalid-token",
            plan: "pro",
            permissions: ["remote_sessions"],
            expiresAt: now.addingTimeInterval(30 * 24 * 60 * 60),
            status: .inactive,
            lastValidatedAt: now,
            offlineToken: nil
        )
        let service = LicenseService(
            store: CompletionLicenseStateStore(state: state),
            verifier: CompletionOfflineVerifier(),
            signedTokenVerifier: CompletionSignedVerifier(claims: nil)
        )

        XCTAssertEqual(service.evaluate(state: state, now: now).status, .invalid)
    }

    func testInactiveStoredLicenseWithoutSignedTokenNeverUpgradesToActive() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let state = LicenseState(
            username: "Ada",
            email: "ada@example.com",
            expiresAt: now.addingTimeInterval(30 * 24 * 60 * 60),
            status: .inactive,
            lastValidatedAt: now
        )
        let service = LicenseService(
            store: CompletionLicenseStateStore(state: state),
            verifier: CompletionOfflineVerifier(),
            signedTokenVerifier: CompletionSignedVerifier(claims: nil)
        )

        XCTAssertEqual(service.evaluate(state: state, now: now).status, .inactive)
    }

    func testActiveStoredLicenseWithoutSignedTokenIsInvalid() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let state = LicenseState(
            username: "Ada",
            email: "ada@example.com",
            plan: "pro",
            permissions: ["remote_sessions"],
            expiresAt: now.addingTimeInterval(30 * 24 * 60 * 60),
            status: .active,
            lastValidatedAt: now
        )
        let service = LicenseService(
            store: CompletionLicenseStateStore(state: state),
            verifier: CompletionOfflineVerifier(),
            signedTokenVerifier: CompletionSignedVerifier(claims: nil)
        )

        XCTAssertEqual(service.evaluate(state: state, now: now).status, .invalid)
    }

    func testInvalidManualActivationDoesNotOverwriteExistingValidLicense() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let existing = makeOnlineState(
            now: now,
            expiresAt: now.addingTimeInterval(30 * 24 * 60 * 60),
            graceUntil: now.addingTimeInterval(24 * 60 * 60)
        )
        let store = CompletionLicenseStateStore(state: existing)
        let service = makeLicenseService(store: store, state: existing)
        let request = makeLicenseRequest()
        let response = LicenseValidationResponse(
            username: request.username,
            email: request.email,
            plan: "",
            expiresAt: nil,
            status: .invalid
        )

        let result = try service.state(
            applyingOnlineValidation: response,
            expected: request,
            now: now
        )

        XCTAssertEqual(result.status, .invalid)
        XCTAssertEqual(store.state, existing)
    }

    func testManualValidationPersistsTerminalStateForCurrentlyStoredLicenseKey() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let existing = makeOnlineState(
            now: now,
            expiresAt: now.addingTimeInterval(30 * 24 * 60 * 60),
            graceUntil: now.addingTimeInterval(24 * 60 * 60)
        )
        let store = LicenseKeychainStore(
            backend: CompletionLicenseKeychainBackend(),
            service: "cn.stacio.tests.license.manual-terminal.\(UUID().uuidString)"
        )
        let request = makeLicenseRequest()
        try store.save(existing)
        try store.saveActivationRecord(LicenseActivationRecord(
            licenseKey: request.licenseKey,
            username: request.username,
            email: request.email
        ))
        let service = makeLicenseService(store: store, state: existing)
        let response = LicenseValidationResponse(
            username: request.username,
            email: request.email,
            plan: existing.plan,
            expiresAt: existing.expiresAt,
            status: .revoked
        )

        let result = try service.state(
            applyingOnlineValidation: response,
            expected: request,
            now: now
        )

        XCTAssertEqual(result.status, .revoked)
        XCTAssertEqual(try store.load()?.status, .revoked)
    }

    func testRevalidationPersistsRevokedStateForStoredCredential() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let existing = makeOnlineState(
            now: now,
            expiresAt: now.addingTimeInterval(30 * 24 * 60 * 60),
            graceUntil: now.addingTimeInterval(24 * 60 * 60)
        )
        let store = CompletionLicenseStateStore(state: existing)
        let service = makeLicenseService(store: store, state: existing)
        let request = makeLicenseRequest()
        let response = LicenseValidationResponse(
            username: request.username,
            email: request.email,
            plan: existing.plan,
            expiresAt: existing.expiresAt,
            status: .revoked
        )

        let result = try service.state(
            applyingRevalidation: response,
            expected: request,
            now: now
        )

        XCTAssertEqual(result.status, .revoked)
        XCTAssertEqual(store.state?.status, .revoked)
    }

    func testNetworkUnavailableUsesGraceForValidSignedState() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let existing = makeOnlineState(
            now: now,
            expiresAt: now.addingTimeInterval(30 * 24 * 60 * 60),
            graceUntil: now.addingTimeInterval(60)
        )
        let store = CompletionLicenseStateStore(state: existing)
        let service = makeLicenseService(store: store, state: existing)

        let result = try service.stateForNetworkUnavailable(now: now)

        XCTAssertEqual(result.status, .offlineGrace)
        XCTAssertEqual(store.state?.status, .offlineGrace)
    }

    func testNetworkUnavailableIsExplicitWhenNoSignedLicenseExists() throws {
        let store = CompletionLicenseStateStore(state: LicenseState())
        let service = LicenseService(
            store: store,
            verifier: CompletionOfflineVerifier(),
            signedTokenVerifier: CompletionSignedVerifier(claims: nil)
        )

        let result = try service.stateForNetworkUnavailable(now: Date())

        XCTAssertEqual(result.status, .networkUnavailable)
        XCTAssertEqual(store.state?.status, .networkUnavailable)
    }

    func testLicenseOnlineValidationClassifiesOfflineTransportFailure() async throws {
        let service = LicenseOnlineValidationService(
            configuration: ProductOpsConfiguration(
                apiBaseURL: try XCTUnwrap(URL(string: "https://ops.example.test"))
            ),
            httpClient: CompletionFailingHTTPClient(error: URLError(.notConnectedToInternet))
        )

        do {
            _ = try await service.validate(makeLicenseRequest())
            XCTFail("Expected offline error")
        } catch {
            XCTAssertEqual(error as? ProductOpsError, .offline)
        }
    }

    func testLicenseOnlineValidationPreservesCancellation() async throws {
        let service = LicenseOnlineValidationService(
            configuration: ProductOpsConfiguration(
                apiBaseURL: try XCTUnwrap(URL(string: "https://ops.example.test"))
            ),
            httpClient: CompletionFailingHTTPClient(error: CancellationError())
        )

        do {
            _ = try await service.validate(makeLicenseRequest())
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    private func makeOnlineState(
        now: Date,
        expiresAt: Date,
        graceUntil: Date,
        status: LicenseStatus = .active
    ) -> LicenseState {
        LicenseState(
            username: "Ada",
            email: "ada@example.com",
            signedLicenseToken: "signed-token",
            plan: "pro",
            permissions: ["remote_sessions"],
            expiresAt: expiresAt,
            graceUntil: graceUntil,
            status: status,
            lastValidatedAt: now,
            offlineToken: nil
        )
    }

    private func makeLicenseRequest() -> LicenseValidationRequest {
        LicenseValidationRequest(
            licenseKey: "STACIO-TEST-KEY",
            username: "Ada",
            email: "ada@example.com",
            appVersion: "1.0",
            buildNumber: "1",
            anonymousDeviceID: "device"
        )
    }

    private func makeLicenseService(state: LicenseState) -> LicenseService {
        makeLicenseService(store: CompletionLicenseStateStore(state: state), state: state)
    }

    private func makeLicenseService(
        store: LicenseStateStoring,
        state: LicenseState
    ) -> LicenseService {
        LicenseService(
            store: store,
            verifier: CompletionOfflineVerifier(),
            signedTokenVerifier: CompletionSignedVerifier(claims: SignedLicenseClaims(
                licenseID: "license-1",
                productID: "stacio",
                email: state.email,
                username: state.username,
                plan: state.plan,
                entitlements: state.permissions,
                expiresAt: state.expiresAt ?? .distantFuture,
                offlineGraceSeconds: max(0, state.graceUntil?.timeIntervalSince(state.lastValidatedAt ?? .distantPast) ?? 0),
                issuedAt: state.lastValidatedAt ?? .distantPast
            ))
        )
    }
}

private final class CompletionLicenseStateStore: LicenseStateStoring {
    var state: LicenseState?

    init(state: LicenseState?) {
        self.state = state
    }

    func load() throws -> LicenseState? {
        state
    }

    func save(_ state: LicenseState) throws {
        self.state = state
    }
}

private final class CompletionLicenseKeychainBackend: LicenseKeychainBackend {
    private var values: [String: Data] = [:]

    func save(_ data: Data, service: String, account: String) throws {
        values[account] = data
    }

    func read(service: String, account: String) throws -> Data? {
        values[account]
    }

    func delete(service: String, account: String) throws {
        values.removeValue(forKey: account)
    }
}

private struct CompletionOfflineVerifier: OfflineLicenseTokenVerifying {
    func validate(_ token: OfflineLicenseToken) -> Bool {
        false
    }
}

private struct CompletionValidOfflineVerifier: OfflineLicenseTokenVerifying {
    func validate(_ token: OfflineLicenseToken) -> Bool {
        true
    }
}

private struct CompletionSignedVerifier: SignedLicenseTokenVerifying {
    var claims: SignedLicenseClaims?

    func verifiedClaims(from token: String) throws -> SignedLicenseClaims {
        guard let claims else {
            throw ProductOpsError.invalidSignedLicenseToken
        }
        return claims
    }
}

private final class CompletionFailingHTTPClient: ProductOpsHTTPClient {
    let error: Error

    init(error: Error) {
        self.error = error
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw error
    }
}
