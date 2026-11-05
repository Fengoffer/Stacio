use stacio_core::infrastructure::conversation_v2::control::{
    ControlDb, ControlError, ControlStore,
};

/// P3-9：agentConversationV2 三态控制面（enabled→draining→disabled→enabled）。
#[test]
fn control_state_transitions_with_generation_cas() {
    let db = ControlDb::open_in_memory().expect("open control db");
    let store = ControlStore::new(&db);

    assert_eq!(store.control_state().expect("read"), "enabled");
    store
        .transition_control("draining", 1, "transition-1")
        .expect("draining");
    store
        .transition_control("disabled", 2, "transition-2")
        .expect("disabled");
    store
        .transition_control("enabled", 2, "transition-3")
        .expect("re-enabled");

    // 旧 generation 的 transition 拒绝（CAS）
    assert!(
        matches!(
            store.transition_control("draining", 0, "transition-stale"),
            Err(ControlError::StaleGeneration { .. })
        ),
        "旧 generation 的 transition 必须拒绝"
    );
}

#[test]
fn transition_id_idempotent() {
    let db = ControlDb::open_in_memory().expect("open control db");
    let store = ControlStore::new(&db);
    // 同 transition ID 重复投递幂等：不改变状态
    store
        .transition_control("draining", 1, "transition-1")
        .expect("first");
    store
        .transition_control("draining", 1, "transition-1")
        .expect("idempotent replay");
    assert_eq!(store.control_state().expect("read"), "draining");
}

#[test]
fn draining_fences_new_permits_and_precommit_transitions_but_allows_settlement() {
    let db = ControlDb::open_in_memory().expect("open control db");
    let store = ControlStore::new(&db);

    store
        .create_permit("authorized", 1, vec!["participant-a"])
        .expect("issue authorized permit");
    store
        .prepare_permit("authorized")
        .expect("prepare before drain");
    store
        .authorize_permit_commit("authorized")
        .expect("authorize before drain");
    store
        .create_permit("unprepared", 1, vec!["participant-b"])
        .expect("issue unprepared permit");

    store
        .transition_control("draining", 1, "start-drain")
        .expect("enter draining");

    assert!(matches!(
        store.create_permit("late", 2, vec!["participant-c"]),
        Err(ControlError::AuthorizationClosed { .. })
    ));
    assert!(matches!(
        store.prepare_permit("unprepared"),
        Err(ControlError::AuthorizationClosed { .. })
    ));

    store
        .settle_permit("authorized", "settling", "settlement-start")
        .expect("start settlement while draining");
    store
        .settle_permit("authorized", "settledCommitted", "settlement-proof")
        .expect("finish settlement while draining");
}

#[test]
fn permit_state_machine_closed() {
    let db = ControlDb::open_in_memory().expect("open control db");
    let store = ControlStore::new(&db);

    store
        .create_permit("permit-1", 1, vec!["participant-a", "participant-b"])
        .expect("issue");
    assert_eq!(store.permit_state("permit-1").expect("read"), "issued");
    store.prepare_permit("permit-1").expect("prepare");
    store
        .authorize_permit_commit("permit-1")
        .expect("commit authorized");
    assert_eq!(
        store.permit_state("permit-1").expect("read"),
        "commitAuthorized"
    );
    // settlement-start（settling）先持久化，再终态结算——不跳过中间态
    store
        .settle_permit("permit-1", "settling", "settlement-start-proof")
        .expect("settlement start");
    assert_eq!(store.permit_state("permit-1").expect("read"), "settling");
    store
        .settle_permit("permit-1", "settledCommitted", "proof-1")
        .expect("settle committed");
    assert_eq!(
        store.permit_state("permit-1").expect("read"),
        "settledCommitted"
    );

    // 终态无出口
    assert!(
        matches!(
            store.prepare_permit("permit-1"),
            Err(ControlError::InvalidTransition { .. })
        ),
        "终态不允许再迁移"
    );
}

