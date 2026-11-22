import XCTest
@testable import StacioApp

final class TransferRateSamplerTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 100)

    func testFrequentPollsAndDuplicateRepaintsDoNotInflateOrStarveRate() throws {
        var sampler = TransferRateSampler()
        _ = sampler.update(bytesDone: 0, status: "running", at: start)
        for tick in 1...50 {
            let time = start.addingTimeInterval(Double(tick) / 10)
            // A redraw just before the byte update used to shrink the denominator.
            _ = sampler.update(bytesDone: UInt64(tick - 1) * 1_048_576, status: "running", at: time.addingTimeInterval(-0.00001))
            let rate = sampler.update(bytesDone: UInt64(tick) * 1_048_576, status: "running", at: time)
            if tick >= 10 {
                XCTAssertEqual(try XCTUnwrap(rate), 10 * 1_048_576, accuracy: 2 * 1_048_576)
            }
        }
    }

    func testFirstSampleAndResumeOffsetAreNotCountedAsNewTraffic() throws {
        var sampler = TransferRateSampler()
        XCTAssertNil(sampler.update(bytesDone: 10_000_000_000, status: "resuming", at: start))
        XCTAssertEqual(sampler.update(bytesDone: 10_001_000_000, status: "running", at: start.addingTimeInterval(1)), 1_000_000)
        XCTAssertNil(sampler.update(bytesDone: 10_001_000_000, status: "paused", at: start.addingTimeInterval(2)))
        XCTAssertNil(sampler.update(bytesDone: 8_000_000_000, status: "resuming", at: start.addingTimeInterval(10)))
        XCTAssertEqual(sampler.update(bytesDone: 8_001_000_000, status: "running", at: start.addingTimeInterval(11)), 1_000_000)
    }

    func testStallClearsRateAndClockRollbackResetsBaseline() {
        var sampler = TransferRateSampler()
        _ = sampler.update(bytesDone: 0, status: "running", at: start)
        XCTAssertEqual(sampler.update(bytesDone: 1024, status: "running", at: start.addingTimeInterval(1)), 1024)
        XCTAssertEqual(sampler.update(bytesDone: 1024, status: "running", at: start.addingTimeInterval(3)), 0)
        XCTAssertNil(sampler.update(bytesDone: 2048, status: "running", at: start))
        XCTAssertNil(sampler.update(bytesDone: 2048, status: "completed", at: start))
    }
}
