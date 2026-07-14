use crate::{
    domain::{
        files::{parse_ftp_list_listing, RemoteFileEntry},
        ftp::{validate_ftp_config, FtpAuthSecret, FtpConnectionConfig},
        ssh::{redact_ssh_diagnostic, SshRuntimeError},
    },
    services::scp_service::is_live_scp_transfer_cancelled,
};
use std::{
    io::{BufRead, BufReader, Read, Write},
    net::{Shutdown, TcpStream, ToSocketAddrs},
    time::Duration,
};

pub struct FtpControlClient {
    reader: BufReader<TcpStream>,
}

impl FtpControlClient {
    pub fn connect(
        config: &FtpConnectionConfig,
        secret: &FtpAuthSecret,
    ) -> Result<Self, SshRuntimeError> {
        validate_ftp_config(config)?;
        let timeout = Duration::from_millis(config.connect_timeout_ms as u64);
        let endpoint = format!("{}:{}", config.host.trim(), config.port);
        let mut addresses = endpoint
            .to_socket_addrs()
            .map_err(|error| ftp_transport_error(&error.to_string()))?;
        let address = addresses.next().ok_or(SshRuntimeError::InvalidConfig)?;
        let stream = TcpStream::connect_timeout(&address, timeout)
            .map_err(|error| ftp_transport_error(&error.to_string()))?;
        stream
            .set_read_timeout(Some(timeout))
            .map_err(|error| ftp_transport_error(&error.to_string()))?;
        stream
            .set_write_timeout(Some(timeout))
            .map_err(|error| ftp_transport_error(&error.to_string()))?;
        let mut client = Self {
            reader: BufReader::new(stream),
        };
        client.expect_response(&[220])?;
        client.command_expect(&format!("USER {}", config.username.trim()), &[230, 331])?;
        if let FtpAuthSecret::Password { value } = secret {
            client.command_expect(&format!("PASS {value}"), &[230])?;
        }
        client.command_expect("TYPE I", &[200])?;
        Ok(client)
    }

    pub fn list_directory(
        &mut self,
        remote_path: &str,
    ) -> Result<Vec<RemoteFileEntry>, SshRuntimeError> {
        let path = normalized_path(remote_path)?;
        let (host, port) = self.enter_passive_mode()?;
        let mut data_stream = TcpStream::connect((host.as_str(), port))
            .map_err(|error| ftp_transport_error(&error.to_string()))?;
        self.write_command(&format!("LIST {path}"))?;
        let preliminary = self.read_response()?;
        if preliminary.code != 125 && preliminary.code != 150 {
            return Err(ftp_status_error(preliminary.code));
        }
        let mut listing = String::new();
        data_stream
            .read_to_string(&mut listing)
            .map_err(|error| ftp_transport_error(&error.to_string()))?;
        let _ = data_stream.shutdown(Shutdown::Both);
        self.expect_response(&[226, 250])?;
        parse_ftp_list_listing(&path, &listing).map_err(|_| SshRuntimeError::Transport {
            message: "FTP_LIST_PARSE_FAILED".to_string(),
        })
    }

    pub fn retrieve_file(&mut self, remote_path: &str) -> Result<Vec<u8>, SshRuntimeError> {
        self.retrieve_file_with_cancellation(remote_path, || false)
    }

    pub fn file_size(&mut self, remote_path: &str) -> Result<u64, SshRuntimeError> {
        let path = normalized_path(remote_path)?;
        let response = self.command_response(&format!("SIZE {path}"))?;
        if response.code != 213 {
            return Err(ftp_resume_status_error(response.code));
        }
        parse_size_response(&response.message)
    }

    pub fn retrieve_file_with_job(
        &mut self,
        remote_path: &str,
        job_id: &str,
    ) -> Result<Vec<u8>, SshRuntimeError> {
        self.retrieve_file_with_cancellation(remote_path, || is_live_scp_transfer_cancelled(job_id))
    }

    pub fn retrieve_file_from_offset_with_job(
        &mut self,
        remote_path: &str,
        offset: u64,
        job_id: &str,
    ) -> Result<Vec<u8>, SshRuntimeError> {
        let mut bytes = Vec::new();
        self.retrieve_file_to_writer_with_cancellation(remote_path, offset, &mut bytes, || {
            is_live_scp_transfer_cancelled(job_id)
        })?;
        Ok(bytes)
    }

