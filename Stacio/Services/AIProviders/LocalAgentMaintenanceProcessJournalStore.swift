import Darwin
import Foundation

public enum LocalAgentMaintenanceProcessJournalStoreError: Error, Equatable {
    case invalidPath
    case corruptJournal
    case invalidEntry(String)
    case duplicateOperation(String)
    case missingReference(String)
    case invalidTransition(referenceID: String, state: LocalAgentSettingsProcessState, event: String)
    case missingProcessIdentity(String)
    case insufficientReconciliationEvidence(String)
    case atomicWriteFailed(String)
}

/// Non-secret facts needed to reconcile an interactive Local Agent maintenance
/// process after a crash. Authentication material, argv values and environment
/// values are deliberately absent; only catalog/configuration identities and
/// digests are persisted.
public struct LocalAgentMaintenanceProcessJournalEntry: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let referenceID: String
    public let operationID: String
    public let configurationID: String
    public let action: LocalAgentMaintenanceAction
    public let executablePath: String
    public let executableIdentityDigest: String
    public let environmentDigest: String
    public let processGeneration: Int64
    public let processIdentifier: Int32?
    public let processGroupIdentifier: Int32?
    public let trustedProcessStartTime: Date?
    public let state: LocalAgentSettingsProcessState
    public let settlement: LocalAgentSettingsProcessSettlement
    public let preparedAt: Date
    public let startedAt: Date?
    public let finishedAt: Date?
    public let updatedAt: Date
    public let businessResultCommitted: Bool
    public let treeExited: Bool
    public let exitCode: Int32?
    public let failureReason: String?

    public init(
        schemaVersion: Int = Self.schemaVersion,
        referenceID: String,
        operationID: String,
        configurationID: String,
        action: LocalAgentMaintenanceAction,
        executablePath: String,
        executableIdentityDigest: String,
        environmentDigest: String,
        processGeneration: Int64,
        processIdentifier: Int32? = nil,
        processGroupIdentifier: Int32? = nil,
        trustedProcessStartTime: Date? = nil,
        state: LocalAgentSettingsProcessState = .prepared,
        settlement: LocalAgentSettingsProcessSettlement = .pending,
        preparedAt: Date,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        updatedAt: Date,
        businessResultCommitted: Bool = false,
        treeExited: Bool = false,
        exitCode: Int32? = nil,
        failureReason: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.referenceID = referenceID
        self.operationID = operationID
        self.configurationID = configurationID
        self.action = action
        self.executablePath = executablePath
        self.executableIdentityDigest = executableIdentityDigest
        self.environmentDigest = environmentDigest
        self.processGeneration = processGeneration
        self.processIdentifier = processIdentifier
        self.processGroupIdentifier = processGroupIdentifier
        self.trustedProcessStartTime = trustedProcessStartTime
        self.state = state
        self.settlement = settlement
        self.preparedAt = preparedAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.updatedAt = updatedAt
        self.businessResultCommitted = businessResultCommitted
        self.treeExited = treeExited
        self.exitCode = exitCode
        self.failureReason = failureReason
    }

    fileprivate func replacing(
        state: LocalAgentSettingsProcessState? = nil,
        settlement: LocalAgentSettingsProcessSettlement? = nil,
        processIdentifier: Int32?? = nil,
        processGroupIdentifier: Int32?? = nil,
        trustedProcessStartTime: Date?? = nil,
        startedAt: Date?? = nil,
        finishedAt: Date?? = nil,
        updatedAt: Date,
        businessResultCommitted: Bool? = nil,
        treeExited: Bool? = nil,
        exitCode: Int32?? = nil,
        failureReason: String?? = nil
    ) -> Self {
        Self(
            schemaVersion: schemaVersion,
            referenceID: referenceID,
            operationID: operationID,
            configurationID: configurationID,
            action: action,
            executablePath: executablePath,
            executableIdentityDigest: executableIdentityDigest,
            environmentDigest: environmentDigest,
            processGeneration: processGeneration,
            processIdentifier: processIdentifier ?? self.processIdentifier,
            processGroupIdentifier: processGroupIdentifier ?? self.processGroupIdentifier,
            trustedProcessStartTime: trustedProcessStartTime ?? self.trustedProcessStartTime,
            state: state ?? self.state,
            settlement: settlement ?? self.settlement,
            preparedAt: preparedAt,
            startedAt: startedAt ?? self.startedAt,
            finishedAt: finishedAt ?? self.finishedAt,
            updatedAt: updatedAt,
            businessResultCommitted: businessResultCommitted ?? self.businessResultCommitted,
            treeExited: treeExited ?? self.treeExited,
            exitCode: exitCode ?? self.exitCode,
            failureReason: failureReason ?? self.failureReason
        )
    }
}

