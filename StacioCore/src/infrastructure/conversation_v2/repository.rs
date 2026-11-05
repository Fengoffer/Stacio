//! Repository 事务与 outbox（规格 §15.1：单事务原子提交）。

use super::schema::ConversationV2Db;
use super::sequence::{CandidateValidationError, EnvelopeCandidate, SequenceValidator};
use rusqlite::{params, Connection, OptionalExtension};
use std::collections::HashSet;
use std::sync::{Arc, Mutex};

/// 单条加密投影（Turn/Session 快照）。
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ProjectionValue {
    pub key: String,
    pub payload_cipher: Vec<u8>,
    pub payload_cipher_version: String,
    pub payload_byte_length: i64,
}

/// Effect outbox 条目（稳定 effect ID / operation ID / 幂等键 / authority 重验 / Permit decision）。
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct OutboxItem {
    pub item_id: String,
    pub effect_id: String,
    pub operation_id: String,
    pub idempotency_key: String,
    pub command_kind: String,
    pub command_payload: Vec<u8>,
    pub authority_lease_id: Option<String>,
    pub capability_generation: Option<i64>,
    pub permit_commit_decision: Option<String>,
}

/// Durable dispatch projection for an effect outbox row.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct LoadedOutboxRecord {
    pub item_id: String,
    pub effect_id: String,
    pub operation_id: String,
    pub idempotency_key: String,
    pub command_kind: String,
    pub command_payload: Vec<u8>,
    pub authority_lease_id: Option<String>,
    pub capability_generation: Option<i64>,
    pub permit_commit_decision: Option<String>,
    pub status: String,
    pub dispatch_token: Option<String>,
    pub dispatched_at: Option<String>,
    pub settlement_outcome: Option<String>,
    pub settled_at: Option<String>,
    pub reconciliation_reason: Option<String>,
}

/// Non-sensitive session index row. Conversation content and display metadata
/// remain encrypted in the event stream; this record is only used to discover
/// sessions and order them before on-demand decryption.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct LoadedConversationSessionRecord {
    pub conversation_id: String,
    pub schema_version: i64,
    pub created_at: String,
    pub updated_at: String,
    pub is_corrupted: bool,
}

