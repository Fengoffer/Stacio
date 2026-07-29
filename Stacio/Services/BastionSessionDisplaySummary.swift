import Foundation

struct BastionSessionDisplaySummary: Equatable {
    let primaryTarget: String
    let gatewayDetail: String?
    let vendor: BastionHostVendor?
    let gatewayHost: String
    let gatewayPort: UInt32
    let targetHost: String?
    let targetPort: UInt32?
    let targetUsername: String?
    let hasTargetMetadata: Bool

    var isBastionHost: Bool {
        vendor != nil || gatewayDetail != nil
    }

    var displayText: String {
        guard let gatewayDetail else { return primaryTarget }
        return "\(primaryTarget) · \(gatewayDetail)"
    }

    func routeIdentity(protocolName: String) -> String? {
        guard isBastionHost,
              let targetHost,
              let targetPort
        else { return nil }
        return [
            vendor?.rawValue ?? "custom",
            gatewayHost.lowercased(),
            String(gatewayPort),
            targetHost.lowercased(),
            String(targetPort),
            protocolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            targetUsername?.lowercased() ?? ""
        ].joined(separator: "|")
    }
}

enum BastionSessionDisplaySummaryCodec {
    static func summary(
        protocolName: String,
        gatewayHost: String,
        gatewayPort: UInt32,
        gatewayUsername: String?,
        configJSON: String?
    ) -> BastionSessionDisplaySummary {
        let normalizedGatewayHost = normalized(gatewayHost) ?? gatewayHost
        let metadata = metadataDictionary(configJSON)
        let vendor = metadata["bastionVendor"]
            .flatMap(stringValue)
            .map(BastionHostVendor.identify)
        let hasBastionMarker = vendor != nil
            || metadata["bastionFormat"] != nil
            || metadata["bastionTargetHost"] != nil
        let compositeRoute = gatewayUsername.flatMap(TopsecBastionRoute.init(compositeUsername:))
        let targetHost = metadata["bastionTargetHost"].flatMap(stringValue).flatMap(normalized)
            ?? compositeRoute?.targetHost
        let targetPort = metadata["bastionTargetPort"].flatMap(portValue)
            ?? compositeRoute.map { UInt32($0.targetPort) }
        let metadataTargetUsername = metadata["bastionTargetUsername"].flatMap(stringValue)
        let targetUsername = safeUsername(metadataTargetUsername)
            ?? safeUsername(compositeRoute?.targetUsername)
        let inferredVendor = vendor ?? (compositeRoute == nil ? nil : .topsec)
        let isBastion = hasBastionMarker || compositeRoute != nil

        guard isBastion else {
            let endpoint = endpointText(
                host: normalizedGatewayHost,
                port: gatewayPort,
                username: safeUsername(gatewayUsername)
            )
            return BastionSessionDisplaySummary(
                primaryTarget: endpoint,
                gatewayDetail: nil,
                vendor: nil,
                gatewayHost: normalizedGatewayHost,
                gatewayPort: gatewayPort,
                targetHost: nil,
                targetPort: nil,
                targetUsername: nil,
                hasTargetMetadata: false
            )
        }

        let primaryTarget: String
        if let targetHost {
            primaryTarget = endpointText(
                host: targetHost,
                port: targetPort ?? defaultPort(for: protocolName),
                username: targetUsername
            )
        } else {
            primaryTarget = "目标信息不可用"
        }
        return BastionSessionDisplaySummary(
            primaryTarget: primaryTarget,
            gatewayDetail: "经由 \(hostPortText(host: normalizedGatewayHost, port: gatewayPort))",
            vendor: inferredVendor,
            gatewayHost: normalizedGatewayHost,
            gatewayPort: gatewayPort,
            targetHost: targetHost,
            targetPort: targetHost == nil ? nil : (targetPort ?? defaultPort(for: protocolName)),
            targetUsername: targetUsername,
            hasTargetMetadata: targetHost != nil
        )
    }

    private static func metadataDictionary(_ configJSON: String?) -> [String: Any] {
        guard let configJSON,
              let data = configJSON.data(using: .utf8),
              let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return dictionary
    }

    private static func stringValue(_ value: Any) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private static func portValue(_ value: Any) -> UInt32? {
        if let number = value as? NSNumber {
            let port = number.uint32Value
            return port > 0 && port <= UInt32(UInt16.max) ? port : nil
        }
        if let text = value as? String,
           let port = UInt32(text),
           port > 0,
           port <= UInt32(UInt16.max) {
            return port
        }
        return nil
    }

    private static func safeUsername(_ value: String?) -> String? {
        guard let value = normalized(value) else { return nil }
        return value.filter { $0 == "@" }.count > 1 ? nil : value
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private static func endpointText(host: String, port: UInt32, username: String?) -> String {
        let endpoint = hostPortText(host: host, port: port)
        guard let username else { return endpoint }
        return "\(username)@\(endpoint)"
    }

    private static func hostPortText(host: String, port: UInt32) -> String {
        let displayHost = host.contains(":") && host.hasPrefix("[") == false ? "[\(host)]" : host
        return "\(displayHost):\(port)"
    }

    private static func defaultPort(for protocolName: String) -> UInt32 {
        switch protocolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "telnet": return 23
        case "vnc": return 5900
        default: return 22
        }
    }
}
