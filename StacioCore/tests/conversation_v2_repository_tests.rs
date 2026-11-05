use stacio_core::infrastructure::conversation_v2::repository::{
    CommitOutcome, CommitRequest, ConversationV2Repository, OutboxItem, ProjectionValue,
};
use stacio_core::infrastructure::conversation_v2::sequence::{CandidateBatch, EnvelopeCandidate};
use stacio_core::infrastructure::conversation_v2::ConversationV2Db;

fn temp_database_path() -> String {
    let file = tempfile::NamedTempFile::new().expect("create temp database");
    let (_file, path) = file.keep().expect("keep temp database");
    path.to_string_lossy().to_string()
}

fn candidate(
    sequence: i64,
    event_id: &str,
    event_type: &str,
    payload_hash: &str,
) -> EnvelopeCandidate {
    EnvelopeCandidate {
        sequence,
        event_id: event_id.to_string(),
        event_type: event_type.to_string(),
        write_class: "durable".to_string(),
        source: "test".to_string(),
        created_at: "t".to_string(),
        payload_hash: payload_hash.to_string(),
        visibility: "session".to_string(),
        payload_cipher: Some(vec![0x01, 0x02, 0x03]),
        payload_cipher_version: Some("aes-256-gcm-v1".to_string()),
        payload_byte_length: Some(3),
    }
}

fn projection(key: &str, payload: &[u8]) -> ProjectionValue {
    ProjectionValue {
        key: key.to_string(),
        payload_cipher: payload.to_vec(),
        payload_cipher_version: "aes-256-gcm-v1".to_string(),
        payload_byte_length: payload.len() as i64,
    }
}

fn outbox_item(item_id: &str, effect_id: &str, operation_id: &str) -> OutboxItem {
    OutboxItem {
        item_id: item_id.to_string(),
        effect_id: effect_id.to_string(),
        operation_id: operation_id.to_string(),
        idempotency_key: format!("{item_id}#{operation_id}"),
        command_kind: "requestAdmission".to_string(),
        command_payload: br#"{"attemptID":"a-1"}"#.to_vec(),
        authority_lease_id: None,
        capability_generation: None,
        permit_commit_decision: None,
    }
}

fn make_repo() -> (ConversationV2Db, ConversationV2Repository) {
    let db = ConversationV2Db::open_in_memory().expect("open in-memory v2 db");
    let repo = ConversationV2Repository::new(&db);
    (db, repo)
}

fn seed_session(db: &ConversationV2Db, conversation_id: &str) {
    db.connection()
        .execute(
            "INSERT INTO conversation_v2_session (conversation_id, schema_version, created_at, updated_at)
             VALUES (?1, 1, 't', 't')",
            rusqlite::params![conversation_id],
        )
        .expect("seed session");
}

fn request(
    expected: i64,
    candidates: Vec<EnvelopeCandidate>,
    conversation_id: &str,
) -> CommitRequest {
    CommitRequest {
        conversation_id: conversation_id.to_string(),
        expected_last_sequence: expected,
        candidates,
        projections: vec![],
        outbox: vec![],
        required_reservations: vec![],
    }
}

/// P3-3：单事务内原子完成 Event append + 加密投影 + outbox——成功后全部可见。
#[test]
fn repository_commit_atomically_appends_events_projection_and_outbox() {
    let (db, repo) = make_repo();
    seed_session(&db, "c-1");
    let mut req = request(
        0,
        vec![
            candidate(1, "ev-1", "turnSubmitted", "h-1"),
            candidate(2, "ev-2", "admissionRequested", "h-2"),
        ],
        "c-1",
    );
    req.projections
        .push(projection("turn:c-1:t-1", b"encrypted-turn"));
    req.outbox.push(outbox_item(
        "admission-c-1-a-1#op-1",
        "admission-c-1-a-1",
        "op-1",
    ));

    let outcome = repo.commit(&req).expect("commit succeeds");
    assert_eq!(
        outcome.snapshot_at_sequence, 2,
        "snapshotAtSequence = 批次最后一个 candidate"
    );

    // Event 全部可见
    let count: i64 = db
        .connection()
        .query_row(
            "SELECT COUNT(*) FROM conversation_v2_event WHERE conversation_id = 'c-1'",
            [],
            |row| row.get(0),
        )
        .expect("count events");
    assert_eq!(count, 2, "事件全部落盘");
    // 投影可见
    let projection_count: i64 = db
        .connection()
        .query_row(
            "SELECT COUNT(*) FROM conversation_v2_projection WHERE conversation_id = 'c-1'",
            [],
            |row| row.get(0),
        )
        .expect("count projections");
    assert_eq!(projection_count, 1);
    // outbox 可见（带稳定 ID）
    let outbox_rows: Vec<(String, String, String)> = {
        let conn = db.connection();
        let mut stmt = conn
            .prepare("SELECT item_id, effect_id, operation_id FROM conversation_v2_outbox WHERE conversation_id = 'c-1'")
            .expect("prepare outbox query");
        let rows = stmt
            .query_map([], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)))
            .expect("query outbox");
        rows.collect::<Result<Vec<_>, _>>().expect("collect outbox")
    };
    assert_eq!(outbox_rows.len(), 1);
    assert_eq!(outbox_rows[0].0, "admission-c-1-a-1#op-1");
    assert_eq!(outbox_rows[0].1, "admission-c-1-a-1");
    assert_eq!(outbox_rows[0].2, "op-1");
}

