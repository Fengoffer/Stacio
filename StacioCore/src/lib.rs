pub mod domain;
pub mod infrastructure;
pub mod services;
pub mod telemetry;

#[cfg(unix)]
use std::os::fd::RawFd;
use std::{
    collections::{HashMap, HashSet},
    io,
    path::{Path, PathBuf},
    sync::{Arc, Mutex, OnceLock},
    thread,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use rusqlite::Connection;

pub use domain::agent::AIConversationHistoryItemDraft;
pub use domain::macro_recording::{MacroRecording, MacroStep};
use domain::{
    agent::{AgentActionAuditEvent, AgentTaskProposalDraft, AgentTaskSessionDraft},
    credential::{CredentialDraft, CredentialRecord},
    device_metrics::DeviceMetricsSnapshot,
    diagnostics::{DiagnosticBundle, DiagnosticEntry},
    files::{parse_remote_listing as parse_remote_listing_target, FilesError, RemoteFileEntry},
    ftp::{validate_ftp_config as validate_ftp_config_target, FtpAuthSecret, FtpConnectionConfig},
    multiexec::{MultiExecError, MultiExecTarget},
    scp::{
        resolve_conflict_path as resolve_scp_conflict_path_target, ScpConflictPolicy,
        ScpResumeOptions, ScpTransferError, ScpTransferJob, ScpTransferProgress,
    },
    serial::{validate_serial_config as validate_serial_config_target, SerialConnectionConfig},
    session::{
        parse_quick_connect as parse_quick_connect_target, QuickConnectTarget, SessionDraft,
        SessionError, SessionFolder, SessionRecord, SessionSidebarOrderItem,
        SessionSidebarSnapshot, SessionUpdate,
    },
    ssh::{
        fingerprint_sha256 as fingerprint_sha256_target, redact_ssh_diagnostic,
        validate_proxy_jump_runtime_config as validate_proxy_jump_runtime_config_target,
        validate_ssh_config as validate_ssh_config_target,
        verify_host_key as verify_host_key_target, HostKeyRecord, HostKeyTrustDecision,
        HostKeyVerification, LiveSshHostKey, LiveSshSessionInfo, RemoteOperatingSystemInfo,
        SshAuthSecret, SshConnectionConfig, SshConnectionStatus, SshProxyJumpRuntimeConfig,
        SshRuntimeError,
    },
    telnet::{validate_telnet_config as validate_telnet_config_target, TelnetConnectionConfig},
    terminal::{TerminalInputBatch, TerminalOutputBatch, TerminalRuntime, TerminalRuntimeError},
    tunnel::{
        validate_tunnel_profile as validate_tunnel_profile_target, TunnelError, TunnelKind,
        TunnelProfile, TunnelProfileRecord, TunnelState,
    },
};
use infrastructure::{
    agent_audit_repository::{AgentActionAuditRecord, AgentActionAuditRepository},
    agent_task_repository::{AgentTaskRepository, AgentTaskSessionRecord},
    ai_conversation_history_repository::{
        AIConversationHistoryItemRecord, AIConversationHistoryRepository,
    },
    audit_repository::{AuditEventRepository, BroadcastAuditRecord},
    credential_repository::CredentialRepository,
    db::apply_migrations,
    files::{
        ftp_control::FtpControlClient,
        libssh2_exec_listing::{Libssh2ExecListing, RemoteFileOperation},
    },
    import_repository::ImportReportRepository,
    known_host_repository::KnownHostRepository,
    scp::libssh2_engine::Libssh2ScpEngine,
    serial::SerialShellChannel,
    session_repository::SessionRepository,
    ssh::libssh2_transport::{
        Libssh2ShellChannel, Libssh2ShellRequest, Libssh2Transport, SshSecret,
    },
    telnet::TelnetShellChannel,
    terminal_macro_repository::{
        TerminalMacroRecord, TerminalMacroRepository, TerminalMacroRepositoryError,
    },
    transfer_repository::{TransferEventRecord, TransferJobRecord, TransferRepository},
    tunnel::libssh2_channel::{
        DynamicSocksTunnelWorker, Libssh2DirectTcpIpOpener, Libssh2RemoteForwardListener,
        LocalTunnelWorker, RemoteTunnelWorker, TcpTunnelClientAcceptor, TcpTunnelTargetConnector,
    },
    tunnel_repository::TunnelRepository,
};
use services::scp_service::{
    cancel_live_scp_transfer as cancel_live_scp_transfer_target, is_live_scp_transfer_cancelled,
    run_scp_transfer,
    take_live_scp_transfer_progress_batch as take_live_scp_transfer_progress_batch_target,
    with_live_scp_transfer_cancellation_scope, MockScpEngine, MockScpOutcome,
};
use services::ssh_service::apply_host_key_decision;
use services::{
    agent_service::validate_agent_action_audit_event,
    device_metrics_service::{build_device_metrics_probe_command, parse_device_metrics_probe},
    diagnostics_service::build_diagnostic_bundle as build_diagnostic_bundle_target,
    graphics_service::{
        build_vnc_launch_config as build_vnc_launch_config_target,
        diagnose_x11 as diagnose_x11_target,
        x11_forwarding_arguments as x11_forwarding_arguments_target, GraphicsAdapterConfig,
        GraphicsConfigError, GraphicsDiagnostic, GraphicsLaunchConfig, X11ProbeInput,
    },
    import_service::{
        preview_csv_import as preview_csv_import_target,
        preview_legacy_ini_import as preview_legacy_ini_import_target,
        preview_stacio_json_import as preview_stacio_json_import_target, ImportApplyResult,
        ImportPreview, ImportReport, ImportSessionPreview,
    },
    live_shell_service::{
        ssh_osc7_bootstrap_input_chunks, LiveShellManager, LiveShellPumpSignal, LiveShellStatus,
        LiveShellWorker, ShellChannel, ShellWaitInterest,
    },
    macro_service::{
        playback_macro_steps as playback_macro_steps_target,
        serialize_macro_recording as serialize_macro_recording_target, MacroError,
    },
    multiexec_service::{
        mark_broadcast_executed as mark_broadcast_executed_target,
        prepare_broadcast_input as prepare_broadcast_input_target, BroadcastAuditEvent,
    },
    os_probe_service::{build_remote_os_probe_command, parse_remote_os_probe},
    terminal_service::TerminalRuntimeRegistry,
    tunnel_service::{
        check_tunnel_local_port_available as check_tunnel_local_port_available_target,
        start_managed_tunnel_worker, start_tunnel as start_tunnel_target,
        stop_tunnel as stop_tunnel_target, MockTunnelChannel, MockTunnelOutcome, TunnelPumpSignal,
        TunnelRuntimeManager, TunnelRuntimeStatus,
    },
};

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CoreHealth {
    pub ok: bool,
    pub app: String,
    pub version: String,
    pub architecture: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ScpTransferJobRecord {
    pub job: ScpTransferJob,
    pub session_id: Option<String>,
    pub status: String,
    pub bytes_done: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ScpTransferEventRecord {
    pub id: String,
    pub job_id: String,
    pub event_type: String,
    pub message: Option<String>,
    pub bytes_done: Option<u64>,
    pub created_at: String,
}

#[uniffi::export]
pub fn health() -> CoreHealth {
    CoreHealth {
        ok: true,
        app: "Stacio".to_string(),
        version: env!("CARGO_PKG_VERSION").to_string(),
        architecture: "swift-appkit-rust-core".to_string(),
    }
}

fn terminal_registry() -> &'static Mutex<TerminalRuntimeRegistry> {
    static REGISTRY: OnceLock<Mutex<TerminalRuntimeRegistry>> = OnceLock::new();
    REGISTRY.get_or_init(|| Mutex::new(TerminalRuntimeRegistry::new(64 * 1024)))
}

fn live_ssh_session_infos() -> &'static Mutex<HashMap<String, LiveSshSessionInfo>> {
    static INFOS: OnceLock<Mutex<HashMap<String, LiveSshSessionInfo>>> = OnceLock::new();
    INFOS.get_or_init(|| Mutex::new(HashMap::new()))
}

fn recover_global_lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|error| error.into_inner())
}

enum LiveShellChannel {
    Ssh(Libssh2ShellChannel),
    Telnet(TelnetShellChannel),
    Serial(SerialShellChannel),
}

impl ShellChannel for LiveShellChannel {
    fn write_input(&mut self, bytes: &[u8]) -> io::Result<usize> {
        match self {
            LiveShellChannel::Ssh(channel) => channel.write_input(bytes),
            LiveShellChannel::Telnet(channel) => channel.write_input(bytes),
            LiveShellChannel::Serial(channel) => channel.write_input(bytes),
        }
    }

    fn read_output(&mut self, max_bytes: usize) -> io::Result<Vec<u8>> {
        match self {
            LiveShellChannel::Ssh(channel) => channel.read_output(max_bytes),
            LiveShellChannel::Telnet(channel) => channel.read_output(max_bytes),
            LiveShellChannel::Serial(channel) => channel.read_output(max_bytes),
        }
    }

    fn resize_pty(&mut self, cols: u32, rows: u32) -> io::Result<()> {
        match self {
            LiveShellChannel::Ssh(channel) => channel.resize_pty(cols, rows),
            LiveShellChannel::Telnet(channel) => channel.resize_pty(cols, rows),
            LiveShellChannel::Serial(channel) => channel.resize_pty(cols, rows),
        }
    }

    fn close(&mut self) -> io::Result<()> {
        match self {
            LiveShellChannel::Ssh(channel) => channel.close(),
            LiveShellChannel::Telnet(channel) => channel.close(),
            LiveShellChannel::Serial(channel) => channel.close(),
        }
    }

    fn is_eof(&self) -> bool {
        match self {
            LiveShellChannel::Ssh(channel) => channel.is_eof(),
            LiveShellChannel::Telnet(channel) => channel.is_eof(),
            LiveShellChannel::Serial(channel) => channel.is_eof(),
        }
    }

    fn wait_interest(&self) -> Option<ShellWaitInterest> {
        match self {
            LiveShellChannel::Ssh(channel) => channel.wait_interest(),
            LiveShellChannel::Telnet(channel) => channel.wait_interest(),
            LiveShellChannel::Serial(channel) => channel.wait_interest(),
        }
    }

    fn keepalive(&mut self) -> io::Result<()> {
        match self {
            LiveShellChannel::Ssh(channel) => channel.keepalive(),
            LiveShellChannel::Telnet(_) | LiveShellChannel::Serial(_) => Ok(()),
        }
    }
}

fn live_shell_manager() -> &'static Mutex<LiveShellManager<LiveShellChannel>> {
    static MANAGER: OnceLock<Mutex<LiveShellManager<LiveShellChannel>>> = OnceLock::new();
    MANAGER.get_or_init(|| Mutex::new(LiveShellManager::new()))
}

enum LiveTunnelWorker {
    Local(LocalTunnelWorker<TcpTunnelClientAcceptor, Libssh2DirectTcpIpOpener>),
    Dynamic(DynamicSocksTunnelWorker<TcpTunnelClientAcceptor, Libssh2DirectTcpIpOpener>),
    Remote(RemoteTunnelWorker<Libssh2RemoteForwardListener, TcpTunnelTargetConnector>),
}

impl services::tunnel_service::ManagedTunnelWorker for LiveTunnelWorker {
    fn poll_once(&mut self) -> Result<services::tunnel_service::TunnelRuntimeTick, TunnelError> {
        match self {
            LiveTunnelWorker::Local(worker) => {
                services::tunnel_service::ManagedTunnelWorker::poll_once(worker)
            }
            LiveTunnelWorker::Dynamic(worker) => {
                services::tunnel_service::ManagedTunnelWorker::poll_once(worker)
            }
            LiveTunnelWorker::Remote(worker) => {
                services::tunnel_service::ManagedTunnelWorker::poll_once(worker)
            }
        }
    }
}

fn live_tunnel_manager() -> &'static Mutex<TunnelRuntimeManager<LiveTunnelWorker>> {
    static MANAGER: OnceLock<Mutex<TunnelRuntimeManager<LiveTunnelWorker>>> = OnceLock::new();
    MANAGER.get_or_init(|| Mutex::new(TunnelRuntimeManager::new()))
}

fn live_tunnel_pump_signal() -> &'static Arc<TunnelPumpSignal> {
    static SIGNAL: OnceLock<Arc<TunnelPumpSignal>> = OnceLock::new();
    SIGNAL.get_or_init(|| Arc::new(TunnelPumpSignal::new()))
}

fn live_shell_pump_signal() -> &'static Arc<LiveShellPumpSignal> {
    static SIGNAL: OnceLock<Arc<LiveShellPumpSignal>> = OnceLock::new();
    SIGNAL.get_or_init(|| Arc::new(LiveShellPumpSignal::new()))
}

#[cfg(unix)]
fn live_shell_wake_pipe() -> &'static LiveShellWakePipe {
    static WAKE_PIPE: OnceLock<LiveShellWakePipe> = OnceLock::new();
    WAKE_PIPE.get_or_init(|| LiveShellWakePipe::new().expect("create live shell wake pipe"))
}

#[cfg(unix)]
struct LiveShellWakePipe {
    read_fd: RawFd,
    write_fd: RawFd,
}

#[cfg(unix)]
impl LiveShellWakePipe {
    fn new() -> io::Result<Self> {
        let mut fds = [0; 2];
        let result = unsafe { libc::pipe(fds.as_mut_ptr()) };
        if result != 0 {
            return Err(io::Error::last_os_error());
        }
        for fd in fds {
            let fd_flags = unsafe { libc::fcntl(fd, libc::F_GETFD, 0) };
            if fd_flags >= 0 {
                let _ = unsafe { libc::fcntl(fd, libc::F_SETFD, fd_flags | libc::FD_CLOEXEC) };
            }
            let flags = unsafe { libc::fcntl(fd, libc::F_GETFL, 0) };
            if flags >= 0 {
                let _ = unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) };
            }
        }
        Ok(Self {
            read_fd: fds[0],
            write_fd: fds[1],
        })
    }

    fn interest(&self) -> ShellWaitInterest {
        ShellWaitInterest::readable(self.read_fd)
    }

    fn wake(&self) {
        let byte = [1_u8];
        let _ = unsafe { libc::write(self.write_fd, byte.as_ptr().cast(), byte.len()) };
    }

    fn drain(&self) {
        let mut buffer = [0_u8; 64];
        loop {
            let read = unsafe {
                libc::read(
                    self.read_fd,
                    buffer.as_mut_ptr().cast(),
                    buffer.len() as libc::size_t,
                )
            };
            if read <= 0 || read < buffer.len() as isize {
                break;
            }
        }
    }
}

fn notify_live_shell_pump() {
    live_shell_pump_signal().notify();
    #[cfg(unix)]
    live_shell_wake_pipe().wake();
}

fn notify_live_tunnel_pump() {
    live_tunnel_pump_signal().notify();
}

fn start_live_tunnel_pump_if_needed() {
    static PUMP: OnceLock<()> = OnceLock::new();
    PUMP.get_or_init(|| {
        let signal = Arc::clone(live_tunnel_pump_signal());
        thread::Builder::new()
            .name("stacio-live-tunnel-pump".to_string())
            .spawn(move || {
                run_live_tunnel_pump(signal);
            })
            .expect("start live tunnel pump thread");
    });
}

fn run_live_tunnel_pump(signal: Arc<TunnelPumpSignal>) {
    let mut marker = signal.marker();
    loop {
        let has_active_workers = pump_live_tunnels_once();
        marker = signal.wait_for_next_tick(marker, has_active_workers, Duration::from_millis(25));
    }
}

fn pump_live_tunnels_once() -> bool {
    let mut manager = recover_global_lock(live_tunnel_manager());
    if manager.active_count() == 0 {
        return false;
    }
    let _ = manager.poll_all();
    manager.active_count() > 0
}

fn start_live_shell_pump_if_needed() {
    static PUMP: OnceLock<()> = OnceLock::new();
    PUMP.get_or_init(|| {
        let signal = Arc::clone(live_shell_pump_signal());
        thread::Builder::new()
            .name("stacio-live-shell-pump".to_string())
            .spawn(move || {
                run_live_shell_pump(signal);
            })
            .expect("start live shell pump thread");
    });
}

fn register_connected_live_shell(
    runtime: TerminalRuntime,
    channel: LiveShellChannel,
    bootstrap_input: Option<Vec<u8>>,
) -> Result<LiveShellStatus, SshRuntimeError> {
    let runtime_id = runtime.id.clone();
    let registry = recover_global_lock(terminal_registry());
    let snapshot = registry
        .runtime_snapshot(runtime_id.clone())
        .map_err(|error| SshRuntimeError::Transport {
            message: redact_ssh_diagnostic(&error.to_string()),
        })?;
    if snapshot.status == "closed" {
        return Err(SshRuntimeError::Transport {
            message: "connection cancelled".to_string(),
        });
    }

    let worker = match bootstrap_input {
        Some(input) => {
            LiveShellWorker::new_with_bootstrap_input(runtime_id.clone(), channel, input)
        }
        None => LiveShellWorker::new(runtime_id.clone(), channel),
    };
    recover_global_lock(live_shell_manager()).register(worker);
    drop(registry);
    notify_live_shell_pump();
    Ok(LiveShellStatus::running(runtime_id))
}

fn close_failed_live_shell_runtime(runtime_id: String) {
    let _ = recover_global_lock(terminal_registry()).close(runtime_id);
}

fn run_live_shell_pump(signal: Arc<LiveShellPumpSignal>) {
    let mut marker = signal.marker();
    loop {
        let wait_state = pump_live_shells_once();
        marker =
            wait_for_live_shell_activity(&signal, marker, wait_state, Duration::from_millis(50));
    }
}

struct LiveShellPumpWaitState {
    has_active_workers: bool,
    has_pending_input: bool,
    wait_interests: Vec<ShellWaitInterest>,
}

fn pump_live_shells_once() -> LiveShellPumpWaitState {
    let mut registry = recover_global_lock(terminal_registry());
    let mut manager = recover_global_lock(live_shell_manager());
    if manager.active_count() == 0 {
        return LiveShellPumpWaitState {
            has_active_workers: false,
            has_pending_input: false,
            wait_interests: Vec::new(),
        };
    }

    let statuses = manager.poll_all(&mut registry);
    if let Err(error) = statuses {
        for runtime_id in manager.active_runtime_ids() {
            let _ = registry.record_output(
                runtime_id.clone(),
                format!("Stacio live shell pump error: {error}\n").into_bytes(),
            );
            let _ = manager.close(&mut registry, runtime_id);
        }
    }
    LiveShellPumpWaitState {
        has_active_workers: manager.active_count() > 0,
        has_pending_input: manager.has_pending_input(),
        wait_interests: manager.wait_interests(),
    }
}

