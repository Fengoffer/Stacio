//! CredentialGeneration/Lifecycle 状态机与删除/孤儿 saga（独立存储域，规格 §15.1）。
//!
//! 存储域边界：本模块使用独立 DB 文件（`credential-lifecycle.sqlite3`），
//! 不放入 `agent-conversations-v2.sqlite3`；会话库只保存不可变引用与投影，
//! 清空会话后本 Store 仍独立存在。secret 正文绝不入库（仅 keychain 引用）。

use rusqlite::{params, Connection};
use std::sync::{Arc, Mutex, OnceLock};

const LIFECYCLE_INIT_SQL: &str =
    include_str!("../../../migrations/credential_lifecycle_0001_init.sql");

// MARK: - 状态

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GenerationLifecycleState {
    PendingActivation,
    Active,
    Retired,
    Revoked,
    Abandoned,
}

impl GenerationLifecycleState {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::PendingActivation => "pendingActivation",
            Self::Active => "active",
            Self::Retired => "retired",
            Self::Revoked => "revoked",
            Self::Abandoned => "abandoned",
        }
    }

    pub fn from_str(value: &str) -> Option<Self> {
        match value {
            "pendingActivation" => Some(Self::PendingActivation),
            "active" => Some(Self::Active),
            "retired" => Some(Self::Retired),
            "revoked" => Some(Self::Revoked),
            "abandoned" => Some(Self::Abandoned),
            _ => None,
        }
    }

    pub fn is_terminal(&self) -> bool {
        matches!(self, Self::Abandoned | Self::Revoked)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SecretAvailability {
    Present,
    PendingDeletion,
    Deleted,
}

impl SecretAvailability {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Present => "present",
            Self::PendingDeletion => "pendingDeletion",
            Self::Deleted => "deleted",
        }
    }

    pub fn from_str(value: &str) -> Option<Self> {
        match value {
            "present" => Some(Self::Present),
            "pendingDeletion" => Some(Self::PendingDeletion),
            "deleted" => Some(Self::Deleted),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DeletionOperationState {
    Requested,
    BlockedByUse,
    Deleting,
    Completed,
    Failed,
}

impl DeletionOperationState {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Requested => "requested",
            Self::BlockedByUse => "blockedByUse",
            Self::Deleting => "deleting",
            Self::Completed => "completed",
            Self::Failed => "failed",
        }
    }
}

// MARK: - 记录

#[derive(Debug, Clone)]
pub struct GenerationRecord {
    pub id: String,
    pub configuration_id: String,
    pub generation: i64,
    pub lifecycle_state: GenerationLifecycleState,
    pub secret_availability: SecretAvailability,
    pub keychain_reference: String,
    pub active_attempt_ref_count: i64,
}

#[derive(Debug, Clone)]
pub struct DeletionOperationRecord {
    pub id: String,
    pub generation_id: String,
    pub state: DeletionOperationState,
    pub deletion_fence: i64,
}

#[derive(Debug, Clone)]
pub struct OrphanRecord {
    pub id: String,
    pub keychain_item_id: String,
    pub state: String,
    pub secret: Option<Vec<u8>>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReconciliationCounts {
    pub generations: i64,
    pub keychain_items: i64,
    pub pending_generations: i64,
    pub active_generations: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CredentialLifecycleError {
    InvalidTransition { from: String, to: String },
    NotFound { id: String },
    InvalidSettlement { reason: String },
    Storage(String),
}

// MARK: - Db / Store

pub struct CredentialLifecycleDb {
    connection: Arc<Mutex<Connection>>,
 #[allow(dead_code)] //保留数据库路径，供诊断与未来排查使用
    path: String,
}

impl CredentialLifecycleDb {
    pub fn open(path: &str) -> rusqlite::Result<Self> {
        let connection = Connection::open(path)?;
        let db = Self {
            connection: Arc::new(Mutex::new(connection)),
            path: path.to_string(),
        };
        db.apply_migrations()?;
        Ok(db)
    }

    pub fn open_in_memory() -> rusqlite::Result<Self> {
        let connection = Connection::open_in_memory()?;
        let db = Self {
            connection: Arc::new(Mutex::new(connection)),
            path: ":memory:".to_string(),
        };
        db.apply_migrations()?;
        Ok(db)
    }

    pub fn connection(&self) -> std::sync::MutexGuard<'_, Connection> {
        self.connection.lock().expect("lifecycle db poisoned")
    }

    pub fn connection_arc(&self) -> Arc<Mutex<Connection>> {
        Arc::clone(&self.connection)
    }

    fn apply_migrations(&self) -> rusqlite::Result<()> {
        self.connection().execute_batch(LIFECYCLE_INIT_SQL)
    }
}

fn generation_sequence() -> &'static Mutex<i64> {
    static SEQUENCE: OnceLock<Mutex<i64>> = OnceLock::new();
    SEQUENCE.get_or_init(|| Mutex::new(0))
}

