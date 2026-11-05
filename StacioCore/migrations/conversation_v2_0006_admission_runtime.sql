-- V2 migration 0006: process-global scheduler state and corrected Attempt identity.

CREATE TABLE IF NOT EXISTS conversation_v2_scheduler_state (
  singleton INTEGER PRIMARY KEY NOT NULL CHECK (singleton = 1),
  generation INTEGER NOT NULL,
  next_queue_ordinal INTEGER NOT NULL
);

INSERT OR IGNORE INTO conversation_v2_scheduler_state
  (singleton, generation, next_queue_ordinal)
VALUES (1, 0, 1);

-- Attempt IDs are only unique inside one conversation (`attempt-1` is reused by
-- every new session), so the original global index rejected the second session.
DROP INDEX IF EXISTS idx_conversation_v2_admission_attempt;
CREATE UNIQUE INDEX IF NOT EXISTS idx_conversation_v2_admission_attempt
  ON conversation_v2_admission_request(conversation_id, attempt_id);

CREATE INDEX IF NOT EXISTS idx_conversation_v2_admission_fifo
  ON conversation_v2_admission_request(state, queue_ordinal);

CREATE INDEX IF NOT EXISTS idx_conversation_v2_admission_lease_state
  ON conversation_v2_admission_lease(state);
