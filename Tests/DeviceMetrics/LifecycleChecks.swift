import Foundation

// Compile this template with lifecycle_smoke.sh, which fills the marked slots
// directly from production. Stubs model only UI sinks and deferred provider I/O.
enum DeviceMetricsInventoryError: Error {
    case authorizationRequired
    case partialContainerInventory([String], requiresAuthorization: Bool)
    case partialPortInventory([String], requiresAuthorization: Bool)
    var requiresAuthorization: Bool {
        switch self {
        case .authorizationRequired: return true
        case let .partialContainerInventory(_, required): return required
        case let .partialPortInventory(_, required): return required
        }
    }
    var partialContainers: [String]? {
        if case let .partialContainerInventory(rows, _) = self { return rows }
        return nil
    }
    var partialPorts: [String]? {
        if case let .partialPortInventory(rows, _) = self { return rows }
        return nil
    }
}

final class DeviceMetricsInventoryPanel {
    typealias Row = String
    struct Item { var name = "service"; var scope = "system"; var id = "container"; var engine = "docker" }
    enum Action { case process(String, UInt32, String? = nil), service(String, Item), container(String, Item) }
    var updates: [[Row]] = []
    var failureCount = 0
    var failure: Error?
    var authorizationClearCount = 0
    var loading = false
    var busy = false
    func setLoading(_ value: Bool) { loading = value }
    func setBusy(_ value: Bool) { busy = value }
    func update(_ rows: [Row]) { updates.append(rows); failure = nil }
    func setFailure(_ error: Error) { failureCount += 1; failure = error }
    func clearAuthorizationFailure() {
        authorizationClearCount += 1
        if (failure as? DeviceMetricsInventoryError)?.requiresAuthorization == true { failure = nil }
    }
}

protocol DeviceMetricsInventoryManaging: AnyObject {
    func listManagedProcesses(_ completion: @escaping (Result<[String], Error>) -> Void)
    func listManagedPorts(_ completion: @escaping (Result<[String], Error>) -> Void)
    func listManagedServices(_ completion: @escaping (Result<[String], Error>) -> Void)
    func listManagedContainers(_ completion: @escaping (Result<[String], Error>) -> Void)
    func performProcessAction(_ operation: String, pid: UInt32, expectedIdentity: String?, completion: @escaping (Result<Void, Error>) -> Void)
    func performServiceAction(_ operation: String, name: String, scope: String, completion: @escaping (Result<Void, Error>) -> Void)
    func performContainerAction(_ operation: String, id: String, engine: String, completion: @escaping (Result<Void, Error>) -> Void)
}

protocol DeviceMetricsInventoryAuthorizing: AnyObject {
    func authorizeInventorySudo(_ password: String, completion: @escaping (Result<Void, Error>) -> Void)
    func retryInventoryAuthorization()
}

final class DeferredProvider: DeviceMetricsInventoryManaging, DeviceMetricsInventoryAuthorizing {
    var requests: [(segment: Int, completion: (Result<[String], Error>) -> Void)] = []
    var actions: [(Result<Void, Error>) -> Void] = []
    var processActionIdentities: [String?] = []
    var authorizations: [(password: String, completion: (Result<Void, Error>) -> Void)] = []
    var authorizationRetries = 0
    func authorizeInventorySudo(_ password: String, completion: @escaping (Result<Void, Error>) -> Void) {
        authorizations.append((password, completion))
    }
    func retryInventoryAuthorization() { authorizationRetries += 1 }
    func listManagedProcesses(_ completion: @escaping (Result<[String], Error>) -> Void) { requests.append((1, completion)) }
    func listManagedPorts(_ completion: @escaping (Result<[String], Error>) -> Void) { requests.append((2, completion)) }
    func listManagedServices(_ completion: @escaping (Result<[String], Error>) -> Void) { requests.append((3, completion)) }
    func listManagedContainers(_ completion: @escaping (Result<[String], Error>) -> Void) { requests.append((4, completion)) }
    func performProcessAction(_ operation: String, pid: UInt32, expectedIdentity: String?, completion: @escaping (Result<Void, Error>) -> Void) {
        processActionIdentities.append(expectedIdentity)
        actions.append(completion)
    }
    func performServiceAction(_ operation: String, name: String, scope: String, completion: @escaping (Result<Void, Error>) -> Void) { actions.append(completion) }
    func performContainerAction(_ operation: String, id: String, engine: String, completion: @escaping (Result<Void, Error>) -> Void) { actions.append(completion) }
}

