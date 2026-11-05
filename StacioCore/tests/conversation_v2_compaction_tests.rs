use stacio_core::infrastructure::conversation_v2::compaction::{
    CompactionError, CompactionStore, SnapshotRecord, SnapshotVerification,
};
use stacio_core::infrastructure::conversation_v2::repository::{
    CommitRequest, ConversationV2Repository, ProjectionValue,
};
use stacio_core::infrastructure::conversation_v2::sequence::EnvelopeCandidate;
use stacio_core::infrastructure::conversation_v2::ConversationV2Db;

fn candidate(sequence: i64, event_id: &str, event_type: &str) -> EnvelopeCandidate {
    EnvelopeCandidate {
        sequence,
        event_id: event_id.to_string(),
        event_type: event_type.to_string(),
        write_class: "durable".to_string(),
        source: "test".to_string(),
        created_at: "t".to_string(),
        payload_hash: format!("h-{sequence}"),
        visibility: "session".to_string(),
        payload_cipher: Some(vec![0x01, 0x02, 0x03]),
        payload_cipher_version: Some("aes-256-gcm-v1".to_string()),
        payload_byte_length: Some(3),
    }
}

fn checkpoint_candidate(sequence: i64, event_id: &str, event_type: &str) -> EnvelopeCandidate {
    let mut value = candidate(sequence, event_id, event_type);
    value.write_class = "checkpoint".to_string();
    value.payload_cipher = Some(vec![0xAA, 0xBB]);
    value.payload_cipher_version = Some("aes-256-gcm-v1".to_string());
    value.payload_byte_length = Some(2);
    value
}

fn projection(key: &str, payload: &[u8]) -> ProjectionValue {
    ProjectionValue {
        key: key.to_string(),
        payload_cipher: payload.to_vec(),
        payload_cipher_version: "aes-256-gcm-v1".to_string(),
        payload_byte_length: payload.len() as i64,
    }
}

fn seed_events(db: &ConversationV2Db, repo: &ConversationV2Repository, up_to: i64) {
    let mut candidates = vec![];
    for seq in 1..=up_to {
        candidates.push(if seq == 2 {
            checkpoint_candidate(seq, &format!("ev-{seq}"), "finalAnswerDelta")
        } else {
            candidate(seq, &format!("ev-{seq}"), "turnSubmitted")
        });
    }
    // 先建会话（外键），再提交事件
    db.connection()
        .execute(
            "INSERT INTO conversation_v2_session (conversation_id, schema_version, created_at, updated_at)
             VALUES ('c-1', 1, 't', 't')",
            [],
        )
        .expect("seed session");
    repo.commit(&CommitRequest {
        conversation_id: "c-1".to_string(),
        expected_last_sequence: 0,
        candidates,
        projections: vec![projection("turn:c-1:t-1", b"encrypted-turn")],
        outbox: vec![],
        required_reservations: vec![],
    })
    .expect("seed events");
}

/// P3-7：verified snapshot 通过验证后才成为恢复基线（覆盖 coversThroughSequence）。
#[test]
fn compaction_verified_snapshot_becomes_recovery_baseline() {
    let db = ConversationV2Db::open_in_memory().expect("open v2 db");
    let repo = ConversationV2Repository::new(&db);
    seed_events(&db, &repo, 5);
    let store = CompactionStore::new(&db);

    // 验证通过 → 成为基线（coversThroughSequence = 5）
    let verification = store.verify_snapshot(&SnapshotRecord {
        snapshot_id: "snap-1".to_string(),
        conversation_id: "c-1".to_string(),
        covers_through_sequence: 5,
        state_digest: "state-digest-ok".to_string(),
        source_range_digest: "range-digest-ok".to_string(),
        payload_cipher_version: "aes-256-gcm-v1".to_string(),
        payload_byte_length: 64,
    });
    assert_eq!(verification, SnapshotVerification::Verified);

    let baseline = store
        .activate_baseline("c-1", "snap-1", 5)
        .expect("activate baseline");
    assert_eq!(
        baseline.covers_through_sequence, 5,
        "verified snapshot 成为恢复基线"
    );
    let watermark: i64 = db
        .connection()
        .query_row(
            "SELECT watermark FROM conversation_v2_compaction_watermark WHERE conversation_id = 'c-1'",
            [],
            |row| row.get(0),
        )
        .expect("read watermark");
    assert_eq!(watermark, 5, "watermark 推进到 snapshot 覆盖点");
}

