import StacioCoreBindings

extension SshAuthSecret: CustomStringConvertible {
    public var description: String {
        switch self {
        case .password:
            "SshAuthSecret.password(value: [redacted])"
        case let .privateKey(_, passphrase):
            "SshAuthSecret.privateKey(privateKeyPem: [redacted], passphrase: \(passphrase == nil ? "nil" : "[redacted]"))"
        case .agent:
            "SshAuthSecret.agent"
        }
    }
}
