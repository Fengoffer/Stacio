use crate::domain::tunnel::{
    transition_tunnel_state, tunnel_requires_local_port_check, validate_tunnel_profile,
    TunnelError, TunnelProfile, TunnelState,
};
use std::collections::BTreeMap;
use std::net::TcpListener;
use std::sync::{Condvar, Mutex};
use std::time::Duration;

pub const DEFAULT_TUNNEL_AUTOMATIC_RECONNECT_ATTEMPTS: usize = 10;

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct TunnelRuntimeStatus {
    pub profile_id: String,
    pub state: TunnelState,
    pub message: String,
}

pub trait TunnelChannel {
    fn start(&self, profile: &TunnelProfile) -> Result<(), TunnelError>;
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct TunnelRuntimeTick {
    pub accepted_connections: usize,
    pub active_connections: usize,
    pub client_to_remote_bytes: u64,
    pub remote_to_client_bytes: u64,
}

impl TunnelRuntimeTick {
    fn summary(&self) -> String {
        format!(
            "running accepted={} active={} client_to_remote_bytes={} remote_to_client_bytes={}",
            self.accepted_connections,
            self.active_connections,
            self.client_to_remote_bytes,
            self.remote_to_client_bytes
        )
    }
}

pub trait ManagedTunnelWorker {
    fn poll_once(&mut self) -> Result<TunnelRuntimeTick, TunnelError>;
}

struct ManagedTunnel<W> {
    profile: TunnelProfile,
    worker: W,
}

struct PendingTunnelReconnect {
    profile_id: String,
    attempt: usize,
    max_attempts: usize,
    last_error: TunnelError,
}

impl PendingTunnelReconnect {
    fn status(&self) -> TunnelRuntimeStatus {
        TunnelRuntimeStatus {
            profile_id: self.profile_id.clone(),
            state: TunnelState::Starting,
            message: format!(
                "reconnecting attempt={} max_attempts={} last_error={}",
                self.attempt, self.max_attempts, self.last_error
            ),
        }
    }
}

pub struct TunnelRuntimeManager<W: ManagedTunnelWorker> {
    workers: BTreeMap<String, ManagedTunnel<W>>,
    reconnecting: BTreeMap<String, PendingTunnelReconnect>,
    max_automatic_reconnect_attempts: usize,
}

impl<W: ManagedTunnelWorker> TunnelRuntimeManager<W> {
    pub fn new() -> Self {
        Self {
            workers: BTreeMap::new(),
            reconnecting: BTreeMap::new(),
            max_automatic_reconnect_attempts: DEFAULT_TUNNEL_AUTOMATIC_RECONNECT_ATTEMPTS,
        }
    }

    pub fn set_max_automatic_reconnect_attempts(&mut self, max_attempts: usize) {
        self.max_automatic_reconnect_attempts = max_attempts;
    }

    pub fn active_count(&self) -> usize {
        self.workers.len()
    }

    pub fn active_profile_ids(&self) -> Vec<String> {
        self.workers.keys().cloned().collect()
    }

    pub fn has_active_profile(&self, profile_id: &str) -> bool {
        self.workers.contains_key(profile_id)
    }

    pub fn register(&mut self, profile: TunnelProfile, worker: W) -> TunnelRuntimeStatus {
        let profile_id = profile.id.clone();
        if self.has_active_profile(&profile_id) {
            return Self::running_status(profile_id);
        }
        self.reconnecting.remove(&profile_id);
        self.workers
            .insert(profile_id.clone(), ManagedTunnel { profile, worker });
        Self::running_status(profile_id)
    }

    fn running_status(profile_id: String) -> TunnelRuntimeStatus {
        TunnelRuntimeStatus {
            profile_id,
            state: TunnelState::Running,
            message: "running".to_string(),
        }
    }

