import Foundation
import XCTest
@testable import StacioApp

final class LocalAgentSettingsCoordinatorTests: XCTestCase {
    func testOwnerRegistrationCoversEveryLocalAgentBusinessAction() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let harness = try makeHarness(
            fixture: fixture,
            detector: StubDetector { _, _ in .init(candidates: [], failures: []) }
        )

        try harness.registerOwners()

        for actionID in [
            "localAgent.detect",
            "localAgent.changeExecutionProfile",
            "localAgent.login",
            "localAgent.logout",
            "localAgent.reconcileProcesses",
            "localAgent.openUpgrade",
            "configuration.delete"
        ] {
            XCTAssertTrue(harness.actions.hasBusinessOwner(for: actionID), actionID)
        }
        XCTAssertTrue(harness.configurationDeleteRouter.hasOwner(for: .localAgent))
    }

    func testCodingPlanTargetsExposeOnlySupportedCompatibleCLIPlans() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let harness = try makeHarness(
            fixture: fixture,
            detector: StubDetector { _, _ in .init(candidates: [], failures: []) }
        )

        XCTAssertEqual(
            Set(harness.settings.codingPlanTargets().map(\.codingPlanCatalogID)),
            Set([
                "coding-plan.chatgpt-codex",
                "coding-plan.claude-code",
                "coding-plan.github-copilot",
                "coding-plan.gemini-cli"
            ])
        )
        XCTAssertFalse(harness.settings.codingPlanTargets().contains {
            $0.codingPlanCatalogID == "coding-plan.aliyun"
                || $0.codingPlanCatalogID == "coding-plan.glm"
        })
    }

    func testCodingPlanTargetsFailClosedWhenCLIBoundaryIsMalformed() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let base = try XCTUnwrap(fixture.catalog.catalogSet)
        let plan = try XCTUnwrap(base.codingPlan(catalogID: "coding-plan.chatgpt-codex"))
        let compatibility = try XCTUnwrap(base.planAgentCompatibility.first {
            $0.planID == plan.planID
        })
        let agent = try XCTUnwrap(base.localAgent(rawIdentity: compatibility.agentRawIdentity))
        let malformedSets: [(String, RuntimeCatalogSet)] = [
            (
                "credential owner",
                replacing(in: base, plan: copy(plan, credentialOwner: .stacioKeychain))
            ),
            (
                "authentication kind",
                replacing(in: base, plan: copy(plan, authenticationKind: .bearerAPIKey))
            ),
            (
                "model discovery",
                replacing(in: base, plan: copy(plan, modelDiscoveryStrategy: .openAIModels))
            ),
            (
                "runtime kind",
                replacing(in: base, plan: copy(plan, allowedRuntimeKinds: [.nativeAPI, .localAgent]))
            ),
            (
                "credential injection",
                replacing(
                    in: base,
                    compatibility: copy(
                        compatibility,
                        credentialInjectionKind: .officialCLIConfiguration
                    )
                )
            ),
            (
                "compatibility terminal capability",
                replacing(
                    in: base,
                    compatibility: copy(compatibility, allowedCapabilities: ["toolCalls"])
                )
            ),
            (
                "agent terminal capability",
                replacing(
                    in: base,
                    agent: copy(agent, supportedCapabilities: ["toolCalls"])
                )
            ),
            (
                "agent terminal profile",
                replacing(in: base, agent: copy(agent, executionProfiles: []))
            )
        ]

        for (boundary, set) in malformedSets {
            let harness = try makeHarness(
                fixture: fixture,
                detector: StubDetector { _, _ in .init(candidates: [], failures: []) },
                catalog: BundledRuntimeCatalog(set: set)
            )

            XCTAssertFalse(
                harness.settings.codingPlanTargets().contains {
                    $0.codingPlanCatalogID == plan.catalogID
                },
                "Malformed \(boundary) must fail closed"
            )
        }
    }

    func testCatalogWebsiteActionOpensVerifiedCodingPlanConsoleWithoutConfiguration() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let opener = RecordingLocalAgentWebsiteOpener()
        let harness = try makeHarness(
            fixture: fixture,
            detector: StubDetector { _, _ in .init(candidates: [], failures: []) },
            websiteOpener: opener
        )
        try harness.registerOwners()

        let result = invoke(
            owner: try XCTUnwrap(harness.owners.owner(for: "localAgent.openUpgrade")),
            request: .init(
                actionID: "localAgent.openUpgrade",
                operationID: "open-codex-plan",
                parameters: [
                    "catalogID": .string("coding-plan.chatgpt-codex"),
                    "websiteActionID": .string("coding-plan.codex.open")
                ]
            )
        )

        XCTAssertEqual(result, .succeeded(proofDigest: "website-action:coding-plan.codex.open"))
        XCTAssertEqual(opener.openedURLs.map(\.absoluteString), ["https://chatgpt.com/codex"])
    }

    func testCatalogWebsiteActionRejectsUnsupportedAndMismatchedPlans() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let opener = RecordingLocalAgentWebsiteOpener()
        let harness = try makeHarness(
            fixture: fixture,
            detector: StubDetector { _, _ in .init(candidates: [], failures: []) },
            websiteOpener: opener
        )
        try harness.registerOwners()
        let owner = try XCTUnwrap(harness.owners.owner(for: "localAgent.openUpgrade"))

        XCTAssertEqual(
            invoke(
                owner: owner,
                request: .init(
                    actionID: "localAgent.openUpgrade",
                    operationID: "open-unsupported-plan",
                    parameters: [
                        "catalogID": .string("coding-plan.aliyun"),
                        "websiteActionID": .string("coding-plan.aliyun.manage")
                    ]
                )
            ),
            .failed(reasonCode: "verified_website_action_unavailable")
        )
        XCTAssertEqual(
            invoke(
                owner: owner,
                request: .init(
                    actionID: "localAgent.openUpgrade",
                    operationID: "open-mismatched-plan",
                    parameters: [
                        "catalogID": .string("coding-plan.chatgpt-codex"),
                        "websiteActionID": .string("coding-plan.claude.open")
                    ]
                )
            ),
            .failed(reasonCode: "verified_website_action_unavailable")
        )
        XCTAssertTrue(opener.openedURLs.isEmpty)
    }

    func testOwnerRegistrationIsAtomicWhenAnyActionAlreadyHasOwner() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let harness = try makeHarness(
            fixture: fixture,
            detector: StubDetector { _, _ in .init(candidates: [], failures: []) }
        )
        try harness.actions.registerOwner(for: "localAgent.login") { _, completion in
            completion(.failed(reasonCode: "existing_owner"))
        }

        XCTAssertThrowsError(try harness.registerOwners())

        for actionID in [
            "localAgent.detect",
            "localAgent.changeExecutionProfile",
            "localAgent.logout",
            "localAgent.reconcileProcesses",
            "localAgent.openUpgrade"
        ] {
            XCTAssertFalse(
                harness.actions.hasBusinessOwner(for: actionID),
                "A failed aggregate registration must not leave a partial owner for \(actionID)"
            )
        }
        XCTAssertTrue(harness.actions.hasBusinessOwner(for: "localAgent.login"))
        XCTAssertTrue(harness.actions.hasBusinessOwner(for: "configuration.delete"))
        XCTAssertFalse(harness.configurationDeleteRouter.hasOwner(for: .localAgent))
    }

    func testPreviewDetectionUsesOneProcessWideSlotAndReleasesIt() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let entered = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let detector = StubDetector { _, _ in
            entered.signal()
            _ = resume.wait(timeout: .now() + 2)
            return .init(candidates: [], failures: [])
        }
        let gate = LocalAgentSettingsOperationGate()
        let harness = try makeHarness(fixture: fixture, detector: detector, gate: gate)
        let first = expectation(description: "first preview")

        harness.settings.previewDetection(catalogID: fixture.descriptor.catalogID) { result in
            if case .failure(let error) = result {
                XCTFail("Unexpected first preview failure: \(error)")
            }
            first.fulfill()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)

        let second = expectation(description: "second preview rejected")
        harness.settings.previewDetection(catalogID: fixture.descriptor.catalogID) { result in
            XCTAssertEqual(
                result.failure as? LocalAgentSettingsCoordinatorError,
                .busy
            )
            second.fulfill()
        }
        wait(for: [second], timeout: 1)
        XCTAssertTrue(gate.hasActiveOperation)

        resume.signal()
        wait(for: [first], timeout: 2)
        XCTAssertFalse(gate.hasActiveOperation)
    }

    func testStartedPreviewSurvivesCoordinatorReleaseWithoutLeakingGate() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let entered = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let detector = StubDetector { _, _ in
            entered.signal()
            _ = resume.wait(timeout: .now() + 2)
            return .init(candidates: [], failures: [])
        }
        let gate = LocalAgentSettingsOperationGate()
        var harness: Harness? = try makeHarness(fixture: fixture, detector: detector, gate: gate)
        let completed = expectation(description: "preview completion")

        harness?.settings.previewDetection(catalogID: fixture.descriptor.catalogID) { result in
            XCTAssertNotNil(try? result.get())
            completed.fulfill()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        harness = nil
        resume.signal()

        wait(for: [completed], timeout: 2)
        XCTAssertFalse(gate.hasActiveOperation)
    }

    func testConfirmedDetectionRejectsCandidateChangedAfterPreview() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let changed = fixture.detected(authenticationState: .authenticated, digest: String(repeating: "f", count: 64))
        let detector = StubDetector { _, _ in
            .init(candidates: [changed], failures: [])
        }
        let harness = try makeHarness(fixture: fixture, detector: detector)
        try harness.registerOwners()

        let result = invoke(
            owner: try XCTUnwrap(harness.owners.owner(for: "localAgent.detect")),
            request: .init(
                actionID: "localAgent.detect",
                operationID: "detect-toctou",
                parameters: fixture.detectionParameters()
            )
        )

        XCTAssertEqual(result, .failed(reasonCode: "confirmed_candidate_changed"))
        XCTAssertEqual(harness.store.saveCount, 0)
        XCTAssertFalse(harness.gate.hasActiveOperation)
    }

    func testAskEveryTurnDetectionPersistsWithoutStoredDirectoryReference() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = InMemoryConfigurationStore()
        let harness = try makeHarness(
            fixture: fixture,
            detector: StubDetector { _, _ in
                .init(
                    candidates: [fixture.detected(authenticationState: .authenticated)],
                    failures: []
                )
            },
            store: store
        )
        try harness.registerOwners()
        var parameters = fixture.detectionParameters()
        parameters["workingDirectoryMode"] = .string(
            AgentProcessWorkingDirectoryMode.askEveryTurn.rawValue
        )
        parameters.removeValue(forKey: "workingDirectoryReference")

        let result = invoke(
            owner: try XCTUnwrap(harness.owners.owner(for: "localAgent.detect")),
            request: .init(
                actionID: "localAgent.detect",
                operationID: "detect-ask-every-turn",
                parameters: parameters
            )
        )

        guard case .succeeded = result else {
            XCTFail("Expected askEveryTurn detection to succeed, got \(String(describing: result))")
            return
        }
        let saved = try XCTUnwrap(store.record(configurationID: "local-agent-new"))
        XCTAssertEqual(saved.workingDirectoryMode, .askEveryTurn)
        XCTAssertNil(saved.workingDirectoryReference)
    }

    func testStaleMaintenanceRevisionNeverPresentsTerminal() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let original = try fixture.record(authenticationState: .needsLogin, revision: 3)
        let store = InMemoryConfigurationStore(records: [original])
        let presenter = StubMaintenancePresenter()
        let harness = try makeHarness(
            fixture: fixture,
            detector: StubDetector { _, _ in .init(candidates: [], failures: []) },
            store: store,
            presenter: presenter
        )
        try harness.registerOwners()

        let result = invoke(
            owner: try XCTUnwrap(harness.owners.owner(for: "localAgent.login")),
            request: .init(
                actionID: "localAgent.login",
                operationID: "login-stale",
                parameters: [
                    "configurationID": .string(original.configurationID),
                    "expectedRevision": .int(2)
                ]
            )
        )

        XCTAssertEqual(result, .failed(reasonCode: "stale_configuration"))
        XCTAssertEqual(presenter.presentationCount, 0)
        XCTAssertFalse(harness.gate.hasActiveOperation)
    }

    func testLoginReprobesAuthenticationAndIgnoresDuplicatePresenterCompletion() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let original = try fixture.record(authenticationState: .needsLogin, revision: 4)
        let refreshed = fixture.detected(authenticationState: .authenticated)
        let detector = StubDetector { _, _ in
            .init(candidates: [refreshed], failures: [])
        }
        let store = InMemoryConfigurationStore(records: [original])
        let presenter = StubMaintenancePresenter()
        let harness = try makeHarness(
            fixture: fixture,
            detector: detector,
            store: store,
            presenter: presenter
        )
        try harness.registerOwners()
        let completion = expectation(description: "login settled")
        completion.expectedFulfillmentCount = 1
        var results: [AssistantSettingsActionExecutionResult] = []

        try XCTUnwrap(harness.owners.owner(for: "localAgent.login"))(
            .init(
                actionID: "localAgent.login",
                operationID: "login-success",
                parameters: [
                    "configurationID": .string(original.configurationID),
                    "expectedRevision": .int(Int(original.configurationRevision))
                ]
            )
        ) { result in
            results.append(result)
            completion.fulfill()
        }
        XCTAssertTrue(presenter.waitUntilPresented())
        XCTAssertEqual(presenter.processStartAccepted, true)
        XCTAssertEqual(
            try harness.journal.entry(referenceID: "login-success")?.state,
            .running
        )
        presenter.complete(.exited(exitCode: 0))
        presenter.complete(.exited(exitCode: 0))

        wait(for: [completion], timeout: 2)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(store.saveCount, 1)
        XCTAssertEqual(try store.record(configurationID: original.configurationID)?.authenticationState, .authenticated)
        let journalEntry = try XCTUnwrap(harness.journal.entry(referenceID: "login-success"))
        XCTAssertEqual(journalEntry.state, .completed)
        XCTAssertEqual(journalEntry.processIdentifier, 4_200)
        XCTAssertEqual(journalEntry.processGroupIdentifier, 4_200)
        XCTAssertEqual(
            journalEntry.trustedProcessStartTime,
            Date(timeIntervalSince1970: 1_786_400_001)
        )
        XCTAssertTrue(journalEntry.treeExited)
        XCTAssertTrue(journalEntry.businessResultCommitted)
        XCTAssertFalse(harness.gate.hasActiveOperation)
    }

    func testNonzeroMaintenanceExitFailsAfterWholeTreeSettlement() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let original = try fixture.record(authenticationState: .needsLogin, revision: 1)
        let store = InMemoryConfigurationStore(records: [original])
        let presenter = StubMaintenancePresenter()
        let harness = try makeHarness(
            fixture: fixture,
            detector: StubDetector { _, _ in
                XCTFail("A nonzero maintenance exit must not re-probe authentication")
                return .init(candidates: [], failures: [])
            },
            store: store,
            presenter: presenter
        )
        try harness.registerOwners()
        let completed = expectation(description: "nonzero exit settled")
        var received: AssistantSettingsActionExecutionResult?

        try XCTUnwrap(harness.owners.owner(for: "localAgent.login"))(
            maintenanceActionRequest(
                actionID: "localAgent.login",
                operationID: "login-nonzero",
                record: original
            )
        ) {
            received = $0
            completed.fulfill()
        }
        XCTAssertTrue(presenter.waitUntilPresented())
        XCTAssertEqual(presenter.processStartAccepted, true)
        presenter.complete(.exited(exitCode: 7))

        wait(for: [completed], timeout: 2)
        XCTAssertEqual(received, .failed(reasonCode: "maintenance_exit_7"))
        let journalEntry = try XCTUnwrap(harness.journal.entry(referenceID: "login-nonzero"))
        XCTAssertEqual(journalEntry.state, .failed)
        XCTAssertEqual(journalEntry.exitCode, 7)
        XCTAssertEqual(journalEntry.failureReason, "maintenance_exit_7")
        XCTAssertTrue(journalEntry.treeExited)
        XCTAssertEqual(store.saveCount, 0)
    }

    func testUnknownAuthenticationAfterZeroExitRequiresReconciliation() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let original = try fixture.record(authenticationState: .needsLogin, revision: 2)
        let store = InMemoryConfigurationStore(records: [original])
        let presenter = StubMaintenancePresenter()
        let harness = try makeHarness(
            fixture: fixture,
            detector: StubDetector { _, _ in
                .init(candidates: [fixture.detected(authenticationState: .unknown)], failures: [])
            },
            store: store,
            presenter: presenter
        )
        try harness.registerOwners()
        let completed = expectation(description: "unknown auth settled")
        var received: AssistantSettingsActionExecutionResult?

        try XCTUnwrap(harness.owners.owner(for: "localAgent.login"))(
            maintenanceActionRequest(
                actionID: "localAgent.login",
                operationID: "login-auth-unknown",
                record: original
            )
        ) {
            received = $0
            completed.fulfill()
        }
        XCTAssertTrue(presenter.waitUntilPresented())
        presenter.complete(.exited(exitCode: 0))

        wait(for: [completed], timeout: 2)
        XCTAssertEqual(received, .reconciliationRequired(referenceID: "login-auth-unknown"))
        let journalEntry = try XCTUnwrap(harness.journal.entry(referenceID: "login-auth-unknown"))
        XCTAssertEqual(journalEntry.state, .stateUnknown)
        XCTAssertEqual(journalEntry.settlement, .unknown)
        XCTAssertTrue(journalEntry.treeExited)
        XCTAssertFalse(journalEntry.businessResultCommitted)
    }

    func testExistingUnknownJournalEntryBlocksNewMaintenanceLaunch() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let original = try fixture.record(authenticationState: .needsLogin, revision: 2)
        let journal = try fixture.makeJournal()
        _ = try journal.prepare(
            referenceID: "unresolved-maintenance",
            operationID: "unresolved-maintenance",
            configurationID: original.configurationID,
            action: .login,
            executablePath: original.executablePath,
            executableIdentityDigest: original.executableIdentityDigest,
            environmentDigest: original.environmentDigest,
            processGeneration: nil
        )
        _ = try journal.transition(referenceID: "unresolved-maintenance", event: .beginStart)
        _ = try journal.transition(referenceID: "unresolved-maintenance", event: .settlementUnknown)
        let presenter = StubMaintenancePresenter()
        let harness = try makeHarness(
            fixture: fixture,
            detector: StubDetector { _, _ in .init(candidates: [], failures: []) },
            store: InMemoryConfigurationStore(records: [original]),
            presenter: presenter,
            journal: journal
        )
        try harness.registerOwners()

        let result = invoke(
            owner: try XCTUnwrap(harness.owners.owner(for: "localAgent.login")),
            request: maintenanceActionRequest(
                actionID: "localAgent.login",
                operationID: "login-blocked-by-unknown",
                record: original
            )
        )

        XCTAssertEqual(result, .failed(reasonCode: "local_agent_reconciliation_required"))
        XCTAssertEqual(presenter.presentationCount, 0)
        XCTAssertEqual(try journal.entries().count, 1)
    }

    func testExistingUnknownJournalEntryBlocksPreviewAndConfirmedDetection() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let original = try fixture.record(authenticationState: .needsLogin, revision: 2)
        let journal = try fixture.makeJournal()
        _ = try journal.prepare(
            referenceID: "unresolved-before-detect",
            operationID: "unresolved-before-detect",
            configurationID: original.configurationID,
            action: .login,
            executablePath: original.executablePath,
            executableIdentityDigest: original.executableIdentityDigest,
            environmentDigest: original.environmentDigest,
            processGeneration: nil
        )
        _ = try journal.transition(referenceID: "unresolved-before-detect", event: .beginStart)
        _ = try journal.transition(referenceID: "unresolved-before-detect", event: .settlementUnknown)
        var detectionCount = 0
        let harness = try makeHarness(
            fixture: fixture,
            detector: StubDetector { _, _ in
                detectionCount += 1
                return .init(
                    candidates: [fixture.detected(authenticationState: .authenticated)],
                    failures: []
                )
            },
            journal: journal
        )
        try harness.registerOwners()

        let previewCompleted = expectation(description: "preview blocked by reconciliation")
        var previewError: Error?
        harness.settings.previewDetection(catalogID: fixture.descriptor.catalogID) { result in
            if case .failure(let error) = result { previewError = error }
            previewCompleted.fulfill()
        }
        wait(for: [previewCompleted], timeout: 2)

        let detectResult = invoke(
            owner: try XCTUnwrap(harness.owners.owner(for: "localAgent.detect")),
            request: .init(
                actionID: "localAgent.detect",
                operationID: "detect-blocked-by-unknown",
                parameters: fixture.detectionParameters()
            )
        )

        XCTAssertEqual(
            previewError as? LocalAgentSettingsCoordinatorError,
            .unavailable("local_agent_reconciliation_required")
        )
        XCTAssertEqual(
            detectResult,
            .failed(reasonCode: "local_agent_reconciliation_required")
        )
        XCTAssertEqual(detectionCount, 0)
        XCTAssertEqual(harness.store.saveCount, 0)
        XCTAssertFalse(harness.gate.hasActiveOperation)
    }

    func testInvalidProcessIdentityFailsJournalCallbackAndUsesDurableReference() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let original = try fixture.record(authenticationState: .needsLogin, revision: 1)
        let presenter = StubMaintenancePresenter(
            identity: .init(
                processIdentifier: 0,
                processGroupIdentifier: 0,
                trustedStartTime: fixture.now
            )
        )
        let harness = try makeHarness(
            fixture: fixture,
            detector: StubDetector { _, _ in .init(candidates: [], failures: []) },
            store: InMemoryConfigurationStore(records: [original]),
            presenter: presenter
        )
        try harness.registerOwners()
        let completed = expectation(description: "invalid process identity settled")
        var received: AssistantSettingsActionExecutionResult?

        try XCTUnwrap(harness.owners.owner(for: "localAgent.login"))(
            maintenanceActionRequest(
                actionID: "localAgent.login",
                operationID: "login-invalid-process-identity",
                record: original
            )
        ) {
            received = $0
            completed.fulfill()
        }
        XCTAssertTrue(presenter.waitUntilPresented())
        XCTAssertEqual(presenter.processStartAccepted, false)
        presenter.complete(.stateUnknown(referenceID: "untrusted-presenter-reference"))

        wait(for: [completed], timeout: 2)
        XCTAssertEqual(
            received,
            .reconciliationRequired(referenceID: "login-invalid-process-identity")
        )
        XCTAssertEqual(
            try harness.journal.entry(referenceID: "login-invalid-process-identity")?.state,
            .stateUnknown
        )
    }

    func testReconcileProcessesSettlesUnknownEntryWithCollectedEvidence() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let journal = try fixture.makeJournal()
        try prepareUnknownRunningEntry(
            in: journal,
            fixture: fixture,
            referenceID: "maintenance-to-reconcile"
        )
        let collector = StubMaintenanceEvidenceCollector(
            result: .success(
                .init(
                    processGenerationMatches: true,
                    processGroupExited: true,
                    businessResultCommitted: false,
                    processWasIsolated: true
                )
            )
        )
        let harness = try makeHarness(
            fixture: fixture,
            detector: StubDetector { _, _ in .init(candidates: [], failures: []) },
            journal: journal,
            evidenceCollector: collector
        )
        try harness.registerOwners()

        let result = invoke(
            owner: try XCTUnwrap(harness.owners.owner(for: "localAgent.reconcileProcesses")),
            request: .init(
                actionID: "localAgent.reconcileProcesses",
                operationID: "reconcile-action",
                parameters: ["referenceID": .string("maintenance-to-reconcile")]
            )
        )

        XCTAssertEqual(
            result,
            .succeeded(proofDigest: "local-agent-maintenance:maintenance-to-reconcile:isolated")
        )
        XCTAssertEqual(
            try journal.entry(referenceID: "maintenance-to-reconcile")?.state,
            .isolated
        )
        XCTAssertEqual(collector.collectedReferenceIDs, ["maintenance-to-reconcile"])
    }

    func testReconcileProcessesKeepsUnknownWhenEvidenceIsInsufficient() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let journal = try fixture.makeJournal()
        try prepareUnknownRunningEntry(
            in: journal,
            fixture: fixture,
            referenceID: "maintenance-still-running"
        )
        let collector = StubMaintenanceEvidenceCollector(
            result: .success(
                .init(
                    processGenerationMatches: false,
                    processGroupExited: false,
                    businessResultCommitted: false,
                    processWasIsolated: false
                )
            )
        )
        let harness = try makeHarness(
            fixture: fixture,
            detector: StubDetector { _, _ in .init(candidates: [], failures: []) },
            journal: journal,
            evidenceCollector: collector
        )
        try harness.registerOwners()

        let result = invoke(
            owner: try XCTUnwrap(harness.owners.owner(for: "localAgent.reconcileProcesses")),
            request: .init(
                actionID: "localAgent.reconcileProcesses",
                operationID: "reconcile-insufficient",
                parameters: ["referenceID": .string("maintenance-still-running")]
            )
        )

        XCTAssertEqual(
            result,
            .reconciliationRequired(referenceID: "maintenance-still-running")
        )
        XCTAssertEqual(
            try journal.entry(referenceID: "maintenance-still-running")?.state,
            .stateUnknown
        )
    }

    func testDeleteRejectsConfigurationWithLiveRuntimeUsage() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let original = try fixture.record(authenticationState: .authenticated, revision: 2)
        let store = InMemoryConfigurationStore(records: [original])
        let usage = LocalAgentRuntimeUsageRegistry()
        let token = usage.register(configurationID: original.configurationID)
        defer { usage.unregister(configurationID: original.configurationID, token: token) }
        let harness = try makeHarness(
            fixture: fixture,
            detector: StubDetector { _, _ in .init(candidates: [], failures: []) },
            store: store,
            runtimeUsage: usage
        )
        try harness.registerOwners()

        let result = invoke(
            owner: try XCTUnwrap(harness.owners.owner(for: "configuration.delete")),
            request: .init(
                actionID: "configuration.delete",
                operationID: "delete-in-use",
                parameters: [
                    "configurationKind": .string(ConfigurationKind.localAgent.rawValue),
                    "configurationID": .string(original.configurationID),
                    "expectedRevision": .int(Int(original.configurationRevision))
                ]
            )
        )

        XCTAssertEqual(result, .failed(reasonCode: "local_agent_in_use"))
        XCTAssertNotNil(try store.record(configurationID: original.configurationID))
        XCTAssertEqual(store.deleteCount, 0)
    }

    func testRuntimeLeasesBlockDetectProfileAndLoginBeforeSideEffects() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let original = try fixture.record(authenticationState: .authenticated, revision: 2)
        let store = InMemoryConfigurationStore(records: [original])
        let usage = LocalAgentRuntimeUsageRegistry()
        let existingLease = try XCTUnwrap(
            usage.acquireUsage(configurationID: original.configurationID)
        )
        let newConfigurationLease = try XCTUnwrap(
            usage.acquireUsage(configurationID: "local-agent-new")
        )
        defer {
            existingLease.release()
            newConfigurationLease.release()
        }
        var detectionCount = 0
        let presenter = StubMaintenancePresenter()
        let harness = try makeHarness(
            fixture: fixture,
            detector: StubDetector { _, _ in
                detectionCount += 1
                return .init(candidates: [], failures: [])
            },
            store: store,
            presenter: presenter,
            runtimeUsage: usage
        )
        try harness.registerOwners()

        let detectResult = invoke(
            owner: try XCTUnwrap(harness.owners.owner(for: "localAgent.detect")),
            request: .init(
                actionID: "localAgent.detect",
                operationID: "detect-in-use",
                parameters: fixture.detectionParameters()
            )
        )
        let profileResult = invoke(
            owner: try XCTUnwrap(harness.owners.owner(for: "localAgent.changeExecutionProfile")),
            request: .init(
                actionID: "localAgent.changeExecutionProfile",
                operationID: "profile-in-use",
                parameters: [
                    "configurationID": .string(original.configurationID),
                    "executionProfileID": .string(original.executionProfileID),
                    "expectedRevision": .int(Int(original.configurationRevision))
                ]
            )
        )
        let loginResult = invoke(
            owner: try XCTUnwrap(harness.owners.owner(for: "localAgent.login")),
            request: maintenanceActionRequest(
                actionID: "localAgent.login",
                operationID: "login-in-use",
                record: original
            )
        )

        XCTAssertEqual(detectResult, .failed(reasonCode: "local_agent_in_use"))
        XCTAssertEqual(profileResult, .failed(reasonCode: "local_agent_in_use"))
        XCTAssertEqual(loginResult, .failed(reasonCode: "local_agent_in_use"))
        XCTAssertEqual(detectionCount, 0)
        XCTAssertEqual(store.saveCount, 0)
        XCTAssertEqual(presenter.presentationCount, 0)
        XCTAssertFalse(harness.gate.hasActiveOperation)
    }

    func testDetectMutationFenceBlocksNewRuntimeLeaseUntilWriteSettles() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let enteredDetection = DispatchSemaphore(value: 0)
        let resumeDetection = DispatchSemaphore(value: 0)
        let usage = LocalAgentRuntimeUsageRegistry()
        let harness = try makeHarness(
            fixture: fixture,
            detector: StubDetector { _, _ in
                enteredDetection.signal()
                _ = resumeDetection.wait(timeout: .now() + 2)
                return .init(
                    candidates: [fixture.detected(authenticationState: .authenticated)],
                    failures: []
                )
            },
            runtimeUsage: usage
        )
        try harness.registerOwners()
        let completed = expectation(description: "detect mutation settled")
        var received: AssistantSettingsActionExecutionResult?

        try XCTUnwrap(harness.owners.owner(for: "localAgent.detect"))(
            .init(
                actionID: "localAgent.detect",
                operationID: "detect-holds-mutation-fence",
                parameters: fixture.detectionParameters()
            )
        ) {
            received = $0
            completed.fulfill()
        }
        XCTAssertEqual(enteredDetection.wait(timeout: .now() + 1), .success)

        XCTAssertNil(
            usage.acquireUsage(configurationID: "local-agent-new"),
            "Runtime launch must not enter while detection is changing the configuration"
        )

        resumeDetection.signal()
        wait(for: [completed], timeout: 2)
        guard case .succeeded = received else {
            XCTFail("Expected detection to settle successfully, got \(String(describing: received))")
            return
        }
        let lease = try XCTUnwrap(
            usage.acquireUsage(configurationID: "local-agent-new")
        )
        lease.release()
        XCTAssertFalse(harness.gate.hasActiveOperation)
    }

    private func makeHarness(
        fixture: Fixture,
        detector: LocalAgentConfigurationDetecting,
        catalog: RuntimeCatalogProviding? = nil,
        gate: LocalAgentSettingsOperationGate = LocalAgentSettingsOperationGate(),
        store: InMemoryConfigurationStore = InMemoryConfigurationStore(),
        presenter: LocalAgentMaintenancePresenting? = nil,
        websiteOpener: LocalAgentWebsiteOpening? = nil,
        runtimeUsage: LocalAgentRuntimeUsageRegistry = LocalAgentRuntimeUsageRegistry(),
        journal: LocalAgentMaintenanceProcessJournalStore? = nil,
        evidenceCollector: LocalAgentMaintenanceEvidenceCollecting = DarwinLocalAgentMaintenanceEvidenceCollector()
    ) throws -> Harness {
        let owners = AssistantSettingsActionOwnerRegistry()
        let databasePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-agent-settings-actions-\(UUID().uuidString).sqlite3").path
        let actions = AssistantSettingsActionCoordinator(
            registry: try .standard(),
            control: StaticControlState(.enabled),
            eventStore: AssistantSettingsEventStore(
                backend: try AssistantSettingsStoreBackend(databasePath: databasePath)
            ),
            owners: owners
        )
        let configurationDeleteRouter = ConfigurationDeleteActionRouter()
        try configurationDeleteRouter.registerActionOwner(in: actions)
        let maintenanceJournal = try journal ?? fixture.makeJournal()
        let settings = LocalAgentSettingsCoordinator(
            catalog: catalog ?? fixture.catalog,
            detector: detector,
            store: store,
            maintenancePresenter: presenter,
            websiteOpener: websiteOpener,
            maintenanceJournal: maintenanceJournal,
            maintenanceEvidenceCollector: evidenceCollector,
            operationGate: gate,
            runtimeUsage: runtimeUsage,
            environment: { fixture.environment },
            homeDirectory: { fixture.root.path },
            controlState: { .enabled },
            now: { fixture.now },
            workerQueue: DispatchQueue(label: "local-agent-settings-tests-\(UUID().uuidString)")
        )
        return Harness(
            settings: settings,
            actions: actions,
            owners: owners,
            store: store,
            gate: gate,
            journal: maintenanceJournal,
            configurationDeleteRouter: configurationDeleteRouter
        )
    }

    private func maintenanceActionRequest(
        actionID: String,
        operationID: String,
        record: LocalAgentConfigurationRecord
    ) -> AssistantSettingsActionRequest {
        .init(
            actionID: actionID,
            operationID: operationID,
            parameters: [
                "configurationID": .string(record.configurationID),
                "expectedRevision": .int(Int(record.configurationRevision))
            ]
        )
    }

    private func prepareUnknownRunningEntry(
        in journal: LocalAgentMaintenanceProcessJournalStore,
        fixture: Fixture,
        referenceID: String
    ) throws {
        let record = try fixture.record(authenticationState: .needsLogin, revision: 1)
        _ = try journal.prepare(
            referenceID: referenceID,
            operationID: referenceID,
            configurationID: record.configurationID,
            action: .login,
            executablePath: record.executablePath,
            executableIdentityDigest: record.executableIdentityDigest,
            environmentDigest: record.environmentDigest,
            processGeneration: nil
        )
        _ = try journal.transition(referenceID: referenceID, event: .beginStart)
        _ = try journal.transition(
            referenceID: referenceID,
            event: .processStarted,
            processIdentifier: 8_200,
            processGroupIdentifier: 8_200,
            trustedProcessStartTime: fixture.now
        )
        _ = try journal.transition(referenceID: referenceID, event: .settlementUnknown)
    }

    private func invoke(
        owner: @escaping AssistantSettingsActionOwner,
        request: AssistantSettingsActionRequest,
        timeout: TimeInterval = 2
    ) -> AssistantSettingsActionExecutionResult? {
        let completed = expectation(description: "owner completion: \(request.actionID)")
        var received: AssistantSettingsActionExecutionResult?
        owner(request) {
            received = $0
            completed.fulfill()
        }
        wait(for: [completed], timeout: timeout)
        return received
    }

    private func copy(
        _ entry: CodingPlanCatalogEntry,
        credentialOwner: CatalogCredentialOwner? = nil,
        authenticationKind: CatalogAuthenticationKind? = nil,
        modelDiscoveryStrategy: CatalogModelDiscoveryStrategy? = nil,
        allowedRuntimeKinds: [CatalogRuntimeKind]? = nil
    ) -> CodingPlanCatalogEntry {
        CodingPlanCatalogEntry(
            catalogID: entry.catalogID,
            planID: entry.planID,
            displayName: entry.displayName,
            supportLevel: entry.supportLevel,
            tombstone: entry.tombstone,
            alias: entry.alias,
            schemaVersion: entry.schemaVersion,
            revision: entry.revision,
            aliases: entry.aliases,
            planKind: entry.planKind,
            credentialOwner: credentialOwner ?? entry.credentialOwner,
            authenticationKind: authenticationKind ?? entry.authenticationKind,
            suggestedBaseURL: entry.suggestedBaseURL,
            modelDiscoveryStrategy: modelDiscoveryStrategy ?? entry.modelDiscoveryStrategy,
            authorizationScope: entry.authorizationScope,
            quotaActionID: entry.quotaActionID,
            websiteActionIDs: entry.websiteActionIDs,
            allowedRuntimeKinds: allowedRuntimeKinds ?? entry.allowedRuntimeKinds,
            documentationSources: entry.documentationSources
        )
    }

    private func copy(
        _ entry: PlanAgentCompatibilityEntry,
        credentialInjectionKind: CatalogCredentialInjectionKind? = nil,
        allowedCapabilities: [String]? = nil
    ) -> PlanAgentCompatibilityEntry {
        PlanAgentCompatibilityEntry(
            planID: entry.planID,
            agentRawIdentity: entry.agentRawIdentity,
            compatible: entry.compatible,
            supportedVersionRange: entry.supportedVersionRange,
            credentialInjectionKind: credentialInjectionKind ?? entry.credentialInjectionKind,
            allowedCapabilities: allowedCapabilities ?? entry.allowedCapabilities,
            authorizationNotes: entry.authorizationNotes,
            supportLevel: entry.supportLevel,
            lastVerifiedCatalogRevision: entry.lastVerifiedCatalogRevision
        )
    }

    private func copy(
        _ entry: LocalAgentCatalogEntry,
        executionProfiles: [LocalAgentExecutionProfileDescriptor]? = nil,
        supportedCapabilities: [String]? = nil
    ) -> LocalAgentCatalogEntry {
        LocalAgentCatalogEntry(
            catalogID: entry.catalogID,
            rawIdentity: entry.rawIdentity,
            displayName: entry.displayName,
            supportLevel: entry.supportLevel,
            tombstone: entry.tombstone,
            alias: entry.alias,
            schemaVersion: entry.schemaVersion,
            revision: entry.revision,
            aliases: entry.aliases,
            executableCandidates: entry.executableCandidates,
            supportedOSVersions: entry.supportedOSVersions,
            supportedArchitectures: entry.supportedArchitectures,
            versionArgv: entry.versionArgv,
            capabilityProbeArgv: entry.capabilityProbeArgv,
            loginStatusArgv: entry.loginStatusArgv,
            loginArgv: entry.loginArgv,
            logoutArgv: entry.logoutArgv,
            terminalPassthroughArgv: entry.terminalPassthroughArgv,
            executionProfiles: executionProfiles ?? entry.executionProfiles,
            upgradeActionID: entry.upgradeActionID,
            structuredProtocolPriority: entry.structuredProtocolPriority,
            permitsPTYFallback: entry.permitsPTYFallback,
            supportedCapabilities: supportedCapabilities ?? entry.supportedCapabilities,
            supportedWorkingDirectoryModes: entry.supportedWorkingDirectoryModes,
            defaultPATHPolicy: entry.defaultPATHPolicy,
            defaultEnvironmentAllowlist: entry.defaultEnvironmentAllowlist,
            websiteActionIDs: entry.websiteActionIDs,
            documentationSources: entry.documentationSources
        )
    }

    private func replacing(
        in set: RuntimeCatalogSet,
        plan: CodingPlanCatalogEntry? = nil,
        compatibility: PlanAgentCompatibilityEntry? = nil,
        agent: LocalAgentCatalogEntry? = nil
    ) -> RuntimeCatalogSet {
        var plans = set.codingPlans
        if let plan, let index = plans.firstIndex(where: { $0.catalogID == plan.catalogID }) {
            plans[index] = plan
        }
        var compatibilityEntries = set.planAgentCompatibility
        if let compatibility,
           let index = compatibilityEntries.firstIndex(where: {
               $0.planID == compatibility.planID
                   && $0.agentRawIdentity == compatibility.agentRawIdentity
           })
        {
            compatibilityEntries[index] = compatibility
        }
        var agents = set.localAgents
        if let agent, let index = agents.firstIndex(where: { $0.catalogID == agent.catalogID }) {
            agents[index] = agent
        }
        return RuntimeCatalogSet(
            catalogSetRevision: set.catalogSetRevision,
            providers: set.providers,
            codingPlans: plans,
            localAgents: agents,
            planAgentCompatibility: compatibilityEntries,
            websiteActions: set.websiteActions,
            pricing: set.pricing,
            toolCatalog: set.toolCatalog
        )
    }
}

