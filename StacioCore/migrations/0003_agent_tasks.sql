CREATE TABLE IF NOT EXISTS agent_task_sessions (
  id TEXT PRIMARY KEY NOT NULL,
  request_id TEXT NOT NULL,
  actor_kind TEXT NOT NULL,
  actor_name TEXT NOT NULL,
  target_runtime_id TEXT,
  target_title TEXT NOT NULL,
  state TEXT NOT NULL,
  user_prompt TEXT NOT NULL DEFAULT '',
  assistant_message TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS agent_task_proposals (
  id TEXT PRIMARY KEY NOT NULL,
  task_id TEXT NOT NULL REFERENCES agent_task_sessions(id) ON DELETE CASCADE,
  command TEXT NOT NULL,
  explanation TEXT NOT NULL DEFAULT '',
  risk TEXT NOT NULL,
  state TEXT NOT NULL,
  sort_order INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_agent_task_sessions_request_updated
  ON agent_task_sessions(request_id, updated_at);

CREATE INDEX IF NOT EXISTS idx_agent_task_sessions_updated
  ON agent_task_sessions(updated_at);

CREATE INDEX IF NOT EXISTS idx_agent_task_proposals_task_order
  ON agent_task_proposals(task_id, sort_order);