fn wait_for_live_shell_activity(
    signal: &LiveShellPumpSignal,
    marker: u64,
    wait_state: LiveShellPumpWaitState,
    fallback_wait: Duration,
) -> u64 {
    if !wait_state.has_active_workers {
        return signal.wait_for_next_tick(marker, false, fallback_wait);
    }
    if wait_state.has_pending_input {
        thread::sleep(Duration::from_millis(1));
        return marker;
    }
    if wait_state.wait_interests.is_empty() {
        return signal.wait_for_next_tick(marker, true, fallback_wait);
    }

    let observed = wait_for_shell_wait_interests(wait_state.wait_interests, fallback_wait);
    if observed {
        marker
    } else {
        signal.wait_for_next_tick(marker, true, fallback_wait)
    }
}

#[cfg(unix)]
fn wait_for_shell_wait_interests(
    mut wait_interests: Vec<ShellWaitInterest>,
    fallback_wait: Duration,
) -> bool {
    wait_interests.push(live_shell_wake_pipe().interest());
    let mut fds = wait_interests
        .into_iter()
        .map(|interest| {
            let mut events = 0;
            if interest.readable {
                events |= libc::POLLIN;
            }
            if interest.writable {
                events |= libc::POLLOUT;
            }
            libc::pollfd {
                fd: interest.raw_fd,
                events,
                revents: 0,
            }
        })
        .collect::<Vec<_>>();
    if fds.is_empty() {
        return false;
    }

    let result = unsafe { libc::poll(fds.as_mut_ptr(), fds.len() as libc::nfds_t, -1) };
    live_shell_wake_pipe().drain();
    if result < 0 {
        thread::sleep(fallback_wait);
    }
    result > 0
}

#[cfg(not(unix))]
fn wait_for_shell_wait_interests(
    _wait_interests: Vec<ShellWaitInterest>,
    fallback_wait: Duration,
) -> bool {
    thread::sleep(fallback_wait);
    false
}

#[uniffi::export]
pub fn open_local_shell_runtime(shell_path: String, cols: u32, rows: u32) -> TerminalRuntime {
    recover_global_lock(terminal_registry()).open_local_shell(shell_path, cols, rows)
}

#[uniffi::export]
pub fn open_remote_ssh_runtime(
    host: String,
    port: u16,
    username: String,
    cols: u32,
    rows: u32,
) -> TerminalRuntime {
    recover_global_lock(terminal_registry()).open_remote_ssh(host, port, username, cols, rows)
}

#[uniffi::export]
pub fn record_terminal_resize(
    runtime_id: String,
    cols: u32,
    rows: u32,
) -> Result<TerminalRuntime, TerminalRuntimeError> {
    let runtime = recover_global_lock(terminal_registry()).record_resize(runtime_id, cols, rows)?;
    notify_live_shell_pump();
    Ok(runtime)
}

#[uniffi::export]
pub fn record_terminal_output(
    runtime_id: String,
    bytes: Vec<u8>,
) -> Result<(), TerminalRuntimeError> {
    recover_global_lock(terminal_registry()).record_output(runtime_id, bytes)
}

#[uniffi::export]
pub fn write_terminal_input(
    runtime_id: String,
    bytes: Vec<u8>,
) -> Result<(), TerminalRuntimeError> {
    recover_global_lock(terminal_registry()).write_input(runtime_id, bytes)?;
    notify_live_shell_pump();
    Ok(())
}

#[uniffi::export]
pub fn take_terminal_input_batch(
    runtime_id: String,
) -> Result<TerminalInputBatch, TerminalRuntimeError> {
    recover_global_lock(terminal_registry()).take_input_batch(runtime_id)
}

#[uniffi::export]
pub fn take_terminal_output_batch(
    runtime_id: String,
) -> Result<TerminalOutputBatch, TerminalRuntimeError> {
    recover_global_lock(terminal_registry()).take_output_batch(runtime_id)
}

#[uniffi::export]
pub fn set_terminal_output_paused(
    runtime_id: String,
    paused: bool,
) -> Result<TerminalRuntime, TerminalRuntimeError> {
    recover_global_lock(terminal_registry()).set_output_paused(runtime_id, paused)
}

#[uniffi::export]
pub fn close_terminal_runtime(runtime_id: String) -> Result<TerminalRuntime, TerminalRuntimeError> {
    recover_global_lock(terminal_registry()).close(runtime_id)
}

#[uniffi::export]
pub fn poll_live_ssh_shell(runtime_id: String) -> Result<LiveShellStatus, TerminalRuntimeError> {
    let mut registry = recover_global_lock(terminal_registry());
    let mut manager = recover_global_lock(live_shell_manager());
    let status = if manager.active_runtime_ids().contains(&runtime_id) {
        manager.poll(&mut registry, runtime_id.clone())?
    } else {
        let snapshot = registry.runtime_snapshot(runtime_id.clone())?;
        if snapshot.status == "closed" {
            LiveShellStatus {
                runtime_id: runtime_id.clone(),
                status: "closed".to_string(),
                diagnostic: "closed".to_string(),
            }
        } else {
            LiveShellStatus::not_running(runtime_id.clone())
        }
    };
    if status.status != "running" {
        recover_global_lock(live_ssh_session_infos()).remove(&runtime_id);
    }
    Ok(status)
}

#[uniffi::export]
pub fn set_live_shell_keepalive_interval(
    runtime_id: String,
    seconds: u32,
) -> Result<(), TerminalRuntimeError> {
    recover_global_lock(live_shell_manager())
        .set_keepalive_interval_seconds(&runtime_id, seconds.clamp(0, 600))?;
    notify_live_shell_pump();
    Ok(())
}

#[uniffi::export]
pub fn close_live_ssh_shell(runtime_id: String) -> Result<LiveShellStatus, TerminalRuntimeError> {
    let mut registry = recover_global_lock(terminal_registry());
    let status =
        recover_global_lock(live_shell_manager()).close(&mut registry, runtime_id.clone())?;
    recover_global_lock(live_ssh_session_infos()).remove(&runtime_id);
    notify_live_shell_pump();
    Ok(status)
}

#[uniffi::export]
pub fn live_ssh_session_info(runtime_id: String) -> Option<LiveSshSessionInfo> {
    recover_global_lock(live_ssh_session_infos())
        .get(&runtime_id)
        .cloned()
}

#[uniffi::export]
pub fn parse_quick_connect(input: String) -> Result<QuickConnectTarget, SessionError> {
    parse_quick_connect_target(&input)
}

#[uniffi::export]
pub fn preview_csv_import(
    input: String,
    existing_session_names: Vec<String>,
) -> Result<ImportPreview, SessionError> {
    preview_csv_import_target(&input, existing_session_names)
}

#[uniffi::export]
pub fn preview_legacy_ini_import(
    input: String,
    existing_session_names: Vec<String>,
) -> Result<ImportPreview, SessionError> {
    preview_legacy_ini_import_target(&input, existing_session_names)
}

#[uniffi::export]
pub fn preview_stacio_json_import(
    input: String,
    existing_session_names: Vec<String>,
) -> Result<ImportPreview, SessionError> {
    preview_stacio_json_import_target(&input, existing_session_names)
}

#[uniffi::export]
pub fn create_session_folder(
    database_path: String,
    parent_id: Option<String>,
    name: String,
) -> Result<SessionFolder, SessionError> {
    let repository = session_repository_for_path(database_path)?;
    repository.create_folder(parent_id, &name)
}

#[uniffi::export]
pub fn rename_session_folder(
    database_path: String,
    id: String,
    name: String,
) -> Result<SessionFolder, SessionError> {
    let repository = session_repository_for_path(database_path)?;
    repository.rename_folder(id, &name)
}

#[uniffi::export]
pub fn delete_session_folder(database_path: String, id: String) -> Result<(), SessionError> {
    let repository = session_repository_for_path(database_path)?;
    repository.delete_folder(id)
}

#[uniffi::export]
pub fn list_session_folders(database_path: String) -> Result<Vec<SessionFolder>, SessionError> {
    let repository = session_repository_for_path(database_path)?;
    repository.list_folders()
}

#[uniffi::export]
pub fn list_session_sidebar_order(
    database_path: String,
) -> Result<Vec<SessionSidebarOrderItem>, SessionError> {
    let repository = session_repository_for_path(database_path)?;
    repository.list_session_sidebar_order()
}

#[uniffi::export]
pub fn load_session_sidebar_snapshot(
    database_path: String,
) -> Result<SessionSidebarSnapshot, SessionError> {
    let repository = session_repository_for_path(database_path)?;
    repository.load_session_sidebar_snapshot()
}

#[uniffi::export]
pub fn save_credential_record(
    database_path: String,
    draft: CredentialDraft,
) -> Result<CredentialRecord, SessionError> {
    let repository = credential_repository_for_path(database_path)?;
    repository.save_credential(draft)
}

#[uniffi::export]
pub fn list_credential_records(
    database_path: String,
) -> Result<Vec<CredentialRecord>, SessionError> {
    let repository = credential_repository_for_path(database_path)?;
    repository.list_credentials()
}

#[uniffi::export]
pub fn delete_credential_record(database_path: String, id: String) -> Result<(), SessionError> {
    let repository = credential_repository_for_path(database_path)?;
    repository.delete_credential(id)
}

#[uniffi::export]
pub fn create_session_record(
    database_path: String,
    draft: SessionDraft,
) -> Result<SessionRecord, SessionError> {
    let repository = session_repository_for_path(database_path)?;
    repository.create_session(draft)
}

#[uniffi::export]
pub fn update_session_record(
    database_path: String,
    id: String,
    update: SessionUpdate,
) -> Result<SessionRecord, SessionError> {
    let repository = session_repository_for_path(database_path)?;
    repository.update_session(id, update)
}

#[uniffi::export]
pub fn duplicate_session_record(
    database_path: String,
    id: String,
    target_folder_id: Option<String>,
) -> Result<SessionRecord, SessionError> {
    let repository = session_repository_for_path(database_path)?;
    repository.duplicate_session(id, target_folder_id)
}

#[uniffi::export]
pub fn move_session_record(
    database_path: String,
    id: String,
    target_folder_id: Option<String>,
) -> Result<SessionRecord, SessionError> {
    let repository = session_repository_for_path(database_path)?;
    repository.move_session(id, target_folder_id)
}

#[uniffi::export]
pub fn place_session_sidebar_item(
    database_path: String,
    kind: String,
    id: String,
    target_parent_id: Option<String>,
    target_index: u32,
) -> Result<SessionSidebarOrderItem, SessionError> {
    let repository = session_repository_for_path(database_path)?;
    repository.place_session_sidebar_item(kind, id, target_parent_id, target_index)
}

#[uniffi::export]
pub fn export_sessions_json(database_path: String) -> Result<String, SessionError> {
    let repository = session_repository_for_path(database_path)?;
    repository.export_sessions_json()
}

#[uniffi::export]
pub fn export_session_folder_json(
    database_path: String,
    folder_id: String,
) -> Result<String, SessionError> {
    let repository = session_repository_for_path(database_path)?;
    repository.export_folder_sessions_json(folder_id)
}

#[uniffi::export]
pub fn delete_session_record(database_path: String, id: String) -> Result<(), SessionError> {
    let repository = session_repository_for_path(database_path.clone())?;
    let session = repository
        .list_all_sessions()?
        .into_iter()
        .find(|session| session.id == id);
    repository.delete_session(id)?;
    if let Some(session) = session {
        if matches!(
            session.protocol.trim().to_ascii_lowercase().as_str(),
            "ssh" | "scp"
        ) {
            clear_known_host_record(database_path, session.host, session.port as u16)?;
        }
    }
    Ok(())
}

#[uniffi::export]
pub fn list_session_records(
    database_path: String,
    folder_id: Option<String>,
) -> Result<Vec<SessionRecord>, SessionError> {
    let repository = session_repository_for_path(database_path)?;
    repository.list_sessions(folder_id)
}

#[uniffi::export]
pub fn list_all_session_records(database_path: String) -> Result<Vec<SessionRecord>, SessionError> {
    let repository = session_repository_for_path(database_path)?;
    repository.list_all_sessions()
}

#[uniffi::export]
pub fn get_session_config_json(
    database_path: String,
    id: String,
) -> Result<Option<String>, SessionError> {
    let repository = session_repository_for_path(database_path)?;
    repository.get_session_config_json(&id)
}

#[uniffi::export]
pub fn mark_session_record_opened(
    database_path: String,
    id: String,
) -> Result<SessionRecord, SessionError> {
    let repository = session_repository_for_path(database_path)?;
    repository.mark_session_opened(id)
}

#[uniffi::export]
pub fn apply_session_import(
    database_path: String,
    source_type: String,
    source_name: String,
    preview: ImportPreview,
) -> Result<ImportApplyResult, SessionError> {
    let source_type = normalize_import_source_type(&source_type)?;
    let source_name = normalized_import_source_name(source_name);
    let repository = session_repository_for_path(database_path.clone())?;
    let mut existing_names = repository
        .list_all_sessions()?
        .into_iter()
        .map(|session| normalized_import_name(&session.name))
        .collect::<HashSet<_>>();
    let existing_folders = repository.list_folders()?;
    let mut folder_ids_by_path = folder_ids_by_path(&existing_folders);
    let mut imported_sessions = Vec::new();
    let mut skipped_count = 0_u32;
    let mut failed_count = 0_u32;
    let mut issues = preview
        .warnings
        .into_iter()
        .map(|warning| redact_import_issue(&warning))
        .collect::<Vec<_>>();

    for session in preview.sessions {
        if session.conflict || existing_names.contains(&normalized_import_name(&session.name)) {
            skipped_count += 1;
            issues.push(redact_import_issue(&format!(
                "{} skipped because a session with the same name exists",
                session.name
            )));
            continue;
        }

        match import_preview_session(
            &repository,
            &mut folder_ids_by_path,
            &session,
            &mut existing_names,
        ) {
            Ok(record) => imported_sessions.push(record),
            Err(error) => {
                failed_count += 1;
                issues.push(redact_import_issue(&format!(
                    "{} failed to import: {error}",
                    session.name
                )));
            }
        }
    }

    let imported_count = imported_sessions.len() as u32;
    let report = import_report_repository_for_path(database_path)?.record_report(
        source_type,
        source_name,
        import_report_status(imported_count, skipped_count, failed_count),
        imported_count,
        skipped_count,
        failed_count,
        issues,
    )?;

    Ok(ImportApplyResult {
        report,
        imported_sessions,
    })
}

#[uniffi::export]
pub fn list_import_reports(database_path: String) -> Result<Vec<ImportReport>, SessionError> {
    let repository = import_report_repository_for_path(database_path)?;
    repository.list_reports()
}

#[uniffi::export]
pub fn validate_ssh_config(config: SshConnectionConfig) -> Result<(), SshRuntimeError> {
    validate_ssh_config_target(config)
}

#[uniffi::export]
pub fn diagnose_ssh_config(
    config: SshConnectionConfig,
) -> Result<SshConnectionStatus, SshRuntimeError> {
    validate_ssh_config_target(config.clone())?;

    Ok(SshConnectionStatus {
        connected: false,
        host: config.host,
        port: config.port,
        username: config.username,
        auth_method: config.auth_method.label(),
        diagnostic: redact_ssh_diagnostic("diagnostic uses credential secret-ref"),
    })
}

#[uniffi::export]
pub fn fingerprint_host_key(host_key: Vec<u8>) -> String {
    fingerprint_sha256_target(&host_key)
}

#[uniffi::export]
pub fn verify_known_host(
    host: String,
    port: u16,
    host_key: Vec<u8>,
    known_hosts: Vec<HostKeyRecord>,
) -> Result<HostKeyVerification, SshRuntimeError> {
    verify_host_key_target(&host, port, &host_key, &known_hosts)
}

#[uniffi::export]
pub fn host_key_trust_decision_label(decision: HostKeyTrustDecision) -> String {
    decision.label()
}

fn auth_secret_to_libssh2(secret: SshAuthSecret) -> Option<SshSecret> {
    match secret {
        SshAuthSecret::Password { value } => Some(SshSecret::Password(value)),
        SshAuthSecret::PrivateKey {
            private_key_pem,
            passphrase,
        } => Some(SshSecret::PrivateKey {
            private_key_pem,
            passphrase,
        }),
        SshAuthSecret::Agent => None,
    }
}

#[uniffi::export]
pub fn apply_host_key_decision_in_database(
    database_path: String,
    host: String,
    port: u16,
    host_key: Vec<u8>,
    decision: HostKeyTrustDecision,
) -> Result<HostKeyVerification, SshRuntimeError> {
    let connection =
        Connection::open(database_path).map_err(|error| SshRuntimeError::Transport {
            message: redact_ssh_diagnostic(&format!("known host database error: {error}")),
        })?;
    apply_migrations(&connection).map_err(|error| SshRuntimeError::Transport {
        message: redact_ssh_diagnostic(&format!("known host database error: {error}")),
    })?;
    let repository = KnownHostRepository::new(connection);

    apply_host_key_decision(&host, port, &host_key, decision, &repository)
}

#[uniffi::export]
pub fn clear_known_host_record(
    database_path: String,
    host: String,
    port: u16,
) -> Result<(), SessionError> {
    let connection = Connection::open(database_path)?;
    apply_migrations(&connection)?;
    let repository = KnownHostRepository::new(connection);
    repository
        .delete(&host, port)
        .map_err(|error| SessionError::Database {
            message: error.to_string(),
        })
}

#[uniffi::export]
pub fn probe_live_ssh_host_key(
    config: SshConnectionConfig,
) -> Result<LiveSshHostKey, SshRuntimeError> {
    validate_ssh_config_target(config.clone())?;
    Libssh2Transport::new().probe_host_key(&config)
}

#[uniffi::export]
pub fn connect_live_ssh(
    config: SshConnectionConfig,
    secret: SshAuthSecret,
    expected_fingerprint_sha256: String,
) -> Result<SshConnectionStatus, SshRuntimeError> {
    validate_ssh_config_target(config.clone())?;
    Libssh2Transport::new().connect_with_secret_and_expected_host_key(
        &config,
        auth_secret_to_libssh2(secret),
        expected_fingerprint_sha256,
    )
}

