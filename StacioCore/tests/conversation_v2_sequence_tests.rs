use stacio_core::infrastructure::conversation_v2::sequence::{
    CandidateBatch, CandidateValidationError, EnvelopeCandidate, SequenceValidator,
};

fn candidate(
    sequence: i64,
    event_id: &str,
    event_type: &str,
    write_class: &str,
) -> EnvelopeCandidate {
    EnvelopeCandidate {
        sequence,
        event_id: event_id.to_string(),
        event_type: event_type.to_string(),
        write_class: write_class.to_string(),
        source: "test".to_string(),
        created_at: "t".to_string(),
        payload_hash: format!("hash-{sequence}"),
        visibility: "session".to_string(),
        payload_cipher: Some(vec![0x01, 0x02, 0x03]),
        payload_cipher_version: Some("aes-256-gcm-v1".to_string()),
        payload_byte_length: Some(3),
    }
}

fn batch(expected: i64, candidates: Vec<EnvelopeCandidate>) -> CandidateBatch {
    CandidateBatch {
        expected_last_sequence: expected,
        candidates,
    }
}

/// P3-2：expected sequence 与库内 lastApplied 冲突 → 拒绝（整批回滚）。
#[test]
fn sequence_expected_mismatch_rejected() {
    let result = SequenceValidator::validate_batch(
        5, // 库内实际 lastApplied
        &batch(3, vec![candidate(4, "ev-4", "turnSubmitted", "durable")]),
    );
    assert!(matches!(
        result,
        Err(CandidateValidationError::ExpectedMismatch { .. })
    ));
}

/// P3-2：candidate range 连续 → 接受并返回 snapshotAtSequence = 批次最后一个 candidate。
#[test]
fn sequence_contiguous_range_accepted_with_snapshot_at_sequence() {
    let result = SequenceValidator::validate_batch(
        0,
        &batch(
            0,
            vec![
                candidate(1, "ev-1", "turnSubmitted", "durable"),
                candidate(2, "ev-2", "admissionRequested", "durable"),
                candidate(3, "ev-3", "admissionGranted", "durable"),
            ],
        ),
    )
    .expect("contiguous range accepted");
    assert_eq!(
        result, 3,
        "snapshotAtSequence 必须等于批次最后一个 candidate"
    );
}

#[test]
fn sequence_requires_authenticated_payload_metadata() {
    let mut invalid = candidate(1, "ev-1", "turnSubmitted", "durable");
    invalid.payload_cipher = None;
    invalid.payload_cipher_version = None;
    invalid.payload_byte_length = None;
    let result = SequenceValidator::validate_batch(0, &batch(0, vec![invalid]));
    assert!(matches!(
        result,
        Err(CandidateValidationError::InvalidEnvelopeField {
            field: "payload_cipher"
        })
    ));
}

/// P3-2：缺失序号（空洞）→ 拒绝（禁止预留空洞/补写空事件）。
#[test]
fn sequence_gap_rejected() {
    let result = SequenceValidator::validate_batch(
        0,
        &batch(
            0,
            vec![
                candidate(1, "ev-1", "turnSubmitted", "durable"),
                candidate(3, "ev-3", "turnSubmitted", "durable"),
            ],
        ),
    );
    assert!(matches!(result, Err(CandidateValidationError::Gap { .. })));
}

/// P3-2：重复序号 → 拒绝。
#[test]
fn sequence_duplicate_rejected() {
    let result = SequenceValidator::validate_batch(
        0,
        &batch(
            0,
            vec![
                candidate(1, "ev-1", "turnSubmitted", "durable"),
                candidate(1, "ev-2", "turnSubmitted", "durable"),
            ],
        ),
    );
    assert!(matches!(
        result,
        Err(CandidateValidationError::Duplicate { .. })
    ));
}

/// P3-2：乱序（批次内序号回退）→ 拒绝。
#[test]
fn sequence_out_of_order_rejected() {
    let result = SequenceValidator::validate_batch(
        0,
        &batch(
            0,
            vec![
                candidate(1, "ev-1", "turnSubmitted", "durable"),
                candidate(2, "ev-2", "turnSubmitted", "durable"),
                candidate(1, "ev-3", "turnSubmitted", "durable"),
            ],
        ),
    );
    assert!(matches!(
        result,
        Err(CandidateValidationError::OutOfOrder { .. })
    ));
}

/// P3-2：空批次 → 拒绝（禁止补写空事件）。
#[test]
fn sequence_empty_batch_rejected() {
    let result = SequenceValidator::validate_batch(0, &batch(0, vec![]));
    assert!(matches!(result, Err(CandidateValidationError::EmptyBatch)));
}

/// P3-2：明文 envelope 字段可由 Rust 校验——event_type 非空、write_class 合法。
#[test]
fn sequence_plaintext_envelope_fields_validated() {
    let empty_type =
        SequenceValidator::validate_batch(0, &batch(0, vec![candidate(1, "ev-1", "", "durable")]));
    assert!(empty_type.is_err(), "event_type 为空必须拒绝");

    let bad_class = SequenceValidator::validate_batch(
        0,
        &batch(
            0,
            vec![candidate(1, "ev-1", "turnSubmitted", "unknown-class")],
        ),
    );
    assert!(bad_class.is_err(), "write_class 非法必须拒绝");

    let empty_id = SequenceValidator::validate_batch(
        0,
        &batch(0, vec![candidate(1, "", "turnSubmitted", "durable")]),
    );
    assert!(empty_id.is_err(), "event_id 为空必须拒绝");
}
