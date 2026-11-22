import AppKit
import XCTest
@testable import StacioApp

final class AgentImageTests: XCTestCase {
    func testImagePayloadCarriesTheNumberAndBytesInAttachmentOrder() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let images = try [(3, "iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAAb0lEQVR4nO3PAQkAAAyEwO9feoshgnABdNvJ8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ2oPcf88OIhvJ6vAAAAAElFTkSuQmCC"), (8, "iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAAb0lEQVR4nO3PAQkAAAyEwO9feoshgnABdLep8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3IPanc8OLDQitxAAAAAElFTkSuQmCC")].map { number, png in
            try AgentImages.save(XCTUnwrap(Data(base64Encoded: png)), in: directory, number: number)
        }
        let parts = try XCTUnwrap(AgentImages.content(text: "先看@图片8", images: images) as? [[String: Any]])
        XCTAssertEqual(parts.compactMap { $0["text"] as? String }, ["先看@图片8", "@图片3", "@图片8"])
        for (index, part) in [parts[2], parts[4]].enumerated() {
            let uri = try XCTUnwrap((part["image_url"] as? [String: String])?["url"])
            let data = try XCTUnwrap(Data(base64Encoded: String(uri.dropFirst("data:image/png;base64,".count))))
            let pixel = try XCTUnwrap(NSBitmapImageRep(data: data)?.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))
            XCTAssertEqual(pixel.redComponent, index == 1 ? 1 : 0, accuracy: 0.02)
            XCTAssertEqual(pixel.blueComponent, index == 0 ? 1 : 0, accuracy: 0.02)
        }
    }

    @MainActor func testPreviewFromThumbnailCanCloseAndReopen() throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let chip = try AgentImages.save(XCTUnwrap(bitmap.representation(using: .png, properties: [:])), in: directory, number: 1)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        let host = try XCTUnwrap(window.contentView)
        let tile = AgentImageTile(chip)
        host.addSubview(tile)
        tile.performClick(nil)
        let overlay = try XCTUnwrap(host.subviews.last)
        XCTAssertTrue(overlay !== tile)
        XCTAssertEqual(overlay.frame, host.bounds)
        try XCTUnwrap(overlay.subviews.compactMap { $0 as? NSButton }.first).performClick(nil)
        XCTAssertNil(overlay.superview)
        tile.performClick(nil)
        let reopened = try XCTUnwrap(host.subviews.last)
        reopened.mouseDown(with: try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 2, y: 2), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)))
        XCTAssertNil(reopened.superview)
    }
}

extension AgentImageTests {
    @MainActor func testCommandVPastesImageOnlyForUnmodifiedPasteShortcut() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let editor = AgentComposerEditor()
        var captured: [Data] = []
        editor.pasteImage = { captured.append($0) }
        func key(_ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9))
        }
        let payload = Data([1, 2, 3])
        board.setData(payload, forType: .png)
        XCTAssertFalse(editor.handleImagePasteShortcut(try key([.command, .shift]), board: board))
        XCTAssertTrue(editor.handleImagePasteShortcut(try key(.command), board: board))
        XCTAssertEqual(captured, [payload])
        board.clearContents()
        board.setString("文字", forType: .string)
        XCTAssertFalse(editor.handleImagePasteShortcut(try key(.command), board: board))
    }

    @MainActor func testHistoryRecordingAndRetentionUseAgentStore() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AgentStore(rootDirectory: directory)
        var old = AgentConversation(isDraft: false)
        old.updatedAt = .distantPast
        var tool = AgentToolInvocation(id: "test-id", name: "test", title: "test", argumentsJSON: "{}", output: "private terminal output")
        tool.recordingScope = "none"
        old.items = [AgentItem(kind: .tool, tool: tool)]
        store.save(old, immediately: true)
        XCTAssertEqual(store.load(id: old.id)?.items.first?.tool?.output, "")
        let latest = AgentConversation(isDraft: false)
        store.save(latest)
        store.removeHistory(before: Date().addingTimeInterval(-86400))
        XCTAssertNil(store.load(id: old.id))
        XCTAssertNotNil(store.load(id: latest.id))
        store.removeHistory()
        XCTAssertTrue(store.loadAll().isEmpty)
    }
}
