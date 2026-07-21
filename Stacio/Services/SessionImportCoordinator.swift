import AppKit
import CoreFoundation
import Foundation
import StacioCoreBindings
import UniformTypeIdentifiers

public enum SessionImportSourceType: String, Sendable {
    case csv
    case legacyINI = "legacy_ini"
    case stacioJSON = "stacio_json"
    case xShell = "xshell"
    case mobaXterm = "mobaxterm"
    case windTerm = "windterm"
    case secureCRT = "securecrt"
    case finalShell = "finalshell"
    case termius
    case electerm
    case genericJSON = "json"
    case unknown
}

public struct SessionImportFile: Sendable {
    public let sourceName: String
    public let sourceType: SessionImportSourceType
    public let contents: String
    public let sourceURL: URL?

    public init(sourceName: String, sourceType: SessionImportSourceType, contents: String, sourceURL: URL? = nil) {
        self.sourceName = sourceName
        self.sourceType = sourceType
        self.contents = contents
        self.sourceURL = sourceURL
    }
}

public protocol SessionImportFilePicking {
    func pickImportFile(parentWindow: NSWindow?) throws -> SessionImportFile?
    func pickImportFile(
        sourceType: SessionImportSourceType,
        parentWindow: NSWindow?
    ) throws -> SessionImportFile?
}

public extension SessionImportFilePicking {
    func pickImportFile(
        sourceType: SessionImportSourceType,
        parentWindow: NSWindow?
    ) throws -> SessionImportFile? {
        try pickImportFile(parentWindow: parentWindow)
    }
}

public struct SessionImportSourceDescriptor: Sendable {
    public let type: SessionImportSourceType
    public let name: String
    public let hint: String
    public let symbolName: String
    public let iconResourceName: String?
}

public enum AppKitSessionImportSourcePicker {
    public static let supportedSources: [SessionImportSourceDescriptor] = [
        .init(type: .stacioJSON, name: "Stacio", hint: ".json / .stacio-session", symbolName: "terminal", iconResourceName: nil),
        .init(type: .xShell, name: "Xshell", hint: ".xsh / .xts", symbolName: "chevron.left.forwardslash.chevron.right", iconResourceName: "xshell.svg"),
        .init(type: .mobaXterm, name: "MobaXterm", hint: ".mxtsessions", symbolName: "rectangle.connected.to.line.below", iconResourceName: "mobaxterm.svg"),
        .init(type: .windTerm, name: "WindTerm", hint: ".sessions", symbolName: "wind", iconResourceName: "windterm.svg"),
        .init(type: .secureCRT, name: "SecureCRT", hint: ".xml", symbolName: "lock.shield", iconResourceName: "securecrt.svg"),
        .init(type: .finalShell, name: "FinalShell", hint: "conn 目录", symbolName: "folder", iconResourceName: "finalshell.svg"),
        .init(type: .termius, name: "Termius", hint: ".json", symbolName: "cloud", iconResourceName: "termius.svg"),
        .init(type: .electerm, name: "Electerm", hint: ".json", symbolName: "bolt.horizontal", iconResourceName: "electerm.svg"),
        .init(type: .genericJSON, name: "JSON", hint: ".json", symbolName: "curlybraces", iconResourceName: nil)
    ]
}

enum SessionImportSourceIconCatalog {
    static func image(for source: SessionImportSourceDescriptor, size: NSSize = NSSize(width: 18, height: 18)) -> NSImage? {
        if source.type == .stacioJSON,
           let image = NSApplication.shared.applicationIconImage.copy() as? NSImage {
            image.size = size
            image.isTemplate = false
            image.accessibilityDescription = source.name
            return image
        }
        if let resourceName = source.iconResourceName {
            let parts = resourceName.split(separator: ".", maxSplits: 1).map(String.init)
            if let image = loadImage(
                basename: parts[0],
                fileExtension: parts.count > 1 ? parts[1] : nil,
                bundle: .main
            ) ?? debugResourceImage(
                basename: parts[0],
                fileExtension: parts.count > 1 ? parts[1] : nil
            ) {
                image.size = size
                image.isTemplate = false
                image.accessibilityDescription = source.name
                return image
            }
        }
        let image = NSImage(systemSymbolName: source.symbolName, accessibilityDescription: source.name)
        image?.size = size
        return image
    }

