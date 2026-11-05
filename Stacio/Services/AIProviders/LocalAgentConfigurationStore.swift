import CryptoKit
import Darwin
import Foundation

public enum LocalAgentConfigurationStoreError: Error, Equatable {
    case valueStorageUnavailable
    case invalidRecord(String)
    case staleRevision(expected: Int64?, actual: Int64?)
    case missingMasterKey
    case corruptedValue(String)
    case consistencyMismatch(String)
    case lockUnavailable
    case storage(String)
}

/// The persisted, non-secret facts needed to reproduce one verified Local Agent
/// launch. OAuth/session material remains owned by the CLI and is never stored.
public struct LocalAgentConfigurationRecord: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let configurationID: String
    public let configurationRevision: Int64
    public let catalogID: String
    public let catalogSetRevision: Int
    public let descriptorRevision: Int
    public let rawIdentity: String
    public let userDisplayName: String
    public let executablePath: String
    public let executableIdentityDigest: String
    public let executableReferenceConfirmedAt: Date
    public let detectedVersion: String
    /// Authentication is an explicit piece of evidence, not inferred from the
    /// presence of an executable. Callers that do not provide a probe result
    /// stay non-runnable until an observed state is persisted.
    public let authenticationState: LocalAgentAuthenticationProbeState
    public let selectedProtocol: LocalAgentStructuredProtocol?
    public let executionProfileID: String
    public let executionProfileRevision: Int
    public let authenticationEvidenceRevision: String
    public let cliAuthenticationScopeDigest: String
    public let cliLoginIdentityDigest: String
    public let workingDirectoryMode: AgentProcessWorkingDirectoryMode
    public let workingDirectoryReference: String?
    public let pathPolicy: LocalAgentPATHPolicy
    public let customPATHEntries: [String]
    public let environmentAllowlist: [String]
    public let environmentDigest: String
    public let lastVerifiedAt: Date
    public let explicitlyEnabled: Bool

    public init(
        schemaVersion: Int = Self.schemaVersion,
        configurationID: String,
        configurationRevision: Int64 = 0,
        catalogID: String,
        catalogSetRevision: Int,
        descriptorRevision: Int,
        rawIdentity: String,
        userDisplayName: String,
        executablePath: String,
        executableIdentityDigest: String,
        executableReferenceConfirmedAt: Date,
        detectedVersion: String,
        authenticationState: LocalAgentAuthenticationProbeState = .unknown,
        selectedProtocol: LocalAgentStructuredProtocol? = nil,
        executionProfileID: String,
        executionProfileRevision: Int,
        authenticationEvidenceRevision: String,
        cliAuthenticationScopeDigest: String,
        cliLoginIdentityDigest: String,
        workingDirectoryMode: AgentProcessWorkingDirectoryMode = .managedWorkspace,
        workingDirectoryReference: String? = nil,
        pathPolicy: LocalAgentPATHPolicy = .controlled,
        customPATHEntries: [String] = [],
        environmentAllowlist: [String] = [],
        environmentDigest: String,
        lastVerifiedAt: Date,
        explicitlyEnabled: Bool
    ) {
        self.schemaVersion = schemaVersion
        self.configurationID = configurationID
        self.configurationRevision = configurationRevision
        self.catalogID = catalogID
        self.catalogSetRevision = catalogSetRevision
        self.descriptorRevision = descriptorRevision
        self.rawIdentity = rawIdentity
        self.userDisplayName = userDisplayName
        self.executablePath = executablePath
        self.executableIdentityDigest = executableIdentityDigest
        self.executableReferenceConfirmedAt = executableReferenceConfirmedAt
        self.detectedVersion = detectedVersion
        self.authenticationState = authenticationState
        self.selectedProtocol = selectedProtocol
        self.executionProfileID = executionProfileID
        self.executionProfileRevision = executionProfileRevision
        self.authenticationEvidenceRevision = authenticationEvidenceRevision
        self.cliAuthenticationScopeDigest = cliAuthenticationScopeDigest
        self.cliLoginIdentityDigest = cliLoginIdentityDigest
        self.workingDirectoryMode = workingDirectoryMode
        self.workingDirectoryReference = workingDirectoryReference
        self.pathPolicy = pathPolicy
        self.customPATHEntries = customPATHEntries
        self.environmentAllowlist = environmentAllowlist
        self.environmentDigest = environmentDigest
        self.lastVerifiedAt = lastVerifiedAt
        self.explicitlyEnabled = explicitlyEnabled
    }

    func replacingRevision(_ revision: Int64) -> Self {
        Self(
            schemaVersion: schemaVersion,
            configurationID: configurationID,
            configurationRevision: revision,
            catalogID: catalogID,
            catalogSetRevision: catalogSetRevision,
            descriptorRevision: descriptorRevision,
            rawIdentity: rawIdentity,
            userDisplayName: userDisplayName,
            executablePath: executablePath,
            executableIdentityDigest: executableIdentityDigest,
            executableReferenceConfirmedAt: executableReferenceConfirmedAt,
            detectedVersion: detectedVersion,
            authenticationState: authenticationState,
            selectedProtocol: selectedProtocol,
            executionProfileID: executionProfileID,
            executionProfileRevision: executionProfileRevision,
            authenticationEvidenceRevision: authenticationEvidenceRevision,
            cliAuthenticationScopeDigest: cliAuthenticationScopeDigest,
            cliLoginIdentityDigest: cliLoginIdentityDigest,
            workingDirectoryMode: workingDirectoryMode,
            workingDirectoryReference: workingDirectoryReference,
            pathPolicy: pathPolicy,
            customPATHEntries: customPATHEntries,
            environmentAllowlist: environmentAllowlist,
            environmentDigest: environmentDigest,
            lastVerifiedAt: lastVerifiedAt,
            explicitlyEnabled: explicitlyEnabled
        )
    }
}

