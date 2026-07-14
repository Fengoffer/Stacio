use std::{
    collections::{BTreeMap, VecDeque},
    io,
    sync::{Condvar, Mutex},
    time::{Duration, Instant},
};

use crate::domain::{
    ssh::{redact_ssh_diagnostic, SshRuntimeError},
    terminal::{TerminalRuntime, TerminalRuntimeError},
};
use crate::services::terminal_service::TerminalRuntimeRegistry;

const INITIAL_INPUT_ECHO_FILTER_TTL: Duration = Duration::from_secs(5);
const OSC7_BOOTSTRAP_ECHO_FILTER_TTL: Duration = Duration::from_secs(30);
const RAPID_LINE_SUBMIT_PROMPT_WAIT_TIMEOUT: Duration = Duration::from_millis(120);

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct LiveShellStatus {
    pub runtime_id: String,
    pub status: String,
    pub diagnostic: String,
}

impl LiveShellStatus {
    pub fn not_running(runtime_id: String) -> Self {
        Self {
            runtime_id,
            status: "not_running".to_string(),
            diagnostic: "not_running".to_string(),
        }
    }

    pub fn running(runtime_id: String) -> Self {
        Self {
            runtime_id,
            status: "running".to_string(),
            diagnostic: "running".to_string(),
        }
    }

    pub fn failed(runtime_id: String, diagnostic: &str) -> Self {
        Self {
            runtime_id,
            status: "failed".to_string(),
            diagnostic: redact_ssh_diagnostic(diagnostic),
        }
    }
}

