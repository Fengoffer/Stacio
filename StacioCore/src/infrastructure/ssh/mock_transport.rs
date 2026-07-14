#[cfg(test)]
mod ssh_transport_tests {
    use crate::domain::ssh::{
        fingerprint_sha256, HostKeyRecord, SshAuthMethod, SshConnectionConfig, SshRuntimeError,
    };
    use crate::services::ssh_service::{connect_with_transport, MockSshOutcome, MockSshTransport};

    fn config() -> SshConnectionConfig {
        SshConnectionConfig {
            host: "example.com".to_string(),
            port: 22,
            username: "deploy".to_string(),
            auth_method: SshAuthMethod::Agent,
            connect_timeout_ms: 10_000,
        }
    }

    #[test]
    fn maps_successful_connection_to_status() {
        let known_hosts = vec![HostKeyRecord {
            host: "example.com".to_string(),
            port: 22,
            fingerprint_sha256: fingerprint_sha256(b"host-key"),
        }];
        let transport = MockSshTransport::new(MockSshOutcome::Connected {
            host_key: b"host-key".to_vec(),
        });

        let status = connect_with_transport(config(), &known_hosts, &transport).expect("connect");

        assert!(status.connected);
        assert_eq!(status.host, "example.com");
        assert_eq!(status.auth_method, "agent");
        assert!(!status.diagnostic.contains("secret"));
    }

    #[test]
    fn maps_auth_failure() {
        let transport = MockSshTransport::new(MockSshOutcome::AuthFailed);

        let error = connect_with_transport(config(), &[], &transport).expect_err("auth failure");

        assert_eq!(error, SshRuntimeError::AuthFailed);
    }

    #[test]
    fn maps_timeout() {
        let transport = MockSshTransport::new(MockSshOutcome::Timeout);

        let error = connect_with_transport(config(), &[], &transport).expect_err("timeout");

        assert_eq!(error, SshRuntimeError::Timeout);
    }

    #[test]
    fn maps_host_key_changed() {
        let known_hosts = vec![HostKeyRecord {
            host: "example.com".to_string(),
            port: 22,
            fingerprint_sha256: fingerprint_sha256(b"old-key"),
        }];
        let transport = MockSshTransport::new(MockSshOutcome::Connected {
            host_key: b"new-key".to_vec(),
        });

        let error =
            connect_with_transport(config(), &known_hosts, &transport).expect_err("changed key");

        assert_eq!(error, SshRuntimeError::HostKeyChanged);
    }
}
