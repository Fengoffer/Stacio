import Foundation

public enum TerminalCommandCompletionKind: Equatable {
    case command
    case history
    case path
}

public struct TerminalCommandCompletionChoice: Equatable {
    public let replacement: String
    public let insertion: String
    public let displayCommand: String
    public let detail: String
    public let kind: TerminalCommandCompletionKind

    public init(
        replacement: String,
        displayCommand: String,
        detail: String,
        insertion: String = "",
        kind: TerminalCommandCompletionKind = .command
    ) {
        self.replacement = replacement
        self.insertion = insertion
        self.displayCommand = displayCommand
        self.detail = detail
        self.kind = kind
    }
}

public struct TerminalCommandCompletionSuggestion: Equatable {
    public let replacement: String
    public let displayCommand: String
    public let detail: String
    public let choices: [TerminalCommandCompletionChoice]
    public let selectedIndex: Int
    private let fallbackInsertion: String

    public init(
        replacement: String,
        insertion: String,
        displayCommand: String,
        detail: String,
        choices: [TerminalCommandCompletionChoice] = [],
        selectedIndex: Int = 0,
        kind: TerminalCommandCompletionKind = .command
    ) {
        let fallbackChoice = TerminalCommandCompletionChoice(
            replacement: replacement,
            displayCommand: displayCommand,
            detail: detail,
            insertion: insertion,
            kind: kind
        )
        let normalizedChoices = choices.isEmpty ? [fallbackChoice] : choices
        let boundedIndex = min(max(selectedIndex, 0), normalizedChoices.count - 1)
        let selectedChoice = normalizedChoices[boundedIndex]
        self.replacement = selectedChoice.replacement
        self.displayCommand = selectedChoice.displayCommand
        self.detail = selectedChoice.detail
        self.choices = normalizedChoices
        self.selectedIndex = boundedIndex
        self.fallbackInsertion = selectedChoice.insertion.isEmpty ? insertion : selectedChoice.insertion
    }

    public var selectedChoice: TerminalCommandCompletionChoice {
        choices[selectedIndex]
    }

    public var insertion: String {
        selectedChoice.insertion.isEmpty ? fallbackInsertion : selectedChoice.insertion
    }

    public func selecting(index: Int) -> TerminalCommandCompletionSuggestion {
        TerminalCommandCompletionSuggestion(
            replacement: replacement,
            insertion: insertion,
            displayCommand: displayCommand,
            detail: detail,
            choices: choices,
            selectedIndex: index
        )
    }

    public func selectingNext() -> TerminalCommandCompletionSuggestion {
        guard choices.isEmpty == false else { return self }
        return selecting(index: (selectedIndex + 1) % choices.count)
    }

    public func selectingPrevious() -> TerminalCommandCompletionSuggestion {
        guard choices.isEmpty == false else { return self }
        return selecting(index: (selectedIndex - 1 + choices.count) % choices.count)
    }

    public var visibleText: String {
        let rows = choices.prefix(5).enumerated().map { index, choice in
            let marker = index == selectedIndex ? "↵" : " "
            let key = index == selectedIndex ? "Tab" : "⌥\(index + 1)"
            return "\(marker) \(key)  \(choice.displayCommand)  ·  \(choice.detail)"
        }
        return (
            ["联想补全  ·  \(choices.count) 条匹配"]
            + rows
            + ["↑↓ 选择  ·  Enter 执行  ·  Tab 填充  ·  Esc 关闭"]
        ).joined(separator: "\n")
    }
}

public struct TerminalPathCompletionRequest: Equatable {
    public let parentPath: String
    public let namePrefix: String

    public init(parentPath: String, namePrefix: String) {
        self.parentPath = parentPath
        self.namePrefix = namePrefix
    }
}

public struct TerminalPathCompletionCandidate: Equatable {
    public let name: String
    public let isDirectory: Bool

    public init(name: String, isDirectory: Bool) {
        self.name = name
        self.isDirectory = isDirectory
    }
}

public protocol TerminalPathCompletionProviding {
    func candidates(for request: TerminalPathCompletionRequest) throws -> [TerminalPathCompletionCandidate]
}

public struct LocalTerminalPathCompletionProvider: TerminalPathCompletionProviding {
    private let currentDirectory: String?
    private let fileManager: FileManager

    public init(currentDirectory: String?, fileManager: FileManager = .default) {
        self.currentDirectory = currentDirectory
        self.fileManager = fileManager
    }

