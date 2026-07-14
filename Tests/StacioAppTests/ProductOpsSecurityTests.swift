import CryptoKit
import Foundation
import Sparkle
import XCTest
@testable import StacioApp

final class ProductOpsSecurityTests: XCTestCase {
    func testConfigurationDoesNotTrustOrPersistSecurityKeysFromUserDefaults() throws {
        let defaults = try makeProductOpsSecurityDefaults()
        defaults.set("https://attacker.example.test", forKey: ProductOpsConfigurationStore.Key.apiBaseURL)
        defaults.set("attacker-product", forKey: ProductOpsConfigurationStore.Key.productID)
        defaults.set("attacker-feedback-key", forKey: ProductOpsConfigurationStore.Key.feedbackProductAPIKey)
        defaults.set("https://attacker.example.test/stable.xml", forKey: ProductOpsConfigurationStore.Key.stableAppcastURL)
        defaults.set("https://attacker.example.test/beta.xml", forKey: ProductOpsConfigurationStore.Key.betaAppcastURL)
        defaults.set("attacker-sparkle-key", forKey: ProductOpsConfigurationStore.Key.sparklePublicEDKey)
        defaults.set("attacker-license-key", forKey: ProductOpsConfigurationStore.Key.licensePublicKeyBase64)
        let store = ProductOpsConfigurationStore(
            defaults: defaults,
            environment: [:],
            bundleInfo: [
                ProductOpsConfigurationStore.Key.apiBaseURL: "https://ops.example.test",
                ProductOpsConfigurationStore.Key.productID: "stacio",
                ProductOpsConfigurationStore.Key.feedbackProductAPIKey: "packaged-feedback-key",
                ProductOpsConfigurationStore.Key.stableAppcastURL: "https://ops.example.test/stable.xml",
                ProductOpsConfigurationStore.Key.betaAppcastURL: "https://ops.example.test/beta.xml",
                ProductOpsConfigurationStore.Key.sparklePublicEDKey: "packaged-sparkle-key",
                ProductOpsConfigurationStore.Key.licensePublicKeyBase64: "packaged-license-key"
            ]
        )

        let loaded = store.load()

        XCTAssertEqual(loaded.apiBaseURL?.absoluteString, "https://ops.example.test")
        XCTAssertEqual(loaded.productID, "stacio")
        XCTAssertEqual(loaded.feedbackProductAPIKey, "packaged-feedback-key")
        XCTAssertEqual(loaded.stableAppcastURL?.absoluteString, "https://ops.example.test/stable.xml")
        XCTAssertEqual(loaded.betaAppcastURL?.absoluteString, "https://ops.example.test/beta.xml")
        XCTAssertEqual(loaded.sparklePublicEDKey, "packaged-sparkle-key")
        XCTAssertEqual(loaded.licensePublicKeyBase64, "packaged-license-key")

        store.save(ProductOpsConfiguration(
            feedbackProductAPIKey: "replacement-feedback-key",
            sparklePublicEDKey: "replacement-sparkle-key",
            licensePublicKeyBase64: "replacement-license-key"
        ))

        XCTAssertNil(defaults.object(forKey: ProductOpsConfigurationStore.Key.apiBaseURL))
        XCTAssertNil(defaults.object(forKey: ProductOpsConfigurationStore.Key.productID))
        XCTAssertNil(defaults.object(forKey: ProductOpsConfigurationStore.Key.feedbackProductAPIKey))
        XCTAssertNil(defaults.object(forKey: ProductOpsConfigurationStore.Key.stableAppcastURL))
        XCTAssertNil(defaults.object(forKey: ProductOpsConfigurationStore.Key.betaAppcastURL))
        XCTAssertNil(defaults.object(forKey: ProductOpsConfigurationStore.Key.sparklePublicEDKey))
        XCTAssertNil(defaults.object(forKey: ProductOpsConfigurationStore.Key.licensePublicKeyBase64))
    }

    func testProductionConfigurationDoesNotAllowEnvironmentToReplacePackagedValues() throws {
        let defaults = try makeProductOpsSecurityDefaults()
        let configuration = ProductOpsConfigurationStore(
            defaults: defaults,
            environment: [
                "STACIO_PRODUCT_OPS_API_BASE_URL": "https://attacker.example.test",
                "STACIO_PRODUCT_OPS_PRODUCT_ID": "attacker-product",
                "STACIO_FEEDBACK_PRODUCT_API_KEY": "attacker-feedback-key",
                "STACIO_SPARKLE_STABLE_APPCAST_URL": "https://attacker.example.test/stable.xml",
                "STACIO_SPARKLE_BETA_APPCAST_URL": "https://attacker.example.test/beta.xml",
                "STACIO_SPARKLE_PUBLIC_ED_KEY": "attacker-sparkle-key",
                "STACIO_LICENSE_PUBLIC_ED25519_KEY": "attacker-license-key"
            ],
            bundleInfo: [
                ProductOpsConfigurationStore.Key.apiBaseURL: "https://ops.example.test",
                ProductOpsConfigurationStore.Key.productID: "stacio",
                ProductOpsConfigurationStore.Key.feedbackProductAPIKey: "packaged-feedback-key",
                ProductOpsConfigurationStore.Key.stableAppcastURL: "https://ops.example.test/stable.xml",
                ProductOpsConfigurationStore.Key.betaAppcastURL: "https://ops.example.test/beta.xml",
                ProductOpsConfigurationStore.Key.sparklePublicEDKey: "packaged-sparkle-key",
                ProductOpsConfigurationStore.Key.licensePublicKeyBase64: "packaged-license-key"
            ]
        ).load()

        XCTAssertEqual(configuration.apiBaseURL?.absoluteString, "https://ops.example.test")
        XCTAssertEqual(configuration.productID, "stacio")
        XCTAssertEqual(configuration.feedbackProductAPIKey, "packaged-feedback-key")
        XCTAssertEqual(configuration.stableAppcastURL?.absoluteString, "https://ops.example.test/stable.xml")
        XCTAssertEqual(configuration.betaAppcastURL?.absoluteString, "https://ops.example.test/beta.xml")
        XCTAssertEqual(configuration.sparklePublicEDKey, "packaged-sparkle-key")
        XCTAssertEqual(configuration.licensePublicKeyBase64, "packaged-license-key")
    }

