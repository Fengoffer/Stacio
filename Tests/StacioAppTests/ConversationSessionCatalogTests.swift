import Foundation
import XCTest
@testable import StacioApp

final class ConversationSessionCatalogTests: XCTestCase {
    private let baseDate = Date(timeIntervalSince1970: 1_800_000_000)

    func testSessionCreationAndMetadataReplayAreEncryptedEventState() throws {
        var created = makeState(sessionID: "catalog-session")
        created.session.title = "生产排查"
        created.session.isPinned = false
        created.session.metadataRevision = 0
        let createdEnvelope = envelope(
            sessionID: created.session.id,
            sequence: 1,
            kind: .sessionCreated,
            scope: .session,
            payload: try JSONEncoder().encode(ConversationSessionCreatedPayload(session: created.session)),
            timestamp: baseDate
        )
        let createdResult = ConversationReducer.reduce(
            state: makeState(sessionID: created.session.id),
            draft: EventDraft(envelope: createdEnvelope, expectedLastSequence: 0)
        ).0
        XCTAssertTrue(createdResult.isValid)
        XCTAssertEqual(createdResult.state.session.title, "生产排查")

        let archivedAt = baseDate.addingTimeInterval(10)
        let metadata = ConversationSessionMetadataChangedPayload(
            expectedRevision: 0,
            title: "  Nginx 故障  ",
            pinned: true,
            archivedAt: archivedAt
        )
        let metadataEnvelope = envelope(
            sessionID: created.session.id,
            sequence: 2,
            kind: .sessionMetadataChanged,
            scope: .session,
            payload: try JSONEncoder().encode(metadata),
            timestamp: archivedAt
        )
        let metadataResult = ConversationReducer.reduce(
            state: createdResult.state,
            draft: EventDraft(envelope: metadataEnvelope, expectedLastSequence: 1)
        ).0
        XCTAssertTrue(metadataResult.isValid)
        XCTAssertEqual(metadataResult.state.session.title, "Nginx 故障")
        XCTAssertEqual(metadataResult.state.session.isPinned, true)
        XCTAssertEqual(metadataResult.state.session.archivedAt, archivedAt)
        XCTAssertEqual(metadataResult.state.session.metadataRevision, 1)
        XCTAssertEqual(metadataResult.state.session.updatedAt, archivedAt)

        let stale = ConversationReducer.reduce(
            state: metadataResult.state,
            draft: EventDraft(
                envelope: envelope(
                    sessionID: created.session.id,
                    sequence: 3,
                    kind: .sessionMetadataChanged,
                    scope: .session,
                    payload: try JSONEncoder().encode(metadata),
                    timestamp: archivedAt.addingTimeInterval(1)
                ),
                expectedLastSequence: 2
            )
        ).0
        XCTAssertFalse(stale.isValid, "stale metadata revision must not overwrite another window")
        XCTAssertEqual(stale.state, metadataResult.state, "rejected metadata update is an atomic no-op")
    }

    func testRepositoryListsAndDecryptsMultipleSessionsThroughOneHandle() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("stacio-session-catalog-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let encryption = ConversationEncryption(masterKeyData: Data(repeating: 0x2a, count: 32))
        let first = try ConversationRepositoryV2(
            conversationID: "session-a",
            databasePath: databaseURL.path,
            encryption: encryption
        )
        let second = try ConversationRepositoryV2(
            conversationID: "session-b",
            databasePath: databaseURL.path,
            encryption: encryption
        )
        let firstState = makeState(sessionID: "session-a")
        let secondState = makeState(sessionID: "session-b")
        _ = try first.commit(
            expectedLastSequence: 0,
            candidates: [envelope(
                sessionID: "session-a",
                sequence: 1,
                kind: .sessionCreated,
                scope: .session,
                payload: try JSONEncoder().encode(ConversationSessionCreatedPayload(session: firstState.session)),
                timestamp: baseDate
            )],
            projections: [:],
            outbox: []
        )
        _ = try second.commit(
            expectedLastSequence: 0,
            candidates: [envelope(
                sessionID: "session-b",
                sequence: 1,
                kind: .sessionCreated,
                scope: .session,
                payload: try JSONEncoder().encode(ConversationSessionCreatedPayload(session: secondState.session)),
                timestamp: baseDate.addingTimeInterval(30)
            )],
            projections: [:],
            outbox: []
        )

        let index = try first.listSessionIndex()
        XCTAssertEqual(index.map(\.conversationID), ["session-b", "session-a"])
        let loaded = try first.loadEvents(conversationID: "session-b")
        XCTAssertEqual(loaded.map(\.conversationID), ["session-b"])
        XCTAssertEqual(loaded.map(\.kind), [.sessionCreated])
        let projection = try ConversationSessionCatalogProjection.makeEntry(
            index: try XCTUnwrap(index.first),
            events: loaded,
            fallbackState: makeState(sessionID: "session-b")
        )
        XCTAssertEqual(projection.session.id, "session-b")
        XCTAssertEqual(projection.updatedAt, baseDate.addingTimeInterval(30))
    }