#[uniffi::export]
pub fn probe_live_device_metrics(
    config: SshConnectionConfig,
    secret: SshAuthSecret,
    expected_fingerprint_sha256: String,
) -> Result<DeviceMetricsSnapshot, SshRuntimeError> {
    validate_ssh_config_target(config.clone())?;
    let transport = Libssh2Transport::new();
    let session = transport.connect_with_secret_and_expected_session(
        &config,
        auth_secret_to_libssh2(secret),
        expected_fingerprint_sha256,
    )?;
    let command = build_device_metrics_probe_command();
    let output = Libssh2ExecListing::run_raw_command(&session, &command).map_err(|message| {
        SshRuntimeError::Transport {
            message: redact_ssh_diagnostic(&message),
        }
    })?;
    let sampled_at_ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis().min(u128::from(u64::MAX)) as u64)
        .unwrap_or(0);

    parse_device_metrics_probe(&output, sampled_at_ms).map_err(|message| {
        SshRuntimeError::Transport {
            message: redact_ssh_diagnostic(&message),
        }
    })
}

#[uniffi::export]
pub fn probe_live_remote_operating_system(
    config: SshConnectionConfig,
    secret: SshAuthSecret,
    expected_fingerprint_sha256: String,
) -> Result<RemoteOperatingSystemInfo, SshRuntimeError> {
    validate_ssh_config_target(config.clone())?;
    let transport = Libssh2Transport::new();
    let session = transport.connect_with_secret_and_expected_session(
        &config,
        auth_secret_to_libssh2(secret),
        expected_fingerprint_sha256,
    )?;
    let command = build_remote_os_probe_command();
    let output = Libssh2ExecListing::run_raw_command(&session, &command).map_err(|message| {
        SshRuntimeError::Transport {
            message: redact_ssh_diagnostic(&message),
        }
    })?;

    parse_remote_os_probe(&output).map_err(|message| SshRuntimeError::Transport {
        message: redact_ssh_diagnostic(&message),
    })
}

#[uniffi::export]
pub fn start_live_ssh_shell_runtime(
    config: SshConnectionConfig,
    secret: SshAuthSecret,
    expected_fingerprint_sha256: String,
    cols: u32,
    rows: u32,
) -> Result<LiveShellStatus, SshRuntimeError> {
    validate_ssh_config_target(config.clone())?;
    start_live_shell_pump_if_needed();
    let runtime = recover_global_lock(terminal_registry()).open_remote_ssh(
        config.host.clone(),
        config.port,
        config.username.clone(),
        cols,
        rows,
    );
    let request = Libssh2ShellRequest::new(runtime.id.clone(), cols, rows);
    match Libssh2Transport::new().open_shell_channel(
        &config,
        auth_secret_to_libssh2(secret),
        expected_fingerprint_sha256,
        request,
    ) {
        Ok((channel, info)) => {
            let status = register_connected_live_shell(
                runtime.clone(),
                LiveShellChannel::Ssh(channel),
                Some(ssh_osc7_bootstrap_input_chunks().concat()),
            )?;
            recover_global_lock(live_ssh_session_infos()).insert(runtime.id, info);
            Ok(status)
        }
        Err(error) => {
            close_failed_live_shell_runtime(runtime.id);
            Err(error)
        }
    }
}

#[uniffi::export]
pub fn start_live_ssh_shell_runtime_with_proxy_jump(
    config: SshConnectionConfig,
    secret: SshAuthSecret,
    proxy_jump: SshProxyJumpRuntimeConfig,
    cols: u32,
    rows: u32,
) -> Result<LiveShellStatus, SshRuntimeError> {
    validate_proxy_jump_runtime_config_target(config.clone(), proxy_jump.clone())?;
    start_live_shell_pump_if_needed();
    let runtime = recover_global_lock(terminal_registry()).open_remote_ssh(
        config.host.clone(),
        config.port,
        config.username.clone(),
        cols,
        rows,
    );
    let request = Libssh2ShellRequest::new(runtime.id.clone(), cols, rows);
    match Libssh2Transport::new().open_shell_channel_via_proxy_jump(
        &config,
        auth_secret_to_libssh2(secret),
        proxy_jump,
        request,
    ) {
        Ok((channel, info)) => {
            let status = register_connected_live_shell(
                runtime.clone(),
                LiveShellChannel::Ssh(channel),
                Some(ssh_osc7_bootstrap_input_chunks().concat()),
            )?;
            recover_global_lock(live_ssh_session_infos()).insert(runtime.id, info);
            Ok(status)
        }
        Err(error) => {
            close_failed_live_shell_runtime(runtime.id);
            Err(error)
        }
    }
}

#[uniffi::export]
pub fn start_live_telnet_shell_runtime(
    config: TelnetConnectionConfig,
    cols: u32,
    rows: u32,
) -> Result<LiveShellStatus, SshRuntimeError> {
    validate_telnet_config_target(&config)?;
    start_live_shell_pump_if_needed();
    let runtime = recover_global_lock(terminal_registry()).open_remote_telnet(
        config.host.trim().to_string(),
        config.port,
        config.username.clone(),
        cols,
        rows,
    );
    match TelnetShellChannel::connect(&config.host, config.port, config.connect_timeout_ms) {
        Ok(channel) => {
            register_connected_live_shell(runtime, LiveShellChannel::Telnet(channel), None)
        }
        Err(error) => {
            close_failed_live_shell_runtime(runtime.id);
            Err(error)
        }
    }
}

#[uniffi::export]
pub fn start_live_serial_shell_runtime(
    config: SerialConnectionConfig,
    cols: u32,
    rows: u32,
) -> Result<LiveShellStatus, SshRuntimeError> {
    validate_serial_config_target(&config)?;
    start_live_shell_pump_if_needed();
    let runtime = recover_global_lock(terminal_registry()).open_serial(
        config.device_path.trim().to_string(),
        config.baud_rate,
        cols,
        rows,
    );
    match SerialShellChannel::open_with_config(config) {
        Ok(channel) => {
            register_connected_live_shell(runtime, LiveShellChannel::Serial(channel), None)
        }
        Err(error) => {
            close_failed_live_shell_runtime(runtime.id);
            Err(error)
        }
    }
}

#[uniffi::export]
pub fn parse_remote_listing(input: String) -> Result<Vec<RemoteFileEntry>, FilesError> {
    parse_remote_listing_target(&input)
}

#[uniffi::export]
pub fn validate_ftp_config(config: FtpConnectionConfig) -> Result<(), SshRuntimeError> {
    validate_ftp_config_target(&config)
}

#[uniffi::export]
pub fn resolve_scp_conflict_path(
    destination_path: String,
    policy: ScpConflictPolicy,
) -> Option<String> {
    resolve_scp_conflict_path_target(&destination_path, policy)
}

#[uniffi::export]
pub fn simulate_scp_transfer(
    job: ScpTransferJob,
) -> Result<Vec<ScpTransferProgress>, ScpTransferError> {
    let engine = MockScpEngine::new(MockScpOutcome::Success);
    run_scp_transfer(job, &engine)
}

#[uniffi::export]
pub fn run_live_scp_transfer(
    config: SshConnectionConfig,
    secret: SshAuthSecret,
    expected_fingerprint_sha256: String,
    job: ScpTransferJob,
) -> Result<Vec<ScpTransferProgress>, SshRuntimeError> {
    run_live_scp_transfer_with_resume(
        config,
        secret,
        expected_fingerprint_sha256,
        job,
        ScpResumeOptions::fresh(),
    )
}

#[uniffi::export]
pub fn run_live_scp_transfer_with_resume(
    config: SshConnectionConfig,
    secret: SshAuthSecret,
    expected_fingerprint_sha256: String,
    job: ScpTransferJob,
    resume_options: ScpResumeOptions,
) -> Result<Vec<ScpTransferProgress>, SshRuntimeError> {
    with_live_scp_transfer_cancellation_scope(&job.id.clone(), || {
        validate_ssh_config_target(config.clone())?;
        let transport = Libssh2Transport::new();
        let session = transport.connect_with_secret_and_expected_transfer_session(
            &config,
            auth_secret_to_libssh2(secret),
            expected_fingerprint_sha256,
        )?;
        let engine = Libssh2ScpEngine::new();
        let bytes_done = match job.direction {
            domain::scp::ScpDirection::Upload => engine
                .upload_file_with_resume(&session, &job, &resume_options)
                .map(|report| report.bytes_written)
                .map_err(files_error_to_ssh_runtime)?,
            domain::scp::ScpDirection::Download => engine
                .download_file_with_resume(&session, &job, &resume_options)
                .map(|report| report.bytes_read)
                .map_err(files_error_to_ssh_runtime)?,
        };
        let bytes_total = if job.bytes_total == 0 {
            bytes_done
        } else {
            job.bytes_total
        };
        let start_status = if resume_options.requested_offset > 0 && !resume_options.force_restart {
            "resuming"
        } else {
            "running"
        };

        Ok(vec![
            ScpTransferProgress {
                job_id: job.id.clone(),
                bytes_done: if start_status == "resuming" {
                    resume_options.requested_offset.min(bytes_total)
                } else {
                    0
                },
                bytes_total,
                status: start_status.to_string(),
            },
            ScpTransferProgress {
                job_id: job.id,
                bytes_done,
                bytes_total,
                status: "completed".to_string(),
            },
        ])
    })
}

#[uniffi::export]
pub fn run_live_ftp_transfer(
    config: FtpConnectionConfig,
    secret: FtpAuthSecret,
    job: ScpTransferJob,
) -> Result<Vec<ScpTransferProgress>, SshRuntimeError> {
    with_live_scp_transfer_cancellation_scope(&job.id.clone(), || {
        validate_ftp_config_target(&config)?;
        let mut client = FtpControlClient::connect(&config, &secret)?;
        match job.direction {
            domain::scp::ScpDirection::Upload => {
                let (bytes_done, bytes_total) = run_ftp_upload(&mut client, &job)?;
                Ok(vec![
                    ScpTransferProgress {
                        job_id: job.id.clone(),
                        bytes_done: 0,
                        bytes_total,
                        status: "running".to_string(),
                    },
                    ScpTransferProgress {
                        job_id: job.id,
                        bytes_done,
                        bytes_total,
                        status: "completed".to_string(),
                    },
                ])
            }
            domain::scp::ScpDirection::Download => {
                let (bytes_done, bytes_total) = run_ftp_download(&mut client, &job)?;
                Ok(vec![
                    ScpTransferProgress {
                        job_id: job.id.clone(),
                        bytes_done: 0,
                        bytes_total,
                        status: "running".to_string(),
                    },
                    ScpTransferProgress {
                        job_id: job.id,
                        bytes_done,
                        bytes_total,
                        status: "completed".to_string(),
                    },
                ])
            }
        }
    })
}

fn run_ftp_download(
    client: &mut FtpControlClient,
    job: &ScpTransferJob,
) -> Result<(u64, u64), SshRuntimeError> {
    let destination_path = Path::new(&job.destination_path);
    let partial_path = ftp_partial_download_path(destination_path);
    let partial_bytes = local_file_size_if_regular(&partial_path)?;

    if partial_bytes > 0 {
        let remote_size = client.file_size(&job.source_path)?;
        if partial_bytes > remote_size {
            return Err(files_error_to_ssh_runtime(
                "FILES_SIZE_MISMATCH".to_string(),
            ));
        }
        if partial_bytes < remote_size {
            let mut partial_file = std::fs::OpenOptions::new()
                .append(true)
                .open(&partial_path)
                .map_err(|_| files_error_to_ssh_runtime("FILES_LOCAL_WRITE_FAILED".to_string()))?;
            let copied = client.retrieve_file_to_writer_with_job(
                &job.source_path,
                partial_bytes,
                &mut partial_file,
                &job.id,
            )?;
            let bytes_done = partial_bytes.saturating_add(copied);
            if bytes_done != remote_size {
                return Err(files_error_to_ssh_runtime(
                    "FILES_SIZE_MISMATCH".to_string(),
                ));
            }
        }
        promote_ftp_partial_download(&partial_path, destination_path)?;
        return Ok((remote_size, remote_size));
    }

    let mut partial_file = std::fs::OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .open(&partial_path)
        .map_err(|_| files_error_to_ssh_runtime("FILES_LOCAL_WRITE_FAILED".to_string()))?;
    let bytes_done =
        client.retrieve_file_to_writer_with_job(&job.source_path, 0, &mut partial_file, &job.id)?;
    drop(partial_file);
    promote_ftp_partial_download(&partial_path, destination_path)?;
    let bytes_total = if job.bytes_total == 0 {
        bytes_done
    } else {
        job.bytes_total
    };
    Ok((bytes_done, bytes_total))
}

fn run_ftp_upload(
    client: &mut FtpControlClient,
    job: &ScpTransferJob,
) -> Result<(u64, u64), SshRuntimeError> {
    let source_path = Path::new(&job.source_path);
    let bytes_done = if source_path.is_dir() {
        client.make_directory(&job.destination_path)?;
        let mut bytes_done = 0_u64;
        upload_ftp_directory_children(
            client,
            job,
            source_path,
            &job.destination_path,
            &mut bytes_done,
        )?;
        bytes_done
    } else {
        upload_ftp_file(client, job, source_path, &job.destination_path)?
    };
    let bytes_total = if job.bytes_total == 0 {
        bytes_done
    } else {
        job.bytes_total
    };
    Ok((bytes_done, bytes_total))
}

fn upload_ftp_directory_children(
    client: &mut FtpControlClient,
    job: &ScpTransferJob,
    local_directory: &Path,
    remote_directory: &str,
    bytes_done: &mut u64,
) -> Result<(), SshRuntimeError> {
    if is_live_scp_transfer_cancelled(&job.id) {
        return Err(SshRuntimeError::Transport {
            message: "FTP_TRANSFER_CANCELLED".to_string(),
        });
    }

    let entries = std::fs::read_dir(local_directory).map_err(|error| {
        files_error_to_ssh_runtime(redact_ssh_diagnostic(&format!(
            "FTP 读取本地文件夹失败：{error}"
        )))
    })?;
    for entry in entries {
        let entry = entry.map_err(|error| {
            files_error_to_ssh_runtime(redact_ssh_diagnostic(&format!(
                "FTP 读取本地文件夹失败：{error}"
            )))
        })?;
        let local_path = entry.path();
        let child_name = entry.file_name().to_string_lossy().to_string();
        let remote_path = ftp_remote_child_path(remote_directory, &child_name)?;
        let metadata = entry.metadata().map_err(|error| {
            files_error_to_ssh_runtime(redact_ssh_diagnostic(&format!(
                "FTP 读取本地文件失败：{error}"
            )))
        })?;
        if metadata.is_dir() {
            client.make_directory(&remote_path)?;
            upload_ftp_directory_children(client, job, &local_path, &remote_path, bytes_done)?;
        } else if metadata.is_file() {
            let copied = upload_ftp_file(client, job, &local_path, &remote_path)?;
            *bytes_done = bytes_done.saturating_add(copied);
        }
    }
    Ok(())
}

fn upload_ftp_file(
    client: &mut FtpControlClient,
    job: &ScpTransferJob,
    local_path: &Path,
    remote_path: &str,
) -> Result<u64, SshRuntimeError> {
    let bytes = std::fs::read(local_path).map_err(|error| {
        files_error_to_ssh_runtime(redact_ssh_diagnostic(&format!(
            "FTP 读取本地文件失败：{error}"
        )))
    })?;
    client.store_file_with_job(remote_path, &bytes, &job.id)?;
    Ok(bytes.len() as u64)
}

fn local_file_size_if_regular(path: &Path) -> Result<u64, SshRuntimeError> {
    match std::fs::metadata(path) {
        Ok(metadata) if metadata.is_file() => Ok(metadata.len()),
        Ok(_) => Err(files_error_to_ssh_runtime(
            "FILES_LOCAL_WRITE_FAILED".to_string(),
        )),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(0),
        Err(_) => Err(files_error_to_ssh_runtime(
            "FILES_LOCAL_WRITE_FAILED".to_string(),
        )),
    }
}

fn promote_ftp_partial_download(
    partial_path: &Path,
    destination_path: &Path,
) -> Result<(), SshRuntimeError> {
    std::fs::rename(partial_path, destination_path)
        .map_err(|_| files_error_to_ssh_runtime("FILES_LOCAL_WRITE_FAILED".to_string()))
}

fn ftp_partial_download_path(destination_path: &Path) -> PathBuf {
    let mut partial = destination_path.as_os_str().to_os_string();
    partial.push(".staciopart");
    PathBuf::from(partial)
}

fn ftp_remote_child_path(
    remote_directory: &str,
    child_name: &str,
) -> Result<String, SshRuntimeError> {
    if child_name.is_empty() || child_name == "." || child_name == ".." || child_name.contains('/')
    {
        return Err(SshRuntimeError::InvalidConfig);
    }

    let normalized_directory = remote_directory.trim_end_matches('/');
    Ok(if normalized_directory.is_empty() {
        format!("/{child_name}")
    } else {
        format!("{normalized_directory}/{child_name}")
    })
}

#[uniffi::export]
pub fn cancel_live_scp_transfer(job_id: String) -> Result<bool, SshRuntimeError> {
    Ok(cancel_live_scp_transfer_target(&job_id))
}

#[uniffi::export]
pub fn cancel_live_ftp_transfer(job_id: String) -> Result<bool, SshRuntimeError> {
    Ok(cancel_live_scp_transfer_target(&job_id))
}

#[uniffi::export]
pub fn take_live_scp_transfer_progress_batch(
    job_id: String,
) -> Result<Vec<ScpTransferProgress>, SshRuntimeError> {
    Ok(take_live_scp_transfer_progress_batch_target(&job_id))
}

#[uniffi::export]
pub fn record_scp_transfer_job(
    database_path: String,
    session_id: Option<String>,
    job: ScpTransferJob,
    status: String,
    bytes_done: u64,
) -> Result<(), SshRuntimeError> {
    let repository = transfer_repository_for_path(database_path)?;
    repository
        .upsert_job(session_id, &job, &status, bytes_done)
        .map_err(transfer_db_error_to_ssh_runtime)
}

#[uniffi::export]
pub fn append_scp_transfer_progress(
    database_path: String,
    progress: ScpTransferProgress,
) -> Result<ScpTransferEventRecord, SshRuntimeError> {
    append_scp_transfer_progress_with_message(database_path, progress, None)
}

#[uniffi::export]
pub fn append_scp_transfer_progress_with_message(
    database_path: String,
    progress: ScpTransferProgress,
    message: Option<String>,
) -> Result<ScpTransferEventRecord, SshRuntimeError> {
    let repository = transfer_repository_for_path(database_path)?;
    repository
        .append_progress_with_message(&progress, message)
        .map(ScpTransferEventRecord::from)
        .map_err(transfer_db_error_to_ssh_runtime)
}

