#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct MacroStep {
    pub order: u32,
    pub input: String,
    pub delay_ms: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct MacroRecording {
    pub id: String,
    pub name: String,
    pub steps: Vec<MacroStep>,
}

pub fn redact_macro_input(input: &str) -> String {
    let mut should_redact_next_bearer_value = false;
    input
        .split_whitespace()
        .map(|token| {
            let lowercased = token.to_ascii_lowercase();
            if should_redact_next_bearer_value {
                should_redact_next_bearer_value = false;
                return "[redacted]".to_string();
            }
            if lowercased == "bearer" || lowercased.ends_with(":bearer") {
                should_redact_next_bearer_value = true;
                return token.to_string();
            }
            if lowercased.contains("password")
                || lowercased.contains("passphrase")
                || lowercased.contains("secret")
                || lowercased.contains("credential")
                || lowercased.contains("token")
                || lowercased.contains("/.ssh/")
                || lowercased.contains(".ssh/")
            {
                "[redacted]".to_string()
            } else {
                token.to_string()
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

#[cfg(test)]
mod macro_recording_tests {
    use super::{MacroRecording, MacroStep};
    use crate::services::macro_service::{playback_macro_steps, serialize_macro_recording};

    #[test]
    fn serializes_macro_without_secret_command_values() {
        let recording = MacroRecording {
            id: "macro_1".to_string(),
            name: "Deploy".to_string(),
            steps: vec![MacroStep {
                order: 1,
                input: "export TOKEN=secret-value".to_string(),
                delay_ms: 100,
            }],
        };

        let json = serialize_macro_recording(recording).expect("serialize");

        assert!(json.contains("Deploy"));
        assert!(!json.contains("secret-value"));
        assert!(json.contains("[redacted]"));
    }

    #[test]
    fn serializes_macro_without_credential_style_command_values() {
        let recording = MacroRecording {
            id: "macro_1".to_string(),
            name: "Deploy".to_string(),
            steps: vec![MacroStep {
                order: 1,
                input: "export PASSWORD=prod-password CREDENTIAL=deploy-token PASSPHRASE=key-passphrase ssh -i /Users/alice/.ssh/id_ed25519".to_string(),
                delay_ms: 100,
            }],
        };

        let json = serialize_macro_recording(recording).expect("serialize");

        assert!(!json.contains("prod-password"));
        assert!(!json.contains("deploy-token"));
        assert!(!json.contains("key-passphrase"));
        assert!(!json.contains("/Users/alice/.ssh/id_ed25519"));
    }

    #[test]
    fn serializes_macro_without_bearer_credential_values() {
        let recording = MacroRecording {
            id: "macro_1".to_string(),
            name: "Deploy".to_string(),
            steps: vec![
                MacroStep {
                    order: 1,
                    input: "curl -H Authorization: Bearer sk-live-123456 https://api.example.com"
                        .to_string(),
                    delay_ms: 100,
                },
                MacroStep {
                    order: 2,
                    input: "curl -H Authorization:Bearer sk-live-abcdef https://api.example.com"
                        .to_string(),
                    delay_ms: 100,
                },
            ],
        };

        let json = serialize_macro_recording(recording).expect("serialize");

        assert!(!json.contains("sk-live-123456"));
        assert!(!json.contains("sk-live-abcdef"));
        assert!(json.contains("Bearer [redacted]"));
        assert!(json.contains("Authorization:Bearer [redacted]"));
    }

    #[test]
    fn playback_preserves_step_order() {
        let recording = MacroRecording {
            id: "macro_1".to_string(),
            name: "Deploy".to_string(),
            steps: vec![
                MacroStep {
                    order: 2,
                    input: "second".to_string(),
                    delay_ms: 0,
                },
                MacroStep {
                    order: 1,
                    input: "first".to_string(),
                    delay_ms: 0,
                },
            ],
        };

        let steps = playback_macro_steps(recording);

        assert_eq!(steps[0].input, "first");
        assert_eq!(steps[1].input, "second");
    }
}