/// P3-3：expected sequence 冲突 → 事务失败，任何动作不可见。
#[test]
fn repository_expected_mismatch_leaves_nothing_visible() {
    let (db, repo) = make_repo();
    seed_session(&db, "c-1");
    // 先提交 sequence 1
    repo.commit(&request(
        0,
        vec![candidate(1, "ev-1", "turnSubmitted", "h-1")],
        "c-1",
    ))
    .expect("first commit");
    // expected 冲突（期望 0 但库内 lastApplied=1）
    let result = repo.commit(&request(
        0,
        vec![candidate(1, "ev-x", "turnSubmitted", "h-x")],
        "c-1",
    ));
    assert!(result.is_err(), "expected mismatch 必须失败");

    let count: i64 = db
        .connection()
        .query_row(
            "SELECT COUNT(*) FROM conversation_v2_event WHERE conversation_id = 'c-1'",
            [],
            |row| row.get(0),
        )
        .expect("count events");
    assert_eq!(count, 1, "事务失败时冲突事件不可见");
}

/// P3-3：幂等键去重——同 sequence 同 event_id 同 hash 重复投递幂等忽略（不报错、不重复 outbox）。
#[test]
fn repository_duplicate_delivery_idempotently_ignored() {
    let (db, repo) = make_repo();
    seed_session(&db, "c-1");
    let mut first = request(0, vec![candidate(1, "ev-1", "turnSubmitted", "h-1")], "c-1");
    first
        .outbox
        .push(outbox_item("item-1#op-1", "effect-1", "op-1"));
    repo.commit(&first).expect("first commit");

    // 重复投递（同 event_id 同 hash）→ 幂等忽略，不报错
    let duplicate = repo.commit(&request(
        1,
        vec![candidate(1, "ev-1", "turnSubmitted", "h-1")],
        "c-1",
    ));
    assert!(
        duplicate.is_ok(),
        "同 sequence 同 hash 重复投递必须幂等忽略"
    );

    let outbox_count: i64 = db
        .connection()
        .query_row(
            "SELECT COUNT(*) FROM conversation_v2_outbox WHERE conversation_id = 'c-1'",
            [],
            |row| row.get(0),
        )
        .expect("count outbox");
    assert_eq!(outbox_count, 1, "重复投递不得重复 outbox");
}

#[test]
fn repository_duplicate_delivery_with_original_expected_sequence_is_idempotent() {
    let (db, repo) = make_repo();
    seed_session(&db, "c-1");
    let first = request(0, vec![candidate(1, "ev-1", "turnSubmitted", "h-1")], "c-1");
    repo.commit(&first).expect("first commit");

    let duplicate = repo.commit(&first);
    assert!(
        duplicate.is_ok(),
        "original expected sequence must be replay-safe"
    );
    assert_eq!(duplicate.unwrap().snapshot_at_sequence, 1);
}

#[test]
fn repository_load_events_rejects_tampered_payload_length() {
    let (db, repo) = make_repo();
    seed_session(&db, "c-1");
    repo.commit(&request(
        0,
        vec![candidate(1, "ev-1", "turnSubmitted", "h-1")],
        "c-1",
    ))
    .expect("first commit");
    db.connection()
        .execute(
            "UPDATE conversation_v2_event
                SET payload_byte_length = 999
              WHERE conversation_id = 'c-1' AND sequence = 1",
            [],
        )
        .expect("tamper payload length");

    assert!(matches!(
        repo.load_events("c-1"),
        Err(stacio_core::infrastructure::conversation_v2::repository::CommitError::CorruptionDetected {
            sequence: 1
        })
    ));
}

