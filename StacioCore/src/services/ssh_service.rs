use crate::domain::ssh::{
    fingerprint_sha256, redact_ssh_diagnostic, validate_ssh_config, verify_host_key, HostKeyRecord,
    HostKeyTrustDecision, HostKeyVerification, SshConnectionConfig, SshConnectionStatus,
    SshProxyJumpRuntimeConfig, SshRuntimeError,
};

pub trait SshTransport {
    fn connect(&self, config: &SshConnectionConfig) -> Result<Vec<u8>, SshRuntimeError>;
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SshConnectionRoute {
    Direct,
    ProxyJump(SshProxyJumpRuntimeConfig),
}

pub trait SshRouteTransport {
    fn connect_direct(&self, config: &SshConnectionConfig) -> Result<Vec<u8>, SshRuntimeError>;

    fn connect_via_proxy_jump(
        &self,
        target_config: &SshConnectionConfig,
        proxy_jump: &SshProxyJumpRuntimeConfig,
    ) -> Result<Vec<u8>, SshRuntimeError>;
}

pub trait KnownHostStore {
    fn find_known_host(
        &self,
        host: &str,
        port: u16,
    ) -> Result<Option<HostKeyRecord>, SshRuntimeError>;

    fn save_known_host(&self, record: HostKeyRecord) -> Result<(), SshRuntimeError>;
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MockSshOutcome {
    Connected { host_key: Vec<u8> },
    AuthFailed,
    Timeout,
    TransportError { message: String },
}

pub struct MockSshTransport {
    outcome: MockSshOutcome,
}

impl MockSshTransport {
    pub fn new(outcome: MockSshOutcome) -> Self {
        Self { outcome }
    }
}

impl SshTransport for MockSshTransport {
    fn connect(&self, _config: &SshConnectionConfig) -> Result<Vec<u8>, SshRuntimeError> {
        match &self.outcome {
            MockSshOutcome::Connected { host_key } => Ok(host_key.clone()),
            MockSshOutcome::AuthFailed => Err(SshRuntimeError::AuthFailed),
            MockSshOutcome::Timeout => Err(SshRuntimeError::Timeout),
            MockSshOutcome::TransportError { message } => Err(SshRuntimeError::Transport {
                message: redact_ssh_diagnostic(message),
            }),
        }
    }
}

impl SshRouteTransport for MockSshTransport {
    fn connect_direct(&self, config: &SshConnectionConfig) -> Result<Vec<u8>, SshRuntimeError> {
        self.connect(config)
    }

    fn connect_via_proxy_jump(
        &self,
        _target_config: &SshConnectionConfig,
        _proxy_jump: &SshProxyJumpRuntimeConfig,
    ) -> Result<Vec<u8>, SshRuntimeError> {
        match &self.outcome {
            MockSshOutcome::Connected { host_key } => Ok(host_key.clone()),
            MockSshOutcome::AuthFailed => Err(SshRuntimeError::AuthFailed),
            MockSshOutcome::Timeout => Err(SshRuntimeError::Timeout),
            MockSshOutcome::TransportError { message } => Err(SshRuntimeError::Transport {
                message: redact_ssh_diagnostic(message),
            }),
        }
    }
}

pub fn connect_with_transport<T: SshTransport>(
    config: SshConnectionConfig,
    known_hosts: &[HostKeyRecord],
    transport: &T,
) -> Result<SshConnectionStatus, SshRuntimeError> {
    validate_ssh_config(config.clone())?;
    let host_key = transport.connect(&config)?;
    match verify_host_key(&config.host, config.port, &host_key, known_hosts)? {
        HostKeyVerification::Trusted => Ok(SshConnectionStatus {
            connected: true,
            host: config.host,
            port: config.port,
            username: config.username,
            auth_method: config.auth_method.label(),
            diagnostic: "connected".to_string(),
        }),
        HostKeyVerification::Unknown { fingerprint } => Err(SshRuntimeError::Transport {
            message: format!("unknown host key {fingerprint}"),
        }),
    }
}

pub fn connect_with_route_transport<T: SshRouteTransport>(
    config: SshConnectionConfig,
    known_hosts: &[HostKeyRecord],
    route: SshConnectionRoute,
    transport: &T,
) -> Result<SshConnectionStatus, SshRuntimeError> {
    validate_ssh_config(config.clone())?;
    let host_key = match &route {
        SshConnectionRoute::Direct => transport.connect_direct(&config),
        SshConnectionRoute::ProxyJump(proxy_jump) => {
            validate_ssh_config(proxy_jump.jump_config.clone())?;
            transport.connect_via_proxy_jump(&config, proxy_jump)
        }
    }?;
    match verify_host_key(&config.host, config.port, &host_key, known_hosts)? {
        HostKeyVerification::Trusted => Ok(SshConnectionStatus {
            connected: true,
            host: config.host,
            port: config.port,
            username: config.username,
            auth_method: config.auth_method.label(),
            diagnostic: "connected".to_string(),
        }),
        HostKeyVerification::Unknown { fingerprint } => Err(SshRuntimeError::Transport {
            message: format!("unknown host key {fingerprint}"),
        }),
    }
}

pub fn apply_host_key_decision<S: KnownHostStore>(
    host: &str,
    port: u16,
    host_key: &[u8],
    decision: HostKeyTrustDecision,
    store: &S,
) -> Result<HostKeyVerification, SshRuntimeError> {
    let fingerprint = fingerprint_sha256(host_key);
    let known = store.find_known_host(host, port)?;

    if let Some(record) = known {
        if record.fingerprint_sha256 == fingerprint {
            return Ok(HostKeyVerification::Trusted);
        }
        if decision != HostKeyTrustDecision::TrustAndSave {
            return Err(SshRuntimeError::HostKeyChanged);
        }
    } else if decision == HostKeyTrustDecision::Reject {
        return Err(SshRuntimeError::UnknownHostKey);
    }

    if decision == HostKeyTrustDecision::TrustAndSave {
        store.save_known_host(HostKeyRecord {
            host: host.to_string(),
            port,
            fingerprint_sha256: fingerprint,
        })?;
    }

    Ok(HostKeyVerification::Trusted)
}

#[cfg(test)]
mod host_key_decision_service_tests {
    use std::cell::RefCell;