private struct Harness {
    let settings: LocalAgentSettingsCoordinator
    let actions: AssistantSettingsActionCoordinator
    let owners: AssistantSettingsActionOwnerRegistry
    let store: InMemoryConfigurationStore
    let gate: LocalAgentSettingsOperationGate
    let journal: LocalAgentMaintenanceProcessJournalStore
    let configurationDeleteRouter: ConfigurationDeleteActionRouter

    func registerOwners() throws {
        try settings.registerOwners(
            in: actions,
            configurationDeleteRouter: configurationDeleteRouter
        )
    }
}

private final class StaticControlState: AssistantSettingsControlStateProviding {
    let state: AgentConversationV2ControlState

    init(_ state: AgentConversationV2ControlState) {
        self.state = state
    }

    func controlState() throws -> AgentConversationV2ControlState { state }
}

private final class StubDetector: LocalAgentConfigurationDetecting {
    typealias Handler = (String, String?) throws -> LocalAgentDetectionReport
    private let handler: Handler

    init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    func detect(
        catalogID: String,
        userSelectedExecutablePath: String?
    ) throws -> LocalAgentDetectionReport {
        try handler(catalogID, userSelectedExecutablePath)
    }
}

private final class StubMaintenanceEvidenceCollector: LocalAgentMaintenanceEvidenceCollecting {
    private let result: Result<LocalAgentMaintenanceReconciliationEvidence, Error>
    private(set) var collectedReferenceIDs: [String] = []

