-- AssistantSettingsStore 独立设置域存储（P3-11）。
-- setting 值表 + assistant_settings_event audit（自带 durable sequence，不依赖会话库）；
-- 清空会话后 Settings 仍独立存在。

CREATE TABLE IF NOT EXISTS setting_value (
  setting_key TEXT PRIMARY KEY NOT NULL,
  revision INTEGER NOT NULL,
  value_digest TEXT NOT NULL,
  scope TEXT NOT NULL,
  migration_key TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS assistant_settings_event (
  event_id TEXT PRIMARY KEY NOT NULL,
  sequence INTEGER NOT NULL UNIQUE,
  operation_id TEXT NOT NULL,
  kind TEXT NOT NULL,
  created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_assistant_settings_event_operation
  ON assistant_settings_event (operation_id, sequence);
