import CryptoKit
import Foundation
import IOKit

public enum OfflineLicenseFileError: LocalizedError, Equatable {
    case exchangeNotConfigured
    case fileFormatInvalid
    case signatureInvalid
    case productMismatch
    case platformMismatch
    case deviceMismatch
    case licenseExpired
    case licenseRevoked
    case licensePlanUnsupported
    case signatureKeyUnsupported
    case entitlementUnsupported
    case boundToOtherDevice

    public var errorDescription: String? {
        switch self {
        case .exchangeNotConfigured: return "离线授权配置不可用，请联网后重试。"
        case .fileFormatInvalid: return "离线授权文件格式错误，请重新导出或下载文件。"
        case .signatureInvalid: return "离线授权签名无效，文件可能已损坏或被修改。"
        case .productMismatch: return "该离线授权不属于 Stacio。"
        case .platformMismatch: return "该离线授权不适用于 macOS。"
        case .deviceMismatch: return "该离线授权绑定的是其他设备，请在对应 Mac 上导入。"
        case .licenseExpired: return "该离线授权已过期，请在兑换页面续期后重新下载。"
        case .licenseRevoked: return "该离线授权已被撤销，请联系管理员。"
        case .licensePlanUnsupported: return "该 License 版本不支持离线授权。"
        case .signatureKeyUnsupported: return "离线授权签名密钥版本不受支持，请更新 Stacio。"
        case .entitlementUnsupported: return "离线授权包含无法识别的功能权限，请更新 Stacio。"
        case .boundToOtherDevice: return "该 License 已绑定其他离线设备，请联系管理员迁移或重置。"
        }
    }
}

public enum DeviceFingerprintSource: String, Codable, Equatable {
    case ioPlatformUUID

    public var displayName: String { "macOS 硬件标识" }
}

public struct StacioDeviceFingerprint: Equatable {
    public let deviceID: String
    public let source: DeviceFingerprintSource
}

public final class StacioDeviceFingerprintProvider {
    private let platformUUIDProvider: () -> String?
    private let fixedDeviceID: String?

    public init(
        platformUUIDProvider: @escaping () -> String? = StacioDeviceFingerprintProvider.readPlatformUUID,
        fixedDeviceID: String? = nil
    ) {
        self.platformUUIDProvider = platformUUIDProvider
        self.fixedDeviceID = fixedDeviceID
    }

    public func current() throws -> StacioDeviceFingerprint {
        if let fixedDeviceID {
            return StacioDeviceFingerprint(deviceID: fixedDeviceID, source: .ioPlatformUUID)
        }
        guard let identifier = platformUUIDProvider()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              identifier.isEmpty == false else {
            throw OfflineLicenseFileError.fileFormatInvalid
        }
        let digest = SHA256.hash(data: Data("stacio-device-v1:\(identifier)".utf8))
        return StacioDeviceFingerprint(
            deviceID: digest.map { String(format: "%02x", $0) }.joined(),
            source: .ioPlatformUUID
        )
    }

    public static func readPlatformUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }
}

public struct OfflineLicenseProtocolConfiguration: Codable, Equatable {
    public let requestKeyID: String
    public let requestPublicKeyBase64: String
    public let signatureKeyID: String
    public let authorizationPublicKeyBase64: String
    public let exchangeAddress: URL?

    public init(
        requestKeyID: String,
        requestPublicKeyBase64: String,
        signatureKeyID: String,
        authorizationPublicKeyBase64: String,
        exchangeAddress: URL? = nil
    ) {
        self.requestKeyID = requestKeyID
        self.requestPublicKeyBase64 = requestPublicKeyBase64
        self.signatureKeyID = signatureKeyID
        self.authorizationPublicKeyBase64 = authorizationPublicKeyBase64
        self.exchangeAddress = exchangeAddress
    }
}

public final class OfflineLicenseConfigurationStore {
    private static let key = "Stacio.OfflineLicense.ProtocolConfiguration.v2"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func load() -> OfflineLicenseProtocolConfiguration? {
        load(apiBaseURL: nil)
    }

    public func load(apiBaseURL: URL?) -> OfflineLicenseProtocolConfiguration? {
        guard let stored = loadStoredConfiguration() else { return nil }
        guard let apiBaseURL else {
            return stored.configuration
        }
        // A cache without a scope is from the pre-scoped format. Do not let a
        // development server's key material leak into a production build.
        guard stored.scope == Self.scope(for: apiBaseURL) else { return nil }
        return stored.configuration
    }

