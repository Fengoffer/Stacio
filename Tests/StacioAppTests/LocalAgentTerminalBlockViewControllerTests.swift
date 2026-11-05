import AppKit
import Darwin
import SwiftTerm
import XCTest
@testable import StacioApp

@MainActor
final class LocalAgentTerminalBlockViewControllerTests: XCTestCase {
    func testManagedProcessGroupOwnershipRejectsPIDReuseAndAcceptsContinuousDescendant() {
        let rootStart = Date(timeIntervalSince1970: 1_700_000_001)
        let childStart = Date(timeIntervalSince1970: 1_700_000_002)
        let replacementStart = Date(timeIntervalSince1970: 1_700_000_101)

        XCTAssertTrue(StacioLocalAgentTerminalView.hasContinuousManagedProcessGroupOwnership(
            known: [700: rootStart, 701: childStart],
            observed: [701: childStart, 702: Date(timeIntervalSince1970: 1_700_000_003)]
        ))
        XCTAssertFalse(StacioLocalAgentTerminalView.hasContinuousManagedProcessGroupOwnership(
            known: [700: rootStart, 701: childStart],
            observed: [700: replacementStart]
        ))
        XCTAssertFalse(StacioLocalAgentTerminalView.hasContinuousManagedProcessGroupOwnership(
            known: [700: rootStart],
            observed: [:]
        ))
    }

    func testRealLocalAgentStopTerminatesCompletePTYProcessGroup() async throws {
        let terminal = StacioLocalAgentTerminalView(frame: .zero)
        let terminated = expectation(description: "managed process group settled")
        let delegate = RecordingLocalAgentProcessDelegate(terminated: terminated)
        terminal.processDelegate = delegate
        let launcher = SwiftTermLocalTerminalProcessLauncher()

        launcher.startProcess(
            in: terminal,
            executable: "/bin/sh",
            args: ["-c", "sleep 30 & wait"],
            environment: nil,
            execName: "sh",
            currentDirectory: NSTemporaryDirectory()
        )
        let rootPID = terminal.process.shellPid
        guard rootPID > 0 else {
            XCTFail("The real PTY process did not start")
            return
        }
        defer { launcher.terminate(terminal) }
        XCTAssertTrue(launcher.isRunning(terminal))

        launcher.terminate(terminal)
        await fulfillment(of: [terminated], timeout: 3)

        XCTAssertFalse(launcher.isRunning(terminal))
        XCTAssertEqual(kill(-rootPID, 0), -1)
        XCTAssertEqual(errno, ESRCH, "No descendant may remain in the managed process group")
    }