    public func candidates(for request: TerminalPathCompletionRequest) throws -> [TerminalPathCompletionCandidate] {
        let directoryURL = resolvedURL(for: request.parentPath)
        let urls = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )
        let showsHiddenFiles = request.namePrefix.hasPrefix(".")
        return urls.compactMap { url -> TerminalPathCompletionCandidate? in
            let name = url.lastPathComponent
            guard name.isEmpty == false,
                  showsHiddenFiles || name.hasPrefix(".") == false,
                  name.range(of: request.namePrefix, options: [.caseInsensitive, .anchored]) != nil,
                  name.caseInsensitiveCompare(request.namePrefix) != .orderedSame
            else {
                return nil
            }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            return TerminalPathCompletionCandidate(name: name, isDirectory: values?.isDirectory == true)
        }
        .sorted(by: Self.sortCandidates)
    }

    private func resolvedURL(for path: String) -> URL {
        let normalizedPath = path.isEmpty ? "." : path
        if normalizedPath == "~" {
            return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        }
        if normalizedPath.hasPrefix("~/") {
            return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent(String(normalizedPath.dropFirst(2)), isDirectory: true)
        }
        if normalizedPath.hasPrefix("/") {
            return URL(fileURLWithPath: normalizedPath, isDirectory: true)
        }
        let basePath = currentDirectory.flatMap { TerminalCurrentDirectoryNormalizer.normalize($0) }
            ?? fileManager.currentDirectoryPath
        return URL(fileURLWithPath: basePath, isDirectory: true)
            .appendingPathComponent(normalizedPath, isDirectory: true)
    }

    private static func sortCandidates(
        _ lhs: TerminalPathCompletionCandidate,
        _ rhs: TerminalPathCompletionCandidate
    ) -> Bool {
        if lhs.isDirectory != rhs.isDirectory {
            return lhs.isDirectory && !rhs.isDirectory
        }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
}

public enum TerminalCommandCompletionEngine {
    private struct Candidate {
        let replacement: String
        let detail: String
    }

    private struct Token {
        let text: String
        let range: Range<String.Index>
    }

    private struct PathCompletionContext {
        let token: Token
        let rawToken: String
        let tokenPrefix: String
        let displayParentPath: String
        let request: TerminalPathCompletionRequest
    }

    private static let wrappers: Set<String> = ["sudo", "doas", "env", "time", "command", "nohup", "nice"]
    private static let operators: Set<String> = ["|", "||", "&&", ";", ">", ">>", "<", "2>", "2>>", "&>"]
    private static let pathAwareCommands: Set<String> = [
        "cd", "ls", "ll", "la", "cat", "less", "more", "tail", "head",
        "vim", "vi", "nano", "emacs", "code", "open", "rm", "cp", "mv",
        "mkdir", "rmdir", "touch", "chmod", "chown", "tar", "du", "find",
        "grep", "rg", "sed", "awk", "scp", "rsync"
    ]

