import Foundation
import Network

public struct LicenseRevalidationContext: Equatable {
    public var appVersion: String
    public var buildNumber: String
    public var anonymousDeviceID: String

    public init(appVersion: String, buildNumber: String, anonymousDeviceID: String) {
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.anonymousDeviceID = anonymousDeviceID
    }
}

public enum LicenseRevalidationOutcome: Equatable {
    case noActivation
    case refreshed(LicenseState)
    case networkUnavailable(LicenseState)
}

@MainActor
public protocol LicenseRevalidating: AnyObject {
    func revalidateOnLaunch() async throws -> LicenseRevalidationOutcome
    func revalidateAfterNetworkRestore() async throws -> LicenseRevalidationOutcome
}

public protocol LicenseNetworkMonitoring: AnyObject {
    func start(onNetworkRestored: @escaping () -> Void)
    func cancel()
}

public protocol LicenseNetworkStatusMonitoring: LicenseNetworkMonitoring {
    func start(
        onNetworkRestored: @escaping () -> Void,
        onNetworkUnavailable: @escaping () -> Void
    )
}

@MainActor
public protocol LicenseNetworkUnavailableHandling: AnyObject {
    func markNetworkUnavailable() async throws -> LicenseRevalidationOutcome
}

public final class NWPathLicenseNetworkMonitor: LicenseNetworkStatusMonitoring {
    private let monitor: NWPathMonitor
    private let queue: DispatchQueue
    private var previousStatus: NWPath.Status?
    private var isStarted = false

    public init(
        monitor: NWPathMonitor = NWPathMonitor(),
        queue: DispatchQueue = DispatchQueue(label: "cn.stacio.license-network-monitor")
    ) {
        self.monitor = monitor
        self.queue = queue
    }

    public func start(onNetworkRestored: @escaping () -> Void) {
        start(onNetworkRestored: onNetworkRestored, onNetworkUnavailable: {})
    }

    public func start(
        onNetworkRestored: @escaping () -> Void,
        onNetworkUnavailable: @escaping () -> Void
    ) {
        guard isStarted == false else { return }
        isStarted = true
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let previousStatus = self.previousStatus
            self.previousStatus = path.status
            guard let previousStatus else { return }
            if previousStatus != .satisfied,
               path.status == .satisfied {
                onNetworkRestored()
            } else if previousStatus == .satisfied,
                      path.status != .satisfied {
                onNetworkUnavailable()
            }
        }
        monitor.start(queue: queue)
    }

    public func cancel() {
        guard isStarted else { return }
        isStarted = false
        previousStatus = nil
        monitor.pathUpdateHandler = nil
        monitor.cancel()
    }
}

@MainActor
public final class LicenseRevalidationCoordinator {
    static let maximumRetryDelay: TimeInterval = 5

    private let store: LicenseKeychainStore
    private let service: LicenseService
    private let onlineValidator: LicenseOnlineValidating
    private let offlineStatusRefresher: OfflineLicenseStatusRefreshing?
    private let contextProvider: () -> LicenseRevalidationContext
    private let retryPolicy: ProductOpsRetryPolicy
    private let nowProvider: () -> Date
    private let sleepForNanoseconds: @MainActor (UInt64) async throws -> Void
    private var inFlightTask: Task<LicenseRevalidationOutcome, Error>?

    public init(
        store: LicenseKeychainStore,
        service: LicenseService,
        onlineValidator: LicenseOnlineValidating,
        offlineStatusRefresher: OfflineLicenseStatusRefreshing? = nil,
        contextProvider: @escaping () -> LicenseRevalidationContext,
        retryPolicy: ProductOpsRetryPolicy = ProductOpsRetryPolicy(maxAttempts: 3),
        nowProvider: @escaping () -> Date = Date.init,
        sleepForNanoseconds: @escaping @MainActor (UInt64) async throws -> Void = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        self.store = store
        self.service = service
        self.onlineValidator = onlineValidator
        self.offlineStatusRefresher = offlineStatusRefresher
        self.contextProvider = contextProvider
        self.retryPolicy = retryPolicy
        self.nowProvider = nowProvider
        self.sleepForNanoseconds = sleepForNanoseconds
    }

    public func revalidateOnLaunch() async throws -> LicenseRevalidationOutcome {
        try await revalidate()
    }

    public func revalidateAfterNetworkRestore() async throws -> LicenseRevalidationOutcome {
        try await revalidate()
    }

    public func markNetworkUnavailable() async throws -> LicenseRevalidationOutcome {
        inFlightTask?.cancel()
        inFlightTask = nil
        let service = self.service
        let now = nowProvider()
        let state = try await performPersistence {
            try service.stateForNetworkUnavailable(now: now)
        }
        return .networkUnavailable(state)
    }

    private func revalidate() async throws -> LicenseRevalidationOutcome {
        if let inFlightTask {
            return try await inFlightTask.value
        }
        let task = Task { @MainActor [weak self] in
            guard let self else {
                return LicenseRevalidationOutcome.noActivation
            }
            return try await self.performRevalidation()
        }
        inFlightTask = task
        do {
            let outcome = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            inFlightTask = nil
            return outcome
        } catch {
            inFlightTask = nil
            throw error
        }
    }

