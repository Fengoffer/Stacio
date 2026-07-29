import Foundation

struct BLEConsoleRSSI: Equatable, Hashable, Sendable {
    let rawValue: Int

    var decibels: Int? {
        rawValue == 127 ? nil : rawValue
    }

    var displayText: String {
        decibels.map { "\($0) dBm" } ?? "-- dBm"
    }
}

enum BLEConsoleRecognition: Equatable, Hashable, Sendable {
    case nbee1103
    case ordinary

    init(deviceName: String?) {
        let normalized = deviceName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased() ?? ""
        if normalized == "NBEE_BLE_1103"
            || normalized.hasPrefix("NBEE_BLE_1103-")
            || normalized.hasPrefix("NBEE_BLE_1103_")
        {
            self = .nbee1103
        } else {
            self = .ordinary
        }
    }
}

struct BLEConsoleDiscoveredDevice: Equatable, Hashable, Sendable {
    let identifier: UUID
    let name: String?
    let advertisedServiceUUIDs: [String]
    let rssi: BLEConsoleRSSI
    let lastSeen: Date

    var displayName: String {
        let normalized = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalized.isEmpty ? L10n.BLEConsole.unnamedDevice : normalized
    }

    var recognition: BLEConsoleRecognition {
        BLEConsoleRecognition(deviceName: name)
    }

    var isProbableConsole: Bool {
        advertisedServiceUUIDs.contains(where: Self.isBTermUARTService)
    }

    private static func isBTermUARTService(_ value: String) -> Bool {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "ffe0", "ffe1",
             "0000ffe0-0000-1000-8000-00805f9b34fb",
             "0000ffe1-0000-1000-8000-00805f9b34fb":
            true
        default:
            false
        }
    }
}

enum BLEConsoleDeviceOrdering {
    static func sorted(_ devices: [BLEConsoleDiscoveredDevice]) -> [BLEConsoleDiscoveredDevice] {
        devices.sorted(by: precedes)
    }

    private static func precedes(
        _ lhs: BLEConsoleDiscoveredDevice,
        _ rhs: BLEConsoleDiscoveredDevice
    ) -> Bool {
        let lhsGroup = group(for: lhs)
        let rhsGroup = group(for: rhs)
        if lhsGroup != rhsGroup {
            return lhsGroup < rhsGroup
        }

        switch (lhs.rssi.decibels, rhs.rssi.decibels) {
        case let (lhsRSSI?, rhsRSSI?) where lhsRSSI != rhsRSSI:
            return lhsRSSI > rhsRSSI
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            break
        }

        let nameOrder = lhs.displayName.caseInsensitiveCompare(rhs.displayName)
        if nameOrder != .orderedSame {
            return nameOrder == .orderedAscending
        }
        return lhs.identifier.uuidString < rhs.identifier.uuidString
    }

    private static func group(for device: BLEConsoleDiscoveredDevice) -> Int {
        if device.recognition == .nbee1103 {
            return 0
        }
        return device.isProbableConsole ? 1 : 2
    }
}

struct BLEConsoleDiscoverySnapshot: Equatable, Sendable {
    static let reorderInterval: TimeInterval = 0.5
    static let staleInterval: TimeInterval = 10

    let devices: [BLEConsoleDiscoveredDevice]
    let selectedIdentifier: UUID?
    let generatedAt: Date
    private let lastReorderedAt: Date

    init(
        devices: [BLEConsoleDiscoveredDevice],
        selectedIdentifier: UUID? = nil,
        generatedAt: Date
    ) {
        let deduplicated = Self.deduplicatedLatest(devices)
        self.devices = BLEConsoleDeviceOrdering.sorted(deduplicated)
        self.selectedIdentifier = selectedIdentifier.flatMap { selected in
            deduplicated.contains(where: { $0.identifier == selected }) ? selected : nil
        }
        self.generatedAt = generatedAt
        lastReorderedAt = generatedAt
    }

    private init(
        devices: [BLEConsoleDiscoveredDevice],
        selectedIdentifier: UUID?,
        generatedAt: Date,
        lastReorderedAt: Date
    ) {
        self.devices = devices
        self.selectedIdentifier = selectedIdentifier
        self.generatedAt = generatedAt
        self.lastReorderedAt = lastReorderedAt
    }

