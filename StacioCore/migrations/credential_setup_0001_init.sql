-- Credential Setup/Use-Lease/Verification 独立存储域（P3-8c）。
-- Permit 接线与 Keychain staging 待 P3-9 后实施；本迁移只落状态机表。

CREATE TABLE IF NOT EXISTS credential_use_lease (
  lease_id TEXT PRIMARY KEY NOT NULL,
  owner TEXT NOT NULL,
  state TEXT NOT NULL,
  credential_generation_id TEXT NOT NULL,
  created_at TEXT NOT NULL,
  released_at TEXT
);

CREATE TABLE IF NOT EXISTS credential_verification_request (
  request_id TEXT PRIMARY KEY NOT NULL,
  configuration_id TEXT NOT NULL,
  state TEXT NOT NULL,
  created_at TEXT NOT NULL
);

-- revoke fence：先 durable 关 gate（closed=1），再 fan-out；gate 关闭后拒绝新 use lease。
CREATE TABLE IF NOT EXISTS credential_revoke_fence (
  credential_generation_id TEXT PRIMARY KEY NOT NULL,
  closed INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL
);
