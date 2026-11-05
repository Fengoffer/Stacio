import AppKit
import Foundation
import XCTest
@testable import StacioApp

@MainActor
final class LocalAgentSettingsViewControllerTests: XCTestCase {
    func testStoredConfigurationRendersCompleteInstanceDetail() throws {
        let record = makeRecord(
            configurationID: "local-agent-primary",
            displayName: "Primary Codex",
            authenticationState: .needsLogin,
            workingDirectoryMode: .userSelectedLocalDirectory,
            workingDirectoryReference: "/tmp",
            pathPolicy: .custom,
            customPATHEntries: ["/opt/homebrew/bin"],
            environmentAllowlist: ["LANG", "LC_*"]
        )
        let controller = makeController(records: [record])
        _ = controller.view

        XCTAssertEqual(controller.configurationCountForTesting, 1)
        XCTAssertEqual(controller.selectedConfigurationIDForTesting, record.configurationID)
        XCTAssertEqual(
            try field("Stacio.Settings.localAgent.displayName", in: controller).stringValue,
            "Primary Codex"
        )
        XCTAssertEqual(
            try field("Stacio.Settings.localAgent.executablePath", in: controller).stringValue,
            record.executablePath
        )
        XCTAssertEqual(
            try field("Stacio.Settings.localAgent.version", in: controller).stringValue,
            record.detectedVersion
        )
        XCTAssertEqual(
            try field("Stacio.Settings.localAgent.authentication", in: controller).stringValue,
            "需要登录"
        )
        XCTAssertFalse(
            try button("Stacio.Settings.localAgent.login", in: controller).isHidden
        )
        XCTAssertTrue(
            try button("Stacio.Settings.localAgent.logout", in: controller).isHidden
        )
        XCTAssertEqual(
            representedValue(
                try popup("Stacio.Settings.localAgent.executionProfile", in: controller)
            ),
            "terminal-passthrough"
        )
        XCTAssertEqual(
            representedValue(
                try popup("Stacio.Settings.localAgent.workingDirectoryMode", in: controller)
            ),
            AgentProcessWorkingDirectoryMode.userSelectedLocalDirectory.rawValue
        )
        XCTAssertEqual(
            try field("Stacio.Settings.localAgent.workingDirectoryReference", in: controller).stringValue,
            "/tmp"
        )
        XCTAssertEqual(
            representedValue(try popup("Stacio.Settings.localAgent.pathPolicy", in: controller)),
            LocalAgentPATHPolicy.custom.rawValue
        )
        XCTAssertEqual(
            tokenValues(try tokenField("Stacio.Settings.localAgent.customPATHEntries", in: controller)),
            ["/opt/homebrew/bin"]
        )
        XCTAssertEqual(
            tokenValues(try tokenField("Stacio.Settings.localAgent.environmentAllowlist", in: controller)),
            ["LANG", "LC_*"]
        )
        XCTAssertFalse(
            try field("Stacio.Settings.localAgent.lastVerified", in: controller).stringValue.isEmpty
        )
    }