    func testFeedbackRequestIncludesPublicKeyAndStableIdempotencyKey() throws {
        let configuration = ProductOpsConfiguration(
            apiBaseURL: try XCTUnwrap(URL(string: "https://ops.example.test")),
            feedbackProductAPIKey: "public-feedback-key",
            productID: "stacio"
        )
        let report = FeedbackReport(
            title: "Connection status did not refresh",
            type: .feature,
            description: "Please add a manual refresh action.",
            contact: "user@example.com",
            includeDiagnostics: true
        )
        let context = FeedbackDiagnosticContext(
            appVersion: "0.13.2",
            build: "17",
            osVersion: "macOS 15.0",
            deviceID: "anonymous-device",
            licenseStatus: .trial,
            diagnostics: [
                "activeWindowCount": "2",
                "safeMetric": "7",
                "terminalTranscript": "rm -rf /",
                "apiToken": "secret"
            ]
        )

        let request = try FeedbackSubmissionService.makeRequest(
            report: report,
            context: context,
            configuration: configuration,
            idempotencyKey: "feedback-draft-1"
        )
        let payload = try XCTUnwrap(request.httpBody).decodeJSON(FeedbackPayload.self)
        let rawPayload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any]
        )

        XCTAssertEqual(request.value(forHTTPHeaderField: "x-product-api-key"), "public-feedback-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Idempotency-Key"), "feedback-draft-1")
        XCTAssertEqual(payload.type, .feature)
        XCTAssertEqual(payload.licenseStatus, .trial)
        XCTAssertEqual(payload.diagnostics?["activeWindowCount"], "2")
        XCTAssertNil(payload.diagnostics?["safeMetric"])
        XCTAssertNil(payload.diagnostics?["terminalTranscript"])
        XCTAssertNil(payload.diagnostics?["apiToken"])
        XCTAssertEqual(rawPayload["contactEmail"] as? String, "user@example.com")
        XCTAssertEqual(rawPayload["buildNumber"] as? String, "17")
        XCTAssertEqual(rawPayload["anonymousDeviceId"] as? String, "anonymous-device")
        XCTAssertEqual(rawPayload["licenseState"] as? String, LicenseStatus.trial.rawValue)
        XCTAssertNotNil(rawPayload["diagnosticsSummary"])
        XCTAssertNil(rawPayload["contact"])
        XCTAssertNil(rawPayload["build"])
        XCTAssertNil(rawPayload["deviceId"])
        XCTAssertNil(rawPayload["licenseStatus"])
        XCTAssertNil(rawPayload["diagnostics"])
    }

    func testFeedbackRequestOmitsOptionalDiagnosticsWithoutConsent() throws {
        let configuration = ProductOpsConfiguration(
            apiBaseURL: try XCTUnwrap(URL(string: "https://ops.example.test")),
            feedbackProductAPIKey: "public-feedback-key"
        )
        let request = try FeedbackSubmissionService.makeRequest(
            report: FeedbackReport(
                title: "Question",
                type: .question,
                description: "How do I configure a profile?",
                contact: nil,
                includeDiagnostics: false
            ),
            context: FeedbackDiagnosticContext(
                appVersion: "1",
                build: "1",
                osVersion: "macOS",
                deviceID: "device",
                licenseStatus: .active,
                diagnostics: ["safeMetric": "2"]
            ),
            configuration: configuration,
            idempotencyKey: "feedback-draft-2"
        )

        let payload = try XCTUnwrap(request.httpBody).decodeJSON(FeedbackPayload.self)
        XCTAssertNil(payload.diagnostics)
        XCTAssertEqual(payload.appVersion, "1")
        XCTAssertEqual(payload.licenseStatus, .active)
    }

    func testFeedbackRejectsMalformedContactEmail() {
        let report = FeedbackReport(
            title: "Bug",
            type: .bug,
            description: "Something broke.",
            contact: "not-an-email",
            includeDiagnostics: false
        )

        XCTAssertEqual(report.validationErrors, [.invalidContactEmail])
    }

    func testProductOpsErrorClassifiesRateLimitAndOfflineFailures() throws {
        let limitedResponse = HTTPURLResponse(
            url: try XCTUnwrap(URL(string: "https://ops.example.test")),
            statusCode: 429,
            httpVersion: nil,
            headerFields: ["Retry-After": "45", "X-Request-ID": "req-rate"]
        )!

        XCTAssertEqual(
            ProductOpsError.responseError(data: Data(), response: limitedResponse),
            .rateLimited(retryAfter: 45, requestID: "req-rate")
        )
        XCTAssertEqual(ProductOpsError.classify(URLError(.notConnectedToInternet)), .offline)
        XCTAssertEqual(ProductOpsError.classify(URLError(.timedOut)), .timeout)
    }

    func testProductOpsErrorDecodesBackendEnvelopeAndPreservesRequestID() throws {
        let response = HTTPURLResponse(
            url: try XCTUnwrap(URL(string: "https://ops.example.test")),
            statusCode: 422,
            httpVersion: nil,
            headerFields: ["X-Request-ID": "req-validation"]
        )!
        let data = Data(
            """
            {
              "ok": false,
              "error": {
                "code": "VALIDATION_ERROR",
                "message": "Invalid feedback payload"
              }
            }
            """.utf8
        )

        XCTAssertEqual(
            ProductOpsError.responseError(data: data, response: response),
            .client(message: "Invalid feedback payload", requestID: "req-validation")
        )
    }

    func testProductOpsRequestsRejectRemoteHTTPButAllowLocalDevelopmentHTTP() throws {
        let insecureConfiguration = ProductOpsConfiguration(
            apiBaseURL: try XCTUnwrap(URL(string: "http://ops.example.test")),
            feedbackProductAPIKey: "public-feedback-key"
        )
        let report = FeedbackReport(
            title: "Security",
            type: .bug,
            description: "Do not send secrets over plaintext HTTP.",
            contact: nil,
            includeDiagnostics: false
        )
        let context = FeedbackDiagnosticContext(
            appVersion: "1",
            build: "1",
            osVersion: "macOS",
            deviceID: "device"
        )
        let licenseRequest = LicenseValidationRequest(
            licenseKey: "STACIO-KEY",
            username: "Ada",
            email: "ada@example.com",
            appVersion: "1",
            buildNumber: "1",
            anonymousDeviceID: "device"
        )

        XCTAssertThrowsError(
            try FeedbackSubmissionService.makeRequest(
                report: report,
                context: context,
                configuration: insecureConfiguration
            )
        ) { error in
            XCTAssertEqual(error as? ProductOpsError, .invalidURL)
        }
        XCTAssertThrowsError(
            try LicenseOnlineValidationService.makeRequest(
                configuration: insecureConfiguration,
                requestBody: licenseRequest
            )
        ) { error in
            XCTAssertEqual(error as? ProductOpsError, .invalidURL)
        }

        let localConfiguration = ProductOpsConfiguration(
            apiBaseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:8080"))
        )
        XCTAssertNoThrow(
            try LicenseOnlineValidationService.makeRequest(
                configuration: localConfiguration,
                requestBody: licenseRequest
            )
        )
    }

    func testFeedbackServiceRetriesTransientFailureWithSameIdempotencyKey() async throws {
        let client = SequencedProductOpsHTTPClient(
            results: [
                .failure(URLError(.networkConnectionLost)),
                .success(
                    Data("{\"id\":\"feedback-1\"}".utf8),
                    makeHTTPResponse(statusCode: 201)
                )
            ]
        )
        let service = FeedbackSubmissionService(
            configuration: ProductOpsConfiguration(
                apiBaseURL: try XCTUnwrap(URL(string: "https://ops.example.test")),
                feedbackProductAPIKey: "public-feedback-key"
            ),
            httpClient: client,
            retryPolicy: .immediate(maxAttempts: 2)
        )

        let result = try await service.submit(
            report: FeedbackReport(
                title: "Network retry",
                type: .bug,
                description: "Retry should preserve the draft id.",
                contact: nil,
                includeDiagnostics: false
            ),
            context: FeedbackDiagnosticContext(
                appVersion: "1",
                build: "1",
                osVersion: "macOS",
                deviceID: "device",
                licenseStatus: .inactive
            ),
            idempotencyKey: "stable-feedback-id"
        )

        XCTAssertEqual(result.id, "feedback-1")
        XCTAssertEqual(client.requests.count, 2)
        XCTAssertEqual(client.requests.map { $0.value(forHTTPHeaderField: "X-Idempotency-Key") }, ["stable-feedback-id", "stable-feedback-id"])
    }

    func testFeedbackServiceDecodesBackendSuccessEnvelope() async throws {
        let responseData = Data(
            """
            {
              "ok": true,
              "data": { "id": "feedback-1" },
              "message": "Feedback received."
            }
            """.utf8
        )
        let service = FeedbackSubmissionService(
            configuration: ProductOpsConfiguration(
                apiBaseURL: try XCTUnwrap(URL(string: "https://ops.example.test")),
                feedbackProductAPIKey: "public-feedback-key"
            ),
            httpClient: SequencedProductOpsHTTPClient(results: [
                .success(responseData, makeHTTPResponse(statusCode: 201))
            ])
        )

        let result = try await service.submit(
            report: FeedbackReport(
                title: "Network retry",
                type: .bug,
                description: "Decode the public API response.",
                contact: nil,
                includeDiagnostics: false
            ),
            context: FeedbackDiagnosticContext(
                appVersion: "1",
                build: "1",
                osVersion: "macOS",
                deviceID: "device"
            ),
            idempotencyKey: "feedback-envelope"
        )

        XCTAssertEqual(result.id, "feedback-1")
        XCTAssertEqual(result.message, "Feedback received.")
    }

    func testFeedbackServiceDoesNotRetryClientHTTPFailures() async throws {
        for statusCode in [401, 409, 422] {
            let response = HTTPURLResponse(
                url: try XCTUnwrap(URL(string: "https://ops.example.test")),
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["X-Request-ID": "req-\(statusCode)"]
            )!
            let client = SequencedProductOpsHTTPClient(results: [
                .success(
                    Data("{\"ok\":false,\"error\":{\"message\":\"Rejected\"}}".utf8),
                    response
                ),
                .success(Data("{\"id\":\"duplicate\"}".utf8), makeHTTPResponse(statusCode: 201))
            ])
            let service = FeedbackSubmissionService(
                configuration: ProductOpsConfiguration(
                    apiBaseURL: try XCTUnwrap(URL(string: "https://ops.example.test")),
                    feedbackProductAPIKey: "public-feedback-key"
                ),
                httpClient: client,
                retryPolicy: .immediate(maxAttempts: 2)
            )

            do {
                _ = try await service.submit(
                    report: validFeedbackReport,
                    context: validFeedbackContext,
                    idempotencyKey: "client-error-\(statusCode)"
                )
                XCTFail("HTTP \(statusCode) must fail")
            } catch {
                XCTAssertEqual(
                    error as? ProductOpsError,
                    .client(message: "Rejected", requestID: "req-\(statusCode)")
                )
            }
            XCTAssertEqual(client.requests.count, 1, "HTTP \(statusCode) must not be retried")
        }
    }

    func testFeedbackServiceRetriesServerHTTPFailure() async throws {
        let client = SequencedProductOpsHTTPClient(results: [
            .success(Data(), makeHTTPResponse(statusCode: 503)),
            .success(Data("{\"id\":\"feedback-after-retry\"}".utf8), makeHTTPResponse(statusCode: 201))
        ])
        let service = FeedbackSubmissionService(
            configuration: ProductOpsConfiguration(
                apiBaseURL: try XCTUnwrap(URL(string: "https://ops.example.test")),
                feedbackProductAPIKey: "public-feedback-key"
            ),
            httpClient: client,
            retryPolicy: .immediate(maxAttempts: 2)
        )

        let result = try await service.submit(
            report: validFeedbackReport,
            context: validFeedbackContext,
            idempotencyKey: "server-retry"
        )

        XCTAssertEqual(result.id, "feedback-after-retry")
        XCTAssertEqual(client.requests.count, 2)
    }

    func testFeedbackServiceRejectsMalformedAndNegativeSuccessResponses() async throws {
        let responses: [Data] = [
            Data("<html>gateway failure</html>".utf8),
            Data("{broken-json".utf8),
            Data("{\"ok\":false,\"message\":\"Feedback rejected\"}".utf8)
        ]

        for (index, data) in responses.enumerated() {
            let client = SequencedProductOpsHTTPClient(results: [
                .success(data, makeHTTPResponse(statusCode: 200))
            ])
            let service = FeedbackSubmissionService(
                configuration: ProductOpsConfiguration(
                    apiBaseURL: try XCTUnwrap(URL(string: "https://ops.example.test")),
                    feedbackProductAPIKey: "public-feedback-key"
                ),
                httpClient: client
            )

            do {
                _ = try await service.submit(
                    report: validFeedbackReport,
                    context: validFeedbackContext,
                    idempotencyKey: "invalid-success-\(index)"
                )
                XCTFail("Malformed 2xx response must not be reported as success")
            } catch {
                XCTAssertNotNil(error as? ProductOpsError)
            }
            XCTAssertEqual(client.requests.count, 1)
        }
    }

    func testLicenseValidationHashesDeviceIdentifierAndUsesPublicEndpoint() throws {
        let configuration = ProductOpsConfiguration(
            apiBaseURL: try XCTUnwrap(URL(string: "https://ops.example.test")),
            productID: "stacio"
        )
        let request = try LicenseOnlineValidationService.makeRequest(
            configuration: configuration,
            requestBody: LicenseValidationRequest(
                licenseKey: "STACIO-SECRET-LICENSE",
                username: "Ada",
                email: "ada@example.com",
                appVersion: "0.13.2",
                buildNumber: "17",
                anonymousDeviceID: "anonymous-device"
            )
        )
        let payload = try XCTUnwrap(request.httpBody).decodeJSON(LicenseValidationRequest.self)
        let rawPayload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any]
        )

        XCTAssertEqual(request.url?.absoluteString, "https://ops.example.test/api/v1/public/products/stacio/licenses/validate")
        XCTAssertEqual(payload.deviceIDHash, DeviceIdentifierHasher.hash("anonymous-device"))
        XCTAssertNotEqual(payload.deviceIDHash, "anonymous-device")
        XCTAssertEqual(payload.licenseKey, "STACIO-SECRET-LICENSE")
        XCTAssertEqual(
            rawPayload["machineFingerprintHash"] as? String,
            DeviceIdentifierHasher.hash("anonymous-device")
        )
        XCTAssertNil(rawPayload["deviceIDHash"])
        XCTAssertNil(rawPayload["anonymousDeviceID"])
        XCTAssertNil(rawPayload["anonymousDeviceId"])
    }

    func testLicenseOnlineValidatorDecodesBackendEnvelope() async throws {
        let responseData = Data(
            """
            {
              "ok": true,
              "data": {
                "valid": true,
                "status": "active",
                "plan": "pro",
                "entitlements": ["remote_sessions"],
                "expiresAt": "2027-01-20T10:00:00Z",
                "offlineGraceSeconds": 1209600,
                "signedLicenseToken": "v1.payload.signature"
              }
            }
            """.utf8
        )
        let client = SequencedProductOpsHTTPClient(results: [
            .success(responseData, makeHTTPResponse(statusCode: 200))
        ])
        let service = LicenseOnlineValidationService(
            configuration: ProductOpsConfiguration(
                apiBaseURL: try XCTUnwrap(URL(string: "https://ops.example.test")),
                productID: "stacio"
            ),
            httpClient: client
        )
        let request = LicenseValidationRequest(
            licenseKey: "STACIO-KEY",
            username: "Ada",
            email: "ada@example.com",
            appVersion: "0.13.2",
            buildNumber: "17",
            anonymousDeviceID: "anonymous-device"
        )

        let response = try await service.validate(request)

        XCTAssertEqual(response.username, "Ada")
        XCTAssertEqual(response.email, "ada@example.com")
        XCTAssertEqual(response.plan, "pro")
        XCTAssertEqual(response.permissions, ["remote_sessions"])
        XCTAssertEqual(response.offlineGraceSeconds, 1_209_600)
        XCTAssertEqual(response.status, .active)
    }

    func testLicenseOnlineValidatorMapsRevokedBackendEnvelopeToTerminalState() async throws {
        let responseData = Data(
            """
            {
              "ok": true,
              "data": {
                "valid": false,
                "reason": "LICENSE_REVOKED"
              }
            }
            """.utf8
        )
        let client = SequencedProductOpsHTTPClient(results: [
            .success(responseData, makeHTTPResponse(statusCode: 200))
        ])
        let service = LicenseOnlineValidationService(
            configuration: ProductOpsConfiguration(
                apiBaseURL: try XCTUnwrap(URL(string: "https://ops.example.test")),
                productID: "stacio"
            ),
            httpClient: client
        )
        let request = LicenseValidationRequest(
            licenseKey: "STACIO-KEY",
            username: "Ada",
            email: "ada@example.com",
            appVersion: "0.13.2",
            buildNumber: "17",
            anonymousDeviceID: "anonymous-device"
        )

        let response = try await service.validate(request)

        XCTAssertEqual(response.username, request.username)
        XCTAssertEqual(response.email, request.email)
        XCTAssertEqual(response.status, .revoked)
        XCTAssertTrue(response.signedLicenseToken.isEmpty)
    }

    func testLicenseOnlineValidatorPreservesStatusOnlyTerminalBackendEnvelope() async throws {
        let responseData = Data(
            """
            {
              "ok": true,
              "data": {
                "valid": false,
                "status": "suspended"
              }
            }
            """.utf8
        )
        let client = SequencedProductOpsHTTPClient(results: [
            .success(responseData, makeHTTPResponse(statusCode: 200))
        ])
        let service = LicenseOnlineValidationService(
            configuration: ProductOpsConfiguration(
                apiBaseURL: try XCTUnwrap(URL(string: "https://ops.example.test")),
                productID: "stacio"
            ),
            httpClient: client
        )
        let request = LicenseValidationRequest(
            licenseKey: "STACIO-KEY",
            username: "Ada",
            email: "ada@example.com",
            appVersion: "0.13.2",
            buildNumber: "17",
            anonymousDeviceID: "anonymous-device"
        )

        let response = try await service.validate(request)

        XCTAssertEqual(response.status, .suspended)
    }

    func testLicenseServiceRejectsOnlineIdentityMismatch() throws {
        let service = LicenseService(store: InMemorySecureLicenseStateStore())
        let request = LicenseValidationRequest(
            licenseKey: "license-key",
            username: "Ada",
            email: "ada@example.com",
            appVersion: "1",
            buildNumber: "1",
            anonymousDeviceID: "device"
        )
        let response = LicenseValidationResponse(
            username: "Grace",
            email: "ada@example.com",
            signedLicenseToken: "signed-token",
            plan: "pro",
            permissions: ["remote_sessions"],
            expiresAt: nil,
            offlineGraceUntil: nil,
            status: .active
        )

        XCTAssertThrowsError(try service.state(applyingOnlineValidation: response, expected: request)) { error in
            XCTAssertEqual(error as? ProductOpsError, .licenseIdentityMismatch)
        }
    }

    func testLicenseServiceRejectsOfflineIdentityMismatch() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-10T12:00:00Z"))
        let token = OfflineLicenseToken(
            productID: "stacio",
            username: "Ada",
            email: "ada@example.com",
            plan: "pro",
            permissions: ["remote_sessions"],
            issuedAt: now,
            expiresAt: try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-10T12:00:00Z")),
            signedLicenseToken: "offline-token",
            signatureKeyID: "primary",
            signature: "signature"
        )
        let service = LicenseService(
            store: InMemorySecureLicenseStateStore(),
            verifier: AlwaysValidOfflineLicenseTokenVerifier()
        )

        XCTAssertThrowsError(
            try service.state(
                applyingOfflineToken: token,
                expectedUsername: "Grace",
                expectedEmail: "ada@example.com",
                now: now
            )
        ) { error in
            XCTAssertEqual(error as? ProductOpsError, .licenseIdentityMismatch)
        }
    }

    func testLicenseServiceRequiresUsernameAndEmailForEveryOfflineImportFormat() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let claims = SignedLicenseClaims(
            licenseID: "license-1",
            productID: "stacio",
            email: "ada@example.com",
            username: "Ada",
            plan: "pro",
            entitlements: ["remote_sessions"],
            expiresAt: now.addingTimeInterval(86_400),
            offlineGraceSeconds: 1_209_600,
            issuedAt: now
        )
        let legacyToken = OfflineLicenseToken(
            productID: claims.productID,
            username: claims.username,
            email: claims.email,
            plan: claims.plan,
            permissions: claims.entitlements,
            issuedAt: claims.issuedAt,
            expiresAt: claims.expiresAt,
            signatureKeyID: "primary",
            signature: "valid"
        )
        let service = LicenseService(
            store: InMemorySecureLicenseStateStore(),
            verifier: AlwaysValidOfflineLicenseTokenVerifier(),
            signedTokenVerifier: StaticSignedLicenseTokenVerifier(claims: claims)
        )

        XCTAssertThrowsError(
            try service.state(
                applyingOfflineToken: legacyToken,
                expectedUsername: "",
                expectedEmail: "",
                now: now
            )
        ) { error in
            XCTAssertEqual(error as? ProductOpsError, .licenseIdentityMismatch)
        }
        XCTAssertThrowsError(
            try service.state(
                applyingOfflineSignedToken: "v1.payload.signature",
                expectedUsername: "",
                expectedEmail: "",
                now: now
            )
        ) { error in
            XCTAssertEqual(error as? ProductOpsError, .licenseIdentityMismatch)
        }
    }

    func testLicenseEvaluationRejectsInvalidStoredOfflineTokenInsteadOfFallingBackToActive() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let token = OfflineLicenseToken(
            username: "Ada",
            email: "ada@example.com",
            plan: "pro",
            issuedAt: now.addingTimeInterval(-60),
            expiresAt: now.addingTimeInterval(86_400),
            signatureKeyID: "primary",
            signature: "invalid"
        )
        let state = LicenseState(
            username: token.username,
            email: token.email,
            signedLicenseToken: "mirrored-token",
            plan: token.plan,
            permissions: token.permissions,
            expiresAt: token.expiresAt,
            status: .offlineActive,
            lastValidatedAt: now,
            offlineToken: token
        )
        let service = LicenseService(
            store: InMemorySecureLicenseStateStore(),
            verifier: AlwaysInvalidOfflineLicenseTokenVerifier()
        )

        let evaluated = service.evaluate(state: state, now: now)

        XCTAssertEqual(evaluated.status, .invalid)
        XCTAssertNil(evaluated.graceUntil)
    }

    func testLicenseEvaluationExpiresValidStoredOfflineTokenWithoutGraceFallback() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let token = OfflineLicenseToken(
            username: "Ada",
            email: "ada@example.com",
            plan: "pro",
            issuedAt: now.addingTimeInterval(-86_400),
            expiresAt: now.addingTimeInterval(-1),
            signatureKeyID: "primary",
            signature: "valid"
        )
        let state = LicenseState(
            username: token.username,
            email: token.email,
            plan: token.plan,
            expiresAt: token.expiresAt,
            status: .offlineActive,
            lastValidatedAt: now.addingTimeInterval(-60),
            offlineToken: token
        )
        let service = LicenseService(
            store: InMemorySecureLicenseStateStore(),
            verifier: AlwaysValidOfflineLicenseTokenVerifier()
        )

        let evaluated = service.evaluate(state: state, now: now)

        XCTAssertEqual(evaluated.status, .expired)
        XCTAssertNil(evaluated.graceUntil)
    }

    func testLicenseEvaluationExpiresOfflineTokenAtExactExpirationBoundary() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let token = OfflineLicenseToken(
            username: "Ada",
            email: "ada@example.com",
            plan: "pro",
            issuedAt: now.addingTimeInterval(-86_400),
            expiresAt: now,
            signatureKeyID: "primary",
            signature: "valid"
        )
        let state = LicenseState(
            username: token.username,
            email: token.email,
            plan: token.plan,
            expiresAt: token.expiresAt,
            status: .offlineActive,
            lastValidatedAt: now.addingTimeInterval(-60),
            offlineToken: token
        )
        let service = LicenseService(
            store: InMemorySecureLicenseStateStore(),
            verifier: AlwaysValidOfflineLicenseTokenVerifier()
        )

        let evaluated = service.evaluate(state: state, now: now)

        XCTAssertEqual(evaluated.status, .expired)
        XCTAssertNil(evaluated.graceUntil)
    }

    func testLicenseImportRejectsOfflineTokenAtExactExpirationBoundary() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let token = OfflineLicenseToken(
            username: "Ada",
            email: "ada@example.com",
            plan: "pro",
            issuedAt: now.addingTimeInterval(-86_400),
            expiresAt: now,
            signatureKeyID: "primary",
            signature: "valid"
        )
        let service = LicenseService(
            store: InMemorySecureLicenseStateStore(),
            verifier: AlwaysValidOfflineLicenseTokenVerifier()
        )

        XCTAssertThrowsError(try service.state(applyingOfflineToken: token, now: now)) { error in
            XCTAssertEqual(error as? ProductOpsError, .invalidOfflineLicenseToken)
        }
    }

    func testLicenseEvaluationPreservesBackendExpiredTerminalState() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let state = LicenseState(
            username: "Ada",
            email: "ada@example.com",
            plan: "pro",
            expiresAt: now.addingTimeInterval(-60),
            status: .expired,
            lastValidatedAt: now
        )
        let service = LicenseService(store: InMemorySecureLicenseStateStore())

        let evaluated = service.evaluate(state: state, now: now)

        XCTAssertEqual(evaluated.status, .expired)
        XCTAssertNil(evaluated.graceUntil)
    }

    func testEd25519SignedLicenseTokenVerifierAcceptsBackendTokenAndRejectsTampering() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let claims = SignedLicenseClaims(
            licenseID: "license-1",
            productID: "stacio",
            email: "ada@example.com",
            username: "Ada",
            plan: "pro",
            entitlements: ["remote_sessions"],
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
            offlineGraceSeconds: 1_209_600,
            issuedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let token = try makeSignedLicenseToken(claims: claims, privateKey: privateKey)
        let verifier = Ed25519SignedLicenseTokenVerifier(
            publicKeyBase64: privateKey.publicKey.rawRepresentation.base64EncodedString(),
            expectedProductID: "stacio"
        )

        XCTAssertEqual(try verifier.verifiedClaims(from: token), claims)
        XCTAssertThrowsError(try verifier.verifiedClaims(from: token + "tampered")) { error in
            XCTAssertEqual(error as? ProductOpsError, .invalidSignedLicenseToken)
        }
    }

    func testEd25519LicenseVerifiersAcceptBackendPEMBase64PublicKey() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKeyBase64 = makeBackendPEMBase64PublicKey(
            rawRepresentation: privateKey.publicKey.rawRepresentation
        )
        let claims = SignedLicenseClaims(
            licenseID: "license-1",
            productID: "stacio",
            email: "ada@example.com",
            username: "Ada",
            plan: "pro",
            entitlements: ["remote_sessions"],
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
            offlineGraceSeconds: 1_209_600,
            issuedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let signedToken = try makeSignedLicenseToken(claims: claims, privateKey: privateKey)
        let signedVerifier = Ed25519SignedLicenseTokenVerifier(
            publicKeyBase64: publicKeyBase64,
            expectedProductID: "stacio"
        )
        var legacyToken = OfflineLicenseToken(
            productID: claims.productID,
            username: claims.username,
            email: claims.email,
            plan: claims.plan,
            permissions: claims.entitlements,
            issuedAt: claims.issuedAt,
            expiresAt: claims.expiresAt,
            signatureKeyID: "primary",
            signature: ""
        )
        legacyToken.signature = try privateKey.signature(for: legacyToken.signedPayload()).base64EncodedString()
        let legacyVerifier = Ed25519OfflineLicenseTokenVerifier(
            publicKeyBase64: publicKeyBase64,
            expectedProductID: "stacio"
        )

        XCTAssertEqual(try signedVerifier.verifiedClaims(from: signedToken), claims)
        XCTAssertTrue(legacyVerifier.validate(legacyToken))
    }

    func testLicenseServiceVerifiesSignedOnlineClaimsBeforeSavingActiveState() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let privateKey = Curve25519.Signing.PrivateKey()
        let claims = SignedLicenseClaims(
            licenseID: "license-1",
            productID: "stacio",
            email: "ada@example.com",
            username: "Ada",
            plan: "pro",
            entitlements: ["remote_sessions"],
            expiresAt: now.addingTimeInterval(86_400),
            offlineGraceSeconds: 1_209_600,
            issuedAt: now
        )
        let token = try makeSignedLicenseToken(claims: claims, privateKey: privateKey)
        let store = InMemorySecureLicenseStateStore()
        let service = LicenseService(
            store: store,
            signedTokenVerifier: Ed25519SignedLicenseTokenVerifier(
                publicKeyBase64: privateKey.publicKey.rawRepresentation.base64EncodedString(),
                expectedProductID: "stacio"
            )
        )
        let request = LicenseValidationRequest(
            licenseKey: "STACIO-KEY",
            username: claims.username,
            email: claims.email,
            appVersion: "1",
            buildNumber: "1",
            anonymousDeviceID: "device"
        )
        let response = LicenseValidationResponse(
            username: claims.username,
            email: claims.email,
            signedLicenseToken: token,
            plan: claims.plan,
            permissions: claims.entitlements,
            expiresAt: claims.expiresAt,
            offlineGraceSeconds: claims.offlineGraceSeconds,
            status: .active
        )

        let state = try service.state(applyingOnlineValidation: response, expected: request, now: now)

        XCTAssertEqual(state.status, .active)
        XCTAssertEqual(state.signedLicenseToken, token)
        XCTAssertEqual(store.storedState?.status, .active)
        XCTAssertEqual(store.storedState?.signedLicenseToken, token)
        XCTAssertEqual(
            store.storedState?.graceUntil,
            now.addingTimeInterval(claims.offlineGraceSeconds)
        )
    }

    func testLicenseServiceDerivesOfflineGraceFromSignedIssuedAt() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let claims = SignedLicenseClaims(
            licenseID: "license-1",
            productID: "stacio",
            email: "ada@example.com",
            username: "Ada",
            plan: "pro",
            entitlements: ["remote_sessions"],
            expiresAt: now.addingTimeInterval(86_400),
            offlineGraceSeconds: 7_200,
            issuedAt: now.addingTimeInterval(-3_600)
        )
        let store = InMemorySecureLicenseStateStore()
        let service = LicenseService(
            store: store,
            signedTokenVerifier: StaticSignedLicenseTokenVerifier(claims: claims)
        )
        let request = LicenseValidationRequest(
            licenseKey: "STACIO-KEY",
            username: claims.username,
            email: claims.email,
            appVersion: "1",
            buildNumber: "1",
            anonymousDeviceID: "device"
        )
        let response = LicenseValidationResponse(
            username: claims.username,
            email: claims.email,
            signedLicenseToken: "v1.payload.signature",
            plan: claims.plan,
            permissions: claims.entitlements,
            expiresAt: claims.expiresAt,
            offlineGraceUntil: now.addingTimeInterval(365 * 24 * 60 * 60),
            offlineGraceSeconds: claims.offlineGraceSeconds,
            status: .active
        )

        _ = try service.state(applyingOnlineValidation: response, expected: request, now: now)

        XCTAssertEqual(
            store.storedState?.graceUntil,
            claims.issuedAt.addingTimeInterval(claims.offlineGraceSeconds)
        )
    }

    func testLicenseEvaluationRecomputesOfflineGraceFromVerifiedClaims() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let claims = SignedLicenseClaims(
            licenseID: "license-1",
            productID: "stacio",
            email: "ada@example.com",
            username: "Ada",
            plan: "pro",
            entitlements: ["remote_sessions"],
            expiresAt: now.addingTimeInterval(86_400),
            offlineGraceSeconds: 3_600,
            issuedAt: now.addingTimeInterval(-7_200)
        )
        let state = LicenseState(
            username: claims.username,
            email: claims.email,
            signedLicenseToken: "v1.payload.signature",
            plan: claims.plan,
            permissions: claims.entitlements,
            expiresAt: claims.expiresAt,
            graceUntil: now.addingTimeInterval(365 * 24 * 60 * 60),
            status: .offlineGrace,
            lastValidatedAt: now.addingTimeInterval(-7_200)
        )
        let service = LicenseService(
            store: InMemorySecureLicenseStateStore(),
            signedTokenVerifier: StaticSignedLicenseTokenVerifier(claims: claims)
        )

        let evaluated = service.evaluate(state: state, now: now)

        XCTAssertEqual(evaluated.status, .expired)
        XCTAssertNil(evaluated.graceUntil)
    }

    func testLicenseServiceRejectsSignedClaimsWhenPlanOrPermissionsMismatch() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let privateKey = Curve25519.Signing.PrivateKey()
        let claims = SignedLicenseClaims(
            licenseID: "license-1",
            productID: "stacio",
            email: "ada@example.com",
            username: "Ada",
            plan: "pro",
            entitlements: ["remote_sessions"],
            expiresAt: now.addingTimeInterval(86_400),
            offlineGraceSeconds: 1_209_600,
            issuedAt: now
        )
        let token = try makeSignedLicenseToken(claims: claims, privateKey: privateKey)
        let service = LicenseService(
            store: InMemorySecureLicenseStateStore(),
            signedTokenVerifier: Ed25519SignedLicenseTokenVerifier(
                publicKeyBase64: privateKey.publicKey.rawRepresentation.base64EncodedString(),
                expectedProductID: "stacio"
            )
        )
        let request = LicenseValidationRequest(
            licenseKey: "STACIO-KEY",
            username: claims.username,
            email: claims.email,
            appVersion: "1",
            buildNumber: "1",
            anonymousDeviceID: "device"
        )
        let planMismatch = LicenseValidationResponse(
            username: claims.username,
            email: claims.email,
            signedLicenseToken: token,
            plan: "team",
            permissions: claims.entitlements,
            expiresAt: claims.expiresAt,
            offlineGraceSeconds: claims.offlineGraceSeconds,
            status: .active
        )
        let permissionsMismatch = LicenseValidationResponse(
            username: claims.username,
            email: claims.email,
            signedLicenseToken: token,
            plan: claims.plan,
            permissions: ["remote_sessions", "team_features"],
            expiresAt: claims.expiresAt,
            offlineGraceSeconds: claims.offlineGraceSeconds,
            status: .active
        )

        for response in [planMismatch, permissionsMismatch] {
            XCTAssertThrowsError(
                try service.state(applyingOnlineValidation: response, expected: request, now: now)
            ) { error in
                XCTAssertEqual(error as? ProductOpsError, .licenseClaimsMismatch)
            }
        }
    }

    func testLicenseServiceImportsAndReverifiesBackendSignedOfflineToken() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let privateKey = Curve25519.Signing.PrivateKey()
        let claims = SignedLicenseClaims(
            licenseID: "license-1",
            productID: "stacio",
            email: "ada@example.com",
            username: "Ada",
            plan: "pro",
            entitlements: ["remote_sessions"],
            expiresAt: now.addingTimeInterval(86_400),
            offlineGraceSeconds: 1_209_600,
            issuedAt: now
        )
        let token = try makeSignedLicenseToken(claims: claims, privateKey: privateKey)
        let store = InMemorySecureLicenseStateStore()
        let service = LicenseService(
            store: store,
            signedTokenVerifier: Ed25519SignedLicenseTokenVerifier(
                publicKeyBase64: privateKey.publicKey.rawRepresentation.base64EncodedString(),
                expectedProductID: "stacio"
            )
        )

        let imported = try service.state(
            applyingOfflineSignedToken: token,
            expectedUsername: claims.username,
            expectedEmail: claims.email,
            now: now
        )
        let restored = service.loadState(now: now.addingTimeInterval(60))

        XCTAssertEqual(imported.status, .offlineActive)
        XCTAssertEqual(imported.signedLicenseToken, token)
        XCTAssertEqual(imported.plan, claims.plan)
        XCTAssertEqual(imported.permissions, claims.entitlements)
        XCTAssertNil(imported.offlineToken)
        XCTAssertEqual(store.storedState?.status, .offlineActive)
        XCTAssertEqual(
            store.storedState?.graceUntil,
            claims.issuedAt.addingTimeInterval(claims.offlineGraceSeconds)
        )
        XCTAssertEqual(restored.status, .offlineActive)
    }

    func testLicenseServiceRejectsBackendSignedOfflineTokenAtExpirationBoundary() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let privateKey = Curve25519.Signing.PrivateKey()
        let claims = SignedLicenseClaims(
            licenseID: "license-1",
            productID: "stacio",
            email: "ada@example.com",
            username: "Ada",
            plan: "pro",
            entitlements: ["remote_sessions"],
            expiresAt: now,
            offlineGraceSeconds: 1_209_600,
            issuedAt: now.addingTimeInterval(-60)
        )
        let token = try makeSignedLicenseToken(claims: claims, privateKey: privateKey)
        let service = LicenseService(
            store: InMemorySecureLicenseStateStore(),
            signedTokenVerifier: Ed25519SignedLicenseTokenVerifier(
                publicKeyBase64: privateKey.publicKey.rawRepresentation.base64EncodedString(),
                expectedProductID: "stacio"
            )
        )

        XCTAssertThrowsError(
            try service.state(
                applyingOfflineSignedToken: token,
                expectedUsername: claims.username,
                expectedEmail: claims.email,
                now: now
            )
        ) { error in
            XCTAssertEqual(error as? ProductOpsError, .invalidOfflineLicenseToken)
        }
    }

    func testLicenseEvaluationReverifiesStoredOnlineTokenBeforeRestoringActiveState() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let state = LicenseState(
            username: "Ada",
            email: "ada@example.com",
            signedLicenseToken: "tampered-token",
            plan: "pro",
            permissions: ["remote_sessions"],
            expiresAt: now.addingTimeInterval(86_400),
            status: .active,
            lastValidatedAt: now
        )
        let service = LicenseService(
            store: InMemorySecureLicenseStateStore(),
            signedTokenVerifier: AlwaysRejectSignedLicenseTokenVerifier()
        )

        let evaluated = service.evaluate(state: state, now: now)

        XCTAssertEqual(evaluated.status, .invalid)
        XCTAssertNil(evaluated.graceUntil)
    }

    func testKeychainLicenseStateStoreMigratesLegacyDefaultsAndClearsPlaintextState() throws {
        let defaults = try makeProductOpsSecurityDefaults()
        let backend = InMemoryKeychainBackend()
        let store = KeychainLicenseStateStore(
            credentialStore: KeychainCredentialStore(backend: backend),
            defaults: defaults
        )
        let state = LicenseState(
            username: "Ada",
            email: "ada@example.com",
            signedLicenseToken: "signed-token",
            plan: "pro",
            permissions: ["remote_sessions"],
            expiresAt: nil,
            graceUntil: nil,
            status: .active,
            lastValidatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            offlineToken: nil
        )
        defaults.set(
            try JSONEncoder.productOps.encode(state),
            forKey: KeychainLicenseStateStore.legacyDefaultsKey
        )

        let loaded = try store.load()

        XCTAssertEqual(loaded, state)
        XCTAssertNil(defaults.data(forKey: KeychainLicenseStateStore.legacyDefaultsKey))
        let savedSecret = try KeychainCredentialStore(backend: backend).readSecret(
            id: KeychainLicenseStateStore.credentialID,
            account: KeychainLicenseStateStore.account
        )
        XCTAssertTrue(savedSecret.contains("signed-token"))
    }

    func testEd25519OfflineLicenseVerifierRejectsMismatchedProductAndAcceptsValidSignature() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        var token = OfflineLicenseToken(
            productID: "stacio",
            username: "Ada",
            email: "ada@example.com",
            plan: "pro",
            permissions: ["remote_sessions"],
            issuedAt: Date(timeIntervalSince1970: 1_700_000_000),
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
            signedLicenseToken: "offline-signed-token",
            signatureKeyID: "primary",
            signature: ""
        )
        token.signature = try privateKey.signature(for: token.signedPayload()).base64EncodedString()
        let verifier = Ed25519OfflineLicenseTokenVerifier(
            publicKeyBase64: privateKey.publicKey.rawRepresentation.base64EncodedString(),
            expectedProductID: "stacio"
        )

        XCTAssertTrue(verifier.validate(token))
        token.productID = "another-product"
        XCTAssertFalse(verifier.validate(token))
    }

    func testSparkleConfigurationUsesManualChecksAndChannelSpecificAppcasts() throws {
        let configuration = ProductOpsConfiguration(
            apiBaseURL: try XCTUnwrap(URL(string: "https://ops.example.test")),
            updateChannel: .beta,
            betaUpdatesEnabled: true,
            stableAppcastURL: try XCTUnwrap(URL(string: "https://ops.stacio.cn/updates/stacio/stable/appcast.xml")),
            betaAppcastURL: try XCTUnwrap(URL(string: "https://ops.stacio.cn/updates/stacio/beta/appcast.xml")),
            sparklePublicEDKey: "public-ed-key"
        )

        let sparkle = SparkleUpdateConfiguration(configuration: configuration)

        XCTAssertFalse(sparkle.automaticallyChecksForUpdates)
        XCTAssertEqual(sparkle.feedURL?.absoluteString, "https://ops.stacio.cn/updates/stacio/beta/appcast.xml")
        XCTAssertEqual(sparkle.publicEDKey, "public-ed-key")
    }

    func testInstalledReleaseNotesRequireBothVersionAndBuildToMatch() throws {
        let defaults = try makeProductOpsSecurityDefaults()
        let store = InstalledUpdateReleaseNotesStore(defaults: defaults)
        store.savePendingNotes(
            version: "0.14.0",
            build: "1",
            releaseNotes: "Release notes"
        )

        XCTAssertNil(store.pendingNotesMatching(version: "0.13.2-Beta", build: "1"))
        XCTAssertNil(store.pendingNotesMatching(version: "0.14.0", build: "2"))
        XCTAssertEqual(
            store.pendingNotesMatching(version: "0.14.0", build: "1")?.releaseNotes,
            "Release notes"
        )
    }

    @MainActor
    func testSparkleDismissKeepsCommittedReleaseNotesForNextLaunch() throws {
        let defaults = try makeProductOpsSecurityDefaults()
        let releaseNotesStore = InstalledUpdateReleaseNotesStore(defaults: defaults)
        releaseNotesStore.savePendingNotes(
            version: "0.14.0",
            build: "1",
            releaseNotes: "Release notes"
        )
        let controller = SparkleUpdateController(
            configurationStore: ProductOpsConfigurationStore(
                defaults: defaults,
                environment: [:],
                bundleInfo: [:]
            ),
            releaseNotesStore: releaseNotesStore
        )
        let userDriver = StacioSparkleUserDriver(controller: controller)

        userDriver.dismissUpdateInstallation()

        XCTAssertEqual(
            releaseNotesStore.pendingNotesMatching(version: "0.14.0", build: "1")?.releaseNotes,
            "Release notes"
        )
    }

    @MainActor
    func testDuplicateSparkleErrorCallbackDoesNotHideVisibleFailure() throws {
        let defaults = try makeProductOpsSecurityDefaults()
        let controller = SparkleUpdateController(
            configurationStore: ProductOpsConfigurationStore(
                defaults: defaults,
                environment: [:],
                bundleInfo: [:]
            ),
            releaseNotesStore: InstalledUpdateReleaseNotesStore(defaults: defaults)
        )
        controller.publish(.failed("Download failed"))

        controller.handleUpdaterError(NSError(
            domain: "Stacio.ProductOpsTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Download failed"]
        ))

        XCTAssertEqual(controller.buttonState, .failed("Download failed"))
    }

    @MainActor
    func testBusySparkleUpdaterIgnoresReentrantProbeWithoutClearingActiveInstall() throws {
        let defaults = try makeProductOpsSecurityDefaults()
        let updater = RecordingSparkleUpdaterDriver()
        let controller = SparkleUpdateController(
            configurationStore: ProductOpsConfigurationStore(
                defaults: defaults,
                environment: [:],
                bundleInfo: [:]
            ),
            releaseNotesStore: InstalledUpdateReleaseNotesStore(defaults: defaults),
            updaterFactory: { _, _, _ in updater }
        )
        controller.installAvailableUpdateFromPrompt()
        updater.sessionInProgress = true

        controller.checkForUpdateInformation(nil)

        XCTAssertEqual(controller.buttonState, .downloading(progress: nil))
        XCTAssertEqual(updater.installCheckCount, 1)
        XCTAssertEqual(updater.informationCheckCount, 0)

        controller.handleUpdaterError(NSError(
            domain: "Stacio.ProductOpsTests",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Download failed"]
        ))
        XCTAssertEqual(controller.buttonState, .failed("Download failed"))
    }

    @MainActor
    func testUnavailableSparkleUpdaterIgnoresReentrantInstallWithoutClearingActiveInstall() throws {
        let defaults = try makeProductOpsSecurityDefaults()
        let updater = RecordingSparkleUpdaterDriver()
        let controller = SparkleUpdateController(
            configurationStore: ProductOpsConfigurationStore(
                defaults: defaults,
                environment: [:],
                bundleInfo: [:]
            ),
            releaseNotesStore: InstalledUpdateReleaseNotesStore(defaults: defaults),
            updaterFactory: { _, _, _ in updater }
        )
        controller.installAvailableUpdateFromPrompt()
        updater.canCheckForUpdates = false

        controller.installAvailableUpdateFromPrompt()

        XCTAssertEqual(controller.buttonState, .downloading(progress: nil))
        XCTAssertEqual(updater.installCheckCount, 1)

        controller.handleUpdaterError(NSError(
            domain: "Stacio.ProductOpsTests",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "Download failed"]
        ))
        XCTAssertEqual(controller.buttonState, .failed("Download failed"))
    }

    @MainActor
    func testLocalInstallStateBlocksReentryWhenSparkleTemporarilyReportsAvailable() throws {
        let defaults = try makeProductOpsSecurityDefaults()
        let updater = RecordingSparkleUpdaterDriver()
        let controller = SparkleUpdateController(
            configurationStore: ProductOpsConfigurationStore(
                defaults: defaults,
                environment: [:],
                bundleInfo: [:]
            ),
            releaseNotesStore: InstalledUpdateReleaseNotesStore(defaults: defaults),
            updaterFactory: { _, _, _ in updater }
        )
        controller.installAvailableUpdateFromPrompt()
        XCTAssertFalse(updater.sessionInProgress)
        XCTAssertTrue(updater.canCheckForUpdates)

        controller.checkForUpdateInformation(nil)
        controller.installAvailableUpdateFromPrompt()

        XCTAssertEqual(controller.buttonState, .downloading(progress: nil))
        XCTAssertEqual(updater.installCheckCount, 1)
        XCTAssertEqual(updater.informationCheckCount, 0)
    }

    @MainActor
    func testUpdateMenuRequestsInformationWithoutStartingInstallation() {
        let checker = RecordingInformationOnlySparkleChecker()
        let delegate = AppDelegate(
            factory: { NoopProductOpsWorkbench() },
            runningTunnelTerminationConfirmation: AllowProductOpsTermination(),
            sparkleUpdateChecker: checker
        )

        delegate.showUpdateCheckWindow(nil)

        XCTAssertEqual(checker.informationCheckCount, 1)
        XCTAssertEqual(checker.installCheckCount, 0)
    }

    func testUpdateSuppressionAppliesOnlyToLaunchChecksAndExactVersion() throws {
        let defaults = try makeProductOpsSecurityDefaults()
        let store = SparkleUpdateSuppressionStore(defaults: defaults)
        let update = SparkleUpdatePromptInfo(
            version: "0.14.0",
            build: "50",
            releaseNotes: "Release notes",
            packageSize: 12_000_000
        )
        let newerUpdate = SparkleUpdatePromptInfo(
            version: "0.14.1",
            build: "51",
            releaseNotes: "Newer release notes",
            packageSize: 13_000_000
        )

        store.skip(update)

        XCTAssertTrue(store.shouldSuppress(update, origin: .launch, now: Date()))
        XCTAssertFalse(store.shouldSuppress(update, origin: .manual, now: Date()))
        XCTAssertFalse(store.shouldSuppress(newerUpdate, origin: .launch, now: Date()))
    }

    func testRemindLaterSuppressionExpires() throws {
        let defaults = try makeProductOpsSecurityDefaults()
        let store = SparkleUpdateSuppressionStore(defaults: defaults)
        let update = SparkleUpdatePromptInfo(version: "999.0.0", build: "50")
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        store.remindLater(update, until: now.addingTimeInterval(3_600))

        XCTAssertTrue(store.shouldSuppress(update, origin: .launch, now: now))
        XCTAssertFalse(store.shouldSuppress(update, origin: .launch, now: now.addingTimeInterval(3_601)))
    }

    @MainActor
    func testManualProbeFailureReportsVisibleResultWithoutShowingTitlebarButton() throws {
        let defaults = try makeProductOpsSecurityDefaults()
        let updater = RecordingSparkleUpdaterDriver()
        let controller = SparkleUpdateController(
            configurationStore: ProductOpsConfigurationStore(
                defaults: defaults,
                environment: [:],
                bundleInfo: [:]
            ),
            releaseNotesStore: InstalledUpdateReleaseNotesStore(defaults: defaults),
            updaterFactory: { _, _, _ in updater }
        )
        var states: [SparkleManualUpdateCheckState] = []

        controller.checkForUpdateInformation(nil) { states.append($0) }
        controller.handleUpdaterError(NSError(
            domain: "Stacio.ProductOpsTests",
            code: 4,
            userInfo: [NSLocalizedDescriptionKey: "Appcast unavailable"]
        ))

        XCTAssertEqual(states, [.checking, .failed("Appcast unavailable")])
        XCTAssertEqual(controller.buttonState, .hidden)
        XCTAssertEqual(updater.informationCheckCount, 0)
        XCTAssertEqual(updater.installCheckCount, 1)
    }

    @MainActor
    func testManualProbeStartFailureReportsSparkleErrorInsteadOfBusyMessage() throws {
        let defaults = try makeProductOpsSecurityDefaults()
        let updater = RecordingSparkleUpdaterDriver()
        updater.startError = NSError(
            domain: "Stacio.ProductOpsTests",
            code: 5,
            userInfo: [NSLocalizedDescriptionKey: "Sparkle could not start"]
        )
        let controller = SparkleUpdateController(
            configurationStore: ProductOpsConfigurationStore(
                defaults: defaults,
                environment: [:],
                bundleInfo: [:]
            ),
            releaseNotesStore: InstalledUpdateReleaseNotesStore(defaults: defaults),
            updaterFactory: { _, _, _ in updater }
        )
        var states: [SparkleManualUpdateCheckState] = []

        controller.checkForUpdateInformation(nil) { states.append($0) }

        XCTAssertEqual(states, [.checking, .failed("Sparkle could not start")])
        XCTAssertEqual(controller.buttonState, .hidden)
        XCTAssertEqual(updater.startCount, 1)
        XCTAssertEqual(updater.informationCheckCount, 0)
        XCTAssertEqual(updater.installCheckCount, 0)
    }

    @MainActor
    func testLaunchProbeRetriesWhenUpdaterCouldNotStartOnFirstAttempt() throws {
        let defaults = try makeProductOpsSecurityDefaults()
        let updater = RecordingSparkleUpdaterDriver()
        updater.startError = NSError(
            domain: "Stacio.ProductOpsTests",
            code: 7,
            userInfo: [NSLocalizedDescriptionKey: "Sparkle unavailable"]
        )
        let controller = SparkleUpdateController(
            configurationStore: ProductOpsConfigurationStore(defaults: defaults, environment: [:], bundleInfo: [:]),
            releaseNotesStore: InstalledUpdateReleaseNotesStore(defaults: defaults),
            updaterFactory: { _, _, _ in updater }
        )

        controller.probeForAvailableUpdate()
        updater.startError = nil
        controller.probeForAvailableUpdate()

        XCTAssertEqual(updater.startCount, 2)
        XCTAssertEqual(updater.informationCheckCount, 1)
    }

    @MainActor
    func testLaunchProbeHonorsSuppressionWhileManualProbeStillReportsUpdate() throws {
        let defaults = try makeProductOpsSecurityDefaults()
        let updater = RecordingSparkleUpdaterDriver()
        let suppressionStore = SparkleUpdateSuppressionStore(defaults: defaults)
        let update = SparkleUpdatePromptInfo(
            version: "999.0.0",
            build: "50",
            releaseNotes: "Release notes",
            packageSize: 12_000_000
        )
        suppressionStore.skip(update)
        let controller = SparkleUpdateController(
            configurationStore: ProductOpsConfigurationStore(defaults: defaults, environment: [:], bundleInfo: [:]),
            releaseNotesStore: InstalledUpdateReleaseNotesStore(defaults: defaults),
            updaterFactory: { _, _, _ in updater },
            suppressionStore: suppressionStore
        )

        controller.probeForAvailableUpdate()
        controller.processDiscoveredUpdateForTesting(update)
        XCTAssertEqual(controller.buttonState, .hidden)

        var manualStates: [SparkleManualUpdateCheckState] = []
        controller.checkForUpdateInformation(nil) { manualStates.append($0) }
        controller.processDiscoveredUpdateForTesting(update)

        XCTAssertEqual(manualStates, [.checking, .available(update)])
        XCTAssertEqual(controller.buttonState, .hidden)
        XCTAssertEqual(updater.informationCheckCount, 1)
        XCTAssertEqual(updater.installCheckCount, 1)
    }

    @MainActor
    func testManualCheckUsesUserInitiatedSparklePathAndDismissesItsBuiltInPrompt() throws {
        let defaults = try makeProductOpsSecurityDefaults()
        let updater = RecordingSparkleUpdaterDriver()
        let suppressionStore = SparkleUpdateSuppressionStore(defaults: defaults)
        let presenter = RecordingSparkleUpdateConfirmationPresenter(
            availableChoice: .download,
            confirmsInstallAndRelaunch: false
        )
        let update = SparkleUpdatePromptInfo(
            version: "999.0.0",
            build: "50",
            releaseNotes: "Release notes"
        )
        suppressionStore.skip(update)
        let controller = SparkleUpdateController(
            configurationStore: ProductOpsConfigurationStore(defaults: defaults, environment: [:], bundleInfo: [:]),
            releaseNotesStore: InstalledUpdateReleaseNotesStore(defaults: defaults),
            updaterFactory: { _, _, _ in updater },
            suppressionStore: suppressionStore,
            confirmationPresenter: presenter
        )
        var states: [SparkleManualUpdateCheckState] = []

        controller.checkForUpdateInformation(nil) { states.append($0) }
        controller.processDiscoveredUpdateForTesting(update)
        let sparkleChoice = controller.resolveAvailableUpdateChoiceForTesting(
            update,
            stage: .notDownloaded
        )

        XCTAssertEqual(updater.informationCheckCount, 0)
        XCTAssertEqual(updater.installCheckCount, 1)
        XCTAssertEqual(states, [.checking, .available(update)])
        XCTAssertEqual(sparkleChoice, .dismiss)
        XCTAssertEqual(presenter.availableChoiceCount, 0)
        XCTAssertEqual(controller.buttonState, .hidden)
    }

    @MainActor
    func testUpdateActionsPersistSuppressionAndPreconfirmedDownloadClearsIt() throws {
        let defaults = try makeProductOpsSecurityDefaults()
        let updater = RecordingSparkleUpdaterDriver()
        let suppressionStore = SparkleUpdateSuppressionStore(defaults: defaults)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let update = SparkleUpdatePromptInfo(version: "999.0.0", build: "50")
        let controller = SparkleUpdateController(
            configurationStore: ProductOpsConfigurationStore(defaults: defaults, environment: [:], bundleInfo: [:]),
            releaseNotesStore: InstalledUpdateReleaseNotesStore(defaults: defaults),
            updaterFactory: { _, _, _ in updater },
            suppressionStore: suppressionStore,
            nowProvider: { now }
        )

        controller.remindLater(update)
        XCTAssertTrue(suppressionStore.shouldSuppress(update, origin: .launch, now: now))

        controller.skip(update)
        XCTAssertTrue(suppressionStore.shouldSuppress(update, origin: .launch, now: now.addingTimeInterval(90_000)))

        controller.downloadUpdate(update)
        XCTAssertFalse(suppressionStore.shouldSuppress(update, origin: .launch, now: now))
        XCTAssertEqual(updater.installCheckCount, 1)
    }

    @MainActor
    func testDownloadStartFailureClearsPreconfirmedUpdateForFuturePrompt() throws {
        let defaults = try makeProductOpsSecurityDefaults()
        let updater = RecordingSparkleUpdaterDriver()
        let presenter = RecordingSparkleUpdateConfirmationPresenter(
            availableChoice: .later,
            confirmsInstallAndRelaunch: false
        )
        let update = SparkleUpdatePromptInfo(version: "999.0.0", build: "50")
        let controller = SparkleUpdateController(
            configurationStore: ProductOpsConfigurationStore(defaults: defaults, environment: [:], bundleInfo: [:]),
            releaseNotesStore: InstalledUpdateReleaseNotesStore(defaults: defaults),
            updaterFactory: { _, _, _ in updater },
            confirmationPresenter: presenter
        )
        updater.startError = NSError(
            domain: "Stacio.ProductOpsTests",
            code: 6,
            userInfo: [NSLocalizedDescriptionKey: "Sparkle start failed"]
        )

        controller.downloadUpdate(update)
        updater.startError = nil
        let choice: SPUUserUpdateChoice = controller.resolveAvailableUpdateChoiceForTesting(
            update,
            stage: .notDownloaded
        )

        XCTAssertEqual(choice, .dismiss)
        XCTAssertEqual(presenter.availableChoiceCount, 1)
        XCTAssertEqual(controller.buttonState, .hidden)
        XCTAssertEqual(updater.installCheckCount, 0)
    }

    @MainActor
    func testSuccessfulInstallUpdateCycleClearsActiveCheckForLaterManualProbe() throws {
        let defaults = try makeProductOpsSecurityDefaults()
        let updater = RecordingSparkleUpdaterDriver()
        let controller = SparkleUpdateController(
            configurationStore: ProductOpsConfigurationStore(defaults: defaults, environment: [:], bundleInfo: [:]),
            releaseNotesStore: InstalledUpdateReleaseNotesStore(defaults: defaults),
            updaterFactory: { _, _, _ in updater }
        )

        controller.installAvailableUpdateFromPrompt()
        controller.finishUpdateCycleForTesting(updateCheck: .updates, error: nil)
        controller.checkForUpdateInformation(nil)

        XCTAssertEqual(updater.installCheckCount, 2)
        XCTAssertEqual(updater.informationCheckCount, 0)
    }

    @MainActor
    func testInformationOnlyUpdateDismissesWithoutShowingDownloadButton() throws {
        let defaults = try makeProductOpsSecurityDefaults()
        let controller = SparkleUpdateController(
            configurationStore: ProductOpsConfigurationStore(defaults: defaults, environment: [:], bundleInfo: [:]),
            releaseNotesStore: InstalledUpdateReleaseNotesStore(defaults: defaults)
        )

        let choice = controller.handleInformationOnlyUpdateForTesting()

        XCTAssertEqual(choice, .dismiss)
        XCTAssertEqual(controller.buttonState, .failed("该更新只包含说明，无法在应用内安装。"))
    }

    @MainActor
    func testInformationOnlyLaunchProbeStaysHiddenWhileManualCheckReportsNotInstallable() throws {
        let defaults = try makeProductOpsSecurityDefaults()
        let updater = RecordingSparkleUpdaterDriver()
        let controller = SparkleUpdateController(
            configurationStore: ProductOpsConfigurationStore(defaults: defaults, environment: [:], bundleInfo: [:]),
            releaseNotesStore: InstalledUpdateReleaseNotesStore(defaults: defaults),
            updaterFactory: { _, _, _ in updater }
        )
        let update = SparkleUpdatePromptInfo(version: "999.0.0", build: "50")

        controller.probeForAvailableUpdate()
        controller.processDiscoveredUpdateForTesting(update, isInformationOnly: true)
        let launchUserDriverChoice = controller.handleInformationOnlyUpdateForTesting()
        XCTAssertEqual(launchUserDriverChoice, .dismiss)
        XCTAssertEqual(controller.buttonState, .hidden)

        var manualStates: [SparkleManualUpdateCheckState] = []
        controller.checkForUpdateInformation(nil) { manualStates.append($0) }
        controller.processDiscoveredUpdateForTesting(update, isInformationOnly: true)

        XCTAssertEqual(manualStates, [.checking, .failed("该更新只包含说明，无法在应用内安装。")])
        XCTAssertEqual(controller.buttonState, .hidden)
        XCTAssertEqual(updater.informationCheckCount, 1)
        XCTAssertEqual(updater.installCheckCount, 1)
    }

    @MainActor
    func testEmptyAppcastIsReportedAsAnExplicitManualCheckFailure() throws {
        let defaults = try makeProductOpsSecurityDefaults()
        let updater = RecordingSparkleUpdaterDriver()
        let controller = SparkleUpdateController(
            configurationStore: ProductOpsConfigurationStore(defaults: defaults, environment: [:], bundleInfo: [:]),
            releaseNotesStore: InstalledUpdateReleaseNotesStore(defaults: defaults),
            updaterFactory: { _, _, _ in updater }
        )
        let userDriver = StacioSparkleUserDriver(controller: controller)
        let error = makeSparkleNoUpdateError(reason: .onLatestVersion, includesLatestItem: false)
        var states: [SparkleManualUpdateCheckState] = []
        var acknowledged = false

        controller.checkForUpdateInformation(nil) { states.append($0) }
        userDriver.showUpdateNotFoundWithError(error) { acknowledged = true }

        XCTAssertTrue(acknowledged)
        XCTAssertEqual(states, [.checking, .failed("Appcast 未包含当前更新通道的可用版本。")])
        XCTAssertEqual(controller.buttonState, .hidden)
    }

    @MainActor
    func testNoUpdateReasonDistinguishesLatestVersionFromUnsupportedSystem() throws {
        let defaults = try makeProductOpsSecurityDefaults()
        let updater = RecordingSparkleUpdaterDriver()
        let controller = SparkleUpdateController(
            configurationStore: ProductOpsConfigurationStore(defaults: defaults, environment: [:], bundleInfo: [:]),
            releaseNotesStore: InstalledUpdateReleaseNotesStore(defaults: defaults),
            updaterFactory: { _, _, _ in updater }
        )
        let userDriver = StacioSparkleUserDriver(controller: controller)
        var latestStates: [SparkleManualUpdateCheckState] = []

        controller.checkForUpdateInformation(nil) { latestStates.append($0) }
        userDriver.showUpdateNotFoundWithError(
            makeSparkleNoUpdateError(reason: .onLatestVersion, includesLatestItem: true),
            acknowledgement: {}
        )

        XCTAssertEqual(latestStates, [.checking, .upToDate])

        var unsupportedStates: [SparkleManualUpdateCheckState] = []
        controller.checkForUpdateInformation(nil) { unsupportedStates.append($0) }
        userDriver.showUpdateNotFoundWithError(
            makeSparkleNoUpdateError(reason: .systemIsTooOld, includesLatestItem: true),
            acknowledgement: {}
        )

        XCTAssertEqual(
            unsupportedStates,
            [.checking, .failed("当前 macOS 版本过低，无法安装可用更新。")]
        )

        let additionalUnsupportedCases: [(SPUNoUpdateFoundReason, String)] = [
            (.systemIsTooNew, "当前 macOS 版本过高，无法安装可用更新。"),
            (.hardwareDoesNotSupportARM64, "当前 Mac 的硬件架构不支持可用更新。")
        ]
        for (reason, expectedMessage) in additionalUnsupportedCases {
            var states: [SparkleManualUpdateCheckState] = []
            controller.checkForUpdateInformation(nil) { states.append($0) }
            userDriver.showUpdateNotFoundWithError(
                makeSparkleNoUpdateError(reason: reason, includesLatestItem: true),
                acknowledgement: {}
            )
            XCTAssertEqual(states, [.checking, .failed(expectedMessage)])
        }
    }

    @MainActor
    func testReadyToInstallDoesNotRelaunchWithoutSecondConfirmation() throws {
        let defaults = try makeProductOpsSecurityDefaults()
        let updater = RecordingSparkleUpdaterDriver()
        let suppressionStore = SparkleUpdateSuppressionStore(defaults: defaults)
        let presenter = RecordingSparkleUpdateConfirmationPresenter(
            availableChoice: .download,
            confirmsInstallAndRelaunch: false
        )
        let update = SparkleUpdatePromptInfo(version: "999.0.0", build: "50")
        let controller = SparkleUpdateController(
            configurationStore: ProductOpsConfigurationStore(defaults: defaults, environment: [:], bundleInfo: [:]),
            releaseNotesStore: InstalledUpdateReleaseNotesStore(defaults: defaults),
            updaterFactory: { _, _, _ in updater },
            suppressionStore: suppressionStore,
            confirmationPresenter: presenter
        )
        controller.processDiscoveredUpdateForTesting(update)
        let userDriver = StacioSparkleUserDriver(controller: controller)
        var selectedChoice: SPUUserUpdateChoice?

        userDriver.showReady(toInstallAndRelaunch: { selectedChoice = $0 })

        XCTAssertEqual(selectedChoice, .skip)
        XCTAssertEqual(presenter.installConfirmationCount, 1)
        XCTAssertTrue(suppressionStore.shouldSuppress(update, origin: .launch, now: Date()))
        XCTAssertEqual(controller.buttonState, .hidden)
    }

    @MainActor
    func testInstallingUpdateRetriesTerminationOnlyAfterExplicitConfirmation() throws {
        let defaults = try makeProductOpsSecurityDefaults()
        let presenter = RecordingSparkleUpdateConfirmationPresenter(
            availableChoice: .later,
            confirmsInstallAndRelaunch: false,
            confirmsTerminationRetry: true
        )
        let controller = SparkleUpdateController(
            configurationStore: ProductOpsConfigurationStore(defaults: defaults, environment: [:], bundleInfo: [:]),
            releaseNotesStore: InstalledUpdateReleaseNotesStore(defaults: defaults),
            confirmationPresenter: presenter
        )
        let userDriver = StacioSparkleUserDriver(controller: controller)
        var retryCount = 0

        userDriver.showInstallingUpdate(
            withApplicationTerminated: false,
            retryTerminatingApplication: { retryCount += 1 }
        )

        XCTAssertEqual(presenter.terminationRetryConfirmationCount, 1)
        XCTAssertEqual(retryCount, 1)
        XCTAssertEqual(controller.buttonState, .installing)
    }

    @MainActor
    func testInstallingUpdateLeavesInstallingStateWhenTerminationRetryIsDeclined() throws {
        let defaults = try makeProductOpsSecurityDefaults()
        let updater = RecordingSparkleUpdaterDriver()
        let presenter = RecordingSparkleUpdateConfirmationPresenter(
            availableChoice: .later,
            confirmsInstallAndRelaunch: false,
            confirmsTerminationRetry: false,
            terminationRetryConfirmations: [false, true]
        )
        let controller = SparkleUpdateController(
            configurationStore: ProductOpsConfigurationStore(defaults: defaults, environment: [:], bundleInfo: [:]),
            releaseNotesStore: InstalledUpdateReleaseNotesStore(defaults: defaults),
            updaterFactory: { _, _, _ in updater },
            confirmationPresenter: presenter
        )
        let userDriver = StacioSparkleUserDriver(controller: controller)
        var retryCount = 0

        controller.installAvailableUpdateFromPrompt()
        updater.sessionInProgress = true
        userDriver.showInstallingUpdate(
            withApplicationTerminated: false,
            retryTerminatingApplication: { retryCount += 1 }
        )

        XCTAssertEqual(presenter.terminationRetryConfirmationCount, 1)
        XCTAssertEqual(retryCount, 0)
        XCTAssertEqual(controller.buttonState, .failed("Stacio 未能退出，更新安装已暂停。"))

        controller.installAvailableUpdateFromPrompt()

        XCTAssertEqual(presenter.terminationRetryConfirmationCount, 2)
        XCTAssertEqual(retryCount, 1)
        XCTAssertEqual(updater.installCheckCount, 1)
        XCTAssertEqual(controller.buttonState, .installing)
    }

    @MainActor
    func testTerminationRetryIsDiscardedAfterUpdateCycleFails() throws {
        let defaults = try makeProductOpsSecurityDefaults()
        let updater = RecordingSparkleUpdaterDriver()
        let presenter = RecordingSparkleUpdateConfirmationPresenter(
            availableChoice: .later,
            confirmsInstallAndRelaunch: false,
            confirmsTerminationRetry: false,
            terminationRetryConfirmations: [false, true]
        )
        let controller = SparkleUpdateController(
            configurationStore: ProductOpsConfigurationStore(defaults: defaults, environment: [:], bundleInfo: [:]),
            releaseNotesStore: InstalledUpdateReleaseNotesStore(defaults: defaults),
            updaterFactory: { _, _, _ in updater },
            confirmationPresenter: presenter
        )
        let userDriver = StacioSparkleUserDriver(controller: controller)
        var staleRetryCount = 0

        controller.installAvailableUpdateFromPrompt()
        userDriver.showInstallingUpdate(
            withApplicationTerminated: false,
            retryTerminatingApplication: { staleRetryCount += 1 }
        )
        controller.handleUpdaterError(NSError(
            domain: "Stacio.ProductOpsTests",
            code: 8,
            userInfo: [NSLocalizedDescriptionKey: "Installation failed"]
        ))
        controller.installAvailableUpdateFromPrompt()

        XCTAssertEqual(staleRetryCount, 0)
        XCTAssertEqual(presenter.terminationRetryConfirmationCount, 1)
        XCTAssertEqual(updater.installCheckCount, 2)
        XCTAssertEqual(controller.buttonState, .downloading(progress: nil))
    }

    @MainActor
    func testUnrelatedUpdateFailureDoesNotEraseCommittedReleaseNotes() throws {
        let defaults = try makeProductOpsSecurityDefaults()
        let store = InstalledUpdateReleaseNotesStore(defaults: defaults)
        let updater = RecordingSparkleUpdaterDriver()
        store.savePendingNotes(
            version: "0.14.0",
            build: "50",
            releaseNotes: "Already committed notes"
        )
        let controller = SparkleUpdateController(
            configurationStore: ProductOpsConfigurationStore(defaults: defaults, environment: [:], bundleInfo: [:]),
            releaseNotesStore: store,
            updaterFactory: { _, _, _ in updater }
        )

        controller.installAvailableUpdateFromPrompt()
        controller.handleUpdaterError(NSError(
            domain: "Stacio.ProductOpsTests",
            code: 9,
            userInfo: [NSLocalizedDescriptionKey: "Unrelated failure"]
        ))

        XCTAssertEqual(
            store.pendingNotesMatching(version: "0.14.0", build: "50")?.releaseNotes,
            "Already committed notes"
        )
    }

    @MainActor
    func testApplicationBlocksQuitBeforeSparkleInstallConfirmation() throws {
        let defaults = try makeProductOpsSecurityDefaults()
        let controller = SparkleUpdateController(
            configurationStore: ProductOpsConfigurationStore(defaults: defaults, environment: [:], bundleInfo: [:]),
            releaseNotesStore: InstalledUpdateReleaseNotesStore(defaults: defaults)
        )
        let delegate = AppDelegate(
            factory: { NoopProductOpsWorkbench() },
            runningTunnelTerminationConfirmation: AllowProductOpsTermination(),
            sparkleUpdateChecker: controller
        )

        controller.publish(.downloading(progress: 0.5))
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateCancel)

        controller.publish(.extracting(progress: 0.5))
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateCancel)

        controller.publish(.installing)
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateNow)
    }

    @MainActor
    func testInstalledWithoutRelaunchShowsExplicitCompletionMessage() throws {
        let defaults = try makeProductOpsSecurityDefaults()
        let presenter = RecordingSparkleUpdateConfirmationPresenter(
            availableChoice: .later,
            confirmsInstallAndRelaunch: false
        )
        let controller = SparkleUpdateController(
            configurationStore: ProductOpsConfigurationStore(defaults: defaults, environment: [:], bundleInfo: [:]),
            releaseNotesStore: InstalledUpdateReleaseNotesStore(defaults: defaults),
            confirmationPresenter: presenter
        )
        let userDriver = StacioSparkleUserDriver(controller: controller)
        var acknowledged = false

        userDriver.showUpdateInstalledAndRelaunched(false) { acknowledged = true }

        XCTAssertTrue(acknowledged)
        XCTAssertEqual(presenter.installCompletedWithoutRelaunchCount, 1)
        XCTAssertEqual(controller.buttonState, .hidden)
    }
}