#[uniffi::export]
pub fn list_scp_transfer_jobs(
    database_path: String,
) -> Result<Vec<ScpTransferJobRecord>, SshRuntimeError> {
    let repository = transfer_repository_for_path(database_path)?;
    repository
        .list_recent_jobs()
        .map(|jobs| jobs.into_iter().map(ScpTransferJobRecord::from).collect())
        .map_err(transfer_db_error_to_ssh_runtime)
}

#[uniffi::export]
pub fn list_scp_transfer_events(
    database_path: String,
    job_id: String,
) -> Result<Vec<ScpTransferEventRecord>, SshRuntimeError> {
    let repository = transfer_repository_for_path(database_path)?;
    repository
        .list_events_for_job(&job_id)
        .map(|events| {
            events
                .into_iter()
                .map(ScpTransferEventRecord::from)
                .collect()
        })
        .map_err(transfer_db_error_to_ssh_runtime)
}

#[uniffi::export]
pub fn clear_finished_scp_transfer_jobs(database_path: String) -> Result<u32, SshRuntimeError> {
    let repository = transfer_repository_for_path(database_path)?;
    repository
        .delete_finished_jobs()
        .map_err(transfer_db_error_to_ssh_runtime)
}

#[uniffi::export]
pub fn list_live_remote_directory(
    config: SshConnectionConfig,
    secret: SshAuthSecret,
    expected_fingerprint_sha256: String,
    remote_path: String,
) -> Result<Vec<RemoteFileEntry>, SshRuntimeError> {
    validate_ssh_config_target(config.clone())?;
    let transport = Libssh2Transport::new();
    let session = transport.connect_with_secret_and_expected_transfer_session(
        &config,
        auth_secret_to_libssh2(secret),
        expected_fingerprint_sha256,
    )?;
    Libssh2ExecListing::new()
        .list_directory(&session, &remote_path)
        .map_err(files_error_to_ssh_runtime)
}

#[uniffi::export]
pub fn search_live_remote_files(
    config: SshConnectionConfig,
    secret: SshAuthSecret,
    expected_fingerprint_sha256: String,
    remote_path: String,
    keyword: String,
    depth: u32,
) -> Result<Vec<RemoteFileEntry>, SshRuntimeError> {
    validate_ssh_config_target(config.clone())?;
    let transport = Libssh2Transport::new();
    let session = transport.connect_with_secret_and_expected_transfer_session(
        &config,
        auth_secret_to_libssh2(secret),
        expected_fingerprint_sha256,
    )?;
    Libssh2ExecListing::new()
        .search_directory(&session, &remote_path, &keyword, depth)
        .map_err(files_error_to_ssh_runtime)
}

#[uniffi::export]
pub fn create_live_remote_directory(
    config: SshConnectionConfig,
    secret: SshAuthSecret,
    expected_fingerprint_sha256: String,
    remote_path: String,
) -> Result<(), SshRuntimeError> {
    apply_live_remote_file_operation(
        config,
        secret,
        expected_fingerprint_sha256,
        RemoteFileOperation::MakeDirectory { path: remote_path },
    )
}

#[uniffi::export]
pub fn rename_live_remote_path(
    config: SshConnectionConfig,
    secret: SshAuthSecret,
    expected_fingerprint_sha256: String,
    from_path: String,
    to_path: String,
) -> Result<(), SshRuntimeError> {
    apply_live_remote_file_operation(
        config,
        secret,
        expected_fingerprint_sha256,
        RemoteFileOperation::Rename { from_path, to_path },
    )
}

#[uniffi::export]
pub fn delete_live_remote_path(
    config: SshConnectionConfig,
    secret: SshAuthSecret,
    expected_fingerprint_sha256: String,
    remote_path: String,
    recursive: bool,
) -> Result<(), SshRuntimeError> {
    apply_live_remote_file_operation(
        config,
        secret,
        expected_fingerprint_sha256,
        RemoteFileOperation::Delete {
            path: remote_path,
            recursive,
        },
    )
}

#[uniffi::export]
pub fn chmod_live_remote_path(
    config: SshConnectionConfig,
    secret: SshAuthSecret,
    expected_fingerprint_sha256: String,
    remote_path: String,
    mode: String,
) -> Result<(), SshRuntimeError> {
    apply_live_remote_file_operation(
        config,
        secret,
        expected_fingerprint_sha256,
        RemoteFileOperation::Chmod {
            path: remote_path,
            mode,
        },
    )
}

#[uniffi::export]
pub fn copy_live_remote_path(
    config: SshConnectionConfig,
    secret: SshAuthSecret,
    expected_fingerprint_sha256: String,
    from_path: String,
    to_path: String,
) -> Result<(), SshRuntimeError> {
    apply_live_remote_file_operation(
        config,
        secret,
        expected_fingerprint_sha256,
        RemoteFileOperation::Copy { from_path, to_path },
    )
}

#[uniffi::export]
pub fn read_live_remote_file(
    config: SshConnectionConfig,
    secret: SshAuthSecret,
    expected_fingerprint_sha256: String,
    remote_path: String,
    offset: u64,
    length: Option<u64>,
) -> Result<Vec<u8>, SshRuntimeError> {
    validate_ssh_config_target(config.clone())?;
    // TODO(proxy-jump-file-transfer): thread SshProxyJumpRuntimeConfig through Files/SCP APIs so file reads can reuse the same one-hop ProxyJump route as terminal sessions.
    let transport = Libssh2Transport::new();
    let session = transport.connect_with_secret_and_expected_transfer_session(
        &config,
        auth_secret_to_libssh2(secret),
        expected_fingerprint_sha256,
    )?;
    Libssh2ScpEngine::new()
        .read_file_bytes(&session, &remote_path, offset, length)
        .map_err(files_error_to_ssh_runtime)
}

#[uniffi::export]
pub fn write_live_remote_file(
    config: SshConnectionConfig,
    secret: SshAuthSecret,
    expected_fingerprint_sha256: String,
    remote_path: String,
    contents: Vec<u8>,
) -> Result<u64, SshRuntimeError> {
    validate_ssh_config_target(config.clone())?;
    // TODO(proxy-jump-file-transfer): thread SshProxyJumpRuntimeConfig through Files/SCP APIs so file writes can reuse the same one-hop ProxyJump route as terminal sessions.
    let transport = Libssh2Transport::new();
    let session = transport.connect_with_secret_and_expected_transfer_session(
        &config,
        auth_secret_to_libssh2(secret),
        expected_fingerprint_sha256,
    )?;
    Libssh2ScpEngine::new()
        .upload_bytes(&session, &remote_path, &contents)
        .map(|report| report.bytes_written)
        .map_err(files_error_to_ssh_runtime)
}

fn apply_live_remote_file_operation(
    config: SshConnectionConfig,
    secret: SshAuthSecret,
    expected_fingerprint_sha256: String,
    operation: RemoteFileOperation,
) -> Result<(), SshRuntimeError> {
    validate_ssh_config_target(config.clone())?;
    // TODO(proxy-jump-file-transfer): thread SshProxyJumpRuntimeConfig through Files/SCP operation APIs so directory operations can reuse the same one-hop ProxyJump route as terminal sessions.
    let transport = Libssh2Transport::new();
    let session = transport.connect_with_secret_and_expected_session(
        &config,
        auth_secret_to_libssh2(secret),
        expected_fingerprint_sha256,
    )?;
    Libssh2ExecListing::new()
        .apply_operation(&session, &operation)
        .map_err(files_error_to_ssh_runtime)
}

#[uniffi::export]
pub fn list_live_ftp_directory(
    config: FtpConnectionConfig,
    secret: FtpAuthSecret,
    remote_path: String,
) -> Result<Vec<RemoteFileEntry>, SshRuntimeError> {
    validate_ftp_config_target(&config)?;
    let mut client = FtpControlClient::connect(&config, &secret)?;
    client.list_directory(&remote_path)
}

#[uniffi::export]
pub fn create_live_ftp_directory(
    config: FtpConnectionConfig,
    secret: FtpAuthSecret,
    remote_path: String,
) -> Result<(), SshRuntimeError> {
    validate_ftp_config_target(&config)?;
    let mut client = FtpControlClient::connect(&config, &secret)?;
    client.make_directory(&remote_path)
}

#[uniffi::export]
pub fn rename_live_ftp_path(
    config: FtpConnectionConfig,
    secret: FtpAuthSecret,
    from_path: String,
    to_path: String,
) -> Result<(), SshRuntimeError> {
    validate_ftp_config_target(&config)?;
    let mut client = FtpControlClient::connect(&config, &secret)?;
    client.rename(&from_path, &to_path)
}

#[uniffi::export]
pub fn delete_live_ftp_path(
    config: FtpConnectionConfig,
    secret: FtpAuthSecret,
    remote_path: String,
    recursive: bool,
) -> Result<(), SshRuntimeError> {
    validate_ftp_config_target(&config)?;
    let mut client = FtpControlClient::connect(&config, &secret)?;
    client.delete(&remote_path, recursive)
}

#[uniffi::export]
pub fn copy_live_ftp_path(
    config: FtpConnectionConfig,
    secret: FtpAuthSecret,
    from_path: String,
    to_path: String,
) -> Result<(), SshRuntimeError> {
    validate_ftp_config_target(&config)?;
    let mut client = FtpControlClient::connect(&config, &secret)?;
    let bytes = client.retrieve_file(&from_path)?;
    client.store_file(&to_path, &bytes)
}

fn transfer_repository_for_path(
    database_path: String,
) -> Result<TransferRepository, SshRuntimeError> {
    let connection = Connection::open(database_path).map_err(transfer_db_error_to_ssh_runtime)?;
    apply_migrations(&connection).map_err(transfer_db_error_to_ssh_runtime)?;
    Ok(TransferRepository::new(connection))
}

fn transfer_db_error_to_ssh_runtime(error: rusqlite::Error) -> SshRuntimeError {
    SshRuntimeError::Transport {
        message: redact_ssh_diagnostic(&format!("transfer database error: {error}")),
    }
}

fn import_preview_session(
    repository: &SessionRepository,
    folder_ids_by_path: &mut HashMap<String, String>,
    session: &ImportSessionPreview,
    existing_names: &mut HashSet<String>,
) -> Result<SessionRecord, SessionError> {
    let protocol = session.protocol.trim().to_ascii_lowercase();
    if !is_supported_import_protocol(&protocol)
        || session.name.trim().is_empty()
        || session.host.trim().is_empty()
    {
        return Err(SessionError::InvalidQuickConnect);
    }

    let folder_id = match session.folder.as_ref().map(|folder| folder.trim()) {
        Some(folder_path) if !folder_path.is_empty() => {
            import_folder_id_for_path(repository, folder_ids_by_path, folder_path)?
        }
        _ => None,
    };
    let record = repository.create_session(SessionDraft {
        folder_id,
        name: session.name.trim().to_string(),
        protocol,
        host: session.host.trim().to_string(),
        port: u32::from(session.port),
        username: session
            .username
            .as_ref()
            .map(|username| username.trim().to_string())
            .filter(|username| !username.is_empty()),
        private_key_path: session
            .private_key_path
            .as_ref()
            .map(|path| path.trim().to_string())
            .filter(|path| !path.is_empty()),
        credential_id: None,
        tags: vec![],
        config_json: session.config_json.clone(),
    })?;
    existing_names.insert(normalized_import_name(&record.name));
    Ok(record)
}

fn is_supported_import_protocol(protocol: &str) -> bool {
    matches!(protocol, "ssh" | "ftp" | "telnet" | "vnc")
}

fn normalize_import_source_type(source_type: &str) -> Result<String, SessionError> {
    match source_type.trim().to_ascii_lowercase().as_str() {
        "csv" => Ok("csv".to_string()),
        "legacy_ini" => Ok("legacy_ini".to_string()),
        "json" | "stacio_json" => Ok("stacio_json".to_string()),
        "xshell" | "mobaxterm" | "windterm" | "securecrt" | "finalshell" | "termius"
        | "electerm" => Ok(source_type.trim().to_ascii_lowercase()),
        _ => Err(SessionError::InvalidQuickConnect),
    }
}

fn normalized_import_source_name(source_name: String) -> String {
    let trimmed = source_name.trim();
    if trimmed.is_empty() {
        "Imported sessions".to_string()
    } else {
        trimmed.to_string()
    }
}

fn normalized_import_name(name: &str) -> String {
    name.trim().to_ascii_lowercase()
}

fn folder_ids_by_path(folders: &[SessionFolder]) -> HashMap<String, String> {
    folder_paths_by_id(folders)
        .into_iter()
        .map(|(id, path)| (normalized_folder_path(&path), id))
        .collect()
}

fn folder_paths_by_id(folders: &[SessionFolder]) -> HashMap<String, String> {
    let folders_by_id = folders
        .iter()
        .map(|folder| (folder.id.clone(), folder.clone()))
        .collect::<HashMap<_, _>>();
    folders
        .iter()
        .filter_map(|folder| {
            folder_path_for(&folder.id, &folders_by_id, &mut HashSet::new())
                .map(|path| (folder.id.clone(), path))
        })
        .collect()
}

fn folder_path_for(
    folder_id: &str,
    folders_by_id: &HashMap<String, SessionFolder>,
    visiting: &mut HashSet<String>,
) -> Option<String> {
    if !visiting.insert(folder_id.to_string()) {
        return None;
    }
    let folder = folders_by_id.get(folder_id)?;
    let name = folder.name.trim();
    if name.is_empty() {
        return None;
    }
    let path = match folder.parent_id.as_ref() {
        Some(parent_id) => {
            let parent = folder_path_for(parent_id, folders_by_id, visiting)?;
            format!("{parent}/{name}")
        }
        None => name.to_string(),
    };
    visiting.remove(folder_id);
    Some(path)
}

fn import_folder_id_for_path(
    repository: &SessionRepository,
    folder_ids_by_path: &mut HashMap<String, String>,
    folder_path: &str,
) -> Result<Option<String>, SessionError> {
    let components = import_folder_path_components(folder_path);
    if components.is_empty() {
        return Ok(None);
    }

    let mut parent_id: Option<String> = None;
    let mut current_id: Option<String> = None;
    let mut current_path = Vec::new();
    for component in components {
        current_path.push(component.clone());
        let normalized = normalized_folder_path(&current_path.join("/"));
        if let Some(existing_id) = folder_ids_by_path.get(&normalized) {
            current_id = Some(existing_id.clone());
        } else {
            let folder = repository.create_folder(parent_id.clone(), &component)?;
            folder_ids_by_path.insert(normalized, folder.id.clone());
            current_id = Some(folder.id);
        }
        parent_id = current_id.clone();
    }

    Ok(current_id)
}

fn import_folder_path_components(folder_path: &str) -> Vec<String> {
    folder_path
        .split('/')
        .map(str::trim)
        .filter(|component| !component.is_empty())
        .map(ToString::to_string)
        .collect()
}

fn normalized_folder_path(folder_path: &str) -> String {
    import_folder_path_components(folder_path)
        .join("/")
        .to_ascii_lowercase()
}

fn import_report_status(imported_count: u32, skipped_count: u32, failed_count: u32) -> String {
    if failed_count > 0 && imported_count == 0 && skipped_count == 0 {
        "failed".to_string()
    } else if skipped_count > 0 && imported_count == 0 && failed_count == 0 {
        "skipped".to_string()
    } else if skipped_count > 0 || failed_count > 0 {
        "partial".to_string()
    } else {
        "imported".to_string()
    }
}

fn redact_import_issue(issue: &str) -> String {
    issue
        .replace("password", "credential")
        .replace("Password", "Credential")
        .replace("secret", "credential")
        .replace("Secret", "Credential")
}

fn session_repository_for_path(database_path: String) -> Result<SessionRepository, SessionError> {
    let connection = Connection::open(database_path)?;
    apply_migrations(&connection)?;
    Ok(SessionRepository::new(connection))
}

fn credential_repository_for_path(
    database_path: String,
) -> Result<CredentialRepository, SessionError> {
    let connection = Connection::open(database_path)?;
    apply_migrations(&connection)?;
    Ok(CredentialRepository::new(connection))
}

fn import_report_repository_for_path(
    database_path: String,
) -> Result<ImportReportRepository, SessionError> {
    let connection = Connection::open(database_path)?;
    apply_migrations(&connection)?;
    Ok(ImportReportRepository::new(connection))
}

fn audit_event_repository_for_path(
    database_path: String,
) -> Result<AuditEventRepository, SshRuntimeError> {
    let connection = Connection::open(database_path).map_err(transfer_db_error_to_ssh_runtime)?;
    apply_migrations(&connection).map_err(transfer_db_error_to_ssh_runtime)?;
    Ok(AuditEventRepository::new(connection))
}

fn agent_action_audit_repository_for_path(
    database_path: String,
) -> Result<AgentActionAuditRepository, SshRuntimeError> {
    let connection = Connection::open(database_path).map_err(transfer_db_error_to_ssh_runtime)?;
    apply_migrations(&connection).map_err(transfer_db_error_to_ssh_runtime)?;
    Ok(AgentActionAuditRepository::new(connection))
}

fn agent_task_repository_for_path(
    database_path: String,
) -> Result<AgentTaskRepository, SshRuntimeError> {
    let connection = Connection::open(database_path).map_err(transfer_db_error_to_ssh_runtime)?;
    apply_migrations(&connection).map_err(transfer_db_error_to_ssh_runtime)?;
    Ok(AgentTaskRepository::new(connection))
}

fn ai_conversation_history_repository_for_path(
    database_path: String,
) -> Result<AIConversationHistoryRepository, SshRuntimeError> {
    let connection = Connection::open(database_path).map_err(transfer_db_error_to_ssh_runtime)?;
    apply_migrations(&connection).map_err(transfer_db_error_to_ssh_runtime)?;
    Ok(AIConversationHistoryRepository::new(connection))
}

fn terminal_macro_repository_for_path(
    database_path: String,
) -> Result<TerminalMacroRepository, SshRuntimeError> {
    let connection = Connection::open(database_path).map_err(transfer_db_error_to_ssh_runtime)?;
    apply_migrations(&connection).map_err(transfer_db_error_to_ssh_runtime)?;
    Ok(TerminalMacroRepository::new(connection))
}

