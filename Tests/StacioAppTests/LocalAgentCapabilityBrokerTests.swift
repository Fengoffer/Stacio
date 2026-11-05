import XCTest
import Foundation
@testable import StacioApp

/// P8-3：LocalAgentCapabilityBroker（能力生命周期、交付渠道、调用方识别、验证拒绝、双 kind、answer-only 零能力）。
final class LocalAgentCapabilityBrokerTests: XCTestCase {

    private let rootProcessIdentity = LocalAgentCapabilityProcessIdentity(
        processIdentifier: 701,
        processGroupIdentifier: 700,
        trustedStartTime: Date(timeIntervalSince1970: 1_700_000_001.25)
    )

    private func makeRegistry() -> LocalAgentCapabilityRegistry {
        let identity = rootProcessIdentity
        return LocalAgentCapabilityRegistry { processIdentifier in
            processIdentifier == identity.processIdentifier ? identity : nil
        }
    }

    func testRuntimeRegistryExpiresRevokesAndRejectsOtherTargets() {
        let registry = makeRegistry()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        registry.register(
            capabilityID: "scope-1",
            targetRuntimeGenerations: ["term-a": 11],
            processGeneration: 7,
            processGroupID: 700,
            processIdentifier: 701,
            trustedStartTime: rootProcessIdentity.trustedStartTime,
            actorName: "Codex",
            expiresAt: now.addingTimeInterval(60)
        )

        XCTAssertTrue(registry.allows(
            capabilityID: "scope-1", runtimeID: "term-a", runtimeGeneration: 11, now: now
        ))
        XCTAssertFalse(registry.allows(
            capabilityID: "scope-1", runtimeID: "term-a", runtimeGeneration: 12, now: now
        ))
        XCTAssertFalse(registry.allows(
            capabilityID: "scope-1", runtimeID: "term-b", runtimeGeneration: 11, now: now
        ))
        XCTAssertFalse(registry.allows(
            capabilityID: "scope-1",
            runtimeID: "term-a",
            runtimeGeneration: 11,
            now: now.addingTimeInterval(61)
        ))
        XCTAssertEqual(registry.processGeneration(for: "scope-1", now: now), 7)
        XCTAssertEqual(
            registry.resolvePeer(processID: 701, processGroupID: 700, now: now),
            .authorized(capabilityID: "scope-1", actorName: "Codex", processGeneration: 7)
        )
        XCTAssertEqual(
            registry.resolvePeer(processID: 701, processGroupID: 999, now: now),
            .unmanaged
        )

        registry.revoke(capabilityID: "scope-1")
        XCTAssertFalse(registry.allows(
            capabilityID: "scope-1", runtimeID: "term-a", runtimeGeneration: 11, now: now
        ))
        XCTAssertTrue(registry.allowedRuntimeGenerations(capabilityID: "scope-1", now: now).isEmpty)
        XCTAssertEqual(
            registry.resolvePeer(processID: 701, processGroupID: 700, now: now),
            .rejected
        )
    }

    func testPeerResolutionRejectsReusedRootPIDOrProcessGroup() {
        let registry = makeRegistry()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        registry.register(
            capabilityID: "scope-reuse",
            targetRuntimeGenerations: ["term-a": 1],
            processGeneration: 1,
            processGroupID: 700,
            processIdentifier: 701,
            trustedStartTime: rootProcessIdentity.trustedStartTime,
            expiresAt: now.addingTimeInterval(60)
        )

        let reusedRegistry = LocalAgentCapabilityRegistry { processIdentifier in
            guard processIdentifier == 701 else { return nil }
            return LocalAgentCapabilityProcessIdentity(
                processIdentifier: 701,
                processGroupIdentifier: 700,
                trustedStartTime: Date(timeIntervalSince1970: 1_700_000_009)
            )
        }
        reusedRegistry.register(
            capabilityID: "scope-reuse",
            targetRuntimeGenerations: ["term-a": 1],
            processGeneration: 1,
            processGroupID: 700,
            processIdentifier: 701,
            trustedStartTime: rootProcessIdentity.trustedStartTime,
            expiresAt: now.addingTimeInterval(60)
        )
        XCTAssertEqual(
            reusedRegistry.resolvePeer(processID: 999, processGroupID: 700, now: now),
            .rejected,
            "PGID 相同但 root trusted start time 已变化时必须拒绝"
        )

        XCTAssertEqual(
            registry.resolvePeer(processID: 999, processGroupID: 701, now: now),
            .unmanaged
        )
    }

    func testPeerResolutionFailsClosedWhenRegistrationOmitsRootIdentity() {
        let registry = LocalAgentCapabilityRegistry()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        registry.register(
            capabilityID: "scope-pgid-only",
            targetRuntimeGenerations: ["term-a": 1],
            processGeneration: 1,
            processGroupID: 700,
            expiresAt: now.addingTimeInterval(60)
        )
        XCTAssertEqual(
            registry.resolvePeer(processID: 701, processGroupID: 700, now: now),
            .rejected
        )
    }

