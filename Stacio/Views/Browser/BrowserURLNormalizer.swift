import Foundation

enum BrowserURLNormalizer {
    private static let ipv4TransportHostPrefix = "stacio-ipv4-"
    private static let ipv6TransportHostPrefix = "stacio-ipv6-"
    private static let transportHostSuffix = "-x.invalid"
    private static let localhostTransportHost = "stacio-host-localhost-x.invalid"

    static func normalizedURL(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if trimmed.hasPrefix("//") {
            return normalizedURL(String(trimmed.dropFirst(2)))
        }

        if trimmed.contains("://") {
            guard let url = URL(string: trimmed), isAllowedBrowserURL(url) else {
                return nil
            }
            return url
        }

        if let url = URL(string: trimmed), url.scheme != nil {
            if isAllowedBrowserURL(url) {
                return url
            }
            guard looksLikeHostPortAddress(trimmed) else {
                return nil
            }
        }

        let scheme = defaultScheme(for: trimmed)
        guard let url = URL(string: "\(scheme)://\(trimmed)") else {
            return nil
        }
        return isAllowedBrowserURL(url) ? url : nil
    }

    static func transportURL(for url: URL) -> URL {
        guard let host = url.host,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            return url
        }

        if let encodedIPv4Host = encodedIPv4TransportHost(host) {
            components.host = encodedIPv4Host
            return components.url ?? url
        }

        if let encodedIPv6Host = encodedIPv6TransportHost(host) {
            components.host = encodedIPv6Host
            return components.url ?? url
        }

        if host.caseInsensitiveCompare("localhost") == .orderedSame {
            components.host = localhostTransportHost
            return components.url ?? url
        }

        if host.hasSuffix(".") {
            let withoutRootLabel = String(host.dropLast())
            if let encodedIPv4Host = encodedIPv4TransportHost(withoutRootLabel) {
                components.host = encodedIPv4Host
                return components.url ?? url
            }
            if withoutRootLabel.caseInsensitiveCompare("localhost") == .orderedSame {
                components.host = localhostTransportHost
                return components.url ?? url
            }
        }

