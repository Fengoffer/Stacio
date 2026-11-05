use std::{
    io::{self, Read, Write},
    net::{TcpStream, ToSocketAddrs},
    time::{Duration, Instant},
};

#[cfg(unix)]
use std::os::fd::AsRawFd;

use crate::{
    domain::ssh::{redact_ssh_diagnostic, SshRuntimeError},
    services::{
        live_shell_service::{ShellChannel, ShellWaitInterest},
        telnet_service::TelnetNegotiationFilter,
    },
};

pub struct TelnetShellChannel {
    stream: TcpStream,
    negotiation_filter: TelnetNegotiationFilter,
    pending_negotiation_response: Vec<u8>,
    auth_gate: Option<TelnetAuthGate>,
    eof: bool,
}

// A peer can send negotiation requests faster than a congested socket can
// accept replies. Keep that control-plane queue bounded so a broken/malicious
// peer cannot grow the process indefinitely while the terminal is idle.
const MAX_PENDING_NEGOTIATION_RESPONSE_BYTES: usize = 64 * 1024;
const TELNET_AUTH_PROMPT_TIMEOUT: Duration = Duration::from_secs(10);
const TELNET_AUTH_PROMPT_BUFFER_BYTES: usize = 4096;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum TelnetAuthPhase {
    WaitingUsername,
    UsernameReady,
    WaitingPassword,
    PasswordReady,
    Complete,
}

struct TelnetAuthGate {
    phase: TelnetAuthPhase,
    password_configured: bool,
    prompt_buffer: Vec<u8>,
    deadline: Instant,
}

impl TelnetAuthGate {
    fn new(username: Option<&str>, password: Option<&str>) -> Option<Self> {
        if username.is_none() && password.is_none() {
            return None;
        }
        Some(Self {
            phase: if username.is_some() {
                TelnetAuthPhase::WaitingUsername
            } else {
                TelnetAuthPhase::WaitingPassword
            },
            password_configured: password.is_some(),
            prompt_buffer: Vec::new(),
            deadline: Instant::now() + TELNET_AUTH_PROMPT_TIMEOUT,
        })
    }

    fn observe_output(&mut self, output: &[u8]) {
        if output.is_empty() {
            return;
        }
        self.prompt_buffer.extend_from_slice(output);
        if self.prompt_buffer.len() > TELNET_AUTH_PROMPT_BUFFER_BYTES {
            let start = self.prompt_buffer.len() - TELNET_AUTH_PROMPT_BUFFER_BYTES;
            self.prompt_buffer.drain(..start);
        }
        let prompt = String::from_utf8_lossy(&self.prompt_buffer).to_ascii_lowercase();
        match self.phase {
            TelnetAuthPhase::WaitingUsername if has_username_prompt(&prompt) => {
                self.phase = TelnetAuthPhase::UsernameReady;
            }
            TelnetAuthPhase::WaitingPassword if has_password_prompt(&prompt) => {
                self.phase = TelnetAuthPhase::PasswordReady;
            }
            _ => {}
        }
    }

    fn before_write(&self) -> io::Result<()> {
        if matches!(
            self.phase,
            TelnetAuthPhase::WaitingUsername | TelnetAuthPhase::WaitingPassword
        ) {
            if Instant::now() >= self.deadline {
                return Err(io::Error::new(
                    io::ErrorKind::PermissionDenied,
                    "telnet authentication prompt not detected",
                ));
            }
            return Err(io::Error::new(
                io::ErrorKind::WouldBlock,
                "waiting for telnet authentication prompt",
            ));
        }
        Ok(())
    }

