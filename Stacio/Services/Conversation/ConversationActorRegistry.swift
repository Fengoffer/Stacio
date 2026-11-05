import Foundation

// MARK: - ConversationActorRegistry（跨窗口/场景同一会话同一 Actor）

/// 会话 Actor 单例映射：任何窗口/场景对同一 `sessionID` 都拿到同一写入者。
/// Registry stores weak entries: live bridges retain their Actor, while closing
/// the final view releases the Repository/SQLite handle automatically.
public final class ConversationActorRegistry {
    public static let shared = ConversationActorRegistry()

    private let lock = NSLock()
    private final class WeakActorBox {
        weak var value: ConversationSessionActor?

        init(_ value: ConversationSessionActor) {
            self.value = value
        }
    }
    private var actors: [String: WeakActorBox] = [:]

    public init() {}

    /// 返回 `sessionID` 对应的 Actor；不存在时用给定 store/sealing 创建。
    /// 注意：同一 sessionID 必须始终使用同一 store/sealing（此处以首次注册者为准）。
    public func actor(
        for sessionID: String,
        store: ConversationSessionStore,
        sealing: ConversationSealing,
        initialState: ConversationSessionState
    ) -> ConversationSessionActor {
        lock.lock()
        defer { lock.unlock() }
        if let existing = actors[sessionID]?.value {
            return existing
        }
        let actor = ConversationSessionActor(
            sessionID: sessionID, initialState: initialState, store: store, sealing: sealing
        )
        actors[sessionID] = WeakActorBox(actor)
        return actor
    }

    public func existingActor(for sessionID: String) -> ConversationSessionActor? {
        lock.lock()
        defer { lock.unlock() }
        guard let actor = actors[sessionID]?.value else {
            actors.removeValue(forKey: sessionID)
            return nil
        }
        return actor
    }

    public func removeActor(for sessionID: String) {
        lock.lock()
        defer { lock.unlock() }
        actors.removeValue(forKey: sessionID)
    }
}
