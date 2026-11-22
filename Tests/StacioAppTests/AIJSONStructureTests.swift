import XCTest
@testable import StacioApp

final class AIJSONStructureTests: XCTestCase {
    func testBalancedObjectIsComplete() {
        XCTAssertTrue(AIJSONStructure.isCompleteObject(#"{"message":"x","commands":[{"command":"u"}]}"#))
    }

    func testTruncatedObjectIsNotComplete() {
        XCTAssertFalse(AIJSONStructure.isCompleteObject(#"{"message":"y""#))
    }

    func testBracesInsideStringsAreIgnored() {
        XCTAssertTrue(AIJSONStructure.isCompleteObject(#"{"message":"a { b } c"}"#))
    }

    /// Interleaved closers have equal counts but are not valid nesting.
    func testMismatchedBracketOrderIsRejected() {
        XCTAssertFalse(AIJSONStructure.isCompleteObject(#"{"a":[}"#), "类型交错不算完整")
        XCTAssertFalse(AIJSONStructure.isCompleteObject(#"{"a":[1}"#), "缺方括号")
        XCTAssertFalse(AIJSONStructure.isCompleteObject(#"{"a":1]"#), "多余方括号")
    }

    func testEscapedStringStillBalances() {
        XCTAssertTrue(AIJSONStructure.isCompleteObject(#"{"m":"a \" b"}"#))
    }
}