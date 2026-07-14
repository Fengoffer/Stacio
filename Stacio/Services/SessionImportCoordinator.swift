import AppKit
import Foundation
import StacioCoreBindings
import UniformTypeIdentifiers

public enum SessionImportSourceType: String, Sendable {
    case csv
    case legacyINI = "legacy_ini"
    case stacioJSON = "stacio_json"
    case unknown
}

public struct SessionImportFile: Sendable {
    public let sourceName: String
    public let sourceType: SessionImportSourceType
    public let contents: String

    public init(sourceName: String, sourceType: SessionImportSourceType, contents: String) {
        self.sourceName = sourceName
        self.sourceType = sourceType
        self.contents = contents
    }
}

public protocol SessionImportFilePicking {
    func pickImportFile(parentWindow: NSWindow?) throws -> SessionImportFile?
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
    private let databasePath: String
    private let filePicker: SessionImportFilePicking
    private let presenter: SessionImportPreviewPresenting
    private let core: SessionImportCoreBridging
    private let onImported: () -> Void

    public init(
        databasePath: String,
        filePicker: SessionImportFilePicking = AppKitSessionImportFilePicker(),
        presenter: SessionImportPreviewPresenting = AppKitSessionImportPreviewPresenter(),
        core: SessionImportCoreBridging = CoreBridgeSessionImportCoreBridge(),
        onImported: @escaping () -> Void = {}
    ) {
        self.databasePath = databasePath
        self.filePicker = filePicker
        self.presenter = presenter
        self.core = core
        self.onImported = onImported
    }

    public func runImport(parentWindow: NSWindow?) throws -> ImportApplyResult? {
        do {
            guard let file = try filePicker.pickImportFile(parentWindow: parentWindow) else {
                return nil
            }

            let existingSessionNames = try core
                .listAllSessionRecords(databasePath: databasePath)
                .map(\.name)
            let (sourceType, preview) = try makePreview(
                for: file,
                existingSessionNames: existingSessionNames
            )
            guard presenter.confirmImport(
                preview: preview,
                sourceName: file.sourceName,
                sourceType: sourceType,
                parentWindow: parentWindow
            ) else {
                return nil
            }
            let result = try core.applySessionImport(
                databasePath: databasePath,
                sourceType: sourceType,
                sourceName: file.sourceName,
                preview: preview
            )
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

    private func makePreview(
        for file: SessionImportFile,
        existingSessionNames: [String]
    ) throws -> (SessionImportSourceType, ImportPreview) {
        switch file.sourceType {
        case .csv:
            return (
                .csv,
                try core.previewCSVImport(
                    file.contents,
                    sourceName: file.sourceName,
                    existingSessionNames: existingSessionNames
                )
            )
        case .legacyINI:
            return (
                .legacyINI,
                try core.previewLegacyIniImport(
                    file.contents,
                    sourceName: file.sourceName,
                    existingSessionNames: existingSessionNames
                )
            )
        case .stacioJSON:
            return (
                .stacioJSON,
                try core.previewStacioJSONImport(
                    file.contents,
                    sourceName: file.sourceName,
                    existingSessionNames: existingSessionNames
                )
            )
        case .unknown:
            if let preview = try? core.previewStacioJSONImport(
                file.contents,
                sourceName: file.sourceName,
                existingSessionNames: existingSessionNames
            ), !preview.sessions.isEmpty {
                return (.stacioJSON, preview)
            }
            if let preview = try? core.previewLegacyIniImport(
                file.contents,
                sourceName: file.sourceName,
                existingSessionNames: existingSessionNames
            ), !preview.sessions.isEmpty {
                return (.legacyINI, preview)
            }
            return (
                .csv,
                try core.previewCSVImport(
                    file.contents,
                    sourceName: file.sourceName,
                    existingSessionNames: existingSessionNames
                )
            )
        }
    }
}

public struct AppKitSessionImportFilePicker: SessionImportFilePicking {
    public init() {}

    public func pickImportFile(parentWindow: NSWindow?) throws -> SessionImportFile? {
        if !Thread.isMainThread {
            return try DispatchQueue.main.sync {
                try pickImportFile(parentWindow: parentWindow)
            }
        }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = L10n.Import.chooseFile
        panel.allowedContentTypes = [
            UTType(filenameExtension: "csv"),
            UTType(filenameExtension: "json"),
            UTType(filenameExtension: "ini"),
            UTType(filenameExtension: "txt")
        ].compactMap { $0 }

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

        return SessionImportFile(
            sourceName: url.lastPathComponent,
            sourceType: Self.sourceType(for: url),
            contents: try String(contentsOf: url, encoding: .utf8)
        )
    }

    private static func sourceType(for url: URL) -> SessionImportSourceType {
        switch url.pathExtension.lowercased() {
        case "csv":
            return .csv
        case "json":
            return .stacioJSON
        case "ini", "txt":
            return .legacyINI
        default:
            return .unknown
        }
    }
}
