import Foundation
import XCTest
@testable import StacioApp

final class BLEConsoleModelsTests: XCTestCase {
    func testRecognizesOnlyExactOrStablySuffixedNBEEBLE1103Names() {
        XCTAssertEqual(BLEConsoleRecognition(deviceName: "NBEE_BLE_1103"), .nbee1103)
        XCTAssertEqual(BLEConsoleRecognition(deviceName: " nbee_ble_1103-fw1 "), .nbee1103)
        XCTAssertEqual(BLEConsoleRecognition(deviceName: "NBEE_BLE_1103_REV2"), .nbee1103)
        XCTAssertEqual(BLEConsoleRecognition(deviceName: "NBEE_BLE_11030"), .ordinary)
        XCTAssertEqual(BLEConsoleRecognition(deviceName: "NBEE_SPP_1103"), .ordinary)
        XCTAssertEqual(BLEConsoleRecognition(deviceName: nil), .ordinary)
    }

    func testRSSI127IsUnavailableAndUsesStableDisplayText() {
        XCTAssertNil(BLEConsoleRSSI(rawValue: 127).decibels)
        XCTAssertEqual(BLEConsoleRSSI(rawValue: 127).displayText, "-- dBm")
        XCTAssertEqual(BLEConsoleRSSI(rawValue: -54).decibels, -54)
        XCTAssertEqual(BLEConsoleRSSI(rawValue: -54).displayText, "-54 dBm")
    }

    func testDeviceDisplayNameAndProbableConsoleDetectionUseAdvertisementMetadata() {
        let unnamed = device(index: 1, name: "   ", services: ["180F"], rssi: -20)
        let shortUUID = device(index: 2, name: "UART", services: ["FFE0"], rssi: -60)
        let fullUUID = device(
            index: 3,
            name: "UART 2",
            services: ["0000ffe1-0000-1000-8000-00805f9b34fb"],
            rssi: -70
        )

        XCTAssertEqual(unnamed.displayName, L10n.BLEConsole.unnamedDevice)
        XCTAssertFalse(unnamed.isProbableConsole)
        XCTAssertTrue(shortUUID.isProbableConsole)
        XCTAssertTrue(fullUUID.isProbableConsole)
    }

    func testOrderingPinsNBEEThenProbableConsoleBeforeOtherDevices() {
        let otherStrong = device(index: 1, name: "Headphones", services: [], rssi: -20)
        let probable = device(index: 2, name: "UART", services: ["FFE0"], rssi: -65)
        let nbeeWeak = device(index: 3, name: "NBEE_BLE_1103", services: [], rssi: -95)

        XCTAssertEqual(
            BLEConsoleDeviceOrdering.sorted([otherStrong, probable, nbeeWeak]).map(\.identifier),
            [nbeeWeak.identifier, probable.identifier, otherStrong.identifier]
        )
    }

    func testOrderingUsesValidRSSIThenNameAndIdentifierWithinAGroup() {
        let invalid = device(index: 4, name: "A", services: [], rssi: 127)
        let weak = device(index: 3, name: "Z", services: [], rssi: -80)
        let alpha = device(index: 2, name: "alpha", services: [], rssi: -40)
        let beta = device(index: 1, name: "Beta", services: [], rssi: -40)

        XCTAssertEqual(
            BLEConsoleDeviceOrdering.sorted([invalid, weak, beta, alpha]).map(\.identifier),
            [alpha.identifier, beta.identifier, weak.identifier, invalid.identifier]
        )
    }

