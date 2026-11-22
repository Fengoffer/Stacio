import AppKit
import Network
import StacioAgentBridge
import XCTest
@testable import StacioApp

@MainActor
final class AgentPermissionLifecycleTests: XCTestCase {
    func testStoppedTurnRefreshesPermissionTooltip() async throws {
        try await checkPermissionTooltip(after: .interrupted)
    }

    func testCompletedTurnRefreshesPermissionTooltip() async throws {
        try await checkPermissionTooltip(after: .completed)
    }

    func testFailedTurnRefreshesPermissionTooltip() async throws {
        try await checkPermissionTooltip(after: .failed)
    }

    private func checkPermissionTooltip(after phase: AgentPhase) async throws {
        // Override only this process's settings; never persist changes to the user's policy.
        let defaults = UserDefaults.standard
        let originalArguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(originalArguments, forName: UserDefaults.argumentDomain) }
        var arguments = originalArguments
        arguments["Stacio.Settings.agentConfirmationPolicy"] = AgentConfirmationPolicyPreference.allowLowRiskWithoutPrompt.rawValue
        arguments["Stacio.Settings.aiAutoRunProposedCommands"] = true
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)

        let server = try PermissionLifecycleServer()
        server.start()
        defer { server.stop() }
        await fulfillment(of: [server.ready], timeout: 5)
        let port = try XCTUnwrap(server.port)
        let suite = "StacioPermissionLifecycle.\(UUID())"
        let providerDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { providerDefaults.removePersistentDomain(forName: suite) }
        let providerSettings = AppSettingsStore(defaults: providerDefaults)
        let providerID = UUID()
        let model = AIProviderModelConfiguration(id: "permission-test", isEnabled: true,
            isManual: true, wasReturnedByLatestCatalog: false)
        let provider = AIProviderConfiguration(id: providerID, profile: .openAICompatible,
            displayName: "Permission test", baseURL: "http://127.0.0.1:\(port)/v1",
            models: [model], defaultModelID: model.id, compatibilityProtocol: .chatCompletions,
            maxRetryCount: 0, requestTimeoutSeconds: 30, userAgent: "Stacio", isEnabled: true,
            lastVerifiedAt: nil, lastModelSyncAt: nil)
        try providerSettings.saveAIProviderSettings(.init(aiProviders: [provider], defaultAIProviderID: providerID))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = AgentSession(store: AgentStore(rootDirectory: root, saveDebounce: 0),
            providerResolver: AgentProviderResolver(settingsStore: providerSettings, keyStore: PermissionLifecycleKeyStore()),
            executorResolver: PermissionLifecycleInertResolver())
        session.setPermissionMode(.dangerFullAccess)
        let panel = AgentPanelViewController(session: session)
        func findButton(_ view: NSView) -> NSButton? {
            if view.accessibilityIdentifier() == "Stacio.Agent.permission" { return view as? NSButton }
            return view.subviews.lazy.compactMap { findButton($0) }.first
        }
        let button = try XCTUnwrap(findButton(panel.view))

        defer {
            session.onChange = nil
            session.stop()
        }
        let settled = expectation(description: "turn reaches \(phase)")
        let updatePanel = session.onChange
        session.onChange = { change in
            updatePanel?(change)
            if case .phase = change, session.active.phase == phase { settled.fulfill() }
        }
        session.updateDraft("Reply with a short answer.")
        session.send()
        await fulfillment(of: [server.requested], timeout: 5)
        XCTAssertEqual(session.active.phase, .modelRequesting, "\(session.active.items.last?.text ?? "")")
        XCTAssertTrue(session.isRunning)
        XCTAssertFalse(button.isEnabled)

        arguments["Stacio.Settings.agentConfirmationPolicy"] = AgentConfirmationPolicyPreference.requireEveryCommand.rawValue
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        let refreshed = expectation(description: "settings notification handled while turn is running")
        button.title = "Waiting for settings refresh"
        let observation = button.observe(\.title, options: [.new]) { _, change in
            if change.newValue == AgentPermissionMode.dangerFullAccess.label { refreshed.fulfill() }
        }
        NotificationCenter.default.post(name: AppSettingsStore.didChangeNotification, object: AppSettingsStore.shared)
        await fulfillment(of: [refreshed], timeout: 5)
        observation.invalidate()
        XCTAssertEqual(AppSettingsStore.shared.snapshot().agentConfirmationPolicy, .requireEveryCommand)
        XCTAssertEqual(session.permissionPreferences.agentConfirmationPolicy, .allowLowRiskWithoutPrompt)
        XCTAssertTrue(button.toolTip?.contains("不会切换对话权限") == true)
        XCTAssertTrue(button.toolTip?.contains("当前任务结束后可更改权限") == true)

        if phase == .interrupted { session.stop() }
        else { server.respond(succeeding: phase == .completed) }
        await fulfillment(of: [settled], timeout: 5)
        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(session.active.phase, phase)
        XCTAssertTrue(button.isEnabled)
        XCTAssertEqual(button.title, AgentPermissionMode.dangerFullAccess.label)
        XCTAssertEqual(session.permissionPreferences.agentConfirmationPolicy, .requireEveryCommand)
        XCTAssertTrue(button.toolTip?.contains("全局策略要求逐条确认，包括完全权限对话") == true,
                      "Settled turn must describe the latest global policy: \(button.toolTip ?? "nil")")
        XCTAssertFalse(button.toolTip?.contains("当前任务结束后可更改权限") == true)
        withExtendedLifetime(panel) {}
    }
}

