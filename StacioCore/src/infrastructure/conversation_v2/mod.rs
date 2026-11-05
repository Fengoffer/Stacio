pub mod admission;
pub mod compaction;
pub mod configuration_store;
pub mod control;
pub mod credential_binding;
pub mod credential_lifecycle;
pub mod credential_setup;
pub mod reconciliation;
pub mod repository;
pub mod schema;
pub mod sequence;
pub mod settings;

pub use admission::{AdmissionLeaseRecord, AdmissionRequestRecord, AdmissionStateRecord};
pub use repository::{
    CommitOutcome, CommitRequest, ConversationV2Repository, LoadedEventRecord, LoadedOutboxRecord,
};
pub use schema::ConversationV2Db;

// MARK: - UniFFI 导出（P3-6：Swift ConversationRepositoryV2 接线）

use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock};

/// UniFFI 错误（Swift 侧呈现 message）。
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum ConversationV2Error {
    #[error("{message}")]
    Message { message: String },
}

impl From<String> for ConversationV2Error {
    fn from(message: String) -> Self {
        Self::Message { message }
    }
}

fn v2_registry() -> &'static Mutex<HashMap<u64, Arc<Mutex<ConversationV2Repository>>>> {
    static REGISTRY: OnceLock<Mutex<HashMap<u64, Arc<Mutex<ConversationV2Repository>>>>> =
        OnceLock::new();
    REGISTRY.get_or_init(|| Mutex::new(HashMap::new()))
}

fn admission_registry() -> &'static Mutex<HashMap<u64, Arc<admission::AdmissionStore>>> {
    static REGISTRY: OnceLock<Mutex<HashMap<u64, Arc<admission::AdmissionStore>>>> =
        OnceLock::new();
    REGISTRY.get_or_init(|| Mutex::new(HashMap::new()))
}

fn with_admission<F, T>(handle: u64, body: F) -> Result<T, ConversationV2Error>
where
    F: FnOnce(&admission::AdmissionStore) -> Result<T, admission::AdmissionError>,
{
    let registry = admission_registry()
        .lock()
        .map_err(|_| ConversationV2Error::from("admission registry poisoned".to_string()))?;
    let store = registry
        .get(&handle)
        .ok_or_else(|| ConversationV2Error::from("unknown conversation v2 handle".to_string()))?;
    body(store).map_err(|error| ConversationV2Error::from(format!("{error:?}")))
}

/// 打开（必要时创建）V2 独立库并返回会话句柄（Swift 侧通过句柄提交）。
#[uniffi::export]
pub fn conversation_v2_open(path: String) -> Result<u64, ConversationV2Error> {
    let db = ConversationV2Db::open(&path)
        .map_err(|error| ConversationV2Error::from(error.to_string()))?;
    let repo = ConversationV2Repository::new(&db);
    let admission_store = admission::AdmissionStore::new(&db);
    let mut registry = v2_registry()
        .lock()
        .map_err(|_| ConversationV2Error::from("registry poisoned".to_string()))?;
    let mut handle = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_nanos() as u64)
        .unwrap_or(1);
    while registry.contains_key(&handle) {
        handle = handle.wrapping_add(1);
    }
    registry.insert(handle, Arc::new(Mutex::new(repo)));
    admission_registry()
        .lock()
        .map_err(|_| ConversationV2Error::from("admission registry poisoned".to_string()))?
        .insert(handle, Arc::new(admission_store));
    Ok(handle)
}

/// 关闭会话句柄（释放 Registry 引用）。
#[uniffi::export]
pub fn conversation_v2_close(handle: u64) {
    let _ = v2_registry()
        .lock()
        .map(|mut registry| registry.remove(&handle));
    let _ = admission_registry()
        .lock()
        .map(|mut registry| registry.remove(&handle));
}

/// 单事务提交（Swift facade 已完成密封/投影后调用）。
#[uniffi::export]
pub fn conversation_v2_commit(
    handle: u64,
    request: CommitRequest,
) -> Result<CommitOutcome, ConversationV2Error> {
    let registry = v2_registry()
        .lock()
        .map_err(|_| ConversationV2Error::from("registry poisoned".to_string()))?;
    let repository = registry
        .get(&handle)
        .ok_or_else(|| ConversationV2Error::from("unknown conversation v2 handle".to_string()))?;
    let repository = repository
        .lock()
        .map_err(|_| ConversationV2Error::from("repository poisoned".to_string()))?;
    repository
        .commit(&request)
        .map_err(|error| ConversationV2Error::from(format!("{error:?}")))
}

