import Foundation

public enum RemoteFileReadSessionError: Error, LocalizedError, Equatable, Sendable {
    case closed

    public var errorDescription: String? {
        switch self {
        case .closed:
            return "远端文件读取会话已关闭。"
        }
    }
}

/// Owns the lifetime of one authenticated SCP/SFTP read connection.
///
/// The operation closures are deliberately small so the same abstraction can
/// use the native libssh2 session when available and fall back to the existing
/// stateless bridge on older cores or in tests.
public final class RemoteFileReadSession: @unchecked Sendable {
    public typealias ReadOperation = @Sendable (
        _ remotePath: String,
        _ offset: UInt64,
        _ length: UInt64?
    ) throws -> Data
    public typealias CloseOperation = @Sendable () -> Void

    private let lock = NSLock()
    private let readOperation: ReadOperation
    private let closeOperation: CloseOperation
    private var closed = false

    public init(
        read: @escaping ReadOperation,
        close: @escaping CloseOperation = {}
    ) {
        self.readOperation = read
        self.closeOperation = close
    }

    public func read(
        remotePath: String,
        offset: UInt64,
        length: UInt64?
    ) throws -> Data {
        lock.lock()
        let isClosed = closed
        lock.unlock()
        guard !isClosed else {
            throw RemoteFileReadSessionError.closed
        }
        return try readOperation(remotePath, offset, length)
    }

    public func close() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        lock.unlock()
        closeOperation()
    }

    public var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    /// Defers the native connection handshake until the first background read.
    /// Opening a preview must never block the main AppKit window while the
    /// session is being prepared.
    public static func deferred(
        open: @escaping @Sendable () throws -> RemoteFileReadSession?,
        fallback: @escaping ReadOperation
    ) -> RemoteFileReadSession {
        let state = DeferredState(open: open, fallback: fallback)
        return RemoteFileReadSession(
            read: { remotePath, offset, length in
                try state.read(remotePath: remotePath, offset: offset, length: length)
            },
            close: {
                state.close()
            }
        )
    }

    deinit {
        close()
    }
}

public extension RemoteFileReadSession {
    static func stateless(read: @escaping ReadOperation) -> RemoteFileReadSession {
        RemoteFileReadSession(read: read)
    }
}

private final class DeferredState: @unchecked Sendable {
    private let condition = NSCondition()
    private let open: @Sendable () throws -> RemoteFileReadSession?
    private let fallback: RemoteFileReadSession.ReadOperation
    private var attemptedOpen = false
    private var opening = false
    private var session: RemoteFileReadSession?
    private var closed = false

    init(
        open: @escaping @Sendable () throws -> RemoteFileReadSession?,
        fallback: @escaping RemoteFileReadSession.ReadOperation
    ) {
        self.open = open
        self.fallback = fallback
    }

    func read(remotePath: String, offset: UInt64, length: UInt64?) throws -> Data {
        condition.lock()
        while opening && !closed {
            condition.wait()
        }
        guard !closed else {
            condition.unlock()
            throw RemoteFileReadSessionError.closed
        }
        if let session {
            condition.unlock()
            return try session.read(remotePath: remotePath, offset: offset, length: length)
        }
        guard !attemptedOpen else {
            condition.unlock()
            return try fallback(remotePath, offset, length)
        }
        attemptedOpen = true
        opening = true
        condition.unlock()

        let opened: RemoteFileReadSession?
        do {
            opened = try open()
        } catch {
            opened = nil
        }

        condition.lock()
        opening = false
        let didCloseWhileOpening = closed
        if !didCloseWhileOpening {
            session = opened
        }
        condition.broadcast()
        condition.unlock()

        if didCloseWhileOpening {
            opened?.close()
            throw RemoteFileReadSessionError.closed
        }
        if let opened {
            return try opened.read(remotePath: remotePath, offset: offset, length: length)
        }
        return try fallback(remotePath, offset, length)
    }

    func close() {
        condition.lock()
        guard !closed else {
            condition.unlock()
            return
        }
        closed = true
        let session = self.session
        self.session = nil
        condition.broadcast()
        condition.unlock()
        session?.close()
    }
}
