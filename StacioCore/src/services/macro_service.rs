use crate::domain::macro_recording::{redact_macro_input, MacroRecording, MacroStep};

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum MacroError {
    #[error("macro serialization failed: {message}")]
    Serialization { message: String },
}

pub fn serialize_macro_recording(recording: MacroRecording) -> Result<String, MacroError> {
    let redacted = MacroRecording {
        id: recording.id,
        name: recording.name,
        steps: recording
            .steps
            .into_iter()
            .map(|step| MacroStep {
                order: step.order,
                input: redact_macro_input(&step.input),
                delay_ms: step.delay_ms,
            })
            .collect(),
    };

    serde_json::to_string(&redacted).map_err(|error| MacroError::Serialization {
        message: error.to_string(),
    })
}

pub fn playback_macro_steps(mut recording: MacroRecording) -> Vec<MacroStep> {
    recording.steps.sort_by_key(|step| step.order);
    recording.steps
}
