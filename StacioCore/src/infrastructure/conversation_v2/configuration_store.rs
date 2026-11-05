//! Configuration Store Rust 后端（P3-12，独立 Configuration Store）。
//!
//! - `configuration`：expected-revision CAS、typed value digest、状态机
//!   （draft→prepared→dispatched→activating→active；任意→deleted 终态）、
//!   credential 只存引用（generation id）不存权威；
//! - `runtime_configuration_event`：关闭 kind 集合、configuration-scoped durable sequence、
//!   mutation/deletion 与 Setting/Action audit 通过同一 operation ID 关联；
//! - 无 secret 存储；存储域与 conversation v2 / settings 分离。

use rusqlite::{params, Connection, OptionalExtension, Transaction, TransactionBehavior};
use std::sync::{Arc, Mutex};

const CONFIGURATION_INIT_SQL: &str =
    include_str!("../../../migrations/configuration_v2_0001_init.sql");

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConfigurationError {
    StaleRevision {
        key: String,
        expected: i64,
        current: i64,
    },
    KeyExists {
        key: String,
    },
    NotFound {
        key: String,
    },
    InvalidTransition {
        from: String,
        to: String,
    },
    InvalidKind {
        kind: String,
    },
    /// An idempotency key is immutable. Reusing it for a different
    /// configuration/operation/kind must fail closed instead of returning the
    /// sequence of an unrelated event.
    EventIdConflict {
        event_id: String,
    },
    Storage(String),
}

/// 关闭 kind 集合（计划 P3-12 Step 1）。
const EVENT_KINDS: &[&str] = &[
    "configurationDraftSaved",
    "configurationMutationCommitted",
    "configurationVerificationPrepared",
    "configurationDispatched",
    "configurationCancellationRequested",
    "configurationSettled",
    "configurationActivationStarted",
    "configurationActivated",
    "configurationDeletionCommitted",
    "configurationStateChanged",
    "configurationDeleted",
];

pub struct ConfigurationDb {
    connection: Arc<Mutex<Connection>>,
}

