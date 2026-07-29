import CoreBluetooth
import Foundation
import StacioCoreBindings

enum BLEConsoleCentralState: Equatable, Sendable {
    case unknown
    case resetting
    case unsupported
    case unauthorized
    case poweredOff
    case poweredOn

    init(coreBluetoothState: CBManagerState) {
        switch coreBluetoothState {
        case .unknown: self = .unknown
        case .resetting: self = .resetting
        case .unsupported: self = .unsupported
        case .unauthorized: self = .unauthorized
        case .poweredOff: self = .poweredOff
        case .poweredOn: self = .poweredOn
        @unknown default: self = .unknown
        }
    }
}

enum BLEConsoleCentralEvent: Equatable, Sendable {
    case stateChanged(BLEConsoleCentralState)
    case discoverySnapshot(BLEConsoleDiscoverySnapshot)
    case scanCompleted(snapshot: BLEConsoleDiscoverySnapshot, timedOut: Bool)
    case connected(identifier: UUID, generation: UInt64)
    case connectionFailed(
        identifier: UUID,
        code: BLEConsoleErrorCode,
        diagnostic: String?,
        generation: UInt64
    )
    case disconnected(identifier: UUID, error: String?, generation: UInt64)
    case servicesDiscovered(
        identifier: UUID,
        services: [ConsoleServiceMetadata],
        generation: UInt64
    )
    case profileDiscoveryFailed(
        identifier: UUID,
        code: BLEConsoleErrorCode,
        diagnostic: String?,
        generation: UInt64
    )
    case subscribed(identifier: UUID, characteristicUUID: String, generation: UInt64)
    case subscriptionFailed(
        identifier: UUID,
        characteristicUUID: String,
        diagnostic: String?,
        generation: UInt64
    )
    case rxData(
        identifier: UUID,
        characteristicUUID: String,
        data: Data,
        generation: UInt64
    )
    case writeAcknowledged(identifier: UUID, characteristicUUID: String, generation: UInt64)
    case writeFailed(
        identifier: UUID,
        characteristicUUID: String,
        diagnostic: String?,
        generation: UInt64
    )
    case readyToSendWithoutResponse(identifier: UUID, generation: UInt64)
}

protocol BLEConsoleCentralDriving: AnyObject {
    var eventHandler: (@Sendable (BLEConsoleCentralEvent) -> Void)? { get set }
    func startScan()
    func stopScan()
    func connect(identifier: UUID, generation: UInt64)
    func discoverProfile(identifier: UUID, generation: UInt64)
    func subscribe(identifier: UUID, characteristicUUID: String, generation: UInt64)
    func maximumWriteLength(identifier: UUID, withoutResponse: Bool) -> Int
    func canSendWriteWithoutResponse(identifier: UUID) -> Bool
    func write(
        identifier: UUID,
        characteristicUUID: String,
        data: Data,
        withoutResponse: Bool,
        generation: UInt64
    )
    func disconnect(identifier: UUID, generation: UInt64)
}

protocol BLEConsoleScheduledAction: AnyObject {
    func cancel()
}

protocol BLEConsoleScheduling: AnyObject {
    func schedule(
        after delay: TimeInterval,
        _ block: @escaping @Sendable () -> Void
    ) -> BLEConsoleScheduledAction
}

final class DispatchBLEConsoleScheduler: BLEConsoleScheduling, @unchecked Sendable {
    private let queue: DispatchQueue

    init(queue: DispatchQueue = .main) {
        self.queue = queue
    }

    func schedule(
        after delay: TimeInterval,
        _ block: @escaping @Sendable () -> Void
    ) -> BLEConsoleScheduledAction {
        let item = DispatchWorkItem(block: block)
        queue.asyncAfter(deadline: .now() + delay, execute: item)
        return DispatchBLEConsoleScheduledAction(item: item)
    }
}

private final class DispatchBLEConsoleScheduledAction: BLEConsoleScheduledAction {
    private let item: DispatchWorkItem

    init(item: DispatchWorkItem) {
        self.item = item
    }

