import Foundation

enum TerminalCurrentDirectoryNormalizer {
    static func normalize(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if trimmed.lowercased().hasPrefix("file://") {
            return cleanPath(pathFromFileURL(trimmed))
        }

        return trimmed
    }

    private static func pathFromFileURL(_ value: String) -> String {
        var remainder = String(value.dropFirst("file://".count))
        if remainder.hasPrefix("/") {
            return percentDecoded(remainder)
        }

        guard let slashIndex = remainder.firstIndex(of: "/") else {
            return ""
        }
        remainder = String(remainder[slashIndex...])
        return percentDecoded(remainder)
    }

    private static func cleanPath(_ value: String) -> String? {
        var path = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.hasPrefix("/localhost/") {
            path.removeFirst("/localhost".count)
        }
        return path.isEmpty ? nil : path
    }

    private static func percentDecoded(_ value: String) -> String {
        value.removingPercentEncoding ?? value
    }
}
