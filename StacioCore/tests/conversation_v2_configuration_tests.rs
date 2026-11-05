use stacio_core::infrastructure::conversation_v2::configuration_store::{
    ConfigurationDb, ConfigurationError, ConfigurationStore,
};

/// P3-12：Configuration Store Rust 后端（独立 Configuration Store，revision CAS + configuration-scoped event）。
#[test]
fn configuration_revision_cas_and_reference_only() {
    let db = ConfigurationDb::open_in_memory().expect("open configuration db");
    let store = ConfigurationStore::new(&db);

    // 创建（expected None）：revision 1，credential 只存引用不存权威
    store
        .upsert_configuration("config-1", None, "digest-v1", "credential-lifecycle:gen-7")
        .expect("create");
    let config = store
        .configuration("config-1")
        .expect("read")
        .expect("exists");
    assert_eq!(config.revision, 1);
    assert_eq!(config.value_digest, "digest-v1");
    assert_eq!(config.credential_reference, "credential-lifecycle:gen-7");
    assert!(
        !config.credential_reference.contains("secret"),
        "credential 只存引用（generation id），不存 secret"
    );

    // CAS 更新
    store
        .upsert_configuration(
            "config-1",
            Some(1),
            "digest-v2",
            "credential-lifecycle:gen-7",
        )
        .expect("update");
    assert_eq!(
        store
            .configuration("config-1")
            .expect("read")
            .expect("exists")
            .revision,
        2
    );

    // 旧 revision 拒绝；已存在但无 expected 拒绝
    assert!(matches!(
        store.upsert_configuration("config-1", Some(1), "d", "r"),
        Err(ConfigurationError::StaleRevision { .. })
    ));
    assert!(matches!(
        store.upsert_configuration("config-1", None, "d", "r"),
        Err(ConfigurationError::KeyExists { .. })
    ));
}

#[test]
fn runtime_configuration_event_closed_kinds_and_configuration_scoped_sequence() {
    let db = ConfigurationDb::open_in_memory().expect("open configuration db");
    let store = ConfigurationStore::new(&db);

    let seq1 = store
        .append_event("ev-1", "config-1", "op-1", "configurationDraftSaved")
        .expect("draft");
    let seq2 = store
        .append_event("ev-2", "config-1", "op-1", "configurationMutationCommitted")
        .expect("committed");
    let seq3 = store
        .append_event("ev-3", "config-1", "op-1", "configurationActivated")
        .expect("activated");
    assert_eq!(seq1, 1);
    assert_eq!(seq2, 2);
    assert_eq!(seq3, 3);

    // 同 event_id 幂等
    assert_eq!(
        store
            .append_event("ev-2", "config-1", "op-1", "configurationMutationCommitted")
            .expect("idempotent"),
        2
    );
    assert!(matches!(
        store.append_event(
            "ev-2",
            "config-other",
            "op-1",
            "configurationMutationCommitted"
        ),
        Err(ConfigurationError::EventIdConflict { .. })
    ));
    assert!(matches!(
        store.append_event(
            "ev-2",
            "config-1",
            "op-other",
            "configurationMutationCommitted"
        ),
        Err(ConfigurationError::EventIdConflict { .. })
    ));
    assert!(matches!(
        store.append_event("ev-2", "config-1", "op-1", "configurationActivated"),
        Err(ConfigurationError::EventIdConflict { .. })
    ));

    // configuration-scoped audit（按 sequence 排序；不同 configuration 隔离）
    store
        .append_event("ev-4", "config-2", "op-2", "configurationDraftSaved")
        .expect("other");
    assert_eq!(
        store.events("config-1").expect("audit"),
        vec![
            "configurationDraftSaved",
            "configurationMutationCommitted",
            "configurationActivated"
        ]
    );

    // 关闭 kind 集合之外拒绝
    assert!(matches!(
        store.append_event("ev-5", "config-1", "op-1", "arbitraryKind"),
        Err(ConfigurationError::InvalidKind { .. })
    ));
}

#[test]
fn mutation_deletion_correlated_by_operation_id() {
    use stacio_core::infrastructure::conversation_v2::settings::{SettingsDb, SettingsStore};

    let db = ConfigurationDb::open_in_memory().expect("open configuration db");
    let store = ConfigurationStore::new(&db);

    // mutation 与 Action audit 通过同一 operation ID 关联：op-1 的 configuration 事件在本库
    store
        .append_event("ev-1", "config-1", "op-1", "configurationDraftSaved")
        .expect("config event");
    store
        .append_event("ev-2", "config-1", "op-1", "configurationMutationCommitted")
        .expect("config event");
    let kinds = store.events_by_operation("op-1").expect("correlation");
    assert_eq!(
        kinds,
        vec!["configurationDraftSaved", "configurationMutationCommitted"]
    );

    // 跨域关联：Action audit 在 settings 域（同一 operation ID）；两库各自查询，投影时合并
    let settings_db = SettingsDb::open_in_memory().expect("open settings db");
    let settings_store = SettingsStore::new(&settings_db);
    settings_store
        .append_event("ev-3", "op-1", "actionRequested")
        .expect("action event");
    assert_eq!(
        settings_store.events("op-1").expect("settings audit"),
        vec!["actionRequested"]
    );

    // 缺 action 事件（op-2 只有 configuration 事件）→ 投影为 NeedsReview（调用方合并两库后判定）
    store
        .append_event("ev-4", "config-1", "op-2", "configurationDraftSaved")
        .expect("config event");
    let incomplete = store.events_by_operation("op-2").expect("correlation");
    assert_eq!(
        incomplete.len(),
        1,
        "同 operation 缺 Action audit → NeedsReview 由投影层判定"
    );
}

