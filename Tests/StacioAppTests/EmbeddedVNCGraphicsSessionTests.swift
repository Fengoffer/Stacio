import Darwin
import AppKit
import Foundation
import XCTest
@testable import StacioApp

final class EmbeddedVNCGraphicsSessionTests: XCTestCase {
    func testRightShiftScancodeMapsToVNCShiftRKeysym() {
        XCTAssertEqual(
            EmbeddedVNCGraphicsSession.keysymForScancode(0x36, isExtended: false),
            0xFFE2
        )
    }

    func testCapsLockAndMenuScancodesMapToVNCKeysyms() {
        XCTAssertEqual(
            EmbeddedVNCGraphicsSession.keysymForScancode(0x3A, isExtended: false),
            0xFFE5
        )
        XCTAssertEqual(
            EmbeddedVNCGraphicsSession.keysymForScancode(0x5D, isExtended: true),
            0xFF67
        )
    }

    func testPasswordIsPassedOnlyThroughChildEnvironment() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("StacioEmbeddedVNCEnvironmentTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let executable = root.appendingPathComponent("capture-vnc-launch.sh")
        let argumentsOutput = root.appendingPathComponent("arguments.txt")
        let environmentOutput = root.appendingPathComponent("environment.txt")
        let script = """
        #!/bin/sh
        printf '%s\n' "$@" > \(shellQuote(argumentsOutput.path))
        printf '%s' "$STACIO_VNC_PASSWORD" > \(shellQuote(environmentOutput.path))
        sleep 1
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let session = EmbeddedVNCGraphicsSession(
            host: "desktop.example.test",
            port: 5900,
            password: "vnc-secret",
            quality: 7,
            maxFps: 30,
            adapterExecutablePath: executable.path,
            appLog: nil
        )
        try session.start()
        defer { session.stop() }

        let arguments = try waitForContents(of: argumentsOutput)
        let environment = try waitForContents(of: environmentOutput)

        XCTAssertFalse(arguments.contains("--password"))
        XCTAssertFalse(arguments.contains("vnc-secret"))
        XCTAssertTrue(arguments.contains("desktop.example.test:5900"))
        XCTAssertEqual(environment, "vnc-secret")
    }

    func testStopTerminatesAdapterAfterSessionIsReleased() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("long-running-vnc-adapter.sh")
        let processIDOutput = root.appendingPathComponent("process-id.txt")
        let terminationOutput = root.appendingPathComponent("terminated.txt")
        let script = """
        #!/bin/sh
        exec 2>/dev/null
        trap 'printf terminated > \(shellQuote(terminationOutput.path)); exit 0' TERM
        printf '%s' "$$" > \(shellQuote(processIDOutput.path))
        while :; do sleep 1; done
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        var session: EmbeddedVNCGraphicsSession? = makeSession(adapterExecutablePath: executable.path)

        try XCTUnwrap(session).start()
        let processID = try XCTUnwrap(Int32(try waitForContents(of: processIDOutput)))
        defer {
            if Darwin.kill(processID, 0) == 0 {
                _ = Darwin.kill(processID, SIGKILL)
            }
        }

        session?.stop()
        session = nil

        XCTAssertEqual(try waitForContents(of: terminationOutput), "terminated")
    }

