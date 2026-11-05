import AppKit
import CoreFoundation
import PDFKit
@preconcurrency import QuickLookUI
import StacioCoreBindings
import XCTest
@testable import StacioApp

@MainActor
final class FileTransferDocumentCoordinatorTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioDocumentCoordinatorTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
        temporaryDirectory = nil
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @escaping () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    func testTextDocumentDecodesUTF8UTF16AndGB18030AndPreservesEncodingWhenSaving() throws {
        let chineseText = "\u{914d}\u{7f6e}\u{6587}\u{4ef6}\n"
        let samples: [(FileTransferTextEncoding, Bool, String, Data)] = [
            (.utf8, false, "hello \u{4e16}\u{754c}\n", Data("hello \u{4e16}\u{754c}\n".utf8)),
            (
                .utf16LittleEndian,
                true,
                "little endian\n",
                Data([0xFF, 0xFE]) + (try XCTUnwrap("little endian\n".data(using: .utf16LittleEndian)))
            ),
            (
                .utf16BigEndian,
                true,
                "big endian\n",
                Data([0xFE, 0xFF]) + (try XCTUnwrap("big endian\n".data(using: .utf16BigEndian)))
            ),
            (
                .gb18030,
                false,
                "\u{8fdc}\u{7a0b}\u{6587}\u{4ef6}\n",
                try XCTUnwrap("\u{8fdc}\u{7a0b}\u{6587}\u{4ef6}\n".data(using: Self.gb18030Encoding))
            ),
            (
                .utf16LittleEndian,
                false,
                chineseText,
                try XCTUnwrap(chineseText.data(using: .utf16LittleEndian))
            ),
            (
                .utf16BigEndian,
                false,
                chineseText,
                try XCTUnwrap(chineseText.data(using: .utf16BigEndian))
            )
        ]

        for (expectedEncoding, expectedBOM, expectedText, data) in samples {
            let document = try XCTUnwrap(FileTransferTextDocument.decode(data))
            XCTAssertEqual(document.text, expectedText)
            XCTAssertEqual(document.encoding, expectedEncoding)
            XCTAssertEqual(document.hasByteOrderMark, expectedBOM)

            let updatedText = expectedText + "updated\n"
            let encoded = try document.encodedData(replacingWith: updatedText)
            let roundTrip = try XCTUnwrap(FileTransferTextDocument.decode(encoded))
            XCTAssertEqual(roundTrip.text, updatedText)
            XCTAssertEqual(roundTrip.encoding, expectedEncoding)
            XCTAssertEqual(roundTrip.hasByteOrderMark, expectedBOM)
        }
    }

    func testTextDecoderRejectsHighByteBinaryButKeepsGB18030ChineseText() throws {
        XCTAssertNil(FileTransferTextDocument.decode(Data([0xDE, 0xAD, 0xBE, 0xEF])))

        let expected = "远程配置=开启\n"
        let gb18030Data = try XCTUnwrap(expected.data(using: Self.gb18030Encoding))
        let document = try XCTUnwrap(FileTransferTextDocument.decode(gb18030Data))
        XCTAssertEqual(document.text, expected)
        XCTAssertEqual(document.encoding, .gb18030)
    }

    func testRemoteTextSaveRejectsShortWriteBeforeVerification() throws {
        let document = try XCTUnwrap(FileTransferTextDocument.decode(Data("old\n".utf8)))
        var didReadForVerification = false

        XCTAssertThrowsError(try FileTransferRemoteTextSaveOperation.execute(
            document: document,
            updatedText: "new\n",
            fileName: "app.conf",
            remotePath: "/etc/app.conf",
            write: { data in UInt64(data.count - 1) },
            read: { _ in
                didReadForVerification = true
                return Data()
            }
        )) { error in
            XCTAssertEqual(
                error as? FileTransferDocumentError,
                .remoteWriteVerificationFailed("/etc/app.conf")
            )
        }
        XCTAssertFalse(didReadForVerification)
    }

    func testRemoteTextSaveRejectsTrailingBytesAndReadsOneBytePastPayload() throws {
        let document = try XCTUnwrap(FileTransferTextDocument.decode(Data("old\n".utf8)))
        var writtenData = Data()
        var requestedVerificationLength: UInt64?

        XCTAssertThrowsError(try FileTransferRemoteTextSaveOperation.execute(
            document: document,
            updatedText: "new\n",
            fileName: "app.conf",
            remotePath: "/etc/app.conf",
            write: { data in
                writtenData = data
                return UInt64(data.count)
            },
            read: { length in
                requestedVerificationLength = length
                return writtenData + Data([0x00])
            }
        )) { error in
            XCTAssertEqual(
                error as? FileTransferDocumentError,
                .remoteWriteVerificationFailed("/etc/app.conf")
            )
        }
        XCTAssertEqual(requestedVerificationLength, UInt64(writtenData.count + 1))
    }

    func testAtomicRemoteTextSaveRejectsConcurrentRemoteChangeBeforeWriting() {
        var didWrite = false

        XCTAssertThrowsError(try FileTransferRemoteTextSaveOperation.executeAtomically(
            expectedData: Data("enabled=true\n".utf8),
            updatedData: Data("enabled=false\n".utf8),
            remotePath: "/etc/app.conf",
            read: { _, _ in Data("enabled=external\n".utf8) },
            write: { _, data in
                didWrite = true
                return UInt64(data.count)
            },
            rename: { _, _ in },
            delete: { _ in }
        )) { error in
            XCTAssertEqual(
                error as? FileTransferDocumentError,
                .remoteFileChangedSinceOpen("/etc/app.conf")
            )
        }
        XCTAssertFalse(didWrite)
    }

    func testAtomicRemoteTextSaveRestoresOriginalWhenPromotionFails() {
        let remotePath = "/etc/app.conf"
        let originalData = Data("enabled=true\n".utf8)
        var files = [remotePath: originalData]
        var renameCount = 0

        XCTAssertThrowsError(try FileTransferRemoteTextSaveOperation.executeAtomically(
            expectedData: originalData,
            updatedData: Data("enabled=false\n".utf8),
            remotePath: remotePath,
            read: { path, length in
                Data((files[path] ?? Data()).prefix(Int(length)))
            },
            write: { path, data in
                files[path] = data
                return UInt64(data.count)
            },
            rename: { fromPath, toPath in
                renameCount += 1
                if renameCount == 2 {
                    throw NSError(domain: "StacioTests", code: 1)
                }
                guard let data = files.removeValue(forKey: fromPath) else {
                    throw NSError(domain: "StacioTests", code: 2)
                }
                files[toPath] = data
            },
            delete: { path in _ = files.removeValue(forKey: path) }
        ))

        XCTAssertEqual(files[remotePath], originalData)
        XCTAssertFalse(files.keys.contains { $0.contains(".partial") })
    }

    func testLocalUTF16AndGB18030DocumentsShareMonacoWindowAndSaveInOriginalEncoding() throws {
        let utf16URL = temporaryDirectory.appendingPathComponent("first.conf")
        let gb18030URL = temporaryDirectory.appendingPathComponent("second.txt")
        let utf16Data = Data([0xFF, 0xFE])
            + (try XCTUnwrap("enabled=true\n".data(using: .utf16LittleEndian)))
        try utf16Data.write(to: utf16URL)
        try XCTUnwrap("\u{914d}\u{7f6e}=\u{5f00}\u{542f}\n".data(using: Self.gb18030Encoding)).write(to: gb18030URL)

        let coordinator = FileTransferDocumentCoordinator()
        coordinator.openLocalURL(utf16URL)
        XCTAssertTrue(waitUntil { coordinator.editorWindowControllerForTesting != nil })
        let windowController = try XCTUnwrap(coordinator.editorWindowControllerForTesting)
        let editor = windowController.editorViewController
        XCTAssertEqual(editor.currentTextForTesting, "enabled=true\n")

        editor.replaceTextForTesting("enabled=false\n")
        try editor.performSaveForTesting()
        XCTAssertTrue(waitUntil { editor.activeSaveStateForTesting == .saved })
        let savedUTF16 = try Data(contentsOf: utf16URL)
        XCTAssertTrue(savedUTF16.starts(with: [0xFF, 0xFE]))
        XCTAssertEqual(
            String(data: savedUTF16.dropFirst(2), encoding: .utf16LittleEndian),
            "enabled=false\n"
        )

        coordinator.openLocalURL(gb18030URL)
        XCTAssertTrue(waitUntil { editor.tabTitlesForTesting.count == 2 })
        XCTAssertTrue(coordinator.editorWindowControllerForTesting === windowController)
        XCTAssertEqual(editor.tabTitlesForTesting, ["first.conf", "second.txt"])
        XCTAssertEqual(editor.currentTextForTesting, "\u{914d}\u{7f6e}=\u{5f00}\u{542f}\n")

        editor.replaceTextForTesting("\u{914d}\u{7f6e}=\u{5173}\u{95ed}\n")
        try editor.performSaveForTesting()
        XCTAssertTrue(waitUntil { editor.activeSaveStateForTesting == .saved })
        XCTAssertEqual(
            String(data: try Data(contentsOf: gb18030URL), encoding: Self.gb18030Encoding),
            "\u{914d}\u{7f6e}=\u{5173}\u{95ed}\n"
        )
        windowController.close()
    }

    func testLocalTextReadAndWriteUseInjectedWorkerQueue() throws {
        let fileURL = temporaryDirectory.appendingPathComponent("worker.txt")
        try Data("before\n".utf8).write(to: fileURL)
        let threadRecorder = LocalTextIOThreadRecorder()
        let localTextIO = FileTransferLocalTextIO(
            queue: DispatchQueue(label: "StacioTests.LocalTextIO"),
            readData: { url in
                threadRecorder.recordRead(isMainThread: Thread.isMainThread)
                return try Data(contentsOf: url)
            },
            writeData: { data, url in
                threadRecorder.recordWrite(isMainThread: Thread.isMainThread)
                try data.write(to: url, options: .atomic)
            }
        )
        let coordinator = FileTransferDocumentCoordinator(localTextIO: localTextIO)

        coordinator.openLocalURL(fileURL)

        XCTAssertTrue(waitUntil { coordinator.editorWindowControllerForTesting != nil })
        let editor = try XCTUnwrap(coordinator.editorWindowControllerForTesting?.editorViewController)
        XCTAssertEqual(editor.currentTextForTesting, "before\n")
        editor.replaceTextForTesting("after\n")
        try editor.performSaveForTesting()
        XCTAssertTrue(waitUntil { editor.activeSaveStateForTesting == .saved })

        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "after\n")
        XCTAssertEqual(threadRecorder.readWasMainThread, false)
        XCTAssertEqual(threadRecorder.writeWasMainThread, false)
        coordinator.closeDocumentWindowsForTesting()
    }

    func testStableDocumentIdentitySeparatesSameRemotePathAcrossRuntimesAndDrivesMonacoURI() {
        let firstIdentity = FileTransferDocumentIdentity.remote(
            runtimeID: "runtime-a",
            path: "/etc/app.conf",
            fileName: "app.conf"
        )
        let secondIdentity = FileTransferDocumentIdentity.remote(
            runtimeID: "runtime-b",
            path: "/etc/app.conf",
            fileName: "app.conf"
        )
        let localIdentity = FileTransferDocumentIdentity.local(
            url: URL(fileURLWithPath: "/etc/app.conf")
        )
        XCTAssertNotEqual(firstIdentity.documentID, secondIdentity.documentID)
        XCTAssertNotEqual(firstIdentity.monacoURI, secondIdentity.monacoURI)
        XCTAssertNotEqual(firstIdentity.documentID, localIdentity.documentID)
        XCTAssertTrue(firstIdentity.documentID.contains("remote|runtime-a|/etc/app.conf"))
        XCTAssertTrue(localIdentity.documentID.contains("local|/etc/app.conf"))

        let first = RemoteTextEditorDocumentDescriptor(
            documentID: firstIdentity.documentID,
            monacoURI: firstIdentity.monacoURI,
            remotePath: "/etc/app.conf",
            fileName: "app.conf",
            content: "first=true\n",
            encodingDisplayName: "UTF-16 LE"
        )
        let second = RemoteTextEditorDocumentDescriptor(
            documentID: secondIdentity.documentID,
            monacoURI: secondIdentity.monacoURI,
            remotePath: "/etc/app.conf",
            fileName: "app.conf",
            content: "second=true\n",
            encodingDisplayName: "GB18030"
        )
        let editor = RemoteTextEditorViewController(document: first)
        editor.openDocument(second)

        XCTAssertEqual(editor.documentIDsForTesting, [firstIdentity.documentID, secondIdentity.documentID])
        XCTAssertEqual(editor.documentMonacoURIsForTesting, [firstIdentity.monacoURI, secondIdentity.monacoURI])
        XCTAssertEqual(editor.tabTitlesForTesting, ["app.conf", "app.conf"])
        XCTAssertEqual(editor.currentTextForTesting, "second=true\n")
        XCTAssertEqual(editor.encodingTextForTesting, "GB18030")
        XCTAssertTrue(editor.editorHTMLForTesting.contains("monaco.Uri.parse(document.monacoURI"))
    }

    func testAsyncSaveTransitionsThroughSavingAndKeepsNewerEditsDirty() {
        let identity = FileTransferDocumentIdentity.remote(
            runtimeID: "runtime-save",
            path: "/etc/save.conf",
            fileName: "save.conf"
        )
        let descriptor = RemoteTextEditorDocumentDescriptor(
            documentID: identity.documentID,
            monacoURI: identity.monacoURI,
            remotePath: "/etc/save.conf",
            fileName: "save.conf",
            content: "value=old\n",
            encodingDisplayName: "UTF-8"
        )
        var completion: ((Result<Void, Error>) -> Void)?
        let editor = RemoteTextEditorViewController(
            document: descriptor,
            onSaveTextAsync: { _, callback in completion = callback }
        )
        editor.replaceTextForTesting("value=saving\n")

        XCTAssertNoThrow(try editor.performSaveForTesting())
        XCTAssertEqual(editor.activeSaveStateForTesting, .saving)

        editor.replaceTextForTesting("value=newer\n")
        completion?(.success(()))

        XCTAssertEqual(editor.currentTextForTesting, "value=newer\n")
        XCTAssertEqual(editor.activeSaveStateForTesting, .dirty)
        XCTAssertTrue(editor.hasUnsavedChangesForTesting)
    }

    func testBinaryUsesPagedReadOnlyHexViewerAndCanExportWithoutWholeFileRead() throws {
        let data = Data((0..<50).map(UInt8.init))
        let source = FileWorkspaceHexDocument(
            sourceID: "binary",
            fileName: "payload.bin",
            byteCount: UInt64(data.count),
            reader: { offset, length in
                let lowerBound = min(Int(offset), data.count)
                let upperBound = min(lowerBound + Int(length), data.count)
                return data.subdata(in: lowerBound..<upperBound)
            }
        )
        let controller = FileWorkspaceHexViewController(document: source, pageSize: 16)
        controller.loadView()

        XCTAssertTrue(controller.isReadOnlyForTesting)
        XCTAssertEqual(controller.pageCountForTesting, 4)
        XCTAssertEqual(controller.byteRangeForPageForTesting(2), 32..<48)
        XCTAssertEqual(
            FileWorkspaceHexFormatter.string(data: Data([0x41, 0x00, 0x7F]), startingAt: 32),
            "00000020  41 00 7F                                         |A..|"
        )

        let destination = temporaryDirectory.appendingPathComponent("saved-copy.bin")
        try source.export(to: destination, chunkSize: 13)
        XCTAssertEqual(try Data(contentsOf: destination), data)
    }

    func testHexExportRejectsSourceDestinationAndFailurePreservesExistingTarget() throws {
        let sourceURL = temporaryDirectory.appendingPathComponent("source.bin")
        try Data([0x01, 0x02, 0x03]).write(to: sourceURL)
        let localDocument = try FileWorkspaceHexDocument.localFile(sourceURL)

        XCTAssertThrowsError(try localDocument.export(to: sourceURL)) { error in
            XCTAssertEqual(error as? FileWorkspaceHexDocumentError, .sourceAndDestinationMatch)
        }

        let destination = temporaryDirectory.appendingPathComponent("existing.bin")
        let originalDestination = Data("keep-me".utf8)
        try originalDestination.write(to: destination)
        let failingDocument = FileWorkspaceHexDocument(
            sourceID: "failing",
            fileName: "failing.bin",
            byteCount: 8,
            reader: { _, _ in throw CocoaError(.fileReadUnknown) }
        )

        XCTAssertThrowsError(try failingDocument.export(to: destination, chunkSize: 4))
        XCTAssertEqual(try Data(contentsOf: destination), originalDestination)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path)
                .contains { $0.hasPrefix(".stacio-hex-") }
        )
    }

    func testLocalBinaryPDFOfficeUnknownAndLargeTextUseHonestViewerRoutes() throws {
        let binaryURL = temporaryDirectory.appendingPathComponent("firmware.bin")
        try Data([0x00, 0xFF, 0x10]).write(to: binaryURL)
        let disguisedBinaryURL = temporaryDirectory.appendingPathComponent("not-really-text.txt")
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: disguisedBinaryURL)
        let pdfURL = temporaryDirectory.appendingPathComponent("manual.pdf")
        let pdf = PDFDocument()
        let image = NSImage(size: NSSize(width: 32, height: 32))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()
        pdf.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        XCTAssertTrue(pdf.write(to: pdfURL))
        let officeURL = temporaryDirectory.appendingPathComponent("report.docx")
        try Data("office".utf8).write(to: officeURL)
        let unknownURL = temporaryDirectory.appendingPathComponent("sample.unregistered-format")
        try Data([1, 2, 3]).write(to: unknownURL)
        let unknownTextURL = temporaryDirectory.appendingPathComponent("notes.custom-text")
        try Data("unknown extension text\n".utf8).write(to: unknownTextURL)
        let namedTextURLs = ["certificate.pem", "host.pub", "change.diff", "fix.patch", "build.gradle", "deps.lock"]
            .map { temporaryDirectory.appendingPathComponent($0) }
        for url in namedTextURLs {
            try Data("text for \(url.lastPathComponent)\n".utf8).write(to: url)
        }
        let largeTextURL = temporaryDirectory.appendingPathComponent("service.log")
        XCTAssertTrue(FileManager.default.createFile(atPath: largeTextURL.path, contents: nil))
        let largeTextHandle = try FileHandle(forWritingTo: largeTextURL)
        try largeTextHandle.truncate(atOffset: 10 * 1_024 * 1_024 + 1)
        try largeTextHandle.close()

        let coordinator = FileTransferDocumentCoordinator()
        coordinator.openLocalURL(binaryURL)
        XCTAssertEqual(coordinator.hexWindowControllersForTesting.count, 1)
        XCTAssertNil(coordinator.editorWindowControllerForTesting)
        coordinator.openLocalURL(disguisedBinaryURL)
        XCTAssertTrue(waitUntil { coordinator.hexWindowControllersForTesting.count == 2 })
        XCTAssertEqual(coordinator.hexWindowControllersForTesting.count, 2)
        XCTAssertNil(coordinator.editorWindowControllerForTesting)

        coordinator.openLocalURL(pdfURL)
        let pdfWindow = try XCTUnwrap(coordinator.pdfWindowControllersForTesting.first)
        XCTAssertEqual(pdfWindow.pdfViewController.pdfViewForTesting.document?.pageCount, 1)

        coordinator.openLocalURL(unknownTextURL)
        for url in namedTextURLs {
            coordinator.openLocalURL(url)
        }
        XCTAssertTrue(waitUntil {
            coordinator.editorWindowControllerForTesting?.editorViewController.tabTitlesForTesting.count
                == namedTextURLs.count + 1
        })
        let editor = try XCTUnwrap(coordinator.editorWindowControllerForTesting?.editorViewController)
        XCTAssertEqual(
            editor.tabTitlesForTesting,
            [unknownTextURL.lastPathComponent] + namedTextURLs.map(\.lastPathComponent)
        )
        coordinator.editorWindowControllerForTesting?.close()

        for url in [officeURL, unknownURL, largeTextURL] {
            coordinator.openLocalURL(url)
            XCTAssertTrue(waitUntil {
                coordinator.quickLookCoordinatorForTesting.previewURLsForTesting == [url.standardizedFileURL]
            })
            XCTAssertEqual(coordinator.quickLookCoordinatorForTesting.previewURLsForTesting, [url.standardizedFileURL])
            XCTAssertNil(coordinator.editorWindowControllerForTesting)
        }

        coordinator.closeDocumentWindowsForTesting()
    }

    func testPendingPreparationRegistryCleansFailureCancelAndTransfersSuccessfulRootOwnership() throws {
        let registry = FileTransferPendingPreparationRegistry()
        var canceledJobIDs: [String] = []
        let failedRoot = temporaryDirectory.appendingPathComponent("failed", isDirectory: true)
        try FileManager.default.createDirectory(at: failedRoot, withIntermediateDirectories: true)
        let failedID = registry.register(root: failedRoot, jobID: "job-failed") {
            canceledJobIDs.append($0)
        }
        registry.finish(id: failedID, outcome: .failure)
        XCTAssertFalse(FileManager.default.fileExists(atPath: failedRoot.path))
        XCTAssertEqual(registry.pendingCountForTesting, 0)

        let successRoot = temporaryDirectory.appendingPathComponent("success", isDirectory: true)
        try FileManager.default.createDirectory(at: successRoot, withIntermediateDirectories: true)
        let successID = registry.register(root: successRoot, jobID: "job-success") {
            canceledJobIDs.append($0)
        }
        registry.finish(id: successID, outcome: .successTransfersRoot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: successRoot.path))
        XCTAssertEqual(registry.pendingCountForTesting, 0)

        let canceledRoot = temporaryDirectory.appendingPathComponent("canceled", isDirectory: true)
        try FileManager.default.createDirectory(at: canceledRoot, withIntermediateDirectories: true)
        _ = registry.register(root: canceledRoot, jobID: "job-canceled") {
            canceledJobIDs.append($0)
        }
        registry.cancelAll()
        XCTAssertEqual(canceledJobIDs, ["job-canceled"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: canceledRoot.path))
        XCTAssertEqual(registry.pendingCountForTesting, 0)
    }

    func testProductionCloseDocumentWindowsIsIdempotentAndReleasesEveryPresenter() throws {
        let textURL = temporaryDirectory.appendingPathComponent("notes.txt")
        try Data("hello\n".utf8).write(to: textURL)
        let imageURL = temporaryDirectory.appendingPathComponent("image.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: imageURL)
        let binaryURL = temporaryDirectory.appendingPathComponent("payload.bin")
        try Data([0xDE, 0xAD, 0xBE, 0xEF]).write(to: binaryURL)
        let pdfURL = temporaryDirectory.appendingPathComponent("manual.pdf")
        let pdf = PDFDocument()
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()
        pdf.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        XCTAssertTrue(pdf.write(to: pdfURL))
        let archiveURL = temporaryDirectory.appendingPathComponent("archive.zip")
        try Data([0x50, 0x4B]).write(to: archiveURL)

        let coordinator = FileTransferDocumentCoordinator()
        coordinator.openLocalURL(textURL)
        coordinator.openLocalURL(imageURL)
        coordinator.openLocalURL(binaryURL)
        coordinator.openLocalURL(pdfURL)
        coordinator.openLocalURL(archiveURL)
        XCTAssertTrue(waitUntil { coordinator.editorWindowControllerForTesting != nil })
        XCTAssertNotNil(coordinator.editorWindowControllerForTesting)
        XCTAssertEqual(coordinator.mediaWindowCountForTesting, 1)
        XCTAssertEqual(coordinator.mediaSourceURLsForTesting.first?.scheme, "http")
        XCTAssertEqual(coordinator.mediaSourceURLsForTesting.first?.host, "127.0.0.1")
        XCTAssertEqual(coordinator.hexWindowControllersForTesting.count, 1)
        XCTAssertEqual(coordinator.pdfWindowControllersForTesting.count, 1)
        XCTAssertEqual(coordinator.quickLookCoordinatorForTesting.previewURLsForTesting, [archiveURL])

        coordinator.closeDocumentWindows()
        coordinator.closeDocumentWindows()

        XCTAssertNil(coordinator.editorWindowControllerForTesting)
        XCTAssertEqual(coordinator.mediaWindowCountForTesting, 0)
        XCTAssertTrue(coordinator.hexWindowControllersForTesting.isEmpty)
        XCTAssertTrue(coordinator.pdfWindowControllersForTesting.isEmpty)
        XCTAssertTrue(coordinator.quickLookCoordinatorForTesting.previewURLsForTesting.isEmpty)
    }

    func testCloseDuringDirectRemotePDFPreparationStopsChunkReadsAndDoesNotReopen() {
        let bridge = BlockingDocumentPreparationRemoteFilesBridge()
        var statuses: [String] = []
        let source = FileTransferRemoteDocumentSource(
            runtimeID: "runtime-close",
            context: TunnelLiveSessionContext(
                config: SshConnectionConfig(
                    host: "files.example.com",
                    port: 22,
                    username: "deploy",
                    authMethod: .agent,
                    connectTimeoutMs: 10_000
                ),
                secret: .agent,
                expectedFingerprintSHA256: "SHA256:files"
            ),
            bridge: bridge,
            transferScheduler: nil,
            setStatus: { statuses.append($0) }
        )
        let coordinator = FileTransferDocumentCoordinator()

        coordinator.openRemoteSelection(
            RemoteFileSelection(path: "/srv/manual.pdf", size: 2_500_000),
            source: source
        )
        XCTAssertEqual(bridge.waitUntilFirstReadStarts(), .success)

        coordinator.closeDocumentWindows()
        bridge.releaseFirstRead()
        let backgroundWorkSettled = expectation(description: "background preparation settles")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            backgroundWorkSettled.fulfill()
        }
        wait(for: [backgroundWorkSettled], timeout: 1)

        XCTAssertEqual(bridge.readCount, 1)
        XCTAssertEqual(bridge.readSessionOpenCount, 1)
        XCTAssertEqual(bridge.readSessionCloseCount, 1)
        XCTAssertTrue(coordinator.pdfWindowControllersForTesting.isEmpty)
        XCTAssertFalse(statuses.contains("已打开 manual.pdf"))
    }

    func testQuickLookExposesDefaultApplicationOpenForCurrentLocalOrPreparedRemoteURL() {
        let url = temporaryDirectory.appendingPathComponent("archive.zip")
        var openedURLs: [URL] = []
        let coordinator = FileWorkspaceQuickLookCoordinator(openURL: { openedURLs.append($0); return true })
        coordinator.present(urls: [url])

        XCTAssertTrue(coordinator.openCurrentWithDefaultApplication())
        XCTAssertEqual(openedURLs, [url.standardizedFileURL])
        coordinator.closePreview()
    }

    func testQuickLookCoordinatorOwnsAndReleasesPreviewPanelControl() throws {
        let coordinator = FileWorkspaceQuickLookCoordinator()
        let panel = try XCTUnwrap(QLPreviewPanel.shared())

        XCTAssertTrue(coordinator.acceptsPreviewPanelControl(panel))
        coordinator.beginPreviewPanelControl(panel)
        XCTAssertTrue(panel.dataSource === coordinator)
        XCTAssertTrue(panel.delegate === coordinator)

        coordinator.endPreviewPanelControl(panel)
        XCTAssertNil(panel.dataSource)
        XCTAssertNil(panel.delegate)
    }

    func testQuickLookPresentReclaimsSharedPanelFromAStaleController() throws {
        let stale = FileWorkspaceQuickLookCoordinator()
        let current = FileWorkspaceQuickLookCoordinator()
        let panel = try XCTUnwrap(QLPreviewPanel.shared())
        let previewURL = temporaryDirectory.appendingPathComponent("local-preview.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: previewURL)
        stale.beginPreviewPanelControl(panel)

        current.present(urls: [previewURL])

        XCTAssertTrue(panel.dataSource === current)
        XCTAssertTrue(panel.delegate === current)
        XCTAssertEqual(current.previewURLsForTesting, [previewURL.standardizedFileURL])
        current.closePreview()
    }

    func testRemoteQuickLookShowsLoadingImmediatelyAndSchedulesSilentCacheTransfer() throws {
        let scheduler = QuickLookRecordingTransferScheduler()
        scheduler.materializesCompletedDownloads = true
        let source = FileTransferRemoteDocumentSource(
            runtimeID: "quicklook-loading",
            context: TunnelLiveSessionContext(
                config: SshConnectionConfig(
                    host: "files.example.com",
                    port: 22,
                    username: "deploy",
                    authMethod: .agent,
                    connectTimeoutMs: 10_000
                ),
                secret: .agent,
                expectedFingerprintSHA256: "SHA256:files"
            ),
            bridge: DirectoryQuickLookRemoteFilesBridge(listings: [:], dataByPath: [:]),
            transferScheduler: scheduler,
            setStatus: { _ in }
        )
        let coordinator = FileTransferDocumentCoordinator()

        coordinator.quickLookRemoteSelections(
            [RemoteFileSelection(path: "/srv/preview.png", size: 4)],
            source: source
        )

        XCTAssertTrue(coordinator.quickLookCoordinatorForTesting.isLoadingForTesting)
        XCTAssertEqual(scheduler.notificationPolicies, [.silent])
        scheduler.complete(jobAt: 0, status: "completed")
        XCTAssertTrue(waitUntil {
            coordinator.quickLookCoordinatorForTesting.previewURLsForTesting.count == 1
        })
        XCTAssertFalse(coordinator.quickLookCoordinatorForTesting.isLoadingForTesting)
        coordinator.closeDocumentWindowsForTesting()
    }

    func testRemoteDocumentPreparationSchedulesSilentCacheTransfer() {
        let scheduler = QuickLookRecordingTransferScheduler()
        let source = FileTransferRemoteDocumentSource(
            runtimeID: "document-silent-cache",
            context: TunnelLiveSessionContext(
                config: SshConnectionConfig(
                    host: "files.example.com",
                    port: 22,
                    username: "deploy",
                    authMethod: .agent,
                    connectTimeoutMs: 10_000
                ),
                secret: .agent,
                expectedFingerprintSHA256: "SHA256:files"
            ),
            bridge: DirectoryQuickLookRemoteFilesBridge(listings: [:], dataByPath: [:]),
            transferScheduler: scheduler,
            setStatus: { _ in }
        )
        let coordinator = FileTransferDocumentCoordinator()

        coordinator.openRemoteSelection(
            RemoteFileSelection(path: "/srv/manual.pdf", size: 2_500_000),
            source: source
        )

        XCTAssertEqual(scheduler.notificationPolicies, [.silent])
        coordinator.closeDocumentWindowsForTesting()
    }

    func testRemoteQuickLookLoadingPanelUsesNativePopoverMaterialInDarkMode() throws {
        let coordinator = FileWorkspaceQuickLookCoordinator()
        coordinator.showLoading(message: "正在准备一项名称较长的远端文件快速预览...")
        defer { coordinator.dismissLoading() }

        let panel = try XCTUnwrap(coordinator.loadingPanelForTesting)
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView?.layoutSubtreeIfNeeded()
        let materialView = try XCTUnwrap(panel.contentView as? NSVisualEffectView)
        XCTAssertEqual(materialView.material, .popover)
        XCTAssertEqual(panel.contentLayoutRect.size, NSSize(width: 292, height: 84))
        XCTAssertFalse(materialView.quickLookDescendants.contains(where: \.hasAmbiguousLayout))

        let progressIndicator = try XCTUnwrap(
            materialView.quickLookDescendants.compactMap { $0 as? NSProgressIndicator }.first
        )
        XCTAssertEqual(progressIndicator.style, .spinning)
        XCTAssertTrue(progressIndicator.isIndeterminate)
        let label = try XCTUnwrap(
            materialView.quickLookDescendants
                .compactMap { $0 as? NSTextField }
                .first(where: { $0.stringValue.contains("远端文件快速预览") })
        )
        XCTAssertEqual(label.textColor, .labelColor)
        XCTAssertEqual(label.lineBreakMode, .byTruncatingTail)
    }

    func testRemoteQuickLookDismissesLoadingWhenCacheTransferFails() {
        let scheduler = QuickLookRecordingTransferScheduler()
        var statuses: [String] = []
        let source = FileTransferRemoteDocumentSource(
            runtimeID: "quicklook-failure",
            context: TunnelLiveSessionContext(
                config: SshConnectionConfig(
                    host: "files.example.com",
                    port: 22,
                    username: "deploy",
                    authMethod: .agent,
                    connectTimeoutMs: 10_000
                ),
                secret: .agent,
                expectedFingerprintSHA256: "SHA256:files"
            ),
            bridge: DirectoryQuickLookRemoteFilesBridge(listings: [:], dataByPath: [:]),
            transferScheduler: scheduler,
            setStatus: { statuses.append($0) }
        )
        let coordinator = FileTransferDocumentCoordinator()

        coordinator.quickLookRemoteSelections(
            [RemoteFileSelection(path: "/srv/missing.png", size: 4)],
            source: source
        )
        XCTAssertTrue(coordinator.quickLookCoordinatorForTesting.isLoadingForTesting)

        scheduler.complete(jobAt: 0, status: "failed")

        XCTAssertTrue(waitUntil {
            coordinator.quickLookCoordinatorForTesting.isLoadingForTesting == false
        })
        XCTAssertTrue(coordinator.quickLookCoordinatorForTesting.previewURLsForTesting.isEmpty)
        XCTAssertEqual(statuses.last, FileTransferDocumentError.previewPreparationFailed("missing.png").localizedDescription)
        coordinator.closeDocumentWindowsForTesting()
    }

    func testClosingRemoteQuickLookDismissesLoadingAndCancelsCacheTransfer() {
        let scheduler = QuickLookRecordingTransferScheduler()
        let source = FileTransferRemoteDocumentSource(
            runtimeID: "quicklook-cancel",
            context: TunnelLiveSessionContext(
                config: SshConnectionConfig(
                    host: "files.example.com",
                    port: 22,
                    username: "deploy",
                    authMethod: .agent,
                    connectTimeoutMs: 10_000
                ),
                secret: .agent,
                expectedFingerprintSHA256: "SHA256:files"
            ),
            bridge: DirectoryQuickLookRemoteFilesBridge(listings: [:], dataByPath: [:]),
            transferScheduler: scheduler,
            setStatus: { _ in }
        )
        let coordinator = FileTransferDocumentCoordinator()

        coordinator.quickLookRemoteSelections(
            [RemoteFileSelection(path: "/srv/cancel.png", size: 4)],
            source: source
        )
        XCTAssertTrue(coordinator.quickLookCoordinatorForTesting.isLoadingForTesting)

        coordinator.closeDocumentWindowsForTesting()

        XCTAssertFalse(coordinator.quickLookCoordinatorForTesting.isLoadingForTesting)
        XCTAssertTrue(scheduler.pendingJobIDs.isEmpty)
    }

    func testQuickLookKeepsPreparedRemoteCopyUntilReplacementOrClose() throws {
        let firstRoot = temporaryDirectory.appendingPathComponent("first-remote", isDirectory: true)
        let secondRoot = temporaryDirectory.appendingPathComponent("second-remote", isDirectory: true)
        try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
        let firstURL = firstRoot.appendingPathComponent("first.docx")
        let secondURL = secondRoot.appendingPathComponent("second.zip")
        try Data("first".utf8).write(to: firstURL)
        try Data("second".utf8).write(to: secondURL)
        let coordinator = FileWorkspaceQuickLookCoordinator()

        coordinator.present(urls: [firstURL], temporaryRoots: [firstRoot])
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstURL.path))

        coordinator.present(urls: [secondURL], temporaryRoots: [secondRoot])
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstRoot.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondURL.path))

        coordinator.closePreview()
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondRoot.path))
    }

    func testRemoteQuickLookDirectoryStagesNestedFilesWhenTransferQueueIsUnavailable() throws {
        let nestedFile = Data("enabled=true\n".utf8)
        let bridge = DirectoryQuickLookRemoteFilesBridge(
            listings: [
                "/srv/assets": [
                    RemoteFileEntry(
                        kind: .directory,
                        path: "/srv/assets/config",
                        size: 0,
                        modifiedTime: nil,
                        linkTarget: nil,
                        owner: nil,
                        permissions: nil
                    ),
                    RemoteFileEntry(
                        kind: .file,
                        path: "/srv/assets/readme.txt",
                        size: UInt64(Data("hello remote\n".utf8).count),
                        modifiedTime: nil,
                        linkTarget: nil,
                        owner: nil,
                        permissions: nil
                    )
                ],
                "/srv/assets/config": [
                    RemoteFileEntry(
                        kind: .file,
                        path: "/srv/assets/config/app.conf",
                        size: UInt64(nestedFile.count),
                        modifiedTime: nil,
                        linkTarget: nil,
                        owner: nil,
                        permissions: nil
                    )
                ]
            ],
            dataByPath: [
                "/srv/assets/readme.txt": Data("hello remote\n".utf8),
                "/srv/assets/config/app.conf": nestedFile
            ]
        )
        let source = FileTransferRemoteDocumentSource(
            runtimeID: "quicklook-directory",
            context: TunnelLiveSessionContext(
                config: SshConnectionConfig(
                    host: "files.example.com",
                    port: 22,
                    username: "deploy",
                    authMethod: .agent,
                    connectTimeoutMs: 10_000
                ),
                secret: .agent,
                expectedFingerprintSHA256: "SHA256:files"
            ),
            bridge: bridge,
            transferScheduler: nil,
            setStatus: { _ in }
        )
        let coordinator = FileTransferDocumentCoordinator()

        coordinator.quickLookRemoteSelections(
            [RemoteFileSelection(path: "/srv/assets", size: 0, kind: .directory)],
            source: source
        )

        XCTAssertTrue(waitUntil {
            coordinator.quickLookCoordinatorForTesting.previewURLsForTesting.count == 1
        })
        let previewURL = try XCTUnwrap(coordinator.quickLookCoordinatorForTesting.previewURLsForTesting.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: previewURL.appendingPathComponent("readme.txt").path))
        XCTAssertEqual(
            try String(contentsOf: previewURL.appendingPathComponent("config/app.conf"), encoding: .utf8),
            "enabled=true\n"
        )
        coordinator.closeDocumentWindowsForTesting()
    }

