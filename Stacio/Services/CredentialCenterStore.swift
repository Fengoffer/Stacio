import Foundation
import SQLite3
import StacioCoreBindings

public protocol CredentialCenterManaging {
    func listCredentials() throws -> [CredentialRecord]
    func saveCredential(kind: String, label: String, account: String, secret: String) throws -> CredentialRecord
    func deleteCredential(id: String) throws

    /// Returns true when a persisted session still points at this credential.
    /// The default keeps lightweight test/dummy stores source-compatible.
    func isCredentialInUse(id: String) throws -> Bool

    /// Returns database-backed creation timestamps when the store exposes them.
    /// The default keeps lightweight test/dummy stores source-compatible.
    func credentialCreationDates() throws -> [String: Date]
}

public extension CredentialCenterManaging {
    func isCredentialInUse(id: String) throws -> Bool { false }
    func credentialCreationDates() throws -> [String: Date] { [:] }
}

public enum CredentialCenterStoreError: LocalizedError, Equatable {
    case credentialInUse

    public var errorDescription: String? {
        switch self {
        case .credentialInUse:
            return "该凭证仍被会话使用，请先移除会话中的凭证引用。"
        }
    }
}

public struct CredentialCenterDeletionTransactionError: LocalizedError {
    public let primaryError: Error
    public let rollbackError: Error

    public init(primaryError: Error, rollbackError: Error) {
        self.primaryError = primaryError
        self.rollbackError = rollbackError
    }

    public var errorDescription: String? {
        "删除凭证失败，且密钥恢复也失败。请保留当前数据并重试。"
    }
}

public struct CoreBridgeCredentialCenterStore: CredentialCenterManaging {
    private let databasePath: String
    private let keychainStore: KeychainCredentialStore

    public init(
        databasePath: String,
        keychainStore: KeychainCredentialStore = KeychainCredentialStore()
    ) {
        self.databasePath = databasePath
        self.keychainStore = keychainStore
    }

    public static func defaultStore() -> CredentialCenterManaging? {
        guard let databasePath = try? StacioPaths().databaseURL.path else {
            return nil
        }
        return CoreBridgeCredentialCenterStore(databasePath: databasePath)
    }

    public func listCredentials() throws -> [CredentialRecord] {
        try CoreBridge.listCredentialRecords(databasePath: databasePath)
    }

    public func saveCredential(kind: String, label: String, account: String, secret: String) throws -> CredentialRecord {
        try KeychainSessionSidebarCredentialSaver(
            databasePath: databasePath,
            keychainStore: keychainStore
        ).saveCredential(
            kind: kind,
            label: label,
            account: account,
            secret: secret
        )
    }

    public func isCredentialInUse(id: String) throws -> Bool {
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedID.isEmpty == false else { return false }
        return try CredentialCenterSQLiteReader(path: databasePath)
            .isCredentialInUse(id: normalizedID)
    }

    public func credentialCreationDates() throws -> [String: Date] {
        try CredentialCenterSQLiteReader(path: databasePath).credentialCreationDates()
    }

    public func deleteCredential(id: String) throws {
        let reader = try CredentialCenterSQLiteReader(path: databasePath)
        guard let credentialSnapshot = try reader.credential(id: id) else {
            return
        }
        guard try reader.isCredentialInUse(id: id) == false else {
            throw CredentialCenterStoreError.credentialInUse
        }

        // Reading and decrypting a secret can be materially slower than the
        // metadata transaction. Capture it before BEGIN IMMEDIATE so unrelated
        // session and folder writes are not blocked by Keychain I/O.
        let existingSecret: String?
        do {
            existingSecret = try keychainStore.readSecret(
                id: credentialSnapshot.id,
                account: credentialSnapshot.keychainAccount
            )
        } catch KeychainCredentialError.notFound {
            existingSecret = nil
        }

        let transaction = try CredentialCenterSQLiteDeletionTransaction(path: databasePath)
        guard let record = try transaction.credential(id: id) else {
            try transaction.commit()
            return
        }
        guard try transaction.isCredentialInUse(id: id) == false else {
            throw CredentialCenterStoreError.credentialInUse
        }

        // Remove the secret before its database metadata so a successful delete
        // cannot leave an unreferenced credential in the Keychain.
        do {
            try keychainStore.delete(
                id: record.id,
                account: record.keychainAccount
            )
        } catch {
            try? transaction.rollback()
            if let existingSecret {
                do {
                    try keychainStore.save(
                        KeychainCredential(
                            id: record.id,
                            account: record.keychainAccount,
                            secret: existingSecret
                        )
                    )
                } catch let rollbackError {
                    throw CredentialCenterDeletionTransactionError(
                        primaryError: error,
                        rollbackError: rollbackError
                    )
                }
            }
            throw error
        }
        do {
            try transaction.deleteCredential(id: id)
            try transaction.commit()
        } catch {
            try? transaction.rollback()
            // Restore the secret when the metadata transaction fails so the
            // record remains usable and a retry cannot strand a partial delete.
            if let existingSecret {
                do {
                    try keychainStore.save(
                        KeychainCredential(
                            id: record.id,
                            account: record.keychainAccount,
                            secret: existingSecret
                        )
                    )
                } catch let rollbackError {
                    throw CredentialCenterDeletionTransactionError(
                        primaryError: error,
                        rollbackError: rollbackError
                    )
                }
            }
            throw error
        }
    }
}

