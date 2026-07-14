#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct QuickConnectTarget {
    pub protocol: String,
    pub username: Option<String>,
    pub host: String,
    pub port: u16,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct SessionFolder {
    pub id: String,
    pub parent_id: Option<String>,
    pub name: String,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct SessionRecord {
    pub id: String,
    pub folder_id: Option<String>,
    pub name: String,
    pub protocol: String,
    pub host: String,
    pub port: u32,
    pub username: Option<String>,
    pub private_key_path: Option<String>,
    pub credential_id: Option<String>,
    pub tags: Vec<String>,
    pub last_opened_at: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct SessionDraft {
    pub folder_id: Option<String>,
    pub name: String,
    pub protocol: String,
    pub host: String,
    pub port: u32,
    pub username: Option<String>,
    pub private_key_path: Option<String>,
    pub credential_id: Option<String>,
    pub tags: Vec<String>,
    pub config_json: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct SessionUpdate {
    pub name: Option<String>,
    pub protocol: Option<String>,
    pub folder_id: Option<String>,
    pub host: Option<String>,
    pub port: Option<u32>,
    pub username: Option<String>,
    pub private_key_path: Option<String>,
    pub credential_id: Option<String>,
    pub tags: Option<Vec<String>>,
    pub config_json: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum SessionError {
    #[error("invalid quick connect input")]
    InvalidQuickConnect,
    #[error("invalid port")]
    InvalidPort,
    #[error("database error: {message}")]
    Database { message: String },
    #[error("session not found")]
    NotFound,
}

impl From<rusqlite::Error> for SessionError {
    fn from(value: rusqlite::Error) -> Self {
        SessionError::Database {
            message: value.to_string(),
        }
    }
}

pub fn parse_quick_connect(input: &str) -> Result<QuickConnectTarget, SessionError> {
    let trimmed = input.trim();
    if trimmed.is_empty() {
        return Err(SessionError::InvalidQuickConnect);
    }

    let without_scheme = trimmed.strip_prefix("ssh://").unwrap_or(trimmed);
    if without_scheme.is_empty() {
        return Err(SessionError::InvalidQuickConnect);
    }

    let (username, host_port) = match without_scheme.rsplit_once('@') {
        Some((user, rest)) if !user.trim().is_empty() && !rest.trim().is_empty() => {
            (Some(user.trim().to_string()), rest.trim())
        }
        Some(_) => return Err(SessionError::InvalidQuickConnect),
        None => (None, without_scheme),
    };

    let (host, port) = match host_port.rsplit_once(':') {
        Some((host, port_text)) if !host.trim().is_empty() && !port_text.trim().is_empty() => {
            let port = port_text
                .parse::<u16>()
                .map_err(|_| SessionError::InvalidPort)?;
            (host.trim().to_string(), port)
        }
        Some(_) => return Err(SessionError::InvalidQuickConnect),
        None => (host_port.trim().to_string(), 22),
    };

    if host.is_empty() {
        return Err(SessionError::InvalidQuickConnect);
    }

    Ok(QuickConnectTarget {
        protocol: "ssh".to_string(),
        username,
        host,
        port,
    })
}

#[cfg(test)]
mod quick_connect_tests {
    use super::{parse_quick_connect, SessionError};

    #[test]
    fn parses_user_host_and_port() {
        let target = parse_quick_connect("admin@example.com:2222").expect("parse quick connect");

        assert_eq!(target.protocol, "ssh");
        assert_eq!(target.username, Some("admin".to_string()));
        assert_eq!(target.host, "example.com");
        assert_eq!(target.port, 2222);
    }

    #[test]
    fn parses_ssh_url() {
        let target =
            parse_quick_connect("ssh://deploy@example.internal:2200").expect("parse ssh url");

        assert_eq!(target.username, Some("deploy".to_string()));
        assert_eq!(target.host, "example.internal");
        assert_eq!(target.port, 2200);
    }

    #[test]
    fn defaults_host_only_to_ssh_port() {
        let target = parse_quick_connect("db.internal").expect("parse host");

        assert_eq!(target.username, None);
        assert_eq!(target.host, "db.internal");
        assert_eq!(target.port, 22);
    }

    #[test]
    fn rejects_empty_input() {
        let error = parse_quick_connect("  ").expect_err("reject empty input");

        assert_eq!(error, SessionError::InvalidQuickConnect);
    }
}