    func testComposerRuntimeMenuRequiresExplicitAcceptedSelection() throws {
        let composer = AgentComposerViewController()
        composer.loadView()
        composer.setRuntimeOptions([
            ComposerRuntimeOption(id: "native", title: "Native · ops-model"),
            ComposerRuntimeOption(id: "local-agent:codex", title: "Stacio Agent · Codex · 终端透传")
        ], selectedID: "native")
        var acceptedIDs: [String] = []
        composer.onRuntimeSelectionChange = { id in
            acceptedIDs.append(id)
            return id == "local-agent:codex"
        }

        let popup = try XCTUnwrap(
            firstSubview(in: composer.view, identifier: "Stacio.AI.composer.runtime") as? NSPopUpButton
        )
        popup.selectItem(at: 1)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(popup.action), to: popup.target, from: popup))

        XCTAssertEqual(composer.selectedRuntimeID, "local-agent:codex")
        XCTAssertEqual(acceptedIDs, ["local-agent:codex"])

        composer.setTerminalPassthroughState(runtimeName: "Codex", isRunning: true)
        XCTAssertTrue(composer.isTerminalPassthroughSelected)
        XCTAssertTrue(composer.isStopVisible)
        XCTAssertFalse(popup.isEnabled, "A running PTY must be stopped before changing Runtime")
        XCTAssertEqual(composer.selectedWorkMode, .agent)
        let workMode = try XCTUnwrap(
            firstSubview(in: composer.view, identifier: "Stacio.AI.composer.workMode") as? NSSegmentedControl
        )
        XCTAssertFalse(workMode.isEnabled, "PTY passthrough cannot claim plan-first or answer-only enforcement")
    }

    func testCompactLocalAgentMenuDoesNotExposeNativeModelControls() throws {
        let composer = AgentComposerViewController()
        composer.loadView()
        composer.setRuntimeIdentity(
            "Native · ops-model",
            models: ["ops-model", "fallback-model"],
            reasoningLevels: ["low", "high"]
        )
        composer.setRuntimeOptions([
            ComposerRuntimeOption(id: "native", title: "Native · ops-model"),
            ComposerRuntimeOption(id: "local-agent:codex", title: "Stacio Agent · Codex · 终端透传")
        ], selectedID: "local-agent:codex")
        composer.setTerminalPassthroughState(runtimeName: "Codex", isRunning: true)
        composer.view.frame.size.width = 520
        composer.view.layoutSubtreeIfNeeded()

        let compactButton = try XCTUnwrap(
            firstSubview(in: composer.view, identifier: "Stacio.AI.composer.compactOptions") as? NSButton
        )
        let titles = compactButton.menu?.items.map(\.title) ?? []
        XCTAssertFalse(compactButton.isHidden)
        XCTAssertTrue(titles.contains("Native · ops-model"))
        XCTAssertTrue(titles.contains("Stacio Agent · Codex · 终端透传"))
        XCTAssertFalse(titles.contains("ops-model"))
        XCTAssertFalse(titles.contains("fallback-model"))
        XCTAssertFalse(titles.contains("推理：low"))
        XCTAssertFalse(titles.contains("推理：high"))
        XCTAssertTrue(compactButton.menu?.items.filter { $0.representedObject != nil }.allSatisfy { !$0.isEnabled } == true)
    }

    func testActivationStartsDetectedCLIInDedicatedLocalWorkspace() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("stacio-managed-workspace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let launcher = RecordingV2LocalAgentLauncher()
        let controller = LocalAgentTerminalBlockViewController(
            resolver: V2StaticLocalAgentResolver(
                paths: [.codex: "/tools/codex"],
                workingDirectoryMode: .managedWorkspace
            ),
            processLauncherFactory: { launcher },
            currentDirectoryProvider: { workspace.path },
            runtimeLaunchAuthorizer: TestLocalAgentRuntimeLaunchAuthorizer()
        )

        XCTAssertTrue(controller.activate(tool: .codex))
        XCTAssertEqual(launcher.startedExecutable, "/tools/codex")
        XCTAssertEqual(launcher.startedArguments, ["--no-alt-screen"])
        XCTAssertEqual(launcher.startedCurrentDirectory, workspace.path)
        XCTAssertEqual(controller.state, .running(.codex, executable: "/tools/codex"))
        XCTAssertTrue(controller.terminalVisibleForTesting)
        XCTAssertTrue(controller.statusTextForTesting.contains("已确认路径"))
        XCTAssertTrue(controller.statusTextForTesting.contains("Experimental"))
    }

    func testComposerInputIsWrittenToPTYWithoutFabricatingTimelineEvents() throws {
        let launcher = RecordingV2LocalAgentLauncher()
        let terminal = LocalAgentTerminalBlockViewController(
            resolver: V2StaticLocalAgentResolver(paths: [.codex: "/tools/codex"]),
            processLauncherFactory: { launcher },
            runtimeLaunchAuthorizer: TestLocalAgentRuntimeLaunchAuthorizer()
        )
        let shell = AgentConversationViewController(sessionID: "local-agent-v2-test")
        let composer = AgentComposerViewController()
        let timeline = ConversationTimelineViewController()
        let toolbar = ConversationToolbarViewController()
        shell.assemble(
            composer: composer,
            timeline: timeline,
            toolbar: toolbar,
            decision: nil,
            localAgentTerminal: terminal
        )

        XCTAssertTrue(terminal.activate(tool: .codex))
        XCTAssertEqual(terminal.send("inspect nginx"), .accepted)

        XCTAssertEqual(launcher.sentInputs, [Array("inspect nginx\n".utf8)])
        XCTAssertEqual(terminal.sentHistory, ["inspect nginx"])
        XCTAssertEqual(timeline.itemCount, 0, "PTY bytes must not become answer, tool, approval, or completion rows")
        XCTAssertFalse(timeline.view.isHidden, "Timeline remains available beside the terminal block")
        XCTAssertFalse(composer.view.isHidden, "Composer remains available beside the terminal block")
        XCTAssertTrue(shell.hasAssembledParts())
    }

    func testCompactPresentationReclaimsTerminalBodyWithoutChangingUserPreference() throws {
        let controller = LocalAgentTerminalBlockViewController(
            resolver: V2StaticLocalAgentResolver(paths: [.codex: "/tools/codex"]),
            processLauncherFactory: { RecordingV2LocalAgentLauncher() },
            runtimeLaunchAuthorizer: TestLocalAgentRuntimeLaunchAuthorizer()
        )
        XCTAssertTrue(controller.activate(tool: .codex))
        XCTAssertTrue(controller.isTerminalBodyVisibleForTesting)

        controller.setCompactPresentation(true)
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(controller.isCompactPresentationForTesting)
        XCTAssertFalse(controller.isTerminalBodyVisibleForTesting)

        controller.setCompactPresentation(false)
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertFalse(controller.isCompactPresentationForTesting)
        XCTAssertTrue(controller.isTerminalBodyVisibleForTesting)

        // A compact pass must not erase an explicit user collapse.
        let collapseButton = try XCTUnwrap(
            controller.view.allSubviews(ofType: NSButton.self).first { $0.toolTip == "折叠终端块" }
        )
        XCTAssertTrue(NSApp.sendAction(
            try XCTUnwrap(collapseButton.action),
            to: collapseButton.target,
            from: collapseButton
        ))
        controller.setCompactPresentation(true)
        controller.setCompactPresentation(false)
        XCTAssertFalse(controller.isTerminalBodyVisibleForTesting)
    }

    func testConversationShellLayoutMatrixKeepsPrimarySurfacesUsableAndAuxiliaryContentScrollable() throws {
        let terminal = LocalAgentTerminalBlockViewController(
            resolver: V2StaticLocalAgentResolver(paths: [.codex: "/tools/codex"]),
            processLauncherFactory: { RecordingV2LocalAgentLauncher() },
            runtimeLaunchAuthorizer: TestLocalAgentRuntimeLaunchAuthorizer()
        )
        XCTAssertTrue(terminal.activate(tool: .codex))
        let decision = ToolDecisionViewController()
        decision.apply(PendingToolDecisionPresentation(
            proposalID: "layout-proposal", decisionID: "layout-decision",
            command: String(repeating: "printf diagnostic-output ", count: 80),
            explanation: String(repeating: "说明 ", count: 40), risk: "read-only",
            targetTitle: "local", targetWorkingDirectory: "/tmp/stacio",
            executionDestination: "真实终端", targetBindingDigest: "sha256:target",
            immutableSummary: "sha256:approval", index: 1, total: 3
        ))

        let shell = AgentConversationViewController(sessionID: "compact-layout-test")
        let composer = AgentComposerViewController()
        let timeline = ConversationTimelineViewController()
        let toolbar = ConversationToolbarViewController()
        shell.assemble(
            composer: composer,
            timeline: timeline,
            toolbar: toolbar,
            decision: decision,
            localAgentTerminal: terminal
        )
        let surfaces: [(name: String, view: NSView)] = [
            ("Toolbar", toolbar.view),
            ("Timeline", timeline.view),
            ("Terminal", terminal.view),
            ("Decision", decision.view),
            ("Composer", composer.view)
        ]
        let matrix: [(size: NSSize, terminalBodyVisible: Bool)] = [
            (NSSize(width: 560, height: 360), false),
            (NSSize(width: 560, height: 520), true),
            (NSSize(width: 840, height: 640), true)
        ]

        for entry in matrix {
            shell.view.frame = NSRect(origin: .zero, size: entry.size)
            shell.view.layoutSubtreeIfNeeded()

            XCTAssertEqual(
                terminal.isTerminalBodyVisibleForTesting,
                entry.terminalBodyVisible,
                "\(entry.size)：终端正文折叠状态必须遵守 < 520pt 的紧凑阈值"
            )
            XCTAssertGreaterThanOrEqual(
                timeline.view.frame.height,
                AgentConversationShellLayout.minimumTimelineHeight - 0.5,
                "\(entry.size)：Timeline 不得被辅助面挤出最低高度"
            )
            XCTAssertGreaterThanOrEqual(
                composer.view.frame.height,
                AgentConversationShellLayout.minimumComposerHeight - 0.5,
                "\(entry.size)：Composer 不得被辅助面挤出最低高度"
            )

            let toleratedBounds = shell.view.bounds.insetBy(dx: -0.5, dy: -0.5)
            let frameSummary = surfaces
                .map { "\($0.name)=\($0.view.frame)" }
                .joined(separator: ", ")
            for surface in surfaces where surface.view.isHidden == false {
                XCTAssertTrue(
                    toleratedBounds.contains(surface.view.frame),
                    "\(entry.size)：\(surface.name) 必须完整位于 shell bounds；\(frameSummary)"
                )
            }
            for firstIndex in surfaces.indices {
                for secondIndex in surfaces.indices where secondIndex > firstIndex {
                    let first = surfaces[firstIndex]
                    let second = surfaces[secondIndex]
                    guard first.view.isHidden == false, second.view.isHidden == false else { continue }
                    XCTAssertFalse(
                        first.view.frame.intersects(second.view.frame),
                        "\(entry.size)：\(first.name) 与 \(second.name) 不得重叠"
                    )
                }
            }
        }

        let detailsScroll = try XCTUnwrap(
            firstSubview(in: decision.view, identifier: "Stacio.AI.decisionCard.detailsScroll") as? NSScrollView
        )
        decision.view.layoutSubtreeIfNeeded()
        let documentHeight = try XCTUnwrap(detailsScroll.documentView).frame.height
        XCTAssertTrue(detailsScroll.hasVerticalScroller)
        XCTAssertGreaterThan(
            documentHeight,
            detailsScroll.documentVisibleRect.height,
            "长命令与审批依据必须保留完整文档，并在固定 Decision viewport 内滚动"
        )
    }

    func testSelectingRuntimeDoesNotStartCLIUntilFirstDurableDelivery() throws {
        let launcher = RecordingV2LocalAgentLauncher()
        let resolver = V2StaticLocalAgentResolver(paths: [.codex: "/tools/codex"])
        let controller = LocalAgentTerminalBlockViewController(
            resolver: resolver,
            processLauncherFactory: { launcher },
            runtimeLaunchAuthorizer: TestLocalAgentRuntimeLaunchAuthorizer()
        )
        let configuration = try XCTUnwrap(resolver.passthroughConfiguration(for: .codex))

        XCTAssertTrue(controller.select(configuration: configuration))
        XCTAssertNil(launcher.startedExecutable)
        XCTAssertEqual(controller.state, .ready(.codex))

        XCTAssertEqual(controller.send("inspect nginx"), .accepted)
        XCTAssertEqual(launcher.startedExecutable, "/tools/codex")
        XCTAssertEqual(launcher.sentInputs, [Array("inspect nginx\n".utf8)])
    }

    func testAskEveryTurnCancellationStartsNoProcessAndWritesNoInput() throws {
        let launcher = RecordingV2LocalAgentLauncher()
        let resolver = V2StaticLocalAgentResolver(
            paths: [.codex: "/tools/codex"],
            workingDirectoryMode: .askEveryTurn
        )
        let controller = LocalAgentTerminalBlockViewController(
            resolver: resolver,
            processLauncherFactory: { launcher },
            workingDirectorySelector: { nil },
            runtimeLaunchAuthorizer: TestLocalAgentRuntimeLaunchAuthorizer()
        )
        let configuration = try XCTUnwrap(resolver.passthroughConfiguration(for: .codex))
        XCTAssertTrue(controller.select(configuration: configuration))

        XCTAssertEqual(controller.send("inspect nginx"), .workingDirectorySelectionCancelled)
        XCTAssertNil(launcher.startedExecutable)
        XCTAssertTrue(launcher.sentInputs.isEmpty)
        XCTAssertTrue(controller.sentHistory.isEmpty)
    }

    func testAskEveryTurnRejectsNonCanonicalOrUnavailableDirectory() throws {
        let launcher = RecordingV2LocalAgentLauncher()
        let resolver = V2StaticLocalAgentResolver(
            paths: [.codex: "/tools/codex"],
            workingDirectoryMode: .askEveryTurn
        )
        let controller = LocalAgentTerminalBlockViewController(
            resolver: resolver,
            processLauncherFactory: { launcher },
            workingDirectorySelector: { NSTemporaryDirectory() + "../missing" },
            runtimeLaunchAuthorizer: TestLocalAgentRuntimeLaunchAuthorizer()
        )
        let configuration = try XCTUnwrap(resolver.passthroughConfiguration(for: .codex))
        XCTAssertTrue(controller.select(configuration: configuration))

        guard case .workingDirectoryUnavailable = controller.send("inspect nginx") else {
            return XCTFail("A non-canonical directory must fail closed")
        }
        XCTAssertNil(launcher.startedExecutable)
        XCTAssertTrue(launcher.sentInputs.isEmpty)
    }

    func testAskEveryTurnBindsSelectedLocalDirectoryWithoutUsingRemoteTargetDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("stacio-ask-every-turn-\(UUID().uuidString)", isDirectory: true)
        let selected = root.appendingPathComponent("selected", isDirectory: true)
        let tools = root.appendingPathComponent("tools", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let launcher = RecordingV2LocalAgentLauncher()
        let resolver = V2StaticLocalAgentResolver(
            paths: [.codex: "/tools/codex"],
            workingDirectoryMode: .askEveryTurn
        )
        let controller = LocalAgentTerminalBlockViewController(
            resolver: resolver,
            processLauncherFactory: { launcher },
            bridgeContextProvider: {
                LocalAgentBridgeContext(
                    socketPath: "/tmp/stacio-test.sock",
                    targetRuntimeID: "remote-runtime",
                    targetRuntimeGenerations: ["remote-runtime": 0],
                    targetTitle: "remote",
                    remoteCurrentDirectory: "/srv/production",
                    cliExecutablePath: "/tools/stacio",
                    toolsDirectory: tools.path,
                    workspaceDirectory: workspace.path
                )
            },
            workingDirectorySelector: { selected.path },
            runtimeLaunchAuthorizer: TestLocalAgentRuntimeLaunchAuthorizer()
        )
        let configuration = try XCTUnwrap(resolver.passthroughConfiguration(for: .codex))
        XCTAssertTrue(controller.select(configuration: configuration))

        XCTAssertEqual(controller.send("inspect nginx"), .accepted)
        XCTAssertEqual(launcher.startedCurrentDirectory, selected.path)
        XCTAssertNotEqual(launcher.startedCurrentDirectory, "/srv/production")
        XCTAssertEqual(controller.lastPreparedWorkingDirectoryForTesting, selected.path)
    }

    func testAskEveryTurnCannotRetargetRunningProcessWithoutStop() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("stacio-ask-retarget-\(UUID().uuidString)", isDirectory: true)
        let first = root.appendingPathComponent("first", isDirectory: true)
        let second = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var selectionCount = 0
        let launcher = RecordingV2LocalAgentLauncher()
        let resolver = V2StaticLocalAgentResolver(
            paths: [.codex: "/tools/codex"],
            workingDirectoryMode: .askEveryTurn
        )
        let controller = LocalAgentTerminalBlockViewController(
            resolver: resolver,
            processLauncherFactory: { launcher },
            workingDirectorySelector: {
                defer { selectionCount += 1 }
                return selectionCount == 0 ? first.path : second.path
            },
            runtimeLaunchAuthorizer: TestLocalAgentRuntimeLaunchAuthorizer()
        )
        let configuration = try XCTUnwrap(resolver.passthroughConfiguration(for: .codex))
        XCTAssertTrue(controller.select(configuration: configuration))

        XCTAssertEqual(controller.send("first"), .accepted)
        XCTAssertEqual(controller.send("second"), .workingDirectoryChangeRequiresRestart)
        XCTAssertEqual(launcher.startedCurrentDirectory, first.path)
        XCTAssertEqual(launcher.sentInputs, [Array("first\n".utf8)])
    }

    func testConfigurationEvidenceChangeAfterSelectionRejectsBeforeLaunch() throws {
        let launcher = RecordingV2LocalAgentLauncher()
        let initial = try XCTUnwrap(
            V2StaticLocalAgentResolver(paths: [.codex: "/tools/codex"])
                .passthroughConfiguration(for: .codex)
        )
        let resolver = MutableV2LocalAgentResolver(configuration: initial)
        let controller = LocalAgentTerminalBlockViewController(
            resolver: resolver,
            processLauncherFactory: { launcher },
            runtimeLaunchAuthorizer: TestLocalAgentRuntimeLaunchAuthorizer()
        )
        XCTAssertTrue(controller.select(configuration: initial))
        resolver.configuration = LocalAgentPassthroughConfiguration(
            configurationID: initial.configurationID,
            configurationRevision: initial.configurationRevision + 1,
            catalogID: initial.catalogID,
            catalogSetRevision: initial.catalogSetRevision,
            descriptorRevision: initial.descriptorRevision,
            tool: initial.tool,
            displayName: initial.displayName,
            executablePath: initial.executablePath,
            executableIdentityDigest: initial.executableIdentityDigest,
            executableReferenceConfirmedAt: initial.executableReferenceConfirmedAt,
            lastVerifiedAt: initial.lastVerifiedAt.addingTimeInterval(1),
            executionProfileID: initial.executionProfileID,
            executionProfileRevision: initial.executionProfileRevision,
            authenticationState: .authenticated,
            authenticationEvidenceRevision: "test-auth-2",
            cliAuthenticationScopeDigest: initial.cliAuthenticationScopeDigest,
            cliLoginIdentityDigest: initial.cliLoginIdentityDigest,
            environmentDigest: initial.environmentDigest,
            launchArguments: initial.launchArguments,
            launchEnvironment: initial.launchEnvironment,
            executableName: initial.executableName,
            pathPolicy: initial.pathPolicy,
            customPATHEntries: initial.customPATHEntries,
            environmentAllowlist: initial.environmentAllowlist,
            supportLevel: initial.supportLevel,
            explicitlyEnabled: initial.explicitlyEnabled
        )

        XCTAssertFalse(controller.canSelect(configuration: initial))
        XCTAssertEqual(controller.send("must not launch"), .configurationChanged)
        XCTAssertNil(launcher.startedExecutable)
        XCTAssertTrue(launcher.sentInputs.isEmpty)
    }

    func testReconciliationBlockedLaunchStartsNoProcessAndWritesNoInput() throws {
        let launcher = RecordingV2LocalAgentLauncher()
        let resolver = V2StaticLocalAgentResolver(paths: [.codex: "/tools/codex"])
        let authorizer = RecordingLocalAgentRuntimeLaunchAuthorizer()
        authorizer.error = .reconciliationRequired("maintenance-reference")
        let controller = LocalAgentTerminalBlockViewController(
            resolver: resolver,
            processLauncherFactory: { launcher },
            runtimeLaunchAuthorizer: authorizer
        )
        let configuration = try XCTUnwrap(resolver.passthroughConfiguration(for: .codex))
        XCTAssertTrue(controller.select(configuration: configuration))

        let result = controller.send("must not be delivered")

        guard case .launchBlocked(let reason) = result else {
            XCTFail("Expected reconciliation gate to block launch, got \(result)")
            return
        }
        XCTAssertTrue(reason.contains("对账"))
        XCTAssertNil(launcher.startedExecutable)
        XCTAssertTrue(launcher.sentInputs.isEmpty)
        XCTAssertEqual(authorizer.acquiredConfigurationIDs, [configuration.configurationID])
        XCTAssertEqual(
            authorizer.acquiredConfigurationRevisions,
            [Int64(configuration.configurationRevision)]
        )
        XCTAssertFalse(authorizer.usage.isInUse(configurationID: configuration.configurationID))
        XCTAssertEqual(controller.state, .blocked(.codex, reason: reason))
    }

    func testStaleRevisionBarrierStartsNoProcessAndWritesNoInput() throws {
        let launcher = RecordingV2LocalAgentLauncher()
        let resolver = V2StaticLocalAgentResolver(paths: [.codex: "/tools/codex"])
        let authorizer = RecordingLocalAgentRuntimeLaunchAuthorizer()
        authorizer.error = .configurationChanged
        let controller = LocalAgentTerminalBlockViewController(
            resolver: resolver,
            processLauncherFactory: { launcher },
            runtimeLaunchAuthorizer: authorizer
        )
        let configuration = try XCTUnwrap(resolver.passthroughConfiguration(for: .codex))
        XCTAssertTrue(controller.select(configuration: configuration))

        let result = controller.send("must not be delivered")

        guard case .launchBlocked(let reason) = result else {
            XCTFail("Expected stale revision to block launch, got \(result)")
            return
        }
        XCTAssertTrue(reason.contains("已变更"))
        XCTAssertNil(launcher.startedExecutable)
        XCTAssertTrue(launcher.sentInputs.isEmpty)
        XCTAssertEqual(authorizer.acquiredConfigurationIDs, [configuration.configurationID])
        XCTAssertEqual(
            authorizer.acquiredConfigurationRevisions,
            [Int64(configuration.configurationRevision)]
        )
        XCTAssertFalse(authorizer.usage.isInUse(configurationID: configuration.configurationID))
    }

    func testRuntimeUsageRemainsRegisteredUntilObservedProcessExit() throws {
        let launcher = RecordingV2LocalAgentLauncher()
        let resolver = V2StaticLocalAgentResolver(paths: [.codex: "/tools/codex"])
        let authorizer = RecordingLocalAgentRuntimeLaunchAuthorizer()
        let controller = LocalAgentTerminalBlockViewController(
            resolver: resolver,
            processLauncherFactory: { launcher },
            runtimeLaunchAuthorizer: authorizer
        )
        let configuration = try XCTUnwrap(resolver.passthroughConfiguration(for: .codex))
        XCTAssertTrue(controller.select(configuration: configuration))

        XCTAssertEqual(controller.send("first"), .accepted)
        XCTAssertTrue(authorizer.usage.isInUse(configurationID: configuration.configurationID))
        XCTAssertEqual(controller.send("second"), .accepted)
        XCTAssertEqual(
            authorizer.acquiredConfigurationIDs,
            [configuration.configurationID],
            "An already-running PTY must keep its original lease instead of acquiring another"
        )

        let session = try XCTUnwrap(controller.activeSessionForTesting)
        launcher.running = false
        session.processTerminated(source: session.terminalView, exitCode: 0)

        XCTAssertFalse(authorizer.usage.isInUse(configurationID: configuration.configurationID))
        XCTAssertEqual(controller.state, .terminated(.codex, exitCode: 0))
        session.processTerminated(source: session.terminalView, exitCode: 0)
        XCTAssertFalse(authorizer.usage.isInUse(configurationID: configuration.configurationID))
    }

    func testFailedProcessStartReleasesRuntimeUsage() throws {
        let launcher = RecordingV2LocalAgentLauncher()
        launcher.startsSuccessfully = false
        let resolver = V2StaticLocalAgentResolver(paths: [.codex: "/tools/codex"])
        let authorizer = RecordingLocalAgentRuntimeLaunchAuthorizer()
        let controller = LocalAgentTerminalBlockViewController(
            resolver: resolver,
            processLauncherFactory: { launcher },
            runtimeLaunchAuthorizer: authorizer
        )
        let configuration = try XCTUnwrap(resolver.passthroughConfiguration(for: .codex))
        XCTAssertTrue(controller.select(configuration: configuration))

        XCTAssertEqual(controller.send("must not be delivered"), .notRunning)

        XCTAssertEqual(authorizer.acquiredConfigurationIDs, [configuration.configurationID])
        XCTAssertFalse(authorizer.usage.isInUse(configurationID: configuration.configurationID))
        XCTAssertTrue(launcher.sentInputs.isEmpty)
    }

    func testSessionDeinitReleasesLiveRuntimeUsage() throws {
        let launcher = RecordingV2LocalAgentLauncher()
        let resolver = V2StaticLocalAgentResolver(paths: [.codex: "/tools/codex"])
        let configuration = try XCTUnwrap(resolver.passthroughConfiguration(for: .codex))
        let authorizer = RecordingLocalAgentRuntimeLaunchAuthorizer()
        var session: LocalAgentSessionViewController? = LocalAgentSessionViewController(
            tool: .codex,
            resolver: resolver,
            processLauncher: launcher,
            requiresVerifiedConfiguration: true,
            runtimeLaunchAuthorizer: authorizer
        )
        _ = session?.view
        session?.startIfNeeded()
        XCTAssertTrue(authorizer.usage.isInUse(configurationID: configuration.configurationID))

        session = nil

        XCTAssertFalse(authorizer.usage.isInUse(configurationID: configuration.configurationID))
    }

    func testReselectingRunningConfigurationPreservesRunningState() throws {
        let launcher = RecordingV2LocalAgentLauncher()
        let resolver = V2StaticLocalAgentResolver(paths: [.codex: "/tools/codex"])
        let controller = LocalAgentTerminalBlockViewController(
            resolver: resolver,
            processLauncherFactory: { launcher },
            runtimeLaunchAuthorizer: TestLocalAgentRuntimeLaunchAuthorizer()
        )
        let configuration = try XCTUnwrap(resolver.passthroughConfiguration(for: .codex))
        XCTAssertTrue(controller.select(configuration: configuration))
        XCTAssertEqual(controller.send("start"), .accepted)
        let runningState = controller.state

        XCTAssertTrue(controller.select(configuration: configuration))
        XCTAssertEqual(controller.state, runningState)
        XCTAssertTrue(controller.state.isRunning)
    }

    func testComposerCannotBecomeSensitivePTYInputAndDirectTerminalInputStaysPrivate() throws {
        let launcher = RecordingV2LocalAgentLauncher()
        let controller = LocalAgentTerminalBlockViewController(
            resolver: V2StaticLocalAgentResolver(paths: [.codex: "/tools/codex"]),
            processLauncherFactory: { launcher },
            runtimeLaunchAuthorizer: TestLocalAgentRuntimeLaunchAuthorizer()
        )
        XCTAssertTrue(controller.activate(tool: .codex))
        let session = try XCTUnwrap(controller.activeSessionForTesting)

        session.terminalView.dataReceived(slice: ArraySlice(Array("Password:".utf8)))

        XCTAssertTrue(session.isAwaitingSensitiveInputForTesting)
        XCTAssertEqual(controller.send("this-is-not-a-password"), .sensitiveInputRequired)
        XCTAssertTrue(launcher.sentInputs.isEmpty)
        XCTAssertTrue(controller.sentHistory.isEmpty)
        XCTAssertTrue(controller.statusTextForTesting.contains("直接在终端中输入"))

        session.terminalView.send(
            source: session.terminalView,
            data: ArraySlice(Array("private-value".utf8))
        )
        session.terminalView.send(source: session.terminalView, data: ArraySlice([13]))

        XCTAssertEqual(launcher.sentInputs, [Array("private-value".utf8), [13]])
        XCTAssertFalse(session.isAwaitingSensitiveInputForTesting)
        XCTAssertTrue(controller.sentHistory.isEmpty, "Sensitive PTY bytes must never enter Composer history")
    }

    func testActivationFailsWhenLauncherDoesNotEstablishAProcess() {
        let launcher = RecordingV2LocalAgentLauncher()
        launcher.startsSuccessfully = false
        let controller = LocalAgentTerminalBlockViewController(
            resolver: V2StaticLocalAgentResolver(paths: [.codex: "/tools/codex"]),
            processLauncherFactory: { launcher },
            runtimeLaunchAuthorizer: TestLocalAgentRuntimeLaunchAuthorizer()
        )

        XCTAssertFalse(controller.activate(tool: .codex))
        XCTAssertEqual(controller.state, .terminated(.codex, exitCode: nil))
        XCTAssertEqual(controller.send("must-not-send"), .notRunning)
        XCTAssertTrue(launcher.sentInputs.isEmpty)
    }

    func testCollapsingTerminalBlockReturnsHeightToTimeline() throws {
        let controller = LocalAgentTerminalBlockViewController(
            resolver: V2StaticLocalAgentResolver(paths: [.codex: "/tools/codex"]),
            processLauncherFactory: { RecordingV2LocalAgentLauncher() },
            runtimeLaunchAuthorizer: TestLocalAgentRuntimeLaunchAuthorizer()
        )
        XCTAssertTrue(controller.activate(tool: .codex))
        controller.view.layoutSubtreeIfNeeded()
        let expandedHeight = controller.view.fittingSize.height
        let collapseButton = try XCTUnwrap(
            controller.view.allSubviews(ofType: NSButton.self).first { $0.toolTip == "折叠终端块" }
        )

        XCTAssertTrue(NSApp.sendAction(
            try XCTUnwrap(collapseButton.action),
            to: collapseButton.target,
            from: collapseButton
        ))
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertFalse(controller.terminalVisibleForTesting)
        XCTAssertEqual(collapseButton.toolTip, "展开终端块")
        XCTAssertLessThan(controller.view.fittingSize.height, expandedHeight - 100)
    }

    func testStopTerminatesOnlySelectedPTYAndBlocksRuntimeChangeUntilExit() throws {
        let launcher = RecordingV2LocalAgentLauncher()
        let controller = LocalAgentTerminalBlockViewController(
            resolver: V2StaticLocalAgentResolver(paths: [.claude: "/tools/claude"]),
            processLauncherFactory: { launcher },
            runtimeLaunchAuthorizer: TestLocalAgentRuntimeLaunchAuthorizer()
        )

        XCTAssertTrue(controller.activate(tool: .claude))
        controller.stop()

        XCTAssertTrue(launcher.terminated)
        XCTAssertEqual(controller.state, .terminating(.claude))
        XCTAssertFalse(controller.deactivateIfStopped())

        let session = try XCTUnwrap(controller.activeSessionForTesting)
        launcher.running = false
        session.processTerminated(source: session.terminalView, exitCode: nil)

        XCTAssertEqual(controller.state, .terminated(.claude, exitCode: nil))
        XCTAssertTrue(controller.deactivateIfStopped())
        XCTAssertEqual(controller.state, .hidden)
    }

    func testHostClosureTerminatesRunningPTYAndRevokesRunningState() {
        let launcher = RecordingV2LocalAgentLauncher()
        launcher.stopsSynchronously = true
        let controller = LocalAgentTerminalBlockViewController(
            resolver: V2StaticLocalAgentResolver(paths: [.claude: "/tools/claude"]),
            processLauncherFactory: { launcher },
            runtimeLaunchAuthorizer: TestLocalAgentRuntimeLaunchAuthorizer()
        )

        XCTAssertTrue(controller.activate(tool: .claude))
        XCTAssertTrue(controller.requiresHostClosureTermination)

        controller.terminateForHostClosure()

        XCTAssertTrue(launcher.terminated)
        XCTAssertFalse(controller.requiresHostClosureTermination)
        XCTAssertEqual(controller.state, .terminated(.claude, exitCode: nil))
    }

    func testUnavailableCLIStartsNoProcessAndAcceptsNoInput() {
        let launcher = RecordingV2LocalAgentLauncher()
        let controller = LocalAgentTerminalBlockViewController(
            resolver: V2StaticLocalAgentResolver(paths: [:]),
            processLauncherFactory: { launcher },
            runtimeLaunchAuthorizer: TestLocalAgentRuntimeLaunchAuthorizer()
        )

        XCTAssertFalse(controller.activate(tool: .qwenCode))
        XCTAssertEqual(controller.state, .unavailable(.qwenCode))
        XCTAssertEqual(controller.send("hello"), .notRunning)
        XCTAssertNil(launcher.startedExecutable)
        XCTAssertTrue(launcher.sentInputs.isEmpty)
    }

    func testPathDiscoveryAloneCannotAuthorizeTerminalPassthrough() {
        let resolver = LocalAgentToolResolver(
            environment: ["PATH": "/tools"],
            homeDirectory: "/Users/test",
            isExecutable: { $0 == "/tools/codex" }
        )

        XCTAssertEqual(resolver.executablePath(for: .codex), "/tools/codex")
        XCTAssertNil(resolver.passthroughConfiguration(for: .codex))
    }

    func testLegacyCompatibilityKeepsRunningPTYAndRebuildsAfterExecutablePathChanges() throws {
        let resolver = MutableLegacyLocalAgentResolver(paths: [.codex: "/tools/codex-v1"])
        var launchers: [RecordingV2LocalAgentLauncher] = []
        let controller = LocalAgentTerminalBlockViewController(
            resolver: resolver,
            processLauncherFactory: {
                let launcher = RecordingV2LocalAgentLauncher()
                launcher.stopsSynchronously = true
                launchers.append(launcher)
                return launcher
            },
            runtimeLaunchAuthorizer: nil
        )

        XCTAssertTrue(controller.selectLegacy(tool: .codex))
        XCTAssertEqual(controller.send("first"), .accepted)
        XCTAssertEqual(try XCTUnwrap(launchers.first).startedExecutable, "/tools/codex-v1")

        resolver.paths[.codex] = nil
        XCTAssertTrue(
            controller.selectLegacy(tool: .codex),
            "A PATH mutation must not orphan an already-running managed PTY"
        )
        XCTAssertEqual(controller.send("second"), .accepted)
        XCTAssertEqual(try XCTUnwrap(launchers.first).sentInputs.count, 2)

        controller.stop()
        XCTAssertEqual(controller.state, .terminated(.codex, exitCode: nil))
        resolver.paths[.codex] = "/tools/codex-v2"

        XCTAssertTrue(controller.selectLegacy(tool: .codex))
        XCTAssertEqual(controller.send("third"), .accepted)
        XCTAssertEqual(launchers.count, 2)
        XCTAssertEqual(launchers[1].startedExecutable, "/tools/codex-v2")
        XCTAssertEqual(launchers[1].sentInputs, [Array("third\n".utf8)])
    }
}

