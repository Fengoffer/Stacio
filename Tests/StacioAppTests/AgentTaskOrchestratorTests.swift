import StacioAgentBridge
import XCTest
@testable import StacioApp

@MainActor
final class AgentTaskOrchestratorTests: XCTestCase {
    func testOperationalDomainClassifierSelectsRelevantCapabilityProfiles() {
        XCTAssertEqual(AgentOperationalDomainClassifier.domains(for: "排查 Kubernetes 中 PostgreSQL 连接超时"), [.kubernetes, .database])
        XCTAssertEqual(AgentOperationalDomainClassifier.domains(for: "部署 Docker Compose 应用并检查健康接口"), [.application, .container, .deployment])
        XCTAssertEqual(AgentOperationalDomainClassifier.domains(for: "检查服务器 CPU、磁盘和网络端口"), [.host, .network])
        XCTAssertEqual(AgentOperationalDomainClassifier.domains(for: "检查 nginx TLS 证书和访问日志"), [.web, .security, .logs])
    }

    func testBackupPolicyRecognizesConfigurationAndDeploymentMutations() {
        XCTAssertTrue(AgentBackupPolicy.requiresBackup(command: "sudo sed -i 's/80/8080/' /etc/nginx/nginx.conf"))
        XCTAssertTrue(AgentBackupPolicy.requiresBackup(command: "systemctl restart nginx"))
        XCTAssertTrue(AgentBackupPolicy.requiresBackup(command: "docker compose up -d"))
        XCTAssertTrue(AgentBackupPolicy.requiresBackup(command: "kubectl apply -f deployment.yaml"))
        XCTAssertTrue(AgentBackupPolicy.requiresBackup(command: "psql app -f migration.sql"))
        XCTAssertFalse(AgentBackupPolicy.requiresBackup(command: "cat /etc/nginx/nginx.conf"))
        XCTAssertFalse(AgentBackupPolicy.requiresBackup(command: "systemctl status nginx"))
    }

    func testBackupPolicyRequiresSuccessfulBackupWithExplicitPath() {
        let valid = AgentTaskStepResult(
            requestID: "backup-1",
            command: "cp -a /etc/nginx/nginx.conf /var/backups/stacio/nginx.conf.20260721-120000",
            intent: "备份配置",
            state: .completed,
            events: [],
            observation: "/var/backups/stacio/nginx.conf.20260721-120000"
        )
        let failed = AgentTaskStepResult(
            requestID: "backup-2",
            command: "cp -a /etc/nginx/nginx.conf /var/backups/stacio/nginx.conf.failed",
            intent: "备份配置",
            state: .failed,
            events: [],
            observation: "permission denied"
        )
        let noEvidence = AgentTaskStepResult(
            requestID: "backup-3",
            command: "cp -a /etc/nginx/nginx.conf /var/backups/stacio/nginx.conf.no-evidence",
            intent: "备份配置",
            state: .completed,
            events: [],
            observation: "command completed"
        )

        XCTAssertEqual(
            AgentBackupPolicy.latestVerifiedBackup(in: [valid])?.path,
            "/var/backups/stacio/nginx.conf.20260721-120000"
        )
        XCTAssertNil(AgentBackupPolicy.latestVerifiedBackup(in: [failed]))
        XCTAssertNil(AgentBackupPolicy.latestVerifiedBackup(in: [noEvidence]))

        let databaseBackup = AgentTaskStepResult(
            requestID: "backup-4",
            command: "pg_dump app > /tmp/app-20260721.sql",
            intent: "备份数据库",
            state: .completed,
            events: [],
            observation: "verified /tmp/app-20260721.sql"
        )
        XCTAssertEqual(AgentBackupPolicy.latestVerifiedBackup(in: [databaseBackup])?.path, "/tmp/app-20260721.sql")

        let mutation = AgentTaskStepResult(
            requestID: "mutation-1",
            command: "systemctl restart nginx",
            intent: "重启服务",
            state: .completed,
            events: [],
            observation: "restarted"
        )
        XCTAssertNil(AgentBackupPolicy.verifiedBackupForNextMutation(in: [valid, mutation]))
        XCTAssertEqual(AgentBackupPolicy.verifiedBackupForNextMutation(in: [mutation, valid])?.path, valid.observation)

        let rollback = AgentTaskStepResult(
            requestID: "rollback-1",
            command: "cp -a /var/backups/stacio/nginx.conf.20260721-120000 /etc/nginx/nginx.conf",
            intent: "恢复配置",
            state: .completed,
            events: [],
            observation: "restored /etc/nginx/nginx.conf"
        )
        XCTAssertEqual(AgentBackupPolicy.latestVerifiedBackup(in: [valid, rollback])?.path, valid.observation)
    }

