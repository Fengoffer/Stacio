use crate::domain::scp::{ScpTransferError, ScpTransferJob, ScpTransferProgress};
use std::collections::{BTreeMap, HashSet, VecDeque};
use std::sync::{Mutex, OnceLock};

static CANCELLED_TRANSFERS: OnceLock<Mutex<HashSet<String>>> = OnceLock::new();
static PROGRESS_EVENTS: OnceLock<Mutex<BTreeMap<String, VecDeque<ScpTransferProgress>>>> =
    OnceLock::new();

pub trait ScpEngine {
    fn transfer(&self, job: &ScpTransferJob) -> Result<Vec<ScpTransferProgress>, ScpTransferError>;
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MockScpOutcome {
    Success,
    PermissionDenied,
    Interrupted,
}

pub struct MockScpEngine {
    outcome: MockScpOutcome,
}

impl MockScpEngine {
    pub fn new(outcome: MockScpOutcome) -> Self {
        Self { outcome }
    }
}

impl ScpEngine for MockScpEngine {
    fn transfer(&self, job: &ScpTransferJob) -> Result<Vec<ScpTransferProgress>, ScpTransferError> {
        match self.outcome {
            MockScpOutcome::Success => Ok(vec![
                ScpTransferProgress {
                    job_id: job.id.clone(),
                    bytes_done: 0,
                    bytes_total: job.bytes_total,
                    status: "queued".to_string(),
                },
                ScpTransferProgress {
                    job_id: job.id.clone(),
                    bytes_done: job.bytes_total,
                    bytes_total: job.bytes_total,
                    status: "completed".to_string(),
                },
            ]),
            MockScpOutcome::PermissionDenied => Err(ScpTransferError::PermissionDenied),
            MockScpOutcome::Interrupted => Err(ScpTransferError::Interrupted),
        }
    }
}

pub fn run_scp_transfer<E: ScpEngine>(
    job: ScpTransferJob,
    engine: &E,
) -> Result<Vec<ScpTransferProgress>, ScpTransferError> {
    engine.transfer(&job)
}

pub fn cancel_live_scp_transfer(job_id: &str) -> bool {
    let normalized = job_id.trim();
    if normalized.is_empty() {
        return false;
    }

    cancellation_registry()
        .lock()
        .expect("scp cancellation registry")
        .insert(normalized.to_string())
}

pub fn is_live_scp_transfer_cancelled(job_id: &str) -> bool {
    cancellation_registry()
        .lock()
        .expect("scp cancellation registry")
        .contains(job_id)
}

pub fn clear_live_scp_transfer_cancellation(job_id: &str) -> bool {
    cancellation_registry()
        .lock()
        .expect("scp cancellation registry")
        .remove(job_id)
}

pub fn with_live_scp_transfer_cancellation_scope<T, F>(job_id: &str, transfer: F) -> T
where
    F: FnOnce() -> T,
{
    let result = transfer();
    clear_live_scp_transfer_cancellation(job_id);
    result
}

pub fn record_live_scp_transfer_progress(progress: ScpTransferProgress) {
    progress_registry()
        .lock()
        .expect("scp progress registry")
        .entry(progress.job_id.clone())
        .or_default()
        .push_back(progress);
}

pub fn take_live_scp_transfer_progress_batch(job_id: &str) -> Vec<ScpTransferProgress> {
    progress_registry()
        .lock()
        .expect("scp progress registry")
        .remove(job_id)
        .map(|events| events.into_iter().collect())
        .unwrap_or_default()
}

fn progress_registry() -> &'static Mutex<BTreeMap<String, VecDeque<ScpTransferProgress>>> {
    PROGRESS_EVENTS.get_or_init(|| Mutex::new(BTreeMap::new()))
}

#[cfg(test)]
mod scp_progress_tests {
    use super::*;

    #[test]
    fn live_progress_batches_drain_by_job_id() {
        record_live_scp_transfer_progress(ScpTransferProgress {
            job_id: "job_progress".to_string(),
            bytes_done: 40,
            bytes_total: 100,
            status: "running".to_string(),
        });

        let first = take_live_scp_transfer_progress_batch("job_progress");
        let second = take_live_scp_transfer_progress_batch("job_progress");

        assert_eq!(first.len(), 1);
        assert_eq!(first[0].bytes_done, 40);
        assert!(second.is_empty());
    }

    #[test]
    fn missing_progress_batch_does_not_create_empty_registry_entry() {
        let job_id = "job_missing_progress_entry";
        progress_registry()
            .lock()
            .expect("scp progress registry")
            .remove(job_id);

        let progress = take_live_scp_transfer_progress_batch(job_id);

        assert!(progress.is_empty());
        assert!(!progress_registry()
            .lock()
            .expect("scp progress registry")
            .contains_key(job_id));
    }
}

fn cancellation_registry() -> &'static Mutex<HashSet<String>> {
    CANCELLED_TRANSFERS.get_or_init(|| Mutex::new(HashSet::new()))
}