/// 读取会话当前 lastApplied（幂等/对账）。
#[uniffi::export]
pub fn conversation_v2_last_applied(
    handle: u64,
    conversation_id: String,
) -> Result<i64, ConversationV2Error> {
    let registry = v2_registry()
        .lock()
        .map_err(|_| ConversationV2Error::from("registry poisoned".to_string()))?;
    let repository = registry
        .get(&handle)
        .ok_or_else(|| ConversationV2Error::from("unknown conversation v2 handle".to_string()))?;
    let connection = repository
        .lock()
        .map_err(|_| ConversationV2Error::from("repository poisoned".to_string()))?;
    connection
        .last_applied_for(conversation_id.as_str())
        .map_err(|error| ConversationV2Error::from(format!("{error:?}")))
}

/// P0-5：按 sequence 升序加载会话全部事件（重启恢复/replay）。
/// 返回加密 payload；Swift 侧经 ConversationEncryption 解密后 replay 到 ConversationSessionState。
#[uniffi::export]
pub fn conversation_v2_load_events(
    handle: u64,
    conversation_id: String,
) -> Result<Vec<LoadedEventRecord>, ConversationV2Error> {
    let registry = v2_registry()
        .lock()
        .map_err(|_| ConversationV2Error::from("registry poisoned".to_string()))?;
    let repository = registry
        .get(&handle)
        .ok_or_else(|| ConversationV2Error::from("unknown conversation v2 handle".to_string()))?;
    let connection = repository
        .lock()
        .map_err(|_| ConversationV2Error::from("repository poisoned".to_string()))?;
    connection
        .load_events(conversation_id.as_str())
        .map_err(|error| ConversationV2Error::from(format!("{error:?}")))
}

/// Lists the non-sensitive V2 session index. Display metadata remains in the
/// encrypted event stream and is decrypted by the Swift facade on demand.
#[uniffi::export]
pub fn conversation_v2_list_sessions(
    handle: u64,
) -> Result<Vec<repository::LoadedConversationSessionRecord>, ConversationV2Error> {
    let registry = v2_registry()
        .lock()
        .map_err(|_| ConversationV2Error::from("v2 registry poisoned".to_string()))?;
    let repository = registry
        .get(&handle)
        .ok_or_else(|| ConversationV2Error::from("invalid v2 handle".to_string()))?;
    let repository = repository
        .lock()
        .map_err(|_| ConversationV2Error::from("repository poisoned".to_string()))?;
    repository
        .list_sessions()
        .map_err(|error| ConversationV2Error::from(format!("{error:?}")))
}

/// Load pending, dispatching, and reconciliation-required effects.
#[uniffi::export]
pub fn conversation_v2_load_unsettled_outbox(
    handle: u64,
    conversation_id: String,
) -> Result<Vec<LoadedOutboxRecord>, ConversationV2Error> {
    let registry = v2_registry()
        .lock()
        .map_err(|_| ConversationV2Error::from("registry poisoned".to_string()))?;
    let repository = registry
        .get(&handle)
        .ok_or_else(|| ConversationV2Error::from("unknown conversation v2 handle".to_string()))?;
    let repository = repository
        .lock()
        .map_err(|_| ConversationV2Error::from("repository poisoned".to_string()))?;
    repository
        .load_unsettled_outbox(conversation_id.as_str())
        .map_err(|error| ConversationV2Error::from(format!("{error:?}")))
}

/// Atomically claim one pending effect by stable effect ID.
#[uniffi::export]
pub fn conversation_v2_claim_outbox_effect(
    handle: u64,
    conversation_id: String,
    effect_id: String,
    dispatch_token: String,
    dispatched_at: String,
) -> Result<Option<LoadedOutboxRecord>, ConversationV2Error> {
    let registry = v2_registry()
        .lock()
        .map_err(|_| ConversationV2Error::from("registry poisoned".to_string()))?;
    let repository = registry
        .get(&handle)
        .ok_or_else(|| ConversationV2Error::from("unknown conversation v2 handle".to_string()))?;
    let repository = repository
        .lock()
        .map_err(|_| ConversationV2Error::from("repository poisoned".to_string()))?;
    repository
        .claim_outbox_effect(
            conversation_id.as_str(),
            effect_id.as_str(),
            dispatch_token.as_str(),
            dispatched_at.as_str(),
        )
        .map_err(|error| ConversationV2Error::from(format!("{error:?}")))
}