/// 一次事务提交请求。
#[derive(Debug, Clone, uniffi::Record)]
pub struct CommitRequest {
    pub conversation_id: String,
    pub expected_last_sequence: i64,
    pub candidates: Vec<EnvelopeCandidate>,
    pub projections: Vec<ProjectionValue>,
    pub outbox: Vec<OutboxItem>,
    /// 必须已存在的 reserved credential binding 引用（无有效 reservation 拒绝提交）。
    pub required_reservations: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CommitOutcome {
    /// snapshotAtSequence = 批次最后一个 candidate sequence
    pub snapshot_at_sequence: i64,
    pub committed_outbox: Vec<OutboxItem>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CommitError {
    ExpectedMismatch {
        expected: i64,
        actual_last: i64,
    },
    Validation(CandidateValidationError),
    ReservationMissing {
        binding_id: String,
    },
    /// 同 sequence 出现不同 event/hash → 只读损坏隔离。
    CorruptionDetected {
        sequence: i64,
    },
    /// A verified compaction watermark exists, but the Swift replay layer has
    /// no authenticated snapshot projection to use as its replay baseline.
    /// Returning this explicitly is safer than pretending the first retained
    /// event is sequence 1 and rebuilding an incomplete conversation.
    CompactionBaselineRequired {
        watermark: i64,
    },
    Storage(String),
}

pub struct ConversationV2Repository {
    connection: Arc<Mutex<Connection>>,
}

impl ConversationV2Repository {
    pub fn new(db: &ConversationV2Db) -> Self {
        Self {
            connection: db.connection_arc(),
        }
    }

    /// 单事务提交：expected 校验 → candidate range → Event append → 加密投影 → outbox → reservation 强制。
    /// 事务失败时任何动作不可见（禁止部分提交/预留空洞/补写空事件）。
    /// 损坏隔离例外：`CorruptionDetected` 的损坏记录在独立事务落盘（持久只读事实，不受回滚影响）。
    pub fn commit(&self, request: &CommitRequest) -> Result<CommitOutcome, CommitError> {
        let mut connection = self.connection.lock().expect("v2 db connection poisoned");
        let transaction = connection
            .transaction()
            .map_err(|error| CommitError::Storage(error.to_string()))?;

        let result = self.commit_inner(&transaction, request);
        match result {
            Ok(outcome) => {
                transaction
                    .commit()
                    .map_err(|error| CommitError::Storage(error.to_string()))?;
                Ok(outcome)
            }
            Err(CommitError::CorruptionDetected { sequence }) => {
                // 主事务回滚（不留下任何部分提交），损坏记录在独立事务落盘
                let _ = transaction.rollback();
                let _ = connection.execute(
                    "INSERT OR REPLACE INTO conversation_v2_corruption (conversation_id, reason, sequence, created_at)
                     VALUES (?1, 'same sequence with different event/hash', ?2, 't')",
                    params![request.conversation_id, sequence],
                );
                Err(CommitError::CorruptionDetected { sequence })
            }
            Err(error) => {
                let _ = transaction.rollback();
                Err(error)
            }
        }
    }

    fn commit_inner(
        &self,
        transaction: &rusqlite::Transaction<'_>,
        request: &CommitRequest,
    ) -> Result<CommitOutcome, CommitError> {
        let conversation_id = &request.conversation_id;

        let corruption_sequence: Option<i64> = transaction
            .query_row(
                "SELECT sequence FROM conversation_v2_corruption WHERE conversation_id = ?1",
                params![conversation_id],
                |row| row.get(0),
            )
            .optional()
            .map_err(|error| CommitError::Storage(error.to_string()))?;
        if let Some(sequence) = corruption_sequence {
            return Err(CommitError::CorruptionDetected { sequence });
        }

        if request.candidates.is_empty() {
            return Err(CommitError::Validation(
                CandidateValidationError::EmptyBatch,
            ));
        }

        let first_candidate_at = request
            .candidates
            .first()
            .map(|candidate| candidate.created_at.as_str())
            .ok_or(CommitError::Validation(CandidateValidationError::EmptyBatch))?;
        let last_candidate_at = request
            .candidates
            .last()
            .map(|candidate| candidate.created_at.as_str())
            .ok_or(CommitError::Validation(CandidateValidationError::EmptyBatch))?;

        // 0) 确保会话行存在。这里只保存非敏感时间索引；标题、目标和
        // Runtime 等元数据仍在 Swift 加密后的事件 payload 中。
        transaction
            .execute(
                "INSERT OR IGNORE INTO conversation_v2_session (conversation_id, schema_version, created_at, updated_at)
                 VALUES (?1, 1, ?2, ?2)",
                params![conversation_id, first_candidate_at],
            )
            .map_err(|error| CommitError::Storage(error.to_string()))?;

        // 1) 读库内 lastApplied
        let actual_last: i64 = transaction
            .query_row(
                "SELECT COALESCE(MAX(sequence), 0) FROM conversation_v2_event WHERE conversation_id = ?1",
                params![conversation_id],
                |row| row.get(0),
            )
            .map_err(|error| CommitError::Storage(error.to_string()))?;

        // 2) reserved binding 强制（事务内）
        for binding_id in &request.required_reservations {
            let valid: bool = transaction
                .query_row(
                    "SELECT state = 'reserved' FROM conversation_v2_reservation WHERE binding_id = ?1",
                    params![binding_id],
                    |row| row.get::<_, bool>(0),
                )
                .map_err(|error| CommitError::Storage(error.to_string()))
                .unwrap_or(false);
            if !valid {
                return Err(CommitError::ReservationMissing {
                    binding_id: binding_id.clone(),
                });
            }
        }

        // A complete replay of an already committed batch is idempotent even if
        // the caller still carries the original expected sequence. Mixed
        // duplicate/new batches remain ordinary optimistic-concurrency conflicts.
        let all_candidates_idempotent = request.candidates.iter().all(|candidate| {
            transaction
                .query_row(
                    "SELECT event_id, payload_hash, event_type, write_class, source, created_at,
                            visibility, payload_cipher_version, payload_byte_length
                       FROM conversation_v2_event
                      WHERE conversation_id = ?1 AND sequence = ?2",
                    params![conversation_id, candidate.sequence],
                    |row| {
                        Ok((
                            row.get::<_, String>(0)?,
                            row.get::<_, String>(1)?,
                            row.get::<_, String>(2)?,
                            row.get::<_, String>(3)?,
                            row.get::<_, String>(4)?,
                            row.get::<_, String>(5)?,
                            row.get::<_, String>(6)?,
                            row.get::<_, Option<String>>(7)?,
                            row.get::<_, Option<i64>>(8)?,
                        ))
                    },
                )
                .optional()
                .ok()
                .flatten()
                .map(
                    |(
                        event_id,
                        payload_hash,
                        event_type,
                        write_class,
                        source,
                        created_at,
                        visibility,
                        payload_cipher_version,
                        payload_byte_length,
                    )| {
                        event_id == candidate.event_id
                            && payload_hash == candidate.payload_hash
                            && event_type == candidate.event_type
                            && write_class == candidate.write_class
                            && source == candidate.source
                            && created_at == candidate.created_at
                            && visibility == candidate.visibility
                            && payload_cipher_version == candidate.payload_cipher_version
                            && payload_byte_length == candidate.payload_byte_length
                    },
                )
                .unwrap_or(false)
        });

        // 3) expected 校验：调用方基于过期 lastApplied 提交 = 并发冲突（ExpectedMismatch），
        //    但完整重复批次已经在上面证明是同一持久事实，因此允许幂等继续。
        if !all_candidates_idempotent && actual_last != request.expected_last_sequence {
            return Err(CommitError::ExpectedMismatch {
                expected: request.expected_last_sequence,
                actual_last,
            });
        }

        // 4) 逐条幂等/损坏判定（同 sequence 同 hash 的重复投递幂等忽略，
        //    同 sequence 不同 hash 隔离损坏）
        let mut new_candidates: Vec<EnvelopeCandidate> = Vec::new();
        for candidate in &request.candidates {
            let existing: Option<(
                String,
                String,
                String,
                String,
                String,
                String,
                String,
                Option<String>,
                Option<i64>,
            )> = transaction
                .query_row(
                    "SELECT event_id, payload_hash, event_type, write_class, source, created_at,
                            visibility, payload_cipher_version, payload_byte_length
                       FROM conversation_v2_event
                      WHERE conversation_id = ?1 AND sequence = ?2",
                    params![conversation_id, candidate.sequence],
                    |row| {
                        Ok((
                            row.get(0)?,
                            row.get(1)?,
                            row.get(2)?,
                            row.get(3)?,
                            row.get(4)?,
                            row.get(5)?,
                            row.get(6)?,
                            row.get(7)?,
                            row.get(8)?,
                        ))
                    },
                )
                .optional()
                .map_err(|error| CommitError::Storage(error.to_string()))?;
            match existing {
                None => new_candidates.push(candidate.clone()),
                Some((
                    existing_id,
                    existing_hash,
                    existing_type,
                    existing_write_class,
                    existing_source,
                    existing_created_at,
                    existing_visibility,
                    existing_payload_cipher_version,
                    existing_payload_byte_length,
                )) => {
                    if existing_id == candidate.event_id
                        && existing_hash == candidate.payload_hash
                        && existing_type == candidate.event_type
                        && existing_write_class == candidate.write_class
                        && existing_source == candidate.source
                        && existing_created_at == candidate.created_at
                        && existing_visibility == candidate.visibility
                        && existing_payload_cipher_version == candidate.payload_cipher_version
                        && existing_payload_byte_length == candidate.payload_byte_length
                    {
                        continue; // 幂等忽略：不重复 append
                    }
                    // 损坏记录由 commit() 在独立事务落盘（主事务回滚后仍保留只读隔离事实）
                    return Err(CommitError::CorruptionDetected {
                        sequence: candidate.sequence,
                    });
                }
            }
        }

        let mut snapshot_at_sequence = actual_last;
        if !new_candidates.is_empty() {
            // 5) candidate range 校验（整批回滚；expected 已在上方校验）
            let batch = super::sequence::CandidateBatch {
                expected_last_sequence: request.expected_last_sequence,
                candidates: new_candidates.clone(),
            };
            snapshot_at_sequence = SequenceValidator::validate_batch(actual_last, &batch)
                .map_err(CommitError::Validation)?;

            // 5) Event append
            for candidate in &new_candidates {
                transaction
                    .execute(
                        "INSERT INTO conversation_v2_event
                           (conversation_id, sequence, event_id, event_type, write_class, source, created_at,
                            payload_cipher, payload_cipher_version, payload_byte_length, payload_hash, status, visibility)
                         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, 'applied', ?12)",
                        params![
                            conversation_id,
                            candidate.sequence,
                            candidate.event_id,
                            candidate.event_type,
                            candidate.write_class,
                            candidate.source,
                            candidate.created_at,
                            candidate.payload_cipher,
                            candidate.payload_cipher_version,
                            candidate.payload_byte_length,
                            candidate.payload_hash,
                            candidate.visibility
                        ],
                    )
                    .map_err(|error| CommitError::Storage(error.to_string()))?;
            }
        }

        // 6) 加密投影 upsert
        let mut projection_keys = HashSet::new();
        for projection in &request.projections {
            if projection.key.trim().is_empty()
                || !projection_keys.insert(projection.key.clone())
                || projection.payload_cipher.is_empty()
                || projection.payload_cipher_version.trim().is_empty()
                || projection.payload_byte_length <= 0
                || projection.payload_byte_length != projection.payload_cipher.len() as i64
            {
                return Err(CommitError::Validation(
                    CandidateValidationError::InvalidEnvelopeField {
                        field: "projection",
                    },
                ));
            }
            transaction
                .execute(
                    "INSERT OR REPLACE INTO conversation_v2_projection
                       (conversation_id, projection_key, payload_cipher, payload_cipher_version, payload_byte_length, updated_at)
                     VALUES (?1, ?2, ?3, ?4, ?5, 't')",
                    params![
                        conversation_id,
                        projection.key,
                        projection.payload_cipher,
                        projection.payload_cipher_version,
                        projection.payload_byte_length
                    ],
                )
                .map_err(|error| CommitError::Storage(error.to_string()))?;
        }

        // 7) outbox append.  Idempotency is a value contract, not a best-effort
        // INSERT OR IGNORE: a retry with the same logical identity must carry
        // exactly the same command and authority metadata.  Any mismatch is
        // treated as corruption instead of silently dropping the new command.
        for item in &request.outbox {
            let matching_count: i64 = transaction
                .query_row(
                    "SELECT COUNT(*) FROM conversation_v2_outbox
                      WHERE conversation_id = ?1
                        AND (item_id = ?2 OR effect_id = ?3 OR idempotency_key = ?4)",
                    params![
                        conversation_id,
                        item.item_id,
                        item.effect_id,
                        item.idempotency_key
                    ],
                    |row| row.get(0),
                )
                .map_err(|error| CommitError::Storage(error.to_string()))?;
            if matching_count > 1 {
                return Err(CommitError::CorruptionDetected {
                    sequence: actual_last,
                });
            }
            let existing: Option<(
                String,
                String,
                String,
                String,
                Option<String>,
                Option<i64>,
                Option<String>,
                String,
                Vec<u8>,
            )> = transaction
                .query_row(
                    "SELECT o.item_id, o.effect_id, o.operation_id, o.idempotency_key,
                            o.authority_lease_id, o.capability_generation,
                            o.permit_commit_decision, d.command_kind, d.command_payload
                       FROM conversation_v2_outbox o
                       JOIN conversation_v2_outbox_dispatch d
                         ON d.conversation_id = o.conversation_id AND d.item_id = o.item_id
                      WHERE o.conversation_id = ?1
                        AND (o.item_id = ?2 OR o.effect_id = ?3 OR o.idempotency_key = ?4)
                      LIMIT 1",
                    params![
                        conversation_id,
                        item.item_id,
                        item.effect_id,
                        item.idempotency_key
                    ],
                    |row| {
                        Ok((
                            row.get(0)?,
                            row.get(1)?,
                            row.get(2)?,
                            row.get(3)?,
                            row.get(4)?,
                            row.get(5)?,
                            row.get(6)?,
                            row.get(7)?,
                            row.get(8)?,
                        ))
                    },
                )
                .optional()
                .map_err(|error| CommitError::Storage(error.to_string()))?;
            if let Some((
                existing_item_id,
                existing_effect_id,
                existing_operation_id,
                existing_idempotency_key,
                existing_authority_lease_id,
                existing_capability_generation,
                existing_permit,
                existing_command_kind,
                existing_command_payload,
            )) = existing
            {
                let exact = existing_item_id == item.item_id
                    && existing_effect_id == item.effect_id
                    && existing_operation_id == item.operation_id
                    && existing_idempotency_key == item.idempotency_key
                    && existing_authority_lease_id == item.authority_lease_id
                    && existing_capability_generation == item.capability_generation
                    && existing_permit == item.permit_commit_decision
                    && existing_command_kind == item.command_kind
                    && existing_command_payload == item.command_payload;
                if !exact {
                    return Err(CommitError::CorruptionDetected {
                        sequence: actual_last,
                    });
                }
                continue;
            }
            transaction
                .execute(
                    "INSERT INTO conversation_v2_outbox
                       (conversation_id, item_id, effect_id, operation_id, idempotency_key,
                        authority_lease_id, capability_generation, permit_commit_decision, dispatched_at)
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, NULL)",
                    params![
                        conversation_id,
                        item.item_id,
                        item.effect_id,
                        item.operation_id,
                        item.idempotency_key,
                        item.authority_lease_id,
                        item.capability_generation,
                        item.permit_commit_decision
                    ],
                )
                .map_err(|error| CommitError::Storage(error.to_string()))?;
            transaction
                .execute(
                    "INSERT INTO conversation_v2_outbox_dispatch
                       (conversation_id, item_id, command_kind, command_payload,
                        capability_generation, status)
                     VALUES (?1, ?2, ?3, ?4, ?5, 'pending')",
                    params![
                        conversation_id,
                        item.item_id,
                        item.command_kind,
                        item.command_payload,
                        item.capability_generation
                    ],
                )
                .map_err(|error| CommitError::Storage(error.to_string()))?;
        }

        transaction
            .execute(
                "UPDATE conversation_v2_session SET updated_at = ?2 WHERE conversation_id = ?1",
                params![conversation_id, last_candidate_at],
            )
            .map_err(|error| CommitError::Storage(error.to_string()))?;

        Ok(CommitOutcome {
            snapshot_at_sequence,
            committed_outbox: request.outbox.clone(),
        })
    }

