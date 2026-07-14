import AppKit
import XCTest
@testable import StacioApp
import StacioCoreBindings

final class SessionImportCoordinatorTests: XCTestCase {
    func testCoordinatorPreviewsConfirmsAppliesAndRefreshesImportedSessions() throws {
        let file = SessionImportFile(
            sourceName: "sessions.csv",
            sourceType: .csv,
            contents: "csv-body"
        )
        let core = RecordingSessionImportCore(
            existingSessions: [makeRecord(name: "API", host: "api.example.com")],
            csvPreview: preview(
                sessions: [
                    previewSession(name: "API", host: "api.example.com", conflict: true),
                    previewSession(name: "Worker", host: "worker.example.com", conflict: false)
                ],
                conflictCount: 1
            ),
            applyResult: makeApplyResult(importedNames: ["Worker"], importedCount: 1, skippedCount: 1)
        )
        let presenter = RecordingSessionImportPresenter(confirmImport: true)
        var refreshCount = 0
        let coordinator = SessionImportCoordinator(
            databasePath: "/tmp/Stacio.sqlite",
            filePicker: RecordingSessionImportFilePicker(file: file),
            presenter: presenter,
            core: core,
            onImported: { refreshCount += 1 }
        )

        let result = try coordinator.runImport(parentWindow: nil)

        XCTAssertEqual(result?.report.importedCount, 1)
        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(core.events, [
            "listAll",
            "previewCSV:sessions.csv",
            "apply:csv:sessions.csv"
        ])
        XCTAssertEqual(presenter.previewedSessionNames, ["API", "Worker"])
    }

    func testCoordinatorDoesNothingWhenFileSelectionIsCancelled() throws {
        let core = RecordingSessionImportCore()
        let presenter = RecordingSessionImportPresenter(confirmImport: true)
        var refreshCount = 0
        let coordinator = SessionImportCoordinator(
            databasePath: "/tmp/Stacio.sqlite",
            filePicker: RecordingSessionImportFilePicker(file: nil),
            presenter: presenter,
            core: core,
            onImported: { refreshCount += 1 }
        )

        let result = try coordinator.runImport(parentWindow: nil)

        XCTAssertNil(result)
        XCTAssertEqual(core.events, [])
        XCTAssertEqual(refreshCount, 0)
    }

    func testCoordinatorDoesNotApplyWhenPreviewIsCancelled() throws {
        let core = RecordingSessionImportCore(
            csvPreview: preview(
                sessions: [previewSession(name: "Worker", host: "worker.example.com", conflict: false)]
            ),
            applyResult: makeApplyResult(importedNames: ["Worker"], importedCount: 1, skippedCount: 0)
        )
        let coordinator = SessionImportCoordinator(
            databasePath: "/tmp/Stacio.sqlite",
            filePicker: RecordingSessionImportFilePicker(
                file: SessionImportFile(sourceName: "sessions.csv", sourceType: .csv, contents: "csv-body")
            ),
            presenter: RecordingSessionImportPresenter(confirmImport: false),
            core: core,
            onImported: {}
        )

        let result = try coordinator.runImport(parentWindow: nil)

        XCTAssertNil(result)
        XCTAssertEqual(core.events, ["listAll", "previewCSV:sessions.csv"])
    }

    func testCoordinatorReturnsVisibleNoChangeResultWhenEveryPreviewRowConflicts() throws {
        let skippedReport = ImportReport(
            id: "report_skipped",
            sourceType: "csv",
            sourceName: "sessions.csv",
            status: "skipped",
            importedCount: 0,
            skippedCount: 1,
            failedCount: 0,
            issues: ["API skipped because a session with the same name exists"],
            createdAt: "2026-05-31T00:00:00Z"
        )
        let core = RecordingSessionImportCore(
            existingSessions: [makeRecord(name: "API", host: "api.example.com")],
            csvPreview: preview(
                sessions: [previewSession(name: "API", host: "api.example.com", conflict: true)],
                conflictCount: 1
            ),
            applyResult: ImportApplyResult(report: skippedReport, importedSessions: [])
        )
        let presenter = RecordingSessionImportPresenter(confirmImport: true)
        var refreshCount = 0
        let coordinator = SessionImportCoordinator(
            databasePath: "/tmp/Stacio.sqlite",
            filePicker: RecordingSessionImportFilePicker(
                file: SessionImportFile(sourceName: "sessions.csv", sourceType: .csv, contents: "csv-body")
            ),
            presenter: presenter,
            core: core,
            onImported: { refreshCount += 1 }
        )

        let result = try coordinator.runImport(parentWindow: nil)

        XCTAssertEqual(result?.report.status, "skipped")
        XCTAssertEqual(result?.report.importedCount, 0)
        XCTAssertEqual(result?.report.skippedCount, 1)
        XCTAssertEqual(result?.report.failedCount, 0)
        XCTAssertTrue(result?.report.issues.first?.contains("API") == true)
        XCTAssertEqual(core.events, [
            "listAll",
            "previewCSV:sessions.csv",
            "apply:csv:sessions.csv"
        ])
        XCTAssertEqual(refreshCount, 0)
        XCTAssertEqual(presenter.shownResults.map(\.report.status), ["skipped"])
    }

