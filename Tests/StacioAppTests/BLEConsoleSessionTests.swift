import Foundation
import StacioCoreBindings
import XCTest
@testable import StacioApp

@MainActor
final class BLEConsoleSessionTests: XCTestCase {
    func testConnectsOnlyAfterProfileDiscoveryAndRXSubscription() {
        let driver = RecordingBLEConsoleDriver()
        let session = makeSession(driver: driver)
        var states: [BLEConsoleSessionState] = []
        session.onStateChange = { states.append($0) }

        session.start()
        let generation = session.currentGeneration
        session.handle(.connected(identifier: driver.deviceID, generation: generation))
        session.handle(.servicesDiscovered(
            identifier: driver.deviceID,
            services: [splitService()],
            generation: generation
        ))

        XCTAssertEqual(session.state, .subscribing)
        XCTAssertEqual(driver.subscribeCalls.count, 1)
        session.handle(.subscribed(
            identifier: driver.deviceID,
            characteristicUUID: "FFE2",
            generation: generation
        ))

        XCTAssertEqual(session.state, .connected)
        XCTAssertEqual(states, [.connecting, .discovering, .subscribing, .connected])
    }

    func testSavedProfileWinsBeforeSplitAndSharedCatalogFallbacks() {
        let driver = RecordingBLEConsoleDriver()
        let config = consoleConfig(
            deviceID: driver.deviceID,
            profileID: "bterm-ffe0-shared-v1",
            serviceUUID: "FFE0",
            txUUID: "FFE1",
            rxUUID: "FFE1",
            writeType: "without_response"
        )
        let session = makeSession(config: config, driver: driver)

        session.start()
        let generation = session.currentGeneration
        session.handle(.connected(identifier: driver.deviceID, generation: generation))
        session.handle(.servicesDiscovered(
            identifier: driver.deviceID,
            services: [splitService(), sharedService()],
            generation: generation
        ))

        XCTAssertEqual(session.resolvedProfile?.profileId, "bterm-ffe0-shared-v1")
        XCTAssertEqual(driver.subscribeCalls.last?.characteristicUUID.uppercased(), "FFE1")
    }

    func testFallsBackToSplitThenSharedAndRequestsMapperWhenNoneMatch() {
        let splitDriver = RecordingBLEConsoleDriver()
        let splitSession = makeSession(
            config: consoleConfig(
                deviceID: splitDriver.deviceID,
                profileID: "custom-v1",
                serviceUUID: "AB00",
                txUUID: "AB01",
                rxUUID: "AB02",
                writeType: "with_response"
            ),
            driver: splitDriver
        )
        connectThroughServices(splitSession, driver: splitDriver, services: [sharedService(), splitService()])
        XCTAssertEqual(splitSession.resolvedProfile?.profileId, "bterm-ffe1-split-v1")

        let sharedDriver = RecordingBLEConsoleDriver()
        let sharedSession = makeSession(driver: sharedDriver)
        connectThroughServices(sharedSession, driver: sharedDriver, services: [sharedService()])
        XCTAssertEqual(sharedSession.resolvedProfile?.profileId, "bterm-ffe0-shared-v1")

        let mapperDriver = RecordingBLEConsoleDriver()
        let mapperSession = makeSession(driver: mapperDriver)
        var mapperServices: [ConsoleServiceMetadata] = []
        mapperSession.onProfileMapperRequest = { mapperServices = $0 }
        let unknown = ConsoleServiceMetadata(
            uuid: "AB00",
            characteristics: [characteristic("AB01", write: true)]
        )
        connectThroughServices(mapperSession, driver: mapperDriver, services: [unknown])
        XCTAssertEqual(mapperSession.state, .failed(code: .profileChanged))
        XCTAssertEqual(mapperServices, [unknown])
    }

    func testWithoutResponseUsesRuntimeMaximumAndPreservesByteOrder() throws {
        for count in [1, 20, 21, 185, 4_096] {
            let driver = RecordingBLEConsoleDriver()
            driver.maximumLength = 20
            let session = makeSession(driver: driver)
            connectSession(session, driver: driver)
            let bytes = (0..<count).map { UInt8($0 % 251) }

            try session.enqueueWrite(bytes)

            XCTAssertEqual(driver.writes.flatMap { Array($0.data) }, bytes, "count \(count)")
            XCTAssertTrue(driver.writes.allSatisfy { $0.data.count <= 20 })
            XCTAssertEqual(session.queuedByteCount, 0)
        }
    }