    func testSnapshotThrottlesRSSIReorderingAndPreservesSelectionByIdentifier() {
        let start = Date(timeIntervalSince1970: 1_000)
        let first = device(index: 1, name: "First", services: [], rssi: -30, lastSeen: start)
        let selected = device(index: 2, name: "Selected", services: [], rssi: -80, lastSeen: start)
        let initial = BLEConsoleDiscoverySnapshot(
            devices: [selected, first],
            selectedIdentifier: selected.identifier,
            generatedAt: start
        )
        XCTAssertEqual(initial.devices.map(\.identifier), [first.identifier, selected.identifier])

        let updatedFirst = device(
            index: 1,
            name: "First",
            services: [],
            rssi: -95,
            lastSeen: start.addingTimeInterval(0.2)
        )
        let updatedSelected = device(
            index: 2,
            name: "Selected",
            services: [],
            rssi: -20,
            lastSeen: start.addingTimeInterval(0.2)
        )
        let throttled = initial.replacing(
            devices: [updatedSelected, updatedFirst],
            at: start.addingTimeInterval(0.2)
        )

        XCTAssertEqual(throttled.devices.map(\.identifier), [first.identifier, selected.identifier])
        XCTAssertEqual(throttled.selectedIdentifier, selected.identifier)
        XCTAssertEqual(throttled.devices[1].rssi.decibels, -20)

        let reordered = throttled.replacing(
            devices: [updatedSelected, updatedFirst],
            at: start.addingTimeInterval(0.6)
        )
        XCTAssertEqual(reordered.devices.map(\.identifier), [selected.identifier, first.identifier])
        XCTAssertEqual(reordered.selectedIdentifier, selected.identifier)
    }

    func testSnapshotDeduplicatesLatestAdvertisementAndEvictsStaleDevices() {
        let start = Date(timeIntervalSince1970: 2_000)
        let duplicateOld = device(index: 1, name: "Old", services: [], rssi: -90, lastSeen: start)
        let duplicateLatest = device(
            index: 1,
            name: "Latest",
            services: ["FFE1"],
            rssi: -45,
            lastSeen: start.addingTimeInterval(1)
        )
        let fresh = device(
            index: 2,
            name: "Fresh",
            services: [],
            rssi: -60,
            lastSeen: start.addingTimeInterval(10.5)
        )
        let initial = BLEConsoleDiscoverySnapshot(
            devices: [duplicateOld, duplicateLatest],
            selectedIdentifier: duplicateOld.identifier,
            generatedAt: start.addingTimeInterval(1)
        )

        XCTAssertEqual(initial.devices.count, 1)
        XCTAssertEqual(initial.devices[0].displayName, "Latest")

        let evicted = initial.replacing(
            devices: [duplicateLatest, fresh],
            at: start.addingTimeInterval(11.1)
        )
        XCTAssertEqual(evicted.devices.map(\.identifier), [fresh.identifier])
        XCTAssertNil(evicted.selectedIdentifier)
    }

    func testFrozenErrorCodesExposeNonemptyLocalizedMetadata() {
        XCTAssertEqual(BLEConsoleErrorCode.allCases.count, 17)
        XCTAssertEqual(
            BLEConsoleErrorCode.permissionDenied.rawValue,
            "BLE_CONSOLE_PERMISSION_DENIED"
        )
        XCTAssertEqual(
            BLEConsoleErrorCode.sppFallbackFailed.rawValue,
            "CONSOLE_SPP_FALLBACK_FAILED"
        )

        for code in BLEConsoleErrorCode.allCases {
            XCTAssertFalse(code.title.isEmpty, code.rawValue)
            XCTAssertFalse(code.message.isEmpty, code.rawValue)
            XCTAssertFalse(code.recovery.isEmpty, code.rawValue)
            XCTAssertEqual(code.diagnosticCode, code.rawValue)
        }
    }

    private func device(
        index: Int,
        name: String?,
        services: [String],
        rssi: Int,
        lastSeen: Date = Date(timeIntervalSince1970: 1_000)
    ) -> BLEConsoleDiscoveredDevice {
        BLEConsoleDiscoveredDevice(
            identifier: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!,
            name: name,
            advertisedServiceUUIDs: services,
            rssi: BLEConsoleRSSI(rawValue: rssi),
            lastSeen: lastSeen
        )
    }
}