private struct CredentialCenterSQLiteRecord {
    let id: String
    let keychainAccount: String
}

/// Keeps the reference check and metadata deletion in one SQLite write
/// transaction. A separate read followed by CoreBridge deletion leaves a
/// window in which another session can acquire the credential.
private final class CredentialCenterSQLiteDeletionTransaction {
    private let database: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private var isActive = false

    init(path: String) throws {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(
            path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK else {
            let message = database
                .flatMap { sqlite3_errmsg($0) }
                .map(String.init(cString:)) ?? "unknown"
            if let database { sqlite3_close(database) }
            throw NSError(
                domain: "Stacio.CredentialCenter.SQLite",
                code: Int(result),
                userInfo: [NSLocalizedDescriptionKey: "SQLite open failed: \(message)"]
            )
        }
        self.database = database
        do {
            try execute("PRAGMA foreign_keys = ON")
            try execute("PRAGMA busy_timeout = 5000")
            try execute("BEGIN IMMEDIATE")
            isActive = true
        } catch {
            sqlite3_close(database)
            throw error
        }
    }

    deinit {
        if isActive {
            sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
        }
        sqlite3_close(database)
    }

    func credential(id: String) throws -> CredentialCenterSQLiteRecord? {
        let statement = try prepare(
            "SELECT id, keychain_account FROM credentials WHERE id = ?1"
        )
        defer { sqlite3_finalize(statement) }
        try bind(id, to: 1, in: statement)
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return CredentialCenterSQLiteRecord(
                id: columnString(statement, index: 0),
                keychainAccount: columnString(statement, index: 1)
            )
        case SQLITE_DONE:
            return nil
        default:
            throw error("read credential")
        }
    }

    func isCredentialInUse(id: String) throws -> Bool {
        let statement = try prepare(
            "SELECT credential_id, config_json FROM sessions "
                + "WHERE credential_id = ?1 OR config_json IS NOT NULL"
        )
        defer { sqlite3_finalize(statement) }
        try bind(id, to: 1, in: statement)
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                if columnOptionalString(statement, index: 0)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) == id {
                    return true
                }
                let configJSON = columnOptionalString(statement, index: 1)
                if case let .manual(manual) = SSHProxyJumpConfigCodec.selection(from: configJSON),
                   manual.credentialID?.trimmingCharacters(in: .whitespacesAndNewlines) == id {
                    return true
                }
            case SQLITE_DONE:
                return false
            default:
                throw error("check credential references")
            }
        }
    }

    func deleteCredential(id: String) throws {
        let statement = try prepare("DELETE FROM credentials WHERE id = ?1")
        defer { sqlite3_finalize(statement) }
        try bind(id, to: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw error("delete credential")
        }
    }

    func commit() throws {
        guard isActive else { return }
        try execute("COMMIT")
        isActive = false
    }

    func rollback() throws {
        guard isActive else { return }
        try execute("ROLLBACK")
        isActive = false
    }

    private func execute(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &message)
        defer { sqlite3_free(message) }
        guard result == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? "unknown"
            throw NSError(
                domain: "Stacio.CredentialCenter.SQLite",
                code: Int(result),
                userInfo: [NSLocalizedDescriptionKey: "SQLite \(sql) failed: \(detail)"]
            )
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK else { throw error("prepare SQL") }
        return statement
    }

    private func bind(_ value: String, to index: Int32, in statement: OpaquePointer?) throws {
        let result = value.withCString { pointer in
            sqlite3_bind_text(statement, index, pointer, -1, transient)
        }
        guard result == SQLITE_OK else { throw error("bind SQL text") }
    }

    private func columnString(_ statement: OpaquePointer?, index: Int32) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: value)
    }

    private func columnOptionalString(_ statement: OpaquePointer?, index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return columnString(statement, index: index)
    }

    private func error(_ action: String) -> NSError {
        let message = database
            .flatMap { sqlite3_errmsg($0) }
            .map(String.init(cString:)) ?? "unknown"
        return NSError(
            domain: "Stacio.CredentialCenter.SQLite",
            code: Int(sqlite3_errcode(database)),
            userInfo: [NSLocalizedDescriptionKey: "SQLite \(action) failed: \(message)"]
        )
    }
}

