import Foundation
import XCTest
@testable import StacioApp

@MainActor
final class LicenseRevalidationCoordinatorTests: XCTestCase {
    func testLaunchWithoutStoredActivationSkipsNetworkRequest() async throws {
        let store = makeStore()
        let validator = RecordingLicenseOnlineValidator(
            result: .success(makeTerminalResponse(status: .revoked))
        )
        let coordinator = LicenseRevalidationCoordinator(
            store: store,
            service: LicenseService(store: store),
            onlineValidator: validator,
            contextProvider: {
                LicenseRevalidationContext(
                    appVersion: "0.13.2-Beta",
                    buildNumber: "1",
                    anonymousDeviceID: "anonymous-device"
                )
            }
        )

        let outcome = try await coordinator.revalidateOnLaunch()

        XCTAssertEqual(outcome, .noActivation)
        XCTAssertEqual(validator.requests.count, 0)
    }

    func testLaunchWithoutActivationInvalidatesStoredOnlineActiveAndTrialStates() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        for status in [LicenseStatus.active, .trial] {
            let store = makeStore()
            var state = makeActiveState(now: now)
            state.status = status
            try store.save(state)
            let validator = RecordingLicenseOnlineValidator(
                result: .success(makeTerminalResponse(status: .revoked))
            )
            let coordinator = makeCoordinator(store: store, validator: validator, now: now)

            let outcome = try await coordinator.revalidateOnLaunch()

            guard case .refreshed(let refreshed) = outcome else {
                return XCTFail("Expected invalidated state for \(status), got \(outcome)")
            }
            XCTAssertEqual(refreshed.status, .invalid)
            XCTAssertNil(refreshed.graceUntil)
            XCTAssertEqual(try store.load()?.status, .invalid)
            XCTAssertEqual(validator.requests.count, 0)
        }
    }

    func testRateLimitIsRetriedBeforePersistingRevokedState() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = makeStore()
        try store.saveActivationRecord(makeActivation())
        try store.save(makeActiveState(now: now))
        let validator = SequencedLicenseOnlineValidator(results: [
            .failure(ProductOpsError.rateLimited(retryAfter: 60, requestID: "req-rate-limit")),
            .success(makeTerminalResponse(status: .revoked))
        ])
        let coordinator = makeCoordinator(store: store, validator: validator, now: now)

        let outcome = try await coordinator.revalidateOnLaunch()

        guard case .refreshed(let state) = outcome else {
            return XCTFail("Expected refreshed outcome, got \(outcome)")
        }
        XCTAssertEqual(state.status, .revoked)
        XCTAssertEqual(validator.requests.count, 2)
        XCTAssertEqual(try store.load()?.status, .revoked)
    }

    func testRepeatedServerFailuresEnterBoundedOfflineGraceAfterFiniteRetries() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = makeStore()
        try store.saveActivationRecord(makeActivation())
        try store.save(makeActiveState(now: now))
        let failure = ProductOpsError.server(message: "temporarily unavailable", requestID: "req-server")
        let validator = SequencedLicenseOnlineValidator(results: [
            .failure(failure),
            .failure(failure),
            .failure(failure)
        ])
        let coordinator = makeCoordinator(store: store, validator: validator, now: now)

        let outcome = try await coordinator.revalidateOnLaunch()

        guard case .networkUnavailable(let state) = outcome else {
            return XCTFail("Expected networkUnavailable outcome, got \(outcome)")
        }
        XCTAssertEqual(state.status, .offlineGrace)
        XCTAssertEqual(validator.requests.count, 3)
        XCTAssertEqual(try store.load()?.status, .offlineGrace)
    }

    func testNetworkRestoreBuildsRequestAndPersistsRevokedState() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = makeStore()
        let activation = makeActivation()
        try store.saveActivationRecord(activation)
        try store.save(makeActiveState(now: now))
        let validator = RecordingLicenseOnlineValidator(
            result: .success(makeTerminalResponse(status: .revoked))
        )
        let coordinator = makeCoordinator(
            store: store,
            validator: validator,
            now: now
        )

        let outcome = try await coordinator.revalidateAfterNetworkRestore()

        let request = try XCTUnwrap(validator.requests.first)
        XCTAssertEqual(request.licenseKey, activation.licenseKey)
        XCTAssertEqual(request.username, activation.username)
        XCTAssertEqual(request.email, activation.email)
        XCTAssertEqual(request.appVersion, "0.13.2-Beta")
        XCTAssertEqual(request.buildNumber, "1")
        XCTAssertEqual(request.deviceIDHash, DeviceIdentifierHasher.hash("anonymous-device"))
        XCTAssertEqual(validator.requests.count, 1)
        guard case .refreshed(let state) = outcome else {
            return XCTFail("Expected refreshed outcome, got \(outcome)")
        }
        XCTAssertEqual(state.status, .revoked)
        XCTAssertEqual(try store.load()?.status, .revoked)
    }

    func testStaleRevalidationResponseDoesNotOverwriteNewerActivationState() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = makeStore()
        try store.saveActivationRecord(makeActivation())
        try store.save(makeActiveState(now: now))
        let gate = RevalidationTestGate()
        let validator = GatedLicenseOnlineValidator(
            gate: gate,
            response: makeTerminalResponse(status: .revoked)
        )
        let coordinator = makeCoordinator(store: store, validator: validator, now: now)

        async let staleOutcome = coordinator.revalidateOnLaunch()
        while await validator.requestCount == 0 {
            await Task.yield()
        }
        let newerActivation = LicenseActivationRecord(
            licenseKey: "STACIO-NEW-SECRET-KEY",
            username: "Ada",
            email: "ada@example.com"
        )
        try store.saveActivationRecord(newerActivation)
        try store.save(makeActiveState(now: now))
        await gate.open()

        guard case .refreshed(let refreshed) = try await staleOutcome else {
            return XCTFail("Expected current state to be reported without saving stale response")
        }
        XCTAssertEqual(refreshed.status, .active)
        XCTAssertEqual(try store.loadActivationRecord(), newerActivation)
        XCTAssertEqual(try store.load()?.status, .active)
    }

    func testOfflineFailurePreservesSignedStateInsideGraceWindow() async throws {
        try await assertNetworkFailurePreservesGrace(URLError(.notConnectedToInternet))
    }

    func testTimeoutPreservesSignedStateInsideGraceWindow() async throws {
        try await assertNetworkFailurePreservesGrace(URLError(.timedOut))
    }

    func testOfflineWithoutStoredStateMarksNetworkUnavailable() async throws {
        let store = makeStore()
        try store.saveActivationRecord(makeActivation())
        let validator = RecordingLicenseOnlineValidator(
            result: .failure(URLError(.notConnectedToInternet))
        )
        let coordinator = makeCoordinator(store: store, validator: validator)

        let outcome = try await coordinator.revalidateOnLaunch()

        guard case .networkUnavailable(let state) = outcome else {
            return XCTFail("Expected networkUnavailable outcome, got \(outcome)")
        }
        XCTAssertEqual(state.status, .networkUnavailable)
        XCTAssertEqual(try store.load()?.status, .networkUnavailable)
    }

    func testNonTransientClientFailureIsRethrownWithoutChangingState() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = makeStore()
        try store.saveActivationRecord(makeActivation())
        let existing = makeActiveState(now: now)
        try store.save(existing)
        let expected = ProductOpsError.client(message: "invalid request", requestID: "req-1")
        let validator = RecordingLicenseOnlineValidator(result: .failure(expected))
        let coordinator = makeCoordinator(store: store, validator: validator, now: now)

        do {
            _ = try await coordinator.revalidateOnLaunch()
            XCTFail("Expected client error")
        } catch {
            XCTAssertEqual(error as? ProductOpsError, expected)
        }
        XCTAssertEqual(try store.load(), existing)
    }

    func testConcurrentLaunchAndNetworkRestoreShareOneRequest() async throws {
        let store = makeStore()
        try store.saveActivationRecord(makeActivation())
        let gate = RevalidationTestGate()
        let validator = GatedLicenseOnlineValidator(
            gate: gate,
            response: makeTerminalResponse(status: .revoked)
        )
        let coordinator = makeCoordinator(store: store, validator: validator)

        async let launchOutcome = coordinator.revalidateOnLaunch()
        while await validator.requestCount == 0 {
            await Task.yield()
        }
        async let restoreOutcome = coordinator.revalidateAfterNetworkRestore()
        await Task.yield()
        await gate.open()

        let outcomes = try await [launchOutcome, restoreOutcome]
        let requestCount = await validator.requestCount

        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(outcomes.count, 2)
        for outcome in outcomes {
            guard case .refreshed(let state) = outcome else {
                return XCTFail("Expected refreshed outcome, got \(outcome)")
            }
            XCTAssertEqual(state.status, .revoked)
        }
    }

    func testCancellationStopsInFlightRevalidationBeforePersistingResponse() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = makeStore()
        try store.saveActivationRecord(makeActivation())
        try store.save(makeActiveState(now: now))
        let gate = RevalidationTestGate()
        let validator = GatedLicenseOnlineValidator(
            gate: gate,
            response: makeTerminalResponse(status: .revoked)
        )
        let coordinator = makeCoordinator(store: store, validator: validator, now: now)

        let task = Task {
            try await coordinator.revalidateOnLaunch()
        }
        while await validator.requestCount == 0 {
            await Task.yield()
        }
        task.cancel()
        await gate.open()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        XCTAssertEqual(try store.load()?.status, .active)
    }

    func testNetworkUnavailableCancelsInFlightRevalidationBeforePersistingResponse() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = makeStore()
        try store.saveActivationRecord(makeActivation())
        try store.save(makeActiveState(now: now))
        let gate = RevalidationTestGate()
        let validator = GatedLicenseOnlineValidator(
            gate: gate,
            response: makeTerminalResponse(status: .revoked)
        )
        let coordinator = makeCoordinator(store: store, validator: validator, now: now)

        let task = Task {
            try await coordinator.revalidateOnLaunch()
        }
        while await validator.requestCount == 0 {
            await Task.yield()
        }

        let unavailable = try await coordinator.markNetworkUnavailable()
        await gate.open()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        guard case .networkUnavailable(let state) = unavailable else {
            return XCTFail("Expected networkUnavailable outcome, got \(unavailable)")
        }
        XCTAssertEqual(state.status, .offlineGrace)
        XCTAssertEqual(try store.load()?.status, .offlineGrace)
    }

    func testRateLimitRetryDelayIsCappedForForegroundRevalidation() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = makeStore()
        try store.saveActivationRecord(makeActivation())
        try store.save(makeActiveState(now: now))
        let validator = SequencedLicenseOnlineValidator(results: [
            .failure(ProductOpsError.rateLimited(retryAfter: 3_600, requestID: "req-rate-limit")),
            .success(makeTerminalResponse(status: .revoked))
        ])
        let sleeper = RevalidationSleepRecorder()
        let coordinator = makeCoordinator(
            store: store,
            validator: validator,
            now: now,
            retryPolicy: ProductOpsRetryPolicy(maxAttempts: 2, delay: 30),
            sleepForNanoseconds: { nanoseconds in
                sleeper.record(nanoseconds)
            }
        )

        _ = try await coordinator.revalidateOnLaunch()

        XCTAssertEqual(sleeper.recordedNanoseconds, [
            UInt64(LicenseRevalidationCoordinator.maximumRetryDelay * 1_000_000_000)
        ])
        XCTAssertEqual(validator.requests.count, 2)
    }

    private func assertNetworkFailurePreservesGrace(_ error: Error) async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = makeStore()
        try store.saveActivationRecord(makeActivation())
        let existing = makeActiveState(now: now)
        try store.save(existing)
        let validator = RecordingLicenseOnlineValidator(result: .failure(error))
        let coordinator = makeCoordinator(store: store, validator: validator, now: now)

        let outcome = try await coordinator.revalidateOnLaunch()

        guard case .networkUnavailable(let state) = outcome else {
            return XCTFail("Expected networkUnavailable outcome, got \(outcome)")
        }
        XCTAssertEqual(state.status, .offlineGrace)
        XCTAssertEqual(state.signedLicenseToken, existing.signedLicenseToken)
        XCTAssertEqual(state.plan, existing.plan)
        XCTAssertEqual(state.permissions, existing.permissions)
        XCTAssertEqual(try store.load(), state)
    }
}

