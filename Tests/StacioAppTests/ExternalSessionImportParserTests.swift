import Foundation
import XCTest
@testable import StacioApp

final class ExternalSessionImportParserTests: XCTestCase {
    func testMobaXtermGB18030ExportIsDecodedBeforeParsing() throws {
        let contents = Data([
            0x5B, 0x42, 0x6F, 0x6F, 0x6B, 0x6D, 0x61, 0x72, 0x6B, 0x73, 0x5D, 0x0D, 0x0A,
            0x53, 0x75, 0x62, 0x52, 0x65, 0x70, 0x3D, 0xB2, 0xE2, 0xCA, 0xD4, 0x0D, 0x0A,
            0x53, 0x65, 0x72, 0x76, 0x65, 0x72, 0x3D, 0x23, 0x31, 0x30, 0x39, 0x23, 0x30,
            0x25, 0x68, 0x6F, 0x73, 0x74, 0x2E, 0x65, 0x78, 0x61, 0x6D, 0x70, 0x6C, 0x65,
            0x2E, 0x63, 0x6F, 0x6D, 0x25, 0x32, 0x32, 0x25, 0x64, 0x65, 0x70, 0x6C, 0x6F,
            0x79, 0x0D, 0x0A
        ])

        let text = try AppKitSessionImportFilePicker.decodeTextData(contents)
        let payload = try ExternalSessionImportParser.parseText(
            text,
            sourceType: .mobaXterm,
            sourceName: "MobaXterm Sessions.mxtsessions"
        )

        XCTAssertTrue(text.hasPrefix("[Bookmarks]"))
        XCTAssertEqual(payload.sessions.count, 1)
        XCTAssertEqual(payload.sessions[0].host, "host.example.com")
        XCTAssertEqual(payload.sessions[0].username, "deploy")
    }

    func testMobaXtermImportsNestedGroupAndPassword() throws {
        let payload = try ExternalSessionImportParser.parseText(
            """
            [Bookmarks]
            SubRep=Production\\Web
            Web 01=#109#0%web.example.com%2222%deploy%%-1%-1%%%%%0%0%0%%%-1%0%0%0%%1080%%0%0%1
            [Passwords]
            web.example.com=plain-secret
            """,
            sourceType: .mobaXterm,
            sourceName: "prod.mxtsessions"
        )

        XCTAssertEqual(payload.sessions.count, 1)
        XCTAssertEqual(payload.sessions[0].folderPath, "Production/Web")
        XCTAssertEqual(payload.sessions[0].host, "web.example.com")
        XCTAssertEqual(payload.sessions[0].port, 2222)
        XCTAssertEqual(payload.sessions[0].username, "deploy")
        XCTAssertEqual(payload.sessions[0].credential, .password("plain-secret"))
    }

    func testMobaXtermMatchesPasswordKeysCaseInsensitivelyIncludingPort() throws {
        let payload = try ExternalSessionImportParser.parseText(
            """
            [Bookmarks]
            192.168.124.100 (fenglee)=#109#0%192.168.124.100%22%FengLee
            [Passwords]
            fenglee@192.168.124.100:22=plain-secret
            """,
            sourceType: .mobaXterm,
            sourceName: "MobaXterm Sessions.mxtsessions"
        )

        XCTAssertEqual(payload.sessions[0].credential, .password("plain-secret"))
    }

    func testXshellImportsPasswordAndPrivateKeyPath() throws {
        let payload = try ExternalSessionImportParser.parseText(
            """
            [CONNECTION]
            Host=api.example.com
            Port=2200
            UserName=ops
            Password=secret-value
            [AUTHENTICATION]
            Method=PUBLICKEY
            UserKey=~/.ssh/ops_ed25519
            Passphrase=key-passphrase
            """,
            sourceType: .xShell,
            sourceName: "Production__API.xsh"
        )

        XCTAssertEqual(payload.sessions[0].name, "API")
        XCTAssertEqual(payload.sessions[0].folderPath, "Production")
        XCTAssertEqual(payload.sessions[0].privateKeyPath, "~/.ssh/ops_ed25519")
        XCTAssertEqual(payload.sessions[0].credential, .privateKeyPassphrase("key-passphrase"))
    }

    func testXshellDirectoryImportsAllFilesUsingRelativeFolders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let group = root.appendingPathComponent("Production/Web", isDirectory: true)
        try FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "[CONNECTION]\nHost=web.example.com\nPort=22\nUserName=deploy\n"
            .write(to: group.appendingPathComponent("Web.xsh"), atomically: true, encoding: .utf8)

