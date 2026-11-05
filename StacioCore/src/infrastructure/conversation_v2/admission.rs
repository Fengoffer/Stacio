//! 全局执行 Admission 表（规格 §7 执行闭环；request/lease 唯一 Scheduler 写入）。

use super::schema::ConversationV2Db;
use rusqlite::{params, Connection, OptionalExtension};
use std::sync::{Arc, Mutex};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AdmissionError {
    /// 同 Attempt 已有请求/lease（幂等返回现有，不报错；此处用于显式失败场景）
    DuplicateAttempt {
        attempt_id: String,
    },
    /// 请求不存在或已被处理
    RequestNotFound {
        request_id: String,
    },
    /// 旧 generation 操作被拒绝
    StaleGeneration {
        expected: i64,
        actual: i64,
    },
    /// lease 状态跳转非法（granted→active→releasing→released；orphaned 需 isolated 证明）
    InvalidStateTransition {
        from: String,
        to: String,
    },
    Storage(String),
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct AdmissionRequestRecord {
    pub request_id: String,
    pub conversation_id: String,
    pub turn_id: String,
    pub attempt_id: String,
    pub scheduler_generation: i64,
    pub queue_ordinal: i64,
    pub state: String,
    pub granted_lease_id: Option<String>,
    pub created_at_seconds: f64,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct AdmissionLeaseRecord {
    pub lease_id: String,
    pub request_id: String,
    pub conversation_id: String,
    pub turn_id: String,
    pub attempt_id: String,
    pub scheduler_generation: i64,
    pub state: String,
    pub settlement_id: String,
    pub acquired_at_seconds: f64,
    pub released_at_seconds: Option<f64>,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct AdmissionStateRecord {
    pub scheduler_generation: i64,
    pub next_queue_ordinal: i64,
    pub requests: Vec<AdmissionRequestRecord>,
    pub active_leases: Vec<AdmissionLeaseRecord>,
}

const LEASE_ALLOWED_TRANSITIONS: &[(&str, &str)] = &[
    ("granted", "releasing"),
    ("granted", "active"),
    ("active", "releasing"),
    ("releasing", "released"),
    ("active", "orphanedRuntime"),
    ("orphanedRuntime", "isolated"),
    ("isolated", "released"),
];

pub struct AdmissionStore {
    connection: Arc<Mutex<Connection>>,
}

impl AdmissionStore {
    pub fn new(db: &ConversationV2Db) -> Self {
        Self {
            connection: db.connection_arc(),
        }
    }

    /// Start one process generation. Work left by an older process is never
    /// treated as live capacity owned by this process: queued requests become
    /// interrupted and granted/active leases become orphaned until reconciled.
    pub fn begin_generation(&self) -> Result<i64, AdmissionError> {
        let mut connection = self.connection.lock().expect("v2 db connection poisoned");
        let transaction = connection
            .transaction()
            .map_err(|error| AdmissionError::Storage(error.to_string()))?;
        let current: i64 = transaction
            .query_row(
                "SELECT generation FROM conversation_v2_scheduler_state WHERE singleton = 1",
                [],
                |row| row.get(0),
            )
            .map_err(|error| AdmissionError::Storage(error.to_string()))?;
        let next = current.saturating_add(1);
        transaction
            .execute(
                "UPDATE conversation_v2_admission_request
                    SET state = 'interrupted'
                  WHERE scheduler_generation < ?1 AND state = 'queued'",
                params![next],
            )
            .map_err(|error| AdmissionError::Storage(error.to_string()))?;
        transaction
            .execute(
                "UPDATE conversation_v2_admission_lease
                    SET state = 'orphanedRuntime'
                  WHERE scheduler_generation < ?1 AND state IN ('granted', 'active')",
                params![next],
            )
            .map_err(|error| AdmissionError::Storage(error.to_string()))?;
        transaction
            .execute(
                "UPDATE conversation_v2_scheduler_state SET generation = ?1 WHERE singleton = 1",
                params![next],
            )
            .map_err(|error| AdmissionError::Storage(error.to_string()))?;
        transaction
            .commit()
            .map_err(|error| AdmissionError::Storage(error.to_string()))?;
        Ok(next)
    }

    pub fn load_state(&self) -> Result<AdmissionStateRecord, AdmissionError> {
        let connection = self.connection.lock().expect("v2 db connection poisoned");
        let (scheduler_generation, next_queue_ordinal): (i64, i64) = connection
            .query_row(
                "SELECT generation, next_queue_ordinal
                   FROM conversation_v2_scheduler_state WHERE singleton = 1",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .map_err(|error| AdmissionError::Storage(error.to_string()))?;

        let mut request_statement = connection
            .prepare(
                "SELECT request_id, conversation_id, turn_id, attempt_id,
                        scheduler_generation, queue_ordinal, state,
                        granted_lease_id, created_at
                   FROM conversation_v2_admission_request
                  WHERE state = 'queued'
                  ORDER BY queue_ordinal ASC",
            )
            .map_err(|error| AdmissionError::Storage(error.to_string()))?;
        let requests = request_statement
            .query_map([], |row| {
                let created_at: String = row.get(8)?;
                Ok(AdmissionRequestRecord {
                    request_id: row.get(0)?,
                    conversation_id: row.get(1)?,
                    turn_id: row.get(2)?,
                    attempt_id: row.get(3)?,
                    scheduler_generation: row.get(4)?,
                    queue_ordinal: row.get(5)?,
                    state: row.get(6)?,
                    granted_lease_id: row.get(7)?,
                    created_at_seconds: created_at.parse().unwrap_or(0.0),
                })
            })
            .map_err(|error| AdmissionError::Storage(error.to_string()))?
            .collect::<Result<Vec<_>, _>>()
            .map_err(|error| AdmissionError::Storage(error.to_string()))?;
        drop(request_statement);

        let mut lease_statement = connection
            .prepare(
                "SELECT lease_id, request_id, conversation_id, turn_id, attempt_id,
                        scheduler_generation, state, settlement_id, acquired_at, released_at
                   FROM conversation_v2_admission_lease
                  WHERE state IN ('granted', 'active', 'orphanedRuntime')
                  ORDER BY acquired_at ASC",
            )
            .map_err(|error| AdmissionError::Storage(error.to_string()))?;
        let active_leases = lease_statement
            .query_map([], |row| {
                let acquired_at: String = row.get(8)?;
                let released_at: Option<String> = row.get(9)?;
                Ok(AdmissionLeaseRecord {
                    lease_id: row.get(0)?,
                    request_id: row.get(1)?,
                    conversation_id: row.get(2)?,
                    turn_id: row.get(3)?,
                    attempt_id: row.get(4)?,
                    scheduler_generation: row.get(5)?,
                    state: row.get(6)?,
                    settlement_id: row.get::<_, Option<String>>(7)?.unwrap_or_default(),
                    acquired_at_seconds: acquired_at.parse().unwrap_or(0.0),
                    released_at_seconds: released_at.and_then(|value| value.parse().ok()),
                })
            })
            .map_err(|error| AdmissionError::Storage(error.to_string()))?
            .collect::<Result<Vec<_>, _>>()
            .map_err(|error| AdmissionError::Storage(error.to_string()))?;

        Ok(AdmissionStateRecord {
            scheduler_generation,
            next_queue_ordinal,
            requests,
            active_leases,
        })
    }

    /// Durable FIFO enqueue with the queue ordinal allocated by the store.
    pub fn enqueue_runtime(
        &self,
        request_id: &str,
        conversation_id: &str,
        turn_id: &str,
        attempt_id: &str,
        scheduler_generation: i64,
        now_seconds: f64,
    ) -> Result<AdmissionRequestRecord, AdmissionError> {
        let mut connection = self.connection.lock().expect("v2 db connection poisoned");
        let transaction = connection
            .transaction()
            .map_err(|error| AdmissionError::Storage(error.to_string()))?;
        let existing = transaction
            .query_row(
                "SELECT request_id, conversation_id, turn_id, attempt_id,
                        scheduler_generation, queue_ordinal, state,
                        granted_lease_id, created_at
                   FROM conversation_v2_admission_request
                  WHERE conversation_id = ?1 AND attempt_id = ?2",
                params![conversation_id, attempt_id],
                |row| {
                    let created_at: String = row.get(8)?;
                    Ok(AdmissionRequestRecord {
                        request_id: row.get(0)?,
                        conversation_id: row.get(1)?,
                        turn_id: row.get(2)?,
                        attempt_id: row.get(3)?,
                        scheduler_generation: row.get(4)?,
                        queue_ordinal: row.get(5)?,
                        state: row.get(6)?,
                        granted_lease_id: row.get(7)?,
                        created_at_seconds: created_at.parse().unwrap_or(0.0),
                    })
                },
            )
            .optional()
            .map_err(|error| AdmissionError::Storage(error.to_string()))?;
        if let Some(existing) = existing {
            transaction
                .commit()
                .map_err(|error| AdmissionError::Storage(error.to_string()))?;
            return Ok(existing);
        }

        let (actual_generation, queue_ordinal): (i64, i64) = transaction
            .query_row(
                "SELECT generation, next_queue_ordinal
                   FROM conversation_v2_scheduler_state WHERE singleton = 1",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .map_err(|error| AdmissionError::Storage(error.to_string()))?;
        if actual_generation != scheduler_generation {
            return Err(AdmissionError::StaleGeneration {
                expected: actual_generation,
                actual: scheduler_generation,
            });
        }
        transaction
            .execute(
                "UPDATE conversation_v2_scheduler_state
                    SET next_queue_ordinal = next_queue_ordinal + 1
                  WHERE singleton = 1",
                [],
            )
            .map_err(|error| AdmissionError::Storage(error.to_string()))?;
        let created_at = now_seconds.to_string();
        transaction
            .execute(
                "INSERT INTO conversation_v2_admission_request
                   (request_id, conversation_id, turn_id, attempt_id,
                    scheduler_generation, queue_ordinal, state, created_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'queued', ?7)",
                params![
                    request_id,
                    conversation_id,
                    turn_id,
                    attempt_id,
                    scheduler_generation,
                    queue_ordinal,
                    created_at
                ],
            )
            .map_err(|error| AdmissionError::Storage(error.to_string()))?;
        transaction
            .commit()
            .map_err(|error| AdmissionError::Storage(error.to_string()))?;
        Ok(AdmissionRequestRecord {
            request_id: request_id.to_string(),
            conversation_id: conversation_id.to_string(),
            turn_id: turn_id.to_string(),
            attempt_id: attempt_id.to_string(),
            scheduler_generation,
            queue_ordinal,
            state: "queued".to_string(),
            granted_lease_id: None,
            created_at_seconds: now_seconds,
        })
    }

    /// 入队：同 Attempt 重复请求幂等（不占两个名额）——返回现有请求 ID。
    pub fn enqueue(
        &self,
        request_id: &str,
        conversation_id: &str,
        turn_id: &str,
        attempt_id: &str,
        scheduler_generation: i64,
        queue_ordinal: i64,
    ) -> Result<String, AdmissionError> {
        let connection = self.connection.lock().expect("v2 db connection poisoned");
        let existing: Option<String> = connection
            .query_row(
                "SELECT request_id FROM conversation_v2_admission_request
                   WHERE conversation_id = ?1 AND attempt_id = ?2",
                params![conversation_id, attempt_id],
                |row| row.get(0),
            )
            .ok();
        if let Some(existing_id) = existing {
            return Ok(existing_id); // 幂等：不占两个名额
        }
        connection
            .execute(
                "INSERT INTO conversation_v2_admission_request
                   (request_id, conversation_id, turn_id, attempt_id, scheduler_generation, queue_ordinal, state, created_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'queued', 't')",
                params![request_id, conversation_id, turn_id, attempt_id, scheduler_generation, queue_ordinal],
            )
            .map_err(|error| AdmissionError::Storage(error.to_string()))?;
        Ok(request_id.to_string())
    }

    /// grant：queued → granted（生成 lease）。
    pub fn grant(
        &self,
        request_id: &str,
        attempt_id: &str,
        scheduler_generation: i64,
    ) -> Result<String, AdmissionError> {
        self.grant_at(request_id, attempt_id, scheduler_generation, "t")
            .map(|record| record.lease_id)
    }

    pub fn grant_runtime(
        &self,
        request_id: &str,
        attempt_id: &str,
        scheduler_generation: i64,
        now_seconds: f64,
    ) -> Result<AdmissionLeaseRecord, AdmissionError> {
        self.grant_at(
            request_id,
            attempt_id,
            scheduler_generation,
            now_seconds.to_string().as_str(),
        )
    }

    fn grant_at(
        &self,
        request_id: &str,
        attempt_id: &str,
        scheduler_generation: i64,
        acquired_at: &str,
    ) -> Result<AdmissionLeaseRecord, AdmissionError> {
        let mut connection = self.connection.lock().expect("v2 db connection poisoned");
        let transaction = connection
            .transaction()
            .map_err(|error| AdmissionError::Storage(error.to_string()))?;

        let (conversation_id, turn_id, generation): (String, String, i64) = transaction
            .query_row(
                "SELECT conversation_id, turn_id, scheduler_generation FROM conversation_v2_admission_request
                  WHERE request_id = ?1 AND state = 'queued'",
                params![request_id],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .map_err(|_| AdmissionError::RequestNotFound {
                request_id: request_id.to_string(),
            })?;
        if generation != scheduler_generation {
            return Err(AdmissionError::StaleGeneration {
                expected: generation,
                actual: scheduler_generation,
            });
        }

        let lease_id = format!("lease-{request_id}");
        transaction
            .execute(
                "INSERT INTO conversation_v2_admission_lease
                   (lease_id, request_id, conversation_id, turn_id, attempt_id, scheduler_generation, state, settlement_id, acquired_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'granted', ?7, ?8)",
                params![lease_id, request_id, conversation_id, turn_id, attempt_id, generation, format!("settle-{request_id}"), acquired_at],
            )
            .map_err(|error| AdmissionError::Storage(error.to_string()))?;
        transaction
            .execute(
                "UPDATE conversation_v2_admission_request SET state = 'granted', granted_lease_id = ?1 WHERE request_id = ?2",
                params![lease_id, request_id],
            )
            .map_err(|error| AdmissionError::Storage(error.to_string()))?;
        transaction
            .commit()
            .map_err(|error| AdmissionError::Storage(error.to_string()))?;
        Ok(AdmissionLeaseRecord {
            lease_id,
            request_id: request_id.to_string(),
            conversation_id,
            turn_id,
            attempt_id: attempt_id.to_string(),
            scheduler_generation: generation,
            state: "granted".to_string(),
            settlement_id: format!("settle-{request_id}"),
            acquired_at_seconds: acquired_at.parse().unwrap_or(0.0),
            released_at_seconds: None,
        })
    }

    /// lease 状态跳转：generation 校验 + 状态约束。
    pub fn transition_lease(
        &self,
        lease_id: &str,
        from: &str,
        to: &str,
        scheduler_generation: i64,
    ) -> Result<(), AdmissionError> {
        let connection = self.connection.lock().expect("v2 db connection poisoned");
        let (actual_generation, current_state): (i64, String) = connection
            .query_row(
                "SELECT scheduler_generation, state FROM conversation_v2_admission_lease WHERE lease_id = ?1",
                params![lease_id],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .map_err(|error| AdmissionError::Storage(error.to_string()))?;
        if actual_generation != scheduler_generation {
            return Err(AdmissionError::StaleGeneration {
                expected: actual_generation,
                actual: scheduler_generation,
            });
        }
        if current_state != from {
            return Err(AdmissionError::InvalidStateTransition {
                from: current_state,
                to: to.to_string(),
            });
        }
        let allowed = LEASE_ALLOWED_TRANSITIONS
            .iter()
            .any(|(allowed_from, allowed_to)| *allowed_from == from && *allowed_to == to);
        if !allowed {
            return Err(AdmissionError::InvalidStateTransition {
                from: from.to_string(),
                to: to.to_string(),
            });
        }
        connection
            .execute(
                "UPDATE conversation_v2_admission_lease SET state = ?1, released_at = CASE WHEN ?1 = 'released' THEN 't' ELSE released_at END WHERE lease_id = ?2",
                params![to, lease_id],
            )
            .map_err(|error| AdmissionError::Storage(error.to_string()))?;
        Ok(())
    }

    pub fn cancel_request(
        &self,
        request_id: &str,
        scheduler_generation: i64,
    ) -> Result<bool, AdmissionError> {
        self.resolve_queued_request(request_id, scheduler_generation, "cancelled")
    }

    pub fn expire_request(
        &self,
        request_id: &str,
        scheduler_generation: i64,
    ) -> Result<bool, AdmissionError> {
        self.resolve_queued_request(request_id, scheduler_generation, "interrupted")
    }

    fn resolve_queued_request(
        &self,
        request_id: &str,
        scheduler_generation: i64,
        state: &str,
    ) -> Result<bool, AdmissionError> {
        let connection = self.connection.lock().expect("v2 db connection poisoned");
        let changed = connection
            .execute(
                "UPDATE conversation_v2_admission_request
                    SET state = ?1
                  WHERE request_id = ?2 AND scheduler_generation = ?3 AND state = 'queued'",
                params![state, request_id, scheduler_generation],
            )
            .map_err(|error| AdmissionError::Storage(error.to_string()))?;
        Ok(changed == 1)
    }

    /// Release a lease only after the owning bridge has settled its runtime.
    /// Orphaned leases intentionally fail closed and require explicit isolation.
    pub fn release_runtime(
        &self,
        lease_id: &str,
        scheduler_generation: i64,
        now_seconds: f64,
    ) -> Result<bool, AdmissionError> {
        let mut connection = self.connection.lock().expect("v2 db connection poisoned");
        let transaction = connection
            .transaction()
            .map_err(|error| AdmissionError::Storage(error.to_string()))?;
        let (actual_generation, state): (i64, String) = transaction
            .query_row(
                "SELECT scheduler_generation, state
                   FROM conversation_v2_admission_lease WHERE lease_id = ?1",
                params![lease_id],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .map_err(|error| AdmissionError::Storage(error.to_string()))?;
        if actual_generation != scheduler_generation {
            return Err(AdmissionError::StaleGeneration {
                expected: actual_generation,
                actual: scheduler_generation,
            });
        }
        if state == "released" {
            transaction
                .commit()
                .map_err(|error| AdmissionError::Storage(error.to_string()))?;
            return Ok(false);
        }
        if state == "orphanedRuntime" {
            return Err(AdmissionError::InvalidStateTransition {
                from: state,
                to: "released".to_string(),
            });
        }
        if state != "granted" && state != "active" && state != "releasing" {
            return Err(AdmissionError::InvalidStateTransition {
                from: state,
                to: "released".to_string(),
            });
        }
        transaction
            .execute(
                "UPDATE conversation_v2_admission_lease SET state = 'releasing' WHERE lease_id = ?1",
                params![lease_id],
            )
            .map_err(|error| AdmissionError::Storage(error.to_string()))?;
        transaction
            .execute(
                "UPDATE conversation_v2_admission_lease
                    SET state = 'released', released_at = ?1
                  WHERE lease_id = ?2 AND state = 'releasing'",
                params![now_seconds.to_string(), lease_id],
            )
            .map_err(|error| AdmissionError::Storage(error.to_string()))?;
        transaction
            .commit()
            .map_err(|error| AdmissionError::Storage(error.to_string()))?;
        Ok(true)
    }
}
