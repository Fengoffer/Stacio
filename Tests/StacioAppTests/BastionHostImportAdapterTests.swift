import XCTest
@testable import StacioApp

final class BastionHostImportAdapterTests: XCTestCase {
    func testManifestMapsGatewayConnectionAndPreservesTargetMetadata() throws {
        let payload = try BastionHostImportAdapter.parseManifest(
            """
            {
              "format": "stacio.bastion.v1",
              "vendor": "天融信",
              "sessions": [{
                "name": "生产数据库",
                "protocol": "ssh",
                "gatewayHost": "bastion.example.com",
                "gatewayPort": 60022,
                "gatewayUsername": "SSH@dba@10.0.0.8",
                "targetHost": "10.0.0.8",
                "targetPort": 22,
                "targetUsername": "dba",
                "assetId": "asset-8",
                "accountId": "account-dba",
                "folderPath": "生产/数据库"
              }]
            }
            """
        )

        let session = try XCTUnwrap(payload.sessions.first)
        XCTAssertEqual(session.host, "bastion.example.com")
        XCTAssertEqual(session.port, 60022)
        XCTAssertEqual(session.username, "SSH@dba@10.0.0.8")
        XCTAssertEqual(session.folderPath, "生产/数据库")
        let config = try XCTUnwrap(session.configJSON)
        XCTAssertTrue(config.contains("\"bastionVendor\":\"topsec\""))
        XCTAssertTrue(config.contains("\"bastionTargetHost\":\"10.0.0.8\""))
        XCTAssertTrue(config.contains("\"bastionAssetId\":\"asset-8\""))
    }

    func testManifestRejectsSecretsAndExecutableFields() {
        for forbidden in ["password", "token", "privateKey", "command", "script"] {
            let text = """
            {
              "format":"stacio.bastion.v1",
              "vendor":"custom",
              "sessions":[{
                "name":"Asset",
                "protocol":"ssh",
                "gatewayHost":"bastion.example.com",
                "gatewayPort":22,
                "gatewayUsername":"user@asset@gateway",
                "\(forbidden)":"unsafe"
              }]
            }
            """
            XCTAssertThrowsError(try BastionHostImportAdapter.parseManifest(text), forbidden)
        }
    }

    func testVendorCatalogRecognizesRequestedDomesticVendors() {
        XCTAssertEqual(BastionHostVendor.identify("天融信"), .topsec)
        XCTAssertEqual(BastionHostVendor.identify("深信服"), .sangfor)
        XCTAssertEqual(BastionHostVendor.identify("奇安信"), .qianxin)
        XCTAssertEqual(BastionHostVendor.identify("360"), .qihoo360)
        XCTAssertEqual(BastionHostVendor.identify("安恒"), .dbappsecurity)
    }

    func testDetectedVendorMetadataIsAddedToStandardClientPayload() throws {
        let source = ExternalSessionImportPayload(
            sessions: [
                ExternalImportedSession(
                    name: "Asset",
                    folderPath: nil,
                    protocolName: "ssh",
                    host: "bastion.example.com",
                    port: 22,
                    username: "user@asset@gateway",
                    privateKeyPath: nil,
                    credential: nil
                )
            ],
            warnings: []
        )
        let enriched = BastionHostImportAdapter.addingDetectedVendorMetadata(
            to: source,
            sourceName: "深信服堡垒机会话.xsh",
            contents: ""
        )
        XCTAssertTrue(try XCTUnwrap(enriched.sessions.first?.configJSON).contains("sangfor"))
    }
}