pub trait ShellChannel {
    fn write_input(&mut self, bytes: &[u8]) -> io::Result<usize>;
    fn read_output(&mut self, max_bytes: usize) -> io::Result<Vec<u8>>;
    fn resize_pty(&mut self, cols: u32, rows: u32) -> io::Result<()>;
    fn close(&mut self) -> io::Result<()>;
    fn is_eof(&self) -> bool;
    fn keepalive(&mut self) -> io::Result<()> {
        Ok(())
    }
    fn wait_interest(&self) -> Option<ShellWaitInterest> {
        None
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ShellWaitInterest {
    pub raw_fd: i32,
    pub readable: bool,
    pub writable: bool,
}

impl ShellWaitInterest {
    pub fn new(raw_fd: i32, readable: bool, writable: bool) -> Self {
        Self {
            raw_fd,
            readable,
            writable,
        }
    }

    pub fn readable(raw_fd: i32) -> Self {
        Self::new(raw_fd, true, false)
    }
}

pub struct LiveShellWorker<C: ShellChannel> {
    runtime_id: String,
    channel: C,
    observed_resize_revision: u64,
    pending_input: Vec<u8>,
    queued_input_chunks: VecDeque<Vec<u8>>,
    bootstrap_input: Vec<u8>,
    initial_input_echo_filters: Vec<InitialInputEchoFilter>,
    rapid_line_submit_prompt_wait_until: Option<Instant>,
    last_keepalive_at: Option<Instant>,
    keepalive_interval: Option<Duration>,
    consecutive_keepalive_failures: u8,
    closed: bool,
}

struct InitialInputEchoFilter {
    pattern: Vec<u8>,
    expires_at: Instant,
    buffered_prefix: Vec<u8>,
    allow_embedded_match: bool,
}

impl<C: ShellChannel> LiveShellWorker<C> {
    pub fn new(runtime_id: String, channel: C) -> Self {
        Self::new_with_initial_input_chunks(runtime_id, channel, Vec::new())
    }

    pub fn new_with_initial_input_chunks(
        runtime_id: String,
        channel: C,
        initial_input_chunks: Vec<Vec<u8>>,
    ) -> Self {
        let now = Instant::now();
        let initial_input_echo_filters =
            initial_input_echo_filters_for_chunks(&initial_input_chunks, now);
        let mut queued_input_chunks = VecDeque::from(initial_input_chunks);
        let pending_input = queued_input_chunks.pop_front().unwrap_or_default();
        Self {
            runtime_id,
            channel,
            observed_resize_revision: 0,
            pending_input,
            queued_input_chunks,
            bootstrap_input: Vec::new(),
            initial_input_echo_filters,
            rapid_line_submit_prompt_wait_until: None,
            last_keepalive_at: Some(now),
            keepalive_interval: Some(Duration::from_secs(20)),
            consecutive_keepalive_failures: 0,
            closed: false,
        }
    }

    pub fn new_with_bootstrap_input(
        runtime_id: String,
        channel: C,
        bootstrap_input: Vec<u8>,
    ) -> Self {
        let now = Instant::now();
        let initial_input_echo_filters =
            initial_input_echo_filters_for_chunks(std::slice::from_ref(&bootstrap_input), now);
        Self {
            runtime_id,
            channel,
            observed_resize_revision: 0,
            pending_input: Vec::new(),
            queued_input_chunks: VecDeque::new(),
            bootstrap_input,
            initial_input_echo_filters,
            rapid_line_submit_prompt_wait_until: None,
            last_keepalive_at: Some(now),
            keepalive_interval: Some(Duration::from_secs(20)),
            consecutive_keepalive_failures: 0,
            closed: false,
        }
    }

    pub fn channel(&self) -> &C {
        &self.channel
    }

    pub fn runtime_id(&self) -> &str {
        &self.runtime_id
    }

    pub fn set_keepalive_interval_seconds(&mut self, seconds: u32) {
        self.keepalive_interval = if seconds == 0 {
            None
        } else {
            Some(Duration::from_secs(seconds.clamp(1, 600).into()))
        };
        self.last_keepalive_at = Some(Instant::now());
        self.consecutive_keepalive_failures = 0;
    }

    pub fn poll(
        &mut self,
        registry: &mut TerminalRuntimeRegistry,
    ) -> Result<LiveShellStatus, TerminalRuntimeError> {
        if self.closed {
            return Ok(self.status("closed", "closed"));
        }

        let snapshot = registry.runtime_snapshot(self.runtime_id.clone())?;
        if snapshot.resize_revision != self.observed_resize_revision {
            self.channel
                .resize_pty(snapshot.cols, snapshot.rows)
                .map_err(map_channel_io_error)?;
            self.observed_resize_revision = snapshot.resize_revision;
        }

        let (input_chunks, input_dropped_byte_count) =
            registry.take_input_chunks(self.runtime_id.clone())?;
        for input_chunk in input_chunks {
            if !input_chunk.is_empty() {
                self.enqueue_input(input_chunk);
            }
        }
        self.flush_bootstrap_input();
        self.flush_pending_input()?;

        if input_dropped_byte_count > 0 {
            registry.record_output(
                self.runtime_id.clone(),
                format!(
                    "\x1b[1;38;5;214mStacio\x1b[0m 因输入缓冲区已满丢弃了 {} 个终端输入字节。\n",
                    input_dropped_byte_count
                )
                .into_bytes(),
            )?;
        }

        if self.keepalive_if_due() {
            self.closed = true;
            let _ = self.channel.close();
            let _ = registry.close(self.runtime_id.clone())?;
            return Ok(self.status("closed", "keepalive_failed"));
        }

        loop {
            let output = self
                .channel
                .read_output(16 * 1024)
                .map_err(map_channel_io_error)?;
            if output.is_empty() {
                break;
            }
            let visible_output = self.filter_initial_input_echo(output);
            if !visible_output.is_empty() {
                if self.rapid_line_submit_prompt_wait_until.is_some()
                    && output_marks_interactive_prompt(visible_output.as_slice())
                {
                    self.rapid_line_submit_prompt_wait_until = None;
                }
                registry.record_output(self.runtime_id.clone(), visible_output)?;
            }
        }

        if self.channel.is_eof() {
            self.closed = true;
            let _ = self.channel.close();
            let _ = registry.close(self.runtime_id.clone())?;
            return Ok(self.status("closed", "closed"));
        }

        Ok(self.status("running", "running"))
    }

    pub fn close(
        &mut self,
        registry: &mut TerminalRuntimeRegistry,
    ) -> Result<LiveShellStatus, TerminalRuntimeError> {
        self.closed = true;
        let _ = self.channel.close();
        let _ = registry.close(self.runtime_id.clone())?;
        Ok(self.status("closed", "closed"))
    }

    fn status(&self, status: &str, diagnostic: &str) -> LiveShellStatus {
        LiveShellStatus {
            runtime_id: self.runtime_id.clone(),
            status: status.to_string(),
            diagnostic: diagnostic.to_string(),
        }
    }

    fn has_pending_input(&self) -> bool {
        !self.bootstrap_input.is_empty()
            || !self.pending_input.is_empty()
            || !self.queued_input_chunks.is_empty()
    }

    fn enqueue_input(&mut self, bytes: Vec<u8>) {
        if self.has_pending_input() {
            self.queued_input_chunks.push_back(bytes);
        } else {
            self.pending_input = bytes;
        }
    }

    fn load_next_pending_input(&mut self) {
        if self.pending_input.is_empty() {
            self.pending_input = self.queued_input_chunks.pop_front().unwrap_or_default();
        }
    }

    fn should_defer_next_pending_input(&mut self) -> bool {
        let Some(wait_until) = self.rapid_line_submit_prompt_wait_until else {
            return false;
        };
        if Instant::now() < wait_until {
            return true;
        }
        self.rapid_line_submit_prompt_wait_until = None;
        false
    }

    fn next_pending_input_is_line_submit(&self) -> bool {
        if !self.pending_input.is_empty() {
            return is_line_submit_input_chunk(&self.pending_input);
        }
        self.queued_input_chunks
            .front()
            .is_some_and(|chunk| is_line_submit_input_chunk(chunk))
    }

    fn keepalive_if_due(&mut self) -> bool {
        let Some(interval) = self.keepalive_interval else {
            return false;
        };
        let now = Instant::now();
        if self
            .last_keepalive_at
            .is_some_and(|last| now.duration_since(last) < interval)
        {
            return false;
        }
        if self.channel.keepalive().is_err() {
            self.last_keepalive_at = Some(now);
            self.consecutive_keepalive_failures =
                self.consecutive_keepalive_failures.saturating_add(1);
            return self.consecutive_keepalive_failures >= 2;
        }
        self.consecutive_keepalive_failures = 0;
        self.last_keepalive_at = Some(now);
        false
    }

    fn flush_bootstrap_input(&mut self) {
        while !self.bootstrap_input.is_empty() {
            match self.channel.write_input(&self.bootstrap_input) {
                Ok(0) => {
                    self.bootstrap_input.clear();
                    break;
                }
                Ok(count) => {
                    let written = count.min(self.bootstrap_input.len());
                    self.bootstrap_input.drain(..written);
                }
                Err(_) => {
                    self.bootstrap_input.clear();
                    break;
                }
            }
        }
    }

    fn flush_pending_input(&mut self) -> Result<(), TerminalRuntimeError> {
        if self.next_pending_input_is_line_submit() && self.should_defer_next_pending_input() {
            return Ok(());
        }
        self.load_next_pending_input();
        let is_line_submit_chunk = is_line_submit_input_chunk(&self.pending_input);
        while !self.pending_input.is_empty() {
            match self.channel.write_input(&self.pending_input) {
                Ok(0) => break,
                Ok(count) => {
                    let written = count.min(self.pending_input.len());
                    self.pending_input.drain(..written);
                    if self.pending_input.is_empty() {
                        if is_line_submit_chunk {
                            self.rapid_line_submit_prompt_wait_until =
                                Some(Instant::now() + RAPID_LINE_SUBMIT_PROMPT_WAIT_TIMEOUT);
                        } else {
                            self.rapid_line_submit_prompt_wait_until = None;
                        }
                        break;
                    }
                }
                Err(error) if is_transient_channel_io_error(&error) => break,
                Err(error) => return Err(map_channel_io_error(error)),
            }
        }
        Ok(())
    }

    fn filter_initial_input_echo(&mut self, output: Vec<u8>) -> Vec<u8> {
        if self.initial_input_echo_filters.is_empty() || output.is_empty() {
            return output;
        }

        let now = Instant::now();
        let mut visible = output;
        let mut retained_filters = Vec::with_capacity(self.initial_input_echo_filters.len());
        for mut filter in self.initial_input_echo_filters.drain(..) {
            if filter.expires_at <= now {
                if !filter.buffered_prefix.is_empty() {
                    let mut restored = std::mem::take(&mut filter.buffered_prefix);
                    restored.extend_from_slice(&visible);
                    visible = restored;
                }
                continue;
            }

            if !filter.buffered_prefix.is_empty() {
                let mut combined = std::mem::take(&mut filter.buffered_prefix);
                combined.extend_from_slice(&visible);
                visible = combined;
            }

            let mut removed_echo = false;
            while let Some(filtered) = remove_first_confirmed_initial_echo(
                visible.as_slice(),
                &filter.pattern,
                filter.allow_embedded_match,
            ) {
                removed_echo = true;
                visible = filtered;
                if !filter.allow_embedded_match {
                    break;
                }
            }
            if removed_echo {
                if filter.allow_embedded_match {
                    if let Some(prefix_len) = pending_initial_echo_prefix_len(
                        visible.as_slice(),
                        &filter.pattern,
                        filter.allow_embedded_match,
                    ) {
                        let split_at = visible.len().saturating_sub(prefix_len);
                        filter.buffered_prefix = visible.split_off(split_at);
                    }
                    retained_filters.push(filter);
                }
                continue;
            }

            if let Some(prefix_len) = pending_initial_echo_prefix_len(
                visible.as_slice(),
                &filter.pattern,
                filter.allow_embedded_match,
            ) {
                let split_at = visible.len().saturating_sub(prefix_len);
                filter.buffered_prefix = visible.split_off(split_at);
            }
            retained_filters.push(filter);
        }
        self.initial_input_echo_filters = retained_filters;
        visible
    }
}

fn is_line_submit_input_chunk(bytes: &[u8]) -> bool {
    matches!(bytes, [b'\n'] | [b'\r'] | [b'\r', b'\n'])
}

fn output_marks_interactive_prompt(bytes: &[u8]) -> bool {
    find_subsequence(bytes, b"\x1b]7;file://").is_some()
        || find_subsequence(bytes, b"\x1b[?2004h").is_some()
}

fn initial_input_echo_filters_for_chunks(
    chunks: &[Vec<u8>],
    installed_at: Instant,
) -> Vec<InitialInputEchoFilter> {
    chunks
        .iter()
        .filter_map(|chunk| shell_echo_filter_for_initial_input(chunk))
        .map(|pattern| {
            let allow_embedded_match = is_stacio_osc7_bootstrap_echo_pattern(&pattern);
            let ttl = if allow_embedded_match {
                OSC7_BOOTSTRAP_ECHO_FILTER_TTL
            } else {
                INITIAL_INPUT_ECHO_FILTER_TTL
            };
            InitialInputEchoFilter {
                pattern,
                expires_at: installed_at + ttl,
                buffered_prefix: Vec::new(),
                allow_embedded_match,
            }
        })
        .collect()
}

fn shell_echo_filter_for_initial_input(input: &[u8]) -> Option<Vec<u8>> {
    let trimmed = trim_ascii_line_ending(input);
    if trimmed.is_empty() {
        return None;
    }

    Some(
        trimmed
            .iter()
            .flat_map(|byte| match *byte {
                b'\n' => vec![b'\r', b'\n'],
                b => vec![b],
            })
            .collect(),
    )
}

fn trim_ascii_line_ending(input: &[u8]) -> &[u8] {
    match input {
        [prefix @ .., b'\r', b'\n'] => prefix,
        [prefix @ .., b'\n'] => prefix,
        [prefix @ .., b'\r'] => prefix,
        _ => input,
    }
}

fn is_stacio_osc7_bootstrap_echo_pattern(pattern: &[u8]) -> bool {
    find_subsequence(pattern, b"__stacio_with_timeout").is_some()
        && find_subsequence(pattern, b"__stacio_report_cwd").is_some()
        && find_subsequence(pattern, b"precmd_functions").is_some()
        && find_subsequence(pattern, b"PROMPT_COMMAND").is_some()
}

fn remove_first_confirmed_initial_echo(
    bytes: &[u8],
    needle: &[u8],
    allow_embedded_start: bool,
) -> Option<Vec<u8>> {
    let start = find_subsequence(bytes, needle)?;
    if !allow_embedded_start && !has_initial_echo_start_boundary(bytes, start) {
        return None;
    }
    let match_end = start + needle.len();
    if !has_initial_echo_end_boundary(bytes, match_end) {
        return None;
    }

    let mut end = match_end;
    if bytes.get(end) == Some(&b'\r') {
        end += 1;
    }
    if bytes.get(end) == Some(&b'\n') {
        end += 1;
    }

    let mut visible = Vec::with_capacity(bytes.len().saturating_sub(end - start));
    visible.extend_from_slice(&bytes[..start]);
    visible.extend_from_slice(&bytes[end..]);
    Some(visible)
}

fn pending_initial_echo_prefix_len(
    bytes: &[u8],
    needle: &[u8],
    allow_embedded_start: bool,
) -> Option<usize> {
    let max_len = bytes.len().min(needle.len().saturating_sub(1));
    for len in (1..=max_len).rev() {
        let start = bytes.len().saturating_sub(len);
        if !allow_embedded_start && !has_initial_echo_start_boundary(bytes, start) {
            continue;
        }
        if bytes[start..] == needle[..len] {
            return Some(len);
        }
    }
    None
}

fn has_initial_echo_start_boundary(bytes: &[u8], start: usize) -> bool {
    if start == 0 || matches!(bytes.get(start - 1), Some(b'\r' | b'\n')) {
        return true;
    }
    if !matches!(bytes.get(start - 1), Some(b' ' | b'\t')) {
        return false;
    }
    let line_start = bytes[..start]
        .iter()
        .rposition(|byte| matches!(*byte, b'\r' | b'\n'))
        .map_or(0, |index| index + 1);
    initial_echo_line_prefix_looks_like_prompt(&bytes[line_start..start])
}

fn initial_echo_line_prefix_looks_like_prompt(bytes: &[u8]) -> bool {
    let Some(last) = bytes.iter().rfind(|byte| !matches!(**byte, b' ' | b'\t')) else {
        return false;
    };
    matches!(*last, b'#' | b'$' | b'%' | b'>')
}

fn has_initial_echo_end_boundary(bytes: &[u8], end: usize) -> bool {
    end >= bytes.len() || matches!(bytes.get(end), Some(b'\r' | b'\n' | 0x1b))
}

fn find_subsequence(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() {
        return None;
    }
    haystack
        .windows(needle.len())
        .position(|window| window == needle)
}

pub struct LiveShellManager<C: ShellChannel> {
    workers: BTreeMap<String, LiveShellWorker<C>>,
}

impl<C: ShellChannel> LiveShellManager<C> {
    pub fn new() -> Self {
        Self {
            workers: BTreeMap::new(),
        }
    }

    pub fn active_count(&self) -> usize {
        self.workers.len()
    }

    pub fn register(&mut self, worker: LiveShellWorker<C>) {
        self.workers.insert(worker.runtime_id().to_string(), worker);
    }

    pub fn poll(
        &mut self,
        registry: &mut TerminalRuntimeRegistry,
        runtime_id: String,
    ) -> Result<LiveShellStatus, TerminalRuntimeError> {
        let Some(worker) = self.workers.get_mut(&runtime_id) else {
            registry.runtime_snapshot(runtime_id.clone())?;
            return Ok(LiveShellStatus::not_running(runtime_id));
        };

        let status = worker.poll(registry)?;
        if status.status == "closed" || status.status == "failed" {
            self.workers.remove(&runtime_id);
        }
        Ok(status)
    }

    pub fn status_for_runtime(
        &self,
        registry: &TerminalRuntimeRegistry,
        runtime_id: String,
    ) -> Result<LiveShellStatus, TerminalRuntimeError> {
        if self.workers.contains_key(&runtime_id) {
            return Ok(LiveShellStatus::running(runtime_id));
        }

        let snapshot = registry.runtime_snapshot(runtime_id.clone())?;
        if snapshot.status == "closed" {
            return Ok(LiveShellStatus {
                runtime_id,
                status: "closed".to_string(),
                diagnostic: "closed".to_string(),
            });
        }

        Ok(LiveShellStatus::not_running(runtime_id))
    }

    pub fn poll_all(
        &mut self,
        registry: &mut TerminalRuntimeRegistry,
    ) -> Result<Vec<LiveShellStatus>, TerminalRuntimeError> {
        let runtime_ids = self.workers.keys().cloned().collect::<Vec<_>>();
        let mut statuses = Vec::with_capacity(runtime_ids.len());
        for runtime_id in runtime_ids {
            statuses.push(self.poll(registry, runtime_id)?);
        }
        Ok(statuses)
    }

    pub fn active_runtime_ids(&self) -> Vec<String> {
        self.workers.keys().cloned().collect()
    }

    pub fn set_keepalive_interval_seconds(
        &mut self,
        runtime_id: &str,
        seconds: u32,
    ) -> Result<(), TerminalRuntimeError> {
        let Some(worker) = self.workers.get_mut(runtime_id) else {
            return Err(TerminalRuntimeError::RuntimeNotFound {
                runtime_id: runtime_id.to_string(),
            });
        };
        worker.set_keepalive_interval_seconds(seconds);
        Ok(())
    }

    pub fn has_pending_input(&self) -> bool {
        self.workers.values().any(LiveShellWorker::has_pending_input)
    }

    pub fn wait_interests(&self) -> Vec<ShellWaitInterest> {
        if self
            .workers
            .values()
            .any(LiveShellWorker::has_pending_input)
        {
            return Vec::new();
        }
        self.workers
            .values()
            .filter_map(|worker| worker.channel.wait_interest())
            .collect()
    }

    pub fn close(
        &mut self,
        registry: &mut TerminalRuntimeRegistry,
        runtime_id: String,
    ) -> Result<LiveShellStatus, TerminalRuntimeError> {
        if let Some(mut worker) = self.workers.remove(&runtime_id) {
            return worker.close(registry);
        }

        let _ = registry.close(runtime_id.clone())?;
        Ok(LiveShellStatus {
            runtime_id,
            status: "closed".to_string(),
            diagnostic: "closed".to_string(),
        })
    }
}

pub struct LiveShellPumpSignal {
    marker: Mutex<u64>,
    changed: Condvar,
}

impl LiveShellPumpSignal {
    pub fn new() -> Self {
        Self {
            marker: Mutex::new(0),
            changed: Condvar::new(),
        }
    }

    pub fn marker(&self) -> u64 {
        *self.marker.lock().expect("live shell pump marker lock")
    }

    pub fn notify(&self) -> u64 {
        let mut marker = self.marker.lock().expect("live shell pump marker lock");
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
        let mut marker = self.marker.lock().expect("live shell pump marker lock");
        if *marker != observed_marker {
            return *marker;
        }

        if has_active_workers {
            let (guard, _) = self
                .changed
                .wait_timeout_while(marker, active_wait, |current| *current == observed_marker)
                .expect("live shell pump condvar wait");
            return *guard;
        }

        while *marker == observed_marker {
            marker = self
                .changed
                .wait(marker)
                .expect("live shell pump condvar wait");
        }
        *marker
    }
}

pub fn start_live_shell_worker<C, F>(
    registry: &mut TerminalRuntimeRegistry,
    manager: &mut LiveShellManager<C>,
    host: String,
    port: u16,
    username: String,
    cols: u32,
    rows: u32,
    open_channel: F,
) -> Result<LiveShellStatus, SshRuntimeError>
where
    C: ShellChannel,
    F: FnOnce(&TerminalRuntime) -> Result<C, SshRuntimeError>,
{
    start_live_shell_worker_with_initial_input_chunks(
        registry,
        manager,
        host,
        port,
        username,
        cols,
        rows,
        open_channel,
        Vec::new(),
    )
}

pub fn start_live_shell_worker_with_initial_input_chunks<C, F>(
    registry: &mut TerminalRuntimeRegistry,
    manager: &mut LiveShellManager<C>,
    host: String,
    port: u16,
    username: String,
    cols: u32,
    rows: u32,
    open_channel: F,
    initial_input_chunks: Vec<Vec<u8>>,
) -> Result<LiveShellStatus, SshRuntimeError>
where
    C: ShellChannel,
    F: FnOnce(&TerminalRuntime) -> Result<C, SshRuntimeError>,
{
    let runtime = registry.open_remote_ssh(host, port, username, cols, rows);
    match open_channel(&runtime) {
        Ok(channel) => {
            manager.register(LiveShellWorker::new_with_initial_input_chunks(
                runtime.id.clone(),
                channel,
                initial_input_chunks,
            ));
            Ok(LiveShellStatus::running(runtime.id))
        }
        Err(error) => {
            let _ = registry.close(runtime.id);
            Err(error)
        }
    }
}

#[allow(clippy::too_many_arguments)]
pub fn start_ssh_live_shell_worker<C, F>(
    registry: &mut TerminalRuntimeRegistry,
    manager: &mut LiveShellManager<C>,
    host: String,
    port: u16,
    username: String,
    cols: u32,
    rows: u32,
    open_channel: F,
) -> Result<LiveShellStatus, SshRuntimeError>
where
    C: ShellChannel,
    F: FnOnce(&TerminalRuntime) -> Result<C, SshRuntimeError>,
{
    let runtime = registry.open_remote_ssh(host, port, username, cols, rows);
    match open_channel(&runtime) {
        Ok(channel) => {
            manager.register(LiveShellWorker::new_with_bootstrap_input(
                runtime.id.clone(),
                channel,
                ssh_osc7_bootstrap_input_chunks().concat(),
            ));
            Ok(LiveShellStatus::running(runtime.id))
        }
        Err(error) => {
            let _ = registry.close(runtime.id);
            Err(error)
        }
    }
}

pub fn ssh_osc7_bootstrap_input_chunks() -> Vec<Vec<u8>> {
    vec![concat!(
            "{ ",
            "__stacio_with_timeout() { __stacio_timeout_seconds=\"$1\"; shift; \"$@\" & __stacio_command_pid=$!; ( sleep \"$__stacio_timeout_seconds\"; kill \"$__stacio_command_pid\" 2>/dev/null ) & __stacio_watchdog_pid=$!; wait \"$__stacio_command_pid\"; __stacio_status=$?; kill \"$__stacio_watchdog_pid\" 2>/dev/null || true; wait \"$__stacio_watchdog_pid\" 2>/dev/null || true; return \"$__stacio_status\"; }; ",
            "__stacio_cached_hostname=\"$(__stacio_with_timeout 1 hostname 2>/dev/null || printf localhost)\"; ",
            "__stacio_report_cwd() { printf '\\033]7;file://%s%s\\033\\\\' \"$__stacio_cached_hostname\" \"$PWD\"; }; ",
            "if [ -n \"${ZSH_VERSION:-}\" ]; then eval 'typeset -ga precmd_functions 2>/dev/null || true; case \" ${precmd_functions[*]-} \" in *\" __stacio_report_cwd \"*) ;; *) precmd_functions+=(__stacio_report_cwd) ;; esac'; fi; ",
            "if [ -n \"${BASH_VERSION:-}\" ]; then case \";${PROMPT_COMMAND:-};\" in *\";__stacio_report_cwd;\"*) ;; *) PROMPT_COMMAND=\"${PROMPT_COMMAND:+${PROMPT_COMMAND%;};}__stacio_report_cwd\" ;; esac; fi; ",
            "} >/dev/null 2>&1; ",
            "__stacio_report_cwd 2>/dev/null || true\n"
        )
    .as_bytes()
    .to_vec()]
}

fn map_channel_io_error(error: io::Error) -> TerminalRuntimeError {
    TerminalRuntimeError::RuntimeIo {
        message: error.to_string(),
    }
}

fn is_transient_channel_io_error(error: &io::Error) -> bool {
    if matches!(
        error.kind(),
        io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted
    ) {
        return true;
    }
    let lowered = error.to_string().to_ascii_lowercase();
    lowered.contains("would block")
        || lowered.contains("operation would block")
        || lowered.contains("session(-37)")
}

#[derive(Debug, Clone)]
pub struct FakeShellChannel {
    written: Vec<u8>,
    read_chunks: Vec<Vec<u8>>,
    pty_resizes: Vec<(u32, u32)>,
    eof_after_poll: bool,
    read_count: usize,
    wait_interest: Option<ShellWaitInterest>,
}

impl FakeShellChannel {
    pub fn new() -> Self {
        Self {
            written: Vec::new(),
            read_chunks: Vec::new(),
            pty_resizes: Vec::new(),
            eof_after_poll: false,
            read_count: 0,
            wait_interest: None,
        }
    }

    pub fn with_read_chunks(mut self, chunks: Vec<Vec<u8>>) -> Self {
        self.read_chunks = chunks;
        self
    }

    pub fn with_eof_after_poll(mut self, eof: bool) -> Self {
        self.eof_after_poll = eof;
        self
    }

    pub fn with_wait_interest(mut self, wait_interest: ShellWaitInterest) -> Self {
        self.wait_interest = Some(wait_interest);
        self
    }

    pub fn written_bytes(&self) -> Vec<u8> {
        self.written.clone()
    }

    pub fn pty_resizes(&self) -> Vec<(u32, u32)> {
        self.pty_resizes.clone()
    }
}

impl ShellChannel for FakeShellChannel {
    fn write_input(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.written.extend_from_slice(bytes);
        Ok(bytes.len())
    }

    fn read_output(&mut self, max_bytes: usize) -> io::Result<Vec<u8>> {
        self.read_count += 1;
        if self.read_chunks.is_empty() {
            return Ok(Vec::new());
        }
        let mut chunk = self.read_chunks.remove(0);
        chunk.truncate(max_bytes);
        Ok(chunk)
    }

    fn resize_pty(&mut self, cols: u32, rows: u32) -> io::Result<()> {
        self.pty_resizes.push((cols, rows));
        Ok(())
    }

    fn close(&mut self) -> io::Result<()> {
        Ok(())
    }

    fn is_eof(&self) -> bool {
        self.eof_after_poll && self.read_count > 0
    }

    fn wait_interest(&self) -> Option<ShellWaitInterest> {
        self.wait_interest
    }

    fn keepalive(&mut self) -> io::Result<()> {
        Ok(())
    }
}

#[cfg(test)]
mod live_shell_tests {
    use super::*;
    use crate::services::terminal_service::TerminalRuntimeRegistry;
    use std::process::{Command, Stdio};
    use std::{
        sync::{Arc, Barrier},
        time::{Duration, Instant},
    };

    #[test]
    fn fake_shell_worker_drains_input_and_records_output() {
        let mut registry = TerminalRuntimeRegistry::new(4096);
        let runtime =
            registry.open_remote_ssh("example.com".to_string(), 22, "deploy".to_string(), 80, 24);
        registry
            .write_input(runtime.id.clone(), b"whoami\n".to_vec())
            .expect("write input");

        let channel = FakeShellChannel::new().with_read_chunks(vec![b"deploy\n".to_vec()]);
        let mut worker = LiveShellWorker::new(runtime.id.clone(), channel);

        let status = worker.poll(&mut registry).expect("poll");
        let output = registry
            .take_output_batch(runtime.id.clone())
            .expect("take output");

        assert_eq!(status.status, "running");
        assert_eq!(worker.channel().written_bytes(), b"whoami\n".to_vec());
        assert_eq!(output.bytes, b"deploy\n".to_vec());
    }

    #[test]
    fn fake_shell_worker_preserves_initial_input_chunk_order_before_user_input() {
        let mut registry = TerminalRuntimeRegistry::new(4096);
        let runtime =
            registry.open_remote_ssh("example.com".to_string(), 22, "deploy".to_string(), 80, 24);
        let channel = FakeShellChannel::new();
        let mut worker = LiveShellWorker::new_with_initial_input_chunks(
            runtime.id.clone(),
            channel,
            vec![b"stty -echo\n".to_vec(), b"install-hook\n".to_vec()],
        );
        registry
            .write_input(runtime.id.clone(), b"cd /srv/app\n".to_vec())
            .expect("write user input");

        worker.poll(&mut registry).expect("poll");
        assert_eq!(worker.channel().written_bytes(), b"stty -echo\n".to_vec());

        worker.poll(&mut registry).expect("second poll");
        assert_eq!(
            worker.channel().written_bytes(),
            b"stty -echo\ninstall-hook\n".to_vec()
        );

        worker.poll(&mut registry).expect("third poll");
        assert_eq!(
            worker.channel().written_bytes(),
            b"stty -echo\ninstall-hook\ncd /srv/app\n".to_vec()
        );
    }

    #[test]
    fn fake_shell_worker_accepts_user_input_in_same_poll_after_bootstrap_write() {
        let mut registry = TerminalRuntimeRegistry::new(4096);
        let runtime =
            registry.open_remote_ssh("example.com".to_string(), 22, "deploy".to_string(), 80, 24);
        let bootstrap = b"install-slow-prompt-hook\n".to_vec();
        let channel = FakeShellChannel::new();
        let mut worker = LiveShellWorker::new_with_bootstrap_input(
            runtime.id.clone(),
            channel,
            bootstrap.clone(),
        );
        registry
            .write_input(runtime.id.clone(), b"pwd\n".to_vec())
            .expect("write user input");

        worker.poll(&mut registry).expect("poll");

        let mut expected = bootstrap;
        expected.extend_from_slice(b"pwd\n");
        assert_eq!(worker.channel().written_bytes(), expected);
    }

    #[test]
    fn fake_shell_worker_flushes_queued_user_input_chunks_one_poll_at_a_time() {
        let mut registry = TerminalRuntimeRegistry::new(4096);
        let runtime =
            registry.open_remote_ssh("example.com".to_string(), 22, "deploy".to_string(), 80, 24);
        let channel = FakeShellChannel::new();
        let mut worker = LiveShellWorker::new(runtime.id.clone(), channel);
        worker.pending_input = b"first\n".to_vec();
        worker.queued_input_chunks.push_back(b"\n".to_vec());
        worker.queued_input_chunks.push_back(b"\n".to_vec());

        worker.poll(&mut registry).expect("poll");
        assert_eq!(worker.channel().written_bytes(), b"first\n".to_vec());

        worker.poll(&mut registry).expect("second poll");
        assert_eq!(worker.channel().written_bytes(), b"first\n\n".to_vec());

        worker.poll(&mut registry).expect("third immediate poll");
        assert_eq!(worker.channel().written_bytes(), b"first\n\n".to_vec());

        std::thread::sleep(RAPID_LINE_SUBMIT_PROMPT_WAIT_TIMEOUT + Duration::from_millis(2));
        worker.poll(&mut registry).expect("third deferred poll");
        assert_eq!(worker.channel().written_bytes(), b"first\n\n\n".to_vec());
    }

    #[test]
    fn fake_shell_worker_waits_for_prompt_before_next_rapid_enter_write() {
        let mut registry = TerminalRuntimeRegistry::new(4096);
        let runtime =
            registry.open_remote_ssh("example.com".to_string(), 22, "deploy".to_string(), 80, 24);
        registry
            .write_input(runtime.id.clone(), b"\n".to_vec())
            .expect("write first enter");
        registry
            .write_input(runtime.id.clone(), b"\n".to_vec())
            .expect("write second enter");
        registry
            .write_input(runtime.id.clone(), b"\n".to_vec())
            .expect("write third enter");
        let channel = FakeShellChannel::new().with_read_chunks(vec![
            b"\r\n\x1b]7;file://example.com/home/deploy\x1b\\deploy@example:~$ ".to_vec(),
        ]);
        let mut worker = LiveShellWorker::new(runtime.id.clone(), channel);

        worker.poll(&mut registry).expect("first poll");
        assert_eq!(worker.channel().written_bytes(), b"\n".to_vec());

        worker.poll(&mut registry).expect("second poll after prompt output");
        assert_eq!(worker.channel().written_bytes(), b"\n\n".to_vec());
    }

    #[test]
    fn fake_shell_worker_times_out_prompt_wait_for_rapid_enter_fallback() {
        let mut registry = TerminalRuntimeRegistry::new(4096);
        let runtime =
            registry.open_remote_ssh("example.com".to_string(), 22, "deploy".to_string(), 80, 24);
        registry
            .write_input(runtime.id.clone(), b"\n".to_vec())
            .expect("write first enter");
        registry
            .write_input(runtime.id.clone(), b"\n".to_vec())
            .expect("write second enter");
        let channel = FakeShellChannel::new();
        let mut worker = LiveShellWorker::new(runtime.id.clone(), channel);

        worker.poll(&mut registry).expect("first poll");
        assert_eq!(worker.channel().written_bytes(), b"\n".to_vec());

        worker.poll(&mut registry).expect("second immediate poll");
        assert_eq!(worker.channel().written_bytes(), b"\n".to_vec());

        std::thread::sleep(RAPID_LINE_SUBMIT_PROMPT_WAIT_TIMEOUT + Duration::from_millis(2));
        worker.poll(&mut registry).expect("second deferred poll");
        assert_eq!(worker.channel().written_bytes(), b"\n\n".to_vec());
    }

    #[test]
    fn fake_shell_worker_ignores_bootstrap_write_failure_and_accepts_user_input() {
        let mut registry = TerminalRuntimeRegistry::new(4096);
        let runtime =
            registry.open_remote_ssh("example.com".to_string(), 22, "deploy".to_string(), 80, 24);
        let channel = ScriptedWriteShellChannel::new(vec![
            Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "bootstrap write timed out",
            )),
            Ok(4),
        ]);
        let mut worker = LiveShellWorker::new_with_bootstrap_input(
            runtime.id.clone(),
            channel,
            b"install-slow-prompt-hook\n".to_vec(),
        );
        registry
            .write_input(runtime.id.clone(), b"pwd\n".to_vec())
            .expect("write user input");

        let status = worker.poll(&mut registry).expect("poll");

        assert_eq!(status.status, "running");
        assert_eq!(worker.channel().written_bytes(), b"pwd\n".to_vec());
    }

