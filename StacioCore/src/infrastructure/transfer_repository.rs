use chrono::Utc;
use rusqlite::{params, Connection};
use uuid::Uuid;

use crate::domain::scp::{ScpDirection, ScpTransferJob, ScpTransferProgress};

const MAX_RESTORED_EVENTS_PER_JOB: i64 = 200;

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct TransferJobRecord {
    pub job: ScpTransferJob,
    pub session_id: Option<String>,
    pub status: String,
    pub bytes_done: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct TransferEventRecord {
    pub id: String,
    pub job_id: String,
    pub event_type: String,
    pub message: Option<String>,
    pub bytes_done: Option<u64>,
    pub created_at: String,
}

pub struct TransferRepository {
    connection: Connection,
}

impl TransferRepository {
    pub fn new(connection: Connection) -> Self {
        Self { connection }
    }

    pub fn upsert_job(
        &self,
        session_id: Option<String>,
        job: &ScpTransferJob,
        status: &str,
        bytes_done: u64,
    ) -> Result<(), rusqlite::Error> {
        let now = Utc::now().to_rfc3339();
        let (local_path, remote_path) = job_paths(job);
        self.connection.execute(
            "INSERT INTO transfer_jobs
             (id, session_id, direction, engine, local_path, remote_path, status, bytes_total, bytes_done, created_at, updated_at)
             VALUES (?1, ?2, ?3, 'scp', ?4, ?5, ?6, ?7, ?8, ?9, ?9)
             ON CONFLICT(id) DO UPDATE SET
               session_id = excluded.session_id,
               direction = excluded.direction,
               local_path = excluded.local_path,
               remote_path = excluded.remote_path,
               status = excluded.status,
               bytes_total = excluded.bytes_total,
               bytes_done = excluded.bytes_done,
               updated_at = excluded.updated_at",
            params![
                job.id,
                session_id,
                direction_label(&job.direction),
                local_path,
                remote_path,
                status,
                job.bytes_total as i64,
                bytes_done as i64,
                now
            ],
        )?;

        Ok(())
    }

    pub fn append_progress(
        &self,
        progress: &ScpTransferProgress,
    ) -> Result<TransferEventRecord, rusqlite::Error> {
        self.append_progress_with_message(progress, None)
    }

    pub fn append_progress_with_message(
        &self,
        progress: &ScpTransferProgress,
        message: Option<String>,
    ) -> Result<TransferEventRecord, rusqlite::Error> {
        let event = TransferEventRecord {
            id: Uuid::new_v4().to_string(),
            job_id: progress.job_id.clone(),
            event_type: progress.status.clone(),
            message,
            bytes_done: Some(progress.bytes_done),
            created_at: Utc::now().to_rfc3339(),
        };

        self.connection.execute(
            "INSERT INTO transfer_events (id, job_id, event_type, message, bytes_done, created_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![
                event.id,
                event.job_id,
                event.event_type,
                event.message,
                progress.bytes_done as i64,
                event.created_at
            ],
        )?;
        self.connection.execute(
            "UPDATE transfer_jobs
             SET status = ?2, bytes_done = ?3, updated_at = ?4,
                 started_at = CASE WHEN started_at IS NULL AND ?2 = 'running' THEN ?4 ELSE started_at END,
                 finished_at = CASE WHEN ?2 IN ('completed', 'failed', 'canceled') THEN ?4 ELSE finished_at END
             WHERE id = ?1",
            params![
                progress.job_id,
                progress.status,
                progress.bytes_done as i64,
                event.created_at
            ],
        )?;

        Ok(event)
    }

    pub fn list_recent_jobs(&self) -> Result<Vec<TransferJobRecord>, rusqlite::Error> {
        let mut statement = self.connection.prepare(
            "SELECT id, session_id, direction, local_path, remote_path, status, bytes_total, bytes_done
             FROM transfer_jobs
             ORDER BY created_at ASC",
        )?;
        let records = statement
            .query_map([], read_transfer_job)?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(records)
    }

    pub fn list_events_for_job(
        &self,
        job_id: &str,
    ) -> Result<Vec<TransferEventRecord>, rusqlite::Error> {
        let mut statement = self.connection.prepare(
            "SELECT id, job_id, event_type, message, bytes_done, created_at
             FROM (
               SELECT id, job_id, event_type, message, bytes_done, created_at
               FROM transfer_events
               WHERE job_id = ?1
               ORDER BY created_at DESC
               LIMIT ?2
             )
             ORDER BY created_at ASC",
        )?;
        let records = statement
            .query_map(
                params![job_id, MAX_RESTORED_EVENTS_PER_JOB],
                read_transfer_event,
            )?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(records)
    }

    pub fn delete_finished_jobs(&self) -> Result<u32, rusqlite::Error> {
        let deleted = self.connection.execute(
            "DELETE FROM transfer_jobs
             WHERE status IN ('completed', 'failed', 'canceled')",
            [],
        )?;
        Ok(deleted as u32)
    }
}

