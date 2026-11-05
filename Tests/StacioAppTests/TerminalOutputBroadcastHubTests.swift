import XCTest
import Foundation
@testable import StacioApp

/// C-1：真实终端单写入与输出广播单消费者契约测试。
///
/// 架构不变量（经代码评审维护，不写成脆弱 grep 断言）：
/// - 每个 runtime 只有一个「既有底层 owner」从 Core 取数（`takeTerminalOutputBatch`
///   的消费点按 runtime 类型分别归属，如 RemoteTerminalPaneViewController / ConsoleSessionCoordinator / RemoteChromiumRuntime）；
/// - 新增 UI（V2 Timeline、TerminalCapabilityAdapter、状态栏）**只能**通过
///   `TerminalOutputBroadcastHub.subscribe` 订阅，不得新增第二个直接 take 类消费路径；
/// - Hub 是扇出广播，同一 runtimeID 允许多个订阅者。
///
/// 本文件测试 Hub 的扇出与发布语义（确定性可测部分）。
final class TerminalOutputBroadcastHubTests: XCTestCase {

    @MainActor
    private func makeHub() -> TerminalOutputBroadcastHub {
        TerminalOutputBroadcastHub()
    }

    @MainActor
    func testFanOutDeliversToAllSubscribersOfSameRuntime() {
        let hub = makeHub()
        let runtimeID = "r-1"
        var received: [TerminalBroadcastEvent] = []
        let s1 = hub.subscribe(runtimeID: runtimeID) { received.append($0) }
        let s2 = hub.subscribe(runtimeID: runtimeID) { received.append($0) }
        hub.publishOutput(runtimeID: runtimeID, bytes: [0x61])
        XCTAssertEqual(received.count, 2, "两个订阅者都应收到非空输出")
        XCTAssertEqual(received[0].runtimeID, runtimeID)
        XCTAssertEqual(received[1].bytes, [0x61])
        _ = s1; _ = s2
    }

    @MainActor
    func testPublishOutputEmptyBytesIsIgnored() {
        let hub = makeHub()
        var received = 0
        _ = hub.subscribe(runtimeID: "r-2") { _ in received += 1 }
        hub.publishOutput(runtimeID: "r-2", bytes: [])
        XCTAssertEqual(received, 0, "空字节输出不应被派发（单消费者/无噪音合同）")
    }

    @MainActor
    func testCommandFinishedEmptyBytesIsDispatched() {
        let hub = makeHub()
        var received = 0
        _ = hub.subscribe(runtimeID: "r-3") { _ in received += 1 }
        hub.publishCommandFinished(runtimeID: "r-3")
        XCTAssertEqual(received, 1, "commandFinished 空字节事件必须派发")
    }

    @MainActor
    func testUserInputNonEmptyIsDispatched() {
        let hub = makeHub()
        var kinds: [TerminalBroadcastEventKind] = []
        _ = hub.subscribe(runtimeID: "r-4") { kinds.append($0.kind) }
        hub.publishUserInput(runtimeID: "r-4", bytes: [0x62])
        XCTAssertEqual(kinds, [.userInput])
    }

    @MainActor
    func testUnsubscribeRemovesHandler() {
        let hub = makeHub()
        var received = 0
        let s = hub.subscribe(runtimeID: "r-5") { _ in received += 1 }
        hub.unsubscribe(runtimeID: "r-5", subscription: s)
        hub.publishOutput(runtimeID: "r-5", bytes: [0x63])
        XCTAssertEqual(received, 0, "退订后不再收到事件")
    }

    @MainActor
    func testRuntimeIsolation() {
        let hub = makeHub()
        var a = 0, b = 0
        _ = hub.subscribe(runtimeID: "r-a") { _ in a += 1 }
        _ = hub.subscribe(runtimeID: "r-b") { _ in b += 1 }
        hub.publishOutput(runtimeID: "r-a", bytes: [0x01])
        XCTAssertEqual(a, 1)
        XCTAssertEqual(b, 0, "不同 runtime 之间互不串扰")
    }
}