final class HoverDetailPresenterStub {
    private(set) var dismissalCount = 0
    func dismiss() { dismissalCount += 1 }
}

final class LifecycleHarness {
    let provider: AnyObject
    let hoverDetailPresenter = HoverDetailPresenterStub()
    var inventoryPanels: [Int: DeviceMetricsInventoryPanel] = [:]
    struct Selection { var selectedSegment = 0 }
    struct Settings { var deviceMetricsRefreshIntervalSeconds = 60; func snapshot() -> Self { self } }
    var inventoryTabControl = Selection()
    var settingsStore = Settings()
    var isViewLoaded = true
    var startsPollingAutomatically = false
    var refreshTimer: Timer?
    var metricsDidUpdate: (() -> Void)?
    var refreshCount = 0
    var retriesAuthorizationImmediately = false
    var usesDeferredAuthorization = false
    var authorizationPromptCount = 0
    // PRODUCTION_STATE
    init(_ provider: DeferredProvider) { self.provider = provider }
    func inventoryPanel(for segment: Int) -> DeviceMetricsInventoryPanel {
        if let panel = inventoryPanels[segment] { return panel }
        let panel = DeviceMetricsInventoryPanel()
        inventoryPanels[segment] = panel
        return panel
    }
    func refreshMetrics() { refreshCount += 1 }
    func invalidatePreferredFloatingHeight() { }
    func requestInventoryAuthorization(for segment: Int, retry: @escaping () -> Void) {
        authorizationPromptCount += 1
        if usesDeferredAuthorization {
            authorizeManagement(password: "fixture-password", segment: segment, retry: retry)
            return
        }
        if retriesAuthorizationImmediately { retry() }
    }
    func processRows(_ values: [String]) -> [String] { values }
    func portRows(_ values: [String]) -> [String] { values }
    func serviceRows(_ values: [String]) -> [String] { values }
    func containerRows(_ values: [String]) -> [String] { values }
    func expireManagementCache(for segment: Int) { managementLastLoad[segment] = .distantPast }
    func generation(for segment: Int) -> Int { managementLoadGenerations[segment, default: 0] }
    var deniedSegments: Set<Int> { managementAuthorizationRequired }
    var cachedSegments: Set<Int> { Set(managementLastLoad.keys) }
    var authorizationPending: Bool { managementAuthorizationPending }
    // PRODUCTION_METHODS
}