    pub fn poll(&mut self, profile_id: String) -> Result<TunnelRuntimeStatus, TunnelError> {
        let Some(managed) = self.workers.get_mut(&profile_id) else {
            if let Some(pending) = self.reconnecting.get(&profile_id) {
                return Ok(pending.status());
            }
            return Ok(TunnelRuntimeStatus {
                profile_id,
                state: TunnelState::Stopped,
                message: "not_running".to_string(),
            });
        };

        match managed.worker.poll_once() {
            Ok(tick) => Ok(TunnelRuntimeStatus {
                profile_id,
                state: TunnelState::Running,
                message: tick.summary(),
            }),
            Err(error) => {
                let profile_id = managed.profile.id.clone();
                self.workers.remove(&profile_id);
                if self.max_automatic_reconnect_attempts > 0 {
                    let pending = PendingTunnelReconnect {
                        profile_id: profile_id.clone(),
                        attempt: 1,
                        max_attempts: self.max_automatic_reconnect_attempts,
                        last_error: error,
                    };
                    let status = pending.status();
                    self.reconnecting.insert(profile_id, pending);
                    return Ok(status);
                }
                Ok(TunnelRuntimeStatus {
                    profile_id,
                    state: TunnelState::Failed,
                    message: error.to_string(),
                })
            }
        }
    }

    pub fn poll_all(&mut self) -> Result<Vec<TunnelRuntimeStatus>, TunnelError> {
        let profile_ids = self.active_profile_ids();
        let mut statuses = Vec::with_capacity(profile_ids.len());
        for profile_id in profile_ids {
            statuses.push(self.poll(profile_id)?);
        }
        Ok(statuses)
    }

    pub fn stop(&mut self, profile_id: String) -> Result<TunnelRuntimeStatus, TunnelError> {
        self.workers.remove(&profile_id);
        self.reconnecting.remove(&profile_id);
        Ok(TunnelRuntimeStatus {
            profile_id,
            state: TunnelState::Stopped,
            message: "stopped".to_string(),
        })
    }
}

pub struct TunnelPumpSignal {
    marker: Mutex<u64>,
    changed: Condvar,
}

impl TunnelPumpSignal {
    pub fn new() -> Self {
        Self {
            marker: Mutex::new(0),
            changed: Condvar::new(),
        }
    }

    pub fn marker(&self) -> u64 {
        *self.marker.lock().expect("tunnel pump marker lock")
    }

    pub fn notify(&self) -> u64 {
        let mut marker = self.marker.lock().expect("tunnel pump marker lock");
        *marker = marker.saturating_add(1);
        let observed = *marker;
        self.changed.notify_all();
        observed
    }

    pub fn wait_for_next_tick(
        &self,
        observed_marker: u64,
        has_active_workers: bool,
        active_wait: Duration,
    ) -> u64 {
        let mut marker = self.marker.lock().expect("tunnel pump marker lock");
        if *marker != observed_marker {
            return *marker;
        }

        if has_active_workers {
            let (guard, _) = self
                .changed
                .wait_timeout_while(marker, active_wait, |current| *current == observed_marker)
                .expect("tunnel pump condvar wait");
            return *guard;
        }

        while *marker == observed_marker {
            marker = self.changed.wait(marker).expect("tunnel pump condvar wait");
        }
        *marker
    }
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Enum)]
pub enum MockTunnelOutcome {
    Started,
    LocalPortInUse,
    SshFailed,
}

pub struct MockTunnelChannel {
    outcome: MockTunnelOutcome,
}

impl MockTunnelChannel {
    pub fn new(outcome: MockTunnelOutcome) -> Self {
        Self { outcome }
    }
}

impl TunnelChannel for MockTunnelChannel {
    fn start(&self, _profile: &TunnelProfile) -> Result<(), TunnelError> {
        match self.outcome {
            MockTunnelOutcome::Started => Ok(()),
            MockTunnelOutcome::LocalPortInUse => Err(TunnelError::LocalPortInUse),
            MockTunnelOutcome::SshFailed => Err(TunnelError::SshFailed),
        }
    }
}

