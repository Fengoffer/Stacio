import AppKit
import StacioAgentBridge

public enum TerminalCommandTokenKind: String, Equatable {
    case command
    case subcommand
    case dangerousSubcommand
    case flag
    case path
    case environmentAssignment
    case argument
    case operatorToken
    case stringLiteral
    case numberLiteral
    case variableReference
    case commandSubstitution
    case comment
    case globPattern
    case redirectionTarget
    case heredocMarker
}

public struct TerminalCommandToken: Equatable {
    public let text: String
    public let kind: TerminalCommandTokenKind
    public let range: NSRange?

    public init(text: String, kind: TerminalCommandTokenKind, range: NSRange? = nil) {
        self.text = text
        self.kind = kind
        self.range = range
    }
}

public struct TerminalCommandHighlightResult: Equatable {
    public let originalCommand: String
    public let primaryCommand: String?
    public let commands: [String]
    public let risk: AgentActionRisk
    public let tokens: [TerminalCommandToken]

    public init(
        originalCommand: String,
        primaryCommand: String?,
        commands: [String]? = nil,
        risk: AgentActionRisk,
        tokens: [TerminalCommandToken]
    ) {
        self.originalCommand = originalCommand
        self.primaryCommand = primaryCommand
        self.commands = commands ?? primaryCommand.map { [$0] } ?? []
        self.risk = risk
        self.tokens = tokens
    }

    public var summary: String {
        var parts: [String] = []
        let visibleCommands = uniquePreservingOrder(commands)
        if visibleCommands.isEmpty == false {
            parts.append("命令：\(visibleCommands.joined(separator: ", "))")
        }
        let subcommands = tokens
            .filter { $0.kind == .subcommand || $0.kind == .dangerousSubcommand }
            .map(\.text)
        if subcommands.isEmpty == false {
            parts.append("子命令：\(subcommands.joined(separator: ", "))")
        }
        let flags = tokens.filter { $0.kind == .flag }.map(\.text)
        if flags.isEmpty == false {
            parts.append("参数：\(flags.joined(separator: ", "))")
        }
        return parts.joined(separator: " · ")
    }

    private func uniquePreservingOrder(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values where seen.contains(value) == false {
            seen.insert(value)
            result.append(value)
        }
        return result
    }
}

public enum TerminalCommandHighlighter {
    private static let wrappers: Set<String> = ["sudo", "env", "time", "command", "nohup"]
    private static let operators: Set<String> = ["|", "||", "&&", ";", ">", ">>", "<", "<<", "2>", "2>>", "&>"]
    private static let redirectionOperators: Set<String> = [">", ">>", "<", "2>", "2>>", "&>"]
    private static let heredocOperators: Set<String> = ["<<"]
    private static let trackedCommands: Set<String> = [
        "docker", "docker-compose", "compose", "podman", "nerdctl", "crictl", "ctr", "kubectl", "helm",
        "systemctl", "service", "journalctl", "nginx", "firewall-cmd", "iptables", "pfctl", "nft", "ufw", "ip",
        "yum", "dnf", "apt", "apt-get", "apk", "zypper", "pacman", "rpm", "git",
        "terraform", "tofu", "ansible", "ansible-playbook", "supervisorctl", "pm2",
        "psql", "mysql", "mariadb", "redis-cli", "aws", "gcloud", "az", "rsync", "scp", "ssh",
        "df", "du", "find", "sort", "tail", "head", "ps", "top", "uptime", "free",
        "xargs", "sh", "bash", "zsh", "dash", "ksh"
    ]
    private static let dangerousSubcommands: Set<String> = [
        "delete", "drain", "cordon", "uncordon", "apply", "replace", "scale",
        "start", "restart", "stop", "reload", "disable", "enable", "mask", "unmask",
        "daemon-reload", "create", "deploy", "init", "login", "logout", "leave",
        "patch", "edit", "label", "annotate", "cp", "port-forward", "expose",
        "install", "remove", "erase", "purge", "update", "upgrade", "dist-upgrade",
        "add", "allow", "deny", "reject", "limit", "enable", "set", "del", "delete", "destroy", "flush", "reset", "insert", "fix", "patch", "in", "up", "dup", "rm", "use", "push",
        "-a", "-i", "-r", "-d", "-f", "-x", "-z", "-s", "-syu", "-u", "-rns",
        "--reload", "--add-service", "--add-port", "--add-rich-rule",
        "--remove-service", "--remove-port", "--remove-rich-rule",
        "up", "down", "rm", "rmi", "prune", "commit", "reset", "clean", "push", "merge", "rebase",
        "destroy", "flushall", "flushdb", "drop", "truncate", "restart", "reload", "sync"
    ]