    public func save(
        _ configuration: OfflineLicenseProtocolConfiguration,
        apiBaseURL: URL? = nil
    ) throws {
        let stored = StoredConfiguration(
            scope: apiBaseURL.flatMap(Self.scope(for:)),
            configuration: configuration
        )
        defaults.set(try JSONEncoder().encode(stored), forKey: Self.key)
    }

    private func loadStoredConfiguration() -> StoredConfiguration? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        if let stored = try? JSONDecoder().decode(StoredConfiguration.self, from: data) {
            return stored
        }
        // Keep reading the v2 pre-scope format so the bundled configuration can
        // safely take over on the next scoped fetch.
        guard let legacy = try? JSONDecoder().decode(OfflineLicenseProtocolConfiguration.self, from: data) else {
            return nil
        }
        return StoredConfiguration(scope: nil, configuration: legacy)
    }

    private static func scope(for apiBaseURL: URL) -> String? {
        guard var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              scheme.isEmpty == false,
              host.isEmpty == false
        else {
            return nil
        }
        components.scheme = scheme
        components.host = host
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        if components.path == "/" {
            components.path = ""
        }
        return components.string
    }

    private struct StoredConfiguration: Codable {
        let scope: String?
        let configuration: OfflineLicenseProtocolConfiguration
    }
}

public final class OfflineLicenseConfigurationService {
    private let apiBaseURL: URL?
    private let store: OfflineLicenseConfigurationStore
    private let session: URLSession

    public init(
        apiBaseURL: URL?,
        store: OfflineLicenseConfigurationStore = OfflineLicenseConfigurationStore(),
        session: URLSession = .shared
    ) {
        self.apiBaseURL = apiBaseURL; self.store = store; self.session = session
    }

    public func fetch() async throws -> OfflineLicenseProtocolConfiguration {
        guard let url = apiBaseURL?.appendingPathComponent("api/v1/public/products/stacio/offline-license/config") else {
            throw OfflineLicenseFileError.exchangeNotConfigured
        }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let envelope = try? JSONDecoder().decode(ConfigurationEnvelope.self, from: data), envelope.ok else {
            throw OfflineLicenseFileError.exchangeNotConfigured
        }
        let value = envelope.data
        guard value.productID == "stacio", value.request.protocol == "stacio-offline-request",
              value.request.version == 1, value.request.hkdf.hash == "SHA-256",
              value.request.hkdf.salt == "stacio-offline-request-v1",
              value.request.hkdf.info == "stacio:offline-request:v1",
              value.request.nonceLength == 12, value.authorization.algorithm == "Ed25519" else {
            throw OfflineLicenseFileError.exchangeNotConfigured
        }
        let configuration = OfflineLicenseProtocolConfiguration(
            requestKeyID: value.request.keyID,
            requestPublicKeyBase64: value.request.publicKeyBase64,
            signatureKeyID: value.authorization.signatureKeyID,
            authorizationPublicKeyBase64: value.authorization.publicKeyBase64,
            exchangeAddress: value.exchangeAddress.flatMap(URL.init(string:))
        )
        try store.save(configuration, apiBaseURL: apiBaseURL)
        return configuration
    }

    public func cachedOrBundled(_ bundled: OfflineLicenseProtocolConfiguration) -> OfflineLicenseProtocolConfiguration {
        store.load(apiBaseURL: apiBaseURL) ?? bundled
    }

    private struct ConfigurationEnvelope: Decodable { let ok: Bool; let data: ConfigurationData }
    private struct ConfigurationData: Decodable {
        let productID: String; let request: Request; let authorization: Authorization; let exchangeAddress: String?
    }
    private struct Request: Decodable {
        let `protocol`: String; let version: Int; let keyID: String; let publicKeyBase64: String
        let hkdf: HKDF; let nonceLength: Int
    }
    private struct HKDF: Decodable { let hash: String; let salt: String; let info: String }
    private struct Authorization: Decodable {
        let signatureKeyID: String; let publicKeyBase64: String; let algorithm: String
    }
}

public enum OfflineDeviceAuthorizationStatus: String, Codable, Equatable { case active, revoked }

public struct OfflineDeviceAuthorization: Codable, Equatable {
    public let productID: String
    public let platform: String
    public let deviceID: String
    public let username: String
    public let email: String
    public let plan: String
    public let entitlements: [String]
    public let issuedAt: String
    public let expiresAt: String
    public let signatureKeyID: String
    public let status: OfflineDeviceAuthorizationStatus
    public let signature: String
    private let statusIsExplicit: Bool

