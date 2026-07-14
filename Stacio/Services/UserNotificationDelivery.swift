import Foundation
import UserNotifications

public struct StacioUserNotificationPayload: Equatable {
    public let identifier: String
    public let title: String
    public let body: String
    public let runtimeID: String

    public init(identifier: String, title: String, body: String, runtimeID: String) {
        self.identifier = identifier
        self.title = title
        self.body = body
        self.runtimeID = runtimeID
    }
}

public protocol StacioUserNotificationDelivering: AnyObject {
    func deliver(_ payload: StacioUserNotificationPayload)
    func setActivationHandler(_ handler: @escaping (String) -> Void)
}

public final class NoopStacioUserNotificationDelivery: StacioUserNotificationDelivering {
    public init() {}
    public func deliver(_ payload: StacioUserNotificationPayload) {}
    public func setActivationHandler(_ handler: @escaping (String) -> Void) {}
}

public final class UserNotificationDelivery: NSObject, StacioUserNotificationDelivering, UNUserNotificationCenterDelegate {
    public static let shared = UserNotificationDelivery()

    private let center: UNUserNotificationCenter
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
        activationHandler = handler
    }

    public func deliver(_ payload: StacioUserNotificationPayload) {
        center.getNotificationSettings { [weak self] settings in
            guard let self else { return }
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                self.post(payload)
            case .notDetermined:
                self.center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    guard granted else { return }
                    self.post(payload)
                }
            case .denied:
                return
            @unknown default:
                return
            }
        }
    }

    private func post(_ payload: StacioUserNotificationPayload) {
        let content = UNMutableNotificationContent()
        content.title = payload.title
        content.body = payload.body
        content.sound = .default
        content.userInfo = ["runtimeID": payload.runtimeID]
        let request = UNNotificationRequest(
            identifier: payload.identifier,
            content: content,
            trigger: nil
        )
        center.add(request)
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let runtimeID = response.notification.request.content.userInfo["runtimeID"] as? String
        DispatchQueue.main.async { [activationHandler] in
            if let runtimeID, runtimeID.isEmpty == false {
                activationHandler(runtimeID)
            }
            completionHandler()
        }
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if #available(macOS 11.0, *) {
            completionHandler([.banner, .sound])
        } else {
            completionHandler([.alert, .sound])
        }
    }
}