    fn after_write(&mut self, written: usize, total: usize) {
        if written != total {
            return;
        }
        let prompt_snapshot = self.prompt_buffer.clone();
        self.phase = match self.phase {
            TelnetAuthPhase::UsernameReady if self.password_configured => {
                TelnetAuthPhase::WaitingPassword
            }
            TelnetAuthPhase::UsernameReady => TelnetAuthPhase::Complete,
            TelnetAuthPhase::PasswordReady => TelnetAuthPhase::Complete,
            phase => phase,
        };
        self.prompt_buffer.clear();
        if matches!(self.phase, TelnetAuthPhase::WaitingPassword) {
            self.deadline = Instant::now() + TELNET_AUTH_PROMPT_TIMEOUT;
            // Some embedded Telnet servers emit `login: Password:` in a
            // single packet. The password prompt was observed while the
            // gate was still waiting for the username, so inspect that same
            // packet after advancing the phase instead of blocking input.
            if has_password_prompt_bytes(&prompt_snapshot) {
                self.phase = TelnetAuthPhase::PasswordReady;
            }
        }
    }
}

fn has_username_prompt(output: &str) -> bool {
    if has_username_prompt_bytes(output.as_bytes()) {
        return true;
    }
    let Some(label) = prompt_label(output) else {
        return false;
    };
    if matches!(
        label.as_str(),
        "user" | "user id" | "username" | "user name" | "login" | "login name"
    ) || label.starts_with("user ")
        || label.starts_with("login ")
    {
        return true;
    }
    let Some(prefix) = label.strip_suffix(" login") else {
        return false;
    };
    let prefix = prefix.trim();
    prefix != "last" && !prefix.is_empty() && !prefix.chars().any(char::is_whitespace)
}

fn has_password_prompt(output: &str) -> bool {
    if has_password_prompt_bytes(output.as_bytes()) {
        return true;
    }
    let Some(label) = prompt_label(output) else {
        return false;
    };
    matches!(label.as_str(), "password" | "passwd" | "passcode")
        || label.starts_with("password ")
        || label.starts_with("enter password")
        || label.starts_with("passcode ")
}

fn has_username_prompt_bytes(output: &[u8]) -> bool {
    let normalized = strip_ansi_csi(&String::from_utf8_lossy(output)).to_ascii_lowercase();
    normalized.split(['\r', '\n']).any(|line| {
        let line = line.trim();
        ["username", "user name", "user id", "user", "login"]
            .iter()
            .any(|label| {
                let marker = format!("{label}:");
                line.contains(&marker) && !(label == &"login" && line.contains("last login:"))
            })
    })
}

fn has_password_prompt_bytes(output: &[u8]) -> bool {
    let normalized = strip_ansi_csi(&String::from_utf8_lossy(output)).to_ascii_lowercase();
    normalized.split(['\r', '\n']).any(|line| {
        let line = line.trim();
        ["password", "passwd", "passcode"]
            .iter()
            .any(|label| line.contains(&format!("{label}:")))
            || line.contains("enter password")
    })
}

fn prompt_label(output: &str) -> Option<String> {
    let line = output
        .rsplit(['\r', '\n'])
        .find(|line| !line.trim().is_empty())
        .unwrap_or_default()
        .trim();
    let normalized = strip_ansi_csi(line);
    let label = normalized.trim().strip_suffix(':')?.trim();
    (!label.is_empty()).then(|| label.to_ascii_lowercase())
}

fn strip_ansi_csi(input: &str) -> String {
    let mut output = String::with_capacity(input.len());
    let mut characters = input.chars();
    while let Some(character) = characters.next() {
        if character != '\x1b' {
            output.push(character);
            continue;
        }
        if characters.next() != Some('[') {
            continue;
        }
        for character in characters.by_ref() {
            if ('@'..='~').contains(&character) {
                break;
            }
        }
    }
    output
}

impl TelnetShellChannel {
    pub fn connect(host: &str, port: u16, timeout_ms: u32) -> Result<Self, SshRuntimeError> {
        Self::connect_internal(host, port, timeout_ms, None, None)
    }

    pub fn connect_with_credentials(
        host: &str,
        port: u16,
        timeout_ms: u32,
        username: Option<&str>,
        password: Option<&str>,
    ) -> Result<Self, SshRuntimeError> {
        Self::connect_internal(host, port, timeout_ms, username, password)
    }