@main
struct LifecycleChecks {
    static func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    static func main() {
        // Repeated forced refreshes coalesce, bypass TTL, and suppress stale data.
        do {
            let provider = DeferredProvider()
            let controller = LifecycleHarness(provider)
            var completed = 0
            controller.loadManagementData(for: 3, force: false) { completed += 1 }
            controller.loadManagementData(for: 3, force: true) { completed += 1 }
            controller.loadManagementData(for: 3, force: true) { completed += 1 }
            precondition(provider.requests.count == 1)
            provider.requests[0].completion(.success(["active-before-stop"]))
            precondition(provider.requests.count == 2 && completed == 0)
            precondition(controller.inventoryPanel(for: 3).updates.isEmpty)
            provider.requests[1].completion(.success(["inactive-after-stop"]))
            precondition(controller.inventoryPanel(for: 3).updates == [["inactive-after-stop"]])
            precondition(completed == 3 && !controller.inventoryPanel(for: 3).loading)
        }

        // Both callback orders must converge on a post-action list, never old rows.
        for responseArrivesBeforeAction in [true, false] {
            let provider = DeferredProvider()
            let controller = LifecycleHarness(provider)
            controller.loadManagementData(for: 3, force: false)
            controller.executeInventoryAction(.service("stop", .init()), segment: 3)
            if responseArrivesBeforeAction {
                provider.requests[0].completion(.success(["active-before-stop"]))
                precondition(controller.inventoryPanel(for: 3).updates.isEmpty)
                provider.actions[0](.success(()))
            } else {
                provider.actions[0](.success(()))
                precondition(provider.requests.count == 1)
                provider.requests[0].completion(.failure(DeviceMetricsInventoryError.authorizationRequired))
            }
            precondition(provider.requests.count == 2)
            precondition(controller.inventoryPanel(for: 3).updates.isEmpty)
            precondition(controller.inventoryPanel(for: 3).failureCount == 0)
            provider.requests[1].completion(.success(["inactive-after-stop"]))
            precondition(controller.inventoryPanel(for: 3).updates == [["inactive-after-stop"]])
        }

        // A forced refresh requested during another segment's action is retained.
        do {
            let provider = DeferredProvider()
            let controller = LifecycleHarness(provider)
            controller.executeInventoryAction(.service("stop", .init()), segment: 3)
            controller.loadManagementData(for: 2, force: true)
            precondition(provider.requests.isEmpty)
            provider.actions[0](.success(()))
            precondition(provider.requests.map(\.segment).sorted() == [2, 3])
        }

        // A newly selected tab must load as soon as an action finishes,
        // including failure; it must not wait for the next resource timer.
        enum ActionFailure: Error { case failed }
        for succeeds in [true, false] {
            let provider = DeferredProvider()
            let controller = LifecycleHarness(provider)
            controller.executeInventoryAction(.service("stop", .init()), segment: 3)
            controller.inventoryTabControl.selectedSegment = 2
            controller.loadManagementData(for: 2, force: false)
            precondition(provider.requests.isEmpty)
            provider.actions[0](succeeds ? .success(()) : .failure(ActionFailure.failed))
            precondition(provider.requests.map(\.segment) == (succeeds ? [3, 2] : [2]))
            precondition(controller.inventoryPanel(for: 2).loading)
            provider.requests.last!.completion(.success(["selected-port"]))
            precondition(controller.inventoryPanel(for: 2).updates == [["selected-port"]])
        }

        // Rapid switches retain only the tab that is still visible. Returning
        // to overview must not turn the abandoned tab loads into warmup work.
        for finalSegment in [0, 4] {
            let provider = DeferredProvider()
            let controller = LifecycleHarness(provider)
            controller.executeInventoryAction(.service("stop", .init()), segment: 3)
            for selected in [2, 4, finalSegment] {
                controller.inventoryTabControl.selectedSegment = selected
                controller.loadManagementData(for: selected, force: false)
            }
            provider.actions[0](.success(()))
            precondition(provider.requests.map(\.segment) == (finalSegment == 0 ? [3] : [3, 4]))
        }

        // An explicit queued refresh already fulfils the deferred tab request.
        do {
            let provider = DeferredProvider()
            let controller = LifecycleHarness(provider)
            controller.executeInventoryAction(.service("stop", .init()), segment: 3)
            controller.inventoryTabControl.selectedSegment = 2
            controller.loadManagementData(for: 2, force: false)
            controller.loadManagementData(for: 2, force: true)
            provider.actions[0](.success(()))
            precondition(provider.requests.map(\.segment) == [3, 2])
            provider.requests[1].completion(.success(["fresh-port"]))
            precondition(provider.requests.count == 2 && controller.inventoryPanel(for: 2).updates == [["fresh-port"]])
        }

        // Deferred tab reads keep normal TTL semantics and join a request
        // that is already in flight instead of forcing another SSH command.
        for completesBeforeAction in [true, false] {
            let provider = DeferredProvider()
            let controller = LifecycleHarness(provider)
            controller.loadManagementData(for: 2, force: false)
            if completesBeforeAction { provider.requests[0].completion(.success(["cached-port"])) }
            controller.executeInventoryAction(.service("stop", .init()), segment: 3)
            controller.inventoryTabControl.selectedSegment = 2
            controller.loadManagementData(for: 2, force: false)
            provider.actions[0](.success(()))
            precondition(provider.requests.map(\.segment) == [2, 3])
        }

        // Hiding drops the added visible-tab work. The existing post-action
        // refresh of the mutated segment still follows its original behavior.
        for succeeds in [true, false] {
            let provider = DeferredProvider()
            let controller = LifecycleHarness(provider)
            controller.executeInventoryAction(.service("stop", .init()), segment: 3)
            controller.inventoryTabControl.selectedSegment = 2
            controller.loadManagementData(for: 2, force: false)
            controller.stopPolling()
            precondition(controller.hoverDetailPresenter.dismissalCount == 1,
                         "stopping dashboard polling must also dismiss the hover surface")
            provider.actions[0](succeeds ? .success(()) : .failure(ActionFailure.failed))
            precondition(provider.requests.map(\.segment) == (succeeds ? [3] : []))
            controller.startPollingIfNeeded()
            controller.loadManagementData(for: 2, force: false)
            precondition(provider.requests.last?.segment == 2)
        }

        // An invisible warmup request does not become deferred user work.
        do {
            let provider = DeferredProvider()
            let controller = LifecycleHarness(provider)
            controller.executeInventoryAction(.service("stop", .init()), segment: 3)
            controller.loadManagementData(for: 1, force: false)
            provider.actions[0](.success(()))
            precondition(provider.requests.map(\.segment) == [3])
        }

        // A synchronous authorization retry begins another mutation before
        // the first callback returns; keep the tab request until that ends.
        do {
            let provider = DeferredProvider()
            let controller = LifecycleHarness(provider)
            controller.retriesAuthorizationImmediately = true
            controller.executeInventoryAction(.service("stop", .init()), segment: 3)
            controller.inventoryTabControl.selectedSegment = 2
            controller.loadManagementData(for: 2, force: false)
            provider.actions[0](.failure(DeviceMetricsInventoryError.authorizationRequired))
            precondition(provider.actions.count == 2 && provider.requests.isEmpty)
            provider.actions[1](.success(()))
            precondition(provider.requests.map(\.segment) == [3, 2])
        }

        // Partial denial must keep polling the healthy engine, even if it was empty.
        for initialRows in [["docker-container"], []] {
            let provider = DeferredProvider()
            let controller = LifecycleHarness(provider)
            controller.loadManagementData(for: 4, force: false)
            provider.requests[0].completion(.failure(DeviceMetricsInventoryError.partialContainerInventory(initialRows, requiresAuthorization: true)))
            let panel = controller.inventoryPanel(for: 4)
            precondition(panel.updates == [initialRows] && panel.failureCount == 1)
            controller.expireManagementCache(for: 4)
            controller.loadManagementData(for: 4, force: false)
            precondition(provider.requests.count == 2)
            precondition(provider.authorizationRetries == 0, "automatic polling must not retry the denied engine")
            provider.requests[1].completion(.failure(DeviceMetricsInventoryError.partialContainerInventory(["docker-new"], requiresAuthorization: true)))
            precondition(panel.updates.last == ["docker-new"])
            controller.loadManagementData(for: 4, force: true)
            precondition(provider.requests.count == 3 && provider.authorizationRetries == 1)
            provider.requests[2].completion(.success(["docker-container", "podman-container"]))
            precondition(panel.updates.last == ["docker-container", "podman-container"] && !panel.loading)
        }

        // Ownership denial must not freeze the readable listening-port inventory.
        for initialRows in [["tcp:22"], []] {
            let provider = DeferredProvider()
            let controller = LifecycleHarness(provider)
            controller.loadManagementData(for: 2, force: false)
            provider.requests[0].completion(.failure(DeviceMetricsInventoryError.partialPortInventory(initialRows, requiresAuthorization: true)))
            let panel = controller.inventoryPanel(for: 2)
            precondition(panel.updates == [initialRows] && panel.failureCount == 1)
            controller.expireManagementCache(for: 2)
            controller.loadManagementData(for: 2, force: false)
            precondition(provider.requests.count == 2 && provider.authorizationRetries == 0)
            provider.requests[1].completion(.failure(DeviceMetricsInventoryError.partialPortInventory(["tcp:80"], requiresAuthorization: true)))
            precondition(panel.updates.last == ["tcp:80"])
            controller.loadManagementData(for: 2, force: true)
            precondition(provider.requests.count == 3 && provider.authorizationRetries == 1)
            provider.requests[2].completion(.success(["tcp:80 nginx"]))
            precondition(panel.updates.last == ["tcp:80 nginx"] && !panel.loading)
        }

        // Complete denial still pauses automatic reads until an explicit retry.
        for segment in [2, 4] {
            let provider = DeferredProvider()
            let controller = LifecycleHarness(provider)
            controller.loadManagementData(for: segment, force: false)
            provider.requests[0].completion(.failure(DeviceMetricsInventoryError.authorizationRequired))
            controller.expireManagementCache(for: segment)
            controller.loadManagementData(for: segment, force: false)
            precondition(provider.requests.count == 1 && provider.authorizationRetries == 0)
            controller.loadManagementData(for: segment, force: true)
            precondition(provider.requests.count == 2 && provider.authorizationRetries == 1)
            provider.requests[1].completion(.success([]))
        }

        // One successful validation invalidates every tab's denied state and
        // TTL. The origin retries immediately, with only one background list
        // at a time, preferring the currently visible tab.
        do {
            let provider = DeferredProvider()
            let controller = LifecycleHarness(provider)
            for segment in 1...4 {
                controller.loadManagementData(for: segment, force: false)
                provider.requests.last!.completion(.failure(DeviceMetricsInventoryError.authorizationRequired))
            }
            precondition(controller.deniedSegments == [1, 2, 3, 4])
            precondition(controller.cachedSegments == [1, 2, 3, 4])
            let oldGenerations = (1...4).map { controller.generation(for: $0) }
            controller.inventoryTabControl.selectedSegment = 3
            var retries = 0
            controller.authorizeManagement(password: "first", segment: 2) {
                retries += 1
                controller.loadManagementData(for: 2, force: false)
            }
            controller.authorizeManagement(password: "duplicate", segment: 4) { preconditionFailure("Duplicate validation ran") }
            controller.executeInventoryAction(.service("stop", .init()), segment: 3)
            precondition(provider.authorizations.count == 1 && provider.authorizations[0].password == "first")
            precondition(provider.actions.isEmpty && controller.authorizationPending)
            precondition(controller.inventoryPanels.values.allSatisfy(\.busy))
            provider.authorizations[0].completion(.success(()))
            precondition(retries == 1 && !controller.authorizationPending && controller.deniedSegments.isEmpty)
            precondition((1...4).allSatisfy { controller.generation(for: $0) > oldGenerations[$0 - 1] })
            precondition(controller.inventoryPanels.values.allSatisfy { $0.failure == nil && $0.authorizationClearCount == 1 && !$0.busy })
            precondition(controller.cachedSegments == [2, 3], "Unrefreshed tabs retained an obsolete TTL")
            precondition(provider.requests.map(\.segment) == [1, 2, 3, 4, 2, 3])
            provider.requests[5].completion(.success(["service-authorized"]))
            precondition(provider.requests.map(\.segment).suffix(3) == [2, 3, 1])
            provider.requests[4].completion(.success(["ports-authorized"]))
            precondition(provider.requests.count == 7, "Origin completion started a second background chain")
            provider.requests[6].completion(.success(["process-authorized"]))
            precondition(provider.requests.last?.segment == 4 && provider.requests.count == 8)
            provider.requests[7].completion(.success(["containers-authorized"]))
            precondition(controller.deniedSegments.isEmpty && controller.cachedSegments == [1, 2, 3, 4])
        }

        // A pre-authorization request can fail before validation completes or
        // after the new generation starts. Neither order may restore denied UI.
        for oldFailureArrivesBeforeValidation in [true, false] {
            let provider = DeferredProvider()
            let controller = LifecycleHarness(provider)
            controller.loadManagementData(for: 4, force: false)
            _ = controller.inventoryPanel(for: 2)
            controller.authorizeManagement(password: "new", segment: 2) {
                controller.loadManagementData(for: 2, force: true)
            }
            if oldFailureArrivesBeforeValidation {
                provider.requests[0].completion(.failure(DeviceMetricsInventoryError.authorizationRequired))
                precondition(controller.deniedSegments == [4])
            }
            provider.authorizations[0].completion(.success(()))
            precondition(controller.deniedSegments.isEmpty)
            let panel = controller.inventoryPanel(for: 4)
            let failuresAfterValidation = panel.failureCount
            if !oldFailureArrivesBeforeValidation {
                provider.requests[0].completion(.failure(DeviceMetricsInventoryError.authorizationRequired))
            }
            precondition(provider.requests.map(\.segment) == [4, 2, 4])
            precondition(panel.failure == nil && panel.failureCount == failuresAfterValidation)
            provider.requests[2].completion(.success(["new-container-scope"]))
            precondition(panel.updates == [["new-container-scope"]] && controller.deniedSegments.isEmpty)
            provider.requests[1].completion(.success(["new-ports"]))
        }

        // An explicit refresh queued on the old request retains its completion
        // exactly once, while authorization joins that same replacement load.
        for oldResponseArrivesDuringValidation in [true, false] {
            let provider = DeferredProvider()
            let controller = LifecycleHarness(provider)
            controller.loadManagementData(for: 4, force: false)
            var refreshCompleted = 0
            controller.loadManagementData(for: 4, force: true) { refreshCompleted += 1 }
            _ = controller.inventoryPanel(for: 2)
            _ = controller.inventoryPanel(for: 3)
            controller.inventoryTabControl.selectedSegment = 4
            controller.authorizeManagement(password: "new", segment: 2) {}
            if oldResponseArrivesDuringValidation {
                provider.requests[0].completion(.failure(DeviceMetricsInventoryError.authorizationRequired))
            }
            provider.authorizations[0].completion(.success(()))
            if !oldResponseArrivesDuringValidation {
                provider.requests[0].completion(.failure(DeviceMetricsInventoryError.authorizationRequired))
            }
            precondition(provider.requests.map(\.segment) == [4, 4] && refreshCompleted == 0)
            provider.requests[1].completion(.success(["fresh-container"]))
            precondition(refreshCompleted == 1 && provider.requests.map(\.segment) == [4, 4, 3])
            provider.requests[2].completion(.success(["fresh-service"]))
            precondition(refreshCompleted == 1 && controller.deniedSegments.isEmpty)
        }

        // Rejected validation neither retries a mutation nor fans out list
        // refreshes to other tabs; all busy state is released for user actions.
        do {
            let provider = DeferredProvider()
            let controller = LifecycleHarness(provider)
            for segment in 1...4 {
                let panel = controller.inventoryPanel(for: segment)
                panel.setFailure(DeviceMetricsInventoryError.authorizationRequired)
            }
            var retries = 0
            controller.authorizeManagement(password: "bad", segment: 2) { retries += 1 }
            provider.authorizations[0].completion(.failure(DeviceMetricsInventoryError.authorizationRequired))
            precondition(retries == 0 && provider.requests.isEmpty && provider.actions.isEmpty)
            precondition(!controller.authorizationPending && controller.inventoryPanels.values.allSatisfy { !$0.busy })
            precondition(controller.inventoryPanel(for: 2).failureCount == 2)
            precondition([1, 3, 4].allSatisfy { controller.inventoryPanel(for: $0).failureCount == 1 })
            precondition(controller.inventoryPanels.values.allSatisfy { $0.authorizationClearCount == 0 })
        }

        // A user-requested refresh queued during verification is still honored
        // after rejection, but does not trigger any other tab or retry closure.
        do {
            let provider = DeferredProvider()
            let controller = LifecycleHarness(provider)
            _ = controller.inventoryPanel(for: 2)
            _ = controller.inventoryPanel(for: 4)
            controller.authorizeManagement(password: "bad", segment: 2) { preconditionFailure("Rejected authorization retried") }
            var refreshCompleted = 0
            controller.loadManagementData(for: 4, force: true) { refreshCompleted += 1 }
            precondition(provider.requests.isEmpty)
            provider.authorizations[0].completion(.failure(DeviceMetricsInventoryError.authorizationRequired))
            precondition(provider.requests.map(\.segment) == [4])
            provider.requests[0].completion(.success(["explicit-refresh"]))
            precondition(refreshCompleted == 1 && provider.requests.count == 1)
        }

        // Hiding the panel stops the remainder of an authorization refresh
        // chain, even if its in-flight request completes after a new appearance.
        for reappearBeforeResponse in [false, true] {
            let provider = DeferredProvider()
            let controller = LifecycleHarness(provider)
            for segment in 1...4 { _ = controller.inventoryPanel(for: segment) }
            controller.inventoryTabControl.selectedSegment = 3
            controller.authorizeManagement(password: "ok", segment: 2) {}
            provider.authorizations[0].completion(.success(()))
            precondition(provider.requests.map(\.segment) == [3])
            controller.stopPolling()
            if reappearBeforeResponse { controller.startPollingIfNeeded() }
            provider.requests[0].completion(.success(["visible-service"]))
            precondition(provider.requests.map(\.segment) == [3], "Hidden authorization chain resumed")
        }

        // A confirmed mutation may request authorization once. Even a later
        // authentication failure must not automatically reopen the prompt.
        do {
            let provider = DeferredProvider()
            let controller = LifecycleHarness(provider)
            controller.usesDeferredAuthorization = true
            _ = controller.inventoryPanel(for: 3)
            controller.executeInventoryAction(.service("restart", .init()), segment: 3)
            controller.authorizeManagement(password: "during-action", segment: 3) { preconditionFailure("Validation raced an action") }
            precondition(provider.authorizations.isEmpty)
            provider.actions[0](.failure(DeviceMetricsInventoryError.authorizationRequired))
            precondition(provider.authorizations.count == 1 && controller.authorizationPromptCount == 1)
            controller.executeInventoryAction(.process("terminate", 42), segment: 1)
            precondition(provider.actions.count == 1, "Action raced credential verification")
            provider.authorizations[0].completion(.success(()))
            precondition(provider.actions.count == 2)
            provider.actions[1](.failure(DeviceMetricsInventoryError.authorizationRequired))
            precondition(provider.actions.count == 2 && provider.authorizations.count == 1
                         && controller.authorizationPromptCount == 1 && provider.requests.isEmpty)
        }

        // A rejected mutation authorization never executes the pending action.
        do {
            let provider = DeferredProvider()
            let controller = LifecycleHarness(provider)
            controller.usesDeferredAuthorization = true
            controller.executeInventoryAction(.process("pause", 99), segment: 1)
            provider.actions[0](.failure(DeviceMetricsInventoryError.authorizationRequired))
            provider.authorizations[0].completion(.failure(DeviceMetricsInventoryError.authorizationRequired))
            precondition(provider.actions.count == 1 && provider.requests.isEmpty && provider.authorizations.count == 1)
        }

        // Authorization retries retain the identity captured by the clicked row;
        // they must never look up a replacement process by PID after the prompt.
        do {
            let provider = DeferredProvider()
            let controller = LifecycleHarness(provider)
            controller.usesDeferredAuthorization = true
            controller.executeInventoryAction(.process("terminate", 42, "boot-100:start-20"), segment: 2)
            precondition(provider.processActionIdentities == ["boot-100:start-20"])
            provider.actions[0](.failure(DeviceMetricsInventoryError.authorizationRequired))
            provider.authorizations[0].completion(.success(()))
            precondition(provider.processActionIdentities == ["boot-100:start-20", "boot-100:start-20"])
            provider.actions[1](.success(()))
        }

        // Late overview completion after hiding may render but must not warm lists.
        do {
            let provider = DeferredProvider()
            let controller = LifecycleHarness(provider)
            controller.stopPolling()
            controller.scheduleManagementWarmupIfNeeded()
            pump(0.85)
            precondition(provider.requests.isEmpty)
            controller.startPollingIfNeeded()
            precondition(controller.refreshTimer == nil && controller.refreshCount == 0)
            controller.scheduleManagementWarmupIfNeeded()
            pump(0.85)
            precondition(provider.requests.map(\.segment) == [1])
            controller.stopPolling()
            provider.requests[0].completion(.success(["process"]))
            pump(0.25)
            precondition(provider.requests.map(\.segment) == [1])
        }

        // Stopping also cancels warmup that was scheduled before disappearance.
        do {
            let provider = DeferredProvider()
            let controller = LifecycleHarness(provider)
            controller.scheduleManagementWarmupIfNeeded()
            controller.stopPolling()
            pump(0.85)
            precondition(provider.requests.isEmpty)
        }
        print("PASS: forced refresh coalescing, stale-result rejection, action callback orders, deferred visible tabs, partial polling, shared sudo authorization across four tabs, ordered background refresh, delayed old failures, duplicate validation suppression, single action retry, authorization/action exclusion, hidden-chain cancellation")
    }
}