public protocol LocalAgentConfigurationReading: AnyObject {
    func records() throws -> [LocalAgentConfigurationRecord]
}

public enum LocalAgentConfigurationIntegrity {
    public static func executableDigest(path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            while let chunk = try handle.read(upToCount: 256 * 1_024), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } catch {
            return nil
        }
        return digestString(hasher.finalize())
    }

    public static func environmentDigest(_ environment: [String]) -> String {
        digest(data: Data(environment.sorted().joined(separator: "\u{1f}").utf8))
    }

    static func evidenceDigest(_ values: [String]) -> String {
        digest(data: Data(values.joined(separator: "\u{1f}").utf8))
    }

    static func recordDigest(_ record: LocalAgentConfigurationRecord) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return digest(data: try encoder.encode(record))
    }

    static func isSHA256Digest(_ value: String) -> Bool {
        guard value.hasPrefix("sha256:"), value.utf8.count == 71 else { return false }
        return value.dropFirst(7).utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }

    private static func digest(data: Data) -> String {
        digestString(SHA256.hash(data: data))
    }

    private static func digestString<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Produces the exact environment frozen into a passthrough launch. A changed
/// inherited value changes the digest and forces the configuration back through
/// verification before another process can start.
public enum LocalAgentLaunchEnvironmentBuilder {
    public enum BuildError: Error, Equatable {
        case invalidPATHEntry(String)
        case emptyCustomPATH
        case invalidEnvironmentPattern(String)
        case forbiddenEnvironmentKey(String)
        case invalidEnvironmentValue(String)
    }

    public static func build(
        record: LocalAgentConfigurationRecord,
        descriptor: LocalAgentCatalogEntry,
        environment: [String: String],
        homeDirectory: String,
        additionalPATHEntries: [String] = []
    ) throws -> [String] {
        try build(
            executablePath: record.executablePath,
            rawIdentity: record.rawIdentity,
            pathPolicy: record.pathPolicy,
            customPATHEntries: record.customPATHEntries,
            environmentAllowlist: record.environmentAllowlist,
            descriptor: descriptor,
            environment: environment,
            homeDirectory: homeDirectory,
            additionalPATHEntries: additionalPATHEntries
        )
    }