    private static let commandCandidates: [Candidate] = [
        Candidate(replacement: "systemctl", detail: "Linux 服务管理"),
        Candidate(replacement: "journalctl", detail: "Linux 日志查看"),
        Candidate(replacement: "service", detail: "SysV/systemd 服务兼容入口"),
        Candidate(replacement: "apt", detail: "Linux 包管理（Debian/Ubuntu）"),
        Candidate(replacement: "apt-get", detail: "Linux 包管理（Debian/Ubuntu 兼容）"),
        Candidate(replacement: "dpkg", detail: "Linux 包管理（Debian/Ubuntu）"),
        Candidate(replacement: "dnf", detail: "Linux 包管理（Fedora/RHEL/CentOS/openEuler/Anolis）"),
        Candidate(replacement: "yum", detail: "Linux 包管理（RHEL/CentOS 7/Anolis）"),
        Candidate(replacement: "rpm", detail: "Linux 包管理（RPM 系）"),
        Candidate(replacement: "zypper", detail: "Linux 包管理（SUSE/openSUSE）"),
        Candidate(replacement: "pacman", detail: "Linux 包管理（Arch）"),
        Candidate(replacement: "apk", detail: "Linux 包管理（Alpine）"),
        Candidate(replacement: "docker", detail: "Linux 容器运行时"),
        Candidate(replacement: "docker-compose", detail: "Linux Compose 兼容命令"),
        Candidate(replacement: "podman", detail: "Linux 容器运行时"),
        Candidate(replacement: "nerdctl", detail: "Linux containerd 客户端"),
        Candidate(replacement: "kubectl", detail: "Linux Kubernetes 管理"),
        Candidate(replacement: "helm", detail: "Linux Kubernetes 包管理"),
        Candidate(replacement: "crictl", detail: "Linux CRI 调试"),
        Candidate(replacement: "ctr", detail: "Linux containerd 调试"),
        Candidate(replacement: "ip", detail: "Linux 网络接口/路由"),
        Candidate(replacement: "ss", detail: "Linux 网络连接查看"),
        Candidate(replacement: "netstat", detail: "Linux 网络连接兼容查看"),
        Candidate(replacement: "ping", detail: "Linux 网络连通性"),
        Candidate(replacement: "traceroute", detail: "Linux 路由追踪"),
        Candidate(replacement: "dig", detail: "Linux DNS 查询"),
        Candidate(replacement: "nslookup", detail: "Linux DNS 查询"),
        Candidate(replacement: "firewall-cmd", detail: "Linux 防火墙（firewalld）"),
        Candidate(replacement: "ufw", detail: "Linux 防火墙（Ubuntu）"),
        Candidate(replacement: "iptables", detail: "Linux 防火墙"),
        Candidate(replacement: "nft", detail: "Linux 防火墙（nftables）"),
        Candidate(replacement: "ls", detail: "Linux 文件列表"),
        Candidate(replacement: "cd", detail: "Linux 目录切换"),
        Candidate(replacement: "pwd", detail: "Linux 当前目录"),
        Candidate(replacement: "cat", detail: "Linux 文件查看"),
        Candidate(replacement: "less", detail: "Linux 分页查看"),
        Candidate(replacement: "tail", detail: "Linux 日志尾部查看"),
        Candidate(replacement: "head", detail: "Linux 文件头部查看"),
        Candidate(replacement: "grep", detail: "Linux 文本搜索"),
        Candidate(replacement: "find", detail: "Linux 文件搜索"),
        Candidate(replacement: "awk", detail: "Linux 文本处理"),
        Candidate(replacement: "sed", detail: "Linux 文本处理"),
        Candidate(replacement: "tar", detail: "Linux 归档压缩"),
        Candidate(replacement: "df", detail: "Linux 磁盘空间"),
        Candidate(replacement: "du", detail: "Linux 目录占用"),
        Candidate(replacement: "free", detail: "Linux 内存查看"),
        Candidate(replacement: "ps", detail: "Linux 进程查看"),
        Candidate(replacement: "top", detail: "Linux 进程监控"),
        Candidate(replacement: "htop", detail: "Linux 进程监控"),
        Candidate(replacement: "curl", detail: "Linux HTTP 请求"),
        Candidate(replacement: "wget", detail: "Linux 下载"),
        Candidate(replacement: "ssh", detail: "Linux SSH 连接"),
        Candidate(replacement: "scp", detail: "Linux 安全复制"),
        Candidate(replacement: "rsync", detail: "Linux 增量同步"),
        Candidate(replacement: "git", detail: "Linux Git 版本控制"),
        Candidate(replacement: "ansible", detail: "Linux 自动化"),
        Candidate(replacement: "ansible-playbook", detail: "Linux 自动化剧本"),
        Candidate(replacement: "terraform", detail: "Linux IaC"),
        Candidate(replacement: "tofu", detail: "Linux IaC")
    ]