        let payload = try ExternalSessionImportParser.parseDirectory(
            root,
            sourceType: .xShell,
            sourceName: "Xshell Sessions"
        )

        XCTAssertEqual(payload.sessions.map(\.name), ["Web"])
        XCTAssertEqual(payload.sessions.map(\.folderPath), ["Production/Web"])
    }

    func testWindTermImportsMultipleSessionsAndGroups() throws {
        let payload = try ExternalSessionImportParser.parseText(
            """
            [
              {"session.protocol":"SSH","session.target":"deploy@web.example.com","session.label":"Web","session.port":22,"session.group":"Production>Web","session.password":"pw1"},
              {"session.protocol":"SSH","session.target":"root@db.example.com","session.label":"DB","session.port":2201,"session.group":"Production>DB"}
            ]
            """,
            sourceType: .windTerm,
            sourceName: "sessions.sessions"
        )

        XCTAssertEqual(payload.sessions.map(\.name), ["Web", "DB"])
        XCTAssertEqual(payload.sessions.map(\.folderPath), ["Production/Web", "Production/DB"])
        XCTAssertEqual(payload.sessions[0].credential, .password("pw1"))
    }

    func testSecureCRTImportsNestedSSHSession() throws {
        let payload = try ExternalSessionImportParser.parseText(
            """
            <key name="Sessions"><key name="Production"><key name="API">
              <string name="Protocol Name">SSH2</string>
              <string name="Hostname">api.example.com</string>
              <dword name="[SSH2] Port">2222</dword>
              <string name="Username">deploy</string>
              <string name="Password V2">plain-secret</string>
            </key></key></key>
            """,
            sourceType: .secureCRT,
            sourceName: "Sessions.xml"
        )

        XCTAssertEqual(payload.sessions[0].folderPath, "Production")
        XCTAssertEqual(payload.sessions[0].name, "API")
        XCTAssertEqual(payload.sessions[0].credential, .password("plain-secret"))
    }

    func testElectermImportsBookmarkGroupsAndCredentials() throws {
        let payload = try ExternalSessionImportParser.parseText(
            """
            {
              "bookmarkGroups":[{"id":"prod","title":"Production","bookmarkIds":["api"]}],
              "bookmarks":[{"id":"api","title":"API","host":"api.example.com","username":"deploy","password":"pw","port":22,"type":"ssh","enableSsh":true}]
            }
            """,
            sourceType: .electerm,
            sourceName: "electerm.json"
        )

        XCTAssertEqual(payload.sessions[0].folderPath, "Production")
        XCTAssertEqual(payload.sessions[0].credential, .password("pw"))
    }

    func testFinalShellImportsDirectoryAndParentGroup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try #"{"id":"prod","name":"Production","parent_id":"root","delete_time":0}"#
            .write(to: root.appendingPathComponent("folder.json"), atomically: true, encoding: .utf8)
        try #"{"name":"API","host":"api.example.com","port":2222,"user_name":"deploy","parent_id":"prod","conection_type":100,"password":"pw","delete_time":0}"#
            .write(to: root.appendingPathComponent("api_connect_config.json"), atomically: true, encoding: .utf8)

        let payload = try ExternalSessionImportParser.parseDirectory(
            root,
            sourceType: .finalShell,
            sourceName: "conn"
        )

        XCTAssertEqual(payload.sessions[0].folderPath, "Production")
        XCTAssertEqual(payload.sessions[0].credential, .password("pw"))
    }

    func testTermiusJSONImportsGroupPasswordAndPrivateKeyPassphrase() throws {
        let payload = try ExternalSessionImportParser.parseText(
            """
            {
              "groups":[{"id":"prod","label":"Production"}],
              "hosts":[
                {"label":"API","address":"api.example.com","username":"deploy","password":"pw","group_id":"prod","port":22},
                {"label":"Bastion","address":"bastion.example.com","username":"ops","private_key_path":"~/.ssh/bastion","passphrase":"key-pass","group_id":"prod","port":2222}
              ]
            }
            """,
            sourceType: .termius,
            sourceName: "termius.json"
        )

        XCTAssertEqual(payload.sessions.map(\.folderPath), ["Production", "Production"])
        XCTAssertEqual(payload.sessions[0].credential, .password("pw"))
        XCTAssertEqual(payload.sessions[1].privateKeyPath, "~/.ssh/bastion")
        XCTAssertEqual(payload.sessions[1].credential, .privateKeyPassphrase("key-pass"))
    }
}