    func testWithoutResponsePausesUntilDriverSignalsReady() throws {
        let driver = RecordingBLEConsoleDriver()
        driver.maximumLength = 20
        driver.canSendWithoutResponse = false
        let session = makeSession(driver: driver)
        connectSession(session, driver: driver)
        let bytes: [UInt8] = (0..<21).map { UInt8($0) }

        try session.enqueueWrite(bytes)
        XCTAssertTrue(driver.writes.isEmpty)
        XCTAssertEqual(session.queuedByteCount, 21)

        driver.canSendWithoutResponse = true
        session.handle(.readyToSendWithoutResponse(
            identifier: driver.deviceID,
            generation: session.currentGeneration
        ))
        XCTAssertEqual(driver.writes.map(\.data.count), [20, 1])
        XCTAssertEqual(driver.writes.flatMap { Array($0.data) }, bytes)
    }

    func testWithResponseWaitsForMatchingAcknowledgementBeforeNextChunk() throws {
        let driver = RecordingBLEConsoleDriver()
        driver.maximumLength = 20
        let config = consoleConfig(
            deviceID: driver.deviceID,
            profileID: "custom-v1",
            serviceUUID: "AB00",
            txUUID: "AB01",
            rxUUID: "AB02",
            writeType: "with_response"
        )
        let session = makeSession(config: config, driver: driver)
        connectSession(session, driver: driver, services: [customService(writeWithoutResponse: false)])
        let bytes: [UInt8] = (0..<21).map { UInt8($0) }

        try session.enqueueWrite(bytes)
        XCTAssertEqual(driver.writes.map(\.data.count), [20])
        XCTAssertEqual(session.queuedByteCount, 21)

        session.handle(.writeAcknowledged(
            identifier: driver.deviceID,
            characteristicUUID: "FFFF",
            generation: session.currentGeneration
        ))
        XCTAssertEqual(driver.writes.map(\.data.count), [20])

        session.handle(.writeAcknowledged(
            identifier: driver.deviceID,
            characteristicUUID: "AB01",
            generation: session.currentGeneration
        ))
        XCTAssertEqual(driver.writes.map(\.data.count), [20, 1])
        XCTAssertEqual(session.queuedByteCount, 1)

        session.handle(.writeAcknowledged(
            identifier: driver.deviceID,
            characteristicUUID: "AB01",
            generation: session.currentGeneration
        ))
        XCTAssertEqual(session.queuedByteCount, 0)
        XCTAssertEqual(driver.writes.flatMap { Array($0.data) }, bytes)
    }

    func testQueueOverflowRejectsWholeWriteWithoutTruncatingAcceptedBytes() throws {
        let driver = RecordingBLEConsoleDriver()
        driver.canSendWithoutResponse = false
        let session = makeSession(driver: driver)
        connectSession(session, driver: driver)
        let accepted = [UInt8](repeating: 0x41, count: 256 * 1_024)

        try session.enqueueWrite(accepted)
        XCTAssertThrowsError(try session.enqueueWrite([0x42])) { error in
            XCTAssertEqual(error as? BLEConsoleErrorCode, .txQueueFull)
        }
        XCTAssertEqual(session.queuedByteCount, accepted.count)
        XCTAssertTrue(driver.writes.isEmpty)
    }

    func testRXDataIsDeliveredUnchangedAsOneBatch() {
        let driver = RecordingBLEConsoleDriver()
        let session = makeSession(driver: driver)
        connectSession(session, driver: driver)
        var batches: [[UInt8]] = []
        session.onReceiveBytes = { batches.append($0) }
        let bytes: [UInt8] = [0x00, 0xFF, 0x0D, 0x0A, 0x80]

        session.handle(.rxData(
            identifier: driver.deviceID,
            characteristicUUID: "FFE2",
            data: Data(bytes),
            generation: session.currentGeneration
        ))

        XCTAssertEqual(batches, [bytes])
        XCTAssertEqual(session.bytesReceived, UInt64(bytes.count))
    }