fn tunnel_repository_for_path(database_path: String) -> Result<TunnelRepository, SshRuntimeError> {
    let connection = Connection::open(database_path).map_err(tunnel_db_error_to_ssh_runtime)?;
    apply_migrations(&connection).map_err(tunnel_db_error_to_ssh_runtime)?;
    Ok(TunnelRepository::new(connection))
}

fn tunnel_db_error_to_ssh_runtime(error: rusqlite::Error) -> SshRuntimeError {
    SshRuntimeError::Transport {
        message: redact_ssh_diagnostic(&format!("tunnel database error: {error}")),
    }
}

fn terminal_macro_error_to_ssh_runtime(error: TerminalMacroRepositoryError) -> SshRuntimeError {
    SshRuntimeError::Transport {
        message: redact_ssh_diagnostic(&format!("{error}")),
    }
}

impl From<TransferJobRecord> for ScpTransferJobRecord {
    fn from(record: TransferJobRecord) -> Self {
        Self {
            job: record.job,
            session_id: record.session_id,
            status: record.status,
            bytes_done: record.bytes_done,
        }
    }
}

impl From<TransferEventRecord> for ScpTransferEventRecord {
    fn from(record: TransferEventRecord) -> Self {
        Self {
            id: record.id,
            job_id: record.job_id,
            event_type: record.event_type,
            message: record.message,
            bytes_done: record.bytes_done,
            created_at: record.created_at,
        }
    }
}

fn files_error_to_ssh_runtime(message: String) -> SshRuntimeError {
    match message.as_str() {
        "FILES_TRANSFER_INTERRUPTED" => SshRuntimeError::Transport { message },
        _ => SshRuntimeError::Transport { message },
    }
}

#[uniffi::export]
pub fn validate_tunnel_profile(profile: TunnelProfile) -> Result<(), TunnelError> {
    validate_tunnel_profile_target(profile)
}

#[uniffi::export]
pub fn check_tunnel_local_port_available(profile: TunnelProfile) -> Result<(), TunnelError> {
    check_tunnel_local_port_available_target(profile)
}

#[uniffi::export]
pub fn save_tunnel_profile(
    database_path: String,
    session_id: Option<String>,
    profile: TunnelProfile,
) -> Result<(), SshRuntimeError> {
    validate_tunnel_profile_target(profile.clone()).map_err(tunnel_error_to_ssh_runtime)?;
    let repository = tunnel_repository_for_path(database_path)?;
    repository
        .upsert_profile(session_id, &profile)
        .map_err(tunnel_db_error_to_ssh_runtime)
}

#[uniffi::export]
pub fn save_tunnel_profile_record(
    database_path: String,
    record: TunnelProfileRecord,
) -> Result<(), SshRuntimeError> {
    validate_tunnel_profile_target(record.profile.clone()).map_err(tunnel_error_to_ssh_runtime)?;
    let repository = tunnel_repository_for_path(database_path)?;
    repository
        .upsert_profile_record(&record)
        .map_err(tunnel_db_error_to_ssh_runtime)
}

#[uniffi::export]
pub fn list_tunnel_profiles(
    database_path: String,
    session_id: Option<String>,
) -> Result<Vec<TunnelProfile>, SshRuntimeError> {
    let repository = tunnel_repository_for_path(database_path)?;
    repository
        .list_profiles(session_id)
        .map_err(tunnel_db_error_to_ssh_runtime)
}

#[uniffi::export]
pub fn list_tunnel_profile_records(
    database_path: String,
    session_id: Option<String>,
) -> Result<Vec<TunnelProfileRecord>, SshRuntimeError> {
    let repository = tunnel_repository_for_path(database_path)?;
    repository
        .list_profile_records(session_id)
        .map_err(tunnel_db_error_to_ssh_runtime)
}

#[uniffi::export]
pub fn delete_tunnel_profile(
    database_path: String,
    profile_id: String,
) -> Result<(), SshRuntimeError> {
    let repository = tunnel_repository_for_path(database_path)?;
    repository
        .delete_profile(&profile_id)
        .map_err(tunnel_db_error_to_ssh_runtime)
}

#[uniffi::export]
pub fn start_mock_tunnel(
    profile: TunnelProfile,
    outcome: MockTunnelOutcome,
) -> Result<TunnelRuntimeStatus, TunnelError> {
    let channel = MockTunnelChannel::new(outcome);
    start_tunnel_target(profile, &channel)
}

#[uniffi::export]
pub fn start_live_local_tunnel_runtime(
    config: SshConnectionConfig,
    secret: SshAuthSecret,
    expected_fingerprint_sha256: String,
    profile: TunnelProfile,
) -> Result<TunnelRuntimeStatus, SshRuntimeError> {
    validate_ssh_config_target(config.clone())?;

    start_live_tunnel_pump_if_needed();
    let mut manager = recover_global_lock(live_tunnel_manager());
    let status = start_managed_tunnel_worker(&mut manager, profile, |profile| {
        let transport = Libssh2Transport::new();
        let session = transport
            .connect_with_secret_and_expected_session(
                &config,
                auth_secret_to_libssh2(secret),
                expected_fingerprint_sha256,
            )
            .map_err(ssh_runtime_error_to_tunnel_error)?;
        match profile.kind {
            TunnelKind::Local => {
                session.session().set_blocking(false);
                let acceptor =
                    TcpTunnelClientAcceptor::bind(&profile.local_host, profile.local_port)
                        .map_err(|_| TunnelError::LocalPortInUse)?;
                let opener = Libssh2DirectTcpIpOpener::new(session);
                Ok(LiveTunnelWorker::Local(LocalTunnelWorker::new(
                    profile.clone(),
                    acceptor,
                    opener,
                )))
            }
            TunnelKind::Dynamic => {
                session.session().set_blocking(false);
                let acceptor =
                    TcpTunnelClientAcceptor::bind(&profile.local_host, profile.local_port)
                        .map_err(|_| TunnelError::LocalPortInUse)?;
                let opener = Libssh2DirectTcpIpOpener::new(session);
                Ok(LiveTunnelWorker::Dynamic(DynamicSocksTunnelWorker::new(
                    profile.clone(),
                    acceptor,
                    opener,
                )))
            }
            TunnelKind::Remote => {
                let acceptor = Libssh2RemoteForwardListener::listen(session, profile)
                    .map_err(|_| TunnelError::SshFailed)?;
                let connector = TcpTunnelTargetConnector::new();
                Ok(LiveTunnelWorker::Remote(RemoteTunnelWorker::new(
                    profile.clone(),
                    acceptor,
                    connector,
                )))
            }
        }
    })
    .map_err(tunnel_error_to_ssh_runtime)?;
    notify_live_tunnel_pump();
    Ok(status)
}

#[uniffi::export]
pub fn poll_live_tunnel_runtime(profile_id: String) -> Result<TunnelRuntimeStatus, TunnelError> {
    recover_global_lock(live_tunnel_manager()).poll(profile_id)
}

#[uniffi::export]
pub fn close_live_tunnel_runtime(profile_id: String) -> Result<TunnelRuntimeStatus, TunnelError> {
    let status = recover_global_lock(live_tunnel_manager()).stop(profile_id)?;
    notify_live_tunnel_pump();
    Ok(status)
}

#[uniffi::export]
pub fn stop_tunnel_runtime(state: TunnelState) -> Result<TunnelState, TunnelError> {
    stop_tunnel_target(state)
}

fn tunnel_error_to_ssh_runtime(error: TunnelError) -> SshRuntimeError {
    match error {
        TunnelError::InvalidPort | TunnelError::InvalidTransition => SshRuntimeError::InvalidConfig,
        TunnelError::LocalPortInUse => SshRuntimeError::Transport {
            message: "TUNNEL_LOCAL_PORT_IN_USE".to_string(),
        },
        TunnelError::SshFailed => SshRuntimeError::Transport {
            message: "TUNNEL_SSH_FAILED".to_string(),
        },
    }
}

fn ssh_runtime_error_to_tunnel_error(error: SshRuntimeError) -> TunnelError {
    match error {
        SshRuntimeError::InvalidConfig => TunnelError::InvalidPort,
        _ => TunnelError::SshFailed,
    }
}

#[uniffi::export]
pub fn build_diagnostic_bundle(
    session_id: String,
    tunnel_id: Option<String>,
    entries: Vec<DiagnosticEntry>,
) -> DiagnosticBundle {
    build_diagnostic_bundle_target(session_id, tunnel_id, entries)
}

#[uniffi::export]
pub fn prepare_broadcast_input(
    targets: Vec<MultiExecTarget>,
    input: String,
    production_confirmed: bool,
) -> Result<BroadcastAuditEvent, MultiExecError> {
    prepare_broadcast_input_target(targets, &input, production_confirmed)
}

#[uniffi::export]
pub fn mark_broadcast_executed(event: BroadcastAuditEvent, sent_count: u32) -> BroadcastAuditEvent {
    mark_broadcast_executed_target(event, sent_count)
}

#[uniffi::export]
pub fn record_broadcast_audit_event(
    database_path: String,
    event: BroadcastAuditEvent,
) -> Result<BroadcastAuditRecord, SshRuntimeError> {
    let repository = audit_event_repository_for_path(database_path)?;
    repository
        .record_broadcast_event(&event)
        .map_err(transfer_db_error_to_ssh_runtime)
}

#[uniffi::export]
pub fn list_broadcast_audit_records(
    database_path: String,
    limit: u32,
) -> Result<Vec<BroadcastAuditRecord>, SshRuntimeError> {
    let repository = audit_event_repository_for_path(database_path)?;
    repository
        .list_broadcast_events(limit)
        .map_err(transfer_db_error_to_ssh_runtime)
}

#[uniffi::export]
pub fn record_agent_action_event(
    database_path: String,
    event: AgentActionAuditEvent,
) -> Result<AgentActionAuditRecord, SshRuntimeError> {
    validate_agent_action_audit_event(&event)
        .map_err(|message| SshRuntimeError::Transport { message })?;
    let repository = agent_action_audit_repository_for_path(database_path)?;
    repository
        .record(&event)
        .map_err(transfer_db_error_to_ssh_runtime)
}

#[uniffi::export]
pub fn list_agent_action_events(
    database_path: String,
    limit: u32,
) -> Result<Vec<AgentActionAuditRecord>, SshRuntimeError> {
    let repository = agent_action_audit_repository_for_path(database_path)?;
    repository
        .list(limit)
        .map_err(transfer_db_error_to_ssh_runtime)
}

#[uniffi::export]
pub fn record_agent_task_session(
    database_path: String,
    session: AgentTaskSessionDraft,
    proposals: Vec<AgentTaskProposalDraft>,
) -> Result<AgentTaskSessionRecord, SshRuntimeError> {
    let repository = agent_task_repository_for_path(database_path)?;
    repository
        .record_session(&session, proposals)
        .map_err(transfer_db_error_to_ssh_runtime)
}

#[uniffi::export]
pub fn list_agent_task_sessions(
    database_path: String,
    limit: u32,
) -> Result<Vec<AgentTaskSessionRecord>, SshRuntimeError> {
    let repository = agent_task_repository_for_path(database_path)?;
    repository
        .list_recent(limit)
        .map_err(transfer_db_error_to_ssh_runtime)
}

#[uniffi::export]
pub fn list_agent_task_sessions_by_request_id(
    database_path: String,
    request_id: String,
) -> Result<Vec<AgentTaskSessionRecord>, SshRuntimeError> {
    let repository = agent_task_repository_for_path(database_path)?;
    repository
        .list_by_request_id(&request_id)
        .map_err(transfer_db_error_to_ssh_runtime)
}

#[uniffi::export]
pub fn append_ai_conversation_history_item(
    database_path: String,
    item: AIConversationHistoryItemDraft,
) -> Result<AIConversationHistoryItemRecord, SshRuntimeError> {
    let repository = ai_conversation_history_repository_for_path(database_path)?;
    repository
        .append(&item)
        .map_err(transfer_db_error_to_ssh_runtime)
}

#[uniffi::export]
pub fn list_ai_conversation_history(
    database_path: String,
    runtime_id: String,
) -> Result<Vec<AIConversationHistoryItemRecord>, SshRuntimeError> {
    let repository = ai_conversation_history_repository_for_path(database_path)?;
    repository
        .list(&runtime_id)
        .map_err(transfer_db_error_to_ssh_runtime)
}

#[uniffi::export]
pub fn clear_ai_conversation_history(database_path: String) -> Result<(), SshRuntimeError> {
    let repository = ai_conversation_history_repository_for_path(database_path)?;
    repository
        .clear_all()
        .map_err(transfer_db_error_to_ssh_runtime)
}

#[uniffi::export]
pub fn create_terminal_macro(
    database_path: String,
    name: String,
    steps: Vec<MacroStep>,
) -> Result<TerminalMacroRecord, SshRuntimeError> {
    let repository = terminal_macro_repository_for_path(database_path)?;
    repository
        .create(&name, steps)
        .map_err(terminal_macro_error_to_ssh_runtime)
}

#[uniffi::export]
pub fn list_terminal_macros(
    database_path: String,
) -> Result<Vec<TerminalMacroRecord>, SshRuntimeError> {
    let repository = terminal_macro_repository_for_path(database_path)?;
    repository
        .list()
        .map_err(terminal_macro_error_to_ssh_runtime)
}

#[uniffi::export]
pub fn update_terminal_macro(
    database_path: String,
    macro_id: String,
    name: String,
    steps: Vec<MacroStep>,
) -> Result<TerminalMacroRecord, SshRuntimeError> {
    let repository = terminal_macro_repository_for_path(database_path)?;
    repository
        .update(&macro_id, &name, steps)
        .map_err(terminal_macro_error_to_ssh_runtime)
}

#[uniffi::export]
pub fn rename_terminal_macro(
    database_path: String,
    macro_id: String,
    name: String,
) -> Result<TerminalMacroRecord, SshRuntimeError> {
    let repository = terminal_macro_repository_for_path(database_path)?;
    repository
        .rename(&macro_id, &name)
        .map_err(terminal_macro_error_to_ssh_runtime)
}

#[uniffi::export]
pub fn delete_terminal_macro(
    database_path: String,
    macro_id: String,
) -> Result<(), SshRuntimeError> {
    let repository = terminal_macro_repository_for_path(database_path)?;
    repository
        .delete(&macro_id)
        .map_err(terminal_macro_error_to_ssh_runtime)
}

#[uniffi::export]
pub fn serialize_macro_recording(recording: MacroRecording) -> Result<String, MacroError> {
    serialize_macro_recording_target(recording)
}

#[uniffi::export]
pub fn playback_macro_steps(recording: MacroRecording) -> Vec<MacroStep> {
    playback_macro_steps_target(recording)
}

#[uniffi::export]
pub fn x11_forwarding_arguments(enable_x11: bool, trusted: bool) -> Vec<String> {
    x11_forwarding_arguments_target(enable_x11, trusted)
}

#[uniffi::export]
pub fn diagnose_x11(input: X11ProbeInput) -> GraphicsDiagnostic {
    diagnose_x11_target(input)
}

#[uniffi::export]
pub fn build_vnc_launch_config(
    config: GraphicsAdapterConfig,
) -> Result<GraphicsLaunchConfig, GraphicsConfigError> {
    build_vnc_launch_config_target(config)
}

uniffi::setup_scaffolding!();

#[cfg(test)]
mod tests {
    use super::health;

    #[test]
    fn health_contains_app_version_and_architecture() {
        let value = health();

        assert_eq!(value.ok, true);
        assert_eq!(value.app, "Stacio");
        assert_eq!(value.version, env!("CARGO_PKG_VERSION"));
        assert_eq!(value.architecture, "swift-appkit-rust-core");
    }

    #[test]
    fn live_remote_file_write_uses_transfer_session() {
        let source = include_str!("lib.rs");
        let start = source
            .find("pub fn write_live_remote_file")
            .expect("write_live_remote_file source");
        let rest = &source[start..];
        let end = rest
            .find("fn apply_live_remote_file_operation")
            .expect("next function source");
        let write_function = &rest[..end];

        assert!(
            write_function.contains("connect_with_secret_and_expected_transfer_session"),
            "write_live_remote_file must use the transfer session so file writes inherit transfer tuning"
        );
        assert!(
            !write_function.contains("connect_with_secret_and_expected_session("),
            "write_live_remote_file must not fall back to the generic SSH session"
        );
    }
}

#[cfg(test)]
mod terminal_api_tests {
    use super::{
        close_terminal_runtime, open_local_shell_runtime, record_terminal_output,
        record_terminal_resize, take_terminal_output_batch, terminal_registry,
    };
    use std::panic::{catch_unwind, AssertUnwindSafe};

    #[test]
    fn exported_terminal_api_records_resize_output_and_close() {
        let runtime = open_local_shell_runtime("/bin/zsh".to_string(), 80, 24);
        let resized = record_terminal_resize(runtime.id.clone(), 100, 32).expect("resize");

        assert_eq!(resized.cols, 100);
        assert_eq!(resized.rows, 32);

        record_terminal_output(runtime.id.clone(), vec![65, 66, 67]).expect("record output");
        let batch = take_terminal_output_batch(runtime.id.clone()).expect("take output");
        assert_eq!(batch.bytes, vec![65, 66, 67]);

        let closed = close_terminal_runtime(runtime.id).expect("close");
        assert_eq!(closed.status, "closed");
    }

    #[test]
    fn exported_terminal_api_recovers_after_global_registry_lock_poison() {
        let poison_result = catch_unwind(AssertUnwindSafe(|| {
            let _guard = terminal_registry()
                .lock()
                .expect("terminal registry lock for poison regression");
            panic!("poison terminal registry lock for regression");
        }));
        assert!(poison_result.is_err());

        let runtime_result = catch_unwind(AssertUnwindSafe(|| {
            open_local_shell_runtime("/bin/zsh".to_string(), 80, 24)
        }));

        let runtime = runtime_result.expect("terminal API should recover poisoned registry lock");
        let closed = close_terminal_runtime(runtime.id).expect("close recovered runtime");
        assert_eq!(closed.status, "closed");
    }
}