private final class SequencedProductOpsHTTPClient: ProductOpsHTTPClient {
    enum Result {
        case success(Data, HTTPURLResponse)
        case failure(Error)
    }

    private var results: [Result]
    private(set) var requests: [URLRequest] = []

    init(results: [Result]) {
        self.results = results
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard results.isEmpty == false else {
            throw URLError(.badServerResponse)
        }
        switch results.removeFirst() {
        case .success(let data, let response):
            return (data, response)
        case .failure(let error):
            throw error
        }
    }
}

private final class InMemorySecureLicenseStateStore: LicenseStateStoring {
    private var state: LicenseState?

    var storedState: LicenseState? {
        state
    }

    func load() throws -> LicenseState? {
        state
    }

    func save(_ state: LicenseState) throws {
        self.state = state
    }
}

private struct AlwaysValidOfflineLicenseTokenVerifier: OfflineLicenseTokenVerifying {
    func validate(_ token: OfflineLicenseToken) -> Bool {
        true
    }
}

private struct AlwaysInvalidOfflineLicenseTokenVerifier: OfflineLicenseTokenVerifying {
    func validate(_ token: OfflineLicenseToken) -> Bool {
        false
    }
}

private struct AlwaysRejectSignedLicenseTokenVerifier: SignedLicenseTokenVerifying {
    func verifiedClaims(from token: String) throws -> SignedLicenseClaims {
        throw ProductOpsError.invalidSignedLicenseToken
    }
}