    private static let subcommandCandidates: [String: [Candidate]] = [
        "apt": packageManagerCandidates(detail: "Linux 包管理（Debian/Ubuntu）"),
        "apt-get": packageManagerCandidates(detail: "Linux 包管理（Debian/Ubuntu 兼容）"),
        "dnf": packageManagerCandidates(detail: "Linux 包管理（Fedora/RHEL/CentOS/openEuler/Anolis）"),
        "yum": packageManagerCandidates(detail: "Linux 包管理（RHEL/CentOS 7/Anolis）"),
        "zypper": [
            Candidate(replacement: "install", detail: "Linux 包管理（SUSE/openSUSE）"),
            Candidate(replacement: "remove", detail: "Linux 包管理（SUSE/openSUSE）"),
            Candidate(replacement: "update", detail: "Linux 包管理（SUSE/openSUSE）"),
            Candidate(replacement: "search", detail: "Linux 包管理（SUSE/openSUSE）"),
            Candidate(replacement: "refresh", detail: "Linux 包管理（SUSE/openSUSE）"),
            Candidate(replacement: "repos", detail: "Linux 包管理（SUSE/openSUSE）"),
            Candidate(replacement: "info", detail: "Linux 包管理（SUSE/openSUSE）")
        ],
        "pacman": [
            Candidate(replacement: "-S", detail: "Linux 包管理（Arch）"),
            Candidate(replacement: "-Syu", detail: "Linux 包管理（Arch）"),
            Candidate(replacement: "-R", detail: "Linux 包管理（Arch）"),
            Candidate(replacement: "-Rs", detail: "Linux 包管理（Arch）"),
            Candidate(replacement: "-Ss", detail: "Linux 包管理（Arch）"),
            Candidate(replacement: "-Qi", detail: "Linux 包管理（Arch）"),
            Candidate(replacement: "-Qs", detail: "Linux 包管理（Arch）"),
            Candidate(replacement: "-U", detail: "Linux 包管理（Arch）")
        ],
        "apk": [
            Candidate(replacement: "add", detail: "Linux 包管理（Alpine）"),
            Candidate(replacement: "del", detail: "Linux 包管理（Alpine）"),
            Candidate(replacement: "update", detail: "Linux 包管理（Alpine）"),
            Candidate(replacement: "upgrade", detail: "Linux 包管理（Alpine）"),
            Candidate(replacement: "search", detail: "Linux 包管理（Alpine）"),
            Candidate(replacement: "info", detail: "Linux 包管理（Alpine）")
        ],
        "systemctl": [
            Candidate(replacement: "status", detail: "Linux systemd 服务管理"),
            Candidate(replacement: "start", detail: "Linux systemd 服务管理"),
            Candidate(replacement: "stop", detail: "Linux systemd 服务管理"),
            Candidate(replacement: "restart", detail: "Linux systemd 服务管理"),
            Candidate(replacement: "reload", detail: "Linux systemd 服务管理"),
            Candidate(replacement: "enable", detail: "Linux systemd 服务管理"),
            Candidate(replacement: "disable", detail: "Linux systemd 服务管理"),
            Candidate(replacement: "daemon-reload", detail: "Linux systemd 服务管理"),
            Candidate(replacement: "list-units", detail: "Linux systemd 服务管理")
        ],
        "journalctl": [
            Candidate(replacement: "-u", detail: "Linux systemd 日志"),
            Candidate(replacement: "--since", detail: "Linux systemd 日志"),
            Candidate(replacement: "--until", detail: "Linux systemd 日志"),
            Candidate(replacement: "--follow", detail: "Linux systemd 日志"),
            Candidate(replacement: "--no-pager", detail: "Linux systemd 日志")
        ],
        "docker": containerCandidates(detail: "Linux 容器运行时"),
        "podman": containerCandidates(detail: "Linux 容器运行时"),
        "nerdctl": containerCandidates(detail: "Linux containerd 客户端"),
        "docker-compose": composeCandidates(detail: "Linux Compose 工作流"),
        "compose": composeCandidates(detail: "Linux Compose 工作流"),
        "docker compose": composeCandidates(detail: "Linux Compose 工作流"),
        "kubectl": [
            Candidate(replacement: "get", detail: "Linux Kubernetes 管理"),
            Candidate(replacement: "describe", detail: "Linux Kubernetes 管理"),
            Candidate(replacement: "logs", detail: "Linux Kubernetes 管理"),
            Candidate(replacement: "exec", detail: "Linux Kubernetes 管理"),
            Candidate(replacement: "apply", detail: "Linux Kubernetes 管理"),
            Candidate(replacement: "delete", detail: "Linux Kubernetes 管理"),
            Candidate(replacement: "rollout", detail: "Linux Kubernetes 管理"),
            Candidate(replacement: "scale", detail: "Linux Kubernetes 管理"),
            Candidate(replacement: "top", detail: "Linux Kubernetes 管理"),
            Candidate(replacement: "config", detail: "Linux Kubernetes 管理"),
            Candidate(replacement: "cp", detail: "Linux Kubernetes 管理"),
            Candidate(replacement: "port-forward", detail: "Linux Kubernetes 管理"),
            Candidate(replacement: "deployments", detail: "Linux Kubernetes 资源"),
            Candidate(replacement: "pods", detail: "Linux Kubernetes 资源"),
            Candidate(replacement: "services", detail: "Linux Kubernetes 资源"),
            Candidate(replacement: "nodes", detail: "Linux Kubernetes 资源")
        ],
        "helm": [
            Candidate(replacement: "install", detail: "Linux Kubernetes 包管理"),
            Candidate(replacement: "upgrade", detail: "Linux Kubernetes 包管理"),
            Candidate(replacement: "rollback", detail: "Linux Kubernetes 包管理"),
            Candidate(replacement: "list", detail: "Linux Kubernetes 包管理"),
            Candidate(replacement: "status", detail: "Linux Kubernetes 包管理"),
            Candidate(replacement: "repo", detail: "Linux Kubernetes 包管理"),
            Candidate(replacement: "template", detail: "Linux Kubernetes 包管理")
        ],
        "git": [
            Candidate(replacement: "status", detail: "Linux Git"),
            Candidate(replacement: "pull", detail: "Linux Git"),
            Candidate(replacement: "push", detail: "Linux Git"),
            Candidate(replacement: "checkout", detail: "Linux Git"),
            Candidate(replacement: "switch", detail: "Linux Git"),
            Candidate(replacement: "branch", detail: "Linux Git"),
            Candidate(replacement: "commit", detail: "Linux Git"),
            Candidate(replacement: "log", detail: "Linux Git"),
            Candidate(replacement: "diff", detail: "Linux Git")
        ]
    ]

