import AppKit
import StacioCoreBindings
import XCTest
@testable import StacioApp

@MainActor
final class QuickConnectCoordinatorTests: XCTestCase {
    func testQuickConnectParsesInputAndStartsRemoteSessionWithAgentAuth() throws {
        let starter = RecordingQuickConnectRemoteSessionStarter(
            status: LiveShellStatus(runtimeId: "term_quick", status: "running", diagnostic: "running")
        )
        let coordinator = QuickConnectCoordinator(remoteSessionStarter: starter)

        let status = try coordinator.connect(
            QuickConnectRequest(target: "deploy@example.com:2200")
        )

        XCTAssertEqual(status.runtimeId, "term_quick")
        XCTAssertEqual(starter.startedTitles, ["deploy@example.com"])
        let config = try XCTUnwrap(starter.startedConfigs.first)
        XCTAssertEqual(config.host, "example.com")
        XCTAssertEqual(config.port, 2200)
        XCTAssertEqual(config.username, "deploy")
        XCTAssertEqual(config.authMethod, .agent)
        XCTAssertFalse(String(describing: config).contains("ssh "))
    }

    func testQuickConnectUsesCurrentNSUserNameWhenInputOmitsUser() throws {
        let starter = RecordingQuickConnectRemoteSessionStarter(
            status: LiveShellStatus(runtimeId: "term_quick", status: "running", diagnostic: "running")
        )
        let coordinator = QuickConnectCoordinator(
            remoteSessionStarter: starter,
            defaultUsernameProvider: { "localuser" }
        )

        try coordinator.connect(QuickConnectRequest(target: "example.com"))

        XCTAssertEqual(starter.startedConfigs.first?.username, "localuser")
        XCTAssertEqual(starter.startedTitles, ["localuser@example.com"])
    }

    func testQuickConnectInvalidInputDoesNotStartRemoteSession() {
        let starter = RecordingQuickConnectRemoteSessionStarter(
            status: LiveShellStatus(runtimeId: "term_quick", status: "running", diagnostic: "running")
        )
        let coordinator = QuickConnectCoordinator(remoteSessionStarter: starter)

        XCTAssertThrowsError(try coordinator.connect(QuickConnectRequest(target: "")))
        XCTAssertTrue(starter.startedConfigs.isEmpty)
    }

    func testQuickConnectCanStartWithPasswordCredentialReference() throws {
        let starter = RecordingQuickConnectRemoteSessionStarter(
            status: LiveShellStatus(runtimeId: "term_quick_password", status: "running", diagnostic: "running")
        )
        let coordinator = QuickConnectCoordinator(remoteSessionStarter: starter)

        _ = try coordinator.connect(
            QuickConnectRequest(
                target: "deploy@example.com:2200",
                authMode: .password,
                credentialID: "cred_password"
            )
        )

        XCTAssertEqual(starter.startedConfigs.map(\.authMethod), [.password(credentialRef: "cred_password")])
    }

    func testQuickConnectCanStartWithPrivateKeyPassphraseReference() throws {
        let starter = RecordingQuickConnectRemoteSessionStarter(
            status: LiveShellStatus(runtimeId: "term_quick_key", status: "running", diagnostic: "running")
        )
        let coordinator = QuickConnectCoordinator(remoteSessionStarter: starter)

        _ = try coordinator.connect(
            QuickConnectRequest(
                target: "deploy@example.com",
                authMode: .privateKey,
                privateKeyPath: "/keys/prod",
                credentialID: "cred_passphrase"
            )
        )

        XCTAssertEqual(
            starter.startedConfigs.map(\.authMethod),
            [.privateKey(keyPath: "/keys/prod", passphraseRef: "cred_passphrase")]
        )
    }

    func testQuickConnectRejectsPasswordAuthWithoutCredentialReference() {
        let starter = RecordingQuickConnectRemoteSessionStarter(
            status: LiveShellStatus(runtimeId: "term_quick", status: "running", diagnostic: "running")
        )
        let coordinator = QuickConnectCoordinator(remoteSessionStarter: starter)

        XCTAssertThrowsError(
            try coordinator.connect(
                QuickConnectRequest(target: "deploy@example.com", authMode: .password)
            )
        ) { error in
            XCTAssertEqual(error as? QuickConnectError, .missingCredentialReference)
        }
        XCTAssertTrue(starter.startedConfigs.isEmpty)
    }

    func testQuickConnectRejectsPrivateKeyAuthWithoutKeyPath() {
        let starter = RecordingQuickConnectRemoteSessionStarter(
            status: LiveShellStatus(runtimeId: "term_quick", status: "running", diagnostic: "running")
        )
        let coordinator = QuickConnectCoordinator(remoteSessionStarter: starter)

        XCTAssertThrowsError(
            try coordinator.connect(
                QuickConnectRequest(target: "deploy@example.com", authMode: .privateKey)
            )
        ) { error in
            XCTAssertEqual(error as? QuickConnectError, .missingPrivateKeyPath)
        }
        XCTAssertTrue(starter.startedConfigs.isEmpty)
    }

    func testQuickConnectRequestDescriptionRedactsTemporarySecret() {
        let request = QuickConnectRequest(
            target: "deploy@example.com",
            authMode: .password,
            credentialID: "cred_password",
            temporarySecret: "super-secret",
            saveAsSession: true,
            sessionName: "API"
        )

        XCTAssertFalse(String(describing: request).contains("super-secret"))
    }