public struct LocalAgentMaintenanceReconciliationEvidence: Equatable, Sendable {
    public let processGenerationMatches: Bool
    public let processGroupExited: Bool
    public let businessResultCommitted: Bool
    public let processWasIsolated: Bool

    public init(
        processGenerationMatches: Bool,
        processGroupExited: Bool,
        businessResultCommitted: Bool,
        processWasIsolated: Bool = false
    ) {
        self.processGenerationMatches = processGenerationMatches
        self.processGroupExited = processGroupExited
        self.businessResultCommitted = businessResultCommitted
        self.processWasIsolated = processWasIsolated
    }
}

public protocol LocalAgentMaintenanceProcessJournalReading: AnyObject {
    func entries() throws -> [LocalAgentMaintenanceProcessJournalEntry]
    func entry(referenceID: String) throws -> LocalAgentMaintenanceProcessJournalEntry?
}

public protocol LocalAgentMaintenanceProcessJournaling: LocalAgentMaintenanceProcessJournalReading {
    @discardableResult
    func prepare(
        referenceID: String,
        operationID: String,
        configurationID: String,
        action: LocalAgentMaintenanceAction,
        executablePath: String,
        executableIdentityDigest: String,
        environmentDigest: String,
        processGeneration: Int64?
    ) throws -> LocalAgentMaintenanceProcessJournalEntry

    @discardableResult
    func transition(
        referenceID: String,
        event: LocalAgentSettingsProcessEvent,
        processIdentifier: Int32?,
        processGroupIdentifier: Int32?,
        trustedProcessStartTime: Date?,
        exitCode: Int32?,
        failureReason: String?
    ) throws -> LocalAgentMaintenanceProcessJournalEntry

    @discardableResult
    func reconcile(
        referenceID: String,
        evidence: LocalAgentMaintenanceReconciliationEvidence
    ) throws -> LocalAgentMaintenanceProcessJournalEntry
}

public extension LocalAgentMaintenanceProcessJournaling {
    @discardableResult
    func transition(
        referenceID: String,
        event: LocalAgentSettingsProcessEvent,
        processIdentifier: Int32? = nil,
        processGroupIdentifier: Int32? = nil,
        exitCode: Int32? = nil,
        failureReason: String? = nil
    ) throws -> LocalAgentMaintenanceProcessJournalEntry {
        try transition(
            referenceID: referenceID,
            event: event,
            processIdentifier: processIdentifier,
            processGroupIdentifier: processGroupIdentifier,
            trustedProcessStartTime: nil,
            exitCode: exitCode,
            failureReason: failureReason
        )
    }
}

private struct LocalAgentMaintenanceProcessJournalEnvelope: Codable {
    let schemaVersion: Int
    let entries: [LocalAgentMaintenanceProcessJournalEntry]
}

/// Atomic, process-safe JSON journal for Settings-only Local Agent launches.
/// The journal is intentionally independent of Conversation/Target/Effect
/// stores because detect/login have no workspace or target binding.
public final class LocalAgentMaintenanceProcessJournalStore: @unchecked Sendable {
    private static let processFileLock = NSLock()

    private let fileURL: URL
    private let lockFileURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private let now: () -> Date