    /// Lists every durable V2 session without decrypting content. The caller
    /// must load and decrypt each selected event stream on demand.
    pub fn list_sessions(&self) -> Result<Vec<LoadedConversationSessionRecord>, CommitError> {
        let connection = self.connection.lock().expect("v2 db connection poisoned");
        let mut statement = connection
            .prepare(
                "SELECT s.conversation_id, s.schema_version, s.created_at, s.updated_at,
                        CASE WHEN c.conversation_id IS NULL THEN 0 ELSE 1 END
                   FROM conversation_v2_session s
              LEFT JOIN conversation_v2_corruption c
                     ON c.conversation_id = s.conversation_id
               ORDER BY s.updated_at DESC, s.conversation_id ASC",
            )
            .map_err(|error| CommitError::Storage(error.to_string()))?;
        let rows = statement
            .query_map([], |row| {
                Ok(LoadedConversationSessionRecord {
                    conversation_id: row.get(0)?,
                    schema_version: row.get(1)?,
                    created_at: row.get(2)?,
                    updated_at: row.get(3)?,
                    is_corrupted: row.get::<_, i64>(4)? != 0,
                })
            })
            .map_err(|error| CommitError::Storage(error.to_string()))?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(|error| CommitError::Storage(error.to_string()))
    }

    /// 读取会话当前 lastApplied（幂等/对账；无事件时为 0）。
    pub fn last_applied_for(&self, conversation_id: &str) -> Result<i64, CommitError> {
        let connection = self.connection.lock().expect("v2 db connection poisoned");
        let corruption_sequence: Option<i64> = connection
            .query_row(
                "SELECT sequence FROM conversation_v2_corruption WHERE conversation_id = ?1",
                params![conversation_id],
                |row| row.get(0),
            )
            .optional()
            .map_err(|error| CommitError::Storage(error.to_string()))?;
        if let Some(sequence) = corruption_sequence {
            return Err(CommitError::CorruptionDetected { sequence });
        }
        let watermark: i64 = connection
            .query_row(
                "SELECT COALESCE(watermark, 0)
                   FROM conversation_v2_compaction_watermark
                  WHERE conversation_id = ?1",
                params![conversation_id],
                |row| row.get(0),
            )
            .optional()
            .map_err(|error| CommitError::Storage(error.to_string()))?
            .unwrap_or(0);
        let last: i64 = connection
            .query_row(
                "SELECT COALESCE(MAX(sequence), 0) FROM conversation_v2_event WHERE conversation_id = ?1",
                params![conversation_id],
                |row| row.get(0),
            )
            .map_err(|error| CommitError::Storage(error.to_string()))?;
        if last < watermark {
            return Err(CommitError::CorruptionDetected {
                sequence: watermark,
            });
        }
        if last > watermark {
            let (min_sequence, count): (Option<i64>, i64) = connection
                .query_row(
                    "SELECT MIN(sequence), COUNT(*)
                       FROM conversation_v2_event
                      WHERE conversation_id = ?1 AND sequence > ?2 AND status = 'applied'",
                    params![conversation_id, watermark],
                    |row| Ok((row.get(0)?, row.get(1)?)),
                )
                .map_err(|error| CommitError::Storage(error.to_string()))?;
            if min_sequence != Some(watermark + 1) || count != last - watermark {
                return Err(CommitError::CorruptionDetected {
                    sequence: min_sequence.unwrap_or(watermark + 1),
                });
            }
        }
        Ok(last)
    }

