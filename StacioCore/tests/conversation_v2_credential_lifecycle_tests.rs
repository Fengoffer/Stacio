use stacio_core::infrastructure::conversation_v2::credential_lifecycle::{
    CredentialLifecycleDb, CredentialLifecycleError, CredentialLifecycleStore,
    DeletionOperationState, GenerationLifecycleState, SecretAvailability,
};

/// P3-8a：CredentialGeneration/Lifecycle 状态机与删除/孤儿 saga（独立存储域）。
#[test]
fn generation_state_machine_closed_transitions() {
    let db = CredentialLifecycleDb::open_in_memory().expect("open lifecycle db");
    let store = CredentialLifecycleStore::new(&db);

    let generation = store
        .create_generation("cfg-1", 1, "keychain-ref-1")
        .expect("create generation");
    assert_eq!(
        generation.lifecycle_state,
        GenerationLifecycleState::PendingActivation
    );

    // pendingActivation -> active（正常激活）
    store.activate_generation(&generation.id).expect("activate");
    // active -> retired
    store.retire_generation(&generation.id).expect("retire");
    // retired -> revoked
    store.revoke_generation(&generation.id).expect("revoke");

    // revoked 是终态：任何转换拒绝
    assert!(matches!(
        store.activate_generation(&generation.id),
        Err(CredentialLifecycleError::InvalidTransition { .. })
    ));
    assert!(matches!(
        store.retire_generation(&generation.id),
        Err(CredentialLifecycleError::InvalidTransition { .. })
    ));
}

#[test]
fn abandoned_is_terminal_and_cannot_revive() {
    let db = CredentialLifecycleDb::open_in_memory().expect("open lifecycle db");
    let store = CredentialLifecycleStore::new(&db);

    let generation = store
        .create_generation("cfg-1", 1, "keychain-ref-1")
        .expect("create generation");
    store.abandon_generation(&generation.id).expect("abandon");
    assert_eq!(
        store.generation_state(&generation.id).expect("read state"),
        GenerationLifecycleState::Abandoned
    );

    // abandoned 终态且不可复活（不能 activate/retire/revoke）
    assert!(
        store.activate_generation(&generation.id).is_err(),
        "abandoned 不可复活"
    );
    assert!(store.retire_generation(&generation.id).is_err());
    assert!(store.revoke_generation(&generation.id).is_err());
}

#[test]
fn secret_availability_transitions_to_deleted() {
    let db = CredentialLifecycleDb::open_in_memory().expect("open lifecycle db");
    let store = CredentialLifecycleStore::new(&db);

    let generation = store
        .create_generation("cfg-1", 1, "keychain-ref-1")
        .expect("create generation");
    assert_eq!(
        store.secret_availability(&generation.id).expect("read"),
        SecretAvailability::Present
    );

    let operation = store
        .begin_deletion(&generation.id)
        .expect("begin deletion");
    assert_eq!(
        store.secret_availability(&generation.id).expect("read"),
        SecretAvailability::PendingDeletion
    );
    assert_eq!(operation.state, DeletionOperationState::Requested);
    assert_eq!(operation.deletion_fence, 1);

    store.mark_deleting(&operation.id).expect("mark deleting");
    store
        .complete_deletion(&operation.id)
        .expect("complete deletion");
    assert_eq!(
        store.secret_availability(&generation.id).expect("read"),
        SecretAvailability::Deleted
    );
}

#[test]
fn deletion_failure_keeps_pending_deletion_and_does_not_revive_generation() {
    let db = CredentialLifecycleDb::open_in_memory().expect("open lifecycle db");
    let store = CredentialLifecycleStore::new(&db);

    let generation = store
        .create_generation("cfg-1", 1, "keychain-ref-1")
        .expect("create generation");
    let operation = store
        .begin_deletion(&generation.id)
        .expect("begin deletion");
    store
        .fail_deletion(&operation.id, "keychain write failed")
        .expect("fail deletion");

    // 删除失败：secretAvailability 保持 pendingDeletion，generation 不复活
    assert_eq!(
        store.secret_availability(&generation.id).expect("read"),
        SecretAvailability::PendingDeletion
    );
    assert_eq!(
        store.operation_state(&operation.id).expect("read"),
        DeletionOperationState::Failed
    );
    assert!(
        store.activate_generation(&generation.id).is_err(),
        "删除中的 generation 不得复活"
    );
}