    func testCoordinatorPersistsSkippedReportWhenEveryPreviewRowConflicts() throws {
        let skippedReport = ImportReport(
            id: "persisted_skipped_report",
            sourceType: "csv",
            sourceName: "sessions.csv",
            status: "skipped",
            importedCount: 0,
            skippedCount: 1,
            failedCount: 0,
            issues: ["API skipped because a session with the same name exists"],
            createdAt: "2026-05-31T00:00:00Z"
        )
        let core = RecordingSessionImportCore(
            existingSessions: [makeRecord(name: "API", host: "api.example.com")],
            csvPreview: preview(
                sessions: [previewSession(name: "API", host: "api.example.com", conflict: true)],
                conflictCount: 1
            ),
            applyResult: ImportApplyResult(report: skippedReport, importedSessions: [])
        )
        let presenter = RecordingSessionImportPresenter(confirmImport: true)
        var refreshCount = 0
        let coordinator = SessionImportCoordinator(
            databasePath: "/tmp/Stacio.sqlite",
            filePicker: RecordingSessionImportFilePicker(
                file: SessionImportFile(sourceName: "sessions.csv", sourceType: .csv, contents: "csv-body")
            ),
            presenter: presenter,
            core: core,
            onImported: { refreshCount += 1 }
        )

        let result = try coordinator.runImport(parentWindow: nil)

        XCTAssertEqual(result?.report, skippedReport)
        XCTAssertEqual(core.events, [
            "listAll",
            "previewCSV:sessions.csv",
            "apply:csv:sessions.csv"
        ])
        XCTAssertEqual(refreshCount, 0)
        XCTAssertEqual(presenter.shownResults.map(\.report.id), ["persisted_skipped_report"])
    }

    func testCoordinatorFallsBackToCSVWhenUnknownFileDoesNotLookLikeLegacyIni() throws {
        let core = RecordingSessionImportCore(
            csvPreview: preview(
                sessions: [previewSession(name: "Worker", host: "worker.example.com", conflict: false)]
            ),
            legacyIniPreview: preview(sessions: []),
            applyResult: makeApplyResult(importedNames: ["Worker"], importedCount: 1, skippedCount: 0)
        )
        let coordinator = SessionImportCoordinator(
            databasePath: "/tmp/Stacio.sqlite",
            filePicker: RecordingSessionImportFilePicker(
                file: SessionImportFile(sourceName: "export.data", sourceType: .unknown, contents: "csv-body")
            ),
            presenter: RecordingSessionImportPresenter(confirmImport: true),
            core: core,
            onImported: {}
        )

        _ = try coordinator.runImport(parentWindow: nil)

        XCTAssertEqual(core.events, [
            "listAll",
            "previewStacioJSON:export.data",
            "previewLegacyIni:export.data",
            "previewCSV:export.data",
            "apply:csv:export.data"
        ])
    }

