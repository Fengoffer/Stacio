import Foundation

public enum ConfigurationDeleteActionRouterError: Error, Equatable {
    case duplicateKind(ConfigurationKind)
}

/// `configuration.delete` has one Action owner, while each configuration
/// domain retains its own deletion invariants and persistence. Dispatch is
/// based only on the closed `ConfigurationKind` value carried by the request.
public final class ConfigurationDeleteActionRouter {
    private struct Route {
        let registrationID: UUID
        let owner: AssistantSettingsActionOwner
    }

    private let lock = NSLock()
    private var routes: [ConfigurationKind: Route] = [:]

    public init() {}

    @discardableResult
    public func registerOwner(
        for kind: ConfigurationKind,
        owner: @escaping AssistantSettingsActionOwner
    ) throws -> UUID {
        lock.lock()
        defer { lock.unlock() }
        guard routes[kind] == nil else {
            throw ConfigurationDeleteActionRouterError.duplicateKind(kind)
        }
        let registrationID = UUID()
        routes[kind] = Route(registrationID: registrationID, owner: owner)
        return registrationID
    }

    public func unregisterOwner(for kind: ConfigurationKind, registrationID: UUID) {
        lock.lock()
        if routes[kind]?.registrationID == registrationID {
            routes.removeValue(forKey: kind)
        }
        lock.unlock()
    }

    public func hasOwner(for kind: ConfigurationKind) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return routes[kind] != nil
    }

    public func registerActionOwner(in coordinator: AssistantSettingsActionCoordinator) throws {
        try coordinator.registerOwner(for: "configuration.delete") { [self] request, completion in
            route(request, completion: completion)
        }
    }

    private func route(
        _ request: AssistantSettingsActionRequest,
        completion: @escaping (AssistantSettingsActionExecutionResult) -> Void
    ) {
        guard request.actionID == "configuration.delete",
              case .string(let rawKind) = request.parameters["configurationKind"],
              let kind = ConfigurationKind(rawValue: rawKind)
        else {
            completion(.failed(reasonCode: "invalid_configuration_delete_kind"))
            return
        }

        lock.lock()
        let owner = routes[kind]?.owner
        lock.unlock()
        guard let owner else {
            completion(.failed(reasonCode: "configuration_delete_owner_unavailable"))
            return
        }
        owner(request, completion)
    }
}
