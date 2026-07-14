import AppKit
import Darwin
import Foundation
import StacioCoreBindings

public struct SessionSidebarPingResult: Equatable {
    public let host: String
    public let reachable: Bool
    public let output: String

    public init(host: String, reachable: Bool, output: String) {
        self.host = host
        self.reachable = reachable
        self.output = output
    }
}

public protocol SessionSidebarPingRunning: AnyObject {
    func cancel()
}

public protocol SessionSidebarHostPinging {
    @discardableResult
    func ping(
        host: String,
        onOutput: @escaping @MainActor @Sendable (String) -> Void,
        completion: @escaping @MainActor @Sendable (Result<SessionSidebarPingResult, Error>) -> Void
    ) throws -> SessionSidebarPingRunning
}

public protocol SessionSidebarShortcutCreating {
    func createShortcut(for session: SessionRecord, destinationURL: URL) throws
}

public protocol SessionSidebarDefaultPresetStoring {
    func saveDefaultPreset(session: SessionRecord, configJSON: String?) throws
}

public protocol SessionSidebarSettingsCopying {
    func copySettings(_ text: String) throws
}

public enum SessionSidebarContextMenuAction {
    case execute
    case connectAs
    case pingHost
    case rename
    case edit
    case delete
    case duplicate
    case move
    case saveToFile
    case createDesktopShortcut
    case saveAsDefaultPreset
    case copySettings
}

public enum SessionSidebarFolderContextMenuAction {
    case createChild
    case rename
    case delete
    case export
}

public enum SessionSidebarSingleSessionExport {
    public static func jsonString(for session: SessionRecord, configJSON: String?) throws -> String {
        var sessionObject: [String: Any] = [
            "id": session.id,
            "name": session.name,
            "protocol": session.protocol,
            "host": session.host,
            "port": session.port,
            "tags": session.tags
        ]
        sessionObject["folder_id"] = session.folderId as Any?
        sessionObject["username"] = session.username as Any?
        sessionObject["private_key_path"] = session.privateKeyPath as Any?
        sessionObject["credential_id"] = session.credentialId as Any?
        sessionObject["last_opened_at"] = session.lastOpenedAt as Any?
        if let configJSON,
           let data = configJSON.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) {
            sessionObject["config_json"] = object
        } else if let configJSON {
            sessionObject["config_json"] = configJSON
        }

        let bundle: [String: Any] = [
            "format": "stacio.sessions.v1",
            "exported_at": ISO8601DateFormatter().string(from: Date()),
            "folders": [],
            "sessions": [sessionObject]
        ]
        let data = try JSONSerialization.data(
            withJSONObject: bundle,
            options: [.prettyPrinted, .sortedKeys]
        )
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

public final class SystemSessionSidebarPingRun: SessionSidebarPingRunning {
    private let process: Process
    private let processID: pid_t
    private let outputReaderQueue: DispatchQueue
    private let lock = NSLock()
    private var completed = false
    private var fallbackWorkItems: [DispatchWorkItem] = []

    fileprivate init(process: Process, outputReaderQueue: DispatchQueue) {
        self.process = process
        self.processID = process.processIdentifier
        self.outputReaderQueue = outputReaderQueue
    }

    public func cancel() {
        lock.lock()
        let shouldCancel = !completed
        lock.unlock()
        guard shouldCancel else {
            return
        }
        Darwin.kill(processID, SIGINT)
        scheduleFallbackSignal(SIGTERM, after: 0.4)
        scheduleFallbackSignal(SIGKILL, after: 0.8)
    }

    fileprivate func markCompleted() {
        lock.lock()
        completed = true
        let workItems = fallbackWorkItems
        fallbackWorkItems.removeAll()
        lock.unlock()
        workItems.forEach { $0.cancel() }
    }

    private func scheduleFallbackSignal(_ signal: Int32, after delay: TimeInterval) {
        let processID = processID
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            self.lock.lock()
            let shouldSignal = !self.completed
            self.lock.unlock()
            guard shouldSignal else {
                return
            }
            Darwin.kill(processID, signal)
        }
        lock.lock()
        if completed {
            lock.unlock()
            return
        }
        fallbackWorkItems.append(workItem)
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: workItem)
    }
}

