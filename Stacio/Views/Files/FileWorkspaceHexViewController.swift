import AppKit
import Foundation

public enum FileWorkspaceHexDocumentError: Error, LocalizedError, Equatable {
    case invalidReadRange
    case sourceAndDestinationMatch
    case unexpectedEndOfFile

    public var errorDescription: String? {
        switch self {
        case .invalidReadRange:
            return "读取范围无效。"
        case .sourceAndDestinationMatch:
            return "源文件和导出目标不能相同。"
        case .unexpectedEndOfFile:
            return "文件在读取过程中提前结束。"
        }
    }
}

public struct FileWorkspaceHexDocument: @unchecked Sendable {
    public let sourceID: String
    public let fileName: String
    public let byteCount: UInt64
    private let localSourceURL: URL?
    private let reader: @Sendable (_ offset: UInt64, _ length: UInt64) throws -> Data

    public init(
        sourceID: String,
        fileName: String,
        byteCount: UInt64,
        reader: @escaping @Sendable (_ offset: UInt64, _ length: UInt64) throws -> Data
    ) {
        self.sourceID = sourceID
        self.fileName = fileName
        self.byteCount = byteCount
        self.localSourceURL = nil
        self.reader = reader
    }

    private init(
        sourceID: String,
        fileName: String,
        byteCount: UInt64,
        localSourceURL: URL,
        reader: @escaping @Sendable (_ offset: UInt64, _ length: UInt64) throws -> Data
    ) {
        self.sourceID = sourceID
        self.fileName = fileName
        self.byteCount = byteCount
        self.localSourceURL = localSourceURL
        self.reader = reader
    }

    public static func localFile(_ url: URL) throws -> FileWorkspaceHexDocument {
        let normalizedURL = url.standardizedFileURL
        let attributes = try FileManager.default.attributesOfItem(atPath: normalizedURL.path)
        let byteCount = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        return FileWorkspaceHexDocument(
            sourceID: normalizedURL.path,
            fileName: normalizedURL.lastPathComponent,
            byteCount: byteCount,
            localSourceURL: normalizedURL,
            reader: { offset, length in
                guard length <= UInt64(Int.max) else {
                    throw FileWorkspaceHexDocumentError.invalidReadRange
                }
                let handle = try FileHandle(forReadingFrom: normalizedURL)
                defer { try? handle.close() }
                try handle.seek(toOffset: offset)
                return try handle.read(upToCount: Int(length)) ?? Data()
            }
        )
    }

    public func read(offset: UInt64, length: UInt64) throws -> Data {
        guard offset <= byteCount else {
            throw FileWorkspaceHexDocumentError.invalidReadRange
        }
        let available = byteCount - offset
        let requestedLength = min(length, available)
        guard requestedLength > 0 else { return Data() }
        let data = try reader(offset, requestedLength)
        if UInt64(data.count) <= requestedLength {
            return data
        }
        return Data(data.prefix(Int(requestedLength)))
    }

    public func export(to destinationURL: URL, chunkSize: UInt64 = 1 * 1_024 * 1_024) throws {
        guard chunkSize > 0, chunkSize <= UInt64(Int.max) else {
            throw FileWorkspaceHexDocumentError.invalidReadRange
        }
        let destinationURL = destinationURL.standardizedFileURL
        if let localSourceURL,
           localSourceURL.resolvingSymlinksInPath() == destinationURL.resolvingSymlinksInPath()
        {
            throw FileWorkspaceHexDocumentError.sourceAndDestinationMatch
        }
        let temporaryURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".stacio-hex-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporaryURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        let handle = try FileHandle(forWritingTo: temporaryURL)
        defer { try? handle.close() }

        var offset: UInt64 = 0
        while offset < byteCount {
            let requestedLength = min(chunkSize, byteCount - offset)
            let data = try read(offset: offset, length: requestedLength)
            guard data.isEmpty == false else {
                throw FileWorkspaceHexDocumentError.unexpectedEndOfFile
            }
            try handle.write(contentsOf: data)
            offset += UInt64(data.count)
        }
        try handle.synchronize()
        try handle.close()

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: temporaryURL)
        } else {
            try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
        }
    }
}

public enum FileWorkspaceHexFormatter {
    public static func string(data: Data, startingAt offset: UInt64, bytesPerLine: Int = 16) -> String {
        guard bytesPerLine > 0 else { return "" }
        var lines: [String] = []
        lines.reserveCapacity((data.count + bytesPerLine - 1) / bytesPerLine)
        for lineStart in stride(from: 0, to: data.count, by: bytesPerLine) {
            let lineEnd = min(lineStart + bytesPerLine, data.count)
            let bytes = data[lineStart..<lineEnd]
            let address = String(format: "%08llX", offset + UInt64(lineStart))
            let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
            let hexWidth = max(0, bytesPerLine * 3 - 1)
            let paddedHex = hex.padding(toLength: hexWidth, withPad: " ", startingAt: 0)
            let ascii = bytes.map { byte -> Character in
                guard byte >= 0x20, byte <= 0x7E else { return "." }
                return Character(UnicodeScalar(byte))
            }
            lines.append("\(address)  \(paddedHex)  |\(String(ascii))|")
        }
        return lines.joined(separator: "\n")
    }
}

@MainActor
public final class FileWorkspaceHexViewController: NSViewController {
    public let document: FileWorkspaceHexDocument
    public let pageSize: UInt64

