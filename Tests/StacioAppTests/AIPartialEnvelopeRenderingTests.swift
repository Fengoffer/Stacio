import XCTest
@testable import StacioApp

/// The transcript must never show the JSON envelope mid-stream. A relay that
/// streams an envelope character by character would otherwise flash braces and
/// escapes at the reader, which is exactly what was reported.
final class AIPartialEnvelopeRenderingTests: XCTestCase {
 private func project(_ text: String) -> String {
 OpenAICompatibleAIAssistantProvider.visibleProjectionForTesting(text)
 }

 func testEnvelopeWithoutMessageYetRendersNothing() {
 let prefixes = [
 "{\"mes",
 "{\"message",
 "{\"mess"
 ]
 for prefix in prefixes {
 XCTAssertEqual(
 project(prefix),
 "",
 "不得把尚未成型的信封当正文: \(prefix)"
 )
 }
 }

 func testEnvelopeWithPartialMessageShowsProseOnly() {
 let raw = "{\"message\":\"##结论"
 let rendered = project(raw)
 XCTAssertTrue(rendered.hasPrefix("##结论"), "应只显示正文")
 XCTAssertFalse(rendered.contains("message\""), "不得泄露字段名")
 }
}
