use std::{
    io::{self, Read, Write},
    net::{TcpStream, ToSocketAddrs},
    time::Duration,
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
    eof: bool,
}

impl TelnetShellChannel {
    pub fn connect(host: &str, port: u16, timeout_ms: u32) -> Result<Self, SshRuntimeError> {
        let endpoint = format!("{}:{}", host.trim(), port);
        if host.trim().is_empty() || port == 0 || timeout_ms == 0 {
            return Err(SshRuntimeError::InvalidConfig);
        }
        let timeout = Duration::from_millis(timeout_ms as u64);
        let mut addresses = endpoint
            .to_socket_addrs()
            .map_err(|error| telnet_transport_error(&error.to_string()))?;
        let address = addresses.next().ok_or(SshRuntimeError::InvalidConfig)?;
        let stream = TcpStream::connect_timeout(&address, timeout)
            .map_err(|error| telnet_transport_error(&error.to_string()))?;
        stream
            .set_nonblocking(true)
            .map_err(|error| telnet_transport_error(&error.to_string()))?;
        Ok(Self {
            stream,
            negotiation_filter: TelnetNegotiationFilter::new(),
            eof: false,
        })
    }
}

impl ShellChannel for TelnetShellChannel {
    fn write_input(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.stream.write(bytes)
    }

    fn read_output(&mut self, max_bytes: usize) -> io::Result<Vec<u8>> {
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
                    match self.stream.write_all(&filtered.responses) {
                        Ok(()) => {}
                        Err(error) if error.kind() == io::ErrorKind::WouldBlock => {}
                        Err(error) => return Err(error),
                    }
                }
                Ok(filtered.output)
            }
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => Ok(Vec::new()),
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

    fn wait_interest(&self) -> Option<ShellWaitInterest> {
        #[cfg(unix)]
        {
            return Some(ShellWaitInterest::readable(self.stream.as_raw_fd()));
        }
        #[cfg(not(unix))]
        {
            None
        }
    }
}

fn telnet_transport_error(message: &str) -> SshRuntimeError {
    let redacted = redact_ssh_diagnostic(message);
    if redacted.contains("timed out") {
        SshRuntimeError::Timeout
    } else {
        SshRuntimeError::Transport { message: redacted }
    }
}

#[cfg(test)]
mod tests {
    use super::TelnetShellChannel;
    use crate::services::live_shell_service::ShellChannel;
    use std::{
        io::{Read, Write},
        net::TcpListener,
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