    pub fn retrieve_file_to_writer_with_job<W: Write>(
        &mut self,
        remote_path: &str,
        offset: u64,
        writer: &mut W,
        job_id: &str,
    ) -> Result<u64, SshRuntimeError> {
        self.retrieve_file_to_writer_with_cancellation(remote_path, offset, writer, || {
            is_live_scp_transfer_cancelled(job_id)
        })
    }

    fn retrieve_file_with_cancellation<F>(
        &mut self,
        remote_path: &str,
        is_cancelled: F,
    ) -> Result<Vec<u8>, SshRuntimeError>
    where
        F: Fn() -> bool,
    {
        let mut bytes = Vec::new();
        self.retrieve_file_to_writer_with_cancellation(remote_path, 0, &mut bytes, is_cancelled)?;
        Ok(bytes)
    }

    fn retrieve_file_to_writer_with_cancellation<W, F>(
        &mut self,
        remote_path: &str,
        offset: u64,
        writer: &mut W,
        is_cancelled: F,
    ) -> Result<u64, SshRuntimeError>
    where
        W: Write,
        F: Fn() -> bool,
    {
        let path = normalized_path(remote_path)?;
        let (host, port) = self.enter_passive_mode()?;
        if offset > 0 {
            let response = self.command_response(&format!("REST {offset}"))?;
            if response.code != 350 {
                return Err(ftp_resume_status_error(response.code));
            }
        }
        let mut data_stream = TcpStream::connect((host.as_str(), port))
            .map_err(|error| ftp_transport_error(&error.to_string()))?;
        self.write_command(&format!("RETR {path}"))?;
        let preliminary = self.read_response()?;
        if preliminary.code != 125 && preliminary.code != 150 {
            let _ = data_stream.shutdown(Shutdown::Both);
            return Err(ftp_status_error(preliminary.code));
        }
        let mut bytes_written = 0_u64;
        let mut chunk = [0_u8; 64 * 1024];
        loop {
            if is_cancelled() {
                let _ = data_stream.shutdown(Shutdown::Both);
                return Err(SshRuntimeError::Transport {
                    message: "FTP_TRANSFER_CANCELLED".to_string(),
                });
            }
            let read = data_stream
                .read(&mut chunk)
                .map_err(|error| ftp_transport_error(&error.to_string()))?;
            if read == 0 {
                break;
            }
            writer
                .write_all(&chunk[..read])
                .map_err(|error| ftp_transport_error(&error.to_string()))?;
            bytes_written = bytes_written.saturating_add(read as u64);
        }
        let _ = data_stream.shutdown(Shutdown::Both);
        self.expect_response(&[226, 250])?;
        Ok(bytes_written)
    }

    pub fn store_file(&mut self, remote_path: &str, bytes: &[u8]) -> Result<(), SshRuntimeError> {
        self.store_file_with_cancellation(remote_path, bytes, || false)
    }

    pub fn store_file_with_job(
        &mut self,
        remote_path: &str,
        bytes: &[u8],
        job_id: &str,
    ) -> Result<(), SshRuntimeError> {
        self.store_file_with_cancellation(remote_path, bytes, || {
            is_live_scp_transfer_cancelled(job_id)
        })
    }

    pub fn append_file_with_job(
        &mut self,
        remote_path: &str,
        bytes: &[u8],
        job_id: &str,
    ) -> Result<(), SshRuntimeError> {
        self.store_file_using_command_with_cancellation(remote_path, bytes, "APPE", || {
            is_live_scp_transfer_cancelled(job_id)
        })
    }

    pub fn store_file_from_offset_with_job(
        &mut self,
        remote_path: &str,
        bytes: &[u8],
        offset: u64,
        job_id: &str,
    ) -> Result<(), SshRuntimeError> {
        if offset == 0 {
            return self.store_file_with_job(remote_path, bytes, job_id);
        }
        self.store_file_from_offset_with_cancellation(remote_path, bytes, offset, || {
            is_live_scp_transfer_cancelled(job_id)
        })
    }