    public static func highlight(_ command: String) -> TerminalCommandHighlightResult {
        let words = split(command)
        var tokens: [TerminalCommandToken] = []
        var primaryCommand: String?
        var activeCommand: String?
        var commands: [String] = []
        var hasSeenCommandInSegment = false
        var firstSubcommandMarked = false
        var expectsFlagValue = false
        var expectsRedirectionTarget = false
        var expectsHeredocMarker = false

        for word in words {
            let normalized = normalizeExecutable(word.text)
            let kind: TerminalCommandTokenKind
            if expectsHeredocMarker {
                expectsHeredocMarker = false
                kind = .heredocMarker
            } else if expectsRedirectionTarget {
                expectsRedirectionTarget = false
                kind = .redirectionTarget
            } else if expectsFlagValue, shouldTreatAsSubcommand(normalized, primaryCommand: activeCommand) == false {
                expectsFlagValue = false
                kind = isPathLike(word.text) ? .path : .argument
            } else if operators.contains(word.text) {
                expectsFlagValue = false
                expectsRedirectionTarget = redirectionOperators.contains(word.text)
                expectsHeredocMarker = heredocOperators.contains(word.text)
                kind = .operatorToken
                activeCommand = nil
                hasSeenCommandInSegment = false
                firstSubcommandMarked = false
            } else if activeCommand == nil && wrappers.contains(normalized) {
                kind = .argument
            } else if activeCommand == nil && isEnvironmentAssignment(word.text) {
                kind = .environmentAssignment
            } else if activeCommand == nil && trackedCommands.contains(normalized) {
                if primaryCommand == nil {
                    primaryCommand = normalized
                }
                activeCommand = normalized
                commands.append(normalized)
                hasSeenCommandInSegment = true
                kind = .command
            } else if activeCommand == "xargs",
                      firstSubcommandMarked == false,
                      trackedCommands.contains(normalized) {
                activeCommand = normalized
                commands.append(normalized)
                hasSeenCommandInSegment = true
                kind = .command
            } else if hasSeenCommandInSegment,
                      shouldTreatAsShellScript(word.text, primaryCommand: activeCommand, previousWord: tokens.last?.text) {
                expectsFlagValue = false
                firstSubcommandMarked = true
                kind = .dangerousSubcommand
            } else if hasSeenCommandInSegment && shouldTreatAsSubcommand(normalized, primaryCommand: activeCommand) {
                expectsFlagValue = false
                firstSubcommandMarked = true
                kind = isRiskActionToken(normalized) ? .dangerousSubcommand : .subcommand
            } else if hasSeenCommandInSegment && word.text.hasPrefix("-") {
                expectsFlagValue = flagConsumesNextValue(word.text, primaryCommand: activeCommand)
                kind = .flag
            } else if hasSeenCommandInSegment && isPathLike(word.text) {
                kind = .path
            } else if hasSeenCommandInSegment && firstSubcommandMarked == false {
                firstSubcommandMarked = true
                kind = isRiskActionToken(normalized) ? .dangerousSubcommand : .subcommand
            } else if isPathLike(word.text) {
                kind = .path
            } else if isEnvironmentAssignment(word.text) {
                kind = .environmentAssignment
            } else if word.text.hasPrefix("-") {
                kind = .flag
            } else {
                kind = .argument
            }
            tokens.append(TerminalCommandToken(text: word.text, kind: kind, range: word.range))
        }
        tokens.append(contentsOf: syntaxTokens(in: command))
        tokens.sort { lhs, rhs in
            let left = lhs.range?.location ?? Int.max
            let right = rhs.range?.location ?? Int.max
            if left == right {
                return (lhs.range?.length ?? 0) > (rhs.range?.length ?? 0)
            }
            return left < right
        }

        return TerminalCommandHighlightResult(
            originalCommand: command,
            primaryCommand: primaryCommand,
            commands: commands,
            risk: AgentActionClassifier.risk(forCommand: command),
            tokens: tokens
        )
    }

