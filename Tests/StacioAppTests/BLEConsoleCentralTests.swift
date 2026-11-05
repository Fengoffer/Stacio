import CoreBluetooth
import Foundation
import StacioCoreBindings
import XCTest
@testable import StacioApp

final class BLEConsoleCentralTests: XCTestCase {
    func testMapsCoreBluetoothManagerStatesToStableConsoleStates() {
        XCTAssertEqual(BLEConsoleCentralState(coreBluetoothState: .unknown), .unknown)
        XCTAssertEqual(BLEConsoleCentralState(coreBluetoothState: .resetting), .resetting)
        XCTAssertEqual(BLEConsoleCentralState(coreBluetoothState: .unsupported), .unsupported)
        XCTAssertEqual(BLEConsoleCentralState(coreBluetoothState: .unauthorized), .unauthorized)
        XCTAssertEqual(BLEConsoleCentralState(coreBluetoothState: .poweredOff), .poweredOff)
        XCTAssertEqual(BLEConsoleCentralState(coreBluetoothState: .poweredOn), .poweredOn)
    }

    func testStartScanUsesNoServiceFilterAllowsDuplicatesAndSchedulesTenSecondTimeout() {
        let controller = RecordingCoreBluetoothController()
        let scheduler = RecordingBLEConsoleScheduler()
        let driver = CoreBluetoothBLEConsoleCentralDriver(
            controller: controller,
            scheduler: scheduler,
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        driver.startScan()

        XCTAssertEqual(controller.scanRequests.count, 1)
        XCTAssertNil(controller.scanRequests[0].serviceUUIDs)
        XCTAssertTrue(controller.scanRequests[0].allowDuplicates)
        XCTAssertEqual(scheduler.delays, [10])
    }

    func testActiveScanRestartsOnceWhenBluetoothFirstBecomesPoweredOn() {
        let controller = RecordingCoreBluetoothController()
        let driver = CoreBluetoothBLEConsoleCentralDriver(
            controller: controller,
            scheduler: RecordingBLEConsoleScheduler(),
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        controller.emit(.event(.stateChanged(.unknown)))
        driver.startScan()
        XCTAssertEqual(controller.scanRequests.count, 1)

        controller.emit(.event(.stateChanged(.poweredOn)))
        XCTAssertEqual(controller.scanRequests.count, 2)

        controller.emit(.event(.stateChanged(.poweredOn)))
        XCTAssertEqual(controller.scanRequests.count, 2)
    }

    func testStopAndRescanCancelAndReplaceTheActiveTimeout() {
        let controller = RecordingCoreBluetoothController()
        let scheduler = RecordingBLEConsoleScheduler()
        let driver = CoreBluetoothBLEConsoleCentralDriver(
            controller: controller,
            scheduler: scheduler,
            now: { Date() }
        )

        driver.startScan()
        let firstTimeout = scheduler.actions[0]
        driver.startScan()

        XCTAssertTrue(firstTimeout.isCancelled)
        XCTAssertEqual(controller.stopScanCount, 1)
        XCTAssertEqual(scheduler.actions.count, 2)

        let replacementTimeout = scheduler.actions[1]
        driver.stopScan()
        XCTAssertTrue(replacementTimeout.isCancelled)
        XCTAssertEqual(controller.stopScanCount, 2)
    }

    func testAdvertisementsCoalesceByIdentifierAndUseLatestNameAndRSSI() throws {
        let controller = RecordingCoreBluetoothController()
        let scheduler = RecordingBLEConsoleScheduler()
        let clock = BLEConsoleTestClock(now: Date(timeIntervalSince1970: 2_000))
        let events = BLEConsoleEventRecorder()
        let driver = CoreBluetoothBLEConsoleCentralDriver(
            controller: controller,
            scheduler: scheduler,
            now: { clock.now }
        )
        driver.eventHandler = { events.append($0) }
        let identifier = UUID()

        driver.startScan()
        controller.emit(.advertisement(BLEConsoleDiscoveredDevice(
            identifier: identifier,
            name: "Old Name",
            advertisedServiceUUIDs: [],
            rssi: BLEConsoleRSSI(rawValue: -80),
            lastSeen: clock.now
        )))
        clock.now = clock.now.addingTimeInterval(0.1)
        controller.emit(.advertisement(BLEConsoleDiscoveredDevice(
            identifier: identifier,
            name: "NBEE_BLE_1103",
            advertisedServiceUUIDs: ["FFE1"],
            rssi: BLEConsoleRSSI(rawValue: -42),
            lastSeen: clock.now
        )))

        let snapshot = try XCTUnwrap(events.discoverySnapshots.last)
        XCTAssertEqual(snapshot.devices.count, 1)
        XCTAssertEqual(snapshot.devices[0].identifier, identifier)
        XCTAssertEqual(snapshot.devices[0].displayName, "NBEE_BLE_1103")
        XCTAssertEqual(snapshot.devices[0].rssi.decibels, -42)
    }

    func testScanTimeoutStopsScanningAndEvictsResultsOutsideActiveWindow() throws {
        let controller = RecordingCoreBluetoothController()
        let scheduler = RecordingBLEConsoleScheduler()
        let clock = BLEConsoleTestClock(now: Date(timeIntervalSince1970: 3_000))
        let events = BLEConsoleEventRecorder()
        let driver = CoreBluetoothBLEConsoleCentralDriver(
            controller: controller,
            scheduler: scheduler,
            now: { clock.now }
        )
        driver.eventHandler = { events.append($0) }

        driver.startScan()
        controller.emit(.advertisement(BLEConsoleDiscoveredDevice(
            identifier: UUID(),
            name: "Stale",
            advertisedServiceUUIDs: [],
            rssi: BLEConsoleRSSI(rawValue: -50),
            lastSeen: clock.now
        )))
        clock.now = clock.now.addingTimeInterval(10.1)
        scheduler.runNext()

        XCTAssertEqual(controller.stopScanCount, 1)
        let completion = try XCTUnwrap(events.scanCompletions.last)
        XCTAssertTrue(completion.timedOut)
        XCTAssertTrue(completion.snapshot.devices.isEmpty)
    }

    func testSavedBindingIsRetrievedBeforeConnectionAndMissingBindingKeepsGeneration() {
        let identifier = UUID()
        let controller = RecordingCoreBluetoothController()
        let scheduler = RecordingBLEConsoleScheduler()
        let events = BLEConsoleEventRecorder()
        let driver = CoreBluetoothBLEConsoleCentralDriver(
            controller: controller,
            scheduler: scheduler,
            now: { Date() }
        )
        driver.eventHandler = { events.append($0) }

        controller.retrieveResult = false
        driver.connect(identifier: identifier, generation: 41)
        XCTAssertEqual(controller.retrieveCalls, [identifier])
        XCTAssertTrue(controller.connectCalls.isEmpty)
        XCTAssertEqual(
            events.values.last,
            .connectionFailed(
                identifier: identifier,
                code: .deviceNotFound,
                diagnostic: nil,
                generation: 41
            )
        )

        controller.retrieveResult = true
        driver.connect(identifier: identifier, generation: 42)
        XCTAssertEqual(controller.connectCalls, [.init(identifier: identifier, generation: 42)])
    }

    func testConnectionOperationsAndCallbacksPreserveGeneration() {
        let identifier = UUID()
        let controller = RecordingCoreBluetoothController()
        let driver = CoreBluetoothBLEConsoleCentralDriver(
            controller: controller,
            scheduler: RecordingBLEConsoleScheduler(),
            now: { Date() }
        )
        let events = BLEConsoleEventRecorder()
        driver.eventHandler = { events.append($0) }
        controller.retrieveResult = true

        driver.connect(identifier: identifier, generation: 7)
        driver.discoverProfile(identifier: identifier, generation: 7)
        driver.subscribe(identifier: identifier, characteristicUUID: "FFE2", generation: 7)
        driver.write(
            identifier: identifier,
            characteristicUUID: "FFE3",
            data: Data([1, 2, 3]),
            withoutResponse: true,
            generation: 7
        )
        driver.disconnect(identifier: identifier, generation: 7)

        XCTAssertEqual(controller.discoverCalls, [.init(identifier: identifier, generation: 7)])
        XCTAssertEqual(controller.subscribeCalls.first?.generation, 7)
        XCTAssertEqual(controller.writeCalls.first?.generation, 7)
        XCTAssertEqual(controller.disconnectCalls, [.init(identifier: identifier, generation: 7)])

        controller.emit(.event(.connected(identifier: identifier, generation: 7)))
        controller.emit(.event(.readyToSendWithoutResponse(identifier: identifier, generation: 7)))
        XCTAssertEqual(events.values.suffix(2), [
            .connected(identifier: identifier, generation: 7),
            .readyToSendWithoutResponse(identifier: identifier, generation: 7),
        ])
    }

    func testCharacteristicPropertiesMapToCoreMetadataBooleans() {
        let metadata = CoreBluetoothBLEConsoleController.characteristicMetadata(
            uuid: CBUUID(string: "FFE3"),
            properties: [.write, .writeWithoutResponse, .notify]
        )

        XCTAssertEqual(metadata.uuid.uppercased(), "FFE3")
        XCTAssertTrue(metadata.supportsWrite)
        XCTAssertTrue(metadata.supportsWriteWithoutResponse)
        XCTAssertTrue(metadata.supportsNotify)
        XCTAssertFalse(metadata.supportsIndicate)
    }
}

private final class BLEConsoleTestClock: @unchecked Sendable {
    var now: Date

    init(now: Date) {
        self.now = now
    }
}

private final class BLEConsoleEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var values: [BLEConsoleCentralEvent] = []

    var discoverySnapshots: [BLEConsoleDiscoverySnapshot] {
        values.compactMap {
            guard case let .discoverySnapshot(snapshot) = $0 else { return nil }
            return snapshot
        }
    }

    var scanCompletions: [(snapshot: BLEConsoleDiscoverySnapshot, timedOut: Bool)] {
        values.compactMap {
            guard case let .scanCompleted(snapshot, timedOut) = $0 else { return nil }
            return (snapshot, timedOut)
        }
    }

    func append(_ event: BLEConsoleCentralEvent) {
        lock.lock()
        values.append(event)
        lock.unlock()
    }
}

private final class RecordingBLEConsoleScheduledAction: BLEConsoleScheduledAction, @unchecked Sendable {
    private let block: @Sendable () -> Void
    private(set) var isCancelled = false