    func cancel() {
        item.cancel()
    }
}

enum BLEConsoleCoreBluetoothEvent: Sendable {
    case advertisement(BLEConsoleDiscoveredDevice)
    case event(BLEConsoleCentralEvent)
}

protocol BLEConsoleCoreBluetoothControlling: AnyObject {
    var eventHandler: (@Sendable (BLEConsoleCoreBluetoothEvent) -> Void)? { get set }
    func startScan(serviceUUIDs: [String]?, allowDuplicates: Bool)
    func stopScan()
    func retrieve(identifier: UUID) -> Bool
    func connect(identifier: UUID, generation: UInt64)
    func discoverProfile(identifier: UUID, generation: UInt64)
    func subscribe(identifier: UUID, characteristicUUID: String, generation: UInt64)
    func maximumWriteLength(identifier: UUID, withoutResponse: Bool) -> Int
    func canSendWriteWithoutResponse(identifier: UUID) -> Bool
    func write(
        identifier: UUID,
        characteristicUUID: String,
        data: Data,
        withoutResponse: Bool,
        generation: UInt64
    )
    func disconnect(identifier: UUID, generation: UInt64)
}

final class CoreBluetoothBLEConsoleCentralDriver: BLEConsoleCentralDriving, @unchecked Sendable {
    var eventHandler: (@Sendable (BLEConsoleCentralEvent) -> Void)?

    private let controller: BLEConsoleCoreBluetoothControlling
    private let scheduler: BLEConsoleScheduling
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var devicesByIdentifier: [UUID: BLEConsoleDiscoveredDevice] = [:]
    private var snapshot: BLEConsoleDiscoverySnapshot
    private var scanGeneration: UInt64 = 0
    private var activeScanGeneration: UInt64?
    private var scanTimeout: BLEConsoleScheduledAction?

    convenience init() {
        let queue = DispatchQueue(label: "app.stacio.ble-console.corebluetooth")
        self.init(
            controller: CoreBluetoothBLEConsoleController(queue: queue),
            scheduler: DispatchBLEConsoleScheduler(queue: queue),
            now: { Date() }
        )
    }

    init(
        controller: BLEConsoleCoreBluetoothControlling,
        scheduler: BLEConsoleScheduling,
        now: @escaping @Sendable () -> Date
    ) {
        self.controller = controller
        self.scheduler = scheduler
        self.now = now
        snapshot = BLEConsoleDiscoverySnapshot(devices: [], generatedAt: now())
        controller.eventHandler = { [weak self] event in
            self?.handle(event)
        }
    }

    func startScan() {
        let startedAt = now()
        let generation: UInt64
        let previousTimeout: BLEConsoleScheduledAction?
        let wasScanning: Bool

        lock.lock()
        previousTimeout = scanTimeout
        wasScanning = activeScanGeneration != nil
        scanGeneration &+= 1
        generation = scanGeneration
        activeScanGeneration = generation
        devicesByIdentifier = [:]
        snapshot = BLEConsoleDiscoverySnapshot(devices: [], generatedAt: startedAt)
        scanTimeout = nil
        lock.unlock()

        previousTimeout?.cancel()
        if wasScanning {
            controller.stopScan()
        }
        controller.startScan(serviceUUIDs: nil, allowDuplicates: true)

        let timeout = scheduler.schedule(after: 10) { [weak self] in
            self?.finishScan(generation: generation, timedOut: true)
        }
        lock.lock()
        if activeScanGeneration == generation {
            scanTimeout = timeout
        } else {
            timeout.cancel()
        }
        let initialSnapshot = snapshot
        lock.unlock()
        eventHandler?(.discoverySnapshot(initialSnapshot))
    }

    func stopScan() {
        lock.lock()
        let generation = activeScanGeneration
        lock.unlock()
        guard let generation else { return }
        finishScan(generation: generation, timedOut: false)
    }

    func connect(identifier: UUID, generation: UInt64) {
        guard controller.retrieve(identifier: identifier) else {
            eventHandler?(.connectionFailed(
                identifier: identifier,
                code: .deviceNotFound,
                diagnostic: nil,
                generation: generation
            ))
            return
        }
        controller.connect(identifier: identifier, generation: generation)
    }

