import Foundation

/// Decrypted, in-memory projection used by the conversation navigator. No
/// title, target, model or message content is written to a plaintext index.
public struct ConversationSessionCatalogEntry: Equatable, Sendable {
    public let session: ConversationSession
    public let latestAttemptPhase: AttemptPhase?
    public let updatedAt: Date
    public let isCorrupted: Bool

    public init(
        session: ConversationSession,
        latestAttemptPhase: AttemptPhase?,
        updatedAt: Date,
        isCorrupted: Bool
    ) {
        self.session = session
        self.latestAttemptPhase = latestAttemptPhase
        self.updatedAt = updatedAt
        self.isCorrupted = isCorrupted
    }
}

/// Async boundary used by the Inspector while it restores the conversation
/// picker. Production reads the encrypted catalog; tests may supply an
/// isolated catalog without touching the user's App Support database or
/// Keychain.
public typealias ConversationSessionCatalogLoadOperation = @Sendable () async throws -> [ConversationSessionCatalogEntry]

public enum ConversationSessionCatalogError: Error, Equatable {
    case invalidSequence(sessionID: String)
    case invalidEvent(sessionID: String)
}

public enum ConversationSessionCatalogProjection {
    public static func makeEntry(
        index: ConversationSessionIndexRecord,
        events: [ConversationEventEnvelope],
        fallbackState: ConversationSessionState
    ) throws -> ConversationSessionCatalogEntry {
        var state = fallbackState
        var firstUserText: String?

        for envelope in events {
            guard envelope.conversationID == index.conversationID,
                  envelope.candidateSequence == state.lastAppliedSequence + 1 else {
                throw ConversationSessionCatalogError.invalidSequence(sessionID: index.conversationID)
            }
            let draft = EventDraft(
                envelope: envelope,
                expectedLastSequence: state.lastAppliedSequence
            )
            let tentative = ConversationReducer.reduce(state: state, draft: draft).0
            guard tentative.isValid else {
                throw ConversationSessionCatalogError.invalidEvent(sessionID: index.conversationID)
            }
            state = tentative.state
            if firstUserText == nil,
               envelope.kind == .turnSubmitted,
               let submitted = EventPayloadCodec.decode(TurnSubmittedPayload.self, from: envelope.payload) {
                firstUserText = submitted.text
            }
        }

        if state.session.title == "新会话", let firstUserText {
            let oneLine = firstUserText
                .split(whereSeparator: \Character.isNewline)
                .first
                .map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if oneLine.isEmpty == false {
                state.session.title = String(oneLine.prefix(48))
            }
        }
        let eventUpdatedAt = events.last?.timestamp
        let updatedAt = eventUpdatedAt ?? index.updatedAt ?? state.session.updatedAt
        state.session.updatedAt = updatedAt
        return ConversationSessionCatalogEntry(
            session: state.session,
            latestAttemptPhase: state.activeAttempt?.phase,
            updatedAt: updatedAt,
            isCorrupted: index.isCorrupted
        )
    }
}

/// Serial background loader for the sidebar/history popover. Repository and
/// Keychain work execute on the actor rather than the AppKit main actor.
public actor ConversationSessionCatalogLoader {
    public init() {}

    public func load() throws -> [ConversationSessionCatalogEntry] {
        let paths = try StacioPaths()
        let repository = try ConversationV2StorageFactory.makeRepository(
            conversationID: "__conversation_catalog__",
            paths: paths
        )
        return try repository.listSessionIndex().map { index in
            let fallback = ConversationV2StorageFactory.makeInitialSessionState(
                sessionID: index.conversationID,
                now: index.createdAt ?? Date(timeIntervalSince1970: 0)
            )
            guard index.isCorrupted == false else {
                var session = fallback.session
                session.title = "会话数据损坏"
                session.updatedAt = index.updatedAt ?? session.updatedAt
                return ConversationSessionCatalogEntry(
                    session: session,
                    latestAttemptPhase: .failed,
                    updatedAt: session.updatedAt,
                    isCorrupted: true
                )
            }
            do {
                return try ConversationSessionCatalogProjection.makeEntry(
                    index: index,
                    events: repository.loadEvents(conversationID: index.conversationID),
                    fallbackState: fallback
                )
            } catch {
                var session = fallback.session
                session.title = "会话无法解密"
                session.updatedAt = index.updatedAt ?? session.updatedAt
                return ConversationSessionCatalogEntry(
                    session: session,
                    latestAttemptPhase: .failed,
                    updatedAt: session.updatedAt,
                    isCorrupted: true
                )
            }
        }
    }
}
