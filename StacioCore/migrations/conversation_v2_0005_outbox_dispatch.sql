-- V2 migration 0005: durable effect dispatch state.
--
-- Keep dispatch metadata in a companion table so existing 0002 databases do not
-- require a destructive table rebuild. Command payloads contain identifiers and
-- enum values only; provider prompts, terminal output, credentials, and command
-- text remain in the encrypted event stream.
CREATE TABLE IF NOT EXISTS conversation_v2_outbox_dispatch (
  conversation_id TEXT NOT NULL,
  item_id TEXT NOT NULL,
  command_kind TEXT NOT NULL,
  command_payload BLOB NOT NULL,
  capability_generation INTEGER,
  status TEXT NOT NULL CHECK (
    status IN ('pending', 'dispatching', 'settled', 'reconciliationRequired')
  ),
  dispatch_token TEXT,
  dispatched_at TEXT,
  settlement_outcome TEXT,
  settled_at TEXT,
  reconciliation_reason TEXT,
  PRIMARY KEY (conversation_id, item_id),
  FOREIGN KEY (conversation_id, item_id)
    REFERENCES conversation_v2_outbox(conversation_id, item_id)
    ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_conversation_v2_outbox_dispatch_status
  ON conversation_v2_outbox_dispatch(conversation_id, status);

-- A logical effect may be retried with a new operation envelope, but its
-- stable effect/idempotency identity must still be unique per conversation.
-- Without these constraints INSERT OR IGNORE could silently drop a conflicting
-- command while the caller believed it had been durably queued.
CREATE UNIQUE INDEX IF NOT EXISTS idx_conversation_v2_outbox_effect_unique
  ON conversation_v2_outbox(conversation_id, effect_id);

CREATE UNIQUE INDEX IF NOT EXISTS idx_conversation_v2_outbox_idempotency_unique
  ON conversation_v2_outbox(conversation_id, idempotency_key);

-- Rows produced by builds predating this migration have no reconstructable
-- command payload. Isolate them instead of guessing or replaying an effect.
INSERT OR IGNORE INTO conversation_v2_outbox_dispatch (
  conversation_id,
  item_id,
  command_kind,
  command_payload,
  capability_generation,
  status,
  reconciliation_reason
)
SELECT
  conversation_id,
  item_id,
  'legacyUnknown',
  X'',
  capability_generation,
  'reconciliationRequired',
  'legacy outbox row has no durable command payload'
FROM conversation_v2_outbox;
