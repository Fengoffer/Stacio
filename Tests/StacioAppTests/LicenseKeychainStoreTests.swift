import Foundation
import XCTest
@testable import StacioApp

final class LicenseKeychainStoreTests: XCTestCase {
    func testEncryptedVaultBackendSurvivesRecreationWithoutWritingPlaintextLicenseData() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioLicenseVaultTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let activation = LicenseActivationRecord(
            licenseKey: "STACIO-SECRET-KEY",
            username: "Ada",
            email: "ada@example.com"
        )
        let state = LicenseState(
            username: activation.username,
            email: activation.email,
            signedLicenseToken: "v1.signed-payload.signature",
            plan: "professional",
            permissions: ["multi_exec"],
            expiresAt: Date(timeIntervalSince1970: 1_900_000_000),
            status: .active
        )
        let makeBackend = {
            EncryptedVaultLicenseBackend(
                backend: StacioFileCredentialBackend(
                    directoryURL: directory,
                    legacyDirectoryURL: nil
                )
            )
        }
        var store: LicenseKeychainStore? = LicenseKeychainStore(
            backend: makeBackend(),
            service: LicenseKeychainStore.defaultService
        )

        try store?.saveActivationRecord(activation)
        try store?.save(state)
        store = nil

        let restored = LicenseKeychainStore(
            backend: makeBackend(),
            service: LicenseKeychainStore.defaultService
        )
        XCTAssertEqual(try restored.loadActivationRecord(), activation)
        XCTAssertEqual(try restored.load(), state)

