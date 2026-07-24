import Foundation

public enum StacioLicenseEntitlement {
    public static let multiExec = "multi_exec"
    public static let aiAgent = "ai_agent"
    public static let bastionHost = "bastion_host"
    public static let sshTunnel = "ssh_tunnel"
    public static let advancedMetrics = "advanced_metrics"
    public static let fileSync = "file_sync"
    public static let proxyJump = "proxy_jump"
    public static let sessionBulkIO = "session_bulk_io"
}

public enum LicensedFeatureAccessError: LocalizedError, Equatable {
    case licenseRequired(StacioLicensedFeature)

    public var errorDescription: String? {
        "该功能模块无有效授权，请升级授权。"
    }
}

public protocol LicensedFeatureAuthorizing {
    func authorize(_ feature: StacioLicensedFeature) throws
}

public struct LicenseFeatureAuthorizer: LicensedFeatureAuthorizing {
    private let accessProvider: any LicenseFeatureAccessProviding

    public init(accessProvider: any LicenseFeatureAccessProviding = LocalLicenseFeatureAccessProvider()) {
        self.accessProvider = accessProvider
    }

    public func authorize(_ feature: StacioLicensedFeature) throws {
        guard accessProvider.isEnabled(feature) else {
            throw LicensedFeatureAccessError.licenseRequired(feature)
        }
    }
}

public enum BastionHostFeatureAccessError: LocalizedError, Equatable {
    case licenseRequired

    public var errorDescription: String? {
        "堡垒机连接需要导入有效的 Stacio 专业版或企业版 License。"
    }
}

public protocol BastionHostFeatureAuthorizing {
    func authorizeBastionHostAccess() throws
}

public struct LicenseBastionHostFeatureAuthorizer: BastionHostFeatureAuthorizing {
    private let accessProvider: any LicenseFeatureAccessProviding

    public init(accessProvider: any LicenseFeatureAccessProviding = LocalLicenseFeatureAccessProvider()) {
        self.accessProvider = accessProvider
    }

    public init(
        stateProvider: @escaping () throws -> LicenseState?,
        nowProvider: @escaping () -> Date = Date.init
    ) {
        accessProvider = ImmediateLicenseFeatureAccessProvider(
            stateProvider: stateProvider,
            nowProvider: nowProvider
        )
    }

    public func authorizeBastionHostAccess() throws {
        guard accessProvider.isEnabled(.bastionHost) else {
            throw BastionHostFeatureAccessError.licenseRequired
        }
    }
}

private struct ImmediateLicenseFeatureAccessProvider: LicenseFeatureAccessProviding {
    let stateProvider: () throws -> LicenseState?
    let nowProvider: () -> Date

    func isEnabled(_ feature: StacioLicensedFeature) -> Bool {
        guard let state = try? stateProvider() else { return false }
        return state.enables(feature, at: nowProvider())
    }
}

public enum BastionHostSessionDetector {
    public static func containsBastionHostSession(_ payload: ExternalSessionImportPayload) -> Bool {
        payload.sessions.contains { session in
            guard let username = session.username?.trimmingCharacters(in: .whitespacesAndNewlines),
                  username.isEmpty == false
            else { return false }

            let components = username.split(separator: "@", omittingEmptySubsequences: false)
            return components.count >= 3
                || username.uppercased().hasPrefix("SSH@")
                || username.uppercased().hasPrefix("SFTP@")
        }
    }
}
