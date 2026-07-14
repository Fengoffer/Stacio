use crate::domain::files::RemoteFileKind;
use crate::domain::scp::{ScpDirection, ScpResumeOptions, ScpTransferJob};
use crate::infrastructure::files::libssh2_exec_listing::{Libssh2ExecListing, RemoteFileOperation};
use crate::infrastructure::ssh::libssh2_transport::{
    with_temporary_blocking, Libssh2ConnectedSession, Libssh2Transport,
};
use crate::services::scp_service::{
    is_live_scp_transfer_cancelled, record_live_scp_transfer_progress,
};
use std::io::{self, BufReader, BufWriter, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::thread;
use std::time::{Duration, UNIX_EPOCH};

pub const DEFAULT_SCP_TRANSFER_CHUNK_SIZE_BYTES: usize = 128 * 1024;
pub const DEFAULT_SCP_TRANSFER_CHANNEL_WINDOW_SIZE_BYTES: u32 = 2 * 1024 * 1024;
pub const DEFAULT_SCP_TRANSFER_CHANNEL_PACKET_SIZE_BYTES: u32 = 128 * 1024;
pub const DEFAULT_SCP_TRANSFER_OPERATION_TIMEOUT_MS: u32 = 30_000;
pub const DEFAULT_SCP_TRANSFER_MAX_RETRY_ATTEMPTS: u8 = 3;
pub const DEFAULT_SCP_TRANSFER_COMPRESSION: &str = "none";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScpTransferTuning {
    pub chunk_size_bytes: usize,
    pub channel_window_size_bytes: u32,
    pub channel_packet_size_bytes: u32,
    pub operation_timeout_ms: u32,
    pub max_retry_attempts: u8,
    pub compression: &'static str,
}

impl Default for ScpTransferTuning {
    fn default() -> Self {
        Self {
            chunk_size_bytes: DEFAULT_SCP_TRANSFER_CHUNK_SIZE_BYTES,
            channel_window_size_bytes: DEFAULT_SCP_TRANSFER_CHANNEL_WINDOW_SIZE_BYTES,
            channel_packet_size_bytes: DEFAULT_SCP_TRANSFER_CHANNEL_PACKET_SIZE_BYTES,
            operation_timeout_ms: DEFAULT_SCP_TRANSFER_OPERATION_TIMEOUT_MS,
            max_retry_attempts: DEFAULT_SCP_TRANSFER_MAX_RETRY_ATTEMPTS,
            compression: DEFAULT_SCP_TRANSFER_COMPRESSION,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
struct ScpResumeMetadata {
    source_size: u64,
    source_mtime_unix: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Libssh2ScpUploadReport {
    pub remote_path: String,
    pub bytes_written: u64,
}

impl Libssh2ScpUploadReport {
    pub fn new(remote_path: String, bytes_written: u64) -> Self {
        Self {
            remote_path,
            bytes_written,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Libssh2ScpDownloadReport {
    pub local_path: String,
    pub bytes_read: u64,
}

impl Libssh2ScpDownloadReport {
    pub fn new(local_path: String, bytes_read: u64) -> Self {
        Self {
            local_path,
            bytes_read,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Libssh2ScpRequest {
    pub direction: ScpDirection,
    pub local_path: String,
    pub remote_path: String,
    pub bytes_total: u64,
}

pub struct Libssh2ScpEngine {
    tuning: ScpTransferTuning,
}

impl Libssh2ScpEngine {
    pub fn new() -> Self {
        Self {
            tuning: ScpTransferTuning::default(),
        }
    }

    pub fn with_tuning(tuning: ScpTransferTuning) -> Self {
        Self { tuning }
    }

    pub fn prepare_request(&self, job: &ScpTransferJob) -> Result<Libssh2ScpRequest, String> {
        let (local_path, remote_path) = match job.direction {
            ScpDirection::Upload => (&job.source_path, &job.destination_path),
            ScpDirection::Download => (&job.destination_path, &job.source_path),
        };

        validate_remote_path(remote_path)?;

        Ok(Libssh2ScpRequest {
            direction: job.direction.clone(),
            local_path: local_path.clone(),
            remote_path: remote_path.clone(),
            bytes_total: job.bytes_total,
        })
    }

    pub fn validate_upload_file(&self, job: &ScpTransferJob) -> Result<u64, String> {
        if job.direction != ScpDirection::Upload {
            return Err("FILES_INVALID_DIRECTION".to_string());
        }

        let request = self.prepare_request(job)?;
        let metadata = std::fs::metadata(Path::new(&request.local_path))
            .map_err(|_| "FILES_LOCAL_FILE_MISSING".to_string())?;

        if !metadata.is_file() {
            return Err("FILES_LOCAL_FILE_MISSING".to_string());
        }

        let actual_len = metadata.len();
        if request.bytes_total != 0 && request.bytes_total != actual_len {
            return Err("FILES_SIZE_MISMATCH".to_string());
        }

        Ok(actual_len)
    }

    pub fn validate_upload_source(&self, job: &ScpTransferJob) -> Result<u64, String> {
        if job.direction != ScpDirection::Upload {
            return Err("FILES_INVALID_DIRECTION".to_string());
        }

        let request = self.prepare_request(job)?;
        let source_path = Path::new(&request.local_path);
        let metadata =
            std::fs::metadata(source_path).map_err(|_| "FILES_LOCAL_FILE_MISSING".to_string())?;

        let actual_len = if metadata.is_file() {
            metadata.len()
        } else if metadata.is_dir() {
            Self::directory_upload_size(source_path)?
        } else {
            return Err("FILES_LOCAL_FILE_MISSING".to_string());
        };

        if request.bytes_total != 0 && request.bytes_total != actual_len {
            return Err("FILES_SIZE_MISMATCH".to_string());
        }

        Ok(actual_len)
    }

    pub fn upload_file(
        &self,
        session: &Libssh2ConnectedSession,
        job: &ScpTransferJob,
    ) -> Result<Libssh2ScpUploadReport, String> {
        self.upload_file_with_resume(session, job, &ScpResumeOptions::fresh())
    }

    pub fn upload_file_with_resume(
        &self,
        session: &Libssh2ConnectedSession,
        job: &ScpTransferJob,
        resume_options: &ScpResumeOptions,
    ) -> Result<Libssh2ScpUploadReport, String> {
        let bytes_total = self.validate_upload_source(job)?;
        let request = self.prepare_request(job)?;
        let local_path = Path::new(&request.local_path);
        let bytes_written = if local_path.is_dir() {
            self.upload_directory_recursive(
                session,
                job,
                local_path,
                &request.remote_path,
                bytes_total,
            )?
        } else {
            self.upload_single_file_with_resume(
                session,
                job,
                local_path,
                &request.remote_path,
                bytes_total,
                resume_options,
            )?
        };

        Ok(Libssh2ScpUploadReport::new(
            request.remote_path,
            bytes_written,
        ))
    }

    pub fn download_file(
        &self,
        session: &Libssh2ConnectedSession,
        job: &ScpTransferJob,
    ) -> Result<Libssh2ScpDownloadReport, String> {
        self.download_file_with_resume(session, job, &ScpResumeOptions::fresh())
    }

    pub fn download_file_with_resume(
        &self,
        session: &Libssh2ConnectedSession,
        job: &ScpTransferJob,
        resume_options: &ScpResumeOptions,
    ) -> Result<Libssh2ScpDownloadReport, String> {
        if job.direction != ScpDirection::Download {
            return Err("FILES_INVALID_DIRECTION".to_string());
        }

        let request = self.prepare_request(job)?;
        let local_path = Path::new(&request.local_path);
        let bytes_read = if self.remote_path_is_directory(session, &request.remote_path)? {
            self.download_directory_recursive(session, job, &request.remote_path, local_path)?
        } else {
            self.download_single_file(
                session,
                job,
                &request.remote_path,
                local_path,
                request.bytes_total,
                0,
                request.bytes_total,
                resume_options,
            )?
        };

        if request.bytes_total != 0 && request.bytes_total != bytes_read {
            return Err("FILES_SIZE_MISMATCH".to_string());
        }

        Ok(Libssh2ScpDownloadReport::new(
            request.local_path,
            bytes_read,
        ))
    }

    pub fn read_file_bytes(
        &self,
        session: &Libssh2ConnectedSession,
        remote_path: &str,
        offset: u64,
        length: Option<u64>,
    ) -> Result<Vec<u8>, String> {
        validate_remote_path(remote_path)?;
        let remote_path = resolve_remote_file_path_for_scp(session, remote_path)?;
        with_transfer_session_settings(session.session(), &self.tuning, || {
            let (mut remote_channel, stat) = session
                .session()
                .scp_recv(Path::new(&remote_path))
                .map_err(map_scp_error)?;
            Self::tune_receive_window(&mut remote_channel, &self.tuning)?;
            if offset > stat.size() {
                return Ok(Vec::new());
            }
            let mut sink = std::io::sink();
            let mut skipped_reader = std::io::Read::by_ref(&mut remote_channel).take(offset);
            let skipped = Self::copy_with_cancellation_and_tuning(
                &mut skipped_reader,
                &mut sink,
                || false,
                |_| {},
                &self.tuning,
            )?;
            Self::validate_transfer_count(skipped, offset)?;
            let remaining = stat.size().saturating_sub(offset);
            let target_len = length.unwrap_or(remaining).min(remaining);
            let mut bytes = Vec::with_capacity(target_len.min(usize::MAX as u64) as usize);
            let mut target_reader = remote_channel.take(target_len);
            let read = Self::copy_with_cancellation_and_tuning(
                &mut target_reader,
                &mut bytes,
                || false,
                |_| {},
                &self.tuning,
            )?;
            Self::validate_transfer_count(read, target_len)?;
            Ok(bytes)
        })
    }

    pub fn upload_bytes(
        &self,
        session: &Libssh2ConnectedSession,
        remote_path: &str,
        contents: &[u8],
    ) -> Result<Libssh2ScpUploadReport, String> {
        validate_remote_path(remote_path)?;
        let scp_remote_path = resolve_remote_file_path_for_scp(session, remote_path)?;
        let bytes_written =
            with_transfer_session_settings(session.session(), &self.tuning, || {
                let mut remote_channel = session
                    .session()
                    .scp_send(
                        Path::new(&scp_remote_path),
                        0o644,
                        contents.len() as u64,
                        None,
                    )
                    .map_err(map_scp_error)?;
                write_all_with_retry(&mut remote_channel, contents, &self.tuning)?;
                remote_channel.send_eof().map_err(map_scp_error)?;
                remote_channel.wait_eof().map_err(map_scp_error)?;
                remote_channel.close().map_err(map_scp_error)?;
                remote_channel.wait_close().map_err(map_scp_error)?;
                Ok::<_, String>(contents.len() as u64)
            })?;

        Ok(Libssh2ScpUploadReport::new(
            remote_path.to_string(),
            bytes_written,
        ))
    }

    fn download_directory_recursive(
        &self,
        session: &Libssh2ConnectedSession,
        job: &ScpTransferJob,
        remote_root: &str,
        local_root: &Path,
    ) -> Result<u64, String> {
        std::fs::create_dir_all(local_root).map_err(|_| "FILES_LOCAL_WRITE_FAILED".to_string())?;
        let remote_root = resolve_existing_remote_directory_path(session, remote_root)?;
        let listing = Libssh2ExecListing::new();
        let mut bytes_read = 0_u64;
        self.download_directory_children(
            session,
            job,
            &listing,
            &remote_root,
            &remote_root,
            local_root,
            &mut bytes_read,
        )?;
        Ok(bytes_read)
    }

    fn download_directory_children(
        &self,
        session: &Libssh2ConnectedSession,
        job: &ScpTransferJob,
        listing: &Libssh2ExecListing,
        remote_root: &str,
        remote_directory: &str,
        local_root: &Path,
        bytes_read: &mut u64,
    ) -> Result<(), String> {
        if is_live_scp_transfer_cancelled(&job.id) {
            return Err("FILES_TRANSFER_CANCELED".to_string());
        }

        for entry in listing.list_directory(session, remote_directory)? {
            let local_path = Self::local_path_for_remote_child(
                &local_root.to_string_lossy(),
                remote_root,
                &entry.path,
            )?;
            match entry.kind {
                RemoteFileKind::Directory => {
                    std::fs::create_dir_all(&local_path)
                        .map_err(|_| "FILES_LOCAL_WRITE_FAILED".to_string())?;
                    self.download_directory_children(
                        session,
                        job,
                        listing,
                        remote_root,
                        &entry.path,
                        local_root,
                        bytes_read,
                    )?;
                }
                RemoteFileKind::File | RemoteFileKind::Symlink => {
                    let copied = self.download_single_file(
                        session,
                        job,
                        &entry.path,
                        &local_path,
                        entry.size,
                        *bytes_read,
                        job.bytes_total,
                        &ScpResumeOptions::fresh(),
                    )?;
                    *bytes_read = bytes_read.saturating_add(copied);
                }
            }
        }
        Ok(())
    }

    fn download_single_file(
        &self,
        session: &Libssh2ConnectedSession,
        job: &ScpTransferJob,
        remote_path: &str,
        local_path: &Path,
        expected_size: u64,
        progress_base: u64,
        progress_total: u64,
        resume_options: &ScpResumeOptions,
    ) -> Result<u64, String> {
        validate_remote_path(remote_path)?;
        let remote_path = resolve_remote_file_path_for_scp(session, remote_path)?;
        let metadata_path = local_resume_metadata_path(local_path);
        let remote_identity = self.remote_file_identity(session, &remote_path)?;
        let resume_offset = if progress_base == 0 {
            local_resume_offset(
                local_path,
                &metadata_path,
                remote_identity.as_ref(),
                resume_options,
            )?
        } else {
            0
        };
        if let Some(parent) = local_path.parent() {
            std::fs::create_dir_all(parent).map_err(|_| "FILES_LOCAL_WRITE_FAILED".to_string())?;
        }
        if resume_offset > 0 {
            let remote_identity =
                remote_identity.ok_or_else(|| "FILES_TRANSFER_INTERRUPTED".to_string())?;
            return self.download_single_file_from_offset(
                session,
                job,
                &remote_path,
                local_path,
                &metadata_path,
                &remote_identity,
                resume_offset,
            );
        }
        if let Some(identity) = remote_identity.as_ref() {
            let _ = write_local_resume_metadata(&metadata_path, identity);
        }
        let local_file = std::fs::File::create(local_path)
            .map_err(|_| "FILES_LOCAL_WRITE_FAILED".to_string())?;
        let mut local_writer = BufWriter::with_capacity(self.tuning.chunk_size_bytes, local_file);
        let (bytes_read, remote_size) =
            with_transfer_session_settings(session.session(), &self.tuning, || {
                let (mut remote_channel, stat) = session
                    .session()
                    .scp_recv(Path::new(&remote_path))
                    .map_err(map_scp_error)?;
                Self::tune_receive_window(&mut remote_channel, &self.tuning)?;
                let reported_total = if progress_total == 0 {
                    progress_base.saturating_add(stat.size())
                } else {
                    progress_total
                };
                let bytes_read = Self::copy_with_cancellation_and_tuning(
                    &mut remote_channel,
                    &mut local_writer,
                    || is_live_scp_transfer_cancelled(&job.id),
                    |bytes_done| {
                        record_transfer_progress(
                            job,
                            progress_base.saturating_add(bytes_done),
                            reported_total,
                        )
                    },
                    &self.tuning,
                )?;
                Self::validate_transfer_count(bytes_read, stat.size())?;
                Ok::<_, String>((bytes_read, stat.size()))
            })?;
        local_writer
            .flush()
            .map_err(|_| "FILES_LOCAL_WRITE_FAILED".to_string())?;
        let _ = std::fs::remove_file(metadata_path);

        if expected_size != 0 && expected_size != remote_size {
            return Err("FILES_SIZE_MISMATCH".to_string());
        }

        Ok(bytes_read)
    }

    fn download_single_file_from_offset(
        &self,
        session: &Libssh2ConnectedSession,
        job: &ScpTransferJob,
        remote_path: &str,
        local_path: &Path,
        metadata_path: &Path,
        remote_identity: &ScpResumeMetadata,
        resume_offset: u64,
    ) -> Result<u64, String> {
        let local_file = std::fs::OpenOptions::new()
            .append(true)
            .open(local_path)
            .map_err(|_| "FILES_LOCAL_WRITE_FAILED".to_string())?;
        let mut local_writer = BufWriter::with_capacity(self.tuning.chunk_size_bytes, local_file);
        record_transfer_progress_with_status(
            job,
            resume_offset,
            remote_identity.source_size,
            "resuming",
        );
        let command = build_resume_download_command(remote_path, resume_offset)?;
        let copied = with_transfer_session_settings(session.session(), &self.tuning, || {
            let mut channel = self.open_transfer_channel(session)?;
            channel
                .exec(&command)
                .map_err(|_| "FILES_REMOTE_COMMAND_FAILED".to_string())?;
            let copied = Self::copy_with_cancellation_and_tuning(
                &mut channel,
                &mut local_writer,
                || is_live_scp_transfer_cancelled(&job.id),
                |bytes_done| {
                    record_transfer_progress_with_status(
                        job,
                        resume_offset.saturating_add(bytes_done),
                        remote_identity.source_size,
                        "resuming",
                    )
                },
                &self.tuning,
            )?;
            channel
                .wait_close()
                .map_err(|_| "FILES_REMOTE_COMMAND_FAILED".to_string())?;
            let status = channel
                .exit_status()
                .map_err(|_| "FILES_REMOTE_COMMAND_FAILED".to_string())?;
            if status != 0 {
                return Err("FILES_REMOTE_COMMAND_FAILED".to_string());
            }
            Ok::<_, String>(copied)
        })?;
        local_writer
            .flush()
            .map_err(|_| "FILES_LOCAL_WRITE_FAILED".to_string())?;
        Self::validate_transfer_count(
            resume_offset.saturating_add(copied),
            remote_identity.source_size,
        )?;
        let _ = std::fs::remove_file(metadata_path);
        Ok(remote_identity.source_size)
    }

    fn upload_directory_recursive(
        &self,
        session: &Libssh2ConnectedSession,
        job: &ScpTransferJob,
        local_root: &Path,
        remote_root: &str,
        progress_total: u64,
    ) -> Result<u64, String> {
        self.create_remote_directory(session, remote_root)?;
        let mut bytes_written = 0_u64;
        self.upload_directory_children(
            session,
            job,
            local_root,
            remote_root,
            &mut bytes_written,
            progress_total,
        )?;
        Ok(bytes_written)
    }

    fn upload_directory_children(
        &self,
        session: &Libssh2ConnectedSession,
        job: &ScpTransferJob,
        local_directory: &Path,
        remote_directory: &str,
        bytes_written: &mut u64,
        progress_total: u64,
    ) -> Result<(), String> {
        if is_live_scp_transfer_cancelled(&job.id) {
            return Err("FILES_TRANSFER_CANCELED".to_string());
        }

        let entries = std::fs::read_dir(local_directory)
            .map_err(|_| "FILES_LOCAL_FILE_MISSING".to_string())?;
        for entry in entries {
            let entry = entry.map_err(|_| "FILES_LOCAL_FILE_MISSING".to_string())?;
            let local_path = entry.path();
            let name = entry
                .file_name()
                .to_str()
                .ok_or_else(|| "FILES_UNSAFE_PATH".to_string())?
                .to_string();
            let remote_path = Self::remote_child_path(remote_directory, &name)?;
            let metadata = entry
                .metadata()
                .map_err(|_| "FILES_LOCAL_FILE_MISSING".to_string())?;

            if metadata.is_dir() {
                self.create_remote_directory(session, &remote_path)?;
                self.upload_directory_children(
                    session,
                    job,
                    &local_path,
                    &remote_path,
                    bytes_written,
                    progress_total,
                )?;
            } else if metadata.is_file() {
                let copied = self.upload_single_file(
                    session,
                    job,
                    &local_path,
                    &remote_path,
                    metadata.len(),
                    *bytes_written,
                    progress_total,
                )?;
                *bytes_written = bytes_written.saturating_add(copied);
            }
        }
        Ok(())
    }

    fn upload_single_file_with_resume(
        &self,
        session: &Libssh2ConnectedSession,
        job: &ScpTransferJob,
        local_path: &Path,
        remote_path: &str,
        expected_size: u64,
        resume_options: &ScpResumeOptions,
    ) -> Result<u64, String> {
        validate_remote_path(remote_path)?;
        let remote_path = resolve_remote_file_path_for_scp(session, remote_path)?;
        let local_identity = local_file_identity(local_path)?;
        let metadata_path = remote_resume_metadata_path(&remote_path)?;
        let remote_identity = self.remote_file_identity(session, &remote_path)?;
        let remote_resume_metadata = self.read_remote_resume_metadata(session, &metadata_path)?;
        let resume_offset = remote_resume_offset(
            remote_identity.as_ref(),
            remote_resume_metadata.as_ref(),
            &local_identity,
            resume_options,
        );

        if resume_offset > 0 {
            return self.upload_single_file_from_offset(
                session,
                job,
                local_path,
                &remote_path,
                &metadata_path,
                &local_identity,
                resume_offset,
            );
        }

        let _ = self.write_remote_resume_metadata(session, &metadata_path, &local_identity);
        let upload = self.upload_single_file(
            session,
            job,
            local_path,
            &remote_path,
            expected_size,
            0,
            expected_size,
        );
        if upload.is_ok() {
            let _ = self.delete_remote_resume_metadata(session, &metadata_path);
        }
        upload
    }

    fn upload_single_file(
        &self,
        session: &Libssh2ConnectedSession,
        job: &ScpTransferJob,
        local_path: &Path,
        remote_path: &str,
        expected_size: u64,
        progress_base: u64,
        progress_total: u64,
    ) -> Result<u64, String> {
        validate_remote_path(remote_path)?;
        let remote_path = resolve_remote_file_path_for_scp(session, remote_path)?;
        let local_file =
            std::fs::File::open(local_path).map_err(|_| "FILES_LOCAL_FILE_MISSING".to_string())?;
        let mut local_reader = BufReader::with_capacity(self.tuning.chunk_size_bytes, local_file);
        let bytes_written =
            with_transfer_session_settings(session.session(), &self.tuning, || {
                let mut channel = session
                    .session()
                    .scp_send(Path::new(&remote_path), 0o644, expected_size, None)
                    .map_err(map_scp_error)?;
                let bytes_written = Self::copy_with_cancellation_and_tuning(
                    &mut local_reader,
                    &mut channel,
                    || is_live_scp_transfer_cancelled(&job.id),
                    |bytes_done| {
                        record_transfer_progress(
                            job,
                            progress_base.saturating_add(bytes_done),
                            progress_total,
                        )
                    },
                    &self.tuning,
                )?;
                Self::validate_transfer_count(bytes_written, expected_size)?;
                channel.send_eof().map_err(map_scp_error)?;
                channel.wait_eof().map_err(map_scp_error)?;
                channel.close().map_err(map_scp_error)?;
                channel.wait_close().map_err(map_scp_error)?;
                Ok::<_, String>(bytes_written)
            })?;
        Ok(bytes_written)
    }

    fn upload_single_file_from_offset(
        &self,
        session: &Libssh2ConnectedSession,
        job: &ScpTransferJob,
        local_path: &Path,
        remote_path: &str,
        metadata_path: &str,
        local_identity: &ScpResumeMetadata,
        resume_offset: u64,
    ) -> Result<u64, String> {
        let local_file =
            std::fs::File::open(local_path).map_err(|_| "FILES_LOCAL_FILE_MISSING".to_string())?;
        let mut local_reader = BufReader::with_capacity(self.tuning.chunk_size_bytes, local_file);
        let command = build_resume_upload_command(remote_path, resume_offset)?;
        record_transfer_progress_with_status(
            job,
            resume_offset,
            local_identity.source_size,
            "resuming",
        );
        let copied = with_transfer_session_settings(session.session(), &self.tuning, || {
            let mut channel = self.open_transfer_channel(session)?;
            channel
                .exec(&command)
                .map_err(|_| "FILES_REMOTE_COMMAND_FAILED".to_string())?;
            let copied = Self::copy_with_cancellation_from_offset_and_tuning(
                &mut local_reader,
                &mut channel,
                resume_offset,
                || is_live_scp_transfer_cancelled(&job.id),
                |bytes_done| {
                    record_transfer_progress_with_status(
                        job,
                        resume_offset.saturating_add(bytes_done),
                        local_identity.source_size,
                        "resuming",
                    )
                },
                &self.tuning,
            )?;
            channel.send_eof().map_err(map_scp_error)?;
            channel.wait_eof().map_err(map_scp_error)?;
            channel.close().map_err(map_scp_error)?;
            channel.wait_close().map_err(map_scp_error)?;
            let status = channel
                .exit_status()
                .map_err(|_| "FILES_REMOTE_COMMAND_FAILED".to_string())?;
            if status != 0 {
                return Err("FILES_REMOTE_COMMAND_FAILED".to_string());
            }
            Ok::<_, String>(copied)
        })?;
        Self::validate_transfer_count(
            resume_offset.saturating_add(copied),
            local_identity.source_size,
        )?;
        let _ = self.delete_remote_resume_metadata(session, metadata_path);
        Ok(local_identity.source_size)
    }

    fn remote_file_identity(
        &self,
        session: &Libssh2ConnectedSession,
        remote_path: &str,
    ) -> Result<Option<ScpResumeMetadata>, String> {
        let command = build_remote_file_identity_command(remote_path)?;
        let output = Libssh2ExecListing::run_raw_command(session, &command)?;
        parse_remote_file_identity_output(&output)
    }

    fn read_remote_resume_metadata(
        &self,
        session: &Libssh2ConnectedSession,
        metadata_path: &str,
    ) -> Result<Option<ScpResumeMetadata>, String> {
        let command = format!(
            "if [ -f {} ]; then cat {}; fi",
            shell_path_argument(metadata_path),
            shell_path_argument(metadata_path)
        );
        let output = Libssh2ExecListing::run_raw_command(session, &command)?;
        parse_resume_metadata(output.trim())
    }

    fn write_remote_resume_metadata(
        &self,
        session: &Libssh2ConnectedSession,
        metadata_path: &str,
        metadata: &ScpResumeMetadata,
    ) -> Result<(), String> {
        let payload = serde_json::to_string(metadata).map_err(|_| "FILES_TRANSFER_INTERRUPTED")?;
        let command = format!(
            "printf '%s\\n' {} > {}",
            shell_quote(&payload),
            shell_path_argument(metadata_path)
        );
        Libssh2ExecListing::run_raw_command(session, &command).map(|_| ())
    }

    fn delete_remote_resume_metadata(
        &self,
        session: &Libssh2ConnectedSession,
        metadata_path: &str,
    ) -> Result<(), String> {
        let command = format!("rm -f {}", shell_path_argument(metadata_path));
        Libssh2ExecListing::run_raw_command(session, &command).map(|_| ())
    }

    fn create_remote_directory(
        &self,
        session: &Libssh2ConnectedSession,
        remote_path: &str,
    ) -> Result<(), String> {
        validate_remote_path(remote_path)?;
        Libssh2ExecListing::new().apply_operation(
            session,
            &RemoteFileOperation::MakeDirectory {
                path: remote_path.to_string(),
            },
        )
    }

    fn remote_path_is_directory(
        &self,
        session: &Libssh2ConnectedSession,
        remote_path: &str,
    ) -> Result<bool, String> {
        let command = build_directory_probe_command(remote_path)?;
        with_temporary_blocking(session.session(), true, || {
            let mut channel = session
                .session()
                .channel_session()
                .map_err(|_| "FILES_REMOTE_COMMAND_FAILED".to_string())?;
            channel
                .exec(&command)
                .map_err(|_| "FILES_REMOTE_COMMAND_FAILED".to_string())?;
            let mut output = String::new();
            channel
                .read_to_string(&mut output)
                .map_err(|_| "FILES_REMOTE_COMMAND_FAILED".to_string())?;
            channel
                .wait_close()
                .map_err(|_| "FILES_REMOTE_COMMAND_FAILED".to_string())?;
            match channel
                .exit_status()
                .map_err(|_| "FILES_REMOTE_COMMAND_FAILED".to_string())?
            {
                0 => Ok(true),
                1 => Ok(false),
                _ => Err("FILES_REMOTE_COMMAND_FAILED".to_string()),
            }
        })
    }

    fn open_transfer_channel(
        &self,
        session: &Libssh2ConnectedSession,
    ) -> Result<ssh2::Channel, String> {
        session
            .session()
            .channel_open(
                "session",
                self.tuning.channel_window_size_bytes,
                self.tuning.channel_packet_size_bytes,
                None,
            )
            .map_err(|_| "FILES_REMOTE_COMMAND_FAILED".to_string())
    }

    fn tune_receive_window(
        channel: &mut ssh2::Channel,
        tuning: &ScpTransferTuning,
    ) -> Result<(), String> {
        let window = channel.read_window();
        if window.remaining < tuning.channel_window_size_bytes {
            let adjust = tuning
                .channel_window_size_bytes
                .saturating_sub(window.remaining) as u64;
            if adjust > 0 {
                channel
                    .adjust_receive_window(adjust, true)
                    .map_err(map_scp_error)?;
            }
        }
        Ok(())
    }

    fn local_path_for_remote_child(
        local_root: &str,
        remote_root: &str,
        remote_child: &str,
    ) -> Result<PathBuf, String> {
        let normalized_root = remote_root.trim_end_matches('/');
        let normalized_child = remote_child.trim_end_matches('/');
        let relative = if normalized_child == normalized_root {
            ""
        } else if let Some(rest) = normalized_child.strip_prefix(&format!("{normalized_root}/")) {
            rest
        } else {
            return Err("FILES_UNSAFE_PATH".to_string());
        };

        let mut local_path = PathBuf::from(local_root);
        for component in relative
            .split('/')
            .filter(|component| !component.is_empty())
        {
            if component == "." || component == ".." {
                return Err("FILES_UNSAFE_PATH".to_string());
            }
            local_path.push(component);
        }
        Ok(local_path)
    }

    fn remote_child_path(remote_directory: &str, child_name: &str) -> Result<String, String> {
        if child_name.is_empty()
            || child_name == "."
            || child_name == ".."
            || child_name.contains('/')
        {
            return Err("FILES_UNSAFE_PATH".to_string());
        }

        let normalized_directory = remote_directory.trim_end_matches('/');
        let path = if normalized_directory.is_empty() {
            format!("/{child_name}")
        } else {
            format!("{normalized_directory}/{child_name}")
        };
        validate_remote_path(&path)?;
        Ok(path)
    }

    fn directory_upload_size(local_root: &Path) -> Result<u64, String> {
        let entries =
            std::fs::read_dir(local_root).map_err(|_| "FILES_LOCAL_FILE_MISSING".to_string())?;
        let mut total = 0_u64;
        for entry in entries {
            let entry = entry.map_err(|_| "FILES_LOCAL_FILE_MISSING".to_string())?;
            let metadata = entry
                .metadata()
                .map_err(|_| "FILES_LOCAL_FILE_MISSING".to_string())?;
            if metadata.is_dir() {
                total = total.saturating_add(Self::directory_upload_size(&entry.path())?);
            } else if metadata.is_file() {
                total = total.saturating_add(metadata.len());
            }
        }
        Ok(total)
    }

    pub fn validate_transfer_count(actual: u64, expected: u64) -> Result<(), String> {
        if actual == expected {
            Ok(())
        } else {
            Err("FILES_TRANSFER_INTERRUPTED".to_string())
        }
    }

    pub fn copy_with_cancellation<R, W, F, P>(
        reader: &mut R,
        writer: &mut W,
        should_cancel: F,
        did_copy: P,
    ) -> Result<u64, String>
    where
        R: Read,
        W: Write,
        F: FnMut() -> bool,
        P: FnMut(u64),
    {
        Self::copy_with_cancellation_and_tuning(
            reader,
            writer,
            should_cancel,
            did_copy,
            &ScpTransferTuning::default(),
        )
    }

    fn copy_with_cancellation_and_tuning<R, W, F, P>(
        reader: &mut R,
        writer: &mut W,
        mut should_cancel: F,
        mut did_copy: P,
        tuning: &ScpTransferTuning,
    ) -> Result<u64, String>
    where
        R: Read,
        W: Write,
        F: FnMut() -> bool,
        P: FnMut(u64),
    {
        let mut buffer = vec![0_u8; tuning.chunk_size_bytes];
        let mut bytes_copied = 0_u64;
        loop {
            if should_cancel() {
                return Err("FILES_TRANSFER_CANCELED".to_string());
            }

            let bytes_read = read_chunk_with_retry(reader, &mut buffer, tuning)?;
            if bytes_read == 0 {
                return Ok(bytes_copied);
            }

            write_all_with_retry(writer, &buffer[..bytes_read], tuning)?;
            bytes_copied += bytes_read as u64;
            did_copy(bytes_copied);
        }
    }

    pub fn copy_with_cancellation_from_offset<R, W, F, P>(
        reader: &mut R,
        writer: &mut W,
        offset: u64,
        should_cancel: F,
        did_copy: P,
    ) -> Result<u64, String>
    where
        R: Read + Seek,
        W: Write,
        F: FnMut() -> bool,
        P: FnMut(u64),
    {
        Self::copy_with_cancellation_from_offset_and_tuning(
            reader,
            writer,
            offset,
            should_cancel,
            did_copy,
            &ScpTransferTuning::default(),
        )
    }

    fn copy_with_cancellation_from_offset_and_tuning<R, W, F, P>(
        reader: &mut R,
        writer: &mut W,
        offset: u64,
        should_cancel: F,
        did_copy: P,
        tuning: &ScpTransferTuning,
    ) -> Result<u64, String>
    where
        R: Read + Seek,
        W: Write,
        F: FnMut() -> bool,
        P: FnMut(u64),
    {
        reader
            .seek(SeekFrom::Start(offset))
            .map_err(|_| "FILES_TRANSFER_INTERRUPTED".to_string())?;
        Self::copy_with_cancellation_and_tuning(reader, writer, should_cancel, did_copy, tuning)
    }
}

fn with_transfer_session_settings<T, F>(
    session: &ssh2::Session,
    tuning: &ScpTransferTuning,
    operation: F,
) -> Result<T, String>
where
    F: FnOnce() -> Result<T, String>,
{
    let _timeout = TemporarySessionTimeout::new(session, tuning.operation_timeout_ms);
    with_temporary_blocking(session, true, operation)
}

struct TemporarySessionTimeout<'session> {
    session: &'session ssh2::Session,
    previous_timeout_ms: u32,
}

impl<'session> TemporarySessionTimeout<'session> {
    fn new(session: &'session ssh2::Session, timeout_ms: u32) -> Self {
        let previous_timeout_ms = session.timeout();
        if previous_timeout_ms != timeout_ms {
            session.set_timeout(timeout_ms);
        }
        Self {
            session,
            previous_timeout_ms,
        }
    }
}

impl Drop for TemporarySessionTimeout<'_> {
    fn drop(&mut self) {
        if self.session.timeout() != self.previous_timeout_ms {
            self.session.set_timeout(self.previous_timeout_ms);
        }
    }
}

fn read_chunk_with_retry<R: Read>(
    reader: &mut R,
    buffer: &mut [u8],
    tuning: &ScpTransferTuning,
) -> Result<usize, String> {
    retry_io_operation(|| reader.read(buffer), tuning)
}

fn write_all_with_retry<W: Write>(
    writer: &mut W,
    bytes: &[u8],
    tuning: &ScpTransferTuning,
) -> Result<(), String> {
    let mut offset = 0;
    while offset < bytes.len() {
        let written = retry_io_operation(
            || match writer.write(&bytes[offset..]) {
                Ok(0) => Err(io::Error::new(
                    io::ErrorKind::WriteZero,
                    "zero bytes written",
                )),
                result => result,
            },
            tuning,
        )?;
        offset += written;
    }
    Ok(())
}

fn retry_io_operation<T, F>(mut operation: F, tuning: &ScpTransferTuning) -> Result<T, String>
where
    F: FnMut() -> io::Result<T>,
{
    let mut retry_count = 0_u8;
    loop {
        match operation() {
            Ok(value) => return Ok(value),
            Err(error) if is_recoverable_transfer_io_error(&error) => {
                if retry_count >= tuning.max_retry_attempts {
                    return Err(retry_exhausted_code(&error).to_string());
                }
                retry_count = retry_count.saturating_add(1);
                thread::sleep(retry_backoff(retry_count));
            }
            Err(error) => return Err(map_io_transfer_error(&error).to_string()),
        }
    }
}

fn retry_backoff(retry_count: u8) -> Duration {
    Duration::from_millis(25 * u64::from(retry_count.max(1)))
}

fn is_recoverable_transfer_io_error(error: &io::Error) -> bool {
    matches!(
        error.kind(),
        io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted | io::ErrorKind::TimedOut
    ) || is_would_block_message(&error.to_string())
}

fn retry_exhausted_code(error: &io::Error) -> &'static str {
    if error.kind() == io::ErrorKind::TimedOut {
        "FILES_TRANSFER_TIMEOUT"
    } else {
        "FILES_TRANSFER_RETRY_EXHAUSTED"
    }
}

fn map_io_transfer_error(error: &io::Error) -> &'static str {
    if is_disk_full_error(error) {
        return "FILES_DISK_FULL";
    }
    match error.kind() {
        io::ErrorKind::PermissionDenied => "FILES_PERMISSION_DENIED",
        io::ErrorKind::NotFound => "FILES_LOCAL_FILE_MISSING",
        io::ErrorKind::TimedOut => "FILES_TRANSFER_TIMEOUT",
        _ => "FILES_TRANSFER_INTERRUPTED",
    }
}

fn is_disk_full_error(error: &io::Error) -> bool {
    error.raw_os_error() == Some(28)
        || error
            .to_string()
            .to_ascii_lowercase()
            .contains("no space left")
}

fn is_would_block_message(message: &str) -> bool {
    let lowered = message.to_ascii_lowercase();
    lowered.contains("would block")
        || lowered.contains("operation would block")
        || lowered.contains("session(-37)")
}

pub fn transfer_error_diagnostic(code: &str) -> &'static str {
    match code {
        "FILES_TRANSFER_TIMEOUT" => "网络超时：单次文件读写超过 30 秒，请检查网络稳定性后重试",
        "FILES_TRANSFER_RETRY_EXHAUSTED" => "网络抖动：SSH 通道连续暂不可用，已自动重试 3 次",
        "FILES_PERMISSION_DENIED" => "权限拒绝：请检查远端目录权限或本地文件读写权限",
        "FILES_DISK_FULL" => "磁盘空间不足：请清理目标磁盘后重试",
        "FILES_REMOTE_FILE_MISSING" => "远端文件不存在：请检查远端路径是否已变更",
        "FILES_LOCAL_FILE_MISSING" => "本地文件不存在：请检查本地路径是否仍然可用",
        "FILES_LOCAL_WRITE_FAILED" => "本地文件写入失败：请检查本机目录权限或磁盘空间",
        _ => "文件传输失败：请检查网络、权限和目标路径后重试",
    }
}

fn record_transfer_progress(job: &ScpTransferJob, bytes_done: u64, bytes_total: u64) {
    record_transfer_progress_with_status(job, bytes_done, bytes_total, "running");
}

fn record_transfer_progress_with_status(
    job: &ScpTransferJob,
    bytes_done: u64,
    bytes_total: u64,
    status: &str,
) {
    record_live_scp_transfer_progress(crate::domain::scp::ScpTransferProgress {
        job_id: job.id.clone(),
        bytes_done,
        bytes_total,
        status: status.to_string(),
    });
}

fn local_file_identity(local_path: &Path) -> Result<ScpResumeMetadata, String> {
    let metadata = std::fs::metadata(local_path).map_err(|_| "FILES_LOCAL_FILE_MISSING")?;
    if !metadata.is_file() {
        return Err("FILES_LOCAL_FILE_MISSING".to_string());
    }
    let modified = metadata
        .modified()
        .map_err(|_| "FILES_LOCAL_FILE_MISSING".to_string())?
        .duration_since(UNIX_EPOCH)
        .map_err(|_| "FILES_LOCAL_FILE_MISSING".to_string())?
        .as_secs() as i64;
    Ok(ScpResumeMetadata {
        source_size: metadata.len(),
        source_mtime_unix: modified,
    })
}

fn local_resume_metadata_path(local_path: &Path) -> PathBuf {
    let mut metadata_path = local_path.as_os_str().to_os_string();
    metadata_path.push(".stacioresume");
    PathBuf::from(metadata_path)
}

fn remote_resume_metadata_path(remote_path: &str) -> Result<String, String> {
    validate_remote_path(remote_path)?;
    Ok(format!("{remote_path}.stacioresume"))
}

fn local_resume_offset(
    local_path: &Path,
    metadata_path: &Path,
    remote_identity: Option<&ScpResumeMetadata>,
    resume_options: &ScpResumeOptions,
) -> Result<u64, String> {
    if resume_options.force_restart {
        let _ = std::fs::remove_file(metadata_path);
        return Ok(0);
    }

    let Some(remote_identity) = remote_identity else {
        return Ok(0);
    };
    let Some(saved_identity) = read_local_resume_metadata(metadata_path)? else {
        return Ok(0);
    };
    if saved_identity != *remote_identity {
        let _ = std::fs::remove_file(metadata_path);
        return Ok(0);
    }

    let partial_size = match std::fs::metadata(local_path) {
        Ok(metadata) if metadata.is_file() => metadata.len(),
        Ok(_) => return Err("FILES_LOCAL_WRITE_FAILED".to_string()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => 0,
        Err(_) => return Err("FILES_LOCAL_WRITE_FAILED".to_string()),
    };
    let requested = if resume_options.requested_offset > 0 {
        resume_options.requested_offset.min(partial_size)
    } else {
        partial_size
    };
    if requested > 0 && requested < remote_identity.source_size {
        Ok(requested)
    } else {
        Ok(0)
    }
}

fn remote_resume_offset(
    remote_identity: Option<&ScpResumeMetadata>,
    saved_identity: Option<&ScpResumeMetadata>,
    local_identity: &ScpResumeMetadata,
    resume_options: &ScpResumeOptions,
) -> u64 {
    if resume_options.force_restart {
        return 0;
    }
    let Some(remote_identity) = remote_identity else {
        return 0;
    };
    let Some(saved_identity) = saved_identity else {
        return 0;
    };
    if saved_identity != local_identity {
        return 0;
    }
    if remote_identity.source_size > 0 && remote_identity.source_size < local_identity.source_size {
        return remote_identity.source_size;
    }
    0
}

fn read_local_resume_metadata(path: &Path) -> Result<Option<ScpResumeMetadata>, String> {
    match std::fs::read_to_string(path) {
        Ok(contents) => parse_resume_metadata(contents.trim()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(_) => Err("FILES_LOCAL_WRITE_FAILED".to_string()),
    }
}

fn write_local_resume_metadata(path: &Path, metadata: &ScpResumeMetadata) -> Result<(), String> {
    let payload = serde_json::to_string(metadata).map_err(|_| "FILES_TRANSFER_INTERRUPTED")?;
    std::fs::write(path, payload).map_err(|_| "FILES_LOCAL_WRITE_FAILED".to_string())
}

fn parse_resume_metadata(input: &str) -> Result<Option<ScpResumeMetadata>, String> {
    if input.trim().is_empty() {
        return Ok(None);
    }
    serde_json::from_str(input)
        .map(Some)
        .map_err(|_| "FILES_TRANSFER_INTERRUPTED".to_string())
}

fn build_remote_file_identity_command(remote_path: &str) -> Result<String, String> {
    validate_remote_path(remote_path)?;
    let path = shell_path_argument(remote_path);
    Ok(format!(
        "if [ -f {path} ]; then (stat -c '%s\\t%Y' {path} 2>/dev/null || stat -f '%z\\t%m' {path} 2>/dev/null); else printf 'missing\\n'; fi"
    ))
}

fn parse_remote_file_identity_output(output: &str) -> Result<Option<ScpResumeMetadata>, String> {
    let line = output.lines().next().unwrap_or("").trim();
    if line.is_empty() || line == "missing" {
        return Ok(None);
    }
    let mut fields = line.split('\t');
    let size = fields
        .next()
        .and_then(|value| value.parse::<u64>().ok())
        .ok_or_else(|| "FILES_REMOTE_COMMAND_FAILED".to_string())?;
    let mtime = fields
        .next()
        .and_then(|value| value.parse::<i64>().ok())
        .ok_or_else(|| "FILES_REMOTE_COMMAND_FAILED".to_string())?;
    Ok(Some(ScpResumeMetadata {
        source_size: size,
        source_mtime_unix: mtime,
    }))
}

fn build_resume_download_command(remote_path: &str, offset: u64) -> Result<String, String> {
    validate_remote_path(remote_path)?;
    Ok(format!(
        "dd if={} bs=1 skip={} 2>/dev/null",
        shell_path_argument(remote_path),
        offset
    ))
}

fn build_resume_upload_command(remote_path: &str, offset: u64) -> Result<String, String> {
    validate_remote_path(remote_path)?;
    Ok(format!(
        "dd of={} bs=1 seek={} conv=notrunc 2>/dev/null",
        shell_path_argument(remote_path),
        offset
    ))
}

fn map_scp_error(error: ssh2::Error) -> String {
    let raw_message = error.to_string();
    let lowered = raw_message.to_ascii_lowercase();
    if lowered.contains("no such file") || lowered.contains("not found") {
        return "FILES_REMOTE_FILE_MISSING".to_string();
    }
    if lowered.contains("no space left") || lowered.contains("disk full") {
        return "FILES_DISK_FULL".to_string();
    }
    if is_would_block_message(&lowered) {
        return "FILES_TRANSFER_RETRY_EXHAUSTED".to_string();
    }

    let mapped = Libssh2Transport::map_error(&raw_message);
    match mapped {
        crate::domain::ssh::SshRuntimeError::AuthFailed => "FILES_PERMISSION_DENIED".to_string(),
        crate::domain::ssh::SshRuntimeError::Timeout => "FILES_TRANSFER_TIMEOUT".to_string(),
        crate::domain::ssh::SshRuntimeError::Transport { message }
            if message.to_ascii_lowercase().contains("permission") =>
        {
            "FILES_PERMISSION_DENIED".to_string()
        }
        _ => "FILES_TRANSFER_INTERRUPTED".to_string(),
    }
}

fn validate_remote_path(path: &str) -> Result<(), String> {
    let trimmed = path.trim();
    if trimmed.is_empty()
        || trimmed.chars().any(char::is_control)
        || trimmed.contains("../")
        || trimmed.starts_with("../")
        || trimmed == ".."
        || trimmed.ends_with("/..")
        || trimmed
            .split('/')
            .any(|component| component.starts_with('-'))
    {
        return Err("FILES_UNSAFE_PATH".to_string());
    }

    Ok(())
}

fn resolve_remote_file_path_for_scp(
    session: &Libssh2ConnectedSession,
    remote_path: &str,
) -> Result<String, String> {
    if !uses_home_alias(remote_path) {
        return Ok(remote_path.to_string());
    }
    let (parent, name) = remote_parent_and_name(remote_path)?;
    let parent = resolve_existing_remote_directory_path(session, &parent)?;
    Ok(join_remote_path(&parent, &name))
}

fn resolve_existing_remote_directory_path(
    session: &Libssh2ConnectedSession,
    remote_path: &str,
) -> Result<String, String> {
    if !uses_home_alias(remote_path) {
        return Ok(remote_path.to_string());
    }
    let command = build_resolve_directory_command(remote_path)?;
    let output = Libssh2ExecListing::run_raw_command(session, &command)?;
    let resolved = output.lines().next().unwrap_or("").trim();
    validate_remote_path(resolved)?;
    Ok(resolved.to_string())
}

fn build_directory_probe_command(remote_path: &str) -> Result<String, String> {
    validate_remote_path(remote_path)?;
    Ok(format!("test -d {}", shell_path_argument(remote_path)))
}

fn build_resolve_directory_command(remote_path: &str) -> Result<String, String> {
    validate_remote_path(remote_path)?;
    Ok(format!("cd {} && pwd -P", shell_path_argument(remote_path)))
}

fn remote_parent_and_name(remote_path: &str) -> Result<(String, String), String> {
    validate_remote_path(remote_path)?;
    let trimmed = remote_path.trim_end_matches('/');
    if trimmed == "~" {
        return Err("FILES_UNSAFE_PATH".to_string());
    }
    let Some((parent, name)) = trimmed.rsplit_once('/') else {
        return Ok((".".to_string(), trimmed.to_string()));
    };
    if name.is_empty() {
        return Err("FILES_UNSAFE_PATH".to_string());
    }
    let parent = if parent.is_empty() { "/" } else { parent };
    Ok((parent.to_string(), name.to_string()))
}

fn uses_home_alias(remote_path: &str) -> bool {
    remote_path == "~" || remote_path.starts_with("~/")
}

fn join_remote_path(base_path: &str, name: &str) -> String {
    let base = base_path.trim_end_matches('/');
    if base.is_empty() {
        return format!("/{name}");
    }
    format!("{base}/{name}")
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

#[cfg(test)]
mod libssh2_scp_tests {
    use crate::domain::scp::{ScpDirection, ScpResumeOptions, ScpTransferJob};
    use crate::domain::ssh::{SshAuthMethod, SshConnectionConfig};
    use crate::infrastructure::files::libssh2_exec_listing::{
        Libssh2ExecListing, RemoteFileOperation,
    };
    use crate::infrastructure::ssh::libssh2_transport::{Libssh2Transport, SshSecret};
    use std::io;
    use std::path::Path;

    use super::{Libssh2ScpDownloadReport, Libssh2ScpEngine, Libssh2ScpUploadReport};

    #[test]
    fn validates_upload_request_without_system_command() {
        let engine = Libssh2ScpEngine::new();
        let job = ScpTransferJob::new(
            ScpDirection::Upload,
            "/Users/me/file.txt".to_string(),
            "/tmp/file.txt".to_string(),
            128,
        );

        let request = engine.prepare_request(&job).expect("request");

        assert_eq!(request.remote_path, "/tmp/file.txt");
        assert!(!format!("{request:?}").contains("scp "));
        assert!(!format!("{request:?}").contains("sftp "));
    }

    #[test]
    fn rejects_unsafe_remote_path() {
        let engine = Libssh2ScpEngine::new();
        let job = ScpTransferJob::new(
            ScpDirection::Download,
            "../etc/passwd".to_string(),
            "/tmp/passwd".to_string(),
            128,
        );

        let error = engine.prepare_request(&job).expect_err("unsafe path");

        assert_eq!(error, "FILES_UNSAFE_PATH");
    }

    #[test]
    fn rejects_parent_directory_segments_at_remote_path_end() {
        let engine = Libssh2ScpEngine::new();
        let job = ScpTransferJob::new(
            ScpDirection::Download,
            "/srv/app/..".to_string(),
            "/tmp/app".to_string(),
            128,
        );

        let error = engine.prepare_request(&job).expect_err("unsafe path");

        assert_eq!(error, "FILES_UNSAFE_PATH");
    }

    #[test]
    fn rejects_option_like_remote_path_components() {
        let engine = Libssh2ScpEngine::new();
        for remote_path in [
            "-relative",
            "/tmp/-flag",
            "~/--flag",
            "/srv/app/-hidden/file.txt",
        ] {
            let job = ScpTransferJob::new(
                ScpDirection::Download,
                remote_path.to_string(),
                "/tmp/file.txt".to_string(),
                128,
            );

            let error = engine.prepare_request(&job).expect_err("unsafe path");

            assert_eq!(error, "FILES_UNSAFE_PATH", "path: {remote_path}");
        }
    }

    #[test]
    fn rejects_control_characters_in_remote_transfer_paths() {
        let engine = Libssh2ScpEngine::new();
        for remote_path in ["/tmp/bad\u{1b}[31m.log", "/tmp/bad\0name.log"] {
            let job = ScpTransferJob::new(
                ScpDirection::Download,
                remote_path.to_string(),
                "/tmp/file.txt".to_string(),
                128,
            );

            let error = engine.prepare_request(&job).expect_err("unsafe path");

            assert_eq!(error, "FILES_UNSAFE_PATH", "path: {remote_path:?}");
        }
    }

    #[test]
    fn scp_shell_commands_allow_home_alias_expansion() {
        let probe = super::build_directory_probe_command("~/release dir").expect("probe command");
        let resolve =
            super::build_resolve_directory_command("~/release dir").expect("resolve command");

        assert_eq!(probe, "test -d ~/'release dir'");
        assert_eq!(resolve, "cd ~/'release dir' && pwd -P");
        assert!(!probe.contains("'~/release dir'"));
        assert!(!resolve.contains("'~/release dir'"));
    }

    #[test]
    fn scp_home_alias_file_paths_split_parent_before_resolution() {
        let home_file = super::remote_parent_and_name("~/release/app.log").expect("home path");
        let root_file = super::remote_parent_and_name("/var/log/app.log").expect("absolute path");
        let plain_file = super::remote_parent_and_name("app.log").expect("plain path");

        assert_eq!(home_file, ("~/release".to_string(), "app.log".to_string()));
        assert_eq!(root_file, ("/var/log".to_string(), "app.log".to_string()));
        assert_eq!(plain_file, (".".to_string(), "app.log".to_string()));
    }

    #[test]
    fn scp_home_alias_without_file_name_is_not_treated_as_relative_file() {
        let error = super::remote_parent_and_name("~").expect_err("home directory is not a file");

        assert_eq!(error, "FILES_UNSAFE_PATH");
    }

    #[test]
    fn rejects_upload_when_local_file_is_missing() {
        let engine = Libssh2ScpEngine::new();
        let job = ScpTransferJob::new(
            ScpDirection::Upload,
            "/tmp/stacio-missing-file".to_string(),
            "/tmp/file.txt".to_string(),
            128,
        );

        let error = engine
            .validate_upload_file(&job)
            .expect_err("missing local file");

        assert_eq!(error, "FILES_LOCAL_FILE_MISSING");
    }

    #[test]
    fn rejects_upload_when_declared_size_does_not_match() {
        let temp = tempfile::NamedTempFile::new().expect("temp file");
        std::fs::write(temp.path(), b"hello").expect("write temp");
        let engine = Libssh2ScpEngine::new();
        let job = ScpTransferJob::new(
            ScpDirection::Upload,
            temp.path().to_string_lossy().to_string(),
            "/tmp/file.txt".to_string(),
            128,
        );

        let error = engine
            .validate_upload_file(&job)
            .expect_err("size mismatch");

        assert_eq!(error, "FILES_SIZE_MISMATCH");
    }

    #[test]
    fn accepts_upload_directory_and_sums_regular_file_bytes() {
        let temp = tempfile::tempdir().expect("temp dir");
        let child_dir = temp.path().join("nested");
        std::fs::create_dir(&child_dir).expect("create child");
        std::fs::write(temp.path().join("first.txt"), b"abc").expect("write first");
        std::fs::write(child_dir.join("second.txt"), b"de").expect("write second");
        let engine = Libssh2ScpEngine::new();
        let job = ScpTransferJob::new(
            ScpDirection::Upload,
            temp.path().to_string_lossy().to_string(),
            "/tmp/uploaded".to_string(),
            5,
        );

        let bytes = engine
            .validate_upload_source(&job)
            .expect("directory source");

        assert_eq!(bytes, 5);
    }

    #[test]
    fn accepts_upload_directory_with_unknown_declared_size() {
        let temp = tempfile::tempdir().expect("temp dir");
        std::fs::write(temp.path().join("payload.bin"), b"abc").expect("write payload");
        let engine = Libssh2ScpEngine::new();
        let job = ScpTransferJob::new(
            ScpDirection::Upload,
            temp.path().to_string_lossy().to_string(),
            "/tmp/uploaded".to_string(),
            0,
        );

        let bytes = engine
            .validate_upload_source(&job)
            .expect("directory source");

        assert_eq!(bytes, 3);
    }

    #[test]
    fn builds_secret_free_transfer_reports() {
        let upload = Libssh2ScpUploadReport::new("/tmp/remote.txt".to_string(), 5);
        let download = Libssh2ScpDownloadReport::new("/tmp/local.txt".to_string(), 5);

        assert_eq!(upload.bytes_written, 5);
        assert_eq!(download.bytes_read, 5);
        assert!(!format!("{upload:?}").contains("scp "));
        assert!(!format!("{download:?}").contains("sftp "));
    }

    #[test]
    fn rejects_incomplete_transfer_counts() {
        assert_eq!(
            Libssh2ScpEngine::validate_transfer_count(4, 5),
            Err("FILES_TRANSFER_INTERRUPTED".to_string())
        );
        assert_eq!(Libssh2ScpEngine::validate_transfer_count(5, 5), Ok(()));
    }

    #[test]
    fn copy_with_cancellation_stops_between_chunks() {
        let payload = vec![42_u8; 384 * 1024];
        let mut reader = std::io::Cursor::new(payload);
        let mut writer = Vec::new();
        let mut checks = 0;

        let error = Libssh2ScpEngine::copy_with_cancellation(
            &mut reader,
            &mut writer,
            || {
                checks += 1;
                checks > 2
            },
            |_| {},
        )
        .expect_err("canceled copy");

        assert_eq!(error, "FILES_TRANSFER_CANCELED");
        assert_eq!(writer.len(), 256 * 1024);
    }

    #[test]
    fn copy_with_cancellation_reports_progress_after_each_chunk() {
        let payload = vec![42_u8; 130 * 1024];
        let mut reader = std::io::Cursor::new(payload);
        let mut writer = Vec::new();
        let mut progress = Vec::new();

        let copied = Libssh2ScpEngine::copy_with_cancellation(
            &mut reader,
            &mut writer,
            || false,
            |bytes_done| progress.push(bytes_done),
        )
        .expect("copy");

        assert_eq!(copied, 130 * 1024);
        assert_eq!(progress, vec![128 * 1024, 130 * 1024]);
    }

    #[test]
    fn default_transfer_tuning_uses_large_binary_scp_settings() {
        let tuning = super::ScpTransferTuning::default();

        assert_eq!(tuning.chunk_size_bytes, 128 * 1024);
        assert_eq!(tuning.channel_window_size_bytes, 2 * 1024 * 1024);
        assert_eq!(tuning.channel_packet_size_bytes, 128 * 1024);
        assert_eq!(tuning.operation_timeout_ms, 30_000);
        assert_eq!(tuning.max_retry_attempts, 3);
        assert_eq!(tuning.compression, "none");
    }

    #[test]
    fn copy_with_cancellation_retries_transient_would_block_reads() {
        let mut reader = FlakyReader::new(
            b"stable payload".to_vec(),
            vec![io::ErrorKind::WouldBlock, io::ErrorKind::Interrupted],
        );
        let mut writer = Vec::new();
        let mut progress = Vec::new();

        let copied = Libssh2ScpEngine::copy_with_cancellation(
            &mut reader,
            &mut writer,
            || false,
            |bytes_done| progress.push(bytes_done),
        )
        .expect("copy retries transient reads");

        assert_eq!(copied, 14);
        assert_eq!(writer, b"stable payload");
        assert_eq!(reader.read_attempts, 4);
        assert_eq!(progress, vec![14]);
    }

    #[test]
    fn copy_with_cancellation_stops_after_retry_budget_is_exhausted() {
        let mut reader = FlakyReader::new(
            b"never reached".to_vec(),
            vec![
                io::ErrorKind::WouldBlock,
                io::ErrorKind::WouldBlock,
                io::ErrorKind::WouldBlock,
                io::ErrorKind::WouldBlock,
            ],
        );
        let mut writer = Vec::new();

        let error =
            Libssh2ScpEngine::copy_with_cancellation(&mut reader, &mut writer, || false, |_| {})
                .expect_err("retry budget exhausted");

        assert_eq!(error, "FILES_TRANSFER_RETRY_EXHAUSTED");
        assert!(writer.is_empty());
    }

    #[test]
    fn maps_transfer_error_codes_to_readable_chinese_diagnostics() {
        assert_eq!(
            super::transfer_error_diagnostic("FILES_TRANSFER_TIMEOUT"),
            "网络超时：单次文件读写超过 30 秒，请检查网络稳定性后重试"
        );
        assert_eq!(
            super::transfer_error_diagnostic("FILES_PERMISSION_DENIED"),
            "权限拒绝：请检查远端目录权限或本地文件读写权限"
        );
        assert_eq!(
            super::transfer_error_diagnostic("FILES_DISK_FULL"),
            "磁盘空间不足：请清理目标磁盘后重试"
        );
    }

    #[test]
    fn resume_upload_copies_from_local_offset_into_mock_writer() {
        let mut reader = std::io::Cursor::new(b"already-written-remaining".to_vec());
        let mut writer = Vec::new();
        let mut progress = Vec::new();

        let copied = Libssh2ScpEngine::copy_with_cancellation_from_offset(
            &mut reader,
            &mut writer,
            16,
            || false,
            |bytes_done| progress.push(bytes_done),
        )
        .expect("resume upload copy");

        assert_eq!(copied, 9);
        assert_eq!(writer, b"remaining");
        assert_eq!(progress, vec![9]);
    }

    #[test]
    fn resume_download_command_requests_remote_bytes_from_offset_without_sftp() {
        let command = super::build_resume_download_command("/srv/releases/build.zip", 131_072)
            .expect("command");

        assert!(command.contains("dd if="));
        assert!(command.contains("skip=131072"));
        assert!(!command.contains("scp "));
        assert!(!command.contains("sftp "));
    }

    #[test]
    fn resume_upload_command_writes_at_remote_offset_without_truncating() {
        let command = super::build_resume_upload_command("/srv/releases/build.zip", 131_072)
            .expect("command");

        assert!(command.contains("dd of="));
        assert!(command.contains("seek=131072"));
        assert!(command.contains("conv=notrunc"));
        assert!(!command.contains("scp "));
        assert!(!command.contains("sftp "));
    }

    #[test]
    fn remote_resume_offset_rejects_changed_source_mtime() {
        let remote_identity = super::ScpResumeMetadata {
            source_size: 40,
            source_mtime_unix: 1_700_000_000,
        };
        let saved_identity = super::ScpResumeMetadata {
            source_size: 100,
            source_mtime_unix: 1_700_000_001,
        };
        let local_identity = super::ScpResumeMetadata {
            source_size: 100,
            source_mtime_unix: 1_700_000_000,
        };
        let options = ScpResumeOptions {
            requested_offset: 40,
            force_restart: false,
        };

        let offset = super::remote_resume_offset(
            Some(&remote_identity),
            Some(&saved_identity),
            &local_identity,
            &options,
        );

        assert_eq!(offset, 0);
    }

    #[test]
    fn remote_resume_offset_rejects_force_restart() {
        let remote_identity = super::ScpResumeMetadata {
            source_size: 40,
            source_mtime_unix: 1_700_000_000,
        };
        let local_identity = super::ScpResumeMetadata {
            source_size: 100,
            source_mtime_unix: 1_700_000_000,
        };
        let options = ScpResumeOptions {
            requested_offset: 40,
            force_restart: true,
        };

        let offset = super::remote_resume_offset(
            Some(&remote_identity),
            Some(&local_identity),
            &local_identity,
            &options,
        );

        assert_eq!(offset, 0);
    }

    #[test]
    fn local_resume_offset_rejects_changed_remote_identity_and_removes_sidecar() {
        let temp = tempfile::tempdir().expect("temp dir");
        let local_path = temp.path().join("build.zip");
        let metadata_path = super::local_resume_metadata_path(&local_path);
        std::fs::write(&local_path, vec![7_u8; 40]).expect("write partial");
        super::write_local_resume_metadata(
            &metadata_path,
            &super::ScpResumeMetadata {
                source_size: 100,
                source_mtime_unix: 1_700_000_000,
            },
        )
        .expect("write sidecar");

        let offset = super::local_resume_offset(
            &local_path,
            &metadata_path,
            Some(&super::ScpResumeMetadata {
                source_size: 100,
                source_mtime_unix: 1_700_000_001,
            }),
            &ScpResumeOptions {
                requested_offset: 40,
                force_restart: false,
            },
        )
        .expect("resume offset");

        assert_eq!(offset, 0);
        assert!(!metadata_path.exists());
    }

    struct FlakyReader {
        payload: Vec<u8>,
        failures: Vec<io::ErrorKind>,
        read_attempts: usize,
        did_read_payload: bool,
    }

    impl FlakyReader {
        fn new(payload: Vec<u8>, failures: Vec<io::ErrorKind>) -> Self {
            Self {
                payload,
                failures,
                read_attempts: 0,
                did_read_payload: false,
            }
        }
    }

    impl io::Read for FlakyReader {
        fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
            self.read_attempts += 1;
            if !self.failures.is_empty() {
                let kind = self.failures.remove(0);
                return Err(io::Error::new(kind, "temporary fixture failure"));
            }
            if self.did_read_payload {
                return Ok(0);
            }
            let count = self.payload.len().min(buffer.len());
            buffer[..count].copy_from_slice(&self.payload[..count]);
            self.did_read_payload = true;
            Ok(count)
        }
    }

    #[test]
    fn builds_local_child_paths_for_recursive_directory_download() {
        let local = Libssh2ScpEngine::local_path_for_remote_child(
            "/Users/alice/Downloads/logs",
            "/srv/app/logs",
            "/srv/app/logs/nginx/access.log",
        )
        .expect("child path");

        assert_eq!(
            local,
            Path::new("/Users/alice/Downloads/logs/nginx/access.log")
        );
    }

    #[test]
    fn rejects_recursive_directory_child_outside_requested_remote_root() {
        let error = Libssh2ScpEngine::local_path_for_remote_child(
            "/Users/alice/Downloads/logs",
            "/srv/app/logs",
            "/srv/app/logs-old/access.log",
        )
        .expect_err("outside root");

        assert_eq!(error, "FILES_UNSAFE_PATH");
    }

    #[test]
    fn uploads_and_downloads_with_gated_ssh_fixture_when_configured() {
        let Some((config, secret, remote_dir)) = scp_fixture_config() else {
            return;
        };
        let ssh = Libssh2Transport::new()
            .connect_with_secret(&config, secret)
            .expect("fixture ssh connection");
        let engine = Libssh2ScpEngine::new();
        let upload_source = tempfile::NamedTempFile::new().expect("upload source");
        std::fs::write(upload_source.path(), b"stacio scp fixture").expect("write upload source");
        let remote_path = format!(
            "{}/stacio-scp-fixture-{}.txt",
            remote_dir.trim_end_matches('/'),
            std::process::id()
        );
        let upload_job = ScpTransferJob::new(
            ScpDirection::Upload,
            upload_source.path().to_string_lossy().to_string(),
            remote_path.clone(),
            20,
        );

        let upload = engine.upload_file(&ssh, &upload_job).expect("upload");

        assert_eq!(upload.bytes_written, 20);

        let download_target = tempfile::NamedTempFile::new().expect("download target");
        let download_job = ScpTransferJob::new(
            ScpDirection::Download,
            remote_path,
            download_target.path().to_string_lossy().to_string(),
            20,
        );

        let download = engine.download_file(&ssh, &download_job).expect("download");

        assert_eq!(download.bytes_read, 20);
        assert_eq!(
            std::fs::read(download_target.path()).expect("download bytes"),
            b"stacio scp fixture"
        );
    }

    #[test]
    fn reads_and_writes_remote_file_bytes_with_gated_ssh_fixture_when_configured() {
        let Some((config, secret, remote_dir)) = scp_fixture_config() else {
            return;
        };
        let ssh = Libssh2Transport::new()
            .connect_with_secret(&config, secret)
            .expect("fixture ssh connection");
        let engine = Libssh2ScpEngine::new();
        let listing = Libssh2ExecListing::new();
        let remote_path = format!(
            "{}/stacio-live-read-write-fixture-{}.txt",
            remote_dir.trim_end_matches('/'),
            std::process::id()
        );
        let contents = b"stacio live file bytes\nrange check\n";

        let upload = engine
            .upload_bytes(&ssh, &remote_path, contents)
            .expect("write remote bytes");
        assert_eq!(upload.bytes_written, contents.len() as u64);

        let full = engine
            .read_file_bytes(&ssh, &remote_path, 0, None)
            .expect("read full remote bytes");
        assert_eq!(full, contents);

        let range = engine
            .read_file_bytes(&ssh, &remote_path, 9, Some(9))
            .expect("read remote byte range");
        assert_eq!(range, b"live file");

        let beyond_end = engine
            .read_file_bytes(&ssh, &remote_path, contents.len() as u64 + 1, Some(16))
            .expect("read beyond EOF");
        assert!(beyond_end.is_empty());

        listing
            .apply_operation(
                &ssh,
                &RemoteFileOperation::Delete {
                    path: remote_path,
                    recursive: false,
                },
            )
            .expect("cleanup remote fixture");
    }

    #[test]
    fn downloads_directory_recursively_with_gated_ssh_fixture_when_configured() {
        let Some((config, secret, remote_dir)) = scp_fixture_config() else {
            return;
        };
        let ssh = Libssh2Transport::new()
            .connect_with_secret(&config, secret)
            .expect("fixture ssh connection");
        let listing = Libssh2ExecListing::new();
        let engine = Libssh2ScpEngine::new();
        let remote_root = format!(
            "{}/stacio-scp-recursive-fixture-{}",
            remote_dir.trim_end_matches('/'),
            std::process::id()
        );
        listing
            .apply_operation(
                &ssh,
                &RemoteFileOperation::MakeDirectory {
                    path: format!("{remote_root}/nested"),
                },
            )
            .expect("create fixture directories");
        let cleanup = || {
            let _ = listing.apply_operation(
                &ssh,
                &RemoteFileOperation::Delete {
                    path: remote_root.clone(),
                    recursive: true,
                },
            );
        };

        let first_source = tempfile::NamedTempFile::new().expect("first source");
        std::fs::write(first_source.path(), b"first").expect("write first");
        let second_source = tempfile::NamedTempFile::new().expect("second source");
        std::fs::write(second_source.path(), b"second").expect("write second");
        engine
            .upload_file(
                &ssh,
                &ScpTransferJob::new(
                    ScpDirection::Upload,
                    first_source.path().to_string_lossy().to_string(),
                    format!("{remote_root}/one.txt"),
                    5,
                ),
            )
            .expect("upload first");
        engine
            .upload_file(
                &ssh,
                &ScpTransferJob::new(
                    ScpDirection::Upload,
                    second_source.path().to_string_lossy().to_string(),
                    format!("{remote_root}/nested/two.txt"),
                    6,
                ),
            )
            .expect("upload second");

        let local_parent = tempfile::tempdir().expect("download root");
        let local_target = local_parent.path().join("recursive");
        let download = engine
            .download_file(
                &ssh,
                &ScpTransferJob::new(
                    ScpDirection::Download,
                    remote_root.clone(),
                    local_target.to_string_lossy().to_string(),
                    0,
                ),
            )
            .expect("download directory");
        cleanup();

        assert_eq!(download.bytes_read, 11);
        assert_eq!(
            std::fs::read(local_target.join("one.txt")).expect("first download"),
            b"first"
        );
        assert_eq!(
            std::fs::read(local_target.join("nested/two.txt")).expect("second download"),
            b"second"
        );
    }

    #[test]
    fn upload_permission_failure_with_gated_ssh_fixture_maps_to_diagnostic_code() {
        let Some((config, secret, _remote_dir)) = scp_fixture_config() else {
            return;
        };
        let remote_path = std::env::var("STACIO_SSH_FIXTURE_READONLY_REMOTE_PATH")
            .unwrap_or_else(|_| "/root/stacio-denied-fixture.txt".to_string());
        let ssh = Libssh2Transport::new()
            .connect_with_secret(&config, secret)
            .expect("fixture ssh connection");
        let engine = Libssh2ScpEngine::new();
        let upload_source = tempfile::NamedTempFile::new().expect("upload source");
        std::fs::write(upload_source.path(), b"stacio denied fixture")
            .expect("write upload source");
        let upload_job = ScpTransferJob::new(
            ScpDirection::Upload,
            upload_source.path().to_string_lossy().to_string(),
            remote_path,
            23,
        );

        let error = engine
            .upload_file(&ssh, &upload_job)
            .expect_err("fixture upload should fail");

        assert!(matches!(
            error.as_str(),
            "FILES_PERMISSION_DENIED" | "FILES_TRANSFER_INTERRUPTED"
        ));
        assert!(!error.contains("scp "));
        assert!(!error.contains("sftp "));
        assert!(!error.contains("rsync "));
        assert!(!error.contains("fixture-password"));
    }

    fn scp_fixture_config() -> Option<(SshConnectionConfig, Option<SshSecret>, String)> {
        let host = std::env::var("STACIO_SSH_FIXTURE_HOST").ok()?;
        let username = std::env::var("STACIO_SSH_FIXTURE_USERNAME").ok()?;
        let remote_dir = std::env::var("STACIO_SSH_FIXTURE_REMOTE_DIR").ok()?;
        let port = std::env::var("STACIO_SSH_FIXTURE_PORT")
            .ok()
            .and_then(|value| value.parse::<u16>().ok())
            .unwrap_or(22);
        let password = std::env::var("STACIO_SSH_FIXTURE_PASSWORD").ok();
        let private_key = std::env::var("STACIO_SSH_FIXTURE_PRIVATE_KEY").ok();
        let passphrase = std::env::var("STACIO_SSH_FIXTURE_PRIVATE_KEY_PASSPHRASE").ok();

        if let Some(password) = password {
            return Some((
                SshConnectionConfig {
                    host,
                    port,
                    username,
                    auth_method: SshAuthMethod::Password {
                        credential_ref: "fixture-password".to_string(),
                    },
                    connect_timeout_ms: 5_000,
                },
                Some(SshSecret::Password(password)),
                remote_dir,
            ));
        }

        private_key.map(|private_key_pem| {
            (
                SshConnectionConfig {
                    host,
                    port,
                    username,
                    auth_method: SshAuthMethod::PrivateKey {
                        key_path: "fixture-memory-key".to_string(),
                        passphrase_ref: passphrase
                            .as_ref()
                            .map(|_| "fixture-passphrase".to_string()),
                    },
                    connect_timeout_ms: 5_000,
                },
                Some(SshSecret::PrivateKey {
                    private_key_pem,
                    passphrase,
                }),
                remote_dir,
            )
        })
    }
}
