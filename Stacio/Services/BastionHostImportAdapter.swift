import Foundation

public enum BastionHostVendor: String, CaseIterable, Codable, Sendable {
    case jumpServer = "jumpserver"
    case topsec = "topsec"
    case sangfor = "sangfor"
    case qianxin = "qianxin"
    case qihoo360 = "360"
    case dbappsecurity = "dbappsecurity"
    case alibabaCloud = "alibaba_cloud"
    case tencentCloud = "tencent_cloud"
    case huaweiCloud = "huawei_cloud"
    case teleport
    case cyberArk = "cyberark"
    case beyondTrust = "beyondtrust"
    case custom

    public var displayName: String {
        switch self {
        case .jumpServer: return "JumpServer"
        case .topsec: return "天融信"
        case .sangfor: return "深信服"
        case .qianxin: return "奇安信"
        case .qihoo360: return "360 企业安全"
        case .dbappsecurity: return "安恒信息"
        case .alibabaCloud: return "阿里云堡垒机"
        case .tencentCloud: return "腾讯云堡垒机"
        case .huaweiCloud: return "华为云堡垒机"
        case .teleport: return "Teleport"
        case .cyberArk: return "CyberArk"
        case .beyondTrust: return "BeyondTrust"
        case .custom: return "其他 / 自定义"
        }
    }

    public static func identify(_ value: String) -> BastionHostVendor {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let aliases: [String: BastionHostVendor] = [
            "jumpserver": .jumpServer,
            "天融信": .topsec, "topsec": .topsec,
            "深信服": .sangfor, "sangfor": .sangfor,
            "奇安信": .qianxin, "qianxin": .qianxin,
            "360": .qihoo360, "360企业安全": .qihoo360,
            "安恒": .dbappsecurity, "dbappsecurity": .dbappsecurity,
            "阿里云": .alibabaCloud, "aliyun": .alibabaCloud, "alibaba_cloud": .alibabaCloud,
            "腾讯云": .tencentCloud, "tencent": .tencentCloud, "tencent_cloud": .tencentCloud,
            "华为云": .huaweiCloud, "huawei": .huaweiCloud, "huawei_cloud": .huaweiCloud,
            "teleport": .teleport,
            "cyberark": .cyberArk,
            "beyondtrust": .beyondTrust
        ]
        return aliases[normalized] ?? .custom
    }

    public static func detect(sourceName: String, contents: String) -> BastionHostVendor? {
        let haystack = "\(sourceName)\n\(contents.prefix(8_192))".lowercased()
        let markers: [(BastionHostVendor, [String])] = [
            (.jumpServer, ["jumpserver"]),
            (.topsec, ["topsec", "天融信"]),
            (.sangfor, ["sangfor", "深信服"]),
            (.qianxin, ["qianxin", "奇安信"]),
            (.dbappsecurity, ["dbappsecurity", "安恒"]),
            (.alibabaCloud, ["aliyun", "阿里云"]),
            (.tencentCloud, ["tencent cloud", "腾讯云"]),
            (.huaweiCloud, ["huawei cloud", "华为云"]),
            (.teleport, ["teleport"]),
            (.cyberArk, ["cyberark"]),
            (.beyondTrust, ["beyondtrust"]),
            (.qihoo360, ["360堡垒机", "360企业安全"])
        ]
        if let matched = markers.first(where: { marker in marker.1.contains(where: haystack.contains) })?.0 {
            return matched
        }
        return TopsecBastionRoute.first(in: contents) == nil ? nil : .topsec
    }
}

struct TopsecBastionRoute: Equatable, Sendable {
    let accountID: String
    let tenant: String
    let protocolName: String
    let targetUsername: String
    let targetHost: String
    let targetPort: UInt16

    init?(compositeUsername: String) {
        let components = compositeUsername
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "@", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard components.count >= 6,
              let targetPort = UInt16(components[components.count - 1]),
              targetPort > 0
        else { return nil }

        let protocolName = components[components.count - 4].lowercased()
        let targetUsername = components[components.count - 3]
        let targetHost = components[components.count - 2]
        let tenant = components[components.count - 5]
        let accountID = components.dropLast(5).joined(separator: "@")
        guard ["ssh", "sftp"].contains(protocolName),
              accountID.isEmpty == false,
              tenant.isEmpty == false,
              targetUsername.isEmpty == false,
              targetHost.isEmpty == false
        else { return nil }

        self.accountID = accountID
        self.tenant = tenant
        self.protocolName = protocolName
        self.targetUsername = targetUsername
        self.targetHost = targetHost
        self.targetPort = targetPort
    }

    static func first(in contents: String) -> TopsecBastionRoute? {
        for rawLine in contents.components(separatedBy: .newlines) {
            let value: Substring
            if let separator = rawLine.firstIndex(of: "=") {
                value = rawLine[rawLine.index(after: separator)...]
            } else {
                value = rawLine[...]
            }
            if let route = TopsecBastionRoute(compositeUsername: String(value)) {
                return route
            }
        }
        return nil
    }
}

public struct BastionHostConnectionManifest: Codable, Equatable, Sendable {
    public let format: String
    public let vendor: String
    public let sessions: [BastionHostConnectionManifestSession]
}

