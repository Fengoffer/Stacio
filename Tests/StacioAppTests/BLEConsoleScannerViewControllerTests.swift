import AppKit
import Foundation
import StacioCoreBindings
import XCTest
@testable import StacioApp

@MainActor
final class BLEConsoleScannerViewControllerTests: XCTestCase {
    func testNativeScannerControlsAndNBEESelectionContract() {
        let driver = RecordingScannerDriver()
        let controller = BLEConsoleScannerViewController(driver: driver)
        controller.loadView()

        XCTAssertTrue(type(of: controller.searchFieldForTesting) == NSSearchField.self)
        XCTAssertTrue(type(of: controller.tableViewForTesting) == NSTableView.self)
        XCTAssertTrue(type(of: controller.scrollViewForTesting) == NSScrollView.self)
        XCTAssertEqual(controller.tableViewForTesting.rowHeight, 40)
        XCTAssertTrue(controller.progressIndicatorForTesting.isIndeterminate)
        XCTAssertTrue(controller.rescanButtonForTesting.image?.isTemplate ?? false)
        XCTAssertEqual(controller.rescanButtonForTesting.toolTip, L10n.BLEConsole.scannerRescan)
        XCTAssertFalse(controller.connectButtonForTesting.isEnabled)

        let nbee = scannerDevice(name: "NBEE_BLE_1103", rssi: -54, services: ["FFE1"])
        let other = scannerDevice(name: "Other Console", rssi: -30, services: [])
        controller.applySnapshotForTesting(
            BLEConsoleDiscoverySnapshot(devices: [other, nbee], generatedAt: Date())
        )

        XCTAssertNil(controller.selectedIdentifierForTesting)
        XCTAssertTrue(driver.connectCalls.isEmpty)
        XCTAssertEqual(controller.rowModel(at: 0).leadingSymbolName, "bluetooth")
        XCTAssertEqual(controller.rowModel(at: 0).signalSymbolName, "cellularbars")
        XCTAssertEqual(controller.rowModel(at: 0).signalStrength, 46.0 / 60.0, accuracy: 0.001)
        XCTAssertFalse(controller.rowModel(at: 0).detail.contains("dBm"))
        XCTAssertEqual(controller.rowModel(at: 0).recognitionSymbolName, "checkmark.circle.fill")
        XCTAssertEqual(controller.rowModel(at: 1).signalStrength, 1, accuracy: 0.001)
        XCTAssertFalse(controller.rowModel(at: 1).detail.contains("dBm"))

        controller.selectDeviceForTesting(nbee.identifier)
        XCTAssertTrue(controller.connectButtonForTesting.isEnabled)
        XCTAssertEqual(controller.selectedIdentifierForTesting, nbee.identifier)
    }

    func testSearchPreservesSelectionAndCommandRStartsAnotherScan() {
        let driver = RecordingScannerDriver()
        let controller = BLEConsoleScannerViewController(driver: driver)
        controller.loadView()
        let nbee = scannerDevice(name: "NBEE_BLE_1103", rssi: -42, services: ["FFE1"])
        let router = scannerDevice(name: "Router Console", rssi: -62, services: ["FFE1"])
        controller.applySnapshotForTesting(
            BLEConsoleDiscoverySnapshot(devices: [nbee, router], generatedAt: Date())
        )
        controller.selectDeviceForTesting(router.identifier)
        controller.setSearchQueryForTesting("router")

        XCTAssertEqual(controller.filteredDevicesForTesting.map(\.displayName), ["Router Console"])
        XCTAssertEqual(controller.selectedIdentifierForTesting, router.identifier)
        XCTAssertTrue(controller.connectButtonForTesting.isEnabled)

        controller.handleKeyForTesting(keyCode: 15, command: true)
        XCTAssertEqual(driver.startScanCount, 2)
        XCTAssertNil(controller.selectedIdentifierForTesting)
    }

    func testBuiltInProfileProbeBuildsConfigAndDisconnectsExactlyOnce() {
        let driver = RecordingScannerDriver()
        let controller = BLEConsoleScannerViewController(driver: driver)
        controller.loadView()
        let device = scannerDevice(name: "NBEE_BLE_1103", rssi: -45, services: ["FFE1"])
        controller.applySnapshotForTesting(
            BLEConsoleDiscoverySnapshot(devices: [device], generatedAt: Date())
        )
        controller.selectDeviceForTesting(device.identifier)
        controller.connectForTesting()

        XCTAssertEqual(driver.connectCalls.count, 1)
        let generation = driver.connectCalls[0].generation
        controller.handleEventForTesting(.connected(identifier: device.identifier, generation: generation))
        controller.handleEventForTesting(.servicesDiscovered(
            identifier: device.identifier,
            services: [splitService()],
            generation: generation
        ))

        XCTAssertEqual(driver.disconnectCalls.count, 1)
        XCTAssertEqual(controller.resultForTesting?.ble.deviceName, "NBEE_BLE_1103")
        XCTAssertEqual(controller.resultForTesting?.ble.profileId, "bterm-ffe1-split-v1")
        XCTAssertEqual(controller.resultForTesting?.ble.serviceUuid, normalized("FFE1"))
        XCTAssertEqual(controller.resultForTesting?.ble.platformBindings.macOsPeripheralUuid, device.identifier.uuidString)

        controller.handleEventForTesting(.disconnected(
            identifier: device.identifier,
            error: nil,
            generation: generation
        ))
        XCTAssertEqual(driver.disconnectCalls.count, 1)
    }