    func testAutonomousLoopBlocksMutationUntilVerifiedBackupCompletes() async throws {
        let mutation = "systemctl restart nginx"
        let backup = "cp -a /etc/nginx/nginx.conf /var/backups/stacio/nginx.conf.20260721-120000"
        let verification = "systemctl is-active nginx"
        let provider = SequencedAgentTaskProvider(responses: [
            AIAssistantResponse(
                message: "重启服务使配置生效。",
                commandProposals: [AgentCommandProposal(command: mutation, explanation: "重启 nginx。", risk: .write)]
            ),
            AIAssistantResponse(
                message: "先创建配置备份。",
                commandProposals: [AgentCommandProposal(command: backup, explanation: "备份 nginx 配置。", risk: .write)]
            ),
            AIAssistantResponse(
                message: "备份已验证，继续重启。",
                commandProposals: [AgentCommandProposal(command: mutation, explanation: "重启 nginx。", risk: .write)]
            ),
            AIAssistantResponse(
                message: "执行状态验证。",
                commandProposals: [AgentCommandProposal(command: verification, explanation: "验证 nginx 状态。", risk: .readOnly)]
            ),
            AIAssistantResponse(
                message: "## 结果\n\n变更完成。\n\n## 备份与回滚\n\n备份位置：`/var/backups/stacio/nginx.conf.20260721-120000`。验证结果：服务为 active。可使用该备份回滚。",
                commandProposals: []
            )
        ])
        let execution = RequestRoutedAgentCommandExecutor(eventsByCommand: [
            backup: [AgentTraceEvent(
                requestID: "ignored",
                state: .completed,
                message: "备份完成",
                redactedCommand: backup,
                metadata: ["terminalOutputSummary": "/var/backups/stacio/nginx.conf.20260721-120000"]
            )],
            mutation: [AgentTraceEvent(
                requestID: "ignored",
                state: .completed,
                message: "nginx restarted",
                redactedCommand: mutation,
                metadata: ["terminalOutputSummary": "nginx restarted"]
            )],
            verification: [AgentTraceEvent(
                requestID: "ignored",
                state: .completed,
                message: "active",
                redactedCommand: verification,
                metadata: ["terminalOutputSummary": "active"]
            )]
        ])
        let orchestrator = AgentTaskOrchestrator(
            coordinator: AIAssistantCoordinator(provider: provider, executionCoordinator: execution),
            limits: AgentTaskLoopLimits(maxSteps: 4, maxDuration: 60)
        )

        let result = try await orchestrator.run(
            goal: "更新 nginx 配置并重启",
            context: AITerminalContext(runtimeID: "term_1", title: "prod", currentDirectory: "/srv/app", recentTranscript: "")
        )

        XCTAssertEqual(execution.commands, [backup, mutation, verification])
        XCTAssertTrue(provider.requests[1].question.contains("禁止执行该变更"))
        XCTAssertTrue(provider.requests[3].question.contains("备份位置：/var/backups/stacio/nginx.conf.20260721-120000"))
        XCTAssertTrue(provider.requests[3].question.contains("备份与回滚"))
        XCTAssertEqual(result.state, .completed)
    }

    func testVerificationPolicyRecognizesOperationalHealthChecks() {
        XCTAssertTrue(AgentVerificationPolicy.isVerificationCommand("systemctl is-active nginx"))
        XCTAssertTrue(AgentVerificationPolicy.isVerificationCommand("nginx -t"))
        XCTAssertTrue(AgentVerificationPolicy.isVerificationCommand("docker compose ps"))
        XCTAssertTrue(AgentVerificationPolicy.isVerificationCommand("kubectl rollout status deployment/api"))
        XCTAssertTrue(AgentVerificationPolicy.isVerificationCommand("curl -fsS http://127.0.0.1:8080/health"))
        XCTAssertTrue(AgentVerificationPolicy.isVerificationCommand("psql app -c 'select 1'"))
        XCTAssertFalse(AgentVerificationPolicy.isVerificationCommand("pwd"))
        XCTAssertFalse(AgentVerificationPolicy.isVerificationCommand("systemctl restart nginx"))
    }

    func testFinalReportPolicyRequiresBackupPathRollbackAndVerificationForMutations() {
        let steps = [AgentTaskStepResult(
            requestID: "backup",
            command: "cp -a /etc/nginx/nginx.conf /var/backups/stacio/nginx.conf.20260721",
            intent: "备份",
            state: .completed,
            events: [],
            observation: "/var/backups/stacio/nginx.conf.20260721"
        ), AgentTaskStepResult(
            requestID: "mutation",
            command: "systemctl restart nginx",
            intent: "重启",
            state: .completed,
            events: [],
            observation: "restarted"
        ), AgentTaskStepResult(
            requestID: "verify",
            command: "systemctl is-active nginx",
            intent: "验证",
            state: .completed,
            events: [],
            observation: "active"
        )]

        XCTAssertFalse(AgentFinalReportPolicy.isCompliant(message: "nginx 已恢复。", steps: steps))
        XCTAssertTrue(AgentFinalReportPolicy.isCompliant(
            message: "## 备份与回滚\n\n备份位置：`/var/backups/stacio/nginx.conf.20260721`。验证结果：nginx 为 active。可使用该备份回滚。",
            steps: steps
        ))
    }

    func testAutonomousLoopRequiresVerificationEvidenceAfterMutationBeforeCompletion() async throws {
        let backup = "cp -a /etc/nginx/nginx.conf /var/backups/stacio/nginx.conf.20260721-130000"
        let mutation = "systemctl restart nginx"
        let verification = "systemctl is-active nginx"
        let provider = SequencedAgentTaskProvider(responses: [
            AIAssistantResponse(
                message: "先备份。",
                commandProposals: [AgentCommandProposal(command: backup, explanation: "备份配置。", risk: .write)]
            ),
            AIAssistantResponse(
                message: "执行重启。",
                commandProposals: [AgentCommandProposal(command: mutation, explanation: "重启 nginx。", risk: .write)]
            ),
            AIAssistantResponse(message: "变更完成。", commandProposals: []),
            AIAssistantResponse(
                message: "验证服务状态。",
                commandProposals: [AgentCommandProposal(command: verification, explanation: "确认 nginx 正常运行。", risk: .readOnly)]
            ),
            AIAssistantResponse(
                message: "## 结果\n\nnginx 已恢复运行。\n\n## 备份与回滚\n\n备份位置：`/var/backups/stacio/nginx.conf.20260721-130000`。验证结果：服务为 active。可使用该备份回滚。",
                commandProposals: []
            )
        ])
        let execution = RequestRoutedAgentCommandExecutor(eventsByCommand: [
            backup: [AgentTraceEvent(
                requestID: "ignored",
                state: .completed,
                message: "backup complete",
                redactedCommand: backup,
                metadata: ["terminalOutputSummary": "/var/backups/stacio/nginx.conf.20260721-130000"]
            )],
            mutation: [AgentTraceEvent(
                requestID: "ignored",
                state: .completed,
                message: "restarted",
                redactedCommand: mutation,
                metadata: ["terminalOutputSummary": "restarted"]
            )],
            verification: [AgentTraceEvent(
                requestID: "ignored",
                state: .completed,
                message: "active",
                redactedCommand: verification,
                metadata: ["terminalOutputSummary": "active"]
            )]
        ])
        let orchestrator = AgentTaskOrchestrator(
            coordinator: AIAssistantCoordinator(provider: provider, executionCoordinator: execution),
            limits: AgentTaskLoopLimits(maxSteps: 5, maxDuration: 60)
        )

        let result = try await orchestrator.run(
            goal: "重启 nginx 并确认服务正常",
            context: AITerminalContext(runtimeID: "term_1", title: "prod", currentDirectory: "/srv/app", recentTranscript: "")
        )

        XCTAssertEqual(execution.commands, [backup, mutation, verification])
        XCTAssertTrue(provider.requests[3].question.contains("变更后验证门禁"))
        XCTAssertEqual(result.state, .completed)
    }

