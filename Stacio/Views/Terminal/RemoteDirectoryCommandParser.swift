import Foundation

enum RemoteDirectoryCommandParser {
    enum DirectoryCommand: Equatable {
        case change(String)
        case previous
        case push(String)
        case pop
    }

    static func resolvedDirectory(
        for line: String,
        currentDirectory: String,
        previousDirectory: String?
    ) -> String? {
        let commands = directoryCommands(from: line)
        guard let command = commands.first else {
            return nil
        }
        return resolvedDirectory(
            for: command,
            currentDirectory: currentDirectory,
            previousDirectory: previousDirectory
        )
    }

    static func resolvedDirectory(
        for command: DirectoryCommand,
        currentDirectory: String,
        previousDirectory: String?
    ) -> String? {
        switch command {
        case .change(let target):
            return normalizedDirectory(target, from: currentDirectory)
        case .previous:
            return previousDirectory
        case .push(let target):
            return normalizedDirectory(target, from: currentDirectory)
        case .pop:
            return previousDirectory
        }
    }

    static func directoryCommands(from line: String) -> [DirectoryCommand] {
        shellCommands(from: line).compactMap(directoryCommand(from:))
    }

    private static func directoryCommand(from rawTokens: [String]) -> DirectoryCommand? {
        var tokens = rawTokens
        while let first = tokens.first,
              first == "builtin" || first == "command"
        {
            tokens.removeFirst()
        }

        guard let command = tokens.first else {
            return nil
        }
        tokens.removeFirst()

        switch command {
        case "cd":
            let target = cdTarget(from: tokens)
            if target == "-" {
                return .previous
            }
            if let target,
               isDynamicDirectoryTarget(target)
            {
                return nil
            }
            return .change(target ?? "~")
        case "pushd":
            return pushdCommand(from: tokens)
        case "popd":
            return popdCommand(from: tokens)
        default:
            return nil
        }
    }

    private static func cdTarget(from tokens: [String]) -> String? {
        var remaining = tokens
        while let first = remaining.first {
            if first == "--" {
                remaining.removeFirst()
                break
            }
            if first == "-L" || first == "-P" {
                remaining.removeFirst()
                continue
            }
            break
        }
        return remaining.first
    }

    private static func pushdCommand(from tokens: [String]) -> DirectoryCommand? {
        var remaining = tokens
        while let first = remaining.first {
            if first == "--" {
                remaining.removeFirst()
                break
            }
            if first == "-n" {
                return nil
            }
            break
        }
        guard let target = remaining.first else {
            return nil
        }
        guard isDirectoryStackIndex(target) == false else {
            return nil
        }
        guard isDynamicDirectoryTarget(target) == false else {
            return nil
        }
        return .push(target)
    }

    private static func isDynamicDirectoryTarget(_ target: String) -> Bool {
        target.contains("$") || target.contains("`") || target.contains("$(") || target.hasPrefix("=")
    }

    private static func popdCommand(from tokens: [String]) -> DirectoryCommand? {
        var remaining = tokens
        while let first = remaining.first {
            if first == "--" {
                remaining.removeFirst()
                break
            }
            if first == "-n" {
                return nil
            }
            break
        }
        guard remaining.first.map(isDirectoryStackIndex) != true else {
            return nil
        }
        return .pop
    }

    private static func isDirectoryStackIndex(_ value: String) -> Bool {
        guard let first = value.first,
              first == "+" || first == "-"
        else {
            return false
        }
        return value.dropFirst().allSatisfy(\.isNumber)
    }

    private static func shellCommands(from line: String) -> [[String]] {
        var commands: [[String]] = []
        var currentTokens: [String] = []
        var token = ""
        var quote: Character?
        var escaping = false

        func flushToken() {
            guard token.isEmpty == false else { return }
            currentTokens.append(token)
            token.removeAll()
        }

        func commitCommand() {
            flushToken()
            guard currentTokens.isEmpty == false else { return }
            commands.append(currentTokens)
            currentTokens.removeAll()
        }

        func discardCommand() {
            token.removeAll()
            currentTokens.removeAll()
        }

        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if escaping {
                token.append(character)
                escaping = false
                index = line.index(after: index)
                continue
            }

            if character == "\\" {
                escaping = true
                index = line.index(after: index)
                continue
            }

            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    token.append(character)
                }
                index = line.index(after: index)
                continue
            }

            if character == "'" || character == "\"" {
                quote = character
                index = line.index(after: index)
                continue
            }

            if character.isWhitespace {
                flushToken()
                index = line.index(after: index)
                continue
            }

            if character == "#" {
                commitCommand()
                break
            }

            if character == ";" {
                commitCommand()
                index = line.index(after: index)
                continue
            }

            if character == "&" || character == "|" {
                let nextIndex = line.index(after: index)
                let next = nextIndex < line.endIndex ? line[nextIndex] : nil
                if character == "&", next == "&" {
                    commitCommand()
                    index = line.index(after: nextIndex)
                    continue
                }
                if character == "|", next == "|" {
                    commitCommand()
                    index = line.index(after: nextIndex)
                    continue
                }
                discardCommand()
                index = line.index(after: index)
                continue
            }

            token.append(character)
            index = line.index(after: index)
        }

        commitCommand()
        return commands
    }

    private static func normalizedDirectory(_ rawTarget: String, from currentDirectory: String) -> String {
        let target = expandedHome(rawTarget)
        if target == "~" {
            return "~"
        }
        if target.hasPrefix("~/") {
            return collapsedPath(prefix: "~", baseComponents: [], adding: String(target.dropFirst(2)))
        }
        if target.hasPrefix("/") {
            return collapsedPath(prefix: "/", baseComponents: [], adding: target)
        }

        if currentDirectory == "~" {
            return collapsedPath(prefix: "~", baseComponents: [], adding: target)
        }
        if currentDirectory.hasPrefix("~/") {
            return collapsedPath(
                prefix: "~",
                baseComponents: pathComponents(String(currentDirectory.dropFirst(2))),
                adding: target
            )
        }
        if currentDirectory.hasPrefix("/") {
            return collapsedPath(
                prefix: "/",
                baseComponents: pathComponents(currentDirectory),
                adding: target
            )
        }

        return collapsedPath(
            prefix: "",
            baseComponents: pathComponents(currentDirectory),
            adding: target
        )
    }

    private static func expandedHome(_ target: String) -> String {
        if target == "$HOME" || target == "${HOME}" {
            return "~"
        }
        if target.hasPrefix("$HOME/") {
            return "~/" + String(target.dropFirst("$HOME/".count))
        }
        if target.hasPrefix("${HOME}/") {
            return "~/" + String(target.dropFirst("${HOME}/".count))
        }
        return target
    }

    private static func collapsedPath(prefix: String, baseComponents: [String], adding path: String) -> String {
        var components = baseComponents
        for component in pathComponents(path) {
            if component == "." {
                continue
            }
            if component == ".." {
                if components.isEmpty == false {
                    components.removeLast()
                } else if prefix.isEmpty {
                    components.append(component)
                }
                continue
            }
            components.append(component)
        }

        switch prefix {
        case "/":
            return components.isEmpty ? "/" : "/" + components.joined(separator: "/")
        case "~":
            return components.isEmpty ? "~" : "~/" + components.joined(separator: "/")
        default:
            return components.isEmpty ? "." : components.joined(separator: "/")
        }
    }

    private static func pathComponents(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }
}