    fn store_file_with_cancellation<F>(
        &mut self,
        remote_path: &str,
        bytes: &[u8],
        is_cancelled: F,
    ) -> Result<(), SshRuntimeError>
    where
        F: Fn() -> bool,
    {
        self.store_file_using_command_with_cancellation(remote_path, bytes, "STOR", is_cancelled)
    }

    fn store_file_from_offset_with_cancellation<F>(
        &mut self,
        remote_path: &str,
        bytes: &[u8],
        offset: u64,
        is_cancelled: F,
    ) -> Result<(), SshRuntimeError>
    where
        F: Fn() -> bool,
    {
        self.store_file_using_command_with_offset(
            remote_path,
            bytes,
            "STOR",
            Some(offset),
            is_cancelled,
        )
    }

    fn store_file_using_command_with_cancellation<F>(
        &mut self,
        remote_path: &str,
        bytes: &[u8],
        command: &str,
        is_cancelled: F,
    ) -> Result<(), SshRuntimeError>
    where
        F: Fn() -> bool,
    {
        self.store_file_using_command_with_offset(remote_path, bytes, command, None, is_cancelled)
    }

    fn store_file_using_command_with_offset<F>(
        &mut self,
        remote_path: &str,
        bytes: &[u8],
        command: &str,
        offset: Option<u64>,
        is_cancelled: F,
    ) -> Result<(), SshRuntimeError>
    where
        F: Fn() -> bool,
    {
        let path = normalized_path(remote_path)?;
        if command != "STOR" && command != "APPE" {
            return Err(SshRuntimeError::InvalidConfig);
        }
        let (host, port) = self.enter_passive_mode()?;
        if let Some(offset) = offset.filter(|value| *value > 0) {
            let response = self.command_response(&format!("REST {offset}"))?;
            if response.code != 350 {
                return Err(ftp_resume_status_error(response.code));
            }
        }
        let mut data_stream = TcpStream::connect((host.as_str(), port))
            .map_err(|error| ftp_transport_error(&error.to_string()))?;
        self.write_command(&format!("{command} {path}"))?;
        let preliminary = self.read_response()?;
        if preliminary.code != 125 && preliminary.code != 150 {
            let _ = data_stream.shutdown(Shutdown::Both);
            return Err(ftp_status_error(preliminary.code));
        }
        for chunk in bytes.chunks(64 * 1024) {
            if is_cancelled() {
                let _ = data_stream.shutdown(Shutdown::Both);
                return Err(SshRuntimeError::Transport {
                    message: "FTP_TRANSFER_CANCELLED".to_string(),
                });
            }
            data_stream
                .write_all(chunk)
                .map_err(|error| ftp_transport_error(&error.to_string()))?;
        }
        data_stream
            .flush()
            .map_err(|error| ftp_transport_error(&error.to_string()))?;
        let _ = data_stream.shutdown(Shutdown::Write);
        self.expect_response(&[226, 250])
    }

    pub fn make_directory(&mut self, remote_path: &str) -> Result<(), SshRuntimeError> {
        let path = normalized_path(remote_path)?;
        self.command_expect(&format!("MKD {path}"), &[257, 250])
    }

    pub fn rename(&mut self, from_path: &str, to_path: &str) -> Result<(), SshRuntimeError> {
        let from_path = normalized_path(from_path)?;
        let to_path = normalized_path(to_path)?;
        self.command_expect(&format!("RNFR {from_path}"), &[350])?;
        self.command_expect(&format!("RNTO {to_path}"), &[250])
    }

    pub fn delete(&mut self, remote_path: &str, recursive: bool) -> Result<(), SshRuntimeError> {
        let path = normalized_path(remote_path)?;
        let result = self.command_expect(&format!("DELE {path}"), &[250]);
        if result.is_ok() || !recursive {
            return result;
        }
        self.command_expect(&format!("RMD {path}"), &[250])
    }

    fn enter_passive_mode(&mut self) -> Result<(String, u16), SshRuntimeError> {
        let response = self.command_response("PASV")?;
        if response.code != 227 {
            return Err(ftp_status_error(response.code));
        }
        parse_pasv_endpoint(&response.message)
    }

