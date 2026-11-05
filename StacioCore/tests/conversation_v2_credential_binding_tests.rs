use stacio_core::infrastructure::conversation_v2::credential_binding::{
    BindingReconciliationOutcome, CredentialBindingDb, CredentialBindingError,
    CredentialBindingStore,
};

/// P3-8b：CredentialAttemptBinding 跨 Store saga 与零 binding proof。
#[test]
fn binding_state_machine_closed_transitions() {
    let db = CredentialBindingDb::open_in_memory().expect("open binding db");
    let store = CredentialBindingStore::new(&db);

    store
        .reserve("binding-1", "a-1", "gen-1", 0)
        .expect("reserve binding");
    assert_eq!(store.binding_state("binding-1").expect("read"), "reserved");

    // reserved → commitPending → committed
    store
        .mark_commit_pending("binding-1")
        .expect("commit pending");
    store
        .commit_bound("binding-1", 5, "proof-digest")
        .expect("commit bound");
    assert_eq!(store.binding_state("binding-1").expect("read"), "committed");
    assert_eq!(
        store.commit_sequence("binding-1").expect("read"),
        5,
        "binding 冻结 Conversation commit proof"
    );

    // committed → releasing → released
    store.release("binding-1", 5).expect("release");
    assert_eq!(store.binding_state("binding-1").expect("read"), "released");
}

#[test]
fn binding_quarantine_on_unconfirmed_release() {
    let db = CredentialBindingDb::open_in_memory().expect("open binding db");
    let store = CredentialBindingStore::new(&db);
    store
        .reserve("binding-1", "a-1", "gen-1", 0)
        .expect("reserve");

    // 无法确认 Conversation 终态 → quarantine（阻止删除）
    store
        .quarantine("binding-1", "conversation commit ack lost")
        .expect("quarantine");
    assert_eq!(
        store.binding_state("binding-1").expect("read"),
        "quarantined"
    );
}

#[test]
fn binding_reconciliation_four_windows() {
    // 四种窗口对账：已提交→补 committed；明确不存在且越过恢复点→released；无法确认→quarantine
    let outcome = CredentialBindingStore::reconcile_window(true, 7, false, true);
    assert_eq!(
        outcome,
        BindingReconciliationOutcome::CommitConfirmed,
        "已提交但 ack 丢失 → 补 committed"
    );

    let released = CredentialBindingStore::reconcile_window(false, 0, false, true);
    assert_eq!(
        released,
        BindingReconciliationOutcome::ReleaseConfirmed,
        "明确不存在且越过可提交恢复点 → released"
    );

    let quarantine = CredentialBindingStore::reconcile_window(false, 0, false, false);
    assert_eq!(
        quarantine,
        BindingReconciliationOutcome::Quarantine,
        "无法确认 → quarantine（阻止删除）"
    );
}

#[test]
fn binding_terminal_release_requires_conversation_terminal_proof() {
    let db = CredentialBindingDb::open_in_memory().expect("open binding db");
    let store = CredentialBindingStore::new(&db);
    store
        .reserve("binding-1", "a-1", "gen-1", 0)
        .expect("reserve");

    // 终态 release 必须验证 Conversation 终态 commit proof
    assert!(
        matches!(
            store.release("binding-1", 0),
            Err(CredentialBindingError::MissingTerminalProof { .. })
        ),
        "无 Conversation 终态 proof 不得 release"
    );
}

#[test]
fn derived_active_binding_count_only_from_unreleased_bindings() {
    let db = CredentialBindingDb::open_in_memory().expect("open binding db");
    let store = CredentialBindingStore::new(&db);
    store.reserve("binding-1", "a-1", "gen-1", 0).expect("b1");
    store.reserve("binding-2", "a-2", "gen-1", 0).expect("b2");
    store.reserve("binding-3", "a-3", "gen-2", 0).expect("b3");
    store.mark_commit_pending("binding-2").expect("b2 pending");
    store
        .commit_bound("binding-2", 3, "proof")
        .expect("b2 committed");
    store.release("binding-2", 3).expect("b2 released");

    let active = store.derived_active_binding_count().expect("count");
    assert_eq!(
        active, 2,
        "只由未释放 binding 的权威索引派生（released/quarantined 不计）"
    );
}

#[test]
fn binding_participant_proof_by_authentication_mode() {
    // stacioCredentialBindings|combined → 必须有 binding
    assert_eq!(
        CredentialBindingStore::participant_proof("stacioCredentialBindings", 0),
        Err(CredentialBindingError::MissingRequiredBinding),
        "stacioCredentialBindings 必须有 binding"
    );
    assert!(CredentialBindingStore::participant_proof("stacioCredentialBindings", 1).is_ok());
    assert_eq!(
        CredentialBindingStore::participant_proof("combined", 0),
        Err(CredentialBindingError::MissingRequiredBinding)
    );
    // cliManagedAuthentication|noneVerified → 必须零 binding；异常 binding → 隔离
    assert!(CredentialBindingStore::participant_proof("cliManagedAuthentication", 0).is_ok());
    assert_eq!(
        CredentialBindingStore::participant_proof("cliManagedAuthentication", 1),
        Err(CredentialBindingError::UnexpectedBinding),
        "cliManaged 出现异常 binding 必须隔离"
    );
    assert!(CredentialBindingStore::participant_proof("noneVerified", 0).is_ok());
    assert_eq!(
        CredentialBindingStore::participant_proof("noneVerified", 1),
        Err(CredentialBindingError::UnexpectedBinding)
    );
}