    public static func build(
        executablePath: String,
        rawIdentity: String,
        pathPolicy: LocalAgentPATHPolicy,
        customPATHEntries: [String],
        environmentAllowlist: [String],
        descriptor: LocalAgentCatalogEntry,
        environment: [String: String],
        homeDirectory: String,
        additionalPATHEntries: [String] = []
    ) throws -> [String] {
        let allowedPatterns = descriptor.defaultEnvironmentAllowlist + environmentAllowlist
        for pattern in allowedPatterns {
            guard isSafeEnvironmentPattern(pattern) else {
                throw BuildError.invalidEnvironmentPattern(pattern)
            }
            guard !LocalAgentContainmentPolicy.envAlwaysRejected(pattern) else {
                throw BuildError.forbiddenEnvironmentKey(pattern)
            }
        }
        var result: [String: String] = [:]
        for (key, value) in environment where matches(key, patterns: allowedPatterns) {
            guard !LocalAgentContainmentPolicy.envAlwaysRejected(key) else {
                throw BuildError.forbiddenEnvironmentKey(key)
            }
            guard isSafeEnvironmentComponent(key), isSafeEnvironmentValue(value) else {
                throw BuildError.invalidEnvironmentValue(key)
            }
            result[key] = value
        }

        let executableDirectory = (executablePath as NSString).deletingLastPathComponent
        let policyEntries: [String]
        switch pathPolicy {
        case .controlled:
            policyEntries = [
                executableDirectory,
                "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"
            ]
        case .loginShell, .custom:
            guard !customPATHEntries.isEmpty else { throw BuildError.emptyCustomPATH }
            policyEntries = [executableDirectory] + customPATHEntries
        }
        let pathEntries = try normalizedPATHEntries(additionalPATHEntries + policyEntries)
        result["PATH"] = pathEntries.joined(separator: ":")
        guard isSafeEnvironmentValue(rawIdentity) else {
            throw BuildError.invalidEnvironmentValue("STACIO_LOCAL_AGENT")
        }
        result["STACIO_LOCAL_AGENT"] = rawIdentity
        if matches("HOME", patterns: allowedPatterns), result["HOME"] == nil {
            guard isSafeEnvironmentValue(homeDirectory) else {
                throw BuildError.invalidEnvironmentValue("HOME")
            }
            result["HOME"] = homeDirectory
        }
        return result.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    }

    private static func normalizedPATHEntries(_ entries: [String]) throws -> [String] {
        var seen = Set<String>()
        return try entries.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            // An empty PATH component means the current working directory on
            // POSIX shells. Never silently widen a frozen launch environment.
            guard !trimmed.isEmpty else {
                throw BuildError.invalidPATHEntry(value)
            }
            guard value == trimmed,
                  !value.contains(":"),
                  isSafeEnvironmentValue(value)
            else {
                throw BuildError.invalidPATHEntry(value)
            }
            let normalized = URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL.path
            guard trimmed.hasPrefix("/"), normalized == trimmed else {
                throw BuildError.invalidPATHEntry(value)
            }
            return seen.insert(normalized).inserted ? normalized : nil
        }
    }

    private static func matches(_ key: String, patterns: [String]) -> Bool {
        patterns.contains { pattern in
            pattern.hasSuffix("*")
                ? key.hasPrefix(String(pattern.dropLast()))
                : key == pattern
        }
    }

    static func isSafeEnvironmentPattern(_ pattern: String) -> Bool {
        let hasWildcard = pattern.hasSuffix("*")
        let key = hasWildcard ? String(pattern.dropLast()) : pattern
        guard !key.isEmpty, !key.contains("*") else { return false }
        return isSafeEnvironmentComponent(key)
    }

    private static func isSafeEnvironmentComponent(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first,
              CharacterSet.letters.union(CharacterSet(charactersIn: "_")).contains(first)
        else { return false }
        return value.unicodeScalars.dropFirst().allSatisfy {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).contains($0)
        }
    }

    private static func isSafeEnvironmentValue(_ value: String) -> Bool {
        !value.contains("\0") && !value.contains("\n") && !value.contains("\r")
    }
}

