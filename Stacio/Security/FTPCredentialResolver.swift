import Foundation
import StacioCoreBindings

public enum FTPCredentialResolverError: Error, Equatable {
    case missingPasswordCredential
    case invalidPort(UInt32)
}

public protocol FTPCredentialResolving {
    func resolve(session: SessionRecord) throws -> FTPLiveSessionContext
}

public final class FTPCredentialResolver: FTPCredentialResolving {
    private let store: KeychainCredentialStore

    public init(store: KeychainCredentialStore) {
        self.store = store
    }

    public func resolve(session: SessionRecord) throws -> FTPLiveSessionContext {
        let username = session.username?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? "anonymous"
        let config = FtpConnectionConfig(
            host: session.host,
            port: try networkPort(session.port),
            username: username,
            connectTimeoutMs: 10_000
        )
        let secret: FtpAuthSecret
        if username == "anonymous" {
            secret = .anonymous
        } else if let credentialID = session.credentialId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        {
            secret = .password(
                value: try store.readSecret(
                    id: credentialID,
                    account: "\(username)@\(session.host)"
                )
            )
        } else {
            throw FTPCredentialResolverError.missingPasswordCredential
        }
        return FTPLiveSessionContext(config: config, secret: secret)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private func networkPort(_ port: UInt32) throws -> UInt16 {
    guard port > 0, port <= UInt32(UInt16.max) else {
        throw FTPCredentialResolverError.invalidPort(port)
    }
    return UInt16(port)
}