pub fn start_tunnel<C: TunnelChannel>(
    profile: TunnelProfile,
    channel: &C,
) -> Result<TunnelRuntimeStatus, TunnelError> {
    validate_tunnel_profile(profile.clone())?;
    let starting = transition_tunnel_state(TunnelState::Stopped, "start")?;
    channel.start(&profile)?;
    let running = transition_tunnel_state(starting, "ready")?;

    Ok(TunnelRuntimeStatus {
        profile_id: profile.id,
        state: running,
        message: "running".to_string(),
    })
}

pub fn start_managed_tunnel_worker<W, F>(
    manager: &mut TunnelRuntimeManager<W>,
    profile: TunnelProfile,
    open_worker: F,
) -> Result<TunnelRuntimeStatus, TunnelError>
where
    W: ManagedTunnelWorker,
    F: FnOnce(&TunnelProfile) -> Result<W, TunnelError>,
{
    validate_tunnel_profile(profile.clone())?;
    if manager.has_active_profile(&profile.id) {
        return Ok(TunnelRuntimeStatus {
            profile_id: profile.id,
            state: TunnelState::Running,
            message: "running".to_string(),
        });
    }
    check_tunnel_local_port_available(profile.clone())?;
    let worker = open_worker(&profile)?;
    Ok(manager.register(profile, worker))
}

pub fn stop_tunnel(state: TunnelState) -> Result<TunnelState, TunnelError> {
    transition_tunnel_state(state, "stop")
}

pub fn check_tunnel_local_port_available(profile: TunnelProfile) -> Result<(), TunnelError> {
    validate_tunnel_profile(profile.clone())?;
    if !tunnel_requires_local_port_check(&profile) {
        return Ok(());
    }

    TcpListener::bind((profile.local_host.as_str(), profile.local_port))
        .map(|_| ())
        .map_err(|_| TunnelError::LocalPortInUse)
}

#[cfg(test)]
mod tunnel_port_preflight_tests {
    use super::check_tunnel_local_port_available;
    use crate::domain::tunnel::{TunnelError, TunnelKind, TunnelProfile};
    use std::net::TcpListener;

    fn profile(kind: TunnelKind, local_port: u16) -> TunnelProfile {
        TunnelProfile {
            id: "tun_preflight".to_string(),
            kind,
            local_host: "127.0.0.1".to_string(),
            local_port,
            remote_host: "127.0.0.1".to_string(),
            remote_port: 5432,
        }
    }

    #[test]
    fn reports_local_port_in_use_for_local_tunnel() {
        let listener = TcpListener::bind(("127.0.0.1", 0)).expect("bind fixture port");
        let port = listener.local_addr().expect("fixture address").port();

        let error = check_tunnel_local_port_available(profile(TunnelKind::Local, port))
            .expect_err("port in use");

        assert_eq!(error, TunnelError::LocalPortInUse);
    }

    #[test]
    fn skips_local_port_preflight_for_remote_tunnel() {
        let listener = TcpListener::bind(("127.0.0.1", 0)).expect("bind fixture port");
        let port = listener.local_addr().expect("fixture address").port();

        check_tunnel_local_port_available(profile(TunnelKind::Remote, port))
            .expect("remote tunnel does not bind local listener");
    }

    #[test]
    fn accepts_available_dynamic_tunnel_port() {
        let listener = TcpListener::bind(("127.0.0.1", 0)).expect("bind fixture port");
        let port = listener.local_addr().expect("fixture address").port();
        drop(listener);

        check_tunnel_local_port_available(profile(TunnelKind::Dynamic, port))
            .expect("available local port");
    }
}

