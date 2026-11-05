import AppKit
import StacioCoreBindings
@testable import StacioApp
import XCTest

@MainActor
final class CredentialManagerViewControllerTests: XCTestCase {
    func testSearchFiltersLocallyAndDeleteUsesSelectedCredentialID() {
        let defaults = makeDefaults()
        let store = CredentialManagerRecordingStore(credentials: [
            credential(id: "cred-prod", kind: "password", label: "Production", account: "root@prod"),
            credential(id: "cred-token", kind: "token", label: "API Token", account: "deploy@api"),
        ])
        let controller = makeController(store: store, defaults: defaults)
        controller.loadView()

        controller.setSearchQueryForTesting("prod")

        XCTAssertEqual(controller.visibleCredentialsForTesting.map(\.id), ["cred-prod"])

        controller.selectCredentialForTesting(id: "cred-prod")
        controller.deleteSelectedCredentialForTesting()

        XCTAssertEqual(store.deletedIDs, ["cred-prod"])
        XCTAssertTrue(controller.visibleCredentialsForTesting.isEmpty)
    }

    func testSavedCredentialUsesPersistentStoreCreationTime() {
        let defaults = makeDefaults()
        let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)
        let store = CredentialManagerRecordingStore(credentials: [])
        store.creationDates = ["cred-saved-1": fixedDate]
        let controller = CredentialManagerViewController(
            store: store,
            defaults: defaults,
            backgroundExecutor: { $0() },
            mainExecutor: { $0() }
        )
        controller.loadView()

        controller.saveCredentialForTesting(
            kind: "password",
            label: "Production",
            account: "root@prod",
            secret: "secret-value"
        )

