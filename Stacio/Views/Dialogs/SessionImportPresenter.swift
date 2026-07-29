import AppKit
import StacioCoreBindings

public struct AppKitBastionHostVendorSelector: BastionHostVendorSelecting {
    static let selectableVendors: [BastionHostVendor] = [.topsec]
        + BastionHostVendor.allCases.filter { $0 != .topsec }

    public init() {}

    public func selectVendor(sourceName: String, parentWindow: NSWindow?) -> BastionHostVendor? {
        if !Thread.isMainThread {
            return DispatchQueue.main.sync {
                selectVendor(sourceName: sourceName, parentWindow: parentWindow)
            }
        }

        let alert = NSAlert()
        alert.messageText = L10n.Import.bastionVendorSelectionTitle
        alert.informativeText = L10n.Import.bastionVendorSelectionMessage(sourceName: sourceName)
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.Import.bastionVendorRetryAction)
        alert.addButton(withTitle: L10n.Common.cancel)

        let popup = Self.makeVendorPopup()
        popup.frame = NSRect(x: 0, y: 0, width: 320, height: 26)
        alert.accessoryView = popup

        guard alert.runModal() == .alertFirstButtonReturn,
              let rawValue = popup.selectedItem?.representedObject as? String
        else {
            return nil
        }
        return BastionHostVendor(rawValue: rawValue)
    }

    static func vendorPopupForTesting() -> NSPopUpButton {
        makeVendorPopup()
    }

    private static func makeVendorPopup() -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.identifier = NSUserInterfaceItemIdentifier("Stacio.Import.bastionVendor")
        for vendor in selectableVendors {
            popup.addItem(withTitle: vendor.displayName)
            popup.lastItem?.representedObject = vendor.rawValue
        }
        popup.selectItem(at: 0)
        return popup
    }
}

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

        return MainActor.assumeIsolated {
            let importableCount = preview.sessions.filter { !$0.conflict }.count
            let controller = SessionImportPreviewWindowController(
                preview: preview,
                title: L10n.Import.title,
                message: L10n.Import.previewMessage(
                    sourceName: sourceName,
                    sourceType: sourceType,
                    importableCount: importableCount,
                    conflictCount: preview.conflictCount
                ),
                importEnabled: importableCount > 0
            )
            return controller.runModal(parentWindow: parentWindow)
        }
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

        let alert = NSAlert()
        alert.messageText = L10n.Import.failedTitle
        alert.informativeText = Self.userFacingErrorDescription(error)
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.Common.ok)
        _ = alert.runModal()
    }

    static func previewAccessoryForTesting(_ preview: ImportPreview) -> NSView {
        MainActor.assumeIsolated {
            SessionImportPreviewWindowController(
                preview: preview,
                title: L10n.Import.title,
                message: "测试导入预览",
                importEnabled: true
            ).window?.contentView ?? NSView()
        }
    }

    static func previewWindowControllerForTesting(
        _ preview: ImportPreview,
        message: String = "测试导入预览"
    ) -> NSWindowController {
        MainActor.assumeIsolated {
            SessionImportPreviewWindowController(
                preview: preview,
                title: L10n.Import.title,
                message: message,
                importEnabled: preview.sessions.contains { $0.conflict == false }
            )
        }
    }

    static func previewContentSizeForTesting(availableSize: NSSize) -> NSSize {
        MainActor.assumeIsolated {
            SessionImportPreviewWindowController.contentSize(forAvailableSize: availableSize)
        }
    }

    static func previewTextForTesting(_ preview: ImportPreview) -> String {
        previewText(preview)
    }

    static func errorMessageForTesting(_ error: Error) -> String {
        userFacingErrorDescription(error)
    }

    private static func userFacingErrorDescription(_ error: Error) -> String {
        if let sessionError = error as? SessionError {
            switch sessionError {
            case .InvalidQuickConnect:
                return L10n.Import.invalidSessionData
            case .InvalidPort:
                return L10n.Import.invalidPort
            case .Database:
                return L10n.Import.databaseFailure
            case .NotFound:
                return L10n.Import.referencedItemMissing
            }
        }
        if let parserError = error as? ExternalSessionImportParserError {
            return parserError.localizedDescription
        }
        if let fallbackError = error as? BastionHostVendorFallbackError {
            return fallbackError.localizedDescription
        }
        if let removedProtocolError = error as? SessionImportRemovedProtocolError {
            return removedProtocolError.localizedDescription
        }
        if let secureTransferError = error as? SecureSessionTransferError {
            return secureTransferError.localizedDescription
        }
        if let licenseError = error as? LicensedFeatureAccessError {
            return licenseError.localizedDescription
        }
        if let bastionLicenseError = error as? BastionHostFeatureAccessError {
            return bastionLicenseError.localizedDescription
        }
        if error is KeychainCredentialError {
            return L10n.Import.credentialStorageFailure
        }
        return L10n.Import.genericFailure
    }

    private static func previewText(_ preview: ImportPreview) -> String {
        var lines = [L10n.Import.header]
        lines.append(contentsOf: preview.sessions.map { session in
            let folder = session.folder ?? ""
            let target = displaySummary(for: session).displayText
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
        case "sftp":
            return "SFTP"
        case "scp":
            return "SCP"
        case "telnet":
            return "Telnet"
        case "vnc":
            return "VNC"
        default:
            return protocolName.uppercased()
        }
    }

    fileprivate static func previewRows(_ preview: ImportPreview) -> [SessionImportPreviewRow] {
        let warnings = sanitizedWarnings(preview.warnings).joined(separator: "\n")
        return preview.sessions.enumerated().map { index, session in
            let summary = displaySummary(for: session)
            return SessionImportPreviewRow(
                name: session.name,
                folder: session.folder ?? "",
                protocolName: protocolLabel(session.protocol),
                target: summary.primaryTarget,
                gateway: summary.gatewayDetail,
                status: session.conflict ? L10n.Import.conflict : L10n.Import.new,
                warnings: index == 0 ? warnings : ""
            )
        }
    }

    private static func displaySummary(for session: ImportSessionPreview) -> BastionSessionDisplaySummary {
        BastionSessionDisplaySummaryCodec.summary(
            protocolName: session.protocol,
            gatewayHost: session.host,
            gatewayPort: UInt32(session.port),
            gatewayUsername: session.username,
            configJSON: session.configJson
        )
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
}

fileprivate struct SessionImportPreviewRow {
    let name: String
    let folder: String
    let protocolName: String
    let target: String
    let gateway: String?
    let status: String
    let warnings: String
}

@MainActor
private final class SessionImportPreviewWindowController: NSWindowController, NSWindowDelegate {
    private enum Layout {
        static let preferredSize = NSSize(width: 840, height: 520)
        static let minimumSize = NSSize(width: 700, height: 420)
        static let screenInset: CGFloat = 48
    }

    private let tableView = NSTableView()
    private let dataSource: SessionImportPreviewTableDataSource
    private let titleLabel: NSTextField
    private let messageLabel: NSTextField
    private let importButton = NSButton(title: L10n.Import.action, target: nil, action: nil)
    private let cancelButton = NSButton(title: L10n.Common.cancel, target: nil, action: nil)
    private var accepted = false

    init(preview: ImportPreview, title: String, message: String, importEnabled: Bool) {
        dataSource = SessionImportPreviewTableDataSource(
            rows: AppKitSessionImportPreviewPresenter.previewRows(preview)
        )
        titleLabel = NSTextField(labelWithString: title)
        messageLabel = NSTextField(wrappingLabelWithString: message)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Layout.preferredSize),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.titleVisibility = .visible
        window.toolbarStyle = .automatic
        window.backgroundColor = .windowBackgroundColor
        window.contentMinSize = Layout.minimumSize
        super.init(window: window)
        window.delegate = self
        configureContent(importEnabled: importEnabled)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func runModal(parentWindow: NSWindow?) -> Bool {
        guard let window else { return false }
        resizeToFit(screen: parentWindow?.screen ?? NSScreen.main)
        if let parentWindow {
            parentWindow.beginSheet(window)
            let response = NSApplication.shared.runModal(for: window)
            parentWindow.endSheet(window)
            window.orderOut(nil)
            return response == .OK && accepted
        }
        window.center()
        let response = NSApplication.shared.runModal(for: window)
        window.close()
        return response == .OK && accepted
    }

    func windowWillClose(_ notification: Notification) {
        NSApplication.shared.stopModal(withCode: .cancel)
    }

    private func configureContent(importEnabled: Bool) {
        guard let window else { return }
        let root = StacioAppearanceRefreshView()
        root.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.applyWorkspaceSurface(root)

        let appIcon = NSImageView(image: NSApplication.shared.applicationIconImage)
        appIcon.imageScaling = .scaleProportionallyUpOrDown
        appIcon.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        titleLabel.textColor = StacioDesignSystem.theme.primaryTextColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setAccessibilityIdentifier("Stacio.ImportPreview.title")

        messageLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        messageLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        messageLabel.maximumNumberOfLines = 3
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.setAccessibilityIdentifier("Stacio.ImportPreview.message")

        configureTableView()
        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.setAccessibilityIdentifier("Stacio.ImportPreview.scroll")

        let footerSeparator = NSBox()
        footerSeparator.boxType = .separator
        footerSeparator.translatesAutoresizingMaskIntoConstraints = false

        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .large
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed(_:))
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.setAccessibilityIdentifier("Stacio.ImportPreview.cancel")

        importButton.bezelStyle = .rounded
        importButton.controlSize = .large
        importButton.keyEquivalent = "\r"
        importButton.isEnabled = importEnabled
        importButton.target = self
        importButton.action = #selector(importPressed(_:))
        importButton.translatesAutoresizingMaskIntoConstraints = false
        importButton.setAccessibilityIdentifier("Stacio.ImportPreview.import")

        [appIcon, titleLabel, messageLabel, scrollView, footerSeparator, cancelButton, importButton]
            .forEach(root.addSubview)
        NSLayoutConstraint.activate([
            appIcon.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            appIcon.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            appIcon.widthAnchor.constraint(equalToConstant: 48),
            appIcon.heightAnchor.constraint(equalToConstant: 48),

            titleLabel.leadingAnchor.constraint(equalTo: appIcon.trailingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),

            messageLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            messageLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            messageLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 7),

            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            scrollView.topAnchor.constraint(equalTo: appIcon.bottomAnchor, constant: 18),
            scrollView.bottomAnchor.constraint(equalTo: footerSeparator.topAnchor, constant: -16),

            footerSeparator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footerSeparator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footerSeparator.bottomAnchor.constraint(equalTo: cancelButton.topAnchor, constant: -15),

            importButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            importButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            importButton.widthAnchor.constraint(equalToConstant: 96),
            importButton.heightAnchor.constraint(equalToConstant: 32),

            cancelButton.trailingAnchor.constraint(equalTo: importButton.leadingAnchor, constant: -10),
            cancelButton.centerYAnchor.constraint(equalTo: importButton.centerYAnchor),
            cancelButton.widthAnchor.constraint(equalToConstant: 96),
            cancelButton.heightAnchor.constraint(equalTo: importButton.heightAnchor)
        ])
        window.contentView = root
        window.initialFirstResponder = tableView
        window.defaultButtonCell = importButton.cell as? NSButtonCell
        tableView.reloadData()
        root.layoutSubtreeIfNeeded()
    }

    private func configureTableView() {
        tableView.frame = NSRect(x: 0, y: 0, width: 796, height: 320)
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.headerView = NSTableHeaderView()
        tableView.rowHeight = 42
        tableView.intercellSpacing = NSSize(width: 3, height: 1)
        tableView.dataSource = dataSource
        tableView.delegate = dataSource
        tableView.allowsColumnReordering = false
        tableView.allowsColumnResizing = true
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.setAccessibilityIdentifier("Stacio.ImportPreview.table")
        StacioDesignSystem.styleTable(tableView)

        [
            ("name", L10n.Import.nameColumn, 150, 110),
            ("folder", L10n.Import.folderColumn, 105, 80),
            ("protocol", L10n.Import.protocolColumn, 64, 58),
            ("target", L10n.Import.targetColumn, 220, 170),
            ("status", L10n.Import.statusColumn, 64, 58),
            ("warnings", L10n.Import.warningsColumn, 150, 100)
        ].forEach { identifier, title, width, minimumWidth in
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = CGFloat(width)
            column.minWidth = CGFloat(minimumWidth)
            tableView.addTableColumn(column)
        }
    }

    private func resizeToFit(screen: NSScreen?) {
        let availableSize = screen?.visibleFrame.size ?? Layout.preferredSize
        let size = Self.contentSize(forAvailableSize: availableSize)
        window?.contentMinSize = NSSize(
            width: min(Layout.minimumSize.width, size.width),
            height: min(Layout.minimumSize.height, size.height)
        )
        window?.setContentSize(size)
    }

    static func contentSize(forAvailableSize availableSize: NSSize) -> NSSize {
        let availableWidth = max(1, availableSize.width - Layout.screenInset)
        let availableHeight = max(1, availableSize.height - Layout.screenInset)
        return NSSize(
            width: min(Layout.preferredSize.width, availableWidth),
            height: min(Layout.preferredSize.height, availableHeight)
        )
    }

    @objc private func importPressed(_ sender: NSButton) {
        accepted = true
        NSApplication.shared.stopModal(withCode: .OK)
    }

    @objc private func cancelPressed(_ sender: NSButton) {
        accepted = false
        NSApplication.shared.stopModal(withCode: .cancel)
    }
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
        textField.maximumNumberOfLines = tableColumn.identifier.rawValue == "target"
            || tableColumn.identifier.rawValue == "warnings" ? 2 : 1
        textField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        textField.textColor = StacioDesignSystem.theme.primaryTextColor
        textField.toolTip = textField.stringValue.isEmpty ? nil : textField.stringValue
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
            guard let gateway = row.gateway else { return row.target }
            return "\(row.target)\n\(gateway)"
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
