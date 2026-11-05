import AppKit

@MainActor
enum AIProviderCredentialOriginConfirmationPresenter {
    static func confirm(_ request: AIProviderCredentialOriginConfirmationRequest) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.Settings.aiCredentialOriginConfirmationTitle
        alert.informativeText = """
        \(L10n.Settings.aiCredentialOriginProvider)：\(request.providerName)
        \(L10n.Settings.aiCredentialOriginDestination)：\(request.origin)
        \(L10n.Settings.aiCredentialOriginPurpose)：\(request.credentialPurpose)

        \(L10n.Settings.aiCredentialOriginConfirmationHelp)
        """
        alert.addButton(withTitle: L10n.Settings.aiCredentialOriginConfirm)
        alert.addButton(withTitle: L10n.Common.cancel)
        return alert.runModal() == .alertFirstButtonReturn
    }
}
