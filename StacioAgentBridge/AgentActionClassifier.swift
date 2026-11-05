import Foundation

public enum AgentActionRisk: String, Codable, Equatable, Comparable {
    case readOnly
    case write
    case network
    case destructive

    public static func < (lhs: AgentActionRisk, rhs: AgentActionRisk) -> Bool {
        let order: [AgentActionRisk] = [.readOnly, .write, .network, .destructive]
        return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
    }
}

public enum AgentActionClassifier {
    public static func risk(forCommand command: String) -> AgentActionRisk {
        risk(forCommand: command, expansionDepth: 0)
    }

    private static func risk(
        forCommand command: String,
        expansionDepth: Int
    ) -> AgentActionRisk {
        let tokens = ShellCommandTokenizer.tokenize(command)
        var resolvedRisk: AgentActionRisk = containsWriteRedirection(in: tokens) ? .write : .readOnly
        // Command substitutions are executable, but a diagnostic script often
        // uses read-only commands such as `$(pgrep ...)` or `$(ps ...)`. Classify
        // the nested command instead of upgrading every substitution to network.
        if let expansionRisk = executableExpansionRisk(in: command, depth: expansionDepth),
           resolvedRisk < expansionRisk {
            resolvedRisk = expansionRisk
        }
        for segment in ShellCommandTokenizer.commandSegments(from: tokens) {
            let segmentRisk = riskForSegment(segment)
            if segmentRisk == .destructive {
                return .destructive
            }
            if resolvedRisk < segmentRisk {
                resolvedRisk = segmentRisk
            }
        }
        return resolvedRisk
    }

    private static func executableExpansionRisk(
        in command: String,
        depth: Int
    ) -> AgentActionRisk? {
        guard depth < 8 else { return .network }
        var highestRisk: AgentActionRisk?
        var index = command.startIndex
        var inSingleQuote = false
        var escaped = false

        while index < command.endIndex {
            let character = command[index]
            if escaped {
                escaped = false
                index = command.index(after: index)
                continue
            }
            if character == "\\", inSingleQuote == false {
                escaped = true
                index = command.index(after: index)
                continue
            }
            if character == "'" {
                inSingleQuote.toggle()
                index = command.index(after: index)
                continue
            }
            if inSingleQuote {
                index = command.index(after: index)
                continue
            }

            if character == "`" {
                let searchStart = command.index(after: index)
                guard let end = command[searchStart..<command.endIndex].firstIndex(of: "`")
                else { return .network }
                let nested = String(command[searchStart..<end])
                highestRisk = maxRisk(highestRisk, risk(forCommand: nested, expansionDepth: depth + 1))
                index = command.index(after: end)
                continue
            }

            if character == "$" || character == "<" || character == ">" {
                let opening = command.index(after: index)
                if opening < command.endIndex, command[opening] == "(" {
                    guard let expansion = balancedExpansion(in: command, opening: opening) else {
                        return .network
                    }
                    highestRisk = maxRisk(
                        highestRisk,
                        risk(forCommand: expansion.body, expansionDepth: depth + 1)
                    )
                    index = expansion.nextIndex
                    continue
                }
            }
            index = command.index(after: index)
        }
        return highestRisk
    }

    private struct BalancedExpansion {
        let body: String
        let nextIndex: String.Index
    }