    fn connect_internal(
        host: &str,
        port: u16,
        timeout_ms: u32,
        username: Option<&str>,
        password: Option<&str>,
    ) -> Result<Self, SshRuntimeError> {
        if host.trim().is_empty() || port == 0 || timeout_ms == 0 {
            return Err(SshRuntimeError::InvalidConfig);
        }
        let timeout = Duration::from_millis(timeout_ms as u64);
        let host = host.trim();
        let lookup_host = host
            .strip_prefix('[')
            .and_then(|value| value.strip_suffix(']'))
            .unwrap_or(host);
        let addresses = (lookup_host, port)
            .to_socket_addrs()
            .map_err(|error| telnet_transport_error(&error.to_string()))?
            .collect::<Vec<_>>();
        if addresses.is_empty() {
            return Err(SshRuntimeError::InvalidConfig);
        }
        let stream = connect_with_timeout_fallback(&addresses, timeout)
            .map_err(|error| telnet_transport_error(&error.to_string()))?;
        configure_tcp_keepalive(&stream);
        stream
            .set_nonblocking(true)
            .map_err(|error| telnet_transport_error(&error.to_string()))?;
        Ok(Self {
            stream,
            negotiation_filter: TelnetNegotiationFilter::new(),
            pending_negotiation_response: Vec::new(),
            auth_gate: TelnetAuthGate::new(username, password),
            eof: false,
        })
    }

    fn flush_pending_negotiation_response(&mut self) -> io::Result<bool> {
        while !self.pending_negotiation_response.is_empty() {
            match self.stream.write(&self.pending_negotiation_response) {
                Ok(0) => return Ok(false),
                Ok(count) => {
                    let written = count.min(self.pending_negotiation_response.len());
                    self.pending_negotiation_response.drain(..written);
                }
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(error)
                    if matches!(
                        error.kind(),
                        io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
                    ) =>
                {
                    return Ok(false);
                }
                Err(error) => return Err(error),
            }
        }
        Ok(true)
    }

    fn queue_negotiation_response(&mut self, response: &[u8]) {
        // Filter responses are concatenated three-byte IAC negotiation
        // frames. Keep as many complete frames as fit instead of dropping an
        // entire batch when only its final frame exceeds the bound.
        for frame in response.chunks(3) {
            let available = MAX_PENDING_NEGOTIATION_RESPONSE_BYTES
                .saturating_sub(self.pending_negotiation_response.len());
            if frame.len() > available {
                break;
            }
            self.pending_negotiation_response.extend_from_slice(frame);
        }
    }
}

fn connect_with_timeout_fallback(
    addresses: &[std::net::SocketAddr],
    timeout: Duration,
) -> io::Result<TcpStream> {
    let deadline = Instant::now() + timeout;
    let mut last_error = None;
    for (index, address) in addresses.iter().enumerate() {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            break;
        }
        let remaining_addresses = (addresses.len() - index) as u32;
        let attempt_timeout = (remaining / remaining_addresses).max(Duration::from_millis(1));
        match TcpStream::connect_timeout(address, attempt_timeout) {
            Ok(stream) => return Ok(stream),
            Err(error) => last_error = Some(error),
        }
    }
    Err(last_error.unwrap_or_else(|| io::Error::from(io::ErrorKind::TimedOut)))
}

impl ShellChannel for TelnetShellChannel {
    fn write_input(&mut self, bytes: &[u8]) -> io::Result<usize> {
        if !self.flush_pending_negotiation_response()? {
            return Err(io::Error::new(
                io::ErrorKind::WouldBlock,
                "telnet negotiation response is pending",
            ));
        }
        if let Some(auth_gate) = &self.auth_gate {
            auth_gate.before_write()?;
        }
        let written = self.stream.write(bytes)?;
        if let Some(auth_gate) = &mut self.auth_gate {
            auth_gate.after_write(written, bytes.len());
        }
        Ok(written)
    }

