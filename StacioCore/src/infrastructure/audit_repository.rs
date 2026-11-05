use chrono::Utc;
use rusqlite::{params, Connection};
use uuid::Uuid;

use crate::services::multiexec_service::BroadcastAuditEvent;

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct BroadcastAuditRecord {
    pub id: String,
    pub trace_id: String,
    pub target_count: u32,
    pub sent_count: u32,
    pub failed_count: u32,
    pub redacted_input: String,
    pub executed: bool,
    pub created_at: String,
}

pub struct AuditEventRepository {
    connection: Connection,
}

impl AuditEventRepository {
    pub fn new(connection: Connection) -> Self {
        Self { connection }
    }

    pub fn record_broadcast_event(
        &self,
        event: &BroadcastAuditEvent,
    ) -> Result<BroadcastAuditRecord, rusqlite::Error> {
        let record = BroadcastAuditRecord {
            id: Uuid::new_v4().to_string(),
            trace_id: Uuid::new_v4().to_string(),
            target_count: event.target_count,
            sent_count: event.sent_count,
            failed_count: event.failed_count,
            redacted_input: event.redacted_input.clone(),
            executed: event.executed,
            created_at: Utc::now().to_rfc3339(),
        };
        self.connection.execute(
            "INSERT INTO audit_events
             (id, trace_id, event_type, severity, target_count, sent_count, failed_count, redacted_input, executed, created_at)
             VALUES (?1, ?2, 'multiexec.broadcast', ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
            params![
                record.id,
                record.trace_id,
                severity_for(event),
                record.target_count as i64,
                record.sent_count as i64,
                record.failed_count as i64,
                record.redacted_input,
                if record.executed { 1_i64 } else { 0_i64 },
                record.created_at
            ],
        )?;
        Ok(record)
    }

    pub fn list_broadcast_events(
        &self,
        limit: u32,
    ) -> Result<Vec<BroadcastAuditRecord>, rusqlite::Error> {
        let mut statement = self.connection.prepare(
            "SELECT id, trace_id, target_count, sent_count, failed_count, redacted_input, executed, created_at
             FROM audit_events
             WHERE event_type = 'multiexec.broadcast'
             ORDER BY created_at DESC, id DESC
             LIMIT ?1",
        )?;
        let records = statement
            .query_map(params![limit as i64], read_broadcast_audit_record)?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(records)
    }
}

fn read_broadcast_audit_record(row: &rusqlite::Row<'_>) -> rusqlite::Result<BroadcastAuditRecord> {
    let target_count: i64 = row.get(2)?;
    let sent_count: i64 = row.get(3)?;
    let failed_count: i64 = row.get(4)?;
    let executed: i64 = row.get(6)?;
    Ok(BroadcastAuditRecord {
        id: row.get(0)?,
        trace_id: row.get(1)?,
        target_count: target_count as u32,
        sent_count: sent_count as u32,
        failed_count: failed_count as u32,
        redacted_input: row.get(5)?,
        executed: executed != 0,
        created_at: row.get(7)?,
    })
}

fn severity_for(event: &BroadcastAuditEvent) -> &'static str {
    if event.failed_count > 0 {
        "warning"
    } else {
        "info"
    }
}

#[cfg(test)]
mod audit_repository_tests {
    use rusqlite::Connection;

    use crate::infrastructure::db::apply_migrations;
    use crate::services::multiexec_service::BroadcastAuditEvent;

    use super::AuditEventRepository;

    #[test]
    fn records_and_lists_broadcast_audit_events_without_secret_values() {
        let connection = Connection::open_in_memory().expect("open database");
        apply_migrations(&connection).expect("migrate");
        let repository = AuditEventRepository::new(connection);

        let record = repository
            .record_broadcast_event(&BroadcastAuditEvent {
                target_count: 2,
                sent_count: 1,
                failed_count: 1,
                redacted_input: "export TOKEN=[redacted]".to_string(),
                executed: true,
            })
            .expect("record event");
        let records = repository.list_broadcast_events(10).expect("list events");

        assert_eq!(records, vec![record]);
        assert_eq!(records[0].target_count, 2);
        assert_eq!(records[0].sent_count, 1);
        assert_eq!(records[0].failed_count, 1);
        assert!(records[0].executed);
        assert!(!records[0].redacted_input.contains("secret-value"));
    }
}