/// Encrypted value sidecar + Rust revision/digest index. The legacy metadata
/// methods remain available for other configuration tests, while production
/// Local Agent reads require the encrypted sidecar to be configured.
public final class LocalAgentConfigurationStore: LocalAgentConfigurationReading {
    private static let processSidecarLock = NSLock()
    private struct Envelope: Codable {
        var schemaVersion: Int
        var values: [String: StoredRecord]
    }

    private struct StoredRecord: Codable {
        var revision: Int64
        var sealedPayload: Data
    }

    private let backend: ConfigurationStoreBackend
    private let fileURL: URL?
    private let masterKeyProvider: ConversationMasterKeyProviding?
    private let catalog: RuntimeCatalogProviding
    private let environment: () -> [String: String]
    private let homeDirectory: () -> String
    private let isExecutable: (String) -> Bool
    private let executableDigest: (String) -> String?
    private let fileManager: FileManager
    private let lock = NSLock()
    private var envelope: Envelope

    public init(backend: ConfigurationStoreBackend) {
        self.backend = backend
        fileURL = nil
        masterKeyProvider = nil
        catalog = BundledRuntimeCatalog.shared
        environment = { ProcessInfo.processInfo.environment }
        homeDirectory = { NSHomeDirectory() }
        isExecutable = { FileManager.default.isExecutableFile(atPath: $0) }
        executableDigest = LocalAgentConfigurationIntegrity.executableDigest(path:)
        fileManager = .default
        envelope = Envelope(schemaVersion: 1, values: [:])
    }

    public init(
        backend: ConfigurationStoreBackend,
        fileURL: URL,
        masterKeyProvider: ConversationMasterKeyProviding = KeychainConversationMasterKeyProvider.shared,
        catalog: RuntimeCatalogProviding = BundledRuntimeCatalog.shared,
        environment: @escaping () -> [String: String] = { ProcessInfo.processInfo.environment },
        homeDirectory: @escaping () -> String = { NSHomeDirectory() },
        isExecutable: @escaping (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        executableDigest: @escaping (String) -> String? = LocalAgentConfigurationIntegrity.executableDigest(path:),
        fileManager: FileManager = .default
    ) throws {
        self.backend = backend
        self.fileURL = fileURL
        self.masterKeyProvider = masterKeyProvider
        self.catalog = catalog
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.isExecutable = isExecutable
        self.executableDigest = executableDigest
        self.fileManager = fileManager
        envelope = Envelope(schemaVersion: 1, values: [:])
        try withSidecarLock {
            try reloadEnvelopeFromDisk()
            try validateAllRecords()
        }
    }

    @discardableResult
    public func save(
        _ proposed: LocalAgentConfigurationRecord,
        expectedRevision: Int64?,
        operationID: String = UUID().uuidString,
        eventID: String = UUID().uuidString
    ) throws -> LocalAgentConfigurationRecord {
        lock.lock()
        defer { lock.unlock() }
        guard fileURL != nil, masterKeyProvider != nil else {
            throw LocalAgentConfigurationStoreError.valueStorageUnavailable
        }
        return try withSidecarLock {
            try reloadEnvelopeFromDisk()
            let actualRevision = envelope.values[proposed.configurationID]?.revision
            guard actualRevision == expectedRevision else {
                throw LocalAgentConfigurationStoreError.staleRevision(
                    expected: expectedRevision,
                    actual: actualRevision
                )
            }
            let nextRevision = (actualRevision ?? 0) + 1
            let record = proposed.replacingRevision(nextRevision)
            try validateForSave(record)
            let payload = try encode(record)
            let sealed = try seal(payload, configurationID: record.configurationID, revision: nextRevision)
            let oldEnvelope = envelope
            envelope.values[record.configurationID] = StoredRecord(
                revision: nextRevision,
                sealedPayload: sealed
            )
            var backendCommitted = false
            do {
                try persistEnvelope()
                let committedRevision = try backend.commitVerified(
                    configurationID: record.configurationID,
                    expectedRevision: expectedRevision,
                    valueDigest: try LocalAgentConfigurationIntegrity.recordDigest(record),
                    credentialReference: "cli-managed:\(record.catalogID)",
                    operationID: operationID,
                    eventID: eventID
                )
                backendCommitted = true
                guard committedRevision == nextRevision else {
                    throw LocalAgentConfigurationStoreError.consistencyMismatch(record.configurationID)
                }
            } catch let error as LocalAgentConfigurationStoreError {
                if !backendCommitted {
                    try restoreEnvelopeOrFail(oldEnvelope, configurationID: record.configurationID)
                }
                throw error
            } catch {
                if !backendCommitted {
                    try restoreEnvelopeOrFail(oldEnvelope, configurationID: record.configurationID)
                }
                throw LocalAgentConfigurationStoreError.storage("local agent configuration CAS")
            }
            return record
        }
    }

    /// Removes the encrypted value only after the Rust store accepts the same
    /// expected revision. A failed backend CAS restores the prior sidecar under
    /// the same cross-process lock.
    @discardableResult
    public func delete(
        configurationID: String,
        expectedRevision: Int64,
        operationID: String = UUID().uuidString,
        eventID: String = UUID().uuidString
    ) throws -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        guard fileURL != nil, masterKeyProvider != nil else {
            throw LocalAgentConfigurationStoreError.valueStorageUnavailable
        }
        return try withSidecarLock {
            try reloadEnvelopeFromDisk()
            guard let stored = envelope.values[configurationID] else {
                throw LocalAgentConfigurationStoreError.staleRevision(
                    expected: expectedRevision,
                    actual: nil
                )
            }
            guard stored.revision == expectedRevision else {
                throw LocalAgentConfigurationStoreError.staleRevision(
                    expected: expectedRevision,
                    actual: stored.revision
                )
            }
            guard try recordLocked(configurationID: configurationID) != nil else {
                throw LocalAgentConfigurationStoreError.consistencyMismatch(configurationID)
            }
            let oldEnvelope = envelope
            envelope.values.removeValue(forKey: configurationID)
            do {
                try persistEnvelope()
                let tombstoneDigest = LocalAgentConfigurationIntegrity.evidenceDigest([
                    configurationID, String(expectedRevision), operationID, "local-agent-deleted-v1"
                ])
                return try backend.delete(
                    configurationID: configurationID,
                    expectedRevision: expectedRevision,
                    tombstoneDigest: tombstoneDigest,
                    operationID: operationID,
                    eventID: eventID
                )
            } catch let error as LocalAgentConfigurationStoreError {
                try restoreEnvelopeOrFail(oldEnvelope, configurationID: configurationID)
                throw error
            } catch {
                try restoreEnvelopeOrFail(oldEnvelope, configurationID: configurationID)
                throw LocalAgentConfigurationStoreError.storage("local agent configuration deletion")
            }
        }
    }

