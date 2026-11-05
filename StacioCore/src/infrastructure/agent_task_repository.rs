use chrono::Utc;
use rusqlite::{params, Connection};

use crate::domain::agent::{AgentTaskProposalDraft, AgentTaskSessionDraft};

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct AgentTaskProposalRecord {
    pub id: String,
    pub command: String,
    pub explanation: String,
    pub risk: String,
    pub state: String,
    pub sort_order: u32,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct AgentTaskSessionRecord {
    pub id: String,
    pub request_id: String,
    pub actor_kind: String,
    pub actor_name: String,
    pub target_runtime_id: Option<String>,
    pub target_title: String,
    pub state: String,
    pub user_prompt: String,
    pub assistant_message: String,
    pub created_at: String,
    pub updated_at: String,
    pub proposals: Vec<AgentTaskProposalRecord>,
}

pub struct AgentTaskRepository {
    connection: Connection,
}

impl AgentTaskRepository {
    pub fn new(connection: Connection) -> Self {
        Self { connection }
    }

    pub fn record_session(
        &self,
        draft: &AgentTaskSessionDraft,
        proposals: Vec<AgentTaskProposalDraft>,
    ) -> Result<AgentTaskSessionRecord, rusqlite::Error> {
        let now = Utc::now().to_rfc3339();
        self.connection.execute(
            "INSERT INTO agent_task_sessions
             (id, request_id, actor_kind, actor_name, target_runtime_id, target_title, state, user_prompt, assistant_message, created_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
             ON CONFLICT(id) DO UPDATE SET
                request_id = excluded.request_id,
                actor_kind = excluded.actor_kind,
                actor_name = excluded.actor_name,
                target_runtime_id = excluded.target_runtime_id,
                target_title = excluded.target_title,
                state = excluded.state,
                user_prompt = excluded.user_prompt,
                assistant_message = excluded.assistant_message,
                updated_at = excluded.updated_at",
            params![
                draft.id,
                draft.request_id,
                draft.actor_kind,
                draft.actor_name,
                draft.target_runtime_id,
                draft.target_title,
                draft.state,
                draft.user_prompt,
                draft.assistant_message,
                now,
                now,
            ],
        )?;
        self.connection.execute(
            "DELETE FROM agent_task_proposals WHERE task_id = ?1",
            params![draft.id],
        )?;
        for proposal in proposals {
            self.connection.execute(
                "INSERT INTO agent_task_proposals
                 (id, task_id, command, explanation, risk, state, sort_order, created_at, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
                params![
                    proposal.id,
                    draft.id,
                    proposal.command,
                    proposal.explanation,
                    proposal.risk,
                    proposal.state,
                    proposal.sort_order as i64,
                    now,
                    now,
                ],
            )?;
        }

        self.get(&draft.id)?
            .ok_or_else(|| rusqlite::Error::QueryReturnedNoRows)
    }

    pub fn list_recent(&self, limit: u32) -> Result<Vec<AgentTaskSessionRecord>, rusqlite::Error> {
        let mut statement = self.connection.prepare(
            "SELECT id, request_id, actor_kind, actor_name, target_runtime_id, target_title,
                    state, user_prompt, assistant_message, created_at, updated_at
             FROM agent_task_sessions
             ORDER BY updated_at DESC, id DESC
             LIMIT ?1",
        )?;
        let records = statement
            .query_map(params![limit as i64], read_agent_task_session_record)?
            .collect::<Result<Vec<_>, _>>()?;
        self.with_proposals(records)
    }

    pub fn list_by_request_id(
        &self,
        request_id: &str,
    ) -> Result<Vec<AgentTaskSessionRecord>, rusqlite::Error> {
        let mut statement = self.connection.prepare(
            "SELECT id, request_id, actor_kind, actor_name, target_runtime_id, target_title,
                    state, user_prompt, assistant_message, created_at, updated_at
             FROM agent_task_sessions
             WHERE request_id = ?1
             ORDER BY updated_at DESC, id DESC",
        )?;
        let records = statement
            .query_map(params![request_id], read_agent_task_session_record)?
            .collect::<Result<Vec<_>, _>>()?;
        self.with_proposals(records)
    }

    fn get(&self, id: &str) -> Result<Option<AgentTaskSessionRecord>, rusqlite::Error> {
        let mut statement = self.connection.prepare(
            "SELECT id, request_id, actor_kind, actor_name, target_runtime_id, target_title,
                    state, user_prompt, assistant_message, created_at, updated_at
             FROM agent_task_sessions
             WHERE id = ?1",
        )?;
        let result = statement.query_row(params![id], read_agent_task_session_record);
        match result {
            Ok(record) => Ok(Some(self.with_proposals(vec![record])?.remove(0))),
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            Err(error) => Err(error),
        }
    }

    fn with_proposals(
        &self,
        records: Vec<AgentTaskSessionRecord>,
    ) -> Result<Vec<AgentTaskSessionRecord>, rusqlite::Error> {
        records
            .into_iter()
            .map(|mut record| {
                record.proposals = self.list_proposals(&record.id)?;
                Ok(record)
            })
            .collect()
    }

    fn list_proposals(
        &self,
        task_id: &str,
    ) -> Result<Vec<AgentTaskProposalRecord>, rusqlite::Error> {
        let mut statement = self.connection.prepare(
            "SELECT id, command, explanation, risk, state, sort_order, created_at, updated_at
             FROM agent_task_proposals
             WHERE task_id = ?1
             ORDER BY sort_order ASC, created_at ASC, id ASC",
        )?;
        let proposals = statement
            .query_map(params![task_id], read_agent_task_proposal_record)?
            .collect();
        proposals
    }
}

fn read_agent_task_session_record(
    row: &rusqlite::Row<'_>,
) -> rusqlite::Result<AgentTaskSessionRecord> {
    Ok(AgentTaskSessionRecord {
        id: row.get(0)?,
        request_id: row.get(1)?,
        actor_kind: row.get(2)?,
        actor_name: row.get(3)?,
        target_runtime_id: row.get(4)?,
        target_title: row.get(5)?,
        state: row.get(6)?,
        user_prompt: row.get(7)?,
        assistant_message: row.get(8)?,
        created_at: row.get(9)?,
        updated_at: row.get(10)?,
        proposals: Vec::new(),
    })
}

fn read_agent_task_proposal_record(
    row: &rusqlite::Row<'_>,
) -> rusqlite::Result<AgentTaskProposalRecord> {
    let sort_order: i64 = row.get(5)?;
    Ok(AgentTaskProposalRecord {
        id: row.get(0)?,
        command: row.get(1)?,
        explanation: row.get(2)?,
        risk: row.get(3)?,
        state: row.get(4)?,
        sort_order: sort_order.max(0) as u32,
        created_at: row.get(6)?,
        updated_at: row.get(7)?,
    })
}

#[cfg(test)]
mod agent_task_repository_tests {
    use rusqlite::Connection;

    use crate::domain::agent::{AgentTaskProposalDraft, AgentTaskSessionDraft};
    use crate::infrastructure::db::apply_migrations;

    use super::AgentTaskRepository;

    #[test]
    fn agent_tasks_are_recorded_and_listed_with_proposals() {
        let connection = Connection::open_in_memory().expect("open database");
        apply_migrations(&connection).expect("migrate");
        let repository = AgentTaskRepository::new(connection);

        let record = repository
            .record_session(
                &AgentTaskSessionDraft {
                    id: "task-1".to_string(),
                    request_id: "req-1".to_string(),
                    actor_kind: "builtInAI".to_string(),
                    actor_name: "Stacio AI".to_string(),
                    target_runtime_id: Some("term-1".to_string()),
                    target_title: "prod@example.com".to_string(),
                    state: "awaitingUser".to_string(),
                    user_prompt: "帮我看磁盘".to_string(),
                    assistant_message: "建议查看磁盘。".to_string(),
                },
                vec![
                    AgentTaskProposalDraft {
                        id: "proposal-1".to_string(),
                        command: "TOKEN=[redacted] df -h".to_string(),
                        explanation: "查看磁盘占用".to_string(),
                        risk: "readOnly".to_string(),
                        state: "proposed".to_string(),
                        sort_order: 0,
                    },
                    AgentTaskProposalDraft {
                        id: "proposal-2".to_string(),
                        command: "du -sh /var/log".to_string(),
                        explanation: "定位日志占用".to_string(),
                        risk: "readOnly".to_string(),
                        state: "proposed".to_string(),
                        sort_order: 1,
                    },
                ],
            )
            .expect("record task");

        let recent = repository.list_recent(10).expect("list recent tasks");
        let by_request = repository
            .list_by_request_id("req-1")
            .expect("list tasks by request");

        assert_eq!(recent, vec![record.clone()]);
        assert_eq!(by_request, vec![record]);
        assert_eq!(recent[0].request_id, "req-1");
        assert_eq!(recent[0].target_runtime_id.as_deref(), Some("term-1"));
        assert_eq!(recent[0].state, "awaitingUser");
        assert_eq!(recent[0].proposals.len(), 2);
        assert_eq!(recent[0].proposals[0].command, "TOKEN=[redacted] df -h");
        assert_eq!(recent[0].proposals[1].command, "du -sh /var/log");
        assert!(!format!("{recent:?}").contains("secret-value"));
    }
}
