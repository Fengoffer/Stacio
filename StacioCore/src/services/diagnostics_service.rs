use crate::domain::diagnostics::{redact_diagnostic_text, DiagnosticBundle, DiagnosticEntry};

pub fn build_diagnostic_bundle(
    session_id: String,
    tunnel_id: Option<String>,
    entries: Vec<DiagnosticEntry>,
) -> DiagnosticBundle {
    DiagnosticBundle {
        session_id,
        tunnel_id,
        entries: entries
            .into_iter()
            .map(|entry| DiagnosticEntry {
                severity: entry.severity,
                message: redact_diagnostic_text(&entry.message),
            })
            .collect(),
    }
}
