import Foundation

public enum WorkspaceCapability: CaseIterable, Hashable, Sendable {
    case deviceDashboard
    case browser
    case tunnels
    case files
    case ai
    case diagnostics
}

public enum WorkspaceSessionProtocol: Equatable, Sendable {
    case noSession
    case local
    case browser
    case ssh
    case scp
    case sftp
    case vnc
    case serial
    case console
    case telnet
    case unsupportedRemote(String)
    case unmanaged

    public init(remoteProtocolName: String) {
        let normalized = remoteProtocolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "ssh": self = .ssh
        case "scp": self = .scp
        case "sftp": self = .sftp
        case "vnc": self = .vnc
        case "serial": self = .serial
        case "console": self = .console
        case "telnet": self = .telnet
        default: self = .unsupportedRemote(normalized)
        }
    }
}

public enum WorkspaceCapabilityPolicy {
    public static func allows(
        _ capability: WorkspaceCapability,
        for sessionProtocol: WorkspaceSessionProtocol
    ) -> Bool {
        switch sessionProtocol {
        case .ssh, .noSession, .local, .browser, .unmanaged:
            return true
        case .console:
            return capability == .ai || capability == .diagnostics
        case .scp, .sftp, .vnc, .serial, .telnet, .unsupportedRemote:
            return false
        }
    }
}