    func testDetectAndSaveEmitsExactEditedParametersAndAskEveryTurnOmitsPath() throws {
        let record = makeRecord(
            configurationID: "local-agent-edit",
            displayName: "Old Name",
            authenticationState: .needsLogin,
            revision: 7,
            workingDirectoryMode: .userSelectedLocalDirectory,
            workingDirectoryReference: "/tmp"
        )
        let recorder = SettingsActionRecorder()
        let controller = makeController(records: [record], recorder: recorder)
        _ = controller.view

        try field("Stacio.Settings.localAgent.displayName", in: controller).stringValue = "  Edited Codex  "
        try switchControl("Stacio.Settings.localAgent.enabled", in: controller).state = .off
        select(
            AgentProcessWorkingDirectoryMode.askEveryTurn.rawValue,
            in: try popup("Stacio.Settings.localAgent.workingDirectoryMode", in: controller)
        )
        try field("Stacio.Settings.localAgent.workingDirectoryReference", in: controller).stringValue = "/tmp/must-not-persist"
        select(
            LocalAgentPATHPolicy.custom.rawValue,
            in: try popup("Stacio.Settings.localAgent.pathPolicy", in: controller)
        )
        try tokenField("Stacio.Settings.localAgent.customPATHEntries", in: controller).objectValue = [
            "/opt/homebrew/bin", "/usr/local/bin"
        ]
        try tokenField("Stacio.Settings.localAgent.environmentAllowlist", in: controller).objectValue = [
            "LANG", "LC_*"
        ]

        try button("Stacio.Settings.localAgent.detectAndSave", in: controller).performClick(nil)

        let call = try XCTUnwrap(recorder.calls.first)
        XCTAssertEqual(call.actionID, "localAgent.detect")
        XCTAssertEqual(call.parameters["configurationID"], .string(record.configurationID))
        XCTAssertEqual(call.parameters["expectedRevision"], .int(7))
        XCTAssertEqual(call.parameters["catalogID"], .string(record.catalogID))
        XCTAssertEqual(call.parameters["executablePath"], .string(record.executablePath))
        XCTAssertEqual(
            call.parameters["executableIdentityDigest"],
            .string(record.executableIdentityDigest)
        )
        XCTAssertEqual(call.parameters["displayName"], .string("Edited Codex"))
        XCTAssertEqual(call.parameters["executionProfileID"], .string("terminal-passthrough"))
        XCTAssertEqual(
            call.parameters["workingDirectoryMode"],
            .string(AgentProcessWorkingDirectoryMode.askEveryTurn.rawValue)
        )
        XCTAssertNil(call.parameters["workingDirectoryReference"])
        XCTAssertEqual(call.parameters["pathPolicy"], .string(LocalAgentPATHPolicy.custom.rawValue))
        XCTAssertEqual(
            call.parameters["customPATHEntries"],
            .stringArray(["/opt/homebrew/bin", "/usr/local/bin"])
        )
        XCTAssertEqual(
            call.parameters["environmentAllowlist"],
            .stringArray(["LANG", "LC_*"])
        )
        XCTAssertEqual(call.parameters["explicitlyEnabled"], .bool(false))
    }

    func testInstanceMaintenanceWebsiteAndDeleteActionsUseStableIdentityAndRevision() throws {
        let needsLogin = makeRecord(
            configurationID: "local-agent-login",
            displayName: "Login Codex",
            authenticationState: .needsLogin,
            revision: 11
        )
        let loginRecorder = SettingsActionRecorder()
        let loginController = makeController(records: [needsLogin], recorder: loginRecorder)
        _ = loginController.view
        try button("Stacio.Settings.localAgent.login", in: loginController).performClick(nil)
        XCTAssertEqual(loginRecorder.calls.first?.actionID, "localAgent.login")
        XCTAssertEqual(
            loginRecorder.calls.first?.parameters,
            ["configurationID": .string("local-agent-login"), "expectedRevision": .int(11)]
        )

        let authenticated = makeRecord(
            configurationID: "local-agent-logout",
            displayName: "Logout Codex",
            authenticationState: .authenticated,
            revision: 12
        )
        let logoutRecorder = SettingsActionRecorder()
        let logoutController = makeController(records: [authenticated], recorder: logoutRecorder)
        _ = logoutController.view
        XCTAssertTrue(try button("Stacio.Settings.localAgent.login", in: logoutController).isHidden)
        XCTAssertFalse(try button("Stacio.Settings.localAgent.logout", in: logoutController).isHidden)
        try button("Stacio.Settings.localAgent.logout", in: logoutController).performClick(nil)
        XCTAssertEqual(logoutRecorder.calls.first?.actionID, "localAgent.logout")
        XCTAssertEqual(
            logoutRecorder.calls.first?.parameters,
            ["configurationID": .string("local-agent-logout"), "expectedRevision": .int(12)]
        )

        let websiteRecorder = SettingsActionRecorder()
        let websiteController = makeController(records: [needsLogin], recorder: websiteRecorder)
        _ = websiteController.view
        let websiteButton = try button("Stacio.Settings.localAgent.openUpgrade", in: websiteController)
        XCTAssertEqual(websiteButton.toolTip, "打开 Coding Plan 官网")
        websiteButton.performClick(nil)
        XCTAssertEqual(websiteRecorder.calls.first?.actionID, "localAgent.openUpgrade")
        XCTAssertEqual(
            websiteRecorder.calls.first?.parameters,
            [
                "configurationID": .string("local-agent-login"),
                "catalogID": .string("coding-plan.chatgpt-codex"),
                "websiteActionID": .string("coding-plan.codex.open")
            ]
        )
        XCTAssertEqual(
            websiteController.deleteParametersForTesting(),
            [
                "configurationKind": .string(ConfigurationKind.localAgent.rawValue),
                "configurationID": .string("local-agent-login"),
                "expectedRevision": .int(11)
            ]
        )
    }