impl ConfigurationDb {
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
        self.connection.lock().expect("configuration db poisoned")
    }

    pub fn connection_arc(&self) -> Arc<Mutex<Connection>> {
        Arc::clone(&self.connection)
    }

    fn apply_migrations(&self) -> rusqlite::Result<()> {
        self.connection().execute_batch(CONFIGURATION_INIT_SQL)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConfigurationSnapshot {
    pub revision: i64,
    pub value_digest: String,
    pub state: String,
    pub credential_reference: String,
}

pub struct ConfigurationStore {
    connection: Arc<Mutex<Connection>>,
}

impl ConfigurationStore {
    pub fn new(db: &ConfigurationDb) -> Self {
        Self {
            connection: db.connection_arc(),
        }
    }

    // MARK: configuration 值表（revision CAS）

    /// 写入/更新 configuration：`expected_revision` Some 时必须匹配；None 仅创建。
    /// `credential_reference` 只存引用（generation id），不存 secret。
    pub fn upsert_configuration(
        &self,
        configuration_id: &str,
        expected_revision: Option<i64>,
        value_digest: &str,
        credential_reference: &str,
    ) -> Result<(), ConfigurationError> {
        let connection = self.connection.lock().expect("configuration db poisoned");
        let current: Option<i64> = connection
            .query_row(
                "SELECT revision FROM configuration WHERE configuration_id = ?1",
                params![configuration_id],
                |row| row.get(0),
            )
            .ok();
        match (expected_revision, current) {
            (None, Some(_)) => Err(ConfigurationError::KeyExists {
                key: configuration_id.to_string(),
            }),
            (None, None) => {
                connection
                    .execute(
                        "INSERT INTO configuration (configuration_id, revision, value_digest, credential_reference, updated_at)
                         VALUES (?1, 1, ?2, ?3, 't')",
                        params![configuration_id, value_digest, credential_reference],
                    )
                    .map_err(|error| ConfigurationError::Storage(error.to_string()))?;
                Ok(())
            }
            (Some(expected), Some(current_revision)) => {
                if expected != current_revision {
                    return Err(ConfigurationError::StaleRevision {
                        key: configuration_id.to_string(),
                        expected,
                        current: current_revision,
                    });
                }
                // 防御性 CAS：UPDATE 携带 revision 条件（当前 Mutex 串行已保证，防未来并发模型回归）
                let updated = connection
                    .execute(
                        "UPDATE configuration SET revision = revision + 1, value_digest = ?2, credential_reference = ?3, updated_at = 't'
                         WHERE configuration_id = ?1 AND revision = ?4",
                        params![configuration_id, value_digest, credential_reference, expected],
                    )
                    .map_err(|error| ConfigurationError::Storage(error.to_string()))?;
                if updated == 0 {
                    return Err(ConfigurationError::StaleRevision {
                        key: configuration_id.to_string(),
                        expected,
                        current: current_revision,
                    });
                }
                Ok(())
            }
            (Some(expected), None) => Err(ConfigurationError::StaleRevision {
                key: configuration_id.to_string(),
                expected,
                current: 0,
            }),
        }
    }

    /// Atomically commits one already-verified configuration as active. The
    /// revision CAS, value update, state publication, and audit evidence share
    /// one SQLite transaction so runtime readers never observe a draft value as
    /// launch authority.
    pub fn commit_verified_configuration(
        &self,
        configuration_id: &str,
        expected_revision: Option<i64>,
        value_digest: &str,
        credential_reference: &str,
        operation_id: &str,
        event_id: &str,
    ) -> Result<i64, ConfigurationError> {
        Self::validate_atomic_input(configuration_id, value_digest, operation_id, event_id)?;
        let mut connection = self.connection.lock().expect("configuration db poisoned");
        let transaction = connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|error| ConfigurationError::Storage(error.to_string()))?;

        // A retry may arrive after the original transaction committed. Treat
        // the exact same mutation + activation pair as idempotent, but never
        // let an event id authorize a different payload or configuration.
        if let Some(existing_revision) = Self::existing_atomic_commit_revision(
            &transaction,
            event_id,
            configuration_id,
            operation_id,
            value_digest,
            credential_reference,
            expected_revision,
        )? {
            return Ok(existing_revision);
        }
        let current: Option<(i64, String)> = transaction
            .query_row(
                "SELECT revision, state FROM configuration WHERE configuration_id = ?1",
                params![configuration_id],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()
            .map_err(|error| ConfigurationError::Storage(error.to_string()))?;

        let next_revision = match (expected_revision, current) {
            (None, None) => {
                transaction
                    .execute(
                        "INSERT INTO configuration
                         (configuration_id, revision, value_digest, state, credential_reference, updated_at)
                         VALUES (?1, 1, ?2, 'active', ?3, 't')",
                        params![configuration_id, value_digest, credential_reference],
                    )
                    .map_err(|error| ConfigurationError::Storage(error.to_string()))?;
                1
            }
            (None, Some(_)) => {
                return Err(ConfigurationError::KeyExists {
                    key: configuration_id.to_string(),
                })
            }
            (Some(expected), Some((current_revision, state))) => {
                if expected != current_revision {
                    return Err(ConfigurationError::StaleRevision {
                        key: configuration_id.to_string(),
                        expected,
                        current: current_revision,
                    });
                }
                if state == "deleted" {
                    return Err(ConfigurationError::InvalidTransition {
                        from: state,
                        to: "active".to_string(),
                    });
                }
                let updated = transaction
                    .execute(
                        "UPDATE configuration
                         SET revision = revision + 1, value_digest = ?2, state = 'active',
                             credential_reference = ?3, updated_at = 't'
                         WHERE configuration_id = ?1 AND revision = ?4 AND state <> 'deleted'",
                        params![
                            configuration_id,
                            value_digest,
                            credential_reference,
                            expected
                        ],
                    )
                    .map_err(|error| ConfigurationError::Storage(error.to_string()))?;
                if updated != 1 {
                    return Err(ConfigurationError::StaleRevision {
                        key: configuration_id.to_string(),
                        expected,
                        current: current_revision,
                    });
                }
                current_revision + 1
            }
            (Some(expected), None) => {
                return Err(ConfigurationError::StaleRevision {
                    key: configuration_id.to_string(),
                    expected,
                    current: 0,
                })
            }
        };

        Self::append_atomic_event(
            &transaction,
            event_id,
            configuration_id,
            operation_id,
            "configurationMutationCommitted",
        )?;
        Self::append_atomic_event(
            &transaction,
            &format!("{event_id}:activated"),
            configuration_id,
            operation_id,
            "configurationActivated",
        )?;
        transaction
            .commit()
            .map_err(|error| ConfigurationError::Storage(error.to_string()))?;
        Ok(next_revision)
    }

    /// Atomically tombstones one configuration under revision CAS and records
    /// both deletion intent and terminal deletion evidence.
    pub fn delete_configuration(
        &self,
        configuration_id: &str,
        expected_revision: i64,
        tombstone_digest: &str,
        operation_id: &str,
        event_id: &str,
    ) -> Result<i64, ConfigurationError> {
        Self::validate_atomic_input(configuration_id, tombstone_digest, operation_id, event_id)?;
        let mut connection = self.connection.lock().expect("configuration db poisoned");
        let transaction = connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|error| ConfigurationError::Storage(error.to_string()))?;

        // Deletion retries are idempotent only when both durable events and
        // the tombstone snapshot match the original request.
        if let Some(existing_revision) = Self::existing_atomic_delete_revision(
            &transaction,
            event_id,
            configuration_id,
            operation_id,
            tombstone_digest,
            expected_revision,
        )? {
            return Ok(existing_revision);
        }
        let current: Option<(i64, String)> = transaction
            .query_row(
                "SELECT revision, state FROM configuration WHERE configuration_id = ?1",
                params![configuration_id],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()
            .map_err(|error| ConfigurationError::Storage(error.to_string()))?;
        let Some((current_revision, state)) = current else {
            return Err(ConfigurationError::NotFound {
                key: configuration_id.to_string(),
            });
        };
        if current_revision != expected_revision {
            return Err(ConfigurationError::StaleRevision {
                key: configuration_id.to_string(),
                expected: expected_revision,
                current: current_revision,
            });
        }
        if state == "deleted" {
            return Err(ConfigurationError::InvalidTransition {
                from: state,
                to: "deleted".to_string(),
            });
        }
        let updated = transaction
            .execute(
                "UPDATE configuration
                 SET revision = revision + 1, value_digest = ?2, state = 'deleted',
                     credential_reference = '', updated_at = 't'
                 WHERE configuration_id = ?1 AND revision = ?3 AND state <> 'deleted'",
                params![configuration_id, tombstone_digest, expected_revision],
            )
            .map_err(|error| ConfigurationError::Storage(error.to_string()))?;
        if updated != 1 {
            return Err(ConfigurationError::StaleRevision {
                key: configuration_id.to_string(),
                expected: expected_revision,
                current: current_revision,
            });
        }
        Self::append_atomic_event(
            &transaction,
            event_id,
            configuration_id,
            operation_id,
            "configurationDeletionCommitted",
        )?;
        Self::append_atomic_event(
            &transaction,
            &format!("{event_id}:deleted"),
            configuration_id,
            operation_id,
            "configurationDeleted",
        )?;
        transaction
            .commit()
            .map_err(|error| ConfigurationError::Storage(error.to_string()))?;
        Ok(current_revision + 1)
    }

    pub fn configuration(
        &self,
        configuration_id: &str,
    ) -> Result<Option<ConfigurationSnapshot>, ConfigurationError> {
        let connection = self.connection.lock().expect("configuration db poisoned");
        connection
            .query_row(
                "SELECT revision, value_digest, state, credential_reference FROM configuration WHERE configuration_id = ?1",
                params![configuration_id],
                |row| {
                    Ok(ConfigurationSnapshot {
                        revision: row.get(0)?,
                        value_digest: row.get(1)?,
                        state: row.get(2)?,
                        credential_reference: row.get(3)?,
                    })
                },
            )
            .map(Some)
            .or_else(|error| match error {
                rusqlite::Error::QueryReturnedNoRows => Ok(None),
                other => Err(ConfigurationError::Storage(other.to_string())),
            })
    }

    fn validate_atomic_input(
        configuration_id: &str,
        value_digest: &str,
        operation_id: &str,
        event_id: &str,
    ) -> Result<(), ConfigurationError> {
        if configuration_id.is_empty()
            || value_digest.is_empty()
            || operation_id.is_empty()
            || event_id.is_empty()
        {
            return Err(ConfigurationError::Storage(
                "empty atomic configuration input".to_string(),
            ));
        }
        Ok(())
    }

    fn append_atomic_event(
        transaction: &Transaction<'_>,
        event_id: &str,
        configuration_id: &str,
        operation_id: &str,
        kind: &str,
    ) -> Result<i64, ConfigurationError> {
        if !EVENT_KINDS.contains(&kind) {
            return Err(ConfigurationError::InvalidKind {
                kind: kind.to_string(),
            });
        }
        if let Some(existing) = transaction
            .query_row(
                "SELECT sequence, configuration_id, operation_id, kind
                   FROM runtime_configuration_event WHERE event_id = ?1",
                params![event_id],
                |row| {
                    Ok((
                        row.get::<_, i64>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, String>(2)?,
                        row.get::<_, String>(3)?,
                    ))
                },
            )
            .optional()
            .map_err(|error| ConfigurationError::Storage(error.to_string()))?
        {
            if existing.1 == configuration_id && existing.2 == operation_id && existing.3 == kind {
                return Ok(existing.0);
            }
            return Err(ConfigurationError::EventIdConflict {
                event_id: event_id.to_string(),
            });
        }
        let next: i64 = transaction
            .query_row(
                "SELECT COALESCE(MAX(sequence), 0) + 1 FROM runtime_configuration_event",
                [],
                |row| row.get(0),
            )
            .map_err(|error| ConfigurationError::Storage(error.to_string()))?;
        transaction
            .execute(
                "INSERT INTO runtime_configuration_event
                 (event_id, sequence, configuration_id, operation_id, kind, created_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, 't')",
                params![event_id, next, configuration_id, operation_id, kind],
            )
            .map_err(|error| ConfigurationError::Storage(error.to_string()))?;
        Ok(next)
    }

    /// Return the committed revision for an exact verified-commit retry.
    /// `None` means the event id is unused and normal mutation processing may
    /// continue. A conflicting existing event is rejected by the helper.
    fn existing_atomic_commit_revision(
        transaction: &Transaction<'_>,
        event_id: &str,
        configuration_id: &str,
        operation_id: &str,
        value_digest: &str,
        credential_reference: &str,
        expected_revision: Option<i64>,
    ) -> Result<Option<i64>, ConfigurationError> {
        let Some((sequence, existing_configuration, existing_operation, existing_kind)) =
            transaction
                .query_row(
                    "SELECT sequence, configuration_id, operation_id, kind
                   FROM runtime_configuration_event WHERE event_id = ?1",
                    params![event_id],
                    |row| {
                        Ok((
                            row.get::<_, i64>(0)?,
                            row.get::<_, String>(1)?,
                            row.get::<_, String>(2)?,
                            row.get::<_, String>(3)?,
                        ))
                    },
                )
                .optional()
                .map_err(|error| ConfigurationError::Storage(error.to_string()))?
        else {
            return Ok(None);
        };
        if existing_configuration != configuration_id
            || existing_operation != operation_id
            || existing_kind != "configurationMutationCommitted"
        {
            return Err(ConfigurationError::EventIdConflict {
                event_id: event_id.to_string(),
            });
        }
        let activated_id = format!("{event_id}:activated");
        let activated_matches: bool = transaction
            .query_row(
                "SELECT COUNT(*) = 1 FROM runtime_configuration_event
                  WHERE event_id = ?1 AND configuration_id = ?2 AND operation_id = ?3
                    AND kind = 'configurationActivated'",
                params![activated_id, configuration_id, operation_id],
                |row| row.get(0),
            )
            .map_err(|error| ConfigurationError::Storage(error.to_string()))?;
        if !activated_matches {
            return Err(ConfigurationError::EventIdConflict {
                event_id: event_id.to_string(),
            });
        }
        let Some((revision, digest, state, reference)) = transaction
            .query_row(
                "SELECT revision, value_digest, state, credential_reference
                   FROM configuration WHERE configuration_id = ?1",
                params![configuration_id],
                |row| {
                    Ok((
                        row.get::<_, i64>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, String>(2)?,
                        row.get::<_, String>(3)?,
                    ))
                },
            )
            .optional()
            .map_err(|error| ConfigurationError::Storage(error.to_string()))?
        else {
            return Err(ConfigurationError::EventIdConflict {
                event_id: event_id.to_string(),
            });
        };
        let expected_result = expected_revision.map(|value| value + 1).unwrap_or(1);
        if revision != expected_result
            || digest != value_digest
            || state != "active"
            || reference != credential_reference
        {
            return Err(ConfigurationError::EventIdConflict {
                event_id: event_id.to_string(),
            });
        }
        let _ = sequence;
        Ok(Some(revision))
    }

    /// Return the committed revision for an exact deletion retry.
    fn existing_atomic_delete_revision(
        transaction: &Transaction<'_>,
        event_id: &str,
        configuration_id: &str,
        operation_id: &str,
        tombstone_digest: &str,
        expected_revision: i64,
    ) -> Result<Option<i64>, ConfigurationError> {
        let Some((_, existing_configuration, existing_operation, existing_kind)) = transaction
            .query_row(
                "SELECT sequence, configuration_id, operation_id, kind
                   FROM runtime_configuration_event WHERE event_id = ?1",
                params![event_id],
                |row| {
                    Ok((
                        row.get::<_, i64>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, String>(2)?,
                        row.get::<_, String>(3)?,
                    ))
                },
            )
            .optional()
            .map_err(|error| ConfigurationError::Storage(error.to_string()))?
        else {
            return Ok(None);
        };
        if existing_configuration != configuration_id
            || existing_operation != operation_id
            || existing_kind != "configurationDeletionCommitted"
        {
            return Err(ConfigurationError::EventIdConflict {
                event_id: event_id.to_string(),
            });
        }
        let deleted_id = format!("{event_id}:deleted");
        let deleted_matches: bool = transaction
            .query_row(
                "SELECT COUNT(*) = 1 FROM runtime_configuration_event
                  WHERE event_id = ?1 AND configuration_id = ?2 AND operation_id = ?3
                    AND kind = 'configurationDeleted'",
                params![deleted_id, configuration_id, operation_id],
                |row| row.get(0),
            )
            .map_err(|error| ConfigurationError::Storage(error.to_string()))?;
        if !deleted_matches {
            return Err(ConfigurationError::EventIdConflict {
                event_id: event_id.to_string(),
            });
        }
        let Some((revision, digest, state, reference)) = transaction
            .query_row(
                "SELECT revision, value_digest, state, credential_reference
                   FROM configuration WHERE configuration_id = ?1",
                params![configuration_id],
                |row| {
                    Ok((
                        row.get::<_, i64>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, String>(2)?,
                        row.get::<_, String>(3)?,
                    ))
                },
            )
            .optional()
            .map_err(|error| ConfigurationError::Storage(error.to_string()))?
        else {
            return Err(ConfigurationError::EventIdConflict {
                event_id: event_id.to_string(),
            });
        };
        if revision != expected_revision + 1
            || digest != tombstone_digest
            || state != "deleted"
            || !reference.is_empty()
        {
            return Err(ConfigurationError::EventIdConflict {
                event_id: event_id.to_string(),
            });
        }
        Ok(Some(revision))
    }

    // MARK: 状态机（draft→prepared→dispatched→activating→active；任意→deleted）

    /// 关闭转换表；UI 的 RuntimeConfigurationState 只由已提交事实计算。
    pub fn transition_state(
        &self,
        configuration_id: &str,
        to: &str,
    ) -> Result<(), ConfigurationError> {
        let connection = self.connection.lock().expect("configuration db poisoned");
        let current: String = connection
            .query_row(
                "SELECT state FROM configuration WHERE configuration_id = ?1",
                params![configuration_id],
                |row| row.get(0),
            )
            .map_err(|_| ConfigurationError::NotFound {
                key: configuration_id.to_string(),
            })?;
        let allowed = match (current.as_str(), to) {
            ("draft", "prepared")
            | ("draft", "deleted")
            | ("prepared", "dispatched")
            | ("prepared", "deleted")
            | ("dispatched", "activating")
            | ("dispatched", "deleted")
            | ("activating", "active")
            | ("activating", "deleted")
            | ("active", "deleted") => true,
            _ => false,
        };
        if !allowed {
            return Err(ConfigurationError::InvalidTransition {
                from: current,
                to: to.to_string(),
            });
        }
        connection
            .execute(
                "UPDATE configuration SET state = ?1, updated_at = 't' WHERE configuration_id = ?2",
                params![to, configuration_id],
            )
            .map_err(|error| ConfigurationError::Storage(error.to_string()))?;
        Ok(())
    }

    // MARK: runtime_configuration_event（configuration-scoped durable sequence）

    /// 追加事件：关闭 kind 集合校验 + 幂等（同 event_id 返回原 sequence）。
    pub fn append_event(
        &self,
        event_id: &str,
        configuration_id: &str,
        operation_id: &str,
        kind: &str,
    ) -> Result<i64, ConfigurationError> {
        if !EVENT_KINDS.contains(&kind) {
            return Err(ConfigurationError::InvalidKind {
                kind: kind.to_string(),
            });
        }
        let connection = self.connection.lock().expect("configuration db poisoned");
        if let Some((sequence, existing_configuration, existing_operation, existing_kind)) =
            connection
                .query_row(
                    "SELECT sequence, configuration_id, operation_id, kind
                   FROM runtime_configuration_event WHERE event_id = ?1",
                    params![event_id],
                    |row| {
                        Ok((
                            row.get::<_, i64>(0)?,
                            row.get::<_, String>(1)?,
                            row.get::<_, String>(2)?,
                            row.get::<_, String>(3)?,
                        ))
                    },
                )
                .optional()
                .map_err(|error| ConfigurationError::Storage(error.to_string()))?
        {
            if existing_configuration == configuration_id
                && existing_operation == operation_id
                && existing_kind == kind
            {
                return Ok(sequence);
            }
            return Err(ConfigurationError::EventIdConflict {
                event_id: event_id.to_string(),
            });
        }
        let next: i64 = connection
            .query_row(
                "SELECT COALESCE(MAX(sequence), 0) FROM runtime_configuration_event",
                [],
                |row| row.get(0),
            )
            .map_err(|error| ConfigurationError::Storage(error.to_string()))?;
        let next = next + 1;
        connection
            .execute(
                "INSERT INTO runtime_configuration_event (event_id, sequence, configuration_id, operation_id, kind, created_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, 't')",
                params![event_id, next, configuration_id, operation_id, kind],
            )
            .map_err(|error| ConfigurationError::Storage(error.to_string()))?;
        Ok(next)
    }

    /// configuration-scoped audit（按 sequence 排序）。
    pub fn events(&self, configuration_id: &str) -> Result<Vec<String>, ConfigurationError> {
        let connection = self.connection.lock().expect("configuration db poisoned");
        let mut statement = connection
            .prepare(
                "SELECT kind FROM runtime_configuration_event WHERE configuration_id = ?1 ORDER BY sequence",
            )
            .map_err(|error| ConfigurationError::Storage(error.to_string()))?;
        let rows = statement
            .query_map(params![configuration_id], |row| row.get::<_, String>(0))
            .map_err(|error| ConfigurationError::Storage(error.to_string()))?;
        let mut kinds = Vec::new();
        for row in rows {
            kinds.push(row.map_err(|error| ConfigurationError::Storage(error.to_string()))?);
        }
        Ok(kinds)
    }

    /// operation-scoped 关联查询（mutation/deletion 与 Setting/Action audit 同一 operation ID；
    /// 缺一侧由调用方投影为 NeedsReview）。
    pub fn events_by_operation(
        &self,
        operation_id: &str,
    ) -> Result<Vec<String>, ConfigurationError> {
        let connection = self.connection.lock().expect("configuration db poisoned");
        let mut statement = connection
            .prepare(
                "SELECT kind FROM runtime_configuration_event WHERE operation_id = ?1 ORDER BY sequence",
            )
            .map_err(|error| ConfigurationError::Storage(error.to_string()))?;
        let rows = statement
            .query_map(params![operation_id], |row| row.get::<_, String>(0))
            .map_err(|error| ConfigurationError::Storage(error.to_string()))?;
        let mut kinds = Vec::new();
        for row in rows {
            kinds.push(row.map_err(|error| ConfigurationError::Storage(error.to_string()))?);
        }
        Ok(kinds)
    }
}