    private func performRevalidation() async throws -> LicenseRevalidationOutcome {
        let now = nowProvider()
        let store = self.store
        let service = self.service
        let stored = try await performPersistence { try store.load() }
        if let stored,
           let authorization = stored.offlineDeviceAuthorization {
            guard let offlineStatusRefresher else {
                return .refreshed(service.evaluate(state: stored, now: now))
            }
            let context = contextProvider()
            do {
                let refreshed = try await offlineStatusRefresher.refresh(
                    authorization: authorization,
                    appVersion: context.appVersion,
                    buildNumber: context.buildNumber
                )
                let state = try await performPersistence {
                    try service.state(
                        applyingOfflineDeviceAuthorization: refreshed,
                        expectedUsername: authorization.username,
                        expectedEmail: authorization.email,
                        activationStore: store,
                        now: now
                    )
                }
                return .refreshed(state)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let classified = ProductOpsError.classify(error)
                if classified.offlineLicenseStatusErrorCode != nil {
                    let state = try await performPersistence {
                        try service.state(applyingOfflineStatusError: classified, now: now)
                    }
                    return .refreshed(state)
                }
                switch classified {
                case .offline, .timeout, .rateLimited, .server:
                    return .networkUnavailable(service.evaluate(state: stored, now: now))
                case .backend(_, _, _, let statusCode) where (500..<600).contains(statusCode):
                    return .networkUnavailable(service.evaluate(state: stored, now: now))
                default:
                    throw classified
                }
            }
        }
        if let stored,
           stored.lastAuthorizationSyncErrorCode?.isEmpty == false {
            // A terminal offline-status response requires an explicit
            // re-import before another automatic online activation is tried.
            return .refreshed(service.evaluate(state: stored, now: now))
        }
        guard let activation = try await performPersistence({
            try store.loadActivationRecord()
        }) else {
            if var state = stored,
               state.status == .active || state.status == .trial {
                state.status = .invalid
                state.graceUntil = nil
                try await performPersistence { try store.save(state) }
                return .refreshed(state)
            }
            return .noActivation
        }
        let context = contextProvider()
        let request = LicenseValidationRequest(
            licenseKey: activation.licenseKey,
            username: activation.username,
            email: activation.email,
            appVersion: context.appVersion,
            buildNumber: context.buildNumber,
            anonymousDeviceID: context.anonymousDeviceID
        )
        let response: LicenseValidationResponse
        do {
            response = try await validateWithRetry(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let classified = ProductOpsError.classify(error)
            switch classified {
            case .offline, .timeout, .rateLimited, .server:
                let service = self.service
                let state = try await performPersistence {
                    try service.stateForNetworkUnavailable(now: now)
                }
                return .networkUnavailable(state)
            case .backend(_, _, _, let statusCode) where (500..<600).contains(statusCode):
                let service = self.service
                let state = try await performPersistence {
                    try service.stateForNetworkUnavailable(now: now)
                }
                return .networkUnavailable(state)
            default:
                throw classified
            }
        }
        guard try await currentActivationMatches(request) else {
            if let currentState = try await performPersistence({ try store.load() }) {
                return .refreshed(service.evaluate(state: currentState, now: now))
            }
            return .noActivation
        }
        let state = try await performPersistence {
            try service.state(
                applyingRevalidation: response,
                expected: request,
                now: now
            )
        }
        return .refreshed(state)
    }

    private func validateWithRetry(
        _ request: LicenseValidationRequest
    ) async throws -> LicenseValidationResponse {
        for attempt in 1...retryPolicy.maxAttempts {
            do {
                let response = try await onlineValidator.validate(request)
                try Task.checkCancellation()
                return response
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let classified = ProductOpsError.classify(error)
                guard attempt < retryPolicy.maxAttempts,
                      shouldRetryValidation(after: classified)
                else {
                    throw classified
                }
                let delay = retryDelay(after: classified)
                if delay > 0 {
                    try await sleepForNanoseconds(UInt64(delay * 1_000_000_000))
                }
            }
        }
        throw ProductOpsError.server(message: "License 校验未返回结果。", requestID: nil)
    }

    private func shouldRetryValidation(after error: ProductOpsError) -> Bool {
        switch error {
        case .rateLimited, .server:
            return true
        case .backend(_, _, _, let statusCode) where (500..<600).contains(statusCode):
            return true
        default:
            return false
        }
    }

    private func retryDelay(after error: ProductOpsError) -> TimeInterval {
        guard retryPolicy.delay > 0 else { return 0 }
        if case .rateLimited(let retryAfter, _) = error {
            return min(Self.maximumRetryDelay, max(0, retryAfter ?? retryPolicy.delay))
        }
        return min(Self.maximumRetryDelay, retryPolicy.delay)
    }

    private func currentActivationMatches(_ request: LicenseValidationRequest) async throws -> Bool {
        let store = self.store
        guard let activation = try await performPersistence({
            try store.loadActivationRecord()
        }) else {
            return false
        }
        return activation.licenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
            == request.licenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
            && activation.username.caseInsensitiveCompare(request.username) == .orderedSame
            && activation.email.caseInsensitiveCompare(request.email) == .orderedSame
    }

    private func performPersistence<T>(
        _ operation: @escaping () throws -> T
    ) async throws -> T {
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let value = try operation()
            try Task.checkCancellation()
            return value
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

extension LicenseRevalidationCoordinator: LicenseRevalidating {}
extension LicenseRevalidationCoordinator: LicenseNetworkUnavailableHandling {}
