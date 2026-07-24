import CryptoKit
import Foundation

public struct BastionHostDeepLinkRequest: Codable, Equatable, Sendable {
    public let version: Int
    public let vendor: String
    public let protocolName: String
    public let gatewayHost: String
    public let gatewayPort: UInt16
    public let gatewayUsername: String
    public let targetHost: String?
    public let targetPort: UInt16?
    public let targetUsername: String?
    public let assetID: String?
    public let accountID: String?
    public let requestID: String
    public let nonce: String
    public let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case version
        case vendor
        case protocolName = "protocol"
        case gatewayHost
        case gatewayPort
        case gatewayUsername
        case targetHost
        case targetPort
        case targetUsername
        case assetID = "assetId"
        case accountID = "accountId"
        case requestID = "requestId"
        case nonce
        case expiresAt
    }
}

public enum BastionHostDeepLinkError: LocalizedError, Equatable {
    case invalidRoute
    case invalidPayload
    case unsupportedVersion
    case unsupportedProtocol
    case expired
    case validityTooLong
    case replayed
    case signatureRequired
    case invalidSignature
    case unsafeParameter

    public var errorDescription: String? {
        switch self {
        case .invalidRoute, .invalidPayload:
            return "堡垒机连接请求格式无效。"
        case .unsupportedVersion:
            return "该堡垒机连接协议版本暂不受支持。"
        case .unsupportedProtocol:
            return "该堡垒机连接协议暂不受支持。"
        case .expired:
            return "堡垒机连接请求已过期。"
        case .validityTooLong:
            return "堡垒机连接请求的有效期过长。"
        case .replayed:
            return "该堡垒机连接请求已经处理过。"
        case .signatureRequired:
            return "该堡垒机厂商的连接请求缺少签名。"
        case .invalidSignature:
            return "堡垒机连接请求签名无效。"
        case .unsafeParameter:
            return "堡垒机连接请求包含不允许的敏感或执行参数。"
        }
    }
}

public enum BastionHostDeepLinkParser {
    public static let maximumValidityInterval: TimeInterval = 5 * 60
    private static let forbiddenQueryNames = Set([
        "password", "passphrase", "private_key", "privatekey", "token", "secret",
        "command", "proxycommand", "script"
    ])

    public static func parse(
        _ url: URL,
        now: Date = Date(),
        supportedSchemes: Set<String> = StacioAppMetadata.supportedURLSchemes,
        signatureVerifier: BastionHostDeepLinkSignatureVerifying = BundleBastionHostDeepLinkSignatureVerifier()
    ) throws -> BastionHostDeepLinkRequest {
        guard let scheme = url.scheme?.lowercased(),
              supportedSchemes.contains(scheme),
              url.host?.lowercased() == "connect",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { throw BastionHostDeepLinkError.invalidRoute }

        let queryItems = components.queryItems ?? []
        if queryItems.contains(where: { forbiddenQueryNames.contains($0.name.lowercased()) }) {
            throw BastionHostDeepLinkError.unsafeParameter
        }
        guard let payloadText = queryItems.first(where: { $0.name == "payload" })?.value,
              let payloadData = base64URLData(payloadText)
        else { throw BastionHostDeepLinkError.invalidPayload }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let request = try? decoder.decode(BastionHostDeepLinkRequest.self, from: payloadData),
              request.vendor.trimmedNonEmpty != nil,
              request.gatewayHost.trimmedNonEmpty != nil,
              request.gatewayUsername.trimmedNonEmpty != nil,
              request.requestID.trimmedNonEmpty != nil,
              request.nonce.trimmedNonEmpty != nil,
              request.gatewayPort > 0
        else { throw BastionHostDeepLinkError.invalidPayload }

        guard request.version == 1 else { throw BastionHostDeepLinkError.unsupportedVersion }
        guard ["ssh", "sftp"].contains(request.protocolName.lowercased()) else {
            throw BastionHostDeepLinkError.unsupportedProtocol
        }
        guard request.expiresAt > now else { throw BastionHostDeepLinkError.expired }
        guard request.expiresAt.timeIntervalSince(now) <= maximumValidityInterval else {
            throw BastionHostDeepLinkError.validityTooLong
        }
        try signatureVerifier.verify(
            payload: payloadData,
            signature: queryItems.first(where: { $0.name == "signature" })?.value,
            vendor: request.vendor
        )
        return request
    }

    private static func base64URLData(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: base64)
    }
}

public protocol BastionHostDeepLinkSignatureVerifying {
    func verify(payload: Data, signature: String?, vendor: String) throws
}

public struct BundleBastionHostDeepLinkSignatureVerifier: BastionHostDeepLinkSignatureVerifying {
    public static let publicKeysInfoPlistKey = "StacioBastionVendorPublicKeys"

    private let publicKeys: [String: String]

    public init(bundle: Bundle = .main) {
        let configured = bundle.object(forInfoDictionaryKey: Self.publicKeysInfoPlistKey)
            as? [String: String] ?? [:]
        publicKeys = Dictionary(uniqueKeysWithValues: configured.map { ($0.key.lowercased(), $0.value) })
    }

    public init(publicKeys: [String: String]) {
        self.publicKeys = Dictionary(uniqueKeysWithValues: publicKeys.map { ($0.key.lowercased(), $0.value) })
    }

    public func verify(payload: Data, signature: String?, vendor: String) throws {
        guard let encodedPublicKey = publicKeys[vendor.lowercased()] else { return }
        guard let signature, let signatureData = base64URLData(signature) else {
            throw BastionHostDeepLinkError.signatureRequired
        }
        guard let keyData = Data(base64Encoded: encodedPublicKey),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              publicKey.isValidSignature(signatureData, for: payload)
        else { throw BastionHostDeepLinkError.invalidSignature }
    }

    private func base64URLData(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: base64)
    }
}

public protocol BastionHostRequestReplayProtecting {
    func consume(_ request: BastionHostDeepLinkRequest, now: Date) throws
}

public final class UserDefaultsBastionHostRequestReplayProtector: BastionHostRequestReplayProtecting {
    public static let defaultsKey = "Stacio.BastionHost.consumedRequests.v1"

    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func consume(_ request: BastionHostDeepLinkRequest, now: Date = Date()) throws {
        lock.lock()
        defer { lock.unlock() }

        var consumed = defaults.dictionary(forKey: Self.defaultsKey) as? [String: TimeInterval] ?? [:]
        consumed = consumed.filter { $0.value > now.timeIntervalSince1970 }
        let key = "\(request.vendor.lowercased())|\(request.requestID)|\(request.nonce)"
        guard consumed[key] == nil else { throw BastionHostDeepLinkError.replayed }
        consumed[key] = request.expiresAt.timeIntervalSince1970
        defaults.set(consumed, forKey: Self.defaultsKey)
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