    use crate::domain::ssh::{
        fingerprint_sha256, HostKeyRecord, HostKeyTrustDecision, HostKeyVerification,
        SshAuthMethod, SshAuthSecret, SshConnectionConfig, SshProxyJumpRuntimeConfig,
        SshRuntimeError,
    };

    use super::{
        apply_host_key_decision, connect_with_route_transport, KnownHostStore, SshConnectionRoute,
        SshRouteTransport,
    };

    #[derive(Default)]
    struct MemoryKnownHostStore {
        records: RefCell<Vec<HostKeyRecord>>,
    }

    impl KnownHostStore for MemoryKnownHostStore {
        fn find_known_host(
            &self,
            host: &str,
            port: u16,
        ) -> Result<Option<HostKeyRecord>, SshRuntimeError> {
            Ok(self
                .records
                .borrow()
                .iter()
                .find(|record| record.host == host && record.port == port)
                .cloned())
        }

        fn save_known_host(&self, record: HostKeyRecord) -> Result<(), SshRuntimeError> {
            let mut records = self.records.borrow_mut();
            records.retain(|current| current.host != record.host || current.port != record.port);
            records.push(record);
            Ok(())
        }
    }

    #[test]
    fn trust_once_allows_unknown_key_without_persisting() {
        let store = MemoryKnownHostStore::default();

        let verification = apply_host_key_decision(
            "example.com",
            22,
            b"host-key",
            HostKeyTrustDecision::TrustOnce,
            &store,
        )
        .expect("trust once");

        assert_eq!(verification, HostKeyVerification::Trusted);
        assert!(store.records.borrow().is_empty());
    }

    #[test]
    fn trust_and_save_persists_unknown_key() {
        let store = MemoryKnownHostStore::default();

        let verification = apply_host_key_decision(
            "example.com",
            22,
            b"host-key",
            HostKeyTrustDecision::TrustAndSave,
            &store,
        )
        .expect("trust and save");

        assert_eq!(verification, HostKeyVerification::Trusted);
        assert_eq!(store.records.borrow().len(), 1);
        assert_eq!(
            store.records.borrow()[0].fingerprint_sha256,
            fingerprint_sha256(b"host-key")
        );
    }

    #[test]
    fn reject_unknown_key_blocks_connection() {
        let store = MemoryKnownHostStore::default();

        let error = apply_host_key_decision(
            "example.com",
            22,
            b"host-key",
            HostKeyTrustDecision::Reject,
            &store,
        )
        .expect_err("reject");

        assert_eq!(error, SshRuntimeError::UnknownHostKey);
    }

    #[test]
    fn trust_and_save_replaces_changed_key() {
        let store = MemoryKnownHostStore::default();
        store
            .save_known_host(HostKeyRecord {
                host: "example.com".to_string(),
                port: 22,
                fingerprint_sha256: fingerprint_sha256(b"old-key"),
            })
            .expect("seed old");

        let verification = apply_host_key_decision(
            "example.com",
            22,
            b"new-key",
            HostKeyTrustDecision::TrustAndSave,
            &store,
        )
        .expect("trust changed");

        assert_eq!(verification, HostKeyVerification::Trusted);
        assert_eq!(
            store.records.borrow()[0].fingerprint_sha256,
            fingerprint_sha256(b"new-key")
        );
    }

    #[test]
    fn trust_once_rejects_changed_key_without_replacing_saved_key() {
        let store = MemoryKnownHostStore::default();
        let old_fingerprint = fingerprint_sha256(b"old-key");
        store
            .save_known_host(HostKeyRecord {
                host: "example.com".to_string(),
                port: 22,
                fingerprint_sha256: old_fingerprint.clone(),
            })
            .expect("seed old");

        let error = apply_host_key_decision(
            "example.com",
            22,
            b"new-key",
            HostKeyTrustDecision::TrustOnce,
            &store,
        )
        .expect_err("trust once cannot bypass changed key");

        assert_eq!(error, SshRuntimeError::HostKeyChanged);
        assert_eq!(
            store.records.borrow()[0].fingerprint_sha256,
            old_fingerprint
        );
    }