    func testCoordinatorAppliesLegacyIniPreviewWhenNonSSHSupportedSessionsAreImportable() throws {
        let core = RecordingSessionImportCore(
            legacyIniPreview: preview(
                sessions: [
                    previewSession(name: "FTP 站点", protocol: "ftp", host: "ftp.example.com", port: 21),
                    previewSession(name: "VNC 控制台", protocol: "vnc", host: "bmc.example.com", port: 5900)
                ]
            ),
            applyResult: makeApplyResult(importedNames: ["FTP 站点", "VNC 控制台"], importedCount: 2, skippedCount: 0)
        )
        let presenter = RecordingSessionImportPresenter(confirmImport: true)
        let coordinator = SessionImportCoordinator(
            databasePath: "/tmp/Stacio.sqlite",
            filePicker: RecordingSessionImportFilePicker(
                file: SessionImportFile(sourceName: "Legacy INI.ini", sourceType: .legacyINI, contents: "legacy-ini-body")
            ),
            presenter: presenter,
            core: core,
            onImported: {}
        )

        let result = try coordinator.runImport(parentWindow: nil)

        XCTAssertEqual(result?.report.importedCount, 2)
        XCTAssertEqual(presenter.previewedSessionNames, ["FTP 站点", "VNC 控制台"])
        XCTAssertEqual(core.events, [
            "listAll",
            "previewLegacyIni:Legacy INI.ini",
            "apply:legacy_ini:Legacy INI.ini"
        ])
    }

    func testCoordinatorAppliesStacioJSONPreviewForExportedGroups() throws {
        let core = RecordingSessionImportCore(
            jsonPreview: preview(
                sessions: [
                    previewSession(
                        name: "Primary DB",
                        protocol: "ssh",
                        host: "db.example.com",
                        port: 22
                    )
                ]
            ),
            applyResult: makeApplyResult(importedNames: ["Primary DB"], importedCount: 1, skippedCount: 0)
        )
        let presenter = RecordingSessionImportPresenter(confirmImport: true)
        let coordinator = SessionImportCoordinator(
            databasePath: "/tmp/Stacio.sqlite",
            filePicker: RecordingSessionImportFilePicker(
                file: SessionImportFile(
                    sourceName: "Production Sessions.json",
                    sourceType: .stacioJSON,
                    contents: "json-body"
                )
            ),
            presenter: presenter,
            core: core,
            onImported: {}
        )

        let result = try coordinator.runImport(parentWindow: nil)

        XCTAssertEqual(result?.report.importedCount, 1)
        XCTAssertEqual(presenter.previewedSessionNames, ["Primary DB"])
        XCTAssertEqual(core.events, [
            "listAll",
            "previewStacioJSON:Production Sessions.json",
            "apply:stacio_json:Production Sessions.json"
        ])
    }

    func testImportPreviewMessageUsesChineseSourceTypeLabel() {
        let message = L10n.Import.previewMessage(
            sourceName: "sessions.csv",
            sourceType: .csv,
            importableCount: 1,
            conflictCount: 0
        )

        XCTAssertTrue(message.contains("CSV 文件"))
        XCTAssertFalse(message.contains(" - csv。"))
    }

    func testImportPreviewTextShowsNonSSHProtocolsAndTargets() {
        let preview = preview(
            sessions: [
                previewSession(name: "FTP 站点", protocol: "ftp", host: "ftp.example.com", port: 21),
                previewSession(name: "Telnet 控制台", protocol: "telnet", host: "10.0.0.20", port: 23),
                previewSession(name: "VNC 控制台", protocol: "vnc", host: "bmc.example.com", port: 5900)
            ]
        )

        let text = AppKitSessionImportPreviewPresenter.previewTextForTesting(preview)

        XCTAssertTrue(text.contains("名称\t文件夹\t协议\t目标\t状态"))
        XCTAssertTrue(text.contains("FTP 站点\tProduction\tFTP\tdeploy@ftp.example.com:21\t新增"))
        XCTAssertTrue(text.contains("Telnet 控制台\tProduction\tTelnet\tdeploy@10.0.0.20:23\t新增"))
        XCTAssertTrue(text.contains("VNC 控制台\tProduction\tVNC\tdeploy@bmc.example.com:5900\t新增"))
        XCTAssertFalse(text.contains("SSH\tdeploy@ftp.example.com:21"))
    }

    func testImportPreviewTextRedactsSensitiveWarnings() {
        let preview = preview(
            sessions: [previewSession(name: "API", host: "api.example.com", conflict: false)],
            warnings: [
                "已忽略 password=hunter2、secret=token123、private key=/Users/me/.ssh/id_rsa"
            ]
        )

        let text = AppKitSessionImportPreviewPresenter.previewTextForTesting(preview)

        XCTAssertTrue(text.contains("已隐藏敏感字段"))
        XCTAssertFalse(text.contains("hunter2"))
        XCTAssertFalse(text.contains("token123"))
        XCTAssertFalse(text.contains("id_rsa"))
    }

