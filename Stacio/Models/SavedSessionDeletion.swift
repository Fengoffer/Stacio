import Foundation

extension Notification.Name {
    static let stacioSavedSessionsDidDelete = Notification.Name("Stacio.SavedSessions.didDelete")
}

enum SavedSessionDeletionNotification {
    static let sessionIDsUserInfoKey = "sessionIDs"

    static func post(
        sessionIDs: Set<String>,
        center: NotificationCenter = .default
    ) {
        let normalizedIDs = sessionIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
            .sorted()
        guard normalizedIDs.isEmpty == false else { return }
        center.post(
            name: .stacioSavedSessionsDidDelete,
            object: nil,
            userInfo: [sessionIDsUserInfoKey: normalizedIDs]
        )
    }

    static func sessionIDs(from notification: Notification) -> Set<String> {
        Set(
            (notification.userInfo?[sessionIDsUserInfoKey] as? [String] ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.isEmpty == false }
        )
    }
}