    func replacing(
        devices candidates: [BLEConsoleDiscoveredDevice],
        at now: Date
    ) -> BLEConsoleDiscoverySnapshot {
        let fresh = Self.deduplicatedLatest(candidates).filter {
            now.timeIntervalSince($0.lastSeen) <= Self.staleInterval
        }
        let freshByIdentifier = Dictionary(uniqueKeysWithValues: fresh.map { ($0.identifier, $0) })
        let shouldReorder = now.timeIntervalSince(lastReorderedAt) >= Self.reorderInterval

        let nextDevices: [BLEConsoleDiscoveredDevice]
        let nextReorderedAt: Date
        if shouldReorder {
            nextDevices = BLEConsoleDeviceOrdering.sorted(fresh)
            nextReorderedAt = now
        } else {
            let existingOrder = devices.compactMap { freshByIdentifier[$0.identifier] }
            let existingIdentifiers = Set(existingOrder.map(\.identifier))
            let additions = fresh.filter { !existingIdentifiers.contains($0.identifier) }
            nextDevices = existingOrder + BLEConsoleDeviceOrdering.sorted(additions)
            nextReorderedAt = lastReorderedAt
        }

        let nextSelection = selectedIdentifier.flatMap { selected in
            freshByIdentifier[selected] == nil ? nil : selected
        }
        return BLEConsoleDiscoverySnapshot(
            devices: nextDevices,
            selectedIdentifier: nextSelection,
            generatedAt: now,
            lastReorderedAt: nextReorderedAt
        )
    }

    func selecting(_ identifier: UUID?) -> BLEConsoleDiscoverySnapshot {
        let selection = identifier.flatMap { proposed in
            devices.contains(where: { $0.identifier == proposed }) ? proposed : nil
        }
        return BLEConsoleDiscoverySnapshot(
            devices: devices,
            selectedIdentifier: selection,
            generatedAt: generatedAt,
            lastReorderedAt: lastReorderedAt
        )
    }

    private static func deduplicatedLatest(
        _ devices: [BLEConsoleDiscoveredDevice]
    ) -> [BLEConsoleDiscoveredDevice] {
        var latest: [UUID: BLEConsoleDiscoveredDevice] = [:]
        for device in devices {
            guard let existing = latest[device.identifier] else {
                latest[device.identifier] = device
                continue
            }
            if device.lastSeen >= existing.lastSeen {
                latest[device.identifier] = device
            }
        }
        return Array(latest.values)
    }
}

enum BLEConsoleErrorCode: String, CaseIterable, Error, Sendable {
    case permissionDenied = "BLE_CONSOLE_PERMISSION_DENIED"
    case poweredOff = "BLE_CONSOLE_POWERED_OFF"
    case unavailable = "BLE_CONSOLE_UNAVAILABLE"
    case scanTimeout = "BLE_CONSOLE_SCAN_TIMEOUT"
    case deviceNotFound = "BLE_CONSOLE_DEVICE_NOT_FOUND"
    case connectFailed = "BLE_CONSOLE_CONNECT_FAILED"
    case serviceMissing = "BLE_CONSOLE_SERVICE_MISSING"
    case txMissing = "BLE_CONSOLE_TX_MISSING"
    case rxMissing = "BLE_CONSOLE_RX_MISSING"
    case subscribeFailed = "BLE_CONSOLE_SUBSCRIBE_FAILED"
    case writeFailed = "BLE_CONSOLE_WRITE_FAILED"
    case txQueueFull = "BLE_CONSOLE_TX_QUEUE_FULL"
    case disconnected = "BLE_CONSOLE_DISCONNECTED"
    case configInvalid = "BLE_CONSOLE_CONFIG_INVALID"
    case profileChanged = "BLE_CONSOLE_PROFILE_CHANGED"
    case sppFallbackNotBound = "CONSOLE_SPP_FALLBACK_NOT_BOUND"
    case sppFallbackFailed = "CONSOLE_SPP_FALLBACK_FAILED"

    var diagnosticCode: String { rawValue }
    var title: String { L10n.BLEConsole.errorTitle(self) }
    var message: String { L10n.BLEConsole.errorMessage(self) }
    var recovery: String { L10n.BLEConsole.errorRecovery(self) }
}

extension BLEConsoleErrorCode: LocalizedError {
    var errorDescription: String? {
        "\(rawValue): \(message)"
    }

    var recoverySuggestion: String? {
        recovery
    }
}
