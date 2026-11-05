import CryptoKit
import Foundation

public enum FeedbackDiagnosticTraceStage: String, Codable, CaseIterable, Sendable {
    case selection
    case recognition
    case preview
    case apply
    case credentials
}

public enum FeedbackDiagnosticTraceResult: String, Codable, CaseIterable, Sendable {
    case selected
    case ready
    case cancelled
    case succeeded
    case failed
}

public enum FeedbackDiagnosticSourceType: String, Codable, CaseIterable, Sendable {
    case bastionHost = "bastion_host"
    case csv
    case legacyINI = "legacy_ini"
    case stacioJSON = "stacio_json"
    case xShell = "xshell"
    case mobaXterm = "mobaxterm"
    case windTerm = "windterm"
    case secureCRT = "securecrt"
    case finalShell = "finalshell"
    case termius
    case electerm
    case genericJSON = "json"
    case unknown

    init(_ sourceType: SessionImportSourceType) {
        self = FeedbackDiagnosticSourceType(rawValue: sourceType.rawValue) ?? .unknown
    }
}

struct FeedbackDiagnosticRouteHasher {
    static let shared = FeedbackDiagnosticRouteHasher(
        keyData: FeedbackDiagnosticRouteSecretStore.shared.keyData()
    )

    private let key: SymmetricKey

    init(keyData: Data) {
        key = SymmetricKey(data: keyData)
    }

    func hash(_ identity: String) -> String? {
        let normalized = identity.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false else { return nil }
        return HMAC<SHA256>.authenticationCode(
            for: Data(normalized.utf8),
            using: key
        )
        .map { String(format: "%02x", $0) }
        .joined()
    }
}

private final class FeedbackDiagnosticRouteSecretStore {
    static let shared = FeedbackDiagnosticRouteSecretStore()
    private static let defaultsKey = "Stacio.ProductOps.diagnosticRouteHashSecretV1"

    private let lock = NSLock()
    private let defaults: UserDefaults
    private var cachedKeyData: Data?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func keyData() -> Data {
        lock.lock()
        defer { lock.unlock() }
        if let cachedKeyData {
            return cachedKeyData
        }
        if let stored = defaults.data(forKey: Self.defaultsKey), stored.count == 32 {
            cachedKeyData = stored
            return stored
        }
        var generator = SystemRandomNumberGenerator()
        var bytes: [UInt8] = []
        bytes.reserveCapacity(32)
        for _ in 0..<32 {
            bytes.append(UInt8.random(in: .min ... .max, using: &generator))
        }
        let generated = Data(bytes)
        defaults.set(generated, forKey: Self.defaultsKey)
        cachedKeyData = generated
        return generated
    }
}

public struct FeedbackDiagnosticTraceEvent: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let stage: FeedbackDiagnosticTraceStage
    public let sourceType: FeedbackDiagnosticSourceType
    public let vendor: String?
    public let sessionCount: Int
    public let conflictCount: Int
    public let result: FeedbackDiagnosticTraceResult
    public let errorCode: String?
    public let routeHashes: [String]
    public let hasTargetMetadata: Bool

    public init(
        timestamp: Date,
        stage: FeedbackDiagnosticTraceStage,
        sourceType: FeedbackDiagnosticSourceType,
        vendor: String?,
        sessionCount: Int,
        conflictCount: Int,
        result: FeedbackDiagnosticTraceResult,
        errorCode: String?,
        routeIdentity: String?,
        hasTargetMetadata: Bool
    ) {
        self.init(
            timestamp: timestamp,
            stage: stage,
            sourceType: sourceType,
            vendor: vendor,
            sessionCount: sessionCount,
            conflictCount: conflictCount,
            result: result,
            errorCode: errorCode,
            routeIdentities: routeIdentity.map { [$0] } ?? [],
            hasTargetMetadata: hasTargetMetadata,
            routeHasher: .shared
        )
    }

    init(
        timestamp: Date,
        stage: FeedbackDiagnosticTraceStage,
        sourceType: FeedbackDiagnosticSourceType,
        vendor: String?,
        sessionCount: Int,
        conflictCount: Int,
        result: FeedbackDiagnosticTraceResult,
        errorCode: String?,
        routeIdentities: [String],
        hasTargetMetadata: Bool,
        routeHasher: FeedbackDiagnosticRouteHasher
    ) {
        self.timestamp = timestamp
        self.stage = stage
        self.sourceType = sourceType
        self.vendor = Self.sanitizedVendor(vendor)
        self.sessionCount = min(max(0, sessionCount), 10_000)
        self.conflictCount = min(max(0, conflictCount), 10_000)
        self.result = result
        self.errorCode = Self.sanitizedErrorCode(errorCode)
        self.routeHashes = Array(
            Set(routeIdentities.compactMap(routeHasher.hash))
        )
        .sorted()
        .prefix(8)
        .map { $0 }
        self.hasTargetMetadata = hasTargetMetadata
    }

    fileprivate var isValid: Bool {
        vendor.map { Self.sanitizedVendor($0) == $0 } ?? true
            && errorCode.map { Self.sanitizedErrorCode($0) == $0 } ?? true
            && sessionCount >= 0 && sessionCount <= 10_000
            && conflictCount >= 0 && conflictCount <= 10_000
            && routeHashes.count <= 8
            && routeHashes.allSatisfy {
                $0.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
            }
    }

    private static func sanitizedVendor(_ vendor: String?) -> String? {
        guard let vendor else { return nil }
        let normalized = vendor.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allowed = Set(BastionHostVendor.allCases.map(\.rawValue))
        guard allowed.contains(normalized) else {
            return nil
        }
        return normalized
    }

    private static func sanitizedErrorCode(_ errorCode: String?) -> String? {
        guard let errorCode else { return nil }
        let normalized = errorCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allowed: Set<String> = [
            "selection_failed",
            "selection_cancelled",
            "parse_failed",
            "vendor_not_selected",
            "preview_failed",
            "preview_cancelled",
            "apply_failed",
            "credentials_failed",
            "authorization_failed"
        ]
        return allowed.contains(normalized) ? normalized : nil
    }
}

