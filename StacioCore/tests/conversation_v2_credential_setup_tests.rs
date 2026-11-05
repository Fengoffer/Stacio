use stacio_core::infrastructure::conversation_v2::credential_setup::{
    CredentialSetupDb, CredentialSetupError, CredentialSetupStore,
};

/// P3-8c：CredentialUseLease owner 隔离、VerificationRequest 状态机与 revoke fence。
#[test]
fn use_lease_owner_isolation_enforced() {
    let db = CredentialSetupDb::open_in_memory().expect("open setup db");
    let store = CredentialSetupStore::new(&db);

    store
        .acquire_use_lease("lease-1", "attempt", "gen-1")
        .expect("attempt owner lease");
    // setup / configuration-action 不能接管 attempt 的 lease
    assert!(matches!(
        store.validate_owner("lease-1", "setup"),
        Err(CredentialSetupError::OwnerMismatch { .. })
    ));
    assert!(matches!(
        store.validate_owner("lease-1", "configurationAction"),
        Err(CredentialSetupError::OwnerMismatch { .. })
    ));
    assert!(store.validate_owner("lease-1", "attempt").is_ok());

    // 三类 owner 各自独立
    store
        .acquire_use_lease("lease-2", "setup", "gen-1")
        .expect("setup owner lease");
    store
        .acquire_use_lease("lease-3", "configurationAction", "gen-1")
        .expect("config owner lease");
    assert!(store.validate_owner("lease-2", "setup").is_ok());
    assert!(store
        .validate_owner("lease-3", "configurationAction")
        .is_ok());
}

#[test]
fn verification_request_state_machine_closed() {
    let db = CredentialSetupDb::open_in_memory().expect("open setup db");
    let store = CredentialSetupStore::new(&db);

    store
        .create_verification_request("req-1", "cfg-1")
        .expect("create request");
    assert_eq!(store.request_state("req-1").expect("read"), "prepared");

    // prepared → inFlight
    store.mark_in_flight("req-1").expect("in flight");
    // inFlight → settledSucceeded / settledFailed / cancellationRequested / stateUnknown
    store
        .settle_verification("req-1", "settledSucceeded")
        .expect("settle succeeded");
    assert_eq!(
        store.request_state("req-1").expect("read"),
        "settledSucceeded"
    );

    // 终态后任何转换拒绝
    assert!(matches!(
        store.mark_in_flight("req-1"),
        Err(CredentialSetupError::InvalidTransition { .. })
    ));
}

#[test]
fn verification_request_cancellation_path() {
    let db = CredentialSetupDb::open_in_memory().expect("open setup db");
    let store = CredentialSetupStore::new(&db);
    store
        .create_verification_request("req-1", "cfg-1")
        .expect("create request");
    store.mark_in_flight("req-1").expect("in flight");
    // inFlight → cancellationRequested
    store
        .request_cancellation("req-1")
        .expect("cancellation requested");
    // cancellationRequested → settledCancelled
    store
        .settle_verification("req-1", "settledCancelled")
        .expect("settle cancelled");
    assert_eq!(
        store.request_state("req-1").expect("read"),
        "settledCancelled"
    );
}

#[test]
fn revoke_fence_closes_gate_before_fanout() {
    let db = CredentialSetupDb::open_in_memory().expect("open setup db");
    let store = CredentialSetupStore::new(&db);

    store
        .create_generation_fence("gen-1")
        .expect("create fence");
    assert_eq!(store.fence_closed("gen-1").expect("read"), false);

    // revoke fence：先 durable 关 gate（closed=true），再 fan-out
    store.close_revoke_fence("gen-1").expect("close fence");
    assert_eq!(
        store.fence_closed("gen-1").expect("read"),
        true,
        "revoke gate 必须先关闭"
    );

    // gate 关闭后新 use lease 拒绝（fan-out 前 gate 已关）
    assert!(
        matches!(
            store.acquire_use_lease("lease-x", "attempt", "gen-1"),
            Err(CredentialSetupError::RevokeGateClosed { .. })
        ),
        "revoke gate 关闭后不得再获取 use lease"
    );
}

#[test]
fn use_lease_lifecycle_requested_to_released() {
    let db = CredentialSetupDb::open_in_memory().expect("open setup db");
    let store = CredentialSetupStore::new(&db);
    store
        .acquire_use_lease("lease-1", "attempt", "gen-1")
        .expect("acquire");
    assert_eq!(store.lease_state("lease-1").expect("read"), "granted");
    store.release_use_lease("lease-1").expect("release");
    assert_eq!(store.lease_state("lease-1").expect("read"), "released");
}
