use crate::domain::scp::{ScpTransferError, ScpTransferJob, ScpTransferProgress};
use std::collections::{BTreeMap, HashSet, VecDeque};
use std::sync::{Mutex, OnceLock};

static CANCELLED_TRANSFERS: OnceLock<Mutex<HashSet<String>>> = OnceLock::new();
#[derive(Default)]
struct ProgressBuffer {
    checkpoint: Option<ScpTransferProgress>,
    latest: Option<ScpTransferProgress>,
    events: VecDeque<ScpTransferProgress>,
}

static PROGRESS_EVENTS: OnceLock<Mutex<BTreeMap<String, ProgressBuffer>>> = OnceLock::new();

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
    pause_with_progress(job_id).is_some()
}

// Capture the whole run, even when a poll drained its last event before the UI
// received it. Publication and cancellation use the same lock order.
pub fn pause_with_progress(job_id: &str) -> Option<Vec<ScpTransferProgress>> {
    let id = job_id.trim();
    let mut cancelled = cancellation_registry()
        .lock()
        .expect("scp cancellation registry");
    if id.is_empty() || !cancelled.insert(id.to_owned()) {
        return None;
    }
    let buffer = progress_registry()
        .lock()
        .expect("scp progress registry")
        .remove(id);
    let mut receipt = Vec::new();
    if let Some(buffer) = buffer {
        receipt.extend(buffer.checkpoint);
        if let Some(latest) = buffer.latest {
            if receipt.last() != Some(&latest) {
                receipt.push(latest);
            }
        }
    }
    Some(receipt)
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
    // Retries share the checkpoint/job ID, but never the previous run's events.
    progress_registry()
        .lock()
        .expect("scp progress registry")
        .remove(job_id);
    let result = transfer();
    // The returned result carries completion/failure. Unconsumed live samples
    // must not survive into a retry while the next worker is still starting.
    progress_registry()
        .lock()
        .expect("scp progress registry")
        .remove(job_id);
    clear_live_scp_transfer_cancellation(job_id);
    result
}

pub fn record_live_scp_transfer_progress(progress: ScpTransferProgress) {
    let cancelled = cancellation_registry()
        .lock()
        .expect("scp cancellation registry");
    if cancelled.contains(&progress.job_id) {
        return;
    }
    let mut registry = progress_registry().lock().expect("scp progress registry");
    let buffer = registry.entry(progress.job_id.clone()).or_default();
    if progress.status == "resuming" && progress.bytes_done > 0 {
        buffer.checkpoint = Some(progress.clone());
    }
    buffer.latest = Some(progress.clone());
    let events = &mut buffer.events;
    let should_replace = matches!(progress.status.as_str(), "running" | "resuming")
        && events
            .back()
            .map(|last| last.status == progress.status)
            .unwrap_or(false);
    if should_replace {
        *events.back_mut().expect("progress event exists") = progress;
    } else {
        events.push_back(progress);
    }
}

pub fn take_live_scp_transfer_progress_batch(job_id: &str) -> Vec<ScpTransferProgress> {
    let mut registry = progress_registry().lock().expect("scp progress registry");
    let Some(buffer) = registry.get_mut(job_id) else {
        return vec![];
    };
    let mut events = std::mem::take(&mut buffer.events);
    if let Some(checkpoint) = &buffer.checkpoint {
        // A poll started before a pause may drain the resumed worker's first
        // batch. Let the next consumer recover its verified starting offset.
        if !events.is_empty() && !events.iter().any(|event| event.status == "resuming") {
            events.push_front(checkpoint.clone());
        }
    }
    events.into_iter().collect()
}

fn progress_registry() -> &'static Mutex<BTreeMap<String, ProgressBuffer>> {
    PROGRESS_EVENTS.get_or_init(|| Mutex::new(BTreeMap::new()))
}

#[cfg(test)]
mod scp_progress_tests {
    use super::*;

    fn progress(job_id: &str, bytes_done: u64, status: &str) -> ScpTransferProgress {
        ScpTransferProgress {
            job_id: job_id.to_string(),
            bytes_done,
            bytes_total: 100,
            status: status.to_string(),
        }
    }

    #[test]
    fn pause_discards_pending_and_late_progress_before_resume() {
        let job_id = "job_pause_progress_isolation";
        with_live_scp_transfer_cancellation_scope(job_id, || {
            record_live_scp_transfer_progress(progress(job_id, 40, "running"));
            assert!(cancel_live_scp_transfer(job_id));
            // A write already in flight can finish after cancellation.
            record_live_scp_transfer_progress(progress(job_id, 45, "running"));
            assert!(take_live_scp_transfer_progress_batch(job_id).is_empty());
        });
        with_live_scp_transfer_cancellation_scope(job_id, || {
            record_live_scp_transfer_progress(progress(job_id, 0, "resuming"));
            record_live_scp_transfer_progress(progress(job_id, 10, "running"));
            assert_eq!(
                take_live_scp_transfer_progress_batch(job_id),
                vec![
                    progress(job_id, 0, "resuming"),
                    progress(job_id, 10, "running")
                ]
            );
        });
    }