#[uniffi::export]
pub fn conversation_v2_settle_outbox(
    handle: u64,
    conversation_id: String,
    item_id: String,
    dispatch_token: String,
    outcome: String,
    settled_at: String,
) -> Result<bool, ConversationV2Error> {
    let registry = v2_registry()
        .lock()
        .map_err(|_| ConversationV2Error::from("registry poisoned".to_string()))?;
    let repository = registry
        .get(&handle)
        .ok_or_else(|| ConversationV2Error::from("unknown conversation v2 handle".to_string()))?;
    let repository = repository
        .lock()
        .map_err(|_| ConversationV2Error::from("repository poisoned".to_string()))?;
    repository
        .settle_outbox(
            conversation_id.as_str(),
            item_id.as_str(),
            dispatch_token.as_str(),
            outcome.as_str(),
            settled_at.as_str(),
        )
        .map_err(|error| ConversationV2Error::from(format!("{error:?}")))
}

#[uniffi::export]
pub fn conversation_v2_require_outbox_reconciliation(
    handle: u64,
    conversation_id: String,
    item_id: String,
    reason: String,
) -> Result<bool, ConversationV2Error> {
    let registry = v2_registry()
        .lock()
        .map_err(|_| ConversationV2Error::from("registry poisoned".to_string()))?;
    let repository = registry
        .get(&handle)
        .ok_or_else(|| ConversationV2Error::from("unknown conversation v2 handle".to_string()))?;
    let repository = repository
        .lock()
        .map_err(|_| ConversationV2Error::from("repository poisoned".to_string()))?;
    repository
        .require_outbox_reconciliation(conversation_id.as_str(), item_id.as_str(), reason.as_str())
        .map_err(|error| ConversationV2Error::from(format!("{error:?}")))
}

// MARK: - Global execution admission

#[uniffi::export]
pub fn conversation_v2_admission_begin_generation(handle: u64) -> Result<i64, ConversationV2Error> {
    with_admission(handle, |store| store.begin_generation())
}

#[uniffi::export]
pub fn conversation_v2_admission_load_state(
    handle: u64,
) -> Result<AdmissionStateRecord, ConversationV2Error> {
    with_admission(handle, |store| store.load_state())
}

#[uniffi::export]
pub fn conversation_v2_admission_enqueue(
    handle: u64,
    request_id: String,
    conversation_id: String,
    turn_id: String,
    attempt_id: String,
    scheduler_generation: i64,
    now_seconds: f64,
) -> Result<AdmissionRequestRecord, ConversationV2Error> {
    with_admission(handle, |store| {
        store.enqueue_runtime(
            request_id.as_str(),
            conversation_id.as_str(),
            turn_id.as_str(),
            attempt_id.as_str(),
            scheduler_generation,
            now_seconds,
        )
    })
}

#[uniffi::export]
pub fn conversation_v2_admission_grant(
    handle: u64,
    request_id: String,
    attempt_id: String,
    scheduler_generation: i64,
    now_seconds: f64,
) -> Result<AdmissionLeaseRecord, ConversationV2Error> {
    with_admission(handle, |store| {
        store.grant_runtime(
            request_id.as_str(),
            attempt_id.as_str(),
            scheduler_generation,
            now_seconds,
        )
    })
}

#[uniffi::export]
pub fn conversation_v2_admission_activate(
    handle: u64,
    lease_id: String,
    scheduler_generation: i64,
) -> Result<(), ConversationV2Error> {
    with_admission(handle, |store| {
        store.transition_lease(lease_id.as_str(), "granted", "active", scheduler_generation)
    })
}

#[uniffi::export]
pub fn conversation_v2_admission_cancel_request(
    handle: u64,
    request_id: String,
    scheduler_generation: i64,
) -> Result<bool, ConversationV2Error> {
    with_admission(handle, |store| {
        store.cancel_request(request_id.as_str(), scheduler_generation)
    })
}

#[uniffi::export]
pub fn conversation_v2_admission_expire_request(
    handle: u64,
    request_id: String,
    scheduler_generation: i64,
) -> Result<bool, ConversationV2Error> {
    with_admission(handle, |store| {
        store.expire_request(request_id.as_str(), scheduler_generation)
    })
}

#[uniffi::export]
pub fn conversation_v2_admission_release(
    handle: u64,
    lease_id: String,
    scheduler_generation: i64,
    now_seconds: f64,
) -> Result<bool, ConversationV2Error> {
    with_admission(handle, |store| {
        store.release_runtime(lease_id.as_str(), scheduler_generation, now_seconds)
    })
}

// MARK: - 控制面 UniFFI 导出（P3-9：Swift V2Control 协调器接线）

fn control_registry() -> &'static Mutex<HashMap<u64, Arc<Mutex<control::ControlStore>>>> {
    static REGISTRY: OnceLock<Mutex<HashMap<u64, Arc<Mutex<control::ControlStore>>>>> =
        OnceLock::new();
    REGISTRY.get_or_init(|| Mutex::new(HashMap::new()))
}