private final class RecordingLicenseOnlineValidator: LicenseOnlineValidating {
    let result: Result<LicenseValidationResponse, Error>
    private(set) var requests: [LicenseValidationRequest] = []

    init(result: Result<LicenseValidationResponse, Error>) {
        self.result = result
    }

    func validate(_ requestBody: LicenseValidationRequest) async throws -> LicenseValidationResponse {
        requests.append(requestBody)
        return try result.get()
    }
}

private final class SequencedLicenseOnlineValidator: LicenseOnlineValidating {
    private var results: [Result<LicenseValidationResponse, Error>]
    private(set) var requests: [LicenseValidationRequest] = []

    init(results: [Result<LicenseValidationResponse, Error>]) {
        self.results = results
    }

    func validate(_ requestBody: LicenseValidationRequest) async throws -> LicenseValidationResponse {
        requests.append(requestBody)
        guard results.isEmpty == false else {
            throw ProductOpsError.server(message: "Missing test response", requestID: nil)
        }
        return try results.removeFirst().get()
    }
}

private actor GatedLicenseOnlineValidator: LicenseOnlineValidating {
    private let gate: RevalidationTestGate
    private let response: LicenseValidationResponse
    private(set) var requestCount = 0

    init(gate: RevalidationTestGate, response: LicenseValidationResponse) {
        self.gate = gate
        self.response = response
    }

    func validate(_ requestBody: LicenseValidationRequest) async throws -> LicenseValidationResponse {
        requestCount += 1
        await gate.wait()
        return response
    }
}