    fn command_expect(&mut self, command: &str, expected: &[u16]) -> Result<(), SshRuntimeError> {
        self.write_command(command)?;
        self.expect_response(expected)
    }

    fn command_response(&mut self, command: &str) -> Result<FtpResponse, SshRuntimeError> {
        self.write_command(command)?;
        self.read_response()
    }

    fn write_command(&mut self, command: &str) -> Result<(), SshRuntimeError> {
        if command.contains('\n') || command.contains('\r') {
            return Err(SshRuntimeError::InvalidConfig);
        }
        let stream = self.reader.get_mut();
        stream
            .write_all(command.as_bytes())
            .and_then(|_| stream.write_all(b"\r\n"))
            .and_then(|_| stream.flush())
            .map_err(|error| ftp_transport_error(&error.to_string()))
    }

    fn expect_response(&mut self, expected: &[u16]) -> Result<(), SshRuntimeError> {
        let response = self.read_response()?;
        if expected.contains(&response.code) {
            Ok(())
        } else {
            Err(ftp_status_error(response.code))
        }
    }

    fn read_response(&mut self) -> Result<FtpResponse, SshRuntimeError> {
        let mut message = String::new();
        let mut code = None;
        loop {
            let mut line = String::new();
            let read = self
                .reader
                .read_line(&mut line)
                .map_err(|error| ftp_transport_error(&error.to_string()))?;
            if read == 0 {
                return Err(SshRuntimeError::Transport {
                    message: "FTP_CONNECTION_CLOSED".to_string(),
                });
            }
            message.push_str(&line);
            let bytes = line.as_bytes();
            if bytes.len() >= 3 && bytes[0..3].iter().all(u8::is_ascii_digit) {
                let parsed_code = line[0..3]
                    .parse::<u16>()
                    .map_err(|_| SshRuntimeError::InvalidConfig)?;
                code.get_or_insert(parsed_code);
                if bytes.get(3) == Some(&b' ') {
                    return Ok(FtpResponse {
                        code: parsed_code,
                        message,
                    });
                }
            }
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct FtpResponse {
    code: u16,
    message: String,
}

fn parse_pasv_endpoint(message: &str) -> Result<(String, u16), SshRuntimeError> {
    let start = message.find('(').ok_or(SshRuntimeError::InvalidConfig)? + 1;
    let end = message[start..]
        .find(')')
        .map(|offset| start + offset)
        .ok_or(SshRuntimeError::InvalidConfig)?;
    let parts = message[start..end]
        .split(',')
        .map(str::trim)
        .map(str::parse::<u16>)
        .collect::<Result<Vec<_>, _>>()
        .map_err(|_| SshRuntimeError::InvalidConfig)?;
    if parts.len() != 6 || parts.iter().any(|part| *part > 255) {
        return Err(SshRuntimeError::InvalidConfig);
    }
    let host = format!("{}.{}.{}.{}", parts[0], parts[1], parts[2], parts[3]);
    let port = parts[4] * 256 + parts[5];
    Ok((host, port))
}

fn normalized_path(path: &str) -> Result<String, SshRuntimeError> {
    let trimmed = path.trim();
    if trimmed.is_empty()
        || trimmed.contains('\r')
        || trimmed.contains('\n')
        || trimmed.contains("../")
        || trimmed.starts_with("../")
        || trimmed == ".."
        || trimmed.ends_with("/..")
    {
        return Err(SshRuntimeError::InvalidConfig);
    }
    Ok(trimmed.to_string())
}

fn parse_size_response(message: &str) -> Result<u64, SshRuntimeError> {
    let final_line = message
        .lines()
        .rev()
        .find(|line| line.starts_with("213 "))
        .ok_or(SshRuntimeError::InvalidConfig)?;
    final_line[4..]
        .trim()
        .parse::<u64>()
        .map_err(|_| SshRuntimeError::InvalidConfig)
}

fn ftp_resume_status_error(code: u16) -> SshRuntimeError {
    match code {
        500 | 501 | 502 | 504 => SshRuntimeError::Transport {
            message: "FTP_RESUME_UNSUPPORTED".to_string(),
        },
        _ => ftp_status_error(code),
    }
}

fn ftp_status_error(code: u16) -> SshRuntimeError {
    match code {
        530 => SshRuntimeError::AuthFailed,
        421 => SshRuntimeError::Timeout,
        _ => SshRuntimeError::Transport {
            message: format!("FTP_STATUS_{code}"),
        },
    }
}

fn ftp_transport_error(message: &str) -> SshRuntimeError {
    let redacted = redact_ssh_diagnostic(message);
    if redacted.contains("timed out") {
        SshRuntimeError::Timeout
    } else {
        SshRuntimeError::Transport { message: redacted }
    }
}

#[cfg(test)]
mod tests {
    use super::{normalized_path, parse_pasv_endpoint, FtpControlClient};
    use crate::domain::{
        ftp::{FtpAuthSecret, FtpConnectionConfig},
        ssh::SshRuntimeError,
    };
    use std::{
        io::{BufRead, BufReader, Read, Write},
        net::{TcpListener, TcpStream},
        sync::{Arc, Mutex},
        thread,
        time::Duration,
    };

    #[test]
    fn parses_pasv_endpoint() {
        let endpoint =
            parse_pasv_endpoint("227 Entering Passive Mode (127,0,0,1,195,80).").expect("pasv");

        assert_eq!(endpoint, ("127.0.0.1".to_string(), 50_000));
    }

    #[test]
    fn rejects_unsafe_paths_and_commands() {
        assert!(normalized_path("../etc").is_err());
        assert!(normalized_path("/pub/..").is_err());
        assert!(normalized_path("/tmp\r\nDELE /").is_err());
    }

    #[test]
    fn retrieves_file_bytes_over_pasv_data_connection() {
        let server = FakeFtpServer::retr(b"hello\x00ftp".to_vec());
        let mut client = FtpControlClient::connect(
            &server.config(),
            &FtpAuthSecret::Password {
                value: "top-secret".to_string(),
            },
        )
        .expect("connect ftp");

        let bytes = client.retrieve_file("/pub/app.bin").expect("retr file");

        assert_eq!(bytes, b"hello\x00ftp");
        assert_eq!(
            server.commands(),
            vec![
                "USER deploy",
                "PASS top-secret",
                "TYPE I",
                "PASV",
                "RETR /pub/app.bin"
            ]
        );
        server.join();
    }

    #[test]
    fn reads_file_size_with_size_command() {
        let server = FakeFtpServer::size(9);
        let mut client = FtpControlClient::connect(
            &server.config(),
            &FtpAuthSecret::Password {
                value: "top-secret".to_string(),
            },
        )
        .expect("connect ftp");

        let size = client.file_size("/pub/app.bin").expect("size");

        assert_eq!(size, 9);
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
    fn retrieves_file_bytes_from_resume_offset() {
        let server = FakeFtpServer::retr_from_offset(b"ftp".to_vec(), 6);
        let mut client = FtpControlClient::connect(
            &server.config(),
            &FtpAuthSecret::Password {
                value: "top-secret".to_string(),
            },
        )
        .expect("connect ftp");

        let bytes = client
            .retrieve_file_from_offset_with_job("/pub/app.bin", 6, "job_resume")
            .expect("retr resume");

        assert_eq!(bytes, b"ftp");
        assert_eq!(
            server.commands(),
            vec![
                "USER deploy",
                "PASS top-secret",
                "TYPE I",
                "PASV",
                "REST 6",
                "RETR /pub/app.bin"
            ]
        );
        server.join();
    }

    #[test]
    fn resume_offset_reports_unsupported_without_opening_data_connection() {
        let server = FakeFtpServer::retr_resume_unsupported(502);
        let mut client = FtpControlClient::connect(
            &server.config(),
            &FtpAuthSecret::Password {
                value: "top-secret".to_string(),
            },
        )
        .expect("connect ftp");

        let error = client
            .retrieve_file_from_offset_with_job("/pub/app.bin", 6, "job_resume")
            .expect_err("resume unsupported");

        assert_eq!(
            error,
            SshRuntimeError::Transport {
                message: "FTP_RESUME_UNSUPPORTED".to_string()
            }
        );
        assert_eq!(
            server.commands(),
            vec!["USER deploy", "PASS top-secret", "TYPE I", "PASV", "REST 6"]
        );
        server.join();
    }

    #[test]
    fn stores_file_bytes_over_pasv_data_connection() {
        let server = FakeFtpServer::stor();
        let mut client = FtpControlClient::connect(
            &server.config(),
            &FtpAuthSecret::Password {
                value: "top-secret".to_string(),
            },
        )
        .expect("connect ftp");

        client
            .store_file("/pub/upload.bin", b"upload\x00payload")
            .expect("stor file");

        assert_eq!(server.uploaded_bytes(), b"upload\x00payload");
        assert_eq!(
            server.commands(),
            vec![
                "USER deploy",
                "PASS top-secret",
                "TYPE I",
                "PASV",
                "STOR /pub/upload.bin"
            ]
        );
        server.join();
    }

    #[test]
    fn appends_file_bytes_over_pasv_data_connection() {
        let server = FakeFtpServer::append();
        let mut client = FtpControlClient::connect(
            &server.config(),
            &FtpAuthSecret::Password {
                value: "top-secret".to_string(),
            },
        )
        .expect("connect ftp");

        client
            .append_file_with_job("/pub/upload.bin", b"tail", "job_append")
            .expect("appe file");

        assert_eq!(server.uploaded_bytes(), b"tail");
        assert_eq!(
            server.commands(),
            vec![
                "USER deploy",
                "PASS top-secret",
                "TYPE I",
                "PASV",
                "APPE /pub/upload.bin"
            ]
        );
        server.join();
    }

    #[test]
    fn retrieve_error_does_not_leak_password() {
        let server = FakeFtpServer::retr_status_error(550);
        let mut client = FtpControlClient::connect(
            &server.config(),
            &FtpAuthSecret::Password {
                value: "top-secret".to_string(),
            },
        )
        .expect("connect ftp");

        let error = client
            .retrieve_file("/pub/top-secret.txt")
            .expect_err("retr should fail");

        assert_eq!(
            error,
            SshRuntimeError::Transport {
                message: "FTP_STATUS_550".to_string()
            }
        );
        assert!(!format!("{error:?}").contains("top-secret"));
        server.join();
    }

    struct FakeFtpServer {
        port: u16,
        commands: Arc<Mutex<Vec<String>>>,
        uploaded: Arc<Mutex<Vec<u8>>>,
        handle: thread::JoinHandle<()>,
    }

    enum FakeFtpScenario {
        Size(u64),
        Retr(Vec<u8>),
        RetrFromOffset { bytes: Vec<u8>, offset: u64 },
        RetrResumeUnsupported(u16),
        RetrStatusError(u16),
        Stor,
        Append,
    }

    impl FakeFtpServer {
        fn size(bytes: u64) -> Self {
            Self::spawn(FakeFtpScenario::Size(bytes))
        }

        fn retr(bytes: Vec<u8>) -> Self {
            Self::spawn(FakeFtpScenario::Retr(bytes))
        }

        fn retr_from_offset(bytes: Vec<u8>, offset: u64) -> Self {
            Self::spawn(FakeFtpScenario::RetrFromOffset { bytes, offset })
        }

        fn retr_resume_unsupported(code: u16) -> Self {
            Self::spawn(FakeFtpScenario::RetrResumeUnsupported(code))
        }

        fn retr_status_error(code: u16) -> Self {
            Self::spawn(FakeFtpScenario::RetrStatusError(code))
        }

        fn stor() -> Self {
            Self::spawn(FakeFtpScenario::Stor)
        }

        fn append() -> Self {
            Self::spawn(FakeFtpScenario::Append)
        }

        fn spawn(scenario: FakeFtpScenario) -> Self {
            let listener = TcpListener::bind(("127.0.0.1", 0)).expect("bind ftp control");
            let port = listener.local_addr().expect("control addr").port();
            let commands = Arc::new(Mutex::new(Vec::new()));
            let uploaded = Arc::new(Mutex::new(Vec::new()));
            let server_commands = Arc::clone(&commands);
            let server_uploaded = Arc::clone(&uploaded);
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
                expect_command(&mut reader, &server_commands, "USER deploy");
                control
                    .write_all(b"331 password required\r\n")
                    .expect("user");
                expect_command(&mut reader, &server_commands, "PASS top-secret");
                control.write_all(b"230 logged in\r\n").expect("pass");
                expect_command(&mut reader, &server_commands, "TYPE I");
                control.write_all(b"200 binary type\r\n").expect("type");

                match scenario {
                    FakeFtpScenario::Size(bytes) => {
                        expect_command(&mut reader, &server_commands, "SIZE /pub/app.bin");
                        write!(control, "213 {bytes}\r\n").expect("size response");
                    }
                    FakeFtpScenario::Retr(bytes) => {
                        let data_listener =
                            enter_fake_passive_mode(&mut reader, &server_commands, &mut control);
                        expect_command(&mut reader, &server_commands, "RETR /pub/app.bin");
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
                    FakeFtpScenario::RetrFromOffset { bytes, offset } => {
                        let data_listener =
                            enter_fake_passive_mode(&mut reader, &server_commands, &mut control);
                        expect_command(&mut reader, &server_commands, &format!("REST {offset}"));
                        control
                            .write_all(b"350 restart position accepted\r\n")
                            .expect("rest 350");
                        expect_command(&mut reader, &server_commands, "RETR /pub/app.bin");
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
                    FakeFtpScenario::RetrResumeUnsupported(code) => {
                        let _data_listener =
                            enter_fake_passive_mode(&mut reader, &server_commands, &mut control);
                        expect_command(&mut reader, &server_commands, "REST 6");
                        write!(control, "{code} restart unsupported\r\n")
                            .expect("rest unsupported");
                    }
                    FakeFtpScenario::RetrStatusError(code) => {
                        let _data_listener =
                            enter_fake_passive_mode(&mut reader, &server_commands, &mut control);
                        expect_command(&mut reader, &server_commands, "RETR /pub/top-secret.txt");
                        write!(control, "{code} no such file top-secret\r\n").expect("retr error");
                    }
                    FakeFtpScenario::Stor => {
                        let data_listener =
                            enter_fake_passive_mode(&mut reader, &server_commands, &mut control);
                        expect_command(&mut reader, &server_commands, "STOR /pub/upload.bin");
                        control
                            .write_all(b"150 opening data\r\n")
                            .expect("stor 150");
                        let (mut data, _) = data_listener.accept().expect("accept stor data");
                        let mut bytes = Vec::new();
                        data.read_to_end(&mut bytes).expect("read upload");
                        *server_uploaded.lock().expect("uploaded lock") = bytes;
                        control
                            .write_all(b"226 transfer complete\r\n")
                            .expect("stor 226");
                    }
                    FakeFtpScenario::Append => {
                        let data_listener =
                            enter_fake_passive_mode(&mut reader, &server_commands, &mut control);
                        expect_command(&mut reader, &server_commands, "APPE /pub/upload.bin");
                        control
                            .write_all(b"150 opening data\r\n")
                            .expect("appe 150");
                        let (mut data, _) = data_listener.accept().expect("accept appe data");
                        let mut bytes = Vec::new();
                        data.read_to_end(&mut bytes).expect("read append");
                        *server_uploaded.lock().expect("uploaded lock") = bytes;
                        control
                            .write_all(b"226 transfer complete\r\n")
                            .expect("appe 226");
                    }
                }
            });

            Self {
                port,
                commands,
                uploaded,
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

        fn uploaded_bytes(&self) -> Vec<u8> {
            self.uploaded.lock().expect("uploaded lock").clone()
        }

        fn join(self) {
            self.handle.join().expect("ftp server thread");
        }
    }

    fn expect_command(
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

    fn enter_fake_passive_mode(
        reader: &mut BufReader<TcpStream>,
        commands: &Arc<Mutex<Vec<String>>>,
        control: &mut TcpStream,
    ) -> TcpListener {
        expect_command(reader, commands, "PASV");
        let data_listener = TcpListener::bind(("127.0.0.1", 0)).expect("bind data");
        let data_port = data_listener.local_addr().expect("data addr").port();
        write_pasv_response(control, data_port);
        data_listener
    }

    fn write_pasv_response(control: &mut TcpStream, port: u16) {
        let high = port / 256;
        let low = port % 256;
        write!(
            control,
            "227 Entering Passive Mode (127,0,0,1,{high},{low}).\r\n"
        )
        .expect("pasv response");
    }
}