private static let gb18030Encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
    ))
}

private final class LocalTextIOThreadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var readWasMainThreadStorage: Bool?
    private var writeWasMainThreadStorage: Bool?

    var readWasMainThread: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return readWasMainThreadStorage
    }

    var writeWasMainThread: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return writeWasMainThreadStorage
    }

    func recordRead(isMainThread: Bool) {
        lock.lock()
        readWasMainThreadStorage = isMainThread
        lock.unlock()
    }

    func recordWrite(isMainThread: Bool) {
        lock.lock()
        writeWasMainThreadStorage = isMainThread
        lock.unlock()
    }
}

private extension NSView {
    var quickLookDescendants: [NSView] {
        subviews + subviews.flatMap(\.quickLookDescendants)
    }
}

private final class BlockingDocumentPreparationRemoteFilesBridge: RemoteFilesBridging, @unchecked Sendable {
    private let lock = NSLock()
    private let firstReadStarted = DispatchSemaphore(value: 0)
    private let releaseGate = DispatchSemaphore(value: 0)
    private var readCountStorage = 0
    private var readSessionOpenCountStorage = 0
    private var readSessionCloseCountStorage = 0

    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return readCountStorage
    }

    var readSessionOpenCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return readSessionOpenCountStorage
    }

    var readSessionCloseCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return readSessionCloseCountStorage
    }

    func waitUntilFirstReadStarts() -> DispatchTimeoutResult {
        firstReadStarted.wait(timeout: .now() + 1)
    }

    func releaseFirstRead() {
        releaseGate.signal()
    }

    func parseRemoteListing(_ input: String) throws -> [RemoteFileEntry] { [] }

    func listLiveRemoteDirectory(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String
    ) throws -> [RemoteFileEntry] { [] }

    func createLiveRemoteDirectory(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String
    ) throws {}

    func renameLiveRemotePath(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        fromPath: String,
        toPath: String
    ) throws {}

    func deleteLiveRemotePath(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String,
        recursive: Bool
    ) throws {}

    func chmodLiveRemotePath(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String,
        mode: String
    ) throws {}

    func readLiveRemoteFile(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String,
        offset: UInt64,
        length: UInt64?
    ) throws -> Data {
        try performRead(length: length)
    }

    func openLiveRemoteFileReadSession(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String
    ) throws -> RemoteFileReadSession? {
        lock.lock()
        readSessionOpenCountStorage += 1
        lock.unlock()
        return RemoteFileReadSession(
            read: { [self] _, _, length in
                try performRead(length: length)
            },
            close: { [self] in
                lock.lock()
                readSessionCloseCountStorage += 1
                lock.unlock()
            }
        )
    }

    private func performRead(length: UInt64?) throws -> Data {
        lock.lock()
        readCountStorage += 1
        let currentRead = readCountStorage
        lock.unlock()
        if currentRead == 1 {
            firstReadStarted.signal()
            _ = releaseGate.wait(timeout: .now() + 1)
        }
        return Data(repeating: 0x20, count: Int(length ?? 0))
    }
}

