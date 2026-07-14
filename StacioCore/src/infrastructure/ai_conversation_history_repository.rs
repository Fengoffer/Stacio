use chrono::Utc;
use rusqlite::{params, Connection};
use uuid::Uuid;

use crate::domain::agent::AIConversationHistoryItemDraft;

const MAX_HISTORY_ITEMS_PER_RUNTIME: i64 = 30;
const MAX_HISTORY_CONTENT_BYTES: usize = 2_048;

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct AIConversationHistoryItemRecord {
    pub id: String,
    pub runtime_id: String,
    pub role: String,
    pub content: String,
    pub request_id: Option<String>,
    pub created_at: String,
}

pub struct AIConversationHistoryRepository {
    connection: Connection,
}

impl AIConversationHistoryRepository {
    pub fn new(connection: Connection) -> Self {
        Self { connection }
    }

    pub fn append(
        &self,
        draft: &AIConversationHistoryItemDraft,
    ) -> Result<AIConversationHistoryItemRecord, rusqlite::Error> {
        let record = AIConversationHistoryItemRecord {
            id: Uuid::new_v4().to_string(),
            runtime_id: draft.runtime_id.clone(),
            role: draft.role.clone(),
            content: truncate_utf8(&draft.content, MAX_HISTORY_CONTENT_BYTES),
            request_id: draft.request_id.clone(),
            created_at: Utc::now().to_rfc3339(),
        };
        self.connection.execute(
            "INSERT INTO ai_conversation_history
             (id, runtime_id, role, content, request_id, created_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![
                record.id,
                record.runtime_id,
                record.role,
                record.content,
                record.request_id,
                record.created_at
            ],
        )?;
        self.prune_runtime(&draft.runtime_id)?;
        Ok(record)
    }

    pub fn list(
        &self,
        runtime_id: &str,
    ) -> Result<Vec<AIConversationHistoryItemRecord>, rusqlite::Error> {
        let mut statement = self.connection.prepare(
            "SELECT id, runtime_id, role, content, request_id, created_at
             FROM ai_conversation_history
             WHERE runtime_id = ?1
             ORDER BY rowid ASC",
        )?;
        let records = statement
            .query_map(params![runtime_id], read_ai_conversation_history_item)?
            .collect();
        records
    }

    pub fn clear_all(&self) -> Result<(), rusqlite::Error> {
        self.connection
            .execute("DELETE FROM ai_conversation_history", [])?;
        Ok(())
    }

    fn prune_runtime(&self, runtime_id: &str) -> Result<(), rusqlite::Error> {
        self.connection.execute(
            "DELETE FROM ai_conversation_history
             WHERE runtime_id = ?1
               AND rowid NOT IN (
                 SELECT rowid
                 FROM ai_conversation_history
                 WHERE runtime_id = ?1
                 ORDER BY rowid DESC
                 LIMIT ?2
               )",
            params![runtime_id, MAX_HISTORY_ITEMS_PER_RUNTIME],
        )?;
        Ok(())
    }
}

fn read_ai_conversation_history_item(
    row: &rusqlite::Row<'_>,
) -> rusqlite::Result<AIConversationHistoryItemRecord> {
    Ok(AIConversationHistoryItemRecord {
        id: row.get(0)?,
        runtime_id: row.get(1)?,
        role: row.get(2)?,
        content: row.get(3)?,
        request_id: row.get(4)?,
        created_at: row.get(5)?,
    })
}

fn truncate_utf8(input: &str, max_bytes: usize) -> String {
    if input.len() <= max_bytes {
        return input.to_string();
    }
    let mut boundary = max_bytes;
    while boundary > 0 && !input.is_char_boundary(boundary) {
        boundary -= 1;
    }
    input[..boundary].to_string()
}
