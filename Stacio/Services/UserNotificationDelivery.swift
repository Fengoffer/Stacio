import Foundation
import UserNotifications

public enum StacioUserNotificationRetentionPolicy: Equatable {
    case uniqueAutomatic
    case replaceableAutomatic
    case explicitRemoval
}

public struct StacioUserNotificationPayload: Equatable {
    public let identifier: String
    public let title: String
    public let body: String
    public let runtimeID: String
    public let retentionPolicy: StacioUserNotificationRetentionPolicy

    public init(
        identifier: String,
        title: String,
        body: String,
        runtimeID: String,
        retentionPolicy: StacioUserNotificationRetentionPolicy = .uniqueAutomatic
    ) {
        self.identifier = identifier
        self.title = title
        self.body = body
        self.runtimeID = runtimeID
        self.retentionPolicy = retentionPolicy
    }
}

public protocol StacioUserNotificationDelivering: AnyObject {
    func deliver(_ payload: StacioUserNotificationPayload)
    func setActivationHandler(_ handler: @escaping (String) -> Void)
    func removeNotifications(identifiers: [String])
}

public extension StacioUserNotificationDelivering {
    func removeNotifications(identifiers: [String]) {}
}

public final class NoopStacioUserNotificationDelivery: StacioUserNotificationDelivering {
    public init() {}
    public func deliver(_ payload: StacioUserNotificationPayload) {}
    public func setActivationHandler(_ handler: @escaping (String) -> Void) {}
}

public final class UserNotificationDelivery: NSObject, StacioUserNotificationDelivering, UNUserNotificationCenterDelegate {
    public static let shared = UserNotificationDelivery()

    private let center: UNUserNotificationCenter
    private let deliveryGenerationGate = NotificationDeliveryGenerationGate()
    private let activationHandlerLock = NSLock()
    private var activationHandler: (String) -> Void

    public init(
        center: UNUserNotificationCenter = .current(),
        activationHandler: @escaping (String) -> Void = { _ in }
    ) {
        self.center = center
        self.activationHandler = activationHandler
        super.init()
        center.delegate = self
    }

    public func setActivationHandler(_ handler: @escaping (String) -> Void) {
        activationHandlerLock.lock()
        defer { activationHandlerLock.unlock() }
        activationHandler = handler
    }

    public func removeNotifications(identifiers: [String]) {
        guard identifiers.isEmpty == false else { return }
        let physicalIdentifiers = deliveryGenerationGate.invalidate(identifiers: identifiers)
        let requestIdentifiers = Array(Set(identifiers + physicalIdentifiers))
        center.removePendingNotificationRequests(withIdentifiers: requestIdentifiers)
        center.removeDeliveredNotifications(withIdentifiers: requestIdentifiers)
    }

