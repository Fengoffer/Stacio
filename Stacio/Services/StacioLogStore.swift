import Foundation
import OSLog

public enum StacioLogLevel: String, Sendable {
    case debug
    case info
    case warning
    case error
}

public protocol StacioLogWriting: AnyObject {
    func append(
        level: StacioLogLevel,
        category: String,
        message: String,
        sensitiveValues: [String]
    )
}

public extension StacioLogWriting {
    func append(level: StacioLogLevel, category: String, message: String) {
        append(level: level, category: category, message: message, sensitiveValues: [])
    }
}

public protocol StacioLogReading: AnyObject {
    func recentLines(limit: Int) throws -> [String]
}

public final class StacioLogStore: StacioLogWriting, StacioLogReading {
    public static let shared = StacioLogStore(logFileURL: defaultLogFileURL())

    public let logFileURL: URL

    private let fileManager: FileManager
    private let lock = NSLock()
    private let unifiedLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.stacio.Stacio",
        category: "AppLog"
    )

    public init(logFileURL: URL, fileManager: FileManager = .default) {
        self.logFileURL = logFileURL
        self.fileManager = fileManager
    }

    public func append(
        level: StacioLogLevel,
        category: String,
        message: String,
        sensitiveValues: [String] = []
    ) {
        let redactedMessage = Self.redacted(message, sensitiveValues: sensitiveValues)
        let line = "\(Self.timestamp()) [\(level.rawValue.uppercased())] [\(category)] \(redactedMessage)"
        writeUnifiedLog(level: level, line: line)

        lock.lock()
        defer { lock.unlock() }
        do {
            try fileManager.createDirectory(
                at: logFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = Data((line + "\n").utf8)
            if fileManager.fileExists(atPath: logFileURL.path) {
                let handle = try FileHandle(forWritingTo: logFileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: logFileURL, options: [.atomic])
            }
        } catch {
            unifiedLogger.error("Stacio log file write failed: \(String(describing: error), privacy: .public)")
        }
    }

    public func recentLines(limit: Int) throws -> [String] {
        guard limit > 0 else { return [] }
        lock.lock()
        defer { lock.unlock() }
        guard fileManager.fileExists(atPath: logFileURL.path) else {
            return []
        }
        let text = try String(contentsOf: logFileURL, encoding: .utf8)
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        return Array(lines.suffix(limit))
    }

    public static func redactedArguments(_ arguments: [String]) -> [String] {
        var redacted: [String] = []
        var shouldRedactNext = false
        for argument in arguments {
            if shouldRedactNext {
                redacted.append(L10n.Diagnostics.redactedCredential)
                shouldRedactNext = false
                continue
            }
            let lowercased = argument.lowercased()
            if lowercased == "--password"
                || lowercased == "-p"
                || lowercased == "--gw-pass"
                || lowercased.contains("token")
                || lowercased.contains("credential")
                || lowercased.contains("secret")
            {
                redacted.append(argument)
                shouldRedactNext = true
                continue
            }
            redacted.append(argument)
        }
        return redacted
    }

    public static func sensitiveArgumentValues(_ arguments: [String]) -> [String] {
        var values: [String] = []
        var shouldCaptureNext = false
        for argument in arguments {
            if shouldCaptureNext {
                values.append(argument)
                shouldCaptureNext = false
                continue
            }
            let lowercased = argument.lowercased()
            if lowercased == "--password"
                || lowercased == "-p"
                || lowercased == "--gw-pass"
                || lowercased.contains("token")
                || lowercased.contains("credential")
                || lowercased.contains("secret")
            {
                shouldCaptureNext = true
            }
        }
        return values
    }

    private static func defaultLogFileURL() -> URL {
        if isRunningUnderXCTest() {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("StacioTests", isDirectory: true)
                .appendingPathComponent("Logs", isDirectory: true)
                .appendingPathComponent("stacio.log")
        }
        if let paths = try? StacioPaths() {
            return paths.applicationSupportDirectory
                .appendingPathComponent("Logs", isDirectory: true)
                .appendingPathComponent("stacio.log")
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("Stacio", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("stacio.log")
    }

    private static func isRunningUnderXCTest() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["XCTestConfigurationFilePath"] != nil {
            return true
        }
        if NSClassFromString("XCTest.XCTestCase") != nil || NSClassFromString("XCTestCase") != nil {
            return true
        }
        let lowercasedProcessName = ProcessInfo.processInfo.processName.lowercased()
        if lowercasedProcessName.contains("xctest") || lowercasedProcessName.contains("packagetests") {
            return true
        }
        return CommandLine.arguments.contains { argument in
            let lowercasedArgument = argument.lowercased()
            return lowercasedArgument.contains(".xctest")
                || lowercasedArgument.contains("/xctest")
                || lowercasedArgument.contains("packagetests")
        }
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private static func redacted(_ message: String, sensitiveValues: [String]) -> String {
        var sanitized = message
        for value in sensitiveValues where !value.isEmpty {
            sanitized = sanitized.replacingOccurrences(of: value, with: L10n.Diagnostics.redactedCredential)
        }

        var tokens: [String] = []
        var shouldRedactNext = false
        for rawToken in sanitized.split(whereSeparator: \.isWhitespace) {
            let token = String(rawToken)
            let lowercased = token.lowercased()
            if shouldRedactNext {
                tokens.append(L10n.Diagnostics.redactedCredential)
                shouldRedactNext = false
                continue
            }
            if lowercased.contains("password")
                || lowercased.contains("secret")
                || lowercased.contains("credential")
                || lowercased.contains("token")
                || lowercased.contains("api_key")
                || lowercased.contains("gw-pass")
            {
                tokens.append(L10n.Diagnostics.redactedCredential)
                if lowercased == "password"
                    || lowercased == "secret"
                    || lowercased == "credential"
                    || lowercased == "token"
                    || lowercased == "api_key"
                    || lowercased == "--password"
                    || lowercased == "-p"
                    || lowercased == "--gw-pass"
                    || lowercased.hasSuffix(":")
                    || lowercased.hasSuffix("=")
                {
                    shouldRedactNext = true
                }
                continue
            }
            tokens.append(token)
        }
        return tokens.joined(separator: " ")
    }

    private func writeUnifiedLog(level: StacioLogLevel, line: String) {
        switch level {
        case .debug:
            unifiedLogger.debug("\(line, privacy: .public)")
        case .info:
            unifiedLogger.info("\(line, privacy: .public)")
        case .warning:
            unifiedLogger.warning("\(line, privacy: .public)")
        case .error:
            unifiedLogger.error("\(line, privacy: .public)")
        }
    }
}
