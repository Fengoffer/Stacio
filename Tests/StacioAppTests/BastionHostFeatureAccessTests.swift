import XCTest
@testable import StacioApp

final class BastionHostFeatureAccessTests: XCTestCase {
    func testEveryLicensedFeatureMapsToItsProductionEntitlement() {
        let expected: [StacioLicensedFeature: String] = [
            .multiExec: "multi_exec",
            .aiAgent: "ai_agent",
            .bastionHost: "bastion_host",
            .sshTunnel: "ssh_tunnel",
            .advancedMetrics: "advanced_metrics",
            .fileSync: "file_sync",
            .proxyJump: "proxy_jump",
            .sessionBulkIO: "session_bulk_io"
        ]

        XCTAssertEqual(StacioLicensedFeature.allCases.count, expected.count)
        for (feature, entitlement) in expected {
            XCTAssertEqual(feature.entitlement, entitlement)
            XCTAssertTrue(makeState(
                plan: "custom",
                status: .offlineActive,
                permissions: [entitlement],
                expiresAt: .distantFuture
            ).enables(feature))
        }
    }

    func testEntitlementDoesNotUnlockOtherLicensedFeatures() {
        let state = makeState(
            plan: "professional",
            status: .offlineActive,
            permissions: [StacioLicenseEntitlement.aiAgent],
            expiresAt: .distantFuture
        )

        XCTAssertTrue(state.enables(.aiAgent))
        XCTAssertFalse(state.enables(.multiExec))
        XCTAssertFalse(state.enables(.bastionHost))
        XCTAssertFalse(state.enables(.sshTunnel))
        XCTAssertFalse(state.enables(.advancedMetrics))
        XCTAssertFalse(state.enables(.fileSync))
        XCTAssertFalse(state.enables(.proxyJump))
        XCTAssertFalse(state.enables(.sessionBulkIO))
    }

    func testInvalidExpiredAndRevokedStatesDisableEveryLicensedFeature() {
        let now = Date(timeIntervalSince1970: 1_000)
        let allEntitlements = StacioLicensedFeature.allCases.map(\.entitlement)
        for status in [LicenseStatus.inactive, .trial, .expired, .suspended, .revoked, .invalid] {
            let state = makeState(
                plan: "enterprise",
                status: status,
                permissions: allEntitlements,
                expiresAt: .distantFuture
            )
            XCTAssertTrue(StacioLicensedFeature.allCases.allSatisfy { state.enables($0, at: now) == false })
        }
        let expired = makeState(
            plan: "enterprise",
            status: .offlineActive,
            permissions: allEntitlements,
            expiresAt: now
        )
        XCTAssertTrue(StacioLicensedFeature.allCases.allSatisfy { expired.enables($0, at: now) == false })
    }

    func testGenericAuthorizerUsesCentralAccessProvider() throws {
        let provider = RecordingLicenseFeatureAccessProvider(enabledFeatures: [.multiExec])
        let authorizer = LicenseFeatureAuthorizer(accessProvider: provider)

        XCTAssertNoThrow(try authorizer.authorize(.multiExec))
        XCTAssertThrowsError(try authorizer.authorize(.aiAgent)) { error in
            XCTAssertEqual(error as? LicensedFeatureAccessError, .licenseRequired(.aiAgent))
        }
    }
    func testProfessionalAndEnterpriseFormalLicensesAllowBastionHostAccess() {
        let now = Date(timeIntervalSince1970: 1_000)
        for plan in ["pro", "professional", "enterprise"] {
            XCTAssertTrue(
                makeState(plan: plan, status: .active, expiresAt: now.addingTimeInterval(60))
                    .enables(.bastionHost, at: now)
            )
        }
    }

