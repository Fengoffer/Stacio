import XCTest
@testable import StacioApp

/// Reproduces the shape of a real relay: roughly28 events per second, each
/// carrying under two characters. The UI must keep up with that rate instead
/// of holding text back until a quota is reached.
final class StreamingLatencyContractTests: XCTestCase {
 func testSmallFragmentsAreEmittedPromptly() {
 let expectation = expectation(description: "emitted")
 expectation.expectedFulfillmentCount = 1
 let lock = NSLock()
 var emitted = ""
 var emitAt: TimeInterval = 0
 let started = CFAbsoluteTimeGetCurrent()
 let coalescer = StreamingDeltaCoalescer { text in
 lock.lock()
 emitted += text
 if emitAt == 0 { emitAt = CFAbsoluteTimeGetCurrent() - started }
 lock.unlock()
 expectation.fulfill()
 }
 // Seven events of two characters each: a quota of twelve would still be
 // waiting here, which is exactly the stall this contract forbids.
 for _ in 0..<7 {
 coalescer.append("ab")
 }
 wait(for: [expectation], timeout:1)
 coalescer.finish()
 lock.lock()
 let firstDelay = emitAt
 lock.unlock()
 XCTAssertLessThan(firstDelay, 0.1, "首批不足十二字也必须在100ms内出现")
 }

 func testLongAnswerFinishesCloseToSourceRate() {
 let lock = NSLock()
 var emittedCount = 0
 let coalescer = StreamingDeltaCoalescer { text in
 lock.lock()
 emittedCount += text.count
 lock.unlock()
 }
 let started = CFAbsoluteTimeGetCurrent()
 //81 events at ~1.79 characters, matching the measured source.
 for _ in 0..<81 {
 coalescer.append("ab")
 }
 coalescer.finish()
 let elapsed = CFAbsoluteTimeGetCurrent() - started
 lock.lock()
 let total = emittedCount
 lock.unlock()
 XCTAssertEqual(total,162, "所有字符都必须送达")
 XCTAssertLessThan(elapsed, 0.5, "批量收尾不得让总时长远离源速率")
 }
}