private struct StaticSignedLicenseTokenVerifier: SignedLicenseTokenVerifying {
    let claims: SignedLicenseClaims

    func verifiedClaims(from token: String) throws -> SignedLicenseClaims {
        claims
    }
}

private func makeSignedLicenseToken(
    claims: SignedLicenseClaims,
    privateKey: Curve25519.Signing.PrivateKey
) throws -> String {
    let payload = try JSONEncoder.productOps.encode(claims)
    let encodedPayload = payload.base64URLEncodedString()
    let signature = try privateKey.signature(for: Data(encodedPayload.utf8))
    return "v1.\(encodedPayload).\(signature.base64URLEncodedString())"
}

private func makeBackendPEMBase64PublicKey(rawRepresentation: Data) -> String {
    var der = Data([
        0x30, 0x2A,
        0x30, 0x05,
        0x06, 0x03, 0x2B, 0x65, 0x70,
        0x03, 0x21, 0x00
    ])
    der.append(rawRepresentation)
    let body = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
    let pem = "-----BEGIN PUBLIC KEY-----\n\(body)-----END PUBLIC KEY-----\n"
    return Data(pem.utf8).base64EncodedString()
}

private func makeProductOpsSecurityDefaults() throws -> UserDefaults {
    let suiteName = "StacioProductOpsSecurityTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}

private func makeHTTPResponse(statusCode: Int) -> HTTPURLResponse {
    HTTPURLResponse(
        url: URL(string: "https://ops.example.test")!,
        statusCode: statusCode,
        httpVersion: nil,
        headerFields: nil
    )!
}

private var validFeedbackReport: FeedbackReport {
    FeedbackReport(
        title: "Feedback",
        type: .bug,
        description: "A reproducible feedback report.",
        contact: nil,
        includeDiagnostics: false
    )
}

private var validFeedbackContext: FeedbackDiagnosticContext {
    FeedbackDiagnosticContext(
        appVersion: "1",
        build: "1",
        osVersion: "macOS",
        deviceID: "device"
    )
}

private func makeSparkleNoUpdateError(
    reason: SPUNoUpdateFoundReason,
    includesLatestItem: Bool
) -> NSError {
    var userInfo: [String: Any] = [
        NSLocalizedDescriptionKey: "No update found",
        SPUNoUpdateFoundReasonKey: NSNumber(value: reason.rawValue)
    ]
    if includesLatestItem {
        userInfo[SPULatestAppcastItemFoundKey] = NSObject()
    }
    return NSError(
        domain: SUSparkleErrorDomain,
        code: 1001,
        userInfo: userInfo
    )
}

@MainActor
private final class RecordingSparkleUpdaterDriver: SparkleUpdaterDriving {
    var sessionInProgress = false
    var canCheckForUpdates = true
    var automaticallyChecksForUpdates = true
    var automaticallyDownloadsUpdates = true
    var sendsSystemProfile = true
    var startError: Error?
    private(set) var startCount = 0
    private(set) var informationCheckCount = 0
    private(set) var installCheckCount = 0

    func start() throws {
        startCount += 1
        if let startError {
            throw startError
        }
    }

    func checkForUpdateInformation() {
        informationCheckCount += 1
    }

    func checkForUpdates() {
        installCheckCount += 1
    }
}

@MainActor
private final class RecordingInformationOnlySparkleChecker: SparkleUpdateChecking {
    private(set) var informationCheckCount = 0
    private(set) var installCheckCount = 0

    func checkForUpdates(_ sender: Any?) {
        installCheckCount += 1
    }

    func checkForUpdateInformation(_ sender: Any?) {
        informationCheckCount += 1
    }
}

@MainActor
private final class RecordingSparkleUpdateConfirmationPresenter: SparkleUpdateConfirmationPresenting {
    let availableChoice: SparkleAvailableUpdateChoice
    let confirmsInstallAndRelaunch: Bool
    let confirmsTerminationRetry: Bool
    private var terminationRetryConfirmations: [Bool]
    private(set) var availableChoiceCount = 0
    private(set) var installConfirmationCount = 0
    private(set) var terminationRetryConfirmationCount = 0
    private(set) var installCompletedWithoutRelaunchCount = 0

    init(
        availableChoice: SparkleAvailableUpdateChoice,
        confirmsInstallAndRelaunch: Bool,
        confirmsTerminationRetry: Bool = false,
        terminationRetryConfirmations: [Bool] = []
    ) {
        self.availableChoice = availableChoice
        self.confirmsInstallAndRelaunch = confirmsInstallAndRelaunch
        self.confirmsTerminationRetry = confirmsTerminationRetry
        self.terminationRetryConfirmations = terminationRetryConfirmations
    }

    func chooseAvailableUpdate(_ update: SparkleUpdatePromptInfo) -> SparkleAvailableUpdateChoice {
        availableChoiceCount += 1
        return availableChoice
    }

    func confirmInstallAndRelaunch(_ update: SparkleUpdatePromptInfo) -> Bool {
        installConfirmationCount += 1
        return confirmsInstallAndRelaunch
    }

    func confirmRetryTerminatingApplication() -> Bool {
        terminationRetryConfirmationCount += 1
        if terminationRetryConfirmations.isEmpty == false {
            return terminationRetryConfirmations.removeFirst()
        }
        return confirmsTerminationRetry
    }

    func showInstallCompletedWithoutRelaunch() {
        installCompletedWithoutRelaunchCount += 1
    }
}

@MainActor
private final class NoopProductOpsWorkbench: WorkbenchWindowShowing {
    func showWindow(_ sender: Any?) {}
    func openSavedSession(id: String) {}
    func toggleDeviceDashboardFromMenu(_ sender: Any?) {}
    func prepareForApplicationTermination() -> Bool { true }
}

@MainActor
private struct AllowProductOpsTermination: RunningTunnelTerminationConfirming {
    func confirmTerminationWithRunningTunnels(count: Int, parentWindow: NSWindow?) -> Bool {
        true
    }
}

private extension Data {
    func decodeJSON<Value: Decodable>(_ type: Value.Type) throws -> Value {
        try JSONDecoder.productOps.decode(Value.self, from: self)
    }

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
