import Foundation
import XCTest
@testable import StacioApp

final class ProductOpsServicesTests: XCTestCase {
    func testServiceErrorsDoNotExposeInternalPlatformName() {
        XCTAssertFalse(ProductOpsError.missingAPIBaseURL.localizedDescription.contains("Product Ops"))
        XCTAssertFalse(ProductOpsError.invalidURL.localizedDescription.contains("Product Ops"))
    }

    func testConfigurationDefaultsToProductionProductOpsEndpoints() throws {
        let defaults = try makeProductOpsDefaults()
        let configuration = ProductOpsConfigurationStore(
            defaults: defaults,
            environment: [:],
            bundleInfo: [:]
        ).load()

        XCTAssertEqual(configuration.apiBaseURL?.absoluteString, "https://ops.stacio.cn")
        XCTAssertEqual(configuration.productID, "stacio")
        XCTAssertEqual(configuration.effectiveAppcastURL?.absoluteString, "https://ops.stacio.cn/updates/stacio/stable/appcast.xml")
        XCTAssertEqual(configuration.betaAppcastURL?.absoluteString, "https://ops.stacio.cn/updates/stacio/beta/appcast.xml")
    }

    func testConfigurationLoadsPackagedInfoPlistValues() throws {
        let defaults = try makeProductOpsDefaults()
        let configuration = ProductOpsConfigurationStore(
            defaults: defaults,
            environment: [:],
            bundleInfo: [
                ProductOpsConfigurationStore.Key.productID: "stacio",
                ProductOpsConfigurationStore.Key.apiBaseURL: "https://ops.example.test",
                ProductOpsConfigurationStore.Key.updateChannel: "beta",
                ProductOpsConfigurationStore.Key.betaUpdatesEnabled: true
            ]
        ).load()

        XCTAssertEqual(configuration.productID, "stacio")
        XCTAssertEqual(configuration.apiBaseURL?.absoluteString, "https://ops.example.test")
        XCTAssertEqual(configuration.updateChannel, .beta)
        XCTAssertTrue(configuration.betaUpdatesEnabled)
        XCTAssertEqual(configuration.effectiveUpdateChannel, .beta)
    }

    func testConfigurationUsesStableWhenBetaUpdatesArePackagedOff() throws {
        let defaults = try makeProductOpsDefaults()
        let configuration = ProductOpsConfigurationStore(
            defaults: defaults,
            environment: [:],
            bundleInfo: [
                ProductOpsConfigurationStore.Key.apiBaseURL: "https://ops.example.test",
                ProductOpsConfigurationStore.Key.updateChannel: "beta",
                ProductOpsConfigurationStore.Key.betaUpdatesEnabled: false
            ]
        ).load()

        XCTAssertEqual(configuration.updateChannel, .beta)
        XCTAssertFalse(configuration.betaUpdatesEnabled)
        XCTAssertEqual(configuration.effectiveUpdateChannel, .stable)
    }

    func testConfigurationAllowsExplicitDevelopmentEnvironmentOverrides() throws {
        let defaults = try makeProductOpsDefaults()
        defaults.set("https://saved.example.test", forKey: ProductOpsConfigurationStore.Key.apiBaseURL)
        defaults.set(ProductOpsReleaseChannel.beta.rawValue, forKey: ProductOpsConfigurationStore.Key.updateChannel)
        defaults.set(true, forKey: ProductOpsConfigurationStore.Key.betaUpdatesEnabled)

        let configuration = ProductOpsConfigurationStore(
            defaults: defaults,
            environment: ["STACIO_PRODUCT_OPS_API_BASE_URL": "https://environment.example.test"],
            bundleInfo: [
                ProductOpsConfigurationStore.Key.productID: "stacio",
                ProductOpsConfigurationStore.Key.apiBaseURL: "https://packaged.example.test",
                ProductOpsConfigurationStore.Key.updateChannel: "stable",
                ProductOpsConfigurationStore.Key.betaUpdatesEnabled: false
            ],
            allowsDevelopmentOverrides: true
        ).load()

        XCTAssertEqual(configuration.productID, "stacio")
        XCTAssertEqual(configuration.apiBaseURL?.absoluteString, "https://environment.example.test")
        XCTAssertEqual(configuration.updateChannel, .beta)
        XCTAssertTrue(configuration.betaUpdatesEnabled)
    }