    public func deliver(_ payload: StacioUserNotificationPayload) {
        let registration = deliveryGenerationGate.begin(identifier: payload.identifier)
        if registration.supersededPhysicalIdentifiers.isEmpty == false {
            center.removePendingNotificationRequests(
                withIdentifiers: registration.supersededPhysicalIdentifiers
            )
            center.removeDeliveredNotifications(
                withIdentifiers: registration.supersededPhysicalIdentifiers
            )
        }
        center.getNotificationSettings { [weak self] settings in
            guard let self else { return }
            guard self.deliveryGenerationGate.isCurrent(registration.token) else { return }
            if settings.alertSetting == .disabled {
                StacioLogStore.shared.append(
                    level: .warning,
                    category: "Notifications",
                    message: "macOS notification banners are disabled for Stacio; notification center delivery may be sound-only."
                )
            }
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                self.post(payload, token: registration.token)
            case .notDetermined:
                self.center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    guard granted else {
                        self.deliveryGenerationGate.finish(registration.token)
                        return
                    }
                    self.post(payload, token: registration.token)
                }
            case .denied:
                self.deliveryGenerationGate.finish(registration.token)
                return
            @unknown default:
                self.deliveryGenerationGate.finish(registration.token)
                return
            }
        }
    }

    private func post(
        _ payload: StacioUserNotificationPayload,
        token: NotificationDeliveryGenerationGate.Token
    ) {
        guard deliveryGenerationGate.isCurrent(token) else { return }
        let content = UNMutableNotificationContent()
        content.title = payload.title
        content.body = payload.body
        content.sound = .default
        content.userInfo = ["runtimeID": payload.runtimeID]
        let request = UNNotificationRequest(
            identifier: token.physicalIdentifier,
            content: content,
            trigger: nil
        )
        center.add(request) { [weak self] error in
            guard let self else { return }
            if self.deliveryGenerationGate.isCurrent(token) == false {
                self.center.removePendingNotificationRequests(withIdentifiers: [token.physicalIdentifier])
                self.center.removeDeliveredNotifications(withIdentifiers: [token.physicalIdentifier])
            }
            if let error {
                self.deliveryGenerationGate.finish(token)
                StacioLogStore.shared.append(
                    level: .warning,
                    category: "Notifications",
                    message: "Failed to deliver notification: \(error.localizedDescription)"
                )
            } else if payload.retentionPolicy == .uniqueAutomatic {
                self.deliveryGenerationGate.finish(token)
            }
        }
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let runtimeID = response.notification.request.content.userInfo["runtimeID"] as? String
        let activationHandler = currentActivationHandler()
        DispatchQueue.main.async {
            if let runtimeID, runtimeID.isEmpty == false {
                activationHandler(runtimeID)
            }
            completionHandler()
        }
    }

    private func currentActivationHandler() -> (String) -> Void {
        activationHandlerLock.lock()
        defer { activationHandlerLock.unlock() }
        return activationHandler
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if #available(macOS 11.0, *) {
            completionHandler([.banner, .list, .sound])
        } else {
            completionHandler([.alert, .sound])
        }
    }
}

final class NotificationDeliveryGenerationGate {
    struct Token: Equatable {
        let logicalIdentifier: String
        let generation: UInt64

        var physicalIdentifier: String {
            "\(logicalIdentifier).generation.\(generation)"
        }
    }

    struct Registration: Equatable {
        let token: Token
        let supersededPhysicalIdentifiers: [String]
    }

    private let lock = NSLock()
    private var nextGeneration: UInt64 = 0
    private var generationsByIdentifier: [String: UInt64] = [:]

    var trackedIdentifierCountForTesting: Int {
        lock.lock()
        defer { lock.unlock() }
        return generationsByIdentifier.count
    }

    func begin(identifier: String) -> Registration {
        lock.lock()
        defer { lock.unlock() }
        let supersededPhysicalIdentifiers = generationsByIdentifier[identifier].map {
            Token(logicalIdentifier: identifier, generation: $0).physicalIdentifier
        }.map { [$0] } ?? []
        nextGeneration &+= 1
        generationsByIdentifier[identifier] = nextGeneration
        return Registration(
            token: Token(logicalIdentifier: identifier, generation: nextGeneration),
            supersededPhysicalIdentifiers: supersededPhysicalIdentifiers
        )
    }

    func invalidate(identifiers: [String]) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        var physicalIdentifiers: [String] = []
        for identifier in identifiers {
            if let generation = generationsByIdentifier[identifier] {
                physicalIdentifiers.append(Token(
                    logicalIdentifier: identifier,
                    generation: generation
                ).physicalIdentifier)
            }
            generationsByIdentifier[identifier] = nil
        }
        return physicalIdentifiers
    }

    func isCurrent(_ token: Token) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generationsByIdentifier[token.logicalIdentifier] == token.generation
    }

    func finish(_ token: Token) {
        lock.lock()
        defer { lock.unlock() }
        guard generationsByIdentifier[token.logicalIdentifier] == token.generation else {
            return
        }
        generationsByIdentifier[token.logicalIdentifier] = nil
    }
}
