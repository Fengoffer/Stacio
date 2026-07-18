#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Enum)]
pub enum TunnelKind {
    Local,
    Remote,
    Dynamic,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct TunnelProfile {
    pub id: String,
    pub kind: TunnelKind,
    pub local_host: String,
    pub local_port: u16,
    pub remote_host: String,
    pub remote_port: u16,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct TunnelProfileRecord {
    pub profile: TunnelProfile,
    pub session_id: Option<String>,
    pub endpoint_session_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Enum)]
pub enum TunnelState {
    Stopped,
    Starting,
    Running,
    Failed,
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum TunnelError {
    #[error("隧道端口无效")]
    InvalidPort,
    #[error("本地端口已被占用")]
    LocalPortInUse,
    #[error("SSH 隧道失败")]
    SshFailed,
    #[error("隧道状态转换无效")]
    InvalidTransition,
}

impl TunnelError {
    pub fn code(&self) -> String {
        match self {
            TunnelError::InvalidPort => "TUNNEL_INVALID_PORT",
            TunnelError::LocalPortInUse => "TUNNEL_LOCAL_PORT_IN_USE",
            TunnelError::SshFailed => "TUNNEL_SSH_FAILED",
            TunnelError::InvalidTransition => "TUNNEL_INVALID_TRANSITION",
        }
        .to_string()
    }
}

pub fn validate_tunnel_profile(profile: TunnelProfile) -> Result<(), TunnelError> {
    if profile.local_host.trim().is_empty()
        || contains_host_separator(&profile.local_host)
        || profile.local_port == 0
    {
        return Err(TunnelError::InvalidPort);
    }
    if matches!(profile.kind, TunnelKind::Dynamic) {
        return Ok(());
    }
    if profile.remote_host.trim().is_empty()
        || contains_host_separator(&profile.remote_host)
        || profile.remote_port == 0
    {
        return Err(TunnelError::InvalidPort);
    }
    Ok(())
}

fn contains_host_separator(value: &str) -> bool {
    value
        .chars()
        .any(|character| character.is_whitespace() || character.is_control())
}

pub fn tunnel_requires_local_port_check(profile: &TunnelProfile) -> bool {
    matches!(profile.kind, TunnelKind::Local | TunnelKind::Dynamic)
}

pub fn transition_tunnel_state(
    state: TunnelState,
    event: &str,
) -> Result<TunnelState, TunnelError> {
    match (state, event) {
        (TunnelState::Stopped, "start") => Ok(TunnelState::Starting),
        (TunnelState::Starting, "ready") => Ok(TunnelState::Running),
        (TunnelState::Starting, "fail") | (TunnelState::Running, "fail") => Ok(TunnelState::Failed),
        (TunnelState::Running, "stop") | (TunnelState::Failed, "stop") => Ok(TunnelState::Stopped),
        _ => Err(TunnelError::InvalidTransition),
    }
}

#[cfg(test)]
mod tunnel_domain_tests {
    use std::collections::BTreeSet;

    use super::{
        transition_tunnel_state, tunnel_requires_local_port_check, validate_tunnel_profile,
        TunnelError, TunnelKind, TunnelProfile, TunnelState,
    };

    #[test]
    fn accepts_local_remote_and_dynamic_tunnels() {
        for kind in [TunnelKind::Local, TunnelKind::Remote, TunnelKind::Dynamic] {
            let profile = TunnelProfile {
                id: "tun_1".to_string(),
                kind,
                local_host: "127.0.0.1".to_string(),
                local_port: 8080,
                remote_host: "127.0.0.1".to_string(),
                remote_port: 80,
            };

            validate_tunnel_profile(profile).expect("valid tunnel");
        }
    }

    #[test]
    fn dynamic_tunnel_validation_does_not_require_remote_target() {
        let profile = TunnelProfile {
            id: "tun_dynamic".to_string(),
            kind: TunnelKind::Dynamic,
            local_host: "127.0.0.1".to_string(),
            local_port: 1080,
            remote_host: "".to_string(),
            remote_port: 0,
        };

        validate_tunnel_profile(profile).expect("dynamic target comes from SOCKS client");
    }

    #[test]
    fn rejects_invalid_ports() {
        let profile = TunnelProfile {
            id: "tun_1".to_string(),
            kind: TunnelKind::Local,
            local_host: "127.0.0.1".to_string(),
            local_port: 0,
            remote_host: "127.0.0.1".to_string(),
            remote_port: 80,
        };

        let error = validate_tunnel_profile(profile).expect_err("invalid port");

        assert_eq!(error, TunnelError::InvalidPort);
    }

