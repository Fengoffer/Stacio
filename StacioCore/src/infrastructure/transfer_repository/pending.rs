use super::{TransferEventRecord, TransferRepository};
use crate::domain::scp::ScpTransferJob;
use crate::infrastructure::db::apply_migrations_with_timeout;
use rusqlite::{
    params, Connection, Error, ErrorCode, OptionalExtension, Result, TransactionBehavior,
};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs::OpenOptions;
#[cfg(unix)]
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use std::time::Duration;
use uuid::Uuid;

#[derive(Serialize, Deserialize)]
pub enum HistoryChange {
    Job {
        session_id: Option<String>,
        job: ScpTransferJob,
        status: String,
        bytes_done: u64,
    },
    Event(TransferEventRecord),
    ClearFinished,
    DeleteFinished(String),
}

impl HistoryChange {
    fn apply(&self, repository: &TransferRepository) -> Result<()> {
        match self {
            Self::Job {
                session_id,
                job,
                status,
                bytes_done,
            } => repository.upsert_job(session_id.clone(), job, status, *bytes_done),
            Self::Event(event) => repository.insert_event(event),
            Self::DeleteFinished(id) => repository.delete_finished_job(id).map(|_| ()),
            Self::ClearFinished => repository.delete_finished_jobs().map(|_| ()),
        }
    }
}

fn busy(error: &Error) -> bool {
    matches!(
        error.sqlite_error_code(),
        Some(ErrorCode::DatabaseBusy | ErrorCode::DatabaseLocked)
    )
}

fn journal_path(database: &str) -> PathBuf {
    PathBuf::from(format!("{database}.transfer-pending"))
}

fn journal(path: &Path) -> Result<Connection> {
    // It contains the same filenames and diagnostics as the primary database.
    let mut options = OpenOptions::new();
    options.create_new(true).write(true);
    #[cfg(unix)]
    options.mode(0o600);
    match options.open(path) {
        Ok(_) => (),
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => (),
        Err(e) => return Err(Error::ToSqlConversionFailure(Box::new(e))),
    }
    let connection = Connection::open(path)?;
    connection.execute_batch("CREATE TABLE IF NOT EXISTS pending(seq INTEGER PRIMARY KEY, id TEXT NOT NULL UNIQUE, payload TEXT NOT NULL)")?;
    Ok(connection)
}

pub fn open_history(database: &str) -> Result<TransferRepository> {
    let connection = Connection::open(database)?;
    apply_migrations_with_timeout(&connection, Duration::from_millis(75))?;
    let repository = TransferRepository::new(connection);
    let path = journal_path(database);
    if path
        .try_exists()
        .map_err(|e| Error::ToSqlConversionFailure(Box::new(e)))?
    {
        replay(&repository, &mut journal(&path)?)?;
    }
    Ok(repository)
}

pub fn save_change(database: &str, change: HistoryChange) -> Result<()> {
    let path = journal_path(database);
    // Append behind earlier staged writes without waiting on the primary lock
    // once per sample. One statement orders this check and append against replay.
    if path
        .try_exists()
        .map_err(|e| Error::ToSqlConversionFailure(Box::new(e)))?
    {
        let payload = serde_json::to_string(&change)
            .map_err(|e| Error::ToSqlConversionFailure(Box::new(e)))?;
        if journal(&path)?.execute(
            "INSERT INTO pending(id, payload) SELECT ?1, ?2 WHERE EXISTS (SELECT 1 FROM pending)",
            params![Uuid::new_v4().to_string(), payload],
        )? > 0
        {
            retry_after_unlock(database);
            return Ok(());
        }
    }
    let result = open_history(database).and_then(|repository| {
        let transaction = repository.connection.unchecked_transaction()?;
        change.apply(&repository)?;
        transaction.commit()
    });
    match result {
        Err(error) if busy(&error) => {
            let payload = serde_json::to_string(&change)
                .map_err(|e| Error::ToSqlConversionFailure(Box::new(e)))?;
            journal(&journal_path(database))?.execute(
                "INSERT INTO pending(id, payload) VALUES (?1, ?2)",
                params![Uuid::new_v4().to_string(), payload],
            )?;
            retry_after_unlock(database);
            Ok(())
        }
        result => result,
    }
}

fn replay(repository: &TransferRepository, journal: &mut Connection) -> Result<()> {
    loop {
        let queue = journal.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let items = queue
            .prepare("SELECT seq, id, payload FROM pending ORDER BY seq LIMIT 128")?
            .query_map([], |r| {
                Ok((
                    r.get::<_, i64>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, String>(2)?,
                ))
            })?
            .collect::<Result<Vec<_>>>()?;
        let Some((last_sequence, last_id, _)) = items.last() else {
            return Ok(());
        };
        let transaction = repository.connection.unchecked_transaction()?;
        transaction.execute_batch("CREATE TABLE IF NOT EXISTS transfer_history_replay(singleton INTEGER PRIMARY KEY, last_id TEXT NOT NULL)")?;
        let committed: Option<String> = transaction
            .query_row(
                "SELECT last_id FROM transfer_history_replay WHERE singleton=1",
                [],
                |r| r.get(0),
            )
            .optional()?;
        // If the process exited between the two commits, these rows already exist.
        let start = items
            .iter()
            .position(|(_, id, _)| Some(id) == committed.as_ref())
            .map_or(0, |i| i + 1);
        for (_, _, payload) in &items[start..] {
            let change: HistoryChange = serde_json::from_str(payload).map_err(|e| {
                Error::FromSqlConversionFailure(2, rusqlite::types::Type::Text, Box::new(e))
            })?;
            // Older journals may contain a late progress event after its job was
            // deleted. Such events have no history row to update.
            if let HistoryChange::Event(event) = &change {
                let exists: bool = transaction.query_row(
                    "SELECT EXISTS(SELECT 1 FROM transfer_jobs WHERE id = ?1)",
                    [&event.job_id],
                    |row| row.get(0),
                )?;
                if !exists {
                    continue;
                }
            }
            change.apply(repository)?;
        }
        transaction.execute(
            "INSERT OR REPLACE INTO transfer_history_replay(singleton, last_id) VALUES (1, ?1)",
            [last_id],
        )?;
        transaction.commit()?;
        queue.execute("DELETE FROM pending WHERE seq <= ?1", [last_sequence])?;
        queue.commit()?;
    }
}

