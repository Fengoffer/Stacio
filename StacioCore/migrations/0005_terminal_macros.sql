CREATE TABLE IF NOT EXISTS terminal_macros (
  id TEXT PRIMARY KEY NOT NULL,
  name TEXT NOT NULL,
  steps_json TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_terminal_macros_updated
  ON terminal_macros(updated_at DESC, id);
