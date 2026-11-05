-- External Effect reconciliation（P3-9，独立存储域）。
-- conflictKey = target_digest|resource_scope|operation_class；evidence strength 每条记录冻结；
-- 同 key 全记录终结前锁不释放；unknown 远端 effect 锁不占全局 Admission。

CREATE TABLE IF NOT EXISTS v2_external_effect (
  effect_id TEXT PRIMARY KEY NOT NULL,
  conflict_key TEXT NOT NULL,
  state TEXT NOT NULL,
  evidence_strength TEXT NOT NULL DEFAULT 'none',
  lock_owner TEXT NOT NULL DEFAULT 'reconciliation',
  created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_v2_external_effect_conflict_key ON v2_external_effect (conflict_key);
