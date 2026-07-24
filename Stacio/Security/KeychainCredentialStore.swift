import CryptoKit
import Foundation

public struct KeychainCredential: CustomStringConvertible, Equatable {
    public let id: String
    public let account: String
    public let secret: String

    public init(id: String, account: String, secret: String) {
        self.id = id
        self.account = account
        self.secret = secret
    }

    public var description: String {
        "KeychainCredential(id: \(id), account: \(account), secret: [redacted])"
    }
}

public enum KeychainCredentialError: Error, Equatable {
    case notFound
    case invalidSecretEncoding
    case accessDenied(Int32)
    case storageUnavailable(String)
    case invalidVaultFormat
    case cryptoFailure
}

public struct StacioCredentialStorageKey: Codable, Equatable, Hashable {
    public let service: String
    public let account: String
    public let id: String

    public init(service: String, account: String, id: String) {
        self.service = service
        self.account = account
        self.id = id
    }
}

public protocol KeychainBackend {
    func save(key: StacioCredentialStorageKey, secret: Data) throws
    func read(key: StacioCredentialStorageKey) throws -> Data
    func delete(key: StacioCredentialStorageKey) throws
}

public final class KeychainCredentialStore {
    public static let serviceName = "Stacio"
    public static let legacyServiceName = ["Port", "Desk"].joined()

    private let backend: KeychainBackend

    public init(backend: KeychainBackend = StacioFileCredentialBackend()) {
        self.backend = backend
    }

    public static func storageKey(for id: String, account: String) -> StacioCredentialStorageKey {
        StacioCredentialStorageKey(service: serviceName, account: account, id: id)
    }

    public static func legacyStorageKey(for id: String, account: String) -> StacioCredentialStorageKey {
        StacioCredentialStorageKey(service: legacyServiceName, account: account, id: id)
    }

    public func save(_ credential: KeychainCredential) throws {
        guard let secret = credential.secret.data(using: .utf8) else {
            throw KeychainCredentialError.invalidSecretEncoding
        }

        try backend.save(
            key: Self.storageKey(for: credential.id, account: credential.account),
            secret: secret
        )
    }

    public func readSecret(id: String, account: String) throws -> String {
        let key = Self.storageKey(for: id, account: account)
        let data: Data
        do {
            data = try backend.read(key: key)
        } catch KeychainCredentialError.notFound {
            let legacyKey = Self.legacyStorageKey(for: id, account: account)
            let legacyData = try backend.read(key: legacyKey)
            try backend.save(key: key, secret: legacyData)
            data = legacyData
        }
        guard let secret = String(data: data, encoding: .utf8) else {
            throw KeychainCredentialError.invalidSecretEncoding
        }
        return secret
    }

    public func delete(id: String, account: String) throws {
        var firstError: Error?
        for key in [
            Self.storageKey(for: id, account: account),
            Self.legacyStorageKey(for: id, account: account)
        ] {
            do {
                try backend.delete(key: key)
            } catch KeychainCredentialError.notFound {
                continue
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }
        if let firstError {
            throw firstError
        }
    }
}

public final class StacioFileCredentialBackend: KeychainBackend {
    public let directoryURL: URL
    public let vaultURL: URL
    public let keyURL: URL
    private let legacyDirectoryURL: URL?
    private let legacyVaultURL: URL?
    private let legacyKeyURL: URL?

    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let lock = NSLock()

    public init(
        directoryURL: URL = StacioFileCredentialBackend.defaultDirectoryURL(),
        legacyDirectoryURL: URL? = StacioFileCredentialBackend.defaultLegacyDirectoryURL(),
        fileManager: FileManager = .default
    ) {
        self.directoryURL = directoryURL
        self.vaultURL = directoryURL.appendingPathComponent("credentials.vault.json")
        self.keyURL = directoryURL.appendingPathComponent("credentials.vault.key")
        self.legacyDirectoryURL = legacyDirectoryURL
        self.legacyVaultURL = legacyDirectoryURL?.appendingPathComponent("credentials.vault.json")
        self.legacyKeyURL = legacyDirectoryURL?.appendingPathComponent("credentials.vault.key")
        self.fileManager = fileManager
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    public static func defaultDirectoryURL() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
        return appSupport
            .appendingPathComponent(StacioPaths.applicationSupportDirectoryName, isDirectory: true)
            .appendingPathComponent("CredentialVault", isDirectory: true)
    }

    public static func defaultLegacyDirectoryURL() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
        return appSupport
            .appendingPathComponent(StacioPaths.legacyApplicationSupportDirectoryName, isDirectory: true)
            .appendingPathComponent("CredentialVault", isDirectory: true)
    }

    public func save(key: StacioCredentialStorageKey, secret: Data) throws {
        try locked {
            let symmetricKey = try loadOrCreateVaultKey()
            var vault = try loadVault()
            vault.entries[storageIdentifier(for: key)] = try makeEntry(
                key: key,
                secret: secret,
                symmetricKey: symmetricKey
            )
            try saveVault(vault)
        }
    }

    public func read(key: StacioCredentialStorageKey) throws -> Data {
        try locked {
            let vault = try loadVault()
            guard let entry = vault.entries[storageIdentifier(for: key)] else {
                return try readLegacyFileCredential(key: key)
            }
            let symmetricKey = try loadOrCreateVaultKey()
            return try openEntry(entry, symmetricKey: symmetricKey)
        }
    }

    public func delete(key: StacioCredentialStorageKey) throws {
        try locked {
            var vault = try loadVault()
            vault.entries.removeValue(forKey: storageIdentifier(for: key))
            try saveVault(vault)
            try deleteLegacyFileCredential(key: key)
        }
    }

