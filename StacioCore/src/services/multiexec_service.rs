use crate::domain::{
    macro_recording::redact_macro_input,
    multiexec::{build_multiexec_plan, MultiExecError, MultiExecTarget},
};

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct BroadcastAuditEvent {
    pub target_count: u32,
    pub sent_count: u32,
    pub failed_count: u32,
    pub redacted_input: String,
    pub executed: bool,
}

pub fn prepare_broadcast_input(
    targets: Vec<MultiExecTarget>,
    input: &str,
    production_confirmed: bool,
) -> Result<BroadcastAuditEvent, MultiExecError> {
    let plan = build_multiexec_plan(targets, production_confirmed)?;

    Ok(BroadcastAuditEvent {
        target_count: plan.target_ids.len() as u32,
        sent_count: 0,
        failed_count: 0,
        redacted_input: redact_broadcast_input(input),
        executed: false,
    })
}

pub fn mark_broadcast_executed(event: BroadcastAuditEvent, sent_count: u32) -> BroadcastAuditEvent {
    let bounded_sent_count = sent_count.min(event.target_count);
    BroadcastAuditEvent {
        failed_count: event.target_count.saturating_sub(bounded_sent_count),
        sent_count: bounded_sent_count,
        executed: true,
        ..event
    }
}

fn redact_broadcast_input(input: &str) -> String {
    redact_macro_input(input)
}

#[cfg(test)]
mod broadcast_audit_tests {
    use crate::domain::multiexec::{MultiExecError, MultiExecTarget};

    use super::{mark_broadcast_executed, prepare_broadcast_input};

    #[test]
    fn prepares_audit_event_without_executing_input() {
        let targets = vec![MultiExecTarget::new("term_1", "dev", "development", true)];

        let event = prepare_broadcast_input(targets, "ls -la", false).expect("broadcast");

        assert_eq!(event.target_count, 1);
        assert_eq!(event.sent_count, 0);
        assert_eq!(event.failed_count, 0);
        assert_eq!(event.redacted_input, "ls -la");
        assert_eq!(event.executed, false);
    }

    #[test]
    fn marks_audit_event_after_swift_broadcast_attempt() {
        let targets = vec![
            MultiExecTarget::new("term_1", "dev", "development", true),
            MultiExecTarget::new("term_2", "prod", "production", true),
        ];

        let prepared = prepare_broadcast_input(targets, "uptime", true).expect("broadcast");
        let event = mark_broadcast_executed(prepared, 1);

        assert_eq!(event.target_count, 2);
        assert_eq!(event.sent_count, 1);
        assert_eq!(event.failed_count, 1);
        assert_eq!(event.redacted_input, "uptime");
        assert!(event.executed);
    }

    #[test]
    fn caps_sent_count_to_target_count() {
        let targets = vec![MultiExecTarget::new("term_1", "dev", "development", true)];

        let prepared = prepare_broadcast_input(targets, "uptime", false).expect("broadcast");
        let event = mark_broadcast_executed(prepared, 9);

        assert_eq!(event.sent_count, 1);
        assert_eq!(event.failed_count, 0);
        assert!(event.executed);
    }

    #[test]
    fn redacts_secret_tokens_in_broadcast_input() {
        let targets = vec![MultiExecTarget::new("term_1", "dev", "development", true)];

        let event = prepare_broadcast_input(targets, "export TOKEN=secret-value", false)
            .expect("broadcast");

        assert!(!event.redacted_input.contains("secret-value"));
        assert!(event.redacted_input.contains("[redacted]"));
    }

    #[test]
    fn redacts_bearer_values_in_broadcast_audit_input() {
        let targets = vec![MultiExecTarget::new("term_1", "dev", "development", true)];

        let event = prepare_broadcast_input(
            targets,
            "curl -H Authorization: Bearer sk-live-123456 && curl -H Authorization:Bearer sk-live-abcdef",
            false,
        )
        .expect("broadcast");

        assert!(!event.redacted_input.contains("sk-live-123456"));
        assert!(!event.redacted_input.contains("sk-live-abcdef"));
        assert!(event.redacted_input.contains("Bearer [redacted]"));
        assert!(event.redacted_input.contains("Authorization:Bearer [redacted]"));
    }

    #[test]
    fn blocks_unconfirmed_production_broadcast() {
        let targets = vec![MultiExecTarget::new("term_1", "prod", "production", true)];

        let error =
            prepare_broadcast_input(targets, "uptime", false).expect_err("blocked production");

        assert_eq!(error, MultiExecError::ProductionConfirmationRequired);
    }
}