private final class CredentialCenterSQLiteReader {
    private let database: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(
            path,
            &database,
            // The app database uses WAL mode. SQLite may need to create or
            // update the adjacent -shm file even for a SELECT-only reader;
            // READWRITE (without CREATE) avoids SQLITE_CANTOPEN on valid WAL
            // databases while this reader itself remains mutation-free.
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK else {
            let message = database
                .flatMap { sqlite3_errmsg($0) }
                .map(String.init(cString:)) ?? "unknown"
            if let database { sqlite3_close(database) }
            throw NSError(
                domain: "Stacio.CredentialCenter.SQLite",
                code: Int(result),
                userInfo: [NSLocalizedDescriptionKey: "SQLite open failed: \(message)"]
            )
        }
        self.database = database
    }

    deinit {
        sqlite3_close(database)
    }

    func credentialCreationDates() throws -> [String: Date] {
        let statement = try prepare("SELECT id, created_at FROM credentials")
        defer { sqlite3_finalize(statement) }
        var result: [String: Date] = [:]
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                let id = columnString(statement, index: 0)
                let timestamp = columnString(statement, index: 1)
                if let date = Self.date(from: timestamp) {
                    result[id] = date
                }
            case SQLITE_DONE:
                return result
            default:
                throw error("read credential creation dates")
            }
        }
    }

    func credential(id: String) throws -> CredentialCenterSQLiteRecord? {
        let statement = try prepare(
            "SELECT id, keychain_account FROM credentials WHERE id = ?"
        )
        defer { sqlite3_finalize(statement) }
        try bind(id, to: 1, in: statement)
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return CredentialCenterSQLiteRecord(
                id: columnString(statement, index: 0),
                keychainAccount: columnString(statement, index: 1)
            )
        case SQLITE_DONE:
            return nil
        default:
            throw error("read credential")
        }
    }

    func isCredentialInUse(id: String) throws -> Bool {
        let statement = try prepare(
            "SELECT credential_id, config_json FROM sessions "
                + "WHERE credential_id = ? OR config_json IS NOT NULL"
        )
        defer { sqlite3_finalize(statement) }
        try bind(id, to: 1, in: statement)
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                if columnOptionalString(statement, index: 0)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) == id {
                    return true
                }
                let configJSON = columnOptionalString(statement, index: 1)
                if case let .manual(manual) = SSHProxyJumpConfigCodec.selection(from: configJSON),
                   manual.credentialID?.trimmingCharacters(in: .whitespacesAndNewlines) == id {
                    return true
                }
            case SQLITE_DONE:
                return false
            default:
                throw error("check credential references")
            }
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK else { throw error("prepare SQL") }
        return statement
    }

    private func bind(_ value: String, to index: Int32, in statement: OpaquePointer?) throws {
        let result = value.withCString { pointer in
            sqlite3_bind_text(statement, index, pointer, -1, transient)
        }
        guard result == SQLITE_OK else { throw error("bind SQL text") }
    }

    private func columnString(_ statement: OpaquePointer?, index: Int32) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: value)
    }

    private func columnOptionalString(_ statement: OpaquePointer?, index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return columnString(statement, index: index)
    }

    private func error(_ action: String) -> NSError {
        let message = database
            .flatMap { sqlite3_errmsg($0) }
            .map(String.init(cString:)) ?? "unknown"
        return NSError(
            domain: "Stacio.CredentialCenter.SQLite",
            code: Int(sqlite3_errcode(database)),
            userInfo: [NSLocalizedDescriptionKey: "SQLite \(action) failed: \(message)"]
        )
    }

    private static func date(from timestamp: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: timestamp) ?? ISO8601DateFormatter().date(from: timestamp)
    }
}
