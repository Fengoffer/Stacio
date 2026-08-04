import CryptoKit
import Foundation
import Security

public enum FeedbackDiagnosticLogLevel: String, Codable, CaseIterable, Sendable {
    case debug
    case info
    case warning
    case error
}

public enum FeedbackDiagnosticLogSubsystem: String, Codable, CaseIterable, Sendable {
    case application
    case session
    case importFlow = "import"
    case deletion
    case feedback
}

public enum FeedbackDiagnosticLogEventCode: String, Codable, CaseIterable, Sendable {
    case applicationStarted = "application.started"
    case sessionCreated = "session.created"
    case sessionCreationFailed = "session.create_failed"
    case sessionConnectionStarted = "session.connection_started"
    case sessionConnected = "session.connected"
    case sessionConnectionFailed = "session.connection_failed"
    case sessionDisconnected = "session.disconnected"
    case sessionReconnectStarted = "session.reconnect_started"
    case sessionReconnected = "session.reconnected"
    case sessionReconnectFailed = "session.reconnect_failed"
    case sessionImportStage = "session.import_stage"
    case sessionDeleted = "session.deleted"
    case sessionDeleteFailed = "session.delete_failed"
    case sessionRuntimeCleanup = "session.runtime_cleanup"
    case feedbackWindowOpened = "feedback.window_opened"
    case feedbackSubmissionStarted = "feedback.submission_started"
    case feedbackSubmissionSucceeded = "feedback.submission_succeeded"
    case feedbackSubmissionFailed = "feedback.submission_failed"
}

public enum FeedbackDiagnosticLogStage: String, Codable, CaseIterable, Sendable {
    case startup
    case create
    case connect
    case disconnect
    case reconnect
    case selection
    case recognition
    case preview
    case apply
    case credentials
    case delete
    case runtimeCleanup = "runtime_cleanup"
    case open
    case submit
}

public enum FeedbackDiagnosticLogResult: String, Codable, CaseIterable, Sendable {
    case started
    case ready
    case succeeded
    case failed
    case cancelled
}

public enum FeedbackDiagnosticLogErrorCategory: String, Codable, CaseIterable, Sendable {
    case authorization
    case configuration
    case credentials
    case network
    case parsing
    case persistence
    case timeout
    case transport
    case unavailable
    case unknown
}

public struct FeedbackDiagnosticLogEnvironment: Codable, Equatable, Sendable {
    public let appVersion: String
    public let build: String
    public let osVersion: String
    public let architecture: String

    public init(appVersion: String, build: String, osVersion: String, architecture: String) {
        self.appVersion = Self.safeIdentifier(appVersion, maximumLength: 80, fallback: "unknown")
        self.build = Self.safeIdentifier(build, maximumLength: 80, fallback: "unknown")
        self.osVersion = Self.safeOSVersion(osVersion)
        self.architecture = Self.safeArchitecture(architecture)
    }

    public static func current(
        bundle: Bundle = .main,
        processInfo: ProcessInfo = .processInfo
    ) -> FeedbackDiagnosticLogEnvironment {
        let version = processInfo.operatingSystemVersion
        return FeedbackDiagnosticLogEnvironment(
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                ?? StacioAppMetadata.displayVersion,
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev",
            osVersion: "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            architecture: currentArchitecture
        )
    }

    fileprivate var isValid: Bool {
        appVersion == Self.safeIdentifier(appVersion, maximumLength: 80, fallback: "unknown")
            && build == Self.safeIdentifier(build, maximumLength: 80, fallback: "unknown")
            && osVersion == Self.safeOSVersion(osVersion)
            && architecture == Self.safeArchitecture(architecture)
    }

    private static var currentArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private static func safeIdentifier(_ value: String, maximumLength: Int, fallback: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._+-"))
        let normalized = value.unicodeScalars.filter(allowed.contains).map(String.init).joined()
        let bounded = String(normalized.prefix(maximumLength))
        return bounded.isEmpty ? fallback : bounded
    }

    private static func safeOSVersion(_ value: String) -> String {
        let components = value
            .split(whereSeparator: { $0.isNumber == false })
            .prefix(3)
            .compactMap { Int($0) }
        guard components.isEmpty == false else { return "macOS unknown" }
        let padded = components + Array(repeating: 0, count: max(0, 3 - components.count))
        return "macOS \(padded[0]).\(padded[1]).\(padded[2])"
    }