    #[test]
    fn start_live_shell_worker_does_not_enqueue_bootstrap_input_by_default() {
        let mut registry = TerminalRuntimeRegistry::new(4096);
        let mut manager = LiveShellManager::new();
        let status = start_live_shell_worker(
            &mut registry,
            &mut manager,
            "example.com".to_string(),
            22,
            "deploy".to_string(),
            80,
            24,
            |_runtime| Ok(FakeShellChannel::new()),
        )
        .expect("start worker");

        manager
            .poll(&mut registry, status.runtime_id.clone())
            .expect("poll worker");

        let worker = manager
            .workers
            .get(&status.runtime_id)
            .expect("worker remains active");
        assert_eq!(worker.channel().written_bytes(), Vec::<u8>::new());
    }

    #[test]
    fn start_ssh_live_shell_worker_enqueues_osc7_bootstrap_by_default() {
        let mut registry = TerminalRuntimeRegistry::new(4096);
        let mut manager = LiveShellManager::new();
        let status = start_ssh_live_shell_worker(
            &mut registry,
            &mut manager,
            "anolis.example.com".to_string(),
            22,
            "deploy".to_string(),
            80,
            24,
            |_runtime| Ok(FakeShellChannel::new()),
        )
        .expect("start ssh worker");

        manager
            .poll(&mut registry, status.runtime_id.clone())
            .expect("poll worker");

        let worker = manager
            .workers
            .get(&status.runtime_id)
            .expect("worker remains active");
        let written = String::from_utf8(worker.channel().written_bytes()).expect("utf8 bootstrap");
        assert!(written.contains("__stacio_report_cwd"));
        assert!(written.contains("PROMPT_COMMAND"));
        assert!(written.contains("precmd_functions"));
    }