public struct FeedbackDiagnosticTrace: Codable, Equatable, Sendable {
    public let version: Int
    public let events: [FeedbackDiagnosticTraceEvent]

    public init(version: Int = 1, events: [FeedbackDiagnosticTraceEvent]) {
        self.version = version
        self.events = events
    }

    public func encodedJSONString() -> String? {
        guard let data = try? JSONEncoder.productOps.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func validatedJSONString(_ value: String) -> String? {
        guard let trace = validatedTrace(from: value),
              let normalized = trace.encodedJSONString(),
              normalized.utf8.count <= FeedbackDiagnosticTraceStore.maximumPayloadBytes
        else {
            return nil
        }
        return normalized
    }

    static func validatedTrace(
        from value: String,
        now: Date = Date(),
        retentionInterval: TimeInterval = 24 * 60 * 60
    ) -> FeedbackDiagnosticTrace? {
        guard value.utf8.count <= FeedbackDiagnosticTraceStore.maximumPayloadBytes,
              let data = value.data(using: .utf8),
              let trace = try? JSONDecoder.productOps.decode(Self.self, from: data),
              trace.isValid,
              trace.events.allSatisfy({ event in
                  event.timestamp >= now.addingTimeInterval(-retentionInterval)
                      && event.timestamp <= now.addingTimeInterval(5 * 60)
              })
        else {
            return nil
        }
        return trace
    }

    fileprivate var isValid: Bool {
        version == 1
            && events.count <= FeedbackDiagnosticTraceStore.maximumPersistedEvents
            && events.allSatisfy(\.isValid)
    }
}

public protocol FeedbackDiagnosticTraceRecording: AnyObject {
    func record(
        stage: FeedbackDiagnosticTraceStage,
        sourceType: SessionImportSourceType,
        vendor: String?,
        sessionCount: Int,
        conflictCount: Int,
        result: FeedbackDiagnosticTraceResult,
        errorCode: String?,
        routeIdentities: [String],
        hasTargetMetadata: Bool
    )
}

public final class FeedbackDiagnosticTraceStore: FeedbackDiagnosticTraceRecording {
    public static let diagnosticsKey = "sessionImportTraceV1"
    public static let defaultsKey = "Stacio.ProductOps.sessionImportTraceV1"
    public static let maximumPersistedEvents = 16
    public static let maximumPayloadBytes = 8 * 1_024
    public static let shared = FeedbackDiagnosticTraceStore(
        defaults: .standard,
        defaultsKey: defaultsKey,
        maxEvents: maximumPersistedEvents,
        ttl: 24 * 60 * 60,
        maximumEncodedBytes: maximumPayloadBytes,
        clock: Date.init
    )

    private let lock = NSLock()
    private let defaults: UserDefaults?
    private let defaultsKey: String
    private let maxEvents: Int
    private let ttl: TimeInterval
    private let maximumEncodedBytes: Int
    private let clock: () -> Date
    private let routeHasher: FeedbackDiagnosticRouteHasher
    private var inMemoryTrace = FeedbackDiagnosticTrace(events: [])

    public init(
        maxEvents: Int = FeedbackDiagnosticTraceStore.maximumPersistedEvents,
        ttl: TimeInterval = 24 * 60 * 60,
        clock: @escaping () -> Date = Date.init,
        maximumEncodedBytes: Int = FeedbackDiagnosticTraceStore.maximumPayloadBytes,
        routeHashKey: Data? = nil
    ) {
        defaults = nil
        defaultsKey = Self.defaultsKey
        self.maxEvents = max(0, min(maxEvents, Self.maximumPersistedEvents))
        self.ttl = max(0, ttl)
        self.maximumEncodedBytes = max(256, min(maximumEncodedBytes, Self.maximumPayloadBytes))
        self.clock = clock
        routeHasher = routeHashKey.map { FeedbackDiagnosticRouteHasher(keyData: $0) } ?? .shared
    }

