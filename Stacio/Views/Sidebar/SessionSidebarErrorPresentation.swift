import AppKit

public enum SessionSidebarErrorContext: Equatable {
    case createSession
    case updateSession
    case duplicateSession
    case moveSession
    case exportSessions
    case createFolder
    case updateFolder
    case deleteFolder
    case pingHost
    case createDesktopShortcut
    case saveDefaultPreset
    case copySessionSettings
    case deleteSession
    case sessionEditor
    case openSession

    var messageText: String {
        switch self {
        case .createSession:
            return L10n.SessionErrors.createTitle
        case .updateSession:
            return L10n.SessionErrors.updateTitle
        case .duplicateSession:
            return L10n.SessionErrors.duplicateTitle
        case .moveSession:
            return L10n.SessionErrors.moveTitle
        case .exportSessions:
            return L10n.SessionErrors.exportTitle
        case .createFolder:
            return L10n.SessionErrors.createFolderTitle
        case .updateFolder:
            return L10n.SessionErrors.updateFolderTitle
        case .deleteFolder:
            return L10n.SessionErrors.deleteFolderTitle
        case .pingHost:
            return L10n.SessionErrors.pingTitle
        case .createDesktopShortcut:
            return L10n.SessionErrors.shortcutTitle
        case .saveDefaultPreset:
            return L10n.SessionErrors.defaultPresetTitle
        case .copySessionSettings:
            return L10n.SessionErrors.copySettingsTitle
        case .deleteSession:
            return L10n.SessionErrors.deleteTitle
        case .sessionEditor:
            return L10n.SessionErrors.saveTitle
        case .openSession:
            return L10n.SessionErrors.openTitle
        }
    }

    func informativeText(for error: Error) -> String {
        if let validation = error as? SessionSidebarSessionDraftValidationError {
            return validation.localizedDescription
        }
        if let factory = error as? SessionSidebarSessionDraftFactoryError {
            switch factory {
            case .credentialSaverUnavailable:
                return L10n.SessionErrors.credentialStorageUnavailable
            }
        }
        if let keychain = error as? KeychainCredentialError {
            switch keychain {
            case .notFound:
                return L10n.SessionErrors.keychainNotFound
            case .invalidSecretEncoding:
                return L10n.SessionErrors.invalidSecretEncoding
            case .accessDenied:
                return L10n.SessionErrors.keychainAccessDenied
            case .storageUnavailable:
                return L10n.SessionErrors.keychainAccessDenied
            case .invalidVaultFormat, .cryptoFailure:
                return L10n.SessionErrors.credentialVaultCorrupted
            }
        }
        switch self {
        case .createSession:
            return L10n.SessionErrors.createMessage
        case .updateSession:
            return L10n.SessionErrors.updateMessage
        case .duplicateSession:
            return L10n.SessionErrors.duplicateMessage
        case .moveSession:
            return L10n.SessionErrors.moveMessage
        case .exportSessions:
            return L10n.SessionErrors.exportMessage
        case .createFolder:
            return L10n.SessionErrors.createFolderMessage
        case .updateFolder:
            return L10n.SessionErrors.updateFolderMessage
        case .deleteFolder:
            return L10n.SessionErrors.deleteFolderMessage
        case .pingHost:
            let description = RuntimeDiagnosticFormatter
                .userMessage(for: error)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return description.isEmpty ? L10n.SessionErrors.pingMessage : description
        case .createDesktopShortcut:
            return L10n.SessionErrors.shortcutMessage
        case .saveDefaultPreset:
            return L10n.SessionErrors.defaultPresetMessage
        case .copySessionSettings:
            return L10n.SessionErrors.copySettingsMessage
        case .deleteSession:
            return L10n.SessionErrors.deleteMessage
        case .sessionEditor:
            return L10n.SessionErrors.saveMessage
        case .openSession:
            let description = RuntimeDiagnosticFormatter
                .userMessage(for: error)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return description.isEmpty ? L10n.SessionErrors.openMessage : description
        }
    }
}

@MainActor
public protocol SessionSidebarErrorPresenting {
    func present(_ error: Error, context: SessionSidebarErrorContext, parentWindow: NSWindow?)
}

@MainActor
public final class AppKitSessionSidebarErrorPresenter: SessionSidebarErrorPresenting {
    public init() {}

    public func present(_ error: Error, context: SessionSidebarErrorContext, parentWindow: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = context.messageText
        alert.informativeText = context.informativeText(for: error)
        alert.addButton(withTitle: L10n.Common.ok)
        if let parentWindow {
            alert.beginSheetModal(for: parentWindow)
        } else {
            alert.runModal()
        }
    }
}