    private static func loadImage(basename: String, fileExtension: String?, bundle: Bundle) -> NSImage? {
        guard let url = bundle.url(
            forResource: basename,
            withExtension: fileExtension,
            subdirectory: "ImportSourceIcons"
        ) ?? bundle.url(forResource: basename, withExtension: fileExtension) else { return nil }
        return NSImage(contentsOf: url)
    }

    private static func debugResourceImage(basename: String, fileExtension: String?) -> NSImage? {
        #if DEBUG
        return loadImage(basename: basename, fileExtension: fileExtension, bundle: .module)
        #else
        return nil
        #endif
    }
}

public protocol SessionImportPreviewPresenting {
    func confirmImport(
        preview: ImportPreview,
        sourceName: String,
        sourceType: SessionImportSourceType,
        parentWindow: NSWindow?
    ) -> Bool
    func showImportResult(_ result: ImportApplyResult, parentWindow: NSWindow?)
    func showImportError(_ error: Error, parentWindow: NSWindow?)
}

public protocol SessionImportCoreBridging {
    func listAllSessionRecords(databasePath: String) throws -> [SessionRecord]
    func previewCSVImport(
        _ input: String,
        sourceName: String,
        existingSessionNames: [String]
    ) throws -> ImportPreview
    func previewLegacyIniImport(
        _ input: String,
        sourceName: String,
        existingSessionNames: [String]
    ) throws -> ImportPreview
    func previewStacioJSONImport(
        _ input: String,
        sourceName: String,
        existingSessionNames: [String]
    ) throws -> ImportPreview
    func applySessionImport(
        databasePath: String,
        sourceType: SessionImportSourceType,
        sourceName: String,
        preview: ImportPreview
    ) throws -> ImportApplyResult
}

public protocol SessionImportCoordinating {
    func runImport(parentWindow: NSWindow?) throws -> ImportApplyResult?
    func runImport(
        sourceType: SessionImportSourceType,
        parentWindow: NSWindow?
    ) throws -> ImportApplyResult?
}

public extension SessionImportCoordinating {
    func runImport(
        sourceType: SessionImportSourceType,
        parentWindow: NSWindow?
    ) throws -> ImportApplyResult? {
        try runImport(parentWindow: parentWindow)
    }
}

public protocol ExternalSessionCredentialApplying {
    func applyCredentials(
        from payload: ExternalSessionImportPayload,
        to importedSessions: [SessionRecord],
        databasePath: String
    ) throws
}

public final class KeychainExternalSessionCredentialApplier: ExternalSessionCredentialApplying {
    private let credentialSaverFactory: (String) -> SessionSidebarCredentialSaving

    public init(
        credentialSaverFactory: @escaping (String) -> SessionSidebarCredentialSaving = {
            KeychainSessionSidebarCredentialSaver(databasePath: $0)
        }
    ) {
        self.credentialSaverFactory = credentialSaverFactory
    }

    public func applyCredentials(
        from payload: ExternalSessionImportPayload,
        to importedSessions: [SessionRecord],
        databasePath: String
    ) throws {
        let importedByName = Dictionary(
            uniqueKeysWithValues: importedSessions.map { ($0.name.lowercased(), $0) }
        )
        let saver = credentialSaverFactory(databasePath)
        for source in payload.sessions {
            guard let credential = source.credential,
                  let imported = importedByName[source.name.lowercased()]
            else { continue }
            let kind: String
            let label: String
            let secret: String
            switch credential {
            case let .password(value):
                kind = "password"
                label = "\(source.name) password"
                secret = value
            case let .privateKeyPassphrase(value):
                kind = "private_key_passphrase"
                label = "\(source.name) private key passphrase"
                secret = value
            }
            let account = "\(source.username ?? "")@\(source.host)"
            let record = try saver.saveCredential(kind: kind, label: label, account: account, secret: secret)
            _ = try CoreBridge.updateSessionRecord(
                databasePath: databasePath,
                id: imported.id,
                update: SessionUpdate(
                    name: nil,
                    protocol: nil,
                    folderId: nil,
                    host: nil,
                    port: nil,
                    username: nil,
                    privateKeyPath: nil,
                    credentialId: record.id,
                    tags: nil,
                    configJson: nil
                )
            )
        }
    }
}

