-- agentConversationV2 三态控制面（P3-9，独立存储域）。
-- enabled→draining→disabled→enabled；generation CAS + transition_id 幂等；
-- Permit（issued→prepared→commitAuthorized→settled*）+ target journal（冻结 participant set）。

CREATE TABLE IF NOT EXISTS v2_control_state (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  state TEXT NOT NULL,
  generation INTEGER NOT NULL,
  last_transition_id TEXT
);

-- 初始代际 generation=1；离开 enabled 和重新进入 enabled 时递增。
INSERT OR IGNORE INTO v2_control_state (id, state, generation) VALUES (1, 'enabled', 1);

CREATE TABLE IF NOT EXISTS v2_control_permit (
  permit_id TEXT PRIMARY KEY NOT NULL,
  generation INTEGER NOT NULL,
  state TEXT NOT NULL,
  settlement_proof TEXT,
  created_at TEXT NOT NULL
);

-- target journal：create_permit 时冻结完整 participant set（state=prepared）。
CREATE TABLE IF NOT EXISTS v2_control_target_journal (
  permit_id TEXT NOT NULL,
  participant TEXT NOT NULL,
  state TEXT NOT NULL,
  PRIMARY KEY (permit_id, participant)
);
