import CryptoKit
import Foundation
import XCTest
@testable import StacioApp

final class OfflineLicenseProtocolTests: XCTestCase {
    private let configuration = OfflineLicenseProtocolConfiguration(
        requestKeyID: "offline-encryption-test-2026-01",
        requestPublicKeyBase64: "K9OVBGEgLiQvK66DwHcRnVukrjAFg9frt5I7Im2FM0M=",
        signatureKeyID: "offline-signing-test-2026-01",
        authorizationPublicKeyBase64: "7WpHo52oabVEYVXkCy2T8ePwFnviZzK656PvnY46P9M="
    )
    private let fixedProvider = StacioDeviceFingerprintProvider(fixedDeviceID: String(repeating: "a", count: 64))

    func testHardwareFingerprintUsesNormalizedPlatformUUID() throws {
        let provider = StacioDeviceFingerprintProvider(
            platformUUIDProvider: { "B1AA9E9D-7A4B-41F8-AB21-9E6A8BE3C51F" }
        )
        XCTAssertEqual(
            try provider.current().deviceID,
            sha256("stacio-device-v1:b1aa9e9d-7a4b-41f8-ab21-9e6a8be3c51f")
        )
    }

    func testFingerprintFailsWithoutStableHardwareIdentifier() {
        let provider = StacioDeviceFingerprintProvider(platformUUIDProvider: { nil })
        XCTAssertThrowsError(try provider.current()) {
            XCTAssertEqual($0 as? OfflineLicenseFileError, .fileFormatInvalid)
        }
    }