    public func record(configurationID: String) throws -> LocalAgentConfigurationRecord? {
        lock.lock()
        defer { lock.unlock() }
        guard fileURL != nil else { return nil }
        return try withSidecarLock {
            try reloadEnvelopeFromDisk()
            return try recordLocked(configurationID: configurationID)
        }
    }

    public func records() throws -> [LocalAgentConfigurationRecord] {
        lock.lock()
        defer { lock.unlock() }
        guard fileURL != nil else { return [] }
        return try withSidecarLock {
            try reloadEnvelopeFromDisk()
            return try envelope.values.keys.sorted().compactMap {
                try recordLocked(configurationID: $0)
            }
        }
    }

    public func upsert(
        configurationID: String,
        expectedRevision: Int64?,
        valueDigest: String,
        credentialReference: String
    ) throws {
        try backend.upsert(
            configurationID: configurationID,
            expectedRevision: expectedRevision,
            valueDigest: valueDigest,
            credentialReference: credentialReference
        )
    }

    public func snapshot(configurationID: String) throws -> (revision: Int64, digest: String, state: String)? {
        try backend.snapshot(configurationID: configurationID)
    }

    public func projectedState(
        abandoned: Bool, processReconciliationRequired: Bool, isDetecting: Bool, isLoggingIn: Bool,
        unsupported: Bool, unconfigured: Bool, detectionFailed: Bool,
        authenticationStateUnknown: Bool, needsLogin: Bool, needsProfileSelection: Bool,
        needsVerification: Bool, disabled: Bool
    ) -> LocalAgentConfigurationState {
        RuntimeConfigurationStateProjector.projectLocalAgent(
            abandoned: abandoned,
            processReconciliationRequired: processReconciliationRequired,
            isDetecting: isDetecting,
            isLoggingIn: isLoggingIn,
            unsupported: unsupported,
            unconfigured: unconfigured,
            detectionFailed: detectionFailed,
            authenticationStateUnknown: authenticationStateUnknown,
            needsLogin: needsLogin,
            needsProfileSelection: needsProfileSelection,
            needsVerification: needsVerification,
            disabled: disabled
        )
    }