    func testQuickConnectPlaceholdersAreLocalized() {
        XCTAssertEqual(L10n.QuickConnect.placeholder, "用户名@主机:端口")
        XCTAssertFalse(L10n.QuickConnect.placeholder.contains("user@host"))

        XCTAssertEqual(L10n.QuickConnect.sessionNamePlaceholder, "默认使用 用户名@主机")
        XCTAssertFalse(L10n.QuickConnect.sessionNamePlaceholder.contains("user@host"))
    }

    func testQuickConnectPromptViewModelUsesNativeChineseCopy() {
        let model = QuickConnectPromptViewModel.default

        XCTAssertEqual(model.title, "快速连接")
        XCTAssertEqual(model.message, "输入 SSH 目标，选择认证方式后立即连接。")
        XCTAssertEqual(model.connectButtonTitle, "连接")
        XCTAssertEqual(model.cancelButtonTitle, "取消")
        XCTAssertEqual(model.targetLabel, "SSH 目标")
        XCTAssertEqual(model.targetPlaceholder, "用户名@主机:端口")
        XCTAssertFalse(model.targetPlaceholder.contains("user@host"))
    }

    func testQuickConnectPromptViewModelExplainsAuthAndSaveSessionControls() {
        let model = QuickConnectPromptViewModel.default

        XCTAssertEqual(model.authLabel, "认证")
        XCTAssertEqual(model.authHint, "默认使用 SSH Agent；需要密码或私钥口令时可临时输入，不会调用外部 ssh。")
        XCTAssertEqual(model.saveAsSessionTitle, "连接成功后保存为会话")
        XCTAssertEqual(model.saveAsSessionHint, "开启后可命名会话，凭据按当前保存流程处理。")
        XCTAssertEqual(model.sessionNamePlaceholder, "默认使用 用户名@主机")
        XCTAssertFalse(model.authHint.contains("ssh "))
    }

    func testQuickConnectPromptUsesCompactNativeFormAccessory() throws {
        let form = QuickConnectPromptForm(model: .default)
        let view = form.view

        XCTAssertLessThanOrEqual(view.fittingSize.width, 360)
        XCTAssertLessThanOrEqual(view.fittingSize.height, 190)
        XCTAssertEqual(view.layer?.borderWidth ?? 0, 0)
        XCTAssertLessThanOrEqual(view.layer?.cornerRadius ?? 0, 0)
        XCTAssertNotNil(view.firstSubview(ofType: NSGridView.self))
        XCTAssertNil(view.firstSubview(withIdentifier: "Stacio.QuickConnect.heroIcon"))

        let targetField = try XCTUnwrap(
            view.firstSubview(withIdentifier: "Stacio.QuickConnect.target") as? NSTextField
        )
        XCTAssertGreaterThanOrEqual(targetField.fittingSize.width, 230)
    }

    func testQuickConnectErrorPresenterBuildsChineseDiagnosticInsteadOfGeneratedEnum() {
        let message = AppKitQuickConnectErrorPresenter.informativeText(
            for: SshRuntimeError.Transport(message: "[Session(-37)] Would block")
        )

        XCTAssertEqual(message, "SSH 通道暂时不可用，请稍后重试")
        XCTAssertFalse(message.contains("StacioCoreBindings"))
        XCTAssertFalse(message.contains("SshRuntimeError"))
        XCTAssertFalse(message.contains("Transport"))
        XCTAssertFalse(message.localizedCaseInsensitiveContains("Would block"))
    }

    func testQuickConnectPromptUsesLightweightSheetWithoutAlertHeroIcon() throws {
        let controller = QuickConnectPromptViewController(model: .default)

        controller.loadView()

        XCTAssertEqual(controller.view.accessibilityIdentifier(), "Stacio.QuickConnect.sheet")
        XCTAssertLessThanOrEqual(controller.view.frame.width, 430)
        XCTAssertLessThanOrEqual(controller.view.frame.height, 310)
        XCTAssertNil(controller.view.firstSubview(ofType: NSImageView.self))
        XCTAssertNotNil(controller.view.firstSubview(ofType: NSGridView.self))
        XCTAssertNotNil(controller.view.firstSubview(withIdentifier: "Stacio.QuickConnect.target"))
    }

    func testQuickConnectPromptDoesNotExposeTemplateActions() throws {
        let controller = QuickConnectPromptViewController(model: .default)

        controller.loadView()

        XCTAssertFalse(controller.view.buttonTitles.contains("保存为模板"))
    }
}

private final class RecordingQuickConnectRemoteSessionStarter: RemoteSSHSessionStarting {
    var startedConfigs: [SshConnectionConfig] = []
    var startedTitles: [String] = []
    private let status: LiveShellStatus

    init(status: LiveShellStatus) {
        self.status = status
    }

    func start(config: SshConnectionConfig, title: String) throws -> LiveShellStatus {
        startedConfigs.append(config)
        startedTitles.append(title)
        return status
    }
}

private extension NSView {
    var buttonTitles: [String] {
        var values: [String] = []
        if let button = self as? NSButton {
            values.append(button.title)
        }
        for subview in subviews {
            values.append(contentsOf: subview.buttonTitles)
        }
        return values
    }

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

    func firstSubview<T: NSView>(ofType type: T.Type) -> T? {
        if let view = self as? T {
            return view
        }
        for subview in subviews {
            if let match = subview.firstSubview(ofType: type) {
                return match
            }
        }
        return nil
    }
}