    /// P0-5：按 sequence 升序加载会话全部事件（重启恢复/replay）。
    /// 返回加密 payload（payload_cipher）；Swift 侧经 ConversationEncryption 解密。
    pub fn load_events(
        &self,
        conversation_id: &str,
    ) -> Result<Vec<LoadedEventRecord>, CommitError> {
        let connection = self.connection.lock().expect("v2 db connection poisoned");
        let corruption_sequence: Option<i64> = connection
            .query_row(
                "SELECT sequence FROM conversation_v2_corruption WHERE conversation_id = ?1",
                params![conversation_id],
                |row| row.get(0),
            )
            .optional()
            .map_err(|error| CommitError::Storage(error.to_string()))?;
        if let Some(sequence) = corruption_sequence {
            return Err(CommitError::CorruptionDetected { sequence });
        }
        let watermark: i64 = connection
            .query_row(
                "SELECT COALESCE(watermark, 0)
                   FROM conversation_v2_compaction_watermark
                  WHERE conversation_id = ?1",
                params![conversation_id],
                |row| row.get(0),
            )
            .optional()
            .map_err(|error| CommitError::Storage(error.to_string()))?
            .unwrap_or(0);
        if watermark > 0 {
            return Err(CommitError::CompactionBaselineRequired { watermark });
        }
        let mut statement = connection
            .prepare(
                "SELECT sequence, event_id, event_type, write_class, source, created_at,
                        payload_cipher, payload_cipher_version, payload_byte_length,
                        payload_hash, visibility
                 FROM conversation_v2_event
                 WHERE conversation_id = ?1 AND status = 'applied'
                 ORDER BY sequence ASC",
            )
            .map_err(|error| CommitError::Storage(error.to_string()))?;
        let records = statement
            .query_map(params![conversation_id], |row| {
                Ok((
                    LoadedEventRecord {
                        sequence: row.get(0)?,
                        event_id: row.get(1)?,
                        event_type: row.get(2)?,
                        write_class: row.get(3)?,
                        source: row.get(4)?,
                        created_at: row.get(5)?,
                        payload_cipher: row.get::<_, Option<Vec<u8>>>(6)?.unwrap_or_default(),
                        payload_cipher_version: row
                            .get::<_, Option<String>>(7)?
                            .unwrap_or_default(),
                        payload_hash: row.get(9)?,
                        visibility: row
                            .get::<_, Option<String>>(10)?
                            .unwrap_or_else(|| "session".to_string()),
                    },
                    row.get::<_, Option<i64>>(8)?,
                ))
            })
            .map_err(|error| CommitError::Storage(error.to_string()))?;
        let mut result = Vec::new();
        for record in records {
            let (record, declared_length) =
                record.map_err(|error| CommitError::Storage(error.to_string()))?;
            if declared_length != Some(record.payload_cipher.len() as i64)
                || record.payload_cipher.is_empty()
                || record.payload_cipher_version.trim().is_empty()
            {
                return Err(CommitError::CorruptionDetected {
                    sequence: record.sequence,
                });
            }
            result.push(record);
        }
        Ok(result)
    }