    private static func safeArchitecture(_ value: String) -> String {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "arm64", "arm64e": return "arm64"
        case "x86_64", "amd64": return "x86_64"
        default: return "unknown"
        }
    }
}

public struct FeedbackDiagnosticLogEvent: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let level: FeedbackDiagnosticLogLevel
    public let subsystem: FeedbackDiagnosticLogSubsystem
    public let eventCode: FeedbackDiagnosticLogEventCode
    public let stage: FeedbackDiagnosticLogStage
    public let result: FeedbackDiagnosticLogResult
    public let errorCategory: FeedbackDiagnosticLogErrorCategory?
    public let resourceHashes: [String]

    fileprivate var isValid: Bool {
        resourceHashes.count <= FeedbackDiagnosticLogStore.maximumResourceHashesPerEvent
            && resourceHashes.allSatisfy {
                $0.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
            }
    }
}

public struct FeedbackDiagnosticLogSnapshot: Codable, Equatable, Sendable {
    public let version: Int
    public let environment: FeedbackDiagnosticLogEnvironment
    public let events: [FeedbackDiagnosticLogEvent]

    public init(
        version: Int = 1,
        environment: FeedbackDiagnosticLogEnvironment,
        events: [FeedbackDiagnosticLogEvent]
    ) {
        self.version = version
        self.environment = environment
        self.events = events
    }

    public func encodedJSONString() -> String? {
        guard isValid,
              let data = try? JSONEncoder.productOps.encode(self),
              data.count <= FeedbackDiagnosticLogStore.maximumPayloadBytes
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func validatedJSONString(_ value: String, now: Date = Date()) -> String? {
        guard let snapshot = validatedSnapshot(from: value, now: now),
              let normalized = snapshot.encodedJSONString()
        else { return nil }
        return normalized
    }

    static func validatedSnapshot(
        from value: String,
        now: Date = Date(),
        retentionInterval: TimeInterval = 24 * 60 * 60
    ) -> FeedbackDiagnosticLogSnapshot? {
        guard value.utf8.count <= FeedbackDiagnosticLogStore.maximumPayloadBytes,
              let data = value.data(using: .utf8),
              let snapshot = try? JSONDecoder.productOps.decode(Self.self, from: data),
              snapshot.isValid,
              snapshot.events.allSatisfy({ event in
                  event.timestamp >= now.addingTimeInterval(-retentionInterval)
                      && event.timestamp <= now.addingTimeInterval(5 * 60)
              })
        else { return nil }
        return snapshot
    }

    fileprivate var isValid: Bool {
        version == 1
            && environment.isValid
            && events.count <= FeedbackDiagnosticLogStore.maximumPersistedEvents
            && events.allSatisfy(\.isValid)
    }
}

public protocol FeedbackDiagnosticLogRecording: AnyObject {
    func record(
        level: FeedbackDiagnosticLogLevel,
        subsystem: FeedbackDiagnosticLogSubsystem,
        eventCode: FeedbackDiagnosticLogEventCode,
        stage: FeedbackDiagnosticLogStage,
        result: FeedbackDiagnosticLogResult,
        errorCategory: FeedbackDiagnosticLogErrorCategory?,
        resourceIdentities: [String]
    )
}

public extension FeedbackDiagnosticLogRecording {
    func record(
        level: FeedbackDiagnosticLogLevel,
        subsystem: FeedbackDiagnosticLogSubsystem,
        eventCode: FeedbackDiagnosticLogEventCode,
        stage: FeedbackDiagnosticLogStage,
        result: FeedbackDiagnosticLogResult,
        errorCategory: FeedbackDiagnosticLogErrorCategory? = nil,
        resourceIdentity: String? = nil
    ) {
        record(
            level: level,
            subsystem: subsystem,
            eventCode: eventCode,
            stage: stage,
            result: result,
            errorCategory: errorCategory,
            resourceIdentities: resourceIdentity.map { [$0] } ?? []
        )
    }
}

/// Centralizes connection lifecycle event mapping so callers cannot accidentally
/// put endpoint or credential values into the structured feedback log.
public enum FeedbackDiagnosticLogConnectionLifecycle {
    public static func recordStarted(
        recorder: FeedbackDiagnosticLogRecording,
        resourceIdentity: String,
        reconnect: Bool
    ) {
        recorder.record(
            level: .info,
            subsystem: .session,
            eventCode: reconnect ? .sessionReconnectStarted : .sessionConnectionStarted,
            stage: reconnect ? .reconnect : .connect,
            result: .started,
            errorCategory: nil,
            resourceIdentity: resourceIdentity
        )
    }