    func testAutonomousLoopRequestsRollbackWhenPostChangeVerificationFails() async throws {
        let backup = "cp -a /etc/nginx/nginx.conf /var/backups/stacio/nginx.conf.20260721-140000"
        let mutation = "systemctl restart nginx"
        let verification = "systemctl is-active nginx"
        let rollback = "cp -a /var/backups/stacio/nginx.conf.20260721-140000 /etc/nginx/nginx.conf"
        let provider = SequencedAgentTaskProvider(responses: [
            AIAssistantResponse(message: "创建备份。", commandProposals: [AgentCommandProposal(command: backup, explanation: "备份配置。", risk: .write)]),
            AIAssistantResponse(message: "重启服务。", commandProposals: [AgentCommandProposal(command: mutation, explanation: "重启 nginx。", risk: .write)]),
            AIAssistantResponse(message: "验证服务。", commandProposals: [AgentCommandProposal(command: verification, explanation: "检查状态。", risk: .readOnly)]),
            AIAssistantResponse(message: "验证失败，恢复备份。", commandProposals: [AgentCommandProposal(command: rollback, explanation: "从备份恢复配置。", risk: .write)]),
            AIAssistantResponse(message: "验证回滚结果。", commandProposals: [AgentCommandProposal(command: verification, explanation: "再次检查状态。", risk: .readOnly)]),
            AIAssistantResponse(
                message: "## 结果\n\n变更验证失败，已回滚。\n\n## 备份与回滚\n\n备份位置：`/var/backups/stacio/nginx.conf.20260721-140000`。回滚结果：已恢复。验证结果：服务为 active。",
                commandProposals: []
            )
        ])
        let execution = SequentialOutcomeAgentCommandExecutor(outcomes: [
            backup: [.completed("/var/backups/stacio/nginx.conf.20260721-140000")],
            mutation: [.completed("restarted")],
            verification: [.failed("inactive"), .completed("active")],
            rollback: [.completed("restored")]
        ])
        let orchestrator = AgentTaskOrchestrator(
            coordinator: AIAssistantCoordinator(provider: provider, executionCoordinator: execution),
            limits: AgentTaskLoopLimits(maxSteps: 7, maxDuration: 60)
        )

        let result = try await orchestrator.run(
            goal: "更新 nginx 并确保失败时恢复",
            context: AITerminalContext(runtimeID: "term_1", title: "prod", currentDirectory: "/srv/app", recentTranscript: "")
        )

        XCTAssertEqual(execution.commands, [backup, mutation, verification, rollback, verification])
        XCTAssertTrue(provider.requests[3].question.contains("进入回滚流程"))
        XCTAssertEqual(result.state, .completed)
    }

    func testDefaultLoopLimitsAllowLongerStepwiseDiagnostics() {
        let limits = AgentTaskLoopLimits()

        XCTAssertEqual(limits.maxSteps, 20)
        XCTAssertEqual(limits.maxDuration, 1_200)
    }

    func testAutonomousLoopFeedsObservedOutputBackIntoNextModelRequest() async throws {
        let provider = SequencedAgentTaskProvider(responses: [
            AIAssistantResponse(
                message: "先看负载。",
                commandProposals: [
                    AgentCommandProposal(command: "uptime", explanation: "查看负载。", risk: .readOnly)
                ]
            ),
            AIAssistantResponse(
                message: "负载正常，任务完成。",
                commandProposals: []
            )
        ])
        let execution = RequestRoutedAgentCommandExecutor(eventsByCommand: [
            "uptime": [
                AgentTraceEvent(
                    requestID: "ignored",
                    state: .running,
                    message: "AI 独立任务输出：load average: 0.08",
                    redactedCommand: "uptime",
                    metadata: [
                        "executionMode": "backgroundTask",
                        "terminalOutputSummary": "load average: 0.08"
                    ]
                ),
                AgentTraceEvent(
                    requestID: "ignored",
                    state: .completed,
                    message: "AI 独立任务已完成：load average: 0.08",
                    redactedCommand: "uptime",
                    metadata: [
                        "executionMode": "backgroundTask",
                        "terminalOutputSummary": "load average: 0.08"
                    ]
                )
            ]
        ])
        let coordinator = AIAssistantCoordinator(provider: provider, executionCoordinator: execution)
        let orchestrator = AgentTaskOrchestrator(
            coordinator: coordinator,
            limits: AgentTaskLoopLimits(maxSteps: 3, maxDuration: 60)
        )
        let context = AITerminalContext(
            runtimeID: "term_1",
            title: "dev@example.com",
            currentDirectory: "/srv/app",
            recentTranscript: ""
        )
        var updates: [AgentTaskUpdate] = []

        let result = try await orchestrator.run(
            goal: "检查服务器负载是否正常",
            context: context,
            onUpdate: { updates.append($0) }
        )

        XCTAssertEqual(execution.commands, ["uptime"])
        XCTAssertEqual(provider.requests.count, 2)
        XCTAssertTrue(provider.requests[1].question.contains("load average: 0.08"))
        XCTAssertFalse(provider.requests[1].question.contains("默认使用 1 至 3 个短句"))
        XCTAssertTrue(provider.requests[1].question.contains("标准 Markdown 报告"))
        XCTAssertTrue(provider.requests[1].question.contains("至少包含结论、关键证据和风险/状态"))
        XCTAssertTrue(provider.requests[1].question.contains("适合表格时应主动使用 Markdown 表格"))
        XCTAssertTrue(provider.requests[0].question.contains("只能写“初步判断”和“待验证项”"))
        XCTAssertEqual(result.state, .completed)
        XCTAssertEqual(result.steps.count, 1)
        XCTAssertEqual(result.steps.first?.state, .completed)
        XCTAssertTrue(updates.contains { $0.kind == .thinking })
        XCTAssertEqual(
            updates.filter { $0.message == "负载正常，任务完成。" }.map(\.kind),
            [.completed]
        )
        XCTAssertTrue(updates.contains { $0.kind == .trace && $0.traceEvent?.state == .running })
        XCTAssertTrue(updates.contains { $0.kind == .completed })
    }

