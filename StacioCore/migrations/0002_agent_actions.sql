CREATE TABLE IF NOT EXISTS agent_action_events (
  id TEXT PRIMARY KEY NOT NULL,
  request_id TEXT NOT NULL,
  actor_kind TEXT NOT NULL,
  actor_name TEXT NOT NULL,
  target_runtime_id TEXT,
  target_title TEXT NOT NULL,
  action_kind TEXT NOT NULL,
  risk TEXT NOT NULL,
  state TEXT NOT NULL,
  redacted_input TEXT NOT NULL DEFAULT '',
  environment TEXT NOT NULL DEFAULT 'unknown',
  approval_mode TEXT NOT NULL DEFAULT 'unknown',
  policy_decision TEXT NOT NULL DEFAULT 'unknown',
  redaction_version TEXT NOT NULL DEFAULT 'stacio.agent-redaction.v1',
  created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_agent_action_events_request_created
  ON agent_action_events(request_id, created_at);

CREATE INDEX IF NOT EXISTS idx_agent_action_events_created
  ON agent_action_events(created_at);