    fn read_output(&mut self, max_bytes: usize) -> io::Result<Vec<u8>> {
        if max_bytes == 0 {
            return Ok(Vec::new());
        }

        // Read before flushing protocol replies.  When a peer closes while a
        // refusal is queued, the write can report EPIPE/ECONNRESET even though
        // the kernel still has the peer's final output buffered.  Consuming
        // the readable bytes first prevents that control-plane error from
        // dropping the terminal tail.
        let mut buffer = vec![0_u8; max_bytes];
        match self.stream.read(&mut buffer) {
            Ok(0) => {
                self.eof = true;
                Ok(Vec::new())
            }
            Ok(count) => {
                buffer.truncate(count);
                let filtered = self.negotiation_filter.filter_read(&buffer);
                if !filtered.responses.is_empty() {
                    self.queue_negotiation_response(&filtered.responses);
                }
                if let Some(auth_gate) = &mut self.auth_gate {
                    auth_gate.observe_output(&filtered.output);
                }

                // A hard reply failure means the transport is going away,
                // but the visible payload above is still valid and must be
                // returned to the worker.  The worker will drain once more
                // before closing the runtime.
                if let Err(error) = self.flush_pending_negotiation_response() {
                    if is_disconnect_io_error(&error) {
                        self.eof = true;
                    } else {
                        return Err(error);
                    }
                }
                Ok(filtered.output)
            }
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::WouldBlock
                        | io::ErrorKind::Interrupted
                        | io::ErrorKind::TimedOut
                ) =>
            {
                // There was no readable payload this round, so make a best
                // effort to flush queued negotiation replies.  WouldBlock is
                // expected on a congested socket and is retried by the next
                // poll; a hard disconnect is represented as EOF.
                match self.flush_pending_negotiation_response() {
                    Ok(_) => Ok(Vec::new()),
                    Err(flush_error) if is_disconnect_io_error(&flush_error) => {
                        self.eof = true;
                        Ok(Vec::new())
                    }
                    Err(flush_error) => Err(flush_error),
                }
            }
            Err(error) => Err(error),
        }
    }

    fn resize_pty(&mut self, _cols: u32, _rows: u32) -> io::Result<()> {
        Ok(())
    }

    fn close(&mut self) -> io::Result<()> {
        self.eof = true;
        self.stream.shutdown(std::net::Shutdown::Both)
    }

    fn is_eof(&self) -> bool {
        self.eof
    }

    fn keepalive(&mut self) -> io::Result<()> {
        // IAC NOP is a protocol-level liveness probe and is ignored by
        // compliant Telnet peers. TCP keepalive below covers peers that do
        // not answer application traffic at all.
        self.queue_negotiation_response(&[255, 241]);
        if self.flush_pending_negotiation_response()? {
            Ok(())
        } else {
            Err(io::Error::new(
                io::ErrorKind::WouldBlock,
                "telnet keepalive is pending",
            ))
        }
    }

    fn wait_interest(&self) -> Option<ShellWaitInterest> {
        #[cfg(unix)]
        {
            return Some(ShellWaitInterest::new(
                self.stream.as_raw_fd(),
                true,
                !self.pending_negotiation_response.is_empty(),
            ));
        }
        #[cfg(not(unix))]
        {
            None
        }
    }
}

#[cfg(unix)]
fn configure_tcp_keepalive(stream: &TcpStream) {
    let fd = stream.as_raw_fd();
    let enabled: libc::c_int = 1;
    let idle_seconds: libc::c_int = 30;
    let interval_seconds: libc::c_int = 10;
    let probe_count: libc::c_int = 3;
    let value_size = std::mem::size_of::<libc::c_int>() as libc::socklen_t;

    unsafe {
        let _ = libc::setsockopt(
            fd,
            libc::SOL_SOCKET,
            libc::SO_KEEPALIVE,
            (&enabled as *const libc::c_int).cast(),
            value_size,
        );
        #[cfg(any(target_os = "macos", target_os = "ios"))]
        let _ = libc::setsockopt(
            fd,
            libc::IPPROTO_TCP,
            libc::TCP_KEEPALIVE,
            (&idle_seconds as *const libc::c_int).cast(),
            value_size,
        );
        #[cfg(any(target_os = "linux", target_os = "android"))]
        let _ = libc::setsockopt(
            fd,
            libc::IPPROTO_TCP,
            libc::TCP_KEEPIDLE,
            (&idle_seconds as *const libc::c_int).cast(),
            value_size,
        );
        let _ = libc::setsockopt(
            fd,
            libc::IPPROTO_TCP,
            libc::TCP_KEEPINTVL,
            (&interval_seconds as *const libc::c_int).cast(),
            value_size,
        );
        let _ = libc::setsockopt(
            fd,
            libc::IPPROTO_TCP,
            libc::TCP_KEEPCNT,
            (&probe_count as *const libc::c_int).cast(),
            value_size,
        );
    }
}

