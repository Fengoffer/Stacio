import Foundation

public enum WorkspaceSessionGroupKind: String, Codable, Equatable, Sendable {
    case scp
    case sftp
    case terminalSplit = "terminal_split"
    case terminalMultiExec = "terminal_multi_exec"

    public init?(sessionProtocol: String) {
        switch sessionProtocol.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "scp-group":
            self = .scp
        case "sftp-group":
            self = .sftp
        case "terminal-group":
            self = .terminalSplit
        case "multi-exec-group":
            self = .terminalMultiExec
        default:
            return nil
        }
    }

    public var sessionProtocol: String {
        switch self {
        case .scp:
            return "scp-group"
        case .sftp:
            return "sftp-group"
        case .terminalSplit:
            return "terminal-group"
        case .terminalMultiExec:
            return "multi-exec-group"
        }
    }

    public var displayName: String {
        switch self {
        case .scp:
            return "SCP 分组"
        case .sftp:
            return "SFTP 分组"
        case .terminalSplit:
            return "终端分屏分组"
        case .terminalMultiExec:
            return "终端多执行分组"
        }
    }
}

public enum WorkspaceSessionGroupLayout: String, Codable, Equatable, Sendable {
    case columns
    case grid
    case vertical
    case horizontal
}

public enum WorkspaceSessionGroupPaneKind: String, Codable, Equatable, Sendable {
    case localDirectory = "local_directory"
    case remoteSession = "remote_session"
    case localTerminal = "local_terminal"
    case terminalSession = "terminal_session"
}

public struct WorkspaceSessionGroupPane: Codable, Equatable, Sendable {
    public let kind: WorkspaceSessionGroupPaneKind
    public let sessionID: String?
    public let path: String?

    public init(
        kind: WorkspaceSessionGroupPaneKind,
        sessionID: String? = nil,
        path: String? = nil
    ) {
        self.kind = kind
        self.sessionID = sessionID
        self.path = path
    }

    public static func localDirectory(path: String) -> Self {
        Self(kind: .localDirectory, path: path)
    }

    public static func remoteSession(sessionID: String, path: String) -> Self {
        Self(kind: .remoteSession, sessionID: sessionID, path: path)
    }

    public static func localTerminal(path: String?) -> Self {
        Self(kind: .localTerminal, path: path)
    }

    public static func terminalSession(sessionID: String) -> Self {
        Self(kind: .terminalSession, sessionID: sessionID)
    }

    public var isRestorable: Bool {
        switch kind {
        case .localDirectory:
            return Self.hasText(path)
        case .remoteSession, .terminalSession:
            return Self.hasText(sessionID)
        case .localTerminal:
            return true
        }
    }

    private static func hasText(_ value: String?) -> Bool {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}

public struct WorkspaceSessionGroupDefinition: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let minimumPaneCountForSaveOffer = 4

    public let schemaVersion: Int
    public let kind: WorkspaceSessionGroupKind
    public let layout: WorkspaceSessionGroupLayout
    public let panes: [WorkspaceSessionGroupPane]

    public init(
        schemaVersion: Int = currentSchemaVersion,
        kind: WorkspaceSessionGroupKind,
        layout: WorkspaceSessionGroupLayout,
        panes: [WorkspaceSessionGroupPane]
    ) {
        self.schemaVersion = schemaVersion
        self.kind = kind
        self.layout = layout
        self.panes = panes
    }

    public var sessionProtocol: String {
        kind.sessionProtocol
    }

    public var displayName: String {
        kind.displayName
    }

    public var shouldOfferSaveOnClose: Bool {
        panes.count >= Self.minimumPaneCountForSaveOffer
    }

    public var isRestorable: Bool {
        panes.isEmpty == false && panes.allSatisfy(\.isRestorable)
    }

    public var paneCountDescription: String {
        switch kind {
        case .scp, .sftp:
            return "\(panes.count) 个文件面板"
        case .terminalSplit, .terminalMultiExec:
            return "\(panes.count) 个终端"
        }
    }
}

public enum WorkspaceSessionGroupCodecError: Error, Equatable, LocalizedError {
    case invalidConfiguration
    case unsupportedSchemaVersion(Int)
    case incompatibleLayout
    case unrestorablePane

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "分组会话配置无效。"
        case .unsupportedSchemaVersion:
            return "该分组会话由更高版本的 Stacio 创建，当前版本无法打开。"
        case .incompatibleLayout:
            return "分组会话的布局与会话类型不匹配。"
        case .unrestorablePane:
            return "分组中包含未保存的远端会话，请先将远端连接保存为会话后再保存分组。"
        }
    }
}

public enum WorkspaceSessionGroupSaveError: Error, LocalizedError {
    case persistenceUnavailable

    public var errorDescription: String? {
        "当前窗口无法保存分组会话，请重新打开 Stacio 后再试。"
    }
}

public enum WorkspaceSessionGroupCodec {
    private struct Envelope: Codable {
        let workspaceGroup: WorkspaceSessionGroupDefinition
    }

    public static func encode(_ definition: WorkspaceSessionGroupDefinition) throws -> String {
        try validate(definition)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Envelope(workspaceGroup: definition))
        guard let json = String(data: data, encoding: .utf8) else {
            throw WorkspaceSessionGroupCodecError.invalidConfiguration
        }
        return json
    }

    public static func decode(_ json: String) throws -> WorkspaceSessionGroupDefinition {
        guard let data = json.data(using: .utf8) else {
            throw WorkspaceSessionGroupCodecError.invalidConfiguration
        }
        let definition: WorkspaceSessionGroupDefinition
        do {
            definition = try JSONDecoder().decode(Envelope.self, from: data).workspaceGroup
        } catch {
            throw WorkspaceSessionGroupCodecError.invalidConfiguration
        }
        try validate(definition)
        return definition
    }

    public static func validate(_ definition: WorkspaceSessionGroupDefinition) throws {
        guard definition.schemaVersion == WorkspaceSessionGroupDefinition.currentSchemaVersion else {
            throw WorkspaceSessionGroupCodecError.unsupportedSchemaVersion(definition.schemaVersion)
        }
        let layoutIsCompatible: Bool
        switch definition.kind {
        case .scp, .sftp:
            layoutIsCompatible = definition.layout == .columns || definition.layout == .grid
        case .terminalSplit, .terminalMultiExec:
            layoutIsCompatible = definition.layout == .vertical
                || definition.layout == .horizontal
                || definition.layout == .grid
        }
        guard layoutIsCompatible else {
            throw WorkspaceSessionGroupCodecError.incompatibleLayout
        }
        let panesAreCompatible: Bool
        switch definition.kind {
        case .scp, .sftp:
            panesAreCompatible = definition.panes.contains { $0.kind == .remoteSession }
                && definition.panes.allSatisfy {
                    $0.kind == .localDirectory || $0.kind == .remoteSession
                }
        case .terminalSplit, .terminalMultiExec:
            panesAreCompatible = definition.panes.count >= 2
                && definition.panes.allSatisfy {
                    $0.kind == .localTerminal || $0.kind == .terminalSession
                }
        }
        guard panesAreCompatible else {
            throw WorkspaceSessionGroupCodecError.invalidConfiguration
        }
        guard definition.isRestorable else {
            throw WorkspaceSessionGroupCodecError.unrestorablePane
        }
    }
}
