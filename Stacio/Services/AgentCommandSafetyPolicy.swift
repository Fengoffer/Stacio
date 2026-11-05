import Foundation

/// Hard safety limits that cannot be relaxed by the user's approval mode.
///
/// The normal approval policy may allow destructive maintenance commands when
/// the user explicitly chooses full automation.  Commands that target the
/// root filesystem are different: allowing them to run unattended can make
/// the host unbootable, so they are denied at the shared policy boundary.
public enum AgentCommandSafetyPolicy {
    public static func catastrophicReason(for command: String) -> String? {
        let tokens = Lexer.tokenize(command)
        let separators: Set<String> = [";", "|", "||", "&", "&&", "{", "}"]
        var segment: [Token] = []

        func isCatastrophic(_ invocation: [Token]) -> Bool {
            var index = 0
            while index < invocation.count {
                let token = invocation[index]
                let word = token.text.lowercased()
                if ["{", "}", "then", "do", "else"].contains(word) {
                    index += 1
                    continue
                }
                if isAssignment(word) {
                    index += 1
                    continue
                }
                if ["sudo", "env", "command", "nohup", "time"].contains(word) {
                    index += 1
                    while index < invocation.count,
                          invocation[index].quoted == false,
                          invocation[index].text.hasPrefix("-") {
                        index += 1
                        if word == "sudo",
                           index < invocation.count,
                           ["-u", "--user", "-g", "--group", "-p", "--prompt"].contains(invocation[index - 1].text),
                           invocation[index].quoted == false {
                            index += 1
                        }
                    }
                    continue
                }
                if ["sh", "bash", "dash", "zsh", "ksh", "fish"].contains(word) {
                    index += 1
                    while index < invocation.count {
                        let argument = invocation[index]
                        index += 1
                        if ["-c", "--command"].contains(argument.text.lowercased()) {
                            guard index < invocation.count else { return false }
                            let script = invocation[index]
                            return catastrophicReason(for: script.text) != nil
                        }
                        if argument.text.hasPrefix("-c=") || argument.text.hasPrefix("--command=") {
                            let script = argument.text.split(separator: "=", maxSplits: 1).dropFirst().joined(separator: "=")
                            return catastrophicReason(for: script) != nil
                        }
                    }
                    return false
                }
                guard word == "rm" else { return false }
                index += 1
                var recursive = false
                var force = false
                var endOfOptions = false
                while index < invocation.count {
                    let argument = invocation[index]
                    index += 1
                    let value = argument.text.lowercased()
                    if endOfOptions == false, value == "--" {
                        endOfOptions = true
                        continue
                    }
                    if endOfOptions == false, value.hasPrefix("--") {
                        recursive = recursive || value == "--recursive"
                        force = force || value == "--force"
                        continue
                    }
                    if endOfOptions == false, value.hasPrefix("-"), value != "-" {
                        let flags = value.dropFirst()
                        recursive = recursive || flags.contains("r")
                        force = force || flags.contains("f")
                        continue
                    }
                    let rootTarget = value == "/" || value == "/*"
                    return recursive && force && rootTarget
                }
                return false
            }
            return false
        }

        func flush() -> Bool {
            defer { segment.removeAll(keepingCapacity: true) }
            return isCatastrophic(segment)
        }

        for token in tokens {
            if token.quoted == false, separators.contains(token.text) {
                if flush() { return "已阻止灾难性命令：会递归强制删除根文件系统（rm -rf /*）。" }
            } else {
                segment.append(token)
            }
        }
        if flush() { return "已阻止灾难性命令：会递归强制删除根文件系统（rm -rf /*）。" }
        return nil
    }

    private static func isAssignment(_ value: String) -> Bool {
        guard let equals = value.firstIndex(of: "="), equals > value.startIndex else { return false }
        let name = value[..<equals]
        return name.allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }

    private struct Token {
        let text: String
        let quoted: Bool
    }

    private enum Lexer {
        static func tokenize(_ command: String) -> [Token] {
            var result: [Token] = []
            var current = ""
            var quoted = false
            var quote: Character?
            var escaped = false

            func flush() {
                guard current.isEmpty == false else { return }
                result.append(Token(text: current, quoted: quoted))
                current.removeAll(keepingCapacity: true)
                quoted = false
            }

            var index = command.startIndex
            while index < command.endIndex {
                let character = command[index]
                if escaped {
                    current.append(character)
                    escaped = false
                } else if character == "\\", quote != "'" {
                    escaped = true
                    quoted = true
                } else if let activeQuote = quote {
                    if character == activeQuote {
                        quote = nil
                    } else {
                        current.append(character)
                        quoted = true
                    }
                } else if character == "'" || character == "\"" {
                    quote = character
                    quoted = true
                } else if character.isWhitespace {
                    flush()
                } else if [";", "|", "&", "{", "}"].contains(character) {
                    flush()
                    if (character == "|" || character == "&"),
                       command.index(after: index) < command.endIndex,
                       command[command.index(after: index)] == character {
                        result.append(Token(text: String(character) + String(character), quoted: false))
                        index = command.index(after: index)
                    } else {
                        result.append(Token(text: String(character), quoted: false))
                    }
                } else {
                    current.append(character)
                }
                index = command.index(after: index)
            }
            if escaped { current.append("\\") }
            flush()
            return result
        }
    }
}