    #[test]
    fn rejects_blank_hosts() {
        for (local_host, remote_host) in [("   ", "127.0.0.1"), ("127.0.0.1", "\n\t")] {
            let profile = TunnelProfile {
                id: "tun_1".to_string(),
                kind: TunnelKind::Local,
                local_host: local_host.to_string(),
                local_port: 8080,
                remote_host: remote_host.to_string(),
                remote_port: 80,
            };

            let error = validate_tunnel_profile(profile).expect_err("blank tunnel host");

            assert_eq!(error, TunnelError::InvalidPort);
        }
    }

    #[test]
    fn rejects_embedded_host_separators() {
        for (local_host, remote_host) in [
            ("127.0.0.1\n0.0.0.0", "db.internal"),
            ("127.0.0.1", "db.internal backup.internal"),
        ] {
            let profile = TunnelProfile {
                id: "tun_1".to_string(),
                kind: TunnelKind::Local,
                local_host: local_host.to_string(),
                local_port: 8080,
                remote_host: remote_host.to_string(),
                remote_port: 80,
            };

            let error = validate_tunnel_profile(profile).expect_err("unsafe tunnel host");

            assert_eq!(error, TunnelError::InvalidPort);
        }
    }

    #[test]
    fn rejects_control_characters_in_hosts() {
        for (local_host, remote_host) in [
            ("127.0.0.1\u{1b}[31m", "db.internal"),
            ("127.0.0.1", "db.internal\0backup"),
        ] {
            let profile = TunnelProfile {
                id: "tun_1".to_string(),
                kind: TunnelKind::Local,
                local_host: local_host.to_string(),
                local_port: 8080,
                remote_host: remote_host.to_string(),
                remote_port: 80,
            };

            let error = validate_tunnel_profile(profile).expect_err("unsafe tunnel host");

            assert_eq!(error, TunnelError::InvalidPort);
        }
    }

    #[test]
    fn maps_port_in_use_error() {
        assert_eq!(
            TunnelError::LocalPortInUse.code(),
            "TUNNEL_LOCAL_PORT_IN_USE"
        );
    }

    #[test]
    fn tunnel_error_codes_are_stable_and_unique() {
        let current_codes = [
            TunnelError::InvalidPort.code(),
            TunnelError::LocalPortInUse.code(),
            TunnelError::SshFailed.code(),
            TunnelError::InvalidTransition.code(),
        ];
        let unique_codes = current_codes.iter().collect::<BTreeSet<_>>();

        assert_eq!(unique_codes.len(), current_codes.len());
        assert_eq!(
            current_codes,
            [
                "TUNNEL_INVALID_PORT".to_string(),
                "TUNNEL_LOCAL_PORT_IN_USE".to_string(),
                "TUNNEL_SSH_FAILED".to_string(),
                "TUNNEL_INVALID_TRANSITION".to_string(),
            ]
        );
    }

    #[test]
    fn errors_use_chinese_user_facing_messages() {
        assert_eq!(TunnelError::InvalidPort.to_string(), "隧道端口无效");
        assert_eq!(TunnelError::LocalPortInUse.to_string(), "本地端口已被占用");
        assert_eq!(TunnelError::SshFailed.to_string(), "SSH 隧道失败");
        assert_eq!(
            TunnelError::InvalidTransition.to_string(),
            "隧道状态转换无效"
        );
    }

    #[test]
    fn transitions_lifecycle_states() {
        let starting = transition_tunnel_state(TunnelState::Stopped, "start").expect("start");
        let running = transition_tunnel_state(starting, "ready").expect("ready");
        let stopped = transition_tunnel_state(running, "stop").expect("stop");

        assert_eq!(stopped, TunnelState::Stopped);
    }

    #[test]
    fn only_local_and_dynamic_tunnels_require_local_port_check() {
        let mut profile = TunnelProfile {
            id: "tun_1".to_string(),
            kind: TunnelKind::Local,
            local_host: "127.0.0.1".to_string(),
            local_port: 8080,
            remote_host: "127.0.0.1".to_string(),
            remote_port: 80,
        };

        assert!(tunnel_requires_local_port_check(&profile));

        profile.kind = TunnelKind::Dynamic;
        assert!(tunnel_requires_local_port_check(&profile));

        profile.kind = TunnelKind::Remote;
        assert!(!tunnel_requires_local_port_check(&profile));
    }
}
