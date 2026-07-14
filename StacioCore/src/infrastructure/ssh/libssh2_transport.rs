use crate::domain::ssh::{
    fingerprint_sha256, redact_ssh_diagnostic, LiveSshHostKey, LiveSshSessionInfo, SshAuthMethod,
    SshAuthSecret, SshConnectionConfig, SshConnectionStatus, SshProxyJumpRuntimeConfig,
    SshRuntimeError,
};
use crate::services::live_shell_service::ShellWaitInterest;
use std::io::{self, Read, Write};
use std::net::{SocketAddr, TcpStream, ToSocketAddrs};
#[cfg(unix)]
use std::os::fd::AsRawFd;
#[cfg(unix)]
use std::os::unix::net::UnixStream;
use std::sync::{
    atomic::{AtomicBool, Ordering},
    mpsc, Arc, Mutex,
};
use std::thread;
use std::time::{Duration, Instant};

#[derive(Clone, PartialEq, Eq)]
pub enum SshSecret {
    Password(String),
    PrivateKey {
        private_key_pem: String,
        passphrase: Option<String>,
    },
}

impl std::fmt::Debug for SshSecret {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SshSecret::Password(_) => formatter
                .debug_tuple("Password")
                .field(&"[redacted]")
                .finish(),
            SshSecret::PrivateKey { passphrase, .. } => formatter
                .debug_struct("PrivateKey")
                .field("private_key_pem", &"[redacted]")
                .field("passphrase", &passphrase.as_ref().map(|_| "[redacted]"))
                .finish(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Libssh2AuthRequest {
    Password {
        username: String,
        password: RedactedSecret,
    },
    PrivateKeyMemory {
        username: String,
        private_key_pem: RedactedSecret,
        passphrase: Option<RedactedSecret>,
    },
    Agent {
        username: String,
    },
}

#[derive(Clone, PartialEq, Eq)]
pub struct RedactedSecret(String);

impl RedactedSecret {
    pub fn new(value: String) -> Self {
        Self(value)
    }

    fn expose(&self) -> &str {
        &self.0
    }
}

impl std::fmt::Debug for RedactedSecret {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("[redacted]")
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Libssh2HostKeySummary {
    pub key_type: String,
    pub fingerprint_sha256: String,
    pub key_len: u64,
}

impl Libssh2HostKeySummary {
    pub fn from_host_key(key_type: &str, host_key: &[u8]) -> Self {
        Self {
            key_type: key_type.to_string(),
            fingerprint_sha256: fingerprint_sha256(host_key),
            key_len: host_key.len() as u64,
        }
    }
}

pub struct Libssh2ConnectedSession {
    session: ssh2::Session,
    _proxy_jump_session: Option<ssh2::Session>,
    _proxy_jump_bridge: Vec<thread::JoinHandle<()>>,
    pub host_key: Libssh2HostKeySummary,
    pub session_info: Libssh2SessionInfo,
}

impl Libssh2ConnectedSession {
    pub fn session(&self) -> &ssh2::Session {
        &self.session
    }

    pub fn authenticated(&self) -> bool {
        self.session.authenticated()
    }

    pub fn live_session_info(
        &self,
        runtime_id: String,
        config: &SshConnectionConfig,
    ) -> LiveSshSessionInfo {
        self.session_info
            .live_session_info(runtime_id, config, &self.host_key)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Libssh2SessionInfo {
    pub cipher_client_to_server: Option<String>,
    pub cipher_server_to_client: Option<String>,
    pub kex_algorithm: Option<String>,
    pub compression_client_to_server: Option<String>,
    pub compression_server_to_client: Option<String>,
    pub server_banner: Option<String>,
    pub userauth_banner: Option<String>,
}

impl Libssh2SessionInfo {
    pub fn from_session(session: &ssh2::Session) -> Self {
        Self {
            cipher_client_to_server: trimmed_optional(session.methods(ssh2::MethodType::CryptCs)),
            cipher_server_to_client: trimmed_optional(session.methods(ssh2::MethodType::CryptSc)),
            kex_algorithm: trimmed_optional(session.methods(ssh2::MethodType::Kex)),
            compression_client_to_server: trimmed_optional(
                session.methods(ssh2::MethodType::CompCs),
            ),
            compression_server_to_client: trimmed_optional(
                session.methods(ssh2::MethodType::CompSc),
            ),
            server_banner: trimmed_optional(session.banner()),
            userauth_banner: trimmed_optional(session.userauth_banner().ok().flatten()),
        }
    }

    fn live_session_info(
        &self,
        runtime_id: String,
        config: &SshConnectionConfig,
        host_key: &Libssh2HostKeySummary,
    ) -> LiveSshSessionInfo {
        LiveSshSessionInfo {
            runtime_id,
            host: config.host.clone(),
            port: config.port,
            username: config.username.clone(),
            host_key_type: host_key.key_type.clone(),
            host_key_fingerprint_sha256: host_key.fingerprint_sha256.clone(),
            cipher_client_to_server: self.cipher_client_to_server.clone(),
            cipher_server_to_client: self.cipher_server_to_client.clone(),
            kex_algorithm: self.kex_algorithm.clone(),
            compression_client_to_server: self.compression_client_to_server.clone(),
            compression_server_to_client: self.compression_server_to_client.clone(),
            server_banner: self.server_banner.clone(),
            userauth_banner: self.userauth_banner.clone(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Libssh2ShellRequest {
    pub runtime_id: String,
    pub term: String,
    pub environment: Vec<(String, String)>,
    pub cols: u32,
    pub rows: u32,
}

impl Libssh2ShellRequest {
    pub fn new(runtime_id: String, cols: u32, rows: u32) -> Self {
        Self {
            runtime_id,
            term: "xterm-256color".to_string(),
            environment: vec![
                ("COLORTERM".to_string(), "truecolor".to_string()),
                ("CLICOLOR".to_string(), "1".to_string()),
                ("CLICOLOR_FORCE".to_string(), "1".to_string()),
                ("FORCE_COLOR".to_string(), "1".to_string()),
                ("SYSTEMD_COLORS".to_string(), "1".to_string()),
                ("SYSTEMD_PAGERSECURE".to_string(), "0".to_string()),
                ("TERM_PROGRAM".to_string(), "Stacio".to_string()),
                ("GREP_COLOR".to_string(), "01;38;5;214".to_string()),
                ("GREP_COLORS".to_string(), rich_grep_colors().to_string()),
                ("LS_COLORS".to_string(), rich_ls_colors().to_string()),
                ("LSCOLORS".to_string(), "ExFxBxDxCxegedabagacad".to_string()),
            ],
            cols,
            rows,
        }
    }
}

fn rich_grep_colors() -> &'static str {
    "ms=01;38;5;214:mc=01;38;5;214:sl=:cx=:fn=38;5;75:ln=38;5;108:bn=38;5;109:se=38;5;244"
}

fn rich_ls_colors() -> &'static str {
    concat!(
        "di=01;38;5;75:ln=01;38;5;44:so=01;38;5;203:pi=01;38;5;179:",
        "ex=01;38;5;113:bd=01;38;5;221:cd=01;38;5;221:su=37;41:",
        "sg=30;43:tw=30;42:ow=34;42:st=37;44:or=37;41:mi=37;41:",
        "*.swift=38;5;214:*.rs=38;5;208:*.go=38;5;81:*.js=38;5;221:",
        "*.ts=38;5;75:*.tsx=38;5;75:*.json=38;5;179:*.yml=38;5;179:",
        "*.yaml=38;5;179:*.toml=38;5;179:*.md=38;5;183:*.sh=38;5;113:",
        "Dockerfile=38;5;75:*Dockerfile=38;5;75:*Dockerfile.*=38;5;75:",
        "Containerfile=38;5;75:*Containerfile=38;5;75:*Containerfile.*=38;5;75:",
        ".dockerignore=38;5;244:*.dockerignore=38;5;244:",
        "docker-compose.yml=38;5;179:*docker-compose.yml=38;5;179:",
        "*docker-compose*.yml=38;5;179:docker-compose.yaml=38;5;179:",
        "*docker-compose.yaml=38;5;179:*docker-compose*.yaml=38;5;179:",
        "compose.yml=38;5;179:*compose.yml=38;5;179:*compose*.yml=38;5;179:",
        "compose.yaml=38;5;179:*compose.yaml=38;5;179:*compose*.yaml=38;5;179:",
        "docker-bake.hcl=38;5;179:*docker-bake*.hcl=38;5;179:buildkitd.toml=38;5;179:",
        "*.dockerfile=38;5;75:*.containerfile=38;5;75:*.oci=38;5;203:",
        "*.tf=38;5;141:*.tfvars=38;5;141:*.env=38;5;108:.env.*=38;5;108:",
        "*.service=38;5;110:*.timer=38;5;110:*.socket=38;5;110:",
        "nginx.conf=38;5;110:*nginx.conf=38;5;110:*.nginx=38;5;110:",
        "*.kubeconfig=38;5;75:Chart.yaml=38;5;179:*Chart.yaml=38;5;179:",
        "values.yaml=38;5;179:*values.yaml=38;5;179:",
        "*.py=38;5;108:*.zip=38;5;203:*.tar=38;5;203:*.gz=38;5;203"
    )
}

pub struct Libssh2ShellChannel {
    _session: ssh2::Session,
    _proxy_jump_session: Option<ssh2::Session>,
    _proxy_jump_bridge: Vec<thread::JoinHandle<()>>,
    channel: ssh2::Channel,
}

pub const SSH_SHELL_KEEPALIVE_INTERVAL_SECONDS: u32 = 30;
const SSH_SESSION_OPERATION_TIMEOUT_MS: u32 = 60_000;
const SSH_TCP_CONNECT_STAGGER_MS: u64 = 150;

impl crate::services::live_shell_service::ShellChannel for Libssh2ShellChannel {
    fn write_input(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.channel.write(bytes)
    }

    fn read_output(&mut self, max_bytes: usize) -> io::Result<Vec<u8>> {
        let mut buffer = vec![0_u8; max_bytes];
        match self.channel.read(&mut buffer) {
            Ok(count) => {
                buffer.truncate(count);
                Ok(buffer)
            }
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => Ok(Vec::new()),
            Err(error) => Err(error),
        }
    }

    fn resize_pty(&mut self, cols: u32, rows: u32) -> io::Result<()> {
        self.channel
            .request_pty_size(cols, rows, None, None)
            .map_err(Into::into)
    }

    fn close(&mut self) -> io::Result<()> {
        self.channel.close().map_err(Into::into)
    }

    fn is_eof(&self) -> bool {
        self.channel.eof()
    }

    fn keepalive(&mut self) -> io::Result<()> {
        match self._session.keepalive_send() {
            Ok(_) => Ok(()),
            Err(error) => {
                let io_error: io::Error = error.into();
                if is_would_block_io_error(&io_error) {
                    Ok(())
                } else {
                    Err(io_error)
                }
            }
        }
    }

    fn wait_interest(&self) -> Option<ShellWaitInterest> {
        #[cfg(unix)]
        {
            let directions = self._session.block_directions();
            return match directions {
                ssh2::BlockDirections::Inbound => Some(ShellWaitInterest::new(
                    self._session.as_raw_fd(),
                    true,
                    false,
                )),
                ssh2::BlockDirections::Outbound => Some(ShellWaitInterest::new(
                    self._session.as_raw_fd(),
                    false,
                    true,
                )),
                ssh2::BlockDirections::Both => Some(ShellWaitInterest::new(
                    self._session.as_raw_fd(),
                    true,
                    true,
                )),
                ssh2::BlockDirections::None => Some(ShellWaitInterest::new(
                    self._session.as_raw_fd(),
                    true,
                    false,
                )),
            };
        }
        #[cfg(not(unix))]
        {
            None
        }
    }
}

fn is_would_block_io_error(error: &io::Error) -> bool {
    if error.kind() == io::ErrorKind::WouldBlock {
        return true;
    }
    let lowered = error.to_string().to_ascii_lowercase();
    lowered.contains("would block")
        || lowered.contains("operation would block")
        || lowered.contains("session(-37)")
}

pub struct Libssh2Transport;

impl Libssh2Transport {
    pub fn new() -> Self {
        Self
    }

    pub fn connect_preview(&self, config: &SshConnectionConfig) -> Result<(), SshRuntimeError> {
        self.endpoint(config)?;

        Err(SshRuntimeError::Transport {
            message: redact_ssh_diagnostic("libssh2 connection execution is not wired yet"),
        })
    }

    pub fn endpoint(&self, config: &SshConnectionConfig) -> Result<String, SshRuntimeError> {
        if config.host.trim().is_empty() || config.port == 0 {
            return Err(SshRuntimeError::InvalidConfig);
        }

        Ok(format!("{}:{}", config.host.trim(), config.port))
    }

    pub fn timeout_ms(&self, config: &SshConnectionConfig) -> u32 {
        config.connect_timeout_ms
    }

    pub fn create_session(&self) -> Result<ssh2::Session, SshRuntimeError> {
        ssh2::Session::new().map_err(|error| SshRuntimeError::Transport {
            message: redact_ssh_diagnostic(&error.to_string()),
        })
    }

    pub fn auth_request(
        &self,
        config: &SshConnectionConfig,
        secret: Option<SshSecret>,
    ) -> Result<Libssh2AuthRequest, SshRuntimeError> {
        match &config.auth_method {
            SshAuthMethod::Password { .. } => match secret {
                Some(SshSecret::Password(password)) if !password.is_empty() => {
                    Ok(Libssh2AuthRequest::Password {
                        username: config.username.clone(),
                        password: RedactedSecret::new(password),
                    })
                }
                _ => Err(SshRuntimeError::InvalidConfig),
            },
            SshAuthMethod::PrivateKey { .. } => match secret {
                Some(SshSecret::PrivateKey {
                    private_key_pem,
                    passphrase,
                }) if !private_key_pem.is_empty() => Ok(Libssh2AuthRequest::PrivateKeyMemory {
                    username: config.username.clone(),
                    private_key_pem: RedactedSecret::new(private_key_pem),
                    passphrase: passphrase.map(RedactedSecret::new),
                }),
                _ => Err(SshRuntimeError::InvalidConfig),
            },
            SshAuthMethod::Agent => Ok(Libssh2AuthRequest::Agent {
                username: config.username.clone(),
            }),
        }
    }

    pub fn map_error(message: &str) -> SshRuntimeError {
        let redacted = redact_ssh_diagnostic(message);
        let lowered = redacted.to_ascii_lowercase();
        if lowered.contains("would block")
            || lowered.contains("operation would block")
            || lowered.contains("session(-37)")
        {
            SshRuntimeError::Transport {
                message: "SSH 通道暂时不可用，请稍后重试".to_string(),
            }
        } else if redacted.contains("timed out") {
            SshRuntimeError::Timeout
        } else if redacted.contains("auth") {
            SshRuntimeError::Transport { message: redacted }
        } else {
            SshRuntimeError::Transport { message: redacted }
        }
    }

    pub fn connect_with_secret(
        &self,
        config: &SshConnectionConfig,
        secret: Option<SshSecret>,
    ) -> Result<Libssh2ConnectedSession, SshRuntimeError> {
        self.endpoint(config)?;
        let auth_request = self.auth_request(config, secret)?;
        let stream = connect_tcp(&self.endpoint(config)?, self.timeout_ms(config))?;
        let mut session = self.create_session()?;
        session.set_tcp_stream(stream);
        session.set_timeout(SSH_SESSION_OPERATION_TIMEOUT_MS);
        session
            .handshake()
            .map_err(|error| Self::map_error(&error.to_string()))?;

        authenticate_session(&session, auth_request)?;

        if !session.authenticated() {
            return Err(SshRuntimeError::AuthFailed);
        }

        let host_key = session
            .host_key()
            .map(|(key, kind)| Libssh2HostKeySummary::from_host_key(&format!("{kind:?}"), key))
            .ok_or_else(|| SshRuntimeError::Transport {
                message: "missing host key after handshake".to_string(),
            })?;

        let session_info = Libssh2SessionInfo::from_session(&session);

        Ok(Libssh2ConnectedSession {
            session,
            _proxy_jump_session: None,
            _proxy_jump_bridge: Vec::new(),
            host_key,
            session_info,
        })
    }

    pub fn probe_host_key(
        &self,
        config: &SshConnectionConfig,
    ) -> Result<LiveSshHostKey, SshRuntimeError> {
        self.endpoint(config)?;
        let stream = connect_tcp(&self.endpoint(config)?, self.timeout_ms(config))?;
        let mut session = self.create_session()?;
        session.set_tcp_stream(stream);
        session.set_timeout(SSH_SESSION_OPERATION_TIMEOUT_MS);
        session
            .handshake()
            .map_err(|error| Self::map_error(&error.to_string()))?;

        self.host_key_from_session(config, &session)
    }

    pub fn verify_expected_fingerprint(
        observed: &LiveSshHostKey,
        expected_fingerprint_sha256: &str,
    ) -> Result<(), SshRuntimeError> {
        if observed.fingerprint_sha256 == expected_fingerprint_sha256 {
            Ok(())
        } else {
            Err(SshRuntimeError::HostKeyChanged)
        }
    }

    pub fn connect_with_secret_and_expected_host_key(
        &self,
        config: &SshConnectionConfig,
        secret: Option<SshSecret>,
        expected_fingerprint_sha256: String,
    ) -> Result<SshConnectionStatus, SshRuntimeError> {
        self.endpoint(config)?;
        let auth_request = self.auth_request(config, secret)?;
        let stream = connect_tcp(&self.endpoint(config)?, self.timeout_ms(config))?;
        let mut session = self.create_session()?;
        session.set_tcp_stream(stream);
        session.set_timeout(SSH_SESSION_OPERATION_TIMEOUT_MS);
        session
            .handshake()
            .map_err(|error| Self::map_error(&error.to_string()))?;

        let observed = self.host_key_from_session(config, &session)?;
        Self::verify_expected_fingerprint(&observed, &expected_fingerprint_sha256)?;

        authenticate_session(&session, auth_request)?;

        if !session.authenticated() {
            return Err(SshRuntimeError::AuthFailed);
        }

        Ok(SshConnectionStatus {
            connected: true,
            host: config.host.clone(),
            port: config.port,
            username: config.username.clone(),
            auth_method: config.auth_method.label(),
            diagnostic: "connected".to_string(),
        })
    }

    pub fn connect_with_secret_and_expected_session(
        &self,
        config: &SshConnectionConfig,
        secret: Option<SshSecret>,
        expected_fingerprint_sha256: String,
    ) -> Result<Libssh2ConnectedSession, SshRuntimeError> {
        self.connect_with_secret_and_expected_session_options(
            config,
            secret,
            expected_fingerprint_sha256,
            false,
        )
    }

    pub fn connect_with_secret_and_expected_transfer_session(
        &self,
        config: &SshConnectionConfig,
        secret: Option<SshSecret>,
        expected_fingerprint_sha256: String,
    ) -> Result<Libssh2ConnectedSession, SshRuntimeError> {
        self.connect_with_secret_and_expected_session_options(
            config,
            secret,
            expected_fingerprint_sha256,
            true,
        )
    }

    fn connect_with_secret_and_expected_session_options(
        &self,
        config: &SshConnectionConfig,
        secret: Option<SshSecret>,
        expected_fingerprint_sha256: String,
        binary_transfer: bool,
    ) -> Result<Libssh2ConnectedSession, SshRuntimeError> {
        self.endpoint(config)?;
        let auth_request = self.auth_request(config, secret)?;
        let stream = connect_tcp(&self.endpoint(config)?, self.timeout_ms(config))?;
        let mut session = self.create_session()?;
        if binary_transfer {
            configure_binary_transfer_session(&session)?;
        }
        session.set_tcp_stream(stream);
        session.set_timeout(SSH_SESSION_OPERATION_TIMEOUT_MS);
        session
            .handshake()
            .map_err(|error| Self::map_error(&error.to_string()))?;

        let observed = self.host_key_from_session(config, &session)?;
        Self::verify_expected_fingerprint(&observed, &expected_fingerprint_sha256)?;
        authenticate_session(&session, auth_request)?;

        if !session.authenticated() {
            return Err(SshRuntimeError::AuthFailed);
        }
        session.set_keepalive(false, SSH_SHELL_KEEPALIVE_INTERVAL_SECONDS);
        session.set_keepalive(true, SSH_SHELL_KEEPALIVE_INTERVAL_SECONDS);

        let host_key = Libssh2HostKeySummary {
            key_type: observed.key_type,
            fingerprint_sha256: observed.fingerprint_sha256,
            key_len: observed.key_len,
        };

        let session_info = Libssh2SessionInfo::from_session(&session);

        Ok(Libssh2ConnectedSession {
            session,
            _proxy_jump_session: None,
            _proxy_jump_bridge: Vec::new(),
            host_key,
            session_info,
        })
    }

    pub fn connect_with_proxy_jump_and_expected_session(
        &self,
        target_config: &SshConnectionConfig,
        target_secret: Option<SshSecret>,
        proxy_jump: SshProxyJumpRuntimeConfig,
    ) -> Result<Libssh2ConnectedSession, SshRuntimeError> {
        let jump_secret = auth_secret_to_transport_secret(proxy_jump.jump_secret.clone());
        let jump_session = self
            .connect_with_secret_and_expected_session(
                &proxy_jump.jump_config,
                jump_secret,
                proxy_jump.jump_expected_fingerprint_sha256.clone(),
            )
            .map_err(|error| phase_error("跳板机连接失败", error))?;

        let (target_stream, bridge_handles) = self
            .open_proxy_jump_bridge(jump_session.session(), target_config)
            .map_err(|error| phase_error("目标主机连接失败", error))?;
        let auth_request = self
            .auth_request(target_config, target_secret)
            .map_err(|error| phase_error("目标主机连接失败", error))?;
        let mut target_session = self
            .create_session()
            .map_err(|error| phase_error("目标主机连接失败", error))?;
        target_session.set_tcp_stream(target_stream);
        target_session.set_timeout(SSH_SESSION_OPERATION_TIMEOUT_MS);
        target_session.handshake().map_err(|error| {
            phase_error("目标主机连接失败", Self::map_error(&error.to_string()))
        })?;

        let observed = self
            .host_key_from_session(target_config, &target_session)
            .map_err(|error| phase_error("目标主机连接失败", error))?;
        Self::verify_expected_fingerprint(
            &observed,
            &proxy_jump.target_expected_fingerprint_sha256,
        )
        .map_err(|error| phase_error("目标主机连接失败", error))?;
        authenticate_session(&target_session, auth_request)
            .map_err(|error| phase_error("目标主机连接失败", error))?;

        if !target_session.authenticated() {
            return Err(phase_error("目标主机连接失败", SshRuntimeError::AuthFailed));
        }
        target_session.set_keepalive(false, SSH_SHELL_KEEPALIVE_INTERVAL_SECONDS);
        target_session.set_keepalive(true, SSH_SHELL_KEEPALIVE_INTERVAL_SECONDS);

        let host_key = Libssh2HostKeySummary {
            key_type: observed.key_type,
            fingerprint_sha256: observed.fingerprint_sha256,
            key_len: observed.key_len,
        };
        let session_info = Libssh2SessionInfo::from_session(&target_session);
        Ok(Libssh2ConnectedSession {
            session: target_session,
            _proxy_jump_session: Some(jump_session.session),
            _proxy_jump_bridge: bridge_handles,
            host_key,
            session_info,
        })
    }

    pub fn open_shell_channel(
        &self,
        config: &SshConnectionConfig,
        secret: Option<SshSecret>,
        expected_fingerprint_sha256: String,
        request: Libssh2ShellRequest,
    ) -> Result<(Libssh2ShellChannel, LiveSshSessionInfo), SshRuntimeError> {
        self.endpoint(config)?;
        let auth_request = self.auth_request(config, secret)?;
        let stream = connect_tcp(&self.endpoint(config)?, self.timeout_ms(config))?;
        let mut session = self.create_session()?;
        session.set_tcp_stream(stream);
        session.set_timeout(SSH_SESSION_OPERATION_TIMEOUT_MS);
        session
            .handshake()
            .map_err(|error| Self::map_error(&error.to_string()))?;

        let observed = self.host_key_from_session(config, &session)?;
        Self::verify_expected_fingerprint(&observed, &expected_fingerprint_sha256)?;
        authenticate_session(&session, auth_request)?;

        if !session.authenticated() {
            return Err(SshRuntimeError::AuthFailed);
        }
        session.set_keepalive(false, SSH_SHELL_KEEPALIVE_INTERVAL_SECONDS);
        session.set_keepalive(true, SSH_SHELL_KEEPALIVE_INTERVAL_SECONDS);

        let host_key = Libssh2HostKeySummary {
            key_type: observed.key_type,
            fingerprint_sha256: observed.fingerprint_sha256,
            key_len: observed.key_len,
        };
        let session_info = Libssh2SessionInfo::from_session(&session).live_session_info(
            request.runtime_id.clone(),
            config,
            &host_key,
        );

        session.set_blocking(false);
        let channel = with_temporary_blocking(&session, true, || {
            let mut channel = session.channel_session()?;
            channel.handle_extended_data(ssh2::ExtendedData::Merge)?;
            channel.request_pty(
                &request.term,
                None,
                Some((request.cols, request.rows, 0, 0)),
            )?;
            for (name, value) in &request.environment {
                let _ = channel.setenv(name, value);
            }
            channel.shell()?;
            Ok::<_, ssh2::Error>(channel)
        })
        .map_err(|error| Self::map_error(&error.to_string()))?;
        session.set_blocking(false);

        Ok((
            Libssh2ShellChannel {
                _session: session,
                _proxy_jump_session: None,
                _proxy_jump_bridge: Vec::new(),
                channel,
            },
            session_info,
        ))
    }

    pub fn open_shell_channel_via_proxy_jump(
        &self,
        target_config: &SshConnectionConfig,
        target_secret: Option<SshSecret>,
        proxy_jump: SshProxyJumpRuntimeConfig,
        request: Libssh2ShellRequest,
    ) -> Result<(Libssh2ShellChannel, LiveSshSessionInfo), SshRuntimeError> {
        let connected = self.connect_with_proxy_jump_and_expected_session(
            target_config,
            target_secret,
            proxy_jump,
        )?;
        self.open_shell_channel_for_connected_session(target_config, request, connected)
            .map_err(|error| phase_error("目标主机连接失败", error))
    }

    fn open_shell_channel_for_connected_session(
        &self,
        config: &SshConnectionConfig,
        request: Libssh2ShellRequest,
        connected: Libssh2ConnectedSession,
    ) -> Result<(Libssh2ShellChannel, LiveSshSessionInfo), SshRuntimeError> {
        let session_info = connected.session_info.live_session_info(
            request.runtime_id.clone(),
            config,
            &connected.host_key,
        );
        let Libssh2ConnectedSession {
            session,
            _proxy_jump_session,
            _proxy_jump_bridge,
            ..
        } = connected;

        session.set_blocking(false);
        let channel = with_temporary_blocking(&session, true, || {
            let mut channel = session.channel_session()?;
            channel.handle_extended_data(ssh2::ExtendedData::Merge)?;
            channel.request_pty(
                &request.term,
                None,
                Some((request.cols, request.rows, 0, 0)),
            )?;
            for (name, value) in &request.environment {
                let _ = channel.setenv(name, value);
            }
            channel.shell()?;
            Ok::<_, ssh2::Error>(channel)
        })
        .map_err(|error| Self::map_error(&error.to_string()))?;
        session.set_blocking(false);

        Ok((
            Libssh2ShellChannel {
                _session: session,
                _proxy_jump_session,
                _proxy_jump_bridge,
                channel,
            },
            session_info,
        ))
    }

    #[cfg(unix)]
    fn open_proxy_jump_bridge(
        &self,
        jump_session: &ssh2::Session,
        target_config: &SshConnectionConfig,
    ) -> Result<(UnixStream, Vec<thread::JoinHandle<()>>), SshRuntimeError> {
        let channel = with_temporary_blocking(jump_session, true, || {
            jump_session.channel_direct_tcpip(&target_config.host, target_config.port, None)
        })
        .map_err(|error| Self::map_error(&error.to_string()))?;
        let (bridge_stream, target_stream) =
            UnixStream::pair().map_err(|error| Self::map_error(&error.to_string()))?;
        let handles = bridge_proxy_jump_channel(bridge_stream, channel)?;
        Ok((target_stream, handles))
    }

    #[cfg(not(unix))]
    fn open_proxy_jump_bridge(
        &self,
        _jump_session: &ssh2::Session,
        _target_config: &SshConnectionConfig,
    ) -> Result<((), Vec<thread::JoinHandle<()>>), SshRuntimeError> {
        Err(SshRuntimeError::Transport {
            message: "ProxyJump is not supported on this platform".to_string(),
        })
    }

    fn host_key_from_session(
        &self,
        config: &SshConnectionConfig,
        session: &ssh2::Session,
    ) -> Result<LiveSshHostKey, SshRuntimeError> {
        session
            .host_key()
            .map(|(key, kind)| {
                LiveSshHostKey::from_host_key(&config.host, config.port, &format!("{kind:?}"), key)
            })
            .ok_or_else(|| SshRuntimeError::Transport {
                message: "missing host key after handshake".to_string(),
            })
    }
}

fn trimmed_optional(value: Option<&str>) -> Option<String> {
    let trimmed = value?.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

fn configure_binary_transfer_session(session: &ssh2::Session) -> Result<(), SshRuntimeError> {
    session.set_compress(false);
    session
        .method_pref(ssh2::MethodType::CompCs, "none")
        .map_err(|error| Libssh2Transport::map_error(&error.to_string()))?;
    session
        .method_pref(ssh2::MethodType::CompSc, "none")
        .map_err(|error| Libssh2Transport::map_error(&error.to_string()))?;
    Ok(())
}

pub(crate) fn with_temporary_blocking<T, E, F>(
    session: &ssh2::Session,
    blocking: bool,
    operation: F,
) -> Result<T, E>
where
    F: FnOnce() -> Result<T, E>,
{
    let _guard = TemporarySessionBlocking::new(session, blocking);
    operation()
}

struct TemporarySessionBlocking<'session> {
    session: &'session ssh2::Session,
    was_blocking: bool,
}

impl<'session> TemporarySessionBlocking<'session> {
    fn new(session: &'session ssh2::Session, blocking: bool) -> Self {
        let was_blocking = session.is_blocking();
        if was_blocking != blocking {
            session.set_blocking(blocking);
        }
        Self {
            session,
            was_blocking,
        }
    }
}

impl Drop for TemporarySessionBlocking<'_> {
    fn drop(&mut self) {
        if self.session.is_blocking() != self.was_blocking {
            self.session.set_blocking(self.was_blocking);
        }
    }
}

fn connect_tcp(endpoint: &str, timeout_ms: u32) -> Result<TcpStream, SshRuntimeError> {
    let addresses = endpoint
        .to_socket_addrs()
        .map_err(|error| Libssh2Transport::map_error(&error.to_string()))?
        .collect::<Vec<_>>();

    connect_tcp_to_addresses(&addresses, timeout_ms)
}

fn connect_tcp_to_addresses(
    addresses: &[SocketAddr],
    timeout_ms: u32,
) -> Result<TcpStream, SshRuntimeError> {
    let timeout = Duration::from_millis(timeout_ms as u64);
    let Some((&first_address, remaining_addresses)) = addresses.split_first() else {
        return Err(SshRuntimeError::InvalidConfig);
    };
    if remaining_addresses.is_empty() {
        return TcpStream::connect_timeout(&first_address, timeout)
            .map_err(|error| Libssh2Transport::map_error(&error.to_string()));
    }

    let deadline = Instant::now() + timeout;
    let (sender, receiver) = mpsc::channel();
    let winner_selected = Arc::new(AtomicBool::new(false));
    for (index, address) in addresses.iter().copied().enumerate() {
        let sender = sender.clone();
        let winner_selected = Arc::clone(&winner_selected);
        thread::spawn(move || {
            if index > 0 {
                let stagger = Duration::from_millis(SSH_TCP_CONNECT_STAGGER_MS * index as u64);
                let remaining = deadline.saturating_duration_since(Instant::now());
                thread::sleep(stagger.min(remaining));
            }
            if winner_selected.load(Ordering::Acquire) {
                return;
            }
            let remaining = deadline.saturating_duration_since(Instant::now());
            let connect_timeout = if remaining.is_zero() {
                Duration::from_millis(1)
            } else {
                remaining
            };
            match TcpStream::connect_timeout(&address, connect_timeout) {
                Ok(stream) => {
                    if winner_selected
                        .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
                        .is_ok()
                    {
                        let _ = sender.send(Ok(stream));
                    }
                }
                Err(error) => {
                    if !winner_selected.load(Ordering::Acquire) {
                        let _ = sender.send(Err(error));
                    }
                }
            }
        });
    }
    drop(sender);

    let mut last_error: Option<io::Error> = None;
    for _ in 0..addresses.len() {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            winner_selected.store(true, Ordering::Release);
            return Err(SshRuntimeError::Timeout);
        }
        match receiver.recv_timeout(remaining) {
            Ok(Ok(stream)) => return Ok(stream),
            Ok(Err(error)) => {
                last_error = Some(error);
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {
                winner_selected.store(true, Ordering::Release);
                return Err(SshRuntimeError::Timeout);
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => break,
        }
    }

    winner_selected.store(true, Ordering::Release);

    match last_error {
        Some(error) => Err(Libssh2Transport::map_error(&error.to_string())),
        None => Err(SshRuntimeError::Timeout),
    }
}

fn authenticate_session(
    session: &ssh2::Session,
    request: Libssh2AuthRequest,
) -> Result<(), SshRuntimeError> {
    match request {
        Libssh2AuthRequest::Password { username, password } => session
            .userauth_password(&username, password.expose())
            .map_err(|error| Libssh2Transport::map_error(&error.to_string())),
        Libssh2AuthRequest::PrivateKeyMemory {
            username,
            private_key_pem,
            passphrase,
        } => session
            .userauth_pubkey_memory(
                &username,
                None,
                private_key_pem.expose(),
                passphrase.as_ref().map(RedactedSecret::expose),
            )
            .map_err(|error| Libssh2Transport::map_error(&error.to_string())),
        Libssh2AuthRequest::Agent { username } => session
            .userauth_agent(&username)
            .map_err(|error| Libssh2Transport::map_error(&error.to_string())),
    }
}

fn auth_secret_to_transport_secret(secret: SshAuthSecret) -> Option<SshSecret> {
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

fn phase_error(phase: &str, error: SshRuntimeError) -> SshRuntimeError {
    let detail = match error {
        SshRuntimeError::InvalidConfig => "SSH 配置无效".to_string(),
        SshRuntimeError::AuthFailed => "SSH 认证失败".to_string(),
        SshRuntimeError::Timeout => "SSH 连接超时".to_string(),
        SshRuntimeError::HostKeyChanged => "SSH 主机密钥已变更".to_string(),
        SshRuntimeError::UnknownHostKey => "SSH 主机密钥未知".to_string(),
        SshRuntimeError::Transport { message } => message,
    };
    let trimmed = detail.trim();
    let message = if trimmed.starts_with(phase) {
        trimmed.to_string()
    } else {
        format!("{phase}: {trimmed}")
    };
    SshRuntimeError::Transport {
        message: redact_ssh_diagnostic(&message),
    }
}

#[cfg(unix)]
fn bridge_proxy_jump_channel(
    local_stream: UnixStream,
    channel: ssh2::Channel,
) -> Result<Vec<thread::JoinHandle<()>>, SshRuntimeError> {
    let channel = Arc::new(Mutex::new(channel));
    let mut local_to_remote = local_stream
        .try_clone()
        .map_err(|error| Libssh2Transport::map_error(&error.to_string()))?;
    let mut remote_to_local = local_stream;
    let channel_writer = Arc::clone(&channel);
    let upload = thread::Builder::new()
        .name("stacio-proxyjump-local-to-remote".to_string())
        .spawn(move || {
            let mut buffer = [0_u8; 16 * 1024];
            loop {
                match local_to_remote.read(&mut buffer) {
                    Ok(0) => break,
                    Ok(count) => {
                        let write_result = channel_writer
                            .lock()
                            .map(|mut locked| locked.write_all(&buffer[..count]));
                        match write_result {
                            Ok(Ok(())) => {}
                            _ => break,
                        }
                    }
                    Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                    Err(_) => break,
                }
            }
        })
        .map_err(|error| Libssh2Transport::map_error(&error.to_string()))?;

    let download = thread::Builder::new()
        .name("stacio-proxyjump-remote-to-local".to_string())
        .spawn(move || {
            let mut buffer = [0_u8; 16 * 1024];
            loop {
                let read_result = channel.lock().map(|mut locked| locked.read(&mut buffer));
                match read_result {
                    Ok(Ok(0)) => break,
                    Ok(Ok(count)) => {
                        if remote_to_local.write_all(&buffer[..count]).is_err() {
                            break;
                        }
                    }
                    Ok(Err(error)) if error.kind() == io::ErrorKind::Interrupted => continue,
                    _ => break,
                }
            }
        })
        .map_err(|error| Libssh2Transport::map_error(&error.to_string()))?;

    Ok(vec![upload, download])
}

#[cfg(test)]
mod libssh2_transport_tests {
    use crate::domain::ssh::{
        fingerprint_sha256, LiveSshHostKey, SshAuthMethod, SshConnectionConfig, SshRuntimeError,
    };
    use crate::services::live_shell_service::{LiveShellStatus, ShellChannel};
    use std::net::{SocketAddr, TcpListener};
    use std::time::{Duration, Instant};

    use super::{
        connect_tcp_to_addresses, is_would_block_io_error, rich_grep_colors, trimmed_optional,
        with_temporary_blocking, Libssh2HostKeySummary, Libssh2ShellRequest, Libssh2Transport,
        SshSecret, SSH_SHELL_KEEPALIVE_INTERVAL_SECONDS,
    };

    #[test]
    fn adapter_accepts_structured_config_without_system_command() {
        let config = SshConnectionConfig {
            host: "example.com".to_string(),
            port: 22,
            username: "deploy".to_string(),
            auth_method: SshAuthMethod::Agent,
            connect_timeout_ms: 10_000,
        };
        let adapter = Libssh2Transport::new();

        let error = adapter.connect_preview(&config).expect_err("scaffold only");

        assert_eq!(
            error,
            SshRuntimeError::Transport {
                message: "libssh2 connection execution is not wired yet".to_string()
            }
        );
        assert!(!format!("{config:?}").contains("ssh "));
    }

    #[test]
    fn builds_endpoint_and_timeout_for_libssh2_session() {
        let config = SshConnectionConfig {
            host: "example.com".to_string(),
            port: 2222,
            username: "deploy".to_string(),
            auth_method: SshAuthMethod::Agent,
            connect_timeout_ms: 15_000,
        };
        let adapter = Libssh2Transport::new();

        let endpoint = adapter.endpoint(&config).expect("endpoint");

        assert_eq!(endpoint, "example.com:2222");
        assert_eq!(adapter.timeout_ms(&config), 15_000);
        assert!(!endpoint.contains("ssh "));
    }

    #[test]
    fn tcp_connect_races_multiple_resolved_addresses_and_uses_first_success() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("local listener");
        let local_address = listener.local_addr().expect("local address");
        let accept_thread = std::thread::spawn(move || {
            let _ = listener.accept();
        });
        let slow_first_address = SocketAddr::from(([10, 255, 255, 1], local_address.port()));
        let started_at = Instant::now();

        let stream = connect_tcp_to_addresses(&[slow_first_address, local_address], 2_000)
            .expect("fallback address should connect");

        assert!(stream.peer_addr().is_ok());
        assert!(
            started_at.elapsed() < Duration::from_secs(1),
            "fallback address should win without waiting for the first address timeout"
        );
        let _ = accept_thread.join();
    }

    #[test]
    fn tcp_connect_cancels_staggered_loser_after_first_success() {
        let winner_listener = TcpListener::bind("127.0.0.1:0").expect("winner listener");
        let loser_listener = TcpListener::bind("127.0.0.1:0").expect("loser listener");
        loser_listener
            .set_nonblocking(true)
            .expect("nonblocking loser listener");

        let stream = connect_tcp_to_addresses(
            &[
                winner_listener.local_addr().expect("winner address"),
                loser_listener.local_addr().expect("loser address"),
            ],
            2_000,
        )
        .expect("first address should connect");
        assert_eq!(
            stream.peer_addr().expect("winner peer"),
            winner_listener.local_addr().expect("winner address")
        );

        std::thread::sleep(Duration::from_millis(350));
        match loser_listener.accept() {
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {}
            Ok(_) => panic!("losing staggered address created an extra TCP connection"),
            Err(error) => panic!("unexpected loser listener error: {error}"),
        }
    }

    #[test]
    fn fast_tcp_connect_budget_does_not_limit_ssh_session_operations() {
        let source = include_str!("libssh2_transport.rs");
        let open_shell = source
            .split("pub fn open_shell_channel(")
            .nth(1)
            .and_then(|tail| {
                tail.split("pub fn open_shell_channel_via_proxy_jump(")
                    .next()
            })
            .expect("open shell implementation");

        assert!(
            open_shell.contains("connect_tcp(&self.endpoint(config)?, self.timeout_ms(config))?")
        );
        assert!(open_shell.contains("session.set_timeout(SSH_SESSION_OPERATION_TIMEOUT_MS);"));
        assert!(!open_shell.contains("session.set_timeout(self.timeout_ms(config));"));
    }

    #[test]
    fn builds_password_auth_request_without_secret_debug_output() {
        let config = SshConnectionConfig {
            host: "example.com".to_string(),
            port: 22,
            username: "deploy".to_string(),
            auth_method: SshAuthMethod::Password {
                credential_ref: "keychain:item".to_string(),
            },
            connect_timeout_ms: 10_000,
        };
        let adapter = Libssh2Transport::new();

        let request = adapter
            .auth_request(
                &config,
                Some(SshSecret::Password("super-secret".to_string())),
            )
            .expect("auth request");

        let debug = format!("{request:?}");
        assert!(debug.contains("Password"));
        assert!(!debug.contains("super-secret"));
        assert!(!debug.contains("ssh "));
        assert!(!debug.contains("scp "));
    }

    #[test]
    fn maps_missing_secret_to_invalid_config() {
        let config = SshConnectionConfig {
            host: "example.com".to_string(),
            port: 22,
            username: "deploy".to_string(),
            auth_method: SshAuthMethod::Password {
                credential_ref: "keychain:item".to_string(),
            },
            connect_timeout_ms: 10_000,
        };
        let adapter = Libssh2Transport::new();

        let error = adapter
            .auth_request(&config, None)
            .expect_err("missing secret");

        assert_eq!(error, SshRuntimeError::InvalidConfig);
    }

    #[test]
    fn builds_host_key_summary_from_raw_key() {
        let summary = Libssh2HostKeySummary::from_host_key("ssh-ed25519", b"host-key");

        assert_eq!(summary.key_type, "ssh-ed25519");
        assert!(summary.fingerprint_sha256.starts_with("SHA256:"));
        assert_eq!(summary.key_len, 8);
        assert!(!format!("{summary:?}").contains("host-key"));
    }

    #[test]
    fn shell_pty_request_uses_xterm_without_system_command() {
        let request = Libssh2ShellRequest::new("term_1".to_string(), 120, 40);

        assert_eq!(request.runtime_id, "term_1");
        assert_eq!(request.term, "xterm-256color");
        assert_eq!(request.cols, 120);
        assert_eq!(request.rows, 40);
        assert!(request
            .environment
            .iter()
            .any(|(name, value)| name == "COLORTERM" && value == "truecolor"));
        assert!(request
            .environment
            .iter()
            .any(|(name, value)| name == "CLICOLOR" && value == "1"));
        assert!(request
            .environment
            .iter()
            .any(|(name, value)| name == "FORCE_COLOR" && value == "1"));
        assert!(request
            .environment
            .iter()
            .any(|(name, value)| name == "SYSTEMD_COLORS" && value == "1"));
        assert!(request
            .environment
            .iter()
            .any(|(name, value)| name == "SYSTEMD_PAGERSECURE" && value == "0"));
        assert!(!request
            .environment
            .iter()
            .any(|(name, _)| name == "NO_COLOR"));
        assert!(request
            .environment
            .iter()
            .any(|(name, value)| name == "GREP_COLORS" && value == rich_grep_colors()));
        assert!(request
            .environment
            .iter()
            .any(|(name, value)| name == "LS_COLORS" && value.contains("*.swift=38;5;214")));
        let ls_colors = request
            .environment
            .iter()
            .find(|(name, _)| name == "LS_COLORS")
            .map(|(_, value)| value.as_str())
            .expect("LS_COLORS should be configured for remote shells");
        assert!(ls_colors.contains("Dockerfile=38;5;75"));
        assert!(ls_colors.contains("*Dockerfile=38;5;75"));
        assert!(ls_colors.contains("docker-compose.yml=38;5;179"));
        assert!(ls_colors.contains("*docker-compose.yml=38;5;179"));
        assert!(ls_colors.contains("docker-bake.hcl=38;5;179"));
        assert!(ls_colors.contains("*docker-bake*.hcl=38;5;179"));
        assert!(ls_colors.contains("buildkitd.toml=38;5;179"));
        assert!(ls_colors.contains("*.tf=38;5;141"));
        assert!(ls_colors.contains(".env.*=38;5;108"));
        assert!(ls_colors.contains("*.service=38;5;110"));
        assert!(ls_colors.contains("nginx.conf=38;5;110"));
        assert!(ls_colors.contains("*.kubeconfig=38;5;75"));
        assert!(!format!("{request:?}").contains("ssh "));
        assert!(!format!("{request:?}").contains("scp "));
    }

    #[test]
    fn live_shell_status_redacts_diagnostic_text() {
        let status = LiveShellStatus::failed(
            "term_1".to_string(),
            "auth failed with credential secret-ref and /Users/me/.ssh/id_ed25519",
        );

        assert!(!status.diagnostic.contains("secret-ref"));
        assert!(!status.diagnostic.contains("/Users/me/.ssh/id_ed25519"));
        assert!(status.diagnostic.contains("[redacted-credential]"));
    }

    #[test]
    fn ssh_shell_keepalive_interval_is_enabled_for_long_lived_sessions() {
        assert!(
            SSH_SHELL_KEEPALIVE_INTERVAL_SECONDS >= 10,
            "SSH shell keepalive should be enabled often enough to survive idle network devices"
        );
    }

    #[test]
    fn ssh_shell_keepalive_interval_matches_disconnected_tcp_detection_policy() {
        assert_eq!(
            SSH_SHELL_KEEPALIVE_INTERVAL_SECONDS, 30,
            "live SSH shells should probe every 30 seconds"
        );
    }

    #[test]
    fn open_shell_channel_enables_session_keepalive_for_live_ssh() {
        let source = include_str!("libssh2_transport.rs");
        let start = source
            .find("pub fn open_shell_channel(")
            .expect("open shell channel function exists");
        let rest = &source[start..];
        let end = rest
            .find("\n    fn host_key_from_session(")
            .expect("open shell channel function is followed by host key helper");
        let function_body = &rest[..end];

        assert!(
            function_body
                .contains("session.set_keepalive(false, SSH_SHELL_KEEPALIVE_INTERVAL_SECONDS);"),
            "live SSH shell sessions must enable libssh2 keepalive, matching other SSH connections"
        );
    }

    #[test]
    fn open_shell_channel_requests_keepalive_replies_for_liveness_detection() {
        let source = include_str!("libssh2_transport.rs");
        let start = source
            .find("pub fn open_shell_channel(")
            .expect("open shell channel function exists");
        let rest = &source[start..];
        let end = rest
            .find("\n    fn host_key_from_session(")
            .expect("open shell channel function is followed by host key helper");
        let function_body = &rest[..end];

        assert!(
            function_body
                .contains("session.set_keepalive(true, SSH_SHELL_KEEPALIVE_INTERVAL_SECONDS);"),
            "live SSH shell keepalive must request replies so repeated no-response probes can disconnect"
        );
    }

    #[test]
    fn keepalive_would_block_detection_accepts_libssh2_session_message() {
        let error = std::io::Error::new(std::io::ErrorKind::Other, "session(-37): would block");

        assert!(is_would_block_io_error(&error));
    }

    #[test]
    fn builds_live_host_key_from_raw_key_without_secret_values() {
        let key = LiveSshHostKey::from_host_key("example.com", 22, "ssh-ed25519", b"host-key");

        assert_eq!(key.host, "example.com");
        assert_eq!(key.port, 22);
        assert_eq!(key.key_type, "ssh-ed25519");
        assert_eq!(key.key_len, 8);
        assert!(key.fingerprint_sha256.starts_with("SHA256:"));
        assert_eq!(key.raw_key, b"host-key".to_vec());
        assert!(!format!("{key:?}").contains("host-key"));
        assert!(!format!("{key:?}").contains("secret"));
    }

    #[test]
    fn rejects_expected_fingerprint_mismatch_before_auth_request_is_used() {
        let observed = LiveSshHostKey::from_host_key("example.com", 22, "ssh-ed25519", b"new-key");
        let error = Libssh2Transport::verify_expected_fingerprint(
            &observed,
            &fingerprint_sha256(b"old-key"),
        )
        .expect_err("changed host key");

        assert_eq!(error, SshRuntimeError::HostKeyChanged);
    }

    #[test]
    fn accepts_expected_fingerprint_match_before_authentication() {
        let observed = LiveSshHostKey::from_host_key("example.com", 22, "ssh-ed25519", b"host-key");

        Libssh2Transport::verify_expected_fingerprint(&observed, &observed.fingerprint_sha256)
            .expect("matching fingerprint");
    }

    #[test]
    fn expected_session_rejects_invalid_endpoint_before_authentication() {
        let config = SshConnectionConfig {
            host: "".to_string(),
            port: 22,
            username: "deploy".to_string(),
            auth_method: SshAuthMethod::Agent,
            connect_timeout_ms: 10_000,
        };
        let adapter = Libssh2Transport::new();

        let error = match adapter.connect_with_secret_and_expected_session(
            &config,
            None,
            "SHA256:test".to_string(),
        ) {
            Ok(_) => panic!("expected invalid endpoint"),
            Err(error) => error,
        };

        assert_eq!(error, SshRuntimeError::InvalidConfig);
    }

    #[test]
    fn maps_libssh2_error_messages_without_credentials() {
        let error = Libssh2Transport::map_error(
            "auth failed for credential secret-ref and key /Users/me/.ssh/id_ed25519",
        );

        assert_eq!(
            error,
            SshRuntimeError::Transport {
                message: "auth failed for [redacted-credential] [redacted-credential] and key [redacted-path]".to_string()
            }
        );
    }

    #[test]
    fn maps_libssh2_would_block_to_actionable_diagnostic() {
        let error = Libssh2Transport::map_error("[Session(-37)] Would block");

        assert_eq!(
            error,
            SshRuntimeError::Transport {
                message: "SSH 通道暂时不可用，请稍后重试".to_string()
            }
        );
    }

    #[test]
    fn trimmed_optional_treats_missing_and_blank_values_as_absent() {
        assert_eq!(trimmed_optional(None), None);
        assert_eq!(trimmed_optional(Some("   \n\t")), None);
        assert_eq!(
            trimmed_optional(Some(" aes256-ctr ")),
            Some("aes256-ctr".to_string())
        );
    }

    #[test]
    fn temporary_blocking_scope_restores_nonblocking_sessions_after_setup() {
        let session = Libssh2Transport::new().create_session().expect("session");
        session.set_blocking(false);

        with_temporary_blocking(&session, true, || {
            assert!(session.is_blocking());
            Ok::<_, ssh2::Error>(())
        })
        .expect("temporary blocking scope");

        assert!(!session.is_blocking());
    }

    #[test]
    fn connects_to_gated_ssh_fixture_when_configured() {
        let Some((config, secret)) = ssh_fixture_config() else {
            return;
        };
        let adapter = Libssh2Transport::new();

        let connected = adapter
            .connect_with_secret(&config, secret)
            .expect("fixture ssh connection");

        assert!(connected.authenticated());
        assert_eq!(connected.host_key.key_len > 0, true);
        assert!(connected.host_key.fingerprint_sha256.starts_with("SHA256:"));
    }

    #[test]
    fn opens_shell_channel_and_reads_marker_with_gated_fixture_when_configured() {
        let Some((config, secret)) = ssh_fixture_config() else {
            return;
        };
        let adapter = Libssh2Transport::new();
        let host_key = adapter.probe_host_key(&config).expect("fixture host key");
        let request = Libssh2ShellRequest::new("term_fixture".to_string(), 80, 24);
        let (mut channel, _session_info) = adapter
            .open_shell_channel(&config, secret, host_key.fingerprint_sha256, request)
            .expect("fixture shell channel");

        channel
            .write_input(b"printf 'STACIO_SHELL_FIXTURE_OK\\n'\nexit\n")
            .expect("write fixture command");

        let output = read_shell_fixture_until_marker(
            &mut channel,
            "STACIO_SHELL_FIXTURE_OK",
            Duration::from_secs(5),
        );

        assert!(
            output.contains("STACIO_SHELL_FIXTURE_OK"),
            "fixture shell output did not contain marker: {output:?}"
        );
    }

    #[test]
    fn shell_channel_reports_osc7_after_bootstrap_with_gated_fixture_when_configured() {
        let Some((config, secret)) = ssh_fixture_config() else {
            return;
        };
        let adapter = Libssh2Transport::new();
        let host_key = adapter.probe_host_key(&config).expect("fixture host key");
        let request = Libssh2ShellRequest::new("term_fixture_osc7".to_string(), 80, 24);
        let (mut channel, _session_info) = adapter
            .open_shell_channel(&config, secret, host_key.fingerprint_sha256, request)
            .expect("fixture shell channel");

        let bootstrap =
            crate::services::live_shell_service::ssh_osc7_bootstrap_input_chunks().concat();
        channel
            .write_input(&bootstrap)
            .expect("write osc7 bootstrap");

        let output = read_shell_fixture_until_marker(
            &mut channel,
            "\u{1b}]7;file://",
            Duration::from_secs(5),
        );
        let _ = channel.write_input(b"exit\n");

        assert!(
            output.contains("\u{1b}]7;file://"),
            "fixture shell output did not contain OSC7 report: {output:?}"
        );
    }

    fn read_shell_fixture_until_marker(
        channel: &mut impl ShellChannel,
        marker: &str,
        timeout: Duration,
    ) -> String {
        let deadline = Instant::now() + timeout;
        let mut output = Vec::new();

        while Instant::now() < deadline {
            let chunk = channel.read_output(16 * 1024).expect("read shell output");
            if !chunk.is_empty() {
                output.extend_from_slice(&chunk);
                let text = String::from_utf8_lossy(&output).to_string();
                if text.contains(marker) {
                    return text;
                }
            }

            if channel.is_eof() {
                break;
            }

            std::thread::sleep(Duration::from_millis(50));
        }

        String::from_utf8_lossy(&output).to_string()
    }

    fn ssh_fixture_config() -> Option<(SshConnectionConfig, Option<SshSecret>)> {
        let host = std::env::var("STACIO_SSH_FIXTURE_HOST").ok()?;
        let username = std::env::var("STACIO_SSH_FIXTURE_USERNAME").ok()?;
        let port = std::env::var("STACIO_SSH_FIXTURE_PORT")
            .ok()
            .and_then(|value| value.parse::<u16>().ok())
            .unwrap_or(22);
        let password = std::env::var("STACIO_SSH_FIXTURE_PASSWORD").ok();
        let private_key = std::env::var("STACIO_SSH_FIXTURE_PRIVATE_KEY").ok();
        let passphrase = std::env::var("STACIO_SSH_FIXTURE_PRIVATE_KEY_PASSPHRASE").ok();

        if let Some(password) = password {
            return Some((
                SshConnectionConfig {
                    host,
                    port,
                    username,
                    auth_method: SshAuthMethod::Password {
                        credential_ref: "fixture-password".to_string(),
                    },
                    connect_timeout_ms: 5_000,
                },
                Some(SshSecret::Password(password)),
            ));
        }

        private_key.map(|private_key_pem| {
            (
                SshConnectionConfig {
                    host,
                    port,
                    username,
                    auth_method: SshAuthMethod::PrivateKey {
                        key_path: "fixture-memory-key".to_string(),
                        passphrase_ref: passphrase
                            .as_ref()
                            .map(|_| "fixture-passphrase".to_string()),
                    },
                    connect_timeout_ms: 5_000,
                },
                Some(SshSecret::PrivateKey {
                    private_key_pem,
                    passphrase,
                }),
            )
        })
    }
}