#[cfg(test)]
mod live_shell_api_tests {
    use super::{
        append_scp_transfer_progress, cancel_live_ftp_transfer, cancel_live_scp_transfer,
        chmod_live_remote_path, clear_finished_scp_transfer_jobs, close_live_ssh_shell,
        close_terminal_runtime, create_live_remote_directory, delete_live_remote_path,
        list_live_remote_directory, list_scp_transfer_events, list_scp_transfer_jobs,
        open_remote_ssh_runtime, poll_live_ssh_shell, record_scp_transfer_job,
        rename_live_remote_path, run_live_ftp_transfer, run_live_scp_transfer,
        start_live_serial_shell_runtime, start_live_telnet_shell_runtime,
        take_live_scp_transfer_progress_batch, take_terminal_output_batch, write_terminal_input,
    };
    use crate::domain::ftp::{FtpAuthSecret, FtpConnectionConfig};
    use crate::domain::scp::{ScpDirection, ScpTransferJob};
    use crate::domain::serial::SerialConnectionConfig;
    use crate::domain::ssh::{SshAuthMethod, SshAuthSecret, SshConnectionConfig, SshRuntimeError};
    use crate::domain::telnet::TelnetConnectionConfig;
    use crate::domain::terminal::TerminalRuntimeError;
    use std::{
        io::{BufRead, BufReader, Write},
        net::{TcpListener, TcpStream},
        sync::{mpsc, Arc, Mutex},
        thread,
        time::{Duration, Instant},
    };

    #[test]
    fn close_live_shell_closes_runtime_without_stored_worker() {
        let runtime =
            open_remote_ssh_runtime("example.com".to_string(), 22, "deploy".to_string(), 80, 24);

        let status = close_live_ssh_shell(runtime.id.clone()).expect("close live shell");
        let error = write_terminal_input(runtime.id.clone(), b"pwd\n".to_vec())
            .expect_err("closed runtime rejects input");

        assert_eq!(status.status, "closed");
        assert_eq!(
            error,
            TerminalRuntimeError::RuntimeClosed {
                runtime_id: runtime.id
            }
        );
    }

    #[test]
    fn poll_live_shell_returns_not_running_when_runtime_has_no_worker() {
        let runtime =
            open_remote_ssh_runtime("example.com".to_string(), 22, "deploy".to_string(), 80, 24);

        let status = poll_live_ssh_shell(runtime.id.clone()).expect("poll live shell");

        assert_eq!(status.runtime_id, runtime.id);
        assert_eq!(status.status, "not_running");
    }

    #[test]
    fn poll_live_shell_reports_closed_for_closed_runtime_without_worker() {
        let runtime =
            open_remote_ssh_runtime("example.com".to_string(), 22, "deploy".to_string(), 80, 24);
        close_terminal_runtime(runtime.id.clone()).expect("close runtime");

        let status = poll_live_ssh_shell(runtime.id.clone()).expect("poll live shell");

        assert_eq!(status.runtime_id, runtime.id);
        assert_eq!(status.status, "closed");
    }

    fn take_output_until_non_empty(runtime_id: &str) -> Vec<u8> {
        let deadline = Instant::now() + Duration::from_secs(2);
        while Instant::now() < deadline {
            let batch = take_terminal_output_batch(runtime_id.to_string()).expect("take output");
            if !batch.bytes.is_empty() {
                return batch.bytes;
            }
            thread::sleep(Duration::from_millis(10));
        }
        Vec::new()
    }

    #[test]
    fn start_live_telnet_shell_runtime_rejects_invalid_config() {
        let error = start_live_telnet_shell_runtime(
            TelnetConnectionConfig {
                host: "".to_string(),
                port: 23,
                username: Some("admin".to_string()),
                connect_timeout_ms: 10_000,
            },
            80,
            24,
        )
        .expect_err("invalid telnet config");

        assert_eq!(error, SshRuntimeError::InvalidConfig);
    }

    #[test]
    fn start_live_telnet_shell_runtime_streams_filtered_output() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind telnet fixture");
        let port = listener.local_addr().expect("fixture addr").port();
        let (ready_tx, ready_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept telnet");
            stream
                .write_all(&[255, 251, 1, b'l', b'o', b'g', b'i', b'n', b':', b' '])
                .expect("write telnet fixture");
            stream.flush().expect("flush telnet fixture");
            ready_tx.send(()).expect("notify telnet fixture ready");
            let _ = release_rx.recv_timeout(Duration::from_secs(2));
        });

        let status = start_live_telnet_shell_runtime(
            TelnetConnectionConfig {
                host: "127.0.0.1".to_string(),
                port,
                username: Some("admin".to_string()),
                connect_timeout_ms: 2_000,
            },
            80,
            24,
        )
        .expect("start telnet runtime");
        ready_rx
            .recv_timeout(Duration::from_secs(2))
            .expect("telnet fixture wrote greeting");
        let output = take_output_until_non_empty(&status.runtime_id);
        release_tx.send(()).expect("release telnet fixture");
        server.join().expect("server joined");

        assert_eq!(status.status, "running");
        assert_eq!(output, b"login: ".to_vec());
    }

    #[test]
    fn start_live_serial_shell_runtime_rejects_invalid_config() {
        let error = start_live_serial_shell_runtime(
            SerialConnectionConfig {
                device_path: "".to_string(),
                baud_rate: 9_600,
                data_bits: 8,
                stop_bits: 1,
                parity: "none".to_string(),
                flow_control: "none".to_string(),
                backspace_mode: "del".to_string(),
            },
            80,
            24,
        )
        .expect_err("invalid serial config");

        assert_eq!(error, SshRuntimeError::InvalidConfig);
    }

    #[test]
    fn live_scp_transfer_rejects_invalid_config_before_network() {
        let config = SshConnectionConfig {
            host: "".to_string(),
            port: 22,
            username: "deploy".to_string(),
            auth_method: SshAuthMethod::Agent,
            connect_timeout_ms: 10_000,
        };
        let job = ScpTransferJob {
            id: "job_invalid".to_string(),
            direction: ScpDirection::Download,
            source_path: "/remote/file.txt".to_string(),
            destination_path: "/local/file.txt".to_string(),
            bytes_total: 0,
        };

        let error =
            run_live_scp_transfer(config, SshAuthSecret::Agent, "SHA256:test".to_string(), job)
                .expect_err("invalid config");

        assert_eq!(error, SshRuntimeError::InvalidConfig);
    }

    #[test]
    fn live_ftp_transfer_rejects_invalid_config_before_network() {
        let config = FtpConnectionConfig {
            host: "".to_string(),
            port: 21,
            username: "deploy".to_string(),
            connect_timeout_ms: 10_000,
        };
        let job = ScpTransferJob {
            id: "ftp_invalid".to_string(),
            direction: ScpDirection::Download,
            source_path: "/pub/file.txt".to_string(),
            destination_path: "/tmp/file.txt".to_string(),
            bytes_total: 0,
        };

        let error = run_live_ftp_transfer(
            config,
            FtpAuthSecret::Password {
                value: "top-secret".to_string(),
            },
            job,
        )
        .expect_err("invalid ftp config");

        assert_eq!(error, SshRuntimeError::InvalidConfig);
        assert!(!format!("{error:?}").contains("top-secret"));
    }

    #[test]
    fn live_scp_cancel_marks_job_for_interruption() {
        assert!(cancel_live_scp_transfer("job_cancel".to_string()).expect("cancel"));
    }

    #[test]
    fn live_ftp_cancel_marks_job_for_interruption() {
        assert!(cancel_live_ftp_transfer("ftp_cancel".to_string()).expect("cancel"));
        assert!(!cancel_live_ftp_transfer("   ".to_string()).expect("cancel"));
    }

    #[test]
    fn live_ftp_transfer_clears_cancel_marker_after_invalid_config_failure() {
        use crate::services::scp_service::is_live_scp_transfer_cancelled;

        let config = FtpConnectionConfig {
            host: "".to_string(),
            port: 21,
            username: "deploy".to_string(),
            connect_timeout_ms: 10_000,
        };
        let job = ScpTransferJob {
            id: "ftp_invalid_canceled".to_string(),
            direction: ScpDirection::Download,
            source_path: "/pub/file.txt".to_string(),
            destination_path: "/tmp/file.txt".to_string(),
            bytes_total: 0,
        };

        assert!(cancel_live_ftp_transfer(job.id.clone()).expect("cancel"));
        let error = run_live_ftp_transfer(config, FtpAuthSecret::Anonymous, job)
            .expect_err("invalid ftp config");

        assert_eq!(error, SshRuntimeError::InvalidConfig);
        assert!(!is_live_scp_transfer_cancelled("ftp_invalid_canceled"));
    }

    #[test]
    fn live_ftp_download_resumes_from_stacio_partial_file() {
        let temp = tempfile::tempdir().expect("temp dir");
        let destination_path = temp.path().join("app.bin");
        let partial_path = temp.path().join("app.bin.staciopart");
        std::fs::write(&partial_path, b"hello ").expect("write partial");
        let server = FakeLiveFtpServer::resume_download(b"ftp".to_vec(), 9, 6);
        let job = ScpTransferJob {
            id: "ftp_resume_download".to_string(),
            direction: ScpDirection::Download,
            source_path: "/pub/app.bin".to_string(),
            destination_path: destination_path.to_string_lossy().to_string(),
            bytes_total: 0,
        };

        let progress = run_live_ftp_transfer(
            server.config(),
            FtpAuthSecret::Password {
                value: "top-secret".to_string(),
            },
            job,
        )
        .expect("ftp resume download");

        assert_eq!(
            std::fs::read(&destination_path).expect("read final"),
            b"hello ftp"
        );
        assert!(!partial_path.exists());
        assert_eq!(progress.last().map(|event| event.bytes_done), Some(9));
        assert_eq!(progress.last().map(|event| event.bytes_total), Some(9));
        assert_eq!(
            server.commands(),
            vec![
                "USER deploy",
                "PASS top-secret",
                "TYPE I",
                "SIZE /pub/app.bin",
                "PASV",
                "REST 6",
                "RETR /pub/app.bin"
            ]
        );
        server.join();
    }

    #[test]
    fn live_ftp_download_rejects_partial_file_larger_than_remote() {
        let temp = tempfile::tempdir().expect("temp dir");
        let destination_path = temp.path().join("app.bin");
        let partial_path = temp.path().join("app.bin.staciopart");
        std::fs::write(&partial_path, b"hello ftp extra").expect("write partial");
        let server = FakeLiveFtpServer::size_only(9);
        let job = ScpTransferJob {
            id: "ftp_resume_too_large".to_string(),
            direction: ScpDirection::Download,
            source_path: "/pub/app.bin".to_string(),
            destination_path: destination_path.to_string_lossy().to_string(),
            bytes_total: 0,
        };

        let error = run_live_ftp_transfer(
            server.config(),
            FtpAuthSecret::Password {
                value: "top-secret".to_string(),
            },
            job,
        )
        .expect_err("partial larger than remote");

        assert_eq!(
            error,
            SshRuntimeError::Transport {
                message: "FILES_SIZE_MISMATCH".to_string()
            }
        );
        assert!(!destination_path.exists());
        assert!(partial_path.exists());
        assert_eq!(
            server.commands(),
            vec![
                "USER deploy",
                "PASS top-secret",
                "TYPE I",
                "SIZE /pub/app.bin"
            ]
        );
        server.join();
    }

    #[test]
    fn live_scp_progress_batch_returns_empty_for_missing_job() {
        let progress =
            take_live_scp_transfer_progress_batch("job_missing".to_string()).expect("progress");

        assert!(progress.is_empty());
    }

    #[test]
    fn live_scp_transfer_preserves_preflight_cancel_marker_until_copy_scope() {
        use crate::services::scp_service::{
            is_live_scp_transfer_cancelled, with_live_scp_transfer_cancellation_scope,
        };

        assert!(cancel_live_scp_transfer("job_preflight_cancel".to_string()).expect("cancel"));
        assert!(is_live_scp_transfer_cancelled("job_preflight_cancel"));

        with_live_scp_transfer_cancellation_scope("job_preflight_cancel", || {
            assert!(is_live_scp_transfer_cancelled("job_preflight_cancel"));
        });

        assert!(!is_live_scp_transfer_cancelled("job_preflight_cancel"));
    }

    #[test]
    fn live_scp_transfer_clears_cancel_marker_after_invalid_config_failure() {
        use crate::services::scp_service::is_live_scp_transfer_cancelled;

        let config = SshConnectionConfig {
            host: "".to_string(),
            port: 22,
            username: "deploy".to_string(),
            auth_method: SshAuthMethod::Agent,
            connect_timeout_ms: 10_000,
        };
        let job = ScpTransferJob {
            id: "job_invalid_canceled".to_string(),
            direction: ScpDirection::Download,
            source_path: "/remote/file.txt".to_string(),
            destination_path: "/local/file.txt".to_string(),
            bytes_total: 0,
        };

        assert!(cancel_live_scp_transfer(job.id.clone()).expect("cancel"));
        let error =
            run_live_scp_transfer(config, SshAuthSecret::Agent, "SHA256:test".to_string(), job)
                .expect_err("invalid config");

        assert_eq!(error, SshRuntimeError::InvalidConfig);
        assert!(!is_live_scp_transfer_cancelled("job_invalid_canceled"));
    }

    #[test]
    fn live_remote_listing_rejects_invalid_config_before_network() {
        let config = SshConnectionConfig {
            host: "".to_string(),
            port: 22,
            username: "deploy".to_string(),
            auth_method: SshAuthMethod::Agent,
            connect_timeout_ms: 10_000,
        };

        let error = list_live_remote_directory(
            config,
            SshAuthSecret::Agent,
            "SHA256:test".to_string(),
            "/var/log".to_string(),
        )
        .expect_err("invalid config");

        assert_eq!(error, SshRuntimeError::InvalidConfig);
    }

    #[test]
    fn live_remote_file_operations_reject_invalid_config_before_network() {
        let config = SshConnectionConfig {
            host: "".to_string(),
            port: 22,
            username: "deploy".to_string(),
            auth_method: SshAuthMethod::Agent,
            connect_timeout_ms: 10_000,
        };

        let mkdir_error = create_live_remote_directory(
            config.clone(),
            SshAuthSecret::Agent,
            "SHA256:test".to_string(),
            "/srv/app/new".to_string(),
        )
        .expect_err("invalid config");
        let rename_error = rename_live_remote_path(
            config.clone(),
            SshAuthSecret::Agent,
            "SHA256:test".to_string(),
            "/srv/app/old".to_string(),
            "/srv/app/new".to_string(),
        )
        .expect_err("invalid config");
        let delete_error = delete_live_remote_path(
            config.clone(),
            SshAuthSecret::Agent,
            "SHA256:test".to_string(),
            "/srv/app/tmp".to_string(),
            true,
        )
        .expect_err("invalid config");
        let chmod_error = chmod_live_remote_path(
            config,
            SshAuthSecret::Agent,
            "SHA256:test".to_string(),
            "/srv/app/run.sh".to_string(),
            "755".to_string(),
        )
        .expect_err("invalid config");

        assert_eq!(mkdir_error, SshRuntimeError::InvalidConfig);
        assert_eq!(rename_error, SshRuntimeError::InvalidConfig);
        assert_eq!(delete_error, SshRuntimeError::InvalidConfig);
        assert_eq!(chmod_error, SshRuntimeError::InvalidConfig);
    }

    #[test]
    fn transfer_history_bridge_persists_jobs_and_events() {
        let temp = tempfile::NamedTempFile::new().expect("temp database");
        let database_path = temp.path().to_string_lossy().to_string();
        let job = ScpTransferJob {
            id: "job_history_bridge".to_string(),
            direction: ScpDirection::Upload,
            source_path: "/local/archive.tar".to_string(),
            destination_path: "/remote/archive.tar".to_string(),
            bytes_total: 256,
        };

        record_scp_transfer_job(
            database_path.clone(),
            None,
            job.clone(),
            "queued".to_string(),
            0,
        )
        .expect("record job");
        let event = append_scp_transfer_progress(
            database_path.clone(),
            crate::domain::scp::ScpTransferProgress {
                job_id: job.id.clone(),
                bytes_done: 256,
                bytes_total: 256,
                status: "completed".to_string(),
            },
        )
        .expect("append progress");

        let jobs = list_scp_transfer_jobs(database_path.clone()).expect("jobs");
        let events = list_scp_transfer_events(database_path, job.id.clone()).expect("events");

        assert_eq!(event.event_type, "completed");
        assert_eq!(jobs[0].job, job);
        assert_eq!(jobs[0].status, "completed");
        assert_eq!(events.len(), 1);
    }

    #[test]
    fn transfer_history_bridge_clears_finished_jobs_and_events() {
        let temp = tempfile::NamedTempFile::new().expect("temp database");
        let database_path = temp.path().to_string_lossy().to_string();
        let completed_job = ScpTransferJob {
            id: "job_completed_bridge_clear".to_string(),
            direction: ScpDirection::Upload,
            source_path: "/local/completed.tar".to_string(),
            destination_path: "/remote/completed.tar".to_string(),
            bytes_total: 100,
        };
        let queued_job = ScpTransferJob {
            id: "job_queued_bridge_keep".to_string(),
            direction: ScpDirection::Download,
            source_path: "/remote/queued.tar".to_string(),
            destination_path: "/local/queued.tar".to_string(),
            bytes_total: 200,
        };

        record_scp_transfer_job(
            database_path.clone(),
            None,
            completed_job.clone(),
            "queued".to_string(),
            0,
        )
        .expect("record completed job");
        append_scp_transfer_progress(
            database_path.clone(),
            crate::domain::scp::ScpTransferProgress {
                job_id: completed_job.id.clone(),
                bytes_done: 100,
                bytes_total: 100,
                status: "completed".to_string(),
            },
        )
        .expect("append completed progress");
        record_scp_transfer_job(
            database_path.clone(),
            None,
            queued_job.clone(),
            "queued".to_string(),
            0,
        )
        .expect("record queued job");

        let deleted =
            clear_finished_scp_transfer_jobs(database_path.clone()).expect("clear finished jobs");
        let jobs = list_scp_transfer_jobs(database_path.clone()).expect("jobs");
        let completed_events =
            list_scp_transfer_events(database_path, completed_job.id).expect("events");

        assert_eq!(deleted, 1);
        assert_eq!(jobs.len(), 1);
        assert_eq!(jobs[0].job, queued_job);
        assert!(completed_events.is_empty());
    }

    struct FakeLiveFtpServer {
        port: u16,
        commands: Arc<Mutex<Vec<String>>>,
        handle: thread::JoinHandle<()>,
    }

    enum FakeLiveFtpScenario {
        ResumeDownload {
            bytes: Vec<u8>,
            remote_size: u64,
            offset: u64,
        },
        SizeOnly(u64),
    }

    impl FakeLiveFtpServer {
        fn resume_download(bytes: Vec<u8>, remote_size: u64, offset: u64) -> Self {
            Self::spawn(FakeLiveFtpScenario::ResumeDownload {
                bytes,
                remote_size,
                offset,
            })
        }

        fn size_only(remote_size: u64) -> Self {
            Self::spawn(FakeLiveFtpScenario::SizeOnly(remote_size))
        }

        fn spawn(scenario: FakeLiveFtpScenario) -> Self {
            let listener = TcpListener::bind(("127.0.0.1", 0)).expect("bind ftp control");
            let port = listener.local_addr().expect("control addr").port();
            let commands = Arc::new(Mutex::new(Vec::new()));
            let server_commands = Arc::clone(&commands);
            let handle = thread::spawn(move || {
                let (mut control, _) = listener.accept().expect("accept ftp control");
                control
                    .set_read_timeout(Some(Duration::from_secs(2)))
                    .expect("set read timeout");
                control
                    .set_write_timeout(Some(Duration::from_secs(2)))
                    .expect("set write timeout");
                control
                    .write_all(b"220 fake ftp ready\r\n")
                    .expect("banner");
                let mut reader = BufReader::new(control.try_clone().expect("clone control"));
                expect_live_ftp_command(&mut reader, &server_commands, "USER deploy");
                control
                    .write_all(b"331 password required\r\n")
                    .expect("user");
                expect_live_ftp_command(&mut reader, &server_commands, "PASS top-secret");
                control.write_all(b"230 logged in\r\n").expect("pass");
                expect_live_ftp_command(&mut reader, &server_commands, "TYPE I");
                control.write_all(b"200 binary type\r\n").expect("type");

                match scenario {
                    FakeLiveFtpScenario::ResumeDownload {
                        bytes,
                        remote_size,
                        offset,
                    } => {
                        expect_live_ftp_command(&mut reader, &server_commands, "SIZE /pub/app.bin");
                        write!(control, "213 {remote_size}\r\n").expect("size response");
                        let data_listener = enter_live_ftp_passive_mode(
                            &mut reader,
                            &server_commands,
                            &mut control,
                        );
                        expect_live_ftp_command(
                            &mut reader,
                            &server_commands,
                            &format!("REST {offset}"),
                        );
                        control
                            .write_all(b"350 restart position accepted\r\n")
                            .expect("rest 350");
                        expect_live_ftp_command(&mut reader, &server_commands, "RETR /pub/app.bin");
                        control
                            .write_all(b"150 opening data\r\n")
                            .expect("retr 150");
                        let (mut data, _) = data_listener.accept().expect("accept retr data");
                        data.write_all(&bytes).expect("write data");
                        drop(data);
                        control
                            .write_all(b"226 transfer complete\r\n")
                            .expect("retr 226");
                    }
                    FakeLiveFtpScenario::SizeOnly(remote_size) => {
                        expect_live_ftp_command(&mut reader, &server_commands, "SIZE /pub/app.bin");
                        write!(control, "213 {remote_size}\r\n").expect("size response");
                    }
                }
            });
            Self {
                port,
                commands,
                handle,
            }
        }

        fn config(&self) -> FtpConnectionConfig {
            FtpConnectionConfig {
                host: "127.0.0.1".to_string(),
                port: self.port,
                username: "deploy".to_string(),
                connect_timeout_ms: 2_000,
            }
        }

        fn commands(&self) -> Vec<String> {
            self.commands.lock().expect("commands lock").clone()
        }

        fn join(self) {
            self.handle.join().expect("ftp server thread");
        }
    }

    fn expect_live_ftp_command(
        reader: &mut BufReader<TcpStream>,
        commands: &Arc<Mutex<Vec<String>>>,
        expected: &str,
    ) {
        let mut line = String::new();
        reader.read_line(&mut line).expect("read command");
        let command = line.trim_end_matches(['\r', '\n']).to_string();
        assert_eq!(command, expected);
        commands.lock().expect("commands lock").push(command);
    }

    fn enter_live_ftp_passive_mode(
        reader: &mut BufReader<TcpStream>,
        commands: &Arc<Mutex<Vec<String>>>,
        control: &mut TcpStream,
    ) -> TcpListener {
        expect_live_ftp_command(reader, commands, "PASV");
        let data_listener = TcpListener::bind(("127.0.0.1", 0)).expect("bind data");
        let port = data_listener.local_addr().expect("data addr").port();
        let high = port / 256;
        let low = port % 256;
        write!(
            control,
            "227 Entering Passive Mode (127,0,0,1,{high},{low}).\r\n"
        )
        .expect("pasv response");
        data_listener
    }
}