    func testPackagedServiceEndpointsOverrideStaleUserDefaultsButKeepUserSelectedChannel() throws {
        let defaults = try makeProductOpsDefaults()
        defaults.set("https://stale.example.test", forKey: ProductOpsConfigurationStore.Key.apiBaseURL)
        defaults.set(
            "https://stale.example.test/stable.xml",
            forKey: ProductOpsConfigurationStore.Key.stableAppcastURL
        )
        defaults.set(
            "https://stale.example.test/beta.xml",
            forKey: ProductOpsConfigurationStore.Key.betaAppcastURL
        )
        defaults.set(ProductOpsReleaseChannel.beta.rawValue, forKey: ProductOpsConfigurationStore.Key.updateChannel)
        defaults.set(true, forKey: ProductOpsConfigurationStore.Key.betaUpdatesEnabled)

        let configuration = ProductOpsConfigurationStore(
            defaults: defaults,
            environment: [:],
            bundleInfo: [
                ProductOpsConfigurationStore.Key.apiBaseURL: "https://packaged.example.test",
                ProductOpsConfigurationStore.Key.stableAppcastURL: "https://packaged.example.test/stable.xml",
                ProductOpsConfigurationStore.Key.betaAppcastURL: "https://packaged.example.test/beta.xml",
                ProductOpsConfigurationStore.Key.updateChannel: ProductOpsReleaseChannel.stable.rawValue,
                ProductOpsConfigurationStore.Key.betaUpdatesEnabled: false
            ]
        ).load()

        XCTAssertEqual(configuration.apiBaseURL?.absoluteString, "https://packaged.example.test")
        XCTAssertEqual(configuration.stableAppcastURL?.absoluteString, "https://packaged.example.test/stable.xml")
        XCTAssertEqual(configuration.betaAppcastURL?.absoluteString, "https://packaged.example.test/beta.xml")
        XCTAssertEqual(configuration.effectiveUpdateChannel, .beta)
    }

    func testConfigurationSavePersistsOnlyUserSelectableUpdateSettings() throws {
        let defaults = try makeProductOpsDefaults()
        let store = ProductOpsConfigurationStore(defaults: defaults, environment: [:])
        store.save(
            ProductOpsConfiguration(
                apiBaseURL: try XCTUnwrap(URL(string: "https://saved.example.test")),
                updateChannel: .beta,
                betaUpdatesEnabled: true
            )
        )

        let configuration = store.load()

        XCTAssertEqual(configuration.apiBaseURL?.absoluteString, "https://ops.stacio.cn")
        XCTAssertEqual(configuration.updateChannel, .beta)
        XCTAssertTrue(configuration.betaUpdatesEnabled)
        XCTAssertNil(defaults.object(forKey: ProductOpsConfigurationStore.Key.apiBaseURL))
    }

    func testFeedbackPayloadBuildsPublicFeedbackRequestWithVisibleDiagnosticsOnly() throws {
        let configuration = ProductOpsConfiguration(
            apiBaseURL: try XCTUnwrap(URL(string: "https://ops.example.test")),
            feedbackProductAPIKey: "public-feedback-key",
            productID: "stacio",
            updateChannel: .stable,
            betaUpdatesEnabled: false
        )
        let report = FeedbackReport(
            title: "  Tunnel check failed  ",
            type: .bug,
            description: "The status badge stayed red after reconnecting.",
            contact: " user@example.com ",
            includeDiagnostics: true
        )
        let context = FeedbackDiagnosticContext(
            appVersion: "0.13.1-Beta",
            build: "42",
            osVersion: "macOS 14.5",
            deviceID: "anonymous-device-id",
            diagnostics: [
                "activeWindowCount": "1",
                "configuredUpdateChannel": "stable"
            ]
        )

        let request = try FeedbackSubmissionService.makeRequest(
            report: report,
            context: context,
            configuration: configuration
        )
        let payload = try XCTUnwrap(request.httpBody).decodeJSON(FeedbackPayload.self)

        XCTAssertEqual(
            request.url?.absoluteString,
            "https://ops.example.test/api/v1/public/products/stacio/feedback"
        )
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(payload.title, "Tunnel check failed")
        XCTAssertEqual(payload.type, .bug)
        XCTAssertEqual(payload.description, "The status badge stayed red after reconnecting.")
        XCTAssertEqual(payload.contact, "user@example.com")
        XCTAssertEqual(payload.appVersion, "0.13.1-Beta")
        XCTAssertEqual(payload.build, "42")
        XCTAssertEqual(payload.osVersion, "macOS 14.5")
        XCTAssertEqual(payload.deviceID, "anonymous-device-id")
        XCTAssertEqual(payload.diagnostics?["activeWindowCount"], "1")
        XCTAssertNil(payload.diagnostics?["terminalTranscript"])
        XCTAssertNil(payload.diagnostics?["environment"])
        XCTAssertTrue(payload.privacySummary.contains("SSH 配置"))
        XCTAssertTrue(payload.privacySummary.contains("终端内容"))
    }