    func discoverProfile(identifier: UUID, generation: UInt64) {
        controller.discoverProfile(identifier: identifier, generation: generation)
    }

    func subscribe(identifier: UUID, characteristicUUID: String, generation: UInt64) {
        controller.subscribe(
            identifier: identifier,
            characteristicUUID: characteristicUUID,
            generation: generation
        )
    }

    func maximumWriteLength(identifier: UUID, withoutResponse: Bool) -> Int {
        controller.maximumWriteLength(identifier: identifier, withoutResponse: withoutResponse)
    }

    func canSendWriteWithoutResponse(identifier: UUID) -> Bool {
        controller.canSendWriteWithoutResponse(identifier: identifier)
    }

    func write(
        identifier: UUID,
        characteristicUUID: String,
        data: Data,
        withoutResponse: Bool,
        generation: UInt64
    ) {
        controller.write(
            identifier: identifier,
            characteristicUUID: characteristicUUID,
            data: data,
            withoutResponse: withoutResponse,
            generation: generation
        )
    }

    func disconnect(identifier: UUID, generation: UInt64) {
        controller.disconnect(identifier: identifier, generation: generation)
    }

    private func handle(_ event: BLEConsoleCoreBluetoothEvent) {
        switch event {
        case let .advertisement(device):
            lock.lock()
            guard activeScanGeneration != nil else {
                lock.unlock()
                return
            }
            devicesByIdentifier[device.identifier] = device
            snapshot = snapshot.replacing(
                devices: Array(devicesByIdentifier.values),
                at: now()
            )
            let nextSnapshot = snapshot
            lock.unlock()
            eventHandler?(.discoverySnapshot(nextSnapshot))
        case let .event(event):
            eventHandler?(event)
        }
    }

    private func finishScan(generation: UInt64, timedOut: Bool) {
        let timeout: BLEConsoleScheduledAction?
        let finalSnapshot: BLEConsoleDiscoverySnapshot

        lock.lock()
        guard activeScanGeneration == generation else {
            lock.unlock()
            return
        }
        activeScanGeneration = nil
        timeout = scanTimeout
        scanTimeout = nil
        snapshot = snapshot.replacing(
            devices: Array(devicesByIdentifier.values),
            at: now()
        )
        devicesByIdentifier = Dictionary(
            uniqueKeysWithValues: snapshot.devices.map { ($0.identifier, $0) }
        )
        finalSnapshot = snapshot
        lock.unlock()

        timeout?.cancel()
        controller.stopScan()
        eventHandler?(.discoverySnapshot(finalSnapshot))
        eventHandler?(.scanCompleted(snapshot: finalSnapshot, timedOut: timedOut))
    }
}