    public static func suggestion(
        for line: String,
        settings: AppSettings = AppSettings(),
        historyCommands: [String] = [],
        pathCompletionProvider: TerminalPathCompletionProviding? = nil
    ) -> TerminalCommandCompletionSuggestion? {
        suggestions(
            for: line,
            settings: settings,
            historyCommands: historyCommands,
            pathCompletionProvider: pathCompletionProvider
        ).first
    }

    public static func suggestions(
        for line: String,
        limit: Int = 5,
        settings: AppSettings = AppSettings(),
        historyCommands: [String] = [],
        pathCompletionProvider: TerminalPathCompletionProviding? = nil
    ) -> [TerminalCommandCompletionSuggestion] {
        guard settings.terminalCommandSuggestionEnabled else {
            return []
        }
        let limit = max(limit, 1)
        if let historySuggestion = historySuggestion(
            for: line,
            limit: limit,
            settings: settings,
            historyCommands: historyCommands
        ) {
            return [historySuggestion]
        }
        if let pathSuggestion = pathSuggestion(
            for: line,
            limit: limit,
            settings: settings,
            pathCompletionProvider: pathCompletionProvider
        ) {
            return [pathSuggestion]
        }
        guard let context = completionContext(
            for: line,
            wordSeparators: settings.terminalCommandSuggestionWordSeparators
        ) else {
            return []
        }
        let matchingCandidates = candidates(for: context).filter {
            $0.replacement.range(of: context.prefix, options: [.caseInsensitive, .anchored]) != nil
                && $0.replacement.caseInsensitiveCompare(context.prefix) != .orderedSame
        }
        let choices = matchingCandidates.prefix(limit).map { candidate in
            let insertion = String(candidate.replacement.dropFirst(context.prefix.count)) + " "
            return TerminalCommandCompletionChoice(
                replacement: candidate.replacement,
                displayCommand: displayCommand(line: line, token: context.token, replacement: candidate.replacement),
                detail: candidate.detail,
                insertion: insertion,
                kind: .command
            )
        }
        return choices.enumerated().map { index, choice in
            return TerminalCommandCompletionSuggestion(
                replacement: choice.replacement,
                insertion: choice.insertion,
                displayCommand: choice.displayCommand,
                detail: choice.detail,
                choices: choices,
                selectedIndex: index
            )
        }
    }

    private struct CompletionContext {
        let tokens: [Token]
        let command: String?
        let composeMode: Bool
        let token: Token
        let tokenRole: TokenRole
        let prefix: String
    }

    private enum TokenRole {
        case command
        case subcommand
    }

