import AppKit
import XCTest
@testable import StacioApp
import StacioCoreBindings
import UniformTypeIdentifiers

@MainActor
final class DiagnosticsViewControllerTests: XCTestCase {
    func testLocalPortProbeControlsDefaultToLoopbackAndRenderReachableResult() throws {
        let probe = FakePortProbe(result: .reachable)
        let controller = DiagnosticsViewController(portProbe: probe)

        controller.loadView()

        let hostField = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Diagnostics.portHost") as? NSTextField
        )
        let portField = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Diagnostics.portNumber") as? NSTextField
        )
        let checkButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Diagnostics.portCheck") as? NSButton
        )

        XCTAssertEqual(hostField.stringValue, "127.0.0.1")
        portField.stringValue = "22"
        checkButton.performClick(nil as Any?)

        XCTAssertEqual(probe.requests, [PortProbeRequest(host: "127.0.0.1", port: 22)])
        XCTAssertTrue(controller.visibleTextSnapshot.contains("本地端口检查"))
        XCTAssertTrue(controller.visibleTextSnapshot.contains("127.0.0.1:22 可连接"))
    }

    func testDiagnosticsInspectorUsesCompactPortProbeControlsForNarrowPanel() throws {
        let controller = DiagnosticsViewController(portProbe: FakePortProbe(result: .reachable))
        controller.loadView()

        let portProbeGrid = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Diagnostics.portProbeControls") as? NSStackView
        )
        let hostField = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Diagnostics.portHost") as? NSTextField
        )
        let portField = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Diagnostics.portNumber") as? NSTextField
        )
        let checkButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Diagnostics.portCheck") as? NSButton
        )

        XCTAssertEqual(portProbeGrid.orientation, .vertical)
        XCTAssertEqual(portProbeGrid.arrangedSubviews.count, 2)
        XCTAssertEqual(portProbeGrid.spacing, 8)
        XCTAssertLessThanOrEqual(hostField.fittingSize.height, 32)
        XCTAssertLessThan(portField.fittingSize.width, hostField.fittingSize.width)
        XCTAssertTrue(checkButton.frame.intersects(portField.frame))
        XCTAssertLessThan(abs(checkButton.frame.midY - portField.frame.midY), portField.frame.height / 2)
    }

    func testLocalPortProbeRendersUnreachableResult() throws {
        let probe = FakePortProbe(result: .unreachable)
        let controller = DiagnosticsViewController(portProbe: probe)

        controller.loadView()

        let portField = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Diagnostics.portNumber") as? NSTextField
        )
        let checkButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Diagnostics.portCheck") as? NSButton
        )

        portField.stringValue = "65535"
        checkButton.performClick(nil as Any?)

        XCTAssertEqual(probe.requests, [PortProbeRequest(host: "127.0.0.1", port: 65_535)])
        XCTAssertTrue(controller.visibleTextSnapshot.contains("127.0.0.1:65535 不可连接"))
    }

    func testLocalPortProbeRejectsInvalidPortWithoutCallingProbe() throws {
        let probe = FakePortProbe(result: .reachable)
        let controller = DiagnosticsViewController(portProbe: probe)

        controller.loadView()

        let portField = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Diagnostics.portNumber") as? NSTextField
        )
        let checkButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Diagnostics.portCheck") as? NSButton
        )

        portField.stringValue = "70000"
        checkButton.performClick(nil as Any?)

        XCTAssertEqual(probe.requests, [])
        XCTAssertTrue(controller.visibleTextSnapshot.contains("端口无效"))
    }

    func testDiagnosticsPanelRendersRedactedBundleInNativeTable() {
        let controller = DiagnosticsViewController()

        controller.loadView()
        controller.replaceBundle(
            sessionID: "session_1",
            tunnelID: "tun_1",
            entries: [
                DiagnosticEntry(
                    severity: .error,
                    message: "credential secret-ref failed at /Users/alice/.ssh/id_ed25519"
                ),
                DiagnosticEntry(severity: .warning, message: "retry scheduled")
            ]
        )

        XCTAssertEqual(controller.tableView.numberOfRows, 2)
        XCTAssertEqual(controller.tableView.tableColumns.map(\.title), ["级别", "消息"])
        XCTAssertTrue(controller.visibleTextSnapshot.contains("诊断"))
        XCTAssertTrue(controller.visibleTextSnapshot.contains("session_1"))
        XCTAssertTrue(controller.visibleTextSnapshot.contains("tun_1"))
        XCTAssertTrue(controller.visibleTextSnapshot.contains("错误"))
        XCTAssertTrue(controller.visibleTextSnapshot.contains("警告"))
        XCTAssertFalse(controller.visibleTextSnapshot.contains("secret-ref"))
        XCTAssertFalse(controller.visibleTextSnapshot.contains("/Users/alice/.ssh/id_ed25519"))
        XCTAssertTrue(controller.visibleTextSnapshot.contains("[redacted-credential]"))
    }

    func testDiagnosticsPanelLoadsMultiExecAuditRecords() throws {
        let store = RecordingMultiExecAuditListing(records: [
            BroadcastAuditRecord(
                id: "audit_1",
                traceId: "trace_1",
                targetCount: 3,
                sentCount: 2,
                failedCount: 1,
                redactedInput: "export TOKEN=[redacted-secret]",
                executed: true,
                createdAt: "2026-05-30T10:00:00Z"
            )
        ])
        let controller = DiagnosticsViewController(auditStore: store)

        controller.loadView()
        let refreshButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Diagnostics.auditRefresh") as? NSButton
        )

        XCTAssertTrue(controller.visibleTextSnapshot.contains("2026-05-30T10:00:00Z"))
        XCTAssertEqual(store.requestedLimits, [20])

        refreshButton.performClick(nil as Any?)

        XCTAssertEqual(store.requestedLimits, [20, 20])
        XCTAssertTrue(controller.visibleTextSnapshot.contains("多执行审计"))
        XCTAssertTrue(controller.visibleTextSnapshot.contains("2026-05-30T10:00:00Z"))
        XCTAssertTrue(controller.visibleTextSnapshot.contains("目标 3"))
        XCTAssertTrue(controller.visibleTextSnapshot.contains("已发送 2 / 失败 1"))
        XCTAssertTrue(controller.visibleTextSnapshot.contains("export [已隐藏凭据]"))
        XCTAssertFalse(controller.visibleTextSnapshot.contains("[redacted-secret]"))
        XCTAssertFalse(controller.visibleTextSnapshot.contains("secret-value"))
    }

    func testDiagnosticsPanelLoadsAgentActionAuditRecords() throws {
        let agentStore = RecordingAgentActionAuditListing(records: [
            AgentActionAuditRecord(
                id: "agent_audit_1",
                requestId: "req-agent-1",
                actorKind: "builtInAI",
                actorName: "Stacio AI",
                targetRuntimeId: "term_1",
                targetTitle: "prod@example.com",
                actionKind: "runCommand",
                risk: "destructive",
                state: "cancelled",
                redactedInput: "export password hunter2 token=live-key /Users/alice/.ssh/id_ed25519",
                environment: "production",
                approvalMode: "requireEveryCommand",
                policyDecision: "confirmed",
                redactionVersion: "stacio.agent-redaction.v1",
                createdAt: "2026-06-04T12:00:00Z"
            )
        ])
        let controller = DiagnosticsViewController(agentAuditStore: agentStore)

        controller.loadView()
        let refreshButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Diagnostics.auditRefresh") as? NSButton
        )

        refreshButton.performClick(nil as Any?)

        let snapshot = controller.visibleTextSnapshot
        XCTAssertEqual(agentStore.requestedLimits, [20, 20])
        XCTAssertTrue(snapshot.contains("AI/Agent 审计"))
        XCTAssertTrue(snapshot.contains("2026-06-04T12:00:00Z"))
        XCTAssertTrue(snapshot.contains("request req-agent-1"))
        XCTAssertTrue(snapshot.contains("runtime term_1"))
        XCTAssertTrue(snapshot.contains("Stacio AI"))
        XCTAssertTrue(snapshot.contains("prod@example.com"))
        XCTAssertTrue(snapshot.contains("destructive"))
        XCTAssertTrue(snapshot.contains("cancelled"))
        XCTAssertTrue(snapshot.contains("production"))
        XCTAssertTrue(snapshot.contains("requireEveryCommand"))
        XCTAssertTrue(snapshot.contains("confirmed"))
        XCTAssertTrue(snapshot.contains("stacio.agent-redaction.v1"))
        XCTAssertTrue(snapshot.contains("[已隐藏凭据]"))
        XCTAssertFalse(snapshot.localizedCaseInsensitiveContains("password"))
        XCTAssertFalse(snapshot.contains("hunter2"))
        XCTAssertFalse(snapshot.contains("live-key"))
        XCTAssertFalse(snapshot.contains("/Users/alice/.ssh/id_ed25519"))
    }

    func testDiagnosticsAuditScopeFilterSeparatesAgentAndMultiExecRecords() throws {
        let multiStore = RecordingMultiExecAuditListing(records: [
            BroadcastAuditRecord(
                id: "multi_audit_scope",
                traceId: "trace_scope",
                targetCount: 2,
                sentCount: 2,
                failedCount: 0,
                redactedInput: "uptime",
                executed: true,
                createdAt: "2026-06-04T10:00:00Z"
            )
        ])
        let agentStore = RecordingAgentActionAuditListing(records: [
            AgentActionAuditRecord(
                id: "agent_audit_scope",
                requestId: "req-scope",
                actorKind: "externalCLI",
                actorName: "codex",
                targetRuntimeId: "term_scope",
                targetTitle: "prod@example.com",
                actionKind: "runCommand",
                risk: "readOnly",
                state: "completed",
                redactedInput: "whoami",
                environment: "production",
                approvalMode: "requireEveryCommand",
                policyDecision: "confirmed",
                redactionVersion: "stacio.agent-redaction.v1",
                createdAt: "2026-06-04T10:01:00Z"
            )
        ])
        let controller = DiagnosticsViewController(
            auditStore: multiStore,
            agentAuditStore: agentStore
        )

        controller.loadView()
        let scope = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Diagnostics.auditScope") as? NSSegmentedControl
        )
        let refreshButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Diagnostics.auditRefresh") as? NSButton
        )

        refreshButton.performClick(nil as Any?)
        XCTAssertTrue(controller.visibleTextSnapshot.contains("uptime"))
        XCTAssertTrue(controller.visibleTextSnapshot.contains("codex"))

        scope.selectedSegment = 1
        scope.sendAction(scope.action, to: scope.target)
        XCTAssertFalse(controller.visibleTextSnapshot.contains("uptime"))
        XCTAssertTrue(controller.visibleTextSnapshot.contains("codex"))

        scope.selectedSegment = 2
        scope.sendAction(scope.action, to: scope.target)
        XCTAssertTrue(controller.visibleTextSnapshot.contains("uptime"))
        XCTAssertFalse(controller.visibleTextSnapshot.contains("codex"))
    }

    func testExportDiagnosticsRespectsSelectedAuditScope() throws {
        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: destinationURL) }
        let exporter = RecordingDiagnosticsExportPresenter(destinationURL: destinationURL)
        let multiStore = RecordingMultiExecAuditListing(records: [
            BroadcastAuditRecord(
                id: "multi_audit_export_scope",
                traceId: "trace-export-scope",
                targetCount: 1,
                sentCount: 1,
                failedCount: 0,
                redactedInput: "uptime",
                executed: true,
                createdAt: "2026-06-04T11:00:00Z"
            )
        ])
        let agentStore = RecordingAgentActionAuditListing(records: [
            AgentActionAuditRecord(
                id: "agent_audit_export_scope",
                requestId: "req-export-scope",
                actorKind: "externalCLI",
                actorName: "codex",
                targetRuntimeId: "term_scope",
                targetTitle: "prod@example.com",
                actionKind: "runCommand",
                risk: "readOnly",
                state: "completed",
                redactedInput: "whoami",
                environment: "production",
                approvalMode: "requireEveryCommand",
                policyDecision: "confirmed",
                redactionVersion: "stacio.agent-redaction.v1",
                createdAt: "2026-06-04T11:01:00Z"
            )
        ])
        let controller = DiagnosticsViewController(
            exportPresenter: exporter,
            auditStore: multiStore,
            agentAuditStore: agentStore
        )

        controller.loadView()
        let scope = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Diagnostics.auditScope") as? NSSegmentedControl
        )
        scope.selectedSegment = 1
        scope.sendAction(scope.action, to: scope.target)
        let exportButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Diagnostics.export") as? NSButton
        )
        exportButton.performClick(nil as Any?)

        let exported = try String(contentsOf: destinationURL, encoding: .utf8)
        XCTAssertEqual(multiStore.requestedLimits, [20])
        XCTAssertEqual(agentStore.requestedLimits, [20, 20])
        XCTAssertTrue(exported.contains(#""agentActions" : ["#))
        XCTAssertTrue(exported.contains(#""actorName" : "codex""#))
        XCTAssertTrue(exported.contains(#""multiExecAudit" : ["#))
        XCTAssertFalse(exported.contains("trace-export-scope"))
        XCTAssertFalse(exported.contains("uptime"))
    }

    func testDiagnosticsPanelShowsWarningWhenMultiExecAuditRefreshFails() throws {
        let store = RecordingMultiExecAuditListing(
            error: StoreRefreshError(message: "sqlite failed password hunter2 at /Users/alice/.ssh/id_ed25519")
        )
        let controller = DiagnosticsViewController(auditStore: store)

        controller.loadView()
        let refreshButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Diagnostics.auditRefresh") as? NSButton
        )
        refreshButton.performClick(nil as Any?)

        let snapshot = controller.visibleTextSnapshot
        XCTAssertEqual(store.requestedLimits, [20, 20])
        XCTAssertTrue(snapshot.contains("无法读取 MultiExec 审计记录"))
        XCTAssertTrue(snapshot.contains("sqlite failed"))
        XCTAssertTrue(snapshot.contains("[已隐藏凭据]"))
        XCTAssertFalse(snapshot.lowercased().contains("password"))
        XCTAssertFalse(snapshot.contains("hunter2"))
        XCTAssertFalse(snapshot.contains("/Users/alice/.ssh/id_ed25519"))
    }

    func testExportDiagnosticsWritesRedactedJSONBundle() throws {
        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: destinationURL) }
        let exporter = RecordingDiagnosticsExportPresenter(destinationURL: destinationURL)
        let controller = DiagnosticsViewController(exportPresenter: exporter)

        controller.loadView()
        controller.replaceBundle(
            sessionID: "session_export",
            tunnelID: "tunnel_export",
            entries: [
                DiagnosticEntry(
                    severity: .error,
                    message: "password secret-ref failed at /Users/alice/.ssh/id_ed25519"
                )
            ]
        )

        let exportButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Diagnostics.export") as? NSButton
        )
        exportButton.performClick(nil as Any?)

        let exported = try String(contentsOf: destinationURL, encoding: .utf8)
        XCTAssertEqual(exporter.suggestedNames, ["Stacio Diagnostics.json"])
        XCTAssertEqual(exporter.completedURLs, [destinationURL])
        XCTAssertTrue(exported.contains(#""sessionId" : "session_export""#))
        XCTAssertTrue(exported.contains(#""tunnelId" : "tunnel_export""#))
        XCTAssertTrue(exported.contains("[redacted-credential]"))
        XCTAssertFalse(exported.contains("secret-ref"))
        XCTAssertFalse(exported.contains("/Users/alice/.ssh/id_ed25519"))
    }

    func testExportDiagnosticsIncludesMultiExecAuditRecords() throws {
        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: destinationURL) }
        let exporter = RecordingDiagnosticsExportPresenter(destinationURL: destinationURL)
        let store = RecordingMultiExecAuditListing(records: [
            BroadcastAuditRecord(
                id: "audit_export",
                traceId: "trace_export",
                targetCount: 2,
                sentCount: 1,
                failedCount: 1,
                redactedInput: "echo [redacted-secret]",
                executed: true,
                createdAt: "2026-05-30T12:00:00Z"
            )
        ])
        let controller = DiagnosticsViewController(exportPresenter: exporter, auditStore: store)

        controller.loadView()
        let exportButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Diagnostics.export") as? NSButton
        )
        exportButton.performClick(nil as Any?)

        let exported = try String(contentsOf: destinationURL, encoding: .utf8)
        XCTAssertEqual(store.requestedLimits, [20, 20])
        XCTAssertTrue(exported.contains(#""multiExecAudit" : ["#))
        XCTAssertTrue(exported.contains(#""traceId" : "trace_export""#))
        XCTAssertTrue(exported.contains(#""targetCount" : 2"#))
        XCTAssertTrue(exported.contains(#""sentCount" : 1"#))
        XCTAssertTrue(exported.contains(#""failedCount" : 1"#))
        XCTAssertTrue(exported.contains(#""redactedInput" : "echo [已隐藏凭据]""#))
        XCTAssertFalse(exported.contains("[redacted-secret]"))
        XCTAssertFalse(exported.contains("secret-value"))
    }

    func testDiagnosticsUsesSettingsBackedAuditAndLogLimits() throws {
        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: destinationURL) }
        let suiteName = "StacioDiagnosticsLimitSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = AppSettingsStore(defaults: defaults)
        settingsStore.update { settings in
            settings.diagnosticsAuditExportLimit = 35
            settings.diagnosticsAppLogLineLimit = 8
        }
        let exporter = RecordingDiagnosticsExportPresenter(destinationURL: destinationURL)
        let multiStore = RecordingMultiExecAuditListing(records: [])
        let agentStore = RecordingAgentActionAuditListing(records: [])
        let logStore = RecordingDiagnosticsLogStore(lines: (1...20).map { "log-entry-\(String(format: "%02d", $0))" })
        let controller = DiagnosticsViewController(
            exportPresenter: exporter,
            auditStore: multiStore,
            agentAuditStore: agentStore,
            appLogStore: logStore,
            settingsStore: settingsStore
        )

        controller.loadView()
        let auditRefreshButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Diagnostics.auditRefresh") as? NSButton
        )
        let logRefreshButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Diagnostics.appLogRefresh") as? NSButton
        )
        auditRefreshButton.performClick(nil as Any?)
        logRefreshButton.performClick(nil as Any?)

        XCTAssertEqual(multiStore.requestedLimits, [35, 35])
        XCTAssertEqual(agentStore.requestedLimits, [35, 35])
        XCTAssertEqual(logStore.requestedLimits, [8, 8])
        XCTAssertFalse(controller.visibleTextSnapshot.contains("log-entry-01"))
        XCTAssertTrue(controller.visibleTextSnapshot.contains("log-entry-20"))

        let exportButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Diagnostics.export") as? NSButton
        )
        exportButton.performClick(nil as Any?)

        XCTAssertEqual(multiStore.requestedLimits, [35, 35, 35])
        XCTAssertEqual(agentStore.requestedLimits, [35, 35, 35])
        XCTAssertEqual(logStore.requestedLimits, [8, 8, 8])
    }

    func testDiagnosticsExportCanOmitAppLogsFromSettings() throws {
        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: destinationURL) }
        let suiteName = "StacioDiagnosticsOmitLogsSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = AppSettingsStore(defaults: defaults)
        settingsStore.update { settings in
            settings.diagnosticsIncludeAppLogs = false
        }
        let exporter = RecordingDiagnosticsExportPresenter(destinationURL: destinationURL)
        let logStore = RecordingDiagnosticsLogStore(lines: ["visible app log"])
        let controller = DiagnosticsViewController(
            exportPresenter: exporter,
            appLogStore: logStore,
            settingsStore: settingsStore
        )

        controller.loadView()
        let logRefreshButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Diagnostics.appLogRefresh") as? NSButton
        )
        logRefreshButton.performClick(nil as Any?)
        XCTAssertEqual(logStore.requestedLimits, [200, 200])
        XCTAssertTrue(controller.visibleTextSnapshot.contains("visible app log"))

        let exportButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Diagnostics.export") as? NSButton
        )
        exportButton.performClick(nil as Any?)

        let exported = try String(contentsOf: destinationURL, encoding: .utf8)
        XCTAssertEqual(logStore.requestedLimits, [200, 200])
        XCTAssertTrue(exported.contains(#""appLogs" : ["#))
        XCTAssertFalse(exported.contains("visible app log"))
    }

    func testExportDiagnosticsIncludesAgentActionAuditRecords() throws {
        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: destinationURL) }
        let exporter = RecordingDiagnosticsExportPresenter(destinationURL: destinationURL)
        let agentStore = RecordingAgentActionAuditListing(records: [
            AgentActionAuditRecord(
                id: "agent_audit_export",
                requestId: "req-agent-export",
                actorKind: "externalCLI",
                actorName: "codex",
                targetRuntimeId: "term_2",
                targetTitle: "dev@example.com",
                actionKind: "runCommand",
                risk: "write",
                state: "running",
                redactedInput: "TOKEN=secret-value tee /Users/alice/.ssh/id_ed25519",
                environment: "development",
                approvalMode: "readOnlyAuto",
                policyDecision: "autoAllowed",
                redactionVersion: "stacio.agent-redaction.v1",
                createdAt: "2026-06-04T13:00:00Z"
            )
        ])
        let controller = DiagnosticsViewController(
            exportPresenter: exporter,
            agentAuditStore: agentStore
        )

        controller.loadView()
        let exportButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Diagnostics.export") as? NSButton
        )
        exportButton.performClick(nil as Any?)

        let exported = try String(contentsOf: destinationURL, encoding: .utf8)
        XCTAssertEqual(agentStore.requestedLimits, [20, 20])
        XCTAssertTrue(exported.contains(#""agentActions" : ["#))
        XCTAssertTrue(exported.contains(#""requestId" : "req-agent-export""#))
        XCTAssertTrue(exported.contains(#""actorName" : "codex""#))
        XCTAssertTrue(exported.contains(#""targetTitle" : "dev@example.com""#))
        XCTAssertTrue(exported.contains(#""state" : "running""#))
        XCTAssertTrue(exported.contains(#""environment" : "development""#))
        XCTAssertTrue(exported.contains(#""approvalMode" : "readOnlyAuto""#))
        XCTAssertTrue(exported.contains(#""policyDecision" : "autoAllowed""#))
        XCTAssertTrue(exported.contains(#""redactionVersion" : "stacio.agent-redaction.v1""#))
        XCTAssertTrue(exported.contains("[已隐藏凭据]"))
        XCTAssertFalse(exported.contains("secret-value"))
        XCTAssertFalse(exported.contains("/Users/alice/.ssh/id_ed25519"))
    }

    func testDiagnosticsRedactsStoredMultiExecAuditInputAgainBeforeDisplayAndExport() throws {
        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: destinationURL) }
        let exporter = RecordingDiagnosticsExportPresenter(destinationURL: destinationURL)
        let store = RecordingMultiExecAuditListing(records: [
            BroadcastAuditRecord(
                id: "audit_untrusted",
                traceId: "trace_untrusted",
                targetCount: 1,
                sentCount: 0,
                failedCount: 1,
                redactedInput: "export password hunter2 token=live-key /Users/alice/.ssh/id_ed25519",
                executed: true,
                createdAt: "2026-05-31T10:00:00Z"
            )
        ])
        let controller = DiagnosticsViewController(exportPresenter: exporter, auditStore: store)

        controller.loadView()
        let refreshButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Diagnostics.auditRefresh") as? NSButton
        )
        refreshButton.performClick(nil as Any?)

        let snapshot = controller.visibleTextSnapshot
        XCTAssertTrue(snapshot.contains("[已隐藏凭据]"))
        XCTAssertFalse(snapshot.localizedCaseInsensitiveContains("password"))
        XCTAssertFalse(snapshot.contains("hunter2"))
        XCTAssertFalse(snapshot.contains("live-key"))
        XCTAssertFalse(snapshot.contains("/Users/alice/.ssh/id_ed25519"))

        let exportButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Diagnostics.export") as? NSButton
        )
        exportButton.performClick(nil as Any?)

        let exported = try String(contentsOf: destinationURL, encoding: .utf8)
        XCTAssertTrue(exported.contains("[已隐藏凭据]"))
        XCTAssertFalse(exported.localizedCaseInsensitiveContains("password"))
        XCTAssertFalse(exported.contains("hunter2"))
        XCTAssertFalse(exported.contains("live-key"))
        XCTAssertFalse(exported.contains("/Users/alice/.ssh/id_ed25519"))
    }

    func testExportDiagnosticsIncludesImportReportsWithoutSecrets() throws {
        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: destinationURL) }
        let exporter = RecordingDiagnosticsExportPresenter(destinationURL: destinationURL)
        let store = RecordingImportReportListing(reports: [
            ImportReport(
                id: "report_export",
                sourceType: "legacy_ini",
                sourceName: "Legacy INI Sessions.ini",
                status: "partial",
                importedCount: 3,
                skippedCount: 1,
                failedCount: 0,
                issues: ["password hunter2 secret-token ignored"],
                createdAt: "2026-05-30T12:45:00Z"
            )
        ])
        let controller = DiagnosticsViewController(exportPresenter: exporter, importReportStore: store)

        controller.loadView()
        let exportButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Diagnostics.export") as? NSButton
        )
        exportButton.performClick(nil as Any?)

        let exported = try String(contentsOf: destinationURL, encoding: .utf8)
        XCTAssertEqual(store.requestedLimits, [20, 20])
        XCTAssertTrue(exported.contains(#""importReports" : ["#))
        XCTAssertTrue(exported.contains(#""sourceName" : "Legacy INI Sessions.ini""#))
        XCTAssertTrue(exported.contains(#""importedCount" : 3"#))
        XCTAssertTrue(exported.contains(#""skippedCount" : 1"#))
        XCTAssertTrue(exported.contains("[已隐藏凭据]"))
        XCTAssertFalse(exported.lowercased().contains("password"))
        XCTAssertFalse(exported.lowercased().contains("secret-token"))
        XCTAssertFalse(exported.contains("hunter2"))
    }

    func testExportDiagnosticsRedactsImportReportTokenKeyValuePairs() throws {
        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: destinationURL) }
        let exporter = RecordingDiagnosticsExportPresenter(destinationURL: destinationURL)
        let store = RecordingImportReportListing(reports: [
            ImportReport(
                id: "report_token",
                sourceType: "csv",
                sourceName: "sessions.csv",
                status: "partial",
                importedCount: 0,
                skippedCount: 1,
                failedCount: 0,
                issues: ["skipped token=hunter2 api_key=live-key token = spaced-token api_key : spaced-key"],
                createdAt: "2026-05-31T09:00:00Z"
            )
        ])
        let controller = DiagnosticsViewController(exportPresenter: exporter, importReportStore: store)

        controller.loadView()
        let exportButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Diagnostics.export") as? NSButton
        )
        exportButton.performClick(nil as Any?)

        let exported = try String(contentsOf: destinationURL, encoding: .utf8)
        XCTAssertTrue(exported.contains("[已隐藏凭据]"))
        XCTAssertFalse(exported.contains("token=hunter2"))
        XCTAssertFalse(exported.contains("api_key=live-key"))
        XCTAssertFalse(exported.contains("hunter2"))
        XCTAssertFalse(exported.contains("live-key"))
        XCTAssertFalse(exported.contains("spaced-token"))
        XCTAssertFalse(exported.contains("spaced-key"))
    }

    func testInspectorDiagnosticsTabHostsDiagnosticsController() {
        let inspector = InspectorViewController(transferHistoryStore: NoOpSCPTransferHistoryStore())

        inspector.loadView()

        XCTAssertNotNil(inspector.diagnosticsViewController)
        XCTAssertEqual(inspector.sectionLabelsForTesting, ["文件", "隧道", "浏览器", "诊断", "宏", "历史命令", "AI"])
        XCTAssertEqual(inspector.sectionControlForTesting.segmentCount, inspector.sectionLabelsForTesting.count)
        XCTAssertEqual(inspector.sectionControlForTesting.selectedSegment, 0)
    }

    func testInspectorDiagnosticsTabPassesAuditStoreToDiagnosticsController() throws {
        let store = RecordingMultiExecAuditListing(records: [
            BroadcastAuditRecord(
                id: "audit_inspector",
                traceId: "trace_inspector",
                targetCount: 1,
                sentCount: 1,
                failedCount: 0,
                redactedInput: "whoami",
                executed: true,
                createdAt: "2026-05-30T11:00:00Z"
            )
        ])
        let inspector = InspectorViewController(
            transferHistoryStore: NoOpSCPTransferHistoryStore(),
            multiExecAuditStore: store
        )

        inspector.loadView()
        let diagnostics = try XCTUnwrap(inspector.diagnosticsViewController)
        diagnostics.loadView()
        XCTAssertEqual(store.requestedLimits, [20])
        XCTAssertTrue(diagnostics.visibleTextSnapshot.contains("2026-05-30T11:00:00Z"))
        XCTAssertTrue(diagnostics.visibleTextSnapshot.contains("whoami"))
    }

    func testInspectorDiagnosticsTabPassesSettingsStoreToDiagnosticsController() throws {
        let suiteName = "StacioInspectorDiagnosticsSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = AppSettingsStore(defaults: defaults)
        settingsStore.update { settings in
            settings.diagnosticsAuditExportLimit = 42
        }
        let store = RecordingMultiExecAuditListing(records: [])
        let inspector = InspectorViewController(
            transferHistoryStore: NoOpSCPTransferHistoryStore(),
            multiExecAuditStore: store,
            settingsStore: settingsStore
        )

        inspector.loadView()
        let diagnostics = try XCTUnwrap(inspector.diagnosticsViewController)
        diagnostics.loadView()
        XCTAssertEqual(store.requestedLimits, [42])
    }

    func testInspectorDiagnosticsTabShowsRecentImportReportsFromInjectedStoreWithoutSecrets() throws {
        let store = RecordingImportReportListing(reports: [
            ImportReport(
                id: "report_recent",
                sourceType: "csv",
                sourceName: "sessions.csv",
                status: "partial",
                importedCount: 2,
                skippedCount: 1,
                failedCount: 1,
                issues: [
                    "API skipped because a session with the same name exists",
                    "password hunter2 secret-token ignored"
                ],
                createdAt: "2026-05-30T12:30:00Z"
            )
        ])
        let inspector = InspectorViewController(
            transferHistoryStore: NoOpSCPTransferHistoryStore(),
            importReportStore: store
        )

        inspector.loadView()
        let diagnosticsIndex = try XCTUnwrap(inspector.sectionLabelsForTesting.firstIndex(of: L10n.Inspector.logs))
        inspector.selectSectionForTesting(diagnosticsIndex)
        let diagnostics = try XCTUnwrap(inspector.diagnosticsViewController)

        let snapshot = diagnostics.visibleTextSnapshot
        XCTAssertEqual(store.requestedLimits, [20])
        XCTAssertTrue(snapshot.contains("导入报告"))
        XCTAssertTrue(snapshot.contains("sessions.csv"))
        XCTAssertTrue(snapshot.contains("partial"))
        XCTAssertTrue(snapshot.contains("已导入 2 / 已跳过 1 / 失败 1"))
        XCTAssertTrue(snapshot.contains("API skipped"))
        XCTAssertFalse(snapshot.lowercased().contains("password"))
        XCTAssertFalse(snapshot.lowercased().contains("secret-token"))
        XCTAssertFalse(snapshot.contains("hunter2"))
    }

    func testDiagnosticsPanelShowsWarningWhenImportReportRefreshFails() throws {
        let store = RecordingImportReportListing(
            error: StoreRefreshError(message: "bridge failed token live-key at ~/.ssh/config")
        )
        let controller = DiagnosticsViewController(importReportStore: store)

        controller.loadView()
        let refreshButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Diagnostics.importReportRefresh") as? NSButton
        )
        refreshButton.performClick(nil as Any?)

        let snapshot = controller.visibleTextSnapshot
        XCTAssertEqual(store.requestedLimits, [20, 20])
        XCTAssertTrue(snapshot.contains("无法读取导入报告"))
        XCTAssertTrue(snapshot.contains("bridge failed"))
        XCTAssertTrue(snapshot.contains("[已隐藏凭据]"))
        XCTAssertTrue(snapshot.contains("[已隐藏路径]"))
        XCTAssertFalse(snapshot.lowercased().contains("token"))
        XCTAssertFalse(snapshot.contains("live-key"))
        XCTAssertFalse(snapshot.contains("~/.ssh/config"))
    }

    func testDiagnosticsPanelShowsRecentAppLogsAndExportsThem() throws {
        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: destinationURL) }
        let exporter = RecordingDiagnosticsExportPresenter(destinationURL: destinationURL)
        let logStore = RecordingDiagnosticsLogStore(lines: [
            "2026-06-02T21:51:49Z [INFO] [Files] file.open.request path=/srv/app/config.json",
            "2026-06-02T21:52:03Z [ERROR] [VNC] viewer failed [已隐藏凭据]"
        ])
        let controller = DiagnosticsViewController(
            exportPresenter: exporter,
            appLogStore: logStore
        )

        controller.loadView()
        let refreshButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Diagnostics.appLogRefresh") as? NSButton
        )
        refreshButton.performClick(nil as Any?)

        let snapshot = controller.visibleTextSnapshot
        XCTAssertEqual(logStore.requestedLimits, [200, 200])
        XCTAssertTrue(snapshot.contains("应用日志"))
        XCTAssertTrue(snapshot.contains("file.open.request"))
        XCTAssertTrue(snapshot.contains("viewer failed"))
        XCTAssertTrue(snapshot.contains("[已隐藏凭据]"))

        let exportButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Diagnostics.export") as? NSButton
        )
        exportButton.performClick(nil as Any?)

        let exported = try String(contentsOf: destinationURL, encoding: .utf8)
        XCTAssertTrue(exported.contains(#""appLogs" : ["#))
        XCTAssertTrue(exported.contains("file.open.request"))
        XCTAssertTrue(exported.contains("viewer failed"))
    }

    func testDiagnosticsAppLogFiltersByKeywordAndLevelWithoutRequeryingStore() throws {
        let logStore = RecordingDiagnosticsLogStore(lines: [
            "2026-06-02T21:51:49Z [INFO] [Files] file.open.request path=/srv/app/config.json",
            "2026-06-02T21:52:03Z [ERROR] [VNC] viewer failed",
            "2026-06-02T21:52:04Z [DEBUG] [Terminal] verbose polling",
            "2026-06-02T21:52:05Z [WARNING] [Files] retry scheduled"
        ])
        let controller = DiagnosticsViewController(appLogStore: logStore)

        controller.loadView()
        let searchField = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Diagnostics.appLogSearch") as? NSSearchField
        )
        let levelPopup = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Diagnostics.appLogLevel") as? NSPopUpButton
        )

        XCTAssertEqual(logStore.requestedLimits, [200])

        searchField.stringValue = "VIEWER"
        searchField.sendAction(searchField.action, to: searchField.target)

        XCTAssertEqual(logStore.requestedLimits, [200])
        XCTAssertTrue(controller.visibleTextSnapshot.contains("viewer failed"))
        XCTAssertFalse(controller.visibleTextSnapshot.contains("file.open.request"))
        XCTAssertFalse(controller.visibleTextSnapshot.contains("verbose polling"))
        XCTAssertFalse(controller.visibleTextSnapshot.contains("retry scheduled"))

        levelPopup.selectItem(withTitle: "ERROR")
        levelPopup.sendAction(levelPopup.action, to: levelPopup.target)

        XCTAssertEqual(logStore.requestedLimits, [200])
        XCTAssertTrue(controller.visibleTextSnapshot.contains("viewer failed"))

        searchField.stringValue = "file"
        searchField.sendAction(searchField.action, to: searchField.target)

        XCTAssertEqual(logStore.requestedLimits, [200])
        XCTAssertFalse(controller.visibleTextSnapshot.contains("file.open.request"))
        XCTAssertFalse(controller.visibleTextSnapshot.contains("viewer failed"))
    }

    func testDiagnosticsAppLogColorsOnlyLevelLabels() throws {
        let logStore = RecordingDiagnosticsLogStore(lines: [
            "2026-06-02T21:52:03Z [ERROR] [VNC] viewer failed",
            "2026-06-02T21:52:04Z [WARNING] [Files] retry scheduled",
            "2026-06-02T21:52:05Z [DEBUG] [Terminal] verbose polling",
            "2026-06-02T21:52:06Z [INFO] [Files] file.open.request"
        ])
        let controller = DiagnosticsViewController(appLogStore: logStore)

        controller.loadView()

        let textView = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Diagnostics.appLogText") as? NSTextView
        )
        let text = textView.string as NSString
        let errorRange = text.range(of: "[ERROR]")
        let warningRange = text.range(of: "[WARNING]")
        let debugRange = text.range(of: "[DEBUG]")
        let bodyRange = text.range(of: "viewer failed")

        XCTAssertNotEqual(errorRange.location, NSNotFound)
        XCTAssertNotEqual(warningRange.location, NSNotFound)
        XCTAssertNotEqual(debugRange.location, NSNotFound)
        XCTAssertNotEqual(bodyRange.location, NSNotFound)
        XCTAssertEqual(
            textView.textStorage?.attribute(.foregroundColor, at: errorRange.location, effectiveRange: nil) as? NSColor,
            StacioDesignSystem.theme.dangerColor
        )
        XCTAssertEqual(
            textView.textStorage?.attribute(.foregroundColor, at: warningRange.location, effectiveRange: nil) as? NSColor,
            StacioDesignSystem.theme.warningColor
        )
        XCTAssertEqual(
            textView.textStorage?.attribute(.foregroundColor, at: debugRange.location, effectiveRange: nil) as? NSColor,
            StacioDesignSystem.theme.secondaryTextColor
        )
        XCTAssertEqual(
            textView.textStorage?.attribute(.foregroundColor, at: bodyRange.location, effectiveRange: nil) as? NSColor,
            StacioDesignSystem.theme.primaryTextColor
        )
        XCTAssertTrue(textView.isSelectable)
        XCTAssertFalse(textView.isEditable)
    }

    func testExportVisibleAppLogsWritesFilteredPlainTextWithoutRequeryingStore() throws {
        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("txt")
        defer { try? FileManager.default.removeItem(at: destinationURL) }
        let exporter = RecordingDiagnosticsExportPresenter(destinationURL: destinationURL)
        let logStore = RecordingDiagnosticsLogStore(lines: [
            "2026-06-02T21:51:49Z [INFO] [Files] file.open.request path=/srv/app/config.json",
            "2026-06-02T21:52:03Z [ERROR] [VNC] viewer failed [已隐藏凭据]",
            "2026-06-02T21:52:04Z [DEBUG] [Terminal] verbose polling"
        ])
        let controller = DiagnosticsViewController(
            exportPresenter: exporter,
            appLogStore: logStore
        )

        controller.loadView()
        controller.replaceBundle(sessionID: "session/export:logs", tunnelID: nil, entries: [])
        let searchField = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Diagnostics.appLogSearch") as? NSSearchField
        )
        let levelPopup = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Diagnostics.appLogLevel") as? NSPopUpButton
        )
        let exportButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Diagnostics.appLogExport") as? NSButton
        )

        searchField.stringValue = "viewer"
        searchField.sendAction(searchField.action, to: searchField.target)
        levelPopup.selectItem(withTitle: "ERROR")
        levelPopup.sendAction(levelPopup.action, to: levelPopup.target)
        exportButton.performClick(nil as Any?)

        XCTAssertEqual(logStore.requestedLimits, [200])
        XCTAssertEqual(exporter.suggestedNames.count, 1)
        XCTAssertTrue(exporter.suggestedNames[0].hasPrefix("stacio-log-session_export_logs-"))
        XCTAssertTrue(exporter.suggestedNames[0].hasSuffix(".txt"))
        XCTAssertEqual(exporter.completedURLs, [destinationURL])

        let exported = try String(contentsOf: destinationURL, encoding: .utf8)
        XCTAssertEqual(exported, "2026-06-02T21:52:03Z ERROR [VNC] viewer failed [已隐藏凭据]\n")
    }

    func testClearAppLogsOnlyClearsPanelAndFollowLatestTracksUserScroll() throws {
        let logStore = RecordingDiagnosticsLogStore(lines: [
            "2026-06-02T21:51:49Z [INFO] [Files] file.open.request"
        ])
        let controller = DiagnosticsViewController(appLogStore: logStore)

        controller.loadView()
        let clearButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Diagnostics.appLogClear") as? NSButton
        )
        let followButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Diagnostics.appLogFollowLatest") as? NSButton
        )
        let scrollView = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Diagnostics.appLogScrollView") as? NSScrollView
        )

        XCTAssertTrue(controller.visibleTextSnapshot.contains("file.open.request"))
        XCTAssertEqual(logStore.requestedLimits, [200])

        clearButton.performClick(nil as Any?)

        XCTAssertEqual(logStore.requestedLimits, [200])
        XCTAssertFalse(controller.visibleTextSnapshot.contains("file.open.request"))

        followButton.performClick(nil as Any?)
        XCTAssertFalse(controller.isFollowingLatestAppLogsForTesting)
        XCTAssertEqual(followButton.state, .off)

        scrollView.frame = NSRect(x: 0, y: 0, width: 240, height: 100)
        scrollView.contentView.frame = scrollView.bounds
        scrollView.documentView?.setFrameSize(NSSize(width: 240, height: 400))
        scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: 300))
        NotificationCenter.default.post(
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        XCTAssertTrue(controller.isFollowingLatestAppLogsForTesting)
        XCTAssertEqual(followButton.state, .on)

        scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: 0))
        NotificationCenter.default.post(
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        XCTAssertFalse(controller.isFollowingLatestAppLogsForTesting)
        XCTAssertEqual(followButton.state, .off)
    }
}

private final class RecordingDiagnosticsExportPresenter: DiagnosticsExportPresenting {
    var suggestedNames: [String] = []
    var requestedContentTypes: [[UTType]] = []
    var completedURLs: [URL] = []
    private let destinationURL: URL?

    init(destinationURL: URL?) {
        self.destinationURL = destinationURL
    }

    func chooseExportDestination(
        suggestedName: String,
        allowedContentTypes: [UTType],
        parentWindow: NSWindow?
    ) -> URL? {
        suggestedNames.append(suggestedName)
        requestedContentTypes.append(allowedContentTypes)
        return destinationURL
    }

    func presentExportComplete(destinationURL: URL, parentWindow: NSWindow?) {
        completedURLs.append(destinationURL)
    }
}

private final class FakePortProbe: PortProbing {
    private let result: PortProbeResult
    private(set) var requests: [PortProbeRequest] = []

    init(result: PortProbeResult) {
        self.result = result
    }

    @MainActor
    func checkPort(host: String, port: UInt16, completion: @escaping @MainActor (PortProbeResult) -> Void) {
        requests.append(PortProbeRequest(host: host, port: port))
        completion(result)
    }
}

private final class RecordingMultiExecAuditListing: MultiExecAuditListing {
    let records: [BroadcastAuditRecord]
    let error: Error?
    var requestedLimits: [UInt32] = []

    init(records: [BroadcastAuditRecord] = [], error: Error? = nil) {
        self.records = records
        self.error = error
    }

    func listBroadcastAuditRecords(limit: UInt32) throws -> [BroadcastAuditRecord] {
        requestedLimits.append(limit)
        if let error {
            throw error
        }
        return records
    }
}

private final class RecordingAgentActionAuditListing: AgentActionAuditListing {
    let records: [AgentActionAuditRecord]
    let error: Error?
    var requestedLimits: [UInt32] = []

    init(records: [AgentActionAuditRecord] = [], error: Error? = nil) {
        self.records = records
        self.error = error
    }

    func listAgentActionEvents(limit: UInt32) throws -> [AgentActionAuditRecord] {
        requestedLimits.append(limit)
        if let error {
            throw error
        }
        return records
    }
}

private final class RecordingImportReportListing: ImportReportListing {
    let reports: [ImportReport]
    let error: Error?
    var requestedLimits: [UInt32] = []

    init(reports: [ImportReport] = [], error: Error? = nil) {
        self.reports = reports
        self.error = error
    }

    func listImportReports(limit: UInt32) throws -> [ImportReport] {
        requestedLimits.append(limit)
        if let error {
            throw error
        }
        return reports
    }
}

private final class RecordingDiagnosticsLogStore: StacioLogReading {
    let lines: [String]
    var requestedLimits: [Int] = []

    init(lines: [String]) {
        self.lines = lines
    }

    func recentLines(limit: Int) throws -> [String] {
        requestedLimits.append(limit)
        return Array(lines.suffix(max(0, limit)))
    }
}

private struct StoreRefreshError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

private struct PortProbeRequest: Equatable {
    let host: String
    let port: UInt16
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