    /// Load every effect that has not reached a durable settlement.
    pub fn load_unsettled_outbox(
        &self,
        conversation_id: &str,
    ) -> Result<Vec<LoadedOutboxRecord>, CommitError> {
        let connection = self.connection.lock().expect("v2 db connection poisoned");
        let corruption_sequence: Option<i64> = connection
            .query_row(
                "SELECT sequence FROM conversation_v2_corruption WHERE conversation_id = ?1",
                params![conversation_id],
                |row| row.get(0),
            )
            .optional()
            .map_err(|error| CommitError::Storage(error.to_string()))?;
        if let Some(sequence) = corruption_sequence {
            return Err(CommitError::CorruptionDetected { sequence });
        }
        let mut statement = connection
            .prepare(
                "SELECT o.item_id, o.effect_id, o.operation_id, o.idempotency_key,
                        d.command_kind, d.command_payload, o.authority_lease_id,
                        d.capability_generation, o.permit_commit_decision, d.status,
                        d.dispatch_token, d.dispatched_at, d.settlement_outcome,
                        d.settled_at, d.reconciliation_reason
                   FROM conversation_v2_outbox o
                   JOIN conversation_v2_outbox_dispatch d
                     ON d.conversation_id = o.conversation_id AND d.item_id = o.item_id
                  WHERE o.conversation_id = ?1 AND d.status != 'settled'
                  ORDER BY o.rowid ASC",
            )
            .map_err(|error| CommitError::Storage(error.to_string()))?;
        let records = statement
            .query_map(params![conversation_id], Self::map_outbox_record)
            .map_err(|error| CommitError::Storage(error.to_string()))?;
        let mut result = Vec::new();
        for record in records {
            result.push(record.map_err(|error| CommitError::Storage(error.to_string()))?);
        }
        Ok(result)
    }

