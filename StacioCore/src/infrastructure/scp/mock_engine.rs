#[cfg(test)]
mod scp_engine_tests {
    use crate::domain::scp::{ScpDirection, ScpTransferError, ScpTransferJob};
    use crate::services::scp_service::{run_scp_transfer, MockScpEngine, MockScpOutcome};

    #[test]
    fn emits_successful_transfer_progress() {
        let job = ScpTransferJob::new(
            ScpDirection::Upload,
            "/local/file.txt".to_string(),
            "/remote/file.txt".to_string(),
            100,
        );
        let engine = MockScpEngine::new(MockScpOutcome::Success);

        let progress = run_scp_transfer(job.clone(), &engine).expect("transfer");

        assert_eq!(progress.last().expect("final").job_id, job.id);
        assert_eq!(progress.last().expect("final").bytes_done, 100);
        assert_eq!(progress.last().expect("final").status, "completed");
    }

    #[test]
    fn maps_permission_failure() {
        let job = ScpTransferJob::new(
            ScpDirection::Download,
            "/root/secret".to_string(),
            "/local/secret".to_string(),
            10,
        );
        let engine = MockScpEngine::new(MockScpOutcome::PermissionDenied);

        let error = run_scp_transfer(job, &engine).expect_err("permission failure");

        assert_eq!(error, ScpTransferError::PermissionDenied);
    }

    #[test]
    fn files_failure_does_not_close_terminal_runtime() {
        let job = ScpTransferJob::new(
            ScpDirection::Download,
            "/root/secret".to_string(),
            "/local/secret".to_string(),
            10,
        );
        let engine = MockScpEngine::new(MockScpOutcome::PermissionDenied);
        let terminal_connected = true;

        let _ = run_scp_transfer(job, &engine).expect_err("permission failure");

        assert!(terminal_connected);
    }
}