public struct BastionHostConnectionManifestSession: Codable, Equatable, Sendable {
    public let name: String
    public let protocolName: String
    public let gatewayHost: String
    public let gatewayPort: UInt16
    public let gatewayUsername: String
    public let targetHost: String?
    public let targetPort: UInt16?
    public let targetUsername: String?
    public let assetID: String?
    public let accountID: String?
    public let folderPath: String?

    enum CodingKeys: String, CodingKey {
        case name
        case protocolName = "protocol"
        case gatewayHost
        case gatewayPort
        case gatewayUsername
        case targetHost
        case targetPort
        case targetUsername
        case assetID = "assetId"
        case accountID = "accountId"
        case folderPath
    }
}

public enum BastionHostImportAdapter {
    public static let format = "stacio.bastion.v1"
    private static let forbiddenKeys = Set([
        "password", "passphrase", "privatekey", "private_key", "token", "secret", "command", "script"
    ])

    public static func parseManifest(_ text: String) throws -> ExternalSessionImportPayload {
        let data = Data(text.utf8)
        guard let object = try? JSONSerialization.jsonObject(with: data),
              containsForbiddenKey(object) == false
        else { throw ExternalSessionImportParserError.invalidFormat }

        let decoder = JSONDecoder()
        guard let manifest = try? decoder.decode(BastionHostConnectionManifest.self, from: data),
              manifest.format == format,
              manifest.sessions.isEmpty == false
        else { throw ExternalSessionImportParserError.invalidFormat }

        let vendor = BastionHostVendor.identify(manifest.vendor)
        let sessions = try manifest.sessions.map { session -> ExternalImportedSession in
            let protocolName = session.protocolName.lowercased()
            guard ["ssh", "sftp"].contains(protocolName),
                  session.name.trimmedNonEmpty != nil,
                  session.gatewayHost.trimmedNonEmpty != nil,
                  session.gatewayUsername.trimmedNonEmpty != nil,
                  session.gatewayPort > 0
            else { throw ExternalSessionImportParserError.invalidFormat }

            let configJSON = try metadataJSON(
                vendor: vendor,
                vendorIdentifier: manifest.vendor,
                session: session
            )
            return ExternalImportedSession(
                name: session.name,
                folderPath: session.folderPath,
                protocolName: protocolName,
                host: session.gatewayHost,
                port: session.gatewayPort,
                username: session.gatewayUsername,
                privateKeyPath: nil,
                credential: nil,
                configJSON: configJSON
            )
        }
        let warnings = vendor == .custom ? ["未识别厂商，将按通用堡垒机连接处理。"] : []
        return ExternalSessionImportPayload(sessions: sessions, warnings: warnings)
    }

    public static func addingDetectedVendorMetadata(
        to payload: ExternalSessionImportPayload,
        sourceName: String,
        contents: String
    ) -> ExternalSessionImportPayload {
        let vendor = BastionHostVendor.detect(sourceName: sourceName, contents: contents)
            ?? (payload.sessions.contains { session in
                session.username.flatMap(TopsecBastionRoute.init(compositeUsername:)) != nil
            } ? .topsec : nil)
        guard let vendor else {
            return payload
        }
        return addingVendorMetadata(to: payload, vendor: vendor, format: "external_session")
    }

    static func addingVendorMetadata(
        to payload: ExternalSessionImportPayload,
        vendor: BastionHostVendor,
        format: String
    ) -> ExternalSessionImportPayload {
        let sessions = payload.sessions.map { session in
            guard session.configJSON == nil else { return session }
            var metadata: [String: Any] = [
                "bastionVendor": vendor.rawValue,
                "bastionFormat": format
            ]
            if vendor == .topsec,
               let route = session.username.flatMap(TopsecBastionRoute.init(compositeUsername:)) {
                metadata["bastionTargetHost"] = route.targetHost
                metadata["bastionTargetPort"] = route.targetPort
                metadata["bastionTargetUsername"] = route.targetUsername
                metadata["bastionAccountId"] = route.accountID
            }
            let data = try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
            return ExternalImportedSession(
                name: session.name,
                folderPath: session.folderPath,
                protocolName: session.protocolName,
                host: session.host,
                port: session.port,
                username: session.username,
                privateKeyPath: session.privateKeyPath,
                credential: session.credential,
                configJSON: data.flatMap { String(data: $0, encoding: .utf8) }
            )
        }
        return ExternalSessionImportPayload(sessions: sessions, warnings: payload.warnings)
    }

    private static func metadataJSON(
        vendor: BastionHostVendor,
        vendorIdentifier: String,
        session: BastionHostConnectionManifestSession
    ) throws -> String {
        var metadata: [String: Any] = [
            "bastionVendor": vendor.rawValue,
            "bastionVendorIdentifier": vendorIdentifier,
            "bastionFormat": format
        ]
        if let value = session.targetHost { metadata["bastionTargetHost"] = value }
        if let value = session.targetPort { metadata["bastionTargetPort"] = value }
        if let value = session.targetUsername { metadata["bastionTargetUsername"] = value }
        if let value = session.assetID { metadata["bastionAssetId"] = value }
        if let value = session.accountID { metadata["bastionAccountId"] = value }
        return try String(
            data: JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]),
            encoding: .utf8
        ) ?? "{}"
    }

    private static func containsForbiddenKey(_ value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            return dictionary.contains { key, nested in
                forbiddenKeys.contains(key.lowercased()) || containsForbiddenKey(nested)
            }
        }
        if let array = value as? [Any] { return array.contains(where: containsForbiddenKey) }
        return false
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