    func testAdapterEventsEmittedAfterStopAreIgnored() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("late-vnc-events.sh")
        let started = root.appendingPathComponent("adapter-started.txt")
        let script = """
        #!/bin/sh
        printf started > \(shellQuote(started.path))
        IFS= read -r _
        printf '%s\n' '{"type":"connected","width":1,"height":1,"name":"late"}'
        printf '%s\n' '{"type":"clipboard","text":"late"}'
        sleep 1
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let session = makeSession(adapterExecutablePath: executable.path)
        let unexpectedConnected = expectation(description: "late connected event is ignored")
        unexpectedConnected.isInverted = true
        let unexpectedClipboard = expectation(description: "late clipboard event is ignored")
        unexpectedClipboard.isInverted = true
        session.onConnected = { _, _, _ in unexpectedConnected.fulfill() }
        session.onClipboard = { _ in unexpectedClipboard.fulfill() }

        try session.start()
        _ = try waitForContents(of: started)
        session.stop()

        wait(for: [unexpectedConnected, unexpectedClipboard], timeout: 0.4)
    }

    func testDisconnectedEventIsRetainedBeforeCallbackRegistration() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try makeAdapterExecutable(
            emitting: [[
                "type": "disconnected",
                "reason": "early disconnect"
            ]],
            in: root
        )
        let session = makeSession(adapterExecutablePath: executable.path)

        try session.start()
        defer { session.stop() }

        let deadline = Date().addingTimeInterval(2)
        while session.lifecycleState == .connecting, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }

        XCTAssertEqual(
            session.lifecycleState,
            .disconnected(reason: "early disconnect")
        )
    }

    func testAdapterErrorIsRetainedAsDisconnectReasonBeforeCallbackRegistration() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try makeAdapterExecutable(
            emitting: [[
                "type": "error",
                "message": "authentication failed"
            ]],
            in: root
        )
        let session = makeSession(adapterExecutablePath: executable.path)
        let disconnected = expectation(description: "adapter error disconnects session immediately")
        session.onDisconnected = { reason in
            XCTAssertEqual(reason, "authentication failed")
            disconnected.fulfill()
        }

        try session.start()
        defer { session.stop() }

        wait(for: [disconnected], timeout: 2)

        let deadline = Date().addingTimeInterval(0.1)
        while session.lifecycleState == .connecting, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }

        XCTAssertEqual(
            session.lifecycleState,
            .disconnected(reason: "authentication failed")
        )
    }

    func testAdapterErrorDisconnectsBeforeAdapterTerminates() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("delayed-error-vnc-adapter.sh")
        let errorEmitted = root.appendingPathComponent("error-emitted.txt")
        let script = """
        #!/bin/sh
        printf '%s\\n' '{"type":"error","message":"authentication failed"}'
        printf emitted > \(shellQuote(errorEmitted.path))
        sleep 1
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let session = makeSession(adapterExecutablePath: executable.path)
        let disconnected = expectation(description: "adapter error disconnects before process exit")
        session.onDisconnected = { reason in
            XCTAssertEqual(reason, "authentication failed")
            disconnected.fulfill()
        }

        try session.start()
        defer { session.stop() }
        _ = try waitForContents(of: errorEmitted)

