import Foundation
import StacioCoreBindings

public enum ResolvedSSHCredentialKind: Equatable {
    case password
    case privateKeyPassphrase
    case agent
}

public struct ResolvedSSHCredential: CustomStringConvertible, Equatable {
    public let kind: ResolvedSSHCredentialKind
    public let primarySecret: String?

    public init(kind: ResolvedSSHCredentialKind, primarySecret: String?) {
        self.kind = kind
        self.primarySecret = primarySecret
    }

    public var description: String {
        "ResolvedSSHCredential(kind: \(kind), primarySecret: \(primarySecret == nil ? "nil" : "[redacted]"))"
    }
}

public final class SSHCredentialResolver {
    private let store: KeychainCredentialStore

    public init(store: KeychainCredentialStore) {
        self.store = store
    }

    public func resolve(_ config: SshConnectionConfig) throws -> ResolvedSSHCredential {
        switch config.authMethod {
        case let .password(credentialRef):
            let secret = try store.readSecret(
                id: credentialRef,
                account: account(for: config)
            )
            return ResolvedSSHCredential(kind: .password, primarySecret: secret)
        case let .privateKey(_, passphraseRef):
            guard let passphraseRef else {
                return ResolvedSSHCredential(kind: .privateKeyPassphrase, primarySecret: nil)
            }
            let passphrase = try store.readSecret(
                id: passphraseRef,
                account: account(for: config)
            )
            return ResolvedSSHCredential(kind: .privateKeyPassphrase, primarySecret: passphrase)
        case .agent:
            return ResolvedSSHCredential(kind: .agent, primarySecret: nil)
        }
    }

    private func account(for config: SshConnectionConfig) -> String {
        "\(config.username)@\(config.host)"
    }
}
