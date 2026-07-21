import AppKit
import XCTest
@testable import StacioApp
import StacioCoreBindings

@MainActor
final class SessionSettingsViewControllerTests: XCTestCase {
    func testSSHSettingsShowsSessionIconRow() {
        let controller = makeController()

        controller.loadView()

        XCTAssertFalse(controller.sessionIconRowIsHiddenForTesting)
        XCTAssertNotNil(controller.view.firstSubview(withIdentifier: "Stacio.SessionSettings.sessionIcon"))
        XCTAssertNil(controller.selectedSessionIconIDForTesting)
    }

    func testSettingsLoadsAndPersistsManualIconWithoutDroppingAutomation() throws {
        let controller = SessionSettingsViewController(
            existingSession: makeExistingSSHSession(),
            selectedFolderID: nil,
            draftFactory: SessionSidebarSessionDraftFactory(defaultUsername: { "local" }),
            existingSerialConfigJSON: #"{"sessionIconID":"ubuntu","startupCommand":"pwd"}"#
        )
        controller.loadView()

        XCTAssertEqual(controller.selectedSessionIconIDForTesting, "ubuntu")
        controller.selectSessionIconForTesting("aliyun")
        let draft = try XCTUnwrap(controller.draft())
        let config = try XCTUnwrap(draft.configJson)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(config.utf8)) as? [String: Any])

        XCTAssertEqual(object["sessionIconID"] as? String, "aliyun")
        XCTAssertEqual(object["startupCommand"] as? String, "pwd")
    }

    func testNonSSHProtocolHidesSessionIconRow() {
        let controller = makeController()
        controller.loadView()

        controller.selectProtocolForTesting(.vnc)

        XCTAssertTrue(controller.sessionIconRowIsHiddenForTesting)
    }

    func testProtocolSelectorOnlyShowsSaveableProtocolsAndUsesSCPInsteadOfSFTP() {
        let controller = makeController()

        controller.loadView()

        XCTAssertEqual(
            controller.protocolLabelsForTesting,
            [
                "SSH（安全 Shell）",
                "Telnet（远程登录）",
                "VNC（远程控制）",
                "FTP（文件传输）",
                "SCP（安全复制）",
                "串口",
                "本地终端"
            ]
        )
        XCTAssertFalse(controller.protocolLabelsForTesting.contains("SFTP"))
        XCTAssertFalse(controller.protocolLabelsForTesting.contains("RSH（远程 Shell）"))
        XCTAssertFalse(controller.protocolLabelsForTesting.contains("XDMCP（图形登录）"))
        XCTAssertFalse(controller.protocolLabelsForTesting.contains("Mosh（移动 Shell）"))
        XCTAssertFalse(controller.protocolLabelsForTesting.contains("S3 对象存储"))
        XCTAssertFalse(controller.protocolLabelsForTesting.contains("WSL（Linux 子系统）"))
        XCTAssertEqual(controller.selectedProtocolForTesting, .ssh)
    }

    func testProtocolSourceListUsesCompactDisplayNames() {
        let controller = makeController()

        controller.loadView()

        XCTAssertEqual(
            controller.protocolSourceListLabelsForTesting,
            ["SSH", "Telnet", "VNC", "FTP", "SCP", "串口", "本地终端"]
        )
        XCTAssertFalse(controller.protocolSourceListLabelsForTesting.contains { $0.contains("（") })
    }

    func testNewSessionProtocolListDoesNotOfferLocalFileOrBrowser() {
        let controller = makeController()

        controller.loadView()

        XCTAssertFalse(controller.protocolSourceListLabelsForTesting.contains("本地文件"))
        XCTAssertFalse(controller.protocolSourceListLabelsForTesting.contains("浏览器"))
        XCTAssertFalse(controller.protocolSourceListLabelsForTesting.contains("RDP"))
        XCTAssertTrue(controller.protocolSourceListLabelsForTesting.contains("VNC"))
        XCTAssertTrue(controller.protocolSourceListLabelsForTesting.contains("FTP"))
        XCTAssertTrue(controller.protocolSourceListLabelsForTesting.contains("SCP"))
        XCTAssertTrue(controller.protocolSourceListLabelsForTesting.contains("串口"))
    }

    func testSessionSettingsCopyUsesChineseMacOSTerms() {
        XCTAssertEqual(L10n.SessionSettings.url, "网址")
        XCTAssertEqual(L10n.SessionSettings.agent, "SSH 代理")
        XCTAssertEqual(L10n.SessionSettings.storedInKeychain, "已保存到 Stacio 凭据库")
        XCTAssertEqual(L10n.SessionErrors.keychainAccessDenied, "Stacio 凭据库无法读写，请检查本机文件权限后再试。")
        XCTAssertEqual(L10n.DeleteSession.oneMessage, "保存的会话将被移除，并同时清除该会话的本地编辑缓存。Stacio 凭据库中的凭据不会被删除。")
        XCTAssertEqual(L10n.DeleteSession.manyMessage(2), "2 个保存的会话将被移除，并同时清除这些会话的本地编辑缓存。Stacio 凭据库中的凭据不会被删除。")
        XCTAssertEqual(L10n.QuickConnect.message, "输入 SSH 目标，例如 用户名@主机:22。")
        XCTAssertEqual(L10n.Import.chooseFile, "选择要导入的会话文件。")
    }

    func testSessionSettingsUsesSystemAdaptiveSheetSurface() {
        let controller = makeController()

        controller.loadView()

        XCTAssertEqual(controller.view.accessibilityIdentifier(), "Stacio.SessionSettings.surface")
        XCTAssertEqual(controller.view.layer?.cornerRadius ?? 0, 0)
        XCTAssertEqual(controller.view.layer?.borderWidth ?? 0, 0)
        XCTAssertEqual(controller.view.layer?.backgroundColor, NSColor.windowBackgroundColor.cgColor)
    }

    func testSessionSettingsUsesSidebarProtocolListInsteadOfHorizontalScroller() throws {
        let controller = makeController()

        controller.loadView()

        let protocolList = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.SessionSettings.protocolList") as? NSTableView
        )
        XCTAssertEqual(protocolList.numberOfRows, controller.protocolLabelsForTesting.count)
        XCTAssertEqual(protocolList.enclosingScrollView?.hasHorizontalScroller, false)
        XCTAssertLessThanOrEqual(protocolList.enclosingScrollView?.fittingSize.width ?? 0, 190)
        XCTAssertNil(controller.view.firstSubview(withIdentifier: "Stacio.SessionSettings.protocolSelector"))
    }

    func testSessionSettingsUsesCompactContentDrivenSheetLayout() throws {
        let controller = makeController()

        controller.loadView()

        let form = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.SessionSettings.sshForm")
        )
        let grid = try XCTUnwrap(
            form.firstSubview(withIdentifier: "Stacio.SessionEditor.formGrid") as? NSGridView
        )
        let protocolList = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.SessionSettings.protocolList") as? NSTableView
        )
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertLessThanOrEqual(controller.view.frame.width, 730)
        XCTAssertLessThanOrEqual(controller.view.frame.height, 700)
        XCTAssertGreaterThanOrEqual(controller.view.frame.width, 660)
        XCTAssertLessThanOrEqual(protocolList.enclosingScrollView?.frame.width ?? 0, 150)
        XCTAssertEqual(protocolList.enclosingScrollView?.hasVerticalScroller, false)
        XCTAssertGreaterThanOrEqual(
            protocolList.enclosingScrollView?.frame.height ?? 0,
            CGFloat(protocolList.numberOfRows) * (protocolList.rowHeight + protocolList.intercellSpacing.height)
        )
        XCTAssertLessThanOrEqual(form.frame.width, 390)
        XCTAssertGreaterThanOrEqual(grid.rowSpacing, 11)
        XCTAssertEqual(grid.columnSpacing, 14)
    }

    func testSessionSettingsShowsTheEntireNameFieldAtInitialScrollPosition() throws {
        let controller = makeController()
        controller.loadView()
        controller.view.layoutSubtreeIfNeeded()

        let scrollView = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.SessionSettings.detailScrollView") as? NSScrollView
        )
        let nameField = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.SessionEditor.name") as? NSTextField
        )
        let visibleRect = scrollView.contentView.documentVisibleRect
        let nameRect = nameField.convert(nameField.bounds, to: scrollView.documentView)

        XCTAssertGreaterThanOrEqual(nameRect.minY, visibleRect.minY - 0.5)
        XCTAssertLessThanOrEqual(nameRect.maxY, visibleRect.maxY + 0.5)
    }

    func testSessionSettingsDoesNotLeaveLargeBlankGapBetweenFormAndAutomation() throws {
        let controller = makeController()

        controller.loadView()
        controller.view.layoutSubtreeIfNeeded()

        let form = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.SessionSettings.sshForm")
        )
        let grid = try XCTUnwrap(
            form.firstSubview(withIdentifier: "Stacio.SessionEditor.formGrid") as? NSGridView
        )
        let automation = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.SessionSettings.automation")
        )
        let sessionIcon = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.SessionSettings.sessionIcon")
        )
        let gridFrame = grid.convert(grid.bounds, to: controller.view)
        let sessionIconFrame = sessionIcon.convert(sessionIcon.bounds, to: controller.view)
        let automationFrame = automation.convert(automation.bounds, to: controller.view)

        XCTAssertLessThanOrEqual(
            gridFrame.minY - sessionIconFrame.maxY,
            24,
            "The form should keep the session icon row close to the last connection field."
        )
        XCTAssertLessThanOrEqual(
            sessionIconFrame.minY - automationFrame.maxY,
            24,
            "The session icon row should stay close to automation controls."
        )
    }

    func testSessionSettingsUsesNativeSheetButtonRolesAndInitialFocus() throws {
        let controller = makeController()
        let window = NSWindow(contentViewController: controller)

        controller.loadView()
        controller.installInitialFirstResponder(in: window)
        let saveButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.SessionSettings.saveButton") as? NSButton
        )
        let cancelButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.SessionSettings.cancelButton") as? NSButton
        )

        XCTAssertEqual(controller.initialFirstResponderIdentifierForTesting, "Stacio.SessionEditor.host")
        XCTAssertEqual(
            window.initialFirstResponder?.accessibilityIdentifier(),
            "Stacio.SessionEditor.host"
        )
        XCTAssertTrue(controller.footerUsesSeparatorForTesting)
        XCTAssertEqual(saveButton.keyEquivalent, "\r")
        XCTAssertEqual(saveButton.bezelStyle, .rounded)
        XCTAssertTrue(saveButton.hasDefaultKeyEquivalentForTesting)
        XCTAssertEqual(cancelButton.keyEquivalent, "\u{1b}")
        XCTAssertEqual(cancelButton.bezelStyle, .rounded)
        XCTAssertFalse(cancelButton.hasDefaultKeyEquivalentForTesting)
    }

    func testSessionSettingsWindowUsesStandardSheetChrome() throws {
        let windowController = SessionSettingsWindowController(
            existingSession: nil,
            selectedFolderID: nil,
            draftFactory: SessionSidebarSessionDraftFactory(defaultUsername: { "local" }),
            errorPresenter: RecordingSessionSettingsErrorPresenter(),
            parentWindowProvider: { nil }
        )

        let window = try XCTUnwrap(windowController.window)

        XCTAssertFalse(window.titlebarAppearsTransparent)
        XCTAssertEqual(window.toolbarStyle, .automatic)
        XCTAssertEqual(window.titleVisibility, .visible)
        XCTAssertTrue(window.styleMask.contains(.titled))
        XCTAssertTrue(window.styleMask.contains(.closable))
        XCTAssertFalse(window.isMovableByWindowBackground)
    }

    func testSessionSettingsKeepsSaveDisabledInitiallyWithoutShowingValidationCopy() {
        let controller = makeController()

        controller.loadView()

        XCTAssertFalse(controller.saveButtonIsEnabledForTesting)
        XCTAssertEqual(controller.validationMessageForTesting, "")
    }

    func testNonSSHProtocolUsesSessionFormAndBuildsProtocolDraft() throws {
        let controller = makeController()
        let saveButton = NSButton(title: "保存", target: nil, action: nil)

        controller.loadView()
        controller.bindSaveButtonForTesting(saveButton)
        controller.selectProtocolForTesting(.telnet)
        controller.setSSHValuesForTesting(
            SessionSidebarSessionFormValues(
                name: "Legacy Router",
                host: "router.example.com",
                port: controller.portValueForTesting,
                username: "admin",
                authMode: .agent,
                privateKeyPath: "",
                credentialSecret: "",
                tags: "legacy"
            )
        )

        let draft = try XCTUnwrap(controller.draft())

        XCTAssertFalse(controller.sshFormIsHiddenForTesting)
        XCTAssertTrue(saveButton.isEnabled)
        XCTAssertEqual(controller.unsupportedMessageForTesting, "")
        XCTAssertEqual(draft.protocol, "telnet")
        XCTAssertEqual(draft.name, "Legacy Router")
        XCTAssertEqual(draft.host, "router.example.com")
        XCTAssertEqual(draft.port, 23)
        XCTAssertEqual(draft.username, "admin")
        XCTAssertEqual(draft.tags, ["legacy"])
    }

    func testSSHSessionDraftPersistsSelectedTagColorInProtocolConfig() throws {
        let controller = makeController()
        let saveButton = NSButton(title: "保存", target: nil, action: nil)

        controller.loadView()
        controller.bindSaveButtonForTesting(saveButton)
        controller.setSSHValuesForTesting(
            SessionSidebarSessionFormValues(
                name: "API",
                host: "api.example.com",
                port: "22",
                username: "",
                authMode: .password,
                privateKeyPath: "",
                credentialSecret: "",
                tags: "prod"
            )
        )
        controller.setTagColorForTesting("#FF3B30")

        let draft = try XCTUnwrap(controller.draft())
        let config = try XCTUnwrap(draft.configJson)
        let data = try XCTUnwrap(config.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let tagStyle = try XCTUnwrap(object["tagStyle"] as? [String: Any])

        XCTAssertEqual(draft.username, nil)
        XCTAssertEqual(draft.credentialId, nil)
        XCTAssertEqual(draft.tags, ["prod"])
        XCTAssertEqual(tagStyle["color"] as? String, "#FF3B30")
    }

    func testSessionSettingsPersistsEnvironmentAndAIPolicyInProtocolConfig() throws {
        let controller = makeController()
        let saveButton = NSButton(title: "保存", target: nil, action: nil)

        controller.loadView()
        controller.bindSaveButtonForTesting(saveButton)
        controller.setSSHValuesForTesting(
            SessionSidebarSessionFormValues(
                name: "API",
                host: "api.example.com",
                port: "22",
                username: "deploy",
                authMode: .agent,
                privateKeyPath: "",
                credentialSecret: "",
                tags: "prod"
            )
        )
        controller.setTagColorForTesting("#FF3B30")
        controller.setAutomationPolicyForTesting(environment: "production", aiExecutionPolicy: "commandCard")

        let draft = try XCTUnwrap(controller.draft())
        let config = try XCTUnwrap(draft.configJson)
        let data = try XCTUnwrap(config.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let tagStyle = try XCTUnwrap(object["tagStyle"] as? [String: Any])

        XCTAssertEqual(object["environment"] as? String, "production")
        XCTAssertEqual(object["aiExecutionPolicy"] as? String, "commandCard")
        XCTAssertEqual(tagStyle["color"] as? String, "#FF3B30")
    }

    func testSessionSettingsPersistsStartupCommandAndEnvironmentVariablesInProtocolConfig() throws {
        let controller = makeController()
        let saveButton = NSButton(title: "保存", target: nil, action: nil)

        controller.loadView()
        controller.bindSaveButtonForTesting(saveButton)
        controller.setSSHValuesForTesting(
            SessionSidebarSessionFormValues(
                name: "API",
                host: "api.example.com",
                port: "22",
                username: "deploy",
                authMode: .agent,
                privateKeyPath: "",
                credentialSecret: "",
                tags: "prod"
            )
        )
        controller.setConnectionStartupForTesting(
            command: "cd /srv/app && docker compose ps",
            environmentVariables: "APP_ENV=prod\nSTACIO_TRACE=1"
        )

        let draft = try XCTUnwrap(controller.draft())
        let config = try XCTUnwrap(draft.configJson)
        let data = try XCTUnwrap(config.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["startupCommand"] as? String, "cd /srv/app && docker compose ps")
        XCTAssertEqual(object["environmentVariables"] as? [String], ["APP_ENV=prod", "STACIO_TRACE=1"])
    }

    func testSessionSettingsPersistsPostConnectScriptAsMultilineProtocolConfig() throws {
        let controller = makeController()
        let saveButton = NSButton(title: "保存", target: nil, action: nil)

        controller.loadView()
        controller.bindSaveButtonForTesting(saveButton)
        controller.setSSHValuesForTesting(
            SessionSidebarSessionFormValues(
                name: "API",
                host: "api.example.com",
                port: "22",
                username: "deploy",
                authMode: .agent,
                privateKeyPath: "",
                credentialSecret: "",
                tags: "prod"
            )
        )
        controller.setPostConnectScriptForTesting("cd /srv/app\nsource .env && export PS1='prod> '")

        let draft = try XCTUnwrap(controller.draft())
        let config = try XCTUnwrap(draft.configJson)
        let data = try XCTUnwrap(config.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["postConnectScript"] as? String, "cd /srv/app\nsource .env && export PS1='prod> '")
    }

    func testSessionSettingsSkipsBlankPostConnectScriptInProtocolConfig() throws {
        let controller = makeController()
        let saveButton = NSButton(title: "保存", target: nil, action: nil)

        controller.loadView()
        controller.bindSaveButtonForTesting(saveButton)
        controller.setSSHValuesForTesting(
            SessionSidebarSessionFormValues(
                name: "API",
                host: "api.example.com",
                port: "22",
                username: "deploy",
                authMode: .agent,
                privateKeyPath: "",
                credentialSecret: "",
                tags: ""
            )
        )
        controller.setPostConnectScriptForTesting(" \n\t ")

        let draft = try XCTUnwrap(controller.draft())

        XCTAssertNil(draft.configJson)
    }

    func testSessionSettingsDefaultsToFastSSHConnectTimeoutWithoutPersistingProtocolConfig() throws {
        let controller = makeController()
        let saveButton = NSButton(title: "保存", target: nil, action: nil)

        controller.loadView()
        controller.bindSaveButtonForTesting(saveButton)
        XCTAssertEqual(
            controller.connectionStartupValuesForTesting[L10n.SessionSettings.connectTimeoutSeconds],
            SSHConnectionDefaults.fastConnectTimeoutSecondsString
        )
        controller.setSSHValuesForTesting(
            SessionSidebarSessionFormValues(
                name: "API",
                host: "api.example.com",
                port: "22",
                username: "deploy",
                authMode: .agent,
                privateKeyPath: "",
                credentialSecret: "",
                tags: ""
            )
        )

        let draft = try XCTUnwrap(controller.draft())

        XCTAssertNil(draft.configJson)
    }

    func testSessionSettingsPersistsCustomConnectTimeoutInProtocolConfig() throws {
        let controller = makeController()
        let saveButton = NSButton(title: "保存", target: nil, action: nil)

        controller.loadView()
        controller.bindSaveButtonForTesting(saveButton)
        controller.setSSHValuesForTesting(
            SessionSidebarSessionFormValues(
                name: "Slow Bastion",
                host: "bastion.example.com",
                port: "22",
                username: "deploy",
                authMode: .agent,
                privateKeyPath: "",
                credentialSecret: "",
                tags: "ops"
            )
        )
        controller.setConnectionAdvancedForTesting(
            startupCommand: "",
            environmentVariables: "",
            connectTimeoutSeconds: "30"
        )

        let draft = try XCTUnwrap(controller.draft())
        let config = try XCTUnwrap(draft.configJson)
        let data = try XCTUnwrap(config.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["connectTimeoutMs"] as? Int, 30_000)
    }

    func testSessionSettingsPersistsSavedSessionProxyJumpInProtocolConfig() throws {
        let controller = makeController()

        controller.loadView()
        controller.setSSHValuesForTesting(
            SessionSidebarSessionFormValues(
                name: "API",
                host: "api.example.com",
                port: "22",
                username: "deploy",
                authMode: .agent,
                privateKeyPath: "",
                credentialSecret: "",
                tags: ""
            )
        )
        controller.setProxyJumpSavedSessionForTesting(id: "session_bastion")

        let draft = try XCTUnwrap(controller.draft())
        let object = try serialConfigDictionary(from: draft)
        let proxyJump = try XCTUnwrap(object["proxyJump"] as? [String: Any])

        XCTAssertEqual(proxyJump["mode"] as? String, "session")
        XCTAssertEqual(proxyJump["sessionId"] as? String, "session_bastion")
    }

    func testSessionSettingsPersistsManualProxyJumpInProtocolConfig() throws {
        let controller = makeController()

        controller.loadView()
        controller.setSSHValuesForTesting(
            SessionSidebarSessionFormValues(
                name: "API",
                host: "api.example.com",
                port: "22",
                username: "deploy",
                authMode: .agent,
                privateKeyPath: "",
                credentialSecret: "",
                tags: ""
            )
        )
        controller.setProxyJumpManualForTesting(
            host: "bastion.example.com",
            port: "2222",
            username: "ops",
            credentialID: "credential_bastion",
            privateKeyPath: ""
        )

        let draft = try XCTUnwrap(controller.draft())
        let object = try serialConfigDictionary(from: draft)
        let proxyJump = try XCTUnwrap(object["proxyJump"] as? [String: Any])

        XCTAssertEqual(proxyJump["mode"] as? String, "manual")
        XCTAssertEqual(proxyJump["host"] as? String, "bastion.example.com")
        XCTAssertEqual(proxyJump["port"] as? Int, 2222)
        XCTAssertEqual(proxyJump["username"] as? String, "ops")
        XCTAssertEqual(proxyJump["credentialId"] as? String, "credential_bastion")
    }

    func testSessionSettingsLoadsExistingProxyJumpConfig() throws {
        let controller = SessionSettingsViewController(
            existingSession: makeExistingSSHSession(),
            selectedFolderID: nil,
            draftFactory: SessionSidebarSessionDraftFactory(defaultUsername: { "local" }),
            existingSerialConfigJSON: #"{"proxyJump":{"mode":"manual","host":"bastion.example.com","port":2222,"username":"ops","credentialId":"credential_bastion"}}"#
        )

        controller.loadView()

        XCTAssertEqual(controller.proxyJumpValuesForTesting[L10n.SessionSettings.proxyJumpMode], L10n.SessionSettings.proxyJumpManual)
        XCTAssertEqual(controller.proxyJumpValuesForTesting[L10n.SessionSettings.host], "bastion.example.com")
        XCTAssertEqual(controller.proxyJumpValuesForTesting[L10n.SessionSettings.port], "2222")
        XCTAssertEqual(controller.proxyJumpValuesForTesting[L10n.SessionSettings.user], "ops")
        XCTAssertEqual(controller.proxyJumpValuesForTesting[L10n.SessionSettings.proxyJumpCredentialID], "credential_bastion")
    }

    func testSessionSettingsLoadsExistingStartupCommandAndEnvironmentVariables() throws {
        let controller = SessionSettingsViewController(
            existingSession: makeExistingSSHSession(),
            selectedFolderID: nil,
            draftFactory: SessionSidebarSessionDraftFactory(defaultUsername: { "local" }),
            existingSerialConfigJSON: #"{"startupCommand":"cd /opt/service && ./healthcheck.sh","environmentVariables":["APP_ENV=staging","DEBUG=1"],"connectTimeoutMs":45000}"#
        )

        controller.loadView()

        XCTAssertEqual(controller.connectionStartupValuesForTesting[L10n.SessionSettings.startupCommand], "cd /opt/service && ./healthcheck.sh")
        XCTAssertEqual(controller.connectionStartupValuesForTesting[L10n.SessionSettings.environmentVariables], "APP_ENV=staging\nDEBUG=1")
        XCTAssertEqual(controller.connectionStartupValuesForTesting[L10n.SessionSettings.connectTimeoutSeconds], "45")
    }

    func testSessionSettingsLoadsExistingPostConnectScript() throws {
        let controller = SessionSettingsViewController(
            existingSession: makeExistingSSHSession(),
            selectedFolderID: nil,
            draftFactory: SessionSidebarSessionDraftFactory(defaultUsername: { "local" }),
            existingSerialConfigJSON: #"{"postConnectScript":"cd /opt/service\nsource .env"}"#
        )

        controller.loadView()

        XCTAssertEqual(controller.postConnectScriptForTesting, "cd /opt/service\nsource .env")
    }

    func testProtocolSelectionAppliesDefaultPorts() {
        let controller = makeController()

        controller.loadView()
        controller.selectProtocolForTesting(.vnc)

        XCTAssertEqual(controller.portValueForTesting, "5900")

        controller.selectProtocolForTesting(.serial)

        XCTAssertEqual(controller.portValueForTesting, "9600")
    }

    func testVNCProtocolStoresPasswordCredentialReferenceForAdapterLaunch() throws {
        let credentialSaver = RecordingSessionSettingsCredentialSaver(
            savedCredentialID: "cred_vnc_password"
        )
        let controller = SessionSettingsViewController(
            existingSession: nil,
            selectedFolderID: nil,
            draftFactory: SessionSidebarSessionDraftFactory(
                credentialSaver: credentialSaver,
                defaultUsername: { "local" }
            )
        )
        let saveButton = NSButton(title: "保存", target: nil, action: nil)

        controller.loadView()
        controller.bindSaveButtonForTesting(saveButton)
        controller.selectProtocolForTesting(.vnc)
        controller.setSSHValuesForTesting(
            SessionSidebarSessionFormValues(
                name: "VNC 桌面",
                host: "desktop.example.com",
                port: controller.portValueForTesting,
                username: "admin",
                authMode: .password,
                privateKeyPath: "",
                credentialSecret: "vnc-secret",
                tags: "desktop"
            )
        )

        let draft = try XCTUnwrap(controller.draft())

        XCTAssertTrue(saveButton.isEnabled)
        XCTAssertEqual(draft.protocol, "vnc")
        XCTAssertEqual(draft.host, "desktop.example.com")
        XCTAssertEqual(draft.port, 5900)
        XCTAssertEqual(draft.username, "admin")
        XCTAssertEqual(draft.credentialId, "cred_vnc_password")
        XCTAssertNil(draft.privateKeyPath)
        XCTAssertEqual(credentialSaver.savedSecrets, ["vnc-secret"])
        XCTAssertFalse(String(describing: draft).contains("vnc-secret"))
    }

    func testSerialProtocolUsesChineseDeviceAndBaudLabelsAndBuildsDraft() throws {
        let controller = makeController()
        let saveButton = NSButton(title: "保存", target: nil, action: nil)

        controller.loadView()
        controller.bindSaveButtonForTesting(saveButton)
        controller.selectProtocolForTesting(.serial)
        controller.setTagColorForTesting("#34C759")
        controller.setSSHValuesForTesting(
            SessionSidebarSessionFormValues(
                name: "串口控制台",
                host: "/dev/cu.usbserial-001",
                port: controller.portValueForTesting,
                username: "ignored",
                authMode: .password,
                privateKeyPath: "",
                credentialSecret: "",
                tags: "lab"
            )
        )

        let draft = try XCTUnwrap(controller.draft())

        XCTAssertEqual(controller.hostLabelForTesting, "设备路径")
        XCTAssertEqual(controller.portLabelForTesting, "波特率")
        XCTAssertEqual(
            controller.serialAdvancedLabelsForTesting,
            ["设备类型", "数据位", "停止位", "校验位", "流控", "退格键", "保存说明"]
        )
        XCTAssertEqual(controller.serialAdvancedValuesForTesting["数据位"], "8")
        XCTAssertEqual(controller.serialAdvancedValuesForTesting["停止位"], "1")
        XCTAssertEqual(controller.serialAdvancedValuesForTesting["校验位"], "无")
        XCTAssertEqual(controller.serialAdvancedValuesForTesting["流控"], "无")
        XCTAssertEqual(controller.serialAdvancedValuesForTesting["退格键"], "DEL (0x7F)")
        XCTAssertEqual(controller.serialStorageHintForTesting, "网络设备预设会随会话保存；手工修改高级项后仍以当前参数连接。")
        XCTAssertFalse(controller.serialAdvancedTextForTesting.contains("Data"))
        XCTAssertFalse(controller.serialAdvancedTextForTesting.contains("Stop"))
        XCTAssertFalse(controller.serialAdvancedTextForTesting.contains("Parity"))
        XCTAssertFalse(controller.serialAdvancedTextForTesting.contains("Flow"))
        XCTAssertTrue(controller.userRowIsHiddenForTesting)
        XCTAssertTrue(controller.authRowIsHiddenForTesting)
        XCTAssertTrue(saveButton.isEnabled)
        XCTAssertEqual(draft.protocol, "serial")
        XCTAssertEqual(draft.host, "/dev/cu.usbserial-001")
        XCTAssertEqual(draft.port, 9_600)
        XCTAssertNil(draft.username)
        XCTAssertNil(draft.credentialId)
        XCTAssertEqual(draft.tags, ["lab"])
        let config = try serialConfigDictionary(from: draft)
        XCTAssertEqual(config["devicePath"] as? String, "/dev/cu.usbserial-001")
        XCTAssertEqual(config["baudRate"] as? Int, 9_600)
        XCTAssertEqual(config["dataBits"] as? Int, 8)
        XCTAssertEqual(config["stopBits"] as? Int, 1)
        XCTAssertEqual(config["parity"] as? String, "none")
        XCTAssertEqual(config["flowControl"] as? String, "none")
        XCTAssertEqual(config["backspaceMode"] as? String, "del")
        XCTAssertEqual(config["deviceProfile"] as? String, "network-generic-9600")
        let tagStyle = try XCTUnwrap(config["tagStyle"] as? [String: Any])
        XCTAssertEqual(tagStyle["color"] as? String, "#34C759")
    }

    func testSerialNetworkDeviceProfilesCoverCommonSwitchRouterBrands() throws {
        let controller = makeController()

        controller.loadView()
        controller.selectProtocolForTesting(.serial)

        let profiles = controller.serialDeviceProfileChoicesForTesting.joined(separator: "\n")
        XCTAssertTrue(profiles.contains("浪潮网络"))
        XCTAssertTrue(profiles.contains("元脉网络"))
        XCTAssertTrue(profiles.contains("思科"))
        XCTAssertTrue(profiles.contains("华为"))
        XCTAssertTrue(profiles.contains("H3C"))
        XCTAssertTrue(profiles.contains("锐捷"))
        XCTAssertTrue(profiles.contains("博达"))
        XCTAssertTrue(profiles.contains("通用网络设备"))
        XCTAssertTrue(profiles.contains("通用高速 Console"))
        XCTAssertEqual(
            controller.serialAdvancedValuesForTesting["设备类型"],
            "通用网络设备（9600 8N1，无流控）"
        )
    }

    func testSerialVendorProfileAppliesUniversalNetworkConsoleParameters() throws {
        let controller = makeController()

        controller.loadView()
        controller.selectProtocolForTesting(.serial)
        controller.selectSerialDeviceProfileForTesting("思科 Cisco（9600 8N1）")
        controller.setSSHValuesForTesting(
            SessionSidebarSessionFormValues(
                name: "Cisco Console",
                host: "/dev/cu.usbserial-cisco",
                port: controller.portValueForTesting,
                username: "ignored",
                authMode: .password,
                privateKeyPath: "",
                credentialSecret: "",
                tags: "switch"
            )
        )

        let draft = try XCTUnwrap(controller.draft())
        let config = try serialConfigDictionary(from: draft)

        XCTAssertEqual(controller.portValueForTesting, "9600")
        XCTAssertEqual(controller.serialAdvancedValuesForTesting["数据位"], "8")
        XCTAssertEqual(controller.serialAdvancedValuesForTesting["停止位"], "1")
        XCTAssertEqual(controller.serialAdvancedValuesForTesting["校验位"], "无")
        XCTAssertEqual(controller.serialAdvancedValuesForTesting["流控"], "无")
        XCTAssertEqual(draft.port, 9_600)
        XCTAssertEqual(config["baudRate"] as? Int, 9_600)
        XCTAssertEqual(config["dataBits"] as? Int, 8)
        XCTAssertEqual(config["stopBits"] as? Int, 1)
        XCTAssertEqual(config["parity"] as? String, "none")
        XCTAssertEqual(config["flowControl"] as? String, "none")
        XCTAssertEqual(config["deviceProfile"] as? String, "cisco")
    }

    func testSerialHighSpeedNetworkProfileApplies115200ConsoleParameters() throws {
        let controller = makeController()

        controller.loadView()
        controller.selectProtocolForTesting(.serial)
        controller.selectSerialDeviceProfileForTesting("通用高速 Console（115200 8N1，无流控）")
        controller.setSSHValuesForTesting(
            SessionSidebarSessionFormValues(
                name: "高速 Console",
                host: "/dev/cu.usbmodem-console",
                port: controller.portValueForTesting,
                username: "ignored",
                authMode: .password,
                privateKeyPath: "",
                credentialSecret: "",
                tags: "router"
            )
        )

        let draft = try XCTUnwrap(controller.draft())
        let config = try serialConfigDictionary(from: draft)

        XCTAssertEqual(controller.portValueForTesting, "115200")
        XCTAssertEqual(draft.port, 115_200)
        XCTAssertEqual(config["baudRate"] as? Int, 115_200)
        XCTAssertEqual(config["dataBits"] as? Int, 8)
        XCTAssertEqual(config["stopBits"] as? Int, 1)
        XCTAssertEqual(config["parity"] as? String, "none")
        XCTAssertEqual(config["flowControl"] as? String, "none")
        XCTAssertEqual(config["deviceProfile"] as? String, "network-generic-115200")
    }

    func testSerialManualAdvancedOverrideDoesNotPersistPresetProfile() throws {
        let controller = makeController()

        controller.loadView()
        controller.selectProtocolForTesting(.serial)
        controller.selectSerialDeviceProfileForTesting("华为 Huawei（9600 8N1）")
        controller.setSerialAdvancedValuesForTesting(
            dataBits: "7",
            stopBits: "1",
            parity: "偶校验",
            flowControl: "XON/XOFF"
        )
        controller.setSSHValuesForTesting(
            SessionSidebarSessionFormValues(
                name: "Custom Console",
                host: "/dev/cu.usbserial-custom",
                port: controller.portValueForTesting,
                username: "ignored",
                authMode: .password,
                privateKeyPath: "",
                credentialSecret: "",
                tags: "switch"
            )
        )

        let draft = try XCTUnwrap(controller.draft())
        let config = try serialConfigDictionary(from: draft)

        XCTAssertNil(config["deviceProfile"])
        XCTAssertEqual(config["dataBits"] as? Int, 7)
        XCTAssertEqual(config["parity"] as? String, "even")
        XCTAssertEqual(config["flowControl"] as? String, "xonxoff")
    }

    func testSerialProtocolOffersCommonBaudRatesAndAllowsUnsetBaudRate() throws {
        let controller = makeController()
        let saveButton = NSButton(title: "保存", target: nil, action: nil)

        controller.loadView()
        controller.bindSaveButtonForTesting(saveButton)
        controller.selectProtocolForTesting(.serial)

        XCTAssertEqual(
            controller.serialBaudChoicesForTesting,
            [
                "自动/不设置",
                "1200",
                "2400",
                "4800",
                "9600",
                "19200",
                "38400",
                "57600",
                "74880",
                "115200",
                "230400",
                "250000",
                "460800",
                "921600"
            ]
        )

        controller.selectBaudRateForTesting("自动/不设置")
        controller.setSSHValuesForTesting(
            SessionSidebarSessionFormValues(
                name: "蓝牙 Console",
                host: "/dev/cu.Stacio-Bluetooth",
                port: "",
                username: "ignored",
                authMode: .password,
                privateKeyPath: "",
                credentialSecret: "",
                tags: "lab"
            )
        )

        let draft = try XCTUnwrap(controller.draft())
        let config = try serialConfigDictionary(from: draft)

        XCTAssertTrue(saveButton.isEnabled)
        XCTAssertEqual(controller.portValueForTesting, "")
        XCTAssertEqual(draft.protocol, "serial")
        XCTAssertEqual(draft.host, "/dev/cu.Stacio-Bluetooth")
        XCTAssertEqual(draft.port, 0)
        XCTAssertNil(config["baudRate"])
        XCTAssertEqual(config["devicePath"] as? String, "/dev/cu.Stacio-Bluetooth")
        XCTAssertEqual(config["dataBits"] as? Int, 8)
        XCTAssertEqual(config["flowControl"] as? String, "none")
    }

    func testSerialProtocolPersistsCustomHighSpeedBaudRate() throws {
        let controller = makeController()

        controller.loadView()
        controller.selectProtocolForTesting(.serial)
        controller.setSSHValuesForTesting(
            SessionSidebarSessionFormValues(
                name: "ESP Boot Console",
                host: "/dev/cu.usbserial-esp",
                port: "74880",
                username: "ignored",
                authMode: .password,
                privateKeyPath: "",
                credentialSecret: "",
                tags: "lab"
            )
        )

        let draft = try XCTUnwrap(controller.draft())
        let config = try serialConfigDictionary(from: draft)

        XCTAssertEqual(draft.port, 74_880)
        XCTAssertEqual(config["baudRate"] as? Int, 74_880)
    }

    func testSerialProtocolAutoSelectsDetectedDevicePathAndKeepsManualEntry() throws {
        let controller = SessionSettingsViewController(
            existingSession: nil,
            selectedFolderID: nil,
            draftFactory: SessionSidebarSessionDraftFactory(defaultUsername: { "local" }),
            serialDevicePathProvider: {
                [
                    "/dev/tty.usbserial-001",
                    "/dev/cu.Bluetooth-Incoming-Port",
                    "/dev/cu.usbserial-001",
                    "/dev/cu.Stacio-Bluetooth"
                ]
            }
        )

        controller.loadView()
        controller.selectProtocolForTesting(.serial)

        XCTAssertEqual(controller.hostValueForTesting, "/dev/cu.usbserial-001")
        XCTAssertEqual(
            controller.serialDevicePathChoicesForTesting,
            ["/dev/cu.usbserial-001", "/dev/cu.Stacio-Bluetooth", "/dev/cu.Bluetooth-Incoming-Port"]
        )

        controller.setSSHValuesForTesting(
            SessionSidebarSessionFormValues(
                name: "自定义串口",
                host: "/dev/cu.Custom-Console",
                port: controller.portValueForTesting,
                username: "",
                authMode: .password,
                privateKeyPath: "",
                credentialSecret: "",
                tags: ""
            )
        )
        controller.selectProtocolForTesting(.ssh)
        controller.selectProtocolForTesting(.serial)

        XCTAssertEqual(controller.hostValueForTesting, "/dev/cu.Custom-Console")
    }

    func testProtocolDraftValuesAreIsolatedWhenSwitchingSessionTypes() throws {
        let controller = SessionSettingsViewController(
            existingSession: nil,
            selectedFolderID: nil,
            draftFactory: SessionSidebarSessionDraftFactory(defaultUsername: { "local" }),
            serialDevicePathProvider: {
                ["/dev/cu.Bluetooth-Incoming-Port"]
            }
        )

        controller.loadView()
        controller.selectProtocolForTesting(.serial)

        XCTAssertEqual(controller.hostValueForTesting, "/dev/cu.Bluetooth-Incoming-Port")
        XCTAssertEqual(controller.nameValueForTesting, "/dev/cu.Bluetooth-Incoming-Port")
        controller.setConnectionStartupForTesting(command: "screen /dev/cu.Bluetooth-Incoming-Port", environmentVariables: "SERIAL=1")

        controller.selectProtocolForTesting(.ssh)

        XCTAssertEqual(controller.nameValueForTesting, "")
        XCTAssertEqual(controller.hostValueForTesting, "")
        XCTAssertEqual(controller.portValueForTesting, "22")
        XCTAssertEqual(controller.connectionStartupValuesForTesting[L10n.SessionSettings.startupCommand], "")
        XCTAssertEqual(controller.connectionStartupValuesForTesting[L10n.SessionSettings.environmentVariables], "")

        controller.setSSHValuesForTesting(
            SessionSidebarSessionFormValues(
                name: "SSH API",
                host: "api.example.com",
                port: "2222",
                username: "deploy",
                authMode: .agent,
                privateKeyPath: "",
                credentialSecret: "",
                tags: "prod"
            )
        )
        controller.setConnectionStartupForTesting(command: "cd /srv/api && ./healthcheck.sh", environmentVariables: "APP_ENV=prod")
        controller.selectProtocolForTesting(.serial)

        XCTAssertEqual(controller.nameValueForTesting, "/dev/cu.Bluetooth-Incoming-Port")
        XCTAssertEqual(controller.hostValueForTesting, "/dev/cu.Bluetooth-Incoming-Port")
        XCTAssertEqual(controller.portValueForTesting, "9600")
        XCTAssertEqual(
            controller.connectionStartupValuesForTesting[L10n.SessionSettings.startupCommand],
            "screen /dev/cu.Bluetooth-Incoming-Port"
        )
        XCTAssertEqual(controller.connectionStartupValuesForTesting[L10n.SessionSettings.environmentVariables], "SERIAL=1")

        controller.selectProtocolForTesting(.ssh)

        XCTAssertEqual(controller.nameValueForTesting, "SSH API")
        XCTAssertEqual(controller.hostValueForTesting, "api.example.com")
        XCTAssertEqual(controller.portValueForTesting, "2222")
        XCTAssertEqual(
            controller.connectionStartupValuesForTesting[L10n.SessionSettings.startupCommand],
            "cd /srv/api && ./healthcheck.sh"
        )
        XCTAssertEqual(controller.connectionStartupValuesForTesting[L10n.SessionSettings.environmentVariables], "APP_ENV=prod")
    }

    func testSerialAdvancedDraftKeepsHostPortCompatibilityMapping() throws {
        let controller = makeController()

        controller.loadView()
        controller.selectProtocolForTesting(.serial)
        controller.setSSHValuesForTesting(
            SessionSidebarSessionFormValues(
                name: "机柜交换机",
                host: "/dev/cu.SLAB_USBtoUART",
                port: "57600",
                username: "ignored",
                authMode: .privateKey,
                privateKeyPath: "~/.ssh/ignored",
                credentialSecret: "ignored-secret",
                tags: "serial, rack"
            )
        )
        controller.setSerialAdvancedValuesForTesting(
            dataBits: "7",
            stopBits: "2",
            parity: "偶校验",
            flowControl: "RTS/CTS"
        )

        let draft = try XCTUnwrap(controller.draft())

        XCTAssertEqual(draft.protocol, "serial")
        XCTAssertEqual(draft.host, "/dev/cu.SLAB_USBtoUART")
        XCTAssertEqual(draft.port, 57_600)
        XCTAssertNil(draft.username)
        XCTAssertNil(draft.privateKeyPath)
        XCTAssertNil(draft.credentialId)
        XCTAssertEqual(draft.tags, ["serial", "rack"])
        let config = try serialConfigDictionary(from: draft)
        XCTAssertEqual(config["dataBits"] as? Int, 7)
        XCTAssertEqual(config["stopBits"] as? Int, 2)
        XCTAssertEqual(config["parity"] as? String, "even")
        XCTAssertEqual(config["flowControl"] as? String, "rtscts")
    }

    func testEditingSerialSessionLoadsSavedAdvancedConfig() throws {
        let session = makeExistingSerialSession()
        let controller = SessionSettingsViewController(
            existingSession: session,
            selectedFolderID: nil,
            draftFactory: SessionSidebarSessionDraftFactory(defaultUsername: { "local" }),
            existingSerialConfigJSON: #"{"kind":"serial","devicePath":"/dev/cu.usbserial-001","baudRate":115200,"dataBits":7,"stopBits":2,"parity":"odd","flowControl":"xonxoff","backspaceMode":"ctrl_h"}"#
        )

        controller.loadView()

        XCTAssertEqual(controller.serialAdvancedValuesForTesting["数据位"], "7")
        XCTAssertEqual(controller.serialAdvancedValuesForTesting["停止位"], "2")
        XCTAssertEqual(controller.serialAdvancedValuesForTesting["校验位"], "奇校验")
        XCTAssertEqual(controller.serialAdvancedValuesForTesting["流控"], "XON/XOFF")
        XCTAssertEqual(controller.serialAdvancedValuesForTesting["退格键"], "Ctrl+H (BS)")

        let draft = try XCTUnwrap(controller.draft())
        let config = try serialConfigDictionary(from: draft)

        XCTAssertEqual(config["dataBits"] as? Int, 7)
        XCTAssertEqual(config["stopBits"] as? Int, 2)
        XCTAssertEqual(config["parity"] as? String, "odd")
        XCTAssertEqual(config["flowControl"] as? String, "xonxoff")
        XCTAssertEqual(config["backspaceMode"] as? String, "ctrl_h")
    }

    func testEditingSerialSessionLoadsSavedNetworkDeviceProfile() throws {
        let session = makeExistingSerialSession()
        let controller = SessionSettingsViewController(
            existingSession: session,
            selectedFolderID: nil,
            draftFactory: SessionSidebarSessionDraftFactory(defaultUsername: { "local" }),
            existingSerialConfigJSON: #"{"kind":"serial","devicePath":"/dev/cu.usbserial-001","baudRate":9600,"dataBits":8,"stopBits":1,"parity":"none","flowControl":"none","deviceProfile":"huawei"}"#
        )

        controller.loadView()

        XCTAssertEqual(controller.serialAdvancedValuesForTesting["设备类型"], "华为 Huawei（9600 8N1）")
        let draft = try XCTUnwrap(controller.draft())
        let config = try serialConfigDictionary(from: draft)

        XCTAssertEqual(config["deviceProfile"] as? String, "huawei")
        XCTAssertEqual(config["baudRate"] as? Int, 9_600)
        XCTAssertEqual(config["dataBits"] as? Int, 8)
        XCTAssertEqual(config["flowControl"] as? String, "none")
    }

    func testEditingSerialSessionUsesProtocolConfigDevicePathAndBaudRate() throws {
        let session = makeExistingSerialSession()
        let controller = SessionSettingsViewController(
            existingSession: session,
            selectedFolderID: nil,
            draftFactory: SessionSidebarSessionDraftFactory(defaultUsername: { "local" }),
            existingSerialConfigJSON: #"{"kind":"serial","devicePath":"/dev/cu.usbserial-json","baudRate":57600,"dataBits":7,"stopBits":2,"parity":"odd","flowControl":"xonxoff"}"#
        )

        controller.loadView()
        let draft = try XCTUnwrap(controller.draft())
        let config = try serialConfigDictionary(from: draft)

        XCTAssertEqual(draft.host, "/dev/cu.usbserial-json")
        XCTAssertEqual(draft.port, 57_600)
        XCTAssertEqual(config["devicePath"] as? String, "/dev/cu.usbserial-json")
        XCTAssertEqual(config["baudRate"] as? Int, 57_600)
    }

    func testEditingSerialSessionWithoutConfigDoesNotOverwriteAdvancedDefaultsWhenUnchanged() throws {
        let controller = SessionSettingsViewController(
            existingSession: makeExistingSerialSession(),
            selectedFolderID: nil,
            draftFactory: SessionSidebarSessionDraftFactory(defaultUsername: { "local" }),
            existingSerialConfigJSON: nil
        )

        controller.loadView()
        let draft = try XCTUnwrap(controller.draft())

        XCTAssertNil(draft.configJson)
    }

    func testEditingSerialSessionWithoutConfigPersistsBaudRateChanges() throws {
        let controller = SessionSettingsViewController(
            existingSession: makeExistingSerialSession(),
            selectedFolderID: nil,
            draftFactory: SessionSidebarSessionDraftFactory(defaultUsername: { "local" }),
            existingSerialConfigJSON: nil
        )

        controller.loadView()
        controller.selectBaudRateForTesting("57600")

        let draft = try XCTUnwrap(controller.draft())
        let config = try serialConfigDictionary(from: draft)

        XCTAssertEqual(draft.port, 57_600)
        XCTAssertEqual(config["baudRate"] as? Int, 57_600)
    }

    func testFTPProtocolUsesNetworkFormAndKeepsPasswordCredentialReference() throws {
        let credentialSaver = RecordingSessionSettingsCredentialSaver(
            savedCredentialID: "cred_ftp_password"
        )
        let controller = SessionSettingsViewController(
            existingSession: nil,
            selectedFolderID: nil,
            draftFactory: SessionSidebarSessionDraftFactory(
                credentialSaver: credentialSaver,
                defaultUsername: { "local" }
            )
        )
        let saveButton = NSButton(title: "保存", target: nil, action: nil)

        controller.loadView()
        controller.bindSaveButtonForTesting(saveButton)
        controller.selectProtocolForTesting(.ftp)
        controller.setSSHValuesForTesting(
            SessionSidebarSessionFormValues(
                name: "FTP 仓库",
                host: "ftp.example.com",
                port: controller.portValueForTesting,
                username: "deploy",
                authMode: .password,
                privateKeyPath: "",
                credentialSecret: "ftp-secret",
                tags: "files"
            )
        )

        let draft = try XCTUnwrap(controller.draft())

        XCTAssertEqual(controller.hostLabelForTesting, "主机")
        XCTAssertEqual(controller.portLabelForTesting, "端口")
        XCTAssertFalse(controller.userRowIsHiddenForTesting)
        XCTAssertTrue(controller.authRowIsHiddenForTesting)
        XCTAssertTrue(saveButton.isEnabled)
        XCTAssertEqual(draft.protocol, "ftp")
        XCTAssertEqual(draft.host, "ftp.example.com")
        XCTAssertEqual(draft.port, 21)
        XCTAssertEqual(draft.username, "deploy")
        XCTAssertEqual(draft.credentialId, "cred_ftp_password")
        XCTAssertNil(draft.privateKeyPath)
        XCTAssertEqual(credentialSaver.savedSecrets, ["ftp-secret"])
        XCTAssertFalse(String(describing: draft).contains("ftp-secret"))
    }

    func testBrowserProtocolUsesURLFieldAndBuildsSecretFreeDraft() throws {
        let controller = makeController()
        let saveButton = NSButton(title: "保存", target: nil, action: nil)

        controller.loadView()
        controller.bindSaveButtonForTesting(saveButton)
        controller.selectProtocolForTesting(.browser)
        controller.setSSHValuesForTesting(
            SessionSidebarSessionFormValues(
                name: "内部文档",
                host: "https://docs.example.com",
                port: controller.portValueForTesting,
                username: "ignored",
                authMode: .password,
                privateKeyPath: "~/.ssh/ignored",
                credentialSecret: "",
                tags: "docs"
            )
        )

        let draft = try XCTUnwrap(controller.draft())

        XCTAssertEqual(controller.hostLabelForTesting, "网址")
        XCTAssertFalse(controller.hostRowIsHiddenForTesting)
        XCTAssertTrue(controller.portRowIsHiddenForTesting)
        XCTAssertTrue(controller.userRowIsHiddenForTesting)
        XCTAssertTrue(controller.authRowIsHiddenForTesting)
        XCTAssertTrue(saveButton.isEnabled)
        XCTAssertEqual(draft.protocol, "browser")
        XCTAssertEqual(draft.host, "https://docs.example.com")
        XCTAssertEqual(draft.port, 443)
        XCTAssertNil(draft.username)
        XCTAssertNil(draft.privateKeyPath)
        XCTAssertNil(draft.credentialId)
        XCTAssertEqual(draft.tags, ["docs"])
    }

    func testFileProtocolUsesLocalPathFieldAndBuildsSecretFreeDraft() throws {
        let controller = makeController()
        let saveButton = NSButton(title: "保存", target: nil, action: nil)

        controller.loadView()
        controller.bindSaveButtonForTesting(saveButton)
        controller.selectProtocolForTesting(.file)
        controller.setSSHValuesForTesting(
            SessionSidebarSessionFormValues(
                name: "下载目录",
                host: "~/Downloads",
                port: controller.portValueForTesting,
                username: "ignored",
                authMode: .privateKey,
                privateKeyPath: "~/.ssh/ignored",
                credentialSecret: "",
                tags: "local"
            )
        )

        let draft = try XCTUnwrap(controller.draft())

        XCTAssertEqual(controller.hostLabelForTesting, "本地路径")
        XCTAssertFalse(controller.hostRowIsHiddenForTesting)
        XCTAssertTrue(controller.portRowIsHiddenForTesting)
        XCTAssertTrue(controller.userRowIsHiddenForTesting)
        XCTAssertTrue(controller.authRowIsHiddenForTesting)
        XCTAssertTrue(saveButton.isEnabled)
        XCTAssertEqual(draft.protocol, "file")
        XCTAssertEqual(draft.host, "~/Downloads")
        XCTAssertEqual(draft.port, 1)
        XCTAssertNil(draft.username)
        XCTAssertNil(draft.privateKeyPath)
        XCTAssertNil(draft.credentialId)
        XCTAssertEqual(draft.tags, ["local"])
    }

    func testShellProtocolHidesConnectionFieldsAndBuildsLocalDraft() throws {
        let controller = makeController()
        let saveButton = NSButton(title: "保存", target: nil, action: nil)

        controller.loadView()
        controller.bindSaveButtonForTesting(saveButton)
        controller.selectProtocolForTesting(.shell)
        controller.setSSHValuesForTesting(
            SessionSidebarSessionFormValues(
                name: "本地 Shell",
                host: "",
                port: "",
                username: "ignored",
                authMode: .password,
                privateKeyPath: "~/.ssh/ignored",
                credentialSecret: "",
                tags: "local"
            )
        )

        let draft = try XCTUnwrap(controller.draft())

        XCTAssertTrue(controller.hostRowIsHiddenForTesting)
        XCTAssertTrue(controller.portRowIsHiddenForTesting)
        XCTAssertTrue(controller.userRowIsHiddenForTesting)
        XCTAssertTrue(controller.authRowIsHiddenForTesting)
        XCTAssertTrue(saveButton.isEnabled)
        XCTAssertEqual(draft.protocol, "shell")
        XCTAssertEqual(draft.host, "localhost")
        XCTAssertEqual(draft.port, 1)
        XCTAssertNil(draft.username)
        XCTAssertNil(draft.privateKeyPath)
        XCTAssertNil(draft.credentialId)
        XCTAssertEqual(draft.tags, ["local"])
    }

    func testAvailableProtocolsCanBuildSessionDrafts() throws {
        for sessionProtocol in SessionSettingsProtocol.allCases where sessionProtocol.isAvailableForSaving {
            let controller = sessionProtocol == .ftp
                ? SessionSettingsViewController(
                    existingSession: nil,
                    selectedFolderID: nil,
                    draftFactory: SessionSidebarSessionDraftFactory(
                        credentialSaver: RecordingSessionSettingsCredentialSaver(
                            savedCredentialID: "cred_\(sessionProtocol.storageKey)"
                        ),
                        defaultUsername: { "local" }
                    )
                )
                : makeController()
            controller.loadView()
            controller.selectProtocolForTesting(sessionProtocol)
            controller.setSSHValuesForTesting(
                SessionSidebarSessionFormValues(
                    name: "\(sessionProtocol.label) Session",
                    host: "target.example.com",
                    port: controller.portValueForTesting,
                    username: "user",
                    authMode: sessionProtocol == .ftp ? .password : .agent,
                    privateKeyPath: "",
                    credentialSecret: sessionProtocol == .ftp ? "ftp-secret" : "",
                    tags: ""
                )
            )

            let draft = try XCTUnwrap(controller.draft(), "Expected draft for \(sessionProtocol.label)")

            XCTAssertEqual(draft.protocol, sessionProtocol.storageKey)
            XCTAssertGreaterThan(draft.port, 0, "Expected positive port/default parameter for \(sessionProtocol.label)")
        }
    }

    func testUnavailableProtocolsDisableSaveAndDoNotBuildDraft() throws {
        let unavailableProtocols: [SessionSettingsProtocol] = [.rsh, .xdmcp, .mosh, .awsS3, .wsl]

        for sessionProtocol in unavailableProtocols {
            let controller = makeController()
            let saveButton = NSButton(title: "保存", target: nil, action: nil)

            controller.loadView()
            controller.bindSaveButtonForTesting(saveButton)
            controller.selectProtocolForTesting(sessionProtocol)
            controller.setSSHValuesForTesting(
                SessionSidebarSessionFormValues(
                    name: "\(sessionProtocol.label) Session",
                    host: "target.example.com",
                    port: controller.portValueForTesting,
                    username: "user",
                    authMode: .agent,
                    privateKeyPath: "",
                    credentialSecret: "",
                    tags: ""
                )
            )

            XCTAssertNil(try controller.draft(), "Expected no draft for \(sessionProtocol.label)")
            XCTAssertFalse(saveButton.isEnabled, "Expected disabled save button for \(sessionProtocol.label)")
            XCTAssertTrue(controller.sshFormIsHiddenForTesting)
            XCTAssertEqual(
                controller.unsupportedMessageForTesting,
                "当前 Stacio 版本暂不支持 \(sessionProtocol.label) 会话。"
            )
        }
    }

    func testSSHProtocolShowsFormAndBuildsSessionDraft() throws {
        let controller = makeController()
        let saveButton = NSButton(title: "保存", target: nil, action: nil)

        controller.loadView()
        controller.bindSaveButtonForTesting(saveButton)
        controller.setSSHValuesForTesting(
            SessionSidebarSessionFormValues(
                name: "API",
                host: "api.example.com",
                port: "2222",
                username: "deploy",
                authMode: .agent,
                privateKeyPath: "",
                credentialSecret: "",
                tags: "prod, api"
            )
        )

        let draft = try XCTUnwrap(controller.draft())

        XCTAssertFalse(controller.sshFormIsHiddenForTesting)
        XCTAssertTrue(saveButton.isEnabled)
        XCTAssertEqual(draft.name, "API")
        XCTAssertEqual(draft.protocol, "ssh")
        XCTAssertEqual(draft.host, "api.example.com")
        XCTAssertEqual(draft.port, 2222)
        XCTAssertEqual(draft.username, "deploy")
        XCTAssertEqual(draft.tags, ["prod", "api"])
        XCTAssertNotNil(draft.configJson)
    }

    func testWindowControllerHostsSettingsContentAndOwnsCloseHandling() {
        let windowController = SessionSettingsWindowController(
            existingSession: nil,
            selectedFolderID: nil,
            draftFactory: SessionSidebarSessionDraftFactory(defaultUsername: { "local" }),
            errorPresenter: RecordingSessionSettingsErrorPresenter(),
            parentWindowProvider: { nil }
        )

        XCTAssertTrue(windowController.window?.contentViewController is SessionSettingsViewController)
        XCTAssertTrue((windowController.window?.delegate as AnyObject?) === windowController)
        XCTAssertEqual(windowController.window?.title, "新建会话")
    }

    private func makeController() -> SessionSettingsViewController {
        SessionSettingsViewController(
            existingSession: nil,
            selectedFolderID: nil,
            draftFactory: SessionSidebarSessionDraftFactory(defaultUsername: { "local" })
        )
    }

    private func makeExistingSerialSession() -> SessionRecord {
        SessionRecord(
            id: "session_serial",
            folderId: nil,
            name: "串口控制台",
            protocol: "serial",
            host: "/dev/cu.usbserial-001",
            port: 115_200,
            username: nil,
            privateKeyPath: nil,
            credentialId: nil,
            tags: [],
            lastOpenedAt: nil
        )
    }

    private func makeExistingSSHSession() -> SessionRecord {
        SessionRecord(
            id: "session_ssh",
            folderId: nil,
            name: "API",
            protocol: "ssh",
            host: "api.example.com",
            port: 22,
            username: "deploy",
            privateKeyPath: nil,
            credentialId: nil,
            tags: [],
            lastOpenedAt: nil
        )
    }

    private func serialConfigDictionary(from draft: SessionDraft) throws -> [String: Any] {
        let configJSON = try XCTUnwrap(draft.configJson)
        let object = try JSONSerialization.jsonObject(with: Data(configJSON.utf8))
        return try XCTUnwrap(object as? [String: Any])
    }
}

private final class RecordingSessionSettingsErrorPresenter: SessionSidebarErrorPresenting {
    func present(_ error: Error, context: SessionSidebarErrorContext, parentWindow: NSWindow?) {}
}

private final class RecordingSessionSettingsCredentialSaver: SessionSidebarCredentialSaving {
    private let savedCredentialID: String
    private(set) var savedSecrets: [String] = []

    init(savedCredentialID: String) {
        self.savedCredentialID = savedCredentialID
    }

    func saveCredential(kind: String, label: String, account: String, secret: String) throws -> CredentialRecord {
        savedSecrets.append(secret)
        return CredentialRecord(
            id: savedCredentialID,
            kind: kind,
            label: label,
            keychainService: KeychainCredentialStore.serviceName,
            keychainAccount: account
        )
    }
}

private extension NSView {
    func firstSubview(withIdentifier identifier: String) -> NSView? {
        if accessibilityIdentifier() == identifier {
            return self
        }
        for subview in subviews {
            if let match = subview.firstSubview(withIdentifier: identifier) {
                return match
            }
        }
        return nil
    }
}

private extension NSButton {
    var hasDefaultKeyEquivalentForTesting: Bool {
        keyEquivalent == "\r"
    }
}
