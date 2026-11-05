-- CredentialAttemptBinding 独立存储域（P3-8b）。
-- 会话库只保存 binding 引用/投影；本库是 binding 状态机的权威索引。

CREATE TABLE IF NOT EXISTS credential_attempt_binding (
  binding_id TEXT PRIMARY KEY NOT NULL,
  attempt_id TEXT NOT NULL,
  credential_generation_id TEXT NOT NULL,
  state TEXT NOT NULL,
  conversation_commit_sequence INTEGER,
  proof_digest TEXT,
  created_at TEXT NOT NULL,
  released_at TEXT
);

CREATE INDEX IF NOT EXISTS idx_credential_binding_unreleased
  ON credential_attempt_binding(state);
