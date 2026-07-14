use uuid::Uuid;

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Enum)]
pub enum ScpDirection {
    Upload,
    Download,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Enum)]
pub enum ScpConflictPolicy {
    Overwrite,
    Skip,
    Rename,
    KeepBoth,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct ScpTransferJob {
    pub id: String,
    pub direction: ScpDirection,
    pub source_path: String,
    pub destination_path: String,
    pub bytes_total: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct ScpResumeOptions {
    pub requested_offset: u64,
    pub force_restart: bool,
}

impl ScpResumeOptions {
    pub fn fresh() -> Self {
        Self {
            requested_offset: 0,
            force_restart: false,
        }
    }
}

impl ScpTransferJob {
    pub fn new(
        direction: ScpDirection,
        source_path: String,
        destination_path: String,
        bytes_total: u64,
    ) -> Self {
        Self {
            id: format!("job_{}", Uuid::new_v4()),
            direction,
            source_path,
            destination_path,
            bytes_total,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct ScpTransferProgress {
    pub job_id: String,
    pub bytes_done: u64,
    pub bytes_total: u64,
    pub status: String,
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum ScpTransferError {
    #[error("FILES_PERMISSION_DENIED")]
    PermissionDenied,
    #[error("FILES_TRANSFER_INTERRUPTED")]
    Interrupted,
}

impl ScpTransferProgress {
    pub fn percent(&self) -> u32 {
        if self.bytes_total == 0 {
            return 0;
        }
        ((self.bytes_done.saturating_mul(100)) / self.bytes_total).min(100) as u32
    }
}

pub fn resolve_conflict_path(destination_path: &str, policy: ScpConflictPolicy) -> Option<String> {
    match policy {
        ScpConflictPolicy::Overwrite => Some(destination_path.to_string()),
        ScpConflictPolicy::Skip => None,
        ScpConflictPolicy::Rename => Some(path_with_suffix(destination_path, "imported")),
        ScpConflictPolicy::KeepBoth => Some(path_with_suffix(destination_path, "copy")),
    }
}

fn path_with_suffix(path: &str, suffix: &str) -> String {
    match path.rsplit_once('.') {
        Some((stem, extension)) if !stem.is_empty() && !extension.contains('/') => {
            format!("{stem} ({suffix}).{extension}")
        }
        _ => format!("{path} ({suffix})"),
    }
}

#[cfg(test)]
mod scp_domain_tests {
    use super::{
        resolve_conflict_path, ScpConflictPolicy, ScpDirection, ScpResumeOptions, ScpTransferJob,
        ScpTransferProgress,
    };

    #[test]
    fn creates_upload_and_download_jobs() {
        let upload = ScpTransferJob::new(
            ScpDirection::Upload,
            "/Users/me/file.txt".to_string(),
            "/tmp/file.txt".to_string(),
            100,
        );
        let download = ScpTransferJob::new(
            ScpDirection::Download,
            "/tmp/file.txt".to_string(),
            "/Users/me/file.txt".to_string(),
            100,
        );

        assert_eq!(upload.direction, ScpDirection::Upload);
        assert_eq!(download.direction, ScpDirection::Download);
        assert!(upload.id.starts_with("job_"));
    }

    #[test]
    fn reports_progress_percentage() {
        let progress = ScpTransferProgress {
            job_id: "job_1".to_string(),
            bytes_done: 25,
            bytes_total: 100,
            status: "running".to_string(),
        };

        assert_eq!(progress.percent(), 25);
    }

    #[test]
    fn creates_default_resume_options_without_changing_fresh_transfers() {
        let options = ScpResumeOptions::fresh();

        assert_eq!(options.requested_offset, 0);
        assert!(!options.force_restart);
    }

    #[test]
    fn resolves_conflict_policies() {
        assert_eq!(
            resolve_conflict_path("/tmp/file.txt", ScpConflictPolicy::Overwrite),
            Some("/tmp/file.txt".to_string())
        );
        assert_eq!(
            resolve_conflict_path("/tmp/file.txt", ScpConflictPolicy::Skip),
            None
        );
        assert_eq!(
            resolve_conflict_path("/tmp/file.txt", ScpConflictPolicy::Rename),
            Some("/tmp/file (imported).txt".to_string())
        );
        assert_eq!(
            resolve_conflict_path("/tmp/file.txt", ScpConflictPolicy::KeepBoth),
            Some("/tmp/file (copy).txt".to_string())
        );
    }
}