    func testAutonomousRunsUseDistinctRequestIDNamespaces() async throws {
        let provider = SequencedAgentTaskProvider(responses: [
            AIAssistantResponse(
                message: "执行第一轮。",
                commandProposals: [
                    AgentCommandProposal(command: "uptime", explanation: "查看负载。", risk: .readOnly)
                ]
            ),
            AIAssistantResponse(message: "第一轮完成。", commandProposals: []),
            AIAssistantResponse(
                message: "执行第二轮。",
                commandProposals: [
                    AgentCommandProposal(command: "uptime", explanation: "再次查看负载。", risk: .readOnly)
                ]
            ),
            AIAssistantResponse(message: "第二轮完成。", commandProposals: [])
        ])
        let execution = RequestRoutedAgentCommandExecutor(eventsByCommand: [
            "uptime": [
                AgentTraceEvent(
                    requestID: "ignored",
                    state: .completed,
                    message: "本次命令已完成：load average: 0.08",
                    redactedCommand: "uptime",
                    metadata: ["terminalOutputSummary": "load average: 0.08"]
                )
            ]
        ])
        let coordinator = AIAssistantCoordinator(provider: provider, executionCoordinator: execution)
        let orchestrator = AgentTaskOrchestrator(coordinator: coordinator)
        let context = AITerminalContext(
            runtimeID: "term_1",
            title: "dev@example.com",
            currentDirectory: "/srv/app",
            recentTranscript: ""
        )

        let firstResult = try await orchestrator.run(goal: "第一轮检查", context: context)
        let secondResult = try await orchestrator.run(goal: "第二轮检查", context: context)

        XCTAssertEqual(firstResult.state, .completed)
        XCTAssertEqual(secondResult.state, .completed)
        XCTAssertEqual(execution.requests.count, 2)
        let requestIDs = execution.requests.map(\.id)
        XCTAssertNotEqual(requestIDs[0], requestIDs[1])
        XCTAssertTrue(requestIDs.allSatisfy { $0.hasPrefix("agent-step-") })
        XCTAssertTrue(requestIDs.allSatisfy { $0.hasSuffix("-1") })
    }

    func testAutonomousLoopRefreshesMappedTerminalHistoryBeforeNextModelDecision() async throws {
        let provider = SequencedAgentTaskProvider(responses: [
            AIAssistantResponse(
                message: "先查看负载。",
                commandProposals: [
                    AgentCommandProposal(command: "uptime", explanation: "查看负载。", risk: .readOnly)
                ]
            ),
            AIAssistantResponse(message: "结合历史输出和本步结果，系统正常。", commandProposals: [])
        ])
        let execution = RequestRoutedAgentCommandExecutor(eventsByCommand: [
            "uptime": [
                AgentTraceEvent(
                    requestID: "ignored",
                    state: .completed,
                    message: "本次命令已完成：load average: 0.08",
                    redactedCommand: "uptime",
                    metadata: ["terminalOutputSummary": "load average: 0.08"]
                )
            ]
        ])
        let coordinator = AIAssistantCoordinator(provider: provider, executionCoordinator: execution)
        let orchestrator = AgentTaskOrchestrator(coordinator: coordinator)
        let initialContext = AITerminalContext(
            runtimeID: "term_1",
            title: "dev@example.com",
            currentDirectory: "/srv/app",
            recentTranscript: "old prompt"
        )
        var currentTranscript = "old prompt"

        let result = try await orchestrator.run(
            goal: "结合终端历史检查服务器",
            context: initialContext,
            contextProvider: {
                AITerminalContext(
                    runtimeID: "term_1",
                    title: "dev@example.com",
                    currentDirectory: "/srv/app",
                    recentTranscript: currentTranscript
                )
            },
            onUpdate: { update in
                if update.traceEvent?.state == .completed {
                    currentTranscript = "old prompt\nload average: 0.08\nroot@host:~#"
                }
            }
        )

        XCTAssertEqual(result.state, .completed)
        XCTAssertEqual(provider.requests.count, 2)
        XCTAssertTrue(provider.requests[1].context.recentTranscript.contains("root@host:~#"))
        XCTAssertTrue(provider.requests[1].question.contains("load average: 0.08"))
    }

