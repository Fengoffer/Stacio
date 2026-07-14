import Foundation
import Security

public enum LicenseKeychainError: Error, Equatable {
    case invalidStoredData
    case unexpectedStatus(OSStatus)
}

public struct LicenseActivationRecord: Codable, Equatable, CustomStringConvertible {
    public var licenseKey: String
    public var username: String
    public var email: String

    public init(licenseKey: String, username: String, email: String) {
        self.licenseKey = licenseKey
        self.username = username
        self.email = email
    }

    public var description: String {
        "LicenseActivationRecord(licenseKey: [redacted], username: \(username), email: \(email))"
    }
}

public protocol LicenseKeychainBackend: AnyObject {
    func save(_ data: Data, service: String, account: String) throws
    func read(service: String, account: String) throws -> Data?
    func delete(service: String, account: String) throws
}

public final class SystemLicenseKeychainBackend: LicenseKeychainBackend {
    public init() {}

    public func save(_ data: Data, service: String, account: String) throws {
        let query = baseQuery(service: service, account: account)
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            attributes.forEach { addQuery[$0.key] = $0.value }
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw LicenseKeychainError.unexpectedStatus(status)
        }
    }

    public func read(service: String, account: String) throws -> Data? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData] = kCFBooleanTrue
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw LicenseKeychainError.unexpectedStatus(status)
        }
        guard let data = result as? Data else {
            throw LicenseKeychainError.invalidStoredData
        }
        return data
    }

    public func delete(service: String, account: String) throws {
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw LicenseKeychainError.unexpectedStatus(status)
        }
    }

    private func baseQuery(service: String, account: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: kCFBooleanFalse as Any
        ]
    }
}

public protocol LicenseActivationRecordStoring: AnyObject {
    func loadActivationRecord() throws -> LicenseActivationRecord?
    func saveActivationRecord(_ record: LicenseActivationRecord) throws
    func deleteActivationRecord() throws
}

public protocol LegacyLicenseStateMigrating: AnyObject {
    func loadLegacyLicenseState() throws -> LicenseState?
    func deleteLegacyLicenseState() throws
}

public final class LicenseKeychainStore: LicenseStateStoring, LicenseActivationRecordStoring {
    public static let defaultService = "cn.stacio.product-ops.license"
    static let activationAccount = "activation"
    static let stateAccount = "state"

    private let backend: LicenseKeychainBackend
    private let service: String
    private let legacyStateStore: LegacyLicenseStateMigrating?

    public init(
        backend: LicenseKeychainBackend = SystemLicenseKeychainBackend(),
        service: String = LicenseKeychainStore.defaultService,
        legacyStateStore: LegacyLicenseStateMigrating? = nil
    ) {
        self.backend = backend
        self.service = service
        if let legacyStateStore {
            self.legacyStateStore = legacyStateStore
        } else if backend is SystemLicenseKeychainBackend,
                  service == LicenseKeychainStore.defaultService {
            self.legacyStateStore = KeychainLicenseStateStore()
        } else {
            self.legacyStateStore = nil
        }
    }

    public func loadActivationRecord() throws -> LicenseActivationRecord? {
        guard let data = try backend.read(service: service, account: Self.activationAccount) else {
            return nil
        }
        return try JSONDecoder.productOps.decode(LicenseActivationRecord.self, from: data)
    }

    public func saveActivationRecord(_ record: LicenseActivationRecord) throws {
        try backend.save(
            JSONEncoder.productOps.encode(record),
            service: service,
            account: Self.activationAccount
        )
    }

    public func deleteActivationRecord() throws {
        try backend.delete(service: service, account: Self.activationAccount)
    }

    public func load() throws -> LicenseState? {
        guard let data = try backend.read(service: service, account: Self.stateAccount) else {
            return try migrateLegacyStateIfNeeded()
        }
        return try JSONDecoder.productOps.decode(LicenseState.self, from: data)
    }

    public func save(_ state: LicenseState) throws {
        try backend.save(
            JSONEncoder.productOps.encode(state),
            service: service,
            account: Self.stateAccount
        )
    }

    public func deleteLicenseState() throws {
        try backend.delete(service: service, account: Self.stateAccount)
    }

    private func migrateLegacyStateIfNeeded() throws -> LicenseState? {
        guard let legacyStateStore,
              let state = try legacyStateStore.loadLegacyLicenseState() else {
            return nil
        }
        try save(state)
        try legacyStateStore.deleteLegacyLicenseState()
        return state
    }
}
