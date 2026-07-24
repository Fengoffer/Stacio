import Foundation

public enum StacioLicensedFeature: CaseIterable, Sendable {
    case multiExec
    case aiAgent
    case bastionHost
    case sshTunnel
    case advancedMetrics
    case fileSync
    case proxyJump
    case sessionBulkIO

    public var entitlement: String {
        switch self {
        case .multiExec: StacioLicenseEntitlement.multiExec
        case .aiAgent: StacioLicenseEntitlement.aiAgent
        case .bastionHost: StacioLicenseEntitlement.bastionHost
        case .sshTunnel: StacioLicenseEntitlement.sshTunnel
        case .advancedMetrics: StacioLicenseEntitlement.advancedMetrics
        case .fileSync: StacioLicenseEntitlement.fileSync
        case .proxyJump: StacioLicenseEntitlement.proxyJump
        case .sessionBulkIO: StacioLicenseEntitlement.sessionBulkIO
        }
    }
}

public protocol LicenseFeatureAccessProviding {
    func isEnabled(_ feature: StacioLicensedFeature) -> Bool
}

public struct UnrestrictedLicenseFeatureAccessProvider: LicenseFeatureAccessProviding {
    public init() {}

    public func isEnabled(_ feature: StacioLicensedFeature) -> Bool { true }
}

public extension Notification.Name {
    static let stacioLicenseAuthorizationDidChange = Notification.Name(
        "Stacio.LicenseAuthorizationDidChange"
    )
}

enum LicenseAuthorizationNotification {
    static let stateUserInfoKey = "Stacio.LicenseAuthorization.state"
}

final class LicenseAuthorizationSnapshot: @unchecked Sendable {
    static let shared = LicenseAuthorizationSnapshot(
        stateProvider: { try LicenseService().loadStateOrThrow() },
        observesAuthorizationChanges: true,
        postsAuthorizationChanges: true
    )

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "cn.stacio.license-authorization-snapshot")
    private let stateProvider: () throws -> LicenseState?
    private let postsAuthorizationChanges: Bool
    private var state: LicenseState?
    private var hasLoaded = false
    private var isLoading = false
    private var needsRefresh = false
    private var authorizationObserver: NSObjectProtocol?

    init(
        stateProvider: @escaping () throws -> LicenseState?,
        observesAuthorizationChanges: Bool = false,
        postsAuthorizationChanges: Bool = false
    ) {
        self.stateProvider = stateProvider
        self.postsAuthorizationChanges = postsAuthorizationChanges
        if observesAuthorizationChanges {
            authorizationObserver = NotificationCenter.default.addObserver(
                forName: .stacioLicenseAuthorizationDidChange,
                object: nil,
                queue: nil
            ) { [weak self] notification in
                guard let self,
                      (notification.object as AnyObject?) !== self
                else { return }
                if let state = notification.userInfo?[LicenseAuthorizationNotification.stateUserInfoKey]
                    as? LicenseState {
                    acceptPersistedState(state)
                } else {
                    refresh()
                }
            }
        }
    }

    deinit {
        if let authorizationObserver {
            NotificationCenter.default.removeObserver(authorizationObserver)
        }
    }

    func currentState() -> LicenseState? {
        lock.lock()
        let current = state
        let shouldLoad = hasLoaded == false && isLoading == false
        if shouldLoad {
            isLoading = true
        }
        lock.unlock()
        if shouldLoad {
            enqueueLoad()
        }
        return current
    }

    func refresh() {
        lock.lock()
        guard isLoading == false else {
            needsRefresh = true
            lock.unlock()
            return
        }
        isLoading = true
        lock.unlock()
        enqueueLoad()
    }

    private func enqueueLoad() {
        queue.async { [weak self] in
            self?.loadState()
        }
    }

    private func acceptPersistedState(_ persistedState: LicenseState) {
        queue.async { [weak self] in
            guard let self else { return }
            lock.lock()
            let previousState = state
            state = persistedState
            hasLoaded = true
            let shouldNotify = postsAuthorizationChanges && previousState != persistedState
            lock.unlock()
            if shouldNotify {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    NotificationCenter.default.post(
                        name: .stacioLicenseAuthorizationDidChange,
                        object: self
                    )
                }
            }
        }
    }

    private func loadState() {
        let result: Result<LicenseState?, Error>
        do {
            result = .success(try stateProvider())
        } catch {
            result = .failure(error)
        }

        lock.lock()
        let previousState = state
        if case .success(let loadedState) = result {
            state = loadedState
            hasLoaded = true
        } else {
            // Keep the last verified snapshot if Keychain is temporarily unavailable.
            hasLoaded = false
        }
        let shouldNotify: Bool
        if case .success(let loadedState) = result {
            shouldNotify = postsAuthorizationChanges && previousState != loadedState
        } else {
            shouldNotify = false
        }
        let shouldReload = needsRefresh
        needsRefresh = false
        isLoading = shouldReload
        lock.unlock()

        if shouldNotify {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                NotificationCenter.default.post(
                    name: .stacioLicenseAuthorizationDidChange,
                    object: self
                )
            }
        }
        if shouldReload {
            enqueueLoad()
        }
    }
}

public struct LocalLicenseFeatureAccessProvider: LicenseFeatureAccessProviding {
    private let snapshot: LicenseAuthorizationSnapshot
    private let nowProvider: () -> Date

    public init(nowProvider: @escaping () -> Date = Date.init) {
        snapshot = .shared
        self.nowProvider = nowProvider
    }

    public init(
        stateProvider: @escaping () throws -> LicenseState?,
        nowProvider: @escaping () -> Date = Date.init
    ) {
        snapshot = LicenseAuthorizationSnapshot(stateProvider: stateProvider)
        self.nowProvider = nowProvider
    }

    public func isEnabled(_ feature: StacioLicensedFeature) -> Bool {
        guard let state = snapshot.currentState() else { return false }
        return state.enables(feature, at: nowProvider())
    }
}

public extension LicenseState {
    func enables(_ feature: StacioLicensedFeature, at now: Date = Date()) -> Bool {
        let formallyLicensedStatuses: Set<LicenseStatus> = [
            .active,
            .offlineActive,
            .offlineGrace,
            .networkUnavailable
        ]
        guard formallyLicensedStatuses.contains(status) else { return false }
        guard let expiresAt, expiresAt > now else { return false }

        let normalizedPlan = plan.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedPermissions = Set(permissions.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        if normalizedPermissions.contains(feature.entitlement) {
            return true
        }

        let formalPlans: Set<String> = ["pro", "professional", "team", "enterprise", "internal"]
        let planBundleEntitlements: Set<String> = ["pro_features", "team_features"]
        let carriesOnlyPlanBundle = normalizedPermissions.isEmpty
            || normalizedPermissions.isSubset(of: planBundleEntitlements)

        // Older and plan-only signed records carry the version without expanded feature keys.
        return formalPlans.contains(normalizedPlan) && carriesOnlyPlanBundle
    }
}