    func testAutonomousLoopUsesOnlyLatestCumulativeTerminalOutputForObservation() async throws {
        let provider = SequencedAgentTaskProvider(responses: [
            AIAssistantResponse(
                message: "检查输出。",
                commandProposals: [AgentCommandProposal(command: "printf test", explanation: "执行检查。", risk: .readOnly)]
            ),
            AIAssistantResponse(message: "检查完成。", commandProposals: [])
        ])
        let execution = RequestRoutedAgentCommandExecutor(eventsByCommand: [
            "printf test": [
                AgentTraceEvent(
                    requestID: "ignored",
                    state: .waitingForOutput,
                    message: "输出更新",
                    redactedCommand: "printf test",
                    metadata: ["terminalOutputSummary": "line 1"]
                ),
                AgentTraceEvent(
                    requestID: "ignored",
                    state: .completed,
                    message: "已完成",
                    redactedCommand: "printf test",
                    metadata: ["terminalOutputSummary": "line 1\nline 2"]
                )
            ]
        ])
        let coordinator = AIAssistantCoordinator(provider: provider, executionCoordinator: execution)
        let orchestrator = AgentTaskOrchestrator(coordinator: coordinator)

        _ = try await orchestrator.run(
            goal: "检查输出",
            context: AITerminalContext(
                runtimeID: "term_1",
                title: "dev@example.com",
                currentDirectory: nil,
                recentTranscript: ""
            )
        )

        let nextQuestion = provider.requests[1].question
        XCTAssertTrue(nextQuestion.contains("观察：line 1 line 2"))
        XCTAssertFalse(nextQuestion.contains("观察：line 1 line 1 line 2"))
    }

    func testAutonomousLoopWaitsForAsynchronousBackgroundCompletion() async throws {
        let provider = SequencedAgentTaskProvider(responses: [
            AIAssistantResponse(
                message: "先读取系统负载。",
                commandProposals: [
                    AgentCommandProposal(command: "uptime", explanation: "查看负载。", risk: .readOnly)
                ]
            ),
            AIAssistantResponse(message: "负载正常，任务完成。", commandProposals: [])
        ])
        let execution = DelayedBackgroundAgentCommandExecutor()
        let coordinator = AIAssistantCoordinator(provider: provider, executionCoordinator: execution)
        let orchestrator = AgentTaskOrchestrator(
            coordinator: coordinator,
            limits: AgentTaskLoopLimits(maxSteps: 3, maxDuration: 60)
        )

        let result = try await orchestrator.run(
            goal: "检查服务器负载",
            context: AITerminalContext(
                runtimeID: "term_1",
                title: "dev@example.com",
                currentDirectory: "/srv/app",
                recentTranscript: ""
            )
        )

        XCTAssertEqual(result.state, .completed)
        XCTAssertEqual(result.steps.first?.state, .completed)
        XCTAssertEqual(provider.requests.count, 2)
        XCTAssertTrue(provider.requests[1].question.contains("load average: 0.04"))
    }

    func testCancellingAsynchronousBackgroundStepReleasesCompletionWait() async throws {
        let provider = SequencedAgentTaskProvider(responses: [
            AIAssistantResponse(
                message: "开始检查。",
                commandProposals: [
                    AgentCommandProposal(command: "uptime", explanation: "查看负载。", risk: .readOnly)
                ]
            )
        ])
        let execution = DelayedBackgroundAgentCommandExecutor(emitCompletion: false)
        let coordinator = AIAssistantCoordinator(provider: provider, executionCoordinator: execution)
        let orchestrator = AgentTaskOrchestrator(coordinator: coordinator)

        let result = try await orchestrator.run(
            goal: "检查服务器负载",
            context: AITerminalContext(
                runtimeID: "term_1",
                title: "dev@example.com",
                currentDirectory: "/srv/app",
                recentTranscript: ""
            ),
            onUpdate: { update in
                if update.traceEvent?.state == .running {
                    orchestrator.cancel()
                }
            }
        )

        XCTAssertEqual(result.state, .cancelled)
        XCTAssertEqual(result.steps.first?.state, .cancelled)
        XCTAssertEqual(execution.cancelledRequestIDs, execution.requestIDs)
    }

    func testInitialResponseOnlyRunsFirstCommandAndNextCommandComesFromObservedOutputRequest() async throws {
        let initialResponse = AIAssistantResponse(
            message: "先看负载，再看磁盘。",
            commandProposals: [
                AgentCommandProposal(command: "uptime", explanation: "查看负载。", risk: .readOnly),
                AgentCommandProposal(command: "df -h", explanation: "首轮计划里的第二条，不能直接执行。", risk: .readOnly)
            ]
        )
        let provider = SequencedAgentTaskProvider(responses: [
            AIAssistantResponse(
                message: "负载正常，改看进程。",
                commandProposals: [
                    AgentCommandProposal(command: "ps aux --sort=-%cpu | head -5", explanation: "根据负载结果查看进程。", risk: .readOnly)
                ]
            ),
            AIAssistantResponse(message: "进程正常，完成。", commandProposals: [])
        ])
        let execution = RequestRoutedAgentCommandExecutor(eventsByCommand: [
            "uptime": [
                AgentTraceEvent(
                    requestID: "ignored",
                    state: .completed,
                    message: "本次命令已完成：load average: 0.05",
                    redactedCommand: "uptime",
                    metadata: ["terminalOutputSummary": "load average: 0.05"]
                )
            ],
            "ps aux --sort=-%cpu | head -5": [
                AgentTraceEvent(
                    requestID: "ignored",
                    state: .completed,
                    message: "本次命令已完成：PID CPU COMMAND\n1 0.1 launchd",
                    redactedCommand: "ps aux --sort=-%cpu | head -5",
                    metadata: ["terminalOutputSummary": "PID CPU COMMAND\n1 0.1 launchd"]
                )
            ]
        ])
        let coordinator = AIAssistantCoordinator(provider: provider, executionCoordinator: execution)
        let orchestrator = AgentTaskOrchestrator(
            coordinator: coordinator,
            limits: AgentTaskLoopLimits(maxSteps: 4, maxDuration: 60)
        )

        let result = try await orchestrator.run(
            goal: "检查机器是否正常",
            context: AITerminalContext(
                runtimeID: "term_1",
                title: "dev@example.com",
                currentDirectory: "/srv/app",
                recentTranscript: ""
            ),
            initialResponse: initialResponse
        )

        XCTAssertEqual(execution.commands, ["uptime", "ps aux --sort=-%cpu | head -5"])
        XCTAssertFalse(execution.commands.contains("df -h"))
        XCTAssertEqual(provider.requests.count, 2)
        XCTAssertTrue(provider.requests[0].question.contains("load average: 0.05"))
        XCTAssertFalse(provider.requests[0].question.contains("df -h"))
        XCTAssertTrue(provider.requests[1].question.contains("PID CPU COMMAND"))
        XCTAssertEqual(result.state, .completed)
        XCTAssertEqual(result.steps.map(\.command), ["uptime", "ps aux --sort=-%cpu | head -5"])
    }