    init(block: @escaping @Sendable () -> Void) {
        self.block = block
    }

    func cancel() {
        isCancelled = true
    }

    func run() {
        guard !isCancelled else { return }
        block()
    }
}

private final class RecordingBLEConsoleScheduler: BLEConsoleScheduling, @unchecked Sendable {
    private(set) var delays: [TimeInterval] = []
    private(set) var actions: [RecordingBLEConsoleScheduledAction] = []

    func schedule(
        after delay: TimeInterval,
        _ block: @escaping @Sendable () -> Void
    ) -> BLEConsoleScheduledAction {
        delays.append(delay)
        let action = RecordingBLEConsoleScheduledAction(block: block)
        actions.append(action)
        return action
    }

    func runNext() {
        actions.first(where: { !$0.isCancelled })?.run()
    }
}

private final class RecordingCoreBluetoothController: BLEConsoleCoreBluetoothControlling, @unchecked Sendable {
    struct ScanRequest {
        let serviceUUIDs: [String]?
        let allowDuplicates: Bool
    }

    struct GenerationCall: Equatable {
        let identifier: UUID
        let generation: UInt64
    }

    struct SubscribeCall {
        let identifier: UUID
        let characteristicUUID: String
        let generation: UInt64
    }

    struct WriteCall {
        let identifier: UUID
        let characteristicUUID: String
        let data: Data
        let withoutResponse: Bool
        let generation: UInt64
    }