    func testStaleGenerationCallbacksAreIgnored() {
        let driver = RecordingBLEConsoleDriver()
        let session = makeSession(driver: driver)
        session.start()
        let current = session.currentGeneration

        session.handle(.connected(identifier: driver.deviceID, generation: current - 1))
        session.handle(.disconnected(identifier: driver.deviceID, error: nil, generation: current - 1))

        XCTAssertEqual(session.state, .connecting)
        XCTAssertTrue(driver.discoverCalls.isEmpty)
    }

    func testUnexpectedDisconnectRetriesOnlyAfterOneTwoAndFourSeconds() async {
        let driver = RecordingBLEConsoleDriver()
        let scheduler = RecordingBLESessionScheduler()
        let session = makeSession(driver: driver, scheduler: scheduler)
        session.start()

        session.handle(.disconnected(
            identifier: driver.deviceID,
            error: nil,
            generation: session.currentGeneration
        ))
        XCTAssertEqual(scheduler.delays, [1])
        scheduler.runNext()
        await settleMainActor()

        session.handle(.connectionFailed(
            identifier: driver.deviceID,
            code: .connectFailed,
            diagnostic: nil,
            generation: session.currentGeneration
        ))
        XCTAssertEqual(scheduler.delays, [1, 2])
        scheduler.runNext()
        await settleMainActor()

        session.handle(.connectionFailed(
            identifier: driver.deviceID,
            code: .connectFailed,
            diagnostic: nil,
            generation: session.currentGeneration
        ))
        XCTAssertEqual(scheduler.delays, [1, 2, 4])
        scheduler.runNext()
        await settleMainActor()

        session.handle(.connectionFailed(
            identifier: driver.deviceID,
            code: .connectFailed,
            diagnostic: nil,
            generation: session.currentGeneration
        ))
        XCTAssertEqual(scheduler.delays, [1, 2, 4])
        XCTAssertEqual(session.state, .failed(code: .connectFailed))
        XCTAssertEqual(driver.connectCalls.count, 4)
    }

    func testCloseCancelsQueuedReconnectAndIsIdempotent() async throws {
        let driver = RecordingBLEConsoleDriver()
        driver.canSendWithoutResponse = false
        let scheduler = RecordingBLESessionScheduler()
        let session = makeSession(driver: driver, scheduler: scheduler)
        session.start()
        try session.enqueueWrite([1, 2, 3])
        session.handle(.disconnected(
            identifier: driver.deviceID,
            error: nil,
            generation: session.currentGeneration
        ))
        XCTAssertEqual(scheduler.delays, [1])

        session.close()
        session.close()
        scheduler.runAll()
        await settleMainActor()

        XCTAssertEqual(session.state, .closed)
        XCTAssertEqual(session.queuedByteCount, 0)
        XCTAssertEqual(driver.connectCalls.count, 1)
        XCTAssertEqual(driver.disconnectCalls.count, 1)
        XCTAssertNil(driver.eventHandler)
    }

    private func makeSession(
        config: ConsoleSessionConfig? = nil,
        driver: RecordingBLEConsoleDriver,
        scheduler: BLEConsoleScheduling = RecordingBLESessionScheduler()
    ) -> BLEConsoleSession {
        BLEConsoleSession(
            config: config ?? consoleConfig(deviceID: driver.deviceID),
            driver: driver,
            scheduler: scheduler
        )
    }

    private func connectThroughServices(
        _ session: BLEConsoleSession,
        driver: RecordingBLEConsoleDriver,
        services: [ConsoleServiceMetadata]
    ) {
        session.start()
        let generation = session.currentGeneration
        session.handle(.connected(identifier: driver.deviceID, generation: generation))
        session.handle(.servicesDiscovered(
            identifier: driver.deviceID,
            services: services,
            generation: generation
        ))
    }

    private func connectSession(
        _ session: BLEConsoleSession,
        driver: RecordingBLEConsoleDriver,
        services: [ConsoleServiceMetadata]? = nil
    ) {
        connectThroughServices(
            session,
            driver: driver,
            services: services ?? [splitService()]
        )
        let profile = session.resolvedProfile!
        session.handle(.subscribed(
            identifier: driver.deviceID,
            characteristicUUID: profile.rxCharacteristicUuid,
            generation: session.currentGeneration
        ))
        XCTAssertEqual(session.state, .connected)
    }

    private func settleMainActor() async {
        await Task.yield()
        await Task.yield()
    }
}