#[cfg(test)]
mod session_api_tests {
    use crate::domain::agent::{
        AgentActionAuditEvent, AgentTaskProposalDraft, AgentTaskSessionDraft,
    };
    use crate::domain::credential::CredentialDraft;
    use crate::domain::multiexec::MultiExecTarget;
    use crate::domain::session::{SessionDraft, SessionUpdate};
    use crate::services::import_service::preview_stacio_json_import;

    #[test]
    fn session_bridge_persists_folders_and_sessions() {
        let temp = tempfile::NamedTempFile::new().expect("temp database");
        let database_path = temp.path().to_string_lossy().to_string();

        let folder =
            super::create_session_folder(database_path.clone(), None, "Production".to_string())
                .expect("create folder");
        let session = super::create_session_record(
            database_path.clone(),
            SessionDraft {
                folder_id: Some(folder.id.clone()),
                name: "API Server".to_string(),
                protocol: "ssh".to_string(),
                host: "api.example.com".to_string(),
                port: 22,
                username: Some("deploy".to_string()),
                private_key_path: None,
                credential_id: None,
                tags: vec!["prod".to_string()],
                config_json: None,
            },
        )
        .expect("create session");

        let folders = super::list_session_folders(database_path.clone()).expect("list folders");
        let sessions =
            super::list_session_records(database_path, Some(folder.id.clone())).expect("sessions");

        assert_eq!(folders, vec![folder]);
        assert_eq!(sessions, vec![session]);
    }

    #[test]
    fn session_bridge_lists_and_places_mixed_sidebar_items() {
        let temp = tempfile::NamedTempFile::new().expect("temp database");
        let database_path = temp.path().to_string_lossy().to_string();
        let root_a = super::create_session_record(
            database_path.clone(),
            SessionDraft {
                folder_id: None,
                name: "Root A".to_string(),
                protocol: "ssh".to_string(),
                host: "a.example.com".to_string(),
                port: 22,
                username: None,
                private_key_path: None,
                credential_id: None,
                tags: vec![],
                config_json: None,
            },
        )
        .expect("create first root session");
        let folder =
            super::create_session_folder(database_path.clone(), None, "Production".to_string())
                .expect("create folder");
        let root_b = super::create_session_record(
            database_path.clone(),
            SessionDraft {
                folder_id: None,
                name: "Root B".to_string(),
                protocol: "ssh".to_string(),
                host: "b.example.com".to_string(),
                port: 22,
                username: None,
                private_key_path: None,
                credential_id: None,
                tags: vec![],
                config_json: None,
            },
        )
        .expect("create second root session");

        let initial = super::list_session_sidebar_order(database_path.clone())
            .expect("list initial sidebar order");
        assert_eq!(
            initial
                .iter()
                .map(|item| item.id.as_str())
                .collect::<Vec<_>>(),
            vec![root_a.id.as_str(), folder.id.as_str(), root_b.id.as_str()]
        );
        super::place_session_sidebar_item(
            database_path.clone(),
            "folder".to_string(),
            folder.id.clone(),
            None,
            0,
        )
        .expect("reorder folder");
        let placed = super::place_session_sidebar_item(
            database_path.clone(),
            "session".to_string(),
            root_b.id.clone(),
            Some(folder.id.clone()),
            0,
        )
        .expect("move session into folder");
        let reordered =
            super::list_session_sidebar_order(database_path).expect("list reordered sidebar order");

        assert_eq!(placed.parent_id, Some(folder.id.clone()));
        assert_eq!(
            reordered
                .iter()
                .filter(|item| item.parent_id.is_none())
                .map(|item| item.id.as_str())
                .collect::<Vec<_>>(),
            vec![folder.id.as_str(), root_a.id.as_str()]
        );
        assert_eq!(
            reordered
                .iter()
                .filter(|item| item.parent_id.as_deref() == Some(folder.id.as_str()))
                .map(|item| item.id.as_str())
                .collect::<Vec<_>>(),
            vec![root_b.id.as_str()]
        );
    }

    #[test]
    fn session_bridge_manages_nested_folders_and_exports_subtree() {
        let temp = tempfile::NamedTempFile::new().expect("temp database");
        let database_path = temp.path().to_string_lossy().to_string();

        let production =
            super::create_session_folder(database_path.clone(), None, "Production".to_string())
                .expect("production folder");
        let database = super::create_session_folder(
            database_path.clone(),
            Some(production.id.clone()),
            "Database".to_string(),
        )
        .expect("database folder");
        let primary = super::create_session_folder(
            database_path.clone(),
            Some(database.id.clone()),
            "Primary".to_string(),
        )
        .expect("primary folder");
        let lab = super::create_session_folder(database_path.clone(), None, "Lab".to_string())
            .expect("lab folder");
        let renamed = super::rename_session_folder(
            database_path.clone(),
            database.id.clone(),
            "DB".to_string(),
        )
        .expect("rename folder");
        super::create_session_record(
            database_path.clone(),
            SessionDraft {
                folder_id: Some(primary.id),
                name: "Primary DB".to_string(),
                protocol: "ssh".to_string(),
                host: "db.example.com".to_string(),
                port: 22,
                username: Some("deploy".to_string()),
                private_key_path: None,
                credential_id: None,
                tags: vec![],
                config_json: None,
            },
        )
        .expect("create primary session");
        super::create_session_record(
            database_path.clone(),
            SessionDraft {
                folder_id: Some(lab.id.clone()),
                name: "Lab Box".to_string(),
                protocol: "ssh".to_string(),
                host: "lab.example.com".to_string(),
                port: 22,
                username: Some("ops".to_string()),
                private_key_path: None,
                credential_id: None,
                tags: vec![],
                config_json: None,
            },
        )
        .expect("create lab session");

        let json = super::export_session_folder_json(database_path.clone(), production.id.clone())
            .expect("export folder");
        super::delete_session_folder(database_path.clone(), lab.id).expect("delete lab folder");
        let root_sessions =
            super::list_session_records(database_path.clone(), None).expect("root sessions");

        assert_eq!(renamed.name, "DB");
        assert!(json.contains("Production"));
        assert!(json.contains("DB"));
        assert!(json.contains("Primary"));
        assert!(json.contains("Primary DB"));
        assert!(!json.contains("Lab Box"));
        assert!(root_sessions
            .iter()
            .any(|session| session.name == "Lab Box"));
    }

    #[test]
    fn session_bridge_updates_and_deletes_session_records() {
        let temp = tempfile::NamedTempFile::new().expect("temp database");
        let database_path = temp.path().to_string_lossy().to_string();

        let folder =
            super::create_session_folder(database_path.clone(), None, "Production".to_string())
                .expect("create folder");
        let session = super::create_session_record(
            database_path.clone(),
            SessionDraft {
                folder_id: None,
                name: "Old API".to_string(),
                protocol: "ssh".to_string(),
                host: "api.example.com".to_string(),
                port: 22,
                username: Some("deploy".to_string()),
                private_key_path: None,
                credential_id: None,
                tags: vec!["old".to_string()],
                config_json: None,
            },
        )
        .expect("create session");

        let updated = super::update_session_record(
            database_path.clone(),
            session.id.clone(),
            SessionUpdate {
                name: Some("API Server".to_string()),
                protocol: Some("telnet".to_string()),
                folder_id: Some(folder.id.clone()),
                host: Some("api.internal".to_string()),
                port: Some(2222),
                username: Some("ops".to_string()),
                private_key_path: Some("~/.ssh/prod".to_string()),
                credential_id: None,
                tags: Some(vec!["prod".to_string(), "api".to_string()]),
                config_json: None,
            },
        )
        .expect("update session");

        assert_eq!(updated.name, "API Server");
        assert_eq!(updated.protocol, "telnet");
        assert_eq!(updated.folder_id, Some(folder.id));
        assert_eq!(updated.host, "api.internal");
        assert_eq!(updated.port, 2222);
        assert_eq!(updated.username, Some("ops".to_string()));
        assert_eq!(updated.private_key_path, Some("~/.ssh/prod".to_string()));
        assert_eq!(updated.tags, vec!["prod".to_string(), "api".to_string()]);

        let cleared = super::update_session_record(
            database_path.clone(),
            session.id.clone(),
            SessionUpdate {
                name: None,
                protocol: None,
                folder_id: None,
                host: None,
                port: None,
                username: Some("".to_string()),
                private_key_path: Some("".to_string()),
                credential_id: None,
                tags: None,
                config_json: None,
            },
        )
        .expect("clear optional metadata");

        assert_eq!(cleared.username, None);
        assert_eq!(cleared.private_key_path, None);

        super::delete_session_record(database_path.clone(), session.id).expect("delete session");
        let all_sessions =
            super::list_all_session_records(database_path).expect("list all sessions");

        assert!(all_sessions.is_empty());
    }

    #[test]
    fn session_bridge_duplicates_moves_and_exports_sessions() {
        let temp = tempfile::NamedTempFile::new().expect("temp database");
        let database_path = temp.path().to_string_lossy().to_string();

        let folder =
            super::create_session_folder(database_path.clone(), None, "Production".to_string())
                .expect("create folder");
        let session = super::create_session_record(
            database_path.clone(),
            SessionDraft {
                folder_id: None,
                name: "API Server".to_string(),
                protocol: "ssh".to_string(),
                host: "api.example.com".to_string(),
                port: 22,
                username: Some("deploy".to_string()),
                private_key_path: Some("~/.ssh/prod".to_string()),
                credential_id: None,
                tags: vec!["prod".to_string()],
                config_json: None,
            },
        )
        .expect("create session");
        let opened = super::mark_session_record_opened(database_path.clone(), session.id.clone())
            .expect("mark opened");

        let duplicate = super::duplicate_session_record(
            database_path.clone(),
            session.id.clone(),
            Some(folder.id.clone()),
        )
        .expect("duplicate");
        let moved = super::move_session_record(database_path.clone(), duplicate.id.clone(), None)
            .expect("move duplicate to root");
        let json = super::export_sessions_json(database_path.clone()).expect("export json");
        let all_sessions =
            super::list_all_session_records(database_path).expect("list all sessions");

        assert_ne!(duplicate.id, session.id);
        assert_eq!(duplicate.name, "API Server 副本");
        assert_eq!(duplicate.folder_id, Some(folder.id));
        assert_eq!(duplicate.last_opened_at, None);
        assert_eq!(moved.folder_id, None);
        assert!(opened.last_opened_at.is_some());
        assert_eq!(all_sessions.len(), 2);
        assert!(json.contains("stacio.sessions.v1"));
        assert!(json.contains("API Server"));
        assert!(json.contains("API Server 副本"));
        assert!(!json.contains("password"));
        assert!(!json.contains("secret"));
        assert!(!json.contains("sftp"));
    }

    #[test]
    fn session_bridge_persists_credential_reference_without_secret_values() {
        let temp = tempfile::NamedTempFile::new().expect("temp database");
        let database_path = temp.path().to_string_lossy().to_string();

        let credential = super::save_credential_record(
            database_path.clone(),
            CredentialDraft {
                kind: "password".to_string(),
                label: "API password".to_string(),
                keychain_service: "Stacio".to_string(),
                keychain_account: "deploy@example.com".to_string(),
            },
        )
        .expect("save credential metadata");
        let session = super::create_session_record(
            database_path.clone(),
            SessionDraft {
                folder_id: None,
                name: "API".to_string(),
                protocol: "ssh".to_string(),
                host: "example.com".to_string(),
                port: 22,
                username: Some("deploy".to_string()),
                private_key_path: None,
                credential_id: Some(credential.id.clone()),
                tags: vec!["prod".to_string()],
                config_json: None,
            },
        )
        .expect("create session");

        let credentials =
            super::list_credential_records(database_path.clone()).expect("list credentials");
        let sessions = super::list_all_session_records(database_path).expect("sessions");
        let serialized = serde_json::to_string(&(credentials.clone(), sessions.clone()))
            .expect("serialize credential/session metadata");

        assert_eq!(credentials, vec![credential.clone()]);
        assert_eq!(session.credential_id, Some(credential.id.clone()));
        assert_eq!(sessions[0].credential_id, Some(credential.id));
        assert!(!serialized.contains("super-secret"));
        assert!(!serialized.contains("password123"));
    }

    #[test]
    fn session_bridge_deletes_credential_metadata_and_clears_session_reference() {
        let temp = tempfile::NamedTempFile::new().expect("temp database");
        let database_path = temp.path().to_string_lossy().to_string();

        let credential = super::save_credential_record(
            database_path.clone(),
            CredentialDraft {
                kind: "password".to_string(),
                label: "API password".to_string(),
                keychain_service: "Stacio".to_string(),
                keychain_account: "deploy@example.com".to_string(),
            },
        )
        .expect("save credential metadata");
        let session = super::create_session_record(
            database_path.clone(),
            SessionDraft {
                folder_id: None,
                name: "API".to_string(),
                protocol: "ssh".to_string(),
                host: "example.com".to_string(),
                port: 22,
                username: Some("deploy".to_string()),
                private_key_path: None,
                credential_id: Some(credential.id.clone()),
                tags: vec![],
                config_json: None,
            },
        )
        .expect("create session");

        super::delete_credential_record(database_path.clone(), credential.id)
            .expect("delete credential metadata");

        let credentials =
            super::list_credential_records(database_path.clone()).expect("list credentials");
        let sessions = super::list_all_session_records(database_path).expect("sessions");

        assert!(credentials.is_empty());
        assert_eq!(sessions[0].id, session.id);
        assert_eq!(sessions[0].credential_id, None);
    }

    #[test]
    fn session_bridge_marks_session_record_opened() {
        let temp = tempfile::NamedTempFile::new().expect("temp database");
        let database_path = temp.path().to_string_lossy().to_string();

        let session = super::create_session_record(
            database_path.clone(),
            SessionDraft {
                folder_id: None,
                name: "Recent API".to_string(),
                protocol: "ssh".to_string(),
                host: "api.example.com".to_string(),
                port: 22,
                username: Some("deploy".to_string()),
                private_key_path: None,
                credential_id: None,
                tags: vec![],
                config_json: None,
            },
        )
        .expect("create session");

        assert_eq!(session.last_opened_at, None);

        let opened = super::mark_session_record_opened(database_path.clone(), session.id.clone())
            .expect("mark session opened");
        let listed = super::list_all_session_records(database_path).expect("list sessions");

        assert_eq!(opened.id, session.id);
        assert!(opened.last_opened_at.is_some());
        assert_eq!(listed[0].last_opened_at, opened.last_opened_at);
    }

