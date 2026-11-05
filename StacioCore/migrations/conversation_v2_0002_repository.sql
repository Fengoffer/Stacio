-- V2 迁移 0002：Repository 事务域（加密投影 / effect outbox / reserved binding 引用）。

-- Turn/Session 加密投影：明文只保留 key 引用与密文长度，负载一律密文。
CREATE TABLE IF NOT EXISTS conversation_v2_projection (
  conversation_id TEXT NOT NULL REFERENCES conversation_v2_session(conversation_id),
  projection_key TEXT NOT NULL,
  payload_cipher BLOB NOT NULL,
  payload_cipher_version TEXT NOT NULL,
  payload_byte_length INTEGER NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (conversation_id, projection_key)
);

-- Effect outbox：带稳定 effect ID / operation ID / 幂等键 / authority 重验 / Permit commit decision。
CREATE TABLE IF NOT EXISTS conversation_v2_outbox (
  conversation_id TEXT NOT NULL REFERENCES conversation_v2_session(conversation_id),
  item_id TEXT NOT NULL,
  effect_id TEXT NOT NULL,
  operation_id TEXT NOT NULL,
  idempotency_key TEXT NOT NULL,
  authority_lease_id TEXT,
  capability_generation INTEGER,
  permit_commit_decision TEXT,
  dispatched_at TEXT,
  PRIMARY KEY (conversation_id, item_id)
);

CREATE INDEX IF NOT EXISTS idx_conversation_v2_outbox_idempotency
  ON conversation_v2_outbox(conversation_id, idempotency_key);

-- reserved binding 引用：Credential binding 的会话库侧引用（仅引用，非权威）；
-- 无有效 reservation 的提交在事务内强制拒绝。
CREATE TABLE IF NOT EXISTS conversation_v2_reservation (
  binding_id TEXT PRIMARY KEY NOT NULL,
  state TEXT NOT NULL,
  created_at TEXT NOT NULL
);
