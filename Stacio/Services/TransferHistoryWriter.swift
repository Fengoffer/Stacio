import Foundation

/// All handles to a database share the same ordering, including history reads and deletes.
final class TransferHistoryWriter: @unchecked Sendable {
    static let shared = TransferHistoryWriter()
    private struct Key: Hashable {
        let database: String
        let jobID: String
    }
    private let queue = DispatchQueue(label: "Stacio.transfer-history", qos: .utility)
    private let queueKey = DispatchSpecificKey<Bool>()
    // Accessed only on queue. Each active job has at most one pending progress sample.
    private var pending: [Key: () -> Void] = [:]
    private var flushScheduled = false

    private init() { queue.setSpecific(key: queueKey, value: true) }

    func submit(database: String, jobID: String, coalescing: Bool, _ write: @escaping () -> Void) {
        let key = Key(database: database, jobID: jobID)
        queue.async {
            guard coalescing else {
                self.pending.removeValue(forKey: key)?()
                write()
                return
            }
            self.pending[key] = write
            guard !self.flushScheduled else { return }
            self.flushScheduled = true
            self.queue.asyncAfter(deadline: .now() + 0.5) {
                self.flushScheduled = false
                self.flush(database: nil)
            }
        }
    }

    func ordered<T>(database: String?, _ action: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return try action() }
        return try queue.sync {
            flush(database: database)
            return try action()
        }
    }

    func perform<T>(database: String, _ action: @escaping () throws -> T,
                    completion: @escaping @MainActor (Result<T, Error>) -> Void) {
        queue.async {
            self.flush(database: database)
            let result = Result { try action() }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func flush(database: String?) {
        for key in Array(pending.keys) where database == nil || key.database == database {
            pending.removeValue(forKey: key)?()
        }
    }
}