final class CoreBluetoothBLEConsoleController: NSObject,
    BLEConsoleCoreBluetoothControlling,
    CBCentralManagerDelegate,
    CBPeripheralDelegate,
    @unchecked Sendable
{
    var eventHandler: (@Sendable (BLEConsoleCoreBluetoothEvent) -> Void)?

    private let queue: DispatchQueue
    private var manager: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var generations: [UUID: UInt64] = [:]
    private var characteristics: [UUID: [String: CBCharacteristic]] = [:]
    private var pendingServiceUUIDs: [UUID: Set<String>] = [:]

    init(queue: DispatchQueue) {
        self.queue = queue
        super.init()
        manager = CBCentralManager(delegate: self, queue: queue)
    }

    func startScan(serviceUUIDs: [String]?, allowDuplicates: Bool) {
        let services = serviceUUIDs?.map(CBUUID.init(string:))
        manager.scanForPeripherals(
            withServices: services,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: allowDuplicates]
        )
    }

    func stopScan() {
        manager.stopScan()
    }

    func retrieve(identifier: UUID) -> Bool {
        if peripherals[identifier] != nil {
            return true
        }
        guard let peripheral = manager
            .retrievePeripherals(withIdentifiers: [identifier])
            .first
        else {
            return false
        }
        register(peripheral)
        return true
    }

    func connect(identifier: UUID, generation: UInt64) {
        guard let peripheral = peripherals[identifier] else {
            emit(.connectionFailed(
                identifier: identifier,
                code: .deviceNotFound,
                diagnostic: nil,
                generation: generation
            ))
            return
        }
        generations[identifier] = generation
        manager.connect(peripheral)
    }

    func discoverProfile(identifier: UUID, generation: UInt64) {
        guard let peripheral = peripherals[identifier] else {
            emit(.profileDiscoveryFailed(
                identifier: identifier,
                code: .deviceNotFound,
                diagnostic: nil,
                generation: generation
            ))
            return
        }
        generations[identifier] = generation
        peripheral.discoverServices(nil)
    }

    func subscribe(identifier: UUID, characteristicUUID: String, generation: UInt64) {
        guard let peripheral = peripherals[identifier],
              let characteristic = characteristic(
                  identifier: identifier,
                  uuid: characteristicUUID
              )
        else {
            emit(.subscriptionFailed(
                identifier: identifier,
                characteristicUUID: characteristicUUID,
                diagnostic: BLEConsoleErrorCode.rxMissing.rawValue,
                generation: generation
            ))
            return
        }
        generations[identifier] = generation
        peripheral.setNotifyValue(true, for: characteristic)
    }

    func maximumWriteLength(identifier: UUID, withoutResponse: Bool) -> Int {
        guard let peripheral = peripherals[identifier] else { return 0 }
        return peripheral.maximumWriteValueLength(
            for: withoutResponse ? .withoutResponse : .withResponse
        )
    }

    func canSendWriteWithoutResponse(identifier: UUID) -> Bool {
        peripherals[identifier]?.canSendWriteWithoutResponse ?? false
    }

    func write(
        identifier: UUID,
        characteristicUUID: String,
        data: Data,
        withoutResponse: Bool,
        generation: UInt64
    ) {
        guard let peripheral = peripherals[identifier],
              let characteristic = characteristic(
                  identifier: identifier,
                  uuid: characteristicUUID
              )
        else {
            emit(.writeFailed(
                identifier: identifier,
                characteristicUUID: characteristicUUID,
                diagnostic: BLEConsoleErrorCode.txMissing.rawValue,
                generation: generation
            ))
            return
        }
        generations[identifier] = generation
        peripheral.writeValue(
            data,
            for: characteristic,
            type: withoutResponse ? .withoutResponse : .withResponse
        )
    }

    func disconnect(identifier: UUID, generation: UInt64) {
        guard let peripheral = peripherals[identifier] else {
            emit(.disconnected(identifier: identifier, error: nil, generation: generation))
            return
        }
        generations[identifier] = generation
        manager.cancelPeripheralConnection(peripheral)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        emit(.stateChanged(BLEConsoleCentralState(coreBluetoothState: central.state)))
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        register(peripheral)
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let serviceUUIDs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?
            .map(\.uuidString) ?? []
        eventHandler?(.advertisement(BLEConsoleDiscoveredDevice(
            identifier: peripheral.identifier,
            name: advertisedName ?? peripheral.name,
            advertisedServiceUUIDs: serviceUUIDs,
            rssi: BLEConsoleRSSI(rawValue: RSSI.intValue),
            lastSeen: Date()
        )))
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        emit(.connected(
            identifier: peripheral.identifier,
            generation: generation(for: peripheral)
        ))
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        emit(.connectionFailed(
            identifier: peripheral.identifier,
            code: .connectFailed,
            diagnostic: error?.localizedDescription,
            generation: generation(for: peripheral)
        ))
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        emit(.disconnected(
            identifier: peripheral.identifier,
            error: error?.localizedDescription,
            generation: generation(for: peripheral)
        ))
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let identifier = peripheral.identifier
        let generation = generation(for: peripheral)
        if let error {
            emit(.profileDiscoveryFailed(
                identifier: identifier,
                code: .serviceMissing,
                diagnostic: error.localizedDescription,
                generation: generation
            ))
            return
        }

        let services = peripheral.services ?? []
        guard !services.isEmpty else {
            emit(.servicesDiscovered(identifier: identifier, services: [], generation: generation))
            return
        }
        pendingServiceUUIDs[identifier] = Set(services.map { $0.uuid.uuidString })
        characteristics[identifier] = [:]
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        let identifier = peripheral.identifier
        let generation = generation(for: peripheral)
        if let error {
            pendingServiceUUIDs[identifier] = nil
            emit(.profileDiscoveryFailed(
                identifier: identifier,
                code: .serviceMissing,
                diagnostic: error.localizedDescription,
                generation: generation
            ))
            return
        }

        for characteristic in service.characteristics ?? [] {
            characteristics[identifier, default: [:]][characteristic.uuid.uuidString] = characteristic
        }
        pendingServiceUUIDs[identifier]?.remove(service.uuid.uuidString)
        guard pendingServiceUUIDs[identifier]?.isEmpty == true else { return }
        pendingServiceUUIDs[identifier] = nil

        let metadata = (peripheral.services ?? []).map { service in
            ConsoleServiceMetadata(
                uuid: service.uuid.uuidString,
                characteristics: (service.characteristics ?? []).map {
                    Self.characteristicMetadata(uuid: $0.uuid, properties: $0.properties)
                }
            )
        }
        emit(.servicesDiscovered(
            identifier: identifier,
            services: metadata,
            generation: generation
        ))
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        let generation = generation(for: peripheral)
        if let error {
            emit(.subscriptionFailed(
                identifier: peripheral.identifier,
                characteristicUUID: characteristic.uuid.uuidString,
                diagnostic: error.localizedDescription,
                generation: generation
            ))
        } else if characteristic.isNotifying {
            emit(.subscribed(
                identifier: peripheral.identifier,
                characteristicUUID: characteristic.uuid.uuidString,
                generation: generation
            ))
        } else {
            emit(.subscriptionFailed(
                identifier: peripheral.identifier,
                characteristicUUID: characteristic.uuid.uuidString,
                diagnostic: BLEConsoleErrorCode.subscribeFailed.rawValue,
                generation: generation
            ))
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil, let data = characteristic.value else { return }
        emit(.rxData(
            identifier: peripheral.identifier,
            characteristicUUID: characteristic.uuid.uuidString,
            data: data,
            generation: generation(for: peripheral)
        ))
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        let generation = generation(for: peripheral)
        if let error {
            emit(.writeFailed(
                identifier: peripheral.identifier,
                characteristicUUID: characteristic.uuid.uuidString,
                diagnostic: error.localizedDescription,
                generation: generation
            ))
        } else {
            emit(.writeAcknowledged(
                identifier: peripheral.identifier,
                characteristicUUID: characteristic.uuid.uuidString,
                generation: generation
            ))
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        emit(.readyToSendWithoutResponse(
            identifier: peripheral.identifier,
            generation: generation(for: peripheral)
        ))
    }

    static func characteristicMetadata(
        uuid: CBUUID,
        properties: CBCharacteristicProperties
    ) -> ConsoleCharacteristicMetadata {
        ConsoleCharacteristicMetadata(
            uuid: uuid.uuidString,
            supportsWrite: properties.contains(.write),
            supportsWriteWithoutResponse: properties.contains(.writeWithoutResponse),
            supportsNotify: properties.contains(.notify),
            supportsIndicate: properties.contains(.indicate)
        )
    }

    private func register(_ peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripherals[peripheral.identifier] = peripheral
    }

    private func characteristic(identifier: UUID, uuid: String) -> CBCharacteristic? {
        let target = CBUUID(string: uuid)
        return characteristics[identifier]?.values.first { $0.uuid == target }
    }

    private func generation(for peripheral: CBPeripheral) -> UInt64 {
        generations[peripheral.identifier] ?? 0
    }

    private func emit(_ event: BLEConsoleCentralEvent) {
        eventHandler?(.event(event))
    }
}