fn with_control<F, T>(handle: u64, body: F) -> Result<T, ConversationV2Error>
where
    F: FnOnce(&control::ControlStore) -> Result<T, ConversationV2Error>,
{
    let registry = control_registry()
        .lock()
        .map_err(|_| ConversationV2Error::from("registry poisoned".to_string()))?;
    let store = registry
        .get(&handle)
        .ok_or_else(|| ConversationV2Error::from("unknown control handle".to_string()))?;
    let store = store
        .lock()
        .map_err(|_| ConversationV2Error::from("control store poisoned".to_string()))?;
    body(&store)
}

/// 打开（必要时创建）控制面独立库并返回会话句柄。
#[uniffi::export]
pub fn control_open(path: String) -> Result<u64, ConversationV2Error> {
    let db = control::ControlDb::open(&path)
        .map_err(|error| ConversationV2Error::from(error.to_string()))?;
    let store = control::ControlStore::new(&db);
    let registry = control_registry();
    let mut lock = registry
        .lock()
        .map_err(|_| ConversationV2Error::from("registry poisoned".to_string()))?;
    let mut handle = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_nanos() as u64)
        .unwrap_or(1);
    while lock.contains_key(&handle) {
        handle = handle.wrapping_add(1);
    }
    lock.insert(handle, Arc::new(Mutex::new(store)));
    Ok(handle)
}

/// 关闭控制面会话句柄。
#[uniffi::export]
pub fn control_close(handle: u64) {
    let _ = control_registry()
        .lock()
        .map(|mut registry| registry.remove(&handle));
}

/// 读取三态控制面状态（enabled/draining/disabled）。
#[uniffi::export]
pub fn control_state(handle: u64) -> Result<String, ConversationV2Error> {
    with_control(handle, |store| {
        store
            .control_state()
            .map_err(|error| ConversationV2Error::from(format!("{error:?}")))
    })
}

/// CAS 三态迁移；expected_generation 不匹配返回 StaleGeneration，同 transition_id 幂等。
#[uniffi::export]
pub fn control_transition(
    handle: u64,
    to: String,
    expected_generation: i64,
    transition_id: String,
) -> Result<(), ConversationV2Error> {
    with_control(handle, |store| {
        store
            .transition_control(&to, expected_generation, &transition_id)
            .map_err(|error| ConversationV2Error::from(format!("{error:?}")))
    })
}

/// draining 后无新 authorization（存量可完成）。
#[uniffi::export]
pub fn control_authorization_allowed(handle: u64) -> Result<bool, ConversationV2Error> {
    with_control(handle, |store| {
        store
            .authorization_allowed()
            .map_err(|error| ConversationV2Error::from(format!("{error:?}")))
    })
}

/// 签发 Permit 并冻结 target journal（完整 participant set）。
#[uniffi::export]
pub fn control_create_permit(
    handle: u64,
    permit_id: String,
    generation: i64,
    participants: Vec<String>,
) -> Result<(), ConversationV2Error> {
    with_control(handle, |store| {
        let participants: Vec<&str> = participants.iter().map(String::as_str).collect();
        store
            .create_permit(&permit_id, generation, participants)
            .map_err(|error| ConversationV2Error::from(format!("{error:?}")))
    })
}

#[uniffi::export]
pub fn control_permit_state(handle: u64, permit_id: String) -> Result<String, ConversationV2Error> {
    with_control(handle, |store| {
        store
            .permit_state(&permit_id)
            .map_err(|error| ConversationV2Error::from(format!("{error:?}")))
    })
}

#[uniffi::export]
pub fn control_prepare_permit(handle: u64, permit_id: String) -> Result<(), ConversationV2Error> {
    with_control(handle, |store| {
        store
            .prepare_permit(&permit_id)
            .map_err(|error| ConversationV2Error::from(format!("{error:?}")))
    })
}

#[uniffi::export]
pub fn control_authorize_permit_commit(
    handle: u64,
    permit_id: String,
) -> Result<(), ConversationV2Error> {
    with_control(handle, |store| {
        store
            .authorize_permit_commit(&permit_id)
            .map_err(|error| ConversationV2Error::from(format!("{error:?}")))
    })
}

/// 结算：settledCommitted（commitAuthorized 或全 journal committed）/settledAborted；settling 中间态可选。
#[uniffi::export]
pub fn control_settle_permit(
    handle: u64,
    permit_id: String,
    settlement: String,
    proof: String,
) -> Result<(), ConversationV2Error> {
    with_control(handle, |store| {
        store
            .settle_permit(&permit_id, &settlement, &proof)
            .map_err(|error| ConversationV2Error::from(format!("{error:?}")))
    })
}