private actor RevalidationTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard isOpen == false else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private func makeStore() -> LicenseKeychainStore {
    LicenseKeychainStore(
        backend: CoordinatorInMemoryLicenseKeychainBackend(),
        service: "cn.stacio.tests.license.revalidation.\(UUID().uuidString)"
    )
}

@MainActor
private func makeCoordinator(
    store: LicenseKeychainStore,
    validator: LicenseOnlineValidating,
    now: Date = Date(timeIntervalSince1970: 1_700_000_000),
    retryPolicy: ProductOpsRetryPolicy = .immediate(maxAttempts: 3),
    sleepForNanoseconds: @escaping (UInt64) async throws -> Void = { _ in }
) -> LicenseRevalidationCoordinator {
    let state = (try? store.load()) ?? nil
    let claims = SignedLicenseClaims(
        licenseID: "license-1",
        productID: "stacio",
        email: state?.email ?? "ada@example.com",
        username: state?.username ?? "Ada",
        plan: state?.plan ?? "pro",
        entitlements: state?.permissions ?? ["remote_sessions"],
        expiresAt: state?.expiresAt ?? now.addingTimeInterval(86_400),
        offlineGraceSeconds: 7_200,
        issuedAt: now.addingTimeInterval(-3_600)
    )
    return LicenseRevalidationCoordinator(
        store: store,
        service: LicenseService(
            store: store,
            signedTokenVerifier: CoordinatorSignedTokenVerifier(claims: claims)
        ),
        onlineValidator: validator,
        contextProvider: {
            LicenseRevalidationContext(
                appVersion: "0.13.2-Beta",
                buildNumber: "1",
                anonymousDeviceID: "anonymous-device"
            )
        },
        retryPolicy: retryPolicy,
        nowProvider: { now },
        sleepForNanoseconds: sleepForNanoseconds
    )
}