private final class RecordingLocalAgentProcessDelegate: LocalProcessTerminalViewDelegate {
    private let terminated: XCTestExpectation

    init(terminated: XCTestExpectation) {
        self.terminated = terminated
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        terminated.fulfill()
    }
}

private func firstSubview(in root: NSView, identifier: String) -> NSView? {
    if root.accessibilityIdentifier() == identifier { return root }
    for child in root.subviews {
        if let match = firstSubview(in: child, identifier: identifier) { return match }
    }
    return nil
}

private extension NSView {
    func allSubviews<T: NSView>(ofType type: T.Type) -> [T] {
        subviews.flatMap { subview -> [T] in
            var matches = subview.allSubviews(ofType: type)
            if let typed = subview as? T {
                matches.insert(typed, at: 0)
            }
            return matches
        }
    }
}

private struct V2StaticLocalAgentResolver: LocalAgentToolResolving {
    let paths: [LocalAgentTool: String]
    let workingDirectoryMode: AgentProcessWorkingDirectoryMode
    let workingDirectoryReference: String?

    init(
        paths: [LocalAgentTool: String],
        workingDirectoryMode: AgentProcessWorkingDirectoryMode = .userSelectedLocalDirectory,
        workingDirectoryReference: String? = nil
    ) {
        self.paths = paths
        self.workingDirectoryMode = workingDirectoryMode
        if workingDirectoryMode == .userSelectedLocalDirectory,
           workingDirectoryReference == nil {
            self.workingDirectoryReference = FileManager.default.temporaryDirectory
                .resolvingSymlinksInPath().path
        } else {
            self.workingDirectoryReference = workingDirectoryReference
        }
    }

