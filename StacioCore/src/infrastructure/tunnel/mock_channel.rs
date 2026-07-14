#[cfg(test)]
mod tunnel_channel_tests {
    use crate::domain::tunnel::{TunnelError, TunnelKind, TunnelProfile, TunnelState};
    use crate::services::tunnel_service::{
        start_tunnel, stop_tunnel, MockTunnelChannel, MockTunnelOutcome,
    };

    fn profile() -> TunnelProfile {
        TunnelProfile {
            id: "tun_1".to_string(),
            kind: TunnelKind::Local,
            local_host: "127.0.0.1".to_string(),
            local_port: 8080,
            remote_host: "127.0.0.1".to_string(),
            remote_port: 80,
        }
    }

    #[test]
    fn starts_tunnel_successfully() {
        let channel = MockTunnelChannel::new(MockTunnelOutcome::Started);

        let status = start_tunnel(profile(), &channel).expect("start");

        assert_eq!(status.state, TunnelState::Running);
        assert_eq!(status.profile_id, "tun_1");
    }

    #[test]
    fn maps_local_port_in_use() {
        let channel = MockTunnelChannel::new(MockTunnelOutcome::LocalPortInUse);

        let error = start_tunnel(profile(), &channel).expect_err("port in use");

        assert_eq!(error, TunnelError::LocalPortInUse);
    }

    #[test]
    fn maps_ssh_failure() {
        let channel = MockTunnelChannel::new(MockTunnelOutcome::SshFailed);

        let error = start_tunnel(profile(), &channel).expect_err("ssh failed");

        assert_eq!(error, TunnelError::SshFailed);
    }

    #[test]
    fn stops_running_tunnel() {
        let state = stop_tunnel(TunnelState::Running).expect("stop");

        assert_eq!(state, TunnelState::Stopped);
    }
}