    init(result: Result<LocalAgentMaintenanceReconciliationEvidence, Error>) {
        self.result = result
    }

    func collectEvidence(
        for entry: LocalAgentMaintenanceProcessJournalEntry
    ) throws -> LocalAgentMaintenanceReconciliationEvidence {
        collectedReferenceIDs.append(entry.referenceID)
        return try result.get()
    }
}

private final class InMemoryConfigurationStore: LocalAgentConfigurationManaging {
    private let lock = NSLock()
    private var values: [String: LocalAgentConfigurationRecord]
    private(set) var saveCount = 0
    private(set) var deleteCount = 0

    init(records: [LocalAgentConfigurationRecord] = []) {
        values = Dictionary(uniqueKeysWithValues: records.map { ($0.configurationID, $0) })
    }

    func records() throws -> [LocalAgentConfigurationRecord] {
        lock.withLock { Array(values.values) }
    }

    func record(configurationID: String) throws -> LocalAgentConfigurationRecord? {
        lock.withLock { values[configurationID] }
    }

    func save(
        _ proposed: LocalAgentConfigurationRecord,
        expectedRevision: Int64?,
        operationID: String,
        eventID: String
    ) throws -> LocalAgentConfigurationRecord {
        try lock.withLock {
            let actual = values[proposed.configurationID]?.configurationRevision
            guard actual == expectedRevision else {
                throw LocalAgentConfigurationStoreError.staleRevision(expected: expectedRevision, actual: actual)
            }
            let saved = proposed.replacingRevision((actual ?? 0) + 1)
            values[saved.configurationID] = saved
            saveCount += 1
            return saved
        }
    }

