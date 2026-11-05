-- Configuration Store 独立存储域（P3-12）。
-- configuration 表（revision CAS、typed value digest、credential 只存引用）+ 
-- runtime_configuration_event 表（configuration-scoped durable sequence）。

CREATE TABLE IF NOT EXISTS configuration (
  configuration_id TEXT PRIMARY KEY NOT NULL,
  revision INTEGER NOT NULL,
  value_digest TEXT NOT NULL,
  state TEXT NOT NULL DEFAULT 'draft',
  credential_reference TEXT NOT NULL DEFAULT '',
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS runtime_configuration_event (
  event_id TEXT PRIMARY KEY NOT NULL,
  sequence INTEGER NOT NULL UNIQUE,
  configuration_id TEXT NOT NULL,
  operation_id TEXT NOT NULL,
  kind TEXT NOT NULL,
  created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_runtime_configuration_event_config
  ON runtime_configuration_event (configuration_id, sequence);
CREATE INDEX IF NOT EXISTS idx_runtime_configuration_event_operation
  ON runtime_configuration_event (operation_id, sequence);
