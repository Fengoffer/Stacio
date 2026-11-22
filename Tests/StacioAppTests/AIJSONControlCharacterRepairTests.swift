import XCTest
@testable import StacioApp

/// The repair exists because a real relay returned a valid answer whose JSON
/// string values contained raw newlines, which strict decoding rejects.
final class AIJSONControlCharacterRepairTests: XCTestCase {
 func testEscapesRawNewlinesInsideStringValues() throws {
 let source = "{\"message\":\"line one\nline two\",\"commands\":[]}"
 let repaired = AIJSONControlCharacterRepair.repair(source)
 let decoded = try JSONSerialization.jsonObject(with: Data(repaired.utf8)) as? [String: Any]
 XCTAssertEqual(decoded?["message"] as? String, "line one\nline two")
    /// Every code point below U+0020 is illegal inside a JSON string, not only
    /// the newline, carriage-return and tab that real relays tend to emit.
    func testAllControlCharactersAreEscaped() throws {
        let formFeed = Character(UnicodeScalar(0x0C)!)
        let backspace = Character(UnicodeScalar(0x08)!)
        let raw = "{\"m\":\"a" + String(formFeed) + "b" + String(backspace) + "c\"}"
        let repaired = AIJSONControlCharacterRepair.repair(raw)
        let decoded = try JSONSerialization.jsonObject(with: Data(repaired.utf8)) as? [String: Any]
        XCTAssertNotNil(decoded?["m"])
    }
 }

 func testLeavesStructuralWhitespaceOutsideStringsUntouched() {
 let source = "{\n \"message\": \"ok\",\n \"commands\": []\n}"
 XCTAssertEqual(AIJSONControlCharacterRepair.repair(source), source)
 }

 func testPreservesAlreadyEscapedSequences() throws {
 let source = "{\"message\":\"a\\nb\"}"
 let repaired = AIJSONControlCharacterRepair.repair(source)
 let decoded = try JSONSerialization.jsonObject(with: Data(repaired.utf8)) as? [String: Any]
 XCTAssertEqual(decoded?["message"] as? String, "a\nb")
 }

 /// A real turn returned bare Markdown with no JSON envelope at all. That
 /// must render as the answer rather than surface a format error.
 func testPlainMarkdownIsNotTreatedAsMalformedJSON() throws {
 let plain = "##结论" + "\n\n" + "容器内 Java进程存活约3秒即退出。"
 XCTAssertFalse(plain.hasPrefix("{"))
 let repaired = AIJSONControlCharacterRepair.repair(plain)
 XCTAssertEqual(repaired, plain, "纯文本不应被改动")
 }

 func testRealWorldPayloadWithTablesAndNewlinesDecodes() throws {
 let source = "{\"message\":\"**结论**\n\n|指标 |值 |\n| --- | --- |\n|核数 |4 |\",\"commands\":[]}"
 let repaired = AIJSONControlCharacterRepair.repair(source)
 let decoded = try JSONSerialization.jsonObject(with: Data(repaired.utf8)) as? [String: Any]
 let message = try XCTUnwrap(decoded?["message"] as? String)
 XCTAssertTrue(message.contains("|核数 |4 |"))
 }
}