    private func validateAllRecords() throws {
        for configurationID in envelope.values.keys {
            _ = try recordLocked(configurationID: configurationID)
        }
    }

    private func recordLocked(configurationID: String) throws -> LocalAgentConfigurationRecord? {
        guard let stored = envelope.values[configurationID] else { return nil }
        guard let backendSnapshot = try? backend.snapshot(configurationID: configurationID),
              backendSnapshot.state == "active",
              backendSnapshot.revision == stored.revision
        else {
            throw LocalAgentConfigurationStoreError.consistencyMismatch(configurationID)
        }
        let payload = try open(
            stored.sealedPayload,
            configurationID: configurationID,
            revision: stored.revision
        )
        guard let record = try? JSONDecoder().decode(LocalAgentConfigurationRecord.self, from: payload),
              record.configurationID == configurationID,
              record.configurationRevision == stored.revision
        else {
            throw LocalAgentConfigurationStoreError.corruptedValue(configurationID)
        }
        guard (try? LocalAgentConfigurationIntegrity.recordDigest(record)) == backendSnapshot.digest else {
            throw LocalAgentConfigurationStoreError.consistencyMismatch(configurationID)
        }
        try validateStoredShape(record)
        return record
    }

    private func validateStoredShape(_ record: LocalAgentConfigurationRecord) throws {
        guard record.schemaVersion == LocalAgentConfigurationRecord.schemaVersion,
              !record.configurationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              record.configurationRevision > 0,
              record.catalogSetRevision > 0,
              record.descriptorRevision > 0,
              record.executionProfileRevision > 0,
              !record.detectedVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !record.authenticationEvidenceRevision.isEmpty,
              LocalAgentConfigurationIntegrity.isSHA256Digest(record.cliAuthenticationScopeDigest),
              LocalAgentConfigurationIntegrity.isSHA256Digest(record.cliLoginIdentityDigest),
              LocalAgentConfigurationIntegrity.isSHA256Digest(record.environmentDigest)
        else {
            throw LocalAgentConfigurationStoreError.invalidRecord(record.configurationID)
        }
        let standardized = URL(fileURLWithPath: record.executablePath).standardizedFileURL.path
        guard record.executablePath.hasPrefix("/"),
              standardized == record.executablePath,
              LocalAgentConfigurationIntegrity.isSHA256Digest(record.executableIdentityDigest)
        else {
            throw LocalAgentConfigurationStoreError.invalidRecord("executable:\(record.configurationID)")
        }
        for entry in record.customPATHEntries {
            guard entry.hasPrefix("/"),
                  URL(fileURLWithPath: entry, isDirectory: true).standardizedFileURL.path == entry,
                  !entry.contains(":"),
                  !entry.contains("\0"),
                  !entry.contains("\n"),
                  !entry.contains("\r")
            else {
                throw LocalAgentConfigurationStoreError.invalidRecord("pathPolicy:\(record.configurationID)")
            }
        }
        for pattern in record.environmentAllowlist {
            guard LocalAgentLaunchEnvironmentBuilder.isSafeEnvironmentPattern(pattern),
                  !LocalAgentContainmentPolicy.envAlwaysRejected(pattern)
            else {
                throw LocalAgentConfigurationStoreError.invalidRecord("environment:\(record.configurationID)")
            }
        }
        switch record.workingDirectoryMode {
        case .managedWorkspace, .askEveryTurn:
            guard record.workingDirectoryReference == nil else {
                throw LocalAgentConfigurationStoreError.invalidRecord("workingDirectory:\(record.configurationID)")
            }
        case .userSelectedLocalDirectory:
            guard let reference = record.workingDirectoryReference,
                  reference.hasPrefix("/"),
                  URL(fileURLWithPath: reference, isDirectory: true).standardizedFileURL.path == reference
            else {
                throw LocalAgentConfigurationStoreError.invalidRecord("workingDirectory:\(record.configurationID)")
            }
        }
    }

