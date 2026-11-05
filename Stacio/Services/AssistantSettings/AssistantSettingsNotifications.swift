import Foundation

/// Published only after the durable troubleshooting-assistant setting owner
/// has accepted the new value.
public extension Notification.Name {
    static let stacioAssistantSettingsDidChange = Notification.Name(
        "Stacio.AssistantSettings.didChange"
    )
}