fn next_generation_id() -> String {
    let mut sequence = generation_sequence().lock().expect("sequence poisoned");
    *sequence += 1;
    format!("gen-{}", *sequence)
}

fn next_operation_id() -> String {
    let mut sequence = generation_sequence().lock().expect("sequence poisoned");
    *sequence += 1;
    format!("op-{}", *sequence)
}

fn next_orphan_id() -> String {
    let mut sequence = generation_sequence().lock().expect("sequence poisoned");
    *sequence += 1;
    format!("orphan-{}", *sequence)
}

pub struct CredentialLifecycleStore {
    connection: Arc<Mutex<Connection>>,
}

impl CredentialLifecycleStore {
    pub fn new(db: &CredentialLifecycleDb) -> Self {
        Self {
            connection: db.connection_arc(),
        }
    }

    // MARK: generation 状态机

    pub fn create_generation(
        &self,
        configuration_id: &str,
        generation: i64,
        keychain_reference: &str,
    ) -> Result<GenerationRecord, CredentialLifecycleError> {
        let id = next_generation_id();
        let connection = self.connection.lock().expect("lifecycle db poisoned");
        connection
            .execute(
                "INSERT INTO credential_generation
                   (generation_id, configuration_id, generation, lifecycle_state, secret_availability, keychain_reference, created_at)
                 VALUES (?1, ?2, ?3, 'pendingActivation', 'present', ?4, 't')",
                params![id, configuration_id, generation, keychain_reference],
            )
            .map_err(|error| CredentialLifecycleError::Storage(error.to_string()))?;
        Ok(GenerationRecord {
            id,
            configuration_id: configuration_id.to_string(),
            generation,
            lifecycle_state: GenerationLifecycleState::PendingActivation,
            secret_availability: SecretAvailability::Present,
            keychain_reference: keychain_reference.to_string(),
            active_attempt_ref_count: 0,
        })
    }

    pub fn transition_generation(
        &self,
        generation_id: &str,
        to: GenerationLifecycleState,
    ) -> Result<(), CredentialLifecycleError> {
        let connection = self.connection.lock().expect("lifecycle db poisoned");
        let current = self.read_state_locked(&connection, generation_id)?;
        // 删除进行中（secretAvailability = pendingDeletion）：不得复活（拒绝激活/退役类转换）
        let availability: String = connection
            .query_row(
                "SELECT secret_availability FROM credential_generation WHERE generation_id = ?1",
                params![generation_id],
                |row| row.get(0),
            )
            .map_err(|error| CredentialLifecycleError::Storage(error.to_string()))?;
        if availability == "pendingDeletion" && !matches!(to, GenerationLifecycleState::Revoked) {
            return Err(CredentialLifecycleError::InvalidTransition {
                from: current.as_str().to_string(),
                to: to.as_str().to_string(),
            });
        }
        // 关闭转换表
        let allowed = match (&current, &to) {
            (GenerationLifecycleState::PendingActivation, GenerationLifecycleState::Active)
            | (GenerationLifecycleState::PendingActivation, GenerationLifecycleState::Abandoned)
            | (GenerationLifecycleState::PendingActivation, GenerationLifecycleState::Revoked)
            | (GenerationLifecycleState::Active, GenerationLifecycleState::Retired)
            | (GenerationLifecycleState::Active, GenerationLifecycleState::Revoked)
            | (GenerationLifecycleState::Retired, GenerationLifecycleState::Revoked) => true,
            _ => false,
        };
        if !allowed {
            return Err(CredentialLifecycleError::InvalidTransition {
                from: current.as_str().to_string(),
                to: to.as_str().to_string(),
            });
        }
        connection
            .execute(
                "UPDATE credential_generation SET lifecycle_state = ?1, retired_at = CASE WHEN ?1 = 'retired' OR ?1 = 'revoked' THEN 't' ELSE retired_at END WHERE generation_id = ?2",
                params![to.as_str(), generation_id],
            )
            .map_err(|error| CredentialLifecycleError::Storage(error.to_string()))?;
        Ok(())
    }

