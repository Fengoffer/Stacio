use crate::domain::ssh::SshRuntimeError;
use std::fmt;

#[derive(Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct TelnetConnectionConfig {
    pub host: String,
    pub port: u16,
    pub username: Option<String>,
    pub password: Option<String>,
    pub connect_timeout_ms: u32,
}

impl fmt::Debug for TelnetConnectionConfig {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("TelnetConnectionConfig")
            .field("host", &self.host)
            .field("port", &self.port)
            .field("username", &self.username)
            .field("credential_configured", &self.password.is_some())
            .field("connect_timeout_ms", &self.connect_timeout_ms)
            .finish()
    }
}

pub fn validate_telnet_config(config: &TelnetConnectionConfig) -> Result<(), SshRuntimeError> {
    if config.host.trim().is_empty()
        || config.port == 0
        || config.connect_timeout_ms == 0
        || config
            .username
            .as_ref()
            .is_some_and(|value| value.chars().any(char::is_control))
        || config
            .password
            .as_ref()
            .is_some_and(|value| value.chars().any(char::is_control))
    {
        return Err(SshRuntimeError::InvalidConfig);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{validate_telnet_config, TelnetConnectionConfig};
    use crate::domain::ssh::SshRuntimeError;

    #[test]
    fn rejects_invalid_telnet_config_without_command() {
        let config = TelnetConnectionConfig {
            host: " ".to_string(),
            port: 23,
            username: Some("admin".to_string()),
            password: None,
            connect_timeout_ms: 10_000,
        };

        let error = validate_telnet_config(&config).expect_err("invalid telnet config");

        assert_eq!(error, SshRuntimeError::InvalidConfig);
        assert!(!format!("{config:?}").contains("telnet "));
        assert!(!format!("{config:?}").contains("password"));
    }
}
