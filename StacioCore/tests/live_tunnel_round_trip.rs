use stacio_core::domain::ssh::{SshAuthMethod, SshAuthSecret, SshConnectionConfig};
use stacio_core::domain::tunnel::{TunnelKind, TunnelProfile, TunnelState};
use stacio_core::{
    close_live_tunnel_runtime, poll_live_tunnel_runtime, probe_live_ssh_host_key,
    start_live_local_tunnel_runtime,
};
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::PathBuf;
use std::time::Duration;

// Run against the disposable loopback sshd fixture, never a production host.
#[test]
#[ignore = "requires STACIO_TUNNEL_FIXTURE_DIR with a loopback sshd, port and client key"]
fn live_remote_tunnel_survives_idle_and_forwards_bytes() {
    let (config, secret, fingerprint) = fixture_context("port");
    let target = TcpListener::bind("127.0.0.1:0").unwrap();
    let reserved = TcpListener::bind("127.0.0.1:0").unwrap();
    let profile = TunnelProfile {
        id: "loopback_remote_round_trip".into(),
        kind: TunnelKind::Remote,
        local_host: "127.0.0.1".into(),
        local_port: target.local_addr().unwrap().port(),
        remote_host: "127.0.0.1".into(),
        remote_port: reserved.local_addr().unwrap().port(),
    };
    drop(reserved);
    let start = start_live_local_tunnel_runtime(config, secret, fingerprint, profile.clone())
        .expect("start real remote listener");
    assert_eq!(start.state, TunnelState::Running);
    let result = std::panic::catch_unwind(|| {
        std::thread::sleep(Duration::from_millis(150));
        assert_eq!(
            poll_live_tunnel_runtime(profile.id.clone()).unwrap().state,
            TunnelState::Running,
            "empty remote accept queue must not stop the listener"
        );
        let mut client = TcpStream::connect(("127.0.0.1", profile.remote_port)).unwrap();
        client
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        client.write_all(b"forward-request").unwrap();
        target.set_nonblocking(true).unwrap();
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        let mut local = loop {
            match target.accept() {
                Ok((s, _)) => break s,
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    assert!(
                        std::time::Instant::now() < deadline,
                        "forwarded connection never arrived"
                    );
                    std::thread::sleep(Duration::from_millis(10));
                }
                Err(e) => panic!("local accept failed: {e}"),
            }
        };
        local
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        let mut request = [0; 15];
        local.read_exact(&mut request).unwrap();
        assert_eq!(&request, b"forward-request");
        local.write_all(b"forward-response").unwrap();
        let mut response = [0; 16];
        client.read_exact(&mut response).unwrap();
        assert_eq!(&response, b"forward-response");
    });
    close_live_tunnel_runtime(profile.id).unwrap();
    if let Err(error) = result {
        std::panic::resume_unwind(error);
    }
}

fn fixture_context(port_file: &str) -> (SshConnectionConfig, SshAuthSecret, String) {
    let fixture = PathBuf::from(std::env::var("STACIO_TUNNEL_FIXTURE_DIR").unwrap());
    let config = SshConnectionConfig {
        host: "127.0.0.1".into(),
        port: std::fs::read_to_string(fixture.join(port_file))
            .unwrap()
            .trim()
            .parse()
            .unwrap(),
        username: std::env::var("USER").unwrap(),
        auth_method: SshAuthMethod::PrivateKey {
            key_path: fixture.join("client").to_string_lossy().into_owned(),
            passphrase_ref: None,
        },
        connect_timeout_ms: 3000,
    };
    let secret = SshAuthSecret::PrivateKey {
        private_key_pem: std::fs::read_to_string(fixture.join("client")).unwrap(),
        passphrase: None,
    };
    let fingerprint = probe_live_ssh_host_key(config.clone())
        .unwrap()
        .fingerprint_sha256;
    (config, secret, fingerprint)
}

fn assert_remote_request_denied(error: stacio_core::domain::ssh::SshRuntimeError) {
    match error {
        stacio_core::domain::ssh::SshRuntimeError::Transport { message } => {
            assert!(
                message.starts_with("SSH_REMOTE_FORWARD_FAILED:"),
                "{message}"
            );
            assert!(message.contains("Session(-32)"), "{message}");
            assert!(
                message.contains("Unable to complete request for forward-listen"),
                "{message}"
            );
        }
        other => panic!("remote rejection was collapsed to an unrelated error: {other:?}"),
    }
}

#[test]
#[ignore = "run with scripts/test-live-tunnels.py"]
fn live_remote_tunnel_reports_occupied_port_and_can_retry_after_release() {
    let (config, secret, fingerprint) = fixture_context("port");
    let occupied = TcpListener::bind("127.0.0.1:0").unwrap();
    let profile = TunnelProfile {
        id: "loopback_remote_occupied".into(),
        kind: TunnelKind::Remote,
        local_host: "127.0.0.1".into(),
        local_port: 8088,
        remote_host: "127.0.0.1".into(),
        remote_port: occupied.local_addr().unwrap().port(),
    };
    assert_remote_request_denied(
        start_live_local_tunnel_runtime(
            config.clone(),
            secret.clone(),
            fingerprint.clone(),
            profile.clone(),
        )
        .unwrap_err(),
    );
    assert_eq!(
        poll_live_tunnel_runtime(profile.id.clone()).unwrap().state,
        TunnelState::Stopped
    );
    drop(occupied);
    let status =
        start_live_local_tunnel_runtime(config, secret, fingerprint, profile.clone()).unwrap();
    close_live_tunnel_runtime(profile.id).unwrap();
    assert_eq!(status.state, TunnelState::Running);
}

#[test]
#[ignore = "run with scripts/test-live-tunnels.py"]
fn live_remote_tunnel_reports_server_policy_rejection_with_same_error() {
    let (config, secret, fingerprint) = fixture_context("denied-port");
    let reserved = TcpListener::bind("127.0.0.1:0").unwrap();
    let profile = TunnelProfile {
        id: "loopback_remote_denied".into(),
        kind: TunnelKind::Remote,
        local_host: "127.0.0.1".into(),
        local_port: 8088,
        remote_host: "127.0.0.1".into(),
        remote_port: reserved.local_addr().unwrap().port(),
    };
    drop(reserved);
    assert_remote_request_denied(
        start_live_local_tunnel_runtime(config, secret, fingerprint, profile.clone()).unwrap_err(),
    );
    assert_eq!(
        poll_live_tunnel_runtime(profile.id).unwrap().state,
        TunnelState::Stopped
    );
}