private func consoleConfig(
    deviceID: UUID,
    profileID: String = "bterm-ffe1-split-v1",
    serviceUUID: String = "FFE1",
    txUUID: String = "FFE3",
    rxUUID: String = "FFE2",
    writeType: String = "without_response"
) -> ConsoleSessionConfig {
    ConsoleSessionConfig(
        kind: "console",
        schemaVersion: 1,
        transportPolicy: "prefer_ble",
        ble: ConsoleBleConfig(
            deviceName: "NBEE_BLE_1103",
            profileId: profileID,
            serviceUuid: serviceUUID,
            txCharacteristicUuid: txUUID,
            rxCharacteristicUuid: rxUUID,
            writeType: writeType,
            platformBindings: ConsolePlatformBindings(
                macOsPeripheralUuid: deviceID.uuidString,
                windowsDeviceId: nil
            )
        ),
        sppFallback: nil
    )
}

private func splitService() -> ConsoleServiceMetadata {
    ConsoleServiceMetadata(
        uuid: "FFE1",
        characteristics: [
            characteristic("FFE3", writeWithoutResponse: true),
            characteristic("FFE2", notify: true),
        ]
    )
}

private func sharedService() -> ConsoleServiceMetadata {
    ConsoleServiceMetadata(
        uuid: "FFE0",
        characteristics: [
            characteristic("FFE1", writeWithoutResponse: true, notify: true),
        ]
    )
}

private func customService(writeWithoutResponse: Bool) -> ConsoleServiceMetadata {
    ConsoleServiceMetadata(
        uuid: "AB00",
        characteristics: [
            characteristic(
                "AB01",
                write: !writeWithoutResponse,
                writeWithoutResponse: writeWithoutResponse
            ),
            characteristic("AB02", notify: true),
        ]
    )
}

private func characteristic(
    _ uuid: String,
    write: Bool = false,
    writeWithoutResponse: Bool = false,
    notify: Bool = false,
    indicate: Bool = false
) -> ConsoleCharacteristicMetadata {
    ConsoleCharacteristicMetadata(
        uuid: uuid,
        supportsWrite: write,
        supportsWriteWithoutResponse: writeWithoutResponse,
        supportsNotify: notify,
        supportsIndicate: indicate
    )
}

private final class RecordingBLEConsoleDriver: BLEConsoleCentralDriving, @unchecked Sendable {
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

    let deviceID = UUID()
    var eventHandler: (@Sendable (BLEConsoleCentralEvent) -> Void)?
    var maximumLength = 20
    var canSendWithoutResponse = true
    private(set) var connectCalls: [GenerationCall] = []
    private(set) var discoverCalls: [GenerationCall] = []
    private(set) var subscribeCalls: [SubscribeCall] = []
    private(set) var writes: [WriteCall] = []
    private(set) var disconnectCalls: [GenerationCall] = []

    func startScan() {}
    func stopScan() {}

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
        maximumLength
    }

    func canSendWriteWithoutResponse(identifier: UUID) -> Bool {
        canSendWithoutResponse
    }

    func write(
        identifier: UUID,
        characteristicUUID: String,
        data: Data,
        withoutResponse: Bool,
        generation: UInt64
    ) {
        writes.append(.init(
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
}

private final class RecordingBLESessionAction: BLEConsoleScheduledAction, @unchecked Sendable {
    let block: @Sendable () -> Void
    private(set) var isCancelled = false
    private(set) var hasRun = false

    init(block: @escaping @Sendable () -> Void) {
        self.block = block
    }

    func cancel() {
        isCancelled = true
    }

    func run() {
        guard !isCancelled, !hasRun else { return }
        hasRun = true
        block()
    }
}

private final class RecordingBLESessionScheduler: BLEConsoleScheduling, @unchecked Sendable {
    private(set) var delays: [TimeInterval] = []
    private(set) var actions: [RecordingBLESessionAction] = []

    func schedule(
        after delay: TimeInterval,
        _ block: @escaping @Sendable () -> Void
    ) -> BLEConsoleScheduledAction {
        delays.append(delay)
        let action = RecordingBLESessionAction(block: block)
        actions.append(action)
        return action
    }

    func runNext() {
        actions.first(where: { !$0.isCancelled && !$0.hasRun })?.run()
    }

    func runAll() {
        actions.forEach { $0.run() }
    }
}