        return url
    }

    static func displayURL(for transportURL: URL) -> URL {
        guard let host = transportURL.host,
              var components = URLComponents(url: transportURL, resolvingAgainstBaseURL: false)
        else {
            return transportURL
        }

        if let decodedIPv4Host = decodedIPv4TransportHost(host) {
            components.host = decodedIPv4Host
            return components.url ?? transportURL
        }

        if let decodedIPv6Host = decodedIPv6TransportHost(host) {
            components.percentEncodedHost = "[\(decodedIPv6Host)]"
            return components.url ?? transportURL
        }

        if host.caseInsensitiveCompare(localhostTransportHost) == .orderedSame {
            components.host = "localhost"
            return components.url ?? transportURL
        }

        guard host.hasSuffix(".") else {
            return transportURL
        }
        let withoutRootLabel = String(host.dropLast())
        guard isIPv4Host(withoutRootLabel)
                || withoutRootLabel.caseInsensitiveCompare("localhost") == .orderedSame
        else {
            return transportURL
        }
        components.host = withoutRootLabel
        return components.url ?? transportURL
    }

    private static func encodedIPv4TransportHost(_ host: String) -> String? {
        guard isIPv4Host(host) else {
            return nil
        }
        let payload = host.replacingOccurrences(of: ".", with: "-")
        return "\(ipv4TransportHostPrefix)\(payload)\(transportHostSuffix)"
    }

    private static func decodedIPv4TransportHost(_ host: String) -> String? {
        let normalized = host.lowercased()
        guard normalized.hasPrefix(ipv4TransportHostPrefix),
              normalized.hasSuffix(transportHostSuffix)
        else {
            return nil
        }
        let payloadStart = normalized.index(normalized.startIndex, offsetBy: ipv4TransportHostPrefix.count)
        let payloadEnd = normalized.index(normalized.endIndex, offsetBy: -transportHostSuffix.count)
        let payload = normalized[payloadStart..<payloadEnd]
        let octets = payload.split(separator: "-")
        guard octets.count == 4,
              octets.allSatisfy({ UInt8($0) != nil })
        else {
            return nil
        }
        return octets.map(String.init).joined(separator: ".")
    }

    private static func encodedIPv6TransportHost(_ host: String) -> String? {
        let normalized = host.lowercased()
        guard normalized.contains(":"),
              normalized.allSatisfy({ $0.isHexDigit || $0 == ":" || $0 == "." })
        else {
            return nil
        }
        let payload = normalized.replacingOccurrences(of: ":", with: "-")
        return "\(ipv6TransportHostPrefix)\(payload)\(transportHostSuffix)"
    }

    private static func decodedIPv6TransportHost(_ host: String) -> String? {
        let normalized = host.lowercased()
        guard normalized.hasPrefix(ipv6TransportHostPrefix),
              normalized.hasSuffix(transportHostSuffix)
        else {
            return nil
        }
        let payloadStart = normalized.index(normalized.startIndex, offsetBy: ipv6TransportHostPrefix.count)
        let payloadEnd = normalized.index(normalized.endIndex, offsetBy: -transportHostSuffix.count)
        let payload = normalized[payloadStart..<payloadEnd]
        guard !payload.isEmpty,
              payload.allSatisfy({ $0.isHexDigit || $0 == "-" || $0 == "." })
        else {
            return nil
        }
        let decoded = payload.replacingOccurrences(of: "-", with: ":")
        return decoded.contains(":") ? decoded : nil
    }

    private static func isAllowedBrowserURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              host.isEmpty == false,
              url.user == nil,
              url.password == nil,
              hasValidExplicitPort(url)
        else {
            return false
        }
        return true
    }

    private static func hasValidExplicitPort(_ url: URL) -> Bool {
        guard let portString = explicitPortString(from: url) else {
            return true
        }
        guard let port = UInt16(portString), port > 0 else {
            return false
        }
        return String(port) == portString
    }

    private static func explicitPortString(from url: URL) -> String? {
        guard let scheme = url.scheme,
              let schemeRange = url.absoluteString.range(
                  of: "\(scheme)://",
                  options: [.caseInsensitive, .anchored]
              )
        else {
            return nil
        }

        let remainder = url.absoluteString[schemeRange.upperBound...]
        let authority = remainder.split(
            maxSplits: 1,
            whereSeparator: { "/?#".contains($0) }
        ).first ?? ""
        guard authority.isEmpty == false else {
            return nil
        }

        if authority.hasPrefix("[") {
            guard let closingBracket = authority.firstIndex(of: "]") else {
                return nil
            }
            let afterBracket = authority[authority.index(after: closingBracket)...]
            return afterBracket.first == ":" ? String(afterBracket.dropFirst()) : nil
        }

        guard let colonIndex = authority.lastIndex(of: ":") else {
            return nil
        }
        return String(authority[authority.index(after: colonIndex)...])
    }

    private static func defaultScheme(for value: String) -> String {
        if let authority = authorityPrefix(from: value),
           defaultToHTTP(for: hostPart(from: authority), value: value)
        {
            return "http"
        }
        return "https"
    }

    private static func defaultToHTTP(for host: String, value: String) -> Bool {
        if isLoopbackHost(host) {
            return true
        }
        if isPrivateIPv4Host(host) {
            return true
        }
        return isPrivateIPv6Host(host)
    }

    private static func looksLikeHostPortAddress(_ value: String) -> Bool {
        guard let authority = authorityPrefix(from: value),
              let colonIndex = authority.lastIndex(of: ":")
        else {
            return false
        }

        let host = String(authority[..<colonIndex])
        let port = authority[authority.index(after: colonIndex)...]
        guard !host.isEmpty,
              !port.isEmpty,
              port.allSatisfy(\.isNumber)
        else {
            return false
        }

        if host.hasPrefix("[") && host.hasSuffix("]") {
            return true
        }
        return host.range(of: #"^[A-Za-z0-9.-]+$"#, options: .regularExpression) != nil
    }

    private static func authorityPrefix(from value: String) -> Substring? {
        let authority = value.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first
        return authority?.isEmpty == false ? authority : nil
    }

    private static func hostPart(from authority: Substring) -> String {
        if authority.hasPrefix("["),
           let closingBracket = authority.firstIndex(of: "]") {
            return String(authority[...closingBracket])
        }
        guard let colonIndex = authority.lastIndex(of: ":") else {
            return String(authority)
        }
        return String(authority[..<colonIndex])
    }

    static func isLoopbackHost(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        return normalized == "localhost" || normalized == "::1" || normalized.hasPrefix("127.")
    }

    private static func isIPv4Host(_ host: String) -> Bool {
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else {
            return false
        }
        return octets.allSatisfy { octet in
            guard !octet.isEmpty,
                  octet.allSatisfy(\.isNumber),
                  let value = UInt8(octet)
            else {
                return false
            }
            return String(value) == octet || octet == "0"
        }
    }

    private static func isPrivateIPv4Host(_ host: String) -> Bool {
        let octets = host.split(separator: ".")
        guard octets.count == 4 else {
            return false
        }

        let values = octets.compactMap { UInt8($0) }
        guard values.count == 4 else {
            return false
        }

        switch values[0] {
        case 10:
            return true
        case 172:
            return (16...31).contains(values[1])
        case 192:
            return values[1] == 168
        case 169:
            return values[1] == 254
        default:
            return false
        }
    }

    private static func isPrivateIPv6Host(_ host: String) -> Bool {
        let normalized = host
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
            .first?
            .lowercased() ?? ""
        guard normalized.contains(":"),
              let firstHextet = normalized.split(separator: ":", maxSplits: 1).first,
              let value = UInt16(firstHextet, radix: 16)
        else {
            return false
        }

        return (value & 0xfe00) == 0xfc00 || (value & 0xffc0) == 0xfe80
    }
}