fn read_transfer_job(row: &rusqlite::Row<'_>) -> rusqlite::Result<TransferJobRecord> {
    let direction: String = row.get(2)?;
    let local_path: String = row.get(3)?;
    let remote_path: String = row.get(4)?;
    let bytes_total: i64 = row.get(6)?;
    let bytes_done: i64 = row.get(7)?;
    let direction = parse_direction(&direction)?;
    let (source_path, destination_path) = match direction {
        ScpDirection::Upload => (local_path, remote_path),
        ScpDirection::Download => (remote_path, local_path),
    };

    Ok(TransferJobRecord {
        job: ScpTransferJob {
            id: row.get(0)?,
            direction,
            source_path,
            destination_path,
            bytes_total: bytes_total as u64,
        },
        session_id: row.get(1)?,
        status: row.get(5)?,
        bytes_done: bytes_done as u64,
    })
}

fn read_transfer_event(row: &rusqlite::Row<'_>) -> rusqlite::Result<TransferEventRecord> {
    let bytes_done: Option<i64> = row.get(4)?;
    Ok(TransferEventRecord {
        id: row.get(0)?,
        job_id: row.get(1)?,
        event_type: row.get(2)?,
        message: row.get(3)?,
        bytes_done: bytes_done.map(|value| value as u64),
        created_at: row.get(5)?,
    })
}

fn job_paths(job: &ScpTransferJob) -> (&str, &str) {
    match job.direction {
        ScpDirection::Upload => (&job.source_path, &job.destination_path),
        ScpDirection::Download => (&job.destination_path, &job.source_path),
    }
}

fn direction_label(direction: &ScpDirection) -> &'static str {
    match direction {
        ScpDirection::Upload => "upload",
        ScpDirection::Download => "download",
    }
}

fn parse_direction(direction: &str) -> rusqlite::Result<ScpDirection> {
    match direction {
        "upload" => Ok(ScpDirection::Upload),
        "download" => Ok(ScpDirection::Download),
        _ => Err(rusqlite::Error::InvalidQuery),
    }
}

#[cfg(test)]
mod transfer_repository_tests {
    use rusqlite::{params, Connection};

    use crate::domain::scp::{ScpDirection, ScpTransferJob, ScpTransferProgress};
    use crate::infrastructure::db::apply_migrations;

    use super::{TransferRepository, MAX_RESTORED_EVENTS_PER_JOB};

    #[test]
    fn records_transfer_job_and_progress_events_without_system_commands_or_secrets() {
        let repository = TransferRepository::new(migrated_connection());
        let job = ScpTransferJob {
            id: "job_history_1".to_string(),
            direction: ScpDirection::Upload,
            source_path: "/Users/alice/build.zip".to_string(),
            destination_path: "/srv/releases/build.zip".to_string(),
            bytes_total: 100,
        };

        repository
            .upsert_job(None, &job, "queued", 0)
            .expect("insert job");
        repository
            .append_progress(&ScpTransferProgress {
                job_id: job.id.clone(),
                bytes_done: 25,
                bytes_total: 100,
                status: "running".to_string(),
            })
            .expect("append progress");
        repository
            .append_progress(&ScpTransferProgress {
                job_id: job.id.clone(),
                bytes_done: 100,
                bytes_total: 100,
                status: "completed".to_string(),
            })
            .expect("append completed");

        let jobs = repository.list_recent_jobs().expect("jobs");
        let events = repository.list_events_for_job(&job.id).expect("events");
        let serialized = serde_json::to_string(&(jobs.clone(), events.clone())).expect("serialize");

        assert_eq!(jobs.len(), 1);
        assert_eq!(jobs[0].job, job);
        assert_eq!(jobs[0].status, "completed");
        assert_eq!(jobs[0].bytes_done, 100);
        assert_eq!(events.len(), 2);
        assert_eq!(events[0].event_type, "running");
        assert_eq!(events[1].event_type, "completed");
        assert!(!serialized.contains("secret"));
        assert!(!serialized.contains("password"));
        assert!(!serialized.contains("scp "));
        assert!(!serialized.contains("sftp "));
        assert!(!serialized.contains("rsync "));
    }

    #[test]
    fn records_failed_transfer_message_without_command_strings() {
        let repository = TransferRepository::new(migrated_connection());
        let job = ScpTransferJob {
            id: "job_failed_message".to_string(),
            direction: ScpDirection::Upload,
            source_path: "/Users/alice/build.zip".to_string(),
            destination_path: "/srv/releases/build.zip".to_string(),
            bytes_total: 100,
        };

        repository
            .upsert_job(None, &job, "queued", 0)
            .expect("insert job");
        repository
            .append_progress_with_message(
                &ScpTransferProgress {
                    job_id: job.id.clone(),
                    bytes_done: 40,
                    bytes_total: 100,
                    status: "failed".to_string(),
                },
                Some("Permission denied".to_string()),
            )
            .expect("append failed");

        let jobs = repository.list_recent_jobs().expect("jobs");
        let events = repository.list_events_for_job(&job.id).expect("events");
        let serialized = serde_json::to_string(&(jobs.clone(), events.clone())).expect("serialize");

        assert_eq!(jobs[0].status, "failed");
        assert_eq!(jobs[0].bytes_done, 40);
        assert_eq!(events[0].event_type, "failed");
        assert_eq!(events[0].message, Some("Permission denied".to_string()));
        assert!(!serialized.contains("scp "));
        assert!(!serialized.contains("sftp "));
        assert!(!serialized.contains("rsync "));
    }