    #[test]
    fn ssh_osc7_bootstrap_input_chunks_install_prompt_hooks_without_tty_echo_changes() {
        let chunks = ssh_osc7_bootstrap_input_chunks();
        let bootstrap = String::from_utf8(chunks.concat()).expect("utf8 bootstrap");

        assert_eq!(chunks.len(), 1);
        assert!(String::from_utf8_lossy(&chunks[0]).ends_with('\n'));
        assert!(!String::from_utf8_lossy(&chunks[0])
            .trim_end()
            .contains('\n'));
        assert!(bootstrap.contains("__stacio_report_cwd"));
        assert!(bootstrap.contains("PROMPT_COMMAND"));
        assert!(bootstrap.contains("precmd_functions"));
        assert!(!bootstrap.contains("printf '\\r\\033[K'"));
        assert!(!bootstrap.contains("\\033[K"));
        assert!(!bootstrap.contains("stty echo"));
        assert!(!bootstrap.contains("stty -echo"));
        assert!(!bootstrap.contains("PS1="));
        assert!(!bootstrap.contains("ssh "));
    }

    #[test]
    fn ssh_osc7_bootstrap_wraps_potentially_blocking_commands_with_timeout_fallbacks() {
        let bootstrap =
            String::from_utf8(ssh_osc7_bootstrap_input_chunks().concat()).expect("utf8 bootstrap");

        assert!(bootstrap.contains("hostname 2>/dev/null || printf localhost"));
        assert!(
            bootstrap.contains("timeout 1 hostname")
                || bootstrap.contains("__stacio_with_timeout 1 hostname"),
            "hostname must not be able to block OSC7 bootstrap indefinitely: {bootstrap}"
        );
        assert!(bootstrap.contains("|| true"));
        assert!(bootstrap.contains(">/dev/null 2>&1"));
    }

