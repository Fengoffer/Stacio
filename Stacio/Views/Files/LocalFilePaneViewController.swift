import AppKit

public enum LocalFilePaneError: Error, Equatable, LocalizedError {
    case invalidPath(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPath:
            return "本地文件路径无效。"
        }
    }
}

public final class LocalFilePaneViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    public let runtimeID: String
    public private(set) var directoryURL: URL
    public let tableView = NSTableView()

    private let statusLabel = NSTextField(labelWithString: "")
    private var rows: [LocalFileRow] = []
    private var statusText = ""
    private var fileActions: [String] = []

    public init(runtimeID: String, directoryURL: URL, title: String) {
        self.runtimeID = runtimeID
        self.directoryURL = directoryURL
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    public override func loadView() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.applyWorkspaceSurface(container)

        let toolbar = NSStackView()
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 8
        toolbar.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        let refreshButton = NSButton(
            image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "刷新") ?? NSImage(),
            target: self,
            action: #selector(refreshButtonPressed)
        )
        refreshButton.bezelStyle = .texturedRounded
        refreshButton.toolTip = "刷新"
        StacioDesignSystem.styleToolbarButton(refreshButton)

        let revealButton = NSButton(
            image: NSImage(systemSymbolName: "scope", accessibilityDescription: "显示路径") ?? NSImage(),
            target: self,
            action: #selector(revealButtonPressed)
        )
        revealButton.bezelStyle = .texturedRounded
        revealButton.toolTip = "显示路径"
        StacioDesignSystem.styleToolbarButton(revealButton)

        let openButton = NSButton(
            image: NSImage(systemSymbolName: "folder", accessibilityDescription: "打开路径") ?? NSImage(),
            target: self,
            action: #selector(openButtonPressed)
        )
        openButton.bezelStyle = .texturedRounded
        openButton.toolTip = "打开路径"
        StacioDesignSystem.styleToolbarButton(openButton)

        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.maximumNumberOfLines = 1
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.setAccessibilityIdentifier("Stacio.LocalFiles.status")

        toolbar.addArrangedSubview(refreshButton)
        toolbar.addArrangedSubview(revealButton)
        toolbar.addArrangedSubview(openButton)
        toolbar.addArrangedSubview(statusLabel)
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        tableView.addTableColumn(makeColumn(identifier: "name", title: "名称", width: 240))
        tableView.addTableColumn(makeColumn(identifier: "size", title: "大小", width: 92))
        tableView.addTableColumn(makeColumn(identifier: "time", title: "时间", width: 118))
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.rowHeight = StacioFileDisplay.tableRowHeight
        tableView.dataSource = self
        tableView.delegate = self
        tableView.setAccessibilityIdentifier("Stacio.LocalFiles.table")
        StacioDesignSystem.styleTable(tableView)

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(toolbar)
        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        view = container
        loadDirectory(recordAction: false)
    }

    public func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    public func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard let tableColumn, rows.indices.contains(row) else {
            return nil
        }
        let identifier = NSUserInterfaceItemIdentifier("LocalFileCell.\(tableColumn.identifier.rawValue)")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? NSTableCellView()
        cell.identifier = identifier
        cell.subviews.forEach { $0.removeFromSuperview() }

        let textField = NSTextField(labelWithString: "")
        textField.lineBreakMode = .byTruncatingMiddle
        textField.maximumNumberOfLines = 1
        textField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.stringValue = rows[row].value(for: tableColumn.identifier.rawValue)
        cell.textField = textField

        if tableColumn.identifier.rawValue == "name" {
            let imageView = NSImageView(image: StacioFileDisplay.localIcon(for: rows[row]))
            imageView.imageScaling = .scaleProportionallyDown
            imageView.setAccessibilityLabel(StacioFileDisplay.iconAccessibilityLabel(for: rows[row]))
            imageView.translatesAutoresizingMaskIntoConstraints = false
            cell.imageView = imageView
            cell.addSubview(imageView)
            cell.addSubview(textField)
            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: StacioFileDisplay.iconDimension),
                imageView.heightAnchor.constraint(equalToConstant: StacioFileDisplay.iconDimension),
                textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 8),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        } else {
            cell.imageView = nil
            cell.addSubview(textField)
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }

        return cell
    }

    public var statusTextForTesting: String {
        statusText
    }

    public var currentPathForTesting: String {
        directoryURL.path
    }

    public var fileActionsForTesting: [String] {
        fileActions
    }

    public var visibleTextSnapshotForTesting: String {
        let rowText = rows
            .map { "\($0.name)\n\($0.size)\n\($0.time)\n" }
            .joined()
        return "\(statusText)\n\(rowText)"
    }

    public func refreshDirectory() {
        loadDirectory(recordAction: true)
    }

    private func loadDirectory(recordAction: Bool) {
        if recordAction {
            fileActions.append("refresh")
        }
        guard FileManager.default.fileExists(atPath: directoryURL.path) else {
            rows = []
            updateStatus("本地路径不存在：\(directoryURL.path)")
            tableView.reloadData()
            return
        }

        guard canReadDirectory(at: directoryURL) else {
            rows = []
            updateStatus("没有权限读取本地路径：\(directoryURL.path)")
            tableView.reloadData()
            return
        }

        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .isHiddenKey, .contentModificationDateKey],
                options: []
            )
            rows = StacioFileDisplay.sortedLocalRows(contents.map(LocalFileRow.init(url:)))
            updateStatus("当前路径：\(directoryURL.path)")
        } catch {
            rows = []
            updateStatus("无法读取本地路径：\(directoryURL.path)")
        }
        tableView.reloadData()
    }

    public func revealCurrentPath() {
        fileActions.append("reveal")
    }

    public func openCurrentPath() {
        fileActions.append("open")
    }

    @objc private func refreshButtonPressed() {
        refreshDirectory()
    }

    @objc private func revealButtonPressed() {
        revealCurrentPath()
    }

    @objc private func openButtonPressed() {
        openCurrentPath()
    }

    private func updateStatus(_ value: String) {
        statusText = value
        if isViewLoaded {
            statusLabel.stringValue = value
        }
    }

    private func canReadDirectory(at url: URL) -> Bool {
        if let permissions = try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber {
            return permissions.intValue & 0o444 != 0
        }
        return FileManager.default.isReadableFile(atPath: url.path)
    }

    private func makeColumn(identifier: String, title: String, width: CGFloat) -> NSTableColumn {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
        column.title = title
        column.width = width
        column.minWidth = 60
        column.resizingMask = .userResizingMask
        return column
    }
}

struct LocalFileRow: StacioFileDisplayRow {
    let url: URL
    let name: String
    let kind: String
    let size: String
    let time: String
    let isDirectory: Bool
    let isHiddenItem: Bool

    init(url: URL) {
        self.url = url
        name = url.lastPathComponent
        let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey,
            .fileSizeKey,
            .isHiddenKey,
            .contentModificationDateKey
        ])
        isDirectory = values?.isDirectory == true
        let isHidden = values?.isHidden == true || name.hasPrefix(".")
        isHiddenItem = isHidden
        time = StacioFileDisplay.timeText(for: values?.contentModificationDate)
        if isDirectory {
            kind = "文件夹"
            size = ""
        } else {
            kind = "文件"
            size = StacioFileDisplay.byteSizeText(values?.fileSize)
        }
    }

    func value(for columnIdentifier: String) -> String {
        switch columnIdentifier {
        case "name":
            return name
        case "size":
            return size
        case "time":
            return time
        default:
            return ""
        }
    }
}
