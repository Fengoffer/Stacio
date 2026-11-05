import AppKit
import Foundation
import StacioCoreBindings
import XCTest
@testable import StacioApp

final class EmbeddedRDPGraphicsSessionTests: XCTestCase {
    func testStartRejectsLegacyRDPSecurityBeforeConnecting() {
        let client = RecordingRdpSession()
        let session = makeSession(
            options: EmbeddedRDPSessionOptions(
                host: "127.0.0.1",
                port: 9,
                user: "tester",
                password: "secret",
                security: .rdp
            ),
            rdpSessionFactory: { client }
        )
        defer { session.stop() }

        XCTAssertThrowsError(try session.start()) { error in
            XCTAssertTrue(
                errorDescription(error).contains("不支持传统 RDP 安全模式"),
                "unexpected error: \(errorDescription(error))"
            )
        }
        XCTAssertEqual(client.connectCount, 0)
    }

    func testStartRejectsDriveWithoutNamePathSeparatorBeforeConnecting() {
        assertStartRejectsDrive("Shared", expectedMessage: "名称:本地目录")
    }

    func testStartRejectsDriveWithEmptyNameBeforeConnecting() {
        assertStartRejectsDrive(":/tmp", expectedMessage: "驱动器名称不能为空")
    }

    func testStartRejectsMissingDriveDirectoryBeforeConnecting() {
        let missingPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("stacio-rdp-missing-\(UUID().uuidString)")
            .path
        assertStartRejectsDrive("Shared:\(missingPath)", expectedMessage: "本地目录不存在")
    }

