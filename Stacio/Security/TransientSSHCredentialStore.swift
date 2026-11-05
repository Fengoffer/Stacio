import Foundation

public final class TransientSSHCredentialStore {
    public static let shared = TransientSSHCredentialStore()

    private let lock = NSLock()
    private var secrets: [String: String] = [:]

    private init() {}

    public func store(password: String) -> String {
        let identifier = "transient-ssh-\(UUID().uuidString)"
        lock.lock()
        secrets[identifier] = password
        lock.unlock()
        return identifier
    }

    public func password(for identifier: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return secrets[identifier]
    }

    public func takePassword(for identifier: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return secrets.removeValue(forKey: identifier)
    }

    public func discardPassword(for identifier: String) {
        lock.lock()
        secrets.removeValue(forKey: identifier)
        lock.unlock()
    }
}