    enum CodingKeys: String, CodingKey {
        case productID, platform, deviceID, username, email, plan, entitlements
        case issuedAt, expiresAt, signatureKeyID, status, signature
    }

    public init(
        productID: String, platform: String = "macos", deviceID: String, username: String, email: String,
        plan: String, entitlements: [String] = [], issuedAt: String, expiresAt: String,
        signatureKeyID: String, status: OfflineDeviceAuthorizationStatus = .active, signature: String,
        statusIsExplicit: Bool = false
    ) {
        self.productID = productID; self.platform = platform; self.deviceID = deviceID
        self.username = username; self.email = email; self.plan = plan; self.entitlements = entitlements
        self.issuedAt = issuedAt; self.expiresAt = expiresAt; self.signatureKeyID = signatureKeyID
        self.status = status; self.signature = signature
        self.statusIsExplicit = statusIsExplicit
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        productID = try values.decode(String.self, forKey: .productID)
        platform = try values.decode(String.self, forKey: .platform)
        deviceID = try values.decode(String.self, forKey: .deviceID)
        username = try values.decode(String.self, forKey: .username)
        email = try values.decode(String.self, forKey: .email)
        plan = try values.decode(String.self, forKey: .plan)
        entitlements = try values.decode([String].self, forKey: .entitlements)
        issuedAt = try values.decode(String.self, forKey: .issuedAt)
        expiresAt = try values.decode(String.self, forKey: .expiresAt)
        signatureKeyID = try values.decode(String.self, forKey: .signatureKeyID)
        statusIsExplicit = values.contains(.status)
        status = try values.decodeIfPresent(OfflineDeviceAuthorizationStatus.self, forKey: .status) ?? .active
        signature = try values.decode(String.self, forKey: .signature)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(productID, forKey: .productID)
        try values.encode(platform, forKey: .platform)
        try values.encode(deviceID, forKey: .deviceID)
        try values.encode(username, forKey: .username)
        try values.encode(email, forKey: .email)
        try values.encode(plan, forKey: .plan)
        try values.encode(entitlements, forKey: .entitlements)
        try values.encode(issuedAt, forKey: .issuedAt)
        try values.encode(expiresAt, forKey: .expiresAt)
        try values.encode(signatureKeyID, forKey: .signatureKeyID)
        if statusIsExplicit || status != .active {
            try values.encode(status, forKey: .status)
        }
        try values.encode(signature, forKey: .signature)
    }

    public func canonicalSignedPayload() throws -> Data {
        var value: [String: Any] = [
            "deviceID": deviceID, "email": email, "entitlements": entitlements,
            "expiresAt": expiresAt, "issuedAt": issuedAt, "plan": plan, "platform": platform,
            "productID": productID, "signatureKeyID": signatureKeyID, "username": username
        ]
        if statusIsExplicit || status != .active { value["status"] = status.rawValue }
        return try CanonicalJSON.data(value)
    }

    public func expirationDate() -> Date? { OfflineLicenseFileCodec.date(from: expiresAt) }
}

public protocol OfflineLicenseStatusRefreshing: AnyObject {
    func refresh(
        authorization: OfflineDeviceAuthorization,
        appVersion: String,
        buildNumber: String
    ) async throws -> OfflineDeviceAuthorization
}

public enum OfflineLicenseStatusErrorCode: String, Codable, Equatable, CaseIterable {
    case licenseRevoked = "OFFLINE_LICENSE_REVOKED"
    case licenseExpired = "OFFLINE_LICENSE_EXPIRED"
    case deviceMismatch = "OFFLINE_DEVICE_MISMATCH"
    case bindingNotFound = "OFFLINE_BINDING_NOT_FOUND"
    case authorizationSignatureInvalid = "OFFLINE_AUTHORIZATION_SIGNATURE_INVALID"

    public var terminalStatus: LicenseStatus {
        switch self {
        case .licenseRevoked:
            return .revoked
        case .licenseExpired:
            return .expired
        case .deviceMismatch, .bindingNotFound, .authorizationSignatureInvalid:
            return .invalid
        }
    }
}

public extension ProductOpsError {
    var offlineLicenseStatusErrorCode: OfflineLicenseStatusErrorCode? {
        guard let backendErrorCode else { return nil }
        return OfflineLicenseStatusErrorCode(rawValue: backendErrorCode.uppercased())
    }
}

public final class OfflineLicenseStatusService: OfflineLicenseStatusRefreshing {
    private struct RequestBody: Encodable {
        let authorization: OfflineDeviceAuthorization
        let appVersion: String
        let buildNumber: String
    }