    func testRevokedCapabilityIdentifierCannotBeRegisteredAgain() {
        let registry = makeRegistry()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertTrue(registry.register(
            capabilityID: "scope-one-shot",
            targetRuntimeGenerations: ["term-a": 1],
            processGeneration: 1,
            processGroupID: 700,
            processIdentifier: 701,
            trustedStartTime: rootProcessIdentity.trustedStartTime,
            expiresAt: now.addingTimeInterval(60)
        ))
        registry.revoke(capabilityID: "scope-one-shot")

        XCTAssertFalse(registry.register(
            capabilityID: "scope-one-shot",
            targetRuntimeGenerations: ["term-b": 2],
            processGeneration: 2,
            processGroupID: 700,
            processIdentifier: 701,
            trustedStartTime: rootProcessIdentity.trustedStartTime,
            expiresAt: now.addingTimeInterval(120)
        ))
        XCTAssertFalse(registry.allows(
            capabilityID: "scope-one-shot",
            runtimeID: "term-a",
            runtimeGeneration: 1,
            now: now
        ))
        XCTAssertFalse(registry.allows(
            capabilityID: "scope-one-shot",
            runtimeID: "term-b",
            runtimeGeneration: 2,
            now: now
        ))
    }

    func testInternalCapabilityReadsFailClosedAfterRootProcessDisappears() {
        final class IdentityBox: @unchecked Sendable {
            var value: LocalAgentCapabilityProcessIdentity?
        }
        let box = IdentityBox()
        box.value = rootProcessIdentity
        let registry = LocalAgentCapabilityRegistry { _ in box.value }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertTrue(registry.register(
            capabilityID: "scope-live-check",
            targetRuntimeGenerations: ["term-a": 4],
            processGeneration: 2,
            processGroupID: rootProcessIdentity.processGroupIdentifier,
            processIdentifier: rootProcessIdentity.processIdentifier,
            trustedStartTime: rootProcessIdentity.trustedStartTime,
            expiresAt: now.addingTimeInterval(60)
        ))
        XCTAssertTrue(registry.allows(
            capabilityID: "scope-live-check",
            runtimeID: "term-a",
            runtimeGeneration: 4,
            now: now
        ))

        box.value = nil
        XCTAssertFalse(registry.allows(
            capabilityID: "scope-live-check",
            runtimeID: "term-a",
            runtimeGeneration: 4,
            now: now
        ))
        XCTAssertTrue(registry.allowedRuntimeGenerations(
            capabilityID: "scope-live-check",
            now: now
        ).isEmpty)
        XCTAssertNil(registry.processGeneration(for: "scope-live-check", now: now))
    }

