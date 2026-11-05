import Foundation

public struct TerminalCommandCompletionNotificationPayload: Equatable {
    public let identifier: String
    public let runtimeID: String
    public let title: String
    public let body: String

    public init(identifier: String, runtimeID: String, title: String, body: String) {
        self.identifier = identifier
        self.runtimeID = runtimeID
        self.title = title
        self.body = body
    }
}

public protocol TerminalCommandCompletionNotificationDelivering: AnyObject {
    func deliver(_ payload: TerminalCommandCompletionNotificationPayload)
}

public final class NoopTerminalCommandCompletionNotifier: TerminalCommandCompletionNotificationDelivering {
    public init() {}
    public func deliver(_ payload: TerminalCommandCompletionNotificationPayload) {}
}

public final class StacioUserNotificationTerminalCommandCompletionNotifier: TerminalCommandCompletionNotificationDelivering {
    private let delivery: StacioUserNotificationDelivering

    public init(delivery: StacioUserNotificationDelivering) {
        self.delivery = delivery
    }

    public func deliver(_ payload: TerminalCommandCompletionNotificationPayload) {
        delivery.deliver(StacioUserNotificationPayload(
            identifier: payload.identifier,
            title: payload.title,
            body: payload.body,
            runtimeID: payload.runtimeID
        ))
    }
}

public final class TerminalCommandCompletionNotificationCoordinator {
    private struct PendingCommand {
        let command: String
        let sessionTitle: String
        let startedAt: Date
    }

    private let settingsProvider: () -> AppSettings
    private let dateProvider: () -> Date
    private let activeTerminalProvider: (String) -> Bool
    private let notifier: TerminalCommandCompletionNotificationDelivering
    private var pendingCommandsByRuntimeID: [String: PendingCommand] = [:]

    public init(
        settingsProvider: @escaping () -> AppSettings,
        dateProvider: @escaping () -> Date = Date.init,
        activeTerminalProvider: @escaping (String) -> Bool,
        notifier: TerminalCommandCompletionNotificationDelivering
    ) {
        self.settingsProvider = settingsProvider
        self.dateProvider = dateProvider
        self.activeTerminalProvider = activeTerminalProvider
        self.notifier = notifier
    }

    public func commandDidStart(runtimeID: String, sessionTitle: String, command rawCommand: String) {
        let command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionTitle = sessionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard runtimeID.isEmpty == false,
              command.isEmpty == false
        else {
            return
        }
        pendingCommandsByRuntimeID[runtimeID] = PendingCommand(
            command: command,
            sessionTitle: sessionTitle.isEmpty ? runtimeID : sessionTitle,
            startedAt: dateProvider()
        )
    }

    public func commandDidFinish(runtimeID: String, sessionTitle fallbackSessionTitle: String) {
        guard let pending = pendingCommandsByRuntimeID.removeValue(forKey: runtimeID) else {
            return
        }

        let settings = settingsProvider()
        guard settings.terminalCommandCompletionNotificationEnabled else {
            return
        }

        let elapsed = dateProvider().timeIntervalSince(pending.startedAt)
        let threshold = TimeInterval(settings.terminalCommandCompletionNotificationThresholdSeconds)
        guard elapsed >= threshold,
              activeTerminalProvider(runtimeID) == false
        else {
            return
        }

        let sessionTitle = pending.sessionTitle.isEmpty
            ? fallbackSessionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            : pending.sessionTitle
        let payload = TerminalCommandCompletionNotificationPayload(
            identifier: "Stacio.commandCompletion.\(runtimeID).\(Int(pending.startedAt.timeIntervalSince1970 * 1_000))",
            runtimeID: runtimeID,
            title: L10n.TerminalNotifications.commandCompletedTitle,
            body: L10n.TerminalNotifications.commandCompletedBody(
                command: Self.truncatedCommand(pending.command),
                sessionTitle: sessionTitle.isEmpty ? runtimeID : sessionTitle
            )
        )
        notifier.deliver(payload)
    }

    private static func truncatedCommand(_ command: String) -> String {
        String(command.prefix(80))
    }
}

public final class UserNotificationTerminalCommandCompletionNotifier: TerminalCommandCompletionNotificationDelivering {
    public static let shared = UserNotificationTerminalCommandCompletionNotifier()

    private let backing: StacioUserNotificationTerminalCommandCompletionNotifier
    private let delivery: StacioUserNotificationDelivering

    public init(
        delivery: StacioUserNotificationDelivering = UserNotificationDelivery.shared,
        activationHandler: @escaping (String) -> Void = { _ in }
    ) {
        self.delivery = delivery
        self.backing = StacioUserNotificationTerminalCommandCompletionNotifier(delivery: delivery)
        delivery.setActivationHandler(activationHandler)
    }

    public func setActivationHandler(_ handler: @escaping (String) -> Void) {
        delivery.setActivationHandler(handler)
    }

    public func deliver(_ payload: TerminalCommandCompletionNotificationPayload) {
        backing.deliver(payload)
    }
}
