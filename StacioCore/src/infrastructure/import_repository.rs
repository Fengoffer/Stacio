use chrono::Utc;
use rusqlite::{params, Connection};
use uuid::Uuid;

use crate::domain::session::SessionError;
use crate::services::import_service::ImportReport;

pub struct ImportReportRepository {
    connection: Connection,
}

impl ImportReportRepository {
    pub fn new(connection: Connection) -> Self {
        Self { connection }
    }

    pub fn record_report(
        &self,
        source_type: String,
        source_name: String,
        status: String,
        imported_count: u32,
        skipped_count: u32,
        failed_count: u32,
        issues: Vec<String>,
    ) -> Result<ImportReport, SessionError> {
        let report = ImportReport {
            id: Uuid::new_v4().to_string(),
            source_type,
            source_name,
            status,
            imported_count,
            skipped_count,
            failed_count,
            issues,
            created_at: Utc::now().to_rfc3339(),
        };
        let issues_json =
            serde_json::to_string(&report.issues).map_err(|error| SessionError::Database {
                message: error.to_string(),
            })?;

        self.connection.execute(
            "INSERT INTO import_reports
             (id, source_type, source_name, status, imported_count, skipped_count, failed_count, issues_json, created_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
            params![
                report.id,
                report.source_type,
                report.source_name,
                report.status,
                i64::from(report.imported_count),
                i64::from(report.skipped_count),
                i64::from(report.failed_count),
                issues_json,
                report.created_at
            ],
        )?;

        Ok(report)
    }

    pub fn list_reports(&self) -> Result<Vec<ImportReport>, SessionError> {
        let mut statement = self.connection.prepare(
            "SELECT id, source_type, source_name, status, imported_count, skipped_count, failed_count, issues_json, created_at
             FROM import_reports ORDER BY created_at",
        )?;
        let reports = statement
            .query_map([], read_report)?
            .collect::<Result<Vec<_>, _>>()?;

        Ok(reports)
    }
}

fn read_report(row: &rusqlite::Row<'_>) -> rusqlite::Result<ImportReport> {
    let issues_json: String = row.get(7)?;
    let issues = serde_json::from_str(&issues_json).unwrap_or_default();
    let imported_count: i64 = row.get(4)?;
    let skipped_count: i64 = row.get(5)?;
    let failed_count: i64 = row.get(6)?;

    Ok(ImportReport {
        id: row.get(0)?,
        source_type: row.get(1)?,
        source_name: row.get(2)?,
        status: row.get(3)?,
        imported_count: imported_count as u32,
        skipped_count: skipped_count as u32,
        failed_count: failed_count as u32,
        issues,
        created_at: row.get(8)?,
    })
}

#[cfg(test)]
mod import_repository_tests {
    use rusqlite::Connection;

    use crate::infrastructure::db::apply_migrations;

    use super::ImportReportRepository;

    #[test]
    fn records_and_lists_import_reports_without_secret_values() {
        let connection = Connection::open_in_memory().expect("open database");
        apply_migrations(&connection).expect("migrate");
        let repository = ImportReportRepository::new(connection);

        let report = repository
            .record_report(
                "csv".to_string(),
                "sessions.csv".to_string(),
                "partial".to_string(),
                1,
                1,
                0,
                vec!["API skipped because a session with the same name exists".to_string()],
            )
            .expect("report");

        let reports = repository.list_reports().expect("reports");
        let serialized = serde_json::to_string(&reports).expect("serialize");

        assert_eq!(reports, vec![report]);
        assert!(serialized.contains("sessions.csv"));
        assert!(!serialized.contains("password"));
        assert!(!serialized.contains("secret"));
    }
}