#[test]
fn repository_conflicting_logical_outbox_identity_isolated_as_corruption() {
    let (db, repo) = make_repo();
    seed_session(&db, "c-1");
    let mut first = request(0, vec![candidate(1, "ev-1", "turnSubmitted", "h-1")], "c-1");
    first.outbox.push(outbox_item("item-1", "effect-1", "op-1"));
    repo.commit(&first).expect("first commit");

    let mut conflicting = request(
        1,
        vec![candidate(2, "ev-2", "runtimeStarted", "h-2")],
        "c-1",
    );
    let mut item = outbox_item("item-2", "effect-1", "op-2");
    item.command_payload = br#"{"attemptID":"a-2"}"#.to_vec();
    conflicting.outbox.push(item);
    let result = repo.commit(&conflicting);
    assert!(matches!(
        result,
        Err(stacio_core::infrastructure::conversation_v2::repository::CommitError::CorruptionDetected { .. })
    ));
    let corruption: i64 = db
        .connection()
        .query_row(
            "SELECT COUNT(*) FROM conversation_v2_corruption WHERE conversation_id = 'c-1'",
            [],
            |row| row.get(0),
        )
        .expect("count corruption");
    assert_eq!(corruption, 1);
}

#[test]
fn repository_rejects_empty_commit_without_creating_session_side_effects() {
    let (db, repo) = make_repo();
    let result = repo.commit(&request(0, vec![], "c-empty"));
    assert!(result.is_err());
    let count: i64 = db
        .connection()
        .query_row(
            "SELECT COUNT(*) FROM conversation_v2_session WHERE conversation_id = 'c-empty'",
            [],
            |row| row.get(0),
        )
        .expect("count sessions");
    assert_eq!(count, 0);
}

/// P3-3：同 sequence 不同 event/hash → 损坏隔离（不得择一覆盖）。
#[test]
fn repository_same_sequence_different_hash_isolated_as_corruption() {
    let (db, repo) = make_repo();
    seed_session(&db, "c-1");
    repo.commit(&request(
        0,
        vec![candidate(1, "ev-1", "turnSubmitted", "h-1")],
        "c-1",
    ))
    .expect("first commit");

    let result = repo.commit(&request(
        1,
        vec![candidate(1, "ev-1", "turnSubmitted", "h-DIFFERENT")],
        "c-1",
    ));
    assert!(
        matches!(result, Err(stacio_core::infrastructure::conversation_v2::repository::CommitError::CorruptionDetected { .. })),
        "同 sequence 不同 hash 必须隔离为损坏"
    );
    let corruption: i64 = db
        .connection()
        .query_row(
            "SELECT COUNT(*) FROM conversation_v2_corruption WHERE conversation_id = 'c-1'",
            [],
            |row| row.get(0),
        )
        .expect("count corruption");
    assert_eq!(corruption, 1, "损坏记录必须落盘（只读隔离）");
}

#[test]
fn corruption_marker_makes_repository_read_only() {
    let (db, repo) = make_repo();
    seed_session(&db, "c-1");
    repo.commit(&request(
        0,
        vec![candidate(1, "ev-1", "turnSubmitted", "h-1")],
        "c-1",
    ))
    .expect("first commit");

    db.connection()
        .execute(
            "INSERT OR REPLACE INTO conversation_v2_corruption
             (conversation_id, reason, sequence, created_at)
             VALUES ('c-1', 'tampered', 1, 't')",
            [],
        )
        .expect("mark corruption");

    assert!(repo
        .commit(&request(
            1,
            vec![candidate(2, "ev-2", "admissionRequested", "h-2")],
            "c-1",
        ))
        .is_err());
    assert!(repo.load_events("c-1").is_err());
    assert!(repo.last_applied_for("c-1").is_err());
    assert!(repo.load_unsettled_outbox("c-1").is_err());
    assert!(repo
        .claim_outbox_effect("c-1", "effect-1", "token", "t")
        .is_err());
    assert!(!repo
        .settle_outbox("c-1", "item-1", "token", "completed", "t")
        .is_ok());
    assert!(repo
        .require_outbox_reconciliation("c-1", "item-1", "corrupt")
        .is_err());
}