    /// Atomically claim one pending effect. A dispatching/reconciliation/settled
    /// row is never returned, so process relaunch cannot blindly repeat it.
    pub fn claim_outbox_effect(
        &self,
        conversation_id: &str,
        effect_id: &str,
        dispatch_token: &str,
        dispatched_at: &str,
    ) -> Result<Option<LoadedOutboxRecord>, CommitError> {
        let mut connection = self.connection.lock().expect("v2 db connection poisoned");
        let corruption_sequence: Option<i64> = connection
            .query_row(
                "SELECT sequence FROM conversation_v2_corruption WHERE conversation_id = ?1",
                params![conversation_id],
                |row| row.get(0),
            )
            .optional()
            .map_err(|error| CommitError::Storage(error.to_string()))?;
        if let Some(sequence) = corruption_sequence {
            return Err(CommitError::CorruptionDetected { sequence });
        }
        let transaction = connection
            .transaction()
            .map_err(|error| CommitError::Storage(error.to_string()))?;
        let item_id: Option<String> = transaction
            .query_row(
                "SELECT o.item_id
                   FROM conversation_v2_outbox o
                   JOIN conversation_v2_outbox_dispatch d
                     ON d.conversation_id = o.conversation_id AND d.item_id = o.item_id
                  WHERE o.conversation_id = ?1 AND o.effect_id = ?2 AND d.status = 'pending'
                  ORDER BY o.rowid ASC
                  LIMIT 1",
                params![conversation_id, effect_id],
                |row| row.get(0),
            )
            .ok();
        let Some(item_id) = item_id else {
            transaction
                .commit()
                .map_err(|error| CommitError::Storage(error.to_string()))?;
            return Ok(None);
        };
        let changed = transaction
            .execute(
                "UPDATE conversation_v2_outbox_dispatch
                    SET status = 'dispatching', dispatch_token = ?3, dispatched_at = ?4,
                        reconciliation_reason = NULL
                  WHERE conversation_id = ?1 AND item_id = ?2 AND status = 'pending'",
                params![conversation_id, item_id, dispatch_token, dispatched_at],
            )
            .map_err(|error| CommitError::Storage(error.to_string()))?;
        if changed != 1 {
            transaction
                .commit()
                .map_err(|error| CommitError::Storage(error.to_string()))?;
            return Ok(None);
        }
        let record = transaction
            .query_row(
                "SELECT o.item_id, o.effect_id, o.operation_id, o.idempotency_key,
                        d.command_kind, d.command_payload, o.authority_lease_id,
                        d.capability_generation, o.permit_commit_decision, d.status,
                        d.dispatch_token, d.dispatched_at, d.settlement_outcome,
                        d.settled_at, d.reconciliation_reason
                   FROM conversation_v2_outbox o
                   JOIN conversation_v2_outbox_dispatch d
                     ON d.conversation_id = o.conversation_id AND d.item_id = o.item_id
                  WHERE o.conversation_id = ?1 AND o.item_id = ?2",
                params![conversation_id, item_id],
                Self::map_outbox_record,
            )
            .map_err(|error| CommitError::Storage(error.to_string()))?;
        transaction
            .commit()
            .map_err(|error| CommitError::Storage(error.to_string()))?;
        Ok(Some(record))
    }