    func executablePath(for tool: LocalAgentTool) -> String? {
        paths[tool]
    }

    func passthroughConfiguration(for tool: LocalAgentTool) -> LocalAgentPassthroughConfiguration? {
        guard let path = paths[tool] else { return nil }
        let launchEnvironment = [
            "PATH=/tools",
            "STACIO_LOCAL_AGENT=\(tool.catalogRawIdentity)"
        ].sorted()
        return LocalAgentPassthroughConfiguration(
            configurationID: "test-config-\(tool.rawValue)",
            configurationRevision: 1,
            catalogID: "local-agent.\(tool.rawValue)",
            catalogSetRevision: 1,
            descriptorRevision: 1,
            tool: tool,
            displayName: tool.displayName,
            executablePath: path,
            executableIdentityDigest: "test-executable-\(tool.rawValue)",
            executableReferenceConfirmedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastVerifiedAt: Date(timeIntervalSince1970: 1_700_000_001),
            executionProfileID: "test-profile-\(tool.rawValue)",
            executionProfileRevision: 1,
            authenticationState: .authenticated,
            authenticationEvidenceRevision: "test-auth-1",
            cliAuthenticationScopeDigest: "test-scope",
            cliLoginIdentityDigest: "test-login",
            environmentDigest: LocalAgentConfigurationIntegrity.environmentDigest(launchEnvironment),
            launchArguments: tool.embeddedTerminalArguments,
            launchEnvironment: launchEnvironment,
            executableName: URL(fileURLWithPath: path).lastPathComponent,
            workingDirectoryMode: workingDirectoryMode,
            workingDirectoryReference: workingDirectoryReference,
            supportLevel: .experimental,
            explicitlyEnabled: true
        )
    }
}