    #[test]
    fn osc7_bootstrap_echo_filter_outlives_general_initial_input_filter() {
        let installed_at = Instant::now() - INITIAL_INPUT_ECHO_FILTER_TTL - Duration::from_secs(1);
        let bootstrap = ssh_osc7_bootstrap_input_chunks().concat();
        let bootstrap_filters =
            initial_input_echo_filters_for_chunks(std::slice::from_ref(&bootstrap), installed_at);
        let general_filters =
            initial_input_echo_filters_for_chunks(&[b"pwd\n".to_vec()], installed_at);

        assert_eq!(bootstrap_filters.len(), 1);
        assert_eq!(general_filters.len(), 1);
        assert!(bootstrap_filters[0].expires_at > Instant::now());
        assert!(general_filters[0].expires_at <= Instant::now());
        assert!(bootstrap_filters[0].allow_embedded_match);
        assert!(!general_filters[0].allow_embedded_match);
    }

    #[test]
    fn ssh_osc7_bootstrap_input_chunks_are_posix_sh_parseable() {
        let chunks = ssh_osc7_bootstrap_input_chunks();
        let bootstrap = String::from_utf8(chunks.concat()).expect("utf8 bootstrap");
        for shell in ["/bin/sh", "/bin/dash"] {
            if !std::path::Path::new(shell).exists() {
                continue;
            }
            let output = Command::new(shell)
                .arg("-n")
                .stdin(Stdio::piped())
                .stderr(Stdio::piped())
                .spawn()
                .and_then(|mut child| {
                    if let Some(stdin) = child.stdin.as_mut() {
                        use std::io::Write;
                        stdin.write_all(bootstrap.as_bytes())?;
                    }
                    child.wait_with_output()
                })
                .unwrap_or_else(|error| panic!("run {shell} syntax check: {error}"));

            assert!(
                output.status.success(),
                "bootstrap should parse under {shell}: {}",
                String::from_utf8_lossy(&output.stderr)
            );
        }
    }

    #[test]
    fn ssh_osc7_bootstrap_input_chunks_execute_under_common_linux_shells() {
        let chunks = ssh_osc7_bootstrap_input_chunks();
        let bootstrap = String::from_utf8(chunks.concat()).expect("utf8 bootstrap");
        for (shell, args) in [
            ("/bin/dash", vec!["-s"]),
            ("/bin/bash", vec!["--noprofile", "--norc", "-s"]),
            ("/bin/zsh", vec!["-f", "-s"]),
        ] {
            if !std::path::Path::new(shell).exists() {
                continue;
            }
            let output = Command::new(shell)
                .args(args)
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .spawn()
                .and_then(|mut child| {
                    if let Some(stdin) = child.stdin.as_mut() {
                        use std::io::Write;
                        stdin.write_all(bootstrap.as_bytes())?;
                    }
                    child.wait_with_output()
                })
                .unwrap_or_else(|error| panic!("run {shell} bootstrap: {error}"));

            assert!(
                output.status.success(),
                "bootstrap should execute under {shell}: {}",
                String::from_utf8_lossy(&output.stderr)
            );
            let stdout = String::from_utf8_lossy(&output.stdout);
            assert!(
                stdout.contains("\u{1b}]7;file://"),
                "bootstrap should report OSC7 under {shell}: {stdout:?}"
            );
        }
    }

    #[test]
    fn fake_shell_worker_filters_initial_bootstrap_echo_from_visible_output() {
        let mut registry = TerminalRuntimeRegistry::new(4096);
        let runtime = registry.open_remote_ssh(
            "anolis.example.com".to_string(),
            22,
            "deploy".to_string(),
            80,
            24,
        );
        let bootstrap = ssh_osc7_bootstrap_input_chunks()
            .into_iter()
            .next()
            .expect("bootstrap chunk");
        let echoed_bootstrap = bootstrap
            .strip_suffix(b"\n")
            .unwrap_or(bootstrap.as_slice());
        let mut echoed_output = Vec::new();
        echoed_output.extend_from_slice(echoed_bootstrap);
        echoed_output.extend_from_slice(b"\r\n");
        echoed_output.extend_from_slice(b"\x1b]7;file://anolis.example.com/srv/app\x1b\\");
        echoed_output.extend_from_slice(b"deploy@anolis:/srv/app$ ");
        let channel = FakeShellChannel::new().with_read_chunks(vec![echoed_output]);
        let mut worker = LiveShellWorker::new_with_initial_input_chunks(
            runtime.id.clone(),
            channel,
            vec![bootstrap],
        );

        worker.poll(&mut registry).expect("poll");
        let output = registry
            .take_output_batch(runtime.id.clone())
            .expect("take output");
        let visible = String::from_utf8(output.bytes).expect("utf8 output");

        assert!(!visible.contains("__stacio_report_cwd()"));
        assert!(!visible.contains("precmd_functions"));
        assert!(visible.contains("\u{1b}]7;file://anolis.example.com/srv/app\u{1b}\\"));
        assert!(visible.contains("deploy@anolis:/srv/app$ "));
    }

    #[test]
    fn fake_shell_worker_filters_prompt_prefixed_initial_bootstrap_echo_from_visible_output() {
        let mut registry = TerminalRuntimeRegistry::new(4096);
        let runtime = registry.open_remote_ssh(
            "anolis.example.com".to_string(),
            22,
            "deploy".to_string(),
            80,
            24,
        );
        let bootstrap = ssh_osc7_bootstrap_input_chunks()
            .into_iter()
            .next()
            .expect("bootstrap chunk");
        let echoed_bootstrap = bootstrap
            .strip_suffix(b"\n")
            .unwrap_or(bootstrap.as_slice());
        let mut echoed_output = Vec::new();
        echoed_output.extend_from_slice(b"Last login: Tue Jul 7 00:13:13 2026\r\n");
        echoed_output.extend_from_slice(b"root@user:~# ");
        echoed_output.extend_from_slice(echoed_bootstrap);
        echoed_output.extend_from_slice(b"\r\n");
        echoed_output.extend_from_slice(b"\x1b]7;file://anolis.example.com/root\x1b\\");
        echoed_output.extend_from_slice(b"root@user:~# ");
        let channel = FakeShellChannel::new().with_read_chunks(vec![echoed_output]);
        let mut worker =
            LiveShellWorker::new_with_bootstrap_input(runtime.id.clone(), channel, bootstrap);

        worker.poll(&mut registry).expect("poll");
        let output = registry
            .take_output_batch(runtime.id.clone())
            .expect("take output");
        let visible = String::from_utf8(output.bytes).expect("utf8 output");

        assert!(visible.contains("Last login: Tue Jul 7"));
        assert!(!visible.contains("__stacio_with_timeout()"));
        assert!(!visible.contains("__stacio_report_cwd()"));
        assert!(!visible.contains("precmd_functions"));
        assert!(visible.contains("\u{1b}]7;file://anolis.example.com/root\u{1b}\\"));
        assert!(visible.ends_with("root@user:~# "));
    }

    #[test]
    fn fake_shell_worker_filters_ansi_prompt_prefixed_initial_bootstrap_echo_from_visible_output() {
        let mut registry = TerminalRuntimeRegistry::new(4096);
        let runtime = registry.open_remote_ssh(
            "anolis.example.com".to_string(),
            22,
            "deploy".to_string(),
            80,
            24,
        );
        let bootstrap = ssh_osc7_bootstrap_input_chunks()
            .into_iter()
            .next()
            .expect("bootstrap chunk");
        let echoed_bootstrap = bootstrap
            .strip_suffix(b"\n")
            .unwrap_or(bootstrap.as_slice());
        let mut echoed_output = Vec::new();
        echoed_output.extend_from_slice(b"Last login: Tue Jul 7 00:24:49 2026\r\n");
        echoed_output.extend_from_slice(b"\x1b[01;32mroot@user:~#\x1b[00m ");
        echoed_output.extend_from_slice(echoed_bootstrap);
        echoed_output.extend_from_slice(b"\r\n");
        echoed_output.extend_from_slice(b"\x1b]7;file://anolis.example.com/root\x1b\\");
        echoed_output.extend_from_slice(b"root@user:~# ");
        let channel = FakeShellChannel::new().with_read_chunks(vec![echoed_output]);
        let mut worker =
            LiveShellWorker::new_with_bootstrap_input(runtime.id.clone(), channel, bootstrap);

        worker.poll(&mut registry).expect("poll");
        let output = registry
            .take_output_batch(runtime.id.clone())
            .expect("take output");
        let visible = String::from_utf8(output.bytes).expect("utf8 output");

        assert!(visible.contains("Last login: Tue Jul 7"));
        assert!(!visible.contains("__stacio_with_timeout()"));
        assert!(!visible.contains("__stacio_report_cwd()"));
        assert!(!visible.contains("precmd_functions"));
        assert!(visible.contains("\u{1b}]7;file://anolis.example.com/root\u{1b}\\"));
        assert!(visible.ends_with("root@user:~# "));
    }