    func testFeedbackReportValidationRequiresTitleAndDescription() {
        let report = FeedbackReport(
            title: " ",
            type: .question,
            description: "\n",
            contact: nil
        )

        XCTAssertEqual(report.validationErrors, [.missingTitle, .missingDescription])
    }

    func testFeedbackConvenienceSubmissionAlwaysRoutesThroughIdempotencyAwareRequirement() async throws {
        let submitter = KeyOnlyFeedbackSubmitter()
        let report = FeedbackReport(
            title: "Connection problem",
            type: .bug,
            description: "The connection state did not refresh.",
            contact: nil
        )
        let context = FeedbackDiagnosticContext(
            appVersion: "1.0",
            build: "1",
            osVersion: "macOS",
            deviceID: "anonymous-device"
        )

        _ = try await submitter.submit(report: report, context: context)

        XCTAssertEqual(submitter.idempotencyKeys.count, 1)
        XCTAssertFalse(submitter.idempotencyKeys[0].isEmpty)
    }

    func testFeedbackIdempotencyStoreDoesNotClearNewerKeyForOldCompletion() throws {
        let defaults = try makeProductOpsDefaults()
        let store = FeedbackIdempotencyKeyStore(defaults: defaults)
        let original = FeedbackReport(
            title: "Connection problem",
            type: .bug,
            description: "The connection state did not refresh.",
            contact: nil
        )
        let different = FeedbackReport(
            title: "Different report",
            type: .feature,
            description: "Please add another action.",
            contact: nil
        )
        let oldKey = store.key(for: original)
        _ = store.key(for: different)
        let newerKey = store.key(for: original)
        XCTAssertNotEqual(oldKey, newerKey)

        store.clearKey(for: original, matching: oldKey)

        XCTAssertEqual(store.key(for: original), newerKey)
    }

    func testFeedbackIdempotencyKeyFingerprintIncludesSubmittedContext() throws {
        let defaults = try makeProductOpsDefaults()
        let store = FeedbackIdempotencyKeyStore(defaults: defaults)
        let report = FeedbackReport(
            title: "Connection problem",
            type: .bug,
            description: "The connection state did not refresh.",
            contact: nil,
            includeDiagnostics: true
        )
        let originalContext = FeedbackDiagnosticContext(
            appVersion: "1.0",
            build: "1",
            osVersion: "macOS 14.5",
            deviceID: "device-a",
            licenseStatus: .trial,
            diagnostics: ["activeWindowCount": "1"]
        )
        let changedContext = FeedbackDiagnosticContext(
            appVersion: "1.0",
            build: "2",
            osVersion: "macOS 14.5",
            deviceID: "device-a",
            licenseStatus: .trial,
            diagnostics: ["activeWindowCount": "1"]
        )

        let originalKey = store.key(for: report, context: originalContext)
        let reusedKey = store.key(for: report, context: originalContext)
        let changedKey = store.key(for: report, context: changedContext)

        XCTAssertEqual(reusedKey, originalKey)
        XCTAssertNotEqual(changedKey, originalKey)
        store.clearKey(for: report, context: originalContext, matching: originalKey)
        XCTAssertEqual(store.key(for: report, context: changedContext), changedKey)
    }

    func testFeedbackMalformedSuccessfulResponseIsNotRetried() async throws {
        let client = StubProductOpsHTTPClient(responseData: Data("<html>bad gateway</html>".utf8))
        let service = FeedbackSubmissionService(
            configuration: ProductOpsConfiguration(
                apiBaseURL: try XCTUnwrap(URL(string: "https://ops.example.test")),
                feedbackProductAPIKey: "public-feedback-key"
            ),
            httpClient: client,
            retryPolicy: .immediate(maxAttempts: 3)
        )

        do {
            _ = try await service.submit(
                report: FeedbackReport(
                    title: "Feedback response",
                    type: .bug,
                    description: "The service returned an invalid success payload.",
                    contact: "user@example.com"
                ),
                context: FeedbackDiagnosticContext(
                    appVersion: "1.0",
                    build: "1",
                    osVersion: "macOS",
                    deviceID: "anonymous-device"
                ),
                idempotencyKey: "feedback-malformed-success"
            )
            XCTFail("Expected malformed success response to fail")
        } catch {
            XCTAssertEqual(
                error as? ProductOpsError,
                .client(message: "反馈服务返回了无法识别的响应。", requestID: nil)
            )
        }
        XCTAssertEqual(client.requestCount, 1)
    }