    public static func recordSucceeded(
        recorder: FeedbackDiagnosticLogRecording,
        resourceIdentity: String,
        reconnect: Bool
    ) {
        recorder.record(
            level: .info,
            subsystem: .session,
            eventCode: reconnect ? .sessionReconnected : .sessionConnected,
            stage: reconnect ? .reconnect : .connect,
            result: .succeeded,
            errorCategory: nil,
            resourceIdentity: resourceIdentity
        )
    }

    public static func recordFailed(
        recorder: FeedbackDiagnosticLogRecording,
        resourceIdentity: String,
        reconnect: Bool,
        errorCategory: FeedbackDiagnosticLogErrorCategory = .network
    ) {
        recorder.record(
            level: .error,
            subsystem: .session,
            eventCode: reconnect ? .sessionReconnectFailed : .sessionConnectionFailed,
            stage: reconnect ? .reconnect : .connect,
            result: .failed,
            errorCategory: errorCategory,
            resourceIdentity: resourceIdentity
        )
    }

    public static func recordDisconnected(
        recorder: FeedbackDiagnosticLogRecording,
        resourceIdentity: String
    ) {
        recorder.record(
            level: .info,
            subsystem: .session,
            eventCode: .sessionDisconnected,
            stage: .disconnect,
            result: .succeeded,
            errorCategory: nil,
            resourceIdentity: resourceIdentity
        )
    }
}

public final class FeedbackDiagnosticLogStore: FeedbackDiagnosticLogRecording {
    private struct PersistedBuffer: Codable {
        let version: Int
        let events: [FeedbackDiagnosticLogEvent]
    }

    public static let diagnosticsKey = "recentDiagnosticEventsV1"
    public static let defaultsKey = "Stacio.ProductOps.recentDiagnosticEventsV1"
    public static let maximumPersistedEvents = 64
    public static let maximumPayloadBytes = 24 * 1_024
    public static let maximumResourceHashesPerEvent = 4
    public static let shared = FeedbackDiagnosticLogStore(
        defaults: .standard,
        defaultsKey: defaultsKey,
        maxEvents: maximumPersistedEvents,
        ttl: 24 * 60 * 60,
        maximumEncodedBytes: maximumPayloadBytes,
        clock: Date.init,
        environmentProvider: { FeedbackDiagnosticLogEnvironment.current() }
    )

    private let lock = NSLock()
    private let defaults: UserDefaults?
    private let defaultsKey: String
    private let maxEvents: Int
    private let ttl: TimeInterval
    private let maximumEncodedBytes: Int
    private let clock: () -> Date
    private let environmentProvider: () throws -> FeedbackDiagnosticLogEnvironment
    private let hasher: FeedbackDiagnosticLogHasher
    private var inMemoryEvents: [FeedbackDiagnosticLogEvent] = []

    public init(
        maxEvents: Int = FeedbackDiagnosticLogStore.maximumPersistedEvents,
        ttl: TimeInterval = 24 * 60 * 60,
        maximumEncodedBytes: Int = FeedbackDiagnosticLogStore.maximumPayloadBytes,
        clock: @escaping () -> Date = Date.init,
        routeHashKey: Data? = nil,
        environmentProvider: @escaping () throws -> FeedbackDiagnosticLogEnvironment = {
            FeedbackDiagnosticLogEnvironment.current()
        }
    ) {
        defaults = nil
        defaultsKey = Self.defaultsKey
        self.maxEvents = max(0, min(maxEvents, Self.maximumPersistedEvents))
        self.ttl = max(0, ttl)
        self.maximumEncodedBytes = max(512, min(maximumEncodedBytes, Self.maximumPayloadBytes))
        self.clock = clock
        self.environmentProvider = environmentProvider
        hasher = FeedbackDiagnosticLogHasher(
            keyData: routeHashKey ?? FeedbackDiagnosticLogSecretStore.shared.keyData()
        )
    }

