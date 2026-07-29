import Foundation
import StacioCoreBindings

enum BLEConsoleSessionState: Equatable, Sendable {
    case idle
    case connecting
    case discovering
    case subscribing
    case connected
    case reconnecting(attempt: Int)
    case failed(code: BLEConsoleErrorCode)
    case closed
}

@MainActor
final class BLEConsoleSession {
    static let maximumQueuedByteCount = 256 * 1_024

    private static let reconnectDelays: [TimeInterval] = [1, 2, 4]

    let config: ConsoleSessionConfig
    private(set) var state: BLEConsoleSessionState = .idle
    private(set) var currentGeneration: UInt64 = 0
    private(set) var resolvedProfile: ConsoleProfileMatch?
    private(set) var queuedByteCount = 0
    private(set) var bytesSent: UInt64 = 0
    private(set) var bytesReceived: UInt64 = 0

    var onStateChange: ((BLEConsoleSessionState) -> Void)?
    var onReceiveBytes: (([UInt8]) -> Void)?
    var onProfileMapperRequest: (([ConsoleServiceMetadata]) -> Void)?
    var onDiagnostic: ((BLEConsoleErrorCode, String?) -> Void)?

    private let driver: BLEConsoleCentralDriving
    private let scheduler: BLEConsoleScheduling
    private let deviceIdentifier: UUID?
    private var queuedBytes: [UInt8] = []
    private var queuedByteOffset = 0
    private var inFlightWithResponseByteCount: Int?
    private var reconnectAttempt = 0
    private var reconnectAction: BLEConsoleScheduledAction?
    private var hasStarted = false
    private var isClosed = false