    func delete(
        configurationID: String,
        expectedRevision: Int64,
        operationID: String,
        eventID: String
    ) throws -> Int64 {
        try lock.withLock {
            guard let actual = values[configurationID]?.configurationRevision,
                  actual == expectedRevision else {
                throw LocalAgentConfigurationStoreError.staleRevision(
                    expected: expectedRevision,
                    actual: values[configurationID]?.configurationRevision
                )
            }
            values.removeValue(forKey: configurationID)
            deleteCount += 1
            return actual + 1
        }
    }
}

private final class StubMaintenancePresenter: LocalAgentMaintenancePresenting {
    private let lock = NSLock()
    private let identity: LocalAgentMaintenanceProcessIdentity
    private var completion: ((LocalAgentMaintenanceLaunchOutcome) -> Void)?
    private(set) var presentationCount = 0
    private(set) var processStartAccepted: Bool?

    init(
        identity: LocalAgentMaintenanceProcessIdentity = .init(
            processIdentifier: 4_200,
            processGroupIdentifier: 4_200,
            trustedStartTime: Date(timeIntervalSince1970: 1_786_400_001)
        )
    ) {
        self.identity = identity
    }

    func present(
        request: LocalAgentMaintenanceLaunchRequest,
        onProcessStarted: @escaping (LocalAgentMaintenanceProcessIdentity) -> Bool,
        completion: @escaping (LocalAgentMaintenanceLaunchOutcome) -> Void
    ) {
        lock.withLock {
            presentationCount += 1
            self.completion = completion
        }
        let accepted = onProcessStarted(identity)
        lock.withLock { processStartAccepted = accepted }
    }