    func testFingerprintExportUsesV2EncryptedJSONEnvelope() throws {
        let date = try XCTUnwrap(OfflineLicenseFileCodec.date(from: "2026-01-02T03:04:05.678Z"))
        let exported = try OfflineLicenseFileCodec.exportDeviceFingerprint(
            configuration: configuration,
            fingerprintProvider: fixedProvider,
            now: date
        )
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: exported.data) as? [String: Any])
        XCTAssertEqual(exported.fileName, "Stacio-offline-request.stacio-offline-request")
        XCTAssertEqual(envelope["protocol"] as? String, "stacio-offline-request")
        XCTAssertEqual(envelope["version"] as? Int, 1)
        XCTAssertEqual(envelope["keyID"] as? String, configuration.requestKeyID)
        XCTAssertEqual(Data(base64Encoded: envelope["ephemeralPublicKey"] as? String ?? "")?.count, 32)
        XCTAssertEqual(Data(base64Encoded: envelope["nonce"] as? String ?? "")?.count, 12)
        XCTAssertGreaterThan(Data(base64Encoded: envelope["ciphertext"] as? String ?? "")?.count ?? 0, 16)
        XCTAssertNil(exported.data.range(of: Data(String(repeating: "a", count: 64).utf8)))
        XCTAssertLessThan(exported.data.count, 65_536)
    }

    func testBackendValidAuthorizationVectorImports() throws {
        let authorization = try OfflineLicenseFileCodec.importAuthorization(
            Data(Self.validAuthorization.utf8), configuration: configuration,
            fingerprintProvider: fixedProvider,
            now: try XCTUnwrap(OfflineLicenseFileCodec.date(from: "2026-06-01T00:00:00.000Z"))
        )
        XCTAssertEqual(authorization.plan, "professional")
        XCTAssertEqual(authorization.entitlements, ["ai_agent", "multi_exec"])
        XCTAssertEqual(authorization.status, .active)
    }

    func testStoredValidAuthorizationRecoversFromStaleInvalidState() throws {
        let now = try XCTUnwrap(OfflineLicenseFileCodec.date(from: "2026-06-01T00:00:00.000Z"))
        let authorization = try JSONDecoder().decode(
            OfflineDeviceAuthorization.self,
            from: Data(Self.validAuthorization.utf8)
        )
        let store = OfflineProtocolLicenseStore()
        try store.save(LicenseState(
            username: authorization.username,
            email: authorization.email,
            plan: authorization.plan,
            permissions: authorization.entitlements,
            expiresAt: authorization.expirationDate(),
            status: .invalid,
            offlineDeviceAuthorization: authorization
        ))
        let service = makeLicenseService(store: store)

        let restored = try service.loadStateOrThrow(now: now)

        XCTAssertEqual(restored.status, .offlineActive)
        XCTAssertEqual(try store.load()?.status, .offlineActive)
        XCTAssertTrue(restored.enables(.aiAgent, at: now))
        XCTAssertTrue(try XCTUnwrap(store.load()).enables(.multiExec, at: now))
    }

    func testStoredSignedRevocationRemainsTerminalWhenOuterStateWasInvalid() throws {
        let now = try XCTUnwrap(OfflineLicenseFileCodec.date(from: "2026-06-01T00:00:00.000Z"))
        let signingKey = Curve25519.Signing.PrivateKey()
        let authorization = try makeSignedAuthorization(
            signingKey: signingKey,
            status: .revoked,
            issuedAt: "2026-01-01T00:00:00.000Z",
            expiresAt: "2027-01-01T00:00:00.000Z"
        )
        let store = OfflineProtocolLicenseStore()
        try store.save(LicenseState(
            username: authorization.username,
            email: authorization.email,
            plan: authorization.plan,
            permissions: authorization.entitlements,
            expiresAt: authorization.expirationDate(),
            status: .invalid,
            offlineDeviceAuthorization: authorization
        ))
        let service = makeLicenseService(store: store, signingKey: signingKey)

        let restored = try service.loadStateOrThrow(now: now)

        XCTAssertEqual(restored.status, .revoked)
        XCTAssertEqual(try store.load()?.status, .revoked)
        XCTAssertFalse(restored.enables(.aiAgent, at: now))
    }

    func testStoredSignedExpiredAuthorizationRemainsExpiredWhenOuterStateWasInvalid() throws {
        let now = try XCTUnwrap(OfflineLicenseFileCodec.date(from: "2026-06-01T00:00:00.000Z"))
        let signingKey = Curve25519.Signing.PrivateKey()
        let authorization = try makeSignedAuthorization(
            signingKey: signingKey,
            status: .active,
            issuedAt: "2025-01-01T00:00:00.000Z",
            expiresAt: "2026-01-01T00:00:00.000Z"
        )
        let store = OfflineProtocolLicenseStore()
        try store.save(LicenseState(
            username: authorization.username,
            email: authorization.email,
            plan: authorization.plan,
            permissions: authorization.entitlements,
            expiresAt: authorization.expirationDate(),
            status: .invalid,
            offlineDeviceAuthorization: authorization
        ))
        let service = makeLicenseService(store: store, signingKey: signingKey)

        let restored = try service.loadStateOrThrow(now: now)

        XCTAssertEqual(restored.status, .expired)
        XCTAssertEqual(try store.load()?.status, .expired)
        XCTAssertFalse(restored.enables(.aiAgent, at: now))
    }

    func testLegacyAuthorizationReencodingDoesNotAddUnsignedStatusField() throws {
        let authorization = try JSONDecoder().decode(
            OfflineDeviceAuthorization.self,
            from: Data(Self.validAuthorization.utf8)
        )
        let encoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder.productOps.encode(authorization)) as? [String: Any]
        )
        XCTAssertNil(encoded["status"])
    }

    func testSynchronizedAuthorizationReencodingPreservesSignedStatusField() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(Self.validAuthorization.utf8)) as? [String: Any]
        )
        object["status"] = "active"
        let authorization = try JSONDecoder().decode(
            OfflineDeviceAuthorization.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        let encoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder.productOps.encode(authorization)) as? [String: Any]
        )
        XCTAssertEqual(encoded["status"] as? String, "active")
    }

    func testBackendDeviceMismatchVectorIsRejected() throws {
        XCTAssertThrowsError(try importVector(Self.deviceMismatchAuthorization, now: "2026-06-01T00:00:00.000Z")) {
            XCTAssertEqual($0 as? OfflineLicenseFileError, .deviceMismatch)
        }
    }

    func testBackendInvalidSignatureVectorIsRejected() throws {
        XCTAssertThrowsError(try importVector(Self.invalidSignatureAuthorization, now: "2026-06-01T00:00:00.000Z")) {
            XCTAssertEqual($0 as? OfflineLicenseFileError, .signatureInvalid)
        }
    }

    func testBackendExpiredAuthorizationVectorIsRejected() throws {
        XCTAssertThrowsError(try importVector(Self.expiredAuthorization, now: "2026-06-01T00:00:00.000Z")) {
            XCTAssertEqual($0 as? OfflineLicenseFileError, .licenseExpired)
        }
    }

    func testSignatureKeyIDMustMatchConfiguration() throws {
        let wrong = OfflineLicenseProtocolConfiguration(
            requestKeyID: configuration.requestKeyID,
            requestPublicKeyBase64: configuration.requestPublicKeyBase64,
            signatureKeyID: "other-key",
            authorizationPublicKeyBase64: configuration.authorizationPublicKeyBase64
        )
        XCTAssertThrowsError(try OfflineLicenseFileCodec.importAuthorization(
            Data(Self.validAuthorization.utf8), configuration: wrong,
            fingerprintProvider: fixedProvider,
            now: try XCTUnwrap(OfflineLicenseFileCodec.date(from: "2026-06-01T00:00:00.000Z"))
        )) { XCTAssertEqual($0 as? OfflineLicenseFileError, .signatureKeyUnsupported) }
    }

    func testConfigurationServiceFetchesAndCachesBackendProtocolConfiguration() async throws {
        let suite = "OfflineLicenseProtocolTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = OfflineLicenseConfigurationStore(defaults: defaults)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [OfflineLicenseConfigurationURLProtocol.self]
        OfflineLicenseConfigurationURLProtocol.responseData = Data(Self.configurationResponse.utf8)
        let service = OfflineLicenseConfigurationService(
            apiBaseURL: URL(string: "https://ops.example.test"),
            store: store,
            session: URLSession(configuration: sessionConfiguration)
        )

        let fetched = try await service.fetch()

        XCTAssertEqual(fetched, configuration)
        XCTAssertEqual(store.load(), configuration)
        XCTAssertEqual(
            OfflineLicenseConfigurationURLProtocol.lastRequest?.url?.path,
            "/api/v1/public/products/stacio/offline-license/config"
        )
    }

    func testConfigurationCacheSurvivesServiceRecreationForOfflineImport() throws {
        let suite = "OfflineLicenseProtocolTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = OfflineLicenseConfigurationStore(defaults: defaults)
        try store.save(configuration)

        let restored = OfflineLicenseConfigurationService(
            apiBaseURL: nil,
            store: OfflineLicenseConfigurationStore(defaults: defaults)
        ).cachedOrBundled(OfflineLicenseProtocolConfiguration(
            requestKeyID: "bundled-request",
            requestPublicKeyBase64: "",
            signatureKeyID: "bundled-signature",
            authorizationPublicKeyBase64: ""
        ))

        XCTAssertEqual(restored, configuration)
        XCTAssertNoThrow(try OfflineLicenseFileCodec.importAuthorization(
            Data(Self.validAuthorization.utf8), configuration: restored,
            fingerprintProvider: fixedProvider,
            now: try XCTUnwrap(OfflineLicenseFileCodec.date(from: "2026-06-01T00:00:00.000Z"))
        ))
    }

    func testConfigurationCacheIsScopedToTheBackendAddress() throws {
        let suite = "OfflineLicenseProtocolTests.Scope.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = OfflineLicenseConfigurationStore(defaults: defaults)
        let developmentURL = try XCTUnwrap(URL(string: "https://ops.example.test"))
        let productionURL = try XCTUnwrap(URL(string: "https://ops.stacio.cn"))
        let bundled = OfflineLicenseProtocolConfiguration(
            requestKeyID: "bundled-request",
            requestPublicKeyBase64: "bundled-request-key",
            signatureKeyID: "bundled-signature",
            authorizationPublicKeyBase64: "bundled-signature-key"
        )

        try store.save(configuration, apiBaseURL: developmentURL)

        XCTAssertEqual(store.load(apiBaseURL: developmentURL), configuration)
        XCTAssertNil(store.load(apiBaseURL: productionURL))
        XCTAssertEqual(
            OfflineLicenseConfigurationService(
                apiBaseURL: productionURL,
                store: store
            ).cachedOrBundled(bundled),
            bundled
        )
    }

    func testOfflineStatusServicePreservesTerminalBackendErrorCode() async throws {
        let authorization = try JSONDecoder().decode(
            OfflineDeviceAuthorization.self,
            from: Data(Self.validAuthorization.utf8)
        )
        let response = HTTPURLResponse(
            url: try XCTUnwrap(URL(string: "https://ops.example.test/api/v1/public/products/stacio/offline-license/status")),
            statusCode: 409,
            httpVersion: nil,
            headerFields: ["X-Request-ID": "req-offline-revoked"]
        )!
        let client = StaticOfflineStatusHTTPClient(
            data: Data(#"{"ok":false,"error":{"code":"OFFLINE_LICENSE_REVOKED","message":"License 已撤销"}}"#.utf8),
            response: response
        )
        let service = OfflineLicenseStatusService(
            configuration: ProductOpsConfiguration(apiBaseURL: URL(string: "https://ops.example.test")),
            httpClient: client
        )

        do {
            _ = try await service.refresh(authorization: authorization, appVersion: "1.0", buildNumber: "1")
            XCTFail("Expected terminal offline status error")
        } catch let error as ProductOpsError {
            XCTAssertEqual(error.offlineLicenseStatusErrorCode, .licenseRevoked)
            XCTAssertEqual(error.backendErrorCode, "OFFLINE_LICENSE_REVOKED")
            XCTAssertEqual(error.backendStatusCode, 409)
            XCTAssertTrue(error.localizedDescription.contains("License 已撤销"))
        }
        XCTAssertEqual(client.requests.count, 1)
    }

    func testOfflineStatusServiceTreatsUnknownSuccessErrorAsServerFailure() async throws {
        let authorization = try JSONDecoder().decode(
            OfflineDeviceAuthorization.self,
            from: Data(Self.validAuthorization.utf8)
        )
        let response = HTTPURLResponse(
            url: try XCTUnwrap(URL(string: "https://ops.example.test")),
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        let client = StaticOfflineStatusHTTPClient(
            data: Data(#"{"ok":false,"error":{"message":"暂时无法同步"}}"#.utf8),
            response: response
        )
        let service = OfflineLicenseStatusService(
            configuration: ProductOpsConfiguration(apiBaseURL: URL(string: "https://ops.example.test")),
            httpClient: client
        )

        do {
            _ = try await service.refresh(authorization: authorization, appVersion: "1.0", buildNumber: "1")
            XCTFail("Expected server failure")
        } catch let error as ProductOpsError {
            XCTAssertNil(error.backendErrorCode)
            XCTAssertEqual(error, .server(message: "暂时无法同步", requestID: nil))
        }
    }

    func testOfflineStatusServicePreservesBindingNotFoundCodeOnHTTP404() async throws {
        let authorization = try JSONDecoder().decode(
            OfflineDeviceAuthorization.self,
            from: Data(Self.validAuthorization.utf8)
        )
        let response = HTTPURLResponse(
            url: try XCTUnwrap(URL(string: "https://ops.example.test")),
            statusCode: 404,
            httpVersion: nil,
            headerFields: nil
        )!
        let service = OfflineLicenseStatusService(
            configuration: ProductOpsConfiguration(apiBaseURL: URL(string: "https://ops.example.test")),
            httpClient: StaticOfflineStatusHTTPClient(
                data: Data(#"{"ok":false,"error":{"code":"OFFLINE_BINDING_NOT_FOUND","message":"未找到设备绑定"}}"#.utf8),
                response: response
            )
        )

        do {
            _ = try await service.refresh(authorization: authorization, appVersion: "1.0", buildNumber: "1")
            XCTFail("Expected binding-not-found error")
        } catch let error as ProductOpsError {
            XCTAssertEqual(error.offlineLicenseStatusErrorCode, .bindingNotFound)
            XCTAssertEqual(error.backendStatusCode, 404)
        }
    }

    func testLiveProductionConfigurationAndFingerprintExportWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["STACIO_RUN_LIVE_OFFLINE_LICENSE_TEST"] == "1" else {
            throw XCTSkip("Set STACIO_RUN_LIVE_OFFLINE_LICENSE_TEST=1 to verify the deployed production protocol.")
        }
        let suite = "OfflineLicenseProtocolTests.Live.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = OfflineLicenseConfigurationStore(defaults: defaults)
        let service = OfflineLicenseConfigurationService(
            apiBaseURL: URL(string: "https://ops.stacio.cn"),
            store: store
        )

        let live = try await service.fetch()
        let requestKey = try XCTUnwrap(Data(base64Encoded: live.requestPublicKeyBase64))
        let signatureKey = try XCTUnwrap(Data(base64Encoded: live.authorizationPublicKeyBase64))
        XCTAssertEqual(live.requestKeyID, "offline-encryption-2026-01")
        XCTAssertEqual(live.signatureKeyID, "offline-signing-2026-01")
        XCTAssertEqual(requestKey.count, 32)
        XCTAssertEqual(signatureKey.count, 32)
        XCTAssertEqual(
            live.exchangeAddress?.absoluteString,
            "https://ops.stacio.cn/api/v1/public/products/stacio/offline-license/exchange"
        )
        XCTAssertNotEqual(live.requestPublicKeyBase64, configuration.requestPublicKeyBase64)
        XCTAssertNotEqual(live.authorizationPublicKeyBase64, configuration.authorizationPublicKeyBase64)
        XCTAssertEqual(store.load(), live)

        let exported = try OfflineLicenseFileCodec.exportDeviceFingerprint(configuration: live)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: exported.data) as? [String: Any])
        XCTAssertEqual(envelope["keyID"] as? String, live.requestKeyID)
        XCTAssertEqual(envelope["protocol"] as? String, "stacio-offline-request")
        XCTAssertEqual(Data(base64Encoded: envelope["ephemeralPublicKey"] as? String ?? "")?.count, 32)
        XCTAssertEqual(Data(base64Encoded: envelope["nonce"] as? String ?? "")?.count, 12)
        XCTAssertLessThan(exported.data.count, 65_536)
        XCTAssertNil(exported.data.range(of: Data((try StacioDeviceFingerprintProvider().current()).deviceID.utf8)))
        if let outputPath = ProcessInfo.processInfo.environment["STACIO_LIVE_OFFLINE_REQUEST_OUTPUT"],
           outputPath.isEmpty == false {
            try exported.data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        }
    }

    func testLiveProductionAuthorizationImportAndRestartPersistenceWhenEnabled() async throws {
        guard let filePath = ProcessInfo.processInfo.environment["STACIO_LIVE_OFFLINE_AUTHORIZATION_FILE"],
              filePath.isEmpty == false else {
            throw XCTSkip("Set STACIO_LIVE_OFFLINE_AUTHORIZATION_FILE to a redeemed production authorization file.")
        }
        let configuration = try await OfflineLicenseConfigurationService(
            apiBaseURL: URL(string: "https://ops.stacio.cn")
        ).fetch()
        let authorization = try OfflineLicenseFileCodec.importAuthorization(
            Data(contentsOf: URL(fileURLWithPath: filePath)), configuration: configuration
        )
        XCTAssertEqual(authorization.username, "FengLee")
        XCTAssertEqual(authorization.email, "Fengoffer@163.com")
        XCTAssertEqual(authorization.plan, "professional")
        XCTAssertEqual(Set(authorization.entitlements), Set([
            "advanced_metrics", "ai_agent", "bastion_host", "file_sync", "multi_exec",
            "proxy_jump", "session_bulk_io", "ssh_tunnel"
        ]))

        let store = OfflineProtocolLicenseStore()
        let service = LicenseService(
            store: store,
            offlineDeviceAuthorizationVerifier: OfflineDeviceAuthorizationVerifier(
                publicKeyBase64: configuration.authorizationPublicKeyBase64,
                expectedSignatureKeyID: configuration.signatureKeyID
            )
        )
        let applied = try service.state(
            applyingOfflineDeviceAuthorization: authorization,
            expectedUsername: "FengLee",
            expectedEmail: "Fengoffer@163.com",
            activationStore: store
        )
        XCTAssertEqual(applied.status, .offlineActive)
        XCTAssertEqual(Set(applied.permissions), Set(authorization.entitlements))

        let restartedService = LicenseService(
            store: store,
            offlineDeviceAuthorizationVerifier: OfflineDeviceAuthorizationVerifier(
                publicKeyBase64: configuration.authorizationPublicKeyBase64,
                expectedSignatureKeyID: configuration.signatureKeyID
            )
        )
        let restored = restartedService.loadState()
        XCTAssertEqual(restored.status, .offlineActive)
        XCTAssertEqual(restored.username, "FengLee")
        XCTAssertEqual(restored.plan, "professional")
        XCTAssertEqual(Set(restored.permissions), Set(authorization.entitlements))
    }

    private func importVector(_ value: String, now: String) throws -> OfflineDeviceAuthorization {
        try OfflineLicenseFileCodec.importAuthorization(
            Data(value.utf8), configuration: configuration, fingerprintProvider: fixedProvider,
            now: try XCTUnwrap(OfflineLicenseFileCodec.date(from: now))
        )
    }

    private func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func makeLicenseService(
        store: LicenseStateStoring,
        signingKey: Curve25519.Signing.PrivateKey? = nil
    ) -> LicenseService {
        LicenseService(
            store: store,
            offlineDeviceAuthorizationVerifier: OfflineDeviceAuthorizationVerifier(
                publicKeyBase64: signingKey?.publicKey.rawRepresentation.base64EncodedString()
                    ?? configuration.authorizationPublicKeyBase64,
                expectedSignatureKeyID: signingKey == nil
                    ? configuration.signatureKeyID
                    : "offline-signing-generated",
                fingerprintProvider: fixedProvider
            )
        )
    }

    private func makeSignedAuthorization(
        signingKey: Curve25519.Signing.PrivateKey,
        status: OfflineDeviceAuthorizationStatus,
        issuedAt: String,
        expiresAt: String
    ) throws -> OfflineDeviceAuthorization {
        let unsigned = OfflineDeviceAuthorization(
            productID: "stacio",
            deviceID: String(repeating: "a", count: 64),
            username: "Test User",
            email: "test@example.com",
            plan: "professional",
            entitlements: ["ai_agent", "multi_exec"],
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            signatureKeyID: "offline-signing-generated",
            status: status,
            signature: "",
            statusIsExplicit: true
        )
        let signature = try signingKey.signature(for: unsigned.canonicalSignedPayload())
        return OfflineDeviceAuthorization(
            productID: unsigned.productID,
            platform: unsigned.platform,
            deviceID: unsigned.deviceID,
            username: unsigned.username,
            email: unsigned.email,
            plan: unsigned.plan,
            entitlements: unsigned.entitlements,
            issuedAt: unsigned.issuedAt,
            expiresAt: unsigned.expiresAt,
            signatureKeyID: unsigned.signatureKeyID,
            status: unsigned.status,
            signature: signature.base64EncodedString(),
            statusIsExplicit: true
        )
    }

    private static let validAuthorization = #"{"deviceID":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","email":"test@example.com","entitlements":["ai_agent","multi_exec"],"expiresAt":"2027-01-02T03:04:05.678Z","issuedAt":"2026-01-02T03:04:05.678Z","plan":"professional","platform":"macos","productID":"stacio","signature":"O6q0s81bhIQi02TuIhm27ywnnujP7kGGyrBexhcM+NZ3C2FiN2KDUYSwF2rnS/cmfpHYjkuYa1RVL8sFGihPBg==","signatureKeyID":"offline-signing-test-2026-01","username":"Test User"}"#
    private static let deviceMismatchAuthorization = #"{"deviceID":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","email":"test@example.com","entitlements":["ai_agent","multi_exec"],"expiresAt":"2027-01-02T03:04:05.678Z","issuedAt":"2026-01-02T03:04:05.678Z","plan":"professional","platform":"macos","productID":"stacio","signature":"qyYA5OTqJ6XDtrGdYoobAvftUzLYGr80FM8UvCgHPiHhrsC3umv6EWCUVXQEsUevjkfi5MDAfDrEcaTTErjIAw==","signatureKeyID":"offline-signing-test-2026-01","username":"Test User"}"#
    private static let invalidSignatureAuthorization = #"{"deviceID":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","email":"test@example.com","entitlements":["ai_agent","multi_exec"],"expiresAt":"2027-01-02T03:04:05.678Z","issuedAt":"2026-01-02T03:04:05.678Z","plan":"professional","platform":"macos","productID":"stacio","signature":"P6q0s81bhIQi02TuIhm27ywnnujP7kGGyrBexhcM+NZ3C2FiN2KDUYSwF2rnS/cmfpHYjkuYa1RVL8sFGihPBg==","signatureKeyID":"offline-signing-test-2026-01","username":"Test User"}"#
    private static let expiredAuthorization = #"{"deviceID":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","email":"test@example.com","entitlements":["ai_agent","multi_exec"],"expiresAt":"2021-01-02T03:04:05.678Z","issuedAt":"2020-01-02T03:04:05.678Z","plan":"professional","platform":"macos","productID":"stacio","signature":"sYTlWUqPxuunPjhWDtoyOh7VTM7CVwdrgROPInQFhVKuusdZoZTHwdYuZU0s+BjD9D0IlnpN4D/HHi0sbJDyBw==","signatureKeyID":"offline-signing-test-2026-01","username":"Test User"}"#
    private static let configurationResponse = #"{"ok":true,"data":{"productID":"stacio","request":{"protocol":"stacio-offline-request","version":1,"keyID":"offline-encryption-test-2026-01","publicKeyBase64":"K9OVBGEgLiQvK66DwHcRnVukrjAFg9frt5I7Im2FM0M=","hkdf":{"hash":"SHA-256","salt":"stacio-offline-request-v1","info":"stacio:offline-request:v1"},"nonceLength":12,"maxFileBytes":65536,"requestFileExtension":".stacio-offline-request"},"authorization":{"signatureKeyID":"offline-signing-test-2026-01","publicKeyBase64":"7WpHo52oabVEYVXkCy2T8ePwFnviZzK656PvnY46P9M=","algorithm":"Ed25519"},"exchangeAddress":null}}"#
}

private final class OfflineLicenseConfigurationURLProtocol: URLProtocol {
    static var responseData = Data()
    static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        client?.urlProtocol(self, didReceive: HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
        )!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class StaticOfflineStatusHTTPClient: ProductOpsHTTPClient {
    let data: Data
    let response: HTTPURLResponse
    private(set) var requests: [URLRequest] = []

    init(data: Data, response: HTTPURLResponse) {
        self.data = data
        self.response = response
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (data, response)
    }
}

private final class OfflineProtocolLicenseStore: LicenseStateStoring, LicenseActivationRecordStoring {
    private var state: LicenseState?
    private var activation: LicenseActivationRecord?

    func load() throws -> LicenseState? { state }
    func save(_ state: LicenseState) throws { self.state = state }
    func loadActivationRecord() throws -> LicenseActivationRecord? { activation }
    func saveActivationRecord(_ record: LicenseActivationRecord) throws { activation = record }
    func deleteActivationRecord() throws { activation = nil }
}