    func testInitialResponseStopsAutomaticLoopWhenFirstStepFails() async throws {
        let initialResponse = AIAssistantResponse(
            message: "先看磁盘，再看负载。",
            commandProposals: [
                AgentCommandProposal(command: "df -h", explanation: "查看磁盘。", risk: .readOnly),
                AgentCommandProposal(command: "uptime", explanation: "失败后不应继续。", risk: .readOnly)
            ]
        )
        let provider = SequencedAgentTaskProvider(responses: [
            AIAssistantResponse(
                message: "不应请求下一步。",
                commandProposals: [
                    AgentCommandProposal(command: "uptime", explanation: "不应执行。", risk: .readOnly)
                ]
            )
        ])
        let execution = RequestRoutedAgentCommandExecutor(eventsByCommand: [
            "df -h": [
                AgentTraceEvent(
                    requestID: "ignored",
                    state: .failed,
                    message: "执行失败：Permission denied",
                    redactedCommand: "df -h",
                    metadata: ["terminalOutputSummary": "Permission denied"]
                )
            ]
        ])
        let coordinator = AIAssistantCoordinator(provider: provider, executionCoordinator: execution)
        let orchestrator = AgentTaskOrchestrator(
            coordinator: coordinator,
            limits: AgentTaskLoopLimits(maxSteps: 3, maxDuration: 60)
        )

        let result = try await orchestrator.run(
            goal: "检查磁盘",
            context: AITerminalContext(
                runtimeID: "term_1",
                title: "dev@example.com",
                currentDirectory: "/srv/app",
                recentTranscript: ""
            ),
            initialResponse: initialResponse
        )

        XCTAssertEqual(execution.commands, ["df -h"])
        XCTAssertEqual(provider.requests.count, 0)
        XCTAssertEqual(result.state, .failed)
        XCTAssertEqual(result.steps.count, 1)
    }

    func testAutonomousLoopStopsAtStepLimitWithoutRunningExtraCommand() async throws {
        let provider = SequencedAgentTaskProvider(responses: [
            AIAssistantResponse(
                message: "第一步。",
                commandProposals: [
                    AgentCommandProposal(command: "pwd", explanation: "查看当前目录。", risk: .readOnly)
                ]
            ),
            AIAssistantResponse(
                message: "第二步。",
                commandProposals: [
                    AgentCommandProposal(command: "ls", explanation: "查看文件。", risk: .readOnly)
                ]
            )
        ])
        let execution = RequestRoutedAgentCommandExecutor(eventsByCommand: [
            "pwd": [
                AgentTraceEvent(
                    requestID: "ignored",
                    state: .completed,
                    message: "AI 独立任务已完成：/srv/app",
                    redactedCommand: "pwd",
                    metadata: ["terminalOutputSummary": "/srv/app"]
                )
            ],
            "ls": [
                AgentTraceEvent(
                    requestID: "ignored",
                    state: .completed,
                    message: "AI 独立任务已完成：app.log",
                    redactedCommand: "ls",
                    metadata: ["terminalOutputSummary": "app.log"]
                )
            ]
        ])
        let coordinator = AIAssistantCoordinator(provider: provider, executionCoordinator: execution)
        let orchestrator = AgentTaskOrchestrator(
            coordinator: coordinator,
            limits: AgentTaskLoopLimits(maxSteps: 1, maxDuration: 60)
        )

        let result = try await orchestrator.run(
            goal: "查看目录并继续诊断",
            context: AITerminalContext(
                runtimeID: "term_1",
                title: "dev@example.com",
                currentDirectory: "/srv/app",
                recentTranscript: ""
            )
        )

        XCTAssertEqual(execution.commands, ["pwd"])
        XCTAssertEqual(result.state, .awaitingUser)
        XCTAssertEqual(result.stopReason, .stepLimitReached)
        XCTAssertTrue(result.summary.contains("已达到自主执行步数上限"))
    }

    func testPauseCancelAndTakeOverStopLoopThroughCoordinatorControls() async throws {
        let provider = SequencedAgentTaskProvider(responses: [
            AIAssistantResponse(
                message: "开始持续跟踪。",
                commandProposals: [
                    AgentCommandProposal(command: "tail -f /var/log/messages", explanation: "查看日志。", risk: .readOnly)
                ]
            ),
            AIAssistantResponse(
                message: "不应继续。",
                commandProposals: [
                    AgentCommandProposal(command: "uptime", explanation: "不应执行。", risk: .readOnly)
                ]
            )
        ])
        let execution = RequestRoutedAgentCommandExecutor(eventsByCommand: [
            "tail -f /var/log/messages": [
                AgentTraceEvent(
                    requestID: "ignored",
                    state: .running,
                    message: "命令已在终端执行，输出将实时显示",
                    redactedCommand: "tail -f /var/log/messages",
                    metadata: ["executionMode": "visibleTerminal"]
                )
            ]
        ])
        let coordinator = AIAssistantCoordinator(provider: provider, executionCoordinator: execution)
        let orchestrator = AgentTaskOrchestrator(
            coordinator: coordinator,
            limits: AgentTaskLoopLimits(maxSteps: 4, maxDuration: 60)
        )
        let result = try await orchestrator.run(
            goal: "持续观察日志",
            context: AITerminalContext(
                runtimeID: "term_1",
                title: "dev@example.com",
                currentDirectory: "/srv/app",
                recentTranscript: ""
            ),
            onUpdate: { update in
                if update.traceEvent?.state == .running {
                    orchestrator.pause()
                }
            }
        )

        XCTAssertEqual(execution.pausedRequestIDs, execution.requests.map(\.id))
        XCTAssertEqual(execution.commands, ["tail -f /var/log/messages"])
        XCTAssertEqual(result.state, .paused)
        XCTAssertEqual(provider.requests.count, 1)
    }