    private func validateForSave(_ record: LocalAgentConfigurationRecord) throws {
        try validateStoredShape(record)
        let resolved = URL(fileURLWithPath: record.executablePath).resolvingSymlinksInPath().path
        guard resolved == record.executablePath,
              isExecutable(record.executablePath),
              executableDigest(record.executablePath) == record.executableIdentityDigest
        else {
            throw LocalAgentConfigurationStoreError.invalidRecord("executable:\(record.configurationID)")
        }
        guard let set = catalog.catalogSet,
              set.catalogSetRevision == record.catalogSetRevision,
              let descriptor = set.localAgent(catalogID: record.catalogID),
              descriptor.revision == record.descriptorRevision,
              descriptor.rawIdentity == record.rawIdentity,
              descriptor.isExecutableCandidate,
              descriptor.permitsPTYFallback,
              descriptor.supportedWorkingDirectoryModes.contains(record.workingDirectoryMode),
              let profile = descriptor.executionProfiles.first(where: {
                  $0.profileID == record.executionProfileID
                      && $0.revision == record.executionProfileRevision
                      && $0.supportLevel != .unsupported
              })
        else {
            throw LocalAgentConfigurationStoreError.invalidRecord("catalog:\(record.configurationID)")
        }
        switch profile.kind {
        case .managed:
            guard let selectedProtocol = record.selectedProtocol,
                  descriptor.structuredProtocolPriority.contains(selectedProtocol)
            else {
                throw LocalAgentConfigurationStoreError.invalidRecord("protocol:\(record.configurationID)")
            }
        case .terminalPassthrough, .none:
            if let selectedProtocol = record.selectedProtocol,
               !descriptor.structuredProtocolPriority.contains(selectedProtocol) {
                throw LocalAgentConfigurationStoreError.invalidRecord("protocol:\(record.configurationID)")
            }
        }
        if record.workingDirectoryMode == .userSelectedLocalDirectory,
           let reference = record.workingDirectoryReference {
            var isDirectory: ObjCBool = false
            let directoryURL = URL(fileURLWithPath: reference, isDirectory: true)
            guard directoryURL.resolvingSymlinksInPath().path == reference,
                  fileManager.fileExists(atPath: reference, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else {
                throw LocalAgentConfigurationStoreError.invalidRecord(
                    "workingDirectory:\(record.configurationID)"
                )
            }
        }
        let launchEnvironment: [String]
        do {
            launchEnvironment = try LocalAgentLaunchEnvironmentBuilder.build(
                record: record,
                descriptor: descriptor,
                environment: environment(),
                homeDirectory: homeDirectory()
            )
        } catch {
            throw LocalAgentConfigurationStoreError.invalidRecord("environment:\(record.configurationID)")
        }
        guard LocalAgentConfigurationIntegrity.environmentDigest(launchEnvironment) == record.environmentDigest else {
            throw LocalAgentConfigurationStoreError.invalidRecord("environmentDigest:\(record.configurationID)")
        }
    }

    private func encode(_ record: LocalAgentConfigurationRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(record)
        } catch {
            throw LocalAgentConfigurationStoreError.storage("encode local agent configuration")
        }
    }

    private func seal(_ payload: Data, configurationID: String, revision: Int64) throws -> Data {
        guard let masterKeyProvider else { throw LocalAgentConfigurationStoreError.missingMasterKey }
        do {
            return try RuntimeConfigurationMetadataKey.seal(
                value: payload,
                configurationID: configurationID,
                field: "localAgentConfiguration.v1.revision.\(revision)",
                masterKeyData: try masterKeyProvider.masterKeyData()
            )
        } catch {
            throw LocalAgentConfigurationStoreError.missingMasterKey
        }
    }

