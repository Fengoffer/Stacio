import XCTest
@testable import StacioApp
import StacioCoreBindings

final class GraphicsBridgeTests: XCTestCase {
    func testX11ForwardingArgumentsAreAvailableFromSwift() {
        let args = CoreBridge.x11ForwardingArguments(enableX11: true, trusted: true)

        XCTAssertEqual(args, ["-X", "-Y"])
    }

    func testMissingVNCAdapterDiagnosticIsAvailableFromSwift() {
        let config = GraphicsAdapterConfig(
            adapterPath: nil,
            host: "screen.example.com",
            port: 5900,
            username: nil
        )

        XCTAssertThrowsError(try CoreBridge.buildVNCLaunchConfig(config))
    }

    func testVNCLaunchConfigIsAvailableFromSwift() throws {
        let config = GraphicsAdapterConfig(
            adapterPath: "/Applications/Stacio.app/Contents/Adapters/vnc",
            host: "screen.example.com",
            port: 5901,
            username: "ignored"
        )

        let launchConfig = try CoreBridge.buildVNCLaunchConfig(config)

        XCTAssertEqual(launchConfig.adapterPath, "/Applications/Stacio.app/Contents/Adapters/vnc")
        XCTAssertEqual(launchConfig.arguments, ["screen.example.com:5901"])
    }
}
