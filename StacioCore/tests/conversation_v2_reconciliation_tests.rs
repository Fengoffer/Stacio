use stacio_core::infrastructure::conversation_v2::reconciliation::{
    ReconciliationDb, ReconciliationError, ReconciliationStore,
};

/// P3-9：External Effect reconciliation（conflictKey / evidence strength / 锁不提前释放 / 不占全局 Admission）。
#[test]
fn conflict_key_is_stable_composition() {
    let key = ReconciliationStore::conflict_key("target-digest-1", "resource:file:/etc", "write");
    let same = ReconciliationStore::conflict_key("target-digest-1", "resource:file:/etc", "write");
    assert_eq!(key, same, "conflictKey 稳定");
    let different =
        ReconciliationStore::conflict_key("target-digest-1", "resource:file:/etc", "read");
    assert_ne!(key, different, "operationClass 变化改变 conflictKey");
    let other_target =
        ReconciliationStore::conflict_key("target-digest-2", "resource:file:/etc", "write");
    assert_ne!(key, other_target, "target digest 变化改变 conflictKey");
}

#[test]
fn lock_not_released_until_all_records_settled() {
    let db = ReconciliationDb::open_in_memory().expect("open reconciliation db");
    let store = ReconciliationStore::new(&db);
    let key = ReconciliationStore::conflict_key("d-1", "resource:file:/x", "write");

    store
        .create_record("effect-1", &key, "unknown")
        .expect("record 1");
    store
        .create_record("effect-2", &key, "verifiedCompleted")
        .expect("record 2");

    // 同 key 尚有 unknown 记录 → 锁不释放
    assert!(store.lock_released(&key).expect("read") == false);
    assert_eq!(
        store.lock_owner(&key).expect("read"),
        "reconciliation",
        "同 key 全记录终结前锁不释放"
    );

    // 全部终结后锁释放
    store
        .settle_record("effect-1", "isolated")
        .expect("settle 1");
    store
        .settle_record("effect-2", "verifiedCompleted")
        .expect("settle 2");
    assert!(
        store.lock_released(&key).expect("read"),
        "全记录终结后锁释放"
    );
}

#[test]
fn unknown_remote_effect_lock_does_not_hold_global_admission() {
    let db = ReconciliationDb::open_in_memory().expect("open reconciliation db");
    let store = ReconciliationStore::new(&db);
    let key = ReconciliationStore::conflict_key("d-1", "resource:file:/x", "write");
    store
        .create_record("effect-1", &key, "unknown")
        .expect("record");

    // 未知远端 effect 转锁：不永久占全局 Admission（状态 unknown 的锁不计入 admission 容量）
    let blocks_admission = store.holds_global_admission(&key).expect("read");
    assert!(
        !blocks_admission,
        "未知远端 effect 锁不永久占全局 Admission"
    );
}

#[test]
fn evidence_strength_recorded_per_record() {
    let db = ReconciliationDb::open_in_memory().expect("open reconciliation db");
    let store = ReconciliationStore::new(&db);
    let key = ReconciliationStore::conflict_key("d-1", "resource:file:/x", "write");
    store
        .create_record_with_strength("effect-1", &key, "unknown", "structured")
        .expect("record");

    assert_eq!(
        store.evidence_strength("effect-1").expect("read"),
        "structured",
        "每条记录冻结 evidence strength"
    );
    // 弱证据（none）不得判定 verifiedCompleted
    assert!(
        matches!(
            store.settle_record("effect-1", "verifiedCompleted"),
            Err(ReconciliationError::EvidenceTooWeak { .. })
        ),
        "none 证据不得结算 verifiedCompleted"
    );
}
