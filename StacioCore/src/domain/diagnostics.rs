#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Enum)]
pub enum DiagnosticSeverity {
    Info,
    Warning,
    Error,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct DiagnosticEntry {
    pub severity: DiagnosticSeverity,
    pub message: String,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct DiagnosticBundle {
    pub session_id: String,
    pub tunnel_id: Option<String>,
    pub entries: Vec<DiagnosticEntry>,
}

pub fn redact_diagnostic_text(input: &str) -> String {
    input
        .split_whitespace()
        .map(|token| {
            if token.contains("secret") || token.contains("credential") {
                "[redacted-credential]".to_string()
            } else if token.contains("/.ssh/") || token.contains(".ssh/") {
                "[redacted-path]".to_string()
            } else {
                token.to_string()
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

#[cfg(test)]
mod diagnostics_tests {
    use super::{redact_diagnostic_text, DiagnosticEntry, DiagnosticSeverity};
    use crate::services::diagnostics_service::build_diagnostic_bundle;

    #[test]
    fn builds_bundle_with_session_and_tunnel_context() {
        let bundle = build_diagnostic_bundle(
            "session_1".to_string(),
            Some("tun_1".to_string()),
            vec![DiagnosticEntry {
                severity: DiagnosticSeverity::Info,
                message: "tunnel running".to_string(),
            }],
        );

        assert_eq!(bundle.session_id, "session_1");
        assert_eq!(bundle.tunnel_id, Some("tun_1".to_string()));
        assert_eq!(bundle.entries.len(), 1);
    }

    #[test]
    fn redacts_credentials_and_private_key_paths() {
        let text = redact_diagnostic_text(
            "credential secret-ref failed with key /Users/me/.ssh/id_ed25519",
        );

        assert!(!text.contains("secret-ref"));
        assert!(!text.contains("/Users/me/.ssh/id_ed25519"));
        assert!(text.contains("[redacted-credential]"));
        assert!(text.contains("[redacted-path]"));
    }
}