    #[test]
    fn fake_shell_worker_filters_duplicate_initial_bootstrap_echo_from_visible_output() {
        let mut registry = TerminalRuntimeRegistry::new(4096);
        let runtime = registry.open_remote_ssh(
            "anolis.example.com".to_string(),
            22,
            "deploy".to_string(),
            160,
            40,
        );
        let bootstrap = ssh_osc7_bootstrap_input_chunks()
            .into_iter()
            .next()
            .expect("bootstrap chunk");
        let echoed_bootstrap = bootstrap
            .strip_suffix(b"\n")
            .unwrap_or(bootstrap.as_slice());
        let mut first_echo = Vec::new();
        first_echo.extend_from_slice(echoed_bootstrap);
        first_echo.extend_from_slice(b"\r\n");
        let mut second_echo = Vec::new();
        second_echo.extend_from_slice(b"Last login: Tue Jul 7 01:32:51 2026\r\r\n");
        second_echo.extend_from_slice(b"\x1b[?2004h\x1b]0;root@user: ~\x07root@user:~# ");
        second_echo.extend_from_slice(echoed_bootstrap);
        second_echo.extend_from_slice(b"\r\n");
        second_echo.extend_from_slice(b"\x1b[?2004l\r");
        second_echo.extend_from_slice(b"\x1b]7;file://user/root\x1b\\");
        second_echo.extend_from_slice(b"\r\x1b[K");
        second_echo.extend_from_slice(b"\x1b[?2004h\x1b]0;root@user: ~\x07root@user:~# ");
        let channel = FakeShellChannel::new().with_read_chunks(vec![first_echo, second_echo]);
        let mut worker =
            LiveShellWorker::new_with_bootstrap_input(runtime.id.clone(), channel, bootstrap);

        worker.poll(&mut registry).expect("poll");
        let output = registry
            .take_output_batch(runtime.id.clone())
            .expect("take output");
        let visible = String::from_utf8(output.bytes).expect("utf8 output");

        assert!(visible.contains("Last login: Tue Jul 7"));
        assert!(!visible.contains("__stacio_with_timeout()"));
        assert!(!visible.contains("__stacio_report_cwd()"));
        assert!(!visible.contains("precmd_functions"));
        assert!(!visible.contains("PROMPT_COMMAND"));
        assert!(visible.contains("\u{1b}]7;file://user/root\u{1b}\\"));
        assert!(visible.ends_with("root@user:~# "));
    }

    #[test]
    fn fake_shell_worker_filters_split_initial_bootstrap_echo_from_visible_output() {
        let mut registry = TerminalRuntimeRegistry::new(4096);
        let runtime = registry.open_remote_ssh(
            "anolis.example.com".to_string(),
            22,
            "deploy".to_string(),
            80,
            24,
        );
        let bootstrap = ssh_osc7_bootstrap_input_chunks()
            .into_iter()
            .next()
            .expect("bootstrap chunk");
        let echoed_bootstrap = bootstrap
            .strip_suffix(b"\n")
            .unwrap_or(bootstrap.as_slice());
        let split_at = echoed_bootstrap.len() / 3;
        assert!(split_at > 0);
        let mut second_chunk = echoed_bootstrap[split_at..].to_vec();
        second_chunk.extend_from_slice(b"\r\n");
        second_chunk.extend_from_slice(b"\x1b]7;file://anolis.example.com/srv/app\x1b\\");
        second_chunk.extend_from_slice(b"deploy@anolis:/srv/app$ ");
        let channel = FakeShellChannel::new()
            .with_read_chunks(vec![echoed_bootstrap[..split_at].to_vec(), second_chunk]);
        let mut worker =
            LiveShellWorker::new_with_bootstrap_input(runtime.id.clone(), channel, bootstrap);

        worker.poll(&mut registry).expect("poll");
        let output = registry
            .take_output_batch(runtime.id.clone())
            .expect("take output");
        let visible = String::from_utf8(output.bytes).expect("utf8 output");

        assert!(!visible.contains("__stacio_with_timeout()"));
        assert!(!visible.contains("__stacio_report_cwd()"));
        assert!(!visible.contains("precmd_functions"));
        assert!(visible.contains("\u{1b}]7;file://anolis.example.com/srv/app\u{1b}\\"));
        assert!(visible.contains("deploy@anolis:/srv/app$ "));
    }

    #[test]
    fn fake_shell_worker_only_filters_initial_echo_once() {
        let mut registry = TerminalRuntimeRegistry::new(4096);
        let runtime =
            registry.open_remote_ssh("example.com".to_string(), 22, "deploy".to_string(), 80, 24);
        let initial_input = b"pwd\n".to_vec();
        let channel = FakeShellChannel::new()
            .with_read_chunks(vec![b"pwd\r\n/root\r\n".to_vec(), b"pwd\r\n".to_vec()]);
        let mut worker = LiveShellWorker::new_with_initial_input_chunks(
            runtime.id.clone(),
            channel,
            vec![initial_input],
        );

        worker.poll(&mut registry).expect("poll");
        let output = registry
            .take_output_batch(runtime.id.clone())
            .expect("output");
        assert_eq!(output.bytes, b"/root\r\npwd\r\n".to_vec());
    }

    #[test]
    fn fake_shell_worker_highlights_stacio_input_drop_diagnostic_with_ansi() {
        let mut registry = TerminalRuntimeRegistry::new(128);
        let runtime =
            registry.open_remote_ssh("example.com".to_string(), 22, "deploy".to_string(), 80, 24);
        registry
            .write_input(runtime.id.clone(), vec![b'a'; 200])
            .expect("write input");

        let channel = FakeShellChannel::new();
        let mut worker = LiveShellWorker::new(runtime.id.clone(), channel);

        worker.poll(&mut registry).expect("poll");
        let output = registry
            .take_output_batch(runtime.id.clone())
            .expect("take output");
        let diagnostic = String::from_utf8(output.bytes).expect("utf8 diagnostic");

        assert!(diagnostic.contains("\x1b[1;38;5;214mStacio\x1b[0m"));
        assert!(diagnostic.contains("72 个终端输入字节"));
    }

    #[test]
    fn fake_shell_worker_keeps_unwritten_input_after_partial_write() {
        let mut registry = TerminalRuntimeRegistry::new(4096);
        let runtime =
            registry.open_remote_ssh("example.com".to_string(), 22, "deploy".to_string(), 80, 24);
        registry
            .write_input(runtime.id.clone(), b"abcdef".to_vec())
            .expect("write input");

        let channel = PartialWriteShellChannel::new(vec![3, 0, 3]);
        let mut worker = LiveShellWorker::new(runtime.id.clone(), channel);

        worker.poll(&mut registry).expect("first poll");
        assert_eq!(worker.channel().written_bytes(), b"abc".to_vec());

        worker.poll(&mut registry).expect("second poll");
        assert_eq!(worker.channel().written_bytes(), b"abcdef".to_vec());
    }

    #[test]
    fn fake_shell_worker_keeps_input_after_would_block_write() {
        let mut registry = TerminalRuntimeRegistry::new(4096);
        let runtime =
            registry.open_remote_ssh("example.com".to_string(), 22, "deploy".to_string(), 80, 24);
        registry
            .write_input(runtime.id.clone(), b"pwd\n".to_vec())
            .expect("write input");

        let channel = ScriptedWriteShellChannel::new(vec![
            Err(io::Error::from(io::ErrorKind::WouldBlock)),
            Ok(4),
        ]);
        let mut worker = LiveShellWorker::new(runtime.id.clone(), channel);

        worker.poll(&mut registry).expect("first poll");
        assert!(worker.channel().written_bytes().is_empty());

        worker.poll(&mut registry).expect("second poll");
        assert_eq!(worker.channel().written_bytes(), b"pwd\n".to_vec());
    }

    #[test]
    fn fake_shell_worker_keeps_input_after_libssh2_would_block_message() {
        let mut registry = TerminalRuntimeRegistry::new(4096);
        let runtime =
            registry.open_remote_ssh("example.com".to_string(), 22, "deploy".to_string(), 80, 24);
        registry
            .write_input(runtime.id.clone(), b"pwd\n".to_vec())
            .expect("write input");

        let channel = ScriptedWriteShellChannel::new(vec![
            Err(io::Error::new(
                io::ErrorKind::Other,
                "Session(-37): would block",
            )),
            Ok(4),
        ]);
        let mut worker = LiveShellWorker::new(runtime.id.clone(), channel);

        let first_status = worker.poll(&mut registry).expect("first poll");
        assert_eq!(first_status.status, "running");
        assert!(worker.channel().written_bytes().is_empty());

        let second_status = worker.poll(&mut registry).expect("second poll");
        assert_eq!(second_status.status, "running");
        assert_eq!(worker.channel().written_bytes(), b"pwd\n".to_vec());
    }

    #[test]
    fn fake_shell_worker_drains_all_immediately_available_output() {
        let mut registry = TerminalRuntimeRegistry::new(4096);
        let runtime =
            registry.open_remote_ssh("example.com".to_string(), 22, "deploy".to_string(), 80, 24);
        let channel = FakeShellChannel::new()
            .with_read_chunks(vec![b"first line\n".to_vec(), b"second line\n".to_vec()]);
        let mut worker = LiveShellWorker::new(runtime.id.clone(), channel);

        worker.poll(&mut registry).expect("poll");
        let output = registry
            .take_output_batch(runtime.id.clone())
            .expect("take output");

        assert_eq!(output.bytes, b"first line\nsecond line\n".to_vec());
    }

    #[test]
    fn fake_shell_worker_resizes_pty_once_for_latest_revision() {
        let mut registry = TerminalRuntimeRegistry::new(4096);
        let runtime =
            registry.open_remote_ssh("example.com".to_string(), 22, "deploy".to_string(), 80, 24);
        registry
            .record_resize(runtime.id.clone(), 100, 30)
            .expect("first resize");
        registry
            .record_resize(runtime.id.clone(), 120, 40)
            .expect("second resize");

        let channel = FakeShellChannel::new();
        let mut worker = LiveShellWorker::new(runtime.id.clone(), channel);

        worker.poll(&mut registry).expect("poll");
        worker.poll(&mut registry).expect("second poll");

        assert_eq!(worker.channel().pty_resizes(), vec![(120, 40)]);
    }