    private func open(_ payload: Data, configurationID: String, revision: Int64) throws -> Data {
        guard let masterKeyProvider else { throw LocalAgentConfigurationStoreError.missingMasterKey }
        do {
            return try RuntimeConfigurationMetadataKey.open(
                sealed: payload,
                configurationID: configurationID,
                field: "localAgentConfiguration.v1.revision.\(revision)",
                masterKeyData: try masterKeyProvider.masterKeyData()
            )
        } catch {
            throw LocalAgentConfigurationStoreError.corruptedValue(configurationID)
        }
    }

    private func persistEnvelope() throws {
        guard let fileURL else { throw LocalAgentConfigurationStoreError.valueStorageUnavailable }
        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(envelope).write(to: fileURL, options: .atomic)
        } catch {
            throw LocalAgentConfigurationStoreError.storage("local agent configuration sidecar")
        }
    }

    private func reloadEnvelopeFromDisk() throws {
        guard let fileURL else { throw LocalAgentConfigurationStoreError.valueStorageUnavailable }
        guard fileManager.fileExists(atPath: fileURL.path) else {
            envelope = Envelope(schemaVersion: 1, values: [:])
            return
        }
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: fileURL))
        } catch {
            throw LocalAgentConfigurationStoreError.storage("local agent configuration envelope")
        }
        guard envelope.schemaVersion == 1 else {
            throw LocalAgentConfigurationStoreError.corruptedValue("schema")
        }
    }

    private func restoreEnvelopeOrFail(
        _ oldEnvelope: Envelope,
        configurationID: String
    ) throws {
        envelope = oldEnvelope
        do {
            try persistEnvelope()
        } catch {
            throw LocalAgentConfigurationStoreError.consistencyMismatch(configurationID)
        }
    }

    private func withSidecarLock<T>(_ body: () throws -> T) throws -> T {
        guard let fileURL else { throw LocalAgentConfigurationStoreError.valueStorageUnavailable }
        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw LocalAgentConfigurationStoreError.lockUnavailable
        }
        let lockURL = fileURL.appendingPathExtension("lock")
        let descriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw LocalAgentConfigurationStoreError.lockUnavailable }
        Self.processSidecarLock.lock()
        defer { Self.processSidecarLock.unlock() }
        var fileLock = Darwin.flock(
            l_start: 0,
            l_len: 0,
            l_pid: 0,
            l_type: Int16(F_WRLCK),
            l_whence: Int16(SEEK_SET)
        )
        defer {
            fileLock.l_type = Int16(F_UNLCK)
            _ = Darwin.fcntl(descriptor, F_SETLK, &fileLock)
            _ = Darwin.close(descriptor)
        }
        guard Darwin.fcntl(descriptor, F_SETLKW, &fileLock) == 0 else {
            throw LocalAgentConfigurationStoreError.lockUnavailable
        }
        return try body()
    }
}

/// One live owner prevents two in-process sidecar snapshots from racing the
/// Rust CAS index. Failure leaves Local Agent launch disabled, never PATH-only.
public enum LocalAgentConfigurationLiveStore {
    private static let lock = NSLock()
    private static var cachedStore: LocalAgentConfigurationStore?

    public static func shared() throws -> LocalAgentConfigurationStore {
        lock.lock()
        defer { lock.unlock() }
        if let cachedStore { return cachedStore }
        let paths = try StacioPaths()
        let backend = try ConfigurationStoreBackend(
            databasePath: paths.applicationSupportDirectory
                .appendingPathComponent("runtime-configurations-v2.sqlite3").path
        )
        let store = try LocalAgentConfigurationStore(
            backend: backend,
            fileURL: paths.applicationSupportDirectory
                .appendingPathComponent("local-agent-configurations-v1.json"),
            masterKeyProvider: KeychainConversationMasterKeyProvider.shared
        )
        cachedStore = store
        return store
    }

    public static func sharedIfAvailable() -> LocalAgentConfigurationStore? {
        try? shared()
    }
}