#[test]
fn permit_abort_path() {
    let db = ControlDb::open_in_memory().expect("open control db");
    let store = ControlStore::new(&db);
    store
        .create_permit("permit-1", 1, vec!["participant-a"])
        .expect("issue");
    store.prepare_permit("permit-1").expect("prepare");
    store
        .settle_permit("permit-1", "settledAborted", "abort-proof")
        .expect("abort");
    assert_eq!(
        store.permit_state("permit-1").expect("read"),
        "settledAborted"
    );
}

#[test]
fn permit_expiry_requires_no_target_proof_for_unprepared_only() {
    let db = ControlDb::open_in_memory().expect("open control db");
    let store = ControlStore::new(&db);

    // 未 prepared 的 issued Permit：expiry/drain 只能以 no-target proof 结算
    store
        .create_permit("permit-1", 1, vec!["participant-a"])
        .expect("issue");
    assert!(
        matches!(
            store.expire_permit("permit-1", true),
            Err(ControlError::InvalidSettlement { .. })
        ),
        "带 target proof 的 expiry 不允许（未 prepared 只能 no-target proof）"
    );
    store
        .expire_permit("permit-1", false)
        .expect("no-target expiry");
    assert_eq!(
        store.permit_state("permit-1").expect("read"),
        "settledAborted"
    );

    // prepared 未授权：必须 abort decision + 全 target abort proof（不允许 no-target expiry）
    store
        .create_permit("permit-2", 1, vec!["participant-a", "participant-b"])
        .expect("issue");
    store.prepare_permit("permit-2").expect("prepare");
    assert!(
        matches!(
            store.expire_permit("permit-2", false),
            Err(ControlError::PreparedRequiresAbortDecision { .. })
        ),
        "prepared 未授权必须 abort decision + 全 target abort proof"
    );
}

#[test]
fn target_journal_frozen_participant_set_and_partial_commit_blocks_disabled() {
    let db = ControlDb::open_in_memory().expect("open control db");
    let store = ControlStore::new(&db);

    store
        .create_permit("permit-1", 1, vec!["participant-a", "participant-b"])
        .expect("issue");
    let participants = store
        .journal_participants("permit-1")
        .expect("read journal");
    assert_eq!(participants.len(), 2, "journal 冻结完整 participant set");
    assert_eq!(participants[0], "participant-a");

    // 局部提交：participant-a committed，participant-b reconciliationRequired → 阻止 disabled
    store
        .mark_journal("permit-1", "participant-a", "committed")
        .expect("a committed");
    store
        .mark_journal("permit-1", "participant-b", "reconciliationRequired")
        .expect("b pending");
    assert!(
        matches!(
            store.transition_control("disabled", 1, "transition-blocked"),
            Err(ControlError::PartialCommitBlocksDisabled { .. })
        ),
        "局部提交/reconciliationRequired 阻止 disabled"
    );

    // 全部结算后可 disabled（settlement-start 先持久化，再终态结算）
    store
        .mark_journal("permit-1", "participant-b", "committed")
        .expect("b committed");
    store
        .settle_permit("permit-1", "settling", "settlement-start-proof")
        .expect("settle start");
    store
        .settle_permit("permit-1", "settledCommitted", "proof")
        .expect("settle");
    assert!(store
        .transition_control("disabled", 1, "transition-ok")
        .is_ok());
}

#[test]
fn draining_fence_blocks_new_authorization() {
    let db = ControlDb::open_in_memory().expect("open control db");
    let store = ControlStore::new(&db);
    store
        .transition_control("draining", 1, "t-1")
        .expect("draining");

    assert!(
        !store.authorization_allowed().expect("read"),
        "draining 后不得签发新 authorization"
    );
    store
        .transition_control("disabled", 2, "t-2")
        .expect("disabled");
    assert!(
        !store.authorization_allowed().expect("read"),
        "disabled 后无新 authorization（draining fence 已关）"
    );
}