        let vaultData = try Data(contentsOf: directory.appendingPathComponent("credentials.vault.json"))
        let vaultText = try XCTUnwrap(String(data: vaultData, encoding: .utf8))
        XCTAssertFalse(vaultText.contains(activation.licenseKey))
        XCTAssertFalse(vaultText.contains(activation.username))
        XCTAssertFalse(vaultText.contains(activation.email))
        XCTAssertFalse(vaultText.contains(state.signedLicenseToken))
    }

    func testRoundTripsActivationRecordAndLicenseStateThroughSeparateAccounts() throws {
        let backend = InMemoryLicenseKeychainBackend()
        let store = LicenseKeychainStore(
            backend: backend,
            service: "cn.stacio.tests.license.\(UUID().uuidString)"
        )
        let activation = LicenseActivationRecord(
            licenseKey: "STACIO-SECRET-KEY",
            username: "Ada",
            email: "ada@example.com"
        )
        let state = LicenseState(
            username: activation.username,
            email: activation.email,
            signedLicenseToken: "v1.payload.signature",
            plan: "pro",
            permissions: ["remote_sessions"],
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
            graceUntil: Date(timeIntervalSince1970: 1_700_086_400),
            status: .active,
            lastValidatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        try store.saveActivationRecord(activation)
        try store.save(state)

        XCTAssertEqual(try store.loadActivationRecord(), activation)
        XCTAssertEqual(try store.load(), state)
        XCTAssertEqual(
            Set(backend.storedAccounts),
            [LicenseKeychainStore.activationAccount, LicenseKeychainStore.stateAccount]
        )
    }

    func testDeletesActivationRecordAndLicenseStateIndependently() throws {
        let backend = InMemoryLicenseKeychainBackend()
        let store = LicenseKeychainStore(
            backend: backend,
            service: "cn.stacio.tests.license.\(UUID().uuidString)"
        )
        try store.saveActivationRecord(LicenseActivationRecord(
            licenseKey: "STACIO-SECRET-KEY",
            username: "Ada",
            email: "ada@example.com"
        ))
        try store.save(LicenseState(
            username: "Ada",
            email: "ada@example.com",
            signedLicenseToken: "v1.payload.signature",
            status: .active
        ))

        try store.deleteActivationRecord()

        XCTAssertNil(try store.loadActivationRecord())
        XCTAssertNotNil(try store.load())

        try store.deleteLicenseState()

        XCTAssertNil(try store.load())
    }

    func testSystemBackendRoundTripsAndDeletesGenericPasswordItem() throws {
        let backend = SystemLicenseKeychainBackend()
        let service = "cn.stacio.tests.license.system.\(UUID().uuidString)"
        let account = "activation"
        let payload = Data("system-keychain-secret".utf8)
        defer {
            try? backend.delete(service: service, account: account)
        }

        try backend.save(payload, service: service, account: account)

        XCTAssertEqual(try backend.read(service: service, account: account), payload)

        try backend.delete(service: service, account: account)

        XCTAssertNil(try backend.read(service: service, account: account))
    }

    func testActivationRecordDescriptionRedactsLicenseKey() {
        let record = LicenseActivationRecord(
            licenseKey: "STACIO-SECRET-KEY",
            username: "Ada",
            email: "ada@example.com"
        )

        XCTAssertFalse(String(describing: record).contains(record.licenseKey))
        XCTAssertTrue(String(describing: record).contains("[redacted]"))
    }

    func testDefaultStoreWritesLicenseKeyOnlyToStableKeychainService() throws {
        let suiteName = "StacioLicenseKeychainDefaultsIsolationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let backend = InMemoryLicenseKeychainBackend()
        let store = LicenseKeychainStore(backend: backend)
        let record = LicenseActivationRecord(
            licenseKey: "STACIO-SECRET-KEY",
            username: "Ada",
            email: "ada@example.com"
        )

        try store.saveActivationRecord(record)

        XCTAssertEqual(try store.loadActivationRecord(), record)
        XCTAssertEqual(backend.storedServices, [LicenseKeychainStore.defaultService])
        XCTAssertTrue(defaults.persistentDomain(forName: suiteName)?.isEmpty ?? true)
        XCTAssertFalse(
            String(describing: defaults.persistentDomain(forName: suiteName)).contains(record.licenseKey)
        )
    }

    func testStateLoadMigratesLegacySecureStateAndDeletesSource() throws {
        let backend = InMemoryLicenseKeychainBackend()
        let legacyState = LicenseState(
            username: "Ada",
            email: "ada@example.com",
            signedLicenseToken: "v1.payload.signature",
            plan: "pro",
            permissions: ["remote_sessions"],
            expiresAt: Date(timeIntervalSince1970: 1_900_000_000),
            status: .active,
            lastValidatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let legacyStore = InMemoryLegacyLicenseStateStore(state: legacyState)
        let store = LicenseKeychainStore(
            backend: backend,
            service: LicenseKeychainStore.defaultService,
            legacyStateStore: legacyStore
        )

        XCTAssertEqual(try store.load(), legacyState)
        XCTAssertNil(legacyStore.state)
        XCTAssertEqual(legacyStore.deleteCount, 1)
        XCTAssertEqual(try store.load(), legacyState)
        XCTAssertEqual(legacyStore.loadCount, 1)
        XCTAssertEqual(backend.storedAccounts, [LicenseKeychainStore.stateAccount])
    }
}

private final class InMemoryLicenseKeychainBackend: LicenseKeychainBackend {
    private var values: [String: Data] = [:]
    private(set) var storedServices: Set<String> = []

    var storedAccounts: [String] {
        Array(values.keys)
    }

    func save(_ data: Data, service: String, account: String) throws {
        storedServices.insert(service)
        values[account] = data
    }

    func read(service: String, account: String) throws -> Data? {
        values[account]
    }

    func delete(service: String, account: String) throws {
        values.removeValue(forKey: account)
    }
}

private final class InMemoryLegacyLicenseStateStore: LegacyLicenseStateMigrating {
    var state: LicenseState?
    private(set) var loadCount = 0
    private(set) var deleteCount = 0

    init(state: LicenseState?) {
        self.state = state
    }

    func loadLegacyLicenseState() throws -> LicenseState? {
        loadCount += 1
        return state
    }

    func deleteLegacyLicenseState() throws {
        deleteCount += 1
        state = nil
    }
}