    func testAutonomousLoopDoesNotAdvanceWhenVisibleCommandNeedsManualCompletion() async throws {
        let provider = SequencedAgentTaskProvider(responses: [
            AIAssistantResponse(
                message: "开始持续观察。",
                commandProposals: [
                    AgentCommandProposal(command: "tail -f /var/log/system.log", explanation: "持续看日志。", risk: .readOnly)
                ]
            ),
            AIAssistantResponse(
                message: "不应继续。",
                commandProposals: [
                    AgentCommandProposal(command: "uptime", explanation: "不应执行。", risk: .readOnly)
                ]
            )
        ])
        let execution = RequestRoutedAgentCommandExecutor(eventsByCommand: [
            "tail -f /var/log/system.log": [
                AgentTraceEvent(
                    requestID: "ignored",
                    state: .running,
                    message: "命令已在终端执行，输出将实时显示",
                    redactedCommand: "tail -f /var/log/system.log",
                    metadata: ["executionMode": "visibleTerminal"]
                ),
                AgentTraceEvent(
                    requestID: "ignored",
                    state: .waitingForOutput,
                    message: "这条命令可能仍在运行，Stacio 不会根据静默输出自动判定完成；请手动停止、确认或接管。",
                    redactedCommand: "tail -f /var/log/system.log",
                    metadata: [
                        "executionMode": "visibleTerminal",
                        "completionConfidence": "manualRequired"
                    ]
                )
            ]
        ])
        let coordinator = AIAssistantCoordinator(provider: provider, executionCoordinator: execution)
        let orchestrator = AgentTaskOrchestrator(
            coordinator: coordinator,
            limits: AgentTaskLoopLimits(maxSteps: 3, maxDuration: 60)
        )

        let result = try await orchestrator.run(
            goal: "观察日志",
            context: AITerminalContext(
                runtimeID: "term_1",
                title: "dev@example.com",
                currentDirectory: "/srv/app",
                recentTranscript: ""
            )
        )

        XCTAssertEqual(execution.commands, ["tail -f /var/log/system.log"])
        XCTAssertEqual(provider.requests.count, 1)
        XCTAssertEqual(result.state, .running)
        XCTAssertEqual(result.steps.first?.state, .running)
        XCTAssertFalse(result.steps.first?.observation.contains("不应继续") == true)
    }

    func testPlanModeProducesEditablePlanBeforeExecution() async throws {
        let provider = SequencedAgentTaskProvider(responses: [
            AIAssistantResponse(
                message: """
                计划：
                1. 查看负载 - 判断是否 CPU 压力
                2. 查看磁盘 - 判断是否 IO 或空间问题
                """,
                commandProposals: [
                    AgentCommandProposal(command: "uptime", explanation: "判断是否 CPU 压力。", risk: .readOnly),
                    AgentCommandProposal(command: "df -h", explanation: "判断是否 IO 或空间问题。", risk: .readOnly)
                ]
            )
        ])
        let coordinator = AIAssistantCoordinator(
            provider: provider,
            executionCoordinator: RequestRoutedAgentCommandExecutor(eventsByCommand: [:])
        )
        let orchestrator = AgentTaskOrchestrator(coordinator: coordinator)

        let plan = try await orchestrator.makePlan(
            goal: "先规划再排查",
            context: AITerminalContext(
                runtimeID: "term_1",
                title: "dev@example.com",
                currentDirectory: "/srv/app",
                recentTranscript: ""
            )
        )

        XCTAssertEqual(plan.steps.map(\.command), ["uptime", "df -h"])
        XCTAssertEqual(plan.steps.map(\.intent), ["判断是否 CPU 压力。", "判断是否 IO 或空间问题。"])
        XCTAssertTrue(provider.requests.first?.question.contains("先产出一个多步计划") == true)
        XCTAssertTrue(provider.requests.first?.question.contains("环境与依赖识别") == true)
        XCTAssertTrue(provider.requests.first?.question.contains("备份 → 变更 → 验证 → 失败回滚") == true)
    }

    func testAutonomousLoopStopsBeforeThirdIdenticalCommand() async throws {
        let repeated = AIAssistantResponse(
            message: "继续重复检查。",
            commandProposals: [
                AgentCommandProposal(command: "uptime", explanation: "再次查看负载。", risk: .readOnly)
            ]
        )
        let provider = SequencedAgentTaskProvider(responses: [repeated, repeated, repeated])
        let execution = RequestRoutedAgentCommandExecutor(eventsByCommand: [
            "uptime": [
                AgentTraceEvent(
                    requestID: "ignored",
                    state: .completed,
                    message: "load average: 0.08",
                    redactedCommand: "uptime",
                    metadata: ["terminalOutputSummary": "load average: 0.08"]
                )
            ]
        ])
        let orchestrator = AgentTaskOrchestrator(
            coordinator: AIAssistantCoordinator(provider: provider, executionCoordinator: execution),
            limits: AgentTaskLoopLimits(maxSteps: 10, maxDuration: 60)
        )

        let result = try await orchestrator.run(
            goal: "检查负载",
            context: AITerminalContext(
                runtimeID: "term_1",
                title: "dev@example.com",
                currentDirectory: nil,
                recentTranscript: ""
            )
        )

        XCTAssertEqual(execution.commands, ["uptime", "uptime"])
        XCTAssertEqual(provider.requests.count, 3)
        XCTAssertEqual(result.state, .failed)
        XCTAssertTrue(result.summary.contains("连续重复同一条命令"))
    }
}