        wait(for: [disconnected], timeout: 0.5)
        XCTAssertEqual(
            session.lifecycleState,
            .disconnected(reason: "authentication failed")
        )
    }

    func testPointerBitmapEventDecodesRGBAAndHotspot() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rgba = Data([
            0x30, 0x20, 0x10, 0xFF,
            0x60, 0x50, 0x40, 0x00,
            0x90, 0x80, 0x70, 0x00,
            0xC0, 0xB0, 0xA0, 0xFF
        ])
        let executable = try makeAdapterExecutable(
            emitting: [[
                "type": "pointer_bitmap",
                "width": 2,
                "height": 2,
                "hotspot_x": 1,
                "hotspot_y": 0,
                "data": rgba.base64EncodedString()
            ]],
            in: root
        )
        let session = makeSession(adapterExecutablePath: executable.path)
        let received = expectation(description: "pointer bitmap callback")
        session.onPointerBitmap = { bitmap in
            XCTAssertEqual(bitmap.width, 2)
            XCTAssertEqual(bitmap.height, 2)
            XCTAssertEqual(bitmap.hotspotX, 1)
            XCTAssertEqual(bitmap.hotspotY, 0)
            XCTAssertEqual(bitmap.rgbaPixels, rgba)
            received.fulfill()
        }

        try session.start()
        defer { session.stop() }
        wait(for: [received], timeout: 2)
    }

    func testPointerVisibilityEventHidesRemotePointer() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try makeAdapterExecutable(
            emitting: [[
                "type": "pointer_visibility",
                "visible": false
            ]],
            in: root
        )
        let session = makeSession(adapterExecutablePath: executable.path)
        let received = expectation(description: "pointer visibility callback")
        session.onPointerVisibilityChanged = { visible in
            XCTAssertFalse(visible)
            received.fulfill()
        }

        try session.start()
        defer { session.stop() }
        wait(for: [received], timeout: 2)
    }

    func testPointerPositionEventForwardsCoordinatesInsideDesktop() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try makeAdapterExecutable(
            emitting: [
                [
                    "type": "connected",
                    "width": 800,
                    "height": 600,
                    "name": "pointer desktop"
                ],
                [
                    "type": "pointer_position",
                    "x": 799,
                    "y": 599
                ]
            ],
            in: root
        )
        let session = makeSession(adapterExecutablePath: executable.path)
        let received = expectation(description: "pointer position callback")
        session.onPointerPosition = { x, y in
            XCTAssertEqual(x, 799)
            XCTAssertEqual(y, 599)
            received.fulfill()
        }

        try session.start()
        defer { session.stop() }
        wait(for: [received], timeout: 2)
    }

    func testPointerPositionEventRejectsCoordinatesOutsideDesktop() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try makeAdapterExecutable(
            emitting: [
                [
                    "type": "connected",
                    "width": 2,
                    "height": 2,
                    "name": "pointer desktop"
                ],
                ["type": "pointer_position", "x": -1, "y": 0],
                ["type": "pointer_position", "x": 0, "y": -1],
                ["type": "pointer_position", "x": 2, "y": 0],
                ["type": "pointer_position", "x": 0, "y": 2]
            ],
            in: root
        )
        let session = makeSession(adapterExecutablePath: executable.path)
        let unexpected = expectation(description: "out-of-bounds pointer position is rejected")
        unexpected.isInverted = true
        session.onPointerPosition = { _, _ in unexpected.fulfill() }

        try session.start()
        defer { session.stop() }
        _ = try waitForContents(of: root.appendingPathComponent("adapter-started.txt"))
        wait(for: [unexpected], timeout: 0.3)
    }

    func testPointerBitmapEventRejectsMalformedDecodedLength() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try makeAdapterExecutable(
            emitting: [[
                "type": "pointer_bitmap",
                "width": 2,
                "height": 2,
                "hotspot_x": 1,
                "hotspot_y": 0,
                "data": Data([0x01, 0x02, 0x03, 0x04]).base64EncodedString()
            ]],
            in: root
        )
        let session = makeSession(adapterExecutablePath: executable.path)
        let unexpected = expectation(description: "malformed pointer bitmap is rejected")
        unexpected.isInverted = true
        session.onPointerBitmap = { _ in unexpected.fulfill() }

        try session.start()
        defer { session.stop() }
        _ = try waitForContents(of: root.appendingPathComponent("adapter-started.txt"))
        wait(for: [unexpected], timeout: 0.3)
    }

    func testPointerBitmapEventRejectsOversizedDimensionsBeforeDecode() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try makeAdapterExecutable(
            emitting: [[
                "type": "pointer_bitmap",
                "width": 2_048,
                "height": 1_024,
                "hotspot_x": 0,
                "hotspot_y": 0,
                "data": Data([0x00]).base64EncodedString()
            ]],
            in: root
        )
        let session = makeSession(adapterExecutablePath: executable.path)
        let unexpected = expectation(description: "oversized pointer bitmap is rejected")
        unexpected.isInverted = true
        session.onPointerBitmap = { _ in unexpected.fulfill() }

        try session.start()
        defer { session.stop() }
        _ = try waitForContents(of: root.appendingPathComponent("adapter-started.txt"))
        wait(for: [unexpected], timeout: 0.3)
    }

    func testConnectedEventRejectsDesktopDimensionAboveLimit() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try makeAdapterExecutable(
            emitting: [[
                "type": "connected",
                "width": 8_193,
                "height": 1,
                "name": "oversized"
            ]],
            in: root
        )
        let session = makeSession(adapterExecutablePath: executable.path)
        let unexpected = expectation(description: "oversized desktop is rejected")
        unexpected.isInverted = true
        session.onConnected = { _, _, _ in unexpected.fulfill() }

        try session.start()
        defer { session.stop() }
        _ = try waitForContents(of: root.appendingPathComponent("adapter-started.txt"))
        wait(for: [unexpected], timeout: 0.3)
    }

    func testOversizedLocalClipboardIsNotWrittenToAdapterStdin() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("capture-vnc-input.sh")
        let capturedInput = root.appendingPathComponent("captured-input.json")
        let temporaryInput = root.appendingPathComponent("captured-input.tmp")
        let script = """
        #!/bin/sh
        /usr/bin/head -n 1 > \(shellQuote(temporaryInput.path))
        /bin/mv \(shellQuote(temporaryInput.path)) \(shellQuote(capturedInput.path))
        sleep 1
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let session = makeSession(adapterExecutablePath: executable.path)

        try session.start()
        defer { session.stop() }
        session.sendInput(.clipboardTextPaste(String(repeating: "x", count: 1_048_577)))
        session.sendInput(.quality(5))

        let captured = try waitForContents(of: capturedInput)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(captured.utf8)) as? [String: Any]
        )
        XCTAssertEqual(payload["type"] as? String, "quality")
        XCTAssertEqual(payload["level"] as? Int, 5)
    }

    func testLocalPasteboardChangeIsWrittenToAdapterAutomatically() throws {
        let pasteboard = NSPasteboard.general
        let originalText = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let originalText {
                pasteboard.setString(originalText, forType: .string)
            }
        }
        pasteboard.clearContents()
        pasteboard.setString("before VNC session", forType: .string)

        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("capture-vnc-pasteboard.sh")
        let capturedInput = root.appendingPathComponent("captured-pasteboard.json")
        let temporaryInput = root.appendingPathComponent("captured-pasteboard.tmp")
        let script = """
        #!/bin/sh
        /usr/bin/head -n 1 > \(shellQuote(temporaryInput.path))
        /bin/mv \(shellQuote(temporaryInput.path)) \(shellQuote(capturedInput.path))
        sleep 1
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let session = makeSession(adapterExecutablePath: executable.path)

        try session.start()
        defer { session.stop() }
        session.setClipboardSynchronizationEnabled(true)
        pasteboard.clearContents()
        pasteboard.setString("Mac → VNC automatically", forType: .string)

        let captured = try waitForContents(of: capturedInput)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(captured.utf8)) as? [String: Any]
        )
        XCTAssertEqual(payload["type"] as? String, "clipboard")
        XCTAssertEqual(payload["text"] as? String, "Mac → VNC automatically")
    }

    func testInactiveSessionDoesNotMonitorLocalPasteboard() throws {
        let pasteboard = NSPasteboard.general
        let originalText = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let originalText {
                pasteboard.setString(originalText, forType: .string)
            }
        }
        pasteboard.clearContents()
        pasteboard.setString("before inactive VNC session", forType: .string)

        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("capture-inactive-vnc-pasteboard.sh")
        let capturedInput = root.appendingPathComponent("captured-inactive-pasteboard.json")
        let temporaryInput = root.appendingPathComponent("captured-inactive-pasteboard.tmp")
        let script = """
        #!/bin/sh
        /usr/bin/head -n 1 > \(shellQuote(temporaryInput.path))
        /bin/mv \(shellQuote(temporaryInput.path)) \(shellQuote(capturedInput.path))
        sleep 1
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let session = makeSession(adapterExecutablePath: executable.path)

        try session.start()
        defer { session.stop() }
        pasteboard.clearContents()
        pasteboard.setString("must not leave inactive VNC session", forType: .string)
        RunLoop.current.run(until: Date().addingTimeInterval(0.7))
        session.sendInput(.quality(5))

        let captured = try waitForContents(of: capturedInput)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(captured.utf8)) as? [String: Any]
        )
        XCTAssertEqual(payload["type"] as? String, "quality")
    }

    func testOversizedResizeIsNotWrittenToAdapterStdin() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("capture-vnc-resize.sh")
        let capturedInput = root.appendingPathComponent("captured-resize.json")
        let temporaryInput = root.appendingPathComponent("captured-resize.tmp")
        let script = """
        #!/bin/sh
        /usr/bin/head -n 1 > \(shellQuote(temporaryInput.path))
        /bin/mv \(shellQuote(temporaryInput.path)) \(shellQuote(capturedInput.path))
        sleep 1
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let session = makeSession(adapterExecutablePath: executable.path)

        try session.start()
        defer { session.stop() }
        session.sendInput(.resize(width: 8_193, height: 1, scaleFactor: 1))
        session.sendInput(.quality(5))

        let captured = try waitForContents(of: capturedInput)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(captured.utf8)) as? [String: Any]
        )
        XCTAssertEqual(payload["type"] as? String, "quality")
        XCTAssertEqual(payload["level"] as? Int, 5)
    }

    func testUnsupportedSideMouseButtonDoesNotSetRFBWheelBits() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("capture-vnc-side-button.sh")
        let capturedInput = root.appendingPathComponent("captured-side-button.json")
        let temporaryInput = root.appendingPathComponent("captured-side-button.tmp")
        let script = """
        #!/bin/sh
        /usr/bin/head -n 1 > \(shellQuote(temporaryInput.path))
        /bin/mv \(shellQuote(temporaryInput.path)) \(shellQuote(capturedInput.path))
        sleep 1
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let session = makeSession(adapterExecutablePath: executable.path)

        try session.start()
        defer { session.stop() }
        session.sendInput(.mouseButton(button: .x1, isPressed: true, x: 12, y: 34))

        let captured = try waitForContents(of: capturedInput)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(captured.utf8)) as? [String: Any]
        )
        XCTAssertEqual(payload["type"] as? String, "pointer")
        XCTAssertEqual(payload["buttons"] as? Int, 0)
    }

    func testAdapterLineBufferDiscardsOversizedLineAndRecoversAtNextNewline() {
        var buffer = VNCAdapterLineBuffer(maximumLineBytes: 8)

        XCTAssertTrue(buffer.append(Data("123456789".utf8)).isEmpty)
        XCTAssertEqual(buffer.bufferedByteCount, 0)

        let recovered = buffer.append(Data("ignored\n{\"ok\":1}\n".utf8))

        XCTAssertEqual(recovered, ["{\"ok\":1}"])
        XCTAssertEqual(buffer.bufferedByteCount, 0)
    }

    func testFramePatchBoundsRejectOverflowingCoordinatesBeforeDecode() {
        XCTAssertFalse(
            EmbeddedVNCGraphicsSession.framePatchFitsCanvas(
                x: Int.max,
                y: 0,
                width: 1,
                height: 1,
                canvasWidth: 1_920,
                canvasHeight: 1_080
            )
        )
        XCTAssertTrue(
            EmbeddedVNCGraphicsSession.framePatchFitsCanvas(
                x: 1_919,
                y: 1_079,
                width: 1,
                height: 1,
                canvasWidth: 1_920,
                canvasHeight: 1_080
            )
        )
    }

    func testBatchedFramePatchesDeliverOneCanvasSnapshot() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let jpeg = try makeOnePixelJPEGBase64()
        let executable = try makeAdapterExecutable(
            emitting: [
                [
                    "type": "connected",
                    "width": 2,
                    "height": 1,
                    "name": "batched desktop"
                ],
                [
                    "type": "frame_patch",
                    "x": 0,
                    "y": 0,
                    "w": 1,
                    "h": 1,
                    "encoding": "jpeg",
                    "data": jpeg,
                    "batch_end": false
                ],
                [
                    "type": "frame_patch",
                    "x": 1,
                    "y": 0,
                    "w": 1,
                    "h": 1,
                    "encoding": "jpeg",
                    "data": jpeg,
                    "batch_end": true
                ]
            ],
            in: root
        )
        let session = makeSession(adapterExecutablePath: executable.path)
        var frames: [GraphicsFrame] = []
        let firstFrame = expectation(description: "batched canvas delivered")
        session.onFrame = { frame in
            frames.append(frame)
            if frames.count == 1 {
                firstFrame.fulfill()
            }
        }

        try session.start()
        defer { session.stop() }
        wait(for: [firstFrame], timeout: 1)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.width, 2)
        XCTAssertEqual(frames.first?.height, 1)
    }

    func testResizePreservesTopLeftCanvasUntilServerRefreshesIt() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let jpeg = try makeOnePixelJPEGBase64()
        let executable = try makeAdapterExecutable(
            emitting: [
                [
                    "type": "connected",
                    "width": 2,
                    "height": 1,
                    "name": "resizing desktop"
                ],
                [
                    "type": "frame_patch",
                    "x": 0,
                    "y": 0,
                    "w": 1,
                    "h": 1,
                    "encoding": "jpeg",
                    "data": jpeg
                ],
                [
                    "type": "resize",
                    "width": 3,
                    "height": 1
                ],
                [
                    "type": "frame_patch",
                    "x": 2,
                    "y": 0,
                    "w": 1,
                    "h": 1,
                    "encoding": "jpeg",
                    "data": jpeg
                ]
            ],
            in: root
        )
        let session = makeSession(adapterExecutablePath: executable.path)
        var frames: [GraphicsFrame] = []
        let delivered = expectation(description: "pre- and post-resize frames delivered")
        delivered.expectedFulfillmentCount = 2
        session.onFrame = { frame in
            frames.append(frame)
            delivered.fulfill()
        }

        try session.start()
        defer { session.stop() }
        wait(for: [delivered], timeout: 3)

        XCTAssertEqual(frames.count, 2)
        let firstFrame = try XCTUnwrap(frames.first)
        let resizedFrame = try XCTUnwrap(frames.dropFirst().first)
        XCTAssertEqual(resizedFrame.width, 3)
        let originalTopLeftPixel = Data(firstFrame.pixels.prefix(4))
        XCTAssertNotEqual(originalTopLeftPixel, Data(repeating: 0, count: 4))
        XCTAssertEqual(Data(resizedFrame.pixels.prefix(4)), originalTopLeftPixel)
    }

    func testVNCLineWriterSerializesConcurrentWrites() {
        let probe = ConcurrentVNCWriteProbe()
        let writer = VNCSerializedLineWriter { _ in
            probe.enter()
            Thread.sleep(forTimeInterval: 0.003)
            probe.leave()
        }

        DispatchQueue.concurrentPerform(iterations: 24) { index in
            writer.write(Data("{\"index\":\(index)}\n".utf8))
        }

        XCTAssertEqual(probe.maximumConcurrentWrites, 1)
    }

    private func makeSession(adapterExecutablePath: String) -> EmbeddedVNCGraphicsSession {
        EmbeddedVNCGraphicsSession(
            host: "desktop.example.test",
            port: 5900,
            password: nil,
            adapterExecutablePath: adapterExecutablePath,
            appLog: nil
        )
    }

    private func makeTemporaryRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("StacioEmbeddedVNCPointerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeOnePixelJPEGBase64() throws -> String {
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 1,
                pixelsHigh: 1,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 4,
                bitsPerPixel: 32
            )
        )
        let pixels = try XCTUnwrap(bitmap.bitmapData)
        pixels[0] = 0xFF
        pixels[1] = 0x00
        pixels[2] = 0x00
        pixels[3] = 0xFF
        let jpeg = try XCTUnwrap(
            bitmap.representation(
                using: .jpeg,
                properties: [.compressionFactor: 0.8]
            )
        )
        return jpeg.base64EncodedString()
    }

    private func makeAdapterExecutable(
        emitting payloads: [[String: Any]],
        in root: URL
    ) throws -> URL {
        let executable = root.appendingPathComponent("emit-vnc-events.sh")
        let started = root.appendingPathComponent("adapter-started.txt")
        let outputLines = try payloads.map { payload -> String in
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            let line = try XCTUnwrap(String(data: data, encoding: .utf8))
            return "/usr/bin/printf '%s\\n' \(shellQuote(line))"
        }
        let script = (
            ["#!/bin/sh", "/usr/bin/printf started > \(shellQuote(started.path))"]
                + outputLines
                + ["sleep 1"]
        ).joined(separator: "\n") + "\n"
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }

    private func waitForContents(of url: URL, timeout: TimeInterval = 2) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = try? String(contentsOf: url, encoding: .utf8),
               !value.isEmpty {
                return value
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        throw NSError(
            domain: "EmbeddedVNCGraphicsSessionTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for \(url.lastPathComponent)"]
        )
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

private final class ConcurrentVNCWriteProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var activeWrites = 0
    private(set) var maximumConcurrentWrites = 0

    func enter() {
        lock.lock()
        activeWrites += 1
        maximumConcurrentWrites = max(maximumConcurrentWrites, activeWrites)
        lock.unlock()
    }

    func leave() {
        lock.lock()
        activeWrites -= 1
        lock.unlock()
    }
}