    public init(
        defaults: UserDefaults,
        defaultsKey: String = FeedbackDiagnosticLogStore.defaultsKey,
        maxEvents: Int = FeedbackDiagnosticLogStore.maximumPersistedEvents,
        ttl: TimeInterval = 24 * 60 * 60,
        maximumEncodedBytes: Int = FeedbackDiagnosticLogStore.maximumPayloadBytes,
        clock: @escaping () -> Date = Date.init,
        routeHashKey: Data? = nil,
        environmentProvider: @escaping () throws -> FeedbackDiagnosticLogEnvironment = {
            FeedbackDiagnosticLogEnvironment.current()
        }
    ) {
        self.defaults = defaults
        self.defaultsKey = defaultsKey
        self.maxEvents = max(0, min(maxEvents, Self.maximumPersistedEvents))
        self.ttl = max(0, ttl)
        self.maximumEncodedBytes = max(512, min(maximumEncodedBytes, Self.maximumPayloadBytes))
        self.clock = clock
        self.environmentProvider = environmentProvider
        hasher = FeedbackDiagnosticLogHasher(
            keyData: routeHashKey ?? FeedbackDiagnosticLogSecretStore.shared.keyData()
        )
    }

    public func record(
        level: FeedbackDiagnosticLogLevel,
        subsystem: FeedbackDiagnosticLogSubsystem,
        eventCode: FeedbackDiagnosticLogEventCode,
        stage: FeedbackDiagnosticLogStage,
        result: FeedbackDiagnosticLogResult,
        errorCategory: FeedbackDiagnosticLogErrorCategory?,
        resourceIdentities: [String]
    ) {
        record(
            level: level,
            subsystem: subsystem,
            eventCode: eventCode,
            stage: stage,
            result: result,
            errorCategory: errorCategory,
            resourceIdentities: resourceIdentities,
            timestamp: nil
        )
    }

    public func record(
        level: FeedbackDiagnosticLogLevel,
        subsystem: FeedbackDiagnosticLogSubsystem,
        eventCode: FeedbackDiagnosticLogEventCode,
        stage: FeedbackDiagnosticLogStage,
        result: FeedbackDiagnosticLogResult,
        errorCategory: FeedbackDiagnosticLogErrorCategory?,
        resourceIdentities: [String],
        timestamp: Date?
    ) {
        let hashes = Array(
            Set(resourceIdentities.compactMap(hasher.hash))
        )
        .sorted()
        .prefix(Self.maximumResourceHashesPerEvent)
        .map { $0 }
        let event = FeedbackDiagnosticLogEvent(
            timestamp: timestamp ?? clock(),
            level: level,
            subsystem: subsystem,
            eventCode: eventCode,
            stage: stage,
            result: result,
            errorCategory: errorCategory,
            resourceHashes: hashes
        )
        lock.lock()
        defer { lock.unlock() }
        var events = boundedEvents(loadEvents(), now: clock())
        events.append(event)
        saveEvents(boundedEvents(events, now: clock()))
    }

    public func snapshot() -> FeedbackDiagnosticLogSnapshot {
        let environment = (try? environmentProvider()) ?? FeedbackDiagnosticLogEnvironment(
            appVersion: "unknown",
            build: "unknown",
            osVersion: "macOS unknown",
            architecture: "unknown"
        )
        lock.lock()
        defer { lock.unlock() }
        let events = boundedEvents(loadEvents(), now: clock(), environment: environment)
        saveEvents(events)
        return FeedbackDiagnosticLogSnapshot(environment: environment, events: events)
    }

    func hashForTesting(_ identity: String) -> String? {
        hasher.hash(identity)
    }

    private func boundedEvents(
        _ input: [FeedbackDiagnosticLogEvent],
        now: Date,
        environment: FeedbackDiagnosticLogEnvironment? = nil
    ) -> [FeedbackDiagnosticLogEvent] {
        let cutoff = now.addingTimeInterval(-ttl)
        var events = input.filter {
            $0.isValid && $0.timestamp >= cutoff && $0.timestamp <= now.addingTimeInterval(5 * 60)
        }
        if events.count > maxEvents {
            events = Array(events.suffix(maxEvents))
        }
        let resolvedEnvironment = environment
            ?? (try? environmentProvider())
            ?? FeedbackDiagnosticLogEnvironment(
                appVersion: "unknown",
                build: "unknown",
                osVersion: "macOS unknown",
                architecture: "unknown"
            )
        while events.isEmpty == false {
            let snapshot = FeedbackDiagnosticLogSnapshot(environment: resolvedEnvironment, events: events)
            let encodedSize = (try? JSONEncoder.productOps.encode(snapshot).count) ?? Int.max
            guard encodedSize > maximumEncodedBytes else { break }
            events.removeFirst()
        }
        return events
    }

