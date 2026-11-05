-- V2 迁移 0004：snapshot/watermark/compaction/omission。

CREATE TABLE IF NOT EXISTS conversation_v2_snapshot (
  snapshot_id TEXT PRIMARY KEY NOT NULL,
  conversation_id TEXT NOT NULL,
  covers_through_sequence INTEGER NOT NULL,
  state_digest TEXT NOT NULL,
  source_range_digest TEXT NOT NULL,
  payload_cipher_version TEXT NOT NULL,
  payload_byte_length INTEGER NOT NULL,
  verified_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS conversation_v2_compaction_watermark (
  conversation_id TEXT PRIMARY KEY NOT NULL,
  watermark INTEGER NOT NULL DEFAULT 0,
  updated_at TEXT NOT NULL
);

-- omission skeleton：中间 checkpoint 只删独立密文 payload，保留原 sequence/event_id/type/hash/时间范围。
CREATE TABLE IF NOT EXISTS conversation_v2_omission (
  conversation_id TEXT NOT NULL,
  sequence INTEGER NOT NULL,
  event_id TEXT NOT NULL,
  event_type TEXT NOT NULL,
  payload_hash TEXT NOT NULL,
  payload_byte_length INTEGER NOT NULL,
  omission_status TEXT NOT NULL,
  omission_reason TEXT NOT NULL,
  created_at TEXT NOT NULL,
  PRIMARY KEY (conversation_id, sequence)
);