/// P3-3：reserved binding 引用在事务中强制——无有效 reservation 拒绝提交。
#[test]
fn repository_reserved_binding_reference_required() {
    let (db, repo) = make_repo();
    seed_session(&db, "c-1");
    let mut req = request(0, vec![candidate(1, "ev-1", "turnSubmitted", "h-1")], "c-1");
    req.required_reservations.push("binding-b-1".to_string());
    let missing = repo.commit(&req);
    assert!(
        matches!(missing, Err(stacio_core::infrastructure::conversation_v2::repository::CommitError::ReservationMissing { .. })),
        "无有效 reservation 必须拒绝提交"
    );

    // 有 reservation → 成功
    db.connection()
        .execute(
            "INSERT INTO conversation_v2_reservation (binding_id, state, created_at)
             VALUES ('binding-b-1', 'reserved', 't')",
            [],
        )
        .expect("insert reservation");
    assert!(repo.commit(&req).is_ok(), "有效 reservation 允许提交");
}

/// P3-3：outbox item 带稳定 effect ID / operation ID 与需要时的 Permit commit decision。
#[test]
fn repository_outbox_carries_stable_ids_and_permit_decision() {
    let (db, repo) = make_repo();
    seed_session(&db, "c-1");
    let mut req = request(0, vec![candidate(1, "ev-1", "turnSubmitted", "h-1")], "c-1");
    req.outbox.push(OutboxItem {
        item_id: "startRuntime-a-1#op-1".to_string(),
        effect_id: "startRuntime-a-1".to_string(),
        operation_id: "op-1".to_string(),
        idempotency_key: "startRuntime-a-1#op-1".to_string(),
        command_kind: "startRuntime".to_string(),
        command_payload: br#"{"attemptID":"a-1"}"#.to_vec(),
        authority_lease_id: Some("auth-9".to_string()),
        capability_generation: Some(17),
        permit_commit_decision: Some("commitAuthorized".to_string()),
    });
    repo.commit(&req).expect("commit with outbox");

    let (authority, generation, permit): (Option<String>, Option<i64>, Option<String>) = db
        .connection()
        .query_row(
            "SELECT authority_lease_id, capability_generation, permit_commit_decision
               FROM conversation_v2_outbox WHERE conversation_id = 'c-1'",
            [],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .expect("read outbox row");
    assert_eq!(
        authority.as_deref(),
        Some("auth-9"),
        "outbox 携带 authority 重验引用"
    );
    assert_eq!(
        generation,
        Some(17),
        "capability generation 不得在 Swift-Rust 边界丢失"
    );
    assert_eq!(
        permit.as_deref(),
        Some("commitAuthorized"),
        "outbox 携带 Permit commit decision"
    );
}

/// An effect can be claimed only once, and settlement requires the claimant's token.
#[test]
fn repository_outbox_claim_and_settle_are_durable_and_token_guarded() {
    let (db, repo) = make_repo();
    seed_session(&db, "c-1");
    let mut req = request(
        0,
        vec![candidate(1, "ev-1", "approvalResolved", "h-1")],
        "c-1",
    );
    let mut item = outbox_item("executeTool-a-1-p-1#op-2", "executeTool-a-1-p-1", "op-2");
    item.command_kind = "executeTool".to_string();
    item.command_payload = br#"{"attemptID":"a-1","proposalID":"p-1"}"#.to_vec();
    item.capability_generation = Some(23);
    req.outbox.push(item);
    repo.commit(&req).expect("commit outbox");

    let pending = repo.load_unsettled_outbox("c-1").expect("load pending");
    assert_eq!(pending.len(), 1);
    assert_eq!(pending[0].status, "pending");
    assert_eq!(pending[0].command_kind, "executeTool");
    assert_eq!(pending[0].capability_generation, Some(23));

    let claimed = repo
        .claim_outbox_effect("c-1", "executeTool-a-1-p-1", "dispatch-1", "t1")
        .expect("claim")
        .expect("pending row must be claimable");
    assert_eq!(claimed.status, "dispatching");
    assert_eq!(claimed.dispatch_token.as_deref(), Some("dispatch-1"));
    assert!(
        repo.claim_outbox_effect("c-1", "executeTool-a-1-p-1", "dispatch-2", "t2")
            .expect("second claim")
            .is_none(),
        "dispatching effect must not be claimed twice"
    );
    assert!(!repo
        .settle_outbox("c-1", &claimed.item_id, "wrong-token", "completed", "t3")
        .expect("wrong-token settlement must be a clean rejection"));
    assert!(repo
        .settle_outbox("c-1", &claimed.item_id, "dispatch-1", "completed", "t3")
        .expect("settle with owner token"));
    assert!(repo
        .settle_outbox("c-1", &claimed.item_id, "dispatch-1", "completed", "t4")
        .expect("same settlement is idempotent"));
    assert!(repo
        .load_unsettled_outbox("c-1")
        .expect("load settled")
        .is_empty());
}

/// A dispatching effect survives repository reopen and cannot be auto-claimed.
#[test]
fn repository_outbox_reopen_requires_reconciliation_for_unknown_dispatch() {
    let path = temp_database_path();
    let db = ConversationV2Db::open(&path).expect("open database");
    let repo = ConversationV2Repository::new(&db);
    seed_session(&db, "c-1");
    let mut req = request(
        0,
        vec![candidate(1, "ev-1", "approvalResolved", "h-1")],
        "c-1",
    );
    req.outbox.push(outbox_item(
        "executeTool-a-1-p-1#op-2",
        "executeTool-a-1-p-1",
        "op-2",
    ));
    repo.commit(&req).expect("commit outbox");
    let claimed = repo
        .claim_outbox_effect("c-1", "executeTool-a-1-p-1", "dispatch-1", "t1")
        .expect("claim")
        .expect("claim record");
    drop(repo);
    drop(db);

    let reopened_db = ConversationV2Db::open(&path).expect("reopen database");
    let reopened = ConversationV2Repository::new(&reopened_db);
    assert!(reopened
        .claim_outbox_effect("c-1", "executeTool-a-1-p-1", "dispatch-2", "t2")
        .expect("claim after reopen")
        .is_none());
    assert!(reopened
        .require_outbox_reconciliation("c-1", &claimed.item_id, "external result unknown")
        .expect("mark reconciliation"));
    let unresolved = reopened
        .load_unsettled_outbox("c-1")
        .expect("load unresolved");
    assert_eq!(unresolved[0].status, "reconciliationRequired");
    assert_eq!(
        unresolved[0].reconciliation_reason.as_deref(),
        Some("external result unknown")
    );
}

/// P3-3：CandidateBatch 校验接入——gap 批次在事务内拒绝。
#[test]
fn repository_rejects_gap_batch_inside_transaction() {
    let (db, repo) = make_repo();
    seed_session(&db, "c-1");
    let result = repo.commit(&request(
        0,
        vec![
            candidate(1, "ev-1", "turnSubmitted", "h-1"),
            candidate(3, "ev-3", "turnSubmitted", "h-3"),
        ],
        "c-1",
    ));
    assert!(result.is_err(), "gap 批次必须拒绝");
    let _ = CandidateBatch {
        expected_last_sequence: 0,
        candidates: vec![],
    };
    let _ = CommitOutcome {
        snapshot_at_sequence: 0,
        committed_outbox: vec![],
    };
}

#[test]
fn repository_lists_sessions_by_real_updated_time_without_plaintext_metadata() {
    let (_db, repo) = make_repo();
    let mut first = candidate(1, "ev-a-1", "sessionCreated", "h-a-1");
    first.created_at = "2026-08-11T09:00:00Z".to_string();
    repo.commit(&request(0, vec![first], "session-a"))
        .expect("create first session");

    let mut second = candidate(1, "ev-b-1", "sessionCreated", "h-b-1");
    second.created_at = "2026-08-11T10:00:00Z".to_string();
    repo.commit(&request(0, vec![second], "session-b"))
        .expect("create second session");

    let mut update = candidate(2, "ev-a-2", "draftChanged", "h-a-2");
    update.created_at = "2026-08-11T11:00:00Z".to_string();
    repo.commit(&request(1, vec![update], "session-a"))
        .expect("update first session");

    let records = repo.list_sessions().expect("list sessions");
    assert_eq!(records.len(), 2);
    assert_eq!(records[0].conversation_id, "session-a");
    assert_eq!(records[0].created_at, "2026-08-11T09:00:00Z");
    assert_eq!(records[0].updated_at, "2026-08-11T11:00:00Z");
    assert!(!records[0].is_corrupted);
    assert_eq!(records[1].conversation_id, "session-b");
    assert_eq!(records[1].updated_at, "2026-08-11T10:00:00Z");
}