/// expiry：未 prepared 只允许 no-target proof；prepared 必须 abort decision。
#[uniffi::export]
pub fn control_expire_permit(
    handle: u64,
    permit_id: String,
    with_target_proof: bool,
) -> Result<(), ConversationV2Error> {
    with_control(handle, |store| {
        store
            .expire_permit(&permit_id, with_target_proof)
            .map_err(|error| ConversationV2Error::from(format!("{error:?}")))
    })
}

/// 冻结的 participant set（签发顺序）。
#[uniffi::export]
pub fn control_journal_participants(
    handle: u64,
    permit_id: String,
) -> Result<Vec<String>, ConversationV2Error> {
    with_control(handle, |store| {
        store
            .journal_participants(&permit_id)
            .map_err(|error| ConversationV2Error::from(format!("{error:?}")))
    })
}

#[uniffi::export]
pub fn control_mark_journal(
    handle: u64,
    permit_id: String,
    participant: String,
    state: String,
) -> Result<(), ConversationV2Error> {
    with_control(handle, |store| {
        store
            .mark_journal(&permit_id, &participant, &state)
            .map_err(|error| ConversationV2Error::from(format!("{error:?}")))
    })
}

// MARK: - External Effect reconciliation UniFFI 导出（P3-9）

fn reconciliation_registry(
) -> &'static Mutex<HashMap<u64, Arc<Mutex<reconciliation::ReconciliationStore>>>> {
    static REGISTRY: OnceLock<
        Mutex<HashMap<u64, Arc<Mutex<reconciliation::ReconciliationStore>>>>,
    > = OnceLock::new();
    REGISTRY.get_or_init(|| Mutex::new(HashMap::new()))
}

fn with_reconciliation<F, T>(handle: u64, body: F) -> Result<T, ConversationV2Error>
where
    F: FnOnce(&reconciliation::ReconciliationStore) -> Result<T, ConversationV2Error>,
{
    let registry = reconciliation_registry()
        .lock()
        .map_err(|_| ConversationV2Error::from("registry poisoned".to_string()))?;
    let store = registry
        .get(&handle)
        .ok_or_else(|| ConversationV2Error::from("unknown reconciliation handle".to_string()))?;
    let store = store
        .lock()
        .map_err(|_| ConversationV2Error::from("reconciliation store poisoned".to_string()))?;
    body(&store)
}

/// 打开（必要时创建）reconciliation 独立库并返回会话句柄。
#[uniffi::export]
pub fn reconciliation_open(path: String) -> Result<u64, ConversationV2Error> {
    let db = reconciliation::ReconciliationDb::open(&path)
        .map_err(|error| ConversationV2Error::from(error.to_string()))?;
    let store = reconciliation::ReconciliationStore::new(&db);
    let registry = reconciliation_registry();
    let mut lock = registry
        .lock()
        .map_err(|_| ConversationV2Error::from("registry poisoned".to_string()))?;
    let mut handle = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_nanos() as u64)
        .unwrap_or(1);
    while lock.contains_key(&handle) {
        handle = handle.wrapping_add(1);
    }
    lock.insert(handle, Arc::new(Mutex::new(store)));
    Ok(handle)
}

/// 关闭 reconciliation 会话句柄。
#[uniffi::export]
pub fn reconciliation_close(handle: u64) {
    let _ = reconciliation_registry()
        .lock()
        .map(|mut registry| registry.remove(&handle));
}

/// 稳定 conflictKey 组合（target digest + resource scope + operation class）。
#[uniffi::export]
pub fn reconciliation_conflict_key(
    target_digest: String,
    resource_scope: String,
    operation_class: String,
) -> String {
    reconciliation::ReconciliationStore::conflict_key(
        &target_digest,
        &resource_scope,
        &operation_class,
    )
}

#[uniffi::export]
pub fn reconciliation_create_record(
    handle: u64,
    effect_id: String,
    conflict_key: String,
    state: String,
) -> Result<(), ConversationV2Error> {
    with_reconciliation(handle, |store| {
        store
            .create_record(&effect_id, &conflict_key, &state)
            .map_err(|error| ConversationV2Error::from(format!("{error:?}")))
    })
}

#[uniffi::export]
pub fn reconciliation_create_record_with_strength(
    handle: u64,
    effect_id: String,
    conflict_key: String,
    state: String,
    evidence_strength: String,
) -> Result<(), ConversationV2Error> {
    with_reconciliation(handle, |store| {
        store
            .create_record_with_strength(&effect_id, &conflict_key, &state, &evidence_strength)
            .map_err(|error| ConversationV2Error::from(format!("{error:?}")))
    })
}

