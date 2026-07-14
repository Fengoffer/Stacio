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
        let tokens = ShellCommandTokenizer.tokenize(command)
        var resolvedRisk: AgentActionRisk = containsWriteRedirection(in: tokens) ? .write : .readOnly
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

    private static func containsWriteRedirection(in tokens: [ShellCommandToken]) -> Bool {
        tokens.contains { token in
            guard token.isQuoted == false else {
                return false
            }
            let value = token.text
            if [">", ">>", "1>", "1>>", "&>"].contains(value) {
                return true
            }
            if value.hasPrefix(">") || value.hasPrefix(">>") || value.hasPrefix("&>") {
                return true
            }
            if value.hasPrefix("1>") || value.hasPrefix("1>>") {
                return true
            }
            return false
        }
    }

    private static func riskForSegment(_ tokens: [ShellCommandToken]) -> AgentActionRisk {
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            let word = normalizedExecutable(token.text)
            index += 1
            if token.isQuoted || word.isEmpty {
                continue
            }
            if ShellCommandTokenizer.redirectionOperators.contains(word) {
                break
            }
            if isEnvironmentAssignment(word) {
                continue
            }
            if isWrapperCommand(word) {
                skipWrapperArguments(wrapper: word, tokens: tokens, index: &index)
                continue
            }
            return riskForExecutable(word, arguments: Array(tokens[index...]))
        }
        return .readOnly
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
            return riskForPacmanPackageCommand(words)
        case "git":
            return riskForGit(words)
        case "tee", "chmod", "chown", "mv", "cp":
            return .write
        case "rpm":
            return riskForRPMCommand(words)
        case "terraform", "tofu":
            return riskForTerraform(words)
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
            return .readOnly
        }
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
            if word == "-c" || (word.hasPrefix("-") && word.dropFirst().contains("c")) {
                let scriptIndex = arguments.index(after: index)
                guard arguments.indices.contains(scriptIndex) else {
                    return .readOnly
                }
                return risk(forCommand: arguments[scriptIndex].text)
            }
            index += 1
        }
        return .readOnly
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

    private static func riskForPacmanPackageCommand(_ words: [String]) -> AgentActionRisk {
        for word in words {
            guard word.hasPrefix("-") else { continue }
            let optionCharacters = Set(word.dropFirst())
            if optionCharacters.contains("r") {
                return .destructive
            }
            if optionCharacters.contains("s") && optionCharacters.contains("q") == false {
                return .network
            }
            if optionCharacters.contains("u") {
                return .network
            }
        }
        return .readOnly
    }

    private static func riskForGit(_ words: [String]) -> AgentActionRisk {
        if words.contains("clean") {
            return .destructive
        }
        if words.contains("push") {
            return .network
        }
        if words.contains(where: { ["commit", "reset"].contains($0) }) {
            return .write
        }
        return .readOnly
    }

    private static func riskForXargs(_ arguments: [ShellCommandToken]) -> AgentActionRisk {
        var index = 0
        while index < arguments.count {
            let token = arguments[index]
            let word = normalizedWord(token.text)
            if token.isQuoted || ShellCommandTokenizer.redirectionOperators.contains(word) {
                return .readOnly
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
            if ShellCommandTokenizer.redirectionOperators.contains(word) {
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

        func flush() {
            guard current.isEmpty == false else { return }
            tokens.append(ShellCommandToken(text: current, isQuoted: currentIsQuoted))
            current = ""
            currentIsQuoted = false
        }

        for character in command {
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
            if character.isWhitespace {
                flush()
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