    func testEmptyStateShowsOnlyVerifiedCodingPlanCLIsAndEmitsCatalogActions() throws {
        let recorder = SettingsActionRecorder()
        let controller = makeController(records: [], recorder: recorder)
        _ = controller.view

        for localAgentCatalogID in [
            "local-agent.codex",
            "local-agent.claude-code",
            "local-agent.github-copilot",
            "local-agent.gemini-cli"
        ] {
            XCTAssertNotNil(findView(
                "Stacio.Settings.localAgent.empty.detect.\(localAgentCatalogID)",
                in: controller.view
            ))
        }
        XCTAssertNil(findView(
            "Stacio.Settings.localAgent.empty.detect.local-agent.stacio",
            in: controller.view
        ))

        try button(
            "Stacio.Settings.localAgent.empty.website.coding-plan.chatgpt-codex",
            in: controller
        ).performClick(nil)
        XCTAssertEqual(recorder.calls.first?.actionID, "localAgent.openUpgrade")
        XCTAssertEqual(recorder.calls.first?.parameters, [
            "catalogID": .string("coding-plan.chatgpt-codex"),
            "websiteActionID": .string("coding-plan.codex.open")
        ])
    }

    func testLogoutIsDisabledWhenAssistantControlIsEnabled() throws {
        let record = makeRecord(
            configurationID: "local-agent-enabled-logout",
            displayName: "Enabled Codex",
            authenticationState: .authenticated
        )
        let controller = makeController(records: [record], controlState: .enabled)
        _ = controller.view

        let logout = try button("Stacio.Settings.localAgent.logout", in: controller)
        XCTAssertFalse(logout.isHidden)
        XCTAssertFalse(logout.isEnabled)
    }

    func testUnresolvedMaintenanceEntryShowsReconciliationAndUsesReferenceID() throws {
        let now = Date(timeIntervalSince1970: 1_786_400_000)
        let entry = LocalAgentMaintenanceProcessJournalEntry(
            referenceID: "maintenance-unknown-1",
            operationID: "maintenance-unknown-1",
            configurationID: "local-agent-reconcile",
            action: .login,
            executablePath: "/opt/homebrew/bin/codex",
            executableIdentityDigest: Self.digest("a"),
            environmentDigest: Self.digest("b"),
            processGeneration: 3,
            processIdentifier: 4_200,
            processGroupIdentifier: 4_200,
            trustedProcessStartTime: now,
            state: .stateUnknown,
            settlement: .unknown,
            preparedAt: now,
            startedAt: now,
            updatedAt: now
        )
        let recorder = SettingsActionRecorder()
        let controller = makeController(
            records: [],
            journalEntries: [entry],
            recorder: recorder
        )
        _ = controller.view

        let reconcile = try button("Stacio.Settings.localAgent.reconcile", in: controller)
        XCTAssertFalse(reconcile.isHidden)
        reconcile.performClick(nil as Any?)
        XCTAssertEqual(recorder.calls.first?.actionID, "localAgent.reconcileProcesses")
        XCTAssertEqual(
            recorder.calls.first?.parameters,
            ["referenceID": .string("maintenance-unknown-1")]
        )
    }