private final class SessionSidebarPingOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ newData: Data) {
        guard !newData.isEmpty else {
            return
        }
        lock.lock()
        data.append(newData)
        lock.unlock()
    }

    func stringValue() -> String {
        lock.lock()
        let snapshot = data
        lock.unlock()
        return String(data: snapshot, encoding: .utf8) ?? ""
    }
}

public struct SystemSessionSidebarHostPinger: SessionSidebarHostPinging {
    private let executableURL: URL
    private let arguments: @Sendable (String) -> [String]

    public init() {
        self.init(
            executableURL: URL(fileURLWithPath: "/sbin/ping"),
            arguments: { host in Self.defaultArguments(for: host) }
        )
    }

    init(
        executableURL: URL,
        arguments: @escaping @Sendable (String) -> [String]
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
    }

    @discardableResult
    public func ping(
        host: String,
        onOutput: @escaping @MainActor @Sendable (String) -> Void,
        completion: @escaping @MainActor @Sendable (Result<SessionSidebarPingResult, Error>) -> Void
    ) throws -> SessionSidebarPingRunning {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments(trimmedHost)

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        let outputBuffer = SessionSidebarPingOutputBuffer()
        let readerQueue = DispatchQueue(
            label: "Stacio.SessionSidebar.pingOutput.\(UUID().uuidString)",
            qos: .utility
        )

        func handleOutputData(_ data: Data) {
            guard !data.isEmpty else {
                return
            }
            outputBuffer.append(data)
            let text = String(data: data, encoding: .utf8) ?? ""
            Task { @MainActor in
                onOutput(text)
            }
        }

        try process.run()
        let run = SystemSessionSidebarPingRun(process: process, outputReaderQueue: readerQueue)
        readerQueue.async {
            while true {
                let data = outputPipe.fileHandleForReading.availableData
                if data.isEmpty {
                    break
                }
                handleOutputData(data)
            }
            process.waitUntilExit()
            run.markCompleted()
            let output = outputBuffer.stringValue()
            let result = SessionSidebarPingResult(
                host: trimmedHost,
                reachable: process.terminationStatus == 0 || Self.outputContainsReply(output),
                output: output
            )
            Task { @MainActor in
                completion(.success(result))
            }
        }
        return run
    }

    private static func defaultArguments(for host: String) -> [String] {
        ["-n", "-W", "1000", host]
    }

    private static func outputContainsReply(_ output: String) -> Bool {
        output
            .localizedCaseInsensitiveContains("bytes from")
    }
}

public struct WeblocSessionSidebarShortcutCreator: SessionSidebarShortcutCreating {
    public init() {}

    public func createShortcut(for session: SessionRecord, destinationURL: URL) throws {
        let url = try portDeskOpenURL(for: session.id)
        let plist: [String: String] = ["URL": url.absoluteString]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: destinationURL, options: .atomic)
    }

    private func portDeskOpenURL(for sessionID: String) throws -> URL {
        var components = URLComponents()
        components.scheme = "stacio"
        components.host = "open-session"
        components.path = "/" + sessionID
        guard let url = components.url else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        return url
    }
}

public final class UserDefaultsSessionSidebarDefaultPresetStore: SessionSidebarDefaultPresetStoring {
    public static let defaultPresetDidChangeNotification = Notification.Name(
        "Stacio.SessionSidebar.defaultPresetDidChange"
    )

    private enum Key {
        static let defaultPreset = "Stacio.SessionSidebar.defaultPreset"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func saveDefaultPreset(session: SessionRecord, configJSON: String?) throws {
        let json = try SessionSidebarSingleSessionExport.jsonString(for: session, configJSON: configJSON)
        defaults.set(json, forKey: Key.defaultPreset)
        NotificationCenter.default.post(name: Self.defaultPresetDidChangeNotification, object: self)
    }

    public func defaultPresetJSON() -> String? {
        defaults.string(forKey: Key.defaultPreset)
    }
}

public struct PasteboardSessionSidebarSettingsCopier: SessionSidebarSettingsCopying {
    public init() {}

    public func copySettings(_ text: String) throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