    public static func attributedString(
        for command: String,
        level: TerminalHighlightLevelPreference,
        baseFont: NSFont,
        baseColor: NSColor = .labelColor,
        theme: TerminalColorTheme = .systemAdaptivePreview,
        richHighlightingEnabled: Bool = true
    ) -> NSAttributedString {
        let result = highlight(command)
        let attributed = NSMutableAttributedString(
            string: command,
            attributes: [.font: baseFont, .foregroundColor: baseColor]
        )
        guard level == .commandLineEnhanced else {
            return attributed
        }

        let palette = TerminalHighlightPalette(theme: theme)
        var searchStart = command.startIndex
        for token in result.tokens {
            guard richHighlightingEnabled || token.kind.isLegacyKind else { continue }
            let nsRange: NSRange
            if let range = token.range {
                nsRange = range
            } else {
                guard let range = command.range(of: token.text, range: searchStart..<command.endIndex) else {
                    continue
                }
                nsRange = NSRange(range, in: command)
                searchStart = range.upperBound
            }
            guard nsRange.location != NSNotFound,
                  nsRange.location + nsRange.length <= (command as NSString).length
            else {
                continue
            }
            attributed.addAttributes(attributes(for: token.kind, baseFont: baseFont, palette: palette), range: nsRange)
        }
        return attributed
    }

