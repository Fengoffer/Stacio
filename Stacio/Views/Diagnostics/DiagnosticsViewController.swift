import AppKit
import StacioCoreBindings
import UniformTypeIdentifiers

@MainActor
public protocol DiagnosticsExportPresenting {
    func chooseExportDestination(
        suggestedName: String,
        allowedContentTypes: [UTType],
        parentWindow: NSWindow?
    ) -> URL?
    func presentExportComplete(destinationURL: URL, parentWindow: NSWindow?)
}

@MainActor
public final class AppKitDiagnosticsExportPresenter: DiagnosticsExportPresenting {
    public init() {}

    public func chooseExportDestination(
        suggestedName: String,
        allowedContentTypes: [UTType],
        parentWindow: NSWindow?
    ) -> URL? {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = allowedContentTypes
        panel.title = L10n.Diagnostics.export
        _ = parentWindow
        return panel.runModal() == .OK ? panel.url : nil
    }

    public func presentExportComplete(destinationURL: URL, parentWindow: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.Diagnostics.exportCompleteTitle
        alert.informativeText = destinationURL.path
        alert.addButton(withTitle: L10n.Common.ok)
        if let parentWindow {
            alert.beginSheetModal(for: parentWindow)
        } else {
            alert.runModal()
        }
    }
}

private enum AppLogLevel: Equatable {
    case error
    case fatal
    case warning
    case info
    case debug

    init?(token: String) {
        switch token.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "ERROR":
            self = .error
        case "FATAL":
            self = .fatal
        case "WARN", "WARNING":
            self = .warning
        case "INFO":
            self = .info
        case "DEBUG":
            self = .debug
        default:
            return nil
        }
    }

    var exportTitle: String {
        switch self {
        case .error:
            return "ERROR"
        case .fatal:
            return "FATAL"
        case .warning:
            return "WARN"
        case .info:
            return "INFO"
        case .debug:
            return "DEBUG"
        }
    }
}

private enum AppLogLevelFilter: CaseIterable {
    case all
    case error
    case warning
    case info
    case debug

    init(title: String?) {
        switch title {
        case Self.error.title:
            self = .error
        case Self.warning.title:
            self = .warning
        case Self.info.title:
            self = .info
        case Self.debug.title:
            self = .debug
        default:
            self = .all
        }
    }

    var title: String {
        switch self {
        case .all:
            return "全部"
        case .error:
            return "ERROR"
        case .warning:
            return "WARN"
        case .info:
            return "INFO"
        case .debug:
            return "DEBUG"
        }
    }

    func matches(_ level: AppLogLevel?) -> Bool {
        switch self {
        case .all:
            return true
        case .error:
            return level == .error || level == .fatal
        case .warning:
            return level == .warning
        case .info:
            return level == .info
        case .debug:
            return level == .debug
        }
    }
}

private struct AppLogLine {
    let rawValue: String
    let timestamp: String?
    let level: AppLogLevel?
    let levelRange: NSRange?
    let message: String

    init(rawValue: String) {
        self.rawValue = rawValue
        let nsLine = rawValue as NSString
        let fullRange = NSRange(location: 0, length: nsLine.length)
        let openRange = nsLine.range(of: "[", options: [], range: fullRange)
        guard openRange.location != NSNotFound else {
            timestamp = nil
            level = nil
            levelRange = nil
            message = rawValue
            return
        }

        let closeSearchLocation = openRange.location + openRange.length
        let closeSearchRange = NSRange(
            location: closeSearchLocation,
            length: max(0, nsLine.length - closeSearchLocation)
        )
        let closeRange = nsLine.range(of: "]", options: [], range: closeSearchRange)
        guard closeRange.location != NSNotFound else {
            timestamp = nil
            level = nil
            levelRange = nil
            message = rawValue
            return
        }

        let tokenLocation = openRange.location + openRange.length
        let tokenLength = closeRange.location - tokenLocation
        let token = nsLine.substring(with: NSRange(location: tokenLocation, length: tokenLength))
        guard let parsedLevel = AppLogLevel(token: token) else {
            timestamp = nil
            level = nil
            levelRange = nil
            message = rawValue
            return
        }

        let rawTimestamp = openRange.location > 0
            ? nsLine.substring(to: openRange.location).trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        let messageStart = closeRange.location + closeRange.length
        let rawMessage = messageStart < nsLine.length ? nsLine.substring(from: messageStart) : ""
        timestamp = rawTimestamp.isEmpty ? nil : rawTimestamp
        level = parsedLevel
        levelRange = NSRange(location: openRange.location, length: closeRange.location - openRange.location + closeRange.length)
        message = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var exportLine: String {
        guard let timestamp, let level else {
            return rawValue
        }
        if message.isEmpty {
            return "\(timestamp) \(level.exportTitle)"
        }
        return "\(timestamp) \(level.exportTitle) \(message)"
    }
}

@MainActor
public final class DiagnosticsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    public let tableView = NSTableView()

