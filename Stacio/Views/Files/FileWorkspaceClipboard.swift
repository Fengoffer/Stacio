import AppKit

public enum FileWorkspaceClipboardOperation: Equatable, Sendable {
    case copy
    case cut
}

public struct FileWorkspaceClipboardPayload: Equatable, Sendable {
    public let operation: FileWorkspaceClipboardOperation
    public let sourceDeviceID: String
    public let localURLs: [URL]
    public let remoteSelections: [RemoteFileSelection]

    public init(
        operation: FileWorkspaceClipboardOperation,
        sourceDeviceID: String,
        localURLs: [URL] = [],
        remoteSelections: [RemoteFileSelection] = []
    ) {
        self.operation = operation
        self.sourceDeviceID = sourceDeviceID
        self.localURLs = localURLs
        self.remoteSelections = remoteSelections
    }
}

public enum FileWorkspaceTransferTargetKind: Equatable, Sendable {
    case local(directoryURL: URL)
    case remote(directoryPath: String)

    public var isLocal: Bool {
        if case .local = self { return true }
        return false
    }
}

public struct FileWorkspaceTransferTarget: Equatable, Sendable {
    public let deviceID: String
    public let title: String
    public let kind: FileWorkspaceTransferTargetKind

    public init(deviceID: String, title: String, kind: FileWorkspaceTransferTargetKind) {
        self.deviceID = deviceID
        self.title = title
        self.kind = kind
    }
}

@MainActor
public final class FileWorkspaceClipboard {
    public static let shared = FileWorkspaceClipboard()

    private static let workspaceType = NSPasteboard.PasteboardType("com.stacio.file-workspace-items")
    private let pasteboard: NSPasteboard
    private var storedPayload: FileWorkspaceClipboardPayload?
    private var ownedChangeCount: Int?

    public var payload: FileWorkspaceClipboardPayload? {
        ownedPayloadIfCurrent()
    }

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    public func storeLocalURLs(
        _ urls: [URL],
        operation: FileWorkspaceClipboardOperation,
        sourceDeviceID: String
    ) {
        let normalizedURLs = urls.map(\.standardizedFileURL)
        guard normalizedURLs.isEmpty == false else {
            clear()
            return
        }
        storedPayload = FileWorkspaceClipboardPayload(
            operation: operation,
            sourceDeviceID: sourceDeviceID,
            localURLs: normalizedURLs
        )
        pasteboard.clearContents()
        pasteboard.writeObjects(normalizedURLs as [NSURL])
        pasteboard.setString(sourceDeviceID, forType: Self.workspaceType)
        ownedChangeCount = pasteboard.changeCount
    }

    public func storeRemoteSelections(
        _ selections: [RemoteFileSelection],
        operation: FileWorkspaceClipboardOperation,
        sourceDeviceID: String
    ) {
        guard selections.isEmpty == false else {
            clear()
            return
        }
        storedPayload = FileWorkspaceClipboardPayload(
            operation: operation,
            sourceDeviceID: sourceDeviceID,
            remoteSelections: selections
        )
        pasteboard.clearContents()
        pasteboard.setString(sourceDeviceID, forType: Self.workspaceType)
        pasteboard.setString(selections.map(\.path).joined(separator: "\n"), forType: .string)
        ownedChangeCount = pasteboard.changeCount
    }

    public func resolvedPayload() -> FileWorkspaceClipboardPayload? {
        if let payload = ownedPayloadIfCurrent() {
            return payload
        }
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        )?.compactMap { ($0 as? URL)?.standardizedFileURL } ?? []
        guard urls.isEmpty == false else { return nil }
        return FileWorkspaceClipboardPayload(
            operation: .copy,
            sourceDeviceID: "external-local",
            localURLs: urls
        )
    }

    public func clear() {
        let stillOwnsPasteboard = ownedChangeCount == pasteboard.changeCount
        storedPayload = nil
        ownedChangeCount = nil
        if stillOwnsPasteboard {
            pasteboard.clearContents()
        }
    }

    private func ownedPayloadIfCurrent() -> FileWorkspaceClipboardPayload? {
        guard let ownedChangeCount else { return nil }
        guard ownedChangeCount == pasteboard.changeCount else {
            storedPayload = nil
            self.ownedChangeCount = nil
            return nil
        }
        return storedPayload
    }
}