    func waitUntilPresented() -> Bool {
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            if lock.withLock({ completion != nil }) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return lock.withLock { completion != nil }
    }

    func complete(_ outcome: LocalAgentMaintenanceLaunchOutcome) {
        let callback = lock.withLock { completion }
        callback?(outcome)
    }
}

private final class RecordingLocalAgentWebsiteOpener: LocalAgentWebsiteOpening {
    private(set) var openedURLs: [URL] = []

    func open(_ url: URL) -> Bool {
        openedURLs.append(url)
        return true
    }
}

private struct Fixture {
    let root: URL
    let executable: URL
    let descriptor: LocalAgentCatalogEntry
    let catalog: BundledRuntimeCatalog
    let environment: [String: String]
    let now = Date(timeIntervalSince1970: 1_786_400_000)

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-agent-settings-coordinator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        executable = root.appendingPathComponent("codex")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: executable.path
        )
        catalog = BundledRuntimeCatalog.shared
        descriptor = try XCTUnwrap(catalog.catalogSet?.localAgent(catalogID: "local-agent.codex"))
        environment = [
            "HOME": root.path,
            "PATH": "/usr/bin:/bin",
            "LANG": "en_US.UTF-8",
            "TERM": "xterm-256color",
            "TMPDIR": root.path
        ]
    }

    func detected(
        authenticationState: LocalAgentAuthenticationProbeState,
        digest: String? = nil
    ) -> LocalAgentDetectedExecutable {
        let executableDigest = digest.map { "sha256:\($0)" }
            ?? LocalAgentConfigurationIntegrity.executableDigest(path: executable.path)!
        return LocalAgentDetectedExecutable(
            catalogID: descriptor.catalogID,
            catalogSetRevision: catalog.catalogSet!.catalogSetRevision,
            descriptorRevision: descriptor.revision,
            rawIdentity: descriptor.rawIdentity,
            displayName: descriptor.displayName,
            executablePath: executable.path,
            executableIdentityDigest: executableDigest,
            detectedVersion: "codex 1.0.0",
            authenticationState: authenticationState,
            authenticationEvidenceRevision: "auth-v1",
            cliAuthenticationScopeDigest: "sha256:\(String(repeating: "1", count: 64))",
            cliLoginIdentityDigest: "sha256:\(String(repeating: "2", count: 64))",
            detectedAt: now
        )
    }

    func record(
        authenticationState: LocalAgentAuthenticationProbeState,
        revision: Int64
    ) throws -> LocalAgentConfigurationRecord {
        try LocalAgentConfigurationProposalFactory.makeRecord(
            from: LocalAgentConfigurationDraft(
                configurationID: "local-agent-test",
                displayName: "Test Codex",
                detectedExecutable: detected(authenticationState: authenticationState),
                executionProfileID: "terminal-passthrough",
                explicitlyEnabled: true
            ),
            catalog: catalog,
            environment: environment,
            homeDirectory: root.path,
            confirmedAt: now
        ).replacingRevision(revision)
    }

    func detectionParameters() -> [String: SettingValue] {
        [
            "configurationID": .string("local-agent-new"),
            "catalogID": .string(descriptor.catalogID),
            "executablePath": .string(executable.path),
            "executableIdentityDigest": .string(
                LocalAgentConfigurationIntegrity.executableDigest(path: executable.path)!
            ),
            "displayName": .string("Test Codex"),
            "executionProfileID": .string("terminal-passthrough"),
            "workingDirectoryMode": .string(AgentProcessWorkingDirectoryMode.managedWorkspace.rawValue),
            "pathPolicy": .string(LocalAgentPATHPolicy.controlled.rawValue),
            "customPATHEntries": .stringArray([]),
            "environmentAllowlist": .stringArray([]),
            "explicitlyEnabled": .bool(true)
        ]
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func makeJournal() throws -> LocalAgentMaintenanceProcessJournalStore {
        try LocalAgentMaintenanceProcessJournalStore(
            fileURL: root.appendingPathComponent("maintenance-journal-v1.json"),
            now: { now }
        )
    }
}

private extension Result {
    var failure: Failure? {
        guard case .failure(let error) = self else { return nil }
        return error
    }
}