    func testPlanOnlyProfessionalAndEnterpriseLicensesUnlockAllCurrentFeatures() {
        let now = Date(timeIntervalSince1970: 1_000)
        for plan in ["pro", "professional", "team", "enterprise", "internal"] {
            let state = makeState(
                plan: plan,
                status: .active,
                expiresAt: now.addingTimeInterval(60)
            )

            XCTAssertTrue(
                StacioLicensedFeature.allCases.allSatisfy { state.enables($0, at: now) },
                "Expected plan-only \(plan) License to unlock every current licensed feature"
            )
        }
    }

    func testLegacyPlanBundleEntitlementsUnlockAllCurrentFeatures() {
        let now = Date(timeIntervalSince1970: 1_000)
        let cases = [
            (plan: "professional", permissions: ["pro_features"]),
            (plan: "enterprise", permissions: ["pro_features", "team_features"])
        ]

        for item in cases {
            let state = makeState(
                plan: item.plan,
                status: .active,
                permissions: item.permissions,
                expiresAt: now.addingTimeInterval(60)
            )
            XCTAssertTrue(
                StacioLicensedFeature.allCases.allSatisfy { state.enables($0, at: now) },
                "Expected \(item.plan) bundle markers to unlock every current licensed feature"
            )
        }
    }

    func testTrialAndInvalidLicensesNeverAllowBastionHostAccess() {
        for status in [LicenseStatus.inactive, .trial, .expired, .suspended, .revoked, .invalid] {
            XCTAssertFalse(
                makeState(plan: "enterprise", status: status, expiresAt: Date.distantFuture)
                    .enables(.bastionHost)
            )
        }
    }

    func testPersistedProfessionalLicenseUsesLocalExpirationWithoutOnlineRevalidation() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let state = makeState(
            plan: "professional",
            status: .networkUnavailable,
            expiresAt: now.addingTimeInterval(60)
        )
        var loadCount = 0
        let authorizer = LicenseBastionHostFeatureAuthorizer(
            stateProvider: {
                loadCount += 1
                return state
            },
            nowProvider: { now }
        )

