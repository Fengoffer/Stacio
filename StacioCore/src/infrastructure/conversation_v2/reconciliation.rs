//! External Effect reconciliation（P3-9，独立存储域）。
//!
//! - `conflict_key`：target_digest + resource_scope + operation_class 的稳定组合。
//! - 每条记录冻结 evidence strength；弱证据（none）不得结算 verifiedCompleted。
//! - 同 key 全记录终结前锁不释放；unknown 远端 effect 锁不占全局 Admission。

use rusqlite::{params, Connection};
use std::sync::{Arc, Mutex};

const RECONCILIATION_INIT_SQL: &str =
    include_str!("../../../migrations/reconciliation_0001_init.sql");

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ReconciliationError {
    EvidenceTooWeak { effect_id: String, required: String },
    InvalidTransition { from: String, to: String },
    NotFound { id: String },
    Storage(String),
}

pub struct ReconciliationDb {
    connection: Arc<Mutex<Connection>>,
}

impl ReconciliationDb {
    pub fn open(path: &str) -> rusqlite::Result<Self> {
        let connection = Connection::open(path)?;
        let db = Self {
            connection: Arc::new(Mutex::new(connection)),
        };
        db.apply_migrations()?;
        Ok(db)
    }

    pub fn open_in_memory() -> rusqlite::Result<Self> {
        let connection = Connection::open_in_memory()?;
        let db = Self {
            connection: Arc::new(Mutex::new(connection)),
        };
        db.apply_migrations()?;
        Ok(db)
    }

    pub fn connection(&self) -> std::sync::MutexGuard<'_, Connection> {
        self.connection.lock().expect("reconciliation db poisoned")
    }

    pub fn connection_arc(&self) -> Arc<Mutex<Connection>> {
        Arc::clone(&self.connection)
    }

    fn apply_migrations(&self) -> rusqlite::Result<()> {
        self.connection().execute_batch(RECONCILIATION_INIT_SQL)
    }
}

pub struct ReconciliationStore {
    connection: Arc<Mutex<Connection>>,
}

/// 终结状态集合：结算后不再变化，锁可释放。
const TERMINAL_STATES: &[&str] = &["isolated", "verifiedCompleted", "verifiedFailed", "noop"];

impl ReconciliationStore {
    pub fn new(db: &ReconciliationDb) -> Self {
        Self {
            connection: db.connection_arc(),
        }
    }

    /// 稳定组合：target digest + resource scope + operation class。
    /// 用长度前缀避免不同段边界碰撞（如 "a|b|c" 与 "ab|c|" 不同）。
    pub fn conflict_key(
        target_digest: &str,
        resource_scope: &str,
        operation_class: &str,
    ) -> String {
        format!(
            "{}:{}|{}:{}|{}:{}",
            target_digest.len(),
            target_digest,
            resource_scope.len(),
            resource_scope,
            operation_class.len(),
            operation_class
        )
    }

    pub fn create_record(
        &self,
        effect_id: &str,
        conflict_key: &str,
        state: &str,
    ) -> Result<(), ReconciliationError> {
        self.create_record_with_strength(effect_id, conflict_key, state, "none")
    }

    pub fn create_record_with_strength(
        &self,
        effect_id: &str,
        conflict_key: &str,
        state: &str,
        evidence_strength: &str,
    ) -> Result<(), ReconciliationError> {
        let connection = self.connection.lock().expect("reconciliation db poisoned");
        connection
            .execute(
                "INSERT INTO v2_external_effect (effect_id, conflict_key, state, evidence_strength, created_at)
                 VALUES (?1, ?2, ?3, ?4, 't')",
                params![effect_id, conflict_key, state, evidence_strength],
            )
            .map_err(|error| ReconciliationError::Storage(error.to_string()))?;
        Ok(())
    }

    fn terminal(state: &str) -> bool {
        TERMINAL_STATES.contains(&state)
    }