        XCTAssertEqual(store.saved.count, 1)
        XCTAssertEqual(controller.visibleCredentialsForTesting.map(\.id), ["cred-saved-1"])
        let createdAt = defaults.dictionary(forKey: "stacio.credentialCenter.createdAt") as? [String: String]
        XCTAssertEqual(
            createdAt?["cred-saved-1"],
            ISO8601DateFormatter().string(from: fixedDate)
        )
    }

    func testSavedCredentialDoesNotSynthesizeCreationTimeWhenMetadataReadFails() {
        let defaults = makeDefaults()
        let store = CredentialManagerRecordingStore(credentials: [])
        store.creationDatesError = CredentialMetadataTestError.failed
        let controller = makeController(store: store, defaults: defaults)
        controller.loadView()

        controller.saveCredentialForTesting(
            kind: "password",
            label: "Production",
            account: "root@prod",
            secret: "secret-value"
        )

        let createdAt = defaults.dictionary(forKey: "stacio.credentialCenter.createdAt") as? [String: String]
        XCTAssertNil(createdAt?["cred-saved-1"])
    }

    func testCopiedSecretClearsAfterDelayOnlyWhenPasteboardIsUnchanged() {
        let defaults = makeDefaults()
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("StacioCredentialManagerTests-\(UUID().uuidString)")
        )
        defer { pasteboard.clearContents() }
        let record = credential(
            id: "cred-copy",
            kind: "token",
            label: "API Token",
            account: "deploy@api"
        )
        let controller = CredentialManagerViewController(
            store: CredentialManagerRecordingStore(credentials: [record]),
            secretReader: { _ in "copied-secret" },
            defaults: defaults,
            pasteboard: pasteboard,
            clipboardClearDelay: 0.01,
            backgroundExecutor: { $0() },
            mainExecutor: { $0() }
        )
        controller.loadView()
        controller.selectCredentialForTesting(id: record.id)

        controller.copySelectedSecretForTesting()

        XCTAssertEqual(pasteboard.string(forType: .string), "copied-secret")
        let cleared = expectation(description: "credential pasteboard cleared")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            XCTAssertNil(pasteboard.string(forType: .string))
            cleared.fulfill()
        }
        wait(for: [cleared], timeout: 1)
    }

    func testNewestCopyRequestWinsWhenSecretReadsFinishOutOfOrder() {
        let defaults = makeDefaults()
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("StacioCredentialCopyOrderTests-\(UUID().uuidString)")
        )
        defer { pasteboard.clearContents() }
        let first = credential(id: "cred-first", kind: "token", label: "First", account: "first")
        let second = credential(id: "cred-second", kind: "token", label: "Second", account: "second")
        let executor = ManualCredentialManagerExecutor()
        let controller = CredentialManagerViewController(
            store: CredentialManagerRecordingStore(credentials: [first, second]),
            secretReader: { record in "secret-\(record.id)" },
            defaults: defaults,
            pasteboard: pasteboard,
            clipboardClearDelay: 60,
            backgroundExecutor: executor.execute,
            mainExecutor: { $0() }
        )
        controller.loadView()
        executor.runNext()

        controller.selectCredentialForTesting(id: first.id)
        controller.copySelectedSecretForTesting()
        controller.selectCredentialForTesting(id: second.id)
        controller.copySelectedSecretForTesting()

        XCTAssertEqual(executor.pendingCount, 2)
        guard executor.pendingCount == 2 else { return }
        executor.runLast()
        XCTAssertEqual(pasteboard.string(forType: .string), "secret-cred-second")
        executor.runNext()
        XCTAssertEqual(pasteboard.string(forType: .string), "secret-cred-second")
    }

    func testPendingCopyRequestCannotWritePasteboardAfterViewDisappears() {
        let defaults = makeDefaults()
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("StacioCredentialCopyDismissTests-\(UUID().uuidString)")
        )
        defer { pasteboard.clearContents() }
        let record = credential(id: "cred-dismissed", kind: "token", label: "Dismissed", account: "dismissed")
        let executor = ManualCredentialManagerExecutor()
        let controller = CredentialManagerViewController(
            store: CredentialManagerRecordingStore(credentials: [record]),
            secretReader: { _ in "secret-after-dismissal" },
            defaults: defaults,
            pasteboard: pasteboard,
            clipboardClearDelay: 60,
            backgroundExecutor: executor.execute,
            mainExecutor: { $0() }
        )
        controller.loadView()
        executor.runNext()
        controller.selectCredentialForTesting(id: record.id)
        controller.copySelectedSecretForTesting()

        controller.viewWillDisappear()
        XCTAssertEqual(executor.pendingCount, 1)
        guard executor.pendingCount == 1 else { return }
        executor.runNext()

        XCTAssertNil(pasteboard.string(forType: .string))
    }

    func testCopiedSecretIsClearedImmediatelyWhenViewDisappears() {
        let defaults = makeDefaults()
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("StacioCredentialCopyCloseTests-\(UUID().uuidString)")
        )
        defer { pasteboard.clearContents() }
        let record = credential(
            id: "cred-close",
            kind: "token",
            label: "Close",
            account: "close"
        )
        let controller = CredentialManagerViewController(
            store: CredentialManagerRecordingStore(credentials: [record]),
            secretReader: { _ in "secret-before-close" },
            defaults: defaults,
            pasteboard: pasteboard,
            clipboardClearDelay: 60,
            backgroundExecutor: { $0() },
            mainExecutor: { $0() }
        )
        controller.loadView()
        controller.selectCredentialForTesting(id: record.id)
        controller.copySelectedSecretForTesting()

        XCTAssertEqual(pasteboard.string(forType: .string), "secret-before-close")
        controller.viewWillDisappear()

        XCTAssertNil(pasteboard.string(forType: .string))
    }

    func testClosingCredentialViewDoesNotClearNewerPasteboardCopy() {
        let defaults = makeDefaults()
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("StacioCredentialCopyOwnershipTests-\(UUID().uuidString)")
        )
        defer { pasteboard.clearContents() }
        let record = credential(
            id: "cred-ownership",
            kind: "token",
            label: "Ownership",
            account: "ownership"
        )
        let controller = CredentialManagerViewController(
            store: CredentialManagerRecordingStore(credentials: [record]),
            secretReader: { _ in "secret-owned-by-controller" },
            defaults: defaults,
            pasteboard: pasteboard,
            clipboardClearDelay: 60,
            backgroundExecutor: { $0() },
            mainExecutor: { $0() }
        )
        controller.loadView()
        controller.selectCredentialForTesting(id: record.id)
        controller.copySelectedSecretForTesting()
        pasteboard.clearContents()
        pasteboard.setString("copied-by-user", forType: .string)

        controller.viewWillDisappear()

        XCTAssertEqual(pasteboard.string(forType: .string), "copied-by-user")
    }

    private func makeController(
        store: CredentialCenterManaging,
        defaults: UserDefaults
    ) -> CredentialManagerViewController {
        CredentialManagerViewController(
            store: store,
            defaults: defaults,
            backgroundExecutor: { $0() },
            mainExecutor: { $0() }
        )
    }

    func testStaleAsyncReloadResultIsIgnored() {
        let defaults = makeDefaults()
        let store = CredentialManagerRecordingStore(credentials: [
            credential(id: "cred-old", kind: "password", label: "Old", account: "old")
        ])
        let executor = ManualCredentialManagerExecutor()
        let controller = CredentialManagerViewController(
            store: store,
            defaults: defaults,
            backgroundExecutor: executor.execute,
            mainExecutor: { $0() }
        )
        controller.loadView()
        // `loadView()` starts the initial async request. Consume it before
        // arranging the two out-of-order refreshes under test.
        XCTAssertEqual(executor.pendingCount, 1)
        executor.runNext()
        XCTAssertEqual(controller.visibleCredentialsForTesting.map(\.id), ["cred-old"])
        let oldCredentials = [
            credential(id: "cred-old", kind: "password", label: "Old", account: "old")
        ]
        let newCredentials = [
            credential(id: "cred-new", kind: "password", label: "New", account: "new")
        ]
        // The newer request is executed first to simulate out-of-order
        // completion, so it must consume the first queued result.
        store.queuedCredentialResults = [newCredentials, oldCredentials]
        controller.reloadCredentialsForPresentation()
        controller.reloadCredentialsForPresentation()
        XCTAssertEqual(executor.pendingCount, 2)
        executor.runLast()
        XCTAssertEqual(controller.visibleCredentialsForTesting.map(\.id), ["cred-new"])
        executor.runNext()
        XCTAssertEqual(controller.visibleCredentialsForTesting.map(\.id), ["cred-new"])
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "StacioCredentialManagerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }
}

