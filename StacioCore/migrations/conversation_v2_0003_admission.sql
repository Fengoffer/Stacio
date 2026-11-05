-- V2 迁移 0003：全局执行 Admission（request/lease 表；唯一 Scheduler 写入）。

-- 请求：queued / granted / cancelled / interrupted。
CREATE TABLE IF NOT EXISTS conversation_v2_admission_request (
  request_id TEXT PRIMARY KEY NOT NULL,
  conversation_id TEXT NOT NULL,
  turn_id TEXT NOT NULL,
  attempt_id TEXT NOT NULL,
  scheduler_generation INTEGER NOT NULL,
  queue_ordinal INTEGER NOT NULL,
  state TEXT NOT NULL,
  granted_lease_id TEXT,
  created_at TEXT NOT NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_conversation_v2_admission_attempt
  ON conversation_v2_admission_request(attempt_id);

-- Lease：granted / active / releasing / released / orphanedRuntime / isolated。
CREATE TABLE IF NOT EXISTS conversation_v2_admission_lease (
  lease_id TEXT PRIMARY KEY NOT NULL,
  request_id TEXT NOT NULL,
  conversation_id TEXT NOT NULL,
  turn_id TEXT NOT NULL,
  attempt_id TEXT NOT NULL,
  scheduler_generation INTEGER NOT NULL,
  state TEXT NOT NULL,
  settlement_id TEXT,
  acquired_at TEXT NOT NULL,
  released_at TEXT
);