    private static func historySuggestion(
        for line: String,
        limit: Int,
        settings: AppSettings,
        historyCommands: [String]
    ) -> TerminalCommandCompletionSuggestion? {
        let prefix = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard prefix.isEmpty == false,
              line.last?.isWhitespace == false
        else {
            return nil
        }
        var seen = Set<String>()
        let candidates = historyCommands.compactMap { command -> String? in
            let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= settings.terminalCommandSuggestionHistoryMinLength,
                  trimmed.count <= settings.terminalCommandSuggestionHistoryMaxLength,
                  trimmed.range(of: prefix, options: [.caseInsensitive, .anchored]) != nil,
                  trimmed.caseInsensitiveCompare(prefix) != .orderedSame,
                  seen.insert(trimmed).inserted
            else {
                return nil
            }
            return trimmed
        }
        let choices = candidates.prefix(limit).map { command in
            TerminalCommandCompletionChoice(
                replacement: command,
                displayCommand: command,
                detail: "历史记录",
                insertion: String(command.dropFirst(prefix.count)),
                kind: .history
            )
        }
        guard let first = choices.first else {
            return nil
        }
        return TerminalCommandCompletionSuggestion(
            replacement: first.replacement,
            insertion: first.insertion,
            displayCommand: first.displayCommand,
            detail: first.detail,
            choices: choices,
            kind: .history
        )
    }

    private static func pathSuggestion(
        for line: String,
        limit: Int,
        settings: AppSettings,
        pathCompletionProvider: TerminalPathCompletionProviding?
    ) -> TerminalCommandCompletionSuggestion? {
        guard let pathCompletionProvider,
              let context = pathCompletionContext(
                for: line,
                wordSeparators: settings.terminalCommandSuggestionWordSeparators
              )
        else {
            return nil
        }
        let candidates = (try? pathCompletionProvider.candidates(for: context.request)) ?? []
        let quote = quoteCharacter(for: context.rawToken)
        let choices = candidates
            .filter {
                $0.name.range(of: context.request.namePrefix, options: [.caseInsensitive, .anchored]) != nil
                    && $0.name.caseInsensitiveCompare(context.request.namePrefix) != .orderedSame
            }
            .prefix(limit)
            .compactMap { candidate -> TerminalCommandCompletionChoice? in
                let escapedName = escapedPathComponent(candidate.name, quote: quote)
                let replacement = context.displayParentPath
                    + escapedName
                    + (candidate.isDirectory ? "/" : "")
                guard replacement.count >= context.tokenPrefix.count else {
                    return nil
                }
                let insertion = String(replacement.dropFirst(context.tokenPrefix.count))
                    + (candidate.isDirectory ? "" : " ")
                return TerminalCommandCompletionChoice(
                    replacement: replacement,
                    displayCommand: displayCommand(line: line, token: context.token, replacement: replacement),
                    detail: candidate.isDirectory ? "目录" : "文件",
                    insertion: insertion,
                    kind: .path
                )
            }
        guard let first = choices.first else {
            return nil
        }
        return TerminalCommandCompletionSuggestion(
            replacement: first.replacement,
            insertion: first.insertion,
            displayCommand: first.displayCommand,
            detail: first.detail,
            choices: choices,
            kind: .path
        )
    }

    private static func completionContext(for line: String, wordSeparators: String) -> CompletionContext? {
        guard line.isEmpty == false,
              line.last?.isWhitespace == false
        else {
            return nil
        }
        let tokens = tokens(in: line, wordSeparators: wordSeparators)
        guard let currentToken = tokens.last,
              currentToken.text.isEmpty == false,
              currentToken.text.contains("/") == false
        else {
            return nil
        }
        let segmentTokens = Array(tokens.suffix(from: latestSegmentStart(in: tokens)))
        guard let currentInSegment = segmentTokens.indices.last else {
            return nil
        }
        let commandIndex = firstCommandIndex(in: segmentTokens)
        let prefix = currentToken.text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard prefix.isEmpty == false else {
            return nil
        }
        guard let commandIndex else {
            return CompletionContext(
                tokens: segmentTokens,
                command: nil,
                composeMode: false,
                token: currentToken,
                tokenRole: .command,
                prefix: prefix
            )
        }
        let command = normalize(segmentTokens[commandIndex].text)
        let composeMode = isComposeMode(command: command, segmentTokens: segmentTokens, currentIndex: currentInSegment)
        let role: TokenRole = currentInSegment == commandIndex ? .command : .subcommand
        guard role == .subcommand || prefix.count >= 1 else {
            return nil
        }
        return CompletionContext(
            tokens: segmentTokens,
            command: command,
            composeMode: composeMode,
            token: currentToken,
            tokenRole: role,
            prefix: prefix
        )
    }