#[cfg(not(unix))]
fn configure_tcp_keepalive(_stream: &TcpStream) {}

fn telnet_transport_error(message: &str) -> SshRuntimeError {
    let redacted = redact_ssh_diagnostic(message);
    if redacted.contains("timed out") {
        SshRuntimeError::Timeout
    } else {
        SshRuntimeError::Transport { message: redacted }
    }
}

fn is_disconnect_io_error(error: &io::Error) -> bool {
    matches!(
        error.kind(),
        io::ErrorKind::BrokenPipe
            | io::ErrorKind::ConnectionAborted
            | io::ErrorKind::ConnectionReset
            | io::ErrorKind::NotConnected
            | io::ErrorKind::UnexpectedEof
    )
}

#[cfg(test)]
mod tests {
    use super::{
        connect_with_timeout_fallback, TelnetAuthGate, TelnetAuthPhase, TelnetShellChannel,
        MAX_PENDING_NEGOTIATION_RESPONSE_BYTES,
    };
    use crate::services::live_shell_service::ShellChannel;
    use std::{
        io::{Read, Write},
        net::{Shutdown, TcpListener},
        thread,
        time::{Duration, Instant},
    };

    #[test]
    fn telnet_channel_filters_negotiation_and_writes_refusal() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind telnet fixture");
        let port = listener.local_addr().expect("fixture addr").port();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept telnet client");
            stream
                .set_read_timeout(Some(Duration::from_secs(2)))
                .expect("server timeout");
            stream
                .write_all(&[255, 251, 1, b'l', b'o', b'g', b'i', b'n', b':', b' '])
                .expect("write telnet greeting");
            let mut response = [0_u8; 3];
            stream.read_exact(&mut response).expect("read refusal");
            response
        });
        let mut channel =
            TelnetShellChannel::connect("127.0.0.1", port, 2_000).expect("connect telnet channel");

        let output = read_until_non_empty(&mut channel);
        let response = server.join().expect("server finished");

        assert_eq!(output, b"login: ".to_vec());
        assert_eq!(response, [255, 254, 1]);
    }

    #[test]
    fn telnet_auth_input_waits_for_prompts() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind telnet fixture");
        let port = listener.local_addr().expect("fixture addr").port();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept telnet client");
            stream
                .set_read_timeout(Some(Duration::from_secs(2)))
                .expect("server timeout");
            thread::sleep(Duration::from_millis(50));
            stream.write_all(b"login: ").expect("write login prompt");
            let mut username = [0_u8; 6];
            stream.read_exact(&mut username).expect("read username");
            stream
                .write_all(b"Password: ")
                .expect("write password prompt");
            let mut password = [0_u8; 7];
            stream.read_exact(&mut password).expect("read password");
            (username, password)
        });
        let mut channel = TelnetShellChannel::connect_with_credentials(
            "127.0.0.1",
            port,
            2_000,
            Some("admin"),
            Some("secret"),
        )
        .expect("connect telnet channel");

        assert_eq!(
            channel
                .write_input(b"admin\n")
                .expect_err("wait for login prompt")
                .kind(),
            std::io::ErrorKind::WouldBlock
        );
        assert_eq!(read_until_non_empty(&mut channel), b"login: ".to_vec());
        assert_eq!(channel.write_input(b"admin\n").expect("write username"), 6);
        assert_eq!(read_until_non_empty(&mut channel), b"Password: ".to_vec());
        assert_eq!(channel.write_input(b"secret\n").expect("write password"), 7);

        let (username, password) = server.join().expect("server finished");
        assert_eq!(&username, b"admin\n");
        assert_eq!(&password, b"secret\n");
    }

    #[test]
    fn telnet_auth_does_not_treat_last_login_banner_as_prompt() {
        let mut gate =
            TelnetAuthGate::new(Some("admin"), Some("secret")).expect("create telnet auth gate");

        gate.observe_output(b"Last login: ");

        assert_eq!(gate.phase, TelnetAuthPhase::WaitingUsername);
        assert_eq!(
            gate.before_write().expect_err("still waiting").kind(),
            std::io::ErrorKind::WouldBlock
        );
    }

    #[test]
    fn telnet_auth_recognizes_common_prompt_variants() {
        let mut gate =
            TelnetAuthGate::new(Some("admin"), Some("secret")).expect("create telnet auth gate");

        gate.observe_output(b"\x1b[32mUser:\x1b[0m ");
        assert_eq!(gate.phase, TelnetAuthPhase::UsernameReady);
        gate.after_write(6, 6);

        gate.observe_output(b"Password for admin: ");
        assert_eq!(gate.phase, TelnetAuthPhase::PasswordReady);
    }

    #[test]
    fn telnet_auth_recognizes_combined_login_and_password_prompt() {
        let mut gate =
            TelnetAuthGate::new(Some("admin"), Some("secret")).expect("create telnet auth gate");

        gate.observe_output(b"HZ_NAS_DS918 login: Password: ");
        assert_eq!(gate.phase, TelnetAuthPhase::UsernameReady);
        gate.after_write(6, 6);
        assert_eq!(gate.phase, TelnetAuthPhase::PasswordReady);
    }

    #[test]
    fn telnet_connect_falls_back_to_later_resolved_address() {
        let unavailable = TcpListener::bind("127.0.0.1:0").expect("bind unavailable fixture");
        let unavailable_address = unavailable.local_addr().expect("unavailable address");
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind available fixture");
        let available_address = listener.local_addr().expect("available address");
        drop(unavailable);
        let server = thread::spawn(move || listener.accept().expect("accept fallback client"));

        let stream = connect_with_timeout_fallback(
            &[unavailable_address, available_address],
            Duration::from_secs(1),
        )
        .expect("connect using later address");
        drop(stream);
        drop(server.join().expect("server finished"));
    }

    #[test]
    fn telnet_negotiation_response_queue_is_bounded() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind telnet fixture");
        let port = listener.local_addr().expect("fixture addr").port();
        let server = thread::spawn(move || listener.accept().expect("accept telnet client"));
        let mut channel =
            TelnetShellChannel::connect("127.0.0.1", port, 2_000).expect("connect telnet channel");
        let peer = server.join().expect("server finished");

        channel.pending_negotiation_response =
            vec![255; MAX_PENDING_NEGOTIATION_RESPONSE_BYTES - 3];
        channel.queue_negotiation_response(&[255; 3]);

        assert_eq!(
            channel.pending_negotiation_response.len(),
            MAX_PENDING_NEGOTIATION_RESPONSE_BYTES
        );
        drop(peer);
    }

    #[test]
    fn telnet_negotiation_queue_keeps_only_complete_frames_that_fit() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind telnet fixture");
        let port = listener.local_addr().expect("fixture addr").port();
        let server = thread::spawn(move || listener.accept().expect("accept telnet client"));
        let mut channel =
            TelnetShellChannel::connect("127.0.0.1", port, 2_000).expect("connect telnet channel");
        let peer = server.join().expect("server finished");
        channel.pending_negotiation_response =
            vec![255; MAX_PENDING_NEGOTIATION_RESPONSE_BYTES - 6];

        channel.queue_negotiation_response(&[255, 254, 1, 255, 252, 3, 255, 254, 24]);

        assert_eq!(
            &channel.pending_negotiation_response[MAX_PENDING_NEGOTIATION_RESPONSE_BYTES - 6..],
            &[255, 254, 1, 255, 252, 3]
        );
        assert_eq!(
            channel.pending_negotiation_response.len(),
            MAX_PENDING_NEGOTIATION_RESPONSE_BYTES
        );
        drop(peer);
    }

    #[test]
    fn idle_telnet_read_does_not_close_connection() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind telnet fixture");
        let port = listener.local_addr().expect("fixture addr").port();
        let server = thread::spawn(move || {
            let (_stream, _) = listener.accept().expect("accept telnet client");
            thread::sleep(Duration::from_millis(100));
        });
        let mut channel =
            TelnetShellChannel::connect("127.0.0.1", port, 2_000).expect("connect telnet channel");

        let output = channel.read_output(1024).expect("read idle telnet channel");

        assert!(output.is_empty());
        assert!(!channel.is_eof());
        server.join().expect("server finished");
    }

    #[test]
    fn readable_telnet_data_is_not_starved_by_blocked_negotiation_reply() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind telnet fixture");
        let port = listener.local_addr().expect("fixture addr").port();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept telnet client");
            stream.write_all(b"ready> ").expect("write visible output");
            thread::sleep(Duration::from_millis(250));
        });
        let mut channel =
            TelnetShellChannel::connect("127.0.0.1", port, 2_000).expect("connect telnet channel");

        channel.pending_negotiation_response = vec![255; 8 * 1024 * 1024];
        assert!(!channel
            .flush_pending_negotiation_response()
            .expect("flush pending response"));
        assert!(!channel.pending_negotiation_response.is_empty());

        let output = channel.read_output(1024).expect("read visible output");
        assert_eq!(output, b"ready> ".to_vec());
        server.join().expect("server finished");
    }

    #[test]
    fn readable_telnet_tail_survives_reply_disconnect_error() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind telnet fixture");
        let port = listener.local_addr().expect("fixture addr").port();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept telnet client");
            stream
                .write_all(b"tail-before-close\r\n")
                .expect("write final telnet output");
            thread::sleep(Duration::from_millis(100));
        });
        let mut channel =
            TelnetShellChannel::connect("127.0.0.1", port, 2_000).expect("connect telnet channel");

        // Force the next protocol reply to fail locally while keeping the
        // read half open.  The peer's final bytes must still be returned.
        channel
            .stream
            .shutdown(Shutdown::Write)
            .expect("shutdown local telnet write half");
        channel.pending_negotiation_response = vec![255, 254, 1];

        let output = read_until_non_empty(&mut channel);
        assert_eq!(output, b"tail-before-close\r\n".to_vec());
        assert!(channel.is_eof());
        server.join().expect("server finished");
    }

    #[test]
    fn remote_telnet_close_is_reported_as_eof() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind telnet fixture");
        let port = listener.local_addr().expect("fixture addr").port();
        let server = thread::spawn(move || {
            let (_stream, _) = listener.accept().expect("accept telnet client");
        });
        let mut channel =
            TelnetShellChannel::connect("127.0.0.1", port, 2_000).expect("connect telnet channel");
        server.join().expect("server finished");

        let deadline = Instant::now() + Duration::from_secs(1);
        while !channel.is_eof() && Instant::now() < deadline {
            let _ = channel
                .read_output(1024)
                .expect("poll closed telnet channel");
            thread::sleep(Duration::from_millis(5));
        }

        assert!(channel.is_eof());
    }

    fn read_until_non_empty(channel: &mut TelnetShellChannel) -> Vec<u8> {
        let deadline = Instant::now() + Duration::from_secs(2);
        while Instant::now() < deadline {
            let output = channel.read_output(1024).expect("read telnet output");
            if !output.is_empty() {
                return output;
            }
            thread::sleep(Duration::from_millis(10));
        }
        Vec::new()
    }
}