    private struct ResponseEnvelope: Decodable {
        let ok: Bool
        let data: ResponseData?
        let error: ResponseError?
    }

    private struct ResponseData: Decodable { let authorization: OfflineDeviceAuthorization }
    private struct ResponseError: Decodable {
        let code: String?
        let message: String?
    }

    private let configuration: ProductOpsConfiguration
    private let httpClient: ProductOpsHTTPClient

    public init(
        configuration: ProductOpsConfiguration,
        httpClient: ProductOpsHTTPClient = URLSessionProductOpsHTTPClient()
    ) {
        self.configuration = configuration
        self.httpClient = httpClient
    }

    public func refresh(
        authorization: OfflineDeviceAuthorization,
        appVersion: String,
        buildNumber: String
    ) async throws -> OfflineDeviceAuthorization {
        let baseURL = try ProductOpsEndpointPolicy.validatedAPIBaseURL(configuration.apiBaseURL)
        let url = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("v1")
            .appendingPathComponent("public")
            .appendingPathComponent("products")
            .appendingPathComponent(configuration.productID)
            .appendingPathComponent("offline-license")
            .appendingPathComponent("status")
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder.productOps.encode(RequestBody(
            authorization: authorization,
            appVersion: appVersion,
            buildNumber: buildNumber
        ))
        let (data, response) = try await httpClient.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            let error = ProductOpsError.responseError(data: data, response: response)
            if response.statusCode == 404, error.backendErrorCode == nil {
                throw ProductOpsError.server(
                    message: "后台尚未启用离线授权状态同步接口。",
                    requestID: response.value(forHTTPHeaderField: "X-Request-ID")
                )
            }
            throw error
        }
        let envelope = try JSONDecoder.productOps.decode(ResponseEnvelope.self, from: data)
        guard envelope.ok, let refreshed = envelope.data?.authorization else {
            if let code = envelope.error?.code?.trimmingCharacters(in: .whitespacesAndNewlines),
               code.isEmpty == false {
                throw ProductOpsError.backend(
                    code: code,
                    message: envelope.error?.message ?? "离线授权状态同步失败。",
                    requestID: response.value(forHTTPHeaderField: "X-Request-ID"),
                    statusCode: response.statusCode
                )
            }
            throw ProductOpsError.server(
                message: envelope.error?.message ?? "离线授权状态同步失败。",
                requestID: response.value(forHTTPHeaderField: "X-Request-ID")
            )
        }
        return refreshed
    }
}

public struct OfflineDeviceAuthorizationVerifier {
    public let publicKeyBase64: String
    public let expectedSignatureKeyID: String?
    public let expectedProductID: String
    public let expectedPlatform: String
    public let fingerprintProvider: StacioDeviceFingerprintProvider
    public let supportedEntitlements: Set<String>?

    public init(
        publicKeyBase64: String,
        expectedSignatureKeyID: String? = nil,
        expectedProductID: String = "stacio",
        expectedPlatform: String = "macos",
        fingerprintProvider: StacioDeviceFingerprintProvider = StacioDeviceFingerprintProvider(),
        supportedEntitlements: Set<String>? = nil
    ) {
        self.publicKeyBase64 = publicKeyBase64; self.expectedSignatureKeyID = expectedSignatureKeyID
        self.expectedProductID = expectedProductID; self.expectedPlatform = expectedPlatform
        self.fingerprintProvider = fingerprintProvider; self.supportedEntitlements = supportedEntitlements
    }

    public func verify(_ authorization: OfflineDeviceAuthorization, now: Date = Date(), allowRevoked: Bool = false) throws {
        guard authorization.productID == expectedProductID else { throw OfflineLicenseFileError.productMismatch }
        guard authorization.platform == expectedPlatform else { throw OfflineLicenseFileError.platformMismatch }
        guard authorization.deviceID == (try fingerprintProvider.current()).deviceID else { throw OfflineLicenseFileError.deviceMismatch }
        guard ["professional", "enterprise"].contains(authorization.plan) else { throw OfflineLicenseFileError.licensePlanUnsupported }
        if let expectedSignatureKeyID, authorization.signatureKeyID != expectedSignatureKeyID {
            throw OfflineLicenseFileError.signatureKeyUnsupported
        }
        if let supportedEntitlements, Set(authorization.entitlements).isSubset(of: supportedEntitlements) == false {
            throw OfflineLicenseFileError.entitlementUnsupported
        }
        guard let issuedAt = OfflineLicenseFileCodec.date(from: authorization.issuedAt),
              let expiresAt = authorization.expirationDate(), issuedAt <= expiresAt else {
            throw OfflineLicenseFileError.fileFormatInvalid
        }
        guard let keyData = OfflineLicenseFileCodec.ed25519PublicKeyData(from: publicKeyBase64),
              let signature = Data(base64Encoded: authorization.signature), signature.count == 64,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              key.isValidSignature(signature, for: try authorization.canonicalSignedPayload()) else {
            throw OfflineLicenseFileError.signatureInvalid
        }
        if authorization.status == .revoked {
            if allowRevoked { return }
            throw OfflineLicenseFileError.licenseRevoked
        }
        guard expiresAt > now else { throw OfflineLicenseFileError.licenseExpired }
    }
}