    private func loadEvents() -> [FeedbackDiagnosticLogEvent] {
        guard let defaults else { return inMemoryEvents }
        guard let data = defaults.data(forKey: defaultsKey),
              let buffer = try? JSONDecoder.productOps.decode(PersistedBuffer.self, from: data),
              buffer.version == 1
        else { return [] }
        return buffer.events.filter(\.isValid)
    }

    private func saveEvents(_ events: [FeedbackDiagnosticLogEvent]) {
        if let defaults {
            guard events.isEmpty == false,
                  let data = try? JSONEncoder.productOps.encode(PersistedBuffer(version: 1, events: events))
            else {
                defaults.removeObject(forKey: defaultsKey)
                return
            }
            defaults.set(data, forKey: defaultsKey)
        } else {
            inMemoryEvents = events
        }
    }
}

private struct FeedbackDiagnosticLogHasher {
    private let key: SymmetricKey

    init(keyData: Data) {
        key = SymmetricKey(data: keyData)
    }

    func hash(_ identity: String) -> String? {
        let normalized = identity.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false else { return nil }
        return HMAC<SHA256>.authenticationCode(for: Data(normalized.utf8), using: key)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private final class FeedbackDiagnosticLogSecretStore {
    static let shared = FeedbackDiagnosticLogSecretStore()

    private static let keychainService = "cn.stacio.product-ops.diagnostics"
    private static let keychainAccount = "hmacHashKey"
    /// 旧版本将 HMAC 密钥存储在 UserDefaults 中，存在明文落盘风险。
    /// 迁移到 Keychain 后保留此 key 用于一次性迁移读取，迁移成功后从 UserDefaults 删除。
    private static let legacyDefaultsKey = "Stacio.ProductOps.diagnosticLogHashSecretV1"

    private let lock = NSLock()
    private var cachedKeyData: Data?

    func keyData(defaults: UserDefaults = .standard) -> Data {
        lock.lock()
        defer { lock.unlock() }
        if let cachedKeyData { return cachedKeyData }

        // 1. 优先从 Keychain 读取
        if let keychainData = readFromKeychain() {
            cachedKeyData = keychainData
            return keychainData
        }

        // 2. 迁移：如果 Keychain 中没有但 UserDefaults 中有，迁移到 Keychain 并清除旧值。
        // 只有当 Keychain 写入成功后才删除 UserDefaults 旧值，避免密钥永久丢失。
        if let legacyData = defaults.data(forKey: Self.legacyDefaultsKey), legacyData.count == 32 {
            if saveToKeychain(legacyData) {
                defaults.removeObject(forKey: Self.legacyDefaultsKey)
                cachedKeyData = legacyData
                return legacyData
            }
            // Keychain 写入失败（被锁定/权限问题）：回退使用 UserDefaults 旧值，
            // 下次调用时再尝试迁移，避免密钥丢失。
            cachedKeyData = legacyData
            return legacyData
        }

        // 3. 生成新密钥并存入 Keychain
        var generator = SystemRandomNumberGenerator()
        let generated = Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        // 即使 Keychain 写入失败也缓存到内存，进程内可用；下次启动会重新生成。
        // 这属于降级：HMAC 哈希在进程重启后无法保持一致，但不影响当前进程功能。
        _ = saveToKeychain(generated)
        cachedKeyData = generated
        return generated
    }

    private func readFromKeychain() -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.keychainService as CFString,
            kSecAttrAccount: Self.keychainAccount as CFString,
            kSecReturnData: kCFBooleanTrue,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecAttrSynchronizable: kCFBooleanFalse as Any
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    /// 将密钥写入 Keychain，返回是否成功。
    /// 失败原因通常是 Keychain 被锁定或应用无钥匙串权限。
    private func saveToKeychain(_ data: Data) -> Bool {
        let baseQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.keychainService as CFString,
            kSecAttrAccount: Self.keychainAccount as CFString,
            kSecAttrSynchronizable: kCFBooleanFalse as Any
        ]
        let updateAttributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        // 先尝试更新，不存在则新增
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updateAttributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }
        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery
            updateAttributes.forEach { addQuery[$0.key] = $0.value }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            return addStatus == errSecSuccess
        }
        return false
    }
}