#[cfg(test)]
mod tunnel_runtime_manager_tests {
    use super::{
        start_managed_tunnel_worker, ManagedTunnelWorker, TunnelRuntimeManager, TunnelRuntimeTick,
    };
    use crate::domain::tunnel::{TunnelError, TunnelKind, TunnelProfile, TunnelState};
    use std::cell::RefCell;
    use std::collections::VecDeque;
    use std::net::TcpListener;
    use std::sync::{Arc, Barrier};
    use std::time::{Duration, Instant};

    #[test]
    fn manager_registers_worker_and_polls_runtime_tick() {
        let mut manager = TunnelRuntimeManager::new();
        let status = manager.register(
            profile(),
            FakeManagedTunnelWorker::with_ticks(vec![TunnelRuntimeTick {
                accepted_connections: 1,
                active_connections: 1,
                client_to_remote_bytes: 12,
                remote_to_client_bytes: 8,
            }]),
        );

        let polled = manager
            .poll("tun_runtime".to_string())
            .expect("poll tunnel");

        assert_eq!(status.state, TunnelState::Running);
        assert_eq!(polled.state, TunnelState::Running);
        assert_eq!(manager.active_count(), 1);
        assert!(polled.message.contains("accepted=1"));
        assert!(polled.message.contains("active=1"));
        assert!(polled.message.contains("client_to_remote_bytes=12"));
        assert!(polled.message.contains("remote_to_client_bytes=8"));
    }

    #[test]
    fn manager_stop_removes_worker_and_returns_stopped_status() {
        let mut manager = TunnelRuntimeManager::new();
        manager.register(profile(), FakeManagedTunnelWorker::new());

        let status = manager
            .stop("tun_runtime".to_string())
            .expect("stop tunnel");

        assert_eq!(status.profile_id, "tun_runtime");
        assert_eq!(status.state, TunnelState::Stopped);
        assert_eq!(status.message, "stopped");
        assert_eq!(manager.active_count(), 0);
    }

    #[test]
    fn manager_poll_failure_marks_runtime_reconnecting_and_removes_worker() {
        let mut manager = TunnelRuntimeManager::new();
        manager.register(
            profile(),
            FakeManagedTunnelWorker::with_errors(vec![TunnelError::SshFailed]),
        );

        let status = manager
            .poll("tun_runtime".to_string())
            .expect("failed status is reportable");

        assert_eq!(status.profile_id, "tun_runtime");
        assert_eq!(status.state, TunnelState::Starting);
        assert!(status.message.contains("reconnecting attempt=1"));
        assert!(status.message.contains("max_attempts=10"));
        assert!(status.message.contains("SSH 隧道失败"));
        assert_eq!(manager.active_count(), 0);

        let pending = manager
            .poll("tun_runtime".to_string())
            .expect("pending reconnect status is reportable");
        assert_eq!(pending.state, TunnelState::Starting);
        assert!(pending.message.contains("reconnecting attempt=1"));
    }

    #[test]
    fn manager_stop_after_poll_failure_clears_pending_reconnect() {
        let mut manager = TunnelRuntimeManager::new();
        manager.register(
            profile(),
            FakeManagedTunnelWorker::with_errors(vec![TunnelError::SshFailed]),
        );
        let failed = manager
            .poll("tun_runtime".to_string())
            .expect("failed poll schedules reconnect");
        assert_eq!(failed.state, TunnelState::Starting);

        let stopped = manager
            .stop("tun_runtime".to_string())
            .expect("manual stop clears reconnect");
        let polled_after_stop = manager
            .poll("tun_runtime".to_string())
            .expect("poll stopped tunnel");

        assert_eq!(stopped.state, TunnelState::Stopped);
        assert_eq!(polled_after_stop.state, TunnelState::Stopped);
        assert_eq!(polled_after_stop.message, "not_running");
    }

