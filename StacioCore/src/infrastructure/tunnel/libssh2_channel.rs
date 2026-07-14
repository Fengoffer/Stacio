use crate::domain::tunnel::{TunnelError, TunnelKind, TunnelProfile};
use crate::infrastructure::ssh::libssh2_transport::Libssh2ConnectedSession;
use crate::infrastructure::tunnel::socks5::{
    parse_socks5_client_hello, parse_socks5_connect_request, socks5_failure_response,
    SOCKS5_CONNECT_SUCCESS_RESPONSE, SOCKS5_GENERAL_FAILURE_RESPONSE,
    SOCKS5_NO_ACCEPTABLE_METHODS_RESPONSE, SOCKS5_NO_AUTH_RESPONSE,
};
use crate::services::tunnel_service::{
    check_tunnel_local_port_available, ManagedTunnelWorker, TunnelChannel, TunnelRuntimeTick,
};
#[cfg(test)]
use std::collections::VecDeque;
use std::io::{self, Read, Write};
use std::net::{TcpListener, TcpStream, ToSocketAddrs};
use std::time::Duration;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Libssh2TunnelOpenRequest {
    pub remote_host: String,
    pub remote_port: u16,
    pub origin_host: String,
    pub origin_port: u16,
}

impl Libssh2TunnelOpenRequest {
    pub fn from_profile(profile: &TunnelProfile) -> Result<Self, TunnelError> {
        match profile.kind {
            TunnelKind::Local => Ok(Self {
                remote_host: profile.remote_host.clone(),
                remote_port: profile.remote_port,
                origin_host: profile.local_host.clone(),
                origin_port: profile.local_port,
            }),
            TunnelKind::Remote | TunnelKind::Dynamic => Err(TunnelError::SshFailed),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Libssh2RemoteForwardListenRequest {
    pub bind_host: String,
    pub bind_port: u16,
    pub target_host: String,
    pub target_port: u16,
}

impl Libssh2RemoteForwardListenRequest {
    pub fn from_profile(profile: &TunnelProfile) -> Result<Self, TunnelError> {
        match profile.kind {
            TunnelKind::Remote => Ok(Self {
                bind_host: profile.remote_host.clone(),
                bind_port: profile.remote_port,
                target_host: profile.local_host.clone(),
                target_port: profile.local_port,
            }),
            TunnelKind::Local | TunnelKind::Dynamic => Err(TunnelError::SshFailed),
        }
    }
}

pub struct Libssh2TunnelAdapter;

impl Libssh2TunnelAdapter {
    pub fn new() -> Self {
        Self
    }
}

impl TunnelChannel for Libssh2TunnelAdapter {
    fn start(&self, profile: &TunnelProfile) -> Result<(), TunnelError> {
        check_tunnel_local_port_available(profile.clone())?;
        match profile.kind {
            TunnelKind::Local => {
                Libssh2TunnelOpenRequest::from_profile(profile)?;
            }
            TunnelKind::Remote => {
                Libssh2RemoteForwardListenRequest::from_profile(profile)?;
            }
            TunnelKind::Dynamic => return Err(TunnelError::SshFailed),
        }
        Err(TunnelError::SshFailed)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TunnelCopyStats {
    pub client_to_remote_bytes: u64,
    pub remote_to_client_bytes: u64,
    pub client_closed: bool,
    pub remote_closed: bool,
}

pub struct TunnelCopyPump<C, R> {
    client: C,
    remote: R,
    client_closed: bool,
    remote_closed: bool,
}

impl<C, R> TunnelCopyPump<C, R>
where
    C: Read + Write,
    R: Read + Write,
{
    pub fn new(client: C, remote: R) -> Self {
        Self {
            client,
            remote,
            client_closed: false,
            remote_closed: false,
        }
    }

    pub fn poll_once(&mut self) -> io::Result<TunnelCopyStats> {
        let (client_to_remote_bytes, client_closed) = if self.client_closed {
            (0, true)
        } else {
            pump_direction(&mut self.client, &mut self.remote)?
        };
        let (remote_to_client_bytes, remote_closed) = if self.remote_closed {
            (0, true)
        } else {
            pump_direction(&mut self.remote, &mut self.client)?
        };
        self.client_closed = client_closed;
        self.remote_closed = remote_closed;

        Ok(TunnelCopyStats {
            client_to_remote_bytes,
            remote_to_client_bytes,
            client_closed: self.client_closed,
            remote_closed: self.remote_closed,
        })
    }

    pub fn client(&self) -> &C {
        &self.client
    }

    pub fn remote(&self) -> &R {
        &self.remote
    }

    pub fn is_closed(&self) -> bool {
        self.client_closed && self.remote_closed
    }

    #[cfg(test)]
    pub fn into_parts(self) -> (C, R) {
        (self.client, self.remote)
    }
}

fn pump_direction<R, W>(reader: &mut R, writer: &mut W) -> io::Result<(u64, bool)>
where
    R: Read,
    W: Write,
{
    let mut buffer = [0_u8; 16 * 1024];
    match reader.read(&mut buffer) {
        Ok(0) => Ok((0, true)),
        Ok(bytes_read) => {
            writer.write_all(&buffer[..bytes_read])?;
            Ok((bytes_read as u64, false))
        }
        Err(error) if error.kind() == io::ErrorKind::WouldBlock => Ok((0, false)),
        Err(error) => Err(error),
    }
}

pub struct AcceptedTunnelClient<C> {
    pub stream: C,
    pub origin_host: String,
    pub origin_port: u16,
}

impl<C> AcceptedTunnelClient<C> {
    pub fn new(stream: C, origin_host: String, origin_port: u16) -> Self {
        Self {
            stream,
            origin_host,
            origin_port,
        }
    }
}

pub trait TunnelClientAcceptor {
    type Client: Read + Write;

    fn accept(&mut self) -> io::Result<Option<AcceptedTunnelClient<Self::Client>>>;
}

pub trait TunnelRemoteChannelOpener {
    type Remote: Read + Write;

    fn open_channel(&mut self, request: Libssh2TunnelOpenRequest) -> io::Result<Self::Remote>;
}

pub trait RemoteForwardChannelAcceptor {
    type Remote: Read + Write;

    fn accept(&mut self) -> io::Result<Option<Self::Remote>>;
}

pub trait TunnelTargetConnector {
    type Target: Read + Write;

    fn connect(&mut self, host: &str, port: u16) -> io::Result<Self::Target>;
}

pub struct TcpTunnelClientAcceptor {
    listener: TcpListener,
}

impl TcpTunnelClientAcceptor {
    pub fn bind(host: &str, port: u16) -> io::Result<Self> {
        Self::from_listener(TcpListener::bind((host, port))?)
    }

    pub fn from_listener(listener: TcpListener) -> io::Result<Self> {
        listener.set_nonblocking(true)?;
        Ok(Self { listener })
    }
}

impl TunnelClientAcceptor for TcpTunnelClientAcceptor {
    type Client = TcpStream;

    fn accept(&mut self) -> io::Result<Option<AcceptedTunnelClient<Self::Client>>> {
        match self.listener.accept() {
            Ok((stream, address)) => {
                stream.set_nonblocking(true)?;
                Ok(Some(AcceptedTunnelClient::new(
                    stream,
                    address.ip().to_string(),
                    address.port(),
                )))
            }
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => Ok(None),
            Err(error) => Err(error),
        }
    }
}

pub struct Libssh2DirectTcpIpOpener {
    session: Option<Libssh2ConnectedSession>,
    opened_count: usize,
}

impl Libssh2DirectTcpIpOpener {
    pub fn new(session: Libssh2ConnectedSession) -> Self {
        Self {
            session: Some(session),
            opened_count: 0,
        }
    }

    #[cfg(test)]
    pub fn new_for_testing() -> Self {
        Self {
            session: None,
            opened_count: 0,
        }
    }

    pub fn opened_count(&self) -> usize {
        self.opened_count
    }
}

impl TunnelRemoteChannelOpener for Libssh2DirectTcpIpOpener {
    type Remote = ssh2::Channel;

    fn open_channel(&mut self, request: Libssh2TunnelOpenRequest) -> io::Result<Self::Remote> {
        let Some(session) = self.session.as_ref() else {
            return Err(io::Error::from(io::ErrorKind::NotConnected));
        };
        let channel = session
            .session()
            .channel_direct_tcpip(
                &request.remote_host,
                request.remote_port,
                Some((&request.origin_host, request.origin_port)),
            )
            .map_err(|error| io::Error::new(io::ErrorKind::Other, error.to_string()))?;
        self.opened_count += 1;
        Ok(channel)
    }
}

pub struct Libssh2RemoteForwardListener {
    _session: Libssh2ConnectedSession,
    listener: ssh2::Listener,
    bound_port: u16,
}

impl Libssh2RemoteForwardListener {
    pub fn listen(session: Libssh2ConnectedSession, profile: &TunnelProfile) -> io::Result<Self> {
        let request = Libssh2RemoteForwardListenRequest::from_profile(profile)
            .map_err(|error| io::Error::new(io::ErrorKind::Other, error.to_string()))?;
        let bind_host = request.bind_host.trim();
        let host = if bind_host.is_empty() {
            None
        } else {
            Some(bind_host)
        };
        let (listener, bound_port) = session
            .session()
            .channel_forward_listen(request.bind_port, host, Some(128))
            .map_err(|error| io::Error::new(io::ErrorKind::Other, error.to_string()))?;
        session.session().set_blocking(false);
        Ok(Self {
            _session: session,
            listener,
            bound_port,
        })
    }

    pub fn bound_port(&self) -> u16 {
        self.bound_port
    }
}

impl RemoteForwardChannelAcceptor for Libssh2RemoteForwardListener {
    type Remote = ssh2::Channel;

    fn accept(&mut self) -> io::Result<Option<Self::Remote>> {
        match self.listener.accept() {
            Ok(channel) => Ok(Some(channel)),
            Err(error) => {
                let io_error: io::Error = error.into();
                if io_error.kind() == io::ErrorKind::WouldBlock {
                    Ok(None)
                } else {
                    Err(io_error)
                }
            }
        }
    }
}

pub struct TcpTunnelTargetConnector {
    connect_timeout: Duration,
}

impl TcpTunnelTargetConnector {
    pub fn new() -> Self {
        Self {
            connect_timeout: Duration::from_secs(1),
        }
    }
}

impl TunnelTargetConnector for TcpTunnelTargetConnector {
    type Target = TcpStream;

    fn connect(&mut self, host: &str, port: u16) -> io::Result<Self::Target> {
        let mut addresses = (host, port).to_socket_addrs()?;
        let address = addresses
            .next()
            .ok_or_else(|| io::Error::from(io::ErrorKind::InvalidInput))?;
        let stream = TcpStream::connect_timeout(&address, self.connect_timeout)?;
        stream.set_nonblocking(true)?;
        Ok(stream)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LocalTunnelWorkerStats {
    pub accepted_connections: usize,
    pub active_connections: usize,
    pub client_to_remote_bytes: u64,
    pub remote_to_client_bytes: u64,
}

pub struct LocalTunnelWorker<A, O>
where
    A: TunnelClientAcceptor,
    O: TunnelRemoteChannelOpener,
{
    profile: TunnelProfile,
    acceptor: A,
    opener: O,
    connections: Vec<TunnelCopyPump<A::Client, O::Remote>>,
}

impl<A, O> LocalTunnelWorker<A, O>
where
    A: TunnelClientAcceptor,
    O: TunnelRemoteChannelOpener,
{
    pub fn new(profile: TunnelProfile, acceptor: A, opener: O) -> Self {
        Self {
            profile,
            acceptor,
            opener,
            connections: Vec::new(),
        }
    }

    pub fn poll_once(&mut self) -> io::Result<LocalTunnelWorkerStats> {
        let mut accepted_connections = 0;
        if let Some(accepted) = self.acceptor.accept()? {
            let mut request = Libssh2TunnelOpenRequest::from_profile(&self.profile)
                .map_err(|error| io::Error::new(io::ErrorKind::Other, error.to_string()))?;
            request.origin_host = accepted.origin_host;
            request.origin_port = accepted.origin_port;
            let remote = self.opener.open_channel(request)?;
            self.connections
                .push(TunnelCopyPump::new(accepted.stream, remote));
            accepted_connections += 1;
        }

        let mut client_to_remote_bytes = 0;
        let mut remote_to_client_bytes = 0;
        for connection in &mut self.connections {
            let stats = connection.poll_once()?;
            client_to_remote_bytes += stats.client_to_remote_bytes;
            remote_to_client_bytes += stats.remote_to_client_bytes;
        }
        self.connections
            .retain(|connection| !connection.is_closed());

        Ok(LocalTunnelWorkerStats {
            accepted_connections,
            active_connections: self.connections.len(),
            client_to_remote_bytes,
            remote_to_client_bytes,
        })
    }

    pub fn opener(&self) -> &O {
        &self.opener
    }
}

pub struct RemoteTunnelWorker<A, C>
where
    A: RemoteForwardChannelAcceptor,
    C: TunnelTargetConnector,
{
    profile: TunnelProfile,
    acceptor: A,
    connector: C,
    connections: Vec<TunnelCopyPump<A::Remote, C::Target>>,
}

impl<A, C> RemoteTunnelWorker<A, C>
where
    A: RemoteForwardChannelAcceptor,
    C: TunnelTargetConnector,
{
    pub fn new(profile: TunnelProfile, acceptor: A, connector: C) -> Self {
        Self {
            profile,
            acceptor,
            connector,
            connections: Vec::new(),
        }
    }

    pub fn poll_once(&mut self) -> io::Result<LocalTunnelWorkerStats> {
        debug_assert!(matches!(self.profile.kind, TunnelKind::Remote));
        let mut accepted_connections = 0;
        if let Some(remote) = self.acceptor.accept()? {
            accepted_connections += 1;
            if let Ok(target) = self
                .connector
                .connect(&self.profile.local_host, self.profile.local_port)
            {
                self.connections.push(TunnelCopyPump::new(remote, target));
            }
        }

        let mut client_to_remote_bytes = 0;
        let mut remote_to_client_bytes = 0;
        for connection in &mut self.connections {
            let stats = connection.poll_once()?;
            client_to_remote_bytes += stats.client_to_remote_bytes;
            remote_to_client_bytes += stats.remote_to_client_bytes;
        }
        self.connections
            .retain(|connection| !connection.is_closed());

        Ok(LocalTunnelWorkerStats {
            accepted_connections,
            active_connections: self.connections.len(),
            client_to_remote_bytes,
            remote_to_client_bytes,
        })
    }

    pub fn connector(&self) -> &C {
        &self.connector
    }
}

pub struct DynamicSocksTunnelWorker<A, O>
where
    A: TunnelClientAcceptor,
    O: TunnelRemoteChannelOpener,
{
    profile: TunnelProfile,
    acceptor: A,
    opener: O,
    pending_clients: Vec<DynamicSocksPendingClient<A::Client>>,
    connections: Vec<TunnelCopyPump<A::Client, O::Remote>>,
    #[cfg(test)]
    completed_clients: Vec<A::Client>,
    #[cfg(test)]
    completed_remotes: Vec<O::Remote>,
}

impl<A, O> DynamicSocksTunnelWorker<A, O>
where
    A: TunnelClientAcceptor,
    O: TunnelRemoteChannelOpener,
{
    pub fn new(profile: TunnelProfile, acceptor: A, opener: O) -> Self {
        Self {
            profile,
            acceptor,
            opener,
            pending_clients: Vec::new(),
            connections: Vec::new(),
            #[cfg(test)]
            completed_clients: Vec::new(),
            #[cfg(test)]
            completed_remotes: Vec::new(),
        }
    }

    pub fn poll_once(&mut self) -> io::Result<LocalTunnelWorkerStats> {
        debug_assert!(matches!(self.profile.kind, TunnelKind::Dynamic));
        let mut accepted_connections = 0;
        if let Some(accepted) = self.acceptor.accept()? {
            accepted_connections += 1;
            self.pending_clients
                .push(DynamicSocksPendingClient::new(accepted));
        }

        let mut client_to_remote_bytes = self.poll_pending_clients()?;
        let mut remote_to_client_bytes = 0;
        for connection in &mut self.connections {
            let stats = connection.poll_once()?;
            client_to_remote_bytes += stats.client_to_remote_bytes;
            remote_to_client_bytes += stats.remote_to_client_bytes;
        }

        #[cfg(test)]
        {
            let mut index = 0;
            while index < self.connections.len() {
                if self.connections[index].is_closed() {
                    let connection = self.connections.remove(index);
                    let (client, remote) = connection.into_parts();
                    self.completed_clients.push(client);
                    self.completed_remotes.push(remote);
                } else {
                    index += 1;
                }
            }
        }

        #[cfg(not(test))]
        {
            self.connections
                .retain(|connection| !connection.is_closed());
        }

        Ok(LocalTunnelWorkerStats {
            accepted_connections,
            active_connections: self.pending_clients.len() + self.connections.len(),
            client_to_remote_bytes,
            remote_to_client_bytes,
        })
    }

    pub fn opener(&self) -> &O {
        &self.opener
    }

    #[cfg(test)]
    pub fn completed_client(&self, index: usize) -> &A::Client {
        if index < self.completed_clients.len() {
            &self.completed_clients[index]
        } else {
            self.connections[index - self.completed_clients.len()].client()
        }
    }

    #[cfg(test)]
    pub fn completed_remote(&self, index: usize) -> &O::Remote {
        if index < self.completed_remotes.len() {
            &self.completed_remotes[index]
        } else {
            self.connections[index - self.completed_remotes.len()].remote()
        }
    }

    fn poll_pending_clients(&mut self) -> io::Result<u64> {
        let mut index = 0;
        let mut buffered_client_to_remote_bytes = 0;
        while index < self.pending_clients.len() {
            let pending = self.pending_clients.remove(index);
            match pending.poll(&mut self.opener)? {
                DynamicSocksPendingResult::Pending(pending) => {
                    self.pending_clients.insert(index, pending);
                    index += 1;
                }
                DynamicSocksPendingResult::Connected {
                    pump,
                    client_to_remote_bytes,
                } => {
                    buffered_client_to_remote_bytes += client_to_remote_bytes;
                    self.connections.push(pump);
                }
                DynamicSocksPendingResult::Completed(_client) => {
                    #[cfg(test)]
                    {
                        self.completed_clients.push(_client);
                    }
                }
            }
        }
        Ok(buffered_client_to_remote_bytes)
    }
}

struct DynamicSocksPendingClient<C> {
    stream: C,
    origin_host: String,
    origin_port: u16,
    buffer: Vec<u8>,
    auth_response_sent: bool,
}

impl<C> DynamicSocksPendingClient<C>
where
    C: Read + Write,
{
    fn new(accepted: AcceptedTunnelClient<C>) -> Self {
        Self {
            stream: accepted.stream,
            origin_host: accepted.origin_host,
            origin_port: accepted.origin_port,
            buffer: Vec::new(),
            auth_response_sent: false,
        }
    }

    fn poll<O>(mut self, opener: &mut O) -> io::Result<DynamicSocksPendingResult<C, O::Remote>>
    where
        O: TunnelRemoteChannelOpener,
    {
        let observed_eof = read_available_socks5_bytes(&mut self.stream, &mut self.buffer)?;
        let hello = match parse_socks5_client_hello(&self.buffer) {
            Ok(hello) => hello,
            Err(error) if error == "incomplete_frame" => {
                if observed_eof {
                    return Ok(DynamicSocksPendingResult::Completed(self.stream));
                }
                return Ok(DynamicSocksPendingResult::Pending(self));
            }
            Err(error) if error == "unsupported_auth_method" => {
                self.stream
                    .write_all(&SOCKS5_NO_ACCEPTABLE_METHODS_RESPONSE)?;
                return Ok(DynamicSocksPendingResult::Completed(self.stream));
            }
            Err(_) => {
                self.stream.write_all(socks5_failure_response("invalid"))?;
                return Ok(DynamicSocksPendingResult::Completed(self.stream));
            }
        };

        if !self.auth_response_sent {
            self.stream.write_all(&SOCKS5_NO_AUTH_RESPONSE)?;
            self.auth_response_sent = true;
        }

        let connect = match parse_socks5_connect_request(&self.buffer[hello.consumed..]) {
            Ok(connect) => connect,
            Err(error) if error == "incomplete_frame" => {
                if observed_eof {
                    return Ok(DynamicSocksPendingResult::Completed(self.stream));
                }
                return Ok(DynamicSocksPendingResult::Pending(self));
            }
            Err(error) => {
                self.stream.write_all(socks5_failure_response(&error))?;
                return Ok(DynamicSocksPendingResult::Completed(self.stream));
            }
        };

        let payload_start = hello.consumed + connect.consumed;
        let buffered_payload = self.buffer[payload_start..].to_vec();
        self.buffer.clear();

        let mut remote = match opener.open_channel(Libssh2TunnelOpenRequest {
            remote_host: connect.target_host(),
            remote_port: connect.target_port,
            origin_host: self.origin_host,
            origin_port: self.origin_port,
        }) {
            Ok(remote) => remote,
            Err(_) => {
                self.stream.write_all(&SOCKS5_GENERAL_FAILURE_RESPONSE)?;
                return Ok(DynamicSocksPendingResult::Completed(self.stream));
            }
        };
        if !buffered_payload.is_empty() {
            remote.write_all(&buffered_payload)?;
        }
        self.stream.write_all(&SOCKS5_CONNECT_SUCCESS_RESPONSE)?;
        Ok(DynamicSocksPendingResult::Connected {
            pump: TunnelCopyPump::new(self.stream, remote),
            client_to_remote_bytes: buffered_payload.len() as u64,
        })
    }
}

enum DynamicSocksPendingResult<C, R> {
    Pending(DynamicSocksPendingClient<C>),
    Connected {
        pump: TunnelCopyPump<C, R>,
        client_to_remote_bytes: u64,
    },
    Completed(C),
}

fn read_available_socks5_bytes<R>(reader: &mut R, buffer: &mut Vec<u8>) -> io::Result<bool>
where
    R: Read,
{
    let mut chunk = [0_u8; 512];
    loop {
        if socks5_buffer_has_decision(buffer) {
            return Ok(false);
        }

        match reader.read(&mut chunk) {
            Ok(0) => return Ok(true),
            Ok(bytes_read) => {
                buffer.extend_from_slice(&chunk[..bytes_read]);
                if !socks5_buffer_has_decision(buffer) && buffer.len() > 1024 {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        "socks5_handshake_too_large",
                    ));
                }
            }
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => return Ok(false),
            Err(error) => return Err(error),
        }
    }
}

fn socks5_buffer_has_decision(buffer: &[u8]) -> bool {
    match parse_socks5_client_hello(buffer) {
        Ok(hello) => match parse_socks5_connect_request(&buffer[hello.consumed..]) {
            Ok(_) => true,
            Err(error) => error != "incomplete_frame",
        },
        Err(error) => error != "incomplete_frame",
    }
}

impl<A, O> ManagedTunnelWorker for DynamicSocksTunnelWorker<A, O>
where
    A: TunnelClientAcceptor,
    O: TunnelRemoteChannelOpener,
{
    fn poll_once(&mut self) -> Result<TunnelRuntimeTick, TunnelError> {
        DynamicSocksTunnelWorker::poll_once(self)
            .map(|stats| TunnelRuntimeTick {
                accepted_connections: stats.accepted_connections,
                active_connections: stats.active_connections,
                client_to_remote_bytes: stats.client_to_remote_bytes,
                remote_to_client_bytes: stats.remote_to_client_bytes,
            })
            .map_err(|_| TunnelError::SshFailed)
    }
}

impl<A, O> ManagedTunnelWorker for LocalTunnelWorker<A, O>
where
    A: TunnelClientAcceptor,
    O: TunnelRemoteChannelOpener,
{
    fn poll_once(&mut self) -> Result<TunnelRuntimeTick, TunnelError> {
        LocalTunnelWorker::poll_once(self)
            .map(|stats| TunnelRuntimeTick {
                accepted_connections: stats.accepted_connections,
                active_connections: stats.active_connections,
                client_to_remote_bytes: stats.client_to_remote_bytes,
                remote_to_client_bytes: stats.remote_to_client_bytes,
            })
            .map_err(|_| TunnelError::SshFailed)
    }
}

impl<A, C> ManagedTunnelWorker for RemoteTunnelWorker<A, C>
where
    A: RemoteForwardChannelAcceptor,
    C: TunnelTargetConnector,
{
    fn poll_once(&mut self) -> Result<TunnelRuntimeTick, TunnelError> {
        RemoteTunnelWorker::poll_once(self)
            .map(|stats| TunnelRuntimeTick {
                accepted_connections: stats.accepted_connections,
                active_connections: stats.active_connections,
                client_to_remote_bytes: stats.client_to_remote_bytes,
                remote_to_client_bytes: stats.remote_to_client_bytes,
            })
            .map_err(|_| TunnelError::SshFailed)
    }
}

#[cfg(test)]
#[derive(Debug, Clone)]
pub struct MemoryTunnelStream {
    read_chunks: VecDeque<Vec<u8>>,
    written: Vec<u8>,
    would_block: bool,
    fail_writes: bool,
}

#[cfg(test)]
impl MemoryTunnelStream {
    pub fn new() -> Self {
        Self {
            read_chunks: VecDeque::new(),
            written: Vec::new(),
            would_block: false,
            fail_writes: false,
        }
    }

    pub fn with_read_chunks(read_chunks: Vec<Vec<u8>>) -> Self {
        Self {
            read_chunks: read_chunks.into(),
            written: Vec::new(),
            would_block: false,
            fail_writes: false,
        }
    }

    pub fn with_nonblocking_read_chunks(read_chunks: Vec<Vec<u8>>) -> Self {
        let mut interleaved = VecDeque::new();
        for chunk in read_chunks {
            interleaved.push_back(chunk);
            interleaved.push_back(Vec::new());
        }
        Self {
            read_chunks: interleaved,
            written: Vec::new(),
            would_block: false,
            fail_writes: false,
        }
    }

    pub fn would_blocking() -> Self {
        Self {
            read_chunks: VecDeque::new(),
            written: Vec::new(),
            would_block: true,
            fail_writes: false,
        }
    }

    pub fn write_failing() -> Self {
        Self {
            read_chunks: VecDeque::new(),
            written: Vec::new(),
            would_block: false,
            fail_writes: true,
        }
    }

    pub fn written_bytes(&self) -> &[u8] {
        &self.written
    }
}

#[cfg(test)]
impl Read for MemoryTunnelStream {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        if self.would_block {
            return Err(io::Error::from(io::ErrorKind::WouldBlock));
        }
        let Some(chunk) = self.read_chunks.pop_front() else {
            return Ok(0);
        };

        if chunk.is_empty() {
            return Err(io::Error::from(io::ErrorKind::WouldBlock));
        }
        let count = chunk.len().min(buffer.len());
        buffer[..count].copy_from_slice(&chunk[..count]);
        if count < chunk.len() {
            self.read_chunks.push_front(chunk[count..].to_vec());
        }
        Ok(count)
    }
}

#[cfg(test)]
impl Write for MemoryTunnelStream {
    fn write(&mut self, buffer: &[u8]) -> io::Result<usize> {
        if self.fail_writes {
            return Err(io::Error::from(io::ErrorKind::BrokenPipe));
        }
        self.written.extend_from_slice(buffer);
        Ok(buffer.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

#[cfg(test)]
mod tunnel_copy_pump_tests {
    use crate::infrastructure::tunnel::libssh2_channel::{MemoryTunnelStream, TunnelCopyPump};
    use std::io;

    #[test]
    fn pumps_client_bytes_to_ssh_channel_and_remote_bytes_back() {
        let client = MemoryTunnelStream::with_read_chunks(vec![b"client-query".to_vec()]);
        let channel = MemoryTunnelStream::with_read_chunks(vec![b"remote-reply".to_vec()]);
        let mut pump = TunnelCopyPump::new(client, channel);

        let stats = pump.poll_once().expect("pump once");

        assert_eq!(stats.client_to_remote_bytes, 12);
        assert_eq!(stats.remote_to_client_bytes, 12);
        assert_eq!(pump.client().written_bytes(), b"remote-reply");
        assert_eq!(pump.remote().written_bytes(), b"client-query");
    }

    #[test]
    fn treats_would_block_as_idle_without_closing_streams() {
        let client = MemoryTunnelStream::would_blocking();
        let channel = MemoryTunnelStream::would_blocking();
        let mut pump = TunnelCopyPump::new(client, channel);

        let stats = pump.poll_once().expect("idle pump");

        assert_eq!(stats.client_to_remote_bytes, 0);
        assert_eq!(stats.remote_to_client_bytes, 0);
        assert!(!stats.client_closed);
        assert!(!stats.remote_closed);
    }

    #[test]
    fn reports_closed_direction_on_eof() {
        let client = MemoryTunnelStream::new();
        let channel = MemoryTunnelStream::with_read_chunks(vec![b"remote-reply".to_vec()]);
        let mut pump = TunnelCopyPump::new(client, channel);

        let stats = pump.poll_once().expect("pump eof");

        assert!(stats.client_closed);
        assert!(!stats.remote_closed);
        assert_eq!(pump.client().written_bytes(), b"remote-reply");
    }

    #[test]
    fn maps_write_failure_to_io_error() {
        let client = MemoryTunnelStream::with_read_chunks(vec![b"client-query".to_vec()]);
        let channel = MemoryTunnelStream::write_failing();
        let mut pump = TunnelCopyPump::new(client, channel);

        let error = pump.poll_once().expect_err("write failure");

        assert_eq!(error.kind(), io::ErrorKind::BrokenPipe);
    }
}

#[cfg(test)]
mod local_tunnel_worker_tests {
    use crate::domain::tunnel::{TunnelKind, TunnelProfile};
    use crate::infrastructure::tunnel::libssh2_channel::{
        AcceptedTunnelClient, DynamicSocksTunnelWorker, Libssh2TunnelOpenRequest,
        LocalTunnelWorker, MemoryTunnelStream, RemoteForwardChannelAcceptor, RemoteTunnelWorker,
        TunnelClientAcceptor, TunnelRemoteChannelOpener, TunnelTargetConnector,
    };
    use std::{collections::VecDeque, io};

    #[test]
    fn accepts_client_opens_direct_tcpip_channel_and_pumps_first_tick() {
        let profile = profile();
        let acceptor = FakeTunnelAcceptor::with_clients(vec![AcceptedTunnelClient::new(
            MemoryTunnelStream::with_read_chunks(vec![b"client-query".to_vec()]),
            "127.0.0.1".to_string(),
            51000,
        )]);
        let opener = RecordingRemoteOpener::with_channels(vec![
            MemoryTunnelStream::with_read_chunks(vec![b"remote-reply".to_vec()]),
        ]);
        let mut worker = LocalTunnelWorker::new(profile, acceptor, opener);

        let stats = worker.poll_once().expect("worker poll");

        assert_eq!(stats.accepted_connections, 1);
        assert_eq!(stats.active_connections, 1);
        assert_eq!(stats.client_to_remote_bytes, 12);
        assert_eq!(stats.remote_to_client_bytes, 12);
        assert_eq!(worker.opener().opened_requests.len(), 1);
        assert_eq!(
            worker.opener().opened_requests[0].remote_host,
            "db.internal"
        );
        assert_eq!(worker.opener().opened_requests[0].remote_port, 5432);
        assert_eq!(worker.opener().opened_requests[0].origin_host, "127.0.0.1");
        assert_eq!(worker.opener().opened_requests[0].origin_port, 51000);
    }

    #[test]
    fn idle_acceptor_keeps_worker_empty() {
        let acceptor = FakeTunnelAcceptor::new();
        let opener = RecordingRemoteOpener::new();
        let mut worker = LocalTunnelWorker::new(profile(), acceptor, opener);

        let stats = worker.poll_once().expect("idle poll");

        assert_eq!(stats.accepted_connections, 0);
        assert_eq!(stats.active_connections, 0);
        assert!(worker.opener().opened_requests.is_empty());
    }

    #[test]
    fn removes_connection_after_both_directions_close() {
        let acceptor = FakeTunnelAcceptor::with_clients(vec![AcceptedTunnelClient::new(
            MemoryTunnelStream::new(),
            "127.0.0.1".to_string(),
            51000,
        )]);
        let opener = RecordingRemoteOpener::with_channels(vec![MemoryTunnelStream::new()]);
        let mut worker = LocalTunnelWorker::new(profile(), acceptor, opener);

        let stats = worker.poll_once().expect("closed poll");

        assert_eq!(stats.accepted_connections, 1);
        assert_eq!(stats.active_connections, 0);
    }

    #[test]
    fn dynamic_socks_worker_opens_requested_domain_and_writes_success_response() {
        let acceptor = FakeTunnelAcceptor::with_clients(vec![AcceptedTunnelClient::new(
            MemoryTunnelStream::with_read_chunks(vec![vec![
                0x05, 0x01, 0x00, 0x05, 0x01, 0x00, 0x03, 0x0b, b'd', b'b', b'.', b'i', b'n', b't',
                b'e', b'r', b'n', b'a', b'l', 0x15, 0x38,
            ]]),
            "127.0.0.1".to_string(),
            51001,
        )]);
        let opener = RecordingRemoteOpener::with_channels(vec![MemoryTunnelStream::new()]);
        let mut worker = DynamicSocksTunnelWorker::new(dynamic_profile(), acceptor, opener);

        let stats = worker.poll_once().expect("dynamic worker poll");

        assert_eq!(stats.accepted_connections, 1);
        assert_eq!(stats.active_connections, 0);
        assert_eq!(worker.opener().opened_requests.len(), 1);
        assert_eq!(
            worker.opener().opened_requests[0].remote_host,
            "db.internal"
        );
        assert_eq!(worker.opener().opened_requests[0].remote_port, 5432);
        assert_eq!(worker.opener().opened_requests[0].origin_host, "127.0.0.1");
        assert_eq!(worker.opener().opened_requests[0].origin_port, 51001);
        assert_eq!(
            worker.completed_client(0).written_bytes(),
            &[0x05, 0x00, 0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]
        );
    }

    #[test]
    fn dynamic_socks_worker_forwards_payload_buffered_after_connect_request() {
        let mut frame = vec![
            0x05, 0x01, 0x00, 0x05, 0x01, 0x00, 0x03, 0x0b, b'd', b'b', b'.', b'i', b'n', b't',
            b'e', b'r', b'n', b'a', b'l', 0x15, 0x38,
        ];
        frame.extend_from_slice(b"GET / HTTP/1.1\r\n");
        let acceptor = FakeTunnelAcceptor::with_clients(vec![AcceptedTunnelClient::new(
            MemoryTunnelStream::with_read_chunks(vec![frame]),
            "127.0.0.1".to_string(),
            51003,
        )]);
        let opener = RecordingRemoteOpener::with_channels(vec![MemoryTunnelStream::new()]);
        let mut worker = DynamicSocksTunnelWorker::new(dynamic_profile(), acceptor, opener);

        let stats = worker.poll_once().expect("dynamic worker poll");

        assert_eq!(stats.client_to_remote_bytes, 16);
        assert_eq!(
            worker.completed_remote(0).written_bytes(),
            b"GET / HTTP/1.1\r\n"
        );
    }

    #[test]
    fn dynamic_socks_worker_accepts_large_payload_after_connect_request() {
        let mut frame = vec![
            0x05, 0x01, 0x00, 0x05, 0x01, 0x00, 0x03, 0x0b, b'd', b'b', b'.', b'i', b'n', b't',
            b'e', b'r', b'n', b'a', b'l', 0x15, 0x38,
        ];
        frame.extend(vec![b'x'; 4 * 1024]);
        let acceptor = FakeTunnelAcceptor::with_clients(vec![AcceptedTunnelClient::new(
            MemoryTunnelStream::with_read_chunks(vec![frame]),
            "127.0.0.1".to_string(),
            51007,
        )]);
        let opener = RecordingRemoteOpener::with_channels(vec![MemoryTunnelStream::new()]);
        let mut worker = DynamicSocksTunnelWorker::new(dynamic_profile(), acceptor, opener);

        let stats = worker.poll_once().expect("large payload after connect");

        assert_eq!(stats.accepted_connections, 1);
        assert_eq!(stats.client_to_remote_bytes, 4 * 1024);
        assert_eq!(
            worker.completed_remote(0).written_bytes(),
            vec![b'x'; 4 * 1024]
        );
    }

    #[test]
    fn dynamic_socks_worker_accepts_split_hello_and_connect_frames() {
        let acceptor = FakeTunnelAcceptor::with_clients(vec![AcceptedTunnelClient::new(
            MemoryTunnelStream::with_nonblocking_read_chunks(vec![
                vec![0x05, 0x01, 0x00],
                vec![0x05, 0x01, 0x00, 0x01, 192, 168, 1, 10, 0x00, 0x50],
            ]),
            "127.0.0.1".to_string(),
            51004,
        )]);
        let opener = RecordingRemoteOpener::with_channels(vec![MemoryTunnelStream::new()]);
        let mut worker = DynamicSocksTunnelWorker::new(dynamic_profile(), acceptor, opener);

        let first_tick = worker.poll_once().expect("hello tick");
        let second_tick = worker.poll_once().expect("connect tick");

        assert_eq!(first_tick.accepted_connections, 1);
        assert_eq!(first_tick.active_connections, 1);
        assert_eq!(second_tick.accepted_connections, 0);
        assert_eq!(
            worker.opener().opened_requests[0].remote_host,
            "192.168.1.10"
        );
        assert_eq!(worker.opener().opened_requests[0].remote_port, 80);
        assert_eq!(
            worker.completed_client(0).written_bytes(),
            &[0x05, 0x00, 0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]
        );
    }

    #[test]
    fn dynamic_socks_worker_opens_requested_ipv6_target() {
        let acceptor = FakeTunnelAcceptor::with_clients(vec![AcceptedTunnelClient::new(
            MemoryTunnelStream::with_read_chunks(vec![vec![
                0x05, 0x01, 0x00, 0x05, 0x01, 0x00, 0x04, 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 1, 0x01, 0xbb,
            ]]),
            "127.0.0.1".to_string(),
            51008,
        )]);
        let opener = RecordingRemoteOpener::with_channels(vec![MemoryTunnelStream::new()]);
        let mut worker = DynamicSocksTunnelWorker::new(dynamic_profile(), acceptor, opener);

        let stats = worker.poll_once().expect("dynamic ipv6 worker poll");

        assert_eq!(stats.accepted_connections, 1);
        assert_eq!(worker.opener().opened_requests.len(), 1);
        assert_eq!(
            worker.opener().opened_requests[0].remote_host,
            "2001:db8::1"
        );
        assert_eq!(worker.opener().opened_requests[0].remote_port, 443);
        assert_eq!(
            worker.completed_client(0).written_bytes(),
            &[0x05, 0x00, 0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]
        );
    }

    #[test]
    fn dynamic_socks_worker_rejects_udp_and_bind_without_opening_channel() {
        for (command, port) in [(0x02, 51009), (0x03, 51010)] {
            let acceptor = FakeTunnelAcceptor::with_clients(vec![AcceptedTunnelClient::new(
                MemoryTunnelStream::with_read_chunks(vec![vec![
                    0x05, 0x01, 0x00, 0x05, command, 0x00, 0x01, 127, 0, 0, 1, 0x00, 0x50,
                ]]),
                "127.0.0.1".to_string(),
                port,
            )]);
            let opener = RecordingRemoteOpener::new();
            let mut worker = DynamicSocksTunnelWorker::new(dynamic_profile(), acceptor, opener);

            let stats = worker
                .poll_once()
                .expect("unsupported command is client-scoped");

            assert_eq!(stats.accepted_connections, 1);
            assert_eq!(stats.active_connections, 0);
            assert!(worker.opener().opened_requests.is_empty());
            assert_eq!(
                worker.completed_client(0).written_bytes(),
                &[0x05, 0x00, 0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0]
            );
        }
    }

    #[test]
    fn dynamic_socks_worker_rejects_unsupported_auth_without_opening_channel() {
        let acceptor = FakeTunnelAcceptor::with_clients(vec![AcceptedTunnelClient::new(
            MemoryTunnelStream::with_read_chunks(vec![vec![0x05, 0x01, 0x02]]),
            "127.0.0.1".to_string(),
            51002,
        )]);
        let opener = RecordingRemoteOpener::new();
        let mut worker = DynamicSocksTunnelWorker::new(dynamic_profile(), acceptor, opener);

        let stats = worker.poll_once().expect("dynamic worker auth reject");

        assert_eq!(stats.accepted_connections, 1);
        assert_eq!(stats.active_connections, 0);
        assert!(worker.opener().opened_requests.is_empty());
        assert_eq!(worker.completed_client(0).written_bytes(), &[0x05, 0xff]);
    }

    #[test]
    fn dynamic_socks_worker_drops_client_when_handshake_eofs_before_connect() {
        let acceptor = FakeTunnelAcceptor::with_clients(vec![AcceptedTunnelClient::new(
            MemoryTunnelStream::with_read_chunks(vec![vec![0x05, 0x01, 0x00]]),
            "127.0.0.1".to_string(),
            51006,
        )]);
        let opener = RecordingRemoteOpener::new();
        let mut worker = DynamicSocksTunnelWorker::new(dynamic_profile(), acceptor, opener);

        let stats = worker.poll_once().expect("incomplete eof is client-scoped");

        assert_eq!(stats.accepted_connections, 1);
        assert_eq!(stats.active_connections, 0);
        assert!(worker.opener().opened_requests.is_empty());
        assert_eq!(worker.completed_client(0).written_bytes(), &[0x05, 0x00]);
    }

    #[test]
    fn dynamic_socks_worker_keeps_listener_running_when_target_open_fails() {
        let acceptor = FakeTunnelAcceptor::with_clients(vec![AcceptedTunnelClient::new(
            MemoryTunnelStream::with_read_chunks(vec![vec![
                0x05, 0x01, 0x00, 0x05, 0x01, 0x00, 0x03, 0x0b, b'd', b'b', b'.', b'i', b'n', b't',
                b'e', b'r', b'n', b'a', b'l', 0x15, 0x38,
            ]]),
            "127.0.0.1".to_string(),
            51005,
        )]);
        let opener = RecordingRemoteOpener::new();
        let mut worker = DynamicSocksTunnelWorker::new(dynamic_profile(), acceptor, opener);

        let stats = worker.poll_once().expect("target failure is client-scoped");

        assert_eq!(stats.accepted_connections, 1);
        assert_eq!(stats.active_connections, 0);
        assert_eq!(worker.opener().opened_requests.len(), 1);
        assert_eq!(
            worker.completed_client(0).written_bytes(),
            &[0x05, 0x00, 0x05, 0x01, 0x00, 0x01, 0, 0, 0, 0, 0, 0]
        );
    }

    #[test]
    fn remote_tunnel_worker_accepts_forwarded_channel_connects_local_target_and_pumps() {
        let acceptor =
            FakeRemoteForwardAcceptor::with_channels(vec![MemoryTunnelStream::with_read_chunks(
                vec![b"remote-query".to_vec()],
            )]);
        let connector =
            RecordingTargetConnector::with_targets(vec![MemoryTunnelStream::with_read_chunks(
                vec![b"local-reply".to_vec()],
            )]);
        let mut worker = RemoteTunnelWorker::new(remote_profile(), acceptor, connector);

        let stats = worker.poll_once().expect("remote worker poll");

        assert_eq!(stats.accepted_connections, 1);
        assert_eq!(stats.active_connections, 1);
        assert_eq!(stats.client_to_remote_bytes, 12);
        assert_eq!(stats.remote_to_client_bytes, 11);
        assert_eq!(
            worker.connector().connect_requests,
            vec![("127.0.0.1".to_string(), 15432)]
        );
    }

    #[test]
    fn remote_tunnel_worker_keeps_listener_running_when_local_target_connect_fails() {
        let acceptor =
            FakeRemoteForwardAcceptor::with_channels(vec![MemoryTunnelStream::with_read_chunks(
                vec![b"remote-query".to_vec()],
            )]);
        let connector = RecordingTargetConnector::new();
        let mut worker = RemoteTunnelWorker::new(remote_profile(), acceptor, connector);

        let stats = worker
            .poll_once()
            .expect("local target failure is connection-scoped");

        assert_eq!(stats.accepted_connections, 1);
        assert_eq!(stats.active_connections, 0);
        assert_eq!(
            worker.connector().connect_requests,
            vec![("127.0.0.1".to_string(), 15432)]
        );
    }

    fn profile() -> TunnelProfile {
        TunnelProfile {
            id: "tun_worker".to_string(),
            kind: TunnelKind::Local,
            local_host: "127.0.0.1".to_string(),
            local_port: 18080,
            remote_host: "db.internal".to_string(),
            remote_port: 5432,
        }
    }

    fn dynamic_profile() -> TunnelProfile {
        TunnelProfile {
            id: "tun_dynamic".to_string(),
            kind: TunnelKind::Dynamic,
            local_host: "127.0.0.1".to_string(),
            local_port: 1080,
            remote_host: "socks".to_string(),
            remote_port: 1080,
        }
    }

    fn remote_profile() -> TunnelProfile {
        TunnelProfile {
            id: "tun_remote".to_string(),
            kind: TunnelKind::Remote,
            local_host: "127.0.0.1".to_string(),
            local_port: 15432,
            remote_host: "0.0.0.0".to_string(),
            remote_port: 19000,
        }
    }

    struct FakeTunnelAcceptor {
        clients: VecDeque<AcceptedTunnelClient<MemoryTunnelStream>>,
    }

    impl FakeTunnelAcceptor {
        fn new() -> Self {
            Self {
                clients: VecDeque::new(),
            }
        }

        fn with_clients(clients: Vec<AcceptedTunnelClient<MemoryTunnelStream>>) -> Self {
            Self {
                clients: clients.into(),
            }
        }
    }

    impl TunnelClientAcceptor for FakeTunnelAcceptor {
        type Client = MemoryTunnelStream;

        fn accept(&mut self) -> io::Result<Option<AcceptedTunnelClient<Self::Client>>> {
            Ok(self.clients.pop_front())
        }
    }

    struct RecordingRemoteOpener {
        channels: VecDeque<MemoryTunnelStream>,
        opened_requests: Vec<Libssh2TunnelOpenRequest>,
    }

    impl RecordingRemoteOpener {
        fn new() -> Self {
            Self {
                channels: VecDeque::new(),
                opened_requests: Vec::new(),
            }
        }

        fn with_channels(channels: Vec<MemoryTunnelStream>) -> Self {
            Self {
                channels: channels.into(),
                opened_requests: Vec::new(),
            }
        }
    }

    impl TunnelRemoteChannelOpener for RecordingRemoteOpener {
        type Remote = MemoryTunnelStream;

        fn open_channel(&mut self, request: Libssh2TunnelOpenRequest) -> io::Result<Self::Remote> {
            self.opened_requests.push(request);
            self.channels
                .pop_front()
                .ok_or_else(|| io::Error::from(io::ErrorKind::NotConnected))
        }
    }

    struct FakeRemoteForwardAcceptor {
        channels: VecDeque<MemoryTunnelStream>,
    }

    impl FakeRemoteForwardAcceptor {
        fn with_channels(channels: Vec<MemoryTunnelStream>) -> Self {
            Self {
                channels: channels.into(),
            }
        }
    }

    impl RemoteForwardChannelAcceptor for FakeRemoteForwardAcceptor {
        type Remote = MemoryTunnelStream;

        fn accept(&mut self) -> io::Result<Option<Self::Remote>> {
            Ok(self.channels.pop_front())
        }
    }

    struct RecordingTargetConnector {
        targets: VecDeque<MemoryTunnelStream>,
        connect_requests: Vec<(String, u16)>,
    }

    impl RecordingTargetConnector {
        fn new() -> Self {
            Self {
                targets: VecDeque::new(),
                connect_requests: Vec::new(),
            }
        }

        fn with_targets(targets: Vec<MemoryTunnelStream>) -> Self {
            Self {
                targets: targets.into(),
                connect_requests: Vec::new(),
            }
        }
    }

    impl TunnelTargetConnector for RecordingTargetConnector {
        type Target = MemoryTunnelStream;

        fn connect(&mut self, host: &str, port: u16) -> io::Result<Self::Target> {
            self.connect_requests.push((host.to_string(), port));
            self.targets
                .pop_front()
                .ok_or_else(|| io::Error::from(io::ErrorKind::NotConnected))
        }
    }
}

#[cfg(test)]
mod tcp_acceptor_tests {
    use crate::infrastructure::tunnel::libssh2_channel::TcpTunnelClientAcceptor;
    use crate::infrastructure::tunnel::libssh2_channel::TunnelClientAcceptor;
    use std::io::Write;
    use std::net::{TcpListener, TcpStream};

    #[test]
    fn accepts_loopback_client_without_blocking_on_empty_queue() {
        let listener = TcpListener::bind(("127.0.0.1", 0)).expect("bind local listener");
        let address = listener.local_addr().expect("local address");
        let mut acceptor = TcpTunnelClientAcceptor::from_listener(listener).expect("acceptor");

        assert!(acceptor.accept().expect("idle accept").is_none());

        let mut client = TcpStream::connect(address).expect("connect client");
        client.write_all(b"ping").expect("write client payload");
        let accepted = acceptor
            .accept()
            .expect("accept client")
            .expect("accepted client");

        assert_eq!(accepted.origin_host, "127.0.0.1");
        assert!(accepted.origin_port > 0);
    }
}

#[cfg(test)]
mod libssh2_opener_tests {
    use crate::infrastructure::tunnel::libssh2_channel::{
        Libssh2DirectTcpIpOpener, Libssh2TunnelOpenRequest,
    };

    #[test]
    fn direct_tcpip_opener_is_debug_redacted() {
        let request = Libssh2TunnelOpenRequest {
            remote_host: "db.internal".to_string(),
            remote_port: 5432,
            origin_host: "127.0.0.1".to_string(),
            origin_port: 51000,
        };
        let opener = Libssh2DirectTcpIpOpener::new_for_testing();

        assert!(!format!("{request:?}").contains("ssh "));
        assert_eq!(opener.opened_count(), 0);
    }
}

#[cfg(test)]
mod libssh2_tunnel_tests {
    use crate::domain::tunnel::{TunnelError, TunnelKind, TunnelProfile};
    use crate::infrastructure::tunnel::libssh2_channel::{
        Libssh2RemoteForwardListenRequest, Libssh2TunnelAdapter, Libssh2TunnelOpenRequest,
    };
    use crate::services::tunnel_service::TunnelChannel;
    use std::net::TcpListener;

    fn profile(kind: TunnelKind) -> TunnelProfile {
        TunnelProfile {
            id: "tun_libssh2".to_string(),
            kind,
            local_host: "127.0.0.1".to_string(),
            local_port: 18080,
            remote_host: "db.internal".to_string(),
            remote_port: 5432,
        }
    }

    #[test]
    fn builds_local_forward_direct_tcpip_request_without_system_command() {
        let request = Libssh2TunnelOpenRequest::from_profile(&profile(TunnelKind::Local))
            .expect("local request");

        assert_eq!(request.remote_host, "db.internal");
        assert_eq!(request.remote_port, 5432);
        assert_eq!(request.origin_host, "127.0.0.1");
        assert_eq!(request.origin_port, 18080);
        assert!(!format!("{request:?}").contains("ssh "));
        assert!(!format!("{request:?}").contains("scp "));
        assert!(!format!("{request:?}").contains("sftp "));
    }

    #[test]
    fn builds_remote_forward_listen_request_without_system_command() {
        let request = Libssh2RemoteForwardListenRequest::from_profile(&profile(TunnelKind::Remote))
            .expect("remote request");

        assert_eq!(request.bind_host, "db.internal");
        assert_eq!(request.bind_port, 5432);
        assert_eq!(request.target_host, "127.0.0.1");
        assert_eq!(request.target_port, 18080);
        assert!(!format!("{request:?}").contains("ssh "));
        assert!(!format!("{request:?}").contains("scp "));
        assert!(!format!("{request:?}").contains("sftp "));
    }

    #[test]
    fn adapter_preflights_local_port_before_opening_ssh_channel() {
        let listener = TcpListener::bind(("127.0.0.1", 0)).expect("bind fixture port");
        let mut tunnel = profile(TunnelKind::Local);
        tunnel.local_port = listener.local_addr().expect("fixture address").port();
        let adapter = Libssh2TunnelAdapter::new();

        let error = adapter.start(&tunnel).expect_err("port in use");

        assert_eq!(error, TunnelError::LocalPortInUse);
    }
}
