-- Credential Lifecycle 独立存储域（规格 §15.1：权威 Store 独立于会话库）。
-- 本库只保存 generation 元数据/lifecycle/orphan/deletion/revoke fence；
-- 会话库只保存不可变 CredentialGeneration 引用与投影；secret 正文绝不入库。

CREATE TABLE IF NOT EXISTS credential_generation (
  generation_id TEXT PRIMARY KEY NOT NULL,
  configuration_id TEXT NOT NULL,
  generation INTEGER NOT NULL,
  lifecycle_state TEXT NOT NULL,
  secret_availability TEXT NOT NULL,
  keychain_reference TEXT NOT NULL,
  active_attempt_ref_count INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  retired_at TEXT,
  UNIQUE (configuration_id, generation)
);

CREATE TABLE IF NOT EXISTS credential_deletion_operation (
  operation_id TEXT PRIMARY KEY NOT NULL,
  generation_id TEXT NOT NULL REFERENCES credential_generation(generation_id),
  state TEXT NOT NULL,
  deletion_fence INTEGER NOT NULL,
  requested_at TEXT NOT NULL,
  completed_at TEXT,
  failure_reason TEXT
);

CREATE TABLE IF NOT EXISTS credential_orphan (
  orphan_id TEXT PRIMARY KEY NOT NULL,
  keychain_item_id TEXT NOT NULL,
  state TEXT NOT NULL,
  secret BLOB,
  created_at TEXT NOT NULL
);
