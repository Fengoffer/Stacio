//! agentConversationV2 三态控制面（P3-9，独立存储域）。
//!
//! - `v2_control_state`：单行状态 enabled→draining→disabled→enabled；generation CAS
//!   （离开 enabled 时提升以冻结新授权，重新进入 enabled 时再次提升）+ transition ID 幂等重放。
//! - `v2_control_permit`：issued→prepared→commitAuthorized→settledCommitted|settledAborted；
//!   expiry 规则：未 prepared 只允许 no-target proof；prepared 必须 abort decision。
//! - `v2_control_target_journal`：create_permit 时冻结完整 participant set；
//!   reconciliationRequired 或未终结 permit 阻止迁移到 disabled（draining fence）。

use rusqlite::{params, Connection};
use std::sync::{Arc, Mutex};

const CONTROL_INIT_SQL: &str = include_str!("../../../migrations/control_0001_init.sql");

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ControlError {
    StaleGeneration { expected: i64, current: i64 },
    InvalidTransition { from: String, to: String },
    InvalidSettlement { permit_id: String, detail: String },
    PreparedRequiresAbortDecision { permit_id: String },
    PartialCommitBlocksDisabled { detail: String },
    AuthorizationClosed { state: String },
    NotFound { id: String },
    Storage(String),
}

pub struct ControlDb {
    connection: Arc<Mutex<Connection>>,
}

impl ControlDb {
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
        self.connection.lock().expect("control db poisoned")
    }

    pub fn connection_arc(&self) -> Arc<Mutex<Connection>> {
        Arc::clone(&self.connection)
    }

    fn apply_migrations(&self) -> rusqlite::Result<()> {
        self.connection().execute_batch(CONTROL_INIT_SQL)
    }
}

pub struct ControlStore {
    connection: Arc<Mutex<Connection>>,
}

impl ControlStore {
    pub fn new(db: &ControlDb) -> Self {
        Self {
            connection: db.connection_arc(),
        }
    }

    // MARK: 三态控制面

    pub fn control_state(&self) -> Result<String, ControlError> {
        let connection = self.connection.lock().expect("control db poisoned");
        connection
            .query_row(
                "SELECT state FROM v2_control_state WHERE id = 1",
                [],
                |row| row.get(0),
            )
            .map_err(|error| ControlError::Storage(error.to_string()))
    }