    func testNarrowDetailControlsRemainInsideVisibleSettingsWidth() throws {
        let record = makeRecord(
            configurationID: "local-agent-layout",
            displayName: "Layout Codex",
            authenticationState: .authenticated,
            pathPolicy: .custom,
            customPATHEntries: ["/usr/bin"]
        )
        let controller = makeController(records: [record])
        controller.view.frame = NSRect(x: 0, y: 0, width: 660, height: 580)
        controller.view.layoutSubtreeIfNeeded()

        let detail = try XCTUnwrap(
            findView("Stacio.Settings.localAgent.detailScroll", in: controller.view)
                as? NSScrollView
        )
        let controls: [NSView] = [
            try field("Stacio.Settings.localAgent.executablePath", in: controller),
            try field("Stacio.Settings.localAgent.displayName", in: controller),
            try tokenField("Stacio.Settings.localAgent.customPATHEntries", in: controller),
            try tokenField("Stacio.Settings.localAgent.environmentAllowlist", in: controller)
        ]
        for control in controls {
            let frame = control.convert(control.bounds, to: detail.contentView)
            XCTAssertGreaterThanOrEqual(frame.minX, 0, control.accessibilityIdentifier())
            XCTAssertLessThanOrEqual(
                frame.maxX,
                detail.contentView.bounds.maxX,
                control.accessibilityIdentifier()
            )
        }
        XCTAssertFalse(controller.view.descendantsContainAmbiguousLayout)
    }

    func testFormControlsExposeVoiceOverLabels() throws {
        let controller = makeController(records: [makeRecord(
            configurationID: "local-agent-accessibility",
            displayName: "Accessible Codex",
            authenticationState: .authenticated
        )])
        _ = controller.view

        XCTAssertEqual(
            try field("Stacio.Settings.localAgent.displayName", in: controller).accessibilityLabel(),
            "名称"
        )
        XCTAssertEqual(
            try popup("Stacio.Settings.localAgent.executionProfile", in: controller).accessibilityLabel(),
            "执行配置"
        )
        XCTAssertEqual(
            try field("Stacio.Settings.localAgent.workingDirectoryReference", in: controller)
                .accessibilityLabel(),
            "本地目录"
        )
        XCTAssertEqual(
            try tokenField("Stacio.Settings.localAgent.environmentAllowlist", in: controller)
                .accessibilityLabel(),
            "环境变量白名单"
        )
    }

    func testInvalidTokenDraftDisablesSaveAndExplainsError() throws {
        let record = makeRecord(
            configurationID: "local-agent-invalid-token",
            displayName: "Token Codex",
            authenticationState: .authenticated,
            pathPolicy: .custom,
            customPATHEntries: ["/usr/bin"]
        )
        let controller = makeController(records: [record])
        _ = controller.view
        let environment = try tokenField(
            "Stacio.Settings.localAgent.environmentAllowlist",
            in: controller
        )
        environment.stringValue = "SSH_AUTH_SOCK"
        XCTAssertTrue(NSApp.sendAction(
            try XCTUnwrap(environment.action),
            to: environment.target,
            from: environment
        ))

        XCTAssertFalse(
            try button("Stacio.Settings.localAgent.detectAndSave", in: controller).isEnabled
        )
        XCTAssertTrue(
            try field("Stacio.Settings.localAgent.detailStatus", in: controller)
                .stringValue.contains("环境变量")
        )
    }

    func testOperationCompletionStatusSurvivesDetailReload() throws {
        let record = makeRecord(
            configurationID: "local-agent-status",
            displayName: "Status Codex",
            authenticationState: .authenticated
        )
        let recorder = SettingsActionRecorder(
            completionResult: .success(.succeeded(proofDigest: "proof"))
        )
        let controller = makeController(records: [record], recorder: recorder)
        _ = controller.view
        let status = try field("Stacio.Settings.localAgent.detailStatus", in: controller)

        try button("Stacio.Settings.localAgent.detectAndSave", in: controller).performClick(nil)
        XCTAssertTrue(waitUntil { status.stringValue == "已完成" })

        XCTAssertEqual(status.stringValue, "已完成")

        let environment = try tokenField(
            "Stacio.Settings.localAgent.environmentAllowlist",
            in: controller
        )
        environment.stringValue = "SSH_AUTH_SOCK"
        XCTAssertTrue(NSApp.sendAction(
            try XCTUnwrap(environment.action),
            to: environment.target,
            from: environment
        ))
        XCTAssertFalse(
            try button("Stacio.Settings.localAgent.detectAndSave", in: controller).isEnabled
        )
        XCTAssertTrue(
            try field("Stacio.Settings.localAgent.detailStatus", in: controller)
                .stringValue.contains("环境变量")
        )
    }