#[test]
fn configuration_state_machine_closed() {
    let db = ConfigurationDb::open_in_memory().expect("open configuration db");
    let store = ConfigurationStore::new(&db);
    store
        .upsert_configuration("config-1", None, "digest-v1", "credential-lifecycle:gen-7")
        .expect("create");

    // draft → prepared → dispatched → activating → active
    store
        .transition_state("config-1", "prepared")
        .expect("prepared");
    store
        .transition_state("config-1", "dispatched")
        .expect("dispatched");
    store
        .transition_state("config-1", "activating")
        .expect("activating");
    store
        .transition_state("config-1", "active")
        .expect("active");
    assert_eq!(
        store
            .configuration("config-1")
            .expect("read")
            .expect("exists")
            .state,
        "active"
    );

    // 回退非法
    assert!(matches!(
        store.transition_state("config-1", "prepared"),
        Err(ConfigurationError::InvalidTransition { .. })
    ));

    // deleted 终态
    store
        .transition_state("config-1", "deleted")
        .expect("delete");
    assert!(matches!(
        store.transition_state("config-1", "active"),
        Err(ConfigurationError::InvalidTransition { .. })
    ));
}

#[test]
fn verified_commit_and_delete_are_atomic_revision_cas_operations() {
    let db = ConfigurationDb::open_in_memory().expect("open configuration db");
    let store = ConfigurationStore::new(&db);

    let revision = store
        .commit_verified_configuration(
            "config-atomic",
            None,
            "digest-v1",
            "cli-managed:codex",
            "op-create",
            "ev-create",
        )
        .expect("commit verified");
    assert_eq!(revision, 1);
    let active = store
        .configuration("config-atomic")
        .expect("read")
        .expect("active config");
    assert_eq!(active.state, "active");
    assert_eq!(
        store.events("config-atomic").expect("events"),
        vec!["configurationMutationCommitted", "configurationActivated"]
    );

    assert!(matches!(
        store.delete_configuration(
            "config-atomic",
            0,
            "deleted-digest",
            "op-delete-stale",
            "ev-delete-stale",
        ),
        Err(ConfigurationError::StaleRevision { .. })
    ));
    assert_eq!(
        store
            .configuration("config-atomic")
            .expect("read after stale")
            .expect("still active")
            .state,
        "active"
    );

    let deleted_revision = store
        .delete_configuration(
            "config-atomic",
            1,
            "deleted-digest",
            "op-delete",
            "ev-delete",
        )
        .expect("delete");
    assert_eq!(deleted_revision, 2);
    let deleted = store
        .configuration("config-atomic")
        .expect("read deleted")
        .expect("tombstone");
    assert_eq!(deleted.state, "deleted");
    assert_eq!(deleted.revision, 2);
    assert_eq!(deleted.credential_reference, "");
    assert_eq!(
        store
            .events_by_operation("op-delete")
            .expect("delete events"),
        vec!["configurationDeletionCommitted", "configurationDeleted"]
    );

    // Exact retries are idempotent; reusing the id with another payload is not.
    let retry_db = ConfigurationDb::open_in_memory().expect("open retry db");
    let retry_store = ConfigurationStore::new(&retry_db);
    assert_eq!(
        retry_store
            .commit_verified_configuration(
                "retry-config",
                None,
                "digest-retry",
                "cli-managed:retry",
                "retry-op",
                "retry-event",
            )
            .expect("first commit"),
        1
    );
    assert_eq!(
        retry_store
            .commit_verified_configuration(
                "retry-config",
                None,
                "digest-retry",
                "cli-managed:retry",
                "retry-op",
                "retry-event",
            )
            .expect("idempotent commit"),
        1
    );
    assert!(matches!(
        retry_store.commit_verified_configuration(
            "retry-config",
            None,
            "different-digest",
            "cli-managed:retry",
            "retry-op",
            "retry-event",
        ),
        Err(ConfigurationError::EventIdConflict { .. })
    ));
    assert_eq!(
        retry_store
            .delete_configuration(
                "retry-config",
                1,
                "retry-tombstone",
                "retry-delete",
                "retry-delete-event",
            )
            .expect("first delete"),
        2
    );
    assert_eq!(
        retry_store
            .delete_configuration(
                "retry-config",
                1,
                "retry-tombstone",
                "retry-delete",
                "retry-delete-event",
            )
            .expect("idempotent delete"),
        2
    );
    assert!(matches!(
        retry_store.delete_configuration(
            "retry-config",
            1,
            "different-tombstone",
            "retry-delete",
            "retry-delete-event",
        ),
        Err(ConfigurationError::EventIdConflict { .. })
    ));
}

#[test]
fn configuration_domain_isolated_storage() {
    // 独立 Configuration Store：不与会话库/设置库混用（storage domain 边界）。
    let dir = std::env::temp_dir().join(format!("config-domain-{}", std::process::id()));
    std::fs::create_dir_all(&dir).expect("mkdir");
    let path = dir.join("runtime-configuration.sqlite3");
    let _ = std::fs::remove_file(&path);

    let db = ConfigurationDb::open(path.to_str().expect("path")).expect("open");
    let store = ConfigurationStore::new(&db);
    store
        .append_event("ev-1", "config-1", "op-1", "configurationDraftSaved")
        .expect("event");
    assert!(path.exists(), "Configuration Store 独立文件域");
    let _ = std::fs::remove_file(&path);
    let _ = std::fs::remove_dir_all(&dir);
}
