import AppKit
import Foundation

/// Native instance editor for Local Agent configurations. Reads come directly
/// from the Local Agent configuration/journal owners; every mutation still
/// crosses the Settings Action Coordinator supplied by the window.
@MainActor
final class LocalAgentSettingsViewController: NSViewController,
    NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSTokenFieldDelegate
{
    private enum DetailStatusTone {
        case neutral
        case error
    }

    private struct DetailStatusPresentation {
        let text: String
        let tone: DetailStatusTone
    }

    private let coordinator: LocalAgentSettingsCoordinator
    private let actionAvailability: (String) -> Bool
    private let actionHandler: V2SettingsActionHandler

    private let splitView = NSSplitView()
    private let listTable = NSTableView()
    private let listStatusLabel = NSTextField(labelWithString: "")
    private let addButton = NSButton()
    private let reconcileButton = NSButton()
    private let detailScrollView = NSScrollView()
    private let detailStack = NSStackView()

    private var configurations: [LocalAgentConfigurationRecord] = []
    private var unresolvedMaintenance: [LocalAgentMaintenanceProcessJournalEntry] = []
    private var selectedConfigurationID: String?
    private var operationInProgress = false
    private var detailStatusByConfigurationID: [String: DetailStatusPresentation] = [:]

    private var displayNameField: NSTextField?
    private var enabledSwitch: NSSwitch?
    private var profilePopup: NSPopUpButton?
    private var workingDirectoryPopup: NSPopUpButton?
    private var workingDirectoryField: NSTextField?
    private var chooseDirectoryButton: NSButton?
    private var pathPolicyPopup: NSPopUpButton?
    private var customPATHField: NSTokenField?
    private var environmentAllowlistField: NSTokenField?
    private var detectAndSaveButton: NSButton?
    private var loginButton: NSButton?
    private var logoutButton: NSButton?
    private var openUpgradeButton: NSButton?
    private var deleteButton: NSButton?
    private var detailStatusLabel: NSTextField?
    private var emptyDetectButtons: [NSButton] = []
    private var emptyWebsiteButtons: [NSButton] = []

    init(
        coordinator: LocalAgentSettingsCoordinator,
        actionAvailability: @escaping (String) -> Bool,
        actionHandler: @escaping V2SettingsActionHandler
    ) {
        self.coordinator = coordinator
        self.actionAvailability = actionAvailability
        self.actionHandler = actionHandler
        super.init(nibName: nil, bundle: nil)
        coordinator.onConfigurationsChanged = { [weak self] in
            DispatchQueue.main.async { self?.reloadData() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        root.setAccessibilityIdentifier("Stacio.Settings.localAgent.instances")

        configureList()
        configureDetail()

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.setAccessibilityIdentifier("Stacio.Settings.localAgent.splitView")
        splitView.addArrangedSubview(makeListContainer())
        splitView.addArrangedSubview(detailScrollView)

        root.addSubview(splitView)
        NSLayoutConstraint.activate([
            splitView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            splitView.topAnchor.constraint(equalTo: root.topAnchor),
            splitView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.heightAnchor.constraint(greaterThanOrEqualToConstant: 580)
        ])
        view = root
        reloadData()
    }

    private func configureList() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("local-agent"))
        column.resizingMask = .autoresizingMask
        listTable.addTableColumn(column)
        listTable.headerView = nil
        listTable.rowHeight = 48
        listTable.intercellSpacing = NSSize(width: 0, height: 2)
        listTable.selectionHighlightStyle = .regular
        listTable.style = .sourceList
        listTable.dataSource = self
        listTable.delegate = self
        listTable.setAccessibilityIdentifier("Stacio.Settings.localAgent.list")

        configureIconButton(
            addButton,
            symbol: "plus",
            description: "添加本地 Agent",
            action: #selector(addConfiguration(_:))
        )
        addButton.setAccessibilityIdentifier("Stacio.Settings.localAgent.add")
        configureIconButton(
            reconcileButton,
            symbol: "arrow.triangle.2.circlepath",
            description: "对账本地 Agent 进程",
            action: #selector(reconcileMaintenance(_:))
        )
        reconcileButton.setAccessibilityIdentifier("Stacio.Settings.localAgent.reconcile")
        reconcileButton.isHidden = true

        listStatusLabel.font = .systemFont(ofSize: 11)
        listStatusLabel.textColor = .secondaryLabelColor
        listStatusLabel.lineBreakMode = .byTruncatingTail
        listStatusLabel.setAccessibilityIdentifier("Stacio.Settings.localAgent.listStatus")
    }

    private func makeListContainer() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.setAccessibilityIdentifier("Stacio.Settings.localAgent.sidebar")

        let title = NSTextField(labelWithString: "配置")
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        let spacer = NSView()
        let header = NSStackView(views: [title, spacer, reconcileButton, addButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 4
        header.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.documentView = listTable
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(header)
        container.addSubview(scroll)
        container.addSubview(listStatusLabel)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 224),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            header.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            header.heightAnchor.constraint(equalToConstant: 30),
            addButton.widthAnchor.constraint(equalToConstant: 28),
            addButton.heightAnchor.constraint(equalToConstant: 28),
            reconcileButton.widthAnchor.constraint(equalToConstant: 28),
            reconcileButton.heightAnchor.constraint(equalToConstant: 28),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            scroll.bottomAnchor.constraint(equalTo: listStatusLabel.topAnchor, constant: -6),
            listStatusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            listStatusLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            listStatusLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
            listStatusLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 16)
        ])
        return container
    }

    private func configureDetail() {
        detailScrollView.hasVerticalScroller = true
        detailScrollView.autohidesScrollers = true
        detailScrollView.drawsBackground = false
        detailScrollView.borderType = .noBorder
        detailScrollView.translatesAutoresizingMaskIntoConstraints = false
        detailScrollView.setAccessibilityIdentifier("Stacio.Settings.localAgent.detailScroll")

        detailStack.orientation = .vertical
        detailStack.alignment = .leading
        detailStack.spacing = 12
        detailStack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 22, right: 20)
        detailStack.translatesAutoresizingMaskIntoConstraints = false
        detailStack.setAccessibilityIdentifier("Stacio.Settings.localAgent.detail")
        detailScrollView.documentView = detailStack
        NSLayoutConstraint.activate([
            detailStack.leadingAnchor.constraint(equalTo: detailScrollView.contentView.leadingAnchor),
            detailStack.trailingAnchor.constraint(equalTo: detailScrollView.contentView.trailingAnchor),
            detailStack.topAnchor.constraint(equalTo: detailScrollView.contentView.topAnchor),
            detailStack.widthAnchor.constraint(equalTo: detailScrollView.contentView.widthAnchor)
        ])
    }

    private func reloadData(selecting preferredConfigurationID: String? = nil) {
        let previous = preferredConfigurationID ?? selectedConfigurationID
        do {
            configurations = try coordinator.configurations()
            unresolvedMaintenance = try coordinator.maintenanceProcessEntries().filter {
                LocalAgentSettingsProcessJournal.reconciliationRequired(
                    state: $0.state,
                    settlement: $0.settlement
                )
            }.sorted {
                if $0.configurationID != $1.configurationID {
                    return $0.configurationID < $1.configurationID
                }
                if $0.action.rawValue != $1.action.rawValue {
                    return $0.action.rawValue < $1.action.rawValue
                }
                return $0.referenceID < $1.referenceID
            }
            listStatusLabel.stringValue = configurations.isEmpty ? "尚未添加" : ""
        } catch {
            configurations = []
            unresolvedMaintenance = []
            listStatusLabel.stringValue = "配置读取失败"
        }

        reconcileButton.isHidden = unresolvedMaintenance.isEmpty
        let reconciliationDescription = "对账本地 Agent 进程（\(unresolvedMaintenance.count)）"
        reconcileButton.toolTip = reconciliationDescription
        reconcileButton.setAccessibilityLabel(reconciliationDescription)
        reconcileButton.isEnabled = !operationInProgress
            && actionAvailability("localAgent.reconcileProcesses")
        addButton.isEnabled = !operationInProgress && !coordinator.catalogEntries().isEmpty
        listTable.reloadData()

        if let previous,
           let row = configurations.firstIndex(where: { $0.configurationID == previous }) {
            selectedConfigurationID = previous
            listTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else if let first = configurations.first {
            selectedConfigurationID = first.configurationID
            listTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        } else {
            selectedConfigurationID = nil
            listTable.deselectAll(nil)
        }
        renderDetail()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        configurations.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard configurations.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("LocalAgentSettingsListCell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self)
            as? LocalAgentSettingsListCell) ?? LocalAgentSettingsListCell(identifier: identifier)
        let record = configurations[row]
        let descriptor = coordinator.catalogEntry(catalogID: record.catalogID)
        cell.configure(
            title: record.userDisplayName.isEmpty ? (descriptor?.displayName ?? record.rawIdentity) : record.userDisplayName,
            detail: listDetail(record: record, descriptor: descriptor),
            enabled: record.explicitlyEnabled
        )
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = listTable.selectedRow
        guard configurations.indices.contains(row) else { return }
        selectedConfigurationID = configurations[row].configurationID
        renderDetail()
    }

    private func renderDetail() {
        detailStack.arrangedSubviews.forEach {
            detailStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        clearDetailControlReferences()

        guard let record = selectedRecord else {
            detailStack.addArrangedSubview(makeEmptyState())
            return
        }
        let descriptor = coordinator.catalogEntry(catalogID: record.catalogID)

        let nameField = NSTextField(string: record.userDisplayName)
        nameField.setAccessibilityIdentifier("Stacio.Settings.localAgent.displayName")
        styleTextField(nameField, width: 280)
        nameField.target = self
        nameField.action = #selector(detailValueChanged(_:))
        nameField.delegate = self
        displayNameField = nameField

        let enabled = NSSwitch()
        enabled.state = record.explicitlyEnabled ? .on : .off
        enabled.target = self
        enabled.action = #selector(detailValueChanged(_:))
        enabled.setAccessibilityIdentifier("Stacio.Settings.localAgent.enabled")
        enabledSwitch = enabled

        let heading = makeDetailHeading(record: record, descriptor: descriptor)
        addDetailArrangedSubview(heading, fullWidth: true)
        addDetailArrangedSubview(makeSeparator(), fullWidth: true)
        detailStack.addArrangedSubview(makeSectionTitle("配置"))
        addDetailArrangedSubview(makeForm(rows: [
            ("名称", nameField),
            ("启用", enabled)
        ]), fullWidth: true)

        let executable = makeReadOnlyField(record.executablePath, identifier: "Stacio.Settings.localAgent.executablePath")
        let version = makeReadOnlyLabel(
            record.detectedVersion.isEmpty ? "未知" : record.detectedVersion,
            identifier: "Stacio.Settings.localAgent.version"
        )
        let authentication = makeReadOnlyLabel(
            authenticationTitle(record.authenticationState),
            identifier: "Stacio.Settings.localAgent.authentication"
        )
        let lastVerified = makeReadOnlyLabel(
            Self.timestampFormatter.string(from: record.lastVerifiedAt),
            identifier: "Stacio.Settings.localAgent.lastVerified"
        )
        addDetailArrangedSubview(makeSeparator(), fullWidth: true)
        detailStack.addArrangedSubview(makeSectionTitle("检测与登录"))
        addDetailArrangedSubview(makeForm(rows: [
            ("可执行文件", executable),
            ("版本", version),
            ("登录状态", authentication),
            ("最后验证", lastVerified)
        ]), fullWidth: true)
        addDetailArrangedSubview(
            makeMaintenanceActions(record: record, descriptor: descriptor),
            fullWidth: true
        )

        let profile = NSPopUpButton()
        let profiles = descriptor.map {
            selectableExecutionProfiles($0, retaining: record.executionProfileID)
        } ?? []
        for item in profiles {
            profile.addItem(withTitle: profileTitle(item))
            profile.lastItem?.representedObject = item.profileID
        }
        if let index = profile.itemArray.firstIndex(where: {
            ($0.representedObject as? String) == record.executionProfileID
        }) {
            profile.selectItem(at: index)
        }
        profile.target = self
        profile.action = #selector(detailValueChanged(_:))
        profile.setAccessibilityIdentifier("Stacio.Settings.localAgent.executionProfile")
        profilePopup = profile

        let workingMode = NSPopUpButton()
        let supportedModes = descriptor?.supportedWorkingDirectoryModes.isEmpty == false
            ? descriptor!.supportedWorkingDirectoryModes
            : AgentProcessWorkingDirectoryMode.allCases
        for mode in supportedModes {
            workingMode.addItem(withTitle: workingDirectoryTitle(mode))
            workingMode.lastItem?.representedObject = mode.rawValue
        }
        workingMode.selectItem(withRepresentedObject: record.workingDirectoryMode.rawValue)
        workingMode.target = self
        workingMode.action = #selector(workingDirectoryModeChanged(_:))
        workingMode.setAccessibilityIdentifier("Stacio.Settings.localAgent.workingDirectoryMode")
        workingDirectoryPopup = workingMode

        let workingDirectory = NSTextField(string: record.workingDirectoryReference ?? "")
        styleTextField(workingDirectory, width: 280)
        workingDirectory.placeholderString = "选择 Mac 本地目录"
        workingDirectory.target = self
        workingDirectory.action = #selector(detailValueChanged(_:))
        workingDirectory.delegate = self
        workingDirectory.setAccessibilityLabel("本地目录")
        workingDirectory.setAccessibilityIdentifier("Stacio.Settings.localAgent.workingDirectoryReference")
        workingDirectoryField = workingDirectory

        let chooseDirectory = NSButton()
        configureIconButton(
            chooseDirectory,
            symbol: "folder",
            description: "选择 Mac 本地目录",
            action: #selector(chooseWorkingDirectory(_:))
        )
        chooseDirectory.setAccessibilityIdentifier("Stacio.Settings.localAgent.chooseWorkingDirectory")
        chooseDirectory.widthAnchor.constraint(equalToConstant: 28).isActive = true
        chooseDirectory.heightAnchor.constraint(equalToConstant: 28).isActive = true
        chooseDirectoryButton = chooseDirectory
        let workingDirectoryRow = NSStackView(views: [workingDirectory, chooseDirectory])
        workingDirectoryRow.orientation = .horizontal
        workingDirectoryRow.alignment = .centerY
        workingDirectoryRow.spacing = 6

        let pathPolicy = NSPopUpButton()
        for policy in [LocalAgentPATHPolicy.controlled, .loginShell, .custom] {
            pathPolicy.addItem(withTitle: pathPolicyTitle(policy))
            pathPolicy.lastItem?.representedObject = policy.rawValue
        }
        pathPolicy.selectItem(withRepresentedObject: record.pathPolicy.rawValue)
        pathPolicy.target = self
        pathPolicy.action = #selector(pathPolicyChanged(_:))
        pathPolicy.setAccessibilityIdentifier("Stacio.Settings.localAgent.pathPolicy")
        pathPolicyPopup = pathPolicy

        let customPATH = makeTokenField(
            values: record.customPATHEntries,
            identifier: "Stacio.Settings.localAgent.customPATHEntries"
        )
        customPATHField = customPATH
        let environment = makeTokenField(
            values: record.environmentAllowlist,
            identifier: "Stacio.Settings.localAgent.environmentAllowlist"
        )
        environmentAllowlistField = environment

        addDetailArrangedSubview(makeSeparator(), fullWidth: true)
        detailStack.addArrangedSubview(makeSectionTitle("运行环境"))
        addDetailArrangedSubview(makeForm(rows: [
            ("执行配置", profile),
            ("工作目录", workingMode),
            ("本地目录", workingDirectoryRow),
            ("PATH", pathPolicy),
            ("自定义 PATH", customPATH),
            ("环境变量白名单", environment)
        ]), fullWidth: true)

        let status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 2
        status.lineBreakMode = .byWordWrapping
        status.setAccessibilityIdentifier("Stacio.Settings.localAgent.detailStatus")
        status.setAccessibilityLabel("配置状态")
        detailStatusLabel = status

        let save = NSButton(
            title: "检测并保存",
            target: self,
            action: #selector(detectAndSave(_:))
        )
        save.bezelStyle = .rounded
        save.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "检测并保存")
        save.imagePosition = .imageLeading
        save.setAccessibilityIdentifier("Stacio.Settings.localAgent.detectAndSave")
        detectAndSaveButton = save

        let delete = NSButton()
        configureIconButton(
            delete,
            symbol: "trash",
            description: "删除本地 Agent 配置",
            action: #selector(deleteConfiguration(_:))
        )
        delete.contentTintColor = .systemRed
        delete.setAccessibilityIdentifier("Stacio.Settings.localAgent.delete")
        delete.widthAnchor.constraint(equalToConstant: 30).isActive = true
        delete.heightAnchor.constraint(equalToConstant: 30).isActive = true
        deleteButton = delete

        let footerSpacer = NSView()
        let footer = NSStackView(views: [status, footerSpacer, delete, save])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false
        addDetailArrangedSubview(makeSeparator(), fullWidth: true)
        addDetailArrangedSubview(footer, fullWidth: true)

        updateConditionalControls(record: record)
        updateActionEnablement()
    }

    private func makeDetailHeading(
        record: LocalAgentConfigurationRecord,
        descriptor: LocalAgentCatalogEntry?
    ) -> NSView {
        let title = NSTextField(
            labelWithString: record.userDisplayName.isEmpty
                ? (descriptor?.displayName ?? record.rawIdentity)
                : record.userDisplayName
        )
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let subtitle = NSTextField(
            labelWithString: "\(descriptor?.displayName ?? record.rawIdentity) · \(supportTitle(descriptor?.supportLevel))"
        )
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor

        let labels = NSStackView(views: [title, subtitle])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        let header = NSStackView(views: [labels, spacer])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.translatesAutoresizingMaskIntoConstraints = false
        return header
    }

    private func makeMaintenanceActions(
        record: LocalAgentConfigurationRecord,
        descriptor: LocalAgentCatalogEntry?
    ) -> NSView {
        let login = NSButton(title: "登录", target: self, action: #selector(login(_:)))
        login.bezelStyle = .rounded
        login.image = NSImage(systemSymbolName: "person.crop.circle.badge.checkmark", accessibilityDescription: "登录")
        login.imagePosition = .imageLeading
        login.isHidden = descriptor?.loginArgv == nil || record.authenticationState == .authenticated
        login.setAccessibilityIdentifier("Stacio.Settings.localAgent.login")
        loginButton = login

        let logout = NSButton(title: "退出登录", target: self, action: #selector(logout(_:)))
        logout.bezelStyle = .rounded
        logout.image = NSImage(systemSymbolName: "rectangle.portrait.and.arrow.right", accessibilityDescription: "退出登录")
        logout.imagePosition = .imageLeading
        logout.isHidden = descriptor?.logoutArgv == nil || record.authenticationState != .authenticated
        logout.setAccessibilityIdentifier("Stacio.Settings.localAgent.logout")
        logoutButton = logout

        let website = NSButton()
        configureIconButton(
            website,
            symbol: "arrow.up.right.square",
            description: "打开 Coding Plan 官网",
            action: #selector(openUpgrade(_:))
        )
        website.isHidden = coordinator.codingPlanTarget(for: record) == nil
            && descriptor?.upgradeActionID == nil
        website.setAccessibilityIdentifier("Stacio.Settings.localAgent.openUpgrade")
        website.widthAnchor.constraint(equalToConstant: 30).isActive = true
        website.heightAnchor.constraint(equalToConstant: 30).isActive = true
        openUpgradeButton = website

        let spacer = NSView()
        let actions = NSStackView(views: [login, logout, spacer, website])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8
        actions.translatesAutoresizingMaskIntoConstraints = false
        return actions
    }

    @objc private func addConfiguration(_ sender: NSButton) {
        let entries = coordinator.catalogEntries()
        guard !entries.isEmpty else { return }
        let menu = NSMenu(title: "添加本地 Agent")
        for entry in entries {
            let item = NSMenuItem(
                title: "\(entry.displayName) · \(supportTitle(entry.supportLevel))",
                action: #selector(addCatalogEntry(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = entry.catalogID
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 2), in: sender)
    }

    @objc private func addCatalogEntry(_ sender: NSMenuItem) {
        guard let catalogID = sender.representedObject as? String else { return }
        previewDetection(catalogID: catalogID, selectedPath: nil)
    }

    private func previewDetection(catalogID: String, selectedPath: String?) {
        guard !operationInProgress else { return }
        operationInProgress = true
        updateActionEnablement()
        listStatusLabel.stringValue = "正在检测..."
        coordinator.previewDetection(
            catalogID: catalogID,
            userSelectedExecutablePath: selectedPath
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.operationInProgress = false
                self.updateActionEnablement()
                switch result {
                case .success(let report) where !report.candidates.isEmpty:
                    self.listStatusLabel.stringValue = ""
                    self.presentDetectionConfirmation(catalogID: catalogID, report: report)
                case .success:
                    self.listStatusLabel.stringValue = "未检测到可执行文件"
                    self.chooseExecutableForDetection(catalogID: catalogID)
                case .failure:
                    self.listStatusLabel.stringValue = "检测失败"
                }
            }
        }
    }

    private func chooseExecutableForDetection(catalogID: String) {
        let panel = NSOpenPanel()
        panel.title = "选择本地 Agent 可执行文件"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self, weak panel] response in
            guard response == .OK, let path = panel?.url?.standardizedFileURL.path else { return }
            self?.previewDetection(catalogID: catalogID, selectedPath: path)
        }
        if let window = view.window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }

    private func presentDetectionConfirmation(
        catalogID: String,
        report: LocalAgentDetectionReport
    ) {
        guard let descriptor = coordinator.catalogEntry(catalogID: catalogID) else { return }
        let profiles = selectableExecutionProfiles(descriptor)
        guard !profiles.isEmpty else {
            listStatusLabel.stringValue = "没有可用执行配置"
            return
        }
        let workingDirectoryModes = descriptor.supportedWorkingDirectoryModes
        guard !workingDirectoryModes.isEmpty else {
            listStatusLabel.stringValue = "没有可用工作目录策略"
            return
        }

        let nameField = NSTextField(string: descriptor.displayName)
        nameField.placeholderString = "名称"
        nameField.widthAnchor.constraint(equalToConstant: 360).isActive = true
        let executablePopup = NSPopUpButton()
        for (index, candidate) in report.candidates.enumerated() {
            executablePopup.addItem(withTitle: "\(candidate.executablePath) · \(candidate.detectedVersion)")
            executablePopup.lastItem?.representedObject = index
        }
        let profilePopup = NSPopUpButton()
        for (index, profile) in profiles.enumerated() {
            profilePopup.addItem(withTitle: profileTitle(profile))
            profilePopup.lastItem?.representedObject = index
        }
        let workingDirectoryPopup = NSPopUpButton()
        for mode in workingDirectoryModes {
            workingDirectoryPopup.addItem(withTitle: workingDirectoryTitle(mode))
            workingDirectoryPopup.lastItem?.representedObject = mode.rawValue
        }
        let accessory = NSStackView(views: [
            makeAlertRow(title: "名称", control: nameField),
            makeAlertRow(title: "可执行文件", control: executablePopup),
            makeAlertRow(title: "执行配置", control: profilePopup),
            makeAlertRow(title: "工作目录", control: workingDirectoryPopup)
        ])
        accessory.orientation = .vertical
        accessory.alignment = .leading
        accessory.spacing = 8

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "添加 \(descriptor.displayName)"
        alert.informativeText = "确认检测结果后创建配置。"
        alert.accessoryView = accessory
        alert.addButton(withTitle: "添加")
        alert.addButton(withTitle: "取消")
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn,
                  let candidateIndex = executablePopup.selectedItem?.representedObject as? Int,
                  report.candidates.indices.contains(candidateIndex),
                  let profileIndex = profilePopup.selectedItem?.representedObject as? Int,
                  profiles.indices.contains(profileIndex),
                  let workingDirectoryRaw = workingDirectoryPopup.selectedItem?.representedObject as? String,
                  let workingDirectoryMode = AgentProcessWorkingDirectoryMode(rawValue: workingDirectoryRaw)
            else { return }
            self?.submitDetectedCandidateAfterChoosingDirectoryIfNeeded(
                catalogID: catalogID,
                candidate: report.candidates[candidateIndex],
                displayName: nameField.stringValue,
                profileID: profiles[profileIndex].profileID,
                workingDirectoryMode: workingDirectoryMode
            )
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    private func submitDetectedCandidateAfterChoosingDirectoryIfNeeded(
        catalogID: String,
        candidate: LocalAgentDetectedExecutable,
        displayName: String,
        profileID: String,
        workingDirectoryMode: AgentProcessWorkingDirectoryMode
    ) {
        guard workingDirectoryMode == .userSelectedLocalDirectory else {
            submitDetectedCandidate(
                catalogID: catalogID,
                candidate: candidate,
                displayName: displayName,
                profileID: profileID,
                workingDirectoryMode: workingDirectoryMode,
                workingDirectoryReference: nil
            )
            return
        }

        let panel = NSOpenPanel()
        panel.title = "选择本地 Agent 工作目录"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self, weak panel] response in
            guard response == .OK, let path = panel?.url?.standardizedFileURL.path else { return }
            self?.submitDetectedCandidate(
                catalogID: catalogID,
                candidate: candidate,
                displayName: displayName,
                profileID: profileID,
                workingDirectoryMode: workingDirectoryMode,
                workingDirectoryReference: path
            )
        }
        if let window = view.window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }

    private func submitDetectedCandidate(
        catalogID: String,
        candidate: LocalAgentDetectedExecutable,
        displayName: String,
        profileID: String,
        workingDirectoryMode: AgentProcessWorkingDirectoryMode,
        workingDirectoryReference: String?
    ) {
        guard let descriptor = coordinator.catalogEntry(catalogID: catalogID) else { return }
        let configurationID = "local-agent-\(UUID().uuidString.lowercased())"
        var parameters: [String: SettingValue] = [
            "configurationID": .string(configurationID),
            "catalogID": .string(catalogID),
            "executablePath": .string(candidate.executablePath),
            "executableIdentityDigest": .string(candidate.executableIdentityDigest),
            "displayName": .string(displayName.trimmingCharacters(in: .whitespacesAndNewlines)),
            "executionProfileID": .string(profileID),
            "workingDirectoryMode": .string(workingDirectoryMode.rawValue),
            "pathPolicy": .string(descriptor.defaultPATHPolicy.rawValue),
            "customPATHEntries": .stringArray([]),
            "environmentAllowlist": .stringArray(descriptor.defaultEnvironmentAllowlist),
            "explicitlyEnabled": .bool(false)
        ]
        if let workingDirectoryReference {
            parameters["workingDirectoryReference"] = .string(workingDirectoryReference)
        }
        performAction("localAgent.detect", parameters: parameters) { [weak self] succeeded in
            if succeeded {
                self?.reloadData(selecting: configurationID)
            }
        }
    }

    @objc private func detectAndSave(_ sender: NSButton) {
        guard let record = selectedRecord,
              let parameters = detectionParameters(for: record)
        else {
            showDetailError("请检查名称、执行配置和本地目录")
            return
        }
        performAction("localAgent.detect", parameters: parameters)
    }

    @objc private func login(_ sender: NSButton) {
        performMaintenanceAction("localAgent.login")
    }

    @objc private func logout(_ sender: NSButton) {
        performMaintenanceAction("localAgent.logout")
    }

    private func performMaintenanceAction(_ actionID: String) {
        guard let record = selectedRecord else { return }
        performAction(actionID, parameters: [
            "configurationID": .string(record.configurationID),
            "expectedRevision": .int(Int(record.configurationRevision))
        ])
    }

    @objc private func openUpgrade(_ sender: NSButton) {
        guard let record = selectedRecord else { return }
        var parameters: [String: SettingValue] = [
            "configurationID": .string(record.configurationID)
        ]
        if let target = coordinator.codingPlanTarget(for: record) {
            parameters["catalogID"] = .string(target.codingPlanCatalogID)
            parameters["websiteActionID"] = .string(target.websiteActionID)
        }
        performAction("localAgent.openUpgrade", parameters: parameters)
    }

    private func makeEmptyState() -> NSView {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        root.setAccessibilityIdentifier("Stacio.Settings.localAgent.empty")

        let title = NSTextField(labelWithString: "添加本地 Agent")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textColor = .labelColor
        let detail = NSTextField(wrappingLabelWithString: "选择已订阅的 Coding Plan，检测本机 CLI 后接入结构化会话；需要时仍可切换到终端透传兼容模式。")
        detail.font = .systemFont(ofSize: 13)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 0

        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 8
        rows.translatesAutoresizingMaskIntoConstraints = false
        for target in coordinator.codingPlanTargets() {
            rows.addArrangedSubview(makeEmptyTargetRow(target))
        }
        if rows.arrangedSubviews.isEmpty {
            let unavailable = NSTextField(wrappingLabelWithString: "暂无经过目录验证的 Coding Plan CLI。")
            unavailable.font = .systemFont(ofSize: 13)
            unavailable.textColor = .secondaryLabelColor
            rows.addArrangedSubview(unavailable)
        }

        let stack = NSStackView(views: [title, detail, rows])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 26),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -26),
            rows.widthAnchor.constraint(equalTo: stack.widthAnchor),
            root.heightAnchor.constraint(greaterThanOrEqualToConstant: 260)
        ])
        return root
    }

    private func makeEmptyTargetRow(_ target: LocalAgentCodingPlanTarget) -> NSView {
        let name = NSTextField(labelWithString: target.displayName)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.setContentCompressionResistancePriority(.required, for: .horizontal)
        let status = NSTextField(labelWithString: supportTitle(target.supportLevel))
        status.font = .systemFont(ofSize: 11)
        status.textColor = target.supportLevel == .experimental ? .systemOrange : .secondaryLabelColor
        let spacer = NSView()
        let detect = LocalAgentCatalogButton(
            title: "检测 CLI",
            target: self,
            action: #selector(emptyDetect(_:))
        )
        detect.bezelStyle = .rounded
        detect.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "检测 CLI")
        detect.imagePosition = .imageLeading
        detect.catalogID = target.localAgentCatalogID
        detect.setAccessibilityIdentifier("Stacio.Settings.localAgent.empty.detect.\(target.localAgentCatalogID)")
        emptyDetectButtons.append(detect)
        let website = LocalAgentCatalogButton()
        configureIconButton(
            website,
            symbol: "arrow.up.right.square",
            description: "打开 \(target.displayName) 官网",
            action: #selector(emptyWebsite(_:))
        )
        website.catalogID = target.codingPlanCatalogID
        website.websiteActionID = target.websiteActionID
        website.setAccessibilityIdentifier("Stacio.Settings.localAgent.empty.website.\(target.codingPlanCatalogID)")
        emptyWebsiteButtons.append(website)
        website.widthAnchor.constraint(equalToConstant: 30).isActive = true
        website.heightAnchor.constraint(equalToConstant: 30).isActive = true
        let row = NSStackView(views: [name, status, spacer, detect, website])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 34).isActive = true
        return row
    }

    @objc private func emptyDetect(_ sender: LocalAgentCatalogButton) {
        guard !sender.catalogID.isEmpty else { return }
        previewDetection(catalogID: sender.catalogID, selectedPath: nil)
    }

    @objc private func emptyWebsite(_ sender: LocalAgentCatalogButton) {
        guard !sender.catalogID.isEmpty, let websiteActionID = sender.websiteActionID else { return }
        performAction("localAgent.openUpgrade", parameters: [
            "catalogID": .string(sender.catalogID),
            "websiteActionID": .string(websiteActionID)
        ])
    }

    @objc private func deleteConfiguration(_ sender: NSButton) {
        guard let record = selectedRecord else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "删除 \(record.userDisplayName)？"
        alert.informativeText = "此操作只删除 Stacio 的本地 Agent 配置，不会删除 CLI 或其账号数据。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.performAction(
                "configuration.delete",
                parameters: Self.deleteParameters(for: record)
            )
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    @objc private func reconcileMaintenance(_ sender: NSButton) {
        guard !unresolvedMaintenance.isEmpty else { return }
        if unresolvedMaintenance.count == 1, let entry = unresolvedMaintenance.first {
            performReconciliation(referenceID: entry.referenceID)
            return
        }
        let menu = makeReconciliationMenu()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 2), in: sender)
    }

    private func makeReconciliationMenu() -> NSMenu {
        let menu = NSMenu(title: "选择待对账进程")
        for entry in unresolvedMaintenance {
            let item = NSMenuItem(
                title: reconciliationMenuTitle(entry),
                action: #selector(reconcileMenuItem(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = entry.referenceID
            menu.addItem(item)
        }
        return menu
    }

    private func reconciliationMenuTitle(
        _ entry: LocalAgentMaintenanceProcessJournalEntry
    ) -> String {
        let record = configurations.first { $0.configurationID == entry.configurationID }
        let fallback = URL(fileURLWithPath: entry.executablePath).lastPathComponent
        let displayName = record?.userDisplayName
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = displayName.isEmpty ? fallback : displayName
        let action: String
        switch entry.action {
        case .login: action = "登录"
        case .logout: action = "退出登录"
        }
        return "\(name) · \(action)"
    }

    @objc private func reconcileMenuItem(_ sender: NSMenuItem) {
        guard let referenceID = sender.representedObject as? String else { return }
        performReconciliation(referenceID: referenceID)
    }

    private func performReconciliation(referenceID: String) {
        performAction("localAgent.reconcileProcesses", parameters: [
            "referenceID": .string(referenceID)
        ])
    }

    private func performAction(
        _ actionID: String,
        parameters: [String: SettingValue],
        completion: ((Bool) -> Void)? = nil
    ) {
        guard !operationInProgress, actionAvailability(actionID) else {
            showDetailError("此操作当前不可用")
            completion?(false)
            return
        }
        let statusConfigurationID = selectedConfigurationID
        operationInProgress = true
        setDetailStatus(
            "处理中...",
            tone: .neutral,
            configurationID: statusConfigurationID
        )
        updateActionEnablement()
        actionHandler(actionID, parameters) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.operationInProgress = false
                let succeeded: Bool
                switch result {
                case .success(.succeeded):
                    self.setDetailStatus(
                        "已完成",
                        tone: .neutral,
                        configurationID: statusConfigurationID
                    )
                    succeeded = true
                case .success(.cancelled):
                    self.setDetailStatus(
                        "已取消",
                        tone: .neutral,
                        configurationID: statusConfigurationID
                    )
                    succeeded = false
                case .success(.failed(let reasonCode)):
                    self.setDetailStatus(
                        Self.failureMessage(reasonCode: reasonCode),
                        tone: .error,
                        configurationID: statusConfigurationID
                    )
                    succeeded = false
                case .success(.reconciliationRequired):
                    self.setDetailStatus(
                        "操作状态待对账，请使用左侧的对账按钮。",
                        tone: .error,
                        configurationID: statusConfigurationID
                    )
                    succeeded = false
                case .failure:
                    self.setDetailStatus(
                        "操作未完成，请稍后重试。",
                        tone: .error,
                        configurationID: statusConfigurationID
                    )
                    succeeded = false
                }
                self.reloadData(selecting: self.selectedConfigurationID)
                completion?(succeeded)
            }
        }
    }

    private func detectionParameters(
        for record: LocalAgentConfigurationRecord
    ) -> [String: SettingValue]? {
        guard draftValidationError(for: record) == nil else { return nil }
        guard let displayName = displayNameField?.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !displayName.isEmpty,
              let profileID = profilePopup?.selectedItem?.representedObject as? String,
              let workingRaw = workingDirectoryPopup?.selectedItem?.representedObject as? String,
              let workingMode = AgentProcessWorkingDirectoryMode(rawValue: workingRaw),
              let pathRaw = pathPolicyPopup?.selectedItem?.representedObject as? String,
              let pathPolicy = LocalAgentPATHPolicy(rawValue: pathRaw)
        else { return nil }

        let customPATHEntries = pathPolicy == .controlled
            ? []
            : tokenValues(customPATHField)
        var parameters: [String: SettingValue] = [
            "configurationID": .string(record.configurationID),
            "expectedRevision": .int(Int(record.configurationRevision)),
            "catalogID": .string(record.catalogID),
            "executablePath": .string(record.executablePath),
            "executableIdentityDigest": .string(record.executableIdentityDigest),
            "displayName": .string(displayName),
            "executionProfileID": .string(profileID),
            "workingDirectoryMode": .string(workingMode.rawValue),
            "pathPolicy": .string(pathPolicy.rawValue),
            "customPATHEntries": .stringArray(customPATHEntries),
            "environmentAllowlist": .stringArray(tokenValues(environmentAllowlistField)),
            "explicitlyEnabled": .bool(enabledSwitch?.state == .on)
        ]
        switch workingMode {
        case .managedWorkspace, .askEveryTurn:
            break
        case .userSelectedLocalDirectory:
            let path = workingDirectoryField?.stringValue
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard path.hasPrefix("/") else { return nil }
            parameters["workingDirectoryReference"] = .string(path)
        }
        return parameters
    }

    @objc private func detailValueChanged(_ sender: NSControl) {
        clearPersistedDetailStatus()
        updateActionEnablement()
    }

    func controlTextDidChange(_ notification: Notification) {
        clearPersistedDetailStatus()
        updateActionEnablement()
    }

    @objc private func workingDirectoryModeChanged(_ sender: NSPopUpButton) {
        clearPersistedDetailStatus()
        updateConditionalControls(record: selectedRecord)
        updateActionEnablement()
    }

    @objc private func pathPolicyChanged(_ sender: NSPopUpButton) {
        clearPersistedDetailStatus()
        updateConditionalControls(record: selectedRecord)
        updateActionEnablement()
    }

    @objc private func chooseWorkingDirectory(_ sender: NSButton) {
        let panel = NSOpenPanel()
        panel.title = "选择本地 Agent 工作目录"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if let existing = workingDirectoryField?.stringValue, existing.hasPrefix("/") {
            panel.directoryURL = URL(fileURLWithPath: existing, isDirectory: true)
        }
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self, weak panel] response in
            guard response == .OK, let path = panel?.url?.standardizedFileURL.path else { return }
            self?.workingDirectoryField?.stringValue = path
            self?.clearPersistedDetailStatus()
            self?.updateActionEnablement()
        }
        if let window = view.window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }

    private func updateConditionalControls(record: LocalAgentConfigurationRecord?) {
        let workingMode = (workingDirectoryPopup?.selectedItem?.representedObject as? String)
            .flatMap(AgentProcessWorkingDirectoryMode.init(rawValue:))
            ?? record?.workingDirectoryMode
        let needsStoredDirectory = workingMode == .userSelectedLocalDirectory
        workingDirectoryField?.isEnabled = needsStoredDirectory && !operationInProgress
        chooseDirectoryButton?.isEnabled = needsStoredDirectory && !operationInProgress
        workingDirectoryField?.placeholderString = workingMode == .askEveryTurn
            ? "每轮发送前选择"
            : "选择 Mac 本地目录"

        let pathPolicy = (pathPolicyPopup?.selectedItem?.representedObject as? String)
            .flatMap(LocalAgentPATHPolicy.init(rawValue:))
            ?? record?.pathPolicy
        customPATHField?.isEnabled = pathPolicy != .controlled && !operationInProgress
    }

    private func updateActionEnablement() {
        let hasSelection = selectedRecord != nil
        let validationError = selectedRecord.flatMap(draftValidationError(for:))
        addButton.isEnabled = !operationInProgress && !coordinator.catalogEntries().isEmpty
        reconcileButton.isEnabled = !operationInProgress
            && actionAvailability("localAgent.reconcileProcesses")
        displayNameField?.isEnabled = !operationInProgress
        enabledSwitch?.isEnabled = !operationInProgress
        profilePopup?.isEnabled = !operationInProgress
        workingDirectoryPopup?.isEnabled = !operationInProgress
        pathPolicyPopup?.isEnabled = !operationInProgress
        environmentAllowlistField?.isEnabled = !operationInProgress
        detectAndSaveButton?.isEnabled = hasSelection && validationError == nil && !operationInProgress
            && actionAvailability("localAgent.detect")
        loginButton?.isEnabled = hasSelection && !operationInProgress
            && actionAvailability("localAgent.login")
        logoutButton?.isEnabled = hasSelection && !operationInProgress
            && actionAvailability("localAgent.logout")
            && coordinator.isLogoutAvailable()
        openUpgradeButton?.isEnabled = hasSelection && !operationInProgress
            && actionAvailability("localAgent.openUpgrade")
        deleteButton?.isEnabled = hasSelection && !operationInProgress
            && actionAvailability("configuration.delete")
        emptyDetectButtons.forEach {
            $0.isEnabled = !operationInProgress && actionAvailability("localAgent.detect")
        }
        emptyWebsiteButtons.forEach {
            $0.isEnabled = !operationInProgress && actionAvailability("localAgent.openUpgrade")
        }
        updateConditionalControls(record: selectedRecord)
        applyDetailStatus(validationError: validationError)
    }

    private func draftValidationError(
        for record: LocalAgentConfigurationRecord
    ) -> String? {
        let displayName = displayNameField?.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard displayName.isEmpty == false else { return "请输入配置名称。" }
        guard displayName.count <= 128 else { return "配置名称不能超过 128 个字符。" }

        guard let workingRaw = workingDirectoryPopup?.selectedItem?.representedObject as? String,
              let workingMode = AgentProcessWorkingDirectoryMode(rawValue: workingRaw)
        else { return "请选择工作目录策略。" }
        if workingMode == .userSelectedLocalDirectory {
            let path = workingDirectoryField?.stringValue
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard LocalAgentWorkingDirectoryValidator.canonicalExistingDirectory(path) != nil else {
                return "请选择可用且规范的 Mac 本地目录。"
            }
        }

        guard let pathRaw = pathPolicyPopup?.selectedItem?.representedObject as? String,
              let pathPolicy = LocalAgentPATHPolicy(rawValue: pathRaw)
        else { return "请选择 PATH 策略。" }
        if pathPolicy != .controlled {
            let entries = tokenValues(customPATHField)
            guard entries.isEmpty == false else {
                return pathPolicy == .loginShell
                    ? "登录 Shell PATH 尚未解析，请填写绝对目录。"
                    : "请至少填写一个自定义 PATH 目录。"
            }
            for entry in entries {
                let url = URL(fileURLWithPath: entry, isDirectory: true)
                guard entry.hasPrefix("/"),
                      url.standardizedFileURL.path == entry,
                      entry.contains(":") == false,
                      entry.contains("\0") == false,
                      entry.contains("\n") == false,
                      entry.contains("\r") == false
                else { return "PATH 只能包含规范的 Mac 绝对目录。" }
            }
        }

        for pattern in tokenValues(environmentAllowlistField) {
            guard LocalAgentLaunchEnvironmentBuilder.isSafeEnvironmentPattern(pattern),
                  LocalAgentContainmentPolicy.envAlwaysRejected(pattern) == false
            else { return "环境变量白名单包含无效或禁止的名称。" }
        }
        return nil
    }

    private func clearPersistedDetailStatus() {
        guard let selectedConfigurationID else { return }
        detailStatusByConfigurationID.removeValue(forKey: selectedConfigurationID)
    }

    private func setDetailStatus(
        _ text: String,
        tone: DetailStatusTone,
        configurationID: String?
    ) {
        guard let configurationID else {
            listStatusLabel.stringValue = text
            return
        }
        detailStatusByConfigurationID[configurationID] = DetailStatusPresentation(
            text: text,
            tone: tone
        )
        if configurationID == selectedConfigurationID {
            applyDetailStatus(validationError: selectedRecord.flatMap(draftValidationError(for:)))
        }
    }

    private func applyDetailStatus(validationError: String?) {
        guard let label = detailStatusLabel else { return }
        let presentation: DetailStatusPresentation?
        if let validationError {
            presentation = DetailStatusPresentation(text: validationError, tone: .error)
        } else if let selectedConfigurationID,
           let persisted = detailStatusByConfigurationID[selectedConfigurationID] {
            presentation = persisted
        } else {
            presentation = nil
        }
        label.stringValue = presentation?.text ?? ""
        label.textColor = presentation?.tone == .error ? .systemRed : .secondaryLabelColor
        label.setAccessibilityHelp(presentation?.text)
        NSAccessibility.post(element: label, notification: .valueChanged)
    }

    private static func failureMessage(reasonCode: String) -> String {
        switch reasonCode {
        case "stale_configuration":
            return "配置已被其他窗口更新，请重新检查后再保存。"
        case "local_agent_in_use":
            return "Local Agent 正在使用中，请停止相关会话后重试。"
        case "local_agent_process_busy":
            return "已有 Local Agent 设置操作正在运行，请稍后重试。"
        case "executable_changed", "invalid_executable_reference":
            return "可执行文件已变化，请重新选择并检测。"
        case "authentication_state_not_changed":
            return "登录状态没有变化，请在终端完成操作后重试。"
        case "logout_requires_draining_or_disabled":
            return "退出登录前请先停用排查助手或进入排空状态。"
        case "maintenance_terminal_unavailable":
            return "无法打开维护终端，请稍后重试。"
        case "control_state_unavailable":
            return "排查助手当前状态不允许此操作。"
        default:
            return "操作失败，请检查配置后重试。"
        }
    }

    private var selectedRecord: LocalAgentConfigurationRecord? {
        guard let selectedConfigurationID else { return nil }
        return configurations.first { $0.configurationID == selectedConfigurationID }
    }

    private func clearDetailControlReferences() {
        displayNameField = nil
        enabledSwitch = nil
        profilePopup = nil
        workingDirectoryPopup = nil
        workingDirectoryField = nil
        chooseDirectoryButton = nil
        pathPolicyPopup = nil
        customPATHField = nil
        environmentAllowlistField = nil
        detectAndSaveButton = nil
        loginButton = nil
        logoutButton = nil
        openUpgradeButton = nil
        deleteButton = nil
        detailStatusLabel = nil
        emptyDetectButtons = []
        emptyWebsiteButtons = []
    }

    private func addDetailArrangedSubview(_ view: NSView, fullWidth: Bool = false) {
        detailStack.addArrangedSubview(view)
        guard fullWidth else { return }
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalTo: detailStack.widthAnchor, constant: -40).isActive = true
    }

    private func makeForm(rows: [(String, NSView)]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        for (title, control) in rows {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            label.alignment = .right
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(equalToConstant: 110).isActive = true
            control.translatesAutoresizingMaskIntoConstraints = false
            control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            if control is NSSwitch {
                control.setContentHuggingPriority(.required, for: .horizontal)
            } else {
                control.setContentHuggingPriority(.defaultLow, for: .horizontal)
            }
            control.setAccessibilityLabel(title)
            control.setAccessibilityTitleUIElement(label)
            let row = NSStackView(views: [label, control])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 12
            row.distribution = .fill
            row.translatesAutoresizingMaskIntoConstraints = false
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            control.widthAnchor.constraint(
                lessThanOrEqualTo: row.widthAnchor,
                constant: -122
            ).isActive = true
        }
        return stack
    }

    private func makeSectionTitle(_ value: String) -> NSTextField {
        let title = NSTextField(labelWithString: value)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .labelColor
        return title
    }

    private func makeSeparator() -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        return separator
    }

    private func makeReadOnlyField(_ value: String, identifier: String) -> NSTextField {
        let field = NSTextField(string: value)
        field.isEditable = false
        field.isSelectable = true
        field.isBordered = false
        field.drawsBackground = false
        field.lineBreakMode = .byTruncatingMiddle
        field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        field.textColor = .secondaryLabelColor
        field.setAccessibilityIdentifier(identifier)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        field.widthAnchor.constraint(lessThanOrEqualToConstant: 340).isActive = true
        return field
    }

    private func makeReadOnlyLabel(_ value: String, identifier: String) -> NSTextField {
        let label = NSTextField(labelWithString: value)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setAccessibilityIdentifier(identifier)
        return label
    }

    private func makeTokenField(values: [String], identifier: String) -> NSTokenField {
        let field = NSTokenField()
        field.objectValue = values
        field.tokenizingCharacterSet = CharacterSet(charactersIn: ",\n")
        field.target = self
        field.action = #selector(detailValueChanged(_:))
        field.delegate = self
        field.setAccessibilityIdentifier(identifier)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        field.widthAnchor.constraint(lessThanOrEqualToConstant: 320).isActive = true
        return field
    }

    private func tokenValues(_ field: NSTokenField?) -> [String] {
        if let values = field?.objectValue as? [String] {
            return values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        return field?.stringValue
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
    }

    private func styleTextField(_ field: NSTextField, width: CGFloat) {
        field.controlSize = .regular
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        field.widthAnchor.constraint(lessThanOrEqualToConstant: width).isActive = true
    }

    private func makeAlertRow(title: String, control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 82).isActive = true
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private func configureIconButton(
        _ button: NSButton,
        symbol: String,
        description: String,
        action: Selector
    ) {
        button.title = ""
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        button.imagePosition = .imageOnly
        button.bezelStyle = .texturedRounded
        button.target = self
        button.action = action
        button.toolTip = description
        button.setAccessibilityLabel(description)
    }

    private func showDetailError(_ value: String) {
        setDetailStatus(
            value,
            tone: .error,
            configurationID: selectedConfigurationID
        )
    }

    private func listDetail(
        record: LocalAgentConfigurationRecord,
        descriptor: LocalAgentCatalogEntry?
    ) -> String {
        let enabled = record.explicitlyEnabled ? "已启用" : "未启用"
        return "\(authenticationTitle(record.authenticationState)) · \(enabled)"
    }

    private func authenticationTitle(_ state: LocalAgentAuthenticationProbeState) -> String {
        switch state {
        case .authenticated: return "已登录"
        case .needsLogin: return "需要登录"
        case .unknown: return "登录状态未知"
        }
    }

    private func supportTitle(_ level: CatalogSupportLevel?) -> String {
        switch level {
        case .ga: return "正式支持"
        case .experimental: return "实验性"
        case .unsupported: return "不支持"
        case nil: return "目录不可用"
        }
    }

    private func profileTitle(_ profile: LocalAgentExecutionProfileDescriptor) -> String {
        let kind: String
        switch profile.kind {
        case .managed: kind = "结构化会话"
        case .terminalPassthrough: kind = "终端透传"
        case .none: kind = "无运行时"
        }
        return "\(kind) · \(supportTitle(profile.supportLevel))"
    }

    private func selectableExecutionProfiles(
        _ descriptor: LocalAgentCatalogEntry,
        retaining currentProfileID: String? = nil
    ) -> [LocalAgentExecutionProfileDescriptor] {
        descriptor.executionProfiles.filter {
            $0.supportLevel != .unsupported
                && (LocalAgentRuntimeCapabilities.supportsManagedProfile(rawIdentity: descriptor.rawIdentity)
                    || $0.kind != .managed
                    || $0.profileID == currentProfileID)
        }
    }

    private func workingDirectoryTitle(_ mode: AgentProcessWorkingDirectoryMode) -> String {
        switch mode {
        case .managedWorkspace: return "会话工作区"
        case .userSelectedLocalDirectory: return "指定 Mac 本地目录"
        case .askEveryTurn: return "每次询问"
        }
    }

    private func pathPolicyTitle(_ policy: LocalAgentPATHPolicy) -> String {
        switch policy {
        case .controlled: return "受控 PATH"
        case .loginShell: return "登录 Shell PATH"
        case .custom: return "显式 PATH 列表"
        }
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    // MARK: - Test surface

    var configurationCountForTesting: Int { configurations.count }
    var selectedConfigurationIDForTesting: String? { selectedConfigurationID }

    func selectConfigurationForTesting(_ configurationID: String) {
        guard let row = configurations.firstIndex(where: { $0.configurationID == configurationID }) else {
            return
        }
        selectedConfigurationID = configurationID
        listTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        renderDetail()
    }

    func detectionParametersForTesting() -> [String: SettingValue]? {
        selectedRecord.flatMap(detectionParameters(for:))
    }

    func deleteParametersForTesting() -> [String: SettingValue]? {
        selectedRecord.map(Self.deleteParameters(for:))
    }

    func reconciliationMenuTitlesForTesting() -> [String] {
        makeReconciliationMenu().items.map(\.title)
    }

    private static func deleteParameters(
        for record: LocalAgentConfigurationRecord
    ) -> [String: SettingValue] {
        [
            "configurationKind": .string(ConfigurationKind.localAgent.rawValue),
            "configurationID": .string(record.configurationID),
            "expectedRevision": .int(Int(record.configurationRevision))
        ]
    }
}

private final class LocalAgentCatalogButton: NSButton {
    var catalogID = ""
    var websiteActionID: String?
}

private final class LocalAgentSettingsListCell: NSTableCellView {
    private let statusImage = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        statusImage.translatesAutoresizingMaskIntoConstraints = false
        statusImage.symbolConfiguration = .init(pointSize: 10, weight: .medium)
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .systemFont(ofSize: 10)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail

        let labels = NSStackView(views: [titleLabel, detailLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        labels.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusImage)
        addSubview(labels)
        NSLayoutConstraint.activate([
            statusImage.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            statusImage.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusImage.widthAnchor.constraint(equalToConstant: 14),
            statusImage.heightAnchor.constraint(equalToConstant: 14),
            labels.leadingAnchor.constraint(equalTo: statusImage.trailingAnchor, constant: 7),
            labels.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func configure(title: String, detail: String, enabled: Bool) {
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        statusImage.image = NSImage(
            systemSymbolName: enabled ? "circle.fill" : "circle",
            accessibilityDescription: enabled ? "已启用" : "未启用"
        )
        statusImage.contentTintColor = enabled ? .systemGreen : .tertiaryLabelColor
    }
}

private extension NSPopUpButton {
    func selectItem(withRepresentedObject value: Any) {
        guard let item = itemArray.first(where: {
            guard let represented = $0.representedObject else { return false }
            return String(describing: represented) == String(describing: value)
        }) else { return }
        select(item)
    }
}