    func testSessionPreludeDoesNotEraseTurnIdentityFromOutbox() throws {
        let state = makeState(sessionID: "session-outbox")
        let store = CapturingConversationStore()
        let actor = ConversationSessionActor(
            sessionID: state.session.id,
            initialState: state,
            store: store,
            sealing: AllowingConversationSealing()
        )
        let created = envelope(
            sessionID: state.session.id,
            sequence: 1,
            kind: .sessionCreated,
            scope: .session,
            payload: try JSONEncoder().encode(ConversationSessionCreatedPayload(session: state.session)),
            timestamp: baseDate
        )
        let submitted = envelope(
            sessionID: state.session.id,
            sequence: 2,
            kind: .turnSubmitted,
            scope: .attempt,
            turnID: "turn-7",
            attemptID: "attempt-7",
            payload: try JSONEncoder().encode(TurnSubmittedPayload(text: "inspect")),
            timestamp: baseDate.addingTimeInterval(1)
        )
        let outcome = actor.submitSync([
            EventDraft(envelope: created, expectedLastSequence: 0),
            EventDraft(envelope: submitted, expectedLastSequence: 1)
        ])
        guard case .committed = outcome else { return XCTFail("batch should commit") }
        XCTAssertEqual(
            store.lastOutbox.first?.command,
            .requestAdmission(sessionID: state.session.id, turnID: "turn-7", attemptID: "attempt-7")
        )
    }

    func testFirstTurnDerivesDurableLocalTitleWhenSettingIsEnabled() throws {
        let state = makeState(sessionID: "session-auto-title")
        let settings = AssistantRuntimeSettingsSnapshot(
            registryRevision: 1,
            valuesByID: ["assistant.general.localAutoTitle": .bool(true)]
        )
        let payload = TurnSubmittedPayload(
            text: "  inspect   nginx\nerror rate on production  ",
            runtimeSettingsSnapshot: settings
        )
        let result = ConversationReducer.reduce(
            state: state,
            draft: EventDraft(
                envelope: envelope(
                    sessionID: state.session.id,
                    sequence: 1,
                    kind: .turnSubmitted,
                    scope: .turn,
                    turnID: "turn-1",
                    attemptID: "attempt-1",
                    payload: try JSONEncoder().encode(payload),
                    timestamp: baseDate
                ),
                expectedLastSequence: 0
            )
        ).0

        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.state.session.title, "inspect nginx error rate on production")
        XCTAssertEqual(result.state.session.metadataRevision, 1)
    }

    func testFirstTurnLeavesDefaultTitleWhenLocalAutoTitleIsDisabled() throws {
        let state = makeState(sessionID: "session-no-auto-title")
        let settings = AssistantRuntimeSettingsSnapshot(
            registryRevision: 1,
            valuesByID: ["assistant.general.localAutoTitle": .bool(false)]
        )
        let payload = TurnSubmittedPayload(
            text: "inspect nginx",
            runtimeSettingsSnapshot: settings
        )
        let result = ConversationReducer.reduce(
            state: state,
            draft: EventDraft(
                envelope: envelope(
                    sessionID: state.session.id,
                    sequence: 1,
                    kind: .turnSubmitted,
                    scope: .turn,
                    turnID: "turn-1",
                    attemptID: "attempt-1",
                    payload: try JSONEncoder().encode(payload),
                    timestamp: baseDate
                ),
                expectedLastSequence: 0
            )
        ).0

        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.state.session.title, "新会话")
        XCTAssertNil(result.state.session.metadataRevision)
    }

    private func makeState(sessionID: String) -> ConversationSessionState {
        ConversationV2StorageFactory.makeInitialSessionState(sessionID: sessionID, now: baseDate)
    }

    private func envelope(
        sessionID: String,
        sequence: Int,
        kind: ConversationEventKind,
        scope: ConversationEventScope,
        turnID: String? = nil,
        attemptID: String? = nil,
        payload: Data,
        timestamp: Date
    ) -> ConversationEventEnvelope {
        ConversationEventEnvelope(
            eventID: "event-\(sessionID)-\(sequence)",
            conversationID: sessionID,
            scope: scope,
            turnID: turnID,
            attemptID: attemptID,
            candidateSequence: sequence,
            source: "test",
            timestamp: timestamp,
            kind: kind,
            writeClass: .durable,
            payloadHash: "hash-\(sequence)",
            payload: payload
        )
    }
}

private final class AllowingConversationSealing: ConversationSealing {
    func verifyRoundTrip(payload: Data, aad: String) -> Bool { true }
}

private final class CapturingConversationStore: ConversationSessionStore {
    var lastOutbox: [ConversationEffectOutboxItem] = []
    private var sequence = 0

    func load() throws -> ConversationSessionSnapshot {
        ConversationSessionSnapshot(lastAppliedSequence: sequence)
    }

    func commit(
        expectedLastSequence: Int,
        candidates: [ConversationEventEnvelope],
        projections: [String: Data],
        outbox: [ConversationEffectOutboxItem]
    ) throws -> ConversationCommitOutcome {
        guard expectedLastSequence == sequence else {
            return .conflict(expected: expectedLastSequence, actual: sequence)
        }
        sequence = candidates.last?.candidateSequence ?? sequence
        lastOutbox = outbox
        return .committed(lastSequence: sequence)
    }

    func existingEventID(at sequence: Int) -> String? { nil }
    func existingPayloadHash(at sequence: Int) -> String? { nil }
}