    #[test]
    fn restores_download_jobs_with_source_and_destination_paths_intact() {
        let connection = migrated_connection();
        connection
            .execute(
                "INSERT INTO sessions (id, name, protocol, host, port, tags_json, created_at, updated_at)
                 VALUES ('session_1', 'Logs', 'ssh', 'logs.example.com', 22, '[]', '2026-05-27T00:00:00Z', '2026-05-27T00:00:00Z')",
                [],
            )
            .expect("insert session");
        let repository = TransferRepository::new(connection);
        let job = ScpTransferJob {
            id: "job_download_history".to_string(),
            direction: ScpDirection::Download,
            source_path: "/srv/logs/app.log".to_string(),
            destination_path: "/Users/alice/app.log".to_string(),
            bytes_total: 512,
        };

        repository
            .upsert_job(Some("session_1".to_string()), &job, "queued", 0)
            .expect("insert download job");

        let jobs = repository.list_recent_jobs().expect("jobs");

        assert_eq!(jobs.len(), 1);
        assert_eq!(jobs[0].job, job);
        assert_eq!(jobs[0].session_id, Some("session_1".to_string()));
    }

    #[test]
    fn deletes_finished_jobs_and_cascades_events_but_keeps_active_jobs() {
        let repository = TransferRepository::new(migrated_connection());
        let finished = ScpTransferJob {
            id: "job_finished_delete".to_string(),
            direction: ScpDirection::Upload,
            source_path: "/Users/alice/done.zip".to_string(),
            destination_path: "/srv/done.zip".to_string(),
            bytes_total: 100,
        };
        let active = ScpTransferJob {
            id: "job_active_keep".to_string(),
            direction: ScpDirection::Download,
            source_path: "/srv/active.zip".to_string(),
            destination_path: "/Users/alice/active.zip".to_string(),
            bytes_total: 200,
        };

        repository
            .upsert_job(None, &finished, "queued", 0)
            .expect("insert finished");
        repository
            .append_progress(&ScpTransferProgress {
                job_id: finished.id.clone(),
                bytes_done: 100,
                bytes_total: 100,
                status: "completed".to_string(),
            })
            .expect("finish");
        repository
            .upsert_job(None, &active, "running", 50)
            .expect("insert active");
        repository
            .append_progress(&ScpTransferProgress {
                job_id: active.id.clone(),
                bytes_done: 50,
                bytes_total: 200,
                status: "running".to_string(),
            })
            .expect("active progress");

        let deleted = repository.delete_finished_jobs().expect("delete");
        let jobs = repository.list_recent_jobs().expect("jobs");
        let finished_events = repository
            .list_events_for_job(&finished.id)
            .expect("finished events");
        let active_events = repository
            .list_events_for_job(&active.id)
            .expect("active events");

        assert_eq!(deleted, 1);
        assert_eq!(jobs.len(), 1);
        assert_eq!(jobs[0].job.id, active.id);
        assert!(finished_events.is_empty());
        assert_eq!(active_events.len(), 1);
    }

    #[test]
    fn list_events_for_job_restores_recent_event_window_only() {
        let connection = migrated_connection();
        let repository = TransferRepository::new(connection);
        let job = ScpTransferJob {
            id: "job_many_events".to_string(),
            direction: ScpDirection::Download,
            source_path: "/srv/big.log".to_string(),
            destination_path: "/Users/alice/big.log".to_string(),
            bytes_total: 250,
        };
        repository
            .upsert_job(None, &job, "running", 0)
            .expect("insert job");
        for index in 0..250 {
            repository
                .connection
                .execute(
                    "INSERT INTO transfer_events (id, job_id, event_type, message, bytes_done, created_at)
                     VALUES (?1, ?2, 'running', NULL, ?3, ?4)",
                    params![
                        format!("event_{index:03}"),
                        job.id,
                        index as i64,
                        format!("2026-05-27T00:{index:03}:00Z")
                    ],
                )
                .expect("insert event");
        }

        let events = repository.list_events_for_job(&job.id).expect("events");

        assert_eq!(events.len(), MAX_RESTORED_EVENTS_PER_JOB as usize);
        assert_eq!(events[0].id, "event_050");
        assert_eq!(events[199].id, "event_249");
    }

    fn migrated_connection() -> Connection {
        let connection = Connection::open_in_memory().expect("open database");
        apply_migrations(&connection).expect("migrate");
        connection
    }
}
