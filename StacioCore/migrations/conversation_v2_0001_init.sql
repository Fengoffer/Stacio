-- V2 独立库迁移 0001：会话/事件/损坏隔离基础表。
-- 物理存储边界（规格 §15.1）：本库只保存会话范围数据与跨域引用/投影；
-- settings/configuration/credential 权威表位于独立存储域，禁止在本库建表。

CREATE TABLE IF NOT EXISTS conversation_v2_session (
  conversation_id TEXT PRIMARY KEY NOT NULL,
  schema_version INTEGER NOT NULL DEFAULT 1,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

-- 事件表：session_id + sequence 唯一（幂等去重 / 损坏隔离基础）。
-- 明文列白名单：ID / type / time / status / sequence / length / cipher-version；
-- 敏感负载只存 payload_cipher（密文），明文绝不落盘。
CREATE TABLE IF NOT EXISTS conversation_v2_event (
  conversation_id TEXT NOT NULL REFERENCES conversation_v2_session(conversation_id),
  sequence INTEGER NOT NULL,
  event_id TEXT NOT NULL,
  event_type TEXT NOT NULL,
  write_class TEXT NOT NULL,
  source TEXT NOT NULL,
  created_at TEXT NOT NULL,
  payload_cipher BLOB,
  payload_cipher_version TEXT,
  payload_byte_length INTEGER,
  payload_hash TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'applied',
  visibility TEXT NOT NULL DEFAULT 'session',
  PRIMARY KEY (conversation_id, sequence)
);

CREATE INDEX IF NOT EXISTS idx_conversation_v2_event_id
  ON conversation_v2_event(conversation_id, event_id);

-- 损坏隔离：同一 sequence 出现不同事件/hash 或无法解密时，会话进入只读 Corrupted。
CREATE TABLE IF NOT EXISTS conversation_v2_corruption (
  conversation_id TEXT PRIMARY KEY NOT NULL,
  reason TEXT NOT NULL,
  sequence INTEGER,
  created_at TEXT NOT NULL
);

-- P3-3 细化：Turn/Attempt/Decision/QueuedInput/outbox 等实体表随 Repository 事务任务落地。