    #[test]
    fn manager_poll_failure_respects_configured_zero_automatic_retries() {
        let mut manager = TunnelRuntimeManager::new();
        manager.set_max_automatic_reconnect_attempts(0);
        manager.register(
            profile(),
            FakeManagedTunnelWorker::with_errors(vec![TunnelError::SshFailed]),
        );

        let status = manager
            .poll("tun_runtime".to_string())
            .expect("failed status is reportable");

        assert_eq!(status.profile_id, "tun_runtime");
        assert_eq!(status.state, TunnelState::Failed);
        assert_eq!(status.message, "SSH 隧道失败");
        assert_eq!(manager.active_count(), 0);
    }

    #[test]
    fn manager_poll_all_drives_workers_and_removes_failed_tunnels() {
        let mut manager = TunnelRuntimeManager::new();
        let mut first = profile();
        first.id = "tun_first".to_string();
        let mut second = profile();
        second.id = "tun_second".to_string();
        manager.register(
            first,
            FakeManagedTunnelWorker::with_ticks(vec![TunnelRuntimeTick {
                accepted_connections: 1,
                active_connections: 1,
                client_to_remote_bytes: 4,
                remote_to_client_bytes: 2,
            }]),
        );
        manager.register(
            second,
            FakeManagedTunnelWorker::with_errors(vec![TunnelError::SshFailed]),
        );

        let statuses = manager.poll_all().expect("poll all tunnels");

        assert_eq!(statuses.len(), 2);
        assert!(
            statuses
                .iter()
                .any(|status| status.profile_id == "tun_first"
                    && status.state == TunnelState::Running)
        );
        assert!(statuses
            .iter()
            .any(|status| status.profile_id == "tun_second"
                && status.state == TunnelState::Starting
                && status.message.contains("reconnecting attempt=1")));
        assert_eq!(manager.active_profile_ids(), vec!["tun_first".to_string()]);
    }

    #[test]
    fn pump_signal_wakes_inactive_waiters_without_timeout_polling() {
        let signal = Arc::new(super::TunnelPumpSignal::new());
        let marker = signal.marker();
        let ready = Arc::new(Barrier::new(2));
        let waiter_signal = Arc::clone(&signal);
        let waiter_ready = Arc::clone(&ready);
        let waiter = std::thread::spawn(move || {
            waiter_ready.wait();
            let started_at = Instant::now();
            let observed = waiter_signal.wait_for_next_tick(marker, false, Duration::from_secs(60));
            (observed, started_at.elapsed())
        });

        ready.wait();
        std::thread::sleep(Duration::from_millis(10));
        signal.notify();
        let (observed, elapsed) = waiter.join().expect("waiter thread");

        assert!(observed > marker);
        assert!(elapsed < Duration::from_millis(500));
    }

    #[test]
    fn pump_signal_uses_bounded_wait_when_workers_are_active() {
        let signal = super::TunnelPumpSignal::new();
        let marker = signal.marker();
        let started_at = Instant::now();

        let observed = signal.wait_for_next_tick(marker, true, Duration::from_millis(10));

        assert_eq!(observed, marker);
        assert!(started_at.elapsed() >= Duration::from_millis(10));
    }

    #[test]
    fn start_managed_worker_registers_after_preflight_and_open_success() {
        let mut manager = TunnelRuntimeManager::new();

        let status = start_managed_tunnel_worker(&mut manager, profile(), |_profile| {
            Ok(FakeManagedTunnelWorker::with_ticks(vec![
                TunnelRuntimeTick {
                    accepted_connections: 0,
                    active_connections: 0,
                    client_to_remote_bytes: 0,
                    remote_to_client_bytes: 0,
                },
            ]))
        })
        .expect("start tunnel worker");

        assert_eq!(status.profile_id, "tun_runtime");
        assert_eq!(status.state, TunnelState::Running);
        assert_eq!(manager.active_count(), 1);
    }