    /// Settle only the claimant that owns the dispatch token. Repeating the same
    /// settlement is idempotent; a different token or outcome is rejected.
    pub fn settle_outbox(
        &self,
        conversation_id: &str,
        item_id: &str,
        dispatch_token: &str,
        outcome: &str,
        settled_at: &str,
    ) -> Result<bool, CommitError> {
        let connection = self.connection.lock().expect("v2 db connection poisoned");
        let corruption_sequence: Option<i64> = connection
            .query_row(
                "SELECT sequence FROM conversation_v2_corruption WHERE conversation_id = ?1",
                params![conversation_id],
                |row| row.get(0),
            )
            .optional()
            .map_err(|error| CommitError::Storage(error.to_string()))?;
        if let Some(sequence) = corruption_sequence {
            return Err(CommitError::CorruptionDetected { sequence });
        }
        let changed = connection
            .execute(
                "UPDATE conversation_v2_outbox_dispatch
                    SET status = 'settled', settlement_outcome = ?4, settled_at = ?5,
                        reconciliation_reason = NULL
                  WHERE conversation_id = ?1 AND item_id = ?2
                    AND status = 'dispatching' AND dispatch_token = ?3",
                params![
                    conversation_id,
                    item_id,
                    dispatch_token,
                    outcome,
                    settled_at
                ],
            )
            .map_err(|error| CommitError::Storage(error.to_string()))?;
        if changed == 1 {
            return Ok(true);
        }
        let idempotent: bool = connection
            .query_row(
                "SELECT COUNT(*) = 1 FROM conversation_v2_outbox_dispatch
                  WHERE conversation_id = ?1 AND item_id = ?2 AND status = 'settled'
                    AND dispatch_token = ?3 AND settlement_outcome = ?4",
                params![conversation_id, item_id, dispatch_token, outcome],
                |row| row.get(0),
            )
            .map_err(|error| CommitError::Storage(error.to_string()))?;
        Ok(idempotent)
    }