    private static func balancedExpansion(
        in command: String,
        opening: String.Index
    ) -> BalancedExpansion? {
        var depth = 1
        var quote: Character?
        var escaped = false
        var index = command.index(after: opening)
        let bodyStart = index

        while index < command.endIndex {
            let character = command[index]
            if escaped {
                escaped = false
                index = command.index(after: index)
                continue
            }
            if character == "\\", quote != "'" {
                escaped = true
                index = command.index(after: index)
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                }
                index = command.index(after: index)
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
            } else if character == "(" {
                depth += 1
            } else if character == ")" {
                depth -= 1
                if depth == 0 {
                    return BalancedExpansion(
                        body: String(command[bodyStart..<index]),
                        nextIndex: command.index(after: index)
                    )
                }
            }
            index = command.index(after: index)
        }
        return nil
    }

    private static func maxRisk(
        _ current: AgentActionRisk?,
        _ candidate: AgentActionRisk
    ) -> AgentActionRisk {
        guard let current else { return candidate }
        return max(current, candidate)
    }

    private static func containsWriteRedirection(in tokens: [ShellCommandToken]) -> Bool {
        for (index, token) in tokens.enumerated() where token.isQuoted == false {
            let value = token.text
            if [">", ">>", "1>", "1>>", "&>"].contains(value)
                || value.hasPrefix("1>")
                || value.hasPrefix("&>")
            {
                return true
            }
            if value == "2>" || value == "2>>" {
                guard tokens.indices.contains(index + 1), tokens[index + 1].text == "/dev/null" else {
                    return true
                }
            } else if value.hasPrefix("2>") {
                let target = value.drop(while: { $0 == "2" || $0 == ">" })
                if target != "/dev/null" {
                    return true
                }
            }
        }
        return false
    }

    private static func riskForSegment(_ tokens: [ShellCommandToken]) -> AgentActionRisk {
        var index = 0
        var sawWrapper = false
        while index < tokens.count {
            let token = tokens[index]
            let word = normalizedExecutable(token.text)
            index += 1
            if word.isEmpty {
                continue
            }
            if token.isQuoted == false,
               ShellCommandTokenizer.redirectionOperators.contains(word) {
                break
            }
            if token.isQuoted == false, isEnvironmentAssignment(word) {
                index = skipAssignmentExpansionTokens(
                    tokens: tokens,
                    nextIndex: index,
                    initialText: token.text
                )
                continue
            }
            if token.isQuoted == false, isShellControlWord(word) {
                if word == "for" {
                    return .readOnly
                }
                continue
            }
            if isWrapperCommand(word) {
                sawWrapper = true
                skipWrapperArguments(wrapper: word, tokens: tokens, index: &index)
                continue
            }
            return riskForExecutable(word, arguments: Array(tokens[index...]))
        }
        return sawWrapper ? .network : .readOnly
    }

    private static func isShellControlWord(_ word: String) -> Bool {
        ["do", "done", "else", "fi", "for", "if", "in", "then", "until", "while"].contains(word)
    }

    private static func skipAssignmentExpansionTokens(
        tokens: [ShellCommandToken],
        nextIndex: Int,
        initialText: String
    ) -> Int {
        var parenthesisBalance = initialText.reduce(into: 0) { count, character in
            if character == "(" { count += 1 }
            if character == ")" { count -= 1 }
        }
        var backtickBalance = initialText.filter { $0 == "`" }.count % 2
        var index = nextIndex
        while index < tokens.count && (parenthesisBalance > 0 || backtickBalance == 1) {
            let text = tokens[index].text
            parenthesisBalance += text.reduce(into: 0) { count, character in
                if character == "(" { count += 1 }
                if character == ")" { count -= 1 }
            }
            backtickBalance = (backtickBalance + text.filter { $0 == "`" }.count) % 2
            index += 1
        }
        return index
    }

    private static func riskForExecutable(
        _ command: String,
        arguments: [ShellCommandToken]
    ) -> AgentActionRisk {
        if let shellRisk = shellScriptRisk(command: command, arguments: arguments) {
            return shellRisk
        }

        let words = commandWords(from: arguments)
        switch command {
        case "kubectl":
            return riskForKubectl(words)
        case "systemctl":
            return riskForSystemctl(words)
        case "docker", "podman", "nerdctl", "crictl", "ctr":
            return riskForDocker(words)
        case "docker-compose", "compose":
            return riskForDockerCompose(words)
        case "helm":
            return riskForHelm(words)
        case "nginx":
            return riskForNginx(words)
        case "firewall-cmd":
            return riskForFirewallCommand(words)
        case "service":
            return riskForService(words)
        case "ip":
            return riskForIP(words)
        case "rm", "mkfs", "shutdown", "reboot", "halt", "poweroff":
            return words.contains("--help") || words.contains("--version") ? .readOnly : .destructive
        case "dd":
            return words.contains(where: { $0.hasPrefix("if=") || $0.hasPrefix("of=") }) ? .destructive : .readOnly
        case "curl", "nc", "netcat":
            return .network
        case "ssh":
            return riskForSSH(arguments)
        case "rsync":
            return riskForRsync(words)
        case "scp":
            return .network
        case "iptables", "pfctl":
            return riskForFirewallTableCommand(words)
        case "nft":
            return riskForNFT(words)
        case "ufw":
            return riskForUFW(words)
        case "xargs":
            return riskForXargs(arguments)
        case "apt", "apt-get":
            return riskForDebianPackageCommand(words)
        case "yum", "dnf":
            return riskForRPMFamilyPackageCommand(words)
        case "apk":
            return riskForAlpinePackageCommand(words)
        case "zypper":
            return riskForZypperPackageCommand(words)
        case "pacman":
            return riskForPacmanPackageCommand(arguments)
        case "git":
            return riskForGit(words)
        case "tee", "chmod", "chown", "chgrp", "mv", "cp", "mkdir", "touch", "ln", "install":
            return .write
        case "rmdir", "unlink":
            return words.contains("--help") || words.contains("--version") ? .readOnly : .destructive
        case "find":
            return riskForFind(arguments)
        case "sed":
            return riskForSed(words)
        case "perl", "python", "python2", "python3", "ruby", "node", "php", "osascript":
            return riskForInterpreter(words)
        case "eval", "source", ".":
            return .network
        case "kill", "killall", "pkill":
            return words.contains("--help") || words.contains("--version") ? .readOnly : .network
        case "sysctl":
            return riskForSysctl(words)
        case "mount":
            return riskForMount(words)
        case "launchctl":
            return riskForLaunchctl(words)
        case "rpm":
            return riskForRPMCommand(words)
        case "terraform", "tofu":
            return riskForTerraform(words)
        case "ansible-inventory":
            return words.contains("--list") || words.contains("--host") || words.contains("--graph")
                ? .readOnly
                : .network
        case "ansible", "ansible-playbook":
            return riskForAnsible(command: command, arguments: arguments, words: words)
        case "supervisorctl":
            return riskForSupervisorctl(words)
        case "pm2":
            return riskForPM2(words)
        case "psql":
            return riskForSQLClient(words, queryFlags: ["-c", "--command"])
        case "mysql", "mariadb":
            return riskForSQLClient(words, queryFlags: ["-e", "--execute"])
        case "redis-cli":
            return riskForRedisCLI(words)
        case "aws":
            return riskForAWS(words)
        case "gcloud":
            return riskForGCloud(words)
        case "az":
            return riskForAzureCLI(words)
        default:
            if isKnownDangerousExecutable(command) {
                return .destructive
            }
            if readOnlyExecutables.contains(command) {
                return .readOnly
            }
            // Unknown binaries, aliases and scripts are executable code. They
            // must never enter a read-only automatic-execution path.
            return .network
        }
    }

    private static let readOnlyExecutables: Set<String> = [
        "[", "arch", "basename", "blkid", "cat", "column", "cut", "date",
        "df", "dirname", "dmesg", "du", "echo", "egrep", "false", "fgrep",
        "file", "free", "getent", "grep", "groups", "head", "hostname", "id",
        "iostat", "journalctl", "join", "jq", "less", "lscpu", "ls", "lsblk",
        "lsmem", "lsof", "lspci", "lsusb", "md5", "md5sum", "more", "mpstat",
        "netstat", "nl", "pgrep", "printenv", "printf", "ps", "pwd", "readlink",
        "realpath", "rg", "sar", "sha1sum", "sha256sum", "shasum", "sleep", "sort",
        "ss", "stat", "strings", "sw_vers", "tail", "test", "top", "tr", "true",
        "type", "uname", "uniq", "uptime", "vm_stat", "vmstat", "w", "wc", "whereis", "which",
        "who", "whoami"
    ]

    /// 检测未在 switch 中显式枚举但具有破坏性的可执行程序。
    private static func isKnownDangerousExecutable(_ command: String) -> Bool {
        // mkfs 系列变体：mkfs.ext2/3/4, mkfs.btrfs, mkfs.xfs, mkfs.ntfs, mkfs.vfat 等
        if command.hasPrefix("mkfs.") || command == "mke2fs" || command == "mkfs" {
            return true
        }
        let dangerousCommands: Set<String> = [
            "shred", "wipe", "truncate", "init", "telinit",
            "ddrescue", "badblocks", "blkdiscard", "shred-uwipe",
            "nvme-format", "sg_format", "hdparm"
        ]
        return dangerousCommands.contains(command)
    }

    private static func shellScriptRisk(
        command: String,
        arguments: [ShellCommandToken]
    ) -> AgentActionRisk? {
        guard ["sh", "bash", "zsh", "dash", "ksh"].contains(command) else {
            return nil
        }
        var index = 0
        while index < arguments.count {
            let word = normalizedWord(arguments[index].text)
            if ShellCommandTokenizer.redirectionOperators.contains(word) {
                break
            }
            if word == "-c" || (word.hasPrefix("-") && word.hasPrefix("--") == false && word.contains("c")) {
                // -c 显式指定，或组合短旗标（如 -lc、-sc）中含 c：均表示执行后续脚本
                let scriptIndex = arguments.index(after: index)
                guard arguments.indices.contains(scriptIndex) else {
                    return .network
                }
                return risk(forCommand: arguments[scriptIndex].text)
            }
            index += 1
        }
        let words = commandWords(from: arguments)
        if words.contains("--help") || words.contains("--version") || words.contains("-n") {
            return .readOnly
        }
        // `sh script`, an interactive shell, and sourced profiles can execute
        // arbitrary operations even without an explicit `-c`.
        return .network
    }

    private static func riskForDebianPackageCommand(_ words: [String]) -> AgentActionRisk {
        if words.contains(where: { ["remove", "purge", "autoremove"].contains($0) }) {
            return .destructive
        }
        if words.contains(where: { ["update", "install", "upgrade", "dist-upgrade"].contains($0) }) {
            return .network
        }
        return .readOnly
    }

    private static func riskForRPMFamilyPackageCommand(_ words: [String]) -> AgentActionRisk {
        if words.contains(where: { ["remove", "erase", "autoremove"].contains($0) }) {
            return .destructive
        }
        if words.contains(where: { ["update", "install", "upgrade"].contains($0) }) {
            return .network
        }
        return .readOnly
    }

    private static func riskForAlpinePackageCommand(_ words: [String]) -> AgentActionRisk {
        if words.contains(where: { ["del", "delete"].contains($0) }) {
            return .destructive
        }
        if words.contains(where: { ["add", "upgrade", "update", "fix"].contains($0) }) {
            return .network
        }
        return .readOnly
    }

    private static func riskForZypperPackageCommand(_ words: [String]) -> AgentActionRisk {
        if words.contains(where: { ["remove", "rm"].contains($0) }) {
            return .destructive
        }
        if words.contains(where: { ["install", "in", "update", "up", "patch", "dup"].contains($0) }) {
            return .network
        }
        return .readOnly
    }

    private static func riskForPacmanPackageCommand(_ arguments: [ShellCommandToken]) -> AgentActionRisk {
        for argument in arguments where argument.isQuoted == false {
            let value = argument.text
            if value.hasPrefix("--") {
                switch value.lowercased() {
                case "--remove": return .destructive
                case "--sync", "--upgrade": return .network
                default: continue
                }
            }
            guard value.hasPrefix("-") else { continue }
            let optionCharacters = Set(value.dropFirst())
            if optionCharacters.contains("R") {
                return .destructive
            }
            if optionCharacters.contains("S") || optionCharacters.contains("U") {
                return .network
            }
        }
        return .readOnly
    }

    private static func riskForGit(_ words: [String]) -> AgentActionRisk {
        if words.contains("clean")
            || words.contains("rm")
            || (words.contains("reset") && words.contains("--hard"))
            || (words.contains("stash") && words.contains(where: { ["drop", "clear"].contains($0) }))
            || (words.contains("worktree") && words.contains(where: { ["remove", "prune"].contains($0) }))
            || (words.contains("branch") && words.contains(where: { ["-d", "-D", "--delete"].contains($0) }))
            || (words.contains("tag") && words.contains(where: { ["-d", "--delete"].contains($0) })) {
            return .destructive
        }
        if words.contains(where: { ["push", "fetch", "pull", "clone", "ls-remote"].contains($0) })
            || (words.contains("submodule") && words.contains(where: { ["update", "sync", "add"].contains($0) })) {
            return .network
        }
        if words.contains("config") {
            let readFlags: Set<String> = [
                "--get", "--get-all", "--get-regexp", "--get-urlmatch", "--list", "-l",
                "--show-origin", "--show-scope"
            ]
            return words.contains(where: readFlags.contains) ? .readOnly : .write
        }
        if words.contains(where: {
            [
                "add", "am", "apply", "bisect", "checkout", "cherry-pick", "commit", "gc",
                "init", "merge", "mv", "rebase", "reset", "restore", "revert", "switch"
            ].contains($0)
        })
            || (words.contains("branch") && words.contains(where: { $0.hasPrefix("-") == false && $0 != "branch" }))
            || (words.contains("tag") && words.contains(where: { $0.hasPrefix("-") == false && $0 != "tag" }))
            || (words.contains("stash") && words.contains(where: { ["push", "pop", "apply", "save"].contains($0) }))
            || (words.contains("worktree") && words.contains("add")) {
            return .write
        }
        let readSubcommands: Set<String> = [
            "annotate", "blame", "branch", "describe", "diff", "grep", "help", "log",
            "ls-files", "ls-tree", "remote", "rev-list", "rev-parse", "shortlog", "show",
            "show-ref", "status", "tag", "version", "whatchanged", "worktree"
        ]
        return words.contains(where: readSubcommands.contains) ? .readOnly : .network
    }

    private static func riskForFind(_ arguments: [ShellCommandToken]) -> AgentActionRisk {
        let words = commandWords(from: arguments)
        if words.contains("-delete") {
            return .destructive
        }
        if words.contains(where: { ["-fprint", "-fprint0", "-fprintf", "-fls"].contains($0) }) {
            return .write
        }
        if let actionIndex = arguments.firstIndex(where: {
            ["-exec", "-execdir", "-ok", "-okdir"].contains(normalizedWord($0.text))
        }) {
            let nestedIndex = arguments.index(after: actionIndex)
            guard nestedIndex < arguments.endIndex else { return .network }
            return riskForSegment(Array(arguments[nestedIndex...]))
        }
        return .readOnly
    }

    private static func riskForSed(_ words: [String]) -> AgentActionRisk {
        let mutatesInPlace = words.contains { word in
            word == "-i"
                || word.hasPrefix("--in-place")
                || (word.hasPrefix("-") && word.hasPrefix("--") == false && word.dropFirst().contains("i"))
        }
        if mutatesInPlace {
            return .write
        }
        if words.contains("--help") || words.contains("--version") {
            return .readOnly
        }
        // sed scripts may execute commands (`e`) or write files (`w`) without
        // `-i`; parsing the full sed language here would be unsafe.
        return .network
    }

    private static func riskForInterpreter(_ words: [String]) -> AgentActionRisk {
        if words.isEmpty == false,
           words.allSatisfy({ ["-v", "--version", "-h", "--help"].contains($0) }) {
            return .readOnly
        }
        return .network
    }

    private static func riskForSysctl(_ words: [String]) -> AgentActionRisk {
        if words.contains("-w") || words.contains("--write")
            || words.contains(where: { $0.contains("=") && $0.hasPrefix("-") == false }) {
            return .write
        }
        return .readOnly
    }

    private static func riskForMount(_ words: [String]) -> AgentActionRisk {
        if words.isEmpty || words.contains("--help") || words.contains("--version") {
            return .readOnly
        }
        return .network
    }

    private static func riskForLaunchctl(_ words: [String]) -> AgentActionRisk {
        if words.contains(where: { ["list", "print", "print-cache", "procinfo", "hostinfo"].contains($0) }) {
            return .readOnly
        }
        return .network
    }

    private static func riskForXargs(_ arguments: [ShellCommandToken]) -> AgentActionRisk {
        var index = 0
        while index < arguments.count {
            let token = arguments[index]
            let word = normalizedWord(token.text)
            if token.isQuoted == false,
               ShellCommandTokenizer.redirectionOperators.contains(word) {
                return .network
            }
            if word == "--" {
                index += 1
                break
            }
            guard word.hasPrefix("-") else {
                break
            }
            index += 1
            if xargsFlagConsumesNextValue(word), index < arguments.count {
                index += 1
            }
        }
        guard index < arguments.count else {
            return .readOnly
        }
        return riskForSegment(Array(arguments[index...]))
    }

    private static func xargsFlagConsumesNextValue(_ flag: String) -> Bool {
        if flag.contains("=") {
            return false
        }
        return [
            "-a", "--arg-file",
            "-d", "--delimiter",
            "-E", "-e", "--eof",
            "-I", "-i", "--replace",
            "-L", "-l", "--max-lines",
            "-n", "--max-args",
            "-P", "--max-procs",
            "-s", "--max-chars"
        ].contains(flag)
    }

    private static func riskForRPMCommand(_ words: [String]) -> AgentActionRisk {
        if words.contains(where: { $0 == "-i" || $0 == "-u" || $0.hasPrefix("-i") || $0.hasPrefix("-u") }) {
            return .write
        }
        return .readOnly
    }

    private static func commandWords(from tokens: [ShellCommandToken]) -> [String] {
        var words: [String] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            let word = normalizedWord(token.text)
            index += 1
            if token.isQuoted == false,
               ShellCommandTokenizer.redirectionOperators.contains(word) {
                break
            }
            if word.isEmpty {
                continue
            }
            words.append(word)
        }
        return words
    }

    private static func isWrapperCommand(_ word: String) -> Bool {
        ["sudo", "env", "time", "command", "nohup"].contains(word)
    }

    private static func skipWrapperArguments(
        wrapper: String,
        tokens: [ShellCommandToken],
        index: inout Int
    ) {
        while index < tokens.count {
            let token = tokens[index]
            let word = normalizedWord(token.text)
            if token.isQuoted || ShellCommandTokenizer.redirectionOperators.contains(word) {
                return
            }
            if wrapper == "env", isEnvironmentAssignment(word) {
                index += 1
                continue
            }
            guard word.hasPrefix("-") else {
                return
            }
            index += 1
            if wrapperFlagConsumesNextValue(wrapper: wrapper, flag: word), index < tokens.count {
                index += 1
            }
        }
    }

    private static func wrapperFlagConsumesNextValue(wrapper: String, flag: String) -> Bool {
        if flag.contains("=") {
            return false
        }
        switch wrapper {
        case "sudo":
            return ["-u", "--user", "-g", "--group", "-h", "--host", "-p", "--prompt", "-C", "-T"].contains(flag)
        case "env":
            return ["-u", "--unset"].contains(flag)
        default:
            return false
        }
    }

    private static func isEnvironmentAssignment(_ word: String) -> Bool {
        guard let first = word.first,
              first == "_" || first.isLetter,
              let equalsIndex = word.firstIndex(of: "="),
              equalsIndex != word.startIndex
        else {
            return false
        }
        return word[..<equalsIndex].allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }

    private static func normalizedExecutable(_ value: String) -> String {
        let word = normalizedWord(value)
        return word.split(separator: "/").last.map(String.init) ?? word
    }

    private static func normalizedWord(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")).lowercased()
    }

    private static func riskForKubectl(_ words: [String]) -> AgentActionRisk {
        if words.contains(where: { ["delete", "drain"].contains($0) }) {
            return .destructive
        }
        if words.contains(where: {
            [
                "apply", "rollout", "restart", "scale", "cordon", "uncordon",
                "create", "patch", "edit", "set", "label", "annotate", "exec",
                "cp", "port-forward", "replace", "expose"
            ].contains($0)
        }) {
            return .network
        }
        return .readOnly
    }

    private static func riskForSystemctl(_ words: [String]) -> AgentActionRisk {
        if words.contains(where: { ["start", "restart", "stop", "reload", "enable", "disable", "mask", "unmask", "daemon-reload"].contains($0) }) {
            return .network
        }
        return .readOnly
    }

    private static func riskForDocker(_ words: [String]) -> AgentActionRisk {
        if words.contains(where: { ["rm", "rmi", "prune", "down", "leave", "remove"].contains($0) }) {
            return .destructive
        }
        if words.contains(where: {
            [
                "run", "exec", "login", "logout", "up", "restart", "start", "stop",
                "create", "update", "scale", "deploy", "init", "use", "disable",
                "enable", "push", "bake", "build"
            ].contains($0)
        }) {
            return .network
        }
        return .readOnly
    }

    private static func riskForDockerCompose(_ words: [String]) -> AgentActionRisk {
        riskForDocker(words)
    }

    private static func riskForHelm(_ words: [String]) -> AgentActionRisk {
        if words.contains(where: { ["uninstall", "delete"].contains($0) }) {
            return .destructive
        }
        if words.contains(where: { ["install", "upgrade", "rollback", "repo"].contains($0) }) {
            return .network
        }
        return .readOnly
    }

    private static func riskForNginx(_ words: [String]) -> AgentActionRisk {
        if words.contains(where: { ["reload", "reopen", "stop", "quit"].contains($0) }) {
            return .network
        }
        guard let signalIndex = words.firstIndex(of: "-s"),
              words.indices.contains(words.index(after: signalIndex))
        else {
            return .readOnly
        }
        let signal = words[words.index(after: signalIndex)]
        return ["reload", "reopen", "stop", "quit"].contains(signal) ? .network : .readOnly
    }

    private static func riskForFirewallCommand(_ words: [String]) -> AgentActionRisk {
        if words.contains(where: { $0.hasPrefix("--remove") || $0.hasPrefix("--delete") }) {
            return .destructive
        }
        if words.contains(where: { $0 == "--reload" || $0.hasPrefix("--add") || $0.hasPrefix("--change") }) {
            return .network
        }
        return .readOnly
    }

    private static func riskForFirewallTableCommand(_ words: [String]) -> AgentActionRisk {
        if words.contains(where: { ["-d", "-f", "-x", "-z", "--delete", "--flush", "--delete-chain", "--zero"].contains($0) }) {
            return .destructive
        }
        if words.contains(where: { ["-a", "-i", "-r", "-p", "--append", "--insert", "--replace", "--policy", "--new-chain"].contains($0) }) {
            return .network
        }
        return .readOnly
    }

    private static func riskForNFT(_ words: [String]) -> AgentActionRisk {
        if words.contains(where: { ["delete", "destroy", "flush", "reset"].contains($0) }) {
            return .destructive
        }
        if words.contains(where: { ["add", "insert", "replace", "create"].contains($0) }) {
            return .network
        }
        return .readOnly
    }

    private static func riskForUFW(_ words: [String]) -> AgentActionRisk {
        if words.contains("delete") || words.contains("reset") {
            return .destructive
        }
        if words.contains(where: { ["allow", "deny", "reject", "limit", "enable", "disable", "reload"].contains($0) }) {
            return .network
        }
        return .readOnly
    }

    private static func riskForService(_ words: [String]) -> AgentActionRisk {
        if words.contains(where: { ["start", "restart", "stop", "reload"].contains($0) }) {
            return .network
        }
        return .readOnly
    }

    private static func riskForIP(_ words: [String]) -> AgentActionRisk {
        if words.contains(where: { ["set", "add", "del", "delete", "replace"].contains($0) }) {
            return .network
        }
        return .readOnly
    }

    private static func riskForTerraform(_ words: [String]) -> AgentActionRisk {
        if words.contains("destroy") || words.contains("-destroy") {
            return .destructive
        }
        if let stateIndex = words.firstIndex(of: "state"),
           words.indices.contains(words.index(after: stateIndex)),
           ["rm", "remove"].contains(words[words.index(after: stateIndex)]) {
            return .destructive
        }
        if let workspaceIndex = words.firstIndex(of: "workspace"),
           words.indices.contains(words.index(after: workspaceIndex)),
           words[words.index(after: workspaceIndex)] == "delete" {
            return .destructive
        }
        if words.contains("apply")
            || words.contains("import")
            || words.contains("init")
            || words.contains("refresh")
            || words.contains("taint")
            || words.contains("untaint")
            || words.contains("-upgrade")
            || words.contains(where: { $0 == "-out" || $0.hasPrefix("-out=") }) {
            return .network
        }
        if words.contains("workspace")
            && words.contains(where: { ["new", "select"].contains($0) }) {
            return .network
        }
        return .readOnly
    }

    private static func riskForAnsible(
        command: String,
        arguments: [ShellCommandToken],
        words: [String]
    ) -> AgentActionRisk {
        if command == "ansible-playbook" {
            return ansibleArgumentsRequestCheckMode(arguments) ? .readOnly : .network
        }

        let module = value(after: ["-m", "--module-name"], in: words)
            ?? value(fromLongOptionWithEquals: "--module-name=", in: words)
        if let module, ["ping", "setup", "debug", "service_facts", "package_facts", "stat"].contains(module) {
            return .readOnly
        }

        let moduleArguments = value(after: ["-a", "--args"], in: words)
            ?? value(fromLongOptionWithEquals: "--args=", in: words)
        if let module, ["shell", "command", "raw", "script"].contains(module) {
            guard let moduleArguments else {
                return .network
            }
            let nestedRisk = risk(forCommand: moduleArguments)
            return nestedRisk == .readOnly ? .network : nestedRisk
        }

        let joined = words.joined(separator: " ")
        if module == "file", joined.contains("state=absent") {
            return .destructive
        }
        if let module, ["service", "systemd", "copy", "template", "lineinfile", "user", "group", "yum", "dnf", "apt", "package"].contains(module) {
            if joined.contains("state=absent") || joined.contains("state=removed") {
                return .destructive
            }
            return .network
        }

        if ansibleArgumentsRequestCheckMode(arguments) {
            return .readOnly
        }
        return .network
    }

    private static func ansibleArgumentsRequestCheckMode(_ arguments: [ShellCommandToken]) -> Bool {
        arguments.contains { token in
            token.text == "-C" || normalizedWord(token.text) == "--check"
        }
    }

    private static func riskForSupervisorctl(_ words: [String]) -> AgentActionRisk {
        if words.contains(where: { ["start", "stop", "restart", "reload", "reread", "update", "shutdown"].contains($0) }) {
            return .network
        }
        if words.contains(where: { ["remove", "delete", "clear"].contains($0) }) {
            return .destructive
        }
        return .readOnly
    }

    private static func riskForPM2(_ words: [String]) -> AgentActionRisk {
        if words.contains(where: { ["delete", "del", "kill", "unstartup"].contains($0) }) {
            return .destructive
        }
        if words.contains(where: { ["start", "stop", "restart", "reload", "gracefulreload", "scale", "deploy", "save", "resurrect", "startup"].contains($0) }) {
            return .network
        }
        return .readOnly
    }

    private static func riskForSQLClient(_ words: [String], queryFlags: Set<String>) -> AgentActionRisk {
        guard let sql = inlineSQL(from: words, queryFlags: queryFlags) else {
            return .network
        }
        if containsDestructiveSQL(sql) {
            return .destructive
        }
        if containsMutatingSQL(sql) {
            return .network
        }
        return .readOnly
    }

    private static func riskForRedisCLI(_ words: [String]) -> AgentActionRisk {
        let redisWords = words.filter { word in
            word.hasPrefix("-") == false && word.contains(":") == false
        }
        if redisWords.contains(where: { ["flushall", "flushdb", "del", "unlink", "shutdown"].contains($0) }) {
            return .destructive
        }
        if redisWords.contains(where: {
            [
                "set", "mset", "hset", "hmset", "lpush", "rpush", "sadd", "zadd",
                "xadd", "incr", "decr", "expire", "persist", "publish", "config"
            ].contains($0)
        }) {
            return .network
        }
        return .readOnly
    }

    private static func riskForAWS(_ words: [String]) -> AgentActionRisk {
        if words.contains("--delete")
            || words.contains(where: { $0 == "rm" || $0 == "delete" || $0.hasPrefix("delete-") || $0.hasPrefix("terminate-") }) {
            return .destructive
        }
        if words.contains(where: {
            [
                "cp", "sync", "mv", "put", "create", "update", "start",
                "stop", "restart", "deploy", "publish", "invoke"
            ].contains($0) || $0.hasPrefix("put-") || $0.hasPrefix("create-") || $0.hasPrefix("update-")
        }) {
            return .network
        }
        return .readOnly
    }

    private static func riskForGCloud(_ words: [String]) -> AgentActionRisk {
        if words.contains(where: { $0 == "delete" || $0 == "remove" || $0 == "destroy" || $0.hasPrefix("delete-") }) {
            return .destructive
        }
        if words.contains(where: {
            [
                "create", "update", "set", "add", "start", "stop", "restart",
                "deploy", "apply", "get-credentials"
            ].contains($0)
        }) {
            return .network
        }
        return .readOnly
    }

    private static func riskForAzureCLI(_ words: [String]) -> AgentActionRisk {
        if words.contains(where: { ["delete", "remove", "purge"].contains($0) }) {
            return .destructive
        }
        if words.contains(where: { ["create", "update", "set", "restart", "start", "stop", "deploy"].contains($0) }) {
            return .network
        }
        return .readOnly
    }

    private static func riskForRsync(_ words: [String]) -> AgentActionRisk {
        words.contains("--delete") ? .destructive : .network
    }

    private static func riskForSSH(_ arguments: [ShellCommandToken]) -> AgentActionRisk {
        var index = 0
        var foundDestination = false
        var remoteCommandTokens: [ShellCommandToken] = []
        while index < arguments.count {
            let token = arguments[index]
            let word = normalizedWord(token.text)
            if token.isQuoted == false, ShellCommandTokenizer.redirectionOperators.contains(word) {
                break
            }
            if foundDestination {
                remoteCommandTokens.append(token)
                index += 1
                continue
            }
            if token.isQuoted == false, word == "--" {
                index += 1
                continue
            }
            if token.isQuoted == false, word.hasPrefix("-") {
                index += 1
                if sshFlagConsumesNextValue(word), index < arguments.count {
                    index += 1
                }
                continue
            }
            foundDestination = true
            index += 1
        }
        guard remoteCommandTokens.isEmpty == false else {
            return .network
        }
        let nestedCommand = remoteCommandTokens.map(\.text).joined(separator: " ")
        let nestedRisk = risk(forCommand: nestedCommand)
        return nestedRisk == .destructive ? .destructive : .network
    }

    private static func sshFlagConsumesNextValue(_ flag: String) -> Bool {
        if flag.count > 2, flag.hasPrefix("-"), flag.hasPrefix("--") == false {
            return false
        }
        return [
            "-b", "-c", "-D", "-E", "-e", "-F", "-i", "-J", "-L", "-l",
            "-m", "-O", "-o", "-p", "-Q", "-R", "-S", "-W", "-w"
        ].contains(flag)
    }

    private static func inlineSQL(from words: [String], queryFlags: Set<String>) -> String? {
        var fragments: [String] = []
        var index = 0
        while index < words.count {
            let word = words[index]
            if queryFlags.contains(word), words.indices.contains(index + 1) {
                fragments.append(words[index + 1])
                index += 2
                continue
            }
            if let flag = queryFlags.first(where: { word.hasPrefix($0 + "=") }) {
                fragments.append(String(word.dropFirst(flag.count + 1)))
            }
            index += 1
        }
        return fragments.isEmpty ? nil : fragments.joined(separator: " ")
    }

    private static func containsDestructiveSQL(_ sql: String) -> Bool {
        [
            "drop database", "drop table", "truncate ", "delete from",
            "drop schema", "drop index", "flush privileges"
        ].contains { sql.contains($0) }
    }

    private static func containsMutatingSQL(_ sql: String) -> Bool {
        [
            "alter table", "create table", "create database", "insert into",
            "update ", "grant ", "revoke ", "replace into", "merge into",
            "create index", "drop index concurrently"
        ].contains { sql.contains($0) }
    }

    private static func value(after flags: Set<String>, in words: [String]) -> String? {
        for (index, word) in words.enumerated() where flags.contains(word) {
            let valueIndex = words.index(after: index)
            if words.indices.contains(valueIndex) {
                return words[valueIndex]
            }
        }
        return nil
    }

    private static func value(fromLongOptionWithEquals prefix: String, in words: [String]) -> String? {
        words.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }
}