    #[test]
    fn start_managed_worker_ignores_duplicate_active_profile_without_replacing_worker() {
        let mut manager = TunnelRuntimeManager::new();
        manager.register(
            remote_profile(),
            FakeManagedTunnelWorker::with_ticks(vec![TunnelRuntimeTick {
                accepted_connections: 1,
                active_connections: 1,
                client_to_remote_bytes: 12,
                remote_to_client_bytes: 8,
            }]),
        );
        let opened_profiles = RefCell::new(Vec::new());

        let status = start_managed_tunnel_worker(&mut manager, remote_profile(), |profile| {
            opened_profiles.borrow_mut().push(profile.id.clone());
            Ok(FakeManagedTunnelWorker::with_ticks(vec![
                TunnelRuntimeTick {
                    accepted_connections: 99,
                    active_connections: 99,
                    client_to_remote_bytes: 99,
                    remote_to_client_bytes: 99,
                },
            ]))
        })
        .expect("duplicate active tunnel start is idempotent");
        let polled = manager
            .poll("tun_runtime".to_string())
            .expect("poll original worker");

        assert_eq!(status.profile_id, "tun_runtime");
        assert_eq!(status.state, TunnelState::Running);
        assert_eq!(opened_profiles.into_inner(), Vec::<String>::new());
        assert_eq!(manager.active_count(), 1);
        assert!(polled.message.contains("accepted=1"));
        assert!(polled.message.contains("client_to_remote_bytes=12"));
    }

    #[test]
    fn start_managed_worker_does_not_register_after_open_failure() {
        let mut manager: TunnelRuntimeManager<FakeManagedTunnelWorker> =
            TunnelRuntimeManager::new();
        let opened_profiles = RefCell::new(Vec::new());

        let error = start_managed_tunnel_worker(&mut manager, remote_profile(), |profile| {
            opened_profiles.borrow_mut().push(profile.id.clone());
            Err(TunnelError::SshFailed)
        })
        .expect_err("open failure");

        assert_eq!(error, TunnelError::SshFailed);
        assert_eq!(
            opened_profiles.into_inner(),
            vec!["tun_runtime".to_string()]
        );
        assert_eq!(manager.active_count(), 0);
    }

    fn profile() -> TunnelProfile {
        let listener = TcpListener::bind(("127.0.0.1", 0)).expect("bind fixture port");
        let local_port = listener.local_addr().expect("fixture address").port();
        drop(listener);

        TunnelProfile {
            id: "tun_runtime".to_string(),
            kind: TunnelKind::Local,
            local_host: "127.0.0.1".to_string(),
            local_port,
            remote_host: "db.internal".to_string(),
            remote_port: 5432,
        }
    }

    fn remote_profile() -> TunnelProfile {
        TunnelProfile {
            id: "tun_runtime".to_string(),
            kind: TunnelKind::Remote,
            local_host: "127.0.0.1".to_string(),
            local_port: 15432,
            remote_host: "db.internal".to_string(),
            remote_port: 5432,
        }
    }

    struct FakeManagedTunnelWorker {
        ticks: VecDeque<TunnelRuntimeTick>,
        errors: VecDeque<TunnelError>,
    }

    impl FakeManagedTunnelWorker {
        fn new() -> Self {
            Self {
                ticks: VecDeque::new(),
                errors: VecDeque::new(),
            }
        }

        fn with_ticks(ticks: Vec<TunnelRuntimeTick>) -> Self {
            Self {
                ticks: ticks.into(),
                errors: VecDeque::new(),
            }
        }

        fn with_errors(errors: Vec<TunnelError>) -> Self {
            Self {
                ticks: VecDeque::new(),
                errors: errors.into(),
            }
        }
    }

    impl ManagedTunnelWorker for FakeManagedTunnelWorker {
        fn poll_once(&mut self) -> Result<TunnelRuntimeTick, TunnelError> {
            if let Some(error) = self.errors.pop_front() {
                return Err(error);
            }
            Ok(self.ticks.pop_front().unwrap_or_default())
        }
    }
}
