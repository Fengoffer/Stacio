CREATE TABLE IF NOT EXISTS ai_conversation_history (
  id TEXT PRIMARY KEY NOT NULL,
  runtime_id TEXT NOT NULL,
  role TEXT NOT NULL,
  content TEXT NOT NULL,
  request_id TEXT,
  created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_ai_conversation_history_runtime_order
  ON ai_conversation_history(runtime_id, created_at, id);
