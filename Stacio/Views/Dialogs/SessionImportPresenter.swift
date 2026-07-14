import AppKit
import StacioCoreBindings

public struct AppKitSessionImportPreviewPresenter: SessionImportPreviewPresenting {
    public init() {}

    public func confirmImport(
        preview: ImportPreview,
        sourceName: String,
        sourceType: SessionImportSourceType,
        parentWindow: NSWindow?
    ) -> Bool {
        if !Thread.isMainThread {
            return DispatchQueue.main.sync {
                confirmImport(
                    preview: preview,
                    sourceName: sourceName,
                    sourceType: sourceType,
                    parentWindow: parentWindow
                )
            }
        }

        let importableCount = preview.sessions.filter { !$0.conflict }.count
        let alert = NSAlert()
        alert.messageText = L10n.Import.title
        alert.informativeText = L10n.Import.previewMessage(
            sourceName: sourceName,
            sourceType: sourceType,
            importableCount: importableCount,
            conflictCount: preview.conflictCount
        )
        alert.addButton(withTitle: L10n.Import.action)
        alert.addButton(withTitle: L10n.Common.cancel)
        alert.buttons.first?.isEnabled = importableCount > 0
        alert.accessoryView = makePreviewAccessory(preview)

        return alert.runModal() == .alertFirstButtonReturn
    }

    public func showImportResult(_ result: ImportApplyResult, parentWindow: NSWindow?) {
        if !Thread.isMainThread {
            DispatchQueue.main.sync {
                showImportResult(result, parentWindow: parentWindow)
            }
            return
        }

        let alert = NSAlert()
        alert.messageText = L10n.Import.completeTitle
        alert.informativeText = L10n.Import.resultMessage(
            imported: result.report.importedCount,
            skipped: result.report.skippedCount,
            failed: result.report.failedCount
        )
        alert.addButton(withTitle: L10n.Common.ok)
        _ = alert.runModal()
    }

    public func showImportError(_ error: Error, parentWindow: NSWindow?) {
        if !Thread.isMainThread {
            DispatchQueue.main.sync {
                showImportError(error, parentWindow: parentWindow)
            }
            return
        }

        let alert = NSAlert(error: error)
        alert.messageText = L10n.Import.failedTitle
        alert.addButton(withTitle: L10n.Common.ok)
        _ = alert.runModal()
    }

    private func makePreviewAccessory(_ preview: ImportPreview) -> NSView {
        let rows = Self.previewRows(preview)
        let dataSource = SessionImportPreviewTableDataSource(rows: rows)
        let tableView = NSTableView(frame: NSRect(x: 0, y: 0, width: 520, height: 220))
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.headerView = NSTableHeaderView()
        tableView.rowHeight = 24
        tableView.dataSource = dataSource
        tableView.delegate = dataSource
        tableView.allowsColumnReordering = false
        tableView.allowsColumnResizing = true
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        StacioDesignSystem.styleTable(tableView)

        [
            ("name", L10n.Import.nameColumn, 104),
            ("folder", L10n.Import.folderColumn, 76),
            ("protocol", L10n.Import.protocolColumn, 58),
            ("target", L10n.Import.targetColumn, 144),
            ("status", L10n.Import.statusColumn, 52),
            ("warnings", L10n.Import.warningsColumn, 86)
        ].forEach { identifier, title, width in
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = CGFloat(width)
            column.minWidth = min(CGFloat(width), 52)
            tableView.addTableColumn(column)
        }

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 220))
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.postsFrameChangedNotifications = true
        objc_setAssociatedObject(
            scrollView,
            &Self.previewTableDataSourceAssociationKey,
            dataSource,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        return scrollView
    }

    static func previewAccessoryForTesting(_ preview: ImportPreview) -> NSView {
        AppKitSessionImportPreviewPresenter().makePreviewAccessory(preview)
    }

    static func previewTextForTesting(_ preview: ImportPreview) -> String {
        previewText(preview)
    }

    private static func previewText(_ preview: ImportPreview) -> String {
        var lines = [L10n.Import.header]
        lines.append(contentsOf: preview.sessions.map { session in
            let folder = session.folder ?? ""
            let username = session.username.map { "\($0)@" } ?? ""
            let target = "\(username)\(session.host):\(session.port)"
            let protocolName = protocolLabel(session.protocol)
            let status = session.conflict ? L10n.Import.conflict : L10n.Import.new
            return "\(session.name)\t\(folder)\t\(protocolName)\t\(target)\t\(status)"
        })
        if !preview.warnings.isEmpty {
            lines.append("")
            lines.append(L10n.Import.warnings)
            lines.append(contentsOf: sanitizedWarnings(preview.warnings).map { "- \($0)" })
        }
        return lines.joined(separator: "\n")
    }

    private static func protocolLabel(_ protocolName: String) -> String {
        switch protocolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "ssh":
            return "SSH"
        case "ftp":
            return "FTP"
        case "telnet":
            return "Telnet"
        case "vnc":
            return "VNC"
        default:
            return protocolName.uppercased()
        }
    }

    private static func previewRows(_ preview: ImportPreview) -> [SessionImportPreviewRow] {
        let warnings = sanitizedWarnings(preview.warnings).joined(separator: "\n")
        return preview.sessions.enumerated().map { index, session in
            let username = session.username.map { "\($0)@" } ?? ""
            return SessionImportPreviewRow(
                name: session.name,
                folder: session.folder ?? "",
                protocolName: protocolLabel(session.protocol),
                target: "\(username)\(session.host):\(session.port)",
                status: session.conflict ? L10n.Import.conflict : L10n.Import.new,
                warnings: index == 0 ? warnings : ""
            )
        }
    }

    private static func sanitizedWarnings(_ warnings: [String]) -> [String] {
        warnings.map { warning in
            let lowercased = warning.lowercased()
            if lowercased.contains("password")
                || lowercased.contains("token")
                || lowercased.contains("api_key")
                || lowercased.contains("secret")
                || lowercased.contains("private key")
                || lowercased.contains("/.ssh/") {
                return L10n.Import.sensitiveWarningHidden
            }
            return warning
        }
    }

    private static var previewTableDataSourceAssociationKey: UInt8 = 0
}

private struct SessionImportPreviewRow {
    let name: String
    let folder: String
    let protocolName: String
    let target: String
    let status: String
    let warnings: String
}

private final class SessionImportPreviewTableDataSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let rows: [SessionImportPreviewRow]

    init(rows: [SessionImportPreviewRow]) {
        self.rows = rows
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row rowIndex: Int
    ) -> NSView? {
        guard rowIndex < rows.count, let tableColumn else {
            return nil
        }

        let cell = NSTableCellView()
        let textField = NSTextField(labelWithString: value(for: tableColumn.identifier.rawValue, in: rows[rowIndex]))
        textField.lineBreakMode = .byTruncatingTail
        textField.maximumNumberOfLines = 1
        textField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        textField.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(textField)
        cell.textField = textField
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    private func value(for identifier: String, in row: SessionImportPreviewRow) -> String {
        switch identifier {
        case "name":
            return row.name
        case "folder":
            return row.folder
        case "protocol":
            return row.protocolName
        case "target":
            return row.target
        case "status":
            return row.status
        case "warnings":
            return row.warnings
        default:
            return ""
        }
    }
}

public struct AppKitSessionImportErrorPresenter: SessionImportErrorPresenting {
    public init() {}

    public func presentSessionImportError(_ error: Error, parentWindow: NSWindow?) {
        AppKitSessionImportPreviewPresenter().showImportError(error, parentWindow: parentWindow)
    }
}
