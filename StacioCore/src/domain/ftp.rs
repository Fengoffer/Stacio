use crate::domain::ssh::SshRuntimeError;

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct FtpConnectionConfig {
    pub host: String,
    pub port: u16,
    pub username: String,
    pub connect_timeout_ms: u32,
}

#[derive(Clone, PartialEq, Eq, uniffi::Enum)]
pub enum FtpAuthSecret {
    Password { value: String },
    Anonymous,
}

impl std::fmt::Debug for FtpAuthSecret {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            FtpAuthSecret::Password { .. } => formatter
                .debug_tuple("Password")
                .field(&"[redacted]")
                .finish(),
            FtpAuthSecret::Anonymous => formatter.write_str("Anonymous"),
        }
    }
}

pub fn validate_ftp_config(config: &FtpConnectionConfig) -> Result<(), SshRuntimeError> {
    if config.host.trim().is_empty()
        || config.port == 0
        || config.username.trim().is_empty()
        || config.connect_timeout_ms == 0
    {
        return Err(SshRuntimeError::InvalidConfig);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{validate_ftp_config, FtpAuthSecret, FtpConnectionConfig};
    use crate::domain::ssh::SshRuntimeError;

    #[test]
    fn rejects_invalid_ftp_config_without_command_or_secret() {
        let config = FtpConnectionConfig {
            host: " ".to_string(),
            port: 21,
            username: "deploy".to_string(),
            connect_timeout_ms: 10_000,
        };
        let secret = FtpAuthSecret::Password {
            value: "do-not-log".to_string(),
        };

        let error = validate_ftp_config(&config).expect_err("invalid ftp config");

        assert_eq!(error, SshRuntimeError::InvalidConfig);
        assert!(!format!("{config:?}").contains("ftp "));
        assert!(!format!("{secret:?}").contains("do-not-log"));
    }
}