private struct ShellCommandToken: Equatable {
    let text: String
    let isQuoted: Bool
}

private enum ShellCommandTokenizer {
    static let commandSeparators: Set<String> = ["|", "||", "&", "&&", ";"]
    static let redirectionOperators: Set<String> = [
        ">", ">>", "<", "1>", "1>>", "2>", "2>>", "&>"
    ]

    static func tokenize(_ command: String) -> [ShellCommandToken] {
        var tokens: [ShellCommandToken] = []
        var current = ""
        var quote: Character?
        var currentIsQuoted = false
        var isEscaping = false
        var isInComment = false

        func flush() {
            guard current.isEmpty == false else { return }
            tokens.append(ShellCommandToken(text: current, isQuoted: currentIsQuoted))
            current = ""
            currentIsQuoted = false
        }

        func appendLineSeparator() {
            flush()
            if tokens.last?.text != ";" {
                tokens.append(ShellCommandToken(text: ";", isQuoted: false))
            }
        }

        for character in command {
            if isInComment {
                if character == "\n" {
                    isInComment = false
                    appendLineSeparator()
                }
                continue
            }
            if isEscaping {
                current.append(character)
                isEscaping = false
                continue
            }
            if character == "\\" {
                isEscaping = true
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                    continue
                }
                current.append(character)
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                currentIsQuoted = true
                continue
            }
            if character == "#" && current.isEmpty {
                isInComment = true
                continue
            }
            if character.isWhitespace {
                if character == "\n" {
                    appendLineSeparator()
                } else {
                    flush()
                }
                continue
            }
            if isOperatorCharacter(character) {
                flush()
                tokens.append(ShellCommandToken(text: String(character), isQuoted: false))
                continue
            }
            current.append(character)
        }
        if isEscaping {
            current.append("\\")
        }
        flush()
        return mergeOperators(tokens)
    }

    static func commandSegments(from tokens: [ShellCommandToken]) -> [[ShellCommandToken]] {
        var segments: [[ShellCommandToken]] = []
        var current: [ShellCommandToken] = []
        for token in tokens {
            if token.isQuoted == false, commandSeparators.contains(token.text) {
                if current.isEmpty == false {
                    segments.append(current)
                    current = []
                }
                continue
            }
            current.append(token)
        }
        if current.isEmpty == false {
            segments.append(current)
        }
        return segments
    }

    private static func isOperatorCharacter(_ character: Character) -> Bool {
        ["|", "&", ";", ">", "<"].contains(character)
    }

    private static func mergeOperators(_ tokens: [ShellCommandToken]) -> [ShellCommandToken] {
        var merged: [ShellCommandToken] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            guard token.isQuoted == false else {
                merged.append(token)
                index += 1
                continue
            }
            if index + 1 < tokens.count {
                let next = tokens[index + 1]
                if next.isQuoted == false {
                    let pair = token.text + next.text
                    if commandSeparators.contains(pair) || redirectionOperators.contains(pair) {
                        merged.append(ShellCommandToken(text: pair, isQuoted: false))
                        index += 2
                        continue
                    }
                }
            }
            merged.append(token)
            index += 1
        }
        return merged
    }
}