    #[test]
    fn fake_shell_worker_marks_runtime_closed_on_eof() {
        let mut registry = TerminalRuntimeRegistry::new(4096);
        let runtime =
            registry.open_remote_ssh("example.com".to_string(), 22, "deploy".to_string(), 80, 24);

        let channel = FakeShellChannel::new().with_eof_after_poll(true);
        let mut worker = LiveShellWorker::new(runtime.id.clone(), channel);

        let status = worker.poll(&mut registry).expect("poll");
        let snapshot = registry
            .runtime_snapshot(runtime.id)
            .expect("runtime snapshot");

        assert_eq!(status.status, "closed");
        assert_eq!(snapshot.status, "closed");
    }

    #[test]
    fn manager_poll_drives_registered_worker_and_records_output() {
        let mut registry = TerminalRuntimeRegistry::new(4096);
        let runtime =
            registry.open_remote_ssh("example.com".to_string(), 22, "deploy".to_string(), 80, 24);
        registry
            .write_input(runtime.id.clone(), b"whoami\n".to_vec())
            .expect("write input");

        let channel = FakeShellChannel::new().with_read_chunks(vec![b"deploy\n".to_vec()]);
        let worker = LiveShellWorker::new(runtime.id.clone(), channel);
        let mut manager = LiveShellManager::new();
        manager.register(worker);

        let status = manager
            .poll(&mut registry, runtime.id.clone())
            .expect("poll worker");
        let output = registry
            .take_output_batch(runtime.id.clone())
            .expect("take output");

        assert_eq!(status, LiveShellStatus::running(runtime.id));
        assert_eq!(output.bytes, b"deploy\n".to_vec());
    }

    #[test]
    fn manager_returns_not_running_for_existing_runtime_without_worker() {
        let mut registry = TerminalRuntimeRegistry::new(4096);
        let runtime =
            registry.open_remote_ssh("example.com".to_string(), 22, "deploy".to_string(), 80, 24);
        let mut manager: LiveShellManager<FakeShellChannel> = LiveShellManager::new();

        let status = manager
            .poll(&mut registry, runtime.id.clone())
            .expect("poll without worker");

        assert_eq!(status, LiveShellStatus::not_running(runtime.id));
    }

    #[test]
    fn manager_removes_worker_when_poll_observes_eof() {
        let mut registry = TerminalRuntimeRegistry::new(4096);
        let runtime =
            registry.open_remote_ssh("example.com".to_string(), 22, "deploy".to_string(), 80, 24);
        let worker = LiveShellWorker::new(
            runtime.id.clone(),
            FakeShellChannel::new().with_eof_after_poll(true),
        );
        let mut manager = LiveShellManager::new();
        manager.register(worker);

        let status = manager
            .poll(&mut registry, runtime.id.clone())
            .expect("poll eof");
        let snapshot = registry
            .runtime_snapshot(runtime.id.clone())
            .expect("runtime snapshot");

        assert_eq!(status.status, "closed");
        assert_eq!(snapshot.status, "closed");
        assert_eq!(manager.active_count(), 0);
    }

    #[test]
    fn manager_close_removes_worker_and_closes_runtime() {
        let mut registry = TerminalRuntimeRegistry::new(4096);
        let runtime =
            registry.open_remote_ssh("example.com".to_string(), 22, "deploy".to_string(), 80, 24);
        let worker = LiveShellWorker::new(runtime.id.clone(), FakeShellChannel::new());
        let mut manager = LiveShellManager::new();
        manager.register(worker);

        let status = manager
            .close(&mut registry, runtime.id.clone())
            .expect("close worker");
        let error = registry
            .write_input(runtime.id.clone(), b"pwd\n".to_vec())
            .expect_err("closed runtime rejects input");

        assert_eq!(status.status, "closed");
        assert_eq!(manager.active_count(), 0);
        assert_eq!(
            error,
            TerminalRuntimeError::RuntimeClosed {
                runtime_id: runtime.id
            }
        );
    }

    #[test]
    fn manager_poll_all_drives_registered_workers_without_runtime_specific_poll() {
        let mut registry = TerminalRuntimeRegistry::new(4096);
        let first = registry.open_remote_ssh(
            "one.example.com".to_string(),
            22,
            "deploy".to_string(),
            80,
            24,
        );
        let second = registry.open_remote_ssh(
            "two.example.com".to_string(),
            22,
            "deploy".to_string(),
            80,
            24,
        );
        let mut manager = LiveShellManager::new();
        manager.register(LiveShellWorker::new(
            first.id.clone(),
            FakeShellChannel::new().with_read_chunks(vec![b"one\n".to_vec()]),
        ));
        manager.register(LiveShellWorker::new(
            second.id.clone(),
            FakeShellChannel::new().with_read_chunks(vec![b"two\n".to_vec()]),
        ));

        let statuses = manager.poll_all(&mut registry).expect("poll all");
        let first_output = registry
            .take_output_batch(first.id.clone())
            .expect("first output");
        let second_output = registry
            .take_output_batch(second.id.clone())
            .expect("second output");

        assert_eq!(statuses.len(), 2);
        assert_eq!(first_output.bytes, b"one\n".to_vec());
        assert_eq!(second_output.bytes, b"two\n".to_vec());
    }

    #[test]
    fn manager_poll_all_removes_workers_closed_by_eof() {
        let mut registry = TerminalRuntimeRegistry::new(4096);
        let runtime =
            registry.open_remote_ssh("example.com".to_string(), 22, "deploy".to_string(), 80, 24);
        let mut manager = LiveShellManager::new();
        manager.register(LiveShellWorker::new(
            runtime.id.clone(),
            FakeShellChannel::new().with_eof_after_poll(true),
        ));

        let statuses = manager.poll_all(&mut registry).expect("poll all");

        assert_eq!(statuses.len(), 1);
        assert_eq!(statuses[0].status, "closed");
        assert_eq!(manager.active_count(), 0);
    }

    #[test]
    fn manager_status_for_runtime_reports_running_without_polling_channel() {
        let mut registry = TerminalRuntimeRegistry::new(4096);
        let runtime =
            registry.open_remote_ssh("example.com".to_string(), 22, "deploy".to_string(), 80, 24);
        let mut manager = LiveShellManager::new();
        manager.register(LiveShellWorker::new(
            runtime.id.clone(),
            KeepaliveCountingShellChannel::new(),
        ));

        let status = manager
            .status_for_runtime(&registry, runtime.id.clone())
            .expect("status");
        let worker = manager
            .workers
            .get(&runtime.id)
            .expect("worker remains registered");

        assert_eq!(status, LiveShellStatus::running(runtime.id));
        assert_eq!(worker.channel().keepalive_count, 0);
    }

    #[test]
    fn pump_signal_wakes_inactive_waiters_without_timeout_polling() {
        let signal = Arc::new(LiveShellPumpSignal::new());
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
        let signal = LiveShellPumpSignal::new();
        let marker = signal.marker();
        let started_at = Instant::now();

        let observed = signal.wait_for_next_tick(marker, true, Duration::from_millis(10));

        assert_eq!(observed, marker);
        assert!(started_at.elapsed() >= Duration::from_millis(10));
    }

    #[test]
    fn manager_exposes_socket_wait_interests_for_registered_workers() {
        let mut registry = TerminalRuntimeRegistry::new(4096);
        let runtime =
            registry.open_remote_ssh("example.com".to_string(), 22, "deploy".to_string(), 80, 24);
        let mut manager = LiveShellManager::new();
        manager.register(LiveShellWorker::new(
            runtime.id,
            FakeShellChannel::new().with_wait_interest(ShellWaitInterest::readable(42)),
        ));

        assert_eq!(
            manager.wait_interests(),
            vec![ShellWaitInterest::readable(42)]
        );
    }

    #[test]
    fn manager_suppresses_socket_wait_interest_while_worker_has_pending_input() {
        let mut registry = TerminalRuntimeRegistry::new(4096);
        let runtime =
            registry.open_remote_ssh("example.com".to_string(), 22, "deploy".to_string(), 80, 24);
        registry
            .write_input(runtime.id.clone(), b"abcdef".to_vec())
            .expect("write input");
        let mut manager = LiveShellManager::new();
        manager.register(LiveShellWorker::new(
            runtime.id.clone(),
            PartialWaitShellChannel::new(vec![3, 0, 3], ShellWaitInterest::readable(42)),
        ));

        manager
            .poll(&mut registry, runtime.id)
            .expect("poll worker");

        assert!(manager.wait_interests().is_empty());
    }

    #[test]
    fn fake_shell_worker_does_not_send_keepalive_on_initial_idle_poll() {
        let mut registry = TerminalRuntimeRegistry::new(4096);
        let runtime =
            registry.open_remote_ssh("example.com".to_string(), 22, "deploy".to_string(), 80, 24);
        let channel = KeepaliveCountingShellChannel::new();
        let mut worker = LiveShellWorker::new(runtime.id.clone(), channel);

        let status = worker.poll(&mut registry).expect("idle poll");

        assert_eq!(status.status, "running");
        assert_eq!(
            worker.channel().keepalive_count,
            0,
            "newly connected SSH shells must not send keepalive before the session has had time to settle"
        );
        assert_eq!(
            registry
                .runtime_snapshot(runtime.id)
                .expect("runtime snapshot")
                .status,
            "running"
        );
    }

    #[test]
    fn fake_shell_worker_sends_keepalive_after_idle_interval() {
        let mut registry = TerminalRuntimeRegistry::new(4096);
        let runtime =
            registry.open_remote_ssh("example.com".to_string(), 22, "deploy".to_string(), 80, 24);
        let channel = KeepaliveCountingShellChannel::new();
        let mut worker = LiveShellWorker::new(runtime.id.clone(), channel);
        worker.last_keepalive_at = Some(Instant::now() - Duration::from_secs(21));

        let status = worker
            .poll(&mut registry)
            .expect("idle poll after interval");

        assert_eq!(status.status, "running");
        assert_eq!(worker.channel().keepalive_count, 1);
    }

