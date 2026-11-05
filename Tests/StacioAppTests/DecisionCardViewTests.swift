import AppKit
import XCTest
import Foundation
@testable import StacioApp

/// P6-4：Decision/Execution/Terminal 卡片与 Change Summary。
final class DecisionCardViewTests: XCTestCase {

    @MainActor
    func testToolDecisionViewShowsAndCopiesCompleteCommand() throws {
        let controller = ToolDecisionViewController()
        controller.loadViewIfNeeded()
        let command = "printf '%s\\n' start\\ncat /var/log/stacio/very-long-output.log"
        controller.apply(PendingToolDecisionPresentation(
            proposalID: "proposal-1", decisionID: "decision-1", command: command,
            explanation: "读取诊断日志", risk: "read-only", targetTitle: "local",
            targetWorkingDirectory: "/srv/app", executionDestination: "后台虚拟终端",
            targetBindingDigest: "sha256:target", targetRuntimeGeneration: 7,
            immutableSummary: "sha256:approval",
            index: 1, total: 2
        ))

        let commandField = try XCTUnwrap(
            descendant(of: controller.view, accessibilityLabel: "待执行命令") as? NSTextField
        )
        XCTAssertEqual(commandField.stringValue, command)
        XCTAssertEqual(commandField.maximumNumberOfLines, 0)

        NSPasteboard.general.clearContents()
        defer { NSPasteboard.general.clearContents() }
        let copyButton = try XCTUnwrap(
            descendant(of: controller.view, accessibilityLabel: "复制完整命令") as? NSButton
        )
        copyButton.performClick(nil)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), command)

        let details = try XCTUnwrap(
            descendant(of: controller.view, accessibilityLabel: "审批详情") as? NSTextField
        )
        XCTAssertTrue(details.stringValue.contains("工作目录：/srv/app"))
        XCTAssertTrue(details.stringValue.contains("执行位置：后台虚拟终端"))
        XCTAssertTrue(details.stringValue.contains("连接代次：7"))
        XCTAssertTrue(details.stringValue.contains("目标绑定：sha256:target"))
        XCTAssertTrue(details.stringValue.contains("审批摘要：sha256:approval"))
        let queued = try XCTUnwrap(
            descendant(of: controller.view, accessibilityLabel: "后续工具调用") as? NSTextField
        )
        XCTAssertEqual(queued.stringValue, "另有 1 个工具调用排队")
        XCTAssertFalse(queued.isHidden)
    }

    @MainActor
    func testToolDecisionViewDoesNotClaimComposerReturnAsApproval() throws {
        let controller = ToolDecisionViewController()
        controller.loadViewIfNeeded()
        var resolutions: [(String, Bool)] = []
        controller.onResolve = { resolutions.append(($0, $1)) }
        controller.apply(PendingToolDecisionPresentation(
            proposalID: "proposal-return",
            decisionID: "decision-return",
            command: "systemctl restart stacio",
            explanation: "重启服务",
            risk: "destructive",
            targetTitle: "production",
            index: 1,
            total: 1
        ))

        let approve = try XCTUnwrap(
            descendant(of: controller.view, accessibilityLabel: "批准并运行命令") as? NSButton
        )
        XCTAssertEqual(approve.keyEquivalent, "")

        let host = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 360))
        let composer = AgentComposerTextView()
        composer.frame = NSRect(x: 20, y: 20, width: 440, height: 80)
        controller.view.frame = NSRect(x: 20, y: 120, width: 440, height: 220)
        host.addSubview(composer)
        host.addSubview(controller.view)

        let window = NSWindow(
            contentRect: host.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        XCTAssertTrue(window.makeFirstResponder(composer))

        let returnEvent = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: AgentComposerKeyRouter.keyCodeReturn
        ))
        _ = window.performKeyEquivalent(with: returnEvent)

        XCTAssertTrue(resolutions.isEmpty, "Return in the Composer must never approve a terminal command")
    }

    @MainActor
    func testCompactDecisionViewKeepsCommandAndApprovalActionsReadable() throws {
        let controller = ToolDecisionViewController()
        controller.loadViewIfNeeded()
        controller.setCompactPresentation(true)
        let command = [
            "journalctl --no-pager --unit=stacio-production.service --since '30 minutes ago'",
            "systemctl show stacio-production.service --property=ActiveState,SubState,ExecMainStatus"
        ].joined(separator: "\n")
        controller.apply(PendingToolDecisionPresentation(
            proposalID: "proposal-compact", decisionID: "decision-compact",
            command: command, explanation: "读取服务状态和最近日志，不修改目标主机。",
            risk: "read-only", targetTitle: "192.168.124.100",
            targetWorkingDirectory: "/home/FengLee",
            executionDestination: "后台虚拟终端",
            targetBindingDigest: "sha256:target-binding",
            targetRuntimeGeneration: 8,
            immutableSummary: "sha256:approval-boundary",
            index: 1, total: 1
        ))

        for width in [CGFloat(300), 320, 360] {
            for height in [CGFloat(148), 180, 212] {
                controller.view.frame = NSRect(x: 0, y: 0, width: width, height: height)
                controller.view.needsLayout = true
                controller.view.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                controller.view.layoutSubtreeIfNeeded()

                let cardBounds = controller.view.bounds.insetBy(dx: -1, dy: -1)
                let detailsFrame = controller.detailsScrollFrameForTesting(in: controller.view)
                let documentFrame = controller.detailsDocumentFrameForTesting(in: controller.view)
                let commandFrame = controller.commandFrameForTesting(in: controller.view)
                let visibleDocumentRect = controller.detailsVisibleDocumentRectForTesting
                let commandInDocument = controller.commandFrameInDetailsDocumentForTesting
                let approveFrame = controller.approvalButtonFrameForTesting(in: controller.view)
                let denyFrame = controller.denialButtonFrameForTesting(in: controller.view)
                let dimensions = "\(Int(width))x\(Int(height))"

                XCTAssertEqual(controller.commandTextForTesting, command, dimensions)
                XCTAssertGreaterThan(detailsFrame.height, 0, dimensions)
                XCTAssertGreaterThanOrEqual(documentFrame.height, detailsFrame.height - 1, dimensions)
                XCTAssertGreaterThan(commandFrame.height, 0, dimensions)
                XCTAssertGreaterThan(
                    NSIntersectionRect(commandInDocument, visibleDocumentRect).height,
                    0,
                    "command first row must be in the initial viewport at \(dimensions)"
                )
                XCTAssertEqual(
                    visibleDocumentRect.minY,
                    0,
                    accuracy: 1,
                    "new approvals must open at the top at \(dimensions)"
                )
                XCTAssertTrue(cardBounds.contains(approveFrame), dimensions)
                XCTAssertTrue(cardBounds.contains(denyFrame), dimensions)
            }
        }
    }

    @MainActor
    func testToolDecisionViewLocksApprovalAndResetsForNewProposal() throws {
        let controller = ToolDecisionViewController()
        controller.loadViewIfNeeded()
        var resolutions: [(String, Bool)] = []
        controller.onResolve = { proposalID, approved in
            resolutions.append((proposalID, approved))
        }
        let first = PendingToolDecisionPresentation(
            proposalID: "proposal-1", decisionID: "decision-1", command: "pwd",
            explanation: "", risk: "read-only", targetTitle: "local", index: 1, total: 2
        )
        controller.apply(first)
        let approve = try XCTUnwrap(
            descendant(of: controller.view, accessibilityLabel: "批准并运行命令") as? NSButton
        )
        approve.performClick(nil)
        approve.performClick(nil)
        XCTAssertEqual(resolutions.count, 1)
        XCTAssertEqual(resolutions.first?.0, "proposal-1")
        XCTAssertTrue(approve.isEnabled == false)

        // A cross-window projection of the same proposal must retain the lock.
        controller.apply(first)
        XCTAssertFalse(approve.isEnabled)

        let second = PendingToolDecisionPresentation(
            proposalID: "proposal-2", decisionID: "decision-2", command: "ls",
            explanation: "列出文件", risk: "read-only", targetTitle: "local", index: 2, total: 2
        )
        controller.apply(second)
        XCTAssertTrue(approve.isEnabled)
        controller.apply(nil)
        XCTAssertTrue(controller.view.isHidden)
        XCTAssertEqual(
            (descendant(of: controller.view, accessibilityLabel: "待执行命令") as? NSTextField)?.stringValue,
            ""
        )
    }

    @MainActor
    func testToolDecisionViewIgnoresLateResolutionForReplacedProposal() throws {
        let controller = ToolDecisionViewController()
        controller.loadViewIfNeeded()
        let first = PendingToolDecisionPresentation(
            proposalID: "proposal-old", decisionID: "decision-old", command: "old-command",
            explanation: "旧建议", risk: "read-only", targetTitle: "local", index: 1, total: 1
        )
        let second = PendingToolDecisionPresentation(
            proposalID: "proposal-new", decisionID: "decision-new", command: "new-command",
            explanation: "新建议", risk: "read-only", targetTitle: "local", index: 1, total: 1
        )

        controller.apply(first)
        controller.setResolving(true)
        controller.apply(second)

        XCTAssertEqual(controller.currentProposalID, "proposal-new")
        XCTAssertFalse(
            controller.setResolving(
                false,
                forProposalID: "proposal-old",
                error: "旧请求失败"
            )
        )
        XCTAssertEqual(controller.currentProposalID, "proposal-new")
        XCTAssertEqual(controller.commandTextForTesting, "new-command")
        let status = try XCTUnwrap(
            descendant(of: controller.view, accessibilityLabel: "审批状态") as? NSTextField
        )
        XCTAssertFalse(status.stringValue.contains("旧请求失败"))
    }

    @MainActor
    func testToolDecisionViewStatusUsesFullWidthOnNarrowCard() throws {
        let controller = ToolDecisionViewController()
        controller.loadViewIfNeeded()
        controller.apply(PendingToolDecisionPresentation(
            proposalID: "proposal-status", decisionID: "decision-status", command: "uptime",
            explanation: "读取状态", risk: "read-only", targetTitle: "local", index: 1, total: 1,
            isActionable: false,
            statusMessage: "该审批已失效，请重新生成建议后再执行。"
        ))
        controller.view.frame = NSRect(x: 0, y: 0, width: 300, height: 180)
        controller.view.needsLayout = true
        controller.view.layoutSubtreeIfNeeded()

        let status = try XCTUnwrap(
            descendant(of: controller.view, accessibilityLabel: "审批状态") as? NSTextField
        )
        XCTAssertFalse(status.isHidden)
        XCTAssertGreaterThan(status.frame.width, 220)
        XCTAssertLessThanOrEqual(status.frame.maxX, controller.view.bounds.width)
    }

    @MainActor
    func testRelaunchInvalidatedDecisionIsCopyableButCannotResolve() throws {
        let controller = ToolDecisionViewController()
        controller.loadViewIfNeeded()
        var resolutions: [(String, Bool)] = []
        controller.onResolve = { resolutions.append(($0, $1)) }
        let command = "systemctl status nginx"
        controller.apply(PendingToolDecisionPresentation(
            proposalID: "proposal-stale",
            decisionID: "decision-stale",
            command: command,
            explanation: "重启前生成的建议",
            risk: "read-only",
            targetTitle: "production",
            index: 1,
            total: 1,
            isActionable: false,
            statusMessage: "App 重启后该审批已失效。请基于当前连接重新生成建议。"
        ))

        let approve = try XCTUnwrap(
            descendant(of: controller.view, accessibilityLabel: "批准并运行命令") as? NSButton
        )
        let deny = try XCTUnwrap(
            descendant(of: controller.view, accessibilityLabel: "拒绝命令") as? NSButton
        )
        let copy = try XCTUnwrap(
            descendant(of: controller.view, accessibilityLabel: "复制完整命令") as? NSButton
        )
        let status = try XCTUnwrap(
            descendant(of: controller.view, accessibilityLabel: "审批状态") as? NSTextField
        )
        XCTAssertFalse(approve.isEnabled)
        XCTAssertFalse(deny.isEnabled)
        XCTAssertTrue(copy.isEnabled)
        XCTAssertTrue(status.stringValue.contains("重启后该审批已失效"))
        approve.performClick(nil)
        deny.performClick(nil)
        XCTAssertTrue(resolutions.isEmpty)

        NSPasteboard.general.clearContents()
        defer { NSPasteboard.general.clearContents() }
        copy.performClick(nil)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), command)
    }

    // MARK: - Decision Card 展示字段

    func testDecisionCardShowsTargetAndBindingIdentity() {
        let card = DecisionCardPresentation(
            targetHost: "deploy@example.com", targetWorkingDirectory: "/srv/app",
            shellOrExecutable: "/bin/zsh", argvItems: ["-c", "deploy.sh"],
            envDeltaKeys: ["STACIO_DEPLOY"], stdinSource: "heredoc",
            redirects: ["stdout→log"], escalationMethod: "sudo", timeoutSeconds: 60,
            impactScope: "remote", riskLevel: "high",
            targetBindingDigest: "digest-1", terminalLeaseGeneration: 3,
            immutableSummary: "sha256:abc",
            localAgentWorkingDirectory: "/Users/mac/stacio", launchContainmentGeneration: "gen-2"
        )
        XCTAssertEqual(card.targetHost, "deploy@example.com")
        XCTAssertEqual(card.targetWorkingDirectory, "/srv/app")
        XCTAssertEqual(card.shellOrExecutable, "/bin/zsh")
        XCTAssertEqual(card.argvItems, ["-c", "deploy.sh"], "逐项 argv")
        XCTAssertEqual(card.escalationMethod, "sudo", "提权方式")
        XCTAssertEqual(card.timeoutSeconds, 60, "超时")
        XCTAssertEqual(card.riskLevel, "high")
        XCTAssertEqual(card.targetBindingDigest, "digest-1", "TargetBinding.digest")
        XCTAssertEqual(card.terminalLeaseGeneration, 3, "TerminalRuntimeLease.generation")
        XCTAssertEqual(card.immutableSummary, "sha256:abc", "不可变摘要")
        // Local Agent 另列
        XCTAssertEqual(card.localAgentWorkingDirectory, "/Users/mac/stacio", "AgentProcessWorkingDirectory")
        XCTAssertEqual(card.launchContainmentGeneration, "gen-2", "launch/containment generation")
    }

    // MARK: - 敏感值只显示来源与存在性

    func testSensitiveValueOnlySourceAndExistence() {
        let display = DecisionCardAction.sensitiveValueDisplay(source: "keychain", present: true)
        XCTAssertEqual(display, "来源：keychain（已存在）")
        XCTAssertFalse(display.contains("secret"), "不显示正文")
        XCTAssertEqual(
            DecisionCardAction.sensitiveValueDisplay(source: "env", present: false),
            "来源：env（未设置）"
        )
    }

    // MARK: - 多 Tool Call

    func testToolCallLabelAndQueuedSummary() {
        XCTAssertEqual(DecisionCardAction.toolCallLabel(index: 1, total: 3), "工具 1/3", "先显示「工具 1/N」")
        XCTAssertEqual(DecisionCardAction.queuedSummaryLabel(remaining: 2), "另有 2 个工具调用排队",
                       "后续只显示排队摘要")
    }

    // MARK: - Execution Card

    func testExecutionCardTerminalKindAndTakeover() {
        let card = ExecutionCardPresentation(
            target: "host", workingDirectory: "/app", redactedCommand: "deploy --token [redacted]",
            riskAndApproval: "已审批", isRealTerminal: true, exitCode: 0,
            durationSeconds: 12, completionBasis: "exitCode"
        )
        XCTAssertEqual(ExecutionCardAction.terminalKindLabel(isRealTerminal: true), "真实终端")
        XCTAssertEqual(ExecutionCardAction.terminalKindLabel(isRealTerminal: false), "后台虚拟终端")
        XCTAssertEqual(card.redactedCommand, "deploy --token [redacted]", "脱敏命令")
        XCTAssertEqual(card.exitCode, 0, "退出码")
        XCTAssertEqual(card.durationSeconds, 12, "持续时间")
        XCTAssertEqual(card.completionBasis, "exitCode", "完成依据")
        // 只有实际持有可移交 handle 才显示「请求接管」
        XCTAssertTrue(ExecutionCardAction.takeoverAvailable(holdsTransferableHandle: true))
        XCTAssertFalse(ExecutionCardAction.takeoverAvailable(holdsTransferableHandle: false))
    }

    // MARK: - Terminal Artifact

    func testTerminalArtifactShowsLiveTailAndExit() {
        let running = TerminalArtifactPresentation(liveTail: "line1", exitCode: nil, durationSeconds: nil)
        XCTAssertFalse(running.isFinished, "运行中无退出码")
        let completedWithoutExitCode = TerminalArtifactPresentation(
            liveTail: "done",
            exitCode: nil,
            durationSeconds: nil,
            hasTerminalState: true
        )
        XCTAssertTrue(completedWithoutExitCode.isFinished, "终态证据不依赖退出码")
        let finished = TerminalArtifactPresentation(liveTail: "done", exitCode: 0, durationSeconds: 5)
        XCTAssertTrue(finished.isFinished)
        XCTAssertEqual(finished.exitCode, 0)
    }

    @MainActor
    func testTerminalArtifactDistinguishesWaitingFromCompletedWithoutOutput() {
        let view = TerminalArtifactView()

        view.apply(
            TerminalArtifactPresentation(liveTail: nil, exitCode: nil, durationSeconds: nil),
            expanded: false
        )
        XCTAssertEqual(
            (descendant(of: view, accessibilityLabel: "脱敏终端输出") as? NSTextField)?.stringValue,
            "等待终端输出…"
        )

        view.apply(
            TerminalArtifactPresentation(
                liveTail: nil,
                exitCode: nil,
                durationSeconds: nil,
                hasTerminalState: true
            ),
            expanded: false
        )
        XCTAssertEqual(
            (descendant(of: view, accessibilityLabel: "脱敏终端输出") as? NSTextField)?.stringValue,
            "命令已结束，未产生可显示的终端输出。"
        )
    }

    @MainActor
    func testExecutionCardRendersRedactedEvidenceAndRoutesRealActions() throws {
        let artifact = TerminalArtifactPresentation(
            requestID: "request-1",
            runtimeID: "runtime-1",
            liveTail: "health: ok",
            exitCode: nil,
            durationSeconds: 3,
            completionBasis: "streaming",
            stateLabel: "执行中",
            isRealTerminal: true,
            canOpenTerminal: true,
            canCancel: true,
            canSaveRedactedLog: true,
            redactedLog: "[running] health: ok"
        )
        let presentation = ExecutionCardPresentation(
            proposalID: "proposal-1",
            target: "production",
            targetRuntimeID: "runtime-1",
            workingDirectory: "/srv/app",
            redactedCommand: "curl -H [redacted] /health",
            riskAndApproval: "风险：read-only · 已批准",
            isRealTerminal: true,
            exitCode: nil,
            durationSeconds: 3,
            completionBasis: "streaming",
            status: "执行中",
            terminalArtifact: artifact
        )
        let view = ExecutionCardView()
        var openedRuntimeID: String?
        var cancelledRequestID: String?
        var saved: TerminalArtifactPresentation?
        view.onOpenTerminal = { openedRuntimeID = $0 }
        view.onCancel = { cancelledRequestID = $0 }
        view.onSaveRedactedLog = { saved = $0 }
        view.apply(presentation, expanded: false)

        XCTAssertEqual(
            (descendant(of: view, accessibilityLabel: "脱敏命令") as? NSTextField)?.stringValue,
            "curl -H [redacted] /health"
        )
        XCTAssertEqual(
            (descendant(of: view, accessibilityLabel: "脱敏终端输出") as? NSTextField)?.stringValue,
            "health: ok"
        )

        NSPasteboard.general.clearContents()
        defer { NSPasteboard.general.clearContents() }
        (descendant(of: view, accessibilityLabel: "复制终端输出") as? NSButton)?.performClick(nil)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "health: ok")
        (descendant(of: view, accessibilityLabel: "展开终端输出") as? NSButton)?.performClick(nil)
        XCTAssertFalse(
            (descendant(of: view, accessibilityLabel: "执行详情") as? NSTextField)?.isHidden ?? true
        )
        (descendant(of: view, accessibilityLabel: "在真实终端中查看") as? NSButton)?.performClick(nil)
        (descendant(of: view, accessibilityLabel: "停止当前执行") as? NSButton)?.performClick(nil)
        (descendant(of: view, accessibilityLabel: "保存脱敏日志") as? NSButton)?.performClick(nil)
        XCTAssertEqual(openedRuntimeID, "runtime-1")
        XCTAssertEqual(cancelledRequestID, "request-1")
        XCTAssertEqual(saved, artifact)
    }

    // MARK: - Change Summary

    func testChangeSummaryStructured() {
        let summary = ChangeSummaryPresentation(
            target: "host:/etc/nginx.conf", operationType: "modify",
            affectedObjects: ["/etc/nginx.conf"], beforeHash: "h1", afterHash: "h2",
            backupRollbackReference: "backup://2026-08-06", verificationResult: "verified",
            unverifiedItems: ["reload 后行为"],
            secretDiff: DecisionCardAction.secretDiffDisplay(afterHash: "h2")
        )
        XCTAssertEqual(summary.operationType, "modify")
        XCTAssertEqual(summary.beforeHash, "h1")
        XCTAssertEqual(summary.afterHash, "h2")
        XCTAssertEqual(summary.backupRollbackReference, "backup://2026-08-06", "备份回滚引用")
        XCTAssertEqual(summary.verificationResult, "verified", "验证结果")
        XCTAssertEqual(summary.unverifiedItems, ["reload 后行为"], "未验证事项")
        XCTAssertEqual(summary.secretDiff, "敏感值已变化 · h2", "secret diff 只显示「敏感值已变化」+ hash")
    }
}

@MainActor
private func descendant(of root: NSView, accessibilityLabel: String) -> NSView? {
    if root.accessibilityLabel() == accessibilityLabel {
        return root
    }
    for child in root.subviews {
        if let match = descendant(of: child, accessibilityLabel: accessibilityLabel) {
            return match
        }
    }
    return nil
}
