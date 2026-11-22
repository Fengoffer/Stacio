import XCTest
@testable import StacioApp

/// The structured (managed JSON-RPC) local agent runtime is retired.
///
/// A managed turn renders the CLI's tool traffic as chat, but this product hands
/// the reader a real terminal with the same reach as an SSH session instead.
/// `isReadyForStructuredRuntime` is therefore a constant `false`, which makes the
/// protocol parsers and the handshake unreachable. The tests that drove those
/// parsers were removed together with the mode they exercised; what remains is
/// the contract that keeps the mode off, so it cannot quietly come back.
final class StructuredLocalAgentRuntimeTests: XCTestCase {
    func testNoToolOffersStructuredMode() {
        for tool in LocalAgentTool.allCases {
            for protocolKind in [LocalAgentStructuredProtocol.rpc, .jsonl, nil] {
                XCTAssertFalse(
                    LocalAgentRuntimeCapabilities.supportsStructuredRuntime(
                        rawIdentity: tool.catalogRawIdentity,
                        structuredProtocol: protocolKind
                    ),
                    "\(tool.rawValue) must stay on the terminal path"
                )
            }
        }
    }

    func testEveryToolKeepsTheTerminalPath() {
        for tool in LocalAgentTool.allCases {
            let descriptor = tool.descriptor()
            guard let descriptor, descriptor.isExecutableCandidate else { continue }
            XCTAssertTrue(
                descriptor.permitsPTYFallback,
                "\(tool.rawValue) must stay launchable in a terminal"
            )
        }
    }
}
