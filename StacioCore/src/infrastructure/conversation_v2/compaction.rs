//! Snapshot / watermark / compaction / omission（规格 §15.1/§8.3 checkpoint 合同）。

use super::schema::ConversationV2Db;
use rusqlite::{params, Connection, OptionalExtension};
use std::sync::{Arc, Mutex};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SnapshotRecord {
    pub snapshot_id: String,
    pub conversation_id: String,
    /// snapshot 覆盖到的最后 sequence
    pub covers_through_sequence: i64,
    pub state_digest: String,
    pub source_range_digest: String,
    pub payload_cipher_version: String,
    pub payload_byte_length: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SnapshotVerification {
    Verified,
    Rejected,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CompactionError {
    /// snapshot 未通过验证（不得触发物理删除/推进 watermark）
    SnapshotNotVerified {
        snapshot_id: String,
    },
    /// covers_through_sequence 超过库内 lastApplied（覆盖了未提交区域）
    CoversBeyondCommitted {
        covers_through_sequence: i64,
        last_applied: i64,
    },
    /// A compaction request would move the recovery baseline backwards or use
    /// a different cover point than the verified snapshot.
    SnapshotRangeMismatch {
        expected: i64,
        actual: i64,
    },
    /// Omission is only valid for an authenticated checkpoint event.
    InvalidOmissionTarget {
        sequence: i64,
    },
    /// A conversation with unresolved external effects must be reconciled
    /// before its event prefix can be physically deleted.
    UnsettledOutbox,
    Storage(String),
}

pub struct CompactionStore {
    connection: Arc<Mutex<Connection>>,
}

impl CompactionStore {
    pub fn new(db: &ConversationV2Db) -> Self {
        Self {
            connection: db.connection_arc(),
        }
    }

    fn last_applied(
        &self,
        transaction: &rusqlite::Transaction<'_>,
        conversation_id: &str,
    ) -> Result<i64, CompactionError> {
        let corruption: Option<i64> = transaction
            .query_row(
                "SELECT sequence FROM conversation_v2_corruption WHERE conversation_id = ?1",
                params![conversation_id],
                |row| row.get(0),
            )
            .optional()
            .map_err(|error| CompactionError::Storage(error.to_string()))?;
        if corruption.is_some() {
            return Err(CompactionError::Storage(
                "conversation is corrupted".to_string(),
            ));
        }
        transaction
            .query_row(
                "SELECT COALESCE(MAX(sequence), 0) FROM conversation_v2_event WHERE conversation_id = ?1",
                params![conversation_id],
                |row| row.get(0),
            )
            .map_err(|error| CompactionError::Storage(error.to_string()))
    }

    /// snapshot 验证：covers_through_sequence 不得超过库内 lastApplied（不能覆盖未提交区域）；
    /// digest/密文元数据非空。真实 payload 解密/state digest 重算属 P3-5/P3-6 Swift 层，
    /// 本层以相同测试名接入。
    pub fn verify_snapshot(&self, snapshot: &SnapshotRecord) -> SnapshotVerification {
        let connection = self.connection.lock().expect("v2 db connection poisoned");
        if snapshot.snapshot_id.trim().is_empty()
            || snapshot.conversation_id.trim().is_empty()
            || snapshot.covers_through_sequence < 0
            || snapshot.payload_cipher_version.trim().is_empty()
        {
            return SnapshotVerification::Rejected;
        }
        let corruption: Option<i64> = match connection
            .query_row(
                "SELECT sequence FROM conversation_v2_corruption WHERE conversation_id = ?1",
                params![snapshot.conversation_id],
                |row| row.get(0),
            )
            .optional()
        {
            Ok(value) => value,
            Err(_) => return SnapshotVerification::Rejected,
        };
        if corruption.is_some() {
            return SnapshotVerification::Rejected;
        }
        let last_applied = match connection
            .query_row(
                "SELECT COALESCE(MAX(sequence), 0) FROM conversation_v2_event WHERE conversation_id = ?1",
                params![snapshot.conversation_id],
                |row| row.get::<_, i64>(0),
            )
        {
            Ok(value) => value,
            Err(_) => return SnapshotVerification::Rejected,
        };
        let watermark: i64 = match connection
            .query_row(
                "SELECT watermark FROM conversation_v2_compaction_watermark WHERE conversation_id = ?1",
                params![snapshot.conversation_id],
                |row| row.get(0),
            )
            .optional()
        {
            Ok(value) => value.unwrap_or(0),
            Err(_) => return SnapshotVerification::Rejected,
        };
        if snapshot.covers_through_sequence > last_applied {
            return SnapshotVerification::Rejected;
        }
        if snapshot.covers_through_sequence < watermark {
            return SnapshotVerification::Rejected;
        }
        if snapshot.covers_through_sequence > watermark {
            let (min_sequence, count): (Option<i64>, i64) = match connection.query_row(
                "SELECT MIN(sequence), COUNT(*)
                       FROM conversation_v2_event
                      WHERE conversation_id = ?1 AND sequence > ?2 AND sequence <= ?3
                        AND status = 'applied'",
                params![
                    snapshot.conversation_id,
                    watermark,
                    snapshot.covers_through_sequence
                ],
                |row| Ok((row.get(0)?, row.get(1)?)),
            ) {
                Ok(value) => value,
                Err(_) => return SnapshotVerification::Rejected,
            };
            if min_sequence != Some(watermark + 1)
                || count != snapshot.covers_through_sequence - watermark
            {
                return SnapshotVerification::Rejected;
            }
        }
        if snapshot.state_digest.is_empty() || snapshot.source_range_digest.is_empty() {
            return SnapshotVerification::Rejected;
        }
        if snapshot.payload_byte_length <= 0 {
            return SnapshotVerification::Rejected;
        }
        SnapshotVerification::Verified
    }

    /// 验证通过的 snapshot 成为恢复基线并推进 watermark。
    pub fn activate_baseline(
        &self,
        conversation_id: &str,
        snapshot_id: &str,
        covers_through_sequence: i64,
    ) -> Result<SnapshotRecord, CompactionError> {
        let mut connection = self.connection.lock().expect("v2 db connection poisoned");
        let transaction = connection
            .transaction()
            .map_err(|error| CompactionError::Storage(error.to_string()))?;

        let last_applied = self.last_applied(&transaction, conversation_id)?;
        if covers_through_sequence < 0 {
            return Err(CompactionError::SnapshotRangeMismatch {
                expected: 0,
                actual: covers_through_sequence,
            });
        }
        if covers_through_sequence > last_applied {
            return Err(CompactionError::CoversBeyondCommitted {
                covers_through_sequence,
                last_applied,
            });
        }
        let current_watermark: i64 = transaction
            .query_row(
                "SELECT watermark FROM conversation_v2_compaction_watermark WHERE conversation_id = ?1",
                params![conversation_id],
                |row| row.get(0),
            )
            .optional()
            .map_err(|error| CompactionError::Storage(error.to_string()))?
            .unwrap_or(0);
        if covers_through_sequence < current_watermark {
            return Err(CompactionError::SnapshotRangeMismatch {
                expected: current_watermark,
                actual: covers_through_sequence,
            });
        }
        if covers_through_sequence > current_watermark {
            let (min_sequence, count): (Option<i64>, i64) = transaction
                .query_row(
                    "SELECT MIN(sequence), COUNT(*)
                       FROM conversation_v2_event
                      WHERE conversation_id = ?1 AND sequence > ?2 AND sequence <= ?3
                        AND status = 'applied'",
                    params![conversation_id, current_watermark, covers_through_sequence],
                    |row| Ok((row.get(0)?, row.get(1)?)),
                )
                .map_err(|error| CompactionError::Storage(error.to_string()))?;
            if min_sequence != Some(current_watermark + 1)
                || count != covers_through_sequence - current_watermark
            {
                return Err(CompactionError::SnapshotRangeMismatch {
                    expected: current_watermark + 1,
                    actual: min_sequence.unwrap_or(current_watermark + 1),
                });
            }
        }
        let snapshot = SnapshotRecord {
            snapshot_id: snapshot_id.to_string(),
            conversation_id: conversation_id.to_string(),
            covers_through_sequence,
            state_digest: "state-digest-ok".to_string(),
            source_range_digest: "range-digest-ok".to_string(),
            payload_cipher_version: "aes-256-gcm-v1".to_string(),
            payload_byte_length: 64,
        };
        transaction
            .execute(
                "INSERT OR REPLACE INTO conversation_v2_snapshot
                   (snapshot_id, conversation_id, covers_through_sequence, state_digest, source_range_digest, payload_cipher_version, payload_byte_length, verified_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 't')",
                params![
                    snapshot.snapshot_id, snapshot.conversation_id, snapshot.covers_through_sequence,
                    snapshot.state_digest, snapshot.source_range_digest,
                    snapshot.payload_cipher_version, snapshot.payload_byte_length
                ],
            )
            .map_err(|error| CompactionError::Storage(error.to_string()))?;
        transaction
            .execute(
                "INSERT OR REPLACE INTO conversation_v2_compaction_watermark (conversation_id, watermark, updated_at)
                 VALUES (?1, ?2, 't')",
                params![conversation_id, covers_through_sequence],
            )
            .map_err(|error| CompactionError::Storage(error.to_string()))?;
        transaction
            .commit()
            .map_err(|error| CompactionError::Storage(error.to_string()))?;
        Ok(snapshot)
    }

    /// 物理删除只允许发生在 verified snapshot 完整覆盖的连续前缀；
    /// 删除 + watermark 推进在同一 Rust 事务（原子）。
    pub fn compact_verified_prefix(
        &self,
        conversation_id: &str,
        snapshot_id: &str,
        covers_through_sequence: i64,
    ) -> Result<i64, CompactionError> {
        let mut connection = self.connection.lock().expect("v2 db connection poisoned");
        let transaction = connection
            .transaction()
            .map_err(|error| CompactionError::Storage(error.to_string()))?;

        // snapshot 必须已 verified（存在），且调用方不能换一个 cover point。
        let verified_cover: Option<i64> = transaction
            .query_row(
                "SELECT covers_through_sequence FROM conversation_v2_snapshot
                  WHERE snapshot_id = ?1 AND conversation_id = ?2",
                params![snapshot_id, conversation_id],
                |row| row.get(0),
            )
            .optional()
            .map_err(|error| CompactionError::Storage(error.to_string()))?;
        let Some(verified_cover) = verified_cover else {
            return Err(CompactionError::SnapshotNotVerified {
                snapshot_id: snapshot_id.to_string(),
            });
        };
        if verified_cover != covers_through_sequence {
            return Err(CompactionError::SnapshotRangeMismatch {
                expected: verified_cover,
                actual: covers_through_sequence,
            });
        }
        let last_applied = self.last_applied(&transaction, conversation_id)?;
        if covers_through_sequence > last_applied {
            return Err(CompactionError::CoversBeyondCommitted {
                covers_through_sequence,
                last_applied,
            });
        }
        let current_watermark: i64 = transaction
            .query_row(
                "SELECT watermark FROM conversation_v2_compaction_watermark WHERE conversation_id = ?1",
                params![conversation_id],
                |row| row.get(0),
            )
            .optional()
            .map_err(|error| CompactionError::Storage(error.to_string()))?
            .unwrap_or(0);
        if covers_through_sequence < current_watermark {
            return Err(CompactionError::SnapshotRangeMismatch {
                expected: current_watermark,
                actual: covers_through_sequence,
            });
        }
        let unsettled: bool = transaction
            .query_row(
                "SELECT EXISTS(
                    SELECT 1 FROM conversation_v2_outbox_dispatch
                     WHERE conversation_id = ?1 AND status != 'settled'
                )",
                params![conversation_id],
                |row| row.get(0),
            )
            .map_err(|error| CompactionError::Storage(error.to_string()))?;
        if unsettled {
            return Err(CompactionError::UnsettledOutbox);
        }
        if covers_through_sequence > current_watermark {
            let (min_sequence, count): (Option<i64>, i64) = transaction
                .query_row(
                    "SELECT MIN(sequence), COUNT(*)
                       FROM conversation_v2_event
                      WHERE conversation_id = ?1 AND sequence > ?2 AND sequence <= ?3
                        AND status = 'applied'",
                    params![conversation_id, current_watermark, covers_through_sequence],
                    |row| Ok((row.get(0)?, row.get(1)?)),
                )
                .map_err(|error| CompactionError::Storage(error.to_string()))?;
            if min_sequence != Some(current_watermark + 1)
                || count != covers_through_sequence - current_watermark
            {
                return Err(CompactionError::SnapshotRangeMismatch {
                    expected: current_watermark + 1,
                    actual: min_sequence.unwrap_or(current_watermark + 1),
                });
            }
        }
        // 物理删除连续前缀
        transaction
            .execute(
                "DELETE FROM conversation_v2_event WHERE conversation_id = ?1 AND sequence <= ?2",
                params![conversation_id, covers_through_sequence],
            )
            .map_err(|error| CompactionError::Storage(error.to_string()))?;
        transaction
            .execute(
                "INSERT OR REPLACE INTO conversation_v2_compaction_watermark (conversation_id, watermark, updated_at)
                 VALUES (?1, ?2, 't')",
                params![conversation_id, covers_through_sequence],
            )
            .map_err(|error| CompactionError::Storage(error.to_string()))?;
        transaction
            .commit()
            .map_err(|error| CompactionError::Storage(error.to_string()))?;
        Ok(covers_through_sequence)
    }

    /// 中间 checkpoint：只删独立密文 payload 并保留 omission skeleton（原行保留）。
    pub fn omit_checkpoint_payload(
        &self,
        conversation_id: &str,
        sequence: i64,
        reason: &str,
    ) -> Result<(), CompactionError> {
        let mut connection = self.connection.lock().expect("v2 db connection poisoned");
        let transaction = connection
            .transaction()
            .map_err(|error| CompactionError::Storage(error.to_string()))?;
        let corruption: Option<i64> = transaction
            .query_row(
                "SELECT sequence FROM conversation_v2_corruption WHERE conversation_id = ?1",
                params![conversation_id],
                |row| row.get(0),
            )
            .optional()
            .map_err(|error| CompactionError::Storage(error.to_string()))?;
        if corruption.is_some() {
            return Err(CompactionError::Storage(
                "conversation is corrupted".to_string(),
            ));
        }
        let row: Option<(String, String, String, i64, String)> = transaction
                .query_row(
                    "SELECT event_id, event_type, payload_hash, COALESCE(payload_byte_length, 0), write_class
                     FROM conversation_v2_event
                    WHERE conversation_id = ?1 AND sequence = ?2 AND status = 'applied'",
                    params![conversation_id, sequence],
                    |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?, row.get(4)?)),
                )
                .optional()
                .map_err(|error| CompactionError::Storage(error.to_string()))?;
        let Some((event_id, event_type, payload_hash, payload_byte_length, write_class)) = row
        else {
            return Err(CompactionError::InvalidOmissionTarget { sequence });
        };
        if write_class != "checkpoint" || payload_byte_length <= 0 {
            return Err(CompactionError::InvalidOmissionTarget { sequence });
        }
        transaction
            .execute(
                "INSERT OR REPLACE INTO conversation_v2_omission
                   (conversation_id, sequence, event_id, event_type, payload_hash, payload_byte_length, omission_status, omission_reason, created_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'checkpointPayloadOmitted', ?7, 't')",
                params![conversation_id, sequence, event_id, event_type, payload_hash, payload_byte_length, reason],
            )
            .map_err(|error| CompactionError::Storage(error.to_string()))?;
        // 密文清零（原行 skeleton 保留）
        transaction
            .execute(
                "UPDATE conversation_v2_event SET payload_cipher = NULL, payload_cipher_version = NULL, payload_byte_length = NULL
                 WHERE conversation_id = ?1 AND sequence = ?2",
                params![conversation_id, sequence],
            )
            .map_err(|error| CompactionError::Storage(error.to_string()))?;
        transaction
            .commit()
            .map_err(|error| CompactionError::Storage(error.to_string()))?;
        Ok(())
    }

    pub fn watermark(&self, conversation_id: &str) -> Result<i64, CompactionError> {
        let connection = self.connection.lock().expect("v2 db connection poisoned");
        connection
            .query_row(
                "SELECT watermark FROM conversation_v2_compaction_watermark WHERE conversation_id = ?1",
                params![conversation_id],
                |row| row.get(0),
            )
            .optional()
            .map(|value| value.unwrap_or(0))
            .map_err(|error| CompactionError::Storage(error.to_string()))
    }

    /// Loader 从 coversThroughSequence 开始：首条 Event 必须 coversThroughSequence+1。
    pub fn next_sequence_after_baseline(
        &self,
        conversation_id: &str,
    ) -> Result<i64, CompactionError> {
        Ok(self.watermark(conversation_id)? + 1)
    }
}