    func testImportPreviewTextRedactsTokensApiKeysAndPrivateKeyPathsInWarnings() {
        let preview = preview(
            sessions: [previewSession(name: "API", host: "api.example.com", conflict: false)],
            warnings: [
                "已忽略 token=def",
                "已忽略 api_key=ghi",
                "已忽略 /Users/mac/.ssh/id_rsa"
            ]
        )

        let text = AppKitSessionImportPreviewPresenter.previewTextForTesting(preview)

        XCTAssertTrue(text.contains("已隐藏敏感字段"))
        XCTAssertFalse(text.contains("def"))
        XCTAssertFalse(text.contains("ghi"))
        XCTAssertFalse(text.contains("/Users/mac/.ssh/id_rsa"))
        XCTAssertFalse(text.contains("id_rsa"))
    }

    func testImportPreviewAccessoryRendersNativeTableWithChineseColumnsAndRedactedWarnings() throws {
        let preview = preview(
            sessions: [
                previewSession(name: "API", host: "api.example.com", conflict: true),
                previewSession(name: "Worker", protocol: "ftp", host: "worker.example.com", port: 21)
            ],
            warnings: [
                "已忽略 password=hunter2、secret=token123、private key=/Users/me/.ssh/id_rsa"
            ],
            conflictCount: 1
        )

        let accessory = AppKitSessionImportPreviewPresenter.previewAccessoryForTesting(preview)
        let scrollView = try XCTUnwrap(accessory.firstSubview(ofType: NSScrollView.self))
        let tableView = try XCTUnwrap(accessory.firstSubview(ofType: NSTableView.self))

        XCTAssertEqual(tableView.tableColumns.map { $0.title }, ["名称", "文件夹", "协议", "目标", "状态", "警告"])
        XCTAssertEqual(tableView.numberOfRows, 2)
        XCTAssertFalse(tableView.usesAlternatingRowBackgroundColors)
        XCTAssertEqual(tableView.backgroundColor, .clear)
        XCTAssertEqual(scrollView.hasHorizontalScroller, false)
        XCTAssertEqual(scrollView.borderType, .noBorder)
        XCTAssertEqual(tableView.tableColumns.reduce(CGFloat(0)) { $0 + $1.width }, 520, accuracy: 1)
        XCTAssertEqual(tableView.stringValue(row: 0, column: "status"), "冲突")
        XCTAssertEqual(tableView.stringValue(row: 1, column: "protocol"), "FTP")
        XCTAssertEqual(tableView.stringValue(row: 1, column: "target"), "deploy@worker.example.com:21")

        let warningText = tableView.stringValue(row: 0, column: "warnings")
        XCTAssertTrue(warningText.contains("已隐藏敏感字段"))
        XCTAssertFalse(warningText.contains("hunter2"))
        XCTAssertFalse(warningText.contains("token123"))
        XCTAssertFalse(warningText.contains("id_rsa"))
    }
}

private final class RecordingSessionImportFilePicker: SessionImportFilePicking {
    private let file: SessionImportFile?

    init(file: SessionImportFile?) {
        self.file = file
    }

    func pickImportFile(parentWindow: NSWindow?) throws -> SessionImportFile? {
        file
    }
}

private final class RecordingSessionImportPresenter: SessionImportPreviewPresenting {
    private let confirmImport: Bool
    private(set) var previewedSessionNames: [String] = []
    private(set) var shownResults: [ImportApplyResult] = []

    init(confirmImport: Bool) {
        self.confirmImport = confirmImport
    }

    func confirmImport(
        preview: ImportPreview,
        sourceName: String,
        sourceType: SessionImportSourceType,
        parentWindow: NSWindow?
    ) -> Bool {
        previewedSessionNames = preview.sessions.map(\.name)
        return confirmImport
    }

    func showImportResult(_ result: ImportApplyResult, parentWindow: NSWindow?) {
        shownResults.append(result)
    }

    func showImportError(_ error: Error, parentWindow: NSWindow?) {}
}

private final class RecordingSessionImportCore: SessionImportCoreBridging {
    var events: [String] = []
    private let existingSessions: [SessionRecord]
    private let csvPreview: ImportPreview
    private let legacyIniPreview: ImportPreview
    private let jsonPreview: ImportPreview
    private let applyResult: ImportApplyResult

