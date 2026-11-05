import XCTest
import Foundation
@testable import StacioApp

/// P4-16：高级诊断页与可观测性关联链。
final class AdvancedDiagnosticsTests: XCTestCase {

    private func makeChain() -> ObservabilityCorrelationChain {
        ObservabilityCorrelationChain(
            conversationID: "conv-1", turnID: "turn-1", attemptID: "attempt-1",
            admissionLeaseID: "lease-1", schedulerGeneration: 2,
            permitID: "permit-1", invocationID: "inv-1", providerRequestID: "req-1",
            localAgentSessionID: nil, capabilityGeneration: "cap-1",
            toolProposalID: "proposal-1", terminalExecutionID: "term-1"
        )
    }

    // MARK: - 全链路关联链

    func testCorrelationChainFullLink() {
        let chain = makeChain()
        XCTAssertEqual(chain.conversationID, "conv-1")
        XCTAssertEqual(chain.turnID, "turn-1")
        XCTAssertEqual(chain.attemptID, "attempt-1")
        XCTAssertEqual(chain.admissionLeaseID, "lease-1", "Admission Lease")
        XCTAssertEqual(chain.schedulerGeneration, 2, "Scheduler Generation")
        XCTAssertEqual(chain.permitID, "permit-1", "Permit/Target Journal")
        XCTAssertEqual(chain.invocationID, "inv-1", "Invocation")
        XCTAssertEqual(chain.providerRequestID, "req-1", "Provider Request")
        XCTAssertEqual(chain.capabilityGeneration, "cap-1")
        XCTAssertEqual(chain.toolProposalID, "proposal-1", "Tool Proposal")
        XCTAssertEqual(chain.terminalExecutionID, "term-1", "Terminal Execution ID")
    }

    func testTimelineTracesToRedactedLog() {
        let chain = makeChain()
        let path = chain.redactedLogPath()
        XCTAssertEqual(path, "redacted-logs/conv-1/turn-1/attempt-1/lease-1.jsonl")
        XCTAssertFalse(path.contains("secret"), "关联链只指向脱敏日志")
    }

    func testLocalAgentSessionAlternatePath() {
        let chain = ObservabilityCorrelationChain(
            conversationID: "c", turnID: "t", attemptID: "a",
            admissionLeaseID: "l", schedulerGeneration: 1,
            permitID: nil, invocationID: nil, providerRequestID: nil,
            localAgentSessionID: "session-9", capabilityGeneration: "cap-9",
            toolProposalID: nil, terminalExecutionID: nil
        )
        XCTAssertEqual(chain.localAgentSessionID, "session-9", "Local Agent Session 替代 Invocation/Provider Request 路径")
        XCTAssertNil(chain.permitID)
    }

    // MARK: - 脱敏

    func testDiagnosticsOnlyExposeRedactedInfo() {
        XCTAssertEqual(AdvancedDiagnosticsAction.redacted("sk-secret-token"), "[redacted]")
        XCTAssertEqual(AdvancedDiagnosticsAction.redacted(""), "")
        XCTAssertFalse(AdvancedDiagnosticsAction.showsRawSecrets(), "不显示原始 Key/Token/capability/完整环境变量")
    }

    func testSnapshotReadOnlyProjection() {
        let snapshot = AdvancedDiagnosticsSnapshot(
            catalogSetRevision: 3,
            catalogResourceHashes: ["provider.json": "sha256:abc"],
            modelSyncRawState: "synced",
            schedulerGeneration: 2,
            localAgentContainment: LocalAgentContainment(targetBindingCount: 0, workspaceCount: 0, effectBrokerCount: 0),
            localAgentProcessState: .running,
            externalEffectReconciliationSummary: "0 unknown",
            correlationChain: makeChain()
        )
        XCTAssertEqual(snapshot.catalogSetRevision, 3)
        XCTAssertEqual(snapshot.catalogResourceHashes["provider.json"], "sha256:abc")
        XCTAssertEqual(snapshot.modelSyncRawState, "synced")
        XCTAssertTrue(snapshot.localAgentContainment.isContained)
        XCTAssertEqual(snapshot.localAgentProcessState, .running)
    }

    // MARK: - Catalog Set 损坏

    func testCorruptedCatalogDiagnosticsOnly() {
        XCTAssertTrue(AdvancedDiagnosticsAction.corruptedCatalogAllowsDiagnosticsOnly())
        XCTAssertTrue(AdvancedDiagnosticsAction.corruptedCatalogBlocksNewExecution(), "损坏/混合 Catalog Set 不能继续新执行")
    }

    // MARK: - 默认日志范围

    func testDefaultLogFieldsOnlyMetadata() {
        let fields = AdvancedDiagnosticsAction.defaultLogFields()
        XCTAssertEqual(fields, ["phase", "duration", "state", "byteCount", "errorCategory"])
        XCTAssertFalse(fields.contains("promptBody"), "Prompt 默认不进遥测")
        let never = AdvancedDiagnosticsAction.contentNeverInTelemetry()
        XCTAssertTrue(never.contains("promptBody"))
        XCTAssertTrue(never.contains("responseBody"))
        XCTAssertTrue(never.contains("terminalContent"))
        XCTAssertTrue(never.contains("attachments"))
    }

    // MARK: - 诊断包导出

    func testExportManifestAndRedactedPreviewFirst() {
        XCTAssertTrue(AdvancedDiagnosticsAction.exportShowsManifestAndRedactedPreviewFirst())
        XCTAssertTrue(AdvancedDiagnosticsAction.exportNeverIncludesSensitive(),
                      "永不包含 Keychain 凭证/OAuth/安全输入/完整环境变量")
    }

    // MARK: - resetCaches / redetectRuntimes

    func testResetCachesOnlyRegenerable() {
        XCTAssertTrue(AdvancedDiagnosticsAction.resetCachesRemovesOnlyRegenerable(),
                      "resetCaches 只删除可再生模型/Catalog 诊断缓存")
    }

    func testRedetectPerConfigurationUnderGlobalLimitOne() {
        XCTAssertTrue(AdvancedDiagnosticsAction.redetectPerConfigurationIndependentOperation(),
                      "逐配置创建独立 detect operation")
        XCTAssertTrue(AdvancedDiagnosticsAction.redetectSubjectToGlobalLimitOne(),
                      "受 settings-process 全局上限 1 约束")
    }
}
