import AppKit
import WebKit
import XCTest
@testable import StacioApp

@MainActor
final class FileWorkspaceMediaWindowControllerTests: XCTestCase {
    func testImageVideoAndAudioWindowsOpenAtUsableVisibleSizes() throws {
        let cases: [(kind: RemoteFileContentKind, fileName: String, minimumSize: NSSize)] = [
            (.image, "diagram.png", NSSize(width: 900, height: 600)),
            (.video, "demo.mp4", NSSize(width: 900, height: 600)),
            (.audio, "recording.m4a", NSSize(width: 520, height: 156))
        ]

        for item in cases {
            let controller = FileWorkspaceMediaWindowController(document: FileWorkspaceMediaDocument(
                sourceID: "visible-\(item.kind)",
                fileName: item.fileName,
                sourceURL: URL(fileURLWithPath: "/tmp/\(item.fileName)"),
                contentKind: item.kind,
                byteCount: 1_024
            ))
            controller.showWindow(nil)
            defer { controller.close() }
            let window = try XCTUnwrap(controller.window)
            window.layoutIfNeeded()

            XCTAssertTrue(window.isVisible, "\(item.kind) window should be visible")
            XCTAssertGreaterThanOrEqual(window.contentLayoutRect.width, item.minimumSize.width)
            XCTAssertGreaterThanOrEqual(window.contentLayoutRect.height, item.minimumSize.height)
        }
    }

    func testImageWindowIsBorderlessResizableAndUsesAutoHidingFloatingControls() throws {
        let document = FileWorkspaceMediaDocument(
            sourceID: "image-preview",
            fileName: "diagram.png",
            sourceURL: URL(fileURLWithPath: "/tmp/diagram.png"),
            contentKind: .image,
            byteCount: 1_024
        )
        let controller = FileWorkspaceMediaWindowController(document: document)
        let window = try XCTUnwrap(controller.window)

        XCTAssertTrue(window.styleMask.contains(.borderless))
        XCTAssertTrue(window.styleMask.contains(.closable))
        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertTrue(window.canBecomeKey)
        XCTAssertTrue(window.canBecomeMain)
        XCTAssertFalse(window.isOpaque)
        XCTAssertTrue(window.hasShadow)
        XCTAssertTrue(controller.mediaViewController.htmlForTesting.contains("installAutoHide()"))
        XCTAssertTrue(controller.mediaViewController.htmlForTesting.contains("顺时针旋转"))
        XCTAssertTrue(controller.mediaViewController.htmlForTesting.contains("实际大小"))
    }

    func testCloseRequestClosesBorderlessWindowAndUnregistersRemoteSource() throws {
        let sourceURL = RemoteFileOnlineMediaRegistry.shared.register(
            fileName: "diagram.png",
            mimeType: "image/png",
            byteCount: 1,
            reader: { _, _ in Data([0]) }
        )
        let controller = FileWorkspaceMediaWindowController(document: FileWorkspaceMediaDocument(
            sourceID: "remote-close",
            fileName: "diagram.png",
            sourceURL: sourceURL,
            contentKind: .image,
            byteCount: 1
        ))
        var closeCount = 0
        controller.onClose = { _ in closeCount += 1 }
        controller.showWindow(nil)
        XCTAssertNotNil(RemoteFileOnlineMediaRegistry.shared.source(for: sourceURL))

        controller.mediaViewController.onCloseRequested?()

        XCTAssertEqual(closeCount, 1)
        XCTAssertNil(RemoteFileOnlineMediaRegistry.shared.source(for: sourceURL))
    }