@MainActor
public protocol SessionImportErrorPresenting {
    func presentSessionImportError(_ error: Error, parentWindow: NSWindow?)
}

public final class CoreBridgeSessionImportCoreBridge: SessionImportCoreBridging {
    public init() {}

    public func listAllSessionRecords(databasePath: String) throws -> [SessionRecord] {
        try CoreBridge.listAllSessionRecords(databasePath: databasePath)
    }

    public func previewCSVImport(
        _ input: String,
        sourceName: String,
        existingSessionNames: [String]
    ) throws -> ImportPreview {
        try CoreBridge.previewCSVImport(input, existingSessionNames: existingSessionNames)
    }

    public func previewLegacyIniImport(
        _ input: String,
        sourceName: String,
        existingSessionNames: [String]
    ) throws -> ImportPreview {
        try CoreBridge.previewLegacyIniImport(input, existingSessionNames: existingSessionNames)
    }

    public func previewStacioJSONImport(
        _ input: String,
        sourceName: String,
        existingSessionNames: [String]
    ) throws -> ImportPreview {
        try CoreBridge.previewStacioJSONImport(input, existingSessionNames: existingSessionNames)
    }

    public func applySessionImport(
        databasePath: String,
        sourceType: SessionImportSourceType,
        sourceName: String,
        preview: ImportPreview
    ) throws -> ImportApplyResult {
        try CoreBridge.applySessionImport(
            databasePath: databasePath,
            sourceType: sourceType.rawValue,
            sourceName: sourceName,
            preview: preview
        )
    }
}

public final class SessionImportCoordinator: SessionImportCoordinating {
    private struct PreparedImport {
        let file: SessionImportFile
        let secureTransfer: SecureSessionTransferPayload?
    }

    private let databasePath: String
    private let filePicker: SessionImportFilePicking
    private let presenter: SessionImportPreviewPresenting
    private let core: SessionImportCoreBridging
    private let credentialApplier: ExternalSessionCredentialApplying
    private let secureSessionTransferPassphrasePrompter: SecureSessionTransferPassphrasePrompting
    private let importedPrivateKeyInstaller: SecureSessionTransferPrivateKeyInstalling
    private let onImported: () -> Void

    public init(
        databasePath: String,
        filePicker: SessionImportFilePicking = AppKitSessionImportFilePicker(),
        presenter: SessionImportPreviewPresenting = AppKitSessionImportPreviewPresenter(),
        core: SessionImportCoreBridging = CoreBridgeSessionImportCoreBridge(),
        credentialApplier: ExternalSessionCredentialApplying = KeychainExternalSessionCredentialApplier(),
        secureSessionTransferPassphrasePrompter: SecureSessionTransferPassphrasePrompting = AppKitSecureSessionTransferPassphrasePrompter(),
        importedPrivateKeyInstaller: SecureSessionTransferPrivateKeyInstalling = StacioImportedPrivateKeyInstaller(),
        onImported: @escaping () -> Void = {}
    ) {
        self.databasePath = databasePath
        self.filePicker = filePicker
        self.presenter = presenter
        self.core = core
        self.credentialApplier = credentialApplier
        self.secureSessionTransferPassphrasePrompter = secureSessionTransferPassphrasePrompter
        self.importedPrivateKeyInstaller = importedPrivateKeyInstaller
        self.onImported = onImported
    }

    public func runImport(parentWindow: NSWindow?) throws -> ImportApplyResult? {
        try runImport(sourceType: nil, parentWindow: parentWindow)
    }

    public func runImport(
        sourceType: SessionImportSourceType,
        parentWindow: NSWindow?
    ) throws -> ImportApplyResult? {
        try runImport(sourceType: Optional(sourceType), parentWindow: parentWindow)
    }