@MainActor
private final class QuickLookRecordingTransferScheduler: SCPTransferScheduling {
    private(set) var jobs: [ScpTransferJob] = []
    private(set) var notificationPolicies: [TransferCompletionNotificationPolicy] = []
    var materializesCompletedDownloads = false
    private var completions: [String: (ScpTransferProgress) -> Void] = [:]

    var pendingJobIDs: Set<String> {
        Set(completions.keys)
    }

    func scheduleLiveTransfer(
        runtimeID: String,
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        job: ScpTransferJob,
        completion: ((ScpTransferProgress) -> Void)?
    ) {
        scheduleLiveTransfer(
            runtimeID: runtimeID,
            config: config,
            secret: secret,
            expectedFingerprintSHA256: expectedFingerprintSHA256,
            job: job,
            notificationPolicy: .userVisible,
            completion: completion
        )
    }

    func scheduleLiveTransfer(
        runtimeID: String,
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        job: ScpTransferJob,
        notificationPolicy: TransferCompletionNotificationPolicy,
        completion: ((ScpTransferProgress) -> Void)?
    ) {
        jobs.append(job)
        notificationPolicies.append(notificationPolicy)
        completions[job.id] = completion
    }

    func disconnectTransfers(runtimeID: String) -> [String] { [] }
    func cancelTransfer(jobID: String) -> Bool { completions.removeValue(forKey: jobID) != nil }
    func updateScheduledTransferEstimatedByteTotal(jobID: String, bytesTotal: UInt64) {}

