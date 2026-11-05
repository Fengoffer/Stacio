use stacio_core::infrastructure::conversation_v2::settings::{
    SettingsDb, SettingsError, SettingsStore,
};

/// P3-11：AssistantSettingsStore Rust 后端（独立设置域存储，不依赖会话库）。
#[test]
fn setting_value_expected_revision_cas() {
    let db = SettingsDb::open_in_memory().expect("open settings db");
    let store = SettingsStore::new(&db);

    // 初始写入（无 expected revision → 创建，revision 1）
    store
        .upsert_setting(
            "appearance.fontSize",
            None,
            "digest-v1",
            "user",
            "migration-key-1",
        )
        .expect("create");
    let (revision, digest) = store
        .setting_value("appearance.fontSize")
        .expect("read")
        .expect("exists");
    assert_eq!(revision, 1);
    assert_eq!(digest, "digest-v1");

    // expected revision 匹配 → 更新，revision 递增
    store
        .upsert_setting(
            "appearance.fontSize",
            Some(1),
            "digest-v2",
            "user",
            "migration-key-1",
        )
        .expect("update");
    let (revision, digest) = store
        .setting_value("appearance.fontSize")
        .expect("read")
        .expect("exists");
    assert_eq!(revision, 2);
    assert_eq!(digest, "digest-v2");

    // expected revision 不匹配 → StaleRevision
    assert!(matches!(
        store.upsert_setting(
            "appearance.fontSize",
            Some(1),
            "digest-v3",
            "user",
            "migration-key-1"
        ),
        Err(SettingsError::StaleRevision { .. })
    ));
    // 已存在但 expected None → 冲突（必须显式 CAS）
    assert!(matches!(
        store.upsert_setting(
            "appearance.fontSize",
            None,
            "digest-v3",
            "user",
            "migration-key-1"
        ),
        Err(SettingsError::KeyExists { .. })
    ));
}

#[test]
fn setting_scope_and_migration_key_preserved() {
    let db = SettingsDb::open_in_memory().expect("open settings db");
    let store = SettingsStore::new(&db);
    store
        .upsert_setting("provider.model", None, "digest-1", "workspace", "mig-7")
        .expect("create");
    let meta = store
        .setting_metadata("provider.model")
        .expect("read")
        .expect("exists");
    assert_eq!(meta.scope, "workspace");
    assert_eq!(meta.migration_key, "mig-7");
}

#[test]
fn events_durable_sequence_single_writer() {
    let db = SettingsDb::open_in_memory().expect("open settings db");
    let store = SettingsStore::new(&db);

    let seq1 = store
        .append_event("ev-1", "op-1", "settingMutationRequested")
        .expect("event 1");
    let seq2 = store
        .append_event("ev-2", "op-1", "settingMutationCommitted")
        .expect("event 2");
    let seq3 = store
        .append_event("ev-3", "op-1", "settingMutationSettled")
        .expect("event 3");
    assert_eq!(seq1, 1, "durable sequence 从 1 开始");
    assert_eq!(seq2, 2);
    assert_eq!(seq3, 3);

    // 同 event_id 重复投递 → 幂等（不新增 sequence）
    let seq2_again = store
        .append_event("ev-2", "op-1", "settingMutationCommitted")
        .expect("idempotent");
    assert_eq!(seq2_again, 2, "重复投递幂等返回原 sequence");
    assert_eq!(store.next_sequence().expect("read"), 4);
}

#[test]
fn setting_mutation_writes_committed_and_settled_dual_events() {
    let db = SettingsDb::open_in_memory().expect("open settings db");
    let store = SettingsStore::new(&db);

    // 成功 Setting mutation：committed + settled 双事件（以操作 ID 关联）
    store
        .append_event("ev-1", "op-1", "settingMutationRequested")
        .expect("requested");
    store
        .append_event("ev-2", "op-1", "settingMutationCommitted")
        .expect("committed");
    store
        .append_event("ev-3", "op-1", "settingMutationSettled")
        .expect("settled");

    let kinds = store.events("op-1").expect("audit");
    assert_eq!(
        kinds,
        vec![
            "settingMutationRequested",
            "settingMutationCommitted",
            "settingMutationSettled"
        ]
    );
}

#[test]
fn settled_events_require_prior_evidence() {
    let db = SettingsDb::open_in_memory().expect("open settings db");
    let store = SettingsStore::new(&db);

    // Permit 已结算但异步 Action 未取得业务结果 → 不允许写 actionSettled（无 requested 证据）
    assert!(matches!(
        store.append_event("ev-1", "op-1", "actionSettled"),
        Err(SettingsError::SettledWithoutEvidence { .. })
    ));
    // settingMutationSettled 需要同 op 的 committed 证据
    assert!(matches!(
        store.append_event("ev-2", "op-2", "settingMutationSettled"),
        Err(SettingsError::SettledWithoutEvidence { .. })
    ));

    store
        .append_event("ev-3", "op-1", "actionRequested")
        .expect("requested");
    store
        .append_event("ev-4", "op-1", "actionSettled")
        .expect("settled");
    store
        .append_event("ev-5", "op-2", "settingMutationCommitted")
        .expect("committed");
    store
        .append_event("ev-6", "op-2", "settingMutationSettled")
        .expect("settled");
}

#[test]
fn closed_event_kind_set() {
    let db = SettingsDb::open_in_memory().expect("open settings db");
    let store = SettingsStore::new(&db);

    // 关闭 kind 集合之外的值拒绝
    assert!(matches!(
        store.append_event("ev-1", "op-1", "arbitraryKind"),
        Err(SettingsError::InvalidKind { .. })
    ));
    // maintenance fence 与 export manifest 事件合法
    store
        .append_event("ev-2", "op-1", "maintenanceFenceAcquired")
        .expect("fence");
    store
        .append_event("ev-3", "op-1", "exportManifestCreated")
        .expect("manifest");
}

#[test]
fn settings_domain_isolated_from_conversation_db() {
    // 独立存储域：settings 库与 conversation v2 库是不同文件（存储域边界）。
    let dir = std::env::temp_dir().join(format!("settings-domain-{}", std::process::id()));
    std::fs::create_dir_all(&dir).expect("mkdir");
    let settings_path = dir.join("agent-settings.sqlite3");
    let conversation_path = dir.join("agent-conversations-v2.sqlite3");
    let _ = std::fs::remove_file(&settings_path);
    let _ = std::fs::remove_file(&conversation_path);

    let db = SettingsDb::open(settings_path.to_str().expect("path")).expect("open settings");
    let store = SettingsStore::new(&db);
    store
        .append_event("ev-1", "op-1", "settingMutationRequested")
        .expect("event");

    assert!(
        settings_path.exists() && !conversation_path.exists(),
        "清空会话后 Settings 仍独立存在（独立文件域）"
    );
    let _ = std::fs::remove_file(&settings_path);
    let _ = std::fs::remove_dir_all(&dir);
}