#[test]
fn deletion_fence_increments_across_operations() {
    let db = CredentialLifecycleDb::open_in_memory().expect("open lifecycle db");
    let store = CredentialLifecycleStore::new(&db);
    let generation = store
        .create_generation("cfg-1", 1, "keychain-ref-1")
        .expect("create generation");

    let first = store
        .begin_deletion(&generation.id)
        .expect("first deletion");
    let second = store
        .begin_deletion(&generation.id)
        .expect("second deletion");
    assert_eq!(first.deletion_fence, 1);
    assert_eq!(second.deletion_fence, 2, "deletionFence 必须递增");
}

#[test]
fn deletion_blocked_by_use_prevents_completion() {
    let db = CredentialLifecycleDb::open_in_memory().expect("open lifecycle db");
    let store = CredentialLifecycleStore::new(&db);
    let generation = store
        .create_generation("cfg-1", 1, "keychain-ref-1")
        .expect("create generation");
    let operation = store
        .begin_deletion(&generation.id)
        .expect("begin deletion");

    // 活跃 Attempt 引用 → blockedByUse
    store
        .block_deletion_by_use(&operation.id)
        .expect("block by use");
    assert_eq!(
        store.operation_state(&operation.id).expect("read"),
        DeletionOperationState::BlockedByUse
    );
    // blocked 状态下不得直接完成删除
    assert!(
        store.complete_deletion(&operation.id).is_err(),
        "blockedByUse 不得完成删除"
    );
    // 解除占用（引用计数归零）后可继续 deleting -> completed
    store
        .mark_deleting(&operation.id)
        .expect("mark deleting after release");
    store
        .complete_deletion(&operation.id)
        .expect("complete deletion");
}

#[test]
fn orphan_quarantine_no_auto_attach_and_no_secret_output() {
    let db = CredentialLifecycleDb::open_in_memory().expect("open lifecycle db");
    let store = CredentialLifecycleStore::new(&db);

    let orphan = store
        .detect_orphan("keychain-item-orphan")
        .expect("detect orphan");
    assert_eq!(orphan.state, "detected");
    store.quarantine_orphan(&orphan.id).expect("quarantine");
    assert_eq!(store.orphan_state(&orphan.id).expect("read"), "quarantined");

    // 不自动挂接到相似配置：孤儿记录没有自动 attach API；只允许 deleted|manualReview 结算
    assert!(
        matches!(
            store.settle_orphan(&orphan.id, "auto_attach"),
            Err(CredentialLifecycleError::InvalidSettlement { .. })
        ),
        "不允许自动挂接结算"
    );
    store
        .settle_orphan(&orphan.id, "manualReview")
        .expect("manual review settlement");
    assert_eq!(
        store.orphan_state(&orphan.id).expect("read"),
        "manualReview"
    );

    // 任何路径都不输出 secret：孤儿记录只有 keychain 引用，无 secret 字段
    let record = store.orphan_record(&orphan.id).expect("read record");
    assert!(record.keychain_item_id.contains("orphan"));
    assert!(record.secret.is_none(), "孤儿记录不得输出 secret");
}

#[test]
fn reconciliation_baseline_counts() {
    let db = CredentialLifecycleDb::open_in_memory().expect("open lifecycle db");
    let store = CredentialLifecycleStore::new(&db);
    let g1 = store.create_generation("cfg-1", 1, "k-1").expect("gen 1");
    let g2 = store.create_generation("cfg-1", 2, "k-2").expect("gen 2");
    let _g3 = store.create_generation("cfg-2", 1, "k-3").expect("gen 3");
    store.activate_generation(&g1.id).expect("activate gen 1");

    let counts = store.reconciliation_counts().expect("counts");
    assert_eq!(counts.generations, 3, "每个 generation ↔ 一个 lifecycle");
    assert_eq!(
        counts.keychain_items, 3,
        "每个 Keychain item ↔ 一个 generation"
    );
    assert_eq!(
        counts.pending_generations, 2,
        "pending generation ↔ 一个 setup operation + 一个具名 role"
    );
    assert_eq!(counts.active_generations, 1);
}