    private func runImport(
        sourceType requestedSourceType: SessionImportSourceType?,
        parentWindow: NSWindow?
    ) throws -> ImportApplyResult? {
        do {
            let file: SessionImportFile?
            if let requestedSourceType {
                file = try filePicker.pickImportFile(
                    sourceType: requestedSourceType,
                    parentWindow: parentWindow
                )
            } else {
                file = try filePicker.pickImportFile(parentWindow: parentWindow)
            }
            guard let file,
                  let preparedImport = try prepareImportFile(file, parentWindow: parentWindow)
            else {
                return nil
            }
            let importFile = preparedImport.file

            let existingSessionNames = try core
                .listAllSessionRecords(databasePath: databasePath)
                .map(\.name)
            let (sourceType, preview, externalPayload) = try makePreview(
                for: importFile,
                existingSessionNames: existingSessionNames
            )
            if let secureTransfer = preparedImport.secureTransfer,
               secureTransferMatchesPreview(secureTransfer, preview: preview) == false {
                throw SecureSessionTransferError.invalidPayload
            }
            guard presenter.confirmImport(
                preview: preview,
                sourceName: importFile.sourceName,
                sourceType: sourceType,
                parentWindow: parentWindow
            ) else {
                return nil
            }
            let result = try core.applySessionImport(
                databasePath: databasePath,
                sourceType: sourceType,
                sourceName: importFile.sourceName,
                preview: preview
            )
            if let secureTransfer = preparedImport.secureTransfer,
               result.importedSessions.isEmpty == false {
                try applySecureTransfer(
                    secureTransfer,
                    to: result.importedSessions
                )
            } else if let externalPayload, result.importedSessions.isEmpty == false {
                try credentialApplier.applyCredentials(
                    from: externalPayload,
                    to: result.importedSessions,
                    databasePath: databasePath
                )
            }
            if result.report.importedCount > 0 {
                onImported()
            }
            presenter.showImportResult(result, parentWindow: parentWindow)
            return result
        } catch {
            presenter.showImportError(error, parentWindow: parentWindow)
            throw error
        }
    }

    private func prepareImportFile(
        _ file: SessionImportFile,
        parentWindow: NSWindow?
    ) throws -> PreparedImport? {
        guard SecureSessionTransfer.isEncryptedTransfer(file.contents) else {
            return PreparedImport(file: file, secureTransfer: nil)
        }
        guard let passphrase = secureSessionTransferPassphrasePrompter.promptForImportPassphrase(
            sourceName: file.sourceName,
            parentWindow: parentWindow
        ) else {
            return nil
        }
        let secureTransfer = try SecureSessionTransfer.decrypt(file.contents, passphrase: passphrase)
        return PreparedImport(
            file: SessionImportFile(
                sourceName: file.sourceName,
                sourceType: .stacioJSON,
                contents: secureTransfer.sessionJSON,
                sourceURL: file.sourceURL
            ),
            secureTransfer: secureTransfer
        )
    }

    private func secureTransferMatchesPreview(
        _ transfer: SecureSessionTransferPayload,
        preview: ImportPreview
    ) -> Bool {
        guard preview.sessions.count == 1,
              let session = preview.sessions.first
        else {
            return false
        }
        return session.name == transfer.metadata.name
            && session.protocol.caseInsensitiveCompare(transfer.metadata.protocolName) == .orderedSame
            && session.host == transfer.metadata.host
            && session.port == transfer.metadata.port
            && session.username == transfer.metadata.username
    }

    private func applySecureTransfer(
        _ transfer: SecureSessionTransferPayload,
        to importedSessions: [SessionRecord]
    ) throws {
        guard importedSessions.count == 1,
              let importedSession = importedSessions.first,
              importedSession.name == transfer.metadata.name,
              importedSession.host == transfer.metadata.host
        else {
            throw SecureSessionTransferError.invalidPayload
        }
        if let privateKey = transfer.privateKey {
            try importedPrivateKeyInstaller.install(
                privateKey,
                for: importedSession,
                databasePath: databasePath
            )
        }
        if let credentialPayload = transfer.externalCredentialPayload() {
            try credentialApplier.applyCredentials(
                from: credentialPayload,
                to: importedSessions,
                databasePath: databasePath
            )
        }
    }