    init(
        config: ConsoleSessionConfig,
        driver: BLEConsoleCentralDriving,
        scheduler: BLEConsoleScheduling = DispatchBLEConsoleScheduler()
    ) {
        self.config = config
        self.driver = driver
        self.scheduler = scheduler
        deviceIdentifier = config.ble.platformBindings.macOsPeripheralUuid.flatMap(UUID.init(uuidString:))

        driver.eventHandler = { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event)
            }
        }
    }

    func start() {
        guard !isClosed else { return }
        guard deviceIdentifier != nil else {
            fail(code: .configInvalid, diagnostic: "missing macOS peripheral binding")
            return
        }

        reconnectAction?.cancel()
        reconnectAction = nil
        reconnectAttempt = 0
        hasStarted = true
        beginConnection(state: .connecting)
    }

    func enqueueWrite(_ bytes: [UInt8]) throws {
        guard !bytes.isEmpty else { return }
        guard bytes.count <= Self.maximumQueuedByteCount - queuedByteCount else {
            throw BLEConsoleErrorCode.txQueueFull
        }

        queuedBytes.append(contentsOf: bytes)
        queuedByteCount += bytes.count
        flushWriteQueueIfPossible()
    }

    func handle(_ event: BLEConsoleCentralEvent) {
        guard !isClosed else { return }

        switch event {
        case let .connected(identifier, generation):
            guard accepts(identifier: identifier, generation: generation) else { return }
            transition(to: .discovering)
            driver.discoverProfile(identifier: identifier, generation: generation)

        case let .connectionFailed(identifier, code, diagnostic, generation):
            guard accepts(identifier: identifier, generation: generation) else { return }
            onDiagnostic?(code, diagnostic)
            scheduleReconnectOrFail(code: code)

        case let .disconnected(identifier, error, generation):
            guard accepts(identifier: identifier, generation: generation) else { return }
            onDiagnostic?(.disconnected, error)
            scheduleReconnectOrFail(code: .disconnected)

        case let .servicesDiscovered(identifier, services, generation):
            guard accepts(identifier: identifier, generation: generation), state == .discovering else {
                return
            }
            guard let profile = resolveProfile(from: services) else {
                fail(code: .profileChanged, diagnostic: nil)
                onProfileMapperRequest?(services)
                return
            }
            resolvedProfile = profile
            transition(to: .subscribing)
            driver.subscribe(
                identifier: identifier,
                characteristicUUID: profile.rxCharacteristicUuid,
                generation: generation
            )

        case let .profileDiscoveryFailed(identifier, code, diagnostic, generation):
            guard accepts(identifier: identifier, generation: generation) else { return }
            fail(code: code, diagnostic: diagnostic)

        case let .subscribed(identifier, characteristicUUID, generation):
            guard accepts(identifier: identifier, generation: generation),
                  state == .subscribing,
                  matches(characteristicUUID, resolvedProfile?.rxCharacteristicUuid)
            else {
                return
            }
            reconnectAttempt = 0
            transition(to: .connected)
            flushWriteQueueIfPossible()

        case let .subscriptionFailed(identifier, characteristicUUID, diagnostic, generation):
            guard accepts(identifier: identifier, generation: generation),
                  matches(characteristicUUID, resolvedProfile?.rxCharacteristicUuid)
            else {
                return
            }
            fail(code: .subscribeFailed, diagnostic: diagnostic)

        case let .rxData(identifier, characteristicUUID, data, generation):
            guard accepts(identifier: identifier, generation: generation),
                  state == .connected,
                  matches(characteristicUUID, resolvedProfile?.rxCharacteristicUuid)
            else {
                return
            }
            let bytes = [UInt8](data)
            bytesReceived &+= UInt64(bytes.count)
            onReceiveBytes?(bytes)

        case let .writeAcknowledged(identifier, characteristicUUID, generation):
            guard accepts(identifier: identifier, generation: generation),
                  matches(characteristicUUID, resolvedProfile?.txCharacteristicUuid),
                  let confirmedCount = inFlightWithResponseByteCount
            else {
                return
            }
            removeQueuedPrefix(confirmedCount)
            inFlightWithResponseByteCount = nil
            flushWriteQueueIfPossible()

        case let .writeFailed(identifier, characteristicUUID, diagnostic, generation):
            guard accepts(identifier: identifier, generation: generation),
                  matches(characteristicUUID, resolvedProfile?.txCharacteristicUuid)
            else {
                return
            }
            inFlightWithResponseByteCount = nil
            fail(code: .writeFailed, diagnostic: diagnostic)

        case let .readyToSendWithoutResponse(identifier, generation):
            guard accepts(identifier: identifier, generation: generation) else { return }
            flushWriteQueueIfPossible()

        case let .stateChanged(centralState):
            handleCentralState(centralState)

        case .discoverySnapshot, .scanCompleted:
            break
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        reconnectAction?.cancel()
        reconnectAction = nil
        queuedBytes.removeAll(keepingCapacity: false)
        queuedByteOffset = 0
        queuedByteCount = 0
        inFlightWithResponseByteCount = nil
        resolvedProfile = nil
        driver.eventHandler = nil

        if hasStarted, let deviceIdentifier {
            driver.disconnect(identifier: deviceIdentifier, generation: currentGeneration)
        }
        transition(to: .closed)
        onReceiveBytes = nil
        onProfileMapperRequest = nil
        onDiagnostic = nil
    }

    private func beginConnection(state nextState: BLEConsoleSessionState) {
        guard !isClosed, let deviceIdentifier else { return }
        currentGeneration &+= 1
        inFlightWithResponseByteCount = nil
        resolvedProfile = nil
        transition(to: nextState)
        driver.connect(identifier: deviceIdentifier, generation: currentGeneration)
    }

    private func scheduleReconnectOrFail(code: BLEConsoleErrorCode) {
        guard reconnectAttempt < Self.reconnectDelays.count else {
            fail(code: code, diagnostic: nil)
            return
        }

        let attempt = reconnectAttempt + 1
        let delay = Self.reconnectDelays[reconnectAttempt]
        reconnectAttempt = attempt
        transition(to: .reconnecting(attempt: attempt))
        reconnectAction?.cancel()
        reconnectAction = scheduler.schedule(after: delay) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.isClosed, self.reconnectAttempt == attempt else { return }
                self.reconnectAction = nil
                self.beginConnection(state: .connecting)
            }
        }
    }

    private func resolveProfile(from services: [ConsoleServiceMetadata]) -> ConsoleProfileMatch? {
        if let saved = savedProfileMatch(in: services) {
            return saved
        }
        return CoreBridge.matchBLEConsoleProfile(services: services)
    }

    private func savedProfileMatch(in services: [ConsoleServiceMetadata]) -> ConsoleProfileMatch? {
        let saved = config.ble
        guard let service = services.first(where: { matches($0.uuid, saved.serviceUuid) }),
              let tx = service.characteristics.first(where: {
                  matches($0.uuid, saved.txCharacteristicUuid)
              }),
              let rx = service.characteristics.first(where: {
                  matches($0.uuid, saved.rxCharacteristicUuid)
              }),
              rx.supportsNotify || rx.supportsIndicate
        else {
            return nil
        }

        let writeType: String
        if tx.supportsWriteWithoutResponse {
            writeType = "without_response"
        } else if tx.supportsWrite {
            writeType = "with_response"
        } else {
            return nil
        }

        return ConsoleProfileMatch(
            profileId: saved.profileId,
            serviceUuid: service.uuid,
            txCharacteristicUuid: tx.uuid,
            rxCharacteristicUuid: rx.uuid,
            writeType: writeType
        )
    }

    private func flushWriteQueueIfPossible() {
        guard state == .connected,
              queuedByteCount > 0,
              let deviceIdentifier,
              let profile = resolvedProfile
        else {
            return
        }

        let withoutResponse = profile.writeType == "without_response"
        let maximumLength = max(
            1,
            driver.maximumWriteLength(
                identifier: deviceIdentifier,
                withoutResponse: withoutResponse
            )
        )

        if withoutResponse {
            while queuedByteCount > 0,
                  driver.canSendWriteWithoutResponse(identifier: deviceIdentifier)
            {
                let count = min(maximumLength, queuedByteCount)
                let chunk = Data(queuedBytes[queuedByteOffset ..< queuedByteOffset + count])
                driver.write(
                    identifier: deviceIdentifier,
                    characteristicUUID: profile.txCharacteristicUuid,
                    data: chunk,
                    withoutResponse: true,
                    generation: currentGeneration
                )
                removeQueuedPrefix(count)
            }
            return
        }

        guard inFlightWithResponseByteCount == nil else { return }
        let count = min(maximumLength, queuedByteCount)
        inFlightWithResponseByteCount = count
        driver.write(
            identifier: deviceIdentifier,
            characteristicUUID: profile.txCharacteristicUuid,
            data: Data(queuedBytes[queuedByteOffset ..< queuedByteOffset + count]),
            withoutResponse: false,
            generation: currentGeneration
        )
    }

    private func removeQueuedPrefix(_ count: Int) {
        guard count > 0 else { return }
        queuedByteOffset += count
        queuedByteCount -= count
        bytesSent &+= UInt64(count)
        if queuedByteCount == 0 {
            queuedBytes.removeAll(keepingCapacity: true)
            queuedByteOffset = 0
        } else if queuedByteOffset >= 4_096, queuedByteOffset * 2 >= queuedBytes.count {
            queuedBytes.removeFirst(queuedByteOffset)
            queuedByteOffset = 0
        }
    }

    private func accepts(identifier: UUID, generation: UInt64) -> Bool {
        identifier == deviceIdentifier && generation == currentGeneration
    }

    private func matches(_ lhs: String, _ rhs: String?) -> Bool {
        guard let rhs else { return false }
        return canonicalBluetoothUUID(lhs) == canonicalBluetoothUUID(rhs)
    }

    private func canonicalBluetoothUUID(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.count == 4, trimmed.allSatisfy(\.isHexDigit) {
            return "0000\(trimmed)-0000-1000-8000-00805f9b34fb"
        }
        if trimmed.count == 8, trimmed.allSatisfy(\.isHexDigit) {
            return "\(trimmed)-0000-1000-8000-00805f9b34fb"
        }
        return UUID(uuidString: trimmed)?.uuidString.lowercased() ?? trimmed
    }

    private func handleCentralState(_ centralState: BLEConsoleCentralState) {
        switch centralState {
        case .unauthorized:
            fail(code: .permissionDenied, diagnostic: nil)
        case .poweredOff:
            fail(code: .poweredOff, diagnostic: nil)
        case .unsupported:
            fail(code: .unavailable, diagnostic: nil)
        case .unknown, .resetting, .poweredOn:
            break
        }
    }

    private func fail(code: BLEConsoleErrorCode, diagnostic: String?) {
        reconnectAction?.cancel()
        reconnectAction = nil
        transition(to: .failed(code: code))
        onDiagnostic?(code, diagnostic)
    }

    private func transition(to nextState: BLEConsoleSessionState) {
        guard state != nextState else { return }
        state = nextState
        onStateChange?(nextState)
    }
}