    func testStartRejectsDrivePathThatIsNotDirectoryBeforeConnecting() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stacio-rdp-drive-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let fileURL = temporaryDirectory.appendingPathComponent("not-a-directory.txt")
        try Data("not a directory".utf8).write(to: fileURL)
        assertStartRejectsDrive("Shared:\(fileURL.path)", expectedMessage: "不是目录")
    }

    func testStartRejectsUnsafeDriveNameBeforeConnecting() {
        let client = RecordingRdpSession()
        let session = makeSession(
            options: EmbeddedRDPSessionOptions(
                host: "127.0.0.1",
                port: 9,
                user: "tester",
                password: "secret",
                drive: "../escape:/tmp"
            ),
            rdpSessionFactory: { client }
        )
        defer { session.stop() }

        XCTAssertThrowsError(try session.start()) { error in
            XCTAssertTrue(
                errorDescription(error).contains("驱动器名称只允许"),
                "unexpected error: \(errorDescription(error))"
            )
        }
        XCTAssertEqual(client.connectCount, 0)
    }

    func testStartRejectsDesktopDimensionAboveLimitBeforeConnecting() {
        let client = RecordingRdpSession()
        let session = makeSession(
            options: EmbeddedRDPSessionOptions(
                host: "127.0.0.1",
                port: 9,
                user: "tester",
                password: "secret",
                width: 8_193,
                height: 1
            ),
            rdpSessionFactory: { client }
        )
        defer { session.stop() }

        XCTAssertThrowsError(try session.start()) { error in
            XCTAssertTrue(
                errorDescription(error).contains("分辨率"),
                "unexpected error: \(errorDescription(error))"
            )
        }
        XCTAssertEqual(client.connectCount, 0)
    }

    func testStartPassesQualitySecurityCertificateAndCanonicalDriveToRustClient() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stacio-rdp-connect-test-\(UUID().uuidString)", isDirectory: true)
        let sharedDirectory = temporaryDirectory.appendingPathComponent("shared", isDirectory: true)
        let symlink = temporaryDirectory.appendingPathComponent("shared-link", isDirectory: true)
        try FileManager.default.createDirectory(at: sharedDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: sharedDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let client = RecordingRdpSession()
        let session = makeSession(
            options: EmbeddedRDPSessionOptions(
                host: "rdp.example.test",
                port: 3390,
                user: "Administrator",
                password: "secret",
                domain: "CORP",
                width: 1920,
                height: 1080,
                quality: 2,
                ignoreCert: true,
                security: .tls,
                drive: "Shared:\(symlink.path)"
            ),
            rdpSessionFactory: { client }
        )
        defer { session.stop() }

        try session.start()

        XCTAssertEqual(client.connectCount, 1)
        XCTAssertEqual(client.host, "rdp.example.test")
        XCTAssertEqual(client.port, 3390)
        XCTAssertEqual(client.username, "Administrator")
        XCTAssertEqual(client.domain, "CORP")
        XCTAssertEqual(client.width, 1920)
        XCTAssertEqual(client.height, 1080)
        XCTAssertEqual(client.quality, 2)
        XCTAssertEqual(client.security, .tls)
        XCTAssertTrue(client.ignoreCertificate)
        XCTAssertEqual(client.driveName, "Shared")
        XCTAssertEqual(client.drivePath, sharedDirectory.resolvingSymlinksInPath().path)
    }

    func testClipboardPasteInputUsesRDPClipboardBridge() throws {
        let client = RecordingRdpSession()
        let session = makeSession(
            options: EmbeddedRDPSessionOptions(
                host: "rdp.example.test",
                port: 3389,
                user: "tester",
                password: "secret"
            ),
            rdpSessionFactory: { client }
        )
        defer { session.stop() }
        try session.start()

        session.sendInput(.clipboardTextPaste("Mac → Windows"))

        XCTAssertEqual(client.clipboardTexts, ["Mac → Windows"])
    }

    func testLocalPasteboardChangeIsAdvertisedAutomatically() throws {
        let pasteboard = NSPasteboard.general
        let originalText = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let originalText {
                pasteboard.setString(originalText, forType: .string)
            }
        }
        pasteboard.clearContents()
        pasteboard.setString("before RDP session", forType: .string)

        let advertised = expectation(description: "local clipboard advertised to RDP")
        let client = RecordingRdpSession()
        client.clipboardTextHandler = { text in
            if text == "Mac → Windows automatically" {
                advertised.fulfill()
            }
        }
        let session = makeSession(
            options: EmbeddedRDPSessionOptions(
                host: "rdp.example.test",
                port: 3389,
                user: "tester",
                password: "secret"
            ),
            rdpSessionFactory: { client }
        )
        try session.start()
        defer { session.stop() }
        session.setClipboardSynchronizationEnabled(true)

        pasteboard.clearContents()
        pasteboard.setString("Mac → Windows automatically", forType: .string)

        wait(for: [advertised], timeout: 1.5)
    }

    func testInactiveSessionDoesNotAdvertiseLocalPasteboard() throws {
        let pasteboard = NSPasteboard.general
        let originalText = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let originalText {
                pasteboard.setString(originalText, forType: .string)
            }
        }
        pasteboard.clearContents()
        pasteboard.setString("before inactive RDP session", forType: .string)

        let unexpected = expectation(description: "inactive RDP clipboard is not advertised")
        unexpected.isInverted = true
        let client = RecordingRdpSession()
        client.clipboardTextHandler = { text in
            if text == "must not leave inactive RDP session" {
                unexpected.fulfill()
            }
        }
        let session = makeSession(
            options: EmbeddedRDPSessionOptions(
                host: "rdp.example.test",
                port: 3389,
                user: "tester",
                password: "secret"
            ),
            rdpSessionFactory: { client }
        )
        try session.start()
        defer { session.stop() }

        pasteboard.clearContents()
        pasteboard.setString("must not leave inactive RDP session", forType: .string)

        wait(for: [unexpected], timeout: 0.8)
    }

    func testInactiveSessionDoesNotForwardRemoteClipboard() throws {
        let unexpected = expectation(description: "inactive RDP remote clipboard is ignored")
        unexpected.isInverted = true
        let client = RecordingRdpSession()
        let session = makeSession(
            options: EmbeddedRDPSessionOptions(
                host: "rdp.example.test",
                port: 3389,
                user: "tester",
                password: "secret"
            ),
            rdpSessionFactory: { client }
        )
        session.onClipboard = { _ in unexpected.fulfill() }
        try session.start()
        defer { session.stop() }

        client.delegate?.onClipboard(text: "must not enter inactive Mac session")

        wait(for: [unexpected], timeout: 0.2)
    }

    func testRemoteClipboardWrittenToPasteboardIsNotAdvertisedBack() throws {
        let pasteboard = NSPasteboard.general
        let originalText = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let originalText {
                pasteboard.setString(originalText, forType: .string)
            }
        }
        pasteboard.clearContents()
        pasteboard.setString("before remote clipboard", forType: .string)

        let echoed = expectation(description: "remote clipboard is not echoed to RDP")
        echoed.isInverted = true
        let client = RecordingRdpSession()
        client.clipboardTextHandler = { text in
            if text == "Windows → Mac without echo" {
                echoed.fulfill()
            }
        }
        let session = makeSession(
            options: EmbeddedRDPSessionOptions(
                host: "rdp.example.test",
                port: 3389,
                user: "tester",
                password: "secret"
            ),
            rdpSessionFactory: { client }
        )
        session.onClipboard = { text in
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
        try session.start()
        defer { session.stop() }
        session.setClipboardSynchronizationEnabled(true)

        client.delegate?.onClipboard(text: "Windows → Mac without echo")

        wait(for: [echoed], timeout: 1.1)
        XCTAssertFalse(client.clipboardTexts.contains("Windows → Mac without echo"))
    }

    func testOversizedClipboardPasteIsNotPassedAcrossRDPBridge() throws {
        let client = RecordingRdpSession()
        let session = makeSession(
            options: EmbeddedRDPSessionOptions(
                host: "rdp.example.test",
                port: 3389,
                user: "tester",
                password: "secret"
            ),
            rdpSessionFactory: { client }
        )
        defer { session.stop() }
        try session.start()

        session.sendInput(.clipboardTextPaste(String(repeating: "x", count: 1_048_577)))

        XCTAssertTrue(client.clipboardTexts.isEmpty)
    }

    func testOversizedResizeIsNotPassedAcrossRDPBridge() throws {
        let client = RecordingRdpSession()
        let session = makeSession(
            options: EmbeddedRDPSessionOptions(
                host: "rdp.example.test",
                port: 3389,
                user: "tester",
                password: "secret"
            ),
            rdpSessionFactory: { client }
        )
        defer { session.stop() }
        try session.start()

        session.sendInput(.resize(width: 8_193, height: 1, scaleFactor: 1))

        XCTAssertTrue(client.resizeRequests.isEmpty)
    }

    func testScrollInputClampsToInt32BeforeCrossingRDPBridge() throws {
        let client = RecordingRdpSession()
        let session = makeSession(
            options: EmbeddedRDPSessionOptions(
                host: "rdp.example.test",
                port: 3389,
                user: "tester",
                password: "secret"
            ),
            rdpSessionFactory: { client }
        )
        defer { session.stop() }
        try session.start()

        session.sendInput(.scroll(deltaX: Int.max, deltaY: Int.min, x: 0, y: 0))

        XCTAssertEqual(client.scrollEvents.map(\.delta), [Int32.min, Int32.max])
        XCTAssertEqual(client.scrollEvents.map(\.horizontal), [false, true])
    }

    func testExtendedKeyInputPreservesE0PrefixAcrossRDPBridge() throws {
        let client = RecordingRdpSession()
        let session = makeSession(
            options: EmbeddedRDPSessionOptions(
                host: "rdp.example.test",
                port: 3389,
                user: "tester",
                password: "secret"
            ),
            rdpSessionFactory: { client }
        )
        defer { session.stop() }
        try session.start()

        session.sendInput(.key(scancode: 0x4B, isExtended: true, isPressed: true))
        session.sendInput(.key(scancode: 0x1E, isExtended: false, isPressed: false))

        XCTAssertEqual(client.keyEvents.count, 2)
        XCTAssertEqual(client.keyEvents[0].scancode, 0xE04B)
        XCTAssertTrue(client.keyEvents[0].down)
        XCTAssertEqual(client.keyEvents[1].scancode, 0x001E)
        XCTAssertFalse(client.keyEvents[1].down)
    }

    func testUnicodeTextInputSendsPressAndReleaseForEveryScalar() throws {
        let client = RecordingRdpSession()
        let session = makeSession(
            options: EmbeddedRDPSessionOptions(
                host: "rdp.example.test",
                port: 3389,
                user: "tester",
                password: "secret"
            ),
            rdpSessionFactory: { client }
        )
        defer { session.stop() }
        try session.start()

        session.sendInput(.unicodeText("中🚀"))

        XCTAssertEqual(client.unicodeEvents.map(\.character), ["中", "中", "🚀", "🚀"])
        XCTAssertEqual(client.unicodeEvents.map(\.down), [true, false, true, false])
    }

    func testExtendedMouseButtonsReachRDPButtonMask() throws {
        let client = RecordingRdpSession()
        let session = makeSession(
            options: EmbeddedRDPSessionOptions(
                host: "rdp.example.test",
                port: 3389,
                user: "tester",
                password: "secret"
            ),
            rdpSessionFactory: { client }
        )
        defer { session.stop() }
        try session.start()

        session.sendInput(.mouseButton(button: .x1, isPressed: true, x: 1, y: 2))
        session.sendInput(.mouseButton(button: .x2, isPressed: true, x: 1, y: 2))
        session.sendInput(.mouseButton(button: .x1, isPressed: false, x: 1, y: 2))

        XCTAssertEqual(client.pointerEvents.map(\.buttons), [0b1_000, 0b11_000, 0b10_000])
    }

    func testDelegateForwardsRemoteClipboardText() throws {
        let client = RecordingRdpSession()
        let session = makeSession(
            options: EmbeddedRDPSessionOptions(
                host: "rdp.example.test",
                port: 3389,
                user: "tester",
                password: "secret"
            ),
            rdpSessionFactory: { client }
        )
        defer { session.stop() }
        var received: [String] = []
        session.onClipboard = { received.append($0) }
        try session.start()
        session.setClipboardSynchronizationEnabled(true)

        client.delegate?.onClipboard(text: "Windows → Mac")

        XCTAssertEqual(received, ["Windows → Mac"])
    }

    func testFirstFrameRetainsConnectedLifecycleStateBeforeCallbackRegistration() throws {
        let client = RecordingRdpSession()
        let session = makeSession(
            options: EmbeddedRDPSessionOptions(
                host: "rdp.example.test",
                port: 3389,
                user: "tester",
                password: "secret"
            ),
            rdpSessionFactory: { client }
        )
        try session.start()
        defer { session.stop() }

        client.delegate?.onFrame(
            desktopWidth: 2,
            desktopHeight: 1,
            x: 0,
            y: 0,
            width: 2,
            height: 1,
            bgra: Data(repeating: 0, count: 8)
        )

        XCTAssertEqual(
            session.lifecycleState,
            .connected(width: 2, height: 1, name: "RDP Desktop")
        )
    }

    func testDisconnectedEventIsRetainedBeforeCallbackRegistration() throws {
        let client = RecordingRdpSession()
        let session = makeSession(
            options: EmbeddedRDPSessionOptions(
                host: "rdp.example.test",
                port: 3389,
                user: "tester",
                password: "secret"
            ),
            rdpSessionFactory: { client }
        )
        try session.start()

        client.delegate?.onDisconnected(reason: "early RDP disconnect")

        XCTAssertEqual(
            session.lifecycleState,
            .disconnected(reason: "early RDP disconnect")
        )
    }

    func testDelegateForwardsMeasuredRDPNetworkStatus() throws {
        let client = RecordingRdpSession()
        let session = makeSession(
            options: EmbeddedRDPSessionOptions(
                host: "rdp.example.test",
                port: 3389,
                user: "tester",
                password: "secret"
            ),
            rdpSessionFactory: { client }
        )
        defer { session.stop() }
        var received: [(rttMs: Int, mode: String)] = []
        session.onNetworkStatus = { received.append(($0, $1)) }
        try session.start()

        client.delegate?.onNetworkStatus(rttMs: 187, mode: "poor")

        XCTAssertEqual(received.map(\.rttMs), [187])
        XCTAssertEqual(received.map(\.mode), ["poor"])
        XCTAssertEqual(client.qualityChanges, [5])
    }

    func testMeasuredRDPNetworkStatusDisablesFrameCadenceFallback() throws {
        var now: TimeInterval = 0
        let client = RecordingRdpSession()
        let session = makeSession(
            options: EmbeddedRDPSessionOptions(
                host: "rdp.example.test",
                port: 3389,
                user: "tester",
                password: "secret"
            ),
            frameClock: { now },
            rdpSessionFactory: { client }
        )
        try session.start()
        defer { session.stop() }
        var modes: [String] = []
        session.onNetworkStatus = { _, mode in modes.append(mode) }

        client.delegate?.onNetworkStatus(rttMs: 187, mode: "poor")
        session.handleFrame(width: 1, height: 1, bgra: Data(repeating: 0, count: 4))
        for index in 1...4 {
            now += 0.1
            session.handleFrame(
                width: 1,
                height: 1,
                bgra: Data(repeating: UInt8(index), count: 4)
            )
        }

        XCTAssertEqual(modes, ["poor"])
    }

    func testDelegateForwardsPointerBitmapGeometryHotspotAndRGBA() throws {
        let client = RecordingRdpSession()
        let session = makeSession(
            options: EmbeddedRDPSessionOptions(
                host: "rdp.example.test",
                port: 3389,
                user: "tester",
                password: "secret"
            ),
            rdpSessionFactory: { client }
        )
        defer { session.stop() }
        var received: [GraphicsPointerBitmap] = []
        session.onPointerBitmap = { received.append($0) }
        try session.start()

        client.delegate?.onPointerBitmap(
            width: 2,
            height: 1,
            hotspotX: 1,
            hotspotY: 0,
            rgba: Data([1, 2, 3, 4, 5, 6, 7, 8])
        )

        XCTAssertEqual(
            received,
            [
                GraphicsPointerBitmap(
                    width: 2,
                    height: 1,
                    hotspotX: 1,
                    hotspotY: 0,
                    rgbaPixels: Data([1, 2, 3, 4, 5, 6, 7, 8])
                )
            ]
        )
    }

    func testFrameThrottleUsesLastDeliveredFrameInsteadOfLastReceivedFrame() {
        var now: TimeInterval = 0
        let session = makeSession(frameClock: { now })
        var deliveredFrames = 0
        session.onFrame = { _ in deliveredFrames += 1 }

        session.handleFrame(width: 1, height: 1, bgra: Data(repeating: 0, count: 4))
        XCTAssertEqual(deliveredFrames, 1)

        now = 1.0 / 60.0
        session.handleFrame(width: 1, height: 1, bgra: Data(repeating: 1, count: 4))
        XCTAssertEqual(deliveredFrames, 1)

        now = 1.0 / 30.0
        session.handleFrame(width: 1, height: 1, bgra: Data(repeating: 2, count: 4))
        XCTAssertEqual(deliveredFrames, 2)
    }

    func testThrottledDirtyRegionsRemainInNextDeliveredCanvas() {
        var now: TimeInterval = 0
        let session = makeSession(frameClock: { now })
        var frames: [GraphicsFrame] = []
        session.onFrame = { frames.append($0) }

        session.handleFrame(
            desktopWidth: 2,
            desktopHeight: 1,
            x: 0,
            y: 0,
            width: 1,
            height: 1,
            bgra: Data([0x00, 0x00, 0xFF, 0xFF])
        )
        now = 1.0 / 60.0
        session.handleFrame(
            desktopWidth: 2,
            desktopHeight: 1,
            x: 1,
            y: 0,
            width: 1,
            height: 1,
            bgra: Data([0x00, 0xFF, 0x00, 0xFF])
        )
        now = 1.0 / 30.0
        session.handleFrame(
            desktopWidth: 2,
            desktopHeight: 1,
            x: 0,
            y: 0,
            width: 1,
            height: 1,
            bgra: Data([0xFF, 0x00, 0x00, 0xFF])
        )

        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(
            frames.last?.pixels,
            Data([
                0xFF, 0x00, 0x00, 0xFF,
                0x00, 0xFF, 0x00, 0xFF
            ])
        )
    }

    func testInitialRDPQualityControlsFrameDeliveryRate() {
        var now: TimeInterval = 0
        let session = makeSession(
            options: EmbeddedRDPSessionOptions(
                host: "rdp.example.test",
                port: 3389,
                user: "tester",
                password: "secret",
                quality: 2
            ),
            frameClock: { now }
        )
        var deliveredFrames = 0
        session.onFrame = { _ in deliveredFrames += 1 }

        session.handleFrame(width: 1, height: 1, bgra: Data(repeating: 0, count: 4))
        now = 0.05
        session.handleFrame(width: 1, height: 1, bgra: Data(repeating: 1, count: 4))
        now = 0.13
        session.handleFrame(width: 1, height: 1, bgra: Data(repeating: 2, count: 4))

        XCTAssertEqual(deliveredFrames, 2)
    }

    func testRDPQualityInputUpdatesFrameDeliveryRate() throws {
        var now: TimeInterval = 0
        let client = RecordingRdpSession()
        let session = makeSession(
            options: EmbeddedRDPSessionOptions(
                host: "rdp.example.test",
                port: 3389,
                user: "tester",
                password: "secret"
            ),
            frameClock: { now },
            rdpSessionFactory: { client }
        )
        try session.start()
        defer { session.stop() }
        var deliveredFrames = 0
        session.onFrame = { _ in deliveredFrames += 1 }

        session.sendInput(.quality(2))
        session.handleFrame(width: 1, height: 1, bgra: Data(repeating: 0, count: 4))
        now = 0.05
        session.handleFrame(width: 1, height: 1, bgra: Data(repeating: 1, count: 4))
        now = 0.13
        session.handleFrame(width: 1, height: 1, bgra: Data(repeating: 2, count: 4))

        XCTAssertEqual(deliveredFrames, 2)
        XCTAssertEqual(client.qualityChanges, [2])
    }

    func testAdaptiveRDPQualityRestoresUserTargetAfterNetworkRecovery() throws {
        let client = RecordingRdpSession()
        let session = makeSession(
            options: EmbeddedRDPSessionOptions(
                host: "rdp.example.test",
                port: 3389,
                user: "tester",
                password: "secret",
                quality: 9
            ),
            rdpSessionFactory: { client }
        )
        try session.start()
        defer { session.stop() }

        client.delegate?.onNetworkStatus(rttMs: 350, mode: "very_poor")
        client.delegate?.onNetworkStatus(rttMs: 40, mode: "normal")

        XCTAssertEqual(client.qualityChanges, [2, 9])
    }

    func testAdaptiveRDPQualityNeverRaisesLowUserTarget() throws {
        let client = RecordingRdpSession()
        let session = makeSession(
            options: EmbeddedRDPSessionOptions(
                host: "rdp.example.test",
                port: 3389,
                user: "tester",
                password: "secret",
                quality: 2
            ),
            rdpSessionFactory: { client }
        )
        try session.start()
        defer { session.stop() }

        client.delegate?.onNetworkStatus(rttMs: 180, mode: "poor")
        client.delegate?.onNetworkStatus(rttMs: 30, mode: "normal")

        XCTAssertTrue(client.qualityChanges.isEmpty)
    }

    func testRDPDelegateCallbacksAfterStopAreIgnored() throws {
        let client = RecordingRdpSession()
        let session = makeSession(
            options: EmbeddedRDPSessionOptions(
                host: "rdp.example.test",
                port: 3389,
                user: "tester",
                password: "secret"
            ),
            rdpSessionFactory: { client }
        )
        var frameCount = 0
        var connectedCount = 0
        var clipboardTexts: [String] = []
        session.onFrame = { _ in frameCount += 1 }
        session.onConnected = { _, _, _ in connectedCount += 1 }
        session.onClipboard = { clipboardTexts.append($0) }
        try session.start()

        session.stop()
        client.delegate?.onFrame(
            desktopWidth: 1,
            desktopHeight: 1,
            x: 0,
            y: 0,
            width: 1,
            height: 1,
            bgra: Data(repeating: 0, count: 4)
        )
        client.delegate?.onClipboard(text: "late")

        XCTAssertEqual(frameCount, 0)
        XCTAssertEqual(connectedCount, 0)
        XCTAssertTrue(clipboardTexts.isEmpty)
    }

    func testRestartClosesPreviousRDPClientAndIgnoresItsLateCallbacks() throws {
        let firstClient = RecordingRdpSession()
        let secondClient = RecordingRdpSession()
        var clients: [RecordingRdpSession] = [firstClient, secondClient]
        let session = makeSession(
            options: EmbeddedRDPSessionOptions(
                host: "rdp.example.test",
                port: 3389,
                user: "tester",
                password: "secret"
            ),
            rdpSessionFactory: { clients.removeFirst() }
        )
        defer { session.stop() }

        try session.start()
        let firstDelegate = try XCTUnwrap(firstClient.delegate)
        firstDelegate.onFrame(
            desktopWidth: 1,
            desktopHeight: 1,
            x: 0,
            y: 0,
            width: 1,
            height: 1,
            bgra: Data([0x00, 0x00, 0xFF, 0xFF])
        )

        try session.start()
        let secondDelegate = try XCTUnwrap(secondClient.delegate)
        secondDelegate.onFrame(
            desktopWidth: 1,
            desktopHeight: 1,
            x: 0,
            y: 0,
            width: 1,
            height: 1,
            bgra: Data([0x00, 0xFF, 0x00, 0xFF])
        )
        firstDelegate.onDisconnected(reason: "late disconnect from replaced client")

        XCTAssertEqual(firstClient.closeCount, 1)
        XCTAssertEqual(
            session.lifecycleState,
            .connected(width: 1, height: 1, name: "RDP Desktop")
        )
        XCTAssertEqual(session.latestFrame?.pixels, Data([0x00, 0xFF, 0x00, 0xFF]))
    }

    func testFrameAboveDesktopLimitIsIgnored() {
        let session = makeSession(frameClock: { 0 })
        var deliveredFrames = 0
        session.onFrame = { _ in deliveredFrames += 1 }

        session.handleFrame(
            width: 8_193,
            height: 1,
            bgra: Data(repeating: 0, count: 8_193 * 4)
        )

        XCTAssertEqual(deliveredFrames, 0)
    }

    func testFrameCadenceNeverFabricatesNetworkStatus() {
        var now: TimeInterval = 0
        let session = makeSession(frameClock: { now })
        var modes: [String] = []
        session.onNetworkStatus = { _, mode in modes.append(mode) }

        session.handleFrame(width: 1, height: 1, bgra: Data(repeating: 0, count: 4))
        now = 0.6
        session.handleFrame(width: 1, height: 1, bgra: Data(repeating: 1, count: 4))
        now = 1.2
        session.handleFrame(width: 1, height: 1, bgra: Data(repeating: 2, count: 4))
        now = 1.8
        session.handleFrame(width: 1, height: 1, bgra: Data(repeating: 3, count: 4))
        now = 1.9
        session.handleFrame(width: 1, height: 1, bgra: Data(repeating: 4, count: 4))
        now = 2.0
        session.handleFrame(width: 1, height: 1, bgra: Data(repeating: 5, count: 4))
        now = 2.1
        session.handleFrame(width: 1, height: 1, bgra: Data(repeating: 6, count: 4))

        XCTAssertTrue(modes.isEmpty)
    }

    private func assertStartRejectsDrive(
        _ drive: String,
        expectedMessage: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let session = makeSession(
            options: EmbeddedRDPSessionOptions(
                host: "127.0.0.1",
                port: 9,
                user: "tester",
                password: "secret",
                drive: drive
            )
        )
        defer { session.stop() }

        XCTAssertThrowsError(try session.start(), file: file, line: line) { error in
            XCTAssertTrue(
                errorDescription(error).contains(expectedMessage),
                "unexpected error: \(errorDescription(error))",
                file: file,
                line: line
            )
        }
    }

    private func makeSession(
        options: EmbeddedRDPSessionOptions,
        frameClock: @escaping () -> TimeInterval = { 0 },
        rdpSessionFactory: @escaping () -> any RdpSessionProtocol = { RdpSession() }
    ) -> EmbeddedRDPGraphicsSession {
        EmbeddedRDPGraphicsSession(
            options: options,
            adapterExecutablePath: "",
            appLog: nil,
            frameClock: frameClock,
            rdpSessionFactory: rdpSessionFactory
        )
    }

    private func makeSession(frameClock: @escaping () -> TimeInterval) -> EmbeddedRDPGraphicsSession {
        makeSession(
            options: EmbeddedRDPSessionOptions(
                host: "rdp.example.test",
                port: 3389,
                user: "tester",
                password: "secret"
            ),
            frameClock: frameClock
        )
    }
}

