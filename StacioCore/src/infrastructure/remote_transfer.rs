use crate::domain::scp::RemoteTransferProtocol;
use crate::domain::ssh::{SshAuthSecret, SshConnectionConfig, SshRuntimeError};
use crate::infrastructure::files::libssh2_exec_listing::Libssh2ExecListing;
use crate::infrastructure::ssh::libssh2_transport::{
    Libssh2ConnectedSession, Libssh2Transport, SshSecret,
};
use sha2::{Digest, Sha256};
use ssh2::{OpenFlags, OpenType, RenameFlags};
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::{mpsc, Arc};
use std::thread;
use std::time::UNIX_EPOCH;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RemoteRelayOptions {
    pub chunk_size_bytes: usize,
    pub queue_depth: usize,
}

impl Default for RemoteRelayOptions {
    fn default() -> Self {
        Self {
            chunk_size_bytes: 1024 * 1024,
            queue_depth: 8,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteRelayReport {
    pub bytes_copied: u64,
    pub final_offset: u64,
    pub sha256_hex: String,
    pub peak_buffered_bytes: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteRelayError {
    pub code: String,
    pub committed_offset: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct RemoteFileIdentity {
    pub size: u64,
    pub mtime_unix: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteResumeDecision {
    pub offset: u64,
    pub discard_partial: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemotePartialPaths {
    pub data: String,
    pub metadata: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteFileTransferRequest {
    pub job_id: String,
    pub source_path: String,
    pub destination_path: String,
    pub expected_size: u64,
    pub requested_offset: u64,
    pub force_restart: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteFileTransferReport {
    pub bytes_done: u64,
    pub bytes_total: u64,
    pub resumed_from: u64,
    pub sha256_hex: String,
    pub peak_buffered_bytes: usize,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct RemoteTransferCheckpoint {
    pub source_identity: RemoteFileIdentity,
    pub chunk_size_bytes: u64,
    pub completed: Vec<bool>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RemoteTransferRange {
    pub start: u64,
    pub length: u64,
}

struct LimitedReader<R> {
    reader: R,
    remaining: u64,
}

impl<R> LimitedReader<R> {
    fn new(reader: R, remaining: u64) -> Self {
        Self { reader, remaining }
    }
}

impl<R: Read> Read for LimitedReader<R> {
    fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
        if self.remaining == 0 {
            return Ok(0);
        }
        let permitted = self.remaining.min(buffer.len() as u64) as usize;
        let count = self.reader.read(&mut buffer[..permitted])?;
        self.remaining = self.remaining.saturating_sub(count as u64);
        Ok(count)
    }
}

/// Returns non-overlapping ranges that cover `[0, total_size)` exactly once.
/// Worker count is bounded to four and zero-sized files produce no ranges.
pub fn plan_remote_transfer_ranges(
    total_size: u64,
    requested_chunk_size: u64,
    requested_workers: u8,
) -> Result<Vec<RemoteTransferRange>, String> {
    if requested_chunk_size == 0 || requested_workers == 0 {
        return Err("FILES_INVALID_TRANSFER_TUNING".to_string());
    }
    if total_size == 0 {
        return Ok(Vec::new());
    }
    let chunk_size = requested_chunk_size.max(64 * 1024);
    let chunks_needed = total_size
        .saturating_add(chunk_size - 1)
        .checked_div(chunk_size)
        .unwrap_or(1)
        .max(1);
    let range_count = u64::from(requested_workers.clamp(1, 4)).min(chunks_needed);
    let mut ranges = Vec::with_capacity(range_count as usize);
    let base_chunks = chunks_needed / range_count;
    let ranges_with_extra_chunk = chunks_needed % range_count;
    let mut start = 0_u64;
    for index in 0..range_count {
        let chunk_count = base_chunks + u64::from(index < ranges_with_extra_chunk);
        let length = chunk_count
            .saturating_mul(chunk_size)
            .min(total_size.saturating_sub(start));
        ranges.push(RemoteTransferRange { start, length });
        start = start.saturating_add(length);
    }
    Ok(ranges)
}

pub trait RemoteFileTransferBackend {
    type Reader: Read + Send + 'static;
    type Writer: Write + Send + 'static;

    fn file_identity(&mut self, path: &str) -> Result<Option<RemoteFileIdentity>, String>;
    fn read_resume_metadata(&mut self, path: &str) -> Result<Option<RemoteFileIdentity>, String>;
    fn write_resume_metadata(
        &mut self,
        path: &str,
        identity: &RemoteFileIdentity,
    ) -> Result<(), String>;
    fn remove_file_if_exists(&mut self, path: &str) -> Result<(), String>;
    fn open_reader(&mut self, path: &str, offset: u64) -> Result<Self::Reader, String>;
    fn open_writer(
        &mut self,
        path: &str,
        offset: u64,
        truncate: bool,
    ) -> Result<Self::Writer, String>;
    fn sha256(&mut self, path: &str) -> Result<String, String>;
    fn promote(&mut self, partial_path: &str, destination_path: &str) -> Result<(), String>;

    fn read_checkpoint(&mut self, path: &str) -> Result<Option<RemoteTransferCheckpoint>, String> {
        self.read_resume_metadata(path).map(|identity| {
            identity.map(|source_identity| RemoteTransferCheckpoint {
                source_identity,
                chunk_size_bytes: 0,
                completed: Vec::new(),
            })
        })
    }

    fn write_checkpoint(
        &mut self,
        path: &str,
        checkpoint: &RemoteTransferCheckpoint,
    ) -> Result<(), String> {
        self.write_resume_metadata(path, &checkpoint.source_identity)
    }
}

pub(crate) struct LocalFileTransferBackend;

impl LocalFileTransferBackend {
    pub(crate) fn new() -> Self {
        Self
    }

    fn write_json_atomically<T: serde::Serialize>(path: &str, value: &T) -> Result<(), String> {
        let path = Path::new(path);
        let temporary_path = path.with_extension(format!(
            "{}.tmp",
            path.extension()
                .and_then(|extension| extension.to_str())
                .unwrap_or("stacio")
        ));
        let payload =
            serde_json::to_vec(value).map_err(|_| "FILES_TRANSFER_INTERRUPTED".to_string())?;
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).map_err(map_local_io_error)?;
        }
        let mut file = File::create(&temporary_path).map_err(map_local_io_error)?;
        file.write_all(&payload).map_err(map_local_io_error)?;
        file.flush().map_err(map_local_io_error)?;
        file.sync_all().map_err(map_local_io_error)?;
        fs::rename(&temporary_path, path).map_err(map_local_io_error)
    }
}

pub(crate) struct LocalTransferWriter(File);

impl Write for LocalTransferWriter {
    fn write(&mut self, buffer: &[u8]) -> std::io::Result<usize> {
        self.0.write(buffer)
    }

    fn flush(&mut self) -> std::io::Result<()> {
        self.0.flush()?;
        self.0.sync_data()
    }
}

impl RemoteFileTransferBackend for LocalFileTransferBackend {
    type Reader = File;
    type Writer = LocalTransferWriter;

    fn file_identity(&mut self, path: &str) -> Result<Option<RemoteFileIdentity>, String> {
        match fs::metadata(path) {
            Ok(metadata) if metadata.is_file() => Ok(Some(RemoteFileIdentity {
                size: metadata.len(),
                mtime_unix: metadata
                    .modified()
                    .ok()
                    .and_then(|value| value.duration_since(UNIX_EPOCH).ok())
                    .map(|value| value.as_secs().min(i64::MAX as u64) as i64)
                    .unwrap_or(0),
            })),
            Ok(_) => Ok(None),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(error) => Err(map_local_io_error(error)),
        }
    }

    fn read_resume_metadata(&mut self, path: &str) -> Result<Option<RemoteFileIdentity>, String> {
        read_local_json(path)
    }

    fn write_resume_metadata(
        &mut self,
        path: &str,
        identity: &RemoteFileIdentity,
    ) -> Result<(), String> {
        Self::write_json_atomically(path, identity)
    }

    fn read_checkpoint(&mut self, path: &str) -> Result<Option<RemoteTransferCheckpoint>, String> {
        read_local_json(path)
    }

    fn write_checkpoint(
        &mut self,
        path: &str,
        checkpoint: &RemoteTransferCheckpoint,
    ) -> Result<(), String> {
        Self::write_json_atomically(path, checkpoint)
    }

    fn remove_file_if_exists(&mut self, path: &str) -> Result<(), String> {
        match fs::remove_file(path) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(map_local_io_error(error)),
        }
    }

    fn open_reader(&mut self, path: &str, offset: u64) -> Result<Self::Reader, String> {
        let mut file = File::open(path).map_err(map_local_io_error)?;
        file.seek(SeekFrom::Start(offset))
            .map_err(map_local_io_error)?;
        Ok(file)
    }

    fn open_writer(
        &mut self,
        path: &str,
        offset: u64,
        truncate: bool,
    ) -> Result<Self::Writer, String> {
        if let Some(parent) = Path::new(path).parent() {
            fs::create_dir_all(parent).map_err(map_local_io_error)?;
        }
        let mut options = OpenOptions::new();
        options.write(true).create(true).truncate(truncate);
        let mut file = options.open(path).map_err(map_local_io_error)?;
        file.seek(SeekFrom::Start(offset))
            .map_err(map_local_io_error)?;
        Ok(LocalTransferWriter(file))
    }

    fn sha256(&mut self, path: &str) -> Result<String, String> {
        let mut file = File::open(path).map_err(map_local_io_error)?;
        let mut hasher = Sha256::new();
        let mut buffer = vec![0_u8; 1024 * 1024];
        loop {
            let count = file.read(&mut buffer).map_err(map_local_io_error)?;
            if count == 0 {
                break;
            }
            hasher.update(&buffer[..count]);
        }
        Ok(hex::encode(hasher.finalize()))
    }

    fn promote(&mut self, partial_path: &str, destination_path: &str) -> Result<(), String> {
        fs::rename(partial_path, destination_path).map_err(map_local_io_error)
    }
}

fn read_local_json<T: serde::de::DeserializeOwned>(path: &str) -> Result<Option<T>, String> {
    match fs::metadata(path) {
        Ok(metadata) if metadata.is_file() && metadata.len() <= 64 * 1024 => {}
        Ok(_) => return Err("FILES_TRANSFER_INTERRUPTED".to_string()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(map_local_io_error(error)),
    }
    let payload = fs::read(path).map_err(map_local_io_error)?;
    serde_json::from_slice(&payload)
        .map(Some)
        .map_err(|_| "FILES_TRANSFER_INTERRUPTED".to_string())
}

fn map_local_io_error(error: std::io::Error) -> String {
    match error.kind() {
        std::io::ErrorKind::NotFound => "FILES_LOCAL_FILE_MISSING".to_string(),
        std::io::ErrorKind::PermissionDenied => "FILES_PERMISSION_DENIED".to_string(),
        std::io::ErrorKind::TimedOut => "FILES_TRANSFER_TIMEOUT".to_string(),
        _ if error.raw_os_error() == Some(28) => "FILES_DISK_FULL".to_string(),
        _ => "FILES_TRANSFER_INTERRUPTED".to_string(),
    }
}

pub fn transfer_remote_file<S, D, C, P>(
    source: &mut S,
    destination: &mut D,
    request: &RemoteFileTransferRequest,
    relay_options: RemoteRelayOptions,
    is_cancelled: C,
    report_progress: P,
) -> Result<RemoteFileTransferReport, RemoteRelayError>
where
    S: RemoteFileTransferBackend,
    D: RemoteFileTransferBackend,
    C: Fn() -> bool + Send + Sync + 'static,
    P: Fn(u64) + Send + Sync + 'static,
{
    validate_remote_transfer_path(&request.source_path)
        .map_err(|code| transfer_state_error(code, 0))?;
    validate_remote_transfer_path(&request.destination_path)
        .map_err(|code| transfer_state_error(code, 0))?;
    let source_identity = source
        .file_identity(&request.source_path)
        .map_err(|code| transfer_state_error(code, 0))?
        .ok_or_else(|| transfer_state_error("FILES_REMOTE_FILE_MISSING", 0))?;
    if request.expected_size != 0 && request.expected_size != source_identity.size {
        return Err(transfer_state_error("FILES_SIZE_MISMATCH", 0));
    }

    let partial_paths = remote_partial_paths(&request.destination_path, &request.job_id)
        .map_err(|code| transfer_state_error(code, 0))?;
    let saved_source_identity = destination
        .read_resume_metadata(&partial_paths.metadata)
        .map_err(|code| transfer_state_error(code, 0))?;
    let partial_identity = destination
        .file_identity(&partial_paths.data)
        .map_err(|code| transfer_state_error(code, 0))?;
    let resume = resolve_remote_resume(
        &source_identity,
        saved_source_identity.as_ref(),
        partial_identity.as_ref().map(|identity| identity.size),
        request.requested_offset,
        request.force_restart,
    );
    if resume.discard_partial {
        destination
            .remove_file_if_exists(&partial_paths.data)
            .map_err(|code| transfer_state_error(code, 0))?;
        destination
            .remove_file_if_exists(&partial_paths.metadata)
            .map_err(|code| transfer_state_error(code, 0))?;
    }
    if resume.offset == 0 || saved_source_identity.as_ref() != Some(&source_identity) {
        destination
            .write_resume_metadata(&partial_paths.metadata, &source_identity)
            .map_err(|code| transfer_state_error(code, 0))?;
    }

    let reader = source
        .open_reader(&request.source_path, resume.offset)
        .map_err(|code| transfer_state_error(code, resume.offset))?;
    let writer = destination
        .open_writer(&partial_paths.data, resume.offset, resume.offset == 0)
        .map_err(|code| transfer_state_error(code, resume.offset))?;
    let relay = stream_with_bounded_pipeline(
        reader,
        writer,
        resume.offset,
        relay_options,
        is_cancelled,
        report_progress,
    )?;
    if relay.final_offset != source_identity.size {
        return Err(transfer_state_error(
            "FILES_SIZE_MISMATCH",
            relay.final_offset,
        ));
    }

    let source_after_transfer = source
        .file_identity(&request.source_path)
        .map_err(|code| transfer_state_error(code, relay.final_offset))?;
    if source_after_transfer.as_ref() != Some(&source_identity) {
        return Err(transfer_state_error(
            "FILES_SOURCE_CHANGED",
            relay.final_offset,
        ));
    }
    let destination_identity = destination
        .file_identity(&partial_paths.data)
        .map_err(|code| transfer_state_error(code, relay.final_offset))?;
    if destination_identity.as_ref().map(|identity| identity.size) != Some(source_identity.size) {
        return Err(transfer_state_error(
            "FILES_SIZE_MISMATCH",
            relay.final_offset,
        ));
    }

    let source_sha256 = if resume.offset == 0 {
        relay.sha256_hex.clone()
    } else {
        source
            .sha256(&request.source_path)
            .map_err(|code| transfer_state_error(code, relay.final_offset))?
    };
    let destination_sha256 = destination
        .sha256(&partial_paths.data)
        .map_err(|code| transfer_state_error(code, relay.final_offset))?;
    if source_sha256 != destination_sha256 {
        return Err(transfer_state_error(
            "FILES_CHECKSUM_MISMATCH",
            relay.final_offset,
        ));
    }
    let source_after_checksum = source
        .file_identity(&request.source_path)
        .map_err(|code| transfer_state_error(code, relay.final_offset))?;
    if source_after_checksum.as_ref() != Some(&source_identity) {
        return Err(transfer_state_error(
            "FILES_SOURCE_CHANGED",
            relay.final_offset,
        ));
    }

    destination
        .promote(&partial_paths.data, &request.destination_path)
        .map_err(|code| transfer_state_error(code, relay.final_offset))?;
    destination
        .remove_file_if_exists(&partial_paths.metadata)
        .map_err(|code| transfer_state_error(code, relay.final_offset))?;

    Ok(RemoteFileTransferReport {
        bytes_done: relay.final_offset,
        bytes_total: source_identity.size,
        resumed_from: resume.offset,
        sha256_hex: source_sha256,
        peak_buffered_bytes: relay.peak_buffered_bytes,
    })
}

/// Range-aware relay. Every worker owns an independently-created source and
/// destination backend, so libssh2 sessions and handles are never shared
/// across threads. The checkpoint is updated only after a range is committed.
pub fn transfer_remote_file_ranges<S, D, SF, DF, C, P>(
    source_factory: SF,
    destination_factory: DF,
    request: &RemoteFileTransferRequest,
    requested_chunk_size: u64,
    requested_workers: u8,
    is_cancelled: C,
    report_progress: P,
) -> Result<RemoteFileTransferReport, RemoteRelayError>
where
    S: RemoteFileTransferBackend,
    D: RemoteFileTransferBackend,
    SF: Fn() -> Result<S, String> + Send + Sync + 'static,
    DF: Fn() -> Result<D, String> + Send + Sync + 'static,
    C: Fn() -> bool + Send + Sync + 'static,
    P: Fn(u64) + Send + Sync + 'static,
{
    validate_remote_transfer_path(&request.source_path)
        .map_err(|code| transfer_state_error(code, 0))?;
    validate_remote_transfer_path(&request.destination_path)
        .map_err(|code| transfer_state_error(code, 0))?;
    let mut source_probe = source_factory().map_err(|code| transfer_state_error(code, 0))?;
    let mut destination_probe =
        destination_factory().map_err(|code| transfer_state_error(code, 0))?;
    let source_identity = source_probe
        .file_identity(&request.source_path)
        .map_err(|code| transfer_state_error(code, 0))?
        .ok_or_else(|| transfer_state_error("FILES_REMOTE_FILE_MISSING", 0))?;
    if request.expected_size != 0 && request.expected_size != source_identity.size {
        return Err(transfer_state_error("FILES_SIZE_MISMATCH", 0));
    }
    let paths = remote_partial_paths(&request.destination_path, &request.job_id)
        .map_err(|code| transfer_state_error(code, 0))?;
    let chunk_size = requested_chunk_size.max(64 * 1024);
    let ranges = plan_remote_transfer_ranges(source_identity.size, chunk_size, requested_workers)
        .map_err(|code| transfer_state_error(code, 0))?;
    if ranges.is_empty() {
        destination_probe
            .remove_file_if_exists(&paths.data)
            .map_err(|code| transfer_state_error(code, 0))?;
        destination_probe
            .remove_file_if_exists(&paths.metadata)
            .map_err(|code| transfer_state_error(code, 0))?;
        let mut writer = destination_probe
            .open_writer(&paths.data, 0, true)
            .map_err(|code| transfer_state_error(code, 0))?;
        writer
            .flush()
            .map_err(|_| transfer_state_error("FILES_DESTINATION_WRITE_FAILED", 0))?;
        drop(writer);
        if source_probe
            .file_identity(&request.source_path)
            .map_err(|code| transfer_state_error(code, 0))?
            .as_ref()
            != Some(&source_identity)
        {
            return Err(transfer_state_error("FILES_SOURCE_CHANGED", 0));
        }
        destination_probe
            .promote(&paths.data, &request.destination_path)
            .map_err(|code| transfer_state_error(code, 0))?;
        return Ok(RemoteFileTransferReport {
            bytes_done: 0,
            bytes_total: 0,
            resumed_from: 0,
            sha256_hex: hex::encode(Sha256::digest([])),
            peak_buffered_bytes: 0,
        });
    }
    let saved_checkpoint = if request.force_restart {
        destination_probe
            .remove_file_if_exists(&paths.data)
            .map_err(|code| transfer_state_error(code, 0))?;
        destination_probe
            .remove_file_if_exists(&paths.metadata)
            .map_err(|code| transfer_state_error(code, 0))?;
        None
    } else {
        destination_probe
            .read_checkpoint(&paths.metadata)
            .map_err(|code| transfer_state_error(code, 0))?
    };
    let partial_identity = destination_probe
        .file_identity(&paths.data)
        .map_err(|code| transfer_state_error(code, 0))?;
    let valid_checkpoint = saved_checkpoint
        .as_ref()
        .filter(|value| {
            let required_partial_size = value
                .completed
                .iter()
                .zip(ranges.iter())
                .filter_map(|(completed, range)| {
                    completed.then_some(range.start.saturating_add(range.length))
                })
                .max()
                .unwrap_or(0);
            let partial_is_usable = if required_partial_size == 0 {
                true
            } else {
                partial_identity
                    .as_ref()
                    .map(|identity| identity.size >= required_partial_size)
                    .unwrap_or(false)
            };
            value.source_identity == source_identity
                && value.chunk_size_bytes == chunk_size
                && value.completed.len() == ranges.len()
                && partial_is_usable
        })
        .cloned();
    let checkpoint = match valid_checkpoint {
        Some(checkpoint) => checkpoint,
        None => {
            if saved_checkpoint.is_some() || partial_identity.is_some() {
                destination_probe
                    .remove_file_if_exists(&paths.data)
                    .map_err(|code| transfer_state_error(code, 0))?;
                destination_probe
                    .remove_file_if_exists(&paths.metadata)
                    .map_err(|code| transfer_state_error(code, 0))?;
            }
            RemoteTransferCheckpoint {
                source_identity: source_identity.clone(),
                chunk_size_bytes: chunk_size,
                completed: vec![false; ranges.len()],
            }
        }
    };
    let checkpoint = Arc::new(std::sync::Mutex::new(checkpoint));
    let resumed_from = checkpoint
        .lock()
        .expect("checkpoint")
        .completed
        .iter()
        .zip(ranges.iter())
        .filter_map(|(completed, range)| completed.then_some(range.length))
        .sum::<u64>();
    destination_probe
        .write_checkpoint(
            &paths.metadata,
            &checkpoint.lock().expect("checkpoint").clone(),
        )
        .map_err(|code| transfer_state_error(code, 0))?;

    let is_cancelled = Arc::new(is_cancelled);
    let report_progress = Arc::new(report_progress);
    let next_range = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let first_error = Arc::new(std::sync::Mutex::new(None::<RemoteRelayError>));
    let completed_bytes = Arc::new(AtomicU64::new(
        checkpoint
            .lock()
            .expect("checkpoint")
            .completed
            .iter()
            .zip(ranges.iter())
            .filter_map(|(done, range)| done.then_some(range.length))
            .sum(),
    ));
    let shared_buffer_tracker = Arc::new(SharedBufferTracker::default());
    // Initialize the partial file before range workers start.  In particular,
    // a late-scheduled first-range worker must never truncate data that a
    // different range worker has already committed.
    {
        let mut initializer = destination_factory()
            .map_err(|code| transfer_state_error(code, completed_bytes.load(Ordering::SeqCst)))?;
        let mut writer = initializer
            .open_writer(&paths.data, 0, resumed_from == 0)
            .map_err(|code| transfer_state_error(code, completed_bytes.load(Ordering::SeqCst)))?;
        writer.flush().map_err(|_| {
            transfer_state_error(
                "FILES_DESTINATION_WRITE_FAILED",
                completed_bytes.load(Ordering::SeqCst),
            )
        })?;
        drop(writer);
    }
    let worker_count = usize::from(requested_workers.clamp(1, 4)).min(ranges.len());
    thread::scope(|scope| {
        for _ in 0..worker_count {
            let ranges = ranges.clone();
            let partial_data_path = paths.data.clone();
            let partial_metadata_path = paths.metadata.clone();
            let source_factory = &source_factory;
            let destination_factory = &destination_factory;
            let next_range = Arc::clone(&next_range);
            let checkpoint = Arc::clone(&checkpoint);
            let first_error = Arc::clone(&first_error);
            let is_cancelled = Arc::clone(&is_cancelled);
            let report_progress = Arc::clone(&report_progress);
            let completed_bytes = Arc::clone(&completed_bytes);
            let shared_buffer_tracker = Arc::clone(&shared_buffer_tracker);
            scope.spawn(move || loop {
                if is_cancelled() {
                    let mut guard = first_error.lock().expect("transfer error");
                    if guard.is_none() {
                        *guard = Some(transfer_state_error(
                            "FILES_TRANSFER_CANCELED",
                            completed_bytes.load(Ordering::SeqCst),
                        ));
                    }
                    break;
                }
                let index = next_range.fetch_add(1, Ordering::SeqCst);
                let Some(range) = ranges.get(index).copied() else {
                    break;
                };
                if checkpoint.lock().expect("checkpoint").completed[index] {
                    continue;
                }
                let mut source = match source_factory() {
                    Ok(value) => value,
                    Err(code) => {
                        *first_error.lock().expect("transfer error") = Some(transfer_state_error(
                            code,
                            completed_bytes.load(Ordering::SeqCst),
                        ));
                        break;
                    }
                };
                let mut destination = match destination_factory() {
                    Ok(value) => value,
                    Err(code) => {
                        *first_error.lock().expect("transfer error") = Some(transfer_state_error(
                            code,
                            completed_bytes.load(Ordering::SeqCst),
                        ));
                        break;
                    }
                };
                let reader = match source.open_reader(&request.source_path, range.start) {
                    Ok(value) => value,
                    Err(code) => {
                        *first_error.lock().expect("transfer error") = Some(transfer_state_error(
                            code,
                            completed_bytes.load(Ordering::SeqCst),
                        ));
                        break;
                    }
                };
                let writer = match destination.open_writer(&partial_data_path, range.start, false) {
                    Ok(value) => value,
                    Err(code) => {
                        *first_error.lock().expect("transfer error") = Some(transfer_state_error(
                            code,
                            completed_bytes.load(Ordering::SeqCst),
                        ));
                        break;
                    }
                };
                let relay = match stream_with_bounded_pipeline_tracked(
                    LimitedReader::new(reader, range.length),
                    writer,
                    range.start,
                    RemoteRelayOptions {
                        chunk_size_bytes: chunk_size.min(usize::MAX as u64) as usize,
                        queue_depth: 4,
                    },
                    {
                        let is_cancelled = Arc::clone(&is_cancelled);
                        move || is_cancelled()
                    },
                    |_| {},
                    Some(Arc::clone(&shared_buffer_tracker)),
                ) {
                    Ok(value) if value.bytes_copied == range.length => value,
                    Ok(value) => {
                        *first_error.lock().expect("transfer error") = Some(transfer_state_error(
                            "FILES_SIZE_MISMATCH",
                            value.final_offset,
                        ));
                        break;
                    }
                    Err(error) => {
                        *first_error.lock().expect("transfer error") = Some(error);
                        break;
                    }
                };
                let checkpoint_result = {
                    let mut state = checkpoint.lock().expect("checkpoint");
                    state.completed[index] = true;
                    destination.write_checkpoint(&partial_metadata_path, &state)
                };
                let bytes =
                    completed_bytes.fetch_add(range.length, Ordering::SeqCst) + range.length;
                if checkpoint_result.is_err() {
                    *first_error.lock().expect("transfer error") =
                        Some(transfer_state_error("FILES_CHECKPOINT_FAILED", bytes));
                    break;
                }
                report_progress(bytes);
                let _ = relay;
            });
        }
    });
    if let Some(error) = first_error.lock().expect("transfer error").clone() {
        return Err(error);
    }
    let state = checkpoint.lock().expect("checkpoint").clone();
    if state.completed.iter().any(|done| !done) {
        return Err(transfer_state_error(
            "FILES_TRANSFER_INTERRUPTED",
            completed_bytes.load(Ordering::SeqCst),
        ));
    }
    let mut source_after = source_factory()
        .map_err(|code| transfer_state_error(code, completed_bytes.load(Ordering::SeqCst)))?;
    let mut destination_after = destination_factory()
        .map_err(|code| transfer_state_error(code, completed_bytes.load(Ordering::SeqCst)))?;
    if source_after
        .file_identity(&request.source_path)
        .map_err(|code| transfer_state_error(code, completed_bytes.load(Ordering::SeqCst)))?
        .as_ref()
        != Some(&source_identity)
    {
        return Err(transfer_state_error(
            "FILES_SOURCE_CHANGED",
            completed_bytes.load(Ordering::SeqCst),
        ));
    }
    let destination_identity = destination_after
        .file_identity(&paths.data)
        .map_err(|code| transfer_state_error(code, completed_bytes.load(Ordering::SeqCst)))?;
    if destination_identity.as_ref().map(|identity| identity.size) != Some(source_identity.size) {
        return Err(transfer_state_error(
            "FILES_SIZE_MISMATCH",
            completed_bytes.load(Ordering::SeqCst),
        ));
    }
    let source_sha256 = source_after
        .sha256(&request.source_path)
        .map_err(|code| transfer_state_error(code, completed_bytes.load(Ordering::SeqCst)))?;
    let destination_sha256 = destination_after
        .sha256(&paths.data)
        .map_err(|code| transfer_state_error(code, completed_bytes.load(Ordering::SeqCst)))?;
    if source_sha256 != destination_sha256 {
        return Err(transfer_state_error(
            "FILES_CHECKSUM_MISMATCH",
            completed_bytes.load(Ordering::SeqCst),
        ));
    }
    if source_after
        .file_identity(&request.source_path)
        .map_err(|code| transfer_state_error(code, completed_bytes.load(Ordering::SeqCst)))?
        .as_ref()
        != Some(&source_identity)
    {
        return Err(transfer_state_error(
            "FILES_SOURCE_CHANGED",
            completed_bytes.load(Ordering::SeqCst),
        ));
    }
    destination_after
        .promote(&paths.data, &request.destination_path)
        .map_err(|code| transfer_state_error(code, completed_bytes.load(Ordering::SeqCst)))?;
    destination_after
        .remove_file_if_exists(&paths.metadata)
        .map_err(|code| transfer_state_error(code, completed_bytes.load(Ordering::SeqCst)))?;
    Ok(RemoteFileTransferReport {
        bytes_done: source_identity.size,
        bytes_total: source_identity.size,
        resumed_from,
        sha256_hex: source_sha256,
        peak_buffered_bytes: shared_buffer_tracker.peak(),
    })
}

fn transfer_state_error(code: impl Into<String>, committed_offset: u64) -> RemoteRelayError {
    RemoteRelayError {
        code: code.into(),
        committed_offset,
    }
}

fn remote_checkpoint_staging_path(path: &str) -> Result<String, String> {
    validate_remote_transfer_path(path)?;
    Ok(format!("{path}.tmp"))
}

pub fn resolve_remote_resume(
    current_source: &RemoteFileIdentity,
    saved_source: Option<&RemoteFileIdentity>,
    partial_size: Option<u64>,
    requested_offset: u64,
    force_restart: bool,
) -> RemoteResumeDecision {
    let has_partial_state = partial_size.is_some() || saved_source.is_some();
    if force_restart || requested_offset > current_source.size {
        return RemoteResumeDecision {
            offset: 0,
            discard_partial: has_partial_state,
        };
    }
    let Some(partial_size) = partial_size else {
        return RemoteResumeDecision {
            offset: 0,
            discard_partial: saved_source.is_some(),
        };
    };
    if saved_source == Some(current_source) && partial_size <= current_source.size {
        return RemoteResumeDecision {
            offset: partial_size,
            discard_partial: false,
        };
    }
    RemoteResumeDecision {
        offset: 0,
        discard_partial: true,
    }
}

pub fn remote_partial_paths(
    destination_path: &str,
    job_id: &str,
) -> Result<RemotePartialPaths, String> {
    validate_remote_transfer_path(destination_path)?;
    let destination_path = destination_path.trim_end_matches('/');
    let (directory, file_name) = destination_path
        .rsplit_once('/')
        .map(|(directory, name)| {
            let directory = if directory.is_empty() { "/" } else { directory };
            (directory, name)
        })
        .unwrap_or((".", destination_path));
    if file_name.is_empty() || file_name == "." || file_name == ".." {
        return Err("FILES_UNSAFE_PATH".to_string());
    }
    let job_hash = hex::encode(Sha256::digest(job_id.as_bytes()));
    let hidden_name = format!(".{file_name}.stacio-{}", &job_hash[..16]);
    let prefix = if directory == "/" {
        format!("/{hidden_name}")
    } else if directory == "." {
        hidden_name
    } else {
        format!("{directory}/{hidden_name}")
    };
    Ok(RemotePartialPaths {
        data: format!("{prefix}.part"),
        metadata: format!("{prefix}.meta"),
    })
}

fn validate_remote_transfer_path(path: &str) -> Result<(), String> {
    let trimmed = path.trim();
    if trimmed.is_empty()
        || trimmed == ".."
        || trimmed.starts_with("../")
        || trimmed.ends_with("/..")
        || trimmed.contains("../")
        || trimmed.chars().any(char::is_control)
    {
        return Err("FILES_UNSAFE_PATH".to_string());
    }
    Ok(())
}

pub fn build_scp_source_command(remote_path: &str, offset: u64) -> Result<String, String> {
    validate_remote_transfer_path(remote_path)?;
    const BLOCK_SIZE: u64 = 1024 * 1024;
    let path = shell_path_argument(remote_path);
    if offset % BLOCK_SIZE == 0 {
        return Ok(format!(
            "exec dd if={path} bs={BLOCK_SIZE} skip={} 2>/dev/null",
            offset / BLOCK_SIZE
        ));
    }
    Ok(format!(
        "if dd if=/dev/null of=/dev/null bs=1 count=0 skip=0 iflag=skip_bytes 2>/dev/null; then \
         exec dd if={path} bs={BLOCK_SIZE} skip={offset} iflag=skip_bytes 2>/dev/null; \
         elif tail -c +1 /dev/null >/dev/null 2>&1; then \
         exec tail -c +{} {path}; \
         else exec dd if={path} bs=1 skip={offset} 2>/dev/null; fi",
        offset.saturating_add(1)
    ))
}

pub fn build_scp_destination_command(
    remote_partial_path: &str,
    offset: u64,
) -> Result<String, String> {
    validate_remote_transfer_path(remote_partial_path)?;
    const BLOCK_SIZE: u64 = 1024 * 1024;
    let path = shell_path_argument(remote_partial_path);
    if offset % BLOCK_SIZE == 0 {
        return Ok(format!(
            "umask 077; exec dd of={path} bs={BLOCK_SIZE} seek={} conv=notrunc 2>/dev/null",
            offset / BLOCK_SIZE
        ));
    }
    Ok(format!(
        "umask 077; if dd if=/dev/null of=/dev/null bs=1 count=0 seek=0 oflag=seek_bytes 2>/dev/null; then \
         exec dd of={path} bs={BLOCK_SIZE} seek={offset} oflag=seek_bytes conv=notrunc 2>/dev/null; \
         else exec dd of={path} bs=1 seek={offset} conv=notrunc 2>/dev/null; fi"
    ))
}

pub fn build_remote_sha256_command(remote_path: &str) -> Result<String, String> {
    validate_remote_transfer_path(remote_path)?;
    let path = shell_path_argument(remote_path);
    Ok(format!(
        "if command -v sha256sum >/dev/null 2>&1; then sha256sum {path}; \
         elif command -v shasum >/dev/null 2>&1; then shasum -a 256 {path}; \
         elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 {path}; \
         else exit 127; fi"
    ))
}

pub fn parse_remote_sha256_output(output: &str) -> Option<String> {
    output
        .split(|character: char| !character.is_ascii_hexdigit())
        .find(|candidate| candidate.len() == 64)
        .map(str::to_ascii_lowercase)
}

fn shell_path_argument(path: &str) -> String {
    let trimmed = path.trim();
    if trimmed == "~" {
        return "~".to_string();
    }
    if let Some(rest) = trimmed.strip_prefix("~/") {
        return format!("~/{}", shell_quote(rest));
    }
    shell_quote(trimmed)
}

fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

pub(crate) struct Libssh2RemoteTransferBackend {
    config: SshConnectionConfig,
    secret: SshAuthSecret,
    expected_fingerprint_sha256: String,
    protocol: RemoteTransferProtocol,
}

impl Libssh2RemoteTransferBackend {
    pub(crate) fn new(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expected_fingerprint_sha256: String,
        protocol: RemoteTransferProtocol,
    ) -> Self {
        Self {
            config,
            secret,
            expected_fingerprint_sha256,
            protocol,
        }
    }

    fn connect(&self) -> Result<Libssh2ConnectedSession, String> {
        Libssh2Transport::new()
            .connect_with_secret_and_expected_transfer_session(
                &self.config,
                auth_secret_to_transport_secret(self.secret.clone()),
                self.expected_fingerprint_sha256.clone(),
            )
            .map_err(map_ssh_runtime_error)
    }

    fn run_command(&self, command: &str) -> Result<String, String> {
        let session = self.connect()?;
        Libssh2ExecListing::run_raw_command(&session, command)
            .map_err(|_| "FILES_REMOTE_COMMAND_FAILED".to_string())
    }

    fn sftp_path(session: &Libssh2ConnectedSession, remote_path: &str) -> Result<PathBuf, String> {
        validate_remote_transfer_path(remote_path)?;
        let sftp = session
            .session()
            .sftp()
            .map_err(|_| "FILES_REMOTE_COMMAND_FAILED".to_string())?;
        let trimmed = remote_path.trim();
        if trimmed == "~" {
            return sftp
                .realpath(Path::new("."))
                .map_err(|_| "FILES_REMOTE_COMMAND_FAILED".to_string());
        }
        if let Some(relative) = trimmed.strip_prefix("~/") {
            return sftp
                .realpath(Path::new("."))
                .map(|home| home.join(relative))
                .map_err(|_| "FILES_REMOTE_COMMAND_FAILED".to_string());
        }
        Ok(PathBuf::from(trimmed))
    }

    fn command_file_identity(&self, path: &str) -> Result<Option<RemoteFileIdentity>, String> {
        validate_remote_transfer_path(path)?;
        let path = shell_path_argument(path);
        let output = self.run_command(&format!(
            "if [ -f {path} ]; then (stat -c '%s:%Y' {path} 2>/dev/null || stat -f '%z:%m' {path} 2>/dev/null); else printf 'missing\\n'; fi"
        ))?;
        parse_remote_identity_output(&output)
    }

    fn sftp_file_identity(&self, path: &str) -> Result<Option<RemoteFileIdentity>, String> {
        let session = self.connect()?;
        let sftp = session
            .session()
            .sftp()
            .map_err(|_| "FILES_REMOTE_COMMAND_FAILED".to_string())?;
        let path = Self::sftp_path(&session, path)?;
        match sftp.lstat(&path) {
            Ok(stat) if stat.file_type().is_file() => Ok(Some(RemoteFileIdentity {
                size: stat.size.unwrap_or(0),
                mtime_unix: stat.mtime.unwrap_or(0).min(i64::MAX as u64) as i64,
            })),
            Ok(_) => Ok(None),
            Err(error) if error.code() == ssh2::ErrorCode::SFTP(2) => Ok(None),
            Err(_) => Err("FILES_REMOTE_COMMAND_FAILED".to_string()),
        }
    }

    fn read_small_file(&mut self, path: &str) -> Result<Option<String>, String> {
        match self.file_identity(path)? {
            None => return Ok(None),
            Some(identity) if identity.size > 4096 => {
                return Err("FILES_TRANSFER_INTERRUPTED".to_string())
            }
            Some(_) => {}
        }
        match self.protocol {
            RemoteTransferProtocol::Scp => {
                let output = self.run_command(&format!("cat {}", shell_path_argument(path)))?;
                Ok(Some(output))
            }
            RemoteTransferProtocol::Sftp => {
                let session = self.connect()?;
                let sftp = session
                    .session()
                    .sftp()
                    .map_err(|_| "FILES_REMOTE_COMMAND_FAILED".to_string())?;
                let path = Self::sftp_path(&session, path)?;
                let mut file = sftp
                    .open(&path)
                    .map_err(|_| "FILES_REMOTE_COMMAND_FAILED".to_string())?;
                let mut output = String::new();
                file.read_to_string(&mut output)
                    .map_err(|_| "FILES_REMOTE_COMMAND_FAILED".to_string())?;
                Ok(Some(output))
            }
        }
    }

    fn write_small_file(&self, path: &str, contents: &str) -> Result<(), String> {
        match self.protocol {
            RemoteTransferProtocol::Scp => {
                self.run_command(&format!(
                    "umask 077; printf %s {} > {}",
                    shell_quote(contents),
                    shell_path_argument(path)
                ))?;
                Ok(())
            }
            RemoteTransferProtocol::Sftp => {
                let session = self.connect()?;
                let sftp = session
                    .session()
                    .sftp()
                    .map_err(|_| "FILES_REMOTE_COMMAND_FAILED".to_string())?;
                let path = Self::sftp_path(&session, path)?;
                let mut file = sftp
                    .open_mode(
                        &path,
                        OpenFlags::WRITE | OpenFlags::CREATE | OpenFlags::TRUNCATE,
                        0o600,
                        OpenType::File,
                    )
                    .map_err(|_| "FILES_REMOTE_COMMAND_FAILED".to_string())?;
                file.write_all(contents.as_bytes())
                    .map_err(|_| "FILES_REMOTE_COMMAND_FAILED".to_string())?;
                file.flush()
                    .map_err(|_| "FILES_REMOTE_COMMAND_FAILED".to_string())
            }
        }
    }
}

pub(crate) enum Libssh2RemoteReader {
    Command(Libssh2CommandReader),
    Sftp(Libssh2SftpReader),
}

impl Read for Libssh2RemoteReader {
    fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
        match self {
            Self::Command(reader) => reader.read(buffer),
            Self::Sftp(reader) => reader.file.read(buffer),
        }
    }
}

pub(crate) enum Libssh2RemoteWriter {
    Command(Libssh2CommandWriter),
    Sftp(Libssh2SftpWriter),
}

impl Write for Libssh2RemoteWriter {
    fn write(&mut self, buffer: &[u8]) -> std::io::Result<usize> {
        match self {
            Self::Command(writer) => writer.channel.write(buffer),
            Self::Sftp(writer) => writer.file.write(buffer),
        }
    }

    fn flush(&mut self) -> std::io::Result<()> {
        match self {
            Self::Command(writer) => writer.finish(),
            Self::Sftp(writer) => writer.file.flush(),
        }
    }
}

pub(crate) struct Libssh2CommandReader {
    channel: ssh2::Channel,
    _session: Libssh2ConnectedSession,
    finalized: bool,
}

impl Read for Libssh2CommandReader {
    fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
        let count = self.channel.read(buffer)?;
        if count == 0 && !self.finalized {
            self.channel.wait_close().map_err(ssh2_to_io_error)?;
            let status = self.channel.exit_status().map_err(ssh2_to_io_error)?;
            self.finalized = true;
            if status != 0 {
                return Err(std::io::Error::other("FILES_REMOTE_COMMAND_FAILED"));
            }
        }
        Ok(count)
    }
}

pub(crate) struct Libssh2CommandWriter {
    channel: ssh2::Channel,
    _session: Libssh2ConnectedSession,
    finalized: bool,
}

impl Libssh2CommandWriter {
    fn finish(&mut self) -> std::io::Result<()> {
        if self.finalized {
            return Ok(());
        }
        self.channel.flush()?;
        self.channel.send_eof().map_err(ssh2_to_io_error)?;
        self.channel.wait_eof().map_err(ssh2_to_io_error)?;
        self.channel.close().map_err(ssh2_to_io_error)?;
        self.channel.wait_close().map_err(ssh2_to_io_error)?;
        let status = self.channel.exit_status().map_err(ssh2_to_io_error)?;
        self.finalized = true;
        if status != 0 {
            return Err(std::io::Error::other("FILES_REMOTE_COMMAND_FAILED"));
        }
        Ok(())
    }
}

pub(crate) struct Libssh2SftpReader {
    file: ssh2::File,
    _session: Libssh2ConnectedSession,
}

pub(crate) struct Libssh2SftpWriter {
    file: ssh2::File,
    _session: Libssh2ConnectedSession,
}

impl RemoteFileTransferBackend for Libssh2RemoteTransferBackend {
    type Reader = Libssh2RemoteReader;
    type Writer = Libssh2RemoteWriter;

    fn file_identity(&mut self, path: &str) -> Result<Option<RemoteFileIdentity>, String> {
        match self.protocol {
            RemoteTransferProtocol::Scp => self.command_file_identity(path),
            RemoteTransferProtocol::Sftp => self.sftp_file_identity(path),
        }
    }

    fn read_resume_metadata(&mut self, path: &str) -> Result<Option<RemoteFileIdentity>, String> {
        self.read_small_file(path)?
            .map(|contents| {
                serde_json::from_str(contents.trim())
                    .map_err(|_| "FILES_TRANSFER_INTERRUPTED".to_string())
            })
            .transpose()
    }

    fn read_checkpoint(&mut self, path: &str) -> Result<Option<RemoteTransferCheckpoint>, String> {
        let Some(contents) = self.read_small_file(path)? else {
            return Ok(None);
        };
        if let Some(checkpoint) = parse_remote_checkpoint_contents(&contents) {
            return Ok(Some(checkpoint));
        }
        // Corrupt metadata is not useful recovery state. Remove it so a retry
        // can validate the partial file and safely restart instead of failing forever.
        self.remove_file_if_exists(path)?;
        Ok(None)
    }

    fn write_resume_metadata(
        &mut self,
        path: &str,
        identity: &RemoteFileIdentity,
    ) -> Result<(), String> {
        let contents = serde_json::to_string(identity)
            .map_err(|_| "FILES_TRANSFER_INTERRUPTED".to_string())?;
        self.write_small_file(path, &contents)
    }

    fn write_checkpoint(
        &mut self,
        path: &str,
        checkpoint: &RemoteTransferCheckpoint,
    ) -> Result<(), String> {
        let contents = serde_json::to_string(checkpoint)
            .map_err(|_| "FILES_TRANSFER_INTERRUPTED".to_string())?;
        let staging_path = remote_checkpoint_staging_path(path)?;
        self.remove_file_if_exists(&staging_path)?;
        if let Err(error) = self.write_small_file(&staging_path, &contents) {
            let _ = self.remove_file_if_exists(&staging_path);
            return Err(error);
        }
        if let Err(error) = self.promote(&staging_path, path) {
            let _ = self.remove_file_if_exists(&staging_path);
            return Err(error);
        }
        Ok(())
    }

    fn remove_file_if_exists(&mut self, path: &str) -> Result<(), String> {
        match self.protocol {
            RemoteTransferProtocol::Scp => {
                self.run_command(&format!("rm -f {}", shell_path_argument(path)))?;
                Ok(())
            }
            RemoteTransferProtocol::Sftp => {
                if self.file_identity(path)?.is_none() {
                    return Ok(());
                }
                let session = self.connect()?;
                let sftp = session
                    .session()
                    .sftp()
                    .map_err(|_| "FILES_REMOTE_COMMAND_FAILED".to_string())?;
                let path = Self::sftp_path(&session, path)?;
                sftp.unlink(&path)
                    .map_err(|_| "FILES_REMOTE_COMMAND_FAILED".to_string())
            }
        }
    }

    fn open_reader(&mut self, path: &str, offset: u64) -> Result<Self::Reader, String> {
        match self.protocol {
            RemoteTransferProtocol::Scp => {
                let session = self.connect()?;
                let mut channel = session
                    .session()
                    .channel_session()
                    .map_err(|_| "FILES_REMOTE_COMMAND_FAILED".to_string())?;
                channel
                    .exec(&build_scp_source_command(path, offset)?)
                    .map_err(|_| "FILES_REMOTE_COMMAND_FAILED".to_string())?;
                Ok(Libssh2RemoteReader::Command(Libssh2CommandReader {
                    channel,
                    _session: session,
                    finalized: false,
                }))
            }
            RemoteTransferProtocol::Sftp => {
                let session = self.connect()?;
                let sftp = session
                    .session()
                    .sftp()
                    .map_err(|_| "FILES_REMOTE_COMMAND_FAILED".to_string())?;
                let path = Self::sftp_path(&session, path)?;
                let mut file = sftp
                    .open(&path)
                    .map_err(|_| "FILES_REMOTE_COMMAND_FAILED".to_string())?;
                file.seek(SeekFrom::Start(offset))
                    .map_err(|_| "FILES_REMOTE_COMMAND_FAILED".to_string())?;
                Ok(Libssh2RemoteReader::Sftp(Libssh2SftpReader {
                    file,
                    _session: session,
                }))
            }
        }
    }

    fn open_writer(
        &mut self,
        path: &str,
        offset: u64,
        truncate: bool,
    ) -> Result<Self::Writer, String> {
        if truncate {
            self.remove_file_if_exists(path)?;
        }
        match self.protocol {
            RemoteTransferProtocol::Scp => {
                let session = self.connect()?;
                let mut channel = session
                    .session()
                    .channel_session()
                    .map_err(|_| "FILES_REMOTE_COMMAND_FAILED".to_string())?;
                channel
                    .exec(&build_scp_destination_command(path, offset)?)
                    .map_err(|_| "FILES_REMOTE_COMMAND_FAILED".to_string())?;
                Ok(Libssh2RemoteWriter::Command(Libssh2CommandWriter {
                    channel,
                    _session: session,
                    finalized: false,
                }))
            }
            RemoteTransferProtocol::Sftp => {
                let session = self.connect()?;
                let sftp = session
                    .session()
                    .sftp()
                    .map_err(|_| "FILES_REMOTE_COMMAND_FAILED".to_string())?;
                let path = Self::sftp_path(&session, path)?;
                let flags = OpenFlags::WRITE | OpenFlags::CREATE;
                let mut file = sftp
                    .open_mode(&path, flags, 0o600, OpenType::File)
                    .map_err(|_| "FILES_REMOTE_COMMAND_FAILED".to_string())?;
                file.seek(SeekFrom::Start(offset))
                    .map_err(|_| "FILES_REMOTE_COMMAND_FAILED".to_string())?;
                Ok(Libssh2RemoteWriter::Sftp(Libssh2SftpWriter {
                    file,
                    _session: session,
                }))
            }
        }
    }

    fn sha256(&mut self, path: &str) -> Result<String, String> {
        match self.protocol {
            RemoteTransferProtocol::Scp => {
                let output = self.run_command(&build_remote_sha256_command(path)?)?;
                parse_remote_sha256_output(&output)
                    .ok_or_else(|| "FILES_REMOTE_CHECKSUM_UNAVAILABLE".to_string())
            }
            RemoteTransferProtocol::Sftp => {
                let session = self.connect()?;
                let sftp = session
                    .session()
                    .sftp()
                    .map_err(|_| "FILES_REMOTE_COMMAND_FAILED".to_string())?;
                let path = Self::sftp_path(&session, path)?;
                let mut file = sftp
                    .open(&path)
                    .map_err(|_| "FILES_REMOTE_COMMAND_FAILED".to_string())?;
                sha256_reader(&mut file)
            }
        }
    }

    fn promote(&mut self, partial_path: &str, destination_path: &str) -> Result<(), String> {
        match self.protocol {
            RemoteTransferProtocol::Scp => {
                self.run_command(&format!(
                    "mv -f {} {}",
                    shell_path_argument(partial_path),
                    shell_path_argument(destination_path)
                ))?;
                Ok(())
            }
            RemoteTransferProtocol::Sftp => {
                let session = self.connect()?;
                let sftp = session
                    .session()
                    .sftp()
                    .map_err(|_| "FILES_REMOTE_COMMAND_FAILED".to_string())?;
                let from = Self::sftp_path(&session, partial_path)?;
                let to = Self::sftp_path(&session, destination_path)?;
                sftp.rename(&from, &to, Some(RenameFlags::OVERWRITE))
                    .map_err(|_| "FILES_REMOTE_COMMAND_FAILED".to_string())
            }
        }
    }
}

fn parse_remote_checkpoint_contents(contents: &str) -> Option<RemoteTransferCheckpoint> {
    if let Ok(checkpoint) = serde_json::from_str(contents.trim()) {
        return Some(checkpoint);
    }
    // Accept the legacy identity-only metadata written by older builds. The
    // range planner will reject its empty layout and restart from zero.
    serde_json::from_str::<RemoteFileIdentity>(contents.trim())
        .ok()
        .map(|source_identity| RemoteTransferCheckpoint {
            source_identity,
            chunk_size_bytes: 0,
            completed: Vec::new(),
        })
}

fn sha256_reader(reader: &mut impl Read) -> Result<String, String> {
    let mut hasher = Sha256::new();
    let mut buffer = vec![0_u8; 1024 * 1024];
    loop {
        let count = reader
            .read(&mut buffer)
            .map_err(|_| "FILES_SOURCE_READ_FAILED".to_string())?;
        if count == 0 {
            break;
        }
        hasher.update(&buffer[..count]);
    }
    Ok(hex::encode(hasher.finalize()))
}

fn parse_remote_identity_output(output: &str) -> Result<Option<RemoteFileIdentity>, String> {
    let line = output.lines().next().unwrap_or("").trim();
    if line.is_empty() || line == "missing" {
        return Ok(None);
    }
    let (size, mtime) = line
        .split_once(':')
        .ok_or_else(|| "FILES_REMOTE_COMMAND_FAILED".to_string())?;
    Ok(Some(RemoteFileIdentity {
        size: size
            .parse()
            .map_err(|_| "FILES_REMOTE_COMMAND_FAILED".to_string())?,
        mtime_unix: mtime
            .parse()
            .map_err(|_| "FILES_REMOTE_COMMAND_FAILED".to_string())?,
    }))
}

fn auth_secret_to_transport_secret(secret: SshAuthSecret) -> Option<SshSecret> {
    match secret {
        SshAuthSecret::Password { value } => Some(SshSecret::Password(value)),
        SshAuthSecret::PrivateKey {
            private_key_pem,
            passphrase,
        } => Some(SshSecret::PrivateKey {
            private_key_pem,
            passphrase,
        }),
        SshAuthSecret::Agent => None,
    }
}

fn map_ssh_runtime_error(error: SshRuntimeError) -> String {
    match error {
        SshRuntimeError::InvalidConfig => "FILES_INVALID_REMOTE_CONFIG",
        SshRuntimeError::AuthFailed => "FILES_REMOTE_AUTH_FAILED",
        SshRuntimeError::Timeout => "FILES_TRANSFER_TIMEOUT",
        SshRuntimeError::HostKeyChanged { .. } => "FILES_REMOTE_HOST_KEY_CHANGED",
        SshRuntimeError::UnknownHostKey => "FILES_REMOTE_HOST_KEY_UNKNOWN",
        SshRuntimeError::Transport { .. } => "FILES_REMOTE_COMMAND_FAILED",
    }
    .to_string()
}

fn ssh2_to_io_error(error: ssh2::Error) -> std::io::Error {
    std::io::Error::other(if error.code() == ssh2::ErrorCode::Session(-37) {
        "FILES_TRANSFER_TIMEOUT"
    } else {
        "FILES_REMOTE_COMMAND_FAILED"
    })
}

#[derive(Default)]
struct SharedBufferTracker {
    buffered_bytes: AtomicUsize,
    peak_buffered_bytes: AtomicUsize,
}

impl SharedBufferTracker {
    fn reserve(&self, count: usize) {
        let buffered = self.buffered_bytes.fetch_add(count, Ordering::SeqCst) + count;
        self.peak_buffered_bytes
            .fetch_max(buffered, Ordering::SeqCst);
    }

    fn release(&self, count: usize) {
        self.buffered_bytes.fetch_sub(count, Ordering::SeqCst);
    }

    fn peak(&self) -> usize {
        self.peak_buffered_bytes.load(Ordering::SeqCst)
    }
}

struct BufferedChunk {
    bytes: Vec<u8>,
    buffered_bytes: Arc<AtomicUsize>,
    shared_buffer_tracker: Option<Arc<SharedBufferTracker>>,
}

impl Drop for BufferedChunk {
    fn drop(&mut self) {
        self.buffered_bytes
            .fetch_sub(self.bytes.len(), Ordering::SeqCst);
        if let Some(tracker) = &self.shared_buffer_tracker {
            tracker.release(self.bytes.len());
        }
    }
}

pub fn stream_with_bounded_pipeline<R, W, C, P>(
    reader: R,
    writer: W,
    start_offset: u64,
    options: RemoteRelayOptions,
    is_cancelled: C,
    report_progress: P,
) -> Result<RemoteRelayReport, RemoteRelayError>
where
    R: Read + Send + 'static,
    W: Write + Send + 'static,
    C: Fn() -> bool + Send + Sync + 'static,
    P: Fn(u64) + Send + Sync + 'static,
{
    stream_with_bounded_pipeline_tracked(
        reader,
        writer,
        start_offset,
        options,
        is_cancelled,
        report_progress,
        None,
    )
}

fn stream_with_bounded_pipeline_tracked<R, W, C, P>(
    mut reader: R,
    mut writer: W,
    start_offset: u64,
    options: RemoteRelayOptions,
    is_cancelled: C,
    report_progress: P,
    shared_buffer_tracker: Option<Arc<SharedBufferTracker>>,
) -> Result<RemoteRelayReport, RemoteRelayError>
where
    R: Read + Send + 'static,
    W: Write + Send + 'static,
    C: Fn() -> bool + Send + Sync + 'static,
    P: Fn(u64) + Send + Sync + 'static,
{
    if options.chunk_size_bytes == 0 || options.queue_depth < 2 {
        return Err(RemoteRelayError {
            code: "FILES_INVALID_TRANSFER_TUNING".to_string(),
            committed_offset: start_offset,
        });
    }

    // The bound includes one chunk being written and one producer chunk waiting
    // to enter the channel, not only chunks already queued in the channel.
    let queue_capacity = options.queue_depth.saturating_sub(2);
    let (sender, receiver) = mpsc::sync_channel::<BufferedChunk>(queue_capacity);
    let committed_offset = Arc::new(AtomicU64::new(start_offset));
    let buffered_bytes = Arc::new(AtomicUsize::new(0));
    let peak_buffered_bytes = Arc::new(AtomicUsize::new(0));
    let is_cancelled = Arc::new(is_cancelled);
    let report_progress = Arc::new(report_progress);

    let producer_committed_offset = Arc::clone(&committed_offset);
    let producer_buffered_bytes = Arc::clone(&buffered_bytes);
    let producer_peak_buffered_bytes = Arc::clone(&peak_buffered_bytes);
    let producer_is_cancelled = Arc::clone(&is_cancelled);
    let producer_shared_buffer_tracker = shared_buffer_tracker;
    let producer = thread::spawn(move || {
        let mut hasher = Sha256::new();
        let mut bytes_read = 0_u64;
        loop {
            if producer_is_cancelled() {
                return Err(RemoteRelayError {
                    code: "FILES_TRANSFER_CANCELED".to_string(),
                    committed_offset: producer_committed_offset.load(Ordering::SeqCst),
                });
            }
            let mut buffer = vec![0_u8; options.chunk_size_bytes];
            let count = loop {
                match reader.read(&mut buffer) {
                    Ok(count) => break count,
                    Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
                    Err(_) => {
                        return Err(RemoteRelayError {
                            code: "FILES_SOURCE_READ_FAILED".to_string(),
                            committed_offset: producer_committed_offset.load(Ordering::SeqCst),
                        })
                    }
                }
            };
            if count == 0 {
                return Ok((bytes_read, hex::encode(hasher.finalize())));
            }
            buffer.truncate(count);
            hasher.update(&buffer);
            bytes_read = bytes_read.saturating_add(count as u64);
            let now_buffered = producer_buffered_bytes.fetch_add(count, Ordering::SeqCst) + count;
            producer_peak_buffered_bytes.fetch_max(now_buffered, Ordering::SeqCst);
            if let Some(tracker) = &producer_shared_buffer_tracker {
                tracker.reserve(count);
            }
            let chunk = BufferedChunk {
                bytes: buffer,
                buffered_bytes: Arc::clone(&producer_buffered_bytes),
                shared_buffer_tracker: producer_shared_buffer_tracker.clone(),
            };
            if sender.send(chunk).is_err() {
                return Err(RemoteRelayError {
                    code: if producer_is_cancelled() {
                        "FILES_TRANSFER_CANCELED"
                    } else {
                        "FILES_DESTINATION_WRITE_FAILED"
                    }
                    .to_string(),
                    committed_offset: producer_committed_offset.load(Ordering::SeqCst),
                });
            }
        }
    });

    let consumer_committed_offset = Arc::clone(&committed_offset);
    let consumer_is_cancelled = Arc::clone(&is_cancelled);
    let consumer_report_progress = Arc::clone(&report_progress);
    let consumer = thread::spawn(move || {
        while let Ok(chunk) = receiver.recv() {
            if consumer_is_cancelled() {
                return Err(RemoteRelayError {
                    code: "FILES_TRANSFER_CANCELED".to_string(),
                    committed_offset: consumer_committed_offset.load(Ordering::SeqCst),
                });
            }
            if writer.write_all(&chunk.bytes).is_err() {
                return Err(RemoteRelayError {
                    code: "FILES_DESTINATION_WRITE_FAILED".to_string(),
                    committed_offset: consumer_committed_offset.load(Ordering::SeqCst),
                });
            }
            let offset = consumer_committed_offset
                .fetch_add(chunk.bytes.len() as u64, Ordering::SeqCst)
                .saturating_add(chunk.bytes.len() as u64);
            consumer_report_progress(offset);
        }
        writer.flush().map_err(|_| RemoteRelayError {
            code: "FILES_DESTINATION_WRITE_FAILED".to_string(),
            committed_offset: consumer_committed_offset.load(Ordering::SeqCst),
        })?;
        Ok(consumer_committed_offset.load(Ordering::SeqCst))
    });

    let producer_result = producer.join().map_err(|_| RemoteRelayError {
        code: "FILES_SOURCE_READ_FAILED".to_string(),
        committed_offset: committed_offset.load(Ordering::SeqCst),
    })?;
    let consumer_result = consumer.join().map_err(|_| RemoteRelayError {
        code: "FILES_DESTINATION_WRITE_FAILED".to_string(),
        committed_offset: committed_offset.load(Ordering::SeqCst),
    })?;

    let final_offset = match consumer_result {
        Ok(offset) => offset,
        Err(error) => return Err(error),
    };
    let (bytes_copied, sha256_hex) = match producer_result {
        Ok(result) => result,
        Err(error) => return Err(error),
    };
    if final_offset.saturating_sub(start_offset) != bytes_copied {
        return Err(RemoteRelayError {
            code: "FILES_SIZE_MISMATCH".to_string(),
            committed_offset: final_offset,
        });
    }

    Ok(RemoteRelayReport {
        bytes_copied,
        final_offset,
        sha256_hex,
        peak_buffered_bytes: peak_buffered_bytes.load(Ordering::SeqCst),
    })
}

#[cfg(test)]
mod remote_transfer_tests {
    use super::{
        build_remote_sha256_command, build_scp_destination_command, build_scp_source_command,
        parse_remote_checkpoint_contents, parse_remote_sha256_output, plan_remote_transfer_ranges,
        remote_checkpoint_staging_path, remote_partial_paths, resolve_remote_resume, sha256_reader,
        stream_with_bounded_pipeline, transfer_remote_file, transfer_remote_file_ranges,
        LocalFileTransferBackend, RemoteFileIdentity, RemoteFileTransferBackend,
        RemoteFileTransferRequest, RemoteRelayOptions, RemoteTransferCheckpoint,
    };
    use sha2::{Digest, Sha256};
    use std::collections::HashMap;
    use std::io::{self, Read, Write};
    use std::path::Path;
    use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
    use std::sync::{Arc, Mutex};

    struct GeneratedReader {
        remaining: u64,
        byte: u8,
        largest_request: Arc<AtomicUsize>,
    }

    impl Read for GeneratedReader {
        fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
            self.largest_request
                .fetch_max(buffer.len(), Ordering::SeqCst);
            if self.remaining == 0 {
                return Ok(0);
            }
            let count = buffer.len().min(self.remaining as usize);
            buffer[..count].fill(self.byte);
            self.remaining -= count as u64;
            Ok(count)
        }
    }

    struct CountingWriter {
        bytes_written: Arc<AtomicU64>,
    }

    impl Write for CountingWriter {
        fn write(&mut self, buffer: &[u8]) -> io::Result<usize> {
            self.bytes_written
                .fetch_add(buffer.len() as u64, Ordering::SeqCst);
            Ok(buffer.len())
        }

        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    struct SlowWriter {
        bytes_written: Arc<AtomicU64>,
    }

    #[derive(Clone)]
    struct MemoryBackend {
        state: Arc<Mutex<MemoryBackendState>>,
    }

    #[derive(Default)]
    struct MemoryBackendState {
        files: HashMap<String, Vec<u8>>,
        mtimes: HashMap<String, i64>,
        metadata: HashMap<String, RemoteFileIdentity>,
        checkpoints: HashMap<String, RemoteTransferCheckpoint>,
        reader_offsets: Vec<u64>,
        reader_bytes_by_offset: HashMap<u64, u64>,
        promoted: Vec<(String, String)>,
        identity_calls: usize,
        mutate_source_on_second_identity: bool,
        mutate_source_after_sha256: bool,
        corrupt_checksum: bool,
        delay_stale_checkpoint_writes: bool,
        flush_count: usize,
    }

    struct MemoryReader {
        cursor: io::Cursor<Vec<u8>>,
        state: Arc<Mutex<MemoryBackendState>>,
        start_offset: u64,
    }

    impl Read for MemoryReader {
        fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
            let count = self.cursor.read(buffer)?;
            *self
                .state
                .lock()
                .expect("memory backend")
                .reader_bytes_by_offset
                .entry(self.start_offset)
                .or_default() += count as u64;
            Ok(count)
        }
    }

    struct MemoryWriter {
        state: Arc<Mutex<MemoryBackendState>>,
        path: String,
        offset: usize,
    }

    impl Write for MemoryWriter {
        fn write(&mut self, buffer: &[u8]) -> io::Result<usize> {
            let mut state = self.state.lock().expect("memory backend");
            let file = state.files.entry(self.path.clone()).or_default();
            let end = self.offset.saturating_add(buffer.len());
            if file.len() < end {
                file.resize(end, 0);
            }
            file[self.offset..end].copy_from_slice(buffer);
            self.offset = end;
            Ok(buffer.len())
        }

        fn flush(&mut self) -> io::Result<()> {
            self.state.lock().expect("memory backend").flush_count += 1;
            Ok(())
        }
    }

    impl MemoryBackend {
        fn with_file(path: &str, contents: &[u8], mtime: i64) -> Self {
            let mut state = MemoryBackendState::default();
            state.files.insert(path.to_string(), contents.to_vec());
            state.mtimes.insert(path.to_string(), mtime);
            Self {
                state: Arc::new(Mutex::new(state)),
            }
        }
    }

    impl RemoteFileTransferBackend for MemoryBackend {
        type Reader = MemoryReader;
        type Writer = MemoryWriter;

        fn file_identity(&mut self, path: &str) -> Result<Option<RemoteFileIdentity>, String> {
            let mut state = self.state.lock().expect("memory backend");
            state.identity_calls += 1;
            if state.mutate_source_on_second_identity && state.identity_calls == 2 {
                state.mtimes.insert(path.to_string(), 999);
            }
            Ok(state.files.get(path).map(|bytes| RemoteFileIdentity {
                size: bytes.len() as u64,
                mtime_unix: *state.mtimes.get(path).unwrap_or(&0),
            }))
        }

        fn read_resume_metadata(
            &mut self,
            path: &str,
        ) -> Result<Option<RemoteFileIdentity>, String> {
            Ok(self
                .state
                .lock()
                .expect("memory backend")
                .metadata
                .get(path)
                .cloned())
        }

        fn write_resume_metadata(
            &mut self,
            path: &str,
            identity: &RemoteFileIdentity,
        ) -> Result<(), String> {
            self.state
                .lock()
                .expect("memory backend")
                .metadata
                .insert(path.to_string(), identity.clone());
            Ok(())
        }

        fn read_checkpoint(
            &mut self,
            path: &str,
        ) -> Result<Option<RemoteTransferCheckpoint>, String> {
            Ok(self
                .state
                .lock()
                .expect("memory backend")
                .checkpoints
                .get(path)
                .cloned())
        }

        fn write_checkpoint(
            &mut self,
            path: &str,
            checkpoint: &RemoteTransferCheckpoint,
        ) -> Result<(), String> {
            let completed_count = checkpoint.completed.iter().filter(|done| **done).count();
            let delay_stale_writes = self
                .state
                .lock()
                .expect("memory backend")
                .delay_stale_checkpoint_writes;
            if delay_stale_writes && completed_count > 0 {
                let delay = 5_usize.saturating_sub(completed_count) as u64 * 10;
                std::thread::sleep(std::time::Duration::from_millis(delay));
            }
            self.state
                .lock()
                .expect("memory backend")
                .checkpoints
                .insert(path.to_string(), checkpoint.clone());
            Ok(())
        }

        fn remove_file_if_exists(&mut self, path: &str) -> Result<(), String> {
            let mut state = self.state.lock().expect("memory backend");
            state.files.remove(path);
            state.metadata.remove(path);
            state.checkpoints.remove(path);
            Ok(())
        }

        fn open_reader(&mut self, path: &str, offset: u64) -> Result<Self::Reader, String> {
            let mut state = self.state.lock().expect("memory backend");
            state.reader_offsets.push(offset);
            let bytes = state
                .files
                .get(path)
                .cloned()
                .ok_or("FILES_REMOTE_FILE_MISSING")?;
            Ok(MemoryReader {
                cursor: io::Cursor::new(bytes.into_iter().skip(offset as usize).collect()),
                state: Arc::clone(&self.state),
                start_offset: offset,
            })
        }

        fn open_writer(
            &mut self,
            path: &str,
            offset: u64,
            truncate: bool,
        ) -> Result<Self::Writer, String> {
            let mut state = self.state.lock().expect("memory backend");
            if truncate {
                state.files.insert(path.to_string(), Vec::new());
            } else {
                state.files.entry(path.to_string()).or_default();
            }
            drop(state);
            Ok(MemoryWriter {
                state: Arc::clone(&self.state),
                path: path.to_string(),
                offset: offset as usize,
            })
        }

        fn sha256(&mut self, path: &str) -> Result<String, String> {
            let mut state = self.state.lock().expect("memory backend");
            let bytes = state
                .files
                .get(path)
                .cloned()
                .ok_or("FILES_REMOTE_FILE_MISSING")?;
            let mut digest = hex::encode(Sha256::digest(&bytes));
            if state.corrupt_checksum {
                digest.replace_range(..1, if digest.starts_with('0') { "1" } else { "0" });
            }
            if state.mutate_source_after_sha256 {
                state.mtimes.insert(path.to_string(), 1_001);
            }
            Ok(digest)
        }

        fn promote(&mut self, partial_path: &str, destination_path: &str) -> Result<(), String> {
            let mut state = self.state.lock().expect("memory backend");
            let bytes = state
                .files
                .remove(partial_path)
                .ok_or("FILES_REMOTE_FILE_MISSING")?;
            state.files.insert(destination_path.to_string(), bytes);
            state
                .promoted
                .push((partial_path.to_string(), destination_path.to_string()));
            Ok(())
        }
    }

    impl Write for SlowWriter {
        fn write(&mut self, buffer: &[u8]) -> io::Result<usize> {
            std::thread::sleep(std::time::Duration::from_millis(2));
            self.bytes_written
                .fetch_add(buffer.len() as u64, Ordering::SeqCst);
            Ok(buffer.len())
        }

        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    #[test]
    fn bounded_pipeline_keeps_fixed_memory_and_uses_u64_offsets_past_one_tibibyte() {
        let chunk_size = 64 * 1024;
        let queue_depth = 4;
        let tail_size = (chunk_size * 3 + 17) as u64;
        let start_offset = 1_u64 << 40;
        let largest_request = Arc::new(AtomicUsize::new(0));
        let bytes_written = Arc::new(AtomicU64::new(0));
        let reader = GeneratedReader {
            remaining: tail_size,
            byte: 0x5a,
            largest_request: Arc::clone(&largest_request),
        };
        let writer = CountingWriter {
            bytes_written: Arc::clone(&bytes_written),
        };

        let report = stream_with_bounded_pipeline(
            reader,
            writer,
            start_offset,
            RemoteRelayOptions {
                chunk_size_bytes: chunk_size,
                queue_depth,
            },
            || false,
            |_| {},
        )
        .expect("bounded relay");

        let mut expected_hasher = Sha256::new();
        expected_hasher.update(vec![0x5a; tail_size as usize]);
        assert_eq!(report.bytes_copied, tail_size);
        assert_eq!(report.final_offset, start_offset + tail_size);
        assert_eq!(report.sha256_hex, hex::encode(expected_hasher.finalize()));
        assert_eq!(bytes_written.load(Ordering::SeqCst), tail_size);
        assert!(largest_request.load(Ordering::SeqCst) <= chunk_size);
        assert!(report.peak_buffered_bytes <= chunk_size * queue_depth);
    }

    #[test]
    fn range_plan_uses_at_most_four_balanced_workers_for_huge_files() {
        let total_size = 5_u64 << 40;
        let ranges = plan_remote_transfer_ranges(total_size, 256_u64 << 30, 8)
            .expect("huge-file range plan");

        assert_eq!(ranges.len(), 4);
        assert_eq!(ranges.first().map(|range| range.start), Some(0));
        assert_eq!(
            ranges
                .last()
                .map(|range| range.start.saturating_add(range.length)),
            Some(total_size)
        );
        for pair in ranges.windows(2) {
            assert_eq!(pair[0].start + pair[0].length, pair[1].start);
        }
        let shortest = ranges.iter().map(|range| range.length).min().unwrap();
        let longest = ranges.iter().map(|range| range.length).max().unwrap();
        assert!(longest - shortest <= 1);
    }

    #[test]
    fn range_plan_keeps_worker_starts_aligned_to_the_io_chunk() {
        let chunk_size = 1024 * 1024;
        let total_size = 19 * chunk_size + 17;
        let ranges =
            plan_remote_transfer_ranges(total_size, chunk_size, 4).expect("aligned range plan");

        assert_eq!(ranges.len(), 4);
        assert!(ranges.iter().all(|range| range.start % chunk_size == 0));
        assert_eq!(
            ranges
                .last()
                .map(|range| range.start.saturating_add(range.length)),
            Some(total_size)
        );
        let shortest = ranges.iter().map(|range| range.length).min().unwrap();
        let longest = ranges.iter().map(|range| range.length).max().unwrap();
        assert!(longest - shortest <= chunk_size);
    }

    #[test]
    fn local_backend_runs_parallel_ranges_with_atomic_promotion_and_checksum() {
        let directory = tempfile::tempdir().expect("temporary directory");
        let source_path = directory.path().join("source.bin");
        let destination_path = directory.path().join("destination.bin");
        let source_bytes = (0..(5 * 64 * 1024 + 37))
            .map(|index| (index % 251) as u8)
            .collect::<Vec<_>>();
        std::fs::write(&source_path, &source_bytes).expect("source file");
        std::fs::write(&destination_path, b"old destination").expect("old destination");

        let report = transfer_remote_file_ranges(
            || Ok(LocalFileTransferBackend::new()),
            || Ok(LocalFileTransferBackend::new()),
            &RemoteFileTransferRequest {
                job_id: "local-parallel".to_string(),
                source_path: source_path.to_string_lossy().into_owned(),
                destination_path: destination_path.to_string_lossy().into_owned(),
                expected_size: source_bytes.len() as u64,
                requested_offset: 0,
                force_restart: false,
            },
            64 * 1024,
            4,
            || false,
            |_| {},
        )
        .expect("parallel local transfer");

        assert_eq!(report.bytes_done, source_bytes.len() as u64);
        assert_eq!(
            std::fs::read(&destination_path).expect("destination"),
            source_bytes
        );
        let partials = std::fs::read_dir(directory.path())
            .expect("directory listing")
            .map(|entry| {
                entry
                    .expect("entry")
                    .file_name()
                    .to_string_lossy()
                    .into_owned()
            })
            .filter(|name| name.contains(".stacio-"))
            .collect::<Vec<_>>();
        assert!(partials.is_empty(), "leftover transfer state: {partials:?}");
    }

    #[test]
    fn range_transfer_reports_actual_peak_buffered_bytes_for_a_small_file() {
        let source_bytes = vec![0x6d; 7 * 1024];
        let source = MemoryBackend::with_file("/source.bin", &source_bytes, 100);
        let destination = MemoryBackend::with_file("/destination.bin", b"old", 1);
        let source_factory = {
            let source = source.clone();
            move || Ok(source.clone())
        };
        let destination_factory = {
            let destination = destination.clone();
            move || Ok(destination.clone())
        };

        let report = transfer_remote_file_ranges(
            source_factory,
            destination_factory,
            &RemoteFileTransferRequest {
                job_id: "actual-peak".to_string(),
                source_path: "/source.bin".to_string(),
                destination_path: "/destination.bin".to_string(),
                expected_size: source_bytes.len() as u64,
                requested_offset: 0,
                force_restart: false,
            },
            64 * 1024,
            4,
            || false,
            |_| {},
        )
        .expect("small range transfer");

        assert_eq!(report.peak_buffered_bytes, source_bytes.len());
    }

    #[test]
    fn range_transfer_rechecks_source_identity_after_checksum_before_promotion() {
        let source_bytes = vec![0x4f; 256 * 1024];
        let source = MemoryBackend::with_file("/source.bin", &source_bytes, 100);
        source
            .state
            .lock()
            .expect("source state")
            .mutate_source_after_sha256 = true;
        let destination = MemoryBackend::with_file("/destination.bin", b"old", 1);
        let source_factory = {
            let source = source.clone();
            move || Ok(source.clone())
        };
        let destination_factory = {
            let destination = destination.clone();
            move || Ok(destination.clone())
        };

        let error = transfer_remote_file_ranges(
            source_factory,
            destination_factory,
            &RemoteFileTransferRequest {
                job_id: "source-changed-after-checksum".to_string(),
                source_path: "/source.bin".to_string(),
                destination_path: "/destination.bin".to_string(),
                expected_size: source_bytes.len() as u64,
                requested_offset: 0,
                force_restart: false,
            },
            64 * 1024,
            4,
            || false,
            |_| {},
        )
        .expect_err("changed source must not replace destination");

        assert_eq!(error.code, "FILES_SOURCE_CHANGED");
        let destination_state = destination.state.lock().expect("destination state");
        assert_eq!(
            destination_state
                .files
                .get("/destination.bin")
                .map(Vec::as_slice),
            Some(b"old".as_slice())
        );
        assert!(destination_state.promoted.is_empty());
    }

    #[test]
    fn remote_checkpoint_staging_path_stays_adjacent_and_hidden() {
        let final_path = "/archive/.image.iso.stacio-job.checkpoint.json";
        let staging_path =
            remote_checkpoint_staging_path(final_path).expect("checkpoint staging path");

        assert_eq!(staging_path, format!("{final_path}.tmp"));
        assert_eq!(
            Path::new(&staging_path).parent(),
            Path::new(final_path).parent()
        );
    }

    #[test]
    fn malformed_checkpoint_contents_are_treated_as_invalid_recovery_state() {
        assert_eq!(parse_remote_checkpoint_contents("{not-json"), None);
    }

    #[test]
    fn range_transfer_restarts_when_checkpoint_has_no_matching_partial_file() {
        let source_bytes = vec![0x31; 256 * 1024];
        let source = MemoryBackend::with_file("/source.bin", &source_bytes, 100);
        let destination = MemoryBackend::with_file("/old.bin", b"old", 1);
        let paths =
            remote_partial_paths("/destination.bin", "missing-partial").expect("partial paths");
        destination
            .state
            .lock()
            .expect("destination state")
            .checkpoints
            .insert(
                paths.metadata.clone(),
                RemoteTransferCheckpoint {
                    source_identity: RemoteFileIdentity {
                        size: source_bytes.len() as u64,
                        mtime_unix: 100,
                    },
                    chunk_size_bytes: 64 * 1024,
                    completed: vec![true, false, false, false],
                },
            );
        let source_factory = {
            let source = source.clone();
            move || Ok(source.clone())
        };
        let destination_factory = {
            let destination = destination.clone();
            move || Ok(destination.clone())
        };

        let report = transfer_remote_file_ranges(
            source_factory,
            destination_factory,
            &RemoteFileTransferRequest {
                job_id: "missing-partial".to_string(),
                source_path: "/source.bin".to_string(),
                destination_path: "/destination.bin".to_string(),
                expected_size: source_bytes.len() as u64,
                requested_offset: 0,
                force_restart: false,
            },
            64 * 1024,
            4,
            || false,
            |_| {},
        )
        .expect("restart missing partial");

        assert_eq!(report.resumed_from, 0);
        let source_state = source.state.lock().expect("source state");
        assert!(source_state.reader_offsets.contains(&0));
        drop(source_state);
        let destination_state = destination.state.lock().expect("destination state");
        assert_eq!(
            destination_state
                .files
                .get("/destination.bin")
                .map(Vec::as_slice),
            Some(source_bytes.as_slice())
        );
    }

    #[test]
    fn range_transfer_discards_unverified_partial_instead_of_trusting_requested_offset() {
        let source_bytes = vec![0x34; 256 * 1024];
        let source = MemoryBackend::with_file("/source.bin", &source_bytes, 100);
        let destination = MemoryBackend::with_file("/old.bin", b"old", 1);
        let paths =
            remote_partial_paths("/destination.bin", "unverified-partial").expect("partial paths");
        destination
            .state
            .lock()
            .expect("destination state")
            .files
            .insert(paths.data, vec![0x99; 128 * 1024]);
        let source_factory = {
            let source = source.clone();
            move || Ok(source.clone())
        };
        let destination_factory = {
            let destination = destination.clone();
            move || Ok(destination.clone())
        };

        let report = transfer_remote_file_ranges(
            source_factory,
            destination_factory,
            &RemoteFileTransferRequest {
                job_id: "unverified-partial".to_string(),
                source_path: "/source.bin".to_string(),
                destination_path: "/destination.bin".to_string(),
                expected_size: source_bytes.len() as u64,
                requested_offset: 128 * 1024,
                force_restart: false,
            },
            64 * 1024,
            4,
            || false,
            |_| {},
        )
        .expect("unverified state must restart safely");

        assert_eq!(report.resumed_from, 0);
        let source_state = source.state.lock().expect("source state");
        assert!(source_state.reader_offsets.contains(&0));
        drop(source_state);
        let destination_state = destination.state.lock().expect("destination state");
        assert_eq!(
            destination_state
                .files
                .get("/destination.bin")
                .map(Vec::as_slice),
            Some(source_bytes.as_slice())
        );
    }

    #[test]
    fn range_transfer_resumes_completed_ranges_and_reads_each_remaining_range_once() {
        let source_bytes = vec![0x32; 256 * 1024];
        let source = MemoryBackend::with_file("/source.bin", &source_bytes, 100);
        let destination = MemoryBackend::with_file("/old.bin", b"old", 1);
        let paths =
            remote_partial_paths("/destination.bin", "range-resume").expect("partial paths");
        {
            let mut state = destination.state.lock().expect("destination state");
            state
                .files
                .insert(paths.data.clone(), source_bytes[..64 * 1024].to_vec());
            state.checkpoints.insert(
                paths.metadata.clone(),
                RemoteTransferCheckpoint {
                    source_identity: RemoteFileIdentity {
                        size: source_bytes.len() as u64,
                        mtime_unix: 100,
                    },
                    chunk_size_bytes: 64 * 1024,
                    completed: vec![true, false, false, false],
                },
            );
        }
        let source_factory = {
            let source = source.clone();
            move || Ok(source.clone())
        };
        let destination_factory = {
            let destination = destination.clone();
            move || Ok(destination.clone())
        };

        let report = transfer_remote_file_ranges(
            source_factory,
            destination_factory,
            &RemoteFileTransferRequest {
                job_id: "range-resume".to_string(),
                source_path: "/source.bin".to_string(),
                destination_path: "/destination.bin".to_string(),
                expected_size: source_bytes.len() as u64,
                requested_offset: 0,
                force_restart: false,
            },
            64 * 1024,
            4,
            || false,
            |_| {},
        )
        .expect("range resume");

        assert_eq!(report.resumed_from, 64 * 1024);
        let source_state = source.state.lock().expect("source state");
        assert_eq!(
            source_state
                .reader_offsets
                .iter()
                .copied()
                .collect::<std::collections::BTreeSet<_>>(),
            std::collections::BTreeSet::from([64 * 1024, 128 * 1024, 192 * 1024])
        );
        for offset in [64 * 1024, 128 * 1024, 192 * 1024] {
            assert_eq!(
                source_state.reader_bytes_by_offset.get(&offset),
                Some(&(64 * 1024))
            );
        }
        drop(source_state);
        let destination_state = destination.state.lock().expect("destination state");
        assert_eq!(
            destination_state
                .files
                .get("/destination.bin")
                .map(Vec::as_slice),
            Some(source_bytes.as_slice())
        );
    }

    #[test]
    fn range_transfer_serializes_checkpoint_updates_and_keeps_recovery_state_on_failure() {
        let source_bytes = vec![0x33; 256 * 1024];
        let source = MemoryBackend::with_file("/source.bin", &source_bytes, 100);
        let destination = MemoryBackend::with_file("/destination.bin", b"old", 1);
        {
            let mut state = destination.state.lock().expect("destination state");
            state.delay_stale_checkpoint_writes = true;
            state.corrupt_checksum = true;
        }
        let source_factory = {
            let source = source.clone();
            move || Ok(source.clone())
        };
        let destination_factory = {
            let destination = destination.clone();
            move || Ok(destination.clone())
        };

        let error = transfer_remote_file_ranges(
            source_factory,
            destination_factory,
            &RemoteFileTransferRequest {
                job_id: "checkpoint-order".to_string(),
                source_path: "/source.bin".to_string(),
                destination_path: "/destination.bin".to_string(),
                expected_size: source_bytes.len() as u64,
                requested_offset: 0,
                force_restart: false,
            },
            64 * 1024,
            4,
            || false,
            |_| {},
        )
        .expect_err("checksum failure preserves checkpoint");

        assert_eq!(error.code, "FILES_CHECKSUM_MISMATCH");
        let paths =
            remote_partial_paths("/destination.bin", "checkpoint-order").expect("partial paths");
        let state = destination.state.lock().expect("destination state");
        assert_eq!(
            state
                .checkpoints
                .get(&paths.metadata)
                .map(|checkpoint| checkpoint.completed.clone()),
            Some(vec![true, true, true, true])
        );
        assert_eq!(
            state.files.get("/destination.bin").map(Vec::as_slice),
            Some(b"old".as_slice())
        );
        assert!(state.files.contains_key(&paths.data));
    }

    #[test]
    fn empty_range_transfer_flushes_partial_before_atomic_promotion() {
        let source = MemoryBackend::with_file("/empty.bin", b"", 100);
        let destination = MemoryBackend::with_file("/destination.bin", b"old", 1);
        let source_factory = {
            let source = source.clone();
            move || Ok(source.clone())
        };
        let destination_factory = {
            let destination = destination.clone();
            move || Ok(destination.clone())
        };

        transfer_remote_file_ranges(
            source_factory,
            destination_factory,
            &RemoteFileTransferRequest {
                job_id: "empty".to_string(),
                source_path: "/empty.bin".to_string(),
                destination_path: "/destination.bin".to_string(),
                expected_size: 0,
                requested_offset: 0,
                force_restart: false,
            },
            64 * 1024,
            4,
            || false,
            |_| {},
        )
        .expect("empty transfer");

        let state = destination.state.lock().expect("destination state");
        assert!(state.flush_count >= 1);
        assert_eq!(
            state.files.get("/destination.bin").map(Vec::as_slice),
            Some(b"".as_slice())
        );
    }

    #[test]
    fn bounded_pipeline_cancels_without_losing_the_committed_offset() {
        let chunk_size = 32 * 1024;
        let bytes_written = Arc::new(AtomicU64::new(0));
        let reader = GeneratedReader {
            remaining: (chunk_size * 32) as u64,
            byte: 0x7f,
            largest_request: Arc::new(AtomicUsize::new(0)),
        };
        let writer = CountingWriter {
            bytes_written: Arc::clone(&bytes_written),
        };
        let cancellation_counter = Arc::clone(&bytes_written);

        let error = stream_with_bounded_pipeline(
            reader,
            writer,
            0,
            RemoteRelayOptions {
                chunk_size_bytes: chunk_size,
                queue_depth: 2,
            },
            move || cancellation_counter.load(Ordering::SeqCst) >= (chunk_size * 2) as u64,
            |_| {},
        )
        .expect_err("canceled relay");

        assert_eq!(error.code, "FILES_TRANSFER_CANCELED");
        assert_eq!(error.committed_offset, bytes_written.load(Ordering::SeqCst));
        assert!(error.committed_offset >= (chunk_size * 2) as u64);
        assert!(error.committed_offset < (chunk_size * 32) as u64);
    }

    #[test]
    fn bounded_pipeline_applies_backpressure_when_destination_is_slow() {
        let chunk_size = 16 * 1024;
        let queue_depth = 3;
        let reader = GeneratedReader {
            remaining: (chunk_size * 20) as u64,
            byte: 0x31,
            largest_request: Arc::new(AtomicUsize::new(0)),
        };
        let writer = SlowWriter {
            bytes_written: Arc::new(AtomicU64::new(0)),
        };

        let report = stream_with_bounded_pipeline(
            reader,
            writer,
            0,
            RemoteRelayOptions {
                chunk_size_bytes: chunk_size,
                queue_depth,
            },
            || false,
            |_| {},
        )
        .expect("slow destination relay");

        assert!(report.peak_buffered_bytes <= chunk_size * queue_depth);
    }

    #[test]
    fn remote_resume_uses_destination_partial_size_beyond_four_tibibytes() {
        let source = RemoteFileIdentity {
            size: 5_u64 << 40,
            mtime_unix: 1_721_891_200,
        };
        let partial_size = (4_u64 << 40) + 123_456;

        let decision = resolve_remote_resume(
            &source,
            Some(&source),
            Some(partial_size),
            partial_size.saturating_sub(1024),
            false,
        );

        assert_eq!(decision.offset, partial_size);
        assert!(!decision.discard_partial);
    }

    #[test]
    fn remote_resume_discards_partial_when_source_identity_changed() {
        let current = RemoteFileIdentity {
            size: 10_000,
            mtime_unix: 200,
        };
        let saved = RemoteFileIdentity {
            size: 10_000,
            mtime_unix: 199,
        };

        let decision = resolve_remote_resume(&current, Some(&saved), Some(8_000), 8_000, false);

        assert_eq!(decision.offset, 0);
        assert!(decision.discard_partial);
    }

    #[test]
    fn remote_partial_paths_are_hidden_stable_and_do_not_embed_raw_job_id() {
        let paths = remote_partial_paths(
            "/srv/releases/archive.tar.zst",
            "job/with user supplied spaces and ? characters",
        )
        .expect("partial paths");
        let repeated = remote_partial_paths(
            "/srv/releases/archive.tar.zst",
            "job/with user supplied spaces and ? characters",
        )
        .expect("stable partial paths");

        assert_eq!(paths, repeated);
        assert!(paths.data.ends_with(".part"));
        assert!(paths.metadata.ends_with(".meta"));
        assert!(paths.data.contains("/.archive.tar.zst.stacio-"));
        assert!(!paths.data.contains("user supplied"));
    }

    #[test]
    fn scp_offset_commands_stream_without_local_files_and_protect_partial_permissions() {
        let source = build_scp_source_command("/srv/releases/a file.bin", 4_u64 << 40)
            .expect("source command");
        let destination =
            build_scp_destination_command("/srv/backup/.a file.bin.stacio-1234.part", 4_u64 << 40)
                .expect("destination command");

        assert!(source.contains("dd if="));
        assert!(source.contains("bs=1048576 skip=4194304"));
        assert!(source.contains("'/srv/releases/a file.bin'"));
        assert!(destination.contains("umask 077"));
        assert!(destination.contains("dd of="));
        assert!(destination.contains("bs=1048576 seek=4194304"));
        assert!(destination.contains("conv=notrunc"));
        assert!(!source.contains("/tmp/"));
        assert!(!destination.contains("/tmp/"));
    }

    #[test]
    fn scp_unaligned_offsets_prefer_byte_seek_flags_with_compatible_fallbacks() {
        let offset = (4_u64 << 40) + 17;
        let source =
            build_scp_source_command("/srv/source.bin", offset).expect("unaligned source command");
        let destination = build_scp_destination_command("/srv/destination.bin", offset)
            .expect("unaligned destination command");

        assert!(source.contains("iflag=skip_bytes"));
        assert!(source.contains("tail -c +4398046511122"));
        assert!(destination.contains("oflag=seek_bytes"));
        assert!(destination.contains("bs=1 seek=4398046511121"));
    }

    #[test]
    fn remote_sha256_parser_accepts_linux_macos_and_openssl_formats() {
        let digest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
        for output in [
            format!("{digest}  archive.bin\n"),
            format!("{digest} *archive.bin\n"),
            format!("SHA256 (archive.bin) = {digest}\n"),
        ] {
            assert_eq!(parse_remote_sha256_output(&output).as_deref(), Some(digest));
        }
        let command = build_remote_sha256_command("/srv/archive.bin").expect("checksum command");
        assert!(command.contains("sha256sum"));
        assert!(command.contains("shasum -a 256"));
        assert!(command.contains("openssl dgst -sha256"));
    }

    #[test]
    fn streaming_sha256_supports_sftp_only_checksum_reads() {
        let mut reader = std::io::Cursor::new(b"abc");

        assert_eq!(
            sha256_reader(&mut reader).expect("streaming checksum"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }

    #[test]
    fn remote_file_transfer_resumes_from_remote_partial_and_commits_atomically() {
        let source_bytes = b"already copied and remaining bytes";
        let mut source = MemoryBackend::with_file("/source.bin", source_bytes, 100);
        let mut destination = MemoryBackend::with_file("/unrelated", b"keep", 1);
        let paths = remote_partial_paths("/destination.bin", "job-resume").expect("paths");
        {
            let mut state = destination.state.lock().expect("destination state");
            state
                .files
                .insert(paths.data.clone(), source_bytes[..15].to_vec());
            state.metadata.insert(
                paths.metadata.clone(),
                RemoteFileIdentity {
                    size: source_bytes.len() as u64,
                    mtime_unix: 100,
                },
            );
        }

        let report = transfer_remote_file(
            &mut source,
            &mut destination,
            &RemoteFileTransferRequest {
                job_id: "job-resume".to_string(),
                source_path: "/source.bin".to_string(),
                destination_path: "/destination.bin".to_string(),
                expected_size: source_bytes.len() as u64,
                requested_offset: 12,
                force_restart: false,
            },
            RemoteRelayOptions {
                chunk_size_bytes: 8,
                queue_depth: 2,
            },
            || false,
            |_| {},
        )
        .expect("resumed transfer");

        assert_eq!(report.resumed_from, 15);
        assert_eq!(report.bytes_done, source_bytes.len() as u64);
        let source_state = source.state.lock().expect("source state");
        assert_eq!(source_state.reader_offsets, [15]);
        drop(source_state);
        let destination_state = destination.state.lock().expect("destination state");
        assert_eq!(
            destination_state
                .files
                .get("/destination.bin")
                .map(Vec::as_slice),
            Some(source_bytes.as_slice())
        );
        assert!(!destination_state.files.contains_key(&paths.data));
        assert!(!destination_state.metadata.contains_key(&paths.metadata));
        assert_eq!(destination_state.promoted.len(), 1);
    }

    #[test]
    fn remote_file_transfer_never_promotes_corrupt_or_mutated_content() {
        for mutation in ["checksum", "source"] {
            let mut source = MemoryBackend::with_file("/source.bin", b"verified bytes", 100);
            let mut destination = MemoryBackend::with_file("/destination.bin", b"old", 10);
            if mutation == "checksum" {
                destination
                    .state
                    .lock()
                    .expect("destination state")
                    .corrupt_checksum = true;
            } else {
                source
                    .state
                    .lock()
                    .expect("source state")
                    .mutate_source_on_second_identity = true;
            }

            let error = transfer_remote_file(
                &mut source,
                &mut destination,
                &RemoteFileTransferRequest {
                    job_id: format!("job-{mutation}"),
                    source_path: "/source.bin".to_string(),
                    destination_path: "/destination.bin".to_string(),
                    expected_size: 14,
                    requested_offset: 0,
                    force_restart: false,
                },
                RemoteRelayOptions {
                    chunk_size_bytes: 8,
                    queue_depth: 2,
                },
                || false,
                |_| {},
            )
            .expect_err("unsafe transfer must fail");

            assert!(matches!(
                error.code.as_str(),
                "FILES_CHECKSUM_MISMATCH" | "FILES_SOURCE_CHANGED"
            ));
            let destination_state = destination.state.lock().expect("destination state");
            assert_eq!(
                destination_state
                    .files
                    .get("/destination.bin")
                    .map(Vec::as_slice),
                Some(b"old".as_slice())
            );
            assert!(destination_state.promoted.is_empty());
        }
    }
}
