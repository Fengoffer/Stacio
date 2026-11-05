//! candidate sequence 与 AAD envelope 校验（规格 §8.3/§15.1）。

/// 一批待提交的候选事件（durable sequence 只能由 V2 持久层在事务中分配）。
#[derive(Debug, Clone, uniffi::Record)]
pub struct CandidateBatch {
    /// 本批期望的前置 lastApplied sequence（= 事务开始时库内 lastApplied）。
    pub expected_last_sequence: i64,
    /// 按候选顺序排列的事件；必须连续且严格递增。
    pub candidates: Vec<EnvelopeCandidate>,
}

/// 明文 envelope 字段（type/ID/candidate/schema 由 Rust 校验；敏感负载走密文列）。
#[derive(Debug, Clone, uniffi::Record)]
pub struct EnvelopeCandidate {
    pub sequence: i64,
    pub event_id: String,
    pub event_type: String,
    pub write_class: String,
    pub source: String,
    pub created_at: String,
    pub payload_hash: String,
    pub visibility: String,
    /// 敏感负载密文（canonical AAD sealed box；明文只落白名单列）
    pub payload_cipher: Option<Vec<u8>>,
    pub payload_cipher_version: Option<String>,
    pub payload_byte_length: Option<i64>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CandidateValidationError {
    /// expected_last_sequence 与库内实际 lastApplied 不一致（冲突 → 整批回滚）。
    ExpectedMismatch { expected: i64, actual_last: i64 },
    /// 序号空洞（禁止预留空洞/补写空事件）。
    Gap { expected_next: i64, got: i64 },
    /// 同批次重复序号。
    Duplicate { sequence: i64 },
    /// 乱序（非严格递增）。
    OutOfOrder { previous: i64, got: i64 },
    /// 空批次（禁止补写空事件）。
    EmptyBatch,
    /// 明文 envelope 字段非法（type/ID/schema）。
    InvalidEnvelopeField { field: &'static str },
}

pub struct SequenceValidator;

impl SequenceValidator {
    /// 校验整批 candidate range 连续性与明文 envelope 字段。
    ///
    /// 返回 `snapshotAtSequence` = 批次最后一个 candidate sequence。
    /// 任何校验失败 → 错误（调用方必须丢弃整批预演，禁止部分提交）。
    pub fn validate_batch(
        actual_last_sequence: i64,
        batch: &CandidateBatch,
    ) -> Result<i64, CandidateValidationError> {
        if batch.candidates.is_empty() {
            return Err(CandidateValidationError::EmptyBatch);
        }
        if actual_last_sequence != batch.expected_last_sequence {
            return Err(CandidateValidationError::ExpectedMismatch {
                expected: batch.expected_last_sequence,
                actual_last: actual_last_sequence,
            });
        }

        let mut previous: Option<i64> = None;
        for candidate in &batch.candidates {
            if candidate.event_id.is_empty() {
                return Err(CandidateValidationError::InvalidEnvelopeField { field: "event_id" });
            }
            if candidate.event_type.is_empty() {
                return Err(CandidateValidationError::InvalidEnvelopeField {
                    field: "event_type",
                });
            }
            if !is_valid_write_class(&candidate.write_class) {
                return Err(CandidateValidationError::InvalidEnvelopeField {
                    field: "write_class",
                });
            }
            if candidate.source.trim().is_empty() {
                return Err(CandidateValidationError::InvalidEnvelopeField { field: "source" });
            }
            if candidate.created_at.trim().is_empty() {
                return Err(CandidateValidationError::InvalidEnvelopeField {
                    field: "created_at",
                });
            }
            if candidate.payload_hash.is_empty() {
                return Err(CandidateValidationError::InvalidEnvelopeField {
                    field: "payload_hash",
                });
            }
            if candidate.visibility.trim().is_empty() {
                return Err(CandidateValidationError::InvalidEnvelopeField {
                    field: "visibility",
                });
            }
            let Some(payload_cipher) = candidate.payload_cipher.as_ref() else {
                return Err(CandidateValidationError::InvalidEnvelopeField {
                    field: "payload_cipher",
                });
            };
            if payload_cipher.is_empty()
                || candidate
                    .payload_cipher_version
                    .as_deref()
                    .map(str::trim)
                    .filter(|version| version.is_empty() == false)
                    .is_none()
                || candidate.payload_byte_length != Some(payload_cipher.len() as i64)
            {
                return Err(CandidateValidationError::InvalidEnvelopeField {
                    field: "payload_cipher",
                });
            }
            match previous {
                None => {
                    let expected_first = batch.expected_last_sequence + 1;
                    if candidate.sequence > expected_first {
                        return Err(CandidateValidationError::Gap {
                            expected_next: expected_first,
                            got: candidate.sequence,
                        });
                    }
                    if candidate.sequence < expected_first {
                        return Err(CandidateValidationError::OutOfOrder {
                            previous: batch.expected_last_sequence,
                            got: candidate.sequence,
                        });
                    }
                }
                Some(prev) => {
                    if candidate.sequence == prev {
                        return Err(CandidateValidationError::Duplicate {
                            sequence: candidate.sequence,
                        });
                    }
                    if candidate.sequence > prev + 1 {
                        return Err(CandidateValidationError::Gap {
                            expected_next: prev + 1,
                            got: candidate.sequence,
                        });
                    }
                    if candidate.sequence < prev {
                        return Err(CandidateValidationError::OutOfOrder {
                            previous: prev,
                            got: candidate.sequence,
                        });
                    }
                }
            }
            previous = Some(candidate.sequence);
        }

        Ok(previous.expect("batch is non-empty"))
    }
}

fn is_valid_write_class(write_class: &str) -> bool {
    matches!(write_class, "ephemeral" | "checkpoint" | "durable")
}
