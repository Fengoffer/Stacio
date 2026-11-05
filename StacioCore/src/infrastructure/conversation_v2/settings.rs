//! AssistantSettingsStore Rust 后端（P3-11，独立设置域存储）。
//!
//! - `setting_value`：expected-revision CAS、typed value digest、scope、migrationKey；
//! - `assistant_settings_event`：关闭 kind 集合、operation-scoped durable sequence 单写入；
//! - settled 事件必须有前置证据（settingMutationSettled←committed、actionSettled←requested），
//!   防止 Permit 已结算但异步 Action 未取得业务结果时提前写 actionSettled；
//! - 存储域边界：本库与 conversation v2 库分离，清空会话后 Settings 仍独立存在。

use rusqlite::{params, Connection};
use std::sync::{Arc, Mutex};

const SETTINGS_INIT_SQL: &str = include_str!("../../../migrations/settings_v2_0001_init.sql");

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SettingsError {
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
    SettledWithoutEvidence {
        kind: String,
        operation_id: String,
    },
    InvalidKind {
        kind: String,
    },
    Storage(String),
}

/// 关闭 kind 集合（计划 P3-11 Step 1）。
const EVENT_KINDS: &[&str] = &[
    "settingMutationRequested",
    "settingMutationCommitted",
    "settingMutationCancelled",
    "settingMutationFailed",
    "settingMutationSettled",
    "actionRequested",
    "actionCancelled",
    "actionFailed",
    "actionReconciliationRequired",
    "actionSettled",
    "exportManifestCreated",
    "maintenanceFenceAcquired",
    "maintenanceFenceReleased",
];

pub struct SettingsDb {
    connection: Arc<Mutex<Connection>>,
}