    func testRealEscapeAndDOMCloseBothCloseWindowAndUnregisterSource() throws {
        let closeActions: [(String, String, String)] = [
            (
                "escape",
                "document.readyState === 'complete' && document.querySelector('button[aria-label=\"关闭\"]') !== null",
                "document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));"
            ),
            (
                "dom",
                "document.readyState === 'complete' && document.querySelector('button[aria-label=\\\"关闭\\\"]') !== null",
                "document.querySelector('button[aria-label=\\\"关闭\\\"]').click();"
            )
        ]

        for (name, readiness, script) in closeActions {
            let imageData = Self.onePixelPNG
            let sourceURL = RemoteFileOnlineMediaRegistry.shared.register(
                fileName: "diagram-\(name).png",
                mimeType: "image/png",
                byteCount: UInt64(imageData.count),
                reader: { [imageData] _, _ in imageData }
            )
            let controller = FileWorkspaceMediaWindowController(document: FileWorkspaceMediaDocument(
                sourceID: "remote-close-\(name)",
                fileName: "diagram.png",
                sourceURL: sourceURL,
                contentKind: .image,
                byteCount: UInt64(imageData.count)
            ))
            let closed = expectation(description: "\(name) closes media window")
            controller.onClose = { _ in closed.fulfill() }
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            XCTAssertTrue(try XCTUnwrap(controller.window).canBecomeKey)
            let webView = try XCTUnwrap(controller.mediaViewController.webViewForTesting)

            try evaluateJavaScriptWhenReady(
                script,
                readinessExpression: readiness,
                in: webView
            )
            wait(for: [closed], timeout: 2)

            XCTAssertNil(RemoteFileOnlineMediaRegistry.shared.source(for: sourceURL))
        }
    }

    func testVideoWindowProvidesFloatingSeekPlayAndPauseControls() {
        let document = FileWorkspaceMediaDocument(
            sourceID: "video-preview",
            fileName: "demo.mp4",
            sourceURL: URL(string: "stacio-remote-media://preview/demo.mp4")!,
            contentKind: .video,
            byteCount: 64 * 1_024
        )
        let controller = FileWorkspaceMediaWindowController(document: document)
        let html = controller.mediaViewController.htmlForTesting

        XCTAssertTrue(html.contains("快退 10 秒"))
        XCTAssertTrue(html.contains("快进 10 秒"))
        XCTAssertTrue(html.contains("video.paused ? video.play() : video.pause()"))
        XCTAssertTrue(html.contains("className = 'floating transport'"))
        XCTAssertTrue(html.contains("stacio-remote-media:"))
        XCTAssertTrue(html.contains("video-volume"))
        XCTAssertTrue(html.contains("bindVolume(video, mute, volume)"))
    }

    func testAudioAndVideoControlsUseNativeMacOSSFSymbols() {
        for kind in [RemoteFileContentKind.video, .audio] {
            let fileName = kind == .video ? "demo.mp4" : "recording.m4a"
            let html = FileWorkspaceMediaWindowController(document: FileWorkspaceMediaDocument(
                sourceID: "native-symbols-\(kind)",
                fileName: fileName,
                sourceURL: URL(fileURLWithPath: "/tmp/\(fileName)"),
                contentKind: kind,
                byteCount: 1_024
            )).mediaViewController.htmlForTesting

            for symbolName in [
                "play.fill",
                "pause.fill",
                "gobackward.10",
                "goforward.10",
                "speaker.wave.2.fill",
                "speaker.wave.1.fill",
                "speaker.slash.fill"
            ] {
                XCTAssertTrue(html.contains(symbolName), "missing SF Symbol \(symbolName) for \(kind)")
            }
            XCTAssertTrue(html.contains("data:image/png;base64,"))
            XCTAssertFalse(html.contains("&#x25B6;"))
            XCTAssertFalse(html.contains("&#x23F8;"))
            XCTAssertFalse(html.contains("&#x1F50A;"))
        }
    }

    func testImageAndVideoMetadataApplyAStableContentAspectRatio() throws {
        for kind in [RemoteFileContentKind.image, .video] {
            let document = FileWorkspaceMediaDocument(
                sourceID: "aspect-\(kind)",
                fileName: kind == .image ? "portrait.png" : "portrait.mp4",
                sourceURL: URL(fileURLWithPath: "/tmp/portrait"),
                contentKind: kind,
                byteCount: 1_024
            )
            let controller = FileWorkspaceMediaWindowController(document: document)
            let window = try XCTUnwrap(controller.window)

            controller.mediaViewController.onPreferredAspectRatioChanged?(900, 1_600)

            XCTAssertEqual(window.contentAspectRatio.width, 900, accuracy: 0.001)
            XCTAssertEqual(window.contentAspectRatio.height, 1_600, accuracy: 0.001)
            XCTAssertEqual(
                window.contentLayoutRect.width / window.contentLayoutRect.height,
                900.0 / 1_600.0,
                accuracy: 0.01
            )
            controller.close()
        }
    }

