import XCTest
@testable import StacioApp
import StacioCoreBindings

final class SessionBridgeTests: XCTestCase {
    func testQuickConnectParserIsAvailableFromSwift() throws {
        let target = try CoreBridge.parseQuickConnect("deploy@example.com:2200")

        XCTAssertEqual(target.protocol, "ssh")
        XCTAssertEqual(target.username, "deploy")
        XCTAssertEqual(target.host, "example.com")
        XCTAssertEqual(target.port, 2200)
    }

    func testCSVImportPreviewDoesNotExposePasswords() throws {
        let csv = """
        name,host,port,username,folder,private_key_path,password
        API,api.example.com,22,deploy,Production,~/.ssh/prod,do-not-import
        """

        let preview = try CoreBridge.previewCSVImport(csv, existingSessionNames: ["API"])

        XCTAssertEqual(preview.sessions.count, 1)
        XCTAssertEqual(preview.sessions[0].name, "API")
        XCTAssertEqual(preview.sessions[0].folder, "Production")
        XCTAssertEqual(preview.conflictCount, 1)
        XCTAssertEqual(preview.ignoredSecretFieldCount, 1)
        XCTAssertTrue(preview.warnings.contains { $0.contains("密码字段，已忽略") })
        XCTAssertFalse(String(describing: preview).contains("do-not-import"))
    }

    func testSessionFoldersAndRecordsPersistThroughCoreBridge() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let folder = try CoreBridge.createSessionFolder(
            databasePath: tempURL.path,
            parentID: nil,
            name: "Production"
        )
        let session = try CoreBridge.createSessionRecord(
            databasePath: tempURL.path,
            draft: SessionDraft(
                folderId: folder.id,
                name: "API Server",
                protocol: "ssh",
                host: "api.example.com",
                port: 22,
                username: "deploy",
                privateKeyPath: nil,
                credentialId: nil,
                tags: ["prod"],
                configJson: nil
            )
        )

        let folders = try CoreBridge.listSessionFolders(databasePath: tempURL.path)
        let sessions = try CoreBridge.listSessionRecords(
            databasePath: tempURL.path,
            folderID: folder.id
        )

