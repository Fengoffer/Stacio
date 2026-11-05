import Foundation

public enum TerminalLinkURLNormalizer {
    public static func browserURL(from rawValue: String) -> URL? {
        let value = trimmedLinkText(rawValue)
        guard value.isEmpty == false else {
            return nil
        }

        if let url = URL(string: value),
           let scheme = url.scheme?.lowercased(),
           scheme.isEmpty == false {
            switch scheme {
            case "http", "https":
                guard url.user == nil,
                      url.password == nil
                else {
                    return nil
                }
                return BrowserURLNormalizer.normalizedURL(value)
            default:
                if value.contains("://") {
                    return nil
                }
            }
        }

        guard isBareWebAddress(value) else {
            return nil
        }
        return BrowserURLNormalizer.normalizedURL(value)
    }

    public static func terminalPath(from rawValue: String) -> String? {
        let value = trimmedLinkText(rawValue)
        guard value.isEmpty == false,
              value.contains("\n") == false,
              value.contains("\r") == false,
              value.hasPrefix("/") || value.hasPrefix("./") || value.hasPrefix("../") || value.hasPrefix("~")
        else {
            return nil
        }
        return value
    }

    private static func trimmedLinkText(_ rawValue: String) -> String {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let leadingDelimiters = CharacterSet(charactersIn: "<([{\"'")
        value = value.trimmingCharacters(in: leadingDelimiters)

        var didTrim = true
        while didTrim, let last = value.last {
            didTrim = false
            if ".!,;:?".contains(last) {
                value.removeLast()
                didTrim = true
                continue
            }
            if shouldTrimUnbalancedClosingDelimiter(last, in: value) {
                value.removeLast()
                didTrim = true
            }
        }
        return value
    }

    private static func shouldTrimUnbalancedClosingDelimiter(_ character: Character, in value: String) -> Bool {
        let pair: (open: Character, close: Character)?
        switch character {
        case ")":
            pair = ("(", ")")
        case "]":
            pair = ("[", "]")
        case "}":
            pair = ("{", "}")
        case ">":
            pair = ("<", ">")
        case "\"", "'":
            return true
        default:
            pair = nil
        }
        guard let pair else {
            return false
        }
        let openCount = value.filter { $0 == pair.open }.count
        let closeCount = value.filter { $0 == pair.close }.count
        return closeCount > openCount
    }

    private static func isBareWebAddress(_ value: String) -> Bool {
        guard value.contains(" ") == false,
              value.contains("\t") == false,
              value.hasPrefix("/") == false,
              value.hasPrefix("./") == false,
              value.hasPrefix("../") == false
        else {
            return false
        }

        let hostPort = value.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
        guard hostPort.isEmpty == false else {
            return false
        }

        let host = bareHost(from: String(hostPort))
        guard host.isEmpty == false else {
            return false
        }

        if host.lowercased() == "localhost" {
            return true
        }
        if isIPv4Address(host) {
            return true
        }
        return isDomainName(host)
    }

    private static func bareHost(from hostPort: String) -> String {
        if hostPort.hasPrefix("["),
           let closingBracket = hostPort.firstIndex(of: "]") {
            return String(hostPort[hostPort.index(after: hostPort.startIndex)..<closingBracket])
        }

        let parts = hostPort.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2 {
            guard let port = Int(parts[1]), (1...65_535).contains(port) else {
                return ""
            }
        }
        return String(parts[0])
    }

    private static func isIPv4Address(_ host: String) -> Bool {
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else {
            return false
        }
        return octets.allSatisfy { octet in
            guard octet.isEmpty == false,
                  octet.allSatisfy(\.isNumber),
                  let value = Int(octet)
            else {
                return false
            }
            return (0...255).contains(value)
        }
    }

    private static func isDomainName(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else {
            return false
        }
        return labels.allSatisfy(isValidDomainLabel(_:))
            && labels.last?.contains(where: \.isLetter) == true
    }

    private static func isValidDomainLabel(_ label: Substring) -> Bool {
        guard label.isEmpty == false,
              label.count <= 63,
              label.first != "-",
              label.last != "-"
        else {
            return false
        }
        return label.allSatisfy { character in
            character.isLetter || character.isNumber || character == "-"
        }
    }
}