    public init(
        fileURL: URL,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) throws {
        let path = fileURL.standardizedFileURL.path
        guard fileURL.isFileURL,
              path.hasPrefix("/"),
              path == fileURL.path,
              !path.hasSuffix("/")
        else {
            throw LocalAgentMaintenanceProcessJournalStoreError.invalidPath
        }
        self.fileURL = fileURL
        lockFileURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".\(fileURL.lastPathComponent).lock")
        self.fileManager = fileManager
        self.now = now
        try Self.prepareDirectory(for: fileURL, fileManager: fileManager)

        lock.lock()
        defer { lock.unlock() }
        try withExclusiveFileLock {
            let entries = try readLocked()
            let recovered = entries.map { entry -> LocalAgentMaintenanceProcessJournalEntry in
                guard !entry.state.isTerminal else { return entry }
                return entry.replacing(
                    state: .stateUnknown,
                    settlement: .unknown,
                    updatedAt: now(),
                    failureReason: .some("reopened_after_crash")
                )
            }
            if recovered != entries {
                try writeLocked(recovered)
            }
        }
    }

    public func entries() throws -> [LocalAgentMaintenanceProcessJournalEntry] {
        lock.lock()
        defer { lock.unlock() }
        return try withExclusiveFileLock { try readLocked() }
    }

    public func entry(referenceID: String) throws -> LocalAgentMaintenanceProcessJournalEntry? {
        try entries().first { $0.referenceID == referenceID }
    }

    /// Creates the durable `prepared` record before any process is started.
    @discardableResult
    public func prepare(
        referenceID: String,
        operationID: String,
        configurationID: String,
        action: LocalAgentMaintenanceAction,
        executablePath: String,
        executableIdentityDigest: String,
        environmentDigest: String,
        processGeneration: Int64? = nil
    ) throws -> LocalAgentMaintenanceProcessJournalEntry {
        lock.lock()
        defer { lock.unlock() }
        return try withExclusiveFileLock {
            var current = try readLocked()
            if let existing = current.first(where: {
                $0.referenceID == referenceID || $0.operationID == operationID
            }) {
                guard existing.referenceID == referenceID,
                      existing.operationID == operationID,
                      existing.configurationID == configurationID,
                      existing.action == action,
                      existing.executablePath == executablePath,
                      existing.executableIdentityDigest == executableIdentityDigest,
                      existing.environmentDigest == environmentDigest,
                      processGeneration.map({ $0 == existing.processGeneration }) ?? true
                else {
                    throw LocalAgentMaintenanceProcessJournalStoreError.duplicateOperation(operationID)
                }
                return existing
            }
            let nextGeneration: Int64
            if let processGeneration {
                nextGeneration = processGeneration
            } else {
                let maximum = current.map(\.processGeneration).max() ?? 0
                guard maximum < Int64.max else {
                    throw LocalAgentMaintenanceProcessJournalStoreError.invalidEntry(referenceID)
                }
                nextGeneration = maximum + 1
            }
            guard current.allSatisfy({ $0.processGeneration != nextGeneration }) else {
                throw LocalAgentMaintenanceProcessJournalStoreError.duplicateOperation(
                    "process-generation-\(nextGeneration)"
                )
            }
            let timestamp = now()
            let candidate = try validatedEntry(
                .init(
                    referenceID: referenceID,
                    operationID: operationID,
                    configurationID: configurationID,
                    action: action,
                    executablePath: executablePath,
                    executableIdentityDigest: executableIdentityDigest,
                    environmentDigest: environmentDigest,
                    processGeneration: nextGeneration,
                    preparedAt: timestamp,
                    updatedAt: timestamp
                )
            )
            current.append(candidate)
            try writeLocked(current)
            return candidate
        }
    }

    /// Applies one closed state-machine event and persists the result atomically.
    @discardableResult
    public func transition(
        referenceID: String,
        event: LocalAgentSettingsProcessEvent,
        processIdentifier: Int32? = nil,
        processGroupIdentifier: Int32? = nil,
        trustedProcessStartTime: Date? = nil,
        exitCode: Int32? = nil,
        failureReason: String? = nil
    ) throws -> LocalAgentMaintenanceProcessJournalEntry {
        lock.lock()
        defer { lock.unlock() }
        return try withExclusiveFileLock {
            var current = try readLocked()
            guard let index = current.firstIndex(where: { $0.referenceID == referenceID }) else {
                throw LocalAgentMaintenanceProcessJournalStoreError.missingReference(referenceID)
            }
            let old = current[index]
            guard let destination = LocalAgentSettingsProcessJournal.destination(from: old.state, event: event) else {
                throw LocalAgentMaintenanceProcessJournalStoreError.invalidTransition(
                    referenceID: referenceID,
                    state: old.state,
                    event: String(describing: event)
                )
            }
            let anyProcessIdentitySupplied = processIdentifier != nil
                || processGroupIdentifier != nil
                || trustedProcessStartTime != nil
            let suppliesProcessIdentity: Bool
            switch event {
            case .processStarted:
                suppliesProcessIdentity = true
            case .settlementUnknown where anyProcessIdentitySupplied:
                suppliesProcessIdentity = true
            default:
                suppliesProcessIdentity = false
            }
            if suppliesProcessIdentity {
                guard let processIdentifier, processIdentifier > 0,
                      let processGroupIdentifier, processGroupIdentifier > 0,
                      let trustedProcessStartTime,
                      trustedProcessStartTime.timeIntervalSince1970 > 0
                else {
                    throw LocalAgentMaintenanceProcessJournalStoreError.missingProcessIdentity(referenceID)
                }
            } else if anyProcessIdentitySupplied {
                throw LocalAgentMaintenanceProcessJournalStoreError.invalidEntry(referenceID)
            }
            let timestamp = now()
            let started = suppliesProcessIdentity ? old.startedAt ?? timestamp : old.startedAt
            let terminal = destination.isTerminal
            let settlement: LocalAgentSettingsProcessSettlement
            switch destination {
            case .completed:
                settlement = .exited
            case .isolated:
                settlement = .isolated
            case .stateUnknown:
                settlement = .unknown
            case .failed, .cancelled:
                settlement = .exited
            default:
                settlement = old.settlement == .unknown ? .pending : old.settlement
            }
            let updated = old.replacing(
                state: destination,
                settlement: settlement,
                processIdentifier: processIdentifier.map(Optional.some),
                processGroupIdentifier: processGroupIdentifier.map(Optional.some),
                trustedProcessStartTime: trustedProcessStartTime.map(Optional.some),
                startedAt: started.map(Optional.some),
                finishedAt: terminal ? .some(timestamp) : nil,
                updatedAt: timestamp,
                businessResultCommitted: old.businessResultCommitted || Self.businessResultCommitted(event),
                treeExited: old.treeExited || Self.isTreeExited(event),
                exitCode: exitCode.map(Optional.some),
                failureReason: failureReason.map(Optional.some)
            )
            current[index] = try validatedEntry(updated)
            try writeLocked(current)
            return current[index]
        }
    }

    /// Reconciles a `stateUnknown` record only when OS/process-generation and
    /// business evidence are explicit. No PID/EOF shortcut can settle it.
    @discardableResult
    public func reconcile(
        referenceID: String,
        evidence: LocalAgentMaintenanceReconciliationEvidence
    ) throws -> LocalAgentMaintenanceProcessJournalEntry {
        lock.lock()
        defer { lock.unlock() }
        return try withExclusiveFileLock {
            var current = try readLocked()
            guard let index = current.firstIndex(where: { $0.referenceID == referenceID }) else {
                throw LocalAgentMaintenanceProcessJournalStoreError.missingReference(referenceID)
            }
            let old = current[index]
            guard old.state == .stateUnknown else {
                throw LocalAgentMaintenanceProcessJournalStoreError.invalidTransition(
                    referenceID: referenceID,
                    state: old.state,
                    event: "reconcile"
                )
            }
            guard evidence.processGenerationMatches, evidence.processGroupExited else {
                throw LocalAgentMaintenanceProcessJournalStoreError.insufficientReconciliationEvidence(referenceID)
            }
            let event: LocalAgentSettingsProcessEvent
            if evidence.businessResultCommitted {
                event = .reconcileSucceeded
            } else if evidence.processWasIsolated {
                event = .reconcileIsolated
            } else {
                throw LocalAgentMaintenanceProcessJournalStoreError.insufficientReconciliationEvidence(referenceID)
            }
            guard let destination = LocalAgentSettingsProcessJournal.destination(from: old.state, event: event) else {
                throw LocalAgentMaintenanceProcessJournalStoreError.invalidTransition(
                    referenceID: referenceID,
                    state: old.state,
                    event: String(describing: event)
                )
            }
            let timestamp = now()
            let updated = old.replacing(
                state: destination,
                settlement: destination == .isolated ? .isolated : .exited,
                finishedAt: .some(timestamp),
                updatedAt: timestamp,
                businessResultCommitted: old.businessResultCommitted || evidence.businessResultCommitted,
                treeExited: true
            )
            current[index] = try validatedEntry(updated)
            try writeLocked(current)
            return current[index]
        }
    }

    private func readLocked() throws -> [LocalAgentMaintenanceProcessJournalEntry] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: fileURL)
            let envelope = try JSONDecoder().decode(
                LocalAgentMaintenanceProcessJournalEnvelope.self,
                from: data
            )
            guard envelope.schemaVersion == LocalAgentMaintenanceProcessJournalEntry.schemaVersion else {
                throw LocalAgentMaintenanceProcessJournalStoreError.corruptJournal
            }
            let entries = try envelope.entries.map(validatedEntry)
            guard Set(entries.map(\.referenceID)).count == entries.count,
                  Set(entries.map(\.operationID)).count == entries.count,
                  Set(entries.map(\.processGeneration)).count == entries.count
            else {
                throw LocalAgentMaintenanceProcessJournalStoreError.corruptJournal
            }
            return entries
        } catch let error as LocalAgentMaintenanceProcessJournalStoreError {
            throw error
        } catch {
            throw LocalAgentMaintenanceProcessJournalStoreError.corruptJournal
        }
    }

    private func writeLocked(_ entries: [LocalAgentMaintenanceProcessJournalEntry]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(
                LocalAgentMaintenanceProcessJournalEnvelope(
                    schemaVersion: LocalAgentMaintenanceProcessJournalEntry.schemaVersion,
                    entries: entries
                )
            )
        } catch {
            throw LocalAgentMaintenanceProcessJournalStoreError.atomicWriteFailed("encode")
        }

        let temporaryURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporaryURL, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: temporaryURL.path
            )
            if fileManager.fileExists(atPath: fileURL.path) {
                _ = try fileManager.replaceItemAt(fileURL, withItemAt: temporaryURL)
            } else {
                try fileManager.moveItem(at: temporaryURL, to: fileURL)
            }
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: fileURL.path
            )
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw LocalAgentMaintenanceProcessJournalStoreError.atomicWriteFailed("replace")
        }
    }

    private func validatedEntry(
        _ entry: LocalAgentMaintenanceProcessJournalEntry
    ) throws -> LocalAgentMaintenanceProcessJournalEntry {
        guard entry.schemaVersion == LocalAgentMaintenanceProcessJournalEntry.schemaVersion,
              validIdentifier(entry.referenceID),
              validIdentifier(entry.operationID),
              validIdentifier(entry.configurationID),
              entry.processGeneration > 0,
              entry.executablePath.hasPrefix("/"),
              URL(fileURLWithPath: entry.executablePath).standardizedFileURL.path == entry.executablePath,
              LocalAgentConfigurationIntegrity.isSHA256Digest(entry.executableIdentityDigest),
              LocalAgentConfigurationIntegrity.isSHA256Digest(entry.environmentDigest),
              entry.processIdentifier.map({ $0 > 0 }) ?? true,
              entry.processGroupIdentifier.map({ $0 > 0 }) ?? true,
              (entry.processIdentifier == nil) == (entry.processGroupIdentifier == nil),
              entry.trustedProcessStartTime.map({ $0.timeIntervalSince1970 > 0 }) ?? true,
              (entry.processIdentifier == nil) == (entry.trustedProcessStartTime == nil),
              entry.preparedAt <= entry.updatedAt,
              entry.startedAt.map({ entry.preparedAt <= $0 && $0 <= entry.updatedAt }) ?? true,
              entry.finishedAt.map({ entry.preparedAt <= $0 && $0 <= entry.updatedAt }) ?? true,
              entry.failureReason.map(validReasonCode) ?? true,
              validStateInvariants(entry)
        else {
            throw LocalAgentMaintenanceProcessJournalStoreError.invalidEntry(entry.referenceID)
        }
        return entry
    }

    private static func prepareDirectory(
        for fileURL: URL,
        fileManager: FileManager
    ) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: directory.path
        )
    }

    private static func isTreeExited(_ event: LocalAgentSettingsProcessEvent) -> Bool {
        switch event {
        case .treeExited, .treeExitedCancelled, .treeExitedFailed:
            return true
        default:
            return false
        }
    }

    private static func businessResultCommitted(_ event: LocalAgentSettingsProcessEvent) -> Bool {
        if case .treeExited(businessResultCommitted: true) = event { return true }
        return false
    }

    private func validStateInvariants(_ entry: LocalAgentMaintenanceProcessJournalEntry) -> Bool {
        switch entry.state {
        case .prepared, .starting:
            return entry.processIdentifier == nil
                && entry.startedAt == nil
                && entry.finishedAt == nil
                && entry.settlement == .pending
                && !entry.treeExited
                && !entry.businessResultCommitted
        case .running, .stopping:
            return entry.processIdentifier != nil
                && entry.startedAt != nil
                && entry.finishedAt == nil
                && entry.settlement == .pending
                && !entry.treeExited
                && !entry.businessResultCommitted
        case .stateUnknown:
            return entry.finishedAt == nil && entry.settlement == .unknown
        case .completed:
            return entry.finishedAt != nil
                && entry.settlement == .exited
                && entry.treeExited
                && entry.businessResultCommitted
        case .failed, .cancelled:
            return entry.finishedAt != nil && entry.settlement == .exited
        case .isolated:
            return entry.finishedAt != nil
                && entry.settlement == .isolated
                && entry.treeExited
        }
    }

    private func validReasonCode(_ value: String) -> Bool {
        validIdentifier(value)
    }

    private func withExclusiveFileLock<T>(_ body: () throws -> T) throws -> T {
        Self.processFileLock.lock()
        defer { Self.processFileLock.unlock() }

        let descriptor = Darwin.open(lockFileURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw LocalAgentMaintenanceProcessJournalStoreError.atomicWriteFailed("lock-open")
        }
        defer { Darwin.close(descriptor) }
        _ = Darwin.fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR))
        var fileLock = Darwin.flock(
            l_start: 0,
            l_len: 0,
            l_pid: 0,
            l_type: Int16(F_WRLCK),
            l_whence: Int16(SEEK_SET)
        )
        guard Darwin.fcntl(descriptor, F_SETLKW, &fileLock) == 0 else {
            throw LocalAgentMaintenanceProcessJournalStoreError.atomicWriteFailed("lock-claim")
        }
        defer {
            fileLock.l_type = Int16(F_UNLCK)
            _ = Darwin.fcntl(descriptor, F_SETLK, &fileLock)
        }
        return try body()
    }

    private func validIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 160 else { return false }
        return value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0)
                || (97...122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95
        }
    }
}

extension LocalAgentMaintenanceProcessJournalStore: LocalAgentMaintenanceProcessJournaling {}

public enum LocalAgentMaintenanceProcessJournalLiveStore {
    private static let lock = NSLock()
    private static var cachedStore: LocalAgentMaintenanceProcessJournalStore?

    public static func shared() throws -> LocalAgentMaintenanceProcessJournalStore {
        lock.lock()
        defer { lock.unlock() }
        if let cachedStore { return cachedStore }
        let paths = try StacioPaths()
        let store = try LocalAgentMaintenanceProcessJournalStore(
            fileURL: paths.applicationSupportDirectory
                .appendingPathComponent("local-agent-maintenance-journal-v1.json")
        )
        cachedStore = store
        return store
    }

    public static func sharedIfAvailable() -> LocalAgentMaintenanceProcessJournalStore? {
        try? shared()
    }
}
