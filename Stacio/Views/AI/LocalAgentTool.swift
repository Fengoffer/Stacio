import Foundation

public enum LocalAgentTool: String, CaseIterable, Hashable {
    case codex
    case claude
    case opencode
    case mimoCode
    case zcode
    case qwenCode

    public var displayName: String {
        switch self {
        case .codex:
            return "Codex"
        case .claude:
            return "Claude"
        case .opencode:
            return "OpenCode"
        case .mimoCode:
            return "MiMo Code"
        case .zcode:
            return "ZCode"
        case .qwenCode:
            return "Qwen Code"
        }
    }

    public var executableNames: [String] {
        switch self {
        case .codex:
            return ["codex"]
        case .claude:
            return ["claude"]
        case .opencode:
            return ["opencode", "open-code"]
        case .mimoCode:
            // 官方 CLI 入口为 mimo；mimocode/mimo-code 兼容别名待确认。
            return ["mimo", "mimocode", "mimo-code"]
        case .zcode:
            // 待确认：ZCode 官方主要分发桌面 Agent，命令行别名按常见命名预留。
            return ["zcode", "z-code"]
        case .qwenCode:
            // 官方 CLI 入口为 qwen；qwen-code 兼容别名待确认。
            return ["qwen", "qwen-code"]
        }
    }

    public func commonExecutablePaths(homeDirectory: String) -> [String] {
        let home = homeDirectory.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let rootedHome = home.isEmpty ? homeDirectory : "/\(home)"
        switch self {
        case .codex:
            return [
                "\(rootedHome)/.hermes/node/bin/codex",
                "\(rootedHome)/.local/bin/codex",
                "/opt/homebrew/bin/codex",
                "/usr/local/bin/codex"
            ]
        case .claude:
            return [
                "\(rootedHome)/.hermes/node/bin/claude",
                "\(rootedHome)/.local/bin/claude",
                "/opt/homebrew/bin/claude",
                "/usr/local/bin/claude"
            ]
        case .opencode:
            return [
                "\(rootedHome)/.opencode/bin/opencode",
                "\(rootedHome)/.local/bin/opencode",
                "/opt/homebrew/bin/opencode",
                "/usr/local/bin/opencode",
                "/opt/homebrew/bin/open-code",
                "/usr/local/bin/open-code"
            ]
        case .mimoCode:
            // 待确认：~/.mimo/bin 是按常见自带安装器布局预留的候选目录。
            return [
                "\(rootedHome)/.mimo/bin/mimo",
                "\(rootedHome)/.local/bin/mimo",
                "\(rootedHome)/.local/bin/mimocode",
                "/opt/homebrew/bin/mimo",
                "/opt/homebrew/bin/mimocode",
                "/usr/local/bin/mimo",
                "/usr/local/bin/mimocode",
                "/opt/homebrew/bin/mimo-code",
                "/usr/local/bin/mimo-code"
            ]
        case .zcode:
            // 待确认：保留桌面 App 内部二进制与可能的 PATH 别名候选。
            return [
                "\(rootedHome)/.local/bin/zcode",
                "\(rootedHome)/.local/bin/z-code",
                "/Applications/ZCode.app/Contents/MacOS/ZCode",
                "/opt/homebrew/bin/zcode",
                "/opt/homebrew/bin/z-code",
                "/usr/local/bin/zcode",
                "/usr/local/bin/z-code"
            ]
        case .qwenCode:
            // 待确认：~/.qwen/bin 是按 CLI 专用安装目录预留的候选目录。
            return [
                "\(rootedHome)/.qwen/bin/qwen",
                "\(rootedHome)/.local/bin/qwen",
                "\(rootedHome)/.local/bin/qwen-code",
                "/opt/homebrew/bin/qwen",
                "/opt/homebrew/bin/qwen-code",
                "/usr/local/bin/qwen",
                "/usr/local/bin/qwen-code"
            ]
        }
    }
}

public protocol LocalAgentToolResolving {
    func executablePath(for tool: LocalAgentTool) -> String?
}

public struct LocalAgentToolResolver: LocalAgentToolResolving {
    private let environment: [String: String]
    private let homeDirectory: String
    private let isExecutable: (String) -> Bool

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory(),
        isExecutable: @escaping (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.isExecutable = isExecutable
    }

    public func executablePath(for tool: LocalAgentTool) -> String? {
        let candidates = tool.commonExecutablePaths(homeDirectory: homeDirectory)
            + pathExecutableCandidates(for: tool)
        return candidates.first(where: isExecutable)
    }

    private func pathExecutableCandidates(for tool: LocalAgentTool) -> [String] {
        let path = environment["PATH"] ?? ""
        return path
            .split(separator: ":")
            .flatMap { directory in
                tool.executableNames.map { "\(directory)/\($0)" }
            }
    }
}