private final class MutableV2LocalAgentResolver: LocalAgentToolResolving {
    var configuration: LocalAgentPassthroughConfiguration?

    init(configuration: LocalAgentPassthroughConfiguration?) {
        self.configuration = configuration
    }

    func executablePath(for tool: LocalAgentTool) -> String? {
        configuration?.tool == tool ? configuration?.executablePath : nil
    }

    func passthroughConfiguration(for tool: LocalAgentTool) -> LocalAgentPassthroughConfiguration? {
        configuration?.tool == tool ? configuration : nil
    }
}

private final class MutableLegacyLocalAgentResolver: LocalAgentToolResolving {
    var paths: [LocalAgentTool: String]

    init(paths: [LocalAgentTool: String]) {
        self.paths = paths
    }

    func executablePath(for tool: LocalAgentTool) -> String? {
        nil
    }

    func legacyExecutablePath(for tool: LocalAgentTool) -> String? {
        paths[tool]
    }
}

private final class RecordingV2LocalAgentLauncher: LocalTerminalProcessLaunching {
    private(set) var startedExecutable: String?
    private(set) var startedArguments: [String]?
    private(set) var startedCurrentDirectory: String?
    private(set) var sentInputs: [[UInt8]] = []
    private(set) var terminated = false
    var running = false
    var startsSuccessfully = true
    var stopsSynchronously = false
    private let processIdentifier: Int32 = 9_002
    private let trustedStartTime = Date(timeIntervalSince1970: 1_700_000_001)