    #[derive(Default)]
    struct RecordingRouteTransport {
        events: RefCell<Vec<String>>,
        host_key: Vec<u8>,
    }

    impl RecordingRouteTransport {
        fn with_host_key(host_key: &[u8]) -> Self {
            Self {
                events: RefCell::new(Vec::new()),
                host_key: host_key.to_vec(),
            }
        }
    }

    impl SshRouteTransport for RecordingRouteTransport {
        fn connect_direct(&self, config: &SshConnectionConfig) -> Result<Vec<u8>, SshRuntimeError> {
            self.events
                .borrow_mut()
                .push(format!("direct:{}:{}", config.host, config.port));
            Ok(self.host_key.clone())
        }

        fn connect_via_proxy_jump(
            &self,
            target_config: &SshConnectionConfig,
            proxy_jump: &SshProxyJumpRuntimeConfig,
        ) -> Result<Vec<u8>, SshRuntimeError> {
            self.events.borrow_mut().push(format!(
                "proxy:{}:{}->{}:{}",
                proxy_jump.jump_config.host,
                proxy_jump.jump_config.port,
                target_config.host,
                target_config.port
            ));
            Ok(self.host_key.clone())
        }
    }

    fn route_target_config() -> SshConnectionConfig {
        SshConnectionConfig {
            host: "app.internal".to_string(),
            port: 22,
            username: "deploy".to_string(),
            auth_method: SshAuthMethod::Agent,
            connect_timeout_ms: 10_000,
        }
    }

    fn route_proxy_jump_config() -> SshProxyJumpRuntimeConfig {
        SshProxyJumpRuntimeConfig {
            jump_config: SshConnectionConfig {
                host: "bastion.example.com".to_string(),
                port: 2222,
                username: "ops".to_string(),
                auth_method: SshAuthMethod::Password {
                    credential_ref: "jump-credential".to_string(),
                },
                connect_timeout_ms: 10_000,
            },
            jump_secret: SshAuthSecret::Password {
                value: "jump-secret".to_string(),
            },
            jump_expected_fingerprint_sha256: fingerprint_sha256(b"jump-key"),
            target_expected_fingerprint_sha256: fingerprint_sha256(b"target-key"),
        }
    }

    #[test]
    fn route_transport_uses_direct_path_when_proxy_jump_is_absent() {
        let target = route_target_config();
        let transport = RecordingRouteTransport::with_host_key(b"target-key");
        let known_hosts = vec![HostKeyRecord {
            host: target.host.clone(),
            port: target.port,
            fingerprint_sha256: fingerprint_sha256(b"target-key"),
        }];

        let status = connect_with_route_transport(
            target,
            &known_hosts,
            SshConnectionRoute::Direct,
            &transport,
        )
        .expect("direct route");

        assert!(status.connected);
        assert_eq!(
            transport.events.borrow().as_slice(),
            ["direct:app.internal:22"]
        );
    }

    #[test]
    fn route_transport_uses_proxy_jump_path_when_configured() {
        let target = route_target_config();
        let transport = RecordingRouteTransport::with_host_key(b"target-key");
        let known_hosts = vec![HostKeyRecord {
            host: target.host.clone(),
            port: target.port,
            fingerprint_sha256: fingerprint_sha256(b"target-key"),
        }];

        let status = connect_with_route_transport(
            target,
            &known_hosts,
            SshConnectionRoute::ProxyJump(route_proxy_jump_config()),
            &transport,
        )
        .expect("proxy jump route");

        assert!(status.connected);
        assert_eq!(
            transport.events.borrow().as_slice(),
            ["proxy:bastion.example.com:2222->app.internal:22"]
        );
    }

    #[test]
    fn route_transport_direct_and_proxy_jump_paths_do_not_interfere() {
        let direct = RecordingRouteTransport::with_host_key(b"target-key");
        let proxy = RecordingRouteTransport::with_host_key(b"target-key");
        let target = route_target_config();
        let known_hosts = vec![HostKeyRecord {
            host: target.host.clone(),
            port: target.port,
            fingerprint_sha256: fingerprint_sha256(b"target-key"),
        }];

        let _ = connect_with_route_transport(
            target.clone(),
            &known_hosts,
            SshConnectionRoute::Direct,
            &direct,
        )
        .expect("direct route");
        let _ = connect_with_route_transport(
            target,
            &known_hosts,
            SshConnectionRoute::ProxyJump(route_proxy_jump_config()),
            &proxy,
        )
        .expect("proxy route");

        assert_eq!(
            direct.events.borrow().as_slice(),
            ["direct:app.internal:22"]
        );
        assert_eq!(
            proxy.events.borrow().as_slice(),
            ["proxy:bastion.example.com:2222->app.internal:22"]
        );
    }
}