    func testUnknownProfileUsesMapperAndRequiresValidCharacteristics() {
        let invalid = BLEConsoleCharacteristicMapperViewController(
            deviceName: "Unknown",
            services: [ConsoleServiceMetadata(
                uuid: "1234",
                characteristics: [ConsoleCharacteristicMetadata(
                    uuid: "ABCD",
                    supportsWrite: true,
                    supportsWriteWithoutResponse: false,
                    supportsNotify: false,
                    supportsIndicate: false
                )]
            )]
        )
        invalid.loadView()
        XCTAssertFalse(invalid.confirmButtonIsEnabledForTesting)

        let valid = BLEConsoleCharacteristicMapperViewController(
            deviceName: "Unknown",
            services: [customService()]
        )
        valid.loadView()
        XCTAssertTrue(valid.confirmButtonIsEnabledForTesting)
        XCTAssertEqual(valid.selectedProfileForTesting?.profileId, "custom-v1")
        XCTAssertEqual(valid.selectedProfileForTesting?.serviceUuid, normalized("1234"))
        XCTAssertEqual(valid.selectedProfileForTesting?.txCharacteristicUuid, normalized("ABCD"))
        XCTAssertEqual(valid.selectedProfileForTesting?.rxCharacteristicUuid, normalized("DCBA"))
        XCTAssertEqual(valid.selectedProfileForTesting?.writeType, "without_response")
    }

    private func scannerDevice(name: String, rssi: Int, services: [String]) -> BLEConsoleDiscoveredDevice {
        BLEConsoleDiscoveredDevice(
            identifier: UUID(),
            name: name,
            advertisedServiceUUIDs: services,
            rssi: BLEConsoleRSSI(rawValue: rssi),
            lastSeen: Date()
        )
    }

    private func splitService() -> ConsoleServiceMetadata {
        ConsoleServiceMetadata(
            uuid: "FFE1",
            characteristics: [
                ConsoleCharacteristicMetadata(
                    uuid: "FFE3",
                    supportsWrite: true,
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
                )
            ]
        )
    }

    private func customService() -> ConsoleServiceMetadata {
        ConsoleServiceMetadata(
            uuid: "1234",
            characteristics: [
                ConsoleCharacteristicMetadata(
                    uuid: "ABCD",
                    supportsWrite: false,
                    supportsWriteWithoutResponse: true,
                    supportsNotify: false,
                    supportsIndicate: false
                ),
                ConsoleCharacteristicMetadata(
                    uuid: "DCBA",
                    supportsWrite: false,
                    supportsWriteWithoutResponse: false,
                    supportsNotify: false,
                    supportsIndicate: true
                )
            ]
        )
    }

    private func normalized(_ value: String) -> String {
        BLEConsoleCharacteristicMapperViewController.normalizeUUID(value)!
    }
}

private final class RecordingScannerDriver: BLEConsoleCentralDriving, @unchecked Sendable {
    struct ConnectCall: Equatable {
        let identifier: UUID
        let generation: UInt64
    }

    var eventHandler: (@Sendable (BLEConsoleCentralEvent) -> Void)?
    private(set) var startScanCount = 0
    private(set) var stopScanCount = 0
    private(set) var connectCalls: [ConnectCall] = []
    private(set) var disconnectCalls: [ConnectCall] = []

    func startScan() { startScanCount += 1 }
    func stopScan() { stopScanCount += 1 }

    func connect(identifier: UUID, generation: UInt64) {
        connectCalls.append(ConnectCall(identifier: identifier, generation: generation))
    }

    func discoverProfile(identifier: UUID, generation: UInt64) {}
    func subscribe(identifier: UUID, characteristicUUID: String, generation: UInt64) {}
    func maximumWriteLength(identifier: UUID, withoutResponse: Bool) -> Int { 185 }
    func canSendWriteWithoutResponse(identifier: UUID) -> Bool { true }
    func write(identifier: UUID, characteristicUUID: String, data: Data, withoutResponse: Bool, generation: UInt64) {}

    func disconnect(identifier: UUID, generation: UInt64) {
        disconnectCalls.append(ConnectCall(identifier: identifier, generation: generation))
    }
}