    private let portProbe: PortProbing
    private let exportPresenter: DiagnosticsExportPresenting
    private let auditStore: MultiExecAuditListing?
    private let agentAuditStore: AgentActionAuditListing?
    private let importReportStore: ImportReportListing?
    private let settingsStore: AppSettingsStore
    private let titleLabel = NSTextField(labelWithString: L10n.Diagnostics.title)
    private let exportButton = StacioHoverButton(title: L10n.Diagnostics.export, target: nil, action: nil)
    private let contextLabel = NSTextField(labelWithString: "")
    private let portCheckTitleLabel = NSTextField(labelWithString: L10n.Diagnostics.localPortCheck)
    private let hostLabel = NSTextField(labelWithString: L10n.Diagnostics.host)
    private let hostField = NSTextField(string: "127.0.0.1")
    private let portLabel = NSTextField(labelWithString: L10n.Diagnostics.port)
    private let portField = NSTextField(string: "")
    private let checkButton = StacioHoverButton(title: L10n.Diagnostics.check, target: nil, action: nil)
    private let portResultLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: L10n.Diagnostics.empty)
    private let auditTitleLabel = NSTextField(labelWithString: L10n.Diagnostics.multiExecAudit)
    private let auditScopeControl = NSSegmentedControl(
        labels: [
            L10n.Diagnostics.auditScopeAll,
            L10n.Diagnostics.auditScopeAgent,
            L10n.Diagnostics.auditScopeMultiExec
        ],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let auditRefreshButton = StacioHoverButton(title: L10n.Diagnostics.refreshAudit, target: nil, action: nil)
    private let auditTextView = NSTextView()
    private let auditEmptyLabel = NSTextField(labelWithString: L10n.Diagnostics.auditEmpty)
    private let importReportTitleLabel = NSTextField(labelWithString: L10n.Diagnostics.importReports)
    private let importReportRefreshButton = StacioHoverButton(title: L10n.Diagnostics.refreshImportReports, target: nil, action: nil)
    private let importReportTextView = NSTextView()
    private let importReportEmptyLabel = NSTextField(labelWithString: L10n.Diagnostics.importReportsEmpty)
    private let appLogTitleLabel = NSTextField(labelWithString: L10n.Diagnostics.appLogs)
    private let appLogRefreshButton = StacioHoverButton(title: L10n.Diagnostics.refreshAppLogs, target: nil, action: nil)
    private let appLogExportButton = StacioHoverButton(title: "导出", target: nil, action: nil)
    private let appLogClearButton = StacioHoverButton(title: "清空", target: nil, action: nil)
    private let appLogSearchField = NSSearchField()
    private let appLogLevelPopup = NSPopUpButton()
    private let appLogFollowLatestButton = NSButton(checkboxWithTitle: "跟随最新", target: nil, action: nil)
    private let appLogTextView = NSTextView()
    private let appLogEmptyLabel = NSTextField(labelWithString: L10n.Diagnostics.appLogsEmpty)
    private let appLogScrollView = NSScrollView()
    private var bundle = DiagnosticBundle(sessionId: "", tunnelId: nil, entries: [])
    private var baseEntries: [DiagnosticEntry] = []
    private var storeRefreshDiagnostics: [String: DiagnosticEntry] = [:]
    private var auditRecords: [BroadcastAuditRecord] = []
    private var agentAuditRecords: [AgentActionAuditRecord] = []
    private var importReports: [ImportReport] = []
    private var appLogLines: [String] = []
    private let appLogStore: StacioLogReading?
    private var appLogSearchQuery = ""
    private var appLogLevelFilter: AppLogLevelFilter = .all
    private var followsLatestAppLogs = true
    private var isProgrammaticAppLogScroll = false
    private var didLoadRecentActivity = false

    public init(
        portProbe: PortProbing = NetworkPortProbe(),
        exportPresenter: DiagnosticsExportPresenting? = nil,
        auditStore: MultiExecAuditListing? = nil,
        agentAuditStore: AgentActionAuditListing? = nil,
        importReportStore: ImportReportListing? = nil,
        appLogStore: StacioLogReading? = StacioLogStore.shared,
        settingsStore: AppSettingsStore = .shared
    ) {
        self.portProbe = portProbe
        self.exportPresenter = exportPresenter ?? AppKitDiagnosticsExportPresenter()
        self.auditStore = auditStore
        self.agentAuditStore = agentAuditStore
        self.importReportStore = importReportStore
        self.appLogStore = appLogStore
        self.settingsStore = settingsStore
        super.init(nibName: nil, bundle: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    public var isFollowingLatestAppLogsForTesting: Bool {
        followsLatestAppLogs
    }

    public var visibleTextSnapshot: String {
        var values = [titleLabel.stringValue]
        if !contextLabel.stringValue.isEmpty {
            values.append(contextLabel.stringValue)
        }
        values.append(portCheckTitleLabel.stringValue)
        if !portResultLabel.stringValue.isEmpty {
            values.append(portResultLabel.stringValue)
        }
        if bundle.entries.isEmpty {
            values.append(emptyLabel.stringValue)
        }
        values.append(contentsOf: bundle.entries.flatMap { entry in
            [severityLabel(for: entry.severity), entry.message]
        })
        let visibleAppLogLines = filteredAppLogLines()
        values.append(importReportTitleLabel.stringValue)
        values.append(importReports.isEmpty ? importReportEmptyLabel.stringValue : importReportTextView.string)
        values.append(auditTitleLabel.stringValue)
        values.append(auditRecords.isEmpty && agentAuditRecords.isEmpty ? auditEmptyLabel.stringValue : auditTextView.string)
        values.append(appLogTitleLabel.stringValue)
        values.append(visibleAppLogLines.isEmpty ? appLogEmptyLabel.stringValue : appLogTextView.string)
        return values.joined(separator: "\n")
    }

    public override func loadView() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.applyInspectorContentSurface(container)

        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        titleLabel.textColor = StacioDesignSystem.theme.primaryTextColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        exportButton.target = self
        exportButton.action = #selector(exportDiagnostics)
        exportButton.setAccessibilityIdentifier("Stacio.Diagnostics.export")
        exportButton.setAccessibilityLabel(L10n.Diagnostics.export)
        exportButton.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.stylePrimaryButton(exportButton)

        contextLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        contextLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        contextLabel.translatesAutoresizingMaskIntoConstraints = false

        configurePortProbeControls()
        configureImportReportControls()
        configureAuditControls()
        configureAppLogControls()

        tableView.addTableColumn(makeColumn(identifier: "severity", title: L10n.Diagnostics.severity, width: 72))
        tableView.addTableColumn(makeColumn(identifier: "message", title: L10n.Diagnostics.message, width: 260))
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.allowsColumnResizing = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.setAccessibilityIdentifier("Stacio.Diagnostics.table")
        tableView.setAccessibilityLabel(L10n.Diagnostics.title)
        StacioDesignSystem.styleTable(tableView)

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        let auditScrollView = makeAuditScrollView()
        let importReportScrollView = makeImportReportScrollView()
        makeAppLogScrollView()

        let hostRow = makePortProbeRow(views: [hostLabel, hostField])
        let portRow = makePortProbeRow(views: [portLabel, portField, checkButton])
        let portProbeControls = NSStackView(views: [hostRow, portRow])
        portProbeControls.orientation = .vertical
        portProbeControls.alignment = .leading
        portProbeControls.spacing = 8
        portProbeControls.setAccessibilityIdentifier("Stacio.Diagnostics.portProbeControls")
        portProbeControls.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        emptyLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let appLogFilterRow = NSStackView(views: [appLogSearchField, appLogLevelPopup])
        appLogFilterRow.orientation = .horizontal
        appLogFilterRow.alignment = .centerY
        appLogFilterRow.spacing = 8
        appLogFilterRow.translatesAutoresizingMaskIntoConstraints = false
        appLogFilterRow.setAccessibilityIdentifier("Stacio.Diagnostics.appLogFilterRow")

        let appLogActionRow = NSStackView(views: [
            appLogRefreshButton,
            appLogExportButton,
            appLogClearButton
        ])
        appLogActionRow.orientation = .horizontal
        appLogActionRow.alignment = .centerY
        appLogActionRow.spacing = 8
        appLogActionRow.translatesAutoresizingMaskIntoConstraints = false
        appLogActionRow.setAccessibilityIdentifier("Stacio.Diagnostics.appLogActions")

        container.addSubview(titleLabel)
        container.addSubview(exportButton)
        container.addSubview(contextLabel)
        container.addSubview(portCheckTitleLabel)
        container.addSubview(portProbeControls)
        container.addSubview(portResultLabel)
        container.addSubview(scrollView)
        container.addSubview(emptyLabel)
        container.addSubview(importReportTitleLabel)
        container.addSubview(importReportRefreshButton)
        container.addSubview(importReportScrollView)
        container.addSubview(importReportEmptyLabel)
        container.addSubview(auditTitleLabel)
        container.addSubview(auditScopeControl)
        container.addSubview(auditRefreshButton)
        container.addSubview(auditScrollView)
        container.addSubview(auditEmptyLabel)
        container.addSubview(appLogTitleLabel)
        container.addSubview(appLogActionRow)
        container.addSubview(appLogFilterRow)
        container.addSubview(appLogScrollView)
        container.addSubview(appLogEmptyLabel)
        container.addSubview(appLogFollowLatestButton)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: exportButton.leadingAnchor, constant: -12),

            exportButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            exportButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            exportButton.widthAnchor.constraint(equalToConstant: 64),
            exportButton.heightAnchor.constraint(equalToConstant: 28),

            contextLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            contextLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -12),
            contextLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),

            portCheckTitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            portCheckTitleLabel.topAnchor.constraint(equalTo: contextLabel.bottomAnchor, constant: 12),

            portProbeControls.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            portProbeControls.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -12),
            portProbeControls.topAnchor.constraint(equalTo: portCheckTitleLabel.bottomAnchor, constant: 8),

            hostLabel.heightAnchor.constraint(equalToConstant: 30),
            hostLabel.widthAnchor.constraint(equalToConstant: 34),
            portLabel.heightAnchor.constraint(equalToConstant: 30),
            portLabel.widthAnchor.constraint(equalToConstant: 34),
            hostField.heightAnchor.constraint(equalToConstant: 30),
            hostField.widthAnchor.constraint(equalToConstant: 176),
            portField.widthAnchor.constraint(equalToConstant: 82),
            portField.heightAnchor.constraint(equalToConstant: 30),
            checkButton.widthAnchor.constraint(equalToConstant: 64),
            checkButton.heightAnchor.constraint(equalToConstant: 28),

            portResultLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            portResultLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -12),
            portResultLabel.topAnchor.constraint(equalTo: portProbeControls.bottomAnchor, constant: 6),

            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            scrollView.topAnchor.constraint(equalTo: portResultLabel.bottomAnchor, constant: 10),
            scrollView.bottomAnchor.constraint(equalTo: importReportTitleLabel.topAnchor, constant: -12),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.leadingAnchor, constant: 16),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.trailingAnchor, constant: -16),

            importReportTitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            importReportTitleLabel.bottomAnchor.constraint(equalTo: importReportScrollView.topAnchor, constant: -8),

            importReportRefreshButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            importReportRefreshButton.centerYAnchor.constraint(equalTo: importReportTitleLabel.centerYAnchor),
            importReportRefreshButton.widthAnchor.constraint(equalToConstant: 56),
            importReportRefreshButton.heightAnchor.constraint(equalToConstant: 24),

            importReportScrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            importReportScrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            importReportScrollView.bottomAnchor.constraint(equalTo: auditTitleLabel.topAnchor, constant: -12),
            importReportScrollView.heightAnchor.constraint(equalToConstant: 96),

            importReportEmptyLabel.centerXAnchor.constraint(equalTo: importReportScrollView.centerXAnchor),
            importReportEmptyLabel.centerYAnchor.constraint(equalTo: importReportScrollView.centerYAnchor),

            auditTitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            auditTitleLabel.bottomAnchor.constraint(equalTo: auditScrollView.topAnchor, constant: -8),

            auditScopeControl.leadingAnchor.constraint(greaterThanOrEqualTo: auditTitleLabel.trailingAnchor, constant: 8),
            auditScopeControl.trailingAnchor.constraint(equalTo: auditRefreshButton.leadingAnchor, constant: -8),
            auditScopeControl.centerYAnchor.constraint(equalTo: auditTitleLabel.centerYAnchor),
            auditScopeControl.widthAnchor.constraint(equalToConstant: 172),
            auditScopeControl.heightAnchor.constraint(equalToConstant: 24),

            auditRefreshButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            auditRefreshButton.centerYAnchor.constraint(equalTo: auditTitleLabel.centerYAnchor),
            auditRefreshButton.widthAnchor.constraint(equalToConstant: 56),
            auditRefreshButton.heightAnchor.constraint(equalToConstant: 24),

            auditScrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            auditScrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            auditScrollView.bottomAnchor.constraint(equalTo: appLogTitleLabel.topAnchor, constant: -12),
            auditScrollView.heightAnchor.constraint(equalToConstant: 92),

            auditEmptyLabel.centerXAnchor.constraint(equalTo: auditScrollView.centerXAnchor),
            auditEmptyLabel.centerYAnchor.constraint(equalTo: auditScrollView.centerYAnchor),

            appLogTitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            appLogTitleLabel.bottomAnchor.constraint(equalTo: appLogFilterRow.topAnchor, constant: -8),
            appLogTitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: appLogActionRow.leadingAnchor, constant: -8),

            appLogActionRow.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            appLogActionRow.centerYAnchor.constraint(equalTo: appLogTitleLabel.centerYAnchor),

            appLogRefreshButton.widthAnchor.constraint(equalToConstant: 56),
            appLogRefreshButton.heightAnchor.constraint(equalToConstant: 24),
            appLogExportButton.widthAnchor.constraint(equalToConstant: 56),
            appLogExportButton.heightAnchor.constraint(equalToConstant: 24),
            appLogClearButton.widthAnchor.constraint(equalToConstant: 56),
            appLogClearButton.heightAnchor.constraint(equalToConstant: 24),

            appLogFilterRow.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            appLogFilterRow.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            appLogFilterRow.bottomAnchor.constraint(equalTo: appLogScrollView.topAnchor, constant: -8),
            appLogFilterRow.heightAnchor.constraint(equalToConstant: 28),
            appLogSearchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            appLogLevelPopup.widthAnchor.constraint(equalToConstant: 92),

            appLogScrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            appLogScrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            appLogScrollView.bottomAnchor.constraint(equalTo: appLogFollowLatestButton.topAnchor, constant: -4),
            appLogScrollView.heightAnchor.constraint(equalToConstant: 112),

            appLogEmptyLabel.centerXAnchor.constraint(equalTo: appLogScrollView.centerXAnchor),
            appLogEmptyLabel.centerYAnchor.constraint(equalTo: appLogScrollView.centerYAnchor),

            appLogFollowLatestButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            appLogFollowLatestButton.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            appLogFollowLatestButton.heightAnchor.constraint(equalToConstant: 22)
        ])

        updateContextLabel()
        updateEmptyState()
        updateImportReportView()
        updateAuditView()
        updateAppLogView()
        view = container
        loadRecentActivityIfNeeded()
    }

    public func replaceBundle(
        sessionID: String,
        tunnelID: String?,
        entries: [DiagnosticEntry]
    ) {
        baseEntries = entries
        bundle = CoreBridge.buildDiagnosticBundle(
            sessionID: sessionID,
            tunnelID: tunnelID,
            entries: diagnosticsEntries()
        )
        updateContextLabel()
        tableView.reloadData()
        updateEmptyState()
    }

    public func loadRecentActivityIfNeeded() {
        guard didLoadRecentActivity == false else {
            return
        }

        didLoadRecentActivity = true
        refreshAuditRecords()
        refreshImportReports()
        refreshAppLogs()
    }

    public func numberOfRows(in tableView: NSTableView) -> Int {
        bundle.entries.count
    }

    public func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard let tableColumn, bundle.entries.indices.contains(row) else {
            return nil
        }

        let identifier = NSUserInterfaceItemIdentifier("DiagnosticCell.\(tableColumn.identifier.rawValue)")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? NSTableCellView()
        cell.identifier = identifier

        let textField = cell.textField ?? NSTextField(labelWithString: "")
        textField.lineBreakMode = .byTruncatingMiddle
        textField.maximumNumberOfLines = 1
        textField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        textField.textColor = StacioDesignSystem.theme.primaryTextColor
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.stringValue = value(for: tableColumn.identifier.rawValue, row: row)
        cell.textField = textField

        if textField.superview == nil {
            cell.addSubview(textField)
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }

        return cell
    }

    private func value(for columnIdentifier: String, row: Int) -> String {
        let entry = bundle.entries[row]
        switch columnIdentifier {
        case "severity":
            return severityLabel(for: entry.severity)
        case "message":
            return entry.message
        default:
            return ""
        }
    }

    private func severityLabel(for severity: DiagnosticSeverity) -> String {
        switch severity {
        case .info:
            return L10n.Diagnostics.info
        case .warning:
            return L10n.Diagnostics.warning
        case .error:
            return L10n.Diagnostics.error
        }
    }

    private func configurePortProbeControls() {
        portCheckTitleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        portCheckTitleLabel.textColor = StacioDesignSystem.theme.primaryTextColor
        portCheckTitleLabel.translatesAutoresizingMaskIntoConstraints = false

        [hostLabel, portLabel].forEach { label in
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = StacioDesignSystem.theme.secondaryTextColor
            label.alignment = .right
            label.translatesAutoresizingMaskIntoConstraints = false
        }

        hostField.setAccessibilityIdentifier("Stacio.Diagnostics.portHost")
        portField.setAccessibilityIdentifier("Stacio.Diagnostics.portNumber")
        portField.placeholderString = "22"
        [hostField, portField].forEach { field in
            field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            field.translatesAutoresizingMaskIntoConstraints = false
            StacioDesignSystem.styleCompactTextField(field)
        }

        checkButton.target = self
        checkButton.action = #selector(checkLocalPort)
        checkButton.setAccessibilityIdentifier("Stacio.Diagnostics.portCheck")
        checkButton.setAccessibilityLabel(L10n.Diagnostics.check)
        checkButton.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.stylePrimaryButton(checkButton)

        portResultLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        portResultLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        portResultLabel.translatesAutoresizingMaskIntoConstraints = false
    }

    private func makePortProbeRow(views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func configureAuditControls() {
        auditTitleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        auditTitleLabel.textColor = StacioDesignSystem.theme.primaryTextColor
        auditTitleLabel.translatesAutoresizingMaskIntoConstraints = false

        auditRefreshButton.target = self
        auditRefreshButton.action = #selector(refreshAuditRecords)
        auditRefreshButton.setAccessibilityIdentifier("Stacio.Diagnostics.auditRefresh")
        auditRefreshButton.setAccessibilityLabel(L10n.Diagnostics.refreshAudit)
        auditRefreshButton.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.stylePrimaryButton(auditRefreshButton)

        auditScopeControl.selectedSegment = 0
        auditScopeControl.target = self
        auditScopeControl.action = #selector(auditScopeChanged(_:))
        auditScopeControl.setAccessibilityIdentifier("Stacio.Diagnostics.auditScope")
        auditScopeControl.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.styleSegmentedControl(auditScopeControl)

        auditTextView.isEditable = false
        auditTextView.isSelectable = true
        auditTextView.drawsBackground = false
        auditTextView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        auditTextView.textColor = StacioDesignSystem.theme.primaryTextColor
        auditTextView.textContainerInset = NSSize(width: 8, height: 8)
        auditTextView.translatesAutoresizingMaskIntoConstraints = false

        auditEmptyLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        auditEmptyLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        auditEmptyLabel.alignment = .center
        auditEmptyLabel.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureAppLogControls() {
        appLogTitleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        appLogTitleLabel.textColor = StacioDesignSystem.theme.primaryTextColor
        appLogTitleLabel.translatesAutoresizingMaskIntoConstraints = false

        appLogRefreshButton.target = self
        appLogRefreshButton.action = #selector(refreshAppLogs)
        appLogRefreshButton.setAccessibilityIdentifier("Stacio.Diagnostics.appLogRefresh")
        appLogRefreshButton.setAccessibilityLabel(L10n.Diagnostics.refreshAppLogs)
        appLogRefreshButton.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.stylePrimaryButton(appLogRefreshButton)

        appLogExportButton.target = self
        appLogExportButton.action = #selector(exportVisibleAppLogs)
        appLogExportButton.setAccessibilityIdentifier("Stacio.Diagnostics.appLogExport")
        appLogExportButton.setAccessibilityLabel("导出日志")
        appLogExportButton.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.stylePrimaryButton(appLogExportButton)

        appLogClearButton.target = self
        appLogClearButton.action = #selector(clearAppLogs)
        appLogClearButton.setAccessibilityIdentifier("Stacio.Diagnostics.appLogClear")
        appLogClearButton.setAccessibilityLabel("清空日志显示")
        appLogClearButton.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.stylePrimaryButton(appLogClearButton)

        appLogSearchField.placeholderString = "搜索日志"
        appLogSearchField.target = self
        appLogSearchField.action = #selector(appLogSearchChanged(_:))
        appLogSearchField.delegate = self
        appLogSearchField.sendsSearchStringImmediately = true
        appLogSearchField.setAccessibilityIdentifier("Stacio.Diagnostics.appLogSearch")
        appLogSearchField.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.styleSearchField(appLogSearchField)

        appLogLevelPopup.removeAllItems()
        appLogLevelPopup.addItems(withTitles: AppLogLevelFilter.allCases.map(\.title))
        appLogLevelPopup.selectItem(withTitle: AppLogLevelFilter.all.title)
        appLogLevelPopup.target = self
        appLogLevelPopup.action = #selector(appLogLevelFilterChanged(_:))
        appLogLevelPopup.setAccessibilityIdentifier("Stacio.Diagnostics.appLogLevel")
        appLogLevelPopup.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.stylePopupButton(appLogLevelPopup)

        appLogFollowLatestButton.target = self
        appLogFollowLatestButton.action = #selector(appLogFollowLatestChanged(_:))
        appLogFollowLatestButton.state = .on
        appLogFollowLatestButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        appLogFollowLatestButton.contentTintColor = StacioDesignSystem.theme.secondaryTextColor
        appLogFollowLatestButton.setAccessibilityIdentifier("Stacio.Diagnostics.appLogFollowLatest")
        appLogFollowLatestButton.setAccessibilityLabel("跟随最新日志")
        appLogFollowLatestButton.translatesAutoresizingMaskIntoConstraints = false

        appLogTextView.isEditable = false
        appLogTextView.isSelectable = true
        appLogTextView.drawsBackground = false
        appLogTextView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        appLogTextView.textColor = StacioDesignSystem.theme.primaryTextColor
        appLogTextView.textContainerInset = NSSize(width: 8, height: 8)
        appLogTextView.setAccessibilityIdentifier("Stacio.Diagnostics.appLogText")
        appLogTextView.translatesAutoresizingMaskIntoConstraints = false

        appLogEmptyLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        appLogEmptyLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        appLogEmptyLabel.alignment = .center
        appLogEmptyLabel.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureImportReportControls() {
        importReportTitleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        importReportTitleLabel.textColor = StacioDesignSystem.theme.primaryTextColor
        importReportTitleLabel.translatesAutoresizingMaskIntoConstraints = false

        importReportRefreshButton.target = self
        importReportRefreshButton.action = #selector(refreshImportReports)
        importReportRefreshButton.setAccessibilityIdentifier("Stacio.Diagnostics.importReportRefresh")
        importReportRefreshButton.setAccessibilityLabel(L10n.Diagnostics.refreshImportReports)
        importReportRefreshButton.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.stylePrimaryButton(importReportRefreshButton)

        importReportTextView.isEditable = false
        importReportTextView.isSelectable = true
        importReportTextView.drawsBackground = false
        importReportTextView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        importReportTextView.textColor = StacioDesignSystem.theme.primaryTextColor
        importReportTextView.textContainerInset = NSSize(width: 8, height: 8)
        importReportTextView.translatesAutoresizingMaskIntoConstraints = false

        importReportEmptyLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        importReportEmptyLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        importReportEmptyLabel.alignment = .center
        importReportEmptyLabel.translatesAutoresizingMaskIntoConstraints = false
    }

    private func makeAuditScrollView() -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.documentView = auditTextView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        return scrollView
    }

    private func makeImportReportScrollView() -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.documentView = importReportTextView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        return scrollView
    }

    private func makeAppLogScrollView() {
        appLogScrollView.documentView = appLogTextView
        appLogScrollView.hasVerticalScroller = true
        appLogScrollView.hasHorizontalScroller = false
        appLogScrollView.borderType = .noBorder
        appLogScrollView.drawsBackground = false
        appLogScrollView.contentView.postsBoundsChangedNotifications = true
        appLogScrollView.setAccessibilityIdentifier("Stacio.Diagnostics.appLogScrollView")
        appLogScrollView.translatesAutoresizingMaskIntoConstraints = false
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appLogClipViewBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: appLogScrollView.contentView
        )
    }

    @objc private func checkLocalPort() {
        let host = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let portText = portField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let portValue = UInt16(portText), portValue > 0 else {
            portResultLabel.stringValue = L10n.Diagnostics.invalidPort
            return
        }

        let resolvedHost = host.isEmpty ? "127.0.0.1" : host
        portProbe.checkPort(host: resolvedHost, port: portValue) { [weak self] result in
            switch result {
            case .reachable:
                self?.portResultLabel.stringValue = L10n.Diagnostics.portReachable(
                    host: resolvedHost,
                    port: portValue
                )
            case .unreachable:
                self?.portResultLabel.stringValue = L10n.Diagnostics.portUnreachable(
                    host: resolvedHost,
                    port: portValue
                )
            }
        }
    }

    @objc private func refreshAuditRecords() {
        if let auditStore {
            do {
                auditRecords = try auditStore.listBroadcastAuditRecords(limit: diagnosticsAuditLimit())
                clearStoreRefreshDiagnostic(for: "multiExecAudit")
            } catch {
                auditRecords = []
                recordStoreRefreshDiagnostic(
                    key: "multiExecAudit",
                    message: "无法读取 MultiExec 审计记录：\(sanitizedErrorMessage(error))"
                )
            }
        } else {
            auditRecords = []
        }

        if let agentAuditStore {
            do {
                agentAuditRecords = try agentAuditStore.listAgentActionEvents(limit: diagnosticsAuditLimit())
                clearStoreRefreshDiagnostic(for: "agentAudit")
            } catch {
                agentAuditRecords = []
                recordStoreRefreshDiagnostic(
                    key: "agentAudit",
                    message: "无法读取 AI/Agent 审计记录：\(sanitizedErrorMessage(error))"
                )
            }
        } else {
            agentAuditRecords = []
        }
        updateAuditView()
    }

    @objc private func auditScopeChanged(_ sender: NSSegmentedControl) {
        updateAuditView()
    }

    @objc private func refreshImportReports() {
        guard let importReportStore else {
            importReports = []
            updateImportReportView()
            return
        }

        do {
            importReports = try importReportStore.listImportReports(limit: 20)
            clearStoreRefreshDiagnostic(for: "importReports")
        } catch {
            importReports = []
            recordStoreRefreshDiagnostic(
                key: "importReports",
                message: "无法读取导入报告：\(sanitizedErrorMessage(error))"
            )
        }
        updateImportReportView()
    }

    @objc private func refreshAppLogs() {
        guard let appLogStore else {
            appLogLines = []
            updateAppLogView()
            return
        }

        do {
            appLogLines = try appLogStore.recentLines(limit: diagnosticsAppLogLineLimit())
            clearStoreRefreshDiagnostic(for: "appLogs")
        } catch {
            appLogLines = []
            recordStoreRefreshDiagnostic(
                key: "appLogs",
                message: "无法读取应用日志：\(sanitizedErrorMessage(error))"
            )
        }
        updateAppLogView()
    }

    @objc private func appLogSearchChanged(_ sender: NSSearchField) {
        appLogSearchQuery = sender.stringValue
        updateAppLogView()
    }

    public func controlTextDidChange(_ obj: Notification) {
        guard obj.object as? NSSearchField === appLogSearchField else {
            return
        }
        appLogSearchQuery = appLogSearchField.stringValue
        updateAppLogView()
    }

    @objc private func appLogLevelFilterChanged(_ sender: NSPopUpButton) {
        appLogLevelFilter = AppLogLevelFilter(title: sender.titleOfSelectedItem)
        updateAppLogView()
    }

    @objc private func clearAppLogs() {
        appLogLines = []
        updateAppLogView()
    }

    @objc private func appLogFollowLatestChanged(_ sender: NSButton) {
        setFollowsLatestAppLogs(sender.state == .on)
        if followsLatestAppLogs {
            scrollAppLogsToBottom()
        }
    }

    @objc private func appLogClipViewBoundsDidChange(_ notification: Notification) {
        guard !isProgrammaticAppLogScroll else {
            return
        }
        setFollowsLatestAppLogs(isAppLogScrolledToBottom())
    }

    @objc private func exportVisibleAppLogs() {
        guard let destinationURL = exportPresenter.chooseExportDestination(
            suggestedName: appLogExportSuggestedName(),
            allowedContentTypes: [.plainText],
            parentWindow: view.window
        ) else {
            return
        }

        do {
            let exportText = filteredAppLogLines()
                .map { AppLogLine(rawValue: $0).exportLine }
                .joined(separator: "\n")
            let content = exportText.isEmpty ? "" : "\(exportText)\n"
            try content.write(to: destinationURL, atomically: true, encoding: .utf8)
            exportPresenter.presentExportComplete(destinationURL: destinationURL, parentWindow: view.window)
        } catch {
            presentExportError(parentWindow: view.window)
        }
    }

    @objc private func exportDiagnostics() {
        guard let destinationURL = exportPresenter.chooseExportDestination(
            suggestedName: L10n.Diagnostics.exportSuggestedName,
            allowedContentTypes: [.json],
            parentWindow: view.window
        ) else {
            return
        }

        do {
            let data = try diagnosticsJSONData()
            try data.write(to: destinationURL, options: [.atomic])
            exportPresenter.presentExportComplete(destinationURL: destinationURL, parentWindow: view.window)
        } catch {
            presentExportError(parentWindow: view.window)
        }
    }

    private func diagnosticsJSONData() throws -> Data {
        let entries = bundle.entries.map { entry -> [String: String] in
            [
                "severity": severityValue(for: entry.severity),
                "message": entry.message
            ]
        }
        let auditScope = auditScopeControl.selectedSegment
        let auditLimit = diagnosticsAuditLimit()
        let auditRecords = auditScope == 1
            ? []
            : ((try? auditStore?.listBroadcastAuditRecords(limit: auditLimit)) ?? [])
        let agentRecords = auditScope == 2
            ? []
            : ((try? agentAuditStore?.listAgentActionEvents(limit: auditLimit)) ?? [])
        let importReports = (try? importReportStore?.listImportReports(limit: 20)) ?? []
        let appLogs = diagnosticsIncludeAppLogs()
            ? ((try? appLogStore?.recentLines(limit: diagnosticsAppLogLineLimit())) ?? [])
            : []
        let object: [String: Any] = [
            "format": "stacio.diagnostics.v1",
            "sessionId": bundle.sessionId,
            "tunnelId": bundle.tunnelId as Any,
            "entries": entries,
            "importReports": importReports.map(importReportExportRecord),
            "multiExecAudit": auditRecords.map(auditExportRecord),
            "agentActions": agentRecords.map(agentAuditExportRecord),
            "appLogs": appLogs.map(sanitizedIssue)
        ]
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    private func severityValue(for severity: DiagnosticSeverity) -> String {
        switch severity {
        case .info:
            return "info"
        case .warning:
            return "warning"
        case .error:
            return "error"
        }
    }

    private func presentExportError(parentWindow: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.Diagnostics.exportFailedTitle
        alert.informativeText = L10n.Diagnostics.exportFailedMessage
        alert.addButton(withTitle: L10n.Common.ok)
        if let parentWindow {
            alert.beginSheetModal(for: parentWindow)
        } else {
            alert.runModal()
        }
    }

    private func diagnosticsAuditLimit() -> UInt32 {
        UInt32(AppSettings.clampedDiagnosticsAuditExportLimit(settingsStore.snapshot().diagnosticsAuditExportLimit))
    }

    private func diagnosticsAppLogLineLimit() -> Int {
        AppSettings.clampedDiagnosticsAppLogLineLimit(settingsStore.snapshot().diagnosticsAppLogLineLimit)
    }

    private func diagnosticsIncludeAppLogs() -> Bool {
        settingsStore.snapshot().diagnosticsIncludeAppLogs
    }

    private func updateContextLabel() {
        guard !bundle.sessionId.isEmpty else {
            contextLabel.stringValue = ""
            return
        }
        let tunnel = bundle.tunnelId.map { " · \($0)" } ?? ""
        contextLabel.stringValue = "\(bundle.sessionId)\(tunnel)"
    }

    private func updateEmptyState() {
        emptyLabel.isHidden = !bundle.entries.isEmpty
    }

    private func diagnosticsEntries() -> [DiagnosticEntry] {
        baseEntries + storeRefreshDiagnostics.keys.sorted().compactMap { storeRefreshDiagnostics[$0] }
    }

    private func recordStoreRefreshDiagnostic(key: String, message: String) {
        storeRefreshDiagnostics[key] = DiagnosticEntry(severity: .warning, message: message)
        rebuildBundlePreservingContext()
    }

    private func clearStoreRefreshDiagnostic(for key: String) {
        guard storeRefreshDiagnostics.removeValue(forKey: key) != nil else {
            return
        }
        rebuildBundlePreservingContext()
    }

    private func rebuildBundlePreservingContext() {
        bundle = CoreBridge.buildDiagnosticBundle(
            sessionID: bundle.sessionId,
            tunnelID: bundle.tunnelId,
            entries: diagnosticsEntries()
        )
        tableView.reloadData()
        updateEmptyState()
    }

    private func updateAuditView() {
        let scope = auditScopeControl.selectedSegment
        var lines: [String] = []
        if scope != 1 {
            lines.append(contentsOf: auditRecords.map(auditLine(for:)))
        }
        if scope != 2, agentAuditRecords.isEmpty == false {
            if lines.isEmpty == false {
                lines.append("")
            }
            lines.append(L10n.Diagnostics.agentAudit)
            lines.append(contentsOf: agentAuditRecords.map(agentAuditLine(for:)))
        }
        auditEmptyLabel.isHidden = !lines.isEmpty
        auditTextView.string = lines.joined(separator: "\n")
    }

    private func updateImportReportView() {
        importReportEmptyLabel.isHidden = !importReports.isEmpty
        importReportTextView.string = importReports.map(importReportLine(for:)).joined(separator: "\n")
    }

    private func updateAppLogView() {
        let visibleLines = filteredAppLogLines()
        appLogEmptyLabel.isHidden = !visibleLines.isEmpty
        appLogTextView.textStorage?.setAttributedString(appLogAttributedString(for: visibleLines))
        if followsLatestAppLogs {
            scrollAppLogsToBottom()
        }
    }

    private func filteredAppLogLines() -> [String] {
        let query = appLogSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return appLogLines.filter { line in
            let parsedLine = AppLogLine(rawValue: line)
            guard appLogLevelFilter.matches(parsedLine.level) else {
                return false
            }
            if query.isEmpty {
                return true
            }
            return line.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    private func appLogAttributedString(for lines: [String]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
            .foregroundColor: StacioDesignSystem.theme.primaryTextColor
        ]

        for (index, line) in lines.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "\n", attributes: baseAttributes))
            }
            let parsedLine = AppLogLine(rawValue: line)
            let attributedLine = NSMutableAttributedString(string: line, attributes: baseAttributes)
            if let level = parsedLine.level, let range = parsedLine.levelRange {
                attributedLine.addAttribute(.foregroundColor, value: appLogColor(for: level), range: range)
            }
            result.append(attributedLine)
        }
        return result
    }

    private func appLogColor(for level: AppLogLevel) -> NSColor {
        switch level {
        case .error, .fatal:
            return StacioDesignSystem.theme.dangerColor
        case .warning:
            return StacioDesignSystem.theme.warningColor
        case .debug:
            return StacioDesignSystem.theme.secondaryTextColor
        case .info:
            return StacioDesignSystem.theme.primaryTextColor
        }
    }

    private func setFollowsLatestAppLogs(_ follows: Bool) {
        followsLatestAppLogs = follows
        appLogFollowLatestButton.state = follows ? .on : .off
    }

    private func scrollAppLogsToBottom() {
        guard !appLogTextView.string.isEmpty else {
            return
        }
        isProgrammaticAppLogScroll = true
        defer { isProgrammaticAppLogScroll = false }
        appLogTextView.scrollRangeToVisible(NSRange(location: appLogTextView.string.utf16.count, length: 0))
        appLogScrollView.reflectScrolledClipView(appLogScrollView.contentView)
    }

    private func isAppLogScrolledToBottom() -> Bool {
        guard let documentView = appLogScrollView.documentView else {
            return true
        }
        let visibleMaxY = appLogScrollView.contentView.bounds.maxY
        let documentHeight = documentView.bounds.height
        return visibleMaxY >= documentHeight - 2
    }

    private func appLogExportSuggestedName(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        let sessionID = sanitizedAppLogSessionID(bundle.sessionId)
        return "stacio-log-\(sessionID)-\(formatter.string(from: date)).txt"
    }

    private func sanitizedAppLogSessionID(_ sessionID: String) -> String {
        let trimmed = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.isEmpty ? "current" : trimmed
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        let scalars = value.unicodeScalars.map { scalar -> String in
            allowed.contains(scalar) ? String(scalar) : "_"
        }
        let sanitized = scalars.joined()
            .replacingOccurrences(of: "__+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return sanitized.isEmpty ? "current" : sanitized
    }

    private func auditLine(for record: BroadcastAuditRecord) -> String {
        [
            record.createdAt,
            L10n.Diagnostics.auditTargets(record.targetCount),
            L10n.Diagnostics.auditDelivery(sent: record.sentCount, failed: record.failedCount),
            sanitizedIssue(record.redactedInput)
        ].joined(separator: " · ")
    }

    private func agentAuditLine(for record: AgentActionAuditRecord) -> String {
        var values = [
            record.createdAt,
            L10n.Diagnostics.auditRequest(record.requestId),
            sanitizedIssue(record.actorName),
            sanitizedIssue(record.targetTitle),
            sanitizedIssue(record.actionKind),
            sanitizedIssue(record.risk),
            sanitizedIssue(record.state),
            sanitizedIssue(record.environment),
            sanitizedIssue(record.approvalMode),
            sanitizedIssue(record.policyDecision),
            sanitizedIssue(record.redactionVersion),
            sanitizedIssue(record.redactedInput)
        ]
        if let targetRuntimeId = record.targetRuntimeId?.trimmingCharacters(in: .whitespacesAndNewlines),
           targetRuntimeId.isEmpty == false {
            values.insert(
                L10n.Diagnostics.auditRuntime(sanitizedIssue(targetRuntimeId)),
                at: 4
            )
        }
        return values.joined(separator: " · ")
    }

    private func importReportLine(for report: ImportReport) -> String {
        var values = [
            report.createdAt,
            sanitizedIssue(report.sourceName),
            sanitizedIssue(report.status),
            L10n.Diagnostics.importReportCounts(
                imported: report.importedCount,
                skipped: report.skippedCount,
                failed: report.failedCount
            )
        ]
        let issues = report.issues.map(sanitizedIssue).filter { !$0.isEmpty }
        if !issues.isEmpty {
            values.append(issues.joined(separator: "；"))
        }
        return values.joined(separator: " · ")
    }

    private func sanitizedErrorMessage(_ error: Error) -> String {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let sanitized = sanitizedIssue(message.trimmingCharacters(in: .whitespacesAndNewlines))
        return sanitized.isEmpty ? "未知错误" : sanitized
    }

    private func sanitizedIssue(_ issue: String) -> String {
        var redactedTokens: [String] = []
        var shouldRedactNext = false

        for rawToken in issue.split(whereSeparator: \.isWhitespace) {
            let token = String(rawToken)
            let lowercased = token.lowercased()

            if lowercased.contains("[redacted") {
                redactedTokens.append(L10n.Diagnostics.redactedCredential)
                shouldRedactNext = false
                continue
            }

            if lowercased.contains("[已隐藏") {
                redactedTokens.append(token)
                shouldRedactNext = false
                continue
            }

            if shouldRedactNext {
                if token == "=" || token == ":" {
                    continue
                }
                redactedTokens.append(L10n.Diagnostics.redactedCredential)
                shouldRedactNext = false
                continue
            }

            if lowercased.contains("password")
                || lowercased.contains("secret")
                || lowercased.contains("credential")
                || lowercased.contains("token")
                || lowercased.contains("api_key")
            {
                redactedTokens.append(L10n.Diagnostics.redactedCredential)
                if lowercased == "password"
                    || lowercased == "secret"
                    || lowercased == "credential"
                    || lowercased == "token"
                    || lowercased == "api_key"
                    || lowercased.hasSuffix(":")
                    || lowercased.hasSuffix("=")
                {
                    shouldRedactNext = true
                }
                continue
            }

            if token.hasPrefix("/") || token.hasPrefix("~") || token.contains("/.ssh/") || token.contains(".ssh/") {
                redactedTokens.append(L10n.Diagnostics.redactedPath)
                continue
            }

            redactedTokens.append(token)
        }

        return redactedTokens.joined(separator: " ")
    }

    private func importReportExportRecord(for report: ImportReport) -> [String: Any] {
        [
            "id": report.id,
            "sourceType": report.sourceType,
            "sourceName": sanitizedIssue(report.sourceName),
            "status": sanitizedIssue(report.status),
            "importedCount": report.importedCount,
            "skippedCount": report.skippedCount,
            "failedCount": report.failedCount,
            "issues": report.issues.map(sanitizedIssue),
            "createdAt": report.createdAt
        ]
    }

    private func auditExportRecord(for record: BroadcastAuditRecord) -> [String: Any] {
        [
            "id": record.id,
            "traceId": record.traceId,
            "targetCount": record.targetCount,
            "sentCount": record.sentCount,
            "failedCount": record.failedCount,
            "redactedInput": sanitizedIssue(record.redactedInput),
            "executed": record.executed,
            "createdAt": record.createdAt
        ]
    }

    private func agentAuditExportRecord(for record: AgentActionAuditRecord) -> [String: Any] {
        [
            "id": record.id,
            "requestId": record.requestId,
            "actorKind": sanitizedIssue(record.actorKind),
            "actorName": sanitizedIssue(record.actorName),
            "targetRuntimeId": (record.targetRuntimeId.map { sanitizedIssue($0) } as Any?) ?? NSNull(),
            "targetTitle": sanitizedIssue(record.targetTitle),
            "actionKind": sanitizedIssue(record.actionKind),
            "risk": sanitizedIssue(record.risk),
            "state": sanitizedIssue(record.state),
            "environment": sanitizedIssue(record.environment),
            "approvalMode": sanitizedIssue(record.approvalMode),
            "policyDecision": sanitizedIssue(record.policyDecision),
            "redactionVersion": sanitizedIssue(record.redactionVersion),
            "redactedInput": sanitizedIssue(record.redactedInput),
            "createdAt": record.createdAt
        ]
    }

    private func makeColumn(identifier: String, title: String, width: CGFloat) -> NSTableColumn {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
        column.title = title
        column.width = width
        column.minWidth = 64
        column.resizingMask = .userResizingMask
        return column
    }
}