    /// 同 key 全记录终结前锁不释放。
    pub fn lock_released(&self, conflict_key: &str) -> Result<bool, ReconciliationError> {
        let connection = self.connection.lock().expect("reconciliation db poisoned");
        let open: i64 = connection
            .query_row(
                "SELECT COUNT(*) FROM v2_external_effect WHERE conflict_key = ?1 AND state = 'unknown'",
                params![conflict_key],
                |row| row.get(0),
            )
            .map_err(|error| ReconciliationError::Storage(error.to_string()))?;
        Ok(open == 0)
    }

    pub fn lock_owner(&self, conflict_key: &str) -> Result<String, ReconciliationError> {
        let connection = self.connection.lock().expect("reconciliation db poisoned");
        let open: i64 = connection
            .query_row(
                "SELECT COUNT(*) FROM v2_external_effect WHERE conflict_key = ?1 AND state = 'unknown'",
                params![conflict_key],
                |row| row.get(0),
            )
            .map_err(|error| ReconciliationError::Storage(error.to_string()))?;
        Ok(if open == 0 {
            "released".to_string()
        } else {
            "reconciliation".to_string()
        })
    }

    /// unknown 远端 effect 锁不占全局 Admission；仅已识别且在途（非终结）记录占用。
    pub fn holds_global_admission(&self, conflict_key: &str) -> Result<bool, ReconciliationError> {
        let connection = self.connection.lock().expect("reconciliation db poisoned");
        let in_flight: i64 = connection
            .query_row(
                "SELECT COUNT(*) FROM v2_external_effect
                 WHERE conflict_key = ?1 AND state != 'unknown' AND state != 'isolated'
                   AND state != 'verifiedCompleted' AND state != 'verifiedFailed' AND state != 'noop'",
                params![conflict_key],
                |row| row.get(0),
            )
            .map_err(|error| ReconciliationError::Storage(error.to_string()))?;
        Ok(in_flight > 0)
    }

    pub fn evidence_strength(&self, effect_id: &str) -> Result<String, ReconciliationError> {
        let connection = self.connection.lock().expect("reconciliation db poisoned");
        connection
            .query_row(
                "SELECT evidence_strength FROM v2_external_effect WHERE effect_id = ?1",
                params![effect_id],
                |row| row.get(0),
            )
            .map_err(|_| ReconciliationError::NotFound {
                id: effect_id.to_string(),
            })
    }

    /// 证据强度等级：none < structured < verified。
    /// verifiedCompleted 需要 verified 级证据（structured 不够）；isolated/verifiedFailed/noop 无需证据。
    fn evidence_sufficient(strength: &str, required: &str) -> bool {
        let rank = |level: &str| match level {
            "verified" => 2,
            "structured" => 1,
            _ => 0,
        };
        rank(strength) >= rank(required)
    }

    /// 结算记录：unknown → 终态；终态重复结算幂等；弱证据不得结算 verifiedCompleted。
    pub fn settle_record(
        &self,
        effect_id: &str,
        settlement: &str,
    ) -> Result<(), ReconciliationError> {
        let connection = self.connection.lock().expect("reconciliation db poisoned");
        let (current, strength): (String, String) = connection
            .query_row(
                "SELECT state, evidence_strength FROM v2_external_effect WHERE effect_id = ?1",
                params![effect_id],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .map_err(|_| ReconciliationError::NotFound {
                id: effect_id.to_string(),
            })?;
        let allowed = Self::terminal(settlement);
        if !allowed {
            return Err(ReconciliationError::InvalidTransition {
                from: current,
                to: settlement.to_string(),
            });
        }
        if current == settlement {
            // 终态重复结算幂等
            return Ok(());
        }
        if current != "unknown" {
            return Err(ReconciliationError::InvalidTransition {
                from: current,
                to: settlement.to_string(),
            });
        }
        if settlement == "verifiedCompleted" && !Self::evidence_sufficient(&strength, "verified") {
            return Err(ReconciliationError::EvidenceTooWeak {
                effect_id: effect_id.to_string(),
                required: "verified".to_string(),
            });
        }
        connection
            .execute(
                "UPDATE v2_external_effect SET state = ?1 WHERE effect_id = ?2",
                params![settlement, effect_id],
            )
            .map_err(|error| ReconciliationError::Storage(error.to_string()))?;
        Ok(())
    }
}
