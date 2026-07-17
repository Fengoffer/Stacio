import AppKit
import XCTest
import StacioCoreBindings
@testable import StacioApp

@MainActor
final class SessionIconCatalogTests: XCTestCase {
    func testCatalogContainsEveryPackagedIconAndSeparatesGroups() {
        XCTAssertEqual(SessionIconCatalog.all.count, 23)
        XCTAssertTrue(SessionIconCatalog.operatingSystems.contains { $0.id == "ubuntu" })
        XCTAssertTrue(SessionIconCatalog.operatingSystems.contains { $0.id == "linux-generic" })
        XCTAssertTrue(SessionIconCatalog.cloudPlatforms.contains { $0.id == "aliyun" })
        XCTAssertTrue(SessionIconCatalog.cloudPlatforms.contains { $0.id == "raincloud" })
    }

    func testSearchMatchesChineseNameAndEnglishAlias() {
        XCTAssertEqual(SessionIconCatalog.matching("阿里").map(\.id), ["aliyun"])
        XCTAssertEqual(SessionIconCatalog.matching("amazon").map(\.id), ["amazon-cloud"])
    }

    func testCatalogLoadsSVGAndPNGImages() throws {
        let ubuntu = try XCTUnwrap(SessionIconCatalog.image(for: "ubuntu", size: NSSize(width: 18, height: 18)))
        let raincloud = try XCTUnwrap(SessionIconCatalog.image(for: "raincloud", size: NSSize(width: 18, height: 18)))

        XCTAssertEqual(ubuntu.size, NSSize(width: 18, height: 18))
        XCTAssertEqual(ubuntu.accessibilityDescription, "Ubuntu")
        XCTAssertEqual(raincloud.accessibilityDescription, "雨云")
    }

    func testCatalogLoadsFromPackagedMainBundleLayoutWithoutSwiftPMResourceBundle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioSessionIconBundleTests-\(UUID().uuidString).bundle", isDirectory: true)
        let contents = root.appendingPathComponent("Contents", isDirectory: true)
        let resources = contents
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("SessionIcons", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "cn.stacio.tests.session-icons.\(UUID().uuidString)",
            "CFBundlePackageType": "BNDL"
        ]
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try plistData.write(to: contents.appendingPathComponent("Info.plist"))
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Stacio/Resources/SessionIcons/ubuntu.svg")
        try FileManager.default.copyItem(
            at: source,
            to: resources.appendingPathComponent("ubuntu.svg")
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let bundle = try XCTUnwrap(Bundle(url: root))

        let image = try XCTUnwrap(
            SessionIconCatalog.image(
                for: "ubuntu",
                size: NSSize(width: 18, height: 18),
                bundle: bundle
            )
        )

        XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
        XCTAssertEqual(image.accessibilityDescription, "Ubuntu")
    }

    func testCodecPreservesExistingConfigWhenSavingIcon() throws {
        let json = try XCTUnwrap(SessionIconConfigCodec.updatingIconID(
            "ubuntu",
            in: #"{"startupCommand":"pwd"}"#
        ))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])

        XCTAssertEqual(object["sessionIconID"] as? String, "ubuntu")
        XCTAssertEqual(object["startupCommand"] as? String, "pwd")
    }

    func testCodecRemovesIconWithoutDroppingOtherConfig() throws {
        let json = try XCTUnwrap(SessionIconConfigCodec.updatingIconID(
            nil,
            in: #"{"sessionIconID":"ubuntu","environment":"production"}"#
        ))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])

        XCTAssertNil(object["sessionIconID"])
        XCTAssertEqual(object["environment"] as? String, "production")
    }

    func testCodecReturnsNilWhenClearingTheOnlyConfigValue() throws {
        XCTAssertNil(try SessionIconConfigCodec.updatingIconID(
            nil,
            in: #"{"sessionIconID":"ubuntu"}"#
        ))
    }

    func testCodecRejectsUnknownStoredIconID() {
        XCTAssertNil(SessionIconConfigCodec.iconID(from: #"{"sessionIconID":"removed-icon"}"#))
        XCTAssertNil(SessionIconConfigCodec.iconID(from: "{broken"))
    }

    func testUnknownLinuxFallsBackToGenericLinuxIcon() {
        XCTAssertEqual(
            SessionIconCatalog.iconID(for: remoteOS(id: "unknown", kernelName: "Linux")),
            "linux-generic"
        )
    }

    func testKnownOperatingSystemsUseSpecificIcons() {
        XCTAssertEqual(SessionIconCatalog.iconID(for: remoteOS(id: "ubuntu", kernelName: "Linux")), "ubuntu")
        XCTAssertEqual(SessionIconCatalog.iconID(for: remoteOS(id: "anolis", kernelName: "Linux")), "anolis")
        XCTAssertNil(SessionIconCatalog.iconID(for: remoteOS(id: "darwin", kernelName: "Darwin")))
    }

    private func remoteOS(id: String, kernelName: String) -> RemoteOperatingSystemInfo {
        RemoteOperatingSystemInfo(
            id: id,
            idLike: [],
            name: id,
            prettyName: id,
            version: "",
            versionId: "",
            kernelName: kernelName,
            kernelRelease: "",
            architecture: "x86_64"
        )
    }
}
