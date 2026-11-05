//! CredentialAttemptBinding 跨 Store saga 与零 binding proof（P3-8b，独立存储域）。
//!
//! 状态机：`reserved→commitPending→committed→releasing→released|quarantined`；
//! 终态 release 必须验证 Conversation 终态 commit proof；
//! 四种 RuntimeAuthenticationSnapshot 的 binding/零 binding participant proof。

use rusqlite::{params, Connection};
use std::sync::{Arc, Mutex, OnceLock};

const BINDING_INIT_SQL: &str = include_str!("../../../migrations/credential_binding_0001_init.sql");

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BindingReconciliationOutcome {
    /// 已提交但 ack 丢失 → 补 committed
    CommitConfirmed,
    /// 明确不存在且越过可提交恢复点 → released
    ReleaseConfirmed,
    /// 无法确认 → quarantine（阻止删除）
    Quarantine,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CredentialBindingError {
    MissingTerminalProof,
    MissingRequiredBinding,
    UnexpectedBinding,
    InvalidTransition { from: String, to: String },
    NotFound { id: String },
    Storage(String),
}

pub struct CredentialBindingDb {
    connection: Arc<Mutex<Connection>>,
    path: String,
}

impl CredentialBindingDb {
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
        self.connection.lock().expect("binding db poisoned")
    }

    pub fn connection_arc(&self) -> Arc<Mutex<Connection>> {
        Arc::clone(&self.connection)
    }

    fn apply_migrations(&self) -> rusqlite::Result<()> {
        self.connection().execute_batch(BINDING_INIT_SQL)
    }
}

fn binding_sequence() -> &'static Mutex<i64> {
    static SEQUENCE: OnceLock<Mutex<i64>> = OnceLock::new();
    SEQUENCE.get_or_init(|| Mutex::new(0))
}

pub struct CredentialBindingStore {
    connection: Arc<Mutex<Connection>>,
}

impl CredentialBindingStore {
    pub fn new(db: &CredentialBindingDb) -> Self {
        Self {
            connection: db.connection_arc(),
        }
    }

    pub fn reserve(
        &self,
        binding_id: &str,
        attempt_id: &str,
        credential_generation_id: &str,
        conversation_commit_sequence: i64,
    ) -> Result<(), CredentialBindingError> {
        let connection = self.connection.lock().expect("binding db poisoned");
        connection
            .execute(
                "INSERT INTO credential_attempt_binding
                   (binding_id, attempt_id, credential_generation_id, state, conversation_commit_sequence, created_at)
                 VALUES (?1, ?2, ?3, 'reserved', ?4, 't')",
                params![binding_id, attempt_id, credential_generation_id, conversation_commit_sequence],
            )
            .map_err(|error| CredentialBindingError::Storage(error.to_string()))?;
        Ok(())
    }

    fn transition(
        &self,
        binding_id: &str,
        to: &str,
        commit_sequence: Option<i64>,
        proof_digest: Option<&str>,
    ) -> Result<(), CredentialBindingError> {
        let connection = self.connection.lock().expect("binding db poisoned");
        let current: String = connection
            .query_row(
                "SELECT state FROM credential_attempt_binding WHERE binding_id = ?1",
                params![binding_id],
                |row| row.get(0),
            )
            .map_err(|_| CredentialBindingError::NotFound {
                id: binding_id.to_string(),
            })?;
        let allowed = match (current.as_str(), to) {
            ("reserved", "commitPending")
            | ("reserved", "quarantined")
            | ("commitPending", "committed")
            | ("commitPending", "quarantined")
            | ("committed", "releasing")
            | ("committed", "quarantined")
            | ("releasing", "released")
            | ("releasing", "quarantined")
            | ("reserved", "releasing") => true,
            _ => false,
        };
        if !allowed {
            return Err(CredentialBindingError::InvalidTransition {
                from: current,
                to: to.to_string(),
            });
        }
        connection
            .execute(
                "UPDATE credential_attempt_binding
                 SET state = ?1,
                     conversation_commit_sequence = COALESCE(?2, conversation_commit_sequence),
                     proof_digest = COALESCE(?3, proof_digest),
                     released_at = CASE WHEN ?1 = 'released' THEN 't' ELSE released_at END
                 WHERE binding_id = ?4",
                params![to, commit_sequence, proof_digest, binding_id],
            )
            .map_err(|error| CredentialBindingError::Storage(error.to_string()))?;
        Ok(())
    }

    pub fn mark_commit_pending(&self, binding_id: &str) -> Result<(), CredentialBindingError> {
        self.transition(binding_id, "commitPending", None, None)
    }

