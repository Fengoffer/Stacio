use sha2::{Digest, Sha256};

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Enum)]
pub enum SshAuthMethod {
    Password {
        credential_ref: String,
    },
    PrivateKey {
        key_path: String,
        passphrase_ref: Option<String>,
    },
    Agent,
}

impl SshAuthMethod {
    pub fn label(&self) -> String {
        match self {
            SshAuthMethod::Password { .. } => "password".to_string(),
            SshAuthMethod::PrivateKey { .. } => "private_key".to_string(),
            SshAuthMethod::Agent => "agent".to_string(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct SshConnectionConfig {
    pub host: String,
    pub port: u16,
    pub username: String,
    pub auth_method: SshAuthMethod,
    pub connect_timeout_ms: u32,
}

#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct SshProxyJumpRuntimeConfig {
    pub jump_config: SshConnectionConfig,
    pub jump_secret: SshAuthSecret,
    pub jump_expected_fingerprint_sha256: String,
    pub target_expected_fingerprint_sha256: String,
}

impl std::fmt::Debug for SshProxyJumpRuntimeConfig {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("SshProxyJumpRuntimeConfig")
            .field("jump_config", &self.jump_config)
            .field("jump_secret", &"[redacted]")
            .field(
                "jump_expected_fingerprint_sha256",
                &self.jump_expected_fingerprint_sha256,
            )
            .field(
                "target_expected_fingerprint_sha256",
                &self.target_expected_fingerprint_sha256,
            )
            .finish()
    }
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct SshConnectionStatus {
    pub connected: bool,
    pub host: String,
    pub port: u16,
    pub username: String,
    pub auth_method: String,
    pub diagnostic: String,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct LiveSshSessionInfo {
    pub runtime_id: String,
    pub host: String,
    pub port: u16,
    pub username: String,
    pub host_key_type: String,
    pub host_key_fingerprint_sha256: String,
    pub cipher_client_to_server: Option<String>,
    pub cipher_server_to_client: Option<String>,
    pub kex_algorithm: Option<String>,
    pub compression_client_to_server: Option<String>,
    pub compression_server_to_client: Option<String>,
    pub server_banner: Option<String>,
    pub userauth_banner: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct RemoteOperatingSystemInfo {
    pub id: String,
    pub id_like: Vec<String>,
    pub name: String,
    pub pretty_name: String,
    pub version: String,
    pub version_id: String,
    pub kernel_name: String,
    pub kernel_release: String,
    pub architecture: String,
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum SshRuntimeError {
    #[error("SSH 配置无效")]
    InvalidConfig,
    #[error("SSH 认证失败")]
    AuthFailed,
    #[error("SSH 连接超时")]
    Timeout,
    #[error("SSH 主机密钥已变更")]
    HostKeyChanged,
    #[error("SSH 主机密钥未知")]
    UnknownHostKey,
    #[error("SSH 传输错误：{message}")]
    Transport { message: String },
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct HostKeyRecord {
    pub host: String,
    pub port: u16,
    pub fingerprint_sha256: String,
}

#[derive(Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct LiveSshHostKey {
    pub host: String,
    pub port: u16,
    pub key_type: String,
    pub fingerprint_sha256: String,
    pub raw_key: Vec<u8>,
    pub key_len: u64,
}

impl std::fmt::Debug for LiveSshHostKey {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("LiveSshHostKey")
            .field("host", &self.host)
            .field("port", &self.port)
            .field("key_type", &self.key_type)
            .field("fingerprint_sha256", &self.fingerprint_sha256)
            .field("raw_key", &"[redacted]")
            .field("key_len", &self.key_len)
            .finish()
    }
}

impl LiveSshHostKey {
    pub fn from_host_key(host: &str, port: u16, key_type: &str, raw_key: &[u8]) -> Self {
        Self {
            host: host.to_string(),
            port,
            key_type: key_type.to_string(),
            fingerprint_sha256: fingerprint_sha256(raw_key),
            raw_key: raw_key.to_vec(),
            key_len: raw_key.len() as u64,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Enum)]
pub enum HostKeyVerification {
    Trusted,
    Unknown { fingerprint: String },
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Enum)]
pub enum HostKeyTrustDecision {
    TrustOnce,
    TrustAndSave,
    Reject,
}

impl HostKeyTrustDecision {
    pub fn label(&self) -> String {
        match self {
            HostKeyTrustDecision::TrustOnce => "trust_once".to_string(),
            HostKeyTrustDecision::TrustAndSave => "trust_and_save".to_string(),
            HostKeyTrustDecision::Reject => "reject".to_string(),
        }
    }
}

#[derive(Clone, PartialEq, Eq, uniffi::Enum)]
pub enum SshAuthSecret {
    Password {
        value: String,
    },
    PrivateKey {
        private_key_pem: String,
        passphrase: Option<String>,
    },
    Agent,
}

impl std::fmt::Debug for SshAuthSecret {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SshAuthSecret::Password { .. } => formatter
                .debug_tuple("Password")
                .field(&"[redacted]")
                .finish(),
            SshAuthSecret::PrivateKey { passphrase, .. } => formatter
                .debug_struct("PrivateKey")
                .field("private_key_pem", &"[redacted]")
                .field("passphrase", &passphrase.as_ref().map(|_| "[redacted]"))
                .finish(),
            SshAuthSecret::Agent => formatter.write_str("Agent"),
        }
    }
}

pub fn validate_ssh_config(config: SshConnectionConfig) -> Result<(), SshRuntimeError> {
    if config.host.trim().is_empty()
        || contains_host_separator(&config.host)
        || contains_control_character(&config.host)
        || config.port == 0
        || config.username.trim().is_empty()
        || contains_control_character(&config.username)
        || config.connect_timeout_ms == 0
    {
        return Err(SshRuntimeError::InvalidConfig);
    }

    match config.auth_method {
        SshAuthMethod::Password { credential_ref } if credential_ref.trim().is_empty() => {
            Err(SshRuntimeError::InvalidConfig)
        }
        SshAuthMethod::PrivateKey { key_path, .. } if key_path.trim().is_empty() => {
            Err(SshRuntimeError::InvalidConfig)
        }
        _ => Ok(()),
    }
}

pub fn validate_proxy_jump_runtime_config(
    target_config: SshConnectionConfig,
    proxy_jump: SshProxyJumpRuntimeConfig,
) -> Result<(), SshRuntimeError> {
    validate_ssh_config(target_config)?;
    validate_ssh_config(proxy_jump.jump_config)?;
    if proxy_jump
        .jump_expected_fingerprint_sha256
        .trim()
        .is_empty()
        || proxy_jump
            .target_expected_fingerprint_sha256
            .trim()
            .is_empty()
    {
        return Err(SshRuntimeError::InvalidConfig);
    }
    Ok(())
}

fn contains_host_separator(value: &str) -> bool {
    value.chars().any(char::is_whitespace)
}

fn contains_control_character(value: &str) -> bool {
    value.chars().any(char::is_control)
}

pub fn redact_ssh_diagnostic(input: &str) -> String {
    let mut should_redact_next_bearer_value = false;
    input
        .split_whitespace()
        .map(|token| {
            let lowercased = token.to_ascii_lowercase();
            if should_redact_next_bearer_value {
                should_redact_next_bearer_value = false;
                return "[redacted-credential]".to_string();
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
            {
                "[redacted-credential]".to_string()
            } else if lowercased.contains("/.ssh/") || lowercased.contains(".ssh/") {
                "[redacted-path]".to_string()
            } else {
                token.to_string()
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

pub fn fingerprint_sha256(host_key: &[u8]) -> String {
    let digest = Sha256::digest(host_key);
    format!("SHA256:{}", hex::encode(digest))
}

pub fn verify_host_key(
    host: &str,
    port: u16,
    host_key: &[u8],
    known_hosts: &[HostKeyRecord],
) -> Result<HostKeyVerification, SshRuntimeError> {
    let fingerprint = fingerprint_sha256(host_key);
    let known = known_hosts
        .iter()
        .find(|record| record.host == host && record.port == port);

    match known {
        Some(record) if record.fingerprint_sha256 == fingerprint => {
            Ok(HostKeyVerification::Trusted)
        }
        Some(_) => Err(SshRuntimeError::HostKeyChanged),
        None => Ok(HostKeyVerification::Unknown { fingerprint }),
    }
}

#[cfg(test)]
mod ssh_config_tests {
    use super::{
        redact_ssh_diagnostic, validate_ssh_config, SshAuthMethod, SshConnectionConfig,
        SshRuntimeError,
    };

    #[test]
    fn accepts_valid_password_config_without_shell_command() {
        let config = SshConnectionConfig {
            host: "example.com".to_string(),
            port: 22,
            username: "deploy".to_string(),
            auth_method: SshAuthMethod::Password {
                credential_ref: "keychain:item".to_string(),
            },
            connect_timeout_ms: 10_000,
        };

        validate_ssh_config(config.clone()).expect("valid config");

        let debug = format!("{config:?}");
        assert!(!debug.contains("ssh "));
        assert!(!debug.contains("scp "));
    }

    #[test]
    fn rejects_empty_host_and_invalid_port() {
        let config = SshConnectionConfig {
            host: " ".to_string(),
            port: 0,
            username: "deploy".to_string(),
            auth_method: SshAuthMethod::Agent,
            connect_timeout_ms: 10_000,
        };

        let error = validate_ssh_config(config).expect_err("reject invalid config");

        assert_eq!(error, SshRuntimeError::InvalidConfig);
    }

    #[test]
    fn rejects_embedded_host_and_username_separators() {
        for (host, username) in [
            ("example.com\nproxy.internal", "deploy"),
            ("bad host.example.com", "deploy"),
            ("example.com", "deploy\rroot"),
        ] {
            let config = SshConnectionConfig {
                host: host.to_string(),
                port: 22,
                username: username.to_string(),
                auth_method: SshAuthMethod::Agent,
                connect_timeout_ms: 10_000,
            };

            let error = validate_ssh_config(config).expect_err("reject unsafe endpoint field");

            assert_eq!(error, SshRuntimeError::InvalidConfig);
        }
    }

    #[test]
    fn rejects_control_characters_in_host() {
        for host in ["example.com\u{1b}[31m", "example.com\0proxy"] {
            let config = SshConnectionConfig {
                host: host.to_string(),
                port: 22,
                username: "deploy".to_string(),
                auth_method: SshAuthMethod::Agent,
                connect_timeout_ms: 10_000,
            };

            let error = validate_ssh_config(config).expect_err("reject unsafe host");

            assert_eq!(error, SshRuntimeError::InvalidConfig, "host: {host:?}");
        }
    }

    #[test]
    fn labels_supported_auth_methods_without_secret_values() {
        assert_eq!(
            SshAuthMethod::Password {
                credential_ref: "secret-ref".to_string()
            }
            .label(),
            "password"
        );
        assert_eq!(
            SshAuthMethod::PrivateKey {
                key_path: "~/.ssh/id_ed25519".to_string(),
                passphrase_ref: Some("secret-ref".to_string())
            }
            .label(),
            "private_key"
        );
        assert_eq!(SshAuthMethod::Agent.label(), "agent");
    }

    #[test]
    fn redacts_diagnostic_strings() {
        let diagnostic = redact_ssh_diagnostic(
            "auth failed for deploy@example.com with credential secret-ref and key /Users/me/.ssh/id",
        );

        assert!(!diagnostic.contains("secret-ref"));
        assert!(!diagnostic.contains("/Users/me/.ssh/id"));
        assert!(diagnostic.contains("[redacted-credential]"));
    }

    #[test]
    fn redacts_sensitive_diagnostic_tokens_case_insensitively() {
        let diagnostic = redact_ssh_diagnostic(
            "auth failed PASSWORD=ProdPassword TOKEN=api-value CREDENTIAL=VaultItem key=~/.SSH/id_ed25519",
        );

        assert!(!diagnostic.contains("ProdPassword"));
        assert!(!diagnostic.contains("api-value"));
        assert!(!diagnostic.contains("VaultItem"));
        assert!(!diagnostic.contains("~/.SSH/id_ed25519"));
        assert!(diagnostic.contains("[redacted-credential]"));
        assert!(diagnostic.contains("[redacted-path]"));
    }

    #[test]
    fn redacts_private_key_passphrase_diagnostics() {
        let diagnostic = redact_ssh_diagnostic(
            "private key auth failed PASSPHRASE=key-passphrase passphrase_ref=keychain-item",
        );

        assert!(!diagnostic.contains("key-passphrase"));
        assert!(!diagnostic.contains("keychain-item"));
        assert!(diagnostic.contains("[redacted-credential]"));
    }

    #[test]
    fn redacts_bearer_credential_values_in_diagnostics() {
        let diagnostic = redact_ssh_diagnostic(
            "proxy failed with Authorization: Bearer sk-live-123456 and Authorization:Bearer sk-live-abcdef",
        );

        assert!(!diagnostic.contains("sk-live-123456"));
        assert!(!diagnostic.contains("sk-live-abcdef"));
        assert!(diagnostic.contains("Bearer [redacted-credential]"));
        assert!(diagnostic.contains("Authorization:Bearer [redacted-credential]"));
    }

    #[test]
    fn runtime_errors_use_chinese_user_facing_messages() {
        assert_eq!(SshRuntimeError::InvalidConfig.to_string(), "SSH 配置无效");
        assert_eq!(SshRuntimeError::AuthFailed.to_string(), "SSH 认证失败");
        assert_eq!(SshRuntimeError::Timeout.to_string(), "SSH 连接超时");
        assert_eq!(
            SshRuntimeError::HostKeyChanged.to_string(),
            "SSH 主机密钥已变更"
        );
        assert_eq!(
            SshRuntimeError::UnknownHostKey.to_string(),
            "SSH 主机密钥未知"
        );
        assert_eq!(
            SshRuntimeError::Transport {
                message: "连接被拒绝".to_string()
            }
            .to_string(),
            "SSH 传输错误：连接被拒绝"
        );
    }
}

#[cfg(test)]
mod host_key_tests {
    use super::{
        fingerprint_sha256, verify_host_key, HostKeyRecord, HostKeyVerification, SshRuntimeError,
    };

    #[test]
    fn returns_unknown_for_first_seen_host_key() {
        let result = verify_host_key("example.com", 22, b"host-key", &[]).expect("verify");

        assert_eq!(
            result,
            HostKeyVerification::Unknown {
                fingerprint: fingerprint_sha256(b"host-key")
            }
        );
    }

    #[test]
    fn accepts_matching_known_host_key() {
        let fingerprint = fingerprint_sha256(b"host-key");
        let known = vec![HostKeyRecord {
            host: "example.com".to_string(),
            port: 22,
            fingerprint_sha256: fingerprint.clone(),
        }];

        let result = verify_host_key("example.com", 22, b"host-key", &known).expect("verify");

        assert_eq!(result, HostKeyVerification::Trusted);
    }

    #[test]
    fn rejects_changed_host_key() {
        let known = vec![HostKeyRecord {
            host: "example.com".to_string(),
            port: 22,
            fingerprint_sha256: fingerprint_sha256(b"old-key"),
        }];

        let error = verify_host_key("example.com", 22, b"new-key", &known)
            .expect_err("changed key rejected");

        assert_eq!(error, SshRuntimeError::HostKeyChanged);
    }

    #[test]
    fn formats_sha256_fingerprint() {
        let fingerprint = fingerprint_sha256(b"host-key");

        assert!(fingerprint.starts_with("SHA256:"));
        assert!(!fingerprint.contains('\n'));
        assert!(fingerprint.len() > "SHA256:".len());
    }
}

#[cfg(test)]
mod host_key_decision_tests {
    use super::HostKeyTrustDecision;

    #[test]
    fn labels_host_key_trust_decisions() {
        assert_eq!(HostKeyTrustDecision::TrustOnce.label(), "trust_once");
        assert_eq!(HostKeyTrustDecision::TrustAndSave.label(), "trust_and_save");
        assert_eq!(HostKeyTrustDecision::Reject.label(), "reject");
    }

    #[test]
    fn debug_output_does_not_contain_secret_material() {
        let debug = format!("{:?}", HostKeyTrustDecision::TrustAndSave);

        assert!(!debug.contains("secret"));
        assert!(!debug.contains("password"));
    }
}
