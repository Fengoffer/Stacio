import XCTest

final class PackageManifestTests: XCTestCase {
    func testSwiftTermPinsUpstreamCellSpacingFixRevision() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let manifest = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        let resolved = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Package.resolved"),
            encoding: .utf8
        )
        let revision = "87a7888edc0ae415922174e4e6c0486f3991e0ea"

        XCTAssertTrue(manifest.contains("https://github.com/migueldeicaza/SwiftTerm.git"))
        XCTAssertTrue(manifest.contains("revision: \"\(revision)\""))
        XCTAssertTrue(resolved.contains("\"revision\" : \"\(revision)\""))
    }

    func testManifestLinksCoreBluetoothForStacioApp() throws {
        let manifestURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Package.swift")
        let manifest = try String(contentsOf: manifestURL, encoding: .utf8)

        XCTAssertTrue(manifest.contains(".linkedFramework(\"CoreBluetooth\")"))
    }

    func testManifestDoesNotExposeRemovedRDPAdapterProduct() throws {
        let manifestURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Package.swift")
        let manifest = try String(contentsOf: manifestURL, encoding: .utf8)

        XCTAssertFalse(manifest.contains("StacioRDPAdapter"))
        XCTAssertFalse(manifest.contains("StacioAdapters/RDP"))
        XCTAssertTrue(manifest.contains("StacioVNCAdapter"))
        XCTAssertTrue(manifest.contains("StacioAdapters/VNC"))
    }

    func testManifestUsesSparkleTwoAndDocumentsPackagingConfiguration() throws {
        let manifestURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let packageManifestURL = manifestURL.appendingPathComponent("Package.swift")
        let packageScriptURL = manifestURL.appendingPathComponent("scripts/package-app.sh")
        let packageManifest = try String(contentsOf: packageManifestURL, encoding: .utf8)
        let script = try String(contentsOf: packageScriptURL, encoding: .utf8)

        XCTAssertTrue(packageManifest.contains("https://github.com/sparkle-project/Sparkle.git"))
        XCTAssertTrue(packageManifest.contains(".product(name: \"Sparkle\", package: \"Sparkle\")"))
        XCTAssertTrue(script.contains("STACIO_SPARKLE_STABLE_APPCAST_URL"))
        XCTAssertTrue(script.contains("/stable/$SPARKLE_UPDATE_ARCHITECTURE/appcast.xml"))
        XCTAssertTrue(script.contains("Sparkle.framework"))
        XCTAssertTrue(script.contains("@executable_path/../Frameworks"))
        XCTAssertTrue(script.contains("SUPublicEDKey"))
        XCTAssertTrue(script.contains("SUEnableAutomaticChecks"))
    }
}