    func testReconciliationMenuUsesDisplayNamesAndLocalizedActions() {
        let now = Date(timeIntervalSince1970: 1_786_400_000)
        let record = makeRecord(
            configurationID: "local-agent-friendly",
            displayName: "Production Codex",
            authenticationState: .authenticated
        )
        let entries = [LocalAgentMaintenanceAction.login, .logout].map { action in
            LocalAgentMaintenanceProcessJournalEntry(
                referenceID: "maintenance-\(action.rawValue)",
                operationID: "maintenance-\(action.rawValue)",
                configurationID: record.configurationID,
                action: action,
                executablePath: record.executablePath,
                executableIdentityDigest: record.executableIdentityDigest,
                environmentDigest: record.environmentDigest,
                processGeneration: 3,
                processIdentifier: 4_200,
                processGroupIdentifier: 4_200,
                trustedProcessStartTime: now,
                state: .stateUnknown,
                settlement: .unknown,
                preparedAt: now,
                startedAt: now,
                updatedAt: now
            )
        }
        let controller = makeController(records: [record], journalEntries: entries)
        _ = controller.view

        let titles = controller.reconciliationMenuTitlesForTesting()
        XCTAssertEqual(titles, ["Production Codex · 登录", "Production Codex · 退出登录"])
        XCTAssertFalse(titles.contains { $0.contains(record.configurationID) })
        XCTAssertFalse(titles.contains { $0.hasSuffix("login") || $0.hasSuffix("logout") })
    }

    func testDedicatedLocalAgentViewSuppressesGenericParameterlessActions() throws {
        let marker = NSView()
        marker.setAccessibilityIdentifier("Stacio.Settings.localAgent.customMarker")
        let pane = V2SettingsPaneFactory.makeRegistryDrivenPane(
            registry: try AssistantSettingRegistry.standard(),
            actionRegistry: try AssistantSettingsActionRegistry.standard(),
            actionAvailability: { _ in true },
            actionHandler: { _, _, _ in },
            localAgentSettingsView: marker
        )

        XCTAssertNotNil(findView("Stacio.Settings.localAgent.customMarker", in: pane))
        XCTAssertNil(findView("Stacio.Settings.action.localAgent.detect.button", in: pane))
        XCTAssertNil(findView("Stacio.Settings.action.localAgent.login.button", in: pane))
        XCTAssertNil(findView("Stacio.Settings.action.localAgent.logout.button", in: pane))
        XCTAssertNil(
            findView("Stacio.Settings.action.configuration.delete.button", in: pane),
            "Delete requires a selected configuration and must never be a global empty-parameter button"
        )
    }