private final class ManualCredentialManagerExecutor {
    private var operations: [() -> Void] = []

    var pendingCount: Int { operations.count }

    func execute(_ operation: @escaping () -> Void) {
        operations.append(operation)
    }

    func runNext() {
        operations.removeFirst()()
    }

    func runLast() {
        operations.removeLast()()
    }
}

private final class CredentialManagerRecordingStore: CredentialCenterManaging {
    struct Saved: Equatable {
        let kind: String
        let label: String
        let account: String
        let secret: String
    }

    private var credentials: [CredentialRecord]
    private(set) var deletedIDs: [String] = []
    private(set) var saved: [Saved] = []

    init(credentials: [CredentialRecord]) {
        self.credentials = credentials
    }

    var queuedCredentialResults: [[CredentialRecord]] = []
    var creationDates: [String: Date] = [:]
    var creationDatesError: Error?

    func listCredentials() throws -> [CredentialRecord] {
        if queuedCredentialResults.isEmpty == false {
            return queuedCredentialResults.removeFirst()
        }
        return credentials
    }

    func saveCredential(
        kind: String,
        label: String,
        account: String,
        secret: String
    ) throws -> CredentialRecord {
        saved.append(.init(kind: kind, label: label, account: account, secret: secret))
        let record = credential(
            id: "cred-saved-\(saved.count)",
            kind: kind,
            label: label,
            account: account
        )
        credentials.append(record)
        return record
    }

    func deleteCredential(id: String) throws {
        deletedIDs.append(id)
        credentials.removeAll { $0.id == id }
    }

    func credentialCreationDates() throws -> [String: Date] {
        if let creationDatesError { throw creationDatesError }
        return creationDates
    }
}

private enum CredentialMetadataTestError: Error {
    case failed
}

private func credential(
    id: String,
    kind: String,
    label: String,
    account: String
) -> CredentialRecord {
    CredentialRecord(
        id: id,
        kind: kind,
        label: label,
        keychainService: KeychainCredentialStore.serviceName,
        keychainAccount: account
    )
}