    #[test]
    fn pause_reports_the_final_published_offset_even_after_poll_drained_it() {
        for (id, first) in [("pause_fresh", 0), ("pause_resumed", 40)] {
            with_live_scp_transfer_cancellation_scope(id, || {
                if first != 0 {
                    record_live_scp_transfer_progress(progress(id, first, "resuming"));
                }
                record_live_scp_transfer_progress(progress(id, 80, "running"));
                let _ = take_live_scp_transfer_progress_batch(id);
                let receipt = pause_with_progress(id).unwrap();
                assert_eq!(receipt.last(), Some(&progress(id, 80, "running")));
                if first > 0 {
                    assert_eq!(receipt.first(), Some(&progress(id, first, "resuming")));
                }
                assert!(pause_with_progress(id).is_none());
                assert!(take_live_scp_transfer_progress_batch(id).is_empty());
            });
        }
    }

    #[test]
    fn retired_poll_cannot_consume_a_verified_checkpoint_permanently() {
        let id = "job_retired_checkpoint";
        with_live_scp_transfer_cancellation_scope(id, || {
            record_live_scp_transfer_progress(progress(id, 40, "resuming"));
            let _ = take_live_scp_transfer_progress_batch(id);
            assert!(take_live_scp_transfer_progress_batch(id).is_empty());
            record_live_scp_transfer_progress(progress(id, 60, "running"));
            assert_eq!(
                take_live_scp_transfer_progress_batch(id),
                vec![progress(id, 40, "resuming"), progress(id, 60, "running")]
            );
        });
        assert!(!progress_registry().lock().unwrap().contains_key(id));
    }

    #[test]
    fn cancellation_and_publication_cannot_leave_stale_progress() {
        let job_id = "job_concurrent_cancel_progress";
        with_live_scp_transfer_cancellation_scope(job_id, || {
            let barrier = std::sync::Arc::new(std::sync::Barrier::new(2));
            let worker_barrier = barrier.clone();
            let worker = std::thread::spawn(move || {
                worker_barrier.wait();
                for bytes in 0..100 {
                    record_live_scp_transfer_progress(progress(job_id, bytes, "running"));
                }
            });
            barrier.wait();
            cancel_live_scp_transfer(job_id);
            worker.join().expect("progress worker");
            assert!(take_live_scp_transfer_progress_batch(job_id).is_empty());
        });
    }

    #[test]
    fn retry_discards_previous_run_events_before_starting() {
        let job_id = "job_retry_progress_isolation";
        record_live_scp_transfer_progress(progress(job_id, 40, "running"));
        with_live_scp_transfer_cancellation_scope(job_id, || {
            assert!(take_live_scp_transfer_progress_batch(job_id).is_empty());
            record_live_scp_transfer_progress(progress(job_id, 0, "running"));
            assert_eq!(
                take_live_scp_transfer_progress_batch(job_id),
                vec![progress(job_id, 0, "running")]
            );
        });
    }

    #[test]
    fn finished_worker_leaves_no_progress_for_a_later_retry() {
        for (job_id, status) in [
            ("job_failed_progress_cleanup", "running"),
            ("job_completed_progress_cleanup", "completed"),
        ] {
            let result = with_live_scp_transfer_cancellation_scope(job_id, || {
                record_live_scp_transfer_progress(progress(job_id, 100, status));
                status
            });
            assert_eq!(result, status);
            assert!(take_live_scp_transfer_progress_batch(job_id).is_empty());
        }
    }

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

    #[test]
    fn live_progress_batch_keeps_only_latest_running_sample() {
        let job_id = "job_progress_coalesced";
        for bytes_done in [4_u64, 8, 12] {
            record_live_scp_transfer_progress(ScpTransferProgress {
                job_id: job_id.to_string(),
                bytes_done,
                bytes_total: 20,
                status: "running".to_string(),
            });
        }

        let progress = take_live_scp_transfer_progress_batch(job_id);

        assert_eq!(progress.len(), 1);
        assert_eq!(progress[0].bytes_done, 12);
    }

    #[test]
    fn live_progress_batch_preserves_status_transitions() {
        let job_id = "job_progress_status_transition";
        for (bytes_done, status) in [(4_u64, "running"), (8, "resuming"), (12, "running")] {
            record_live_scp_transfer_progress(ScpTransferProgress {
                job_id: job_id.to_string(),
                bytes_done,
                bytes_total: 20,
                status: status.to_string(),
            });
        }

        let progress = take_live_scp_transfer_progress_batch(job_id);

        assert_eq!(progress.len(), 3);
        assert_eq!(
            progress
                .iter()
                .map(|event| event.status.as_str())
                .collect::<Vec<_>>(),
            ["running", "resuming", "running"]
        );
    }
}

fn cancellation_registry() -> &'static Mutex<HashSet<String>> {
    CANCELLED_TRANSFERS.get_or_init(|| Mutex::new(HashSet::new()))
}