    pub fn activate_generation(&self, generation_id: &str) -> Result<(), CredentialLifecycleError> {
        self.transition_generation(generation_id, GenerationLifecycleState::Active)
    }

    pub fn retire_generation(&self, generation_id: &str) -> Result<(), CredentialLifecycleError> {
        self.transition_generation(generation_id, GenerationLifecycleState::Retired)
    }

    pub fn revoke_generation(&self, generation_id: &str) -> Result<(), CredentialLifecycleError> {
        self.transition_generation(generation_id, GenerationLifecycleState::Revoked)
    }

    pub fn abandon_generation(&self, generation_id: &str) -> Result<(), CredentialLifecycleError> {
        self.transition_generation(generation_id, GenerationLifecycleState::Abandoned)
    }

    pub fn generation_state(
        &self,
        generation_id: &str,
    ) -> Result<GenerationLifecycleState, CredentialLifecycleError> {
        let connection = self.connection.lock().expect("lifecycle db poisoned");
        self.read_state_locked(&connection, generation_id)
    }

    pub fn secret_availability(
        &self,
        generation_id: &str,
    ) -> Result<SecretAvailability, CredentialLifecycleError> {
        let connection = self.connection.lock().expect("lifecycle db poisoned");
        connection
            .query_row(
                "SELECT secret_availability FROM credential_generation WHERE generation_id = ?1",
                params![generation_id],
                |row| row.get::<_, String>(0),
            )
            .map_err(|_| CredentialLifecycleError::NotFound {
                id: generation_id.to_string(),
            })?
            .parse_availability()
            .ok_or_else(|| CredentialLifecycleError::Storage("unknown availability".to_string()))
    }

    // MARK: 删除 saga

    pub fn begin_deletion(
        &self,
        generation_id: &str,
    ) -> Result<DeletionOperationRecord, CredentialLifecycleError> {
        let connection = self.connection.lock().expect("lifecycle db poisoned");
        let current_fence: i64 = connection
            .query_row(
                "SELECT COALESCE(MAX(deletion_fence), 0) FROM credential_deletion_operation WHERE generation_id = ?1",
                params![generation_id],
                |row| row.get(0),
            )
            .map_err(|error| CredentialLifecycleError::Storage(error.to_string()))?;
        let fence = current_fence + 1;
        let id = next_operation_id();
        connection
            .execute(
                "INSERT INTO credential_deletion_operation (operation_id, generation_id, state, deletion_fence, requested_at)
                 VALUES (?1, ?2, 'requested', ?3, 't')",
                params![id, generation_id, fence],
            )
            .map_err(|error| CredentialLifecycleError::Storage(error.to_string()))?;
        connection
            .execute(
                "UPDATE credential_generation SET secret_availability = 'pendingDeletion' WHERE generation_id = ?1",
                params![generation_id],
            )
            .map_err(|error| CredentialLifecycleError::Storage(error.to_string()))?;
        Ok(DeletionOperationRecord {
            id,
            generation_id: generation_id.to_string(),
            state: DeletionOperationState::Requested,
            deletion_fence: fence,
        })
    }