    func complete(jobAt index: Int, status: String) {
        guard jobs.indices.contains(index) else { return }
        let job = jobs[index]
        if status == "completed", materializesCompletedDownloads {
            let destination = URL(fileURLWithPath: job.destinationPath)
            try? FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(
                atPath: destination.path,
                contents: Data(repeating: 0x41, count: Int(clamping: job.bytesTotal))
            )
        }
        completions.removeValue(forKey: job.id)?(ScpTransferProgress(
            jobId: job.id,
            bytesDone: status == "completed" ? job.bytesTotal : 0,
            bytesTotal: job.bytesTotal,
            status: status
        ))
    }
}

private final class DirectoryQuickLookRemoteFilesBridge: RemoteFilesBridging, @unchecked Sendable {
    private let listings: [String: [RemoteFileEntry]]
    private let dataByPath: [String: Data]

    init(listings: [String: [RemoteFileEntry]], dataByPath: [String: Data]) {
        self.listings = listings
        self.dataByPath = dataByPath
    }

    func parseRemoteListing(_ input: String) throws -> [RemoteFileEntry] { [] }

    func listLiveRemoteDirectory(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String
    ) throws -> [RemoteFileEntry] {
        listings[remotePath] ?? []
    }

    func createLiveRemoteDirectory(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String
    ) throws {}

    func renameLiveRemotePath(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        fromPath: String,
        toPath: String
    ) throws {}

    func deleteLiveRemotePath(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String,
        recursive: Bool
    ) throws {}

    func chmodLiveRemotePath(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String,
        mode: String
    ) throws {}

    func readLiveRemoteFile(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String,
        offset: UInt64,
        length: UInt64?
    ) throws -> Data {
        let data = dataByPath[remotePath] ?? Data()
        let start = min(Int(offset), data.count)
        let requestedEnd = length.map { start + Int($0) } ?? data.count
        let end = min(requestedEnd, data.count)
        return data.subdata(in: start..<end)
    }
}