    private static func pathCompletionContext(for line: String, wordSeparators: String) -> PathCompletionContext? {
        guard line.isEmpty == false,
              line.last?.isWhitespace == false
        else {
            return nil
        }
        let tokens = tokens(in: line, wordSeparators: wordSeparators)
        guard let currentToken = tokens.last,
              currentToken.text.isEmpty == false
        else {
            return nil
        }
        let segmentTokens = Array(tokens.suffix(from: latestSegmentStart(in: tokens)))
        guard let currentInSegment = segmentTokens.indices.last,
              let commandIndex = firstCommandIndex(in: segmentTokens),
              currentInSegment > commandIndex
        else {
            return nil
        }
        let command = normalize(segmentTokens[commandIndex].text)
        let rawToken = currentToken.text
        let tokenPrefix = unquotedTokenPrefix(rawToken)
        guard tokenPrefix.isEmpty == false,
              shouldCompletePath(command: command, tokenPrefix: tokenPrefix)
        else {
            return nil
        }
        let split = splitPathPrefix(tokenPrefix)
        guard split.namePrefix.isEmpty == false else {
            return nil
        }
        return PathCompletionContext(
            token: currentToken,
            rawToken: rawToken,
            tokenPrefix: tokenPrefix,
            displayParentPath: split.displayParentPath,
            request: TerminalPathCompletionRequest(
                parentPath: split.parentPath,
                namePrefix: split.namePrefix
            )
        )
    }

    private static func candidates(for context: CompletionContext) -> [Candidate] {
        switch context.tokenRole {
        case .command:
            return commandCandidates
        case .subcommand:
            guard let command = context.command else {
                return []
            }
            if context.composeMode {
                return subcommandCandidates["docker compose"] ?? []
            }
            return subcommandCandidates[command] ?? []
        }
    }