    init(
        existingSessions: [SessionRecord] = [],
        csvPreview: ImportPreview = preview(sessions: []),
        legacyIniPreview: ImportPreview = preview(sessions: []),
        jsonPreview: ImportPreview = preview(sessions: []),
        applyResult: ImportApplyResult = makeApplyResult(importedNames: [], importedCount: 0, skippedCount: 0)
    ) {
        self.existingSessions = existingSessions
        self.csvPreview = csvPreview
        self.legacyIniPreview = legacyIniPreview
        self.jsonPreview = jsonPreview
        self.applyResult = applyResult
    }

    func listAllSessionRecords(databasePath: String) throws -> [SessionRecord] {
        events.append("listAll")
        return existingSessions
    }

    func previewCSVImport(
        _ input: String,
        sourceName: String,
        existingSessionNames: [String]
    ) throws -> ImportPreview {
        events.append("previewCSV:\(sourceName)")
        return csvPreview
    }

    func previewLegacyIniImport(
        _ input: String,
        sourceName: String,
        existingSessionNames: [String]
    ) throws -> ImportPreview {
        events.append("previewLegacyIni:\(sourceName)")
        return legacyIniPreview
    }

    func previewStacioJSONImport(
        _ input: String,
        sourceName: String,
        existingSessionNames: [String]
    ) throws -> ImportPreview {
        events.append("previewStacioJSON:\(sourceName)")
        return jsonPreview
    }

    func applySessionImport(
        databasePath: String,
        sourceType: SessionImportSourceType,
        sourceName: String,
        preview: ImportPreview
    ) throws -> ImportApplyResult {
        events.append("apply:\(sourceType.rawValue):\(sourceName)")
        return applyResult
    }
}

private func preview(
    sessions: [ImportSessionPreview],
    warnings: [String] = [],
    conflictCount: UInt32 = 0
) -> ImportPreview {
    ImportPreview(
        sessions: sessions,
        warnings: warnings,
        conflictCount: conflictCount,
        ignoredSecretFieldCount: 0
    )
}

private extension NSView {
    func firstSubview<View: NSView>(ofType type: View.Type) -> View? {
        if let view = self as? View {
            return view
        }
        for subview in subviews {
            if let match = subview.firstSubview(ofType: type) {
                return match
            }
        }
        return nil
    }
}

private extension NSTableView {
    func stringValue(row: Int, column identifier: String) -> String {
        guard let columnIndex = tableColumns.firstIndex(where: { $0.identifier.rawValue == identifier }),
              let view = view(atColumn: columnIndex, row: row, makeIfNecessary: false) as? NSTableCellView
        else {
            return ""
        }
        return view.textField?.stringValue ?? ""
    }
}

private func previewSession(
    name: String,
    host: String,
    conflict: Bool
) -> ImportSessionPreview {
    previewSession(name: name, protocol: "ssh", host: host, port: 22, conflict: conflict)
}

private func previewSession(
    name: String,
    protocol: String,
    host: String,
    port: UInt16,
    conflict: Bool = false
) -> ImportSessionPreview {
    ImportSessionPreview(
        name: name,
        folder: "Production",
        protocol: `protocol`,
        host: host,
        port: port,
        username: "deploy",
        privateKeyPath: nil,
        conflict: conflict
    )
}

private func makeApplyResult(
    importedNames: [String],
    importedCount: UInt32,
    skippedCount: UInt32
) -> ImportApplyResult {
    ImportApplyResult(
        report: ImportReport(
            id: "report_1",
            sourceType: "csv",
            sourceName: "sessions.csv",
            status: skippedCount > 0 ? "partial" : "imported",
            importedCount: importedCount,
            skippedCount: skippedCount,
            failedCount: 0,
            issues: [],
            createdAt: "2026-05-28T00:00:00Z"
        ),
        importedSessions: importedNames.map { makeRecord(name: $0, host: "\($0.lowercased()).example.com") }
    )
}

private func makeRecord(name: String, host: String) -> SessionRecord {
    SessionRecord(
        id: "session_\(name.lowercased())",
        folderId: nil,
        name: name,
        protocol: "ssh",
        host: host,
        port: 22,
        username: "deploy",
        privateKeyPath: nil,
        credentialId: nil,
        tags: [],
        lastOpenedAt: nil
    )
}