/// 同 key 全记录终结前锁不释放。
#[uniffi::export]
pub fn reconciliation_lock_released(
    handle: u64,
    conflict_key: String,
) -> Result<bool, ConversationV2Error> {
    with_reconciliation(handle, |store| {
        store
            .lock_released(&conflict_key)
            .map_err(|error| ConversationV2Error::from(format!("{error:?}")))
    })
}

#[uniffi::export]
pub fn reconciliation_lock_owner(
    handle: u64,
    conflict_key: String,
) -> Result<String, ConversationV2Error> {
    with_reconciliation(handle, |store| {
        store
            .lock_owner(&conflict_key)
            .map_err(|error| ConversationV2Error::from(format!("{error:?}")))
    })
}

/// unknown 远端 effect 锁不占全局 Admission。
#[uniffi::export]
pub fn reconciliation_holds_global_admission(
    handle: u64,
    conflict_key: String,
) -> Result<bool, ConversationV2Error> {
    with_reconciliation(handle, |store| {
        store
            .holds_global_admission(&conflict_key)
            .map_err(|error| ConversationV2Error::from(format!("{error:?}")))
    })
}

#[uniffi::export]
pub fn reconciliation_evidence_strength(
    handle: u64,
    effect_id: String,
) -> Result<String, ConversationV2Error> {
    with_reconciliation(handle, |store| {
        store
            .evidence_strength(&effect_id)
            .map_err(|error| ConversationV2Error::from(format!("{error:?}")))
    })
}

/// 结算记录：弱证据不得结算 verifiedCompleted。
#[uniffi::export]
pub fn reconciliation_settle_record(
    handle: u64,
    effect_id: String,
    settlement: String,
) -> Result<(), ConversationV2Error> {
    with_reconciliation(handle, |store| {
        store
            .settle_record(&effect_id, &settlement)
            .map_err(|error| ConversationV2Error::from(format!("{error:?}")))
    })
}

// MARK: - AssistantSettingsStore UniFFI 导出（P3-11：独立设置域存储）

/// setting 值快照（revision + typed value digest；不暴露 secret/prompt/路径正文）。
#[derive(uniffi::Record)]
pub struct SettingValueSnapshot {
    pub revision: i64,
    pub value_digest: String,
}

#[derive(uniffi::Record)]
pub struct SettingMetadataSnapshot {
    pub revision: i64,
    pub value_digest: String,
    pub scope: String,
    pub migration_key: String,
}

fn settings_registry() -> &'static Mutex<HashMap<u64, Arc<Mutex<settings::SettingsStore>>>> {
    static REGISTRY: OnceLock<Mutex<HashMap<u64, Arc<Mutex<settings::SettingsStore>>>>> =
        OnceLock::new();
    REGISTRY.get_or_init(|| Mutex::new(HashMap::new()))
}

fn with_settings<F, T>(handle: u64, body: F) -> Result<T, ConversationV2Error>
where
    F: FnOnce(&settings::SettingsStore) -> Result<T, ConversationV2Error>,
{
    let registry = settings_registry()
        .lock()
        .map_err(|_| ConversationV2Error::from("registry poisoned".to_string()))?;
    let store = registry
        .get(&handle)
        .ok_or_else(|| ConversationV2Error::from("unknown settings handle".to_string()))?;
    let store = store
        .lock()
        .map_err(|_| ConversationV2Error::from("settings store poisoned".to_string()))?;
    body(&store)
}

/// 打开（必要时创建）设置域独立库并返回会话句柄。
#[uniffi::export]
pub fn settings_open(path: String) -> Result<u64, ConversationV2Error> {
    let db = settings::SettingsDb::open(&path)
        .map_err(|error| ConversationV2Error::from(error.to_string()))?;
    let store = settings::SettingsStore::new(&db);
    let registry = settings_registry();
    let mut lock = registry
        .lock()
        .map_err(|_| ConversationV2Error::from("registry poisoned".to_string()))?;
    let mut handle = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_nanos() as u64)
        .unwrap_or(1);
    while lock.contains_key(&handle) {
        handle = handle.wrapping_add(1);
    }
    lock.insert(handle, Arc::new(Mutex::new(store)));
    Ok(handle)
}

/// 关闭设置域会话句柄。
#[uniffi::export]
pub fn settings_close(handle: u64) {
    let _ = settings_registry()
        .lock()
        .map(|mut registry| registry.remove(&handle));
}

/// expected-revision CAS 写入 setting 值。
#[uniffi::export]
pub fn settings_upsert(
    handle: u64,
    key: String,
    expected_revision: Option<i64>,
    value_digest: String,
    scope: String,
    migration_key: String,
) -> Result<(), ConversationV2Error> {
    with_settings(handle, |store| {
        store
            .upsert_setting(
                &key,
                expected_revision,
                &value_digest,
                &scope,
                &migration_key,
            )
            .map_err(|error| ConversationV2Error::from(format!("{error:?}")))
    })
}

