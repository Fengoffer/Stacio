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

    func testExternalBLERuntimeReusesTerminalBridgeOperations() throws {
        let runtime = try CoreBridge.openExternalTerminalRuntime(
            kind: "ble_console",
            endpoint: "NBEE_BLE_1103",
            cols: 80,
            rows: 24
        )
        defer { _ = try? CoreBridge.closeTerminalRuntime(runtimeID: runtime.id) }

        XCTAssertEqual(runtime.kind, "ble_console")
        XCTAssertEqual(runtime.remoteHost, "NBEE_BLE_1103")
        XCTAssertNil(runtime.remotePort)

        try CoreBridge.recordTerminalOutput(runtimeID: runtime.id, bytes: [0x4F, 0x4B])
        let firstBatch = try CoreBridge.takeTerminalOutputBatch(runtimeID: runtime.id)
        XCTAssertEqual(Array(firstBatch.bytes), [0x4F, 0x4B])

        let resized = try CoreBridge.recordTerminalResize(
            runtimeID: runtime.id,
            cols: 120,
            rows: 40
        )
        XCTAssertEqual(resized.cols, 120)
        XCTAssertEqual(resized.rows, 40)

        let paused = try CoreBridge.setTerminalOutputPaused(runtimeID: runtime.id, paused: true)
        XCTAssertTrue(paused.outputPaused)
        try CoreBridge.recordTerminalOutput(runtimeID: runtime.id, bytes: [0x52, 0x58])
        let pausedBatch = try CoreBridge.takeTerminalOutputBatch(runtimeID: runtime.id)
        XCTAssertTrue(pausedBatch.bytes.isEmpty)

        let resumed = try CoreBridge.setTerminalOutputPaused(runtimeID: runtime.id, paused: false)
        XCTAssertFalse(resumed.outputPaused)
        let resumedBatch = try CoreBridge.takeTerminalOutputBatch(runtimeID: runtime.id)
        XCTAssertEqual(Array(resumedBatch.bytes), [0x52, 0x58])

        let closed = try CoreBridge.closeTerminalRuntime(runtimeID: runtime.id)
        XCTAssertEqual(closed.status, "closed")
    }

    func testConsoleContractBridgeUsesValidatedCoreAPIs() throws {
        let json = #"""
        {
          "kind": "console",
          "schemaVersion": 1,
          "transportPolicy": "prefer_ble",
          "ble": {
            "deviceName": "NBEE_BLE_1103",
            "profileID": "bterm-ffe1-split-v1",
            "serviceUUID": "FFE1",
            "txCharacteristicUUID": "FFE3",
            "rxCharacteristicUUID": "FFE2",
            "writeType": "without_response",
            "platformBindings": {
              "macOSPeripheralUUID": "opaque-device-id",
              "windowsDeviceID": null
            }
          },
          "sppFallback": null
        }
        """#

        let config = try CoreBridge.parseConsoleSessionConfig(json: json)
        XCTAssertEqual(config.ble.profileId, "bterm-ffe1-split-v1")
        XCTAssertEqual(config.ble.serviceUuid, "0000ffe1-0000-1000-8000-00805f9b34fb")
        XCTAssertEqual(config.ble.platformBindings.macOsPeripheralUuid, "opaque-device-id")

        let serialized = try CoreBridge.serializeConsoleSessionConfig(config: config)
        let reparsed = try CoreBridge.parseConsoleSessionConfig(json: serialized)
        XCTAssertEqual(reparsed, config)

        let profile = CoreBridge.matchBLEConsoleProfile(services: [
            ConsoleServiceMetadata(
                uuid: "FFE1",
                characteristics: [
                    ConsoleCharacteristicMetadata(
                        uuid: "FFE3",
                        supportsWrite: false,
                        supportsWriteWithoutResponse: true,
                        supportsNotify: false,
                        supportsIndicate: false
                    ),
                    ConsoleCharacteristicMetadata(
                        uuid: "FFE2",
                        supportsWrite: false,
                        supportsWriteWithoutResponse: false,
                        supportsNotify: true,
                        supportsIndicate: false
                    ),
                ]
            ),
        ])
        XCTAssertEqual(profile?.profileId, "bterm-ffe1-split-v1")
        XCTAssertEqual(
            CoreBridge.consoleTransportPolicy(platform: .macos, windowsPort: "COM7"),
            .bleOnly
        )
    }
}