/// P3-7：校验失败保留旧 snapshot 与原 Event——不推进 watermark、不物理删除。
#[test]
fn compaction_failed_verification_keeps_old_snapshot_and_events() {
    let db = ConversationV2Db::open_in_memory().expect("open v2 db");
    let repo = ConversationV2Repository::new(&db);
    seed_events(&db, &repo, 5);
    let store = CompactionStore::new(&db);
    store
        .activate_baseline("c-1", "snap-valid", 5)
        .expect("activate valid baseline");

    // 新 snapshot 验证失败（state digest 不匹配 source range）
    let failed = store.verify_snapshot(&SnapshotRecord {
        snapshot_id: "snap-bad".to_string(),
        conversation_id: "c-1".to_string(),
        covers_through_sequence: 10,
        state_digest: "state-digest-BAD".to_string(),
        source_range_digest: "range-digest-BAD".to_string(),
        payload_cipher_version: "aes-256-gcm-v1".to_string(),
        payload_byte_length: 64,
    });
    assert_eq!(failed, SnapshotVerification::Rejected);

    let result = store.compact_verified_prefix("c-1", "snap-bad", 10);
    assert!(
        matches!(result, Err(CompactionError::SnapshotNotVerified { .. })),
        "验证失败的 snapshot 不得触发物理删除"
    );
    let count: i64 = db
        .connection()
        .query_row(
            "SELECT COUNT(*) FROM conversation_v2_event WHERE conversation_id = 'c-1'",
            [],
            |row| row.get(0),
        )
        .expect("count events");
    assert_eq!(count, 5, "校验失败保留原 Event");
    let watermark: i64 = db
        .connection()
        .query_row(
            "SELECT watermark FROM conversation_v2_compaction_watermark WHERE conversation_id = 'c-1'",
            [],
            |row| row.get(0),
        )
        .expect("read watermark");
    assert_eq!(watermark, 5, "校验失败不推进 watermark");
}

/// P3-7：物理删除只允许发生在 verified snapshot 完整覆盖的连续前缀（同一 Rust 事务）。
#[test]
fn compaction_physical_delete_only_within_verified_continuous_prefix() {
    let db = ConversationV2Db::open_in_memory().expect("open v2 db");
    let repo = ConversationV2Repository::new(&db);
    seed_events(&db, &repo, 10);
    let store = CompactionStore::new(&db);

    // 验证 snapshot 覆盖 1..7 → 只能删前缀 1..7（8..10 保留）
    assert_eq!(
        store.verify_snapshot(&SnapshotRecord {
            snapshot_id: "snap-7".to_string(),
            conversation_id: "c-1".to_string(),
            covers_through_sequence: 7,
            state_digest: "state-ok".to_string(),
            source_range_digest: "range-ok".to_string(),
            payload_cipher_version: "aes-256-gcm-v1".to_string(),
            payload_byte_length: 64,
        }),
        SnapshotVerification::Verified,
        "verify snapshot"
    );
    // snapshot 激活落盘（与物理删除同事务前置：删除只允许发生在已验证并激活的 snapshot 覆盖前缀）
    store
        .activate_baseline("c-1", "snap-7", 7)
        .expect("activate baseline");
    store
        .compact_verified_prefix("c-1", "snap-7", 7)
        .expect("compact verified prefix");

    let remaining: Vec<i64> = {
        let conn = db.connection();
        let mut stmt = conn
            .prepare("SELECT sequence FROM conversation_v2_event WHERE conversation_id = 'c-1' ORDER BY sequence")
            .expect("prepare query");
        let rows = stmt
            .query_map([], |row| row.get::<_, i64>(0))
            .expect("query sequences");
        rows.collect::<Result<Vec<_>, _>>().expect("collect")
    };
    assert_eq!(
        remaining,
        vec![8, 9, 10],
        "只允许删除 verified snapshot 覆盖的连续前缀"
    );
    assert_eq!(
        store.watermark("c-1").expect("read watermark"),
        7,
        "watermark 推进到删除前缀的末端"
    );
}