public struct OfflineDeviceFingerprintExport {
    public let data: Data
    public let fileName: String
    public let fingerprint: StacioDeviceFingerprint
}

public enum OfflineLicenseFileCodec {
    private static let protocolName = "stacio-offline-request"
    private static let requestSalt = Data("stacio-offline-request-v1".utf8)
    private static let requestInfo = Data("stacio:offline-request:v1".utf8)
    private static let maxFileBytes = 65_536

    public static func exportDeviceFingerprint(
        configuration: OfflineLicenseProtocolConfiguration,
        fingerprintProvider: StacioDeviceFingerprintProvider = StacioDeviceFingerprintProvider(),
        now: Date = Date()
    ) throws -> OfflineDeviceFingerprintExport {
        guard let backendKeyData = Data(base64Encoded: configuration.requestPublicKeyBase64), backendKeyData.count == 32,
              let backendKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: backendKeyData),
              configuration.requestKeyID.isEmpty == false else { throw OfflineLicenseFileError.exchangeNotConfigured }
        let fingerprint = try fingerprintProvider.current()
        let payload: [String: Any] = [
            "createdAt": timestamp(now), "deviceID": fingerprint.deviceID, "formatVersion": 1,
            "platform": "macos", "productID": "stacio"
        ]
        let plaintext = try CanonicalJSON.data(payload)
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let nonce = ChaChaPoly.Nonce()
        let header: [String: Any] = [
            "ephemeralPublicKey": ephemeral.publicKey.rawRepresentation.base64EncodedString(),
            "keyID": configuration.requestKeyID,
            "nonce": Data(nonce).base64EncodedString(),
            "protocol": protocolName, "version": 1
        ]
        let aad = try CanonicalJSON.data(header)
        let secret = try ephemeral.sharedSecretFromKeyAgreement(with: backendKey)
        let key = secret.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: requestSalt, sharedInfo: requestInfo, outputByteCount: 32
        )
        let sealed = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce, authenticating: aad)
        var envelope = header
        envelope["ciphertext"] = (sealed.ciphertext + sealed.tag).base64EncodedString()
        let data = try CanonicalJSON.data(envelope)
        guard data.count <= maxFileBytes else { throw OfflineLicenseFileError.fileFormatInvalid }
        return OfflineDeviceFingerprintExport(
            data: data, fileName: "Stacio-offline-request.stacio-offline-request", fingerprint: fingerprint
        )
    }

    public static func importAuthorization(
        _ data: Data,
        configuration: OfflineLicenseProtocolConfiguration,
        fingerprintProvider: StacioDeviceFingerprintProvider = StacioDeviceFingerprintProvider(),
        now: Date = Date()
    ) throws -> OfflineDeviceAuthorization {
        guard data.count <= maxFileBytes,
              let authorization = try? JSONDecoder().decode(OfflineDeviceAuthorization.self, from: data) else {
            throw OfflineLicenseFileError.fileFormatInvalid
        }
        try OfflineDeviceAuthorizationVerifier(
            publicKeyBase64: configuration.authorizationPublicKeyBase64,
            expectedSignatureKeyID: configuration.signatureKeyID,
            fingerprintProvider: fingerprintProvider
        ).verify(authorization, now: now, allowRevoked: true)
        return authorization
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func date(from value: String) -> Date? {
        guard value.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$"#, options: .regularExpression) != nil else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }

    static func ed25519PublicKeyData(from configuredBase64: String) -> Data? {
        Ed25519PublicKeyMaterial.rawRepresentation(from: configuredBase64)
    }
}

enum CanonicalJSON {
    static func data(_ value: Any) throws -> Data {
        guard JSONSerialization.isValidJSONObject(value) else { throw OfflineLicenseFileError.fileFormatInvalid }
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}