    public init(
        defaults: UserDefaults,
        defaultsKey: String = FeedbackDiagnosticTraceStore.defaultsKey,
        maxEvents: Int = FeedbackDiagnosticTraceStore.maximumPersistedEvents,
        ttl: TimeInterval = 24 * 60 * 60,
        maximumEncodedBytes: Int = FeedbackDiagnosticTraceStore.maximumPayloadBytes,
        clock: @escaping () -> Date = Date.init,
        routeHashKey: Data? = nil
    ) {
        self.defaults = defaults
        self.defaultsKey = defaultsKey
        self.maxEvents = max(0, min(maxEvents, Self.maximumPersistedEvents))
        self.ttl = max(0, ttl)
        self.maximumEncodedBytes = max(256, min(maximumEncodedBytes, Self.maximumPayloadBytes))
        self.clock = clock
        routeHasher = routeHashKey.map { FeedbackDiagnosticRouteHasher(keyData: $0) } ?? .shared
    }

    public func record(
        stage: FeedbackDiagnosticTraceStage,
        sourceType: FeedbackDiagnosticSourceType,
        vendor: String?,
        sessionCount: Int,
        conflictCount: Int,
        result: FeedbackDiagnosticTraceResult,
        errorCode: String?,
        routeIdentity: String?,
        hasTargetMetadata: Bool,
        timestamp: Date? = nil
    ) {
        recordEvent(
            FeedbackDiagnosticTraceEvent(
                timestamp: timestamp ?? clock(),
                stage: stage,
                sourceType: sourceType,
                vendor: vendor,
                sessionCount: sessionCount,
                conflictCount: conflictCount,
                result: result,
                errorCode: errorCode,
                routeIdentities: routeIdentity.map { [$0] } ?? [],
                hasTargetMetadata: hasTargetMetadata,
                routeHasher: routeHasher
            )
        )
    }

    public func record(
        stage: FeedbackDiagnosticTraceStage,
        sourceType: SessionImportSourceType,
        vendor: String?,
        sessionCount: Int,
        conflictCount: Int,
        result: FeedbackDiagnosticTraceResult,
        errorCode: String?,
        routeIdentities: [String],
        hasTargetMetadata: Bool
    ) {
        recordEvent(
            FeedbackDiagnosticTraceEvent(
                timestamp: clock(),
                stage: stage,
                sourceType: FeedbackDiagnosticSourceType(sourceType),
                vendor: vendor,
                sessionCount: sessionCount,
                conflictCount: conflictCount,
                result: result,
                errorCode: errorCode,
                routeIdentities: routeIdentities,
                hasTargetMetadata: hasTargetMetadata,
                routeHasher: routeHasher
            )
        )
    }

    public func snapshot() -> FeedbackDiagnosticTrace {
        lock.lock()
        defer { lock.unlock() }
        let trace = boundedTrace(from: loadTrace(), now: clock())
        saveTrace(trace)
        return trace
    }

    private func recordEvent(_ event: FeedbackDiagnosticTraceEvent) {
        lock.lock()
        defer { lock.unlock() }
        var events = boundedTrace(from: loadTrace(), now: clock()).events
        events.append(event)
        saveTrace(boundedTrace(from: FeedbackDiagnosticTrace(events: events), now: clock()))
    }

    private func boundedTrace(from trace: FeedbackDiagnosticTrace, now: Date) -> FeedbackDiagnosticTrace {
        let cutoff = now.addingTimeInterval(-ttl)
        var events = trace.events.filter { event in
            event.isValid && event.timestamp >= cutoff && event.timestamp <= now.addingTimeInterval(5 * 60)
        }
        if events.count > maxEvents {
            events = Array(events.suffix(maxEvents))
        }
        var bounded = FeedbackDiagnosticTrace(events: events)
        while bounded.events.isEmpty == false,
              (bounded.encodedJSONString()?.utf8.count ?? Int.max) > maximumEncodedBytes {
            events.removeFirst()
            bounded = FeedbackDiagnosticTrace(events: events)
        }
        return bounded
    }

    private func loadTrace() -> FeedbackDiagnosticTrace {
        guard let defaults else { return inMemoryTrace }
        guard let data = defaults.data(forKey: defaultsKey),
              let trace = try? JSONDecoder.productOps.decode(FeedbackDiagnosticTrace.self, from: data),
              trace.isValid
        else {
            return FeedbackDiagnosticTrace(events: [])
        }
        return trace
    }

    private func saveTrace(_ trace: FeedbackDiagnosticTrace) {
        if let defaults {
            guard trace.events.isEmpty == false,
                  let data = try? JSONEncoder.productOps.encode(trace)
            else {
                defaults.removeObject(forKey: defaultsKey)
                return
            }
            defaults.set(data, forKey: defaultsKey)
        } else {
            inMemoryTrace = trace
        }
    }
}
