import XCTest
import Foundation
@testable import StacioApp

/// P7-4a：Terminal/SecureInput Lease 集成（共用合同、安全输入失效/暂停/敏感值隔离、control PTY 独立）。
final class TerminalLeaseIntegrationTests: XCTestCase {

    func testRealAndVirtualTerminalsShareContract() {
        XCTAssertTrue(TerminalLeaseContract.sharedContractForRealAndVirtualTerminals(),
                      "真实/虚拟终端共用审批/审计/脱敏/取消/输出事件合同")
    }

    func testControlPTYIndependentFromTargetExecution() {
        XCTAssertTrue(TerminalLeaseContract.controlPTYIndependentLeaseAndUIRegion(),
                      "Local Agent control PTY 与目标执行面是独立 lease 与 UI 区域")
        XCTAssertTrue(TerminalLeaseContract.controlPTYCannotReuseRuntimeIDInputLockCompletion(),
                      "不能复用 runtimeID/输入锁/完成判断")
    }

    func testSecureInputInvalidationOnAnyEvent() {
        for event in [SecureInputInvalidationEvent.windowResignsKey, .generationChanged, .stopped,
                      .takenOver, .sleepOrLock, .processExited] {
            XCTAssertTrue(SecureInputLeaseAction.invalidatedBy(event), "\(event) 立即失效")
        }
    }

    func testSecureInputSingleUseTwoMinutes() {
        XCTAssertEqual(SecureInputLeaseAction.singleUseDefaultDuration, 120, "单次使用默认 2 分钟")
        let issued = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertFalse(SecureInputLeaseAction.expired(issuedAt: issued, now: issued.addingTimeInterval(60)))
        XCTAssertTrue(SecureInputLeaseAction.expired(issuedAt: issued, now: issued.addingTimeInterval(121)))
        XCTAssertTrue(SecureInputLeaseAction.singleUse(consumed: true), "单次使用")
    }

    func testSecureInputPausesSensitiveCollection() {
        XCTAssertTrue(SecureInputLeaseAction.pausesAgentInputInjection())
        XCTAssertTrue(SecureInputLeaseAction.pausesKeyAndEchoBroadcast())
        XCTAssertTrue(SecureInputLeaseAction.pausesTranscriptRecorder())
        XCTAssertTrue(SecureInputLeaseAction.pausesTerminalContentCheckpoint())
        XCTAssertTrue(SecureInputLeaseAction.pausesNormalLogging())
    }

    func testSecureValueIsolation() {
        XCTAssertTrue(SecureInputLeaseAction.writesOnlyFromMemoryBufferToCurrentGenerationPTY(),
                      "敏感值只从内存缓冲直接写该代次目标 PTY")
        XCTAssertTrue(SecureInputLeaseAction.clearsAfterCommitOrCancel(), "提交或取消后立即清零")
        XCTAssertTrue(SecureInputLeaseAction.neverEntersModelHistoryQueueClipboardEventsLogsOrCrashReports(),
                      "不进入模型/历史/队列/剪贴板监控/Event payload/日志/崩溃报告")
        XCTAssertTrue(SecureInputLeaseAction.returnsStructuredResultWithoutEchoBackfill(),
                      "lease 结束只恢复非敏感记录并返回结构化结果，不回填含回显原文")
    }
}

/// P7-4b：SecureInputLease 绑定 generation 与 prompt digest。
final class SecureInputLeaseTests: XCTestCase {

    func testLeaseBindsGenerationAndPromptDigest() {
        let lease = SecureInputLease(
            leaseID: "si-1", terminalRuntimeGeneration: 3, promptDigest: "digest-p", issuedAt: Date()
        )
        XCTAssertEqual(lease.terminalRuntimeGeneration, 3, "绑定 TerminalRuntimeLease.generation")
        XCTAssertEqual(lease.promptDigest, "digest-p", "绑定 prompt digest")
        XCTAssertFalse(lease.consumed)
    }

    func testGenerationChangeInvalidatesLease() {
        // 代次变化 → 立即失效（写入前校验）
        XCTAssertTrue(SecureInputLeaseAction.invalidatedBy(.generationChanged))
    }
}