private final class RecordingRdpSession: RdpSessionProtocol, @unchecked Sendable {
    private(set) var connectCount = 0
    private(set) var host: String?
    private(set) var port: UInt16?
    private(set) var username: String?
    private(set) var password: String?
    private(set) var domain: String?
    private(set) var width: UInt16?
    private(set) var height: UInt16?
    private(set) var quality: UInt8?
    private(set) var security: RdpSecurityMode?
    private(set) var ignoreCertificate = false
    private(set) var driveName: String?
    private(set) var drivePath: String?
    private(set) var delegate: RdpSessionDelegate?
    private(set) var clipboardTexts: [String] = []
    private(set) var resizeRequests: [(width: UInt32, height: UInt32)] = []
    private(set) var scrollEvents: [(delta: Int32, horizontal: Bool)] = []
    private(set) var keyEvents: [(scancode: UInt32, down: Bool)] = []
    private(set) var unicodeEvents: [(character: String, down: Bool)] = []
    private(set) var pointerEvents: [(x: UInt32, y: UInt32, buttons: UInt32)] = []
    private(set) var qualityChanges: [UInt8] = []
    private(set) var closeCount = 0
    var clipboardTextHandler: ((String) -> Void)?

    func connect(
        host: String,
        port: UInt16,
        username: String,
        password: String,
        domain: String?,
        width: UInt16,
        height: UInt16,
        quality: UInt8,
        security: RdpSecurityMode,
        ignoreCertificate: Bool,
        driveName: String?,
        drivePath: String?,
        delegate: RdpSessionDelegate
    ) {
        connectCount += 1
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.domain = domain
        self.width = width
        self.height = height
        self.quality = quality
        self.security = security
        self.ignoreCertificate = ignoreCertificate
        self.driveName = driveName
        self.drivePath = drivePath
        self.delegate = delegate
    }

    func close() {
        closeCount += 1
    }

    func requestResize(width: UInt32, height: UInt32) {
        resizeRequests.append((width, height))
    }
    func sendClipboardText(text: String) {
        clipboardTexts.append(text)
        clipboardTextHandler?(text)
    }
    func sendKey(scancode: UInt32, down: Bool) {
        keyEvents.append((scancode: scancode, down: down))
    }
    func sendPointer(x: UInt32, y: UInt32, buttons: UInt32) {
        pointerEvents.append((x, y, buttons))
    }
    func sendScroll(delta: Int32, horizontal: Bool) {
        scrollEvents.append((delta, horizontal))
    }
    func sendUnicode(character: String, down: Bool) {
        unicodeEvents.append((character, down))
    }
    func setQuality(quality: UInt8) {
        qualityChanges.append(quality)
    }
}

private func errorDescription(_ error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? String(describing: error)
}