/// 读取 setting 值（revision + digest）。
#[uniffi::export]
pub fn settings_value(
    handle: u64,
    key: String,
) -> Result<Option<SettingValueSnapshot>, ConversationV2Error> {
    with_settings(handle, |store| {
        store
            .setting_value(&key)
            .map(|value| {
                value.map(|(revision, value_digest)| SettingValueSnapshot {
                    revision,
                    value_digest,
                })
            })
            .map_err(|error| ConversationV2Error::from(format!("{error:?}")))
    })
}

/// 读取 setting 元数据（scope/migrationKey）。
#[uniffi::export]
pub fn settings_metadata(
    handle: u64,
    key: String,
) -> Result<Option<SettingMetadataSnapshot>, ConversationV2Error> {
    with_settings(handle, |store| {
        store
            .setting_metadata(&key)
            .map(|meta| {
                meta.map(|m| SettingMetadataSnapshot {
                    revision: m.revision,
                    value_digest: m.value_digest,
                    scope: m.scope,
                    migration_key: m.migration_key,
                })
            })
            .map_err(|error| ConversationV2Error::from(format!("{error:?}")))
    })
}

/// 列出已提交 setting key（不暴露值正文）。
#[uniffi::export]
pub fn settings_keys(handle: u64) -> Result<Vec<String>, ConversationV2Error> {
    with_settings(handle, |store| {
        store
            .setting_keys()
            .map_err(|error| ConversationV2Error::from(format!("{error:?}")))
    })
}

/// 追加 assistant_settings_event（关闭 kind 集合 + settled 前置证据 + 幂等）。
#[uniffi::export]
pub fn settings_append_event(
    handle: u64,
    event_id: String,
    operation_id: String,
    kind: String,
) -> Result<i64, ConversationV2Error> {
    with_settings(handle, |store| {
        store
            .append_event(&event_id, &operation_id, &kind)
            .map_err(|error| ConversationV2Error::from(format!("{error:?}")))
    })
}

/// 当前 durable sequence 的下一个值。
#[uniffi::export]
pub fn settings_next_sequence(handle: u64) -> Result<i64, ConversationV2Error> {
    with_settings(handle, |store| {
        store
            .next_sequence()
            .map_err(|error| ConversationV2Error::from(format!("{error:?}")))
    })
}

/// operation-scoped audit（按 sequence 排序）。
#[uniffi::export]
pub fn settings_events(
    handle: u64,
    operation_id: String,
) -> Result<Vec<String>, ConversationV2Error> {
    with_settings(handle, |store| {
        store
            .events(&operation_id)
            .map_err(|error| ConversationV2Error::from(format!("{error:?}")))
    })
}

// MARK: - Configuration Store UniFFI 导出（P3-12：独立 Configuration Store）

#[derive(uniffi::Record)]
pub struct ConfigurationSnapshotRecord {
    pub revision: i64,
    pub value_digest: String,
    pub state: String,
    pub credential_reference: String,
}

fn configuration_registry(
) -> &'static Mutex<HashMap<u64, Arc<Mutex<configuration_store::ConfigurationStore>>>> {
    static REGISTRY: OnceLock<
        Mutex<HashMap<u64, Arc<Mutex<configuration_store::ConfigurationStore>>>>,
    > = OnceLock::new();
    REGISTRY.get_or_init(|| Mutex::new(HashMap::new()))
}

fn with_configuration<F, T>(handle: u64, body: F) -> Result<T, ConversationV2Error>
where
    F: FnOnce(&configuration_store::ConfigurationStore) -> Result<T, ConversationV2Error>,
{
    let registry = configuration_registry()
        .lock()
        .map_err(|_| ConversationV2Error::from("registry poisoned".to_string()))?;
    let store = registry
        .get(&handle)
        .ok_or_else(|| ConversationV2Error::from("unknown configuration handle".to_string()))?;
    let store = store
        .lock()
        .map_err(|_| ConversationV2Error::from("configuration store poisoned".to_string()))?;
    body(&store)
}

/// 打开（必要时创建）Configuration Store 独立库并返回会话句柄。
#[uniffi::export]
pub fn configuration_open(path: String) -> Result<u64, ConversationV2Error> {
    let db = configuration_store::ConfigurationDb::open(&path)
        .map_err(|error| ConversationV2Error::from(error.to_string()))?;
    let store = configuration_store::ConfigurationStore::new(&db);
    let registry = configuration_registry();
    let mut lock = registry
        .lock()
        .map_err(|_| ConversationV2Error::from("registry poisoned".to_string()))?;
    let mut handle = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_nanos() as u64)
        .unwrap_or(1);
    while lock.contains_key(&handle) {
        handle = handle.wrapping_add(1);
    }
    lock.insert(handle, Arc::new(Mutex::new(store)));
    Ok(handle)
}