    private static func tokens(in line: String, wordSeparators: String) -> [Token] {
        var tokens: [Token] = []
        var tokenStart: String.Index?
        var quote: Character?
        var isEscaping = false
        let separators = Set(wordSeparators)

        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if isEscaping {
                isEscaping = false
                index = line.index(after: index)
                continue
            }
            if character == "\\" {
                if tokenStart == nil { tokenStart = index }
                isEscaping = true
                index = line.index(after: index)
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                }
                index = line.index(after: index)
                continue
            }
            if character == "\"" || character == "'" {
                if tokenStart == nil { tokenStart = index }
                quote = character
                index = line.index(after: index)
                continue
            }
            if character.isWhitespace || separators.contains(character) {
                if let start = tokenStart {
                    tokens.append(Token(text: String(line[start..<index]), range: start..<index))
                    tokenStart = nil
                }
                index = line.index(after: index)
                continue
            }
            if tokenStart == nil { tokenStart = index }
            index = line.index(after: index)
        }
        if let start = tokenStart {
            tokens.append(Token(text: String(line[start..<line.endIndex]), range: start..<line.endIndex))
        }
        return tokens
    }

    private static func latestSegmentStart(in tokens: [Token]) -> Int {
        guard let operatorIndex = tokens.lastIndex(where: { operators.contains($0.text) }) else {
            return tokens.startIndex
        }
        return tokens.index(after: operatorIndex)
    }

    private static func firstCommandIndex(in tokens: [Token]) -> Int? {
        for index in tokens.indices {
            let value = normalize(tokens[index].text)
            if operators.contains(value) {
                continue
            }
            if wrappers.contains(value) || isEnvironmentAssignment(tokens[index].text) {
                continue
            }
            return index
        }
        return nil
    }

    private static func isComposeMode(command: String, segmentTokens: [Token], currentIndex: Int) -> Bool {
        if command == "docker-compose" || command == "compose" {
            return true
        }
        guard command == "docker" || command == "podman" || command == "nerdctl" else {
            return false
        }
        let valuesBeforeCurrent = segmentTokens[..<currentIndex].map { normalize($0.text) }
        return valuesBeforeCurrent.contains("compose")
    }

    private static func normalize(_ value: String) -> String {
        let executable = value.split(separator: "/").last.map(String.init) ?? value
        return executable.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")).lowercased()
    }

    private static func isEnvironmentAssignment(_ value: String) -> Bool {
        guard let equalIndex = value.firstIndex(of: "="),
              equalIndex != value.startIndex
        else {
            return false
        }
        let key = value[..<equalIndex]
        return key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    private static func displayCommand(line: String, token: Token, replacement: String) -> String {
        String(line[..<token.range.lowerBound]) + replacement
    }

    private static func shouldCompletePath(command: String, tokenPrefix: String) -> Bool {
        if tokenPrefix.contains("/") || tokenPrefix.hasPrefix(".") || tokenPrefix.hasPrefix("~") {
            return true
        }
        return pathAwareCommands.contains(command)
    }

    private static func splitPathPrefix(_ tokenPrefix: String) -> (
        parentPath: String,
        displayParentPath: String,
        namePrefix: String
    ) {
        guard let slashIndex = tokenPrefix.lastIndex(of: "/") else {
            return (".", "", tokenPrefix)
        }
        let afterSlash = tokenPrefix.index(after: slashIndex)
        let displayParentPath = String(tokenPrefix[..<afterSlash])
        let namePrefix = String(tokenPrefix[afterSlash...])
        let parentPath: String
        if slashIndex == tokenPrefix.startIndex {
            parentPath = "/"
        } else {
            parentPath = String(tokenPrefix[..<slashIndex])
        }
        return (parentPath.isEmpty ? "." : parentPath, displayParentPath, namePrefix)
    }

    private static func unquotedTokenPrefix(_ rawToken: String) -> String {
        var value = rawToken
        if let first = value.first,
           first == "\"" || first == "'"
        {
            value.removeFirst()
        }
        if let last = value.last,
           last == "\"" || last == "'"
        {
            value.removeLast()
        }
        return unescapedShellToken(value)
    }

    private static func unescapedShellToken(_ value: String) -> String {
        var result = ""
        var isEscaping = false
        for character in value {
            if isEscaping {
                result.append(character)
                isEscaping = false
            } else if character == "\\" {
                isEscaping = true
            } else {
                result.append(character)
            }
        }
        if isEscaping {
            result.append("\\")
        }
        return result
    }

    private static func quoteCharacter(for rawToken: String) -> Character? {
        guard let first = rawToken.first,
              first == "\"" || first == "'"
        else {
            return nil
        }
        return first
    }

    private static func escapedPathComponent(_ value: String, quote: Character?) -> String {
        if quote == "\"" {
            return value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "$", with: "\\$")
                .replacingOccurrences(of: "`", with: "\\`")
        }
        if quote == "'" {
            return value.replacingOccurrences(of: "'", with: #"'\'"'"#)
        }
        var result = ""
        for character in value {
            if character.isWhitespace || "\\\"'`$&;|<>*?()[]{}!".contains(character) {
                result.append("\\")
            }
            result.append(character)
        }
        return result
    }

    private static func packageManagerCandidates(detail: String) -> [Candidate] {
        [
            Candidate(replacement: "install", detail: detail),
            Candidate(replacement: "remove", detail: detail),
            Candidate(replacement: "update", detail: detail),
            Candidate(replacement: "upgrade", detail: detail),
            Candidate(replacement: "search", detail: detail),
            Candidate(replacement: "show", detail: detail),
            Candidate(replacement: "info", detail: detail),
            Candidate(replacement: "list", detail: detail),
            Candidate(replacement: "autoremove", detail: detail),
            Candidate(replacement: "clean", detail: detail)
        ]
    }

    private static func containerCandidates(detail: String) -> [Candidate] {
        [
            Candidate(replacement: "compose", detail: detail),
            Candidate(replacement: "ps", detail: detail),
            Candidate(replacement: "logs", detail: detail),
            Candidate(replacement: "exec", detail: detail),
            Candidate(replacement: "run", detail: detail),
            Candidate(replacement: "build", detail: detail),
            Candidate(replacement: "pull", detail: detail),
            Candidate(replacement: "push", detail: detail),
            Candidate(replacement: "images", detail: detail),
            Candidate(replacement: "inspect", detail: detail),
            Candidate(replacement: "restart", detail: detail),
            Candidate(replacement: "stop", detail: detail),
            Candidate(replacement: "start", detail: detail),
            Candidate(replacement: "rm", detail: detail),
            Candidate(replacement: "rmi", detail: detail),
            Candidate(replacement: "network", detail: detail),
            Candidate(replacement: "volume", detail: detail),
            Candidate(replacement: "system", detail: detail)
        ]
    }

    private static func composeCandidates(detail: String) -> [Candidate] {
        [
            Candidate(replacement: "up", detail: detail),
            Candidate(replacement: "down", detail: detail),
            Candidate(replacement: "ps", detail: detail),
            Candidate(replacement: "logs", detail: detail),
            Candidate(replacement: "build", detail: detail),
            Candidate(replacement: "pull", detail: detail),
            Candidate(replacement: "restart", detail: detail),
            Candidate(replacement: "exec", detail: detail),
            Candidate(replacement: "config", detail: detail),
            Candidate(replacement: "run", detail: detail)
        ]
    }
}