    #[test]
    fn fake_shell_worker_does_not_disconnect_when_keepalive_probe_fails() {
        let mut registry = TerminalRuntimeRegistry::new(4096);
        let runtime =
            registry.open_remote_ssh("example.com".to_string(), 22, "deploy".to_string(), 80, 24);
        let channel = KeepaliveFailingShellChannel::new();
        let mut worker = LiveShellWorker::new(runtime.id.clone(), channel);
        worker.last_keepalive_at = Some(Instant::now() - Duration::from_secs(21));

        let status = worker
            .poll(&mut registry)
            .expect("idle poll after keepalive failure");

        assert_eq!(status.status, "running");
        assert_eq!(worker.channel().keepalive_count, 1);
        assert_eq!(
            registry
                .runtime_snapshot(runtime.id)
                .expect("runtime snapshot")
                .status,
            "running"
        );
    }

    #[test]
    fn fake_shell_worker_closes_runtime_after_two_keepalive_failures() {
        let mut registry = TerminalRuntimeRegistry::new(4096);
        let runtime =
            registry.open_remote_ssh("example.com".to_string(), 22, "deploy".to_string(), 80, 24);
        let channel = KeepaliveFailingShellChannel::new();
        let mut worker = LiveShellWorker::new(runtime.id.clone(), channel);

        worker.last_keepalive_at = Some(Instant::now() - Duration::from_secs(31));
        let first_status = worker
            .poll(&mut registry)
            .expect("first idle poll after keepalive failure");
        worker.last_keepalive_at = Some(Instant::now() - Duration::from_secs(31));
        let second_status = worker
            .poll(&mut registry)
            .expect("second idle poll after keepalive failure");

        assert_eq!(first_status.status, "running");
        assert_eq!(second_status.status, "closed");
        assert_eq!(worker.channel().keepalive_count, 2);
        assert_eq!(
            registry
                .runtime_snapshot(runtime.id)
                .expect("runtime snapshot")
                .status,
            "closed"
        );
    }

    #[test]
    fn fake_shell_worker_throttles_keepalive_between_idle_polls() {
        let mut registry = TerminalRuntimeRegistry::new(4096);
        let runtime =
            registry.open_remote_ssh("example.com".to_string(), 22, "deploy".to_string(), 80, 24);
        let channel = KeepaliveCountingShellChannel::new();
        let mut worker = LiveShellWorker::new(runtime.id.clone(), channel);
        worker.last_keepalive_at = Some(Instant::now() - Duration::from_secs(21));

        worker.poll(&mut registry).expect("first idle poll");
        worker
            .poll(&mut registry)
            .expect("second immediate idle poll");

        assert_eq!(
            worker.channel().keepalive_count,
            1,
            "live shell pump can poll repeatedly; SSH keepalive must be interval-gated"
        );
    }

    #[test]
    fn fake_shell_worker_uses_configured_keepalive_interval_and_can_disable_it() {
        let mut registry = TerminalRuntimeRegistry::new(4096);
        let runtime =
            registry.open_remote_ssh("example.com".to_string(), 22, "deploy".to_string(), 80, 24);
        let channel = KeepaliveCountingShellChannel::new();
        let mut worker = LiveShellWorker::new(runtime.id.clone(), channel);
        worker.set_keepalive_interval_seconds(5);
        worker.last_keepalive_at = Some(Instant::now() - Duration::from_secs(6));

        worker.poll(&mut registry).expect("poll after configured interval");
        assert_eq!(worker.channel().keepalive_count, 1);

        worker.set_keepalive_interval_seconds(0);
        worker.last_keepalive_at = Some(Instant::now() - Duration::from_secs(60));
        worker.poll(&mut registry).expect("poll with disabled keepalive");
        assert_eq!(worker.channel().keepalive_count, 1);
    }

    #[test]
    fn start_live_shell_worker_registers_worker_after_opener_success() {
        let mut registry = TerminalRuntimeRegistry::new(4096);
        let mut manager = LiveShellManager::new();

        let status = start_live_shell_worker(
            &mut registry,
            &mut manager,
            "example.com".to_string(),
            22,
            "deploy".to_string(),
            80,
            24,
            |_runtime| Ok(FakeShellChannel::new().with_read_chunks(vec![b"ready\n".to_vec()])),
        )
        .expect("start worker");

        let poll_status = manager
            .poll(&mut registry, status.runtime_id.clone())
            .expect("poll worker");
        let output = registry
            .take_output_batch(status.runtime_id.clone())
            .expect("take output");

        assert_eq!(status.status, "running");
        assert_eq!(poll_status.status, "running");
        assert_eq!(manager.active_count(), 1);
        assert_eq!(output.bytes, b"ready\n".to_vec());
    }

    #[test]
    fn start_live_shell_worker_closes_runtime_after_opener_failure() {
        let mut registry = TerminalRuntimeRegistry::new(4096);
        let mut manager: LiveShellManager<FakeShellChannel> = LiveShellManager::new();

        let error = start_live_shell_worker(
            &mut registry,
            &mut manager,
            "example.com".to_string(),
            22,
            "deploy".to_string(),
            80,
            24,
            |_runtime| {
                Err(crate::domain::ssh::SshRuntimeError::Transport {
                    message: "channel failed".to_string(),
                })
            },
        )
        .expect_err("start fails");

        assert_eq!(
            error,
            crate::domain::ssh::SshRuntimeError::Transport {
                message: "channel failed".to_string(),
            }
        );
        assert_eq!(registry.active_count(), 0);
        assert_eq!(manager.active_count(), 0);
    }

    struct PartialWriteShellChannel {
        write_limits: Vec<usize>,
        written: Vec<u8>,
    }

    impl PartialWriteShellChannel {
        fn new(write_limits: Vec<usize>) -> Self {
            Self {
                write_limits,
                written: Vec::new(),
            }
        }

        fn written_bytes(&self) -> Vec<u8> {
            self.written.clone()
        }
    }

    impl ShellChannel for PartialWriteShellChannel {
        fn write_input(&mut self, bytes: &[u8]) -> io::Result<usize> {
            let limit = self.write_limits.remove(0);
            let count = limit.min(bytes.len());
            self.written.extend_from_slice(&bytes[..count]);
            Ok(count)
        }

        fn read_output(&mut self, _max_bytes: usize) -> io::Result<Vec<u8>> {
            Ok(Vec::new())
        }

        fn resize_pty(&mut self, _cols: u32, _rows: u32) -> io::Result<()> {
            Ok(())
        }

        fn close(&mut self) -> io::Result<()> {
            Ok(())
        }

        fn is_eof(&self) -> bool {
            false
        }
    }

    struct ScriptedWriteShellChannel {
        writes: Vec<io::Result<usize>>,
        written: Vec<u8>,
    }

    impl ScriptedWriteShellChannel {
        fn new(writes: Vec<io::Result<usize>>) -> Self {
            Self {
                writes,
                written: Vec::new(),
            }
        }

        fn written_bytes(&self) -> Vec<u8> {
            self.written.clone()
        }
    }

    impl ShellChannel for ScriptedWriteShellChannel {
        fn write_input(&mut self, bytes: &[u8]) -> io::Result<usize> {
            let result = self.writes.remove(0);
            if let Ok(count) = result {
                let written = count.min(bytes.len());
                self.written.extend_from_slice(&bytes[..written]);
                return Ok(written);
            }
            result
        }

        fn read_output(&mut self, _max_bytes: usize) -> io::Result<Vec<u8>> {
            Ok(Vec::new())
        }

        fn resize_pty(&mut self, _cols: u32, _rows: u32) -> io::Result<()> {
            Ok(())
        }

        fn close(&mut self) -> io::Result<()> {
            Ok(())
        }

        fn is_eof(&self) -> bool {
            false
        }
    }

    struct PartialWaitShellChannel {
        write_limits: Vec<usize>,
        wait_interest: ShellWaitInterest,
    }

    impl PartialWaitShellChannel {
        fn new(write_limits: Vec<usize>, wait_interest: ShellWaitInterest) -> Self {
            Self {
                write_limits,
                wait_interest,
            }
        }
    }

    impl ShellChannel for PartialWaitShellChannel {
        fn write_input(&mut self, bytes: &[u8]) -> io::Result<usize> {
            let limit = self.write_limits.remove(0);
            Ok(limit.min(bytes.len()))
        }

        fn read_output(&mut self, _max_bytes: usize) -> io::Result<Vec<u8>> {
            Ok(Vec::new())
        }

        fn resize_pty(&mut self, _cols: u32, _rows: u32) -> io::Result<()> {
            Ok(())
        }

        fn close(&mut self) -> io::Result<()> {
            Ok(())
        }

        fn is_eof(&self) -> bool {
            false
        }

        fn wait_interest(&self) -> Option<ShellWaitInterest> {
            Some(self.wait_interest)
        }
    }

    struct KeepaliveCountingShellChannel {
        keepalive_count: usize,
    }

    impl KeepaliveCountingShellChannel {
        fn new() -> Self {
            Self { keepalive_count: 0 }
        }
    }

    impl ShellChannel for KeepaliveCountingShellChannel {
        fn write_input(&mut self, _bytes: &[u8]) -> io::Result<usize> {
            Ok(0)
        }

        fn read_output(&mut self, _max_bytes: usize) -> io::Result<Vec<u8>> {
            Ok(Vec::new())
        }

        fn resize_pty(&mut self, _cols: u32, _rows: u32) -> io::Result<()> {
            Ok(())
        }

        fn close(&mut self) -> io::Result<()> {
            Ok(())
        }

        fn is_eof(&self) -> bool {
            false
        }

        fn keepalive(&mut self) -> io::Result<()> {
            self.keepalive_count += 1;
            Ok(())
        }
    }

    struct KeepaliveFailingShellChannel {
        keepalive_count: usize,
    }

    impl KeepaliveFailingShellChannel {
        fn new() -> Self {
            Self { keepalive_count: 0 }
        }
    }

    impl ShellChannel for KeepaliveFailingShellChannel {
        fn write_input(&mut self, _bytes: &[u8]) -> io::Result<usize> {
            Ok(0)
        }

        fn read_output(&mut self, _max_bytes: usize) -> io::Result<Vec<u8>> {
            Ok(Vec::new())
        }

        fn resize_pty(&mut self, _cols: u32, _rows: u32) -> io::Result<()> {
            Ok(())
        }

        fn close(&mut self) -> io::Result<()> {
            Ok(())
        }

        fn is_eof(&self) -> bool {
            false
        }

        fn keepalive(&mut self) -> io::Result<()> {
            self.keepalive_count += 1;
            Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "keepalive probe timed out",
            ))
        }
    }
}
