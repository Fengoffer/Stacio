use chrono::Utc;
use rusqlite::{params, Connection};
use uuid::Uuid;

use crate::domain::agent::AgentActionAuditEvent;

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct AgentActionAuditRecord {
    pub id: String,
    pub request_id: String,
    pub actor_kind: String,
    pub actor_name: String,
    pub target_runtime_id: Option<String>,
    pub target_title: String,
    pub action_kind: String,
    pub risk: String,
    pub state: String,
    pub redacted_input: String,
    pub environment: String,
    pub approval_mode: String,
    pub policy_decision: String,
    pub redaction_version: String,
    pub created_at: String,
}

pub struct AgentActionAuditRepository {
    connection: Connection,
}

impl AgentActionAuditRepository {
    pub fn new(connection: Connection) -> Self {
        Self { connection }
    }

    pub fn record(
        &self,
        event: &AgentActionAuditEvent,
    ) -> Result<AgentActionAuditRecord, rusqlite::Error> {
        let record = AgentActionAuditRecord {
            id: Uuid::new_v4().to_string(),
            request_id: event.request_id.clone(),
            actor_kind: event.actor_kind.clone(),
            actor_name: event.actor_name.clone(),
            target_runtime_id: event.target_runtime_id.clone(),
            target_title: event.target_title.clone(),
            action_kind: event.action_kind.clone(),
            risk: event.risk.clone(),
            state: event.state.clone(),
            redacted_input: event.redacted_input.clone(),
            environment: event.environment.clone(),
            approval_mode: event.approval_mode.clone(),
            policy_decision: event.policy_decision.clone(),
            redaction_version: event.redaction_version.clone(),
            created_at: Utc::now().to_rfc3339(),
        };
        self.connection.execute(
            "INSERT INTO agent_action_events
             (id, request_id, actor_kind, actor_name, target_runtime_id, target_title, action_kind, risk, state, redacted_input, environment, approval_mode, policy_decision, redaction_version, created_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)",
            params![
                record.id,
                record.request_id,
                record.actor_kind,
                record.actor_name,
                record.target_runtime_id,
                record.target_title,
                record.action_kind,
                record.risk,
                record.state,
                record.redacted_input,
                record.environment,
                record.approval_mode,
                record.policy_decision,
                record.redaction_version,
                record.created_at
            ],
        )?;
        Ok(record)
    }

    pub fn list(&self, limit: u32) -> Result<Vec<AgentActionAuditRecord>, rusqlite::Error> {
        let mut statement = self.connection.prepare(
            "SELECT id, request_id, actor_kind, actor_name, target_runtime_id, target_title,
                    action_kind, risk, state, redacted_input, environment, approval_mode,
                    policy_decision, redaction_version, created_at
             FROM agent_action_events
             ORDER BY created_at DESC, id DESC
             LIMIT ?1",
        )?;
        let records = statement
            .query_map(params![limit as i64], read_agent_action_audit_record)?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(records)
    }
}

fn read_agent_action_audit_record(
    row: &rusqlite::Row<'_>,
) -> rusqlite::Result<AgentActionAuditRecord> {
    Ok(AgentActionAuditRecord {
        id: row.get(0)?,
        request_id: row.get(1)?,
        actor_kind: row.get(2)?,
        actor_name: row.get(3)?,
        target_runtime_id: row.get(4)?,
        target_title: row.get(5)?,
        action_kind: row.get(6)?,
        risk: row.get(7)?,
        state: row.get(8)?,
        redacted_input: row.get(9)?,
        environment: row.get(10)?,
        approval_mode: row.get(11)?,
        policy_decision: row.get(12)?,
        redaction_version: row.get(13)?,
        created_at: row.get(14)?,
    })
}

#[cfg(test)]
mod agent_audit_repository_tests {
    use rusqlite::Connection;

    use crate::domain::agent::AgentActionAuditEvent;
    use crate::infrastructure::db::apply_migrations;

    use super::AgentActionAuditRepository;

    #[test]
    fn agent_action_records_are_listed_without_secret_values() {
        let connection = Connection::open_in_memory().expect("open database");
        apply_migrations(&connection).expect("migrate");
        let repository = AgentActionAuditRepository::new(connection);

        let record = repository
            .record(&AgentActionAuditEvent {
                request_id: "req-1".to_string(),
                actor_kind: "externalCLI".to_string(),
                actor_name: "codex".to_string(),
                target_runtime_id: Some("term_1".to_string()),
                target_title: "prod@example.com".to_string(),
                action_kind: "runCommand".to_string(),
                risk: "destructive".to_string(),
                state: "running".to_string(),
                redacted_input: "TOKEN=[redacted] rm -rf /tmp/build".to_string(),
                environment: "production".to_string(),
                approval_mode: "requireEveryCommand".to_string(),
                policy_decision: "confirmed".to_string(),
                redaction_version: "stacio.agent-redaction.v1".to_string(),
            })
            .expect("record event");
        let records = repository.list(10).expect("list events");

        assert_eq!(records, vec![record]);
        assert_eq!(records[0].request_id, "req-1");
        assert_eq!(records[0].actor_name, "codex");
        assert_eq!(records[0].environment, "production");
        assert_eq!(records[0].approval_mode, "requireEveryCommand");
        assert_eq!(records[0].policy_decision, "confirmed");
        assert_eq!(records[0].redaction_version, "stacio.agent-redaction.v1");
        assert!(!records[0].redacted_input.contains("secret-value"));
    }
}
