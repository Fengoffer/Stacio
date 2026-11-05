use stacio_core::infrastructure::conversation_v2::admission::{AdmissionError, AdmissionStore};
use stacio_core::infrastructure::conversation_v2::ConversationV2Db;

/// P3-4：GlobalExecutionAdmissionRequest/Lease 表唯一 Scheduler 原子更新。
#[test]
fn admission_enqueue_is_idempotent_by_attempt() {
    let db = ConversationV2Db::open_in_memory().expect("open v2 db");
    let store = AdmissionStore::new(&db);
    store
        .enqueue("req-1", "c-1", "t-1", "a-1", 1, 1)
        .expect("first enqueue");
    // 相同 Attempt 重复请求幂等（不占两个名额）→ 返回现有请求（不报错、不新增）
    store
        .enqueue("req-2", "c-1", "t-1", "a-1", 1, 2)
        .expect("duplicate enqueue must be idempotent");
    let count: i64 = db
        .connection()
        .query_row(
            "SELECT COUNT(*) FROM conversation_v2_admission_request WHERE attempt_id = 'a-1'",
            [],
            |row| row.get(0),
        )
        .expect("count requests");
    assert_eq!(count, 1, "同 Attempt 重复请求幂等，不占两个名额");
}

#[test]
fn admission_attempt_identity_is_scoped_to_conversation() {
    let db = ConversationV2Db::open_in_memory().expect("open v2 db");
    let store = AdmissionStore::new(&db);
    store
        .enqueue("req-c1", "c-1", "t-1", "attempt-1", 1, 1)
        .expect("first conversation enqueue");
    store
        .enqueue("req-c2", "c-2", "t-1", "attempt-1", 1, 2)
        .expect("second conversation may reuse its local attempt ordinal");

    let count: i64 = db
        .connection()
        .query_row(
            "SELECT COUNT(*) FROM conversation_v2_admission_request WHERE attempt_id = 'attempt-1'",
            [],
            |row| row.get(0),
        )
        .expect("count requests");
    assert_eq!(count, 2);
}

#[test]
fn runtime_admission_allocates_fifo_activates_and_releases_durably() {
    let db = ConversationV2Db::open_in_memory().expect("open v2 db");
    let store = AdmissionStore::new(&db);
    let generation = store.begin_generation().expect("begin generation");

    let first = store
        .enqueue_runtime("r-1", "c-1", "t-1", "a-1", generation, 10.0)
        .expect("enqueue first");
    let second = store
        .enqueue_runtime("r-2", "c-2", "t-1", "a-1", generation, 11.0)
        .expect("enqueue second");
    assert_eq!(first.queue_ordinal + 1, second.queue_ordinal);

    let lease = store
        .grant_runtime(&first.request_id, &first.attempt_id, generation, 12.0)
        .expect("grant first");
    store
        .transition_lease(&lease.lease_id, "granted", "active", generation)
        .expect("activate lease");
    assert!(store
        .release_runtime(&lease.lease_id, generation, 13.0)
        .expect("release lease"));

    let state = store.load_state().expect("load scheduler state");
    assert_eq!(state.requests.len(), 1);
    assert_eq!(state.requests[0].request_id, second.request_id);
    assert!(state.active_leases.is_empty());
}

/// P3-4：grant 只允许 queued → granted（生成 lease）。
#[test]
fn admission_grant_creates_lease_and_marks_request_granted() {
    let db = ConversationV2Db::open_in_memory().expect("open v2 db");
    let store = AdmissionStore::new(&db);
    store
        .enqueue("req-1", "c-1", "t-1", "a-1", 1, 1)
        .expect("enqueue");
    let lease_id = store
        .grant("req-1", "a-1", 1)
        .expect("grant queued request");
    let (request_state, lease_state): (String, String) = db
        .connection()
        .query_row(
            "SELECT r.state, l.state FROM conversation_v2_admission_request r
             JOIN conversation_v2_admission_lease l ON l.lease_id = ?1
             WHERE r.request_id = 'req-1'",
            [&lease_id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .expect("read admission states");
    assert_eq!(request_state, "granted");
    assert_eq!(lease_state, "granted");
}

/// P3-4：lease 状态约束——只允许 granted→active→releasing→released 链；非法跳转拒绝。
#[test]
fn admission_lease_state_transitions_constrained() {
    let db = ConversationV2Db::open_in_memory().expect("open v2 db");
    let store = AdmissionStore::new(&db);
    store
        .enqueue("req-1", "c-1", "t-1", "a-1", 1, 1)
        .expect("enqueue");
    let lease_id = store.grant("req-1", "a-1", 1).expect("grant");

    store
        .transition_lease(&lease_id, "granted", "active", 1)
        .expect("granted -> active");
    store
        .transition_lease(&lease_id, "active", "releasing", 1)
        .expect("active -> releasing");
    store
        .transition_lease(&lease_id, "releasing", "released", 1)
        .expect("releasing -> released");

    // 非法跳转：granted -> released（跳过 active）必须拒绝
    let result = store.transition_lease(&lease_id, "granted", "released", 1);
    assert!(matches!(
        result,
        Err(AdmissionError::InvalidStateTransition { .. })
    ));
}

/// P3-4：generation 校验——旧 generation 的 lease 操作拒绝。
#[test]
fn admission_stale_generation_rejected() {
    let db = ConversationV2Db::open_in_memory().expect("open v2 db");
    let store = AdmissionStore::new(&db);
    store
        .enqueue("req-1", "c-1", "t-1", "a-1", 1, 1)
        .expect("enqueue");
    let lease_id = store.grant("req-1", "a-1", 1).expect("grant");

    // 用旧 generation（0）操作当前 lease → 拒绝
    let result = store.transition_lease(&lease_id, "granted", "active", 0);
    assert!(
        matches!(result, Err(AdmissionError::StaleGeneration { .. })),
        "旧 generation 必须拒绝"
    );
}

/// P3-4：orphanedRuntime / isolated 状态可表达且约束正确（orphaned 不误释放）。
#[test]
fn admission_orphaned_and_isolated_states_expressible() {
    let db = ConversationV2Db::open_in_memory().expect("open v2 db");
    let store = AdmissionStore::new(&db);
    store
        .enqueue("req-1", "c-1", "t-1", "a-1", 1, 1)
        .expect("enqueue");
    let lease_id = store.grant("req-1", "a-1", 1).expect("grant");

    // orphanedRuntime：只能从 active 进入；进入后不允许直接 released（不误释放）
    store
        .transition_lease(&lease_id, "granted", "active", 1)
        .expect("granted -> active");
    store
        .transition_lease(&lease_id, "active", "orphanedRuntime", 1)
        .expect("active -> orphanedRuntime");
    let direct_release = store.transition_lease(&lease_id, "orphanedRuntime", "released", 1);
    assert!(
        matches!(
            direct_release,
            Err(AdmissionError::InvalidStateTransition { .. })
        ),
        "orphanedRuntime 不得直接 released（需 settlement 证明）"
    );

    // isolated 可表达（隔离后释放容量）
    store
        .transition_lease(&lease_id, "orphanedRuntime", "isolated", 1)
        .expect("orphanedRuntime -> isolated");
    store
        .transition_lease(&lease_id, "isolated", "released", 1)
        .expect("isolated -> released");
}