    pub fn commit_bound(
        &self,
        binding_id: &str,
        conversation_commit_sequence: i64,
        proof_digest: &str,
    ) -> Result<(), CredentialBindingError> {
        self.transition(
            binding_id,
            "committed",
            Some(conversation_commit_sequence),
            Some(proof_digest),
        )
    }

    /// 终态 release：必须验证 Conversation 终态 commit proof（sequence > 0 表示已提交）。
    /// 经 releasing 中间态两跳：committed → releasing → released。
    pub fn release(
        &self,
        binding_id: &str,
        conversation_commit_sequence: i64,
    ) -> Result<(), CredentialBindingError> {
        if conversation_commit_sequence <= 0 {
            return Err(CredentialBindingError::MissingTerminalProof);
        }
        self.transition(
            binding_id,
            "releasing",
            Some(conversation_commit_sequence),
            None,
        )?;
        self.transition(
            binding_id,
            "released",
            Some(conversation_commit_sequence),
            None,
        )
    }

    pub fn quarantine(
        &self,
        binding_id: &str,
        _reason: &str,
    ) -> Result<(), CredentialBindingError> {
        self.transition(binding_id, "quarantined", None, None)
    }

    pub fn binding_state(&self, binding_id: &str) -> Result<String, CredentialBindingError> {
        let connection = self.connection.lock().expect("binding db poisoned");
        connection
            .query_row(
                "SELECT state FROM credential_attempt_binding WHERE binding_id = ?1",
                params![binding_id],
                |row| row.get(0),
            )
            .map_err(|_| CredentialBindingError::NotFound {
                id: binding_id.to_string(),
            })
    }

    pub fn commit_sequence(&self, binding_id: &str) -> Result<i64, CredentialBindingError> {
        let connection = self.connection.lock().expect("binding db poisoned");
        connection
            .query_row(
                "SELECT conversation_commit_sequence FROM credential_attempt_binding WHERE binding_id = ?1",
                params![binding_id],
                |row| row.get(0),
            )
            .map_err(|_| CredentialBindingError::NotFound {
                id: binding_id.to_string(),
            })
    }

    /// 四种窗口对账（不可变 proof）：
    /// 已提交 → CommitConfirmed；明确不存在且越过可提交恢复点 → ReleaseConfirmed；
    /// 无法确认 → Quarantine（阻止删除）。
    #[allow(clippy::too_many_arguments)]
    pub fn reconcile_window(
        had_conversation_commit: bool,
        conversation_commit_sequence: i64,
        ack_received: bool,
        past_commit_recovery_point: bool,
    ) -> BindingReconciliationOutcome {
        if had_conversation_commit && !ack_received {
            return BindingReconciliationOutcome::CommitConfirmed;
        }
        if !had_conversation_commit && past_commit_recovery_point {
            return BindingReconciliationOutcome::ReleaseConfirmed;
        }
        if had_conversation_commit && conversation_commit_sequence > 0 && !ack_received {
            return BindingReconciliationOutcome::CommitConfirmed;
        }
        BindingReconciliationOutcome::Quarantine
    }

    /// derivedActiveBindingCount 只由未释放 binding 的权威索引派生。
    pub fn derived_active_binding_count(&self) -> Result<i64, CredentialBindingError> {
        let connection = self.connection.lock().expect("binding db poisoned");
        connection
            .query_row(
                "SELECT COUNT(*) FROM credential_attempt_binding WHERE state NOT IN ('released', 'quarantined')",
                [],
                |row| row.get(0),
            )
            .map_err(|error| CredentialBindingError::Storage(error.to_string()))
    }

    /// 四 mode participant proof：
    /// `stacioCredentialBindings|combined` 必须有 binding；`cliManagedAuthentication|noneVerified`
    /// 必须零 binding（异常 binding → 隔离并在 Admission 前失败）。
    pub fn participant_proof(
        authentication_mode: &str,
        binding_count: i64,
    ) -> Result<(), CredentialBindingError> {
        match authentication_mode {
            "stacioCredentialBindings" | "combined" => {
                if binding_count == 0 {
                    Err(CredentialBindingError::MissingRequiredBinding)
                } else {
                    Ok(())
                }
            }
            "cliManagedAuthentication" | "noneVerified" => {
                if binding_count == 0 {
                    Ok(())
                } else {
                    Err(CredentialBindingError::UnexpectedBinding)
                }
            }
            _ => Err(CredentialBindingError::UnexpectedBinding),
        }
    }
}