@MainActor
private final class RevalidationSleepRecorder {
    private(set) var recordedNanoseconds: [UInt64] = []

    func record(_ nanoseconds: UInt64) {
        recordedNanoseconds.append(nanoseconds)
    }
}

private func makeActivation() -> LicenseActivationRecord {
    LicenseActivationRecord(
        licenseKey: "STACIO-SECRET-KEY",
        username: "Ada",
        email: "ada@example.com"
    )
}

private func makeActiveState(now: Date) -> LicenseState {
    LicenseState(
        username: "Ada",
        email: "ada@example.com",
        signedLicenseToken: "v1.payload.signature",
        plan: "pro",
        permissions: ["remote_sessions"],
        expiresAt: now.addingTimeInterval(86_400),
        graceUntil: now.addingTimeInterval(3_600),
        status: .active,
        lastValidatedAt: now.addingTimeInterval(-3_600)
    )
}

private func makeTerminalResponse(status: LicenseStatus) -> LicenseValidationResponse {
    LicenseValidationResponse(
        username: "Ada",
        email: "ada@example.com",
        plan: "",
        expiresAt: nil,
        status: status
    )
}

private struct CoordinatorSignedTokenVerifier: SignedLicenseTokenVerifying {
    let claims: SignedLicenseClaims

    func verifiedClaims(from token: String) throws -> SignedLicenseClaims {
        claims
    }
}

private final class CoordinatorInMemoryLicenseKeychainBackend: LicenseKeychainBackend {
    private var values: [String: Data] = [:]

    func save(_ data: Data, service: String, account: String) throws {
        values[account] = data
    }

    func read(service: String, account: String) throws -> Data? {
        values[account]
    }

    func delete(service: String, account: String) throws {
        values.removeValue(forKey: account)
    }
}
