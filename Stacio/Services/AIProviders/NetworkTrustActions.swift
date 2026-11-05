import Foundation

// MARK: - 网络信任动作（P4-7）

/// 证书摘要（CA subject/issuer/SAN/fingerprint 展示用）。
public struct CertificateSummary: Equatable, Sendable {
    public let subject: String
    public let issuer: String
    public let sanHosts: [String]
    public let fingerprintSHA256: String

    public init(subject: String, issuer: String, sanHosts: [String], fingerprintSHA256: String) {
        self.subject = subject
        self.issuer = issuer
        self.sanHosts = sanHosts
        self.fingerprintSHA256 = fingerprintSHA256
    }
}

/// 网络信任绑定：精确 revision + normalized origin。
public struct NetworkTrustBinding: Equatable, Sendable {
    public let configurationRevision: Int
    public let normalizedOrigin: String

    public init(configurationRevision: Int, normalizedOrigin: String) {
        self.configurationRevision = configurationRevision
        self.normalizedOrigin = normalizedOrigin
    }
}

public enum NetworkTrustActionError: Error, Equatable {
    case publicHTTPRejected
    case revisionMismatch(expected: Int, actual: Int)
    case fingerprintMismatch
    /// 绝不提供跳过证书链/主机名校验的选项。
    case skipVerificationNotOffered
}

public enum NetworkTrustAction {

    /// `configuration.changeNetworkTrust` 绑定精确 revision + normalized origin。
    public static func bind(
        configurationRevision: Int, baseURL: URL, currentRevision: Int
    ) -> Result<NetworkTrustBinding, NetworkTrustActionError> {
        guard configurationRevision == currentRevision else {
            return .failure(.revisionMismatch(expected: configurationRevision, actual: currentRevision))
        }
        guard let origin = WebsiteActionResolver.normalizedOrigin(url: baseURL) else {
            return .failure(.publicHTTPRejected)
        }
        return .success(NetworkTrustBinding(configurationRevision: configurationRevision, normalizedOrigin: origin))
    }

    /// 公网 HTTP 拒绝（仅 loopback 允许 HTTP——内网 HTTP 需显式 allowLanHTTP 设置）。
    public static func allowsHTTP(origin: String) -> Bool {
        let host = origin.split(separator: "://").last.map(String.init) ?? ""
        return host.hasPrefix("localhost") || host.hasPrefix("127.") || host.hasPrefix("[::1]")
    }

    /// verification fingerprint 失效：期望值与实际值不匹配 → 失效（拒绝信任）。
    public static func fingerprintValid(expected: String, actual: String) -> Bool {
        expected == actual
    }

    /// 展示字段：CA subject/issuer/SAN/fingerprint。
    public static func displayFields(certificate: CertificateSummary) -> [String] {
        [
            "subject:\(certificate.subject)",
            "issuer:\(certificate.issuer)",
            "san:\(certificate.sanHosts.joined(separator: ","))",
            "fingerprint:\(certificate.fingerprintSHA256)"
        ]
    }

    /// 绝不提供跳过证书链/主机名校验（无此选项）。
    public static func skipCertificateVerificationOffered() -> Bool { false }
}