/// 关闭 Configuration Store 会话句柄。
#[uniffi::export]
pub fn configuration_close(handle: u64) {
    let _ = configuration_registry()
        .lock()
        .map(|mut registry| registry.remove(&handle));
}

/// revision CAS 写入 configuration（credential 只存引用）。
#[uniffi::export]
pub fn configuration_upsert(
    handle: u64,
    configuration_id: String,
    expected_revision: Option<i64>,
    value_digest: String,
    credential_reference: String,
) -> Result<(), ConversationV2Error> {
    with_configuration(handle, |store| {
        store
            .upsert_configuration(
                &configuration_id,
                expected_revision,
                &value_digest,
                &credential_reference,
            )
            .map_err(|error| ConversationV2Error::from(format!("{error:?}")))
    })
}

/// 单事务提交已验证 configuration 并发布 active 状态与审计证据。
#[uniffi::export]
pub fn configuration_commit_verified(
    handle: u64,
    configuration_id: String,
    expected_revision: Option<i64>,
    value_digest: String,
    credential_reference: String,
    operation_id: String,
    event_id: String,
) -> Result<i64, ConversationV2Error> {
    with_configuration(handle, |store| {
        store
            .commit_verified_configuration(
                &configuration_id,
                expected_revision,
                &value_digest,
                &credential_reference,
                &operation_id,
                &event_id,
            )
            .map_err(|error| ConversationV2Error::from(format!("{error:?}")))
    })
}

/// revision CAS 删除 configuration，并在同一事务写入终态与审计证据。
#[uniffi::export]
pub fn configuration_delete(
    handle: u64,
    configuration_id: String,
    expected_revision: i64,
    tombstone_digest: String,
    operation_id: String,
    event_id: String,
) -> Result<i64, ConversationV2Error> {
    with_configuration(handle, |store| {
        store
            .delete_configuration(
                &configuration_id,
                expected_revision,
                &tombstone_digest,
                &operation_id,
                &event_id,
            )
            .map_err(|error| ConversationV2Error::from(format!("{error:?}")))
    })
}

/// 读取 configuration 快照。
#[uniffi::export]
pub fn configuration_snapshot(
    handle: u64,
    configuration_id: String,
) -> Result<Option<ConfigurationSnapshotRecord>, ConversationV2Error> {
    with_configuration(handle, |store| {
        store
            .configuration(&configuration_id)
            .map(|config| {
                config.map(|c| ConfigurationSnapshotRecord {
                    revision: c.revision,
                    value_digest: c.value_digest,
                    state: c.state,
                    credential_reference: c.credential_reference,
                })
            })
            .map_err(|error| ConversationV2Error::from(format!("{error:?}")))
    })
}

/// 关闭状态机转换（draft→prepared→dispatched→activating→active；任意→deleted）。
#[uniffi::export]
pub fn configuration_transition_state(
    handle: u64,
    configuration_id: String,
    to: String,
) -> Result<(), ConversationV2Error> {
    with_configuration(handle, |store| {
        store
            .transition_state(&configuration_id, &to)
            .map_err(|error| ConversationV2Error::from(format!("{error:?}")))
    })
}

/// 追加 runtime_configuration_event（关闭 kind 集合 + 幂等），返回 durable sequence。
#[uniffi::export]
pub fn configuration_append_event(
    handle: u64,
    event_id: String,
    configuration_id: String,
    operation_id: String,
    kind: String,
) -> Result<i64, ConversationV2Error> {
    with_configuration(handle, |store| {
        store
            .append_event(&event_id, &configuration_id, &operation_id, &kind)
            .map_err(|error| ConversationV2Error::from(format!("{error:?}")))
    })
}

/// configuration-scoped audit（按 sequence 排序）。
#[uniffi::export]
pub fn configuration_events(
    handle: u64,
    configuration_id: String,
) -> Result<Vec<String>, ConversationV2Error> {
    with_configuration(handle, |store| {
        store
            .events(&configuration_id)
            .map_err(|error| ConversationV2Error::from(format!("{error:?}")))
    })
}

/// operation-scoped 关联查询（跨域关联由投影层合并 settings 域事件）。
#[uniffi::export]
pub fn configuration_events_by_operation(
    handle: u64,
    operation_id: String,
) -> Result<Vec<String>, ConversationV2Error> {
    with_configuration(handle, |store| {
        store
            .events_by_operation(&operation_id)
            .map_err(|error| ConversationV2Error::from(format!("{error:?}")))
    })
}