    /// CAS：expected_generation 必须等于当前代际；同 transition_id 幂等重放。
    pub fn transition_control(
        &self,
        to: &str,
        expected_generation: i64,
        transition_id: &str,
    ) -> Result<(), ControlError> {
        let connection = self.connection.lock().expect("control db poisoned");
        let (current_state, generation, last_transition_id): (String, i64, Option<String>) = connection
            .query_row(
                "SELECT state, generation, last_transition_id FROM v2_control_state WHERE id = 1",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .map_err(|error| ControlError::Storage(error.to_string()))?;

        // 同 transition ID 重复投递幂等：不改变状态（不检查 generation，重放合法）。
        if last_transition_id.as_deref() == Some(transition_id) {
            return Ok(());
        }
        if expected_generation != generation {
            return Err(ControlError::StaleGeneration {
                expected: expected_generation,
                current: generation,
            });
        }
        let allowed = match (current_state.as_str(), to) {
            ("enabled", "draining")
            | ("enabled", "disabled")
            | ("draining", "disabled")
            | ("disabled", "enabled")
            | ("draining", "enabled") => true,
            _ => false,
        };
        if !allowed {
            return Err(ControlError::InvalidTransition {
                from: current_state,
                to: to.to_string(),
            });
        }
        if to == "disabled" {
            self.check_drain_fence(&connection)?;
        }
        // 离开 enabled 时先提升代际，令旧代际无法再 prepare/authorize；重新进入
        // enabled 时再次提升，防止排空周期中的任何旧请求复活。
        let next_generation = if current_state == "enabled" || to == "enabled" {
            generation + 1
        } else {
            generation
        };
        connection
            .execute(
                "UPDATE v2_control_state SET state = ?1, generation = ?2, last_transition_id = ?3 WHERE id = 1",
                params![to, next_generation, transition_id],
            )
            .map_err(|error| ControlError::Storage(error.to_string()))?;
        Ok(())
    }

    /// disabled 门禁：任何未终结 permit 或 reconciliationRequired journal 都阻止。
    fn check_drain_fence(&self, connection: &Connection) -> Result<(), ControlError> {
        let open_permits: i64 = connection
            .query_row(
                "SELECT COUNT(*) FROM v2_control_permit
                 WHERE state NOT IN ('settledCommitted', 'settledAborted')",
                [],
                |row| row.get(0),
            )
            .map_err(|error| ControlError::Storage(error.to_string()))?;
        if open_permits > 0 {
            return Err(ControlError::PartialCommitBlocksDisabled {
                detail: format!("{open_permits} permits not settled"),
            });
        }
        let pending_reconciliation: i64 = connection
            .query_row(
                "SELECT COUNT(*) FROM v2_control_target_journal WHERE state = 'reconciliationRequired'",
                [],
                |row| row.get(0),
            )
            .map_err(|error| ControlError::Storage(error.to_string()))?;
        if pending_reconciliation > 0 {
            return Err(ControlError::PartialCommitBlocksDisabled {
                detail: format!("{pending_reconciliation} targets require reconciliation"),
            });
        }
        Ok(())
    }

    /// draining 阶段存量 authorization 仍可完成；disabled 后关闭（draining fence）。
    pub fn authorization_allowed(&self) -> Result<bool, ControlError> {
        Ok(self.control_state()? == "enabled")
    }

    // MARK: Permit 状态机

    /// 签发 Permit 并冻结 target journal（完整 participant set，顺序=传入顺序）。
    pub fn create_permit(
        &self,
        permit_id: &str,
        generation: i64,
        participants: Vec<&str>,
    ) -> Result<(), ControlError> {
        let mut connection = self.connection.lock().expect("control db poisoned");
        let transaction = connection
            .transaction()
            .map_err(|error| ControlError::Storage(error.to_string()))?;
        let (control_state, current_generation): (String, i64) = transaction
            .query_row(
                "SELECT state, generation FROM v2_control_state WHERE id = 1",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .map_err(|error| ControlError::Storage(error.to_string()))?;
        if control_state != "enabled" {
            return Err(ControlError::AuthorizationClosed {
                state: control_state,
            });
        }
        if generation != current_generation {
            return Err(ControlError::StaleGeneration {
                expected: generation,
                current: current_generation,
            });
        }
        transaction
            .execute(
                "INSERT INTO v2_control_permit (permit_id, generation, state, created_at)
                 VALUES (?1, ?2, 'issued', 't')",
                params![permit_id, generation],
            )
            .map_err(|error| ControlError::Storage(error.to_string()))?;
        for participant in &participants {
            transaction
                .execute(
                    "INSERT INTO v2_control_target_journal (permit_id, participant, state)
                     VALUES (?1, ?2, 'prepared')",
                    params![permit_id, participant],
                )
                .map_err(|error| ControlError::Storage(error.to_string()))?;
        }
        transaction
            .commit()
            .map_err(|error| ControlError::Storage(error.to_string()))?;
        Ok(())
    }

    pub fn permit_state(&self, permit_id: &str) -> Result<String, ControlError> {
        let connection = self.connection.lock().expect("control db poisoned");
        connection
            .query_row(
                "SELECT state FROM v2_control_permit WHERE permit_id = ?1",
                params![permit_id],
                |row| row.get(0),
            )
            .map_err(|_| ControlError::NotFound {
                id: permit_id.to_string(),
            })
    }

    fn transition_permit(&self, permit_id: &str, to: &str) -> Result<(), ControlError> {
        let connection = self.connection.lock().expect("control db poisoned");
        let (current, permit_generation): (String, i64) = connection
            .query_row(
                "SELECT state, generation FROM v2_control_permit WHERE permit_id = ?1",
                params![permit_id],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .map_err(|_| ControlError::NotFound {
                id: permit_id.to_string(),
            })?;
        let (control_state, control_generation): (String, i64) = connection
            .query_row(
                "SELECT state, generation FROM v2_control_state WHERE id = 1",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .map_err(|error| ControlError::Storage(error.to_string()))?;
        if control_state != "enabled" {
            return Err(ControlError::AuthorizationClosed {
                state: control_state,
            });
        }
        if permit_generation != control_generation {
            return Err(ControlError::StaleGeneration {
                expected: permit_generation,
                current: control_generation,
            });
        }
        let allowed = match (current.as_str(), to) {
            ("issued", "prepared") | ("prepared", "commitAuthorized") => true,
            _ => false,
        };
        if !allowed {
            return Err(ControlError::InvalidTransition {
                from: current,
                to: to.to_string(),
            });
        }
        connection
            .execute(
                "UPDATE v2_control_permit SET state = ?1 WHERE permit_id = ?2",
                params![to, permit_id],
            )
            .map_err(|error| ControlError::Storage(error.to_string()))?;
        Ok(())
    }

    pub fn prepare_permit(&self, permit_id: &str) -> Result<(), ControlError> {
        self.transition_permit(permit_id, "prepared")
    }

    pub fn authorize_permit_commit(&self, permit_id: &str) -> Result<(), ControlError> {
        self.transition_permit(permit_id, "commitAuthorized")
    }

    /// 结算：settledCommitted（commitAuthorized 或全 journal committed）/settledAborted；settling 中间态可选。
    /// proof（targetSettlementProofDigest 等）作为对账锚点持久化。
    pub fn settle_permit(
        &self,
        permit_id: &str,
        settlement: &str,
        proof: &str,
    ) -> Result<(), ControlError> {
        let connection = self.connection.lock().expect("control db poisoned");
        let current: String = connection
            .query_row(
                "SELECT state FROM v2_control_permit WHERE permit_id = ?1",
                params![permit_id],
                |row| row.get(0),
            )
            .map_err(|_| ControlError::NotFound {
                id: permit_id.to_string(),
            })?;
        let allowed = match (current.as_str(), settlement) {
            // 授权路径：commitAuthorized → settling → settledCommitted（settlement-start 先持久化）
            ("commitAuthorized", "settling") | ("settling", "settledCommitted") => true,
            // 全 target journal 一致 committed 即授权证据（无 prepare/authorize 步骤的收尾路径）
            ("issued" | "prepared", "settling" | "settledCommitted") => {
                let journal_consistent: i64 = connection
                    .query_row(
                        "SELECT COUNT(*) FROM v2_control_target_journal
                         WHERE permit_id = ?1 AND state != 'committed'",
                        params![permit_id],
                        |row| row.get(0),
                    )
                    .map_err(|error| ControlError::Storage(error.to_string()))?;
                journal_consistent == 0
            }
            // abort path（abort decision 可直接结算，无需 settling）
            ("settling", "settledAborted")
            | ("issued", "settledAborted")
            | ("prepared", "settledAborted")
            | ("commitAuthorized", "settledAborted") => true,
            _ => false,
        };
        if !allowed {
            // 终态再结算走 InvalidTransition（区别于非法 settlement 值）。
            let terminal = matches!(current.as_str(), "settledCommitted" | "settledAborted");
            if terminal {
                return Err(ControlError::InvalidTransition {
                    from: current,
                    to: settlement.to_string(),
                });
            }
            return Err(ControlError::InvalidSettlement {
                permit_id: permit_id.to_string(),
                detail: format!("{current} → {settlement}"),
            });
        }
        connection
            .execute(
                "UPDATE v2_control_permit SET state = ?1, settlement_proof = ?3 WHERE permit_id = ?2",
                params![settlement, permit_id, proof],
            )
            .map_err(|error| ControlError::Storage(error.to_string()))?;
        Ok(())
    }

    /// expiry：未 prepared（issued）只允许 no-target proof（with_target_proof=false）；
    /// prepared 或已授权必须走 abort decision（全 target abort proof），拒绝 no-target expiry。
    pub fn expire_permit(
        &self,
        permit_id: &str,
        with_target_proof: bool,
    ) -> Result<(), ControlError> {
        let connection = self.connection.lock().expect("control db poisoned");
        let current: String = connection
            .query_row(
                "SELECT state FROM v2_control_permit WHERE permit_id = ?1",
                params![permit_id],
                |row| row.get(0),
            )
            .map_err(|_| ControlError::NotFound {
                id: permit_id.to_string(),
            })?;
        match current.as_str() {
            "issued" => {
                if with_target_proof {
                    return Err(ControlError::InvalidSettlement {
                        permit_id: permit_id.to_string(),
                        detail: "unprepared permit cannot settle with target proof".to_string(),
                    });
                }
                connection
                    .execute(
                        "UPDATE v2_control_permit SET state = 'settledAborted', settlement_proof = 'expiry:no-target-proof' WHERE permit_id = ?1",
                        params![permit_id],
                    )
                    .map_err(|error| ControlError::Storage(error.to_string()))?;
                Ok(())
            }
            "prepared" | "commitAuthorized" => Err(ControlError::PreparedRequiresAbortDecision {
                permit_id: permit_id.to_string(),
            }),
            _ => Err(ControlError::InvalidTransition {
                from: current,
                to: "settledAborted".to_string(),
            }),
        }
    }

    // MARK: target journal

    /// 冻结的 participant set（按签发顺序）。
    pub fn journal_participants(&self, permit_id: &str) -> Result<Vec<String>, ControlError> {
        let connection = self.connection.lock().expect("control db poisoned");
        let mut statement = connection
            .prepare(
                "SELECT participant FROM v2_control_target_journal WHERE permit_id = ?1 ORDER BY rowid",
            )
            .map_err(|error| ControlError::Storage(error.to_string()))?;
        let rows = statement
            .query_map(params![permit_id], |row| row.get::<_, String>(0))
            .map_err(|error| ControlError::Storage(error.to_string()))?;
        let mut participants = Vec::new();
        for row in rows {
            participants.push(row.map_err(|error| ControlError::Storage(error.to_string()))?);
        }
        if participants.is_empty() {
            return Err(ControlError::NotFound {
                id: permit_id.to_string(),
            });
        }
        Ok(participants)
    }

    pub fn mark_journal(
        &self,
        permit_id: &str,
        participant: &str,
        state: &str,
    ) -> Result<(), ControlError> {
        // 与 Swift V2ControlTargetJournalState 关闭集合一致：
        // prepared/committing/committed/aborting/aborted/reconciliationRequired
        let allowed = matches!(
            state,
            "prepared"
                | "committing"
                | "committed"
                | "aborting"
                | "aborted"
                | "reconciliationRequired"
        );
        if !allowed {
            return Err(ControlError::InvalidTransition {
                from: "journal".to_string(),
                to: state.to_string(),
            });
        }
        let connection = self.connection.lock().expect("control db poisoned");
        let updated = connection
            .execute(
                "UPDATE v2_control_target_journal SET state = ?1 WHERE permit_id = ?2 AND participant = ?3",
                params![state, permit_id, participant],
            )
            .map_err(|error| ControlError::Storage(error.to_string()))?;
        if updated == 0 {
            return Err(ControlError::NotFound {
                id: format!("{permit_id}/{participant}"),
            });
        }
        Ok(())
    }
}