        XCTAssertEqual(folders, [folder])
        XCTAssertEqual(sessions, [session])
        XCTAssertFalse(String(describing: sessions).contains("secret"))
    }

    func testImportApplyPersistsSessionsReportsAndExposesAllSessionList() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let existing = try CoreBridge.createSessionRecord(
            databasePath: tempURL.path,
            draft: SessionDraft(
                folderId: nil,
                name: "API",
                protocol: "ssh",
                host: "old-api.example.com",
                port: 22,
                username: "deploy",
                privateKeyPath: nil,
                credentialId: nil,
                tags: ["existing"],
                configJson: nil
            )
        )
        let csv = """
        name,host,port,username,folder,private_key_path,password
        API,api.example.com,22,deploy,Production,~/.ssh/prod,do-not-import
        Worker,worker.example.com,2200,ops,Production,~/.ssh/worker,
        """
        let preview = try CoreBridge.previewCSVImport(csv, existingSessionNames: ["API"])

        let result = try CoreBridge.applySessionImport(
            databasePath: tempURL.path,
            sourceType: "csv",
            sourceName: "sessions.csv",
            preview: preview
        )
        let reports = try CoreBridge.listImportReports(databasePath: tempURL.path)
        let productionFolder = try XCTUnwrap(
            CoreBridge.listSessionFolders(databasePath: tempURL.path)
                .first(where: { $0.name == "Production" })
        )
        let productionSessions = try CoreBridge.listSessionRecords(
            databasePath: tempURL.path,
            folderID: productionFolder.id
        )
        let rootSessions = try CoreBridge.listSessionRecords(
            databasePath: tempURL.path,
            folderID: nil
        )
        let allSessions = try CoreBridge.listAllSessionRecords(databasePath: tempURL.path)
        let serialized = String(describing: result)

        XCTAssertEqual(result.report.status, "partial")
        XCTAssertEqual(result.report.importedCount, 1)
        XCTAssertEqual(result.report.skippedCount, 1)
        XCTAssertEqual(result.report.failedCount, 0)
        XCTAssertEqual(reports, [result.report])
        XCTAssertEqual(productionSessions.map(\.name), ["Worker"])
        XCTAssertEqual(rootSessions, [existing])
        XCTAssertEqual(Set(allSessions.map(\.name)), Set(["API", "Worker"]))
        XCTAssertFalse(serialized.contains("do-not-import"))
        XCTAssertFalse(serialized.contains("secret"))
    }

    func testSessionRecordUpdateAndDeletePersistThroughCoreBridge() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let folder = try CoreBridge.createSessionFolder(
            databasePath: tempURL.path,
            parentID: nil,
            name: "Production"
        )
        let session = try CoreBridge.createSessionRecord(
            databasePath: tempURL.path,
            draft: SessionDraft(
                folderId: nil,
                name: "Old API",
                protocol: "ssh",
                host: "api.example.com",
                port: 22,
                username: "deploy",
                privateKeyPath: nil,
                credentialId: nil,
                tags: ["old"],
                configJson: nil
            )
        )

        let updated = try CoreBridge.updateSessionRecord(
            databasePath: tempURL.path,
            id: session.id,
            update: SessionUpdate(
                name: "API Server",
                protocol: "telnet",
                folderId: folder.id,
                host: "api.internal",
                port: 2222,
                username: "ops",
                privateKeyPath: "~/.ssh/prod",
                credentialId: nil,
                tags: ["prod", "api"],
                configJson: nil
            )
        )

        XCTAssertEqual(updated.name, "API Server")
        XCTAssertEqual(updated.protocol, "telnet")
        XCTAssertEqual(updated.folderId, folder.id)
        XCTAssertEqual(updated.host, "api.internal")
        XCTAssertEqual(updated.port, 2222)
        XCTAssertEqual(updated.username, "ops")
        XCTAssertEqual(updated.privateKeyPath, "~/.ssh/prod")
        XCTAssertEqual(updated.tags, ["prod", "api"])

        let cleared = try CoreBridge.updateSessionRecord(
            databasePath: tempURL.path,
            id: session.id,
            update: SessionUpdate(
                name: nil,
                protocol: nil,
                folderId: nil,
                host: nil,
                port: nil,
                username: "",
                privateKeyPath: "",
                credentialId: nil,
                tags: nil,
                configJson: nil
            )
        )

        XCTAssertNil(cleared.username)
        XCTAssertNil(cleared.privateKeyPath)

        try CoreBridge.deleteSessionRecord(databasePath: tempURL.path, id: session.id)

        XCTAssertEqual(try CoreBridge.listAllSessionRecords(databasePath: tempURL.path), [])
    }

    func testDeletingSSHSessionClearsSavedHostKeyForSameHostAndPort() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let session = try CoreBridge.createSessionRecord(
            databasePath: tempURL.path,
            draft: SessionDraft(
                folderId: nil,
                name: "Reinstalled Host",
                protocol: "ssh",
                host: "192.168.1.201",
                port: 22,
                username: "root",
                privateKeyPath: nil,
                credentialId: nil,
                tags: [],
                configJson: nil
            )
        )
        _ = try CoreBridge.applyHostKeyDecisionInDatabase(
            databasePath: tempURL.path,
            host: "192.168.1.201",
            port: 22,
            hostKey: Array("old-host-key".utf8),
            decision: .trustAndSave
        )

        try CoreBridge.deleteSessionRecord(databasePath: tempURL.path, id: session.id)

        XCTAssertThrowsError(
            try CoreBridge.applyHostKeyDecisionInDatabase(
                databasePath: tempURL.path,
                host: "192.168.1.201",
                port: 22,
                hostKey: Array("new-host-key".utf8),
                decision: .reject
            )
        ) { error in
            XCTAssertEqual(error as? SshRuntimeError, .UnknownHostKey)
        }
    }

    func testSessionDuplicateMoveAndExportJSONThroughCoreBridge() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let folder = try CoreBridge.createSessionFolder(
            databasePath: tempURL.path,
            parentID: nil,
            name: "Production"
        )
        let session = try CoreBridge.createSessionRecord(
            databasePath: tempURL.path,
            draft: SessionDraft(
                folderId: nil,
                name: "API Server",
                protocol: "ssh",
                host: "api.example.com",
                port: 22,
                username: "deploy",
                privateKeyPath: "~/.ssh/prod",
                credentialId: nil,
                tags: ["prod"],
                configJson: nil
            )
        )
        let opened = try CoreBridge.markSessionRecordOpened(
            databasePath: tempURL.path,
            id: session.id
        )

        let duplicate = try CoreBridge.duplicateSessionRecord(
            databasePath: tempURL.path,
            id: session.id,
            targetFolderID: folder.id
        )
        let moved = try CoreBridge.moveSessionRecord(
            databasePath: tempURL.path,
            id: duplicate.id,
            targetFolderID: nil
        )
        let exportJSON = try CoreBridge.exportSessionsJSON(databasePath: tempURL.path)
        let exportData = try XCTUnwrap(exportJSON.data(using: .utf8))
        let exportObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: exportData) as? [String: Any]
        )
        let allSessions = try CoreBridge.listAllSessionRecords(databasePath: tempURL.path)

        XCTAssertNotEqual(duplicate.id, session.id)
        XCTAssertEqual(duplicate.name, "API Server 副本")
        XCTAssertEqual(duplicate.folderId, folder.id)
        XCTAssertNil(duplicate.lastOpenedAt)
        XCTAssertEqual(moved.folderId, nil)
        XCTAssertNotNil(opened.lastOpenedAt)
        XCTAssertEqual(allSessions.count, 2)
        XCTAssertEqual(exportObject["format"] as? String, "stacio.sessions.v1")
        XCTAssertTrue(exportJSON.contains("API Server"))
        XCTAssertTrue(exportJSON.contains("API Server 副本"))
        XCTAssertTrue(exportJSON.contains("~/.ssh/prod"))
        XCTAssertFalse(exportJSON.localizedCaseInsensitiveContains("password"))
        XCTAssertFalse(exportJSON.localizedCaseInsensitiveContains("secret"))
        XCTAssertFalse(exportJSON.localizedCaseInsensitiveContains("sftp"))
    }

    func testProtocolSpecificSessionConfigIsAvailableThroughCoreBridge() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let session = try CoreBridge.createSessionRecord(
            databasePath: tempURL.path,
            draft: SessionDraft(
                folderId: nil,
                name: "串口控制台",
                protocol: "serial",
                host: "/dev/cu.usbserial-001",
                port: 115_200,
                username: nil,
                privateKeyPath: nil,
                credentialId: nil,
                tags: [],
                configJson: nil
            )
        )

        let configJSON = try CoreBridge.getSessionConfigJSON(databasePath: tempURL.path, id: session.id)

        XCTAssertEqual(
            configJSON,
            #"{"kind":"serial","devicePath":"/dev/cu.usbserial-001","baudRate":115200,"dataBits":8,"stopBits":1,"parity":"none","flowControl":"none","backspaceMode":"del"}"#
        )
        XCTAssertFalse(String(describing: configJSON).contains("secret"))
        XCTAssertFalse(String(describing: configJSON).contains("password"))
    }

    func testCredentialReferencePersistsThroughCoreBridgeWithoutSecretValues() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let credential = try CoreBridge.saveCredentialRecord(
            databasePath: tempURL.path,
            draft: CredentialDraft(
                kind: "password",
                label: "API password",
                keychainService: KeychainCredentialStore.serviceName,
                keychainAccount: "deploy@example.com"
            )
        )
        let session = try CoreBridge.createSessionRecord(
            databasePath: tempURL.path,
            draft: SessionDraft(
                folderId: nil,
                name: "API",
                protocol: "ssh",
                host: "example.com",
                port: 22,
                username: "deploy",
                privateKeyPath: nil,
                credentialId: credential.id,
                tags: ["prod"],
                configJson: nil
            )
        )

        let credentials = try CoreBridge.listCredentialRecords(databasePath: tempURL.path)
        let sessions = try CoreBridge.listAllSessionRecords(databasePath: tempURL.path)
        let serialized = String(describing: (credentials, sessions))

        XCTAssertEqual(credentials, [credential])
        XCTAssertEqual(session.credentialId, credential.id)
        XCTAssertEqual(sessions[0].credentialId, credential.id)
        XCTAssertFalse(serialized.contains("super-secret"))
        XCTAssertFalse(serialized.contains("password123"))
    }

    func testCredentialDeleteClearsSessionReferenceThroughCoreBridge() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let credential = try CoreBridge.saveCredentialRecord(
            databasePath: tempURL.path,
            draft: CredentialDraft(
                kind: "password",
                label: "API password",
                keychainService: KeychainCredentialStore.serviceName,
                keychainAccount: "deploy@example.com"
            )
        )
        let session = try CoreBridge.createSessionRecord(
            databasePath: tempURL.path,
            draft: SessionDraft(
                folderId: nil,
                name: "API",
                protocol: "ssh",
                host: "example.com",
                port: 22,
                username: "deploy",
                privateKeyPath: nil,
                credentialId: credential.id,
                tags: [],
                configJson: nil
            )
        )

        try CoreBridge.deleteCredentialRecord(databasePath: tempURL.path, id: credential.id)

        XCTAssertEqual(try CoreBridge.listCredentialRecords(databasePath: tempURL.path), [])
        XCTAssertEqual(try CoreBridge.listAllSessionRecords(databasePath: tempURL.path)[0].id, session.id)
        XCTAssertNil(try CoreBridge.listAllSessionRecords(databasePath: tempURL.path)[0].credentialId)
    }

    func testSessionRecordMarkOpenedPersistsThroughCoreBridge() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let session = try CoreBridge.createSessionRecord(
            databasePath: tempURL.path,
            draft: SessionDraft(
                folderId: nil,
                name: "Recent API",
                protocol: "ssh",
                host: "api.example.com",
                port: 22,
                username: "deploy",
                privateKeyPath: nil,
                credentialId: nil,
                tags: [],
                configJson: nil
            )
        )

        XCTAssertNil(session.lastOpenedAt)

        let opened = try CoreBridge.markSessionRecordOpened(
            databasePath: tempURL.path,
            id: session.id
        )
        let listed = try CoreBridge.listAllSessionRecords(databasePath: tempURL.path)

        XCTAssertEqual(opened.id, session.id)
        XCTAssertNotNil(opened.lastOpenedAt)
        XCTAssertEqual(listed[0].lastOpenedAt, opened.lastOpenedAt)
    }
}
