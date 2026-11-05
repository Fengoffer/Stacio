import AppKit
import StacioCoreBindings

public enum HostKeyConfirmationReason: Equatable {
    case unknown
    case changed(previousFingerprintSHA256: String)
}

public struct HostKeyConfirmation: Equatable {
    public let host: String
    public let port: UInt16
    public let fingerprintSHA256: String
    public let reason: HostKeyConfirmationReason

    public init(
        host: String,
        port: UInt16,
        fingerprintSHA256: String,
        reason: HostKeyConfirmationReason
    ) {
        self.host = host
        self.port = port
        self.fingerprintSHA256 = fingerprintSHA256
        self.reason = reason
    }
}

public enum HostKeyConfirmationDecision: Equatable {
    case trust
    case reject
}

public enum HostKeyConfirmationPresenter {
    public static func makeAlert(for confirmation: HostKeyConfirmation) -> NSAlert {
        let alert = NSAlert()

        switch confirmation.reason {
        case .unknown:
            alert.alertStyle = .warning
            alert.messageText = L10n.HostKey.unknownTitle(host: confirmation.host)
            alert.informativeText = L10n.HostKey.unknownMessage(
                host: confirmation.host,
                port: confirmation.port,
                fingerprint: confirmation.fingerprintSHA256
            )
            alert.addButton(withTitle: L10n.HostKey.trust)
            alert.addButton(withTitle: L10n.Common.cancel)
        case let .changed(previousFingerprintSHA256):
            alert.alertStyle = .critical
            alert.messageText = L10n.HostKey.changedTitle(host: confirmation.host)
            alert.informativeText = L10n.HostKey.changedMessage(
                host: confirmation.host,
                port: confirmation.port,
                previous: previousFingerprintSHA256,
                new: confirmation.fingerprintSHA256
            )
            alert.addButton(withTitle: L10n.HostKey.reject)
            alert.addButton(withTitle: L10n.HostKey.trustNew)
        }

        return alert
    }
}

public struct AppKitHostKeyConfirmer: HostKeyConfirming {
    public init() {}

    public func confirm(_ confirmation: HostKeyConfirmation) throws -> HostKeyTrustDecision {
        if Thread.isMainThread {
            return Self.confirmOnMainThread(confirmation)
        }
        return DispatchQueue.main.sync {
            Self.confirmOnMainThread(confirmation)
        }
    }

    private static func confirmOnMainThread(_ confirmation: HostKeyConfirmation) -> HostKeyTrustDecision {
        let alert = HostKeyConfirmationPresenter.makeAlert(for: confirmation)
        let response = alert.runModal()
        switch confirmation.reason {
        case .unknown:
            return response == .alertFirstButtonReturn ? .trustAndSave : .reject
        case .changed:
            return response == .alertSecondButtonReturn ? .trustAndSave : .reject
        }
    }
}