    var eventHandler: (@Sendable (BLEConsoleCoreBluetoothEvent) -> Void)?
    var retrieveResult = true
    private(set) var scanRequests: [ScanRequest] = []
    private(set) var stopScanCount = 0
    private(set) var retrieveCalls: [UUID] = []
    private(set) var connectCalls: [GenerationCall] = []
    private(set) var discoverCalls: [GenerationCall] = []
    private(set) var subscribeCalls: [SubscribeCall] = []
    private(set) var writeCalls: [WriteCall] = []
    private(set) var disconnectCalls: [GenerationCall] = []

    func startScan(serviceUUIDs: [String]?, allowDuplicates: Bool) {
        scanRequests.append(.init(serviceUUIDs: serviceUUIDs, allowDuplicates: allowDuplicates))
    }

    func stopScan() {
        stopScanCount += 1
    }

    func retrieve(identifier: UUID) -> Bool {
        retrieveCalls.append(identifier)
        return retrieveResult
    }

    func connect(identifier: UUID, generation: UInt64) {
        connectCalls.append(.init(identifier: identifier, generation: generation))
    }

    func discoverProfile(identifier: UUID, generation: UInt64) {
        discoverCalls.append(.init(identifier: identifier, generation: generation))
    }

    func subscribe(identifier: UUID, characteristicUUID: String, generation: UInt64) {
        subscribeCalls.append(.init(
            identifier: identifier,
            characteristicUUID: characteristicUUID,
            generation: generation
        ))
    }

    func maximumWriteLength(identifier: UUID, withoutResponse: Bool) -> Int {
        185
    }

    func canSendWriteWithoutResponse(identifier: UUID) -> Bool {
        true
    }

    func write(
        identifier: UUID,
        characteristicUUID: String,
        data: Data,
        withoutResponse: Bool,
        generation: UInt64
    ) {
        writeCalls.append(.init(
            identifier: identifier,
            characteristicUUID: characteristicUUID,
            data: data,
            withoutResponse: withoutResponse,
            generation: generation
        ))
    }

    func disconnect(identifier: UUID, generation: UInt64) {
        disconnectCalls.append(.init(identifier: identifier, generation: generation))
    }

    func emit(_ event: BLEConsoleCoreBluetoothEvent) {
        eventHandler?(event)
    }
}