    func testAudioWindowUsesFixedFloatingPlayerSize() throws {
        let document = FileWorkspaceMediaDocument(
            sourceID: "audio-preview",
            fileName: "recording.m4a",
            sourceURL: URL(fileURLWithPath: "/tmp/recording.m4a"),
            contentKind: .audio,
            byteCount: 4_096
        )
        let controller = FileWorkspaceMediaWindowController(document: document)
        let window = try XCTUnwrap(controller.window)

        XCTAssertTrue(window.styleMask.contains(.borderless))
        XCTAssertFalse(window.styleMask.contains(.resizable))
        XCTAssertEqual(window.minSize, NSSize(width: 520, height: 156))
        XCTAssertEqual(window.maxSize, NSSize(width: 520, height: 156))
        XCTAssertEqual(window.level, .floating)
        XCTAssertTrue(controller.mediaViewController.htmlForTesting.contains("audio-progress"))
        XCTAssertTrue(controller.mediaViewController.htmlForTesting.contains("audio.paused ? audio.play() : audio.pause()"))
        XCTAssertTrue(controller.mediaViewController.htmlForTesting.contains("audio-volume"))
        XCTAssertTrue(controller.mediaViewController.htmlForTesting.contains("bindVolume(audio, mute, volume)"))
    }

    func testVolumeControlSupportsMuteRestoreAndSliderAdjustment() {
        let document = FileWorkspaceMediaDocument(
            sourceID: "volume-controls",
            fileName: "recording.m4a",
            sourceURL: URL(fileURLWithPath: "/tmp/recording.m4a"),
            contentKind: .audio,
            byteCount: 4_096
        )
        let html = FileWorkspaceMediaWindowController(document: document)
            .mediaViewController.htmlForTesting

        XCTAssertTrue(html.contains("function bindVolume(player, muteButton, volumeSlider)"))
        XCTAssertTrue(html.contains("player.muted = nextVolume === 0"))
        XCTAssertTrue(html.contains("player.volume = Math.max(lastAudibleVolume, .1)"))
        XCTAssertTrue(html.contains("player.addEventListener('volumechange', sync)"))
        XCTAssertTrue(html.contains("volumeSlider.addEventListener('input'"))
    }

    func testAudioVolumeSliderAndMuteButtonUpdateTheRealMediaElement() throws {
        let controller = FileWorkspaceMediaWindowController(document: FileWorkspaceMediaDocument(
            sourceID: "volume-webview",
            fileName: "recording.wav",
            sourceURL: URL(fileURLWithPath: "/tmp/recording.wav"),
            contentKind: .audio,
            byteCount: 4_096
        ))
        controller.showWindow(nil)
        defer { controller.close() }
        let webView = try XCTUnwrap(controller.mediaViewController.webViewForTesting)

        let adjusted = try evaluateJavaScriptValueWhenReady(
            "(() => { const slider = document.getElementById('audio-volume'); slider.value = '0.25'; slider.dispatchEvent(new Event('input', { bubbles: true })); const audio = document.querySelector('audio'); return [audio.volume, audio.muted]; })()",
            readinessExpression: "document.getElementById('audio-volume') !== null && document.querySelector('audio') !== null",
            in: webView
        ) as? [Any]
        XCTAssertEqual((adjusted?.first as? NSNumber)?.doubleValue ?? -1, 0.25, accuracy: 0.001)
        XCTAssertEqual(adjusted?.dropFirst().first as? Bool, false)

        let muted = try evaluateJavaScriptValueWhenReady(
            "(() => { document.querySelector('.audio-actions button[aria-label=\"静音\"]').click(); const audio = document.querySelector('audio'); return [audio.volume, audio.muted]; })()",
            readinessExpression: "document.querySelector('.audio-actions button[aria-label=\"静音\"]') !== null",
            in: webView
        ) as? [Any]
        XCTAssertEqual(muted?.dropFirst().first as? Bool, true)

        let restored = try evaluateJavaScriptValueWhenReady(
            "(() => { document.querySelector('.audio-actions button[aria-label=\"取消静音\"]').click(); const audio = document.querySelector('audio'); return [audio.volume, audio.muted]; })()",
            readinessExpression: "document.querySelector('.audio-actions button[aria-label=\"取消静音\"]') !== null",
            in: webView
        ) as? [Any]
        XCTAssertEqual((restored?.first as? NSNumber)?.doubleValue ?? -1, 0.25, accuracy: 0.001)
        XCTAssertEqual(restored?.dropFirst().first as? Bool, false)
    }