private struct PermissionLifecycleInertResolver: AgentTerminalResolving {
    func resolveTerminalTarget(_ target: AgentTarget) throws -> AgentTerminalTarget {
        throw AgentExecutionError.terminalNotFound
    }
}

private final class PermissionLifecycleKeyStore: AIApiKeyStoring {
    func saveAPIKey(_ apiKey: String, for providerID: UUID) throws {}
    func readAPIKey(for providerID: UUID) throws -> String? { "test-key" }
    func deleteAPIKey(for providerID: UUID) throws {}
}

/// Hold a real model request until the test has changed the global policy.
private final class PermissionLifecycleServer {
    let ready = XCTestExpectation(description: "local model fixture is ready")
    let requested = XCTestExpectation(description: "model request is in flight")
    private let listener: NWListener
    private let queue = DispatchQueue(label: "StacioTests.PermissionLifecycle")
    private var connection: NWConnection?
    private var requestData = Data()
    var port: NWEndpoint.Port? { listener.port }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() {
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state { self?.ready.fulfill() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, self.connection == nil else { connection.cancel(); return }
            self.connection = connection
            connection.start(queue: self.queue)
            self.receive(on: connection)
        }
        listener.start(queue: queue)
    }

    func stop() {
        queue.async {
            self.connection?.cancel()
            self.listener.cancel()
        }
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data { self.requestData.append(data) }
            if let boundary = self.requestData.range(of: Data("\r\n\r\n".utf8)) {
                let headers = String(decoding: self.requestData[..<boundary.lowerBound], as: UTF8.self)
                let length = headers.components(separatedBy: "\r\n")
                    .first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
                if self.requestData.count >= boundary.upperBound + length {
                    self.requested.fulfill()
                    return
                }
            }
            if error == nil && !complete { self.receive(on: connection) }
        }
    }

    func respond(succeeding: Bool) {
        queue.async {
            guard let connection = self.connection else { return }
            let body = succeeding
                ? "data: {\"choices\":[{\"delta\":{\"content\":\"Done.\"}}]}\n\ndata: [DONE]\n\n"
                : #"{"error":{"message":"Simulated provider failure"}}"#
            let status = succeeding ? "200 OK" : "500 Internal Server Error"
            let response = "HTTP/1.1 \(status)\r\nContent-Type: text/event-stream\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
