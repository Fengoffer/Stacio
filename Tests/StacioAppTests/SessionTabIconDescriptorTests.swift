import AppKit
import XCTest
import StacioCoreBindings
@testable import StacioApp

@MainActor
final class SessionTabIconDescriptorTests: XCTestCase {
    func testBluetoothConsoleIconProvidesReusableTemplateImage() throws {
        let image = try XCTUnwrap(
            StacioSymbolImage.image(
                named: "bluetooth",
                accessibilityDescription: "蓝牙 Console",
                size: NSSize(width: 18, height: 18)
            )
        )

        XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.accessibilityDescription, "蓝牙 Console")
        XCTAssertFalse(try XCTUnwrap(image.tiffRepresentation).isEmpty)
    }

    func testConsoleUsesNativeBluetoothSymbolInSidebarAndTab() {
        let sidebarIcon = SessionSidebarViewController.sessionProtocolIconDescriptor(for: " Console ")
        let tabIcon = SessionTabIconDescriptor.console

        XCTAssertEqual(sidebarIcon.symbolName, "bluetooth")
        XCTAssertEqual(sidebarIcon.accessibilityDescription, "蓝牙 Console")
        XCTAssertEqual(tabIcon.identifier, "console-default")
        XCTAssertEqual(tabIcon.systemSymbolName, "bluetooth")
        XCTAssertEqual(tabIcon.accessibilityLabel, "蓝牙 Console")
        XCTAssertNotNil(tabIcon.image())
    }

    func testMapsUbuntuReleaseToUbuntuIcon() {
        let descriptor = SessionTabIconDescriptor.operatingSystem(remoteOS(
            id: "ubuntu",
            idLike: ["debian"],
            prettyName: "Ubuntu 24.04 LTS",
            versionID: "24.04"
        ))

        XCTAssertEqual(descriptor.identifier, "ubuntu")
        XCTAssertTrue(descriptor.accessibilityLabel.contains("Ubuntu 24.04 LTS"))
    }

    func testMapsCentOSSevenReleaseToCentOSIcon() {
        let descriptor = SessionTabIconDescriptor.operatingSystem(remoteOS(
            id: "",
            idLike: ["rhel", "fedora"],
            name: "CentOS Linux",
            prettyName: "CentOS Linux 7 (Core)",
            versionID: "7"
        ))

        XCTAssertEqual(descriptor.identifier, "centos")
        XCTAssertEqual(descriptor.shortLabel, "C")
    }

    func testFallsBackToGenericLinuxIconForUnknownLinux() {
        let descriptor = SessionTabIconDescriptor.operatingSystem(remoteOS(
            id: "",
            idLike: [],
            name: "Unknown Linux",
            prettyName: "Linux",
            versionID: ""
        ))

        XCTAssertEqual(descriptor.identifier, "linux")
        XCTAssertEqual(descriptor.shortLabel, "LNX")
    }

    func testMapsVNCGraphicsSessionToRemoteDesktopIcon() {
        let descriptor = SessionTabIconDescriptor.graphicsProtocol("VNC")

        XCTAssertEqual(descriptor.identifier, "vnc-default")
        XCTAssertEqual(descriptor.accessibilityLabel, "VNC 远程桌面")
        XCTAssertEqual(descriptor.shortLabel, "VNC")
    }

    func testUnknownGraphicsProtocolUsesGenericGraphicsIcon() {
        let descriptor = SessionTabIconDescriptor.graphicsProtocol("X11")

        XCTAssertEqual(descriptor.identifier, "graphics-default")
        XCTAssertEqual(descriptor.accessibilityLabel, "X11 图形会话")
        XCTAssertEqual(descriptor.shortLabel, "X11")
    }

    private func remoteOS(
        id: String,
        idLike: [String],
        name: String = "",
        prettyName: String,
        versionID: String
    ) -> RemoteOperatingSystemInfo {
        RemoteOperatingSystemInfo(
            id: id,
            idLike: idLike,
            name: name,
            prettyName: prettyName,
            version: versionID,
            versionId: versionID,
            kernelName: "Linux",
            kernelRelease: "6.8.0",
            architecture: "x86_64"
        )
    }
}