/// P3-7：中间 checkpoint 只删独立密文 payload 并保留 omission skeleton。
#[test]
fn compaction_checkpoint_omission_keeps_skeleton() {
    let db = ConversationV2Db::open_in_memory().expect("open v2 db");
    let repo = ConversationV2Repository::new(&db);
    seed_events(&db, &repo, 3);
    let store = CompactionStore::new(&db);

    // 对 sequence 2 的 checkpoint 做 omission（只删密文，保留 skeleton）
    store
        .omit_checkpoint_payload("c-1", 2, "checkpointPayloadOmitted")
        .expect("omit checkpoint payload");

    let (status, reason): (String, String) = db
        .connection()
        .query_row(
            "SELECT omission_status, omission_reason FROM conversation_v2_omission WHERE conversation_id = 'c-1' AND sequence = 2",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .expect("read omission skeleton");
    assert_eq!(status, "checkpointPayloadOmitted");
    assert_eq!(reason, "checkpointPayloadOmitted");
    // 原 event 行保留（sequence/event_id/type/hash/时间范围），仅密文被标记删除
    let event_count: i64 = db
        .connection()
        .query_row(
            "SELECT COUNT(*) FROM conversation_v2_event WHERE conversation_id = 'c-1' AND sequence = 2",
            [],
            |row| row.get(0),
        )
        .expect("count event");
    assert_eq!(event_count, 1, "omission 保留 skeleton 原行");
}

/// P3-7：Loader 首条 Event 必须 coversThroughSequence+1（从快照后继续）。
#[test]
fn compaction_loader_continues_after_snapshot() {
    let db = ConversationV2Db::open_in_memory().expect("open v2 db");
    let repo = ConversationV2Repository::new(&db);
    seed_events(&db, &repo, 10);
    let store = CompactionStore::new(&db);
    assert_eq!(
        store.verify_snapshot(&SnapshotRecord {
            snapshot_id: "snap-7".to_string(),
            conversation_id: "c-1".to_string(),
            covers_through_sequence: 7,
            state_digest: "state-ok".to_string(),
            source_range_digest: "range-ok".to_string(),
            payload_cipher_version: "aes-256-gcm-v1".to_string(),
            payload_byte_length: 64,
        }),
        SnapshotVerification::Verified,
        "verify snapshot"
    );
    store
        .activate_baseline("c-1", "snap-7", 7)
        .expect("activate baseline");
    store
        .compact_verified_prefix("c-1", "snap-7", 7)
        .expect("compact");

    let next_expected = store
        .next_sequence_after_baseline("c-1")
        .expect("next sequence");
    assert_eq!(
        next_expected, 8,
        "Loader 首条 Event 必须 coversThroughSequence+1"
    );
}

#[test]
fn compaction_rejects_snapshot_watermark_regression_and_mismatched_delete() {
    let db = ConversationV2Db::open_in_memory().expect("open v2 db");
    let repo = ConversationV2Repository::new(&db);
    seed_events(&db, &repo, 10);
    let store = CompactionStore::new(&db);
    store
        .activate_baseline("c-1", "snap-7", 7)
        .expect("activate baseline");
    assert!(matches!(
        store.activate_baseline("c-1", "snap-5", 5),
        Err(CompactionError::SnapshotRangeMismatch { .. })
    ));
    assert!(matches!(
        store.compact_verified_prefix("c-1", "snap-7", 6),
        Err(CompactionError::SnapshotRangeMismatch { .. })
    ));
}

#[test]
fn compaction_rejects_unsettled_outbox_before_deleting_events() {
    let db = ConversationV2Db::open_in_memory().expect("open v2 db");
    let repo = ConversationV2Repository::new(&db);
    seed_events(&db, &repo, 3);
    repo.commit(&CommitRequest {
        conversation_id: "c-1".to_string(),
        expected_last_sequence: 3,
        candidates: vec![candidate(4, "ev-4", "runtimeStarted")],
        projections: vec![],
        outbox: vec![
            stacio_core::infrastructure::conversation_v2::repository::OutboxItem {
                item_id: "item-1".to_string(),
                effect_id: "effect-1".to_string(),
                operation_id: "op-1".to_string(),
                idempotency_key: "idem-1".to_string(),
                command_kind: "startRuntime".to_string(),
                command_payload: vec![1],
                authority_lease_id: None,
                capability_generation: None,
                permit_commit_decision: None,
            },
        ],
        required_reservations: vec![],
    })
    .expect("seed outbox");
    let store = CompactionStore::new(&db);
    store
        .activate_baseline("c-1", "snap-3", 3)
        .expect("activate baseline");
    assert!(matches!(
        store.compact_verified_prefix("c-1", "snap-3", 3),
        Err(CompactionError::UnsettledOutbox)
    ));
}

#[test]
fn compaction_requires_checkpoint_write_class_for_omission() {
    let db = ConversationV2Db::open_in_memory().expect("open v2 db");
    let repo = ConversationV2Repository::new(&db);
    seed_events(&db, &repo, 1);
    let store = CompactionStore::new(&db);
    assert!(matches!(
        store.omit_checkpoint_payload("c-1", 1, "bad-target"),
        Err(CompactionError::InvalidOmissionTarget { sequence: 1 })
    ));
}