    func testLocalImageResourceActuallyLoadsInWebView() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioMediaTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let imageURL = temporaryDirectory.appendingPathComponent("local.png")
        try Self.onePixelPNG.write(to: imageURL)

        let windowController = showMediaWindow(
            document: FileWorkspaceMediaDocument(localURL: imageURL)
        )
        defer { windowController.close() }

        let result = try loadImageAndReadDimensions(from: windowController.mediaViewController)
        XCTAssertEqual(result.state, "loaded")
        XCTAssertEqual(result.width, 1)
        XCTAssertEqual(result.height, 1)
    }

    func testRemoteImageResourceActuallyLoadsThroughCustomScheme() throws {
        let reader = FileWorkspaceMediaRecordingReader(data: Self.onePixelPNG)
        let sourceURL = RemoteFileOnlineMediaRegistry.shared.register(
            fileName: "remote.png",
            mimeType: "image/png",
            byteCount: UInt64(Self.onePixelPNG.count),
            reader: { offset, length in
                reader.read(offset: offset, length: length)
            }
        )
        let windowController = showMediaWindow(document: FileWorkspaceMediaDocument(
            sourceID: "remote-image",
            fileName: "remote.png",
            sourceURL: sourceURL,
            contentKind: .image,
            byteCount: UInt64(Self.onePixelPNG.count)
        ))
        defer { windowController.close() }

        let result = try loadImageAndReadDimensions(from: windowController.mediaViewController)
        XCTAssertEqual(result.state, "loaded")
        XCTAssertEqual(result.width, 1)
        XCTAssertEqual(result.height, 1)
        XCTAssertFalse(reader.requests.isEmpty)
    }

    func testLocalAudioAndVideoMetadataActuallyLoad() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioLocalMediaTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let audioURL = temporaryDirectory.appendingPathComponent("local.wav")
        let videoURL = temporaryDirectory.appendingPathComponent("local.mp4")
        try Self.shortPCMFile.write(to: audioURL)
        try Self.oneFrameMP4.write(to: videoURL)

        let audioWindow = showMediaWindow(document: FileWorkspaceMediaDocument(localURL: audioURL))
        defer { audioWindow.close() }
        let audioResult = try loadMediaAndReadMetadata(
            from: audioWindow.mediaViewController,
            selector: "audio",
            widthProperty: "readyState",
            heightProperty: "readyState"
        )
        XCTAssertEqual(audioResult.state, "loaded")

        let videoWindow = showMediaWindow(document: FileWorkspaceMediaDocument(localURL: videoURL))
        defer { videoWindow.close() }
        let videoResult = try loadMediaAndReadMetadata(
            from: videoWindow.mediaViewController,
            selector: "video",
            widthProperty: "videoWidth",
            heightProperty: "videoHeight"
        )
        XCTAssertEqual(videoResult.state, "loaded")
        XCTAssertEqual(videoResult.width, 16)
        XCTAssertEqual(videoResult.height, 16)
    }

    func testRemoteVideoMetadataActuallyLoadsThroughLoopbackHTTP() throws {
        let reader = FileWorkspaceMediaRecordingReader(data: Self.oneFrameMP4)
        let sourceURL = try RemoteFileOnlineMediaRegistry.shared.registerForPlayback(
            fileName: "remote.mp4",
            mimeType: "video/mp4",
            byteCount: UInt64(Self.oneFrameMP4.count),
            reader: { offset, length in
                reader.read(offset: offset, length: length)
            }
        )
        let windowController = showMediaWindow(document: FileWorkspaceMediaDocument(
            sourceID: "remote-video",
            fileName: "remote.mp4",
            sourceURL: sourceURL,
            contentKind: .video,
            byteCount: UInt64(Self.oneFrameMP4.count)
        ))
        defer { windowController.close() }

        let result = try loadMediaAndReadMetadata(
            from: windowController.mediaViewController,
            selector: "video",
            widthProperty: "videoWidth",
            heightProperty: "videoHeight"
        )
        XCTAssertEqual(result.state, "loaded")
        XCTAssertEqual(result.width, 16)
        XCTAssertEqual(result.height, 16)
        XCTAssertFalse(reader.requests.isEmpty)
        XCTAssertFalse(reader.requests.contains { $0.length == nil })
        XCTAssertTrue(reader.requests.contains { request in
            guard let length = request.length else { return false }
            return length < UInt64(Self.oneFrameMP4.count)
        })
    }

    func testRemoteAudioMetadataActuallyLoadsThroughLoopbackHTTP() throws {
        let audioData = Self.shortPCMFile
        let reader = FileWorkspaceMediaRecordingReader(data: audioData)
        let sourceURL = try RemoteFileOnlineMediaRegistry.shared.registerForPlayback(
            fileName: "remote.wav",
            mimeType: "audio/wav",
            byteCount: UInt64(audioData.count),
            reader: { offset, length in
                reader.read(offset: offset, length: length)
            }
        )
        let windowController = showMediaWindow(document: FileWorkspaceMediaDocument(
            sourceID: "remote-audio",
            fileName: "remote.wav",
            sourceURL: sourceURL,
            contentKind: .audio,
            byteCount: UInt64(audioData.count)
        ))
        defer { windowController.close() }

        let result = try loadMediaAndReadMetadata(
            from: windowController.mediaViewController,
            selector: "audio",
            widthProperty: "readyState",
            heightProperty: "readyState"
        )
        XCTAssertEqual(result.state, "loaded")
        XCTAssertGreaterThanOrEqual(result.width, 1)
        XCTAssertFalse(reader.requests.isEmpty)
        XCTAssertFalse(reader.requests.contains { $0.length == nil })
        XCTAssertTrue(reader.requests.contains { request in
            guard let length = request.length else { return false }
            return length < UInt64(audioData.count)
        })
    }

    private func loadImageAndReadDimensions(
        from controller: FileWorkspaceMediaViewController
    ) throws -> (state: String, width: Int, height: Int) {
        try loadMediaAndReadMetadata(
            from: controller,
            selector: "img",
            widthProperty: "naturalWidth",
            heightProperty: "naturalHeight",
            readinessExpression: "element.complete"
        )
    }

    private func loadMediaAndReadMetadata(
        from controller: FileWorkspaceMediaViewController,
        selector: String,
        widthProperty: String,
        heightProperty: String,
        readinessExpression: String = "element.readyState >= 1"
    ) throws -> (state: String, width: Int, height: Int) {
        controller.loadViewIfNeeded()
        let webView = try XCTUnwrap(controller.webViewForTesting)
        let resourceFinished = expectation(description: "image resource finishes")
        var result: (state: String, width: Int, height: Int)?
        let deadline = Date().addingTimeInterval(3)
        func poll() {
            webView.evaluateJavaScript(
                "(() => { const element = document.querySelector('\(selector)'); if (!element) return ['missing', 0, 0]; if (!(\(readinessExpression))) return element.error ? ['failed', 0, 0] : ['loading', 0, 0]; return [element.\(widthProperty) > 0 ? 'loaded' : 'failed', element.\(widthProperty), element.\(heightProperty)]; })()"
            ) { value, error in
                guard error == nil,
                      let values = value as? [Any],
                      values.count == 3,
                      let state = values[0] as? String,
                      let width = values[1] as? NSNumber,
                      let height = values[2] as? NSNumber
                else {
                    XCTFail("Unable to inspect media image: \(error?.localizedDescription ?? "invalid result")")
                    resourceFinished.fulfill()
                    return
                }
                if (state == "loading" || state == "missing"), Date() < deadline {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll)
                    return
                }
                result = (state, width.intValue, height.intValue)
                resourceFinished.fulfill()
            }
        }
        poll()
        wait(for: [resourceFinished], timeout: 4)
        return try XCTUnwrap(result)
    }

    private func showMediaWindow(
        document: FileWorkspaceMediaDocument
    ) -> FileWorkspaceMediaWindowController {
        let controller = FileWorkspaceMediaWindowController(document: document)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        return controller
    }

    private func evaluateJavaScriptWhenReady(
        _ script: String,
        readinessExpression: String,
        in webView: WKWebView
    ) throws {
        let completed = expectation(description: "JavaScript action completes")
        let deadline = Date().addingTimeInterval(2)
        var capturedError: Error?
        func poll() {
            webView.evaluateJavaScript(readinessExpression) { ready, error in
                if error == nil, (ready as? Bool) == true {
                    webView.evaluateJavaScript(script) { _, actionError in
                        capturedError = actionError
                        completed.fulfill()
                    }
                } else if Date() < deadline {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: poll)
                } else {
                    capturedError = error ?? CocoaError(.coderReadCorrupt)
                    completed.fulfill()
                }
            }
        }
        poll()
        wait(for: [completed], timeout: 3)
        if let capturedError {
            throw capturedError
        }
    }

    private func evaluateJavaScriptValueWhenReady(
        _ script: String,
        readinessExpression: String,
        in webView: WKWebView
    ) throws -> Any? {
        let completed = expectation(description: "JavaScript value is returned")
        let deadline = Date().addingTimeInterval(2)
        var capturedValue: Any?
        var capturedError: Error?
        func poll() {
            webView.evaluateJavaScript(readinessExpression) { ready, error in
                if error == nil, (ready as? Bool) == true {
                    webView.evaluateJavaScript(script) { value, actionError in
                        capturedValue = value
                        capturedError = actionError
                        completed.fulfill()
                    }
                } else if Date() < deadline {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: poll)
                } else {
                    capturedError = error ?? CocoaError(.coderReadCorrupt)
                    completed.fulfill()
                }
            }
        }
        poll()
        wait(for: [completed], timeout: 3)
        if let capturedError { throw capturedError }
        return capturedValue
    }

    private static let onePixelPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    )!

    private static let oneFrameMP4 = Data(base64Encoded:
        "AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAAMNbW9vdgAAAGxtdmhkAAAAAAAAAAAAAAAAAAAD6AAAA+gAAQAAAQAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAjd0cmFrAAAAXHRraGQAAAADAAAAAAAAAAAAAAABAAAAAAAAA+gAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAABAAAAAQAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAAPoAAAAAAABAAAAAAGvbWRpYQAAACBtZGhkAAAAAAAAAAAAAAAAAABAAAAAQABVxAAAAAAALWhkbHIAAAAAAAAAAHZpZGUAAAAAAAAAAAAAAABWaWRlb0hhbmRsZXIAAAABWm1pbmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAARpzdGJsAAAAtnN0c2QAAAAAAAAAAQAAAKZhdmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAABAAEABIAAAASAAAAAAAAAABFUxhdmM2Mi4yOC4xMDEgbGlieDI2NAAAAAAAAAAAAAAAGP//AAAALGF2Y0MBQsAK/+EAFWdCwAraewEQAAADABAAAAMAIPEiagEABGjOD8gAAAAQcGFzcAAAAAEAAAABAAAAFGJ0cnQAAAAAAAATOAAAAAAAAAAYc3R0cwAAAAAAAAABAAAAAQAAQAAAAAAcc3RzYwAAAAAAAAABAAAAAQAAAAEAAAABAAAAFHN0c3oAAAAAAAACZwAAAAEAAAAUc3RjbwAAAAAAAAABAAADPQAAAGJ1ZHRhAAAAWm1ldGEAAAAAAAAAIWhkbHIAAAAAAAAAAG1kaXJhcHBsAAAAAAAAAAAAAAAALWlsc3QAAAAlqXRvbwAAAB1kYXRhAAAAAQAAAABMYXZmNjIuMTIuMTAxAAAACGZyZWUAAAJvbWRhdAAAAlUGBf//UdxF6b3m2Ui3lizYINkj7u94MjY0IC0gY29yZSAxNjUgcjMyMjIgYjM1NjA1YSAtIEguMjY0L01QRUctNCBBVkMgY29kZWMgLSBDb3B5bGVmdCAyMDAzLTIwMjUgLSBodHRwOi8vd3d3LnZpZGVvbGFuLm9yZy94MjY0Lmh0bWwgLSBvcHRpb25zOiBjYWJhYz0wIHJlZj0xIGRlYmxvY2s9MDotMzotMyBhbmFseXNpPTA6MCBtZT1kaWEgc3VibWU9MCBwc3k9MSBwc3lfcmQ9Mi4wMDowLjcwIG1peGVkX3JlZj0wIG1lX3JhbmdlPTE2IGNocm9tYV9tZT0xIHRyZWxsaXM9MCA4eDhkY3Q9MCBjcW09MCBkZWFkem9uZT0yMSwxMSBmYXN0X3Bza2lwPTEgY2hyb21hX3FwX29mZnNldD0wIHRocmVhZHM9MSBsb29rYWhlYWRfdGhyZWFkcz0xIHNsaWNlZF90aHJlYWRzPTAgbnI9MCBkZWNpbWF0ZT0xIGludGVybGFjZWQ9MCBibHVyYXlfY29tcGF0PTAgY29uc3RyYWluZWRfaW50cmE9MCBiZnJhbWVzPTAgd2VpZ2h0cD0wIGtleWludD0yNTAga2V5aW50X21pbj0xIHNjZW5lY3V0PTAgaW50cmFfcmVmcmVzaD0wIHJjPWNyZiBtYnRyZWU9MCBjcmY9MjMuMCBxY29tcD0wLjYwIHFwbWluPTAgcXBtYXg9NjkgcXBzdGVwPTQgaXBfcmF0aW89MS40NCBhcT0wAIAAAAAKZYiEOiYoAAkC4A=="
    )!

    private static var shortPCMFile: Data {
        let sampleRate: UInt32 = 8_000
        let samples = Data(repeating: 128, count: 800)
        var data = Data("RIFF".utf8)
        append(UInt32(36 + samples.count), to: &data)
        data.append(Data("WAVEfmt ".utf8))
        append(UInt32(16), to: &data)
        append(UInt16(1), to: &data)
        append(UInt16(1), to: &data)
        append(sampleRate, to: &data)
        append(sampleRate, to: &data)
        append(UInt16(1), to: &data)
        append(UInt16(8), to: &data)
        data.append(Data("data".utf8))
        append(UInt32(samples.count), to: &data)
        data.append(samples)
        return data
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            data.append(contentsOf: bytes)
        }
    }
}

private final class FileWorkspaceMediaRecordingReader: @unchecked Sendable {
    private let lock = NSLock()
    private let data: Data
    private var recordedRequests: [(offset: UInt64, length: UInt64?)] = []

    init(data: Data) {
        self.data = data
    }

    var requests: [(offset: UInt64, length: UInt64?)] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    func read(offset: UInt64, length: UInt64?) -> Data {
        lock.lock()
        recordedRequests.append((offset, length))
        lock.unlock()
        let start = min(Int(offset), data.count)
        let end = min(start + Int(length ?? UInt64(data.count - start)), data.count)
        return data.subdata(in: start..<end)
    }
}