@MainActor
private final class DelayedBackgroundAgentCommandExecutor: AgentCommandStreamingExecuting, AgentTaskControlling {
    private let emitCompletion: Bool
    private(set) var requestIDs: [String] = []
    private(set) var cancelledRequestIDs: [String] = []

    init(emitCompletion: Bool = true) {
        self.emitCompletion = emitCompletion
    }

    func runCommand(_ request: AgentBridgeRequest) throws -> [AgentTraceEvent] {
        try runCommand(request, emit: { _ in })
    }

    func runCommand(
        _ request: AgentBridgeRequest,
        emit: @escaping (AgentTraceEvent) -> Void
    ) throws -> [AgentTraceEvent] {
        requestIDs.append(request.id)
        let running = AgentTraceEvent(
            requestID: request.id,
            state: .running,
            message: "独立任务已启动，输出将同步显示",
            redactedCommand: "uptime",
            metadata: ["executionMode": "backgroundTask"]
        )
        emit(running)
        if emitCompletion {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 20_000_000)
                emit(AgentTraceEvent(
                    requestID: request.id,
                    state: .completed,
                    message: "AI 独立任务已完成：load average: 0.04",
                    redactedCommand: "uptime",
                    metadata: [
                        "executionMode": "backgroundTask",
                        "terminalOutputSummary": "load average: 0.04"
                    ]
                ))
            }
        }
        return [running]
    }

    func cancelTask(requestID: String) -> AgentTraceEvent? {
        cancelledRequestIDs.append(requestID)
        return AgentTraceEvent(
            requestID: requestID,
            state: .cancelled,
            message: "AI 独立任务已取消。",
            redactedCommand: "uptime",
            metadata: ["executionMode": "backgroundTask"]
        )
    }
}

private final class SequencedAgentTaskProvider: AIAssistantProviding {
    private let responses: [AIAssistantResponse]
    private(set) var requests: [AIAssistantRequest] = []

    init(responses: [AIAssistantResponse]) {
        self.responses = responses
    }

    func respond(to request: AIAssistantRequest) throws -> AIAssistantResponse {
        requests.append(request)
        let index = min(requests.count - 1, responses.count - 1)
        return responses[index]
    }
}

@MainActor
private final class SequentialOutcomeAgentCommandExecutor: AgentCommandStreamingExecuting {
    enum Outcome {
        case completed(String)
        case failed(String)
    }

    private var outcomes: [String: [Outcome]]
    private(set) var commands: [String] = []

    init(outcomes: [String: [Outcome]]) {
        self.outcomes = outcomes
    }

    func runCommand(_ request: AgentBridgeRequest) throws -> [AgentTraceEvent] {
        try runCommand(request, emit: { _ in })
    }

    func runCommand(
        _ request: AgentBridgeRequest,
        emit: @escaping (AgentTraceEvent) -> Void
    ) throws -> [AgentTraceEvent] {
        guard case .runCommand(let run) = request.action else { return [] }
        commands.append(run.command)
        var queued = outcomes[run.command] ?? []
        let outcome = queued.isEmpty ? .failed("missing outcome") : queued.removeFirst()
        outcomes[run.command] = queued
        let event: AgentTraceEvent
        switch outcome {
        case .completed(let output):
            event = AgentTraceEvent(
                requestID: request.id,
                state: .completed,
                message: output,
                redactedCommand: run.command,
                metadata: ["terminalOutputSummary": output]
            )
        case .failed(let output):
            event = AgentTraceEvent(
                requestID: request.id,
                state: .failed,
                message: output,
                redactedCommand: run.command,
                metadata: ["terminalOutputSummary": output]
            )
        }
        emit(event)
        return [event]
    }
}

@MainActor
private final class RequestRoutedAgentCommandExecutor: AgentCommandStreamingExecuting, AgentTaskControlling {
    private(set) var requests: [AgentBridgeRequest] = []
    private(set) var commands: [String] = []
    private(set) var cancelledRequestIDs: [String] = []
    private(set) var pausedRequestIDs: [String] = []
    private(set) var takenOverRequestIDs: [String] = []
    var cancelEvents: [String: AgentTraceEvent] = [:]
    var pauseEvents: [String: AgentTraceEvent] = [:]
    var takeOverEvents: [String: AgentTraceEvent] = [:]
    private let eventsByCommand: [String: [AgentTraceEvent]]

    init(eventsByCommand: [String: [AgentTraceEvent]]) {
        self.eventsByCommand = eventsByCommand
    }

    func runCommand(_ request: AgentBridgeRequest) throws -> [AgentTraceEvent] {
        try runCommand(request, emit: { _ in })
    }

    func runCommand(
        _ request: AgentBridgeRequest,
        emit: @escaping (AgentTraceEvent) -> Void
    ) throws -> [AgentTraceEvent] {
        requests.append(request)
        guard case .runCommand(let run) = request.action else {
            return []
        }
        commands.append(run.command)
        let events = (eventsByCommand[run.command] ?? []).map { event in
            AgentTraceEvent(
                requestID: request.id,
                state: event.state,
                message: event.message,
                redactedCommand: event.redactedCommand,
                metadata: event.metadata
            )
        }
        events.forEach(emit)
        return events
    }

    func cancelTask(requestID: String) -> AgentTraceEvent? {
        cancelledRequestIDs.append(requestID)
        return cancelEvents[requestID]
    }

    func pauseTask(requestID: String) -> AgentTraceEvent? {
        pausedRequestIDs.append(requestID)
        return pauseEvents[requestID]
    }

    func takeOverTask(requestID: String) -> AgentTraceEvent? {
        takenOverRequestIDs.append(requestID)
        return takeOverEvents[requestID]
    }
}