    func isRunning(_ terminalView: LocalProcessTerminalView) -> Bool {
        running
    }

    func managedProcessGroupID(_ terminalView: LocalProcessTerminalView) -> Int32? {
        isRunning(terminalView) ? 9_002 : nil
    }

    func managedProcessIdentifier(_ terminalView: LocalProcessTerminalView) -> Int32? {
        isRunning(terminalView) ? processIdentifier : nil
    }

    func managedProcessTrustedStartTime(_ terminalView: LocalProcessTerminalView) -> Date? {
        isRunning(terminalView) ? trustedStartTime : nil
    }

    func startProcess(
        in terminalView: LocalProcessTerminalView,
        executable: String,
        args: [String],
        environment: [String]?,
        execName: String?,
        currentDirectory: String?
    ) {
        startedExecutable = executable
        startedArguments = args
        startedCurrentDirectory = currentDirectory
        running = startsSuccessfully
    }

    func terminate(_ terminalView: LocalProcessTerminalView) {
        terminated = true
        if stopsSynchronously {
            running = false
        }
    }

    func sendInput(_ bytes: [UInt8], to terminalView: LocalProcessTerminalView) {
        sentInputs.append(bytes)
    }
}

private final class TestLocalAgentRuntimeLaunchAuthorizer: LocalAgentRuntimeLaunchAuthorizing {
    private let usage = LocalAgentRuntimeUsageRegistry()

    func acquireUsage(
        configurationID: String,
        expectedConfigurationRevision: Int64
    ) throws -> LocalAgentRuntimeUsageLease {
        try XCTUnwrap(usage.acquireUsage(configurationID: configurationID))
    }
}

private final class RecordingLocalAgentRuntimeLaunchAuthorizer: LocalAgentRuntimeLaunchAuthorizing {
    let usage = LocalAgentRuntimeUsageRegistry()
    var error: LocalAgentRuntimeLaunchAuthorizationError?
    private(set) var acquiredConfigurationIDs: [String] = []
    private(set) var acquiredConfigurationRevisions: [Int64] = []

    func acquireUsage(
        configurationID: String,
        expectedConfigurationRevision: Int64
    ) throws -> LocalAgentRuntimeUsageLease {
        acquiredConfigurationIDs.append(configurationID)
        acquiredConfigurationRevisions.append(expectedConfigurationRevision)
        if let error { throw error }
        return try XCTUnwrap(usage.acquireUsage(configurationID: configurationID))
    }
}
