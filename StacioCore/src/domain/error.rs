use std::collections::BTreeMap;

use serde::Serialize;

use crate::telemetry::redaction::redact_detail;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ErrorCode {
    AppInitializationFailed,
    KeychainAccessDenied,
}

impl ErrorCode {
    pub fn as_str(self) -> &'static str {
        match self {
            ErrorCode::AppInitializationFailed => "APP_INITIALIZATION_FAILED",
            ErrorCode::KeychainAccessDenied => "KEYCHAIN_ACCESS_DENIED",
        }
    }
}

#[derive(Debug, Clone)]
pub struct AppError {
    code: ErrorCode,
    message: String,
    details: BTreeMap<String, String>,
}

impl AppError {
    pub fn new(code: ErrorCode, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
            details: BTreeMap::new(),
        }
    }

    pub fn with_detail(mut self, key: impl Into<String>, value: impl Into<String>) -> Self {
        self.details.insert(key.into(), value.into());
        self
    }

    pub fn to_client_error(&self, trace_id: impl Into<String>) -> ClientErrorResponse {
        let details = self
            .details
            .iter()
            .map(|(key, value)| (key.clone(), redact_detail(key, value)))
            .collect();

        ClientErrorResponse {
            ok: false,
            error: ClientError {
                code: self.code.as_str().to_string(),
                message: self.message.clone(),
                details,
                trace_id: trace_id.into(),
            },
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct ClientErrorResponse {
    pub ok: bool,
    pub error: ClientError,
}

#[derive(Debug, Clone, Serialize)]
pub struct ClientError {
    pub code: String,
    pub message: String,
    pub details: BTreeMap<String, String>,
    pub trace_id: String,
}

#[cfg(test)]
mod tests {
    use super::{AppError, ErrorCode};

    #[test]
    fn client_error_redacts_secret_details() {
        let response = AppError::new(ErrorCode::KeychainAccessDenied, "Keychain access denied")
            .with_detail("password", "secret")
            .with_detail("host", "example.com")
            .to_client_error("trace_001");

        assert_eq!(response.ok, false);
        assert_eq!(response.error.code, "KEYCHAIN_ACCESS_DENIED");
        assert_eq!(
            response.error.details.get("password").unwrap(),
            "[redacted]"
        );
        assert_eq!(response.error.details.get("host").unwrap(), "example.com");
    }
}