impl SettingsDb {
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
        self.connection.lock().expect("settings db poisoned")
    }

    pub fn connection_arc(&self) -> Arc<Mutex<Connection>> {
        Arc::clone(&self.connection)
    }

    fn apply_migrations(&self) -> rusqlite::Result<()> {
        self.connection().execute_batch(SETTINGS_INIT_SQL)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SettingMetadata {
    pub revision: i64,
    pub value_digest: String,
    pub scope: String,
    pub migration_key: String,
}

pub struct SettingsStore {
    connection: Arc<Mutex<Connection>>,
}

impl SettingsStore {
    pub fn new(db: &SettingsDb) -> Self {
        Self {
            connection: db.connection_arc(),
        }
    }

    // MARK: setting 值表（expected-revision CAS）

    /// 写入/更新 setting：`expected_revision` 为 Some 时必须匹配当前 revision；
    /// None 仅允许创建（已存在 → KeyExists）。
    pub fn upsert_setting(
        &self,
        key: &str,
        expected_revision: Option<i64>,
        value_digest: &str,
        scope: &str,
        migration_key: &str,
    ) -> Result<(), SettingsError> {
        let connection = self.connection.lock().expect("settings db poisoned");
        let current: Option<(i64, String)> = connection
            .query_row(
                "SELECT revision, value_digest FROM setting_value WHERE setting_key = ?1",
                params![key],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .ok();
        match (expected_revision, current) {
            (None, Some(_)) => Err(SettingsError::KeyExists {
                key: key.to_string(),
            }),
            (None, None) => {
                connection
                    .execute(
                        "INSERT INTO setting_value (setting_key, revision, value_digest, scope, migration_key, updated_at)
                         VALUES (?1, 1, ?2, ?3, ?4, 't')",
                        params![key, value_digest, scope, migration_key],
                    )
                    .map_err(|error| SettingsError::Storage(error.to_string()))?;
                Ok(())
            }
            (Some(expected), Some((current_revision, _))) => {
                if expected != current_revision {
                    return Err(SettingsError::StaleRevision {
                        key: key.to_string(),
                        expected,
                        current: current_revision,
                    });
                }
                // 防御性 CAS：UPDATE 携带 revision 条件（当前 Mutex 串行已保证，防未来并发模型回归）
                let updated = connection
                    .execute(
                        "UPDATE setting_value SET revision = revision + 1, value_digest = ?2, scope = ?3, migration_key = ?4, updated_at = 't'
                         WHERE setting_key = ?1 AND revision = ?5",
                        params![key, value_digest, scope, migration_key, expected],
                    )
                    .map_err(|error| SettingsError::Storage(error.to_string()))?;
                if updated == 0 {
                    return Err(SettingsError::StaleRevision {
                        key: key.to_string(),
                        expected,
                        current: current_revision,
                    });
                }
                Ok(())
            }
            (Some(expected), None) => Err(SettingsError::StaleRevision {
                key: key.to_string(),
                expected,
                current: 0,
            }),
        }
    }

    pub fn setting_value(&self, key: &str) -> Result<Option<(i64, String)>, SettingsError> {
        let connection = self.connection.lock().expect("settings db poisoned");
        connection
            .query_row(
                "SELECT revision, value_digest FROM setting_value WHERE setting_key = ?1",
                params![key],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .map(Some)
            .or_else(|error| match error {
                rusqlite::Error::QueryReturnedNoRows => Ok(None),
                other => Err(SettingsError::Storage(other.to_string())),
            })
    }

    pub fn setting_metadata(&self, key: &str) -> Result<Option<SettingMetadata>, SettingsError> {
        let connection = self.connection.lock().expect("settings db poisoned");
        connection
            .query_row(
                "SELECT revision, value_digest, scope, migration_key FROM setting_value WHERE setting_key = ?1",
                params![key],
                |row| {
                    Ok(SettingMetadata {
                        revision: row.get(0)?,
                        value_digest: row.get(1)?,
                        scope: row.get(2)?,
                        migration_key: row.get(3)?,
                    })
                },
            )
            .map(Some)
            .or_else(|error| match error {
                rusqlite::Error::QueryReturnedNoRows => Ok(None),
                other => Err(SettingsError::Storage(other.to_string())),
            })
    }

    /// 返回所有已提交 setting key，供 sidecar 恢复时做双向一致性检查。
    /// 只返回 key，不暴露值正文或 digest。
    pub fn setting_keys(&self) -> Result<Vec<String>, SettingsError> {
        let connection = self.connection.lock().expect("settings db poisoned");
        let mut statement = connection
            .prepare("SELECT setting_key FROM setting_value ORDER BY setting_key")
            .map_err(|error| SettingsError::Storage(error.to_string()))?;
        let rows = statement
            .query_map([], |row| row.get::<_, String>(0))
            .map_err(|error| SettingsError::Storage(error.to_string()))?;
        let mut keys = Vec::new();
        for row in rows {
            keys.push(row.map_err(|error| SettingsError::Storage(error.to_string()))?);
        }
        Ok(keys)
    }

    // MARK: assistant_settings_event（durable sequence 单写入）

    /// 追加事件：关闭 kind 集合校验 + settled 前置证据校验 + 幂等（同 event_id 返回原 sequence）。
    pub fn append_event(
        &self,
        event_id: &str,
        operation_id: &str,
        kind: &str,
    ) -> Result<i64, SettingsError> {
        if !EVENT_KINDS.contains(&kind) {
            return Err(SettingsError::InvalidKind {
                kind: kind.to_string(),
            });
        }
        let connection = self.connection.lock().expect("settings db poisoned");

        // 幂等：同 event_id 已存在 → 返回原 sequence
        if let Some(sequence) = connection
            .query_row(
                "SELECT sequence FROM assistant_settings_event WHERE event_id = ?1",
                params![event_id],
                |row| row.get::<_, i64>(0),
            )
            .ok()
        {
            return Ok(sequence);
        }

        // settled 前置证据：不允许无证据提前写 settled
        let requires_evidence: Option<&str> = match kind {
            "settingMutationSettled" => Some("settingMutationCommitted"),
            "actionSettled" => Some("actionRequested"),
            _ => None,
        };
        if let Some(required_kind) = requires_evidence {
            let has_evidence: i64 = connection
                .query_row(
                    "SELECT COUNT(*) FROM assistant_settings_event
                     WHERE operation_id = ?1 AND kind = ?2",
                    params![operation_id, required_kind],
                    |row| row.get(0),
                )
                .map_err(|error| SettingsError::Storage(error.to_string()))?;
            if has_evidence == 0 {
                return Err(SettingsError::SettledWithoutEvidence {
                    kind: kind.to_string(),
                    operation_id: operation_id.to_string(),
                });
            }
        }

        let next = self.next_sequence_locked(&connection)?;
        connection
            .execute(
                "INSERT INTO assistant_settings_event (event_id, sequence, operation_id, kind, created_at)
                 VALUES (?1, ?2, ?3, ?4, 't')",
                params![event_id, next, operation_id, kind],
            )
            .map_err(|error| SettingsError::Storage(error.to_string()))?;
        Ok(next)
    }

    /// 当前 durable sequence 的下一个值（单写入：调用方持锁）。
    fn next_sequence_locked(&self, connection: &Connection) -> Result<i64, SettingsError> {
        let max: i64 = connection
            .query_row(
                "SELECT COALESCE(MAX(sequence), 0) FROM assistant_settings_event",
                [],
                |row| row.get(0),
            )
            .map_err(|error| SettingsError::Storage(error.to_string()))?;
        Ok(max + 1)
    }

    pub fn next_sequence(&self) -> Result<i64, SettingsError> {
        let connection = self.connection.lock().expect("settings db poisoned");
        self.next_sequence_locked(&connection)
    }

    /// operation-scoped audit（按 sequence 排序）。
    pub fn events(&self, operation_id: &str) -> Result<Vec<String>, SettingsError> {
        let connection = self.connection.lock().expect("settings db poisoned");
        let mut statement = connection
            .prepare(
                "SELECT kind FROM assistant_settings_event WHERE operation_id = ?1 ORDER BY sequence",
            )
            .map_err(|error| SettingsError::Storage(error.to_string()))?;
        let rows = statement
            .query_map(params![operation_id], |row| row.get::<_, String>(0))
            .map_err(|error| SettingsError::Storage(error.to_string()))?;
        let mut kinds = Vec::new();
        for row in rows {
            kinds.push(row.map_err(|error| SettingsError::Storage(error.to_string()))?);
        }
        Ok(kinds)
    }
}