    func testUpdateCheckReportsAvailableVersionAndComparesBuilds() async throws {
        let publishedAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-10T08:00:00Z"))
        let update = UpdateInfo(
            version: "0.14.0",
            build: "50",
            channel: .stable,
            releaseNotes: "Feedback and license foundations.",
            artifactURL: try XCTUnwrap(URL(string: "https://download.example.test/Stacio.dmg")),
            publishedAt: publishedAt,
            minSupportedVersion: "0.13.0"
        )
        let client = StubProductOpsHTTPClient(responseData: try JSONEncoder.productOps.encode(update))
        let service = UpdateCheckService(
            configuration: ProductOpsConfiguration(
                apiBaseURL: try XCTUnwrap(URL(string: "https://ops.example.test")),
                productID: "stacio",
                updateChannel: .stable,
                betaUpdatesEnabled: false
            ),
            currentVersion: "0.13.1-Beta",
            currentBuild: "42",
            httpClient: client
        )

        let status = try await service.checkForUpdates()

        XCTAssertEqual(status, .updateAvailable(update))
        XCTAssertEqual(
            client.requestedURL?.absoluteString,
            "https://ops.example.test/api/v1/public/products/stacio/updates?channel=stable&version=0.13.1-Beta&build=42"
        )
        XCTAssertTrue(UpdateVersionComparator.isUpdate(update, newerThanVersion: "0.13.1-Beta", build: "42"))
        XCTAssertFalse(UpdateVersionComparator.isUpdate(update, newerThanVersion: "0.14.0", build: "50"))
    }

    func testUpdateCheckReportsUpToDateWhenBackendVersionIsNotNewer() async throws {
        let update = UpdateInfo(
            version: "0.13.1-Beta",
            build: "42",
            channel: .stable,
            releaseNotes: "",
            artifactURL: nil,
            publishedAt: nil,
            minSupportedVersion: nil
        )
        let service = UpdateCheckService(
            configuration: ProductOpsConfiguration(
                apiBaseURL: try XCTUnwrap(URL(string: "https://ops.example.test")),
                productID: "stacio",
                updateChannel: .stable,
                betaUpdatesEnabled: false
            ),
            currentVersion: "0.13.1-Beta",
            currentBuild: "42",
            httpClient: StubProductOpsHTTPClient(responseData: try JSONEncoder.productOps.encode(update))
        )

        let status = try await service.checkForUpdates()

        XCTAssertEqual(status, .upToDate)
    }

    func testVersionComparisonOrdersReleaseAndPrereleaseIdentifiers() {
        XCTAssertEqual(
            UpdateVersionComparator.compareVersions("0.13.2", "0.13.2-Beta"),
            .orderedDescending
        )
        XCTAssertEqual(
            UpdateVersionComparator.compareVersions("0.13.2-Beta.2", "0.13.2-Beta.1"),
            .orderedDescending
        )
        XCTAssertEqual(
            UpdateVersionComparator.compareVersions("0.13.2-Beta.1", "0.13.2-Beta.1"),
            .orderedSame
        )
        XCTAssertEqual(
            UpdateVersionComparator.compareVersions("0.13.2-Beta.1", "0.13.2"),
            .orderedAscending
        )
    }

    func testLicenseEvaluationAllowsFourteenDayOfflineGraceAfterOnlineValidation() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-10T12:00:00Z"))
        let lastValidated = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-06-28T12:00:00Z"))
        let expiresAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-01T00:00:00Z"))
        let state = LicenseState(
            username: "Ada",
            email: "ada@example.com",
            signedLicenseToken: "signed-token",
            plan: "team",
            expiresAt: expiresAt,
            graceUntil: nil,
            status: .active,
            lastValidatedAt: lastValidated,
            offlineToken: nil
        )
        let service = LicenseService(
            store: InMemoryLicenseStateStore(state: state),
            verifier: StubOfflineLicenseTokenVerifier(isValid: false),
            signedTokenVerifier: StubSignedLicenseTokenVerifier(claims: SignedLicenseClaims(
                licenseID: "license-1",
                productID: "stacio",
                email: state.email,
                username: state.username,
                plan: state.plan,
                entitlements: state.permissions,
                expiresAt: expiresAt,
                offlineGraceSeconds: 14 * 24 * 60 * 60,
                issuedAt: lastValidated
            ))
        )