    private let textView = NSTextView()
    private let previousButton = NSButton()
    private let nextButton = NSButton()
    private let pageLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private var currentPage: UInt64 = 0
    private var loadGeneration: UInt64 = 0

    public init(document: FileWorkspaceHexDocument, pageSize: UInt64 = 64 * 1_024) {
        self.document = document
        self.pageSize = max(1, pageSize)
        super.init(nibName: nil, bundle: nil)
        title = document.fileName
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    public var isReadOnlyForTesting: Bool {
        textView.isEditable == false
    }

    public var pageCountForTesting: UInt64 {
        pageCount
    }

    public func byteRangeForPageForTesting(_ page: UInt64) -> Range<UInt64> {
        byteRange(forPage: page)
    }

    public override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        StacioDesignSystem.setLayerBackgroundColor(root, color: NSColor.windowBackgroundColor)

        let toolbar = NSStackView()
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 8
        toolbar.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)

        configureSymbolButton(previousButton, symbol: "chevron.left", label: "上一页", action: #selector(showPreviousPage))
        configureSymbolButton(nextButton, symbol: "chevron.right", label: "下一页", action: #selector(showNextPage))
        let saveButton = NSButton()
        configureSymbolButton(saveButton, symbol: "square.and.arrow.down", label: "另存为", action: #selector(saveAs))
        pageLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        pageLabel.alignment = .center
        pageLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle

        toolbar.addArrangedSubview(previousButton)
        toolbar.addArrangedSubview(pageLabel)
        toolbar.addArrangedSubview(nextButton)
        toolbar.addArrangedSubview(statusLabel)
        toolbar.addArrangedSubview(NSView())
        toolbar.addArrangedSubview(saveButton)

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.setAccessibilityIdentifier("Stacio.FileWorkspaceHex.text")
        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        toolbar.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(toolbar)
        root.addSubview(scrollView)
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        view = root
        updatePageControls()
        loadCurrentPage()
    }

    private var pageCount: UInt64 {
        guard document.byteCount > 0 else { return 1 }
        return (document.byteCount + pageSize - 1) / pageSize
    }

    private func byteRange(forPage page: UInt64) -> Range<UInt64> {
        let clampedPage = min(page, pageCount - 1)
        let lowerBound = min(clampedPage * pageSize, document.byteCount)
        let upperBound = min(lowerBound + pageSize, document.byteCount)
        return lowerBound..<upperBound
    }

    private func configureSymbolButton(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.title = ""
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imagePosition = .imageOnly
        button.bezelStyle = .texturedRounded
        button.target = self
        button.action = action
        button.toolTip = label
        button.setAccessibilityLabel(label)
    }

    @objc private func showPreviousPage() {
        guard currentPage > 0 else { return }
        currentPage -= 1
        updatePageControls()
        loadCurrentPage()
    }

    @objc private func showNextPage() {
        guard currentPage + 1 < pageCount else { return }
        currentPage += 1
        updatePageControls()
        loadCurrentPage()
    }

    private func updatePageControls() {
        previousButton.isEnabled = currentPage > 0
        nextButton.isEnabled = currentPage + 1 < pageCount
        pageLabel.stringValue = "\(currentPage + 1) / \(pageCount)"
        statusLabel.stringValue = ByteCountFormatter.string(
            fromByteCount: Int64(clamping: document.byteCount),
            countStyle: .file
        )
    }

    private func loadCurrentPage() {
        loadGeneration &+= 1
        let generation = loadGeneration
        let range = byteRange(forPage: currentPage)
        let document = document
        statusLabel.stringValue = "正在读取..."
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                try document.read(offset: range.lowerBound, length: UInt64(range.count))
            }
            DispatchQueue.main.async {
                guard let self, self.loadGeneration == generation else { return }
                switch result {
                case .success(let data):
                    self.textView.string = FileWorkspaceHexFormatter.string(
                        data: data,
                        startingAt: range.lowerBound
                    )
                    self.updatePageControls()
                case .failure(let error):
                    self.textView.string = ""
                    self.statusLabel.stringValue = RuntimeDiagnosticFormatter.userMessage(for: error)
                }
            }
        }
    }

    @objc private func saveAs() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = document.fileName
        panel.canCreateDirectories = true
        if let window = view.window {
            panel.beginSheetModal(for: window) { [weak self] response in
                guard response == .OK, let destination = panel.url else { return }
                self?.export(to: destination)
            }
        } else if panel.runModal() == .OK, let destination = panel.url {
            export(to: destination)
        }
    }

    private func export(to destination: URL) {
        let document = document
        statusLabel.stringValue = "正在保存..."
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try document.export(to: destination) }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success:
                    self.updatePageControls()
                case .failure(let error):
                    self.statusLabel.stringValue = RuntimeDiagnosticFormatter.userMessage(for: error)
                }
            }
        }
    }
}

@MainActor
public final class FileWorkspaceHexWindowController: NSWindowController, NSWindowDelegate {
    public let hexViewController: FileWorkspaceHexViewController
    public var onClose: ((FileWorkspaceHexWindowController) -> Void)?

    public init(document: FileWorkspaceHexDocument) {
        hexViewController = FileWorkspaceHexViewController(document: document)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(document.fileName) - Hex"
        window.contentViewController = hexViewController
        window.minSize = NSSize(width: 560, height: 360)
        super.init(window: window)
        window.delegate = self
        window.center()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    public func windowWillClose(_ notification: Notification) {
        onClose?(self)
    }
}