    private func makeController(
        records: [LocalAgentConfigurationRecord],
        journalEntries: [LocalAgentMaintenanceProcessJournalEntry] = [],
        recorder: SettingsActionRecorder? = nil,
        controlState: AgentConversationV2ControlState = .draining,
        actionAvailability: @escaping (String) -> Bool = { _ in true }
    ) -> LocalAgentSettingsViewController {
        let recorder = recorder ?? SettingsActionRecorder()
        let coordinator = LocalAgentSettingsCoordinator(
            detector: SettingsViewDetector(),
            store: SettingsViewConfigurationStore(records: records),
            maintenancePresenter: nil,
            websiteOpener: nil,
            maintenanceJournal: SettingsViewJournal(entries: journalEntries),
            operationGate: LocalAgentSettingsOperationGate(),
            runtimeUsage: LocalAgentRuntimeUsageRegistry(),
            controlState: { controlState }
        )
        return LocalAgentSettingsViewController(
            coordinator: coordinator,
            actionAvailability: actionAvailability,
            actionHandler: recorder.handler
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 3,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    private func makeRecord(
        configurationID: String,
        displayName: String,
        authenticationState: LocalAgentAuthenticationProbeState,
        revision: Int64 = 4,
        workingDirectoryMode: AgentProcessWorkingDirectoryMode = .managedWorkspace,
        workingDirectoryReference: String? = nil,
        pathPolicy: LocalAgentPATHPolicy = .controlled,
        customPATHEntries: [String] = [],
        environmentAllowlist: [String] = ["LANG"]
    ) -> LocalAgentConfigurationRecord {
        let catalog = BundledRuntimeCatalog.shared
        let descriptor = catalog.catalogSet!.localAgent(catalogID: "local-agent.codex")!
        let now = Date(timeIntervalSince1970: 1_786_400_000)
        return LocalAgentConfigurationRecord(
            configurationID: configurationID,
            configurationRevision: revision,
            catalogID: descriptor.catalogID,
            catalogSetRevision: catalog.catalogSet!.catalogSetRevision,
            descriptorRevision: descriptor.revision,
            rawIdentity: descriptor.rawIdentity,
            userDisplayName: displayName,
            executablePath: "/opt/homebrew/bin/codex",
            executableIdentityDigest: Self.digest("c"),
            executableReferenceConfirmedAt: now,
            detectedVersion: "codex-cli 1.2.3",
            authenticationState: authenticationState,
            selectedProtocol: nil,
            executionProfileID: "terminal-passthrough",
            executionProfileRevision: 1,
            authenticationEvidenceRevision: "auth-v1",
            cliAuthenticationScopeDigest: Self.digest("d"),
            cliLoginIdentityDigest: Self.digest("e"),
            workingDirectoryMode: workingDirectoryMode,
            workingDirectoryReference: workingDirectoryReference,
            pathPolicy: pathPolicy,
            customPATHEntries: customPATHEntries,
            environmentAllowlist: environmentAllowlist,
            environmentDigest: Self.digest("f"),
            lastVerifiedAt: now,
            explicitlyEnabled: true
        )
    }

    private func field(
        _ identifier: String,
        in controller: LocalAgentSettingsViewController
    ) throws -> NSTextField {
        try XCTUnwrap(findView(identifier, in: controller.view) as? NSTextField)
    }

    private func tokenField(
        _ identifier: String,
        in controller: LocalAgentSettingsViewController
    ) throws -> NSTokenField {
        try XCTUnwrap(findView(identifier, in: controller.view) as? NSTokenField)
    }

    private func popup(
        _ identifier: String,
        in controller: LocalAgentSettingsViewController
    ) throws -> NSPopUpButton {
        try XCTUnwrap(findView(identifier, in: controller.view) as? NSPopUpButton)
    }

    private func button(
        _ identifier: String,
        in controller: LocalAgentSettingsViewController
    ) throws -> NSButton {
        try XCTUnwrap(findView(identifier, in: controller.view) as? NSButton)
    }

    private func switchControl(
        _ identifier: String,
        in controller: LocalAgentSettingsViewController
    ) throws -> NSSwitch {
        try XCTUnwrap(findView(identifier, in: controller.view) as? NSSwitch)
    }

    private func findView(_ identifier: String, in root: NSView) -> NSView? {
        if root.accessibilityIdentifier() == identifier { return root }
        for subview in root.subviews {
            if let match = findView(identifier, in: subview) { return match }
        }
        return nil
    }

    private func representedValue(_ popup: NSPopUpButton) -> String? {
        popup.selectedItem?.representedObject as? String
    }

    private func select(_ representedValue: String, in popup: NSPopUpButton) {
        let item = popup.itemArray.first {
            ($0.representedObject as? String) == representedValue
        }
        popup.select(item)
    }

    private func tokenValues(_ field: NSTokenField) -> [String] {
        field.objectValue as? [String] ?? []
    }

    private static func digest(_ character: Character) -> String {
        "sha256:" + String(repeating: String(character), count: 64)
    }
}

@MainActor
private final class SettingsActionRecorder {
    struct Call {
        let actionID: String
        let parameters: [String: SettingValue]
    }

    private(set) var calls: [Call] = []
    private let completionResult: Result<
        AssistantSettingsActionExecutionResult,
        AssistantSettingsActionError
    >?

    init(
        completionResult: Result<
            AssistantSettingsActionExecutionResult,
            AssistantSettingsActionError
        >? = nil
    ) {
        self.completionResult = completionResult
    }

    var handler: V2SettingsActionHandler {
        { [weak self] actionID, parameters, completion in
            self?.calls.append(.init(actionID: actionID, parameters: parameters))
            if let result = self?.completionResult {
                completion(result)
            }
        }
    }
}

private extension NSView {
    var descendantsContainAmbiguousLayout: Bool {
        hasAmbiguousLayout || subviews.contains(where: \.descendantsContainAmbiguousLayout)
    }
}

private final class SettingsViewDetector: LocalAgentConfigurationDetecting {
    func detect(
        catalogID: String,
        userSelectedExecutablePath: String?
    ) throws -> LocalAgentDetectionReport {
        .init(candidates: [], failures: [])
    }
}

private final class SettingsViewConfigurationStore: LocalAgentConfigurationManaging {
    private var values: [String: LocalAgentConfigurationRecord]

    init(records: [LocalAgentConfigurationRecord]) {
        values = Dictionary(uniqueKeysWithValues: records.map { ($0.configurationID, $0) })
    }

    func records() throws -> [LocalAgentConfigurationRecord] { Array(values.values) }

    func record(configurationID: String) throws -> LocalAgentConfigurationRecord? {
        values[configurationID]
    }

    func save(
        _ proposed: LocalAgentConfigurationRecord,
        expectedRevision: Int64?,
        operationID: String,
        eventID: String
    ) throws -> LocalAgentConfigurationRecord {
        values[proposed.configurationID] = proposed
        return proposed
    }

    func delete(
        configurationID: String,
        expectedRevision: Int64,
        operationID: String,
        eventID: String
    ) throws -> Int64 {
        values.removeValue(forKey: configurationID)
        return expectedRevision + 1
    }
}

private final class SettingsViewJournal: LocalAgentMaintenanceProcessJournaling {
    private var values: [String: LocalAgentMaintenanceProcessJournalEntry]

    init(entries: [LocalAgentMaintenanceProcessJournalEntry]) {
        values = Dictionary(uniqueKeysWithValues: entries.map { ($0.referenceID, $0) })
    }

    func entries() throws -> [LocalAgentMaintenanceProcessJournalEntry] { Array(values.values) }

    func entry(referenceID: String) throws -> LocalAgentMaintenanceProcessJournalEntry? {
        values[referenceID]
    }

    func prepare(
        referenceID: String,
        operationID: String,
        configurationID: String,
        action: LocalAgentMaintenanceAction,
        executablePath: String,
        executableIdentityDigest: String,
        environmentDigest: String,
        processGeneration: Int64?
    ) throws -> LocalAgentMaintenanceProcessJournalEntry {
        throw LocalAgentMaintenanceProcessJournalStoreError.invalidEntry("unused_test_prepare")
    }

    func transition(
        referenceID: String,
        event: LocalAgentSettingsProcessEvent,
        processIdentifier: Int32?,
        processGroupIdentifier: Int32?,
        trustedProcessStartTime: Date?,
        exitCode: Int32?,
        failureReason: String?
    ) throws -> LocalAgentMaintenanceProcessJournalEntry {
        throw LocalAgentMaintenanceProcessJournalStoreError.invalidEntry("unused_test_transition")
    }

    func reconcile(
        referenceID: String,
        evidence: LocalAgentMaintenanceReconciliationEvidence
    ) throws -> LocalAgentMaintenanceProcessJournalEntry {
        throw LocalAgentMaintenanceProcessJournalStoreError.invalidEntry("unused_test_reconcile")
    }
}