        let evaluated = try service.stateForNetworkUnavailable(now: now)

        XCTAssertEqual(evaluated.status, .offlineGrace)
        XCTAssertEqual(evaluated.graceUntil, lastValidated.addingTimeInterval(14 * 24 * 60 * 60))
    }

    func testLicenseEvaluationExpiresAfterOfflineGraceWindow() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-10T12:00:00Z"))
        let lastValidated = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-06-20T12:00:00Z"))
        let state = LicenseState(
            username: "Ada",
            email: "ada@example.com",
            signedLicenseToken: "signed-token",
            plan: "team",
            expiresAt: try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-01T00:00:00Z")),
            graceUntil: nil,
            status: .active,
            lastValidatedAt: lastValidated,
            offlineToken: nil
        )
        let service = LicenseService(
            store: InMemoryLicenseStateStore(state: state),
            verifier: StubOfflineLicenseTokenVerifier(isValid: false),
            signedTokenVerifier: StubSignedLicenseTokenVerifier(claims: SignedLicenseClaims(
                licenseID: "license-1",
                productID: "stacio",
                email: state.email,
                username: state.username,
                plan: state.plan,
                entitlements: state.permissions,
                expiresAt: try XCTUnwrap(state.expiresAt),
                offlineGraceSeconds: 14 * 24 * 60 * 60,
                issuedAt: lastValidated
            ))
        )

        let evaluated = service.evaluate(state: state, now: now)

        XCTAssertEqual(evaluated.status, .expired)
        XCTAssertNil(evaluated.graceUntil)
    }

    func testOfflineLicenseTokenRequiresVerifierAndCarriesUserIdentity() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-10T12:00:00Z"))
        let expiresAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-01T00:00:00Z"))
        let token = OfflineLicenseToken(
            username: "Ada",
            email: "ada@example.com",
            plan: "team",
            issuedAt: now,
            expiresAt: expiresAt,
            signatureKeyID: "stacio-public-2026-01",
            signature: "public-signature"
        )
        let service = LicenseService(
            store: InMemoryLicenseStateStore(),
            verifier: StubOfflineLicenseTokenVerifier(isValid: true)
        )

        let state = try service.state(applyingOfflineToken: token, now: now)

        XCTAssertEqual(state.username, "Ada")
        XCTAssertEqual(state.email, "ada@example.com")
        XCTAssertEqual(state.plan, "team")
        XCTAssertEqual(state.expiresAt, expiresAt)
        XCTAssertEqual(state.status, .offlineActive)
        XCTAssertEqual(state.offlineToken, token)
    }
}

private func makeProductOpsDefaults() throws -> UserDefaults {
    let suiteName = "StacioProductOpsServicesTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}

private final class StubProductOpsHTTPClient: ProductOpsHTTPClient {
    private let responseData: Data
    private(set) var requestedURL: URL?
    private(set) var requestCount = 0

    init(responseData: Data) {
        self.responseData = responseData
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestCount += 1
        requestedURL = request.url
        return (
            responseData,
            HTTPURLResponse(
                url: request.url ?? URL(string: "https://ops.example.test")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
        )
    }
}

private final class KeyOnlyFeedbackSubmitter: FeedbackSubmitting {
    private(set) var idempotencyKeys: [String] = []

    func submit(
        report: FeedbackReport,
        context: FeedbackDiagnosticContext,
        idempotencyKey: String
    ) async throws -> FeedbackSubmissionResult {
        idempotencyKeys.append(idempotencyKey)
        return FeedbackSubmissionResult(id: "feedback-1", message: "ok")
    }
}

private struct StubOfflineLicenseTokenVerifier: OfflineLicenseTokenVerifying {
    let isValid: Bool

    func validate(_ token: OfflineLicenseToken) -> Bool {
        isValid
    }
}

private struct StubSignedLicenseTokenVerifier: SignedLicenseTokenVerifying {
    let claims: SignedLicenseClaims

    func verifiedClaims(from token: String) throws -> SignedLicenseClaims {
        claims
    }
}

private final class InMemoryLicenseStateStore: LicenseStateStoring {
    var state: LicenseState?

    init(state: LicenseState? = nil) {
        self.state = state
    }

    func load() throws -> LicenseState? {
        state
    }

    func save(_ state: LicenseState) throws {
        self.state = state
    }
}

private extension Data {
    func decodeJSON<Value: Decodable>(_ type: Value.Type) throws -> Value {
        try JSONDecoder.productOps.decode(type, from: self)
    }
}
