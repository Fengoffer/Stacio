import Darwin
import Foundation

public enum AIEndpointSecurityPolicy {
    public static func validate(_ url: URL) throws {
        guard let host = url.host, host.isEmpty == false else {
            throw AIAssistantProviderError.insecureBaseURL
        }
        switch url.scheme?.lowercased() {
        case "https":
            return
        case "http" where isLoopbackHost(host):
            return
        default:
            throw AIAssistantProviderError.insecureBaseURL
        }
    }

    static func isLoopbackHost(_ host: String?) -> Bool {
        guard let host else {
            return false
        }
        let canonicalHost = host
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        guard canonicalHost.isEmpty == false else {
            return false
        }

        if canonicalHost == "localhost"
            || (canonicalHost.count > ".localhost".count && canonicalHost.hasSuffix(".localhost"))
        {
            return true
        }
        if isIPv4Loopback(canonicalHost) {
            return true
        }
        return isIPv6Loopback(canonicalHost)
    }

    private static func isIPv4Loopback(_ host: String) -> Bool {
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else {
            return false
        }
        let values = octets.compactMap { octet -> Int? in
            guard octet.isEmpty == false,
                  octet.utf8.allSatisfy({ (48...57).contains($0) }),
                  let value = Int(octet),
                  (0...255).contains(value)
            else {
                return nil
            }
            return value
        }
        return values.count == 4 && values[0] == 127
    }

    private static func isIPv6Loopback(_ host: String) -> Bool {
        var address = in6_addr()
        let result = host.withCString { pointer in
            inet_pton(AF_INET6, pointer, &address)
        }
        guard result == 1 else {
            return false
        }
        return withUnsafeBytes(of: &address) { bytes in
            bytes.count == 16
                && bytes.dropLast().allSatisfy { $0 == 0 }
                && bytes.last == 1
        }
    }
}