    #[test]
    fn session_import_bridge_applies_preview_skips_conflicts_and_records_report() {
        let temp = tempfile::NamedTempFile::new().expect("temp database");
        let database_path = temp.path().to_string_lossy().to_string();

        let existing = super::create_session_record(
            database_path.clone(),
            SessionDraft {
                folder_id: None,
                name: "API".to_string(),
                protocol: "ssh".to_string(),
                host: "old-api.example.com".to_string(),
                port: 22,
                username: Some("deploy".to_string()),
                private_key_path: None,
                credential_id: None,
                tags: vec!["existing".to_string()],
                config_json: None,
            },
        )
        .expect("existing session");
        let csv = "name,host,port,username,folder,private_key_path,password\n\
                   API,api.example.com,22,deploy,Production,~/.ssh/prod,do-not-import\n\
                   Worker,worker.example.com,2200,ops,Production,~/.ssh/worker,\n";
        let preview =
            super::preview_csv_import(csv.to_string(), vec!["API".to_string()]).expect("preview");

        let result = super::apply_session_import(
            database_path.clone(),
            "csv".to_string(),
            "sessions.csv".to_string(),
            preview,
        )
        .expect("apply import");
        let reports = super::list_import_reports(database_path.clone()).expect("reports");
        let production = super::list_session_folders(database_path.clone())
            .expect("folders")
            .into_iter()
            .find(|folder| folder.name == "Production")
            .expect("production folder");
        let production_sessions =
            super::list_session_records(database_path.clone(), Some(production.id.clone()))
                .expect("production sessions");
        let root_sessions =
            super::list_session_records(database_path.clone(), None).expect("root sessions");
        let all_sessions = super::list_all_session_records(database_path).expect("all sessions");
        let serialized = serde_json::to_string(&result).expect("serialize");

        assert_eq!(result.report.source_type, "csv");
        assert_eq!(result.report.source_name, "sessions.csv");
        assert_eq!(result.report.status, "partial");
        assert_eq!(result.report.imported_count, 1);
        assert_eq!(result.report.skipped_count, 1);
        assert_eq!(result.report.failed_count, 0);
        assert!(result
            .report
            .issues
            .iter()
            .any(|issue| issue.contains("API") && issue.contains("skipped")));
        assert_eq!(reports, vec![result.report.clone()]);
        assert_eq!(production_sessions.len(), 1);
        assert_eq!(production_sessions[0].name, "Worker");
        assert_eq!(
            production_sessions[0].private_key_path,
            Some("~/.ssh/worker".to_string())
        );
        assert_eq!(root_sessions, vec![existing.clone()]);
        assert_eq!(all_sessions.len(), 2);
        assert!(all_sessions.contains(&existing));
        assert!(!serialized.contains("do-not-import"));
        assert!(!serialized.contains("secret"));
    }

    #[test]
    fn session_import_bridge_applies_legacy_ini_non_ssh_protocols_and_skips_unsupported_graphics_protocols(
    ) {
        let temp = tempfile::NamedTempFile::new().expect("temp database");
        let database_path = temp.path().to_string_lossy().to_string();
        let text = "Production/FTP=ftp://files@files.example.com\n\
                    Lab/Telnet=telnet://admin@router.example.com\n\
                    Desktop/VNC=vnc://screen.example.com:5901\n\
                    Desktop/XDMCP=xdmcp://display.example.com";
        let preview = super::preview_legacy_ini_import(text.to_string(), vec![]).expect("preview");

        let result = super::apply_session_import(
            database_path.clone(),
            "legacy_ini".to_string(),
            "Legacy INI Sessions.txt".to_string(),
            preview,
        )
        .expect("apply import");
        let all_sessions = super::list_all_session_records(database_path).expect("all sessions");
        let protocols = all_sessions
            .iter()
            .map(|session| session.protocol.as_str())
            .collect::<Vec<_>>();
        let ftp = all_sessions
            .iter()
            .find(|session| session.name == "FTP")
            .expect("ftp session");
        let telnet = all_sessions
            .iter()
            .find(|session| session.name == "Telnet")
            .expect("telnet session");
        let vnc = all_sessions
            .iter()
            .find(|session| session.name == "VNC")
            .expect("vnc session");
        assert_eq!(result.report.status, "imported");
        assert_eq!(result.imported_sessions.len(), 3);
        assert_eq!(protocols, vec!["ftp", "telnet", "vnc"]);
        assert_eq!(ftp.username, Some("files".to_string()));
        assert_eq!(telnet.port, 23);
        assert_eq!(vnc.port, 5901);
        assert!(all_sessions.iter().all(|session| session.protocol != "rdp"));
        assert!(all_sessions
            .iter()
            .all(|session| session.protocol != "xdmcp"));
    }

    #[test]
    fn session_import_bridge_applies_stacio_json_without_credential_references() {
        let source = tempfile::NamedTempFile::new().expect("source database");
        let source_database_path = source.path().to_string_lossy().to_string();
        let destination = tempfile::NamedTempFile::new().expect("destination database");
        let destination_database_path = destination.path().to_string_lossy().to_string();

        let folder = super::create_session_folder(
            source_database_path.clone(),
            None,
            "Production".to_string(),
        )
        .expect("create source folder");
        let credential = super::save_credential_record(
            source_database_path.clone(),
            CredentialDraft {
                kind: "password".to_string(),
                label: "API password".to_string(),
                keychain_service: "Stacio".to_string(),
                keychain_account: "deploy@example.com".to_string(),
            },
        )
        .expect("save credential metadata");
        super::create_session_record(
            source_database_path.clone(),
            SessionDraft {
                folder_id: Some(folder.id),
                name: "API".to_string(),
                protocol: "ssh".to_string(),
                host: "api.example.com".to_string(),
                port: 2200,
                username: Some("deploy".to_string()),
                private_key_path: Some("~/.ssh/prod".to_string()),
                credential_id: Some(credential.id.clone()),
                tags: vec!["prod".to_string()],
                config_json: None,
            },
        )
        .expect("create source session");
        let json = super::export_sessions_json(source_database_path).expect("export source json");
        let preview = preview_stacio_json_import(&json, vec![]).expect("preview json");

        let result = super::apply_session_import(
            destination_database_path.clone(),
            "stacio_json".to_string(),
            "Stacio Sessions.json".to_string(),
            preview,
        )
        .expect("apply stacio json import");
        let folders =
            super::list_session_folders(destination_database_path.clone()).expect("folders");
        let sessions =
            super::list_all_session_records(destination_database_path.clone()).expect("sessions");
        let reports = super::list_import_reports(destination_database_path).expect("reports");
        let serialized = serde_json::to_string(&(result.clone(), sessions.clone()))
            .expect("serialize import result");

        assert_eq!(result.report.source_type, "stacio_json");
        assert_eq!(result.report.status, "imported");
        assert_eq!(result.report.imported_count, 1);
        assert_eq!(reports, vec![result.report]);
        assert_eq!(folders.len(), 1);
        assert_eq!(folders[0].name, "Production");
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].name, "API");
        assert_eq!(sessions[0].folder_id, Some(folders[0].id.clone()));
        assert_eq!(sessions[0].port, 2200);
        assert_eq!(sessions[0].username, Some("deploy".to_string()));
        assert_eq!(
            sessions[0].private_key_path,
            Some("~/.ssh/prod".to_string())
        );
        assert_eq!(sessions[0].credential_id, None);
        assert!(!serialized.contains(&credential.id));
        assert!(!serialized.contains("password123"));
    }

    #[test]
    fn session_import_bridge_applies_stacio_json_nested_folder_paths() {
        let destination = tempfile::NamedTempFile::new().expect("destination database");
        let destination_database_path = destination.path().to_string_lossy().to_string();
        let json = r#"{
            "format": "stacio.sessions.v1",
            "exported_at": "2026-06-02T00:00:00Z",
            "folders": [
                {"id": "folder_prod", "parent_id": null, "name": "Production"},
                {"id": "folder_db", "parent_id": "folder_prod", "name": "Database"},
                {"id": "folder_primary", "parent_id": "folder_db", "name": "Primary"}
            ],
            "sessions": [
                {
                    "id": "session_db",
                    "folder_id": "folder_primary",
                    "name": "Primary DB",
                    "protocol": "ssh",
                    "host": "db.example.com",
                    "port": 22,
                    "username": "deploy",
                    "private_key_path": null,
                    "credential_id": null,
                    "tags": [],
                    "last_opened_at": null
                }
            ]
        }"#;
        let preview = preview_stacio_json_import(json, vec![]).expect("preview json");

        let result = super::apply_session_import(
            destination_database_path.clone(),
            "stacio_json".to_string(),
            "Production.json".to_string(),
            preview,
        )
        .expect("apply import");
        let folders =
            super::list_session_folders(destination_database_path.clone()).expect("folders");
        let sessions =
            super::list_all_session_records(destination_database_path).expect("sessions");
        let production = folders
            .iter()
            .find(|folder| folder.name == "Production")
            .expect("production folder");
        let database = folders
            .iter()
            .find(|folder| folder.name == "Database")
            .expect("database folder");
        let primary = folders
            .iter()
            .find(|folder| folder.name == "Primary")
            .expect("primary folder");

        assert_eq!(result.report.imported_count, 1);
        assert_eq!(folders.len(), 3);
        assert_eq!(database.parent_id, Some(production.id.clone()));
        assert_eq!(primary.parent_id, Some(database.id.clone()));
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].folder_id, Some(primary.id.clone()));
    }

    #[test]
    fn multiexec_audit_bridge_records_and_lists_redacted_broadcasts() {
        let temp = tempfile::NamedTempFile::new().expect("temp database");
        let database_path = temp.path().to_string_lossy().to_string();
        let prepared = super::prepare_broadcast_input(
            vec![MultiExecTarget::new("term_1", "生产", "production", true)],
            "export TOKEN=secret-value".to_string(),
            true,
        )
        .expect("prepare");
        let executed = super::mark_broadcast_executed(prepared, 1);

        let recorded =
            super::record_broadcast_audit_event(database_path.clone(), executed).expect("record");
        let records =
            super::list_broadcast_audit_records(database_path, 10).expect("list audit records");

        assert_eq!(recorded.target_count, 1);
        assert_eq!(recorded.sent_count, 1);
        assert_eq!(recorded.failed_count, 0);
        assert!(recorded.executed);
        assert!(!recorded.redacted_input.contains("secret-value"));
        assert_eq!(records, vec![recorded]);
    }

    #[test]
    fn agent_action_audit_bridge_records_and_lists_redacted_events() {
        let temp = tempfile::NamedTempFile::new().expect("temp database");
        let database_path = temp.path().to_string_lossy().to_string();
        let event = AgentActionAuditEvent {
            request_id: "req-1".to_string(),
            actor_kind: "externalCLI".to_string(),
            actor_name: "codex".to_string(),
            target_runtime_id: Some("term_1".to_string()),
            target_title: "prod@example.com".to_string(),
            action_kind: "runCommand".to_string(),
            risk: "destructive".to_string(),
            state: "running".to_string(),
            redacted_input: "TOKEN=[redacted] rm -rf /tmp/build".to_string(),
            environment: "production".to_string(),
            approval_mode: "requireEveryCommand".to_string(),
            policy_decision: "confirmed".to_string(),
            redaction_version: "stacio.agent-redaction.v1".to_string(),
        };

        let recorded =
            super::record_agent_action_event(database_path.clone(), event).expect("record");
        let records =
            super::list_agent_action_events(database_path, 10).expect("list agent action records");

        assert_eq!(recorded.request_id, "req-1");
        assert_eq!(recorded.actor_name, "codex");
        assert_eq!(recorded.environment, "production");
        assert_eq!(recorded.approval_mode, "requireEveryCommand");
        assert_eq!(recorded.policy_decision, "confirmed");
        assert_eq!(recorded.redaction_version, "stacio.agent-redaction.v1");
        assert!(!recorded.redacted_input.contains("secret-value"));
        assert_eq!(records, vec![recorded]);
    }

    #[test]
    fn agent_task_bridge_records_and_lists_task_history() {
        let temp = tempfile::NamedTempFile::new().expect("temp database");
        let database_path = temp.path().to_string_lossy().to_string();
        let session = AgentTaskSessionDraft {
            id: "task-bridge-1".to_string(),
            request_id: "req-bridge-1".to_string(),
            actor_kind: "builtInAI".to_string(),
            actor_name: "Stacio AI".to_string(),
            target_runtime_id: Some("term_1".to_string()),
            target_title: "prod@example.com".to_string(),
            state: "awaitingUser".to_string(),
            user_prompt: "检查 docker 容器".to_string(),
            assistant_message: "建议查看 Docker 状态。".to_string(),
        };
        let proposals = vec![AgentTaskProposalDraft {
            id: "proposal-bridge-1".to_string(),
            command: "docker ps --format '[redacted]'".to_string(),
            explanation: "列出容器".to_string(),
            risk: "readOnly".to_string(),
            state: "proposed".to_string(),
            sort_order: 0,
        }];

        let recorded = super::record_agent_task_session(database_path.clone(), session, proposals)
            .expect("record task");
        let recent =
            super::list_agent_task_sessions(database_path.clone(), 10).expect("list tasks");
        let by_request = super::list_agent_task_sessions_by_request_id(
            database_path,
            "req-bridge-1".to_string(),
        )
        .expect("list tasks by request");

        assert_eq!(recorded.request_id, "req-bridge-1");
        assert_eq!(recorded.proposals.len(), 1);
        assert_eq!(
            recorded.proposals[0].command,
            "docker ps --format '[redacted]'"
        );
        assert_eq!(recent, vec![recorded.clone()]);
        assert_eq!(by_request, vec![recorded]);
        assert!(!format!("{recent:?}").contains("secret-value"));
    }
}

#[cfg(test)]
mod tunnel_api_tests {
    use super::{
        check_tunnel_local_port_available, close_live_tunnel_runtime, poll_live_tunnel_runtime,
        start_live_local_tunnel_runtime, start_mock_tunnel, stop_tunnel_runtime,
    };
    use crate::domain::ssh::{SshAuthMethod, SshAuthSecret, SshConnectionConfig, SshRuntimeError};
    use crate::domain::tunnel::{TunnelError, TunnelKind, TunnelProfile, TunnelState};
    use crate::services::tunnel_service::MockTunnelOutcome;
    use std::net::TcpListener;

    fn profile() -> TunnelProfile {
        TunnelProfile {
            id: "tun_api".to_string(),
            kind: TunnelKind::Local,
            local_host: "127.0.0.1".to_string(),
            local_port: 9000,
            remote_host: "127.0.0.1".to_string(),
            remote_port: 5432,
        }
    }

    #[test]
    fn exported_mock_tunnel_start_and_stop_round_trip() {
        let status =
            start_mock_tunnel(profile(), MockTunnelOutcome::Started).expect("start tunnel");
        let stopped = stop_tunnel_runtime(status.state).expect("stop tunnel");

        assert_eq!(status.profile_id, "tun_api");
        assert_eq!(status.message, "running");
        assert_eq!(stopped, TunnelState::Stopped);
    }

    #[test]
    fn exported_mock_tunnel_maps_local_port_in_use() {
        let error = start_mock_tunnel(profile(), MockTunnelOutcome::LocalPortInUse)
            .expect_err("port in use");

        assert_eq!(error, TunnelError::LocalPortInUse);
    }

    #[test]
    fn exported_local_port_preflight_maps_port_in_use() {
        let listener = TcpListener::bind(("127.0.0.1", 0)).expect("bind fixture port");
        let mut profile = profile();
        profile.local_port = listener.local_addr().expect("fixture address").port();

        let error = check_tunnel_local_port_available(profile).expect_err("port in use");

        assert_eq!(error, TunnelError::LocalPortInUse);
    }

    #[test]
    fn exported_live_tunnel_rejects_invalid_ssh_config_before_binding_port() {
        let error = start_live_local_tunnel_runtime(
            SshConnectionConfig {
                host: "".to_string(),
                port: 22,
                username: "deploy".to_string(),
                auth_method: SshAuthMethod::Agent,
                connect_timeout_ms: 10_000,
            },
            SshAuthSecret::Agent,
            "SHA256:test".to_string(),
            profile(),
        )
        .expect_err("invalid ssh config");

        assert_eq!(error, SshRuntimeError::InvalidConfig);
    }

    #[test]
    fn exported_live_remote_tunnel_rejects_invalid_ssh_config_before_listening() {
        let mut remote_profile = profile();
        remote_profile.kind = TunnelKind::Remote;

        let error = start_live_local_tunnel_runtime(
            SshConnectionConfig {
                host: "".to_string(),
                port: 22,
                username: "deploy".to_string(),
                auth_method: SshAuthMethod::Agent,
                connect_timeout_ms: 10_000,
            },
            SshAuthSecret::Agent,
            "SHA256:test".to_string(),
            remote_profile,
        )
        .expect_err("invalid ssh config");

        assert_eq!(error, SshRuntimeError::InvalidConfig);
    }

    #[test]
    fn exported_live_tunnel_poll_and_close_missing_runtime_are_stable() {
        let polled =
            poll_live_tunnel_runtime("tun_missing".to_string()).expect("poll missing tunnel");
        let closed =
            close_live_tunnel_runtime("tun_missing".to_string()).expect("close missing tunnel");

        assert_eq!(polled.profile_id, "tun_missing");
        assert_eq!(polled.state, TunnelState::Stopped);
        assert_eq!(polled.message, "not_running");
        assert_eq!(closed.profile_id, "tun_missing");
        assert_eq!(closed.state, TunnelState::Stopped);
        assert_eq!(closed.message, "stopped");
    }

    #[test]
    fn tunnel_profile_bridge_persists_lists_and_deletes_profiles() {
        let temp = tempfile::NamedTempFile::new().expect("temp database");
        let database_path = temp.path().to_string_lossy().to_string();
        let profile = profile();

        super::save_tunnel_profile(database_path.clone(), None, profile.clone())
            .expect("save profile");
        let profiles =
            super::list_tunnel_profiles(database_path.clone(), None).expect("list profiles");
        super::delete_tunnel_profile(database_path.clone(), profile.id.clone())
            .expect("delete profile");
        let deleted = super::list_tunnel_profiles(database_path, None).expect("list deleted");

        assert_eq!(profiles, vec![profile]);
        assert!(deleted.is_empty());
    }
}
