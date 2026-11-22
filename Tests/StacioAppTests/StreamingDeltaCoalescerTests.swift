import XCTest
@testable import StacioApp

final class StreamingDeltaCoalescerTests: XCTestCase {
    private final class Emissions {
        private let lock = NSLock()
        private var values: [String] = []

        func append(_ text: String) {
            lock.lock()
            values.append(text)
            lock.unlock()
        }

        var snapshot: [String] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    func testFragmentsJoinedInOrderAfterFinish() {
        let emitted = Emissions()
        let coalescer = StreamingDeltaCoalescer(interval: 0.01, emit: emitted.append)
        let fragments = (0..<50).map { index in "x" + String(index) }
        fragments.forEach { coalescer.append($0) }
        coalescer.finish()
        XCTAssertEqual(emitted.snapshot.joined(), fragments.joined(), "顺序与内容都不能丢")
    }

    func testFinishFlushesRemainingBuffer() {
        let emitted = Emissions()
        let coalescer = StreamingDeltaCoalescer(interval: 5, emit: emitted.append)
        coalescer.append("a")
        coalescer.append("b")
        coalescer.finish()
        XCTAssertEqual(emitted.snapshot.joined(), "ab")
    }

    func testAppendAfterFinishIsIgnored() {
        let emitted = Emissions()
        let coalescer = StreamingDeltaCoalescer(interval: 5, emit: emitted.append)
        coalescer.finish()
        coalescer.append("late")
        coalescer.finish()
        XCTAssertTrue(emitted.snapshot.isEmpty, "结束后不再接受碎片")
    }

    func testEmptyFragmentsIgnored() {
        let emitted = Emissions()
        let coalescer = StreamingDeltaCoalescer(interval: 5, emit: emitted.append)
        coalescer.append("")
        coalescer.finish()
        XCTAssertTrue(emitted.snapshot.isEmpty)
    }

    func testSmallBatchWaitsForCharacterTargetPastOrdinaryInterval() {
        let emitted = Emissions()
        let delivered = expectation(description: "character target delivered")
        let coalescer = StreamingDeltaCoalescer(
            interval: 0.02,
            minimumCharacterCount: 12,
            maximumLatency: 0.5
        ) { text in
            emitted.append(text)
            delivered.fulfill()
        }
        coalescer.append("中")
        Thread.sleep(forTimeInterval: 0.08)
        XCTAssertTrue(emitted.snapshot.isEmpty, "80ms 内不足12字，不应逐字刷新")
        coalescer.append(String(repeating: "文", count: 11))
        wait(for: [delivered], timeout: 1)
        coalescer.finish()
        XCTAssertEqual(emitted.snapshot, ["中" + String(repeating: "文", count: 11)])
    }

    func testSmallBatchHasBoundedLatency() {
        let emitted = Emissions()
        let delivered = expectation(description: "short reply delivered without finish")
        let coalescer = StreamingDeltaCoalescer(
            interval: 0.01,
            minimumCharacterCount: 12,
            maximumLatency: 0.05
        ) { text in
            emitted.append(text)
            delivered.fulfill()
        }
        coalescer.append("好")
        wait(for: [delivered], timeout: 1)
        XCTAssertEqual(emitted.snapshot, ["好"])
        coalescer.finish()
    }

    func testSlowCharacterSourceIsBatchedAndTailIsPreserved() {
        let emitted = Emissions()
        let coalescer = StreamingDeltaCoalescer(
            interval: 0.005,
            minimumCharacterCount: 12,
            maximumLatency: 0.06,
            emit: emitted.append
        )
        for _ in 0..<12 {
            coalescer.append("中")
            Thread.sleep(forTimeInterval: 0.01)
        }
        coalescer.finish()
        XCTAssertEqual(emitted.snapshot.joined(), String(repeating: "中", count: 12))
        XCTAssertLessThan(emitted.snapshot.count, 6, "慢速单字源应合并为多字批次")
    }

    func testFullFragmentsStillRespectRefreshInterval() {
        let emitted = Emissions()
        let coalescer = StreamingDeltaCoalescer(
            interval: 0.2,
            minimumCharacterCount: 12,
            emit: emitted.append
        )
        coalescer.append(String(repeating: "中", count: 12))
        Thread.sleep(forTimeInterval: 0.03)
        XCTAssertTrue(emitted.snapshot.isEmpty, "大碎片也不能绕过刷新间隔")
        coalescer.finish()
        XCTAssertEqual(emitted.snapshot.joined(), String(repeating: "中", count: 12))
    }

    func testConcurrentFlushesPreserveProducerOrder() {
        let emitted = Emissions()
        let coalescer = StreamingDeltaCoalescer(interval: 10) { text in
            emitted.append(text)
            // Keep emit busy while other flushers contend for the next batch.
            Thread.sleep(forTimeInterval: 0.00002)
        }
        let flushers = DispatchGroup()
        for _ in 0..<3 {
            flushers.enter()
            DispatchQueue.global().async {
                for _ in 0..<20_000 {
                    coalescer.flush()
                }
                flushers.leave()
            }
        }
        for index in 0..<4_000 {
            coalescer.append(String(index) + ",")
            coalescer.flush()
        }
        XCTAssertEqual(flushers.wait(timeout: .now() + 10), .success)
        coalescer.finish()
        let values = emitted.snapshot.joined().split(separator: ",").compactMap { Int($0) }
        XCTAssertEqual(values, Array(0..<4_000))
    }

    func testExplicitFlushInvalidatesOldTimerForNextBatch() {
        let emitted = Emissions()
        let coalescer = StreamingDeltaCoalescer(interval: 0.2, emit: emitted.append)
        coalescer.append("first")
        Thread.sleep(forTimeInterval: 0.08)
        coalescer.flush()
        coalescer.append("second")
        Thread.sleep(forTimeInterval: 0.15)
        XCTAssertEqual(emitted.snapshot, ["first"], "上一批旧定时器不能提前刷新下一批")
        coalescer.finish()
        XCTAssertEqual(emitted.snapshot, ["first", "second"])
    }
}
