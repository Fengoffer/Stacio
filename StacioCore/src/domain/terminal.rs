use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct TerminalRuntime {
    pub id: String,
    pub kind: String,
    pub shell_path: String,
    pub remote_host: Option<String>,
    pub remote_port: Option<u32>,
    pub username: Option<String>,
    pub cols: u32,
    pub rows: u32,
    pub resize_revision: u64,
    pub status: String,
    pub output_paused: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct TerminalOutputBatch {
    pub runtime_id: String,
    pub bytes: Vec<u8>,
    pub dropped_byte_count: u32,
    pub protection_active: bool,
    pub buffered_byte_count: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct TerminalInputBatch {
    pub runtime_id: String,
    pub bytes: Vec<u8>,
    pub dropped_byte_count: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum TerminalRuntimeError {
    #[error("Terminal runtime not found: {runtime_id}")]
    RuntimeNotFound { runtime_id: String },
    #[error("Terminal runtime is closed: {runtime_id}")]
    RuntimeClosed { runtime_id: String },
    #[error("Terminal runtime I/O error: {message}")]
    RuntimeIo { message: String },
}

#[cfg(test)]
mod tests {
    use super::TerminalRuntimeError;
    use crate::services::terminal_service::TerminalRuntimeRegistry;

    #[test]
    fn creates_local_shell_runtime_with_default_size() {
        let mut registry = TerminalRuntimeRegistry::new(4096);

        let runtime = registry.open_local_shell("/bin/zsh".to_string(), 120, 30);

        assert_eq!(runtime.kind, "local_shell");
        assert_eq!(runtime.shell_path, "/bin/zsh");
        assert_eq!(runtime.cols, 120);
        assert_eq!(runtime.rows, 30);
        assert_eq!(registry.active_count(), 1);
    }

    #[test]
    fn resize_updates_runtime_size() {
        let mut registry = TerminalRuntimeRegistry::new(4096);
        let runtime = registry.open_local_shell("/bin/zsh".to_string(), 80, 24);

        let updated = registry
            .record_resize(runtime.id.clone(), 132, 40)
            .expect("resize runtime");

        assert_eq!(updated.cols, 132);
        assert_eq!(updated.rows, 40);
    }

    #[test]
    fn batches_output_without_exceeding_limit() {
        let mut registry = TerminalRuntimeRegistry::new(8);
        let runtime = registry.open_local_shell("/bin/zsh".to_string(), 80, 24);

        registry
            .record_output(runtime.id.clone(), vec![1, 2, 3, 4, 5])
            .expect("record first output");
        registry
            .record_output(runtime.id.clone(), vec![6, 7, 8, 9, 10])
            .expect("record second output");

        let batch = registry.take_output_batch(runtime.id).expect("take output");

        assert_eq!(batch.bytes, vec![1, 2, 3, 4, 5, 6, 7, 8]);
        assert_eq!(batch.dropped_byte_count, 2);
    }

    #[test]
    fn output_batch_reports_protection_when_buffer_pressure_drops_bytes() {
        let mut registry = TerminalRuntimeRegistry::new(3);
        let runtime = registry.open_local_shell("/bin/zsh".to_string(), 80, 24);

        registry
            .record_output(runtime.id.clone(), b"abcde".to_vec())
            .expect("record output");

        let batch = registry.take_output_batch(runtime.id).expect("take output");

        assert_eq!(batch.bytes, b"abc".to_vec());
        assert_eq!(batch.dropped_byte_count, 2);
        assert!(batch.protection_active);
        assert_eq!(batch.buffered_byte_count, 3);
    }

    #[test]
    fn paused_runtime_buffers_output_without_draining_to_ui() {
        let mut registry = TerminalRuntimeRegistry::new(8);
        let runtime = registry.open_local_shell("/bin/zsh".to_string(), 80, 24);

        registry
            .set_output_paused(runtime.id.clone(), true)
            .expect("pause output");
        registry
            .record_output(runtime.id.clone(), b"hello".to_vec())
            .expect("record output while paused");

        let paused = registry
            .take_output_batch(runtime.id.clone())
            .expect("take paused output");
        assert_eq!(paused.bytes, Vec::<u8>::new());
        assert_eq!(paused.dropped_byte_count, 0);

        registry
            .set_output_paused(runtime.id.clone(), false)
            .expect("resume output");
        let resumed = registry.take_output_batch(runtime.id).expect("take resumed output");

        assert_eq!(resumed.bytes, b"hello".to_vec());
        assert_eq!(resumed.dropped_byte_count, 0);
    }

    #[test]
    fn creates_remote_ssh_runtime_without_secret_or_system_command() {
        let mut registry = TerminalRuntimeRegistry::new(4096);

        let runtime =
            registry.open_remote_ssh("example.com".to_string(), 22, "deploy".to_string(), 100, 32);

        assert_eq!(runtime.kind, "remote_ssh");
        assert_eq!(runtime.shell_path, "");
        assert_eq!(runtime.remote_host, Some("example.com".to_string()));
        assert_eq!(runtime.remote_port, Some(22));
        assert_eq!(runtime.username, Some("deploy".to_string()));
        assert_eq!(runtime.cols, 100);
        assert_eq!(runtime.rows, 32);
        assert_eq!(runtime.status, "running");
        assert_eq!(registry.active_count(), 1);

        let debug = format!("{runtime:?}");
        assert!(!debug.contains("secret"));
        assert!(!debug.contains("password"));
        assert!(!debug.contains("ssh "));
        assert!(!debug.contains("scp "));
        assert!(!debug.contains("sftp "));
        assert!(!debug.contains("rsync "));
    }

    #[test]
    fn creates_remote_serial_runtime_without_system_command_or_secret() {
        let mut registry = TerminalRuntimeRegistry::new(4096);

        let runtime = registry.open_serial("/dev/cu.usbserial-001".to_string(), 9_600, 100, 32);

        assert_eq!(runtime.kind, "remote_serial");
        assert_eq!(runtime.shell_path, "");
        assert_eq!(
            runtime.remote_host,
            Some("/dev/cu.usbserial-001".to_string())
        );
        assert_eq!(runtime.remote_port, Some(9_600));
        assert_eq!(runtime.username, None);
        assert_eq!(runtime.cols, 100);
        assert_eq!(runtime.rows, 32);
        assert_eq!(runtime.status, "running");
        assert_eq!(registry.active_count(), 1);

        let debug = format!("{runtime:?}");
        assert!(!debug.contains("screen "));
        assert!(!debug.contains("cu "));
        assert!(!debug.contains("minicom "));
        assert!(!debug.contains("password"));
        assert!(!debug.contains("secret"));
    }

    #[test]
    fn batches_remote_input_without_exceeding_limit() {
        let mut registry = TerminalRuntimeRegistry::new(6);
        let runtime =
            registry.open_remote_ssh("example.com".to_string(), 22, "deploy".to_string(), 80, 24);

        registry
            .write_input(runtime.id.clone(), vec![1, 2, 3, 4])
            .expect("write first input");
        registry
            .write_input(runtime.id.clone(), vec![5, 6, 7])
            .expect("write second input");

        let batch = registry.take_input_batch(runtime.id).expect("take input");

        assert_eq!(batch.bytes, vec![1, 2, 3, 4, 5, 6]);
        assert_eq!(batch.dropped_byte_count, 1);
    }

    #[test]
    fn input_batch_drains_after_read() {
        let mut registry = TerminalRuntimeRegistry::new(4096);
        let runtime =
            registry.open_remote_ssh("example.com".to_string(), 22, "deploy".to_string(), 80, 24);

        registry
            .write_input(runtime.id.clone(), b"ls\n".to_vec())
            .expect("write input");

        let first = registry
            .take_input_batch(runtime.id.clone())
            .expect("first input batch");
        let second = registry
            .take_input_batch(runtime.id)
            .expect("second input batch");

        assert_eq!(first.bytes, b"ls\n".to_vec());
        assert_eq!(second.bytes, Vec::<u8>::new());
        assert_eq!(second.dropped_byte_count, 0);
    }

    #[test]
    fn resize_revision_increments_only_when_size_changes() {
        let mut registry = TerminalRuntimeRegistry::new(4096);
        let runtime =
            registry.open_remote_ssh("example.com".to_string(), 22, "deploy".to_string(), 80, 24);

        let initial = registry
            .runtime_snapshot(runtime.id.clone())
            .expect("runtime snapshot");
        assert_eq!(initial.resize_revision, 0);

        let same_size = registry
            .record_resize(runtime.id.clone(), 80, 24)
            .expect("same resize");
        assert_eq!(same_size.resize_revision, 0);

        let changed = registry
            .record_resize(runtime.id, 120, 40)
            .expect("changed resize");
        assert_eq!(changed.resize_revision, 1);
    }

    #[test]
    fn close_marks_runtime_closed_and_rejects_future_input() {
        let mut registry = TerminalRuntimeRegistry::new(4096);
        let runtime =
            registry.open_remote_ssh("example.com".to_string(), 22, "deploy".to_string(), 80, 24);

        registry.close(runtime.id.clone()).expect("close");

        let error = registry
            .write_input(runtime.id.clone(), b"whoami\n".to_vec())
            .expect_err("closed runtime rejects input");

        assert_eq!(
            error,
            TerminalRuntimeError::RuntimeClosed {
                runtime_id: runtime.id
            }
        );
    }
}