    private static func attributes(
        for kind: TerminalCommandTokenKind,
        baseFont: NSFont,
        palette: TerminalHighlightPalette
    ) -> [NSAttributedString.Key: Any] {
        switch kind {
        case .command:
            return [.foregroundColor: palette.nsColor(for: .command), .font: NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .semibold)]
        case .subcommand:
            return [.foregroundColor: palette.nsColor(for: .subcommand), .font: NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .medium)]
        case .dangerousSubcommand:
            return [.foregroundColor: palette.nsColor(for: .dangerous), .font: NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .semibold)]
        case .flag:
            return [.foregroundColor: palette.nsColor(for: .flag)]
        case .path:
            return [.foregroundColor: palette.nsColor(for: .path)]
        case .environmentAssignment:
            return [.foregroundColor: palette.nsColor(for: .environment)]
        case .operatorToken:
            return [.foregroundColor: palette.nsColor(for: .operatorToken)]
        case .stringLiteral:
            return [.foregroundColor: palette.nsColor(for: .string)]
        case .numberLiteral:
            return [.foregroundColor: palette.nsColor(for: .number)]
        case .variableReference:
            return [.foregroundColor: palette.nsColor(for: .variable)]
        case .commandSubstitution:
            return [.foregroundColor: palette.nsColor(for: .substitution)]
        case .comment:
            return [.foregroundColor: palette.nsColor(for: .comment)]
        case .globPattern:
            return [.foregroundColor: palette.nsColor(for: .glob)]
        case .redirectionTarget:
            return [.foregroundColor: palette.nsColor(for: .redirection)]
        case .heredocMarker:
            return [.foregroundColor: palette.nsColor(for: .heredoc)]
        case .argument:
            return [.foregroundColor: palette.nsColor(for: .argument)]
        }
    }

    private struct ShellWord {
        let text: String
        let range: NSRange
    }

    private static func split(_ command: String) -> [ShellWord] {
        let characters = Array(command)
        var words: [ShellWord] = []
        var current = ""
        var wordStart: Int?
        var index = 0
        var quote: Character?
        var isEscaping = false

        func finishWord(at end: Int) {
            guard let start = wordStart, current.isEmpty == false else {
                current = ""
                wordStart = nil
                return
            }
            words.append(ShellWord(text: current, range: NSRange(location: start, length: end - start)))
            current = ""
            wordStart = nil
        }

        while index < characters.count {
            let character = characters[index]
            if isEscaping {
                wordStart = wordStart ?? index - 1
                current.append(character)
                isEscaping = false
                index += 1
                continue
            }
            if character == "\\" {
                wordStart = wordStart ?? index
                isEscaping = true
                index += 1
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
                index += 1
                continue
            }
            if character == "#" && wordStart == nil {
                break
            }
            if character == "\"" || character == "'" {
                wordStart = wordStart ?? index
                quote = character
                index += 1
                continue
            }
            if character.isWhitespace {
                finishWord(at: index)
                index += 1
                continue
            }
            if let op = operatorToken(in: characters, at: index) {
                finishWord(at: index)
                words.append(ShellWord(text: op, range: NSRange(location: index, length: op.count)))
                index += op.count
                continue
            }
            wordStart = wordStart ?? index
            current.append(character)
            index += 1
        }

        if isEscaping {
            current.append("\\")
        }
        finishWord(at: characters.count)
        return words
    }

    private static func operatorToken(in characters: [Character], at index: Int) -> String? {
        let two = index + 1 < characters.count ? String(characters[index...index + 1]) : nil
        if let two, operators.contains(two) {
            return two
        }
        let one = String(characters[index])
        return operators.contains(one) ? one : nil
    }

    private static func syntaxTokens(in command: String) -> [TerminalCommandToken] {
        var tokens: [TerminalCommandToken] = []
        let characters = Array(command)
        var index = 0
        var quote: Character?
        var isEscaping = false
        var currentWordStart: Int?

        while index < characters.count {
            let character = characters[index]
            if isEscaping {
                isEscaping = false
                index += 1
                continue
            }
            if character == "\\" {
                isEscaping = true
                currentWordStart = currentWordStart ?? index
                index += 1
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                    index += 1
                    continue
                }
                if activeQuote == "\"", character == "$" {
                    if let substitution = commandSubstitution(in: characters, at: index, command: command) {
                        tokens.append(substitution.token)
                        tokens.append(contentsOf: syntaxTokens(in: substitution.inner, baseLocation: substitution.innerLocation))
                        index = substitution.end
                        continue
                    }
                    if let variable = variableReference(in: characters, at: index, command: command) {
                        tokens.append(variable.token)
                        index = variable.end
                        continue
                    }
                }
                index += 1
                continue
            }
            if character == "#" && currentWordStart == nil {
                let text = String(characters[index...])
                tokens.append(TerminalCommandToken(text: text, kind: .comment, range: NSRange(location: index, length: characters.count - index)))
                break
            }
            if character.isWhitespace {
                currentWordStart = nil
                index += 1
                continue
            }
            if character == "\"" || character == "'" {
                let quoted = quotedString(in: characters, at: index, quote: character)
                tokens.append(quoted.token)
                if character == "\"" {
                    tokens.append(contentsOf: syntaxTokens(in: quoted.text, baseLocation: quoted.contentLocation))
                }
                currentWordStart = currentWordStart ?? index
                index = quoted.end
                continue
            }
            if character == "$" {
                if let substitution = commandSubstitution(in: characters, at: index, command: command) {
                    tokens.append(substitution.token)
                    tokens.append(contentsOf: syntaxTokens(in: substitution.inner, baseLocation: substitution.innerLocation))
                    currentWordStart = currentWordStart ?? index
                    index = substitution.end
                    continue
                }
                if let variable = variableReference(in: characters, at: index, command: command) {
                    tokens.append(variable.token)
                    currentWordStart = currentWordStart ?? index
                    index = variable.end
                    continue
                }
            }
            if character == "`" {
                let substitution = backtickSubstitution(in: characters, at: index)
                tokens.append(substitution.token)
                tokens.append(contentsOf: syntaxTokens(in: substitution.inner, baseLocation: substitution.innerLocation))
                currentWordStart = currentWordStart ?? index
                index = substitution.end
                continue
            }
            currentWordStart = currentWordStart ?? index
            index += 1
        }

        tokens.append(contentsOf: numericTokens(in: command, baseLocation: 0))
        tokens.append(contentsOf: globTokens(in: split(command)))
        return tokens
    }

    private static func syntaxTokens(in text: String, baseLocation: Int) -> [TerminalCommandToken] {
        syntaxTokens(in: text).map { token in
            guard let range = token.range else { return token }
            return TerminalCommandToken(
                text: token.text,
                kind: token.kind,
                range: NSRange(location: range.location + baseLocation, length: range.length)
            )
        }
    }

    private static func quotedString(in characters: [Character], at start: Int, quote: Character) -> (token: TerminalCommandToken, text: String, contentLocation: Int, end: Int) {
        var index = start + 1
        var text = ""
        var isEscaping = false
        while index < characters.count {
            let character = characters[index]
            if isEscaping {
                text.append(character)
                isEscaping = false
                index += 1
                continue
            }
            if quote == "\"" && character == "\\" {
                isEscaping = true
                index += 1
                continue
            }
            if character == quote {
                let range = NSRange(location: start + 1, length: max(0, index - start - 1))
                return (TerminalCommandToken(text: text, kind: .stringLiteral, range: range), text, start + 1, index + 1)
            }
            text.append(character)
            index += 1
        }
        let range = NSRange(location: start + 1, length: max(0, characters.count - start - 1))
        return (TerminalCommandToken(text: text, kind: .stringLiteral, range: range), text, start + 1, characters.count)
    }

    private static func variableReference(in characters: [Character], at start: Int, command: String) -> (token: TerminalCommandToken, end: Int)? {
        guard characters[start] == "$" else { return nil }
        if start + 1 < characters.count, characters[start + 1] == "{" {
            var index = start + 2
            while index < characters.count, characters[index] != "}" {
                index += 1
            }
            guard index < characters.count else { return nil }
            let range = NSRange(location: start, length: index - start + 1)
            return (TerminalCommandToken(text: substring(command, range: range), kind: .variableReference, range: range), index + 1)
        }
        var index = start + 1
        guard index < characters.count,
              characters[index].isLetter || characters[index] == "_"
        else {
            return nil
        }
        while index < characters.count,
              characters[index].isLetter || characters[index].isNumber || characters[index] == "_" {
            index += 1
        }
        let range = NSRange(location: start, length: index - start)
        return (TerminalCommandToken(text: substring(command, range: range), kind: .variableReference, range: range), index)
    }

    private static func commandSubstitution(in characters: [Character], at start: Int, command: String) -> (token: TerminalCommandToken, inner: String, innerLocation: Int, end: Int)? {
        guard start + 1 < characters.count,
              characters[start] == "$",
              characters[start + 1] == "("
        else {
            return nil
        }
        var index = start + 2
        var depth = 1
        var quote: Character?
        var isEscaping = false
        while index < characters.count {
            let character = characters[index]
            if isEscaping {
                isEscaping = false
                index += 1
                continue
            }
            if character == "\\" {
                isEscaping = true
                index += 1
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                }
                index += 1
                continue
            }
            if character == "\"" || character == "'" || character == "`" {
                quote = character
                index += 1
                continue
            }
            if character == "(" {
                depth += 1
            } else if character == ")" {
                depth -= 1
                if depth == 0 {
                    let range = NSRange(location: start, length: index - start + 1)
                    let innerRange = NSRange(location: start + 2, length: index - start - 2)
                    return (
                        TerminalCommandToken(text: substring(command, range: range), kind: .commandSubstitution, range: range),
                        substring(command, range: innerRange),
                        start + 2,
                        index + 1
                    )
                }
            }
            index += 1
        }
        return nil
    }

    private static func backtickSubstitution(in characters: [Character], at start: Int) -> (token: TerminalCommandToken, inner: String, innerLocation: Int, end: Int) {
        var index = start + 1
        var inner = ""
        var isEscaping = false
        while index < characters.count {
            let character = characters[index]
            if isEscaping {
                inner.append(character)
                isEscaping = false
                index += 1
                continue
            }
            if character == "\\" {
                isEscaping = true
                index += 1
                continue
            }
            if character == "`" {
                let text = "`\(inner)`"
                return (
                    TerminalCommandToken(text: text, kind: .commandSubstitution, range: NSRange(location: start, length: index - start + 1)),
                    inner,
                    start + 1,
                    index + 1
                )
            }
            inner.append(character)
            index += 1
        }
        let text = "`\(inner)"
        return (
            TerminalCommandToken(text: text, kind: .commandSubstitution, range: NSRange(location: start, length: characters.count - start)),
            inner,
            start + 1,
            characters.count
        )
    }

    private static func numericTokens(in text: String, baseLocation: Int) -> [TerminalCommandToken] {
        let regex = try! NSRegularExpression(pattern: #"(?<![\w.])\d+(?:\.\d+)?(?![\w.])"#)
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: nsRange).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            return TerminalCommandToken(
                text: String(text[range]),
                kind: .numberLiteral,
                range: NSRange(location: match.range.location + baseLocation, length: match.range.length)
            )
        }
    }

    private static func globTokens(in words: [ShellWord]) -> [TerminalCommandToken] {
        words.compactMap { word in
            guard word.text.contains("*") || word.text.contains("?") || word.text.contains("[") else {
                return nil
            }
            return TerminalCommandToken(text: word.text, kind: .globPattern, range: word.range)
        }
    }

    private static func substring(_ text: String, range: NSRange) -> String {
        guard let stringRange = Range(range, in: text) else {
            return ""
        }
        return String(text[stringRange])
    }

    private static func normalizeExecutable(_ value: String) -> String {
        let executable = value.split(separator: "/").last.map(String.init) ?? value
        return executable.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")).lowercased()
    }

    private static func isEnvironmentAssignment(_ value: String) -> Bool {
        guard let equalIndex = value.firstIndex(of: "="),
              equalIndex != value.startIndex else {
            return false
        }
        let key = value[..<equalIndex]
        return key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    private static func isPathLike(_ value: String) -> Bool {
        value.hasPrefix("/")
            || value.hasPrefix("./")
            || value.hasPrefix("../")
            || value.contains(":/")
    }

    private static func shouldTreatAsSubcommand(_ value: String, primaryCommand: String?) -> Bool {
        guard let primaryCommand else {
            return false
        }
        switch primaryCommand {
        case "docker", "podman", "nerdctl", "crictl", "ctr":
            return [
                "build", "builder", "buildx", "commit", "compose", "container",
                "bake", "context", "cp", "create", "diff", "events", "exec",
                "image", "images", "inspect", "kill", "load", "login", "logout",
                "logs", "manifest", "network", "node", "pause", "plugin", "port",
                "ps", "pull", "push", "rename",
                "restart", "rm", "rmi", "run", "save", "secret", "service", "stack",
                "start", "stats", "stop", "swarm", "system", "tag", "top", "trust",
                "unpause", "update", "version", "volume", "wait",
                "up", "down", "prune", "leave", "deploy", "scale", "use",
                "disable", "enable", "remove", "pods", "pod", "images", "image",
                "containers", "tasks", "task", "namespaces", "namespace", "leases",
                "runp", "stopp", "rmp", "inspectp"
            ].contains(value)
        case "docker-compose", "compose":
            return [
                "build", "config", "cp", "create", "down", "events", "exec",
                "images", "kill", "logs", "ls", "pause", "port", "ps", "pull",
                "push", "restart", "rm", "run", "start", "stop", "top",
                "unpause", "up", "version"
            ].contains(value)
        case "kubectl":
            return [
                "get", "describe", "logs", "exec", "delete", "apply", "rollout",
                "restart", "scale", "create", "patch", "edit", "set", "label",
                "annotate", "cp", "port-forward", "replace", "expose"
            ].contains(value)
        case "helm":
            return ["list", "status", "history", "get", "template", "install", "upgrade", "rollback", "uninstall", "repo"].contains(value)
        case "systemctl":
            return [
                "status", "start", "stop", "restart", "reload", "enable", "disable",
                "mask", "unmask", "daemon-reload", "is-active", "list-units", "show", "cat"
            ].contains(value)
        case "service":
            return ["status", "start", "stop", "restart", "reload"].contains(value)
        case "journalctl":
            return ["show", "status"].contains(value)
        case "nginx":
            return ["-t", "-s"].contains(value)
        case "firewall-cmd":
            return value == "--reload"
                || value.hasPrefix("--add-")
                || value.hasPrefix("--remove-")
                || value.hasPrefix("--delete-")
                || value.hasPrefix("--change-")
        case "iptables", "pfctl":
            return [
                "-l", "--list", "-s", "--list-rules", "-n", "--new-chain",
                "-a", "--append", "-i", "--insert", "-r", "--replace", "-p", "--policy",
                "-d", "--delete", "-f", "--flush", "-x", "--delete-chain", "-z", "--zero"
            ].contains(value)
        case "nft":
            return [
                "list", "add", "insert", "replace", "create",
                "delete", "destroy", "flush", "reset"
            ].contains(value)
        case "ufw":
            return [
                "status", "show", "allow", "deny", "reject", "limit",
                "enable", "disable", "reload", "delete", "reset"
            ].contains(value)
        case "ip":
            return ["addr", "address", "link", "route", "show", "set", "add", "del", "delete", "replace"].contains(value)
        case "yum", "dnf", "apt", "apt-get", "apk", "zypper", "rpm", "git":
            return true
        case "pacman":
            return true
        case "terraform", "tofu":
            return [
                "init", "validate", "plan", "show", "apply", "destroy",
                "import", "state", "workspace", "refresh", "taint", "untaint"
            ].contains(value)
        case "ansible":
            return [
                "all", "shell", "command", "raw", "script", "service",
                "systemd", "copy", "template", "file", "yum", "dnf", "apt",
                "package", "ping", "setup", "debug"
            ].contains(value)
        case "ansible-playbook":
            return true
        case "supervisorctl":
            return [
                "status", "start", "stop", "restart", "reload", "reread",
                "update", "shutdown", "tail", "pid", "clear"
            ].contains(value)
        case "pm2":
            return [
                "list", "ls", "status", "logs", "monit", "show", "describe",
                "start", "stop", "restart", "reload", "delete", "del", "kill",
                "scale", "deploy", "save", "resurrect", "startup"
            ].contains(value)
        case "psql", "mysql", "mariadb":
            return ["select", "show", "alter", "create", "insert", "update", "delete", "drop", "truncate"].contains(value)
        case "redis-cli":
            return [
                "info", "monitor", "keys", "scan", "get", "set", "mset",
                "del", "unlink", "flushall", "flushdb", "config", "shutdown"
            ].contains(value)
        case "aws":
            return [
                "s3", "ec2", "ecs", "eks", "lambda", "cloudformation", "iam",
                "logs", "rds", "ls", "cp", "sync", "mv", "rm", "delete",
                "create", "update", "deploy", "invoke"
            ].contains(value) || value.hasPrefix("delete-") || value.hasPrefix("put-") || value.hasPrefix("create-") || value.hasPrefix("update-")
        case "gcloud":
            return [
                "compute", "container", "run", "functions", "sql", "projects",
                "list", "describe", "create", "update", "set", "add", "start",
                "stop", "restart", "deploy", "delete", "get-credentials"
            ].contains(value)
        case "az":
            return [
                "group", "webapp", "vm", "aks", "storage", "functionapp",
                "list", "show", "create", "update", "set", "restart",
                "start", "stop", "deploy", "delete", "remove", "purge"
            ].contains(value)
        case "rsync":
            return value == "--delete"
                || value.hasPrefix("--delete-")
        case "scp", "ssh":
            return false
        case "df", "du", "find", "sort", "tail", "head", "ps", "top", "uptime", "free":
            return true
        case "xargs":
            return false
        case "sh", "bash", "zsh", "dash", "ksh":
            return value == "-c" || value == "-lc"
        default:
            return false
        }
    }

    private static func flagConsumesNextValue(_ value: String, primaryCommand: String?) -> Bool {
        if value.contains("=") {
            return false
        }
        guard let primaryCommand else {
            return false
        }
        let commonValueFlags: Set<String> = [
            "-c", "--config",
            "-f", "--file",
            "-o", "--output",
            "--format",
            "--filter"
        ]
        if commonValueFlags.contains(value) {
            return true
        }
        switch primaryCommand {
        case "sh", "bash", "zsh", "dash", "ksh":
            return ["-c", "-lc"].contains(value)
        case "kubectl":
            return [
                "-n", "--namespace",
                "--context",
                "--kubeconfig",
                "-l", "--selector",
                "--field-selector",
                "--container"
            ].contains(value)
        case "journalctl":
            return [
                "-u", "--unit",
                "--since",
                "--until",
                "-p", "--priority",
                "-t", "--identifier"
            ].contains(value)
        case "systemctl":
            return ["-t", "--type", "--state"].contains(value)
        case "docker", "podman", "nerdctl", "crictl", "ctr":
            return [
                "--name",
                "--network",
                "-v", "--volume",
                "--mount",
                "-p", "--publish",
                "--env", "-e",
                "--image",
                "--context",
                "--tail",
                "--since",
                "--until",
                "--profile",
                "--project-name",
                "-f", "--file"
            ].contains(value)
        case "docker-compose", "compose":
            return [
                "-f", "--file",
                "-p", "--project-name",
                "--profile",
                "--env-file",
                "--tail",
                "--since",
                "--until",
                "--scale"
            ].contains(value)
        case "helm":
            return [
                "-n", "--namespace",
                "--kube-context",
                "--kubeconfig",
                "-f", "--values",
                "--set",
                "--version",
                "--repo"
            ].contains(value)
        case "nginx":
            return ["-c", "-p", "-g", "-s"].contains(value)
        case "firewall-cmd":
            return ["--zone", "--timeout", "--set-log-denied"].contains(value)
        case "iptables", "pfctl":
            return [
                "-p", "--protocol", "--dport", "--sport", "-s", "--source",
                "-d", "--destination", "-j", "--jump", "-i", "--in-interface",
                "-o", "--out-interface", "-t", "--table"
            ].contains(value)
        case "nft":
            return ["-f", "--file", "-I", "--includepath"].contains(value)
        case "ufw":
            return ["--dry-run"].contains(value)
        case "ip":
            return false
        case "terraform", "tofu":
            return [
                "-chdir",
                "-out",
                "-var",
                "-var-file",
                "-state",
                "-target",
                "-lock-timeout"
            ].contains(value)
        case "ansible", "ansible-playbook":
            return [
                "-i", "--inventory",
                "-m", "--module-name",
                "-a", "--args",
                "-u", "--user",
                "--become-user",
                "-e", "--extra-vars",
                "--limit",
                "--tags",
                "--skip-tags",
                "--vault-password-file"
            ].contains(value)
        case "supervisorctl":
            return ["-c", "--configuration", "-s", "--serverurl", "-u", "--username", "-p", "--password"].contains(value)
        case "pm2":
            return ["--lines", "-n", "--name", "--env", "--only", "--update-env", "--instances"].contains(value)
        case "psql":
            return ["-c", "--command", "-d", "--dbname", "-h", "--host", "-p", "--port", "-U", "--username", "-f", "--file"].contains(value)
        case "mysql", "mariadb":
            return ["-e", "--execute", "-h", "--host", "-P", "--port", "-u", "--user", "-p", "--password"].contains(value)
        case "redis-cli":
            return ["-h", "-p", "-a", "-n", "--user", "--pass", "-u"].contains(value)
        case "aws":
            return ["--profile", "--region", "--output", "--query", "--endpoint-url"].contains(value)
        case "gcloud":
            return ["--project", "--zone", "--region", "--account", "--format", "--filter"].contains(value)
        case "az":
            return ["--subscription", "--resource-group", "--name", "--query", "--output"].contains(value)
        case "rsync":
            return ["-e", "--rsh", "--rsync-path", "--log-file", "--files-from", "--exclude", "--include"].contains(value)
        case "scp", "ssh":
            return [
                "-b", "-c", "-D", "-E", "-e", "-F", "-i", "-J", "-L", "-l",
                "-m", "-O", "-o", "-p", "-Q", "-R", "-S", "-W", "-w"
            ].contains(value)
        case "xargs":
            return [
                "-a", "--arg-file",
                "-d", "--delimiter",
                "-E", "-e", "--eof",
                "-I", "-i", "--replace",
                "-L", "-l", "--max-lines",
                "-n", "--max-args",
                "-P", "--max-procs",
                "-s", "--max-chars"
            ].contains(value)
        default:
            return false
        }
    }

    private static func isRiskActionToken(_ value: String) -> Bool {
        dangerousSubcommands.contains(value)
            || value.hasPrefix("--add-")
            || value.hasPrefix("--remove-")
            || value.hasPrefix("--delete-")
            || value == "--delete"
            || value.hasPrefix("--change-")
    }

    private static func shouldTreatAsShellScript(
        _ value: String,
        primaryCommand: String?,
        previousWord: String?
    ) -> Bool {
        guard let primaryCommand,
              ["sh", "bash", "zsh", "dash", "ksh"].contains(primaryCommand),
              ["-c", "-lc"].contains(previousWord ?? "")
        else {
            return false
        }
        return AgentActionClassifier.risk(forCommand: value) != .readOnly
    }
}

private extension TerminalCommandTokenKind {
    var isLegacyKind: Bool {
        switch self {
        case .command, .subcommand, .dangerousSubcommand, .flag, .path, .environmentAssignment, .argument, .operatorToken:
            return true
        case .stringLiteral, .numberLiteral, .variableReference, .commandSubstitution, .comment, .globPattern, .redirectionTarget, .heredocMarker:
            return false
        }
    }
}