    private func makeCapability(kind: ManagedCapabilityKind = .effectCapable) -> ManagedCapability {
        LocalAgentCapabilityBrokerAction.createCapability(
            capabilityID: "cap-1", kind: kind,
            conversationID: "conv-1", turnID: "turn-1", attemptID: "attempt-1",
            authorityLeaseGeneration: 2, targetBindingDigest: "d1",
            workingDirectoryDigest: "wd-1", executableHash: "sha256:exe",
            processGeneration: 3, containmentRevision: 4,
            allowedActions: ["executeTool"], expiresAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
    }

    // MARK: - 能力绑定完整身份链

    func testCapabilityBindsFullIdentityChain() {
        let capability = makeCapability()
        XCTAssertEqual(capability.conversationID, "conv-1")
        XCTAssertEqual(capability.turnID, "turn-1")
        XCTAssertEqual(capability.attemptID, "attempt-1")
        XCTAssertEqual(capability.authorityLeaseGeneration, 2, "AttemptExecutionAuthorityLease.generation")
        XCTAssertEqual(capability.targetBindingDigest, "d1", "TargetBinding digest")
        XCTAssertEqual(capability.workingDirectoryDigest, "wd-1", "AgentProcessWorkingDirectory digest")
        XCTAssertEqual(capability.executableHash, "sha256:exe", "executable hash")
        XCTAssertEqual(capability.processGeneration, 3, "进程代次")
        XCTAssertEqual(capability.containmentRevision, 4, "containment revision")
        XCTAssertFalse(capability.revoked)
    }

    func testRevokeMakesUnreusable() {
        let revoked = LocalAgentCapabilityBrokerAction.revoke(makeCapability())
        XCTAssertTrue(revoked.revoked, "可撤销")
        let outcome = LocalAgentCapabilityBrokerAction.verify(
            capability: revoked, peerMatches: true, replayTokenValid: true,
            targetDigest: "d1", workingDirectoryDigest: "wd-1", requestedAction: "executeTool", now: Date(timeIntervalSince1970: 1_700_000_050)
        )
        XCTAssertEqual(outcome, .reject(reason: "revokedGeneration"), "已撤销 generation 拒绝")
    }

    // MARK: - 交付渠道

    func testDeliveryChannelNotArgvEnvPlainFile() {
        XCTAssertEqual(LocalAgentCapabilityBrokerAction.deliveryChannel(), .xpcUnixWithPeerAuth)
        XCTAssertTrue(LocalAgentCapabilityBrokerAction.neverBearerTokenInArgvEnvPlainFileOrTerminalOutput(),
                      "不得把 bearer token 放入命令行/环境变量/临时明文文件/终端输出")
    }

    // MARK: - 调用方识别

    func testTrustsSelfCreatedIdentityOnly() {
        XCTAssertTrue(LocalAgentCapabilityBrokerAction.trustsSelfCreatedIdentityOnly(),
                      "Broker 从自己创建的 handle/audit token/peer credentials 识别调用方，不信任 CLI 自报")
    }

    // MARK: - 验证拒绝

    func testVerifyAllowsWhenEverythingMatches() {
        let outcome = LocalAgentCapabilityBrokerAction.verify(
            capability: makeCapability(), peerMatches: true, replayTokenValid: true,
            targetDigest: "d1", workingDirectoryDigest: "wd-1", requestedAction: "executeTool",
            now: Date(timeIntervalSince1970: 1_700_000_050)
        )
        XCTAssertEqual(outcome, .allow)
    }

    func testVerifyRejectsOnAnyViolation() {
        let capability = makeCapability()
        let now = Date(timeIntervalSince1970: 1_700_000_050)
        // 错误 peer
        XCTAssertEqual(
            LocalAgentCapabilityBrokerAction.verify(
                capability: capability, peerMatches: false, replayTokenValid: true,
                targetDigest: "d1", workingDirectoryDigest: "wd-1", requestedAction: "executeTool", now: now
            ),
            .reject(reason: "wrongPeer")
        )
        // 旧重放 token
        XCTAssertEqual(
            LocalAgentCapabilityBrokerAction.verify(
                capability: capability, peerMatches: true, replayTokenValid: false,
                targetDigest: "d1", workingDirectoryDigest: "wd-1", requestedAction: "executeTool", now: now
            ),
            .reject(reason: "replayedToken")
        )
        // 错误 target digest
        XCTAssertEqual(
            LocalAgentCapabilityBrokerAction.verify(
                capability: capability, peerMatches: true, replayTokenValid: true,
                targetDigest: "wrong", workingDirectoryDigest: "wd-1", requestedAction: "executeTool", now: now
            ),
            .reject(reason: "wrongTargetDigest")
        )
        // 越权动作
        XCTAssertEqual(
            LocalAgentCapabilityBrokerAction.verify(
                capability: capability, peerMatches: true, replayTokenValid: true,
                targetDigest: "d1", workingDirectoryDigest: "wd-1", requestedAction: "deleteEverything", now: now
            ),
            .reject(reason: "actionNotAllowed")
        )
        // 过期
        XCTAssertEqual(
            LocalAgentCapabilityBrokerAction.verify(
                capability: capability, peerMatches: true, replayTokenValid: true,
                targetDigest: "d1", workingDirectoryDigest: "wd-1", requestedAction: "executeTool",
                now: Date(timeIntervalSince1970: 1_700_000_200)
            ),
            .reject(reason: "expired")
        )
        // 错误 workingDirectoryDigest → 拒绝
        XCTAssertEqual(
            LocalAgentCapabilityBrokerAction.verify(
                capability: capability, peerMatches: true, replayTokenValid: true,
                targetDigest: "d1", workingDirectoryDigest: "wrong-wd", requestedAction: "executeTool",
                now: Date(timeIntervalSince1970: 1_700_000_050)
            ),
            .reject(reason: "wrongWorkingDirectoryDigest")
        )
    }

    // MARK: - 双 kind 独立

    func testEffectAndAnswerOnlyIndependentEndpoints() {
        XCTAssertTrue(LocalAgentCapabilityBrokerAction.independentEndpointsForKinds(),
                      "effect-capable 与 answer-only 是两套独立 capability/endpoint")
        XCTAssertNotEqual(ManagedCapabilityKind.allCases.count, 1)
    }

    // MARK: - answer-only 零能力

    func testAnswerOnlyZeroCapabilities() {
        XCTAssertTrue(LocalAgentCapabilityBrokerAction.answerOnlyZeroTargetWorkspaceTerminalEffectSubprocessPersistentWrite(),
                      "answer-only 零 Target/workspace/terminal/Effect Broker/任意子进程/持久写入")
        XCTAssertTrue(LocalAgentCapabilityBrokerAction.answerOnlyAllows("readOnlyAuthContextIPC"))
        XCTAssertTrue(LocalAgentCapabilityBrokerAction.answerOnlyAllows("privateEphemeralScratch"))
        XCTAssertTrue(LocalAgentCapabilityBrokerAction.answerOnlyAllows("declaredModelEgress"))
        XCTAssertFalse(LocalAgentCapabilityBrokerAction.answerOnlyAllows("executeTool"))
    }

    // MARK: - realpath 重验

    func testRealpathRevalidationBeforeExec() {
        XCTAssertTrue(LocalAgentCapabilityBrokerAction.realpathRevalidationRequiredBeforeExec(),
                      "launch 紧邻 exec 重新解析 realpath 并验证 file identity")
        XCTAssertTrue(LocalAgentCapabilityBrokerAction.identityMismatchStopsAndRequiresRedetection(),
                      "symlink 替换/路径组件变化/升级/TOCTOU → 停止并要求重新检测")
    }
}