        XCTAssertNoThrow(try authorizer.authorizeBastionHostAccess())
        XCTAssertEqual(loadCount, 1)
    }

    func testPersistedProfessionalLicenseIsRejectedAfterLocalExpiration() {
        let now = Date(timeIntervalSince1970: 1_000)
        let state = makeState(
            plan: "professional",
            status: .active,
            expiresAt: now
        )
        let authorizer = LicenseBastionHostFeatureAuthorizer(
            stateProvider: { state },
            nowProvider: { now }
        )

        XCTAssertThrowsError(try authorizer.authorizeBastionHostAccess())
    }

    @MainActor
    func testLocalFeatureAccessLoadsPersistedStateOffMainThread() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let probe = BlockingLicenseStateProvider(state: makeState(
            plan: "professional",
            status: .active,
            expiresAt: now.addingTimeInterval(60)
        ))
        let provider = LocalLicenseFeatureAccessProvider(
            stateProvider: { try probe.load() },
            nowProvider: { now }
        )
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            probe.release()
        }

        let initialValue = provider.isEnabled(.bastionHost)
        if initialValue {
            XCTFail("Feature access must not wait for a persisted-state read on the calling thread")
            XCTAssertEqual(probe.firstLoadWasOnMainThread, false)
            return
        }

        let deadline = Date().addingTimeInterval(1)
        while provider.isEnabled(.bastionHost) == false, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(probe.firstLoadWasOnMainThread, false)
        XCTAssertTrue(provider.isEnabled(.bastionHost))
    }

    @MainActor
    func testLocalFeatureAccessRetriesAfterInitialPersistedStateReadFailure() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let expectedState = makeState(
            plan: "professional",
            status: .active,
            expiresAt: now.addingTimeInterval(60)
        )
        let probe = ScriptedLicenseStateProvider(results: [
            .failure(LicenseStateProviderTestError.unavailable),
            .success(expectedState)
        ])
        let provider = LocalLicenseFeatureAccessProvider(
            stateProvider: { try probe.load() },
            nowProvider: { now }
        )

        XCTAssertFalse(provider.isEnabled(.bastionHost))

        let deadline = Date().addingTimeInterval(1)
        while provider.isEnabled(.bastionHost) == false, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(probe.loadCount, 2)
        XCTAssertTrue(provider.isEnabled(.bastionHost))
    }

    @MainActor
    func testLicenseSnapshotKeepsLastVerifiedStateWhenRefreshFails() async throws {
        let state = makeState(
            plan: "professional",
            status: .active,
            expiresAt: .distantFuture
        )
        let probe = ScriptedLicenseStateProvider(results: [
            .success(state),
            .failure(LicenseStateProviderTestError.unavailable)
        ])
        let snapshot = LicenseAuthorizationSnapshot(stateProvider: { try probe.load() })

        XCTAssertNil(snapshot.currentState())
        let initialDeadline = Date().addingTimeInterval(1)
        while snapshot.currentState() != state, Date() < initialDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        snapshot.refresh()
        let refreshDeadline = Date().addingTimeInterval(1)
        while probe.loadCount < 2, Date() < refreshDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(snapshot.currentState(), state)
    }

    @MainActor
    func testLicenseSnapshotDoesNotNotifyWhenRetryRestoresSameState() async throws {
        let state = makeState(
            plan: "professional",
            status: .active,
            expiresAt: .distantFuture
        )
        let probe = ScriptedLicenseStateProvider(results: [
            .success(state),
            .failure(LicenseStateProviderTestError.unavailable),
            .success(state)
        ])
        let snapshot = LicenseAuthorizationSnapshot(
            stateProvider: { try probe.load() },
            postsAuthorizationChanges: true
        )
        let notificationCount = LockedCounter()
        let observer = NotificationCenter.default.addObserver(
            forName: .stacioLicenseAuthorizationDidChange,
            object: nil,
            queue: .main
        ) { notification in
            guard (notification.object as AnyObject?) === snapshot else { return }
            notificationCount.increment()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        _ = snapshot.currentState()
        let initialDeadline = Date().addingTimeInterval(1)
        while notificationCount.value < 1, Date() < initialDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        snapshot.refresh()
        let failedRefreshDeadline = Date().addingTimeInterval(1)
        while probe.loadCount < 2, Date() < failedRefreshDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        _ = snapshot.currentState()
        let recoveryDeadline = Date().addingTimeInterval(1)
        while probe.loadCount < 3, Date() < recoveryDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(notificationCount.value, 1)
        XCTAssertEqual(snapshot.currentState(), state)
    }

    @MainActor
    func testLicenseSnapshotCoalescesConcurrentRefreshRequests() async throws {
        let state = makeState(
            plan: "enterprise",
            status: .active,
            expiresAt: .distantFuture
        )
        let probe = BlockingLicenseStateProvider(state: state)
        let snapshot = LicenseAuthorizationSnapshot(stateProvider: { try probe.load() })

        XCTAssertNil(snapshot.currentState())
        let firstLoadDeadline = Date().addingTimeInterval(1)
        while probe.loadCount < 1, Date() < firstLoadDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        for _ in 0..<20 {
            snapshot.refresh()
        }
        probe.release()

        let secondLoadDeadline = Date().addingTimeInterval(1)
        while probe.loadCount < 2, Date() < secondLoadDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        probe.release()

        let completionDeadline = Date().addingTimeInterval(1)
        while snapshot.currentState() != state, Date() < completionDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(probe.loadCount, 2)
        XCTAssertEqual(snapshot.currentState(), state)
    }

    @MainActor
    func testLicenseSnapshotConsumesPersistedStateFromAuthorizationNotification() async throws {
        let state = makeState(
            plan: "professional",
            status: .active,
            expiresAt: .distantFuture
        )
        let snapshot = LicenseAuthorizationSnapshot(
            stateProvider: { throw LicenseStateProviderTestError.unavailable },
            observesAuthorizationChanges: true,
            postsAuthorizationChanges: true
        )
        let changed = expectation(description: "Snapshot publishes persisted authorization")
        let observer = NotificationCenter.default.addObserver(
            forName: .stacioLicenseAuthorizationDidChange,
            object: nil,
            queue: .main
        ) { notification in
            guard (notification.object as AnyObject?) === snapshot else { return }
            changed.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        NotificationCenter.default.post(
            name: .stacioLicenseAuthorizationDidChange,
            object: NSObject(),
            userInfo: ["Stacio.LicenseAuthorization.state": state]
        )
        await fulfillment(of: [changed], timeout: 1)

        XCTAssertEqual(snapshot.currentState(), state)
    }

    func testExplicitEntitlementAllowsAFormalCustomPlan() {
        let state = makeState(
            plan: "custom",
            status: .offlineActive,
            permissions: [StacioLicenseEntitlement.bastionHost],
            expiresAt: Date.distantFuture
        )
        XCTAssertTrue(state.enables(.bastionHost))
    }

    func testAuthorizerRejectsMissingLicense() {
        let authorizer = LicenseBastionHostFeatureAuthorizer(stateProvider: { nil })
        XCTAssertThrowsError(try authorizer.authorizeBastionHostAccess()) { error in
            XCTAssertEqual(error as? BastionHostFeatureAccessError, .licenseRequired)
        }
    }

    func testDetectorRecognizesBastionUsernameWithoutGatingOrdinarySSH() {
        XCTAssertTrue(BastionHostSessionDetector.containsBastionHostSession(payload(username: "SSH@khyk@192.168.146.57")))
        XCTAssertTrue(BastionHostSessionDetector.containsBastionHostSession(payload(username: "ops@asset-123@gateway")))
        XCTAssertFalse(BastionHostSessionDetector.containsBastionHostSession(payload(username: "root")))
        XCTAssertFalse(BastionHostSessionDetector.containsBastionHostSession(payload(username: "root@example.com")))
    }

    private func makeState(
        plan: String,
        status: LicenseStatus,
        permissions: [String] = [],
        expiresAt: Date? = nil
    ) -> LicenseState {
        LicenseState(plan: plan, permissions: permissions, expiresAt: expiresAt, status: status)
    }

    private func payload(username: String) -> ExternalSessionImportPayload {
        ExternalSessionImportPayload(
            sessions: [
                ExternalImportedSession(
                    name: "Bastion",
                    folderPath: nil,
                    protocolName: "ssh",
                    host: "bastion.example.com",
                    port: 22,
                    username: username,
                    privateKeyPath: nil,
                    credential: nil
                )
            ],
            warnings: []
        )
    }
}

private struct RecordingLicenseFeatureAccessProvider: LicenseFeatureAccessProviding {
    let enabledFeatures: Set<StacioLicensedFeature>

    func isEnabled(_ feature: StacioLicensedFeature) -> Bool {
        enabledFeatures.contains(feature)
    }
}

private final class BlockingLicenseStateProvider: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private let state: LicenseState
    private var loadThreads: [Bool] = []

    init(state: LicenseState) {
        self.state = state
    }

    var firstLoadWasOnMainThread: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return loadThreads.first
    }

    var loadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return loadThreads.count
    }

    func load() throws -> LicenseState? {
        lock.lock()
        loadThreads.append(Thread.isMainThread)
        lock.unlock()
        _ = releaseSemaphore.wait(timeout: .now() + 1)
        return state
    }

    func release() {
        releaseSemaphore.signal()
    }
}

private enum LicenseStateProviderTestError: Error {
    case unavailable
}

private final class ScriptedLicenseStateProvider: @unchecked Sendable {
    private let lock = NSLock()
    private let results: [Result<LicenseState?, Error>]
    private var index = 0

    init(results: [Result<LicenseState?, Error>]) {
        self.results = results
    }

    var loadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return index
    }

    func load() throws -> LicenseState? {
        lock.lock()
        let result = results[min(index, results.count - 1)]
        index += 1
        lock.unlock()
        return try result.get()
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
