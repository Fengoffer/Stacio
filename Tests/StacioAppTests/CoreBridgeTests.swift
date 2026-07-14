import XCTest
import StacioCoreBindings
@testable import StacioApp

final class CoreBridgeTests: XCTestCase {
    func testHealthReturnsStacioMetadata() throws {
        let health = try CoreBridge.health()

        XCTAssertEqual(health.ok, true)
        XCTAssertEqual(health.app, "Stacio")
        XCTAssertEqual(health.architecture, "swift-appkit-rust-core")
    }

    func testAppHealthViewModelLoadsHealth() throws {
        let viewModel = AppHealthViewModel()

        try viewModel.refresh()

        XCTAssertEqual(viewModel.appName, "Stacio")
        XCTAssertEqual(viewModel.isHealthy, true)
    }
}