    pub fn transition_operation(
        &self,
        operation_id: &str,
        to: DeletionOperationState,
        failure_reason: Option<&str>,
    ) -> Result<(), CredentialLifecycleError> {
        let connection = self.connection.lock().expect("lifecycle db poisoned");
        let (current, generation_id): (String, String) = connection
            .query_row(
                "SELECT state, generation_id FROM credential_deletion_operation WHERE operation_id = ?1",
                params![operation_id],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .map_err(|_| CredentialLifecycleError::NotFound {
                id: operation_id.to_string(),
            })?;
        let allowed = match (current.as_str(), to.as_str()) {
            ("requested", "blockedByUse")
            | ("requested", "deleting")
            | ("requested", "failed")
            | ("blockedByUse", "deleting")
            | ("blockedByUse", "failed")
            | ("deleting", "completed")
            | ("deleting", "failed") => true,
            _ => false,
        };
        if !allowed {
            return Err(CredentialLifecycleError::InvalidTransition {
                from: current,
                to: to.as_str().to_string(),
            });
        }
        connection
            .execute(
                "UPDATE credential_deletion_operation
                 SET state = ?1, completed_at = CASE WHEN ?1 = 'completed' OR ?1 = 'failed' THEN 't' ELSE completed_at END,
                     failure_reason = ?2
                 WHERE operation_id = ?3",
                params![to.as_str(), failure_reason, operation_id],
            )
            .map_err(|error| CredentialLifecycleError::Storage(error.to_string()))?;
        // completed → secret deleted；failed → 保持 pendingDeletion（不复活）
        if to == DeletionOperationState::Completed {
            connection
                .execute(
                    "UPDATE credential_generation SET secret_availability = 'deleted' WHERE generation_id = ?1",
                    params![generation_id],
                )
                .map_err(|error| CredentialLifecycleError::Storage(error.to_string()))?;
        }
        Ok(())
    }

    pub fn block_deletion_by_use(
        &self,
        operation_id: &str,
    ) -> Result<(), CredentialLifecycleError> {
        self.transition_operation(operation_id, DeletionOperationState::BlockedByUse, None)
    }

    pub fn mark_deleting(&self, operation_id: &str) -> Result<(), CredentialLifecycleError> {
        self.transition_operation(operation_id, DeletionOperationState::Deleting, None)
    }

    pub fn complete_deletion(&self, operation_id: &str) -> Result<(), CredentialLifecycleError> {
        self.transition_operation(operation_id, DeletionOperationState::Completed, None)
    }

    pub fn fail_deletion(
        &self,
        operation_id: &str,
        reason: &str,
    ) -> Result<(), CredentialLifecycleError> {
        self.transition_operation(operation_id, DeletionOperationState::Failed, Some(reason))
    }

    pub fn operation_state(
        &self,
        operation_id: &str,
    ) -> Result<DeletionOperationState, CredentialLifecycleError> {
        let connection = self.connection.lock().expect("lifecycle db poisoned");
        connection
            .query_row(
                "SELECT state FROM credential_deletion_operation WHERE operation_id = ?1",
                params![operation_id],
                |row| row.get::<_, String>(0),
            )
            .map_err(|_| CredentialLifecycleError::NotFound {
                id: operation_id.to_string(),
            })?
            .parse_operation()
            .ok_or_else(|| CredentialLifecycleError::Storage("unknown operation state".to_string()))
    }

    // MARK: orphan

    pub fn detect_orphan(
        &self,
        keychain_item_id: &str,
    ) -> Result<OrphanRecord, CredentialLifecycleError> {
        let id = next_orphan_id();
        let connection = self.connection.lock().expect("lifecycle db poisoned");
        connection
            .execute(
                "INSERT INTO credential_orphan (orphan_id, keychain_item_id, state, created_at)
                 VALUES (?1, ?2, 'detected', 't')",
                params![id, keychain_item_id],
            )
            .map_err(|error| CredentialLifecycleError::Storage(error.to_string()))?;
        Ok(OrphanRecord {
            id,
            keychain_item_id: keychain_item_id.to_string(),
            state: "detected".to_string(),
            secret: None,
        })
    }

    pub fn quarantine_orphan(&self, orphan_id: &str) -> Result<(), CredentialLifecycleError> {
        self.transition_orphan(orphan_id, "quarantined")
    }

    /// 孤儿结算：只允许 deleted|manualReview；不自动挂接相似配置（auto_attach 拒绝）。
    pub fn settle_orphan(
        &self,
        orphan_id: &str,
        resolution: &str,
    ) -> Result<(), CredentialLifecycleError> {
        match resolution {
            "deleted" | "manualReview" => self.transition_orphan(orphan_id, resolution),
            _ => Err(CredentialLifecycleError::InvalidSettlement {
                reason: "orphan 不允许自动挂接/回填 active".to_string(),
            }),
        }
    }

    pub fn orphan_state(&self, orphan_id: &str) -> Result<String, CredentialLifecycleError> {
        let connection = self.connection.lock().expect("lifecycle db poisoned");
        connection
            .query_row(
                "SELECT state FROM credential_orphan WHERE orphan_id = ?1",
                params![orphan_id],
                |row| row.get(0),
            )
            .map_err(|_| CredentialLifecycleError::NotFound {
                id: orphan_id.to_string(),
            })
    }

    pub fn orphan_record(&self, orphan_id: &str) -> Result<OrphanRecord, CredentialLifecycleError> {
        let connection = self.connection.lock().expect("lifecycle db poisoned");
        connection
            .query_row(
                "SELECT orphan_id, keychain_item_id, state, secret FROM credential_orphan WHERE orphan_id = ?1",
                params![orphan_id],
                |row| {
                    Ok(OrphanRecord {
                        id: row.get(0)?,
                        keychain_item_id: row.get(1)?,
                        state: row.get(2)?,
                        secret: row.get(3)?,
                    })
                },
            )
            .map_err(|_| CredentialLifecycleError::NotFound {
                id: orphan_id.to_string(),
            })
    }

    fn transition_orphan(&self, orphan_id: &str, to: &str) -> Result<(), CredentialLifecycleError> {
        let connection = self.connection.lock().expect("lifecycle db poisoned");
        let current: String = connection
            .query_row(
                "SELECT state FROM credential_orphan WHERE orphan_id = ?1",
                params![orphan_id],
                |row| row.get(0),
            )
            .map_err(|_| CredentialLifecycleError::NotFound {
                id: orphan_id.to_string(),
            })?;
        let allowed = match (current.as_str(), to) {
            ("detected", "quarantined")
            | ("quarantined", "deleted")
            | ("quarantined", "manualReview") => true,
            _ => false,
        };
        if !allowed {
            return Err(CredentialLifecycleError::InvalidTransition {
                from: current,
                to: to.to_string(),
            });
        }
        connection
            .execute(
                "UPDATE credential_orphan SET state = ?1 WHERE orphan_id = ?2",
                params![to, orphan_id],
            )
            .map_err(|error| CredentialLifecycleError::Storage(error.to_string()))?;
        Ok(())
    }

    // MARK: 对账基数

    pub fn reconciliation_counts(&self) -> Result<ReconciliationCounts, CredentialLifecycleError> {
        let connection = self.connection.lock().expect("lifecycle db poisoned");
        let generations: i64 = connection
            .query_row("SELECT COUNT(*) FROM credential_generation", [], |row| {
                row.get(0)
            })
            .map_err(|error| CredentialLifecycleError::Storage(error.to_string()))?;
        let keychain_items: i64 = connection
            .query_row(
                "SELECT COUNT(DISTINCT keychain_reference) FROM credential_generation",
                [],
                |row| row.get(0),
            )
            .map_err(|error| CredentialLifecycleError::Storage(error.to_string()))?;
        let pending_generations: i64 = connection
            .query_row(
                "SELECT COUNT(*) FROM credential_generation WHERE lifecycle_state = 'pendingActivation'",
                [],
                |row| row.get(0),
            )
            .map_err(|error| CredentialLifecycleError::Storage(error.to_string()))?;
        let active_generations: i64 = connection
            .query_row(
                "SELECT COUNT(*) FROM credential_generation WHERE lifecycle_state = 'active'",
                [],
                |row| row.get(0),
            )
            .map_err(|error| CredentialLifecycleError::Storage(error.to_string()))?;
        Ok(ReconciliationCounts {
            generations,
            keychain_items,
            pending_generations,
            active_generations,
        })
    }

    // MARK: helpers

    fn read_state_locked(
        &self,
        connection: &Connection,
        generation_id: &str,
    ) -> Result<GenerationLifecycleState, CredentialLifecycleError> {
        connection
            .query_row(
                "SELECT lifecycle_state FROM credential_generation WHERE generation_id = ?1",
                params![generation_id],
                |row| row.get::<_, String>(0),
            )
            .map_err(|_| CredentialLifecycleError::NotFound {
                id: generation_id.to_string(),
            })?
            .parse_lifecycle()
            .ok_or_else(|| CredentialLifecycleError::Storage("unknown lifecycle state".to_string()))
    }
}

trait StateParsing {
    fn parse_lifecycle(&self) -> Option<GenerationLifecycleState>;
    fn parse_availability(&self) -> Option<SecretAvailability>;
    fn parse_operation(&self) -> Option<DeletionOperationState>;
}

impl StateParsing for String {
    fn parse_lifecycle(&self) -> Option<GenerationLifecycleState> {
        GenerationLifecycleState::from_str(self)
    }

    fn parse_availability(&self) -> Option<SecretAvailability> {
        SecretAvailability::from_str(self)
    }

    fn parse_operation(&self) -> Option<DeletionOperationState> {
        match self.as_str() {
            "requested" => Some(DeletionOperationState::Requested),
            "blockedByUse" => Some(DeletionOperationState::BlockedByUse),
            "deleting" => Some(DeletionOperationState::Deleting),
            "completed" => Some(DeletionOperationState::Completed),
            "failed" => Some(DeletionOperationState::Failed),
            _ => None,
        }
    }
}
