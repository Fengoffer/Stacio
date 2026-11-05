import XCTest
import Foundation
@testable import StacioApp

/// P7-1：TerminalCapabilityAdapter（事件映射不改底层语义、hub 订阅、单写入者、lease 重验、断连/重连）。
final class TerminalCapabilityAdapterTests: XCTestCase {

    // MARK: - 事件映射

    func testSignalMappingDoesNotChangeUnderlyingSemantics() {
        XCTAssertEqual(
            TerminalCapabilityAdapter.mapSignal(.output(runtimeID: "rt-1", bytes: 100)),
            "terminalOutput"
        )
        XCTAssertEqual(
            TerminalCapabilityAdapter.mapSignal(.commandStarted(commandID: "c-1")),
            "toolExecutionStarted"
        )
        XCTAssertEqual(
            TerminalCapabilityAdapter.mapSignal(.commandCompleted(commandID: "c-1", exitCode: 0)),
            "toolExecutionCompleted"
        )
        XCTAssertEqual(
            TerminalCapabilityAdapter.mapSignal(.commandFailed(commandID: "c-1", errorCategory: "io")),
            "toolExecutionFailed"
        )
        XCTAssertEqual(
            TerminalCapabilityAdapter.mapSignal(.connectionLost(runtimeID: "rt-1")),
            "terminalConnectionLost"
        )
    }

    // MARK: - hub 订阅与单写入者

    func testSubscribesToHubOnlyAndSingleWriter() {
        XCTAssertTrue(TerminalCapabilityAdapter.subscribesToBroadcastHubOnly(),
                      "真实终端输出仍唯一底层消费者（Adapter 只订阅 hub 不新增 take 类消费路径）")
        XCTAssertTrue(TerminalCapabilityAdapter.singleWriterPolicy(),
                      "每终端单写入者")
    }

    // MARK: - lease 重验

    func testWriteAllowedWhenLeaseMatches() {
        let lease = TerminalWriteLease(targetBindingDigest: "d1", runtimeID: "rt-1", leaseGeneration: 2)
        let result = TerminalCapabilityAdapter.writeAllowed(
            current: lease, expected: lease, connected: true
        )
        guard case .success = result else { return XCTFail("匹配时允许写入") }
    }

    func testWriteRejectedOnAnyLeaseChange() {
        let base = TerminalWriteLease(targetBindingDigest: "d1", runtimeID: "rt-1", leaseGeneration: 2)
        // digest 变化
        let result1 = TerminalCapabilityAdapter.writeAllowed(
            current: base,
            expected: TerminalWriteLease(targetBindingDigest: "d2", runtimeID: "rt-1", leaseGeneration: 2),
            connected: true
        )
        guard case .failure(.leaseMismatch) = result1 else {
            return XCTFail("digest 变化拒绝写入")
        }
        // runtimeID 变化
        let result2 = TerminalCapabilityAdapter.writeAllowed(
            current: base,
            expected: TerminalWriteLease(targetBindingDigest: "d1", runtimeID: "rt-2", leaseGeneration: 2),
            connected: true
        )
        guard case .failure(.leaseMismatch) = result2 else {
            return XCTFail("runtimeID 变化拒绝写入")
        }
        // generation 变化
        let result3 = TerminalCapabilityAdapter.writeAllowed(
            current: base,
            expected: TerminalWriteLease(targetBindingDigest: "d1", runtimeID: "rt-1", leaseGeneration: 3),
            connected: true
        )
        guard case .failure(.leaseMismatch) = result3 else {
            return XCTFail("leaseGeneration 变化拒绝写入")
        }
    }

    func testWriteRejectedOnConnectionLost() {
        let lease = TerminalWriteLease(targetBindingDigest: "d1", runtimeID: "rt-1", leaseGeneration: 1)
        let result = TerminalCapabilityAdapter.writeAllowed(
            current: lease, expected: lease, connected: false
        )
        guard case .failure(.connectionLostBeforeWrite) = result else {
            return XCTFail("断连立即拒绝写入")
        }
    }

    // MARK: - 断连/重连

    func testDisconnectRevokesLeaseAndReconnectCreatesNewLease() {
        XCTAssertTrue(TerminalCapabilityAdapter.disconnectRevokesLease(connectionLost: true),
                      "连接断开立即撤销终端租约")
        XCTAssertFalse(TerminalCapabilityAdapter.disconnectRevokesLease(connectionLost: false))
        XCTAssertTrue(TerminalCapabilityAdapter.reconnectCreatesNewLease(),
                      "重连只创建新 lease")
    }

    // MARK: - ambiguousUserInput 保留

    func testAmbiguousUserInputRetained() {
        XCTAssertTrue(TerminalCapabilityAdapter.ambiguousUserInputRetained(),
                      "ambiguousUserInput 保留（不丢弃）")
    }

    // MARK: - 执行模式不迁移运行中命令

    func testExecutionModeChangeCannotMigrateRunningCommand() {
        XCTAssertTrue(TerminalCapabilityAdapter.executionModeChangeCannotMigrateRunningCommand(),
                      "执行模式改变只影响下一条未启动的工具调用，不能迁移正在运行的命令")
    }
}