    /// Isolate an in-flight effect whose external result cannot be proven after
    /// relaunch. This state requires explicit reconciliation and is not claimable.
    pub fn require_outbox_reconciliation(
        &self,
        conversation_id: &str,
        item_id: &str,
        reason: &str,
    ) -> Result<bool, CommitError> {
        let connection = self.connection.lock().expect("v2 db connection poisoned");
        let corruption_sequence: Option<i64> = connection
            .query_row(
                "SELECT sequence FROM conversation_v2_corruption WHERE conversation_id = ?1",
                params![conversation_id],
                |row| row.get(0),
            )
            .optional()
            .map_err(|error| CommitError::Storage(error.to_string()))?;
        if let Some(sequence) = corruption_sequence {
            return Err(CommitError::CorruptionDetected { sequence });
        }
        let changed = connection
            .execute(
                "UPDATE conversation_v2_outbox_dispatch
                    SET status = 'reconciliationRequired', reconciliation_reason = ?3
                  WHERE conversation_id = ?1 AND item_id = ?2
                    AND status IN ('pending', 'dispatching')",
                params![conversation_id, item_id, reason],
            )
            .map_err(|error| CommitError::Storage(error.to_string()))?;
        Ok(changed == 1)
    }

    fn map_outbox_record(row: &rusqlite::Row<'_>) -> rusqlite::Result<LoadedOutboxRecord> {
        Ok(LoadedOutboxRecord {
            item_id: row.get(0)?,
            effect_id: row.get(1)?,
            operation_id: row.get(2)?,
            idempotency_key: row.get(3)?,
            command_kind: row.get(4)?,
            command_payload: row.get(5)?,
            authority_lease_id: row.get(6)?,
            capability_generation: row.get(7)?,
            permit_commit_decision: row.get(8)?,
            status: row.get(9)?,
            dispatch_token: row.get(10)?,
            dispatched_at: row.get(11)?,
            settlement_outcome: row.get(12)?,
            settled_at: row.get(13)?,
            reconciliation_reason: row.get(14)?,
        })
    }
}

/// P0-5：加载的事件记录（加密 payload；Swift 侧解密后 replay）。
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct LoadedEventRecord {
    pub sequence: i64,
    pub event_id: String,
    pub event_type: String,
    pub write_class: String,
    pub source: String,
    pub created_at: String,
    pub payload_cipher: Vec<u8>,
    pub payload_cipher_version: String,
    pub payload_hash: String,
    pub visibility: String,
}