    private func deleteLegacyFileCredential(key: StacioCredentialStorageKey) throws {
        guard let legacyVaultURL,
              fileManager.fileExists(atPath: legacyVaultURL.path)
        else {
            return
        }
        var legacyVault = try loadVault(at: legacyVaultURL)
        guard legacyVault.entries.removeValue(forKey: storageIdentifier(for: key)) != nil else {
            return
        }
        try saveVault(legacyVault, at: legacyVaultURL)
    }

    private func readLegacyFileCredential(key: StacioCredentialStorageKey) throws -> Data {
        guard let legacyVaultURL,
              let legacyKeyURL,
              fileManager.fileExists(atPath: legacyVaultURL.path),
              fileManager.fileExists(atPath: legacyKeyURL.path)
        else {
            throw KeychainCredentialError.notFound
        }
        let legacyKey = try loadVaultKey(at: legacyKeyURL)
        let legacyVault = try loadVault(at: legacyVaultURL)
        guard let entry = legacyVault.entries[storageIdentifier(for: key)] else {
            throw KeychainCredentialError.notFound
        }
        return try openEntry(entry, symmetricKey: legacyKey)
    }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func loadOrCreateVaultKey() throws -> SymmetricKey {
        try ensureDirectory()
        if fileManager.fileExists(atPath: keyURL.path) {
            return try loadVaultKey(at: keyURL)
        }

        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        try writeData(keyData, to: keyURL)
        return key
    }

    private func loadVault() throws -> CredentialVault {
        try ensureDirectory()
        guard fileManager.fileExists(atPath: vaultURL.path) else {
            return CredentialVault(version: 1, entries: [:])
        }
        return try loadVault(at: vaultURL)
    }

    private func loadVaultKey(at url: URL) throws -> SymmetricKey {
        let data = try readData(at: url)
        guard data.count == 32 else {
            throw KeychainCredentialError.invalidVaultFormat
        }
        return SymmetricKey(data: data)
    }

    private func loadVault(at url: URL) throws -> CredentialVault {
        let data = try readData(at: url)
        do {
            let vault = try decoder.decode(CredentialVault.self, from: data)
            guard vault.version == 1 else {
                throw KeychainCredentialError.invalidVaultFormat
            }
            return vault
        } catch let error as KeychainCredentialError {
            throw error
        } catch {
            throw KeychainCredentialError.invalidVaultFormat
        }
    }

    private func saveVault(_ vault: CredentialVault) throws {
        try saveVault(vault, at: vaultURL)
    }

    private func saveVault(_ vault: CredentialVault, at url: URL) throws {
        do {
            try writeData(encoder.encode(vault), to: url)
        } catch let error as KeychainCredentialError {
            throw error
        } catch {
            throw KeychainCredentialError.storageUnavailable(error.localizedDescription)
        }
    }

    private func ensureDirectory() throws {
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
            try? fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: directoryURL.path
            )
        } catch {
            throw KeychainCredentialError.storageUnavailable(error.localizedDescription)
        }
    }

    private func readData(at url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url)
        } catch {
            throw KeychainCredentialError.storageUnavailable(error.localizedDescription)
        }
    }

    private func writeData(_ data: Data, to url: URL) throws {
        do {
            try data.write(to: url, options: [.atomic])
            try? fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: url.path
            )
        } catch {
            throw KeychainCredentialError.storageUnavailable(error.localizedDescription)
        }
    }

    private func makeEntry(
        key: StacioCredentialStorageKey,
        secret: Data,
        symmetricKey: SymmetricKey
    ) throws -> CredentialVaultEntry {
        do {
            let sealedBox = try AES.GCM.seal(secret, using: symmetricKey)
            guard let combined = sealedBox.combined else {
                throw KeychainCredentialError.cryptoFailure
            }
            return CredentialVaultEntry(
                service: key.service,
                account: key.account,
                id: key.id,
                sealedBox: combined.base64EncodedString()
            )
        } catch let error as KeychainCredentialError {
            throw error
        } catch {
            throw KeychainCredentialError.cryptoFailure
        }
    }

    private func openEntry(
        _ entry: CredentialVaultEntry,
        symmetricKey: SymmetricKey
    ) throws -> Data {
        guard let data = Data(base64Encoded: entry.sealedBox) else {
            throw KeychainCredentialError.invalidVaultFormat
        }
        do {
            let box = try AES.GCM.SealedBox(combined: data)
            return try AES.GCM.open(box, using: symmetricKey)
        } catch {
            throw KeychainCredentialError.cryptoFailure
        }
    }

    private func storageIdentifier(for key: StacioCredentialStorageKey) -> String {
        [
            key.service,
            key.account,
            key.id
        ]
        .map { Data($0.utf8).base64EncodedString() }
        .joined(separator: ".")
    }
}

public final class InMemoryKeychainBackend: KeychainBackend {
    private var storage: [StacioCredentialStorageKey: Data] = [:]

    public init() {}

    public func save(key: StacioCredentialStorageKey, secret: Data) throws {
        storage[key] = secret
    }

    public func read(key: StacioCredentialStorageKey) throws -> Data {
        guard let data = storage[key] else {
            throw KeychainCredentialError.notFound
        }
        return data
    }

    public func delete(key: StacioCredentialStorageKey) throws {
        storage.removeValue(forKey: key)
    }
}

private struct CredentialVault: Codable {
    var version: Int
    var entries: [String: CredentialVaultEntry]
}

private struct CredentialVaultEntry: Codable {
    var service: String
    var account: String
    var id: String
    var sealedBox: String
}