// One background retry per busy database. Opening the history also replays it
// synchronously, including after the application exited with the lock still held.
fn retry_after_unlock(database: &str) {
    static RETRYING: OnceLock<Mutex<HashMap<String, bool>>> = OnceLock::new();
    let active = RETRYING.get_or_init(Mutex::default);
    if active
        .lock()
        .unwrap()
        .insert(database.to_owned(), true)
        .is_some()
    {
        return;
    }
    let database = database.to_owned();
    std::thread::spawn(move || loop {
        std::thread::sleep(Duration::from_millis(500));
        active.lock().unwrap().insert(database.clone(), false);
        let still_busy =
            journal_path(&database).is_file() && open_history(&database).is_err_and(|e| busy(&e));
        let mut active = active.lock().unwrap();
        // A write arriving during replay requests one more pass before we retire.
        if still_busy || active.get(&database) == Some(&true) {
            continue;
        }
        active.remove(&database);
        break;
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::scp::{ScpDirection, ScpTransferProgress};

    #[test]
    fn orphan_progress_in_an_old_journal_does_not_block_later_jobs() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("history.sqlite");
        let database = path.to_str().unwrap();
        let old = ScpTransferJob::new(ScpDirection::Upload, "src".into(), "old".into(), 12);
        let new = ScpTransferJob::new(ScpDirection::Upload, "src".into(), "new".into(), 12);
        let progress = ScpTransferProgress {
            job_id: old.id.clone(),
            status: "running".into(),
            bytes_total: 12,
            bytes_done: 1,
        };
        let changes = [
            HistoryChange::Job {
                session_id: None,
                job: old,
                status: "failed".into(),
                bytes_done: 0,
            },
            HistoryChange::ClearFinished,
            HistoryChange::Event(TransferEventRecord::new(&progress, None)),
            HistoryChange::Job {
                session_id: None,
                job: new.clone(),
                status: "queued".into(),
                bytes_done: 0,
            },
        ];
        let queue = journal(&journal_path(database)).unwrap();
        for (id, change) in changes.iter().enumerate() {
            queue
                .execute(
                    "INSERT INTO pending(id, payload) VALUES (?1, ?2)",
                    params![id.to_string(), serde_json::to_string(change).unwrap()],
                )
                .unwrap();
        }
        let rows = open_history(database).unwrap().list_recent_jobs().unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].job.id, new.id);
        assert_eq!(
            queue
                .query_row("SELECT count(*) FROM pending", [], |r| r.get::<_, u64>(0))
                .unwrap(),
            0
        );
    }

    #[test]
    fn recovery_after_main_commit_does_not_repeat_or_resurrect_history() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("history.sqlite");
        let database = path.to_str().unwrap();
        let job = ScpTransferJob::new(ScpDirection::Upload, "src".into(), "dst".into(), 12);
        let start = HistoryChange::Job {
            session_id: None,
            job: job.clone(),
            status: "queued".into(),
            bytes_done: 0,
        };
        let progress = ScpTransferProgress {
            job_id: job.id.clone(),
            status: "completed".into(),
            bytes_total: 12,
            bytes_done: 12,
        };
        let finish = HistoryChange::Event(TransferEventRecord::new(&progress, None));
        let mut queue = journal(&journal_path(database)).unwrap();
        let stage = |db: &Connection| {
            for (id, change) in [("first", &start), ("second", &finish)] {
                db.execute(
                    "INSERT INTO pending(id, payload) VALUES (?1, ?2)",
                    params![id, serde_json::to_string(change).unwrap()],
                )
                .unwrap();
            }
        };
        stage(&queue);
        let repository = open_history(database).unwrap();
        assert_eq!(
            repository.list_recent_jobs().unwrap()[0].status,
            "completed"
        );
        assert_eq!(repository.list_events_for_job(&job.id).unwrap().len(), 1);
        // The journal's final commit was lost while the primary database kept its commit.
        stage(&queue);
        replay(&repository, &mut queue).unwrap();
        assert_eq!(repository.list_events_for_job(&job.id).unwrap().len(), 1);
        assert_eq!(repository.delete_finished_jobs().unwrap(), 1);
        assert!(open_history(database)
            .unwrap()
            .list_recent_jobs()
            .unwrap()
            .is_empty());
    }
}