    private func makePreview(
        for file: SessionImportFile,
        existingSessionNames: [String]
    ) throws -> (SessionImportSourceType, ImportPreview, ExternalSessionImportPayload?) {
        switch file.sourceType {
        case .csv:
            return (
                .csv,
                try core.previewCSVImport(
                    file.contents,
                    sourceName: file.sourceName,
                    existingSessionNames: existingSessionNames
                ),
                nil
            )
        case .legacyINI:
            return (
                .legacyINI,
                try core.previewLegacyIniImport(
                    file.contents,
                    sourceName: file.sourceName,
                    existingSessionNames: existingSessionNames
                ),
                nil
            )
        case .stacioJSON:
            return (
                .stacioJSON,
                try core.previewStacioJSONImport(
                    file.contents,
                    sourceName: file.sourceName,
                    existingSessionNames: existingSessionNames
                ),
                nil
            )
        case .mobaXterm, .windTerm, .secureCRT, .termius, .electerm:
            let payload = try ExternalSessionImportParser.parseText(
                file.contents,
                sourceType: file.sourceType,
                sourceName: file.sourceName
            )
            return (file.sourceType, externalPreview(payload, existingSessionNames: existingSessionNames), payload)
        case .xShell:
            let payload: ExternalSessionImportPayload
            if let sourceURL = file.sourceURL, sourceURL.hasDirectoryPath {
                payload = try ExternalSessionImportParser.parseDirectory(
                    sourceURL,
                    sourceType: .xShell,
                    sourceName: file.sourceName
                )
            } else {
                payload = try ExternalSessionImportParser.parseText(
                    file.contents,
                    sourceType: .xShell,
                    sourceName: file.sourceName
                )
            }
            return (.xShell, externalPreview(payload, existingSessionNames: existingSessionNames), payload)
        case .finalShell:
            guard let sourceURL = file.sourceURL else { throw ExternalSessionImportParserError.invalidFormat }
            let payload = try ExternalSessionImportParser.parseDirectory(
                sourceURL,
                sourceType: .finalShell,
                sourceName: file.sourceName
            )
            return (.finalShell, externalPreview(payload, existingSessionNames: existingSessionNames), payload)
        case .genericJSON:
            if let preview = try? core.previewStacioJSONImport(
                file.contents,
                sourceName: file.sourceName,
                existingSessionNames: existingSessionNames
            ), !preview.sessions.isEmpty {
                return (.stacioJSON, preview, nil)
            }
            if let payload = try? ExternalSessionImportParser.parseText(
                file.contents,
                sourceType: .electerm,
                sourceName: file.sourceName
            ) {
                return (.electerm, externalPreview(payload, existingSessionNames: existingSessionNames), payload)
            }
            let payload = try ExternalSessionImportParser.parseText(
                file.contents,
                sourceType: .termius,
                sourceName: file.sourceName
            )
            return (.termius, externalPreview(payload, existingSessionNames: existingSessionNames), payload)
        case .unknown:
            if let preview = try? core.previewStacioJSONImport(
                file.contents,
                sourceName: file.sourceName,
                existingSessionNames: existingSessionNames
            ), !preview.sessions.isEmpty {
                return (.stacioJSON, preview, nil)
            }
            if let preview = try? core.previewLegacyIniImport(
                file.contents,
                sourceName: file.sourceName,
                existingSessionNames: existingSessionNames
            ), !preview.sessions.isEmpty {
                return (.legacyINI, preview, nil)
            }
            return (
                .csv,
                try core.previewCSVImport(
                    file.contents,
                    sourceName: file.sourceName,
                    existingSessionNames: existingSessionNames
                ),
                nil
            )
        }
    }

