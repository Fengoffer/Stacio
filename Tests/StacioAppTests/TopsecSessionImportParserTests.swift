import Foundation
import XCTest
import ZIPFoundation
@testable import StacioApp
import StacioCoreBindings

final class TopsecSessionImportParserTests: XCTestCase {
    func testOtherXLSXExportMapsGatewayAndCompositeTargetMetadata() throws {
        let url = try makeArchive(
            pathExtension: "xlsx",
            entries: [
                "xl/sharedStrings.xml": Data(
                    """
                    <?xml version="1.0" encoding="UTF-8"?>
                    <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
                      <si><t>Host</t></si><si><t>Protocol</t></si><si><t>UserName</t></si><si><t>Port</t></si>
                      <si><t>bastion.example.com</t></si><si><t>SSH</t></si>
                      <si><t>opaque-account@default@SSH@ops@10.0.0.8@22</t></si>
                    </sst>
                    """.utf8
                ),
                "xl/worksheets/sheet1.xml": Data(
                    """
                    <?xml version="1.0" encoding="UTF-8"?>
                    <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>
                      <row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c><c r="C1" t="s"><v>2</v></c><c r="D1" t="s"><v>3</v></c></row>
                      <row r="2"><c r="A2" t="s"><v>4</v></c><c r="B2" t="s"><v>5</v></c><c r="C2" t="s"><v>6</v></c><c r="D2"><v>2222</v></c></row>
                    </sheetData></worksheet>
                    """.utf8
                )
            ]
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let payload = try TopsecSessionImportParser.parseFile(at: url)
        let session = try XCTUnwrap(payload.sessions.first)

        XCTAssertEqual(payload.sessions.count, 1)
        XCTAssertEqual(session.name, "10.0.0.8")
        XCTAssertEqual(session.host, "bastion.example.com")
        XCTAssertEqual(session.port, 2222)
        XCTAssertEqual(session.username, "opaque-account@default@SSH@ops@10.0.0.8@22")
        let config = try XCTUnwrap(session.configJSON)
        XCTAssertTrue(config.contains("\"bastionVendor\":\"topsec\""))
        XCTAssertTrue(config.contains("\"bastionTargetHost\":\"10.0.0.8\""))
        try assertPayloadCanBeApplied(payload, sourceName: "sessions.xlsx")
    }

    func testXshellZIPExportDecodesBothVersionsAndDeduplicatesTheSession() throws {
        let session = """
        [CONNECTION]
        Host=bastion.example.com
        Port=2222
        Protocol=SSH
        [CONNECTION:AUTHENTICATION]
        UserName=opaque-account@default@SSH@ops@10.0.0.8@22
        """
        var utf16Session = Data([0xFF, 0xFE])
        utf16Session.append(try XCTUnwrap(session.data(using: .utf16LittleEndian)))
        let url = try makeArchive(
            pathExtension: "zip",
            entries: [
                "10.0.0.8_SSH_22_ops(Asset)_6.xsh": Data(session.utf8),
                "10.0.0.8_SSH_22_ops(Asset)_7.xsh": utf16Session
            ]
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let payload = try TopsecSessionImportParser.parseFile(at: url)
        let imported = try XCTUnwrap(payload.sessions.first)

        XCTAssertEqual(payload.sessions.count, 1)
        XCTAssertEqual(imported.name, "10.0.0.8_SSH_22_ops(Asset)")
        XCTAssertEqual(imported.host, "bastion.example.com")
        XCTAssertEqual(imported.port, 2222)
        XCTAssertEqual(imported.username, "opaque-account@default@SSH@ops@10.0.0.8@22")
        XCTAssertTrue(try XCTUnwrap(imported.configJSON).contains("\"bastionVendor\":\"topsec\""))
        try assertPayloadCanBeApplied(payload, sourceName: "xshell-sessions.zip")
    }

    func testSecureCRTZIPExportParsesTypedINIAndAddsTargetMetadata() throws {
        let session = """
        D:"Is Session"=00000001
        S:"Protocol Name"=SSH2
        S:"Hostname"=bastion.example.com
        S:"Username"=opaque-account@default@SSH@ops@10.0.0.8@22
        D:"[SSH2] Port"=000008AE
        S:"Password"=
        D:"Session Password Saved"=00000001
        """
        let url = try makeArchive(
            pathExtension: "zip",
            entries: ["asset.ini": Data(session.utf8)]
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let payload = try TopsecSessionImportParser.parseFile(at: url)
        let imported = try XCTUnwrap(payload.sessions.first)

        XCTAssertEqual(payload.sessions.count, 1)
        XCTAssertEqual(imported.name, "asset")
        XCTAssertEqual(imported.host, "bastion.example.com")
        XCTAssertEqual(imported.port, 2222)
        XCTAssertEqual(imported.username, "opaque-account@default@SSH@ops@10.0.0.8@22")
        XCTAssertNil(imported.credential)
        let config = try XCTUnwrap(imported.configJSON)
        XCTAssertTrue(config.contains("\"bastionVendor\":\"topsec\""))
        XCTAssertTrue(config.contains("\"bastionFormat\":\"topsec_securecrt_zip\""))
        XCTAssertTrue(config.contains("\"bastionTargetHost\":\"10.0.0.8\""))
        XCTAssertTrue(config.contains("\"bastionTargetPort\":22"))
        XCTAssertTrue(config.contains("\"bastionTargetUsername\":\"ops\""))
        try assertPayloadCanBeApplied(payload, sourceName: "securecrt-sessions.zip")
    }

    func testGenericXshellZIPIsNotClaimedAsTopsecWithoutCompositeRoute() throws {
        let session = """
        [CONNECTION]
        Host=server.example.com
        Port=22
        Protocol=SSH
        [CONNECTION:AUTHENTICATION]
        UserName=deploy
        """
        let url = try makeArchive(
            pathExtension: "zip",
            entries: ["server.xsh": Data(session.utf8)]
        )
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try TopsecSessionImportParser.parseFile(at: url)) { error in
            XCTAssertEqual(error as? ExternalSessionImportParserError, .invalidFormat)
        }
    }

    private func makeArchive(
        pathExtension: String,
        entries: [String: Data]
    ) throws -> URL {
        let archive = try Archive(accessMode: .create)
        for (path, data) in entries.sorted(by: { $0.key < $1.key }) {
            try archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(data.count),
                provider: { position, size in
                    data.subdata(in: Int(position)..<(Int(position) + size))
                }
            )
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(pathExtension)
        try XCTUnwrap(archive.data).write(to: url)
        return url
    }

    private func assertPayloadCanBeApplied(
        _ payload: ExternalSessionImportPayload,
        sourceName: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let sessions = payload.sessions.map { session in
            ImportSessionPreview(
                name: session.name,
                folder: session.folderPath,
                protocol: session.protocolName,
                host: session.host,
                port: session.port,
                username: session.username,
                privateKeyPath: session.privateKeyPath,
                configJson: session.configJSON,
                conflict: false
            )
        }
        let preview = ImportPreview(
            sessions: sessions,
            warnings: payload.warnings,
            conflictCount: 0,
            ignoredSecretFieldCount: 0
        )

        let result = try CoreBridge.applySessionImport(
            databasePath: databaseURL.path,
            sourceType: SessionImportSourceType.bastionHost.rawValue,
            sourceName: sourceName,
            preview: preview
        )
        let imported = try CoreBridge.listAllSessionRecords(databasePath: databaseURL.path)

        XCTAssertEqual(result.report.sourceType, "bastion_host", file: file, line: line)
        XCTAssertEqual(result.report.importedCount, UInt32(sessions.count), file: file, line: line)
        XCTAssertEqual(imported.count, sessions.count, file: file, line: line)
        XCTAssertEqual(imported.map(\.username), sessions.map(\.username), file: file, line: line)
        for (record, source) in zip(imported, sessions) {
            let storedConfig = try CoreBridge.getSessionConfigJSON(
                databasePath: databaseURL.path,
                id: record.id
            )
            let storedConfigText = try XCTUnwrap(storedConfig, file: file, line: line)
            let sourceConfigText = try XCTUnwrap(source.configJson, file: file, line: line)
            let storedDictionary = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: Data(storedConfigText.utf8)) as? [String: Any],
                file: file,
                line: line
            )
            let sourceDictionary = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: Data(sourceConfigText.utf8)) as? [String: Any],
                file: file,
                line: line
            )
            for (key, sourceValue) in sourceDictionary {
                let storedValue = storedDictionary[key] ?? NSNull()
                let storedData = try JSONSerialization.data(
                    withJSONObject: [key: storedValue],
                    options: [.sortedKeys]
                )
                let sourceData = try JSONSerialization.data(
                    withJSONObject: [key: sourceValue],
                    options: [.sortedKeys]
                )
                XCTAssertEqual(storedData, sourceData, "Missing persisted config key: \(key)", file: file, line: line)
            }
        }
    }
}