    private func externalPreview(
        _ payload: ExternalSessionImportPayload,
        existingSessionNames: [String]
    ) -> ImportPreview {
        let existing = Set(existingSessionNames.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        let sessions = payload.sessions.map { session in
            ImportSessionPreview(
                name: session.name,
                folder: session.folderPath,
                protocol: session.protocolName,
                host: session.host,
                port: session.port,
                username: session.username,
                privateKeyPath: session.privateKeyPath,
                configJson: nil,
                conflict: existing.contains(session.name.lowercased())
            )
        }
        return ImportPreview(
            sessions: sessions,
            warnings: payload.warnings,
            conflictCount: UInt32(sessions.filter(\.conflict).count),
            ignoredSecretFieldCount: 0
        )
    }
}

public struct AppKitSessionImportFilePicker: SessionImportFilePicking {
    public init() {}

    public func pickImportFile(parentWindow: NSWindow?) throws -> SessionImportFile? {
        try pickImportFile(sourceType: .genericJSON, parentWindow: parentWindow)
    }

    public func pickImportFile(
        sourceType: SessionImportSourceType,
        parentWindow: NSWindow?
    ) throws -> SessionImportFile? {
        if !Thread.isMainThread {
            return try DispatchQueue.main.sync {
                try pickImportFile(sourceType: sourceType, parentWindow: parentWindow)
            }
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = sourceType == .finalShell || sourceType == .xShell
        panel.canChooseFiles = sourceType != .finalShell
        panel.allowsMultipleSelection = false
        panel.message = L10n.Import.chooseFile
        panel.allowedContentTypes = Self.allowedContentTypes(for: sourceType)

        let response: NSApplication.ModalResponse
        if let parentWindow {
            response = panel.runModal()
            parentWindow.makeKey()
        } else {
            response = panel.runModal()
        }
        guard response == .OK, let url = panel.url else {
            return nil
        }

        let contents = url.hasDirectoryPath ? "" : try Self.readTextFile(url)
        return SessionImportFile(
            sourceName: url.lastPathComponent,
            sourceType: sourceType,
            contents: contents,
            sourceURL: url
        )
    }

    private static func allowedContentTypes(for sourceType: SessionImportSourceType) -> [UTType] {
        let extensions: [String]
        switch sourceType {
        case .stacioJSON, .genericJSON:
            extensions = ["json", SecureSessionTransfer.fileExtension]
        case .termius, .electerm:
            extensions = ["json"]
        case .xShell:
            return [UTType.folder] + ["xsh", "xts"].compactMap { UTType(filenameExtension: $0) }
        case .mobaXterm:
            extensions = ["mxtsessions"]
        case .windTerm:
            extensions = ["sessions"]
        case .secureCRT:
            extensions = ["xml"]
        case .finalShell:
            return [.folder]
        case .csv:
            extensions = ["csv"]
        case .legacyINI:
            extensions = ["ini", "txt"]
        case .unknown:
            return [.data]
        }
        return extensions.compactMap { UTType(filenameExtension: $0) }
    }

    private static func readTextFile(_ url: URL) throws -> String {
        try decodeTextData(Data(contentsOf: url))
    }

    static func decodeTextData(_ data: Data) throws -> String {
        guard data.isEmpty == false else { return "" }

        if data.starts(with: [0xFF, 0xFE, 0x00, 0x00]),
           let text = String(data: data, encoding: .utf32LittleEndian) {
            return text
        }
        if data.starts(with: [0x00, 0x00, 0xFE, 0xFF]),
           let text = String(data: data, encoding: .utf32BigEndian) {
            return text
        }
        if data.starts(with: [0xFF, 0xFE]),
           let text = String(data: data, encoding: .utf16LittleEndian) {
            return text
        }
        if data.starts(with: [0xFE, 0xFF]),
           let text = String(data: data, encoding: .utf16BigEndian) {
            return text
        }
        if let text = String(data: data, encoding: .utf8) {
            return text
        }

        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        ))
        if let text = String(data: data, encoding: gb18030) {
            return text
        }
        if let text = String(data: data, encoding: .windowsCP1252)
            ?? String(data: data, encoding: .isoLatin1) {
            return text
        }
        throw CocoaError(.fileReadInapplicableStringEncoding)
    }
}
