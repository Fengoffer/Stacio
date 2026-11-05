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
const OSC7_BOOTSTRAP_ECHO_MAX_BYTES: usize = 64 * 1024;
const OSC7_BOOTSTRAP_ECHO_HEADER: &[u8] = b"{ __stacio_with_timeout() { ";
const OSC7_BOOTSTRAP_ECHO_TAIL: &[u8] = b"__stacio_report_cwd 2>/dev/null || true";
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
    bootstrap: Option<BootstrapEchoFilter>,
}

#[derive(Clone, Copy)]
struct BootstrapRenderedByte {
    byte: u8,
    start: usize,
    end: usize,
}

// Expected positions in the known command, not a renderer for remote output.
// Each newly displayed byte must extend the confirmed prefix; a repaint must
// match the command position already assigned to that cell. This deliberately
// supports only the readline/ZLE controls we can verify, and otherwise fails open.
struct BootstrapEchoScreen {
    cells: Vec<Vec<Option<usize>>>,
    column: usize,
    row: usize,
}

impl BootstrapEchoScreen {
    fn delete_lines(&mut self, count: usize) {
        let columns = self.cells[0].len();
        for _ in 0..count.min(self.cells.len() - self.row) {
            self.cells.remove(self.row);
            self.cells.push(vec![None; columns]);
        }
    }

    fn next_row(&mut self) {
        if self.row + 1 == self.cells.len() {
            self.row = 0;
            self.delete_lines(1);
            self.row = self.cells.len() - 1;
        } else {
            self.row += 1;
        }
    }
}

fn bootstrap_csi(bytes: &[u8]) -> Option<(usize, &[u8], u8)> {
    if !bytes.starts_with(b"\x1b[") { return None; }
    let end = bytes.iter().take(64).enumerate().skip(2)
        .find(|(_, byte)| (0x40..=0x7e).contains(*byte))?.0;
    Some((end + 1, &bytes[2..end], bytes[end]))
}

fn bootstrap_wrap_padding(mut bytes: &[u8]) -> bool {
    // Readline/ZLE force a delayed wrap with a space, then immediately erase it.
    while let Some((length, parameters, command)) = bootstrap_csi(bytes) {
        if !matches!(command, b'K' | b'm')
            || !parameters.iter().all(|v| v.is_ascii_digit() || matches!(v, b';' | b':')) {
            return false;
        }
        bytes = &bytes[length..];
    }
    bytes.starts_with(b"\r")
}

fn bootstrap_echo_matches_screen(
    pattern: &[u8], bytes: &[u8], columns: usize, rows: usize, start_column: usize,
) -> bool {
    let mut screen = BootstrapEchoScreen {
        cells: vec![vec![None; columns]; rows], column: start_column, row: 0,
    };
    let mut confirmed: usize = 0;
    let mut cursor = 0;
    let mut marker_padding = false;
    let mut truncated = false;
    let mut viewport_advance = false;
    let mut marker_line_feed = false;
    while cursor < bytes.len() {
        let byte = bytes[cursor];
        if byte == 0x1b {
            let Some((length, parameters, command)) = bootstrap_csi(&bytes[cursor..]) else { return false; };
            cursor += length;
            if command == b'm' {
                if !parameters.iter().all(|v| v.is_ascii_digit() || matches!(v, b';' | b':')) { return false; }
                continue;
            }
            if matches!(command, b'h' | b'l') && matches!(parameters, b"?25" | b"?2004") {
                continue; // Visibility and bracketed-paste modes do not move text.
            }
            let mut parameter = 0usize;
            for &digit in parameters {
                if !digit.is_ascii_digit() { return false; }
                let Some(value) = parameter.checked_mul(10).and_then(|n| n.checked_add((digit - b'0') as usize))
                    else { return false; };
                parameter = value;
            }
            let count = parameter.max(1);
            screen.column = screen.column.min(columns - 1);
            match command {
                b'A' => {
                    // Once ZLE truncates a screenful, it advances the viewport
                    // either with DL or by repainting the following command row.
                    viewport_advance = truncated && screen.row == rows - 1
                        && screen.column == columns - 1 && count == rows - 2
                        && screen.cells[screen.row][columns - 2] == confirmed.checked_sub(1);
                    screen.row = screen.row.saturating_sub(count);
                }
                b'B' => screen.row = screen.row.saturating_add(count).min(rows - 1),
                b'C' => screen.column = screen.column.saturating_add(count).min(columns - 1),
                b'D' => screen.column = screen.column.saturating_sub(count),
                b'M' => {
                    viewport_advance = false;
                    screen.delete_lines(count);
                }
                // EL/DCH do not move the cursor. Keep the target command layout:
                // repainting erased cells still has to match their known offsets.
                b'K' if parameter <= 2 => {}
                b'P' => {}
                _ => return false,
            }
            continue;
        }
        match byte {
            b'\r' => { screen.column = 0; marker_padding = false; }
            b'\n' => {
                // The injected command has one logical line. An early newline
                // is only accounted for by ZLE's explicit truncation repaint.
                if confirmed != pattern.len() && !marker_line_feed { return false; }
                marker_line_feed = false;
                screen.next_row();
                screen.column = screen.column.min(columns - 1);
            }
            b'\x08' => screen.column = screen.column.saturating_sub(1),
            0x20..=0x7e => {
                if !truncated && screen.row == 0 && screen.column == start_column
                    && columns - start_column >= 5
                    && confirmed >= columns * (rows - 1) - start_column
                    && bytes[cursor..].starts_with(b">....") {
                    truncated = true;
                    marker_padding = true;
                    screen.column += 5;
                    cursor += 5;
                    let padding = bytes[cursor..].iter().take_while(|&&b| b == b' ').count();
                    if bytes[cursor + padding..].starts_with(b"\r\n") {
                        // Full repaint variant of ZLE's first viewport advance.
                        screen.row = 1;
                        screen.delete_lines(1);
                        screen.row = 0;
                        marker_line_feed = true;
                    }
                    continue;
                }
                if marker_padding {
                    if byte != b' ' || screen.column >= columns { return false; }
                    screen.column += 1;
                    cursor += 1;
                    continue;
                }
                if viewport_advance {
                    let row = screen.row;
                    screen.row = 1;
                    screen.delete_lines(1);
                    screen.row = row;
                    viewport_advance = false;
                }
                let padding = screen.column == columns && byte == b' '
                    && bootstrap_wrap_padding(&bytes[cursor + 1..]);
                if screen.column == columns { screen.next_row(); screen.column = 0; }
                if screen.column >= columns { return false; }
                if !padding {
                    // Bash can repaint its final full row after a forced wrap.
                    if confirmed == pattern.len() && screen.row > 0 && screen.column == 0
                        && screen.cells[screen.row][0].is_none()
                        && screen.cells[screen.row - 1][columns - 1] == pattern.len().checked_sub(1) {
                        screen.cells[screen.row] = screen.cells[screen.row - 1].clone();
                    }
                    if let Some(expected) = screen.cells[screen.row][screen.column] {
                        if pattern.get(expected) != Some(&byte) { return false; }
                    } else {
                        if pattern.get(confirmed) != Some(&byte) { return false; }
                        screen.cells[screen.row][screen.column] = Some(confirmed);
                        confirmed += 1;
                    }
                }
                screen.column += 1;
            }
            _ => return false,
        }
        cursor += 1;
    }
    confirmed == pattern.len()
}

// Readline/ZLE render the injected line, rather than echoing its bytes verbatim.
// This view is used ONLY to recognize our own bootstrap. Every unconfirmed byte
// is returned unchanged; ANSI/padding are never stripped from normal output.
struct BootstrapEchoFilter {
    pattern: Vec<u8>,
    pending: Vec<u8>,
    rendered: Vec<BootstrapRenderedByte>,
    offset: usize,
    next_offset: usize,
    capturing: bool,
    prefix_checked: bool,
    tail_seen: bool,
    preserved: Vec<(usize, usize)>,
    candidate_start: usize,
    terminal_size: (usize, usize),
    escape: Option<(usize, usize)>,
    after_cr: bool,
    overwritten_start: Option<usize>,
    disabled: bool,
}

impl BootstrapEchoFilter {
    fn new(pattern: Vec<u8>) -> Self {
        Self {
            pattern, pending: Vec::new(), rendered: Vec::new(), offset: 0,
            next_offset: 0, capturing: false, prefix_checked: false, tail_seen: false,
            preserved: Vec::new(), candidate_start: 0, terminal_size: (80, 24),
            escape: None, after_cr: false,
            overwritten_start: None, disabled: false,
        }
    }

    fn finish(&mut self) -> Vec<u8> {
        self.disabled = true;
        self.rendered.clear();
        self.preserved.clear();
        std::mem::take(&mut self.pending)
    }

    fn reset_candidate(&mut self) {
        self.pending.clear();
        self.rendered.clear();
        self.preserved.clear();
        self.offset = self.next_offset;
        self.capturing = false;
        self.candidate_start = self.next_offset;
        self.prefix_checked = false;
        self.tail_seen = false;
        self.overwritten_start = None;
        self.after_cr = false;
    }

    fn ends_with(&self, needle: &[u8]) -> bool {
        self.rendered.len() >= needle.len()
            && self.rendered[self.rendered.len() - needle.len()..].iter()
                .zip(needle).all(|(a, b)| a.byte == *b)
    }

    fn candidate_matches_pattern(&self) -> bool {
        let (columns, rows) = self.terminal_size;
        // Bound both screen storage and attempts to infer an unknown prompt
        // width. Unusual geometries retain the original output unchanged.
        if !(2..=512).contains(&columns) || !(2..=256).contains(&rows)
            || columns * rows > 32 * 1024 { return false; }
        let bytes = &self.pending[self.candidate_start - self.offset..];
        (0..columns).any(|column|
            bootstrap_echo_matches_screen(&self.pattern, bytes, columns, rows, column))
    }

    // Streaming normalization has at most one CSI sequence in flight. The
    // original offsets let us remove a confirmed echo without changing nearby
    // prompts, terminal modes, login banners or OSC7 output.
    fn render_byte(&mut self, byte: u8, position: usize) {
        if let Some((start, length)) = self.escape {
            if length == 1 && byte != b'[' {
                self.escape = None;
                self.rendered.push(BootstrapRenderedByte { byte: 0, start, end: position + 1 });
            } else if length >= 2 && (0x40..=0x7e).contains(&byte) {
                if self.capturing && self.pending.get(start.saturating_sub(self.offset) + 2) == Some(&b'?') {
                    self.preserved.push((start, position + 1));
                }
                self.escape = None;
            } else if length >= 64 {
                self.escape = None;
                self.rendered.push(BootstrapRenderedByte { byte: 0, start, end: position + 1 });
            } else {
                self.escape = Some((start, length + 1));
            }
            return;
        }
        match byte {
            0x1b => self.escape = Some((position, 1)),
            b'\r' => {
                if self.rendered.last().is_some_and(|last| last.byte == b' ') {
                    self.overwritten_start = self.rendered.pop().map(|last| last.start);
                    self.after_cr = false;
                } else {
                    self.after_cr = true;
                }
            }
            b'\x08' => {
                self.overwritten_start = self.rendered.pop().map(|last| last.start);
                self.after_cr = false;
            }
            _ => {
                // ZLE writes the first character of a soft-wrapped line twice:
                // space CR CSI-K character CR character. BS redraws are similar.
                if self.after_cr && byte != b'\n'
                    && self.rendered.last().is_some_and(|last| last.byte == byte) {
                    self.overwritten_start = self.rendered.pop().map(|last| last.start);
                }
                self.rendered.push(BootstrapRenderedByte {
                    byte, start: self.overwritten_start.take().unwrap_or(position), end: position + 1,
                });
                self.after_cr = false;
            }
        }
    }

    // Input queued before readline starts can echo a prefix, then a login
    // banner/prompt, then redraw the input. Remove only long, exact fragments
    // of the known prefix, keeping the intervening non-echo bytes verbatim.
    fn preserve_interrupted_prefix(&mut self, restart_index: usize) {
        let tokens = &self.rendered[..restart_index];
        let restart = self.rendered[restart_index].start;
        let mut cursor = 0;
        let mut expected = 0;
        let mut raw_cursor = self.candidate_start;
        while cursor < tokens.len() && expected < self.pattern.len() {
            let matched = tokens[cursor..].iter().zip(&self.pattern[expected..])
                .take_while(|(token, byte)| token.byte == **byte).count();
            if matched >= OSC7_BOOTSTRAP_ECHO_HEADER.len() {
                let mut start = tokens[cursor].start.max(raw_cursor);
                let end = tokens[cursor + matched - 1].end;
                // Canonical echo fragments are literal. Their first rendered
                // token can inherit preceding prompt padding via CR; prefer
                // the exact bytes so that padding remains part of the prompt.
                if let Some(literal) = find_subsequence(&self.pending[start - self.offset..end - self.offset],
                    &self.pattern[expected..expected + matched]) {
                    start += literal;
                }
                self.preserved.push((raw_cursor, start));
                raw_cursor = tokens[cursor + matched - 1].end;
                expected += matched;
                cursor += matched;
            } else {
                cursor += 1;
            }
        }
        self.preserved.push((raw_cursor, restart));
        self.candidate_start = restart;
        // This is still the same bounded raw candidate. Keep only the restarted
        // match view, so prefix validation is specific to the new echo.
        self.rendered.drain(..restart_index);
        self.prefix_checked = false;
        self.tail_seen = false;
    }

    fn filter(&mut self, bytes: &[u8]) -> Vec<u8> {
        if self.disabled { return bytes.to_vec(); }
        let mut visible = Vec::with_capacity(bytes.len());
        for (index, &byte) in bytes.iter().enumerate() {
            self.pending.push(byte);
            let position = self.next_offset;
            self.next_offset += 1;
            self.render_byte(byte, position);

            if self.pending.len() > OSC7_BOOTSTRAP_ECHO_MAX_BYTES {
                visible.extend(self.finish());
                visible.extend_from_slice(&bytes[index + 1..]);
                return visible;
            }
            if self.ends_with(OSC7_BOOTSTRAP_ECHO_HEADER) {
                let start = self.rendered.len() - OSC7_BOOTSTRAP_ECHO_HEADER.len();
                if self.capturing && start > 0 {
                    self.preserve_interrupted_prefix(start);
                }
                if !self.capturing {
                    self.candidate_start = self.rendered[start].start;
                }
                self.capturing = true;
            }
            if self.capturing {
                // The injected script is ASCII and prints no real OSC until it
                // executes. Do not hold or eat unrelated UTF-8 / early OSC.
                if byte >= 0x80 || self.rendered.last().is_some_and(|token| token.byte == 0) {
                    visible.extend(self.finish());
                    visible.extend_from_slice(&bytes[index + 1..]);
                    return visible;
                }
                if !self.prefix_checked && self.rendered.len() >= 64 {
                    if !self.rendered[..64].iter().zip(&self.pattern).all(|(a,b)| a.byte == *b) {
                        visible.extend(self.finish());
                        visible.extend_from_slice(&bytes[index + 1..]);
                        return visible;
                    }
                    self.prefix_checked = true;
                }
                if self.ends_with(OSC7_BOOTSTRAP_ECHO_TAIL) { self.tail_seen = true; }
                if byte == b'\n' && self.tail_seen {
                    // A short diagnostic that only mentions the function name
                    // cannot authorize discarding arbitrary following output.
                    let evidence = [b"precmd_functions".as_slice(), b"PROMPT_COMMAND".as_slice()]
                        .iter().all(|marker| self.rendered.windows(marker.len())
                            .any(|part| part.iter().zip(*marker).all(|(a,b)| a.byte == *b)));
                    if self.prefix_checked && evidence && self.candidate_matches_pattern() {
                        self.preserved.sort_unstable();
                        let mut cursor = self.offset;
                        for &(start, end) in &self.preserved {
                            let start = start.max(cursor);
                            if end > start {
                                visible.extend_from_slice(&self.pending[start - self.offset..end - self.offset]);
                                cursor = end;
                            }
                        }
                        self.reset_candidate();
                    } else {
                        visible.extend(self.finish());
                        visible.extend_from_slice(&bytes[index + 1..]);
                        return visible;
                    }
                }
                continue;
            }
            // Retain only a possible unique header prefix. This bounds both
            // lookbehind and work per byte, including one-byte SSH reads.
            let mut prefix = (1..OSC7_BOOTSTRAP_ECHO_HEADER.len()).rev().find(|&len|
                self.rendered.len() >= len && self.rendered[self.rendered.len()-len..]
                    .iter().zip(OSC7_BOOTSTRAP_ECHO_HEADER).all(|(a,b)| a.byte == *b));
            // A wrap's padding space may arrive in a separate read before CR.
            // Keep that one provisional byte instead of releasing the header.
            if prefix.is_none() && self.rendered.last().is_some_and(|token| token.byte == b' ') {
                prefix = (1..OSC7_BOOTSTRAP_ECHO_HEADER.len()).rev().find(|&len|
                    self.rendered.len() > len && self.rendered[self.rendered.len()-len-1..self.rendered.len()-1]
                        .iter().zip(OSC7_BOOTSTRAP_ECHO_HEADER).all(|(a,b)| a.byte == *b)).map(|len| len + 1);
            }
            if prefix.is_none() && byte == b'\x08'
                && self.overwritten_start.is_some_and(|start|
                    self.pending.get(start.saturating_sub(self.offset)) == Some(&b'{')) {
                continue;
            }
            let keep = prefix.map(|len| self.rendered[self.rendered.len()-len].start)
                .unwrap_or(self.next_offset);
            let release = keep.saturating_sub(self.offset).min(self.pending.len());
            visible.extend(self.pending.drain(..release));
            self.offset += release;
            let retain_count = prefix.unwrap_or(0);
            self.rendered.drain(..self.rendered.len().saturating_sub(retain_count));
        }
        visible
    }
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
        let restored = self.set_initial_echo_terminal_size(snapshot.cols, snapshot.rows);
        if !restored.is_empty() {
            registry.record_output(self.runtime_id.clone(), restored)?;
        }
        if snapshot.resize_revision != self.observed_resize_revision {
            if let Err(error) = self.channel.resize_pty(snapshot.cols, snapshot.rows) {
                self.record_pending_initial_echo(registry)?;
                return Err(map_channel_io_error(error));
            }
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
        if let Err(error) = self.flush_pending_input() {
            self.record_pending_initial_echo(registry)?;
            return Err(error);
        }

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
            self.record_pending_initial_echo(registry)?;
            self.closed = true;
            let _ = self.channel.close();
            let _ = registry.close(self.runtime_id.clone())?;
            return Ok(self.status("closed", "keepalive_failed"));
        }

        loop {
            let output = match self.channel.read_output(16 * 1024) {
                Ok(output) => output,
                Err(error) => {
                    self.record_pending_initial_echo(registry)?;
                    return Err(map_channel_io_error(error));
                }
            };
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

        let expired_output = self.filter_initial_input_echo(Vec::new());
        if !expired_output.is_empty() {
            registry.record_output(self.runtime_id.clone(), expired_output)?;
        }
        if self.channel.is_eof() {
            self.record_pending_initial_echo(registry)?;
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
        self.record_pending_initial_echo(registry)?;
        self.closed = true;
        let _ = self.channel.close();
        let _ = registry.close(self.runtime_id.clone())?;
        Ok(self.status("closed", "closed"))
    }

    fn record_pending_initial_echo(&mut self, registry: &mut TerminalRuntimeRegistry) -> Result<(), TerminalRuntimeError> {
        let pending = self.finish_initial_input_echo();
        if !pending.is_empty() { registry.record_output(self.runtime_id.clone(), pending)?; }
        Ok(())
    }

    fn set_initial_echo_terminal_size(&mut self, columns: u32, rows: u32) -> Vec<u8> {
        let size = (columns as usize, rows as usize);
        let mut restored = Vec::new();
        for filter in &mut self.initial_input_echo_filters {
            if let Some(bootstrap) = &mut filter.bootstrap {
                if bootstrap.terminal_size != size {
                    // A candidate spanning a resize has two coordinate systems.
                    // Release it before reading more bytes rather than guessing.
                    if !bootstrap.pending.is_empty() { restored.extend(bootstrap.finish()); }
                    bootstrap.terminal_size = size;
                }
            }
        }
        restored
    }

    fn finish_initial_input_echo(&mut self) -> Vec<u8> {
        let mut pending = Vec::new();
        for mut filter in self.initial_input_echo_filters.drain(..) {
            if let Some(bootstrap) = &mut filter.bootstrap { pending.extend(bootstrap.finish()); }
            pending.extend(filter.buffered_prefix);
        }
        pending
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
        if self.initial_input_echo_filters.is_empty() {
            return output;
        }

        let now = Instant::now();
        let mut visible = output;
        let mut retained_filters = Vec::with_capacity(self.initial_input_echo_filters.len());
        for mut filter in self.initial_input_echo_filters.drain(..) {
            if filter.expires_at <= now {
                if let Some(bootstrap) = &mut filter.bootstrap {
                    let mut restored = bootstrap.finish();
                    restored.extend_from_slice(&visible);
                    visible = restored;
                }
                if !filter.buffered_prefix.is_empty() {
                    let mut restored = std::mem::take(&mut filter.buffered_prefix);
                    restored.extend_from_slice(&visible);
                    visible = restored;
                }
                continue;
            }

            if let Some(bootstrap) = &mut filter.bootstrap {
                visible = bootstrap.filter(&visible);
                if !bootstrap.disabled { retained_filters.push(filter); }
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
                bootstrap: allow_embedded_match.then(|| BootstrapEchoFilter::new(pattern.clone())),
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
    pattern.starts_with(OSC7_BOOTSTRAP_ECHO_HEADER)
        && pattern.ends_with(OSC7_BOOTSTRAP_ECHO_TAIL)
        && find_subsequence(pattern, b"__stacio_with_timeout").is_some()
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
        self.workers
            .values()
            .any(LiveShellWorker::has_pending_input)
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

const STACIO_LS_COLOR_DEFAULTS: &str = concat!(
    "fi=38;5;252:di=01;38;5;75:ln=01;38;5;44:so=01;38;5;203:pi=01;38;5;179:",
    "ex=01;38;5;113:bd=01;38;5;221:cd=01;38;5;221:su=37;41:",
    "sg=30;43:tw=30;42:ow=34;42:st=37;44:or=37;41:mi=37;41:",
    "*.swift=38;5;214:*.rs=38;5;208:*.go=38;5;81:*.js=38;5;221:",
    "*.ts=38;5;75:*.tsx=38;5;75:*.json=38;5;179:*.yml=38;5;179:",
    "*.yaml=38;5;179:*.toml=38;5;179:*.md=38;5;183:*.sh=38;5;113:",
    "Dockerfile=38;5;75:*Dockerfile=38;5;75:*Dockerfile.*=38;5;75:",
    "dockerfile=38;5;75:*dockerfile=38;5;75:*dockerfile.*=38;5;75:",
    "Containerfile=38;5;75:*Containerfile=38;5;75:*Containerfile.*=38;5;75:",
    "containerfile=38;5;75:*containerfile=38;5;75:*containerfile.*=38;5;75:",
    ".dockerignore=38;5;244:*.dockerignore=38;5;244:",
    "docker-compose.yml=38;5;179:*docker-compose.yml=38;5;179:",
    "*docker-compose*.yml=38;5;179:docker-compose.yaml=38;5;179:",
    "*docker-compose.yaml=38;5;179:*docker-compose*.yaml=38;5;179:",
    "compose.yml=38;5;179:*compose.yml=38;5;179:*compose*.yml=38;5;179:",
    "compose.yaml=38;5;179:*compose.yaml=38;5;179:*compose*.yaml=38;5;179:",
    "compose.override.yml=38;5;179:*compose.override*.yml=38;5;179:",
    "compose.override.yaml=38;5;179:*compose.override*.yaml=38;5;179:",
    "compose.prod.yml=38;5;179:*compose.prod*.yml=38;5;179:",
    "compose.prod.yaml=38;5;179:*compose.prod*.yaml=38;5;179:",
    "compose.dev.yml=38;5;179:*compose.dev*.yml=38;5;179:",
    "compose.dev.yaml=38;5;179:*compose.dev*.yaml=38;5;179:",
    "compose.staging.yml=38;5;179:*compose.staging*.yml=38;5;179:",
    "compose.staging.yaml=38;5;179:*compose.staging*.yaml=38;5;179:",
    "docker-bake.hcl=38;5;179:*docker-bake*.hcl=38;5;179:buildkitd.toml=38;5;179:",
    "daemon.json=38;5;179:containers.conf=38;5;179:registries.conf=38;5;179:",
    "*.dockerfile=38;5;75:*.containerfile=38;5;75:*.oci=38;5;203:",
    "*.tf=38;5;141:*.tfvars=38;5;141:*.env=38;5;108:.env.*=38;5;108:",
    "*.service=38;5;110:*.timer=38;5;110:*.socket=38;5;110:",
    "*.mount=38;5;110:*.target=38;5;110:nginx.conf=38;5;110:*nginx.conf=38;5;110:*.nginx=38;5;110:",
    "*.kubeconfig=38;5;75:Chart.yaml=38;5;179:*Chart.yaml=38;5;179:",
    "values.yaml=38;5;179:*values.yaml=38;5;179:kustomization.yaml=38;5;179:",
    "kustomization.yml=38;5;179:sources.list=38;5;179:*.sources=38;5;179:",
    "Jenkinsfile=38;5;214:*Jenkinsfile=38;5;214:Vagrantfile=38;5;141:*Vagrantfile=38;5;141:",
    ".envrc=38;5;108:*.repo=38;5;179:*.py=38;5;108:",
    "*.log=38;5;244:*.pem=38;5;221:*.crt=38;5;221:*.cer=38;5;221:*.key=38;5;203:",
    "*.zip=38;5;203:*.tar=38;5;203:*.gz=38;5;203"
);

pub fn ssh_osc7_bootstrap_input_chunks() -> Vec<Vec<u8>> {
    vec![[
            "{ ",
            "__stacio_with_timeout() { __stacio_timeout_seconds=\"$1\"; shift; \"$@\" & __stacio_command_pid=$! ; ( sleep \"$__stacio_timeout_seconds\"; kill \"$__stacio_command_pid\" 2>/dev/null ) & __stacio_watchdog_pid=$! ; wait \"$__stacio_command_pid\"; __stacio_status=$?; kill \"$__stacio_watchdog_pid\" 2>/dev/null || true; wait \"$__stacio_watchdog_pid\" 2>/dev/null || true; return \"$__stacio_status\"; }; ",
            "__stacio_cached_hostname=\"$(__stacio_with_timeout 1 hostname 2>/dev/null || printf localhost)\"; ",
            "__stacio_report_cwd() { printf '\\033]7;file://%s%s\\033\\\\' \"$__stacio_cached_hostname\" \"$PWD\"; }; ",
            "if [ -n \"${ZSH_VERSION:-}\" ]; then eval 'typeset -ga precmd_functions 2>/dev/null || true; case \" ${precmd_functions[*]-} \" in *\" __stacio_report_cwd \"*) ;; *) precmd_functions+=(__stacio_report_cwd) ;; esac'; fi; ",
            "if [ -n \"${BASH_VERSION:-}\" ]; then case \";${PROMPT_COMMAND:-};\" in *\";__stacio_report_cwd;\"*) ;; *) PROMPT_COMMAND=\"${PROMPT_COMMAND:+${PROMPT_COMMAND%;};}__stacio_report_cwd\" ;; esac; fi; ",
            "if [ -z \"${NO_COLOR:-}\" ]; then if [ -z \"${LS_COLORS+x}\" ]; then export LS_COLORS='",
            STACIO_LS_COLOR_DEFAULTS,
            "'; fi; if [ -z \"${LSCOLORS+x}\" ]; then export LSCOLORS='ExFxBxDxCxegedabagacad'; fi; if ! alias ls >/dev/null 2>&1; then if ls --color=auto -d . >/dev/null 2>&1; then alias ls='ls --color=auto'; elif ls --color -d . >/dev/null 2>&1; then alias ls='ls --color'; fi; fi; fi; ",
            "} >/dev/null 2>&1; ",
            "__stacio_report_cwd 2>/dev/null || true\n"
        ]
        .concat()
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
    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt;
    use std::{
        fs,
        process::{Command, Stdio},
    };
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

        worker
            .poll(&mut registry)
            .expect("second poll after prompt output");
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
    fn linux_ls_bootstrap_covers_gnu_busybox_and_unsupported_capabilities() {
        let bootstrap =
            String::from_utf8(ssh_osc7_bootstrap_input_chunks().concat()).expect("utf8 bootstrap");
        assert!(
            bootstrap.starts_with("{ "),
            "bootstrap prefix: {bootstrap:?}"
        );
        assert!(bootstrap.contains("ls --color=auto -d ."));
        assert!(bootstrap.contains("ls --color -d ."));
        assert!(bootstrap.contains("alias ls >/dev/null 2>&1"));
        assert!(bootstrap.contains("${NO_COLOR:-}"));
        assert!(bootstrap.contains("${LS_COLORS+x}"));
        for mapping in ["fi=", "di=", "ex=", "ln=", "so=", "pi=", "bd=", "cd="] {
            assert!(bootstrap.contains(mapping), "missing ls mapping {mapping}");
        }
        for mapping in [
            "dockerfile=",
            "*dockerfile=",
            "compose.override.yml=",
            "compose.prod.yaml=",
            "daemon.json=",
            "Jenkinsfile=",
            "Vagrantfile=",
            ".envrc=",
            "*.repo=",
            "kustomization.yaml=",
            "sources.list=",
            "*.cer=",
        ] {
            assert!(
                bootstrap.contains(mapping),
                "missing extension mapping {mapping}"
            );
        }
    }

    #[cfg(unix)]
    #[test]
    fn linux_ls_bootstrap_selects_gnu_busybox_flag_and_skips_unsupported_ls() {
        let bootstrap =
            String::from_utf8(ssh_osc7_bootstrap_input_chunks().concat()).expect("utf8 bootstrap");
        for (name, script, expected_alias) in [
            (
                "gnu",
                "case \"$1\" in --color=auto) exit 0;; *) exit 1;; esac",
                "ls='ls --color=auto'",
            ),
            (
                "busybox",
                "case \"$1\" in --color=auto) exit 1;; --color) exit 0;; *) exit 1;; esac",
                "ls='ls --color'",
            ),
            ("unsupported", "exit 1", ""),
        ] {
            let temp = tempfile::tempdir().expect("temp dir");
            let ls_path = temp.path().join("ls");
            fs::write(&ls_path, format!("#!/bin/sh\n{}\n", script)).expect("fake ls");
            fs::set_permissions(&ls_path, fs::Permissions::from_mode(0o755))
                .expect("executable fake ls");
            let output = Command::new("/bin/sh")
                .arg("-c")
                .arg(format!("{}alias ls 2>/dev/null || true", bootstrap))
                .env("PATH", format!("{}:/bin:/usr/bin", temp.path().display()))
                .env_remove("NO_COLOR")
                .env_remove("LS_COLORS")
                .env_remove("LSCOLORS")
                .output()
                .expect("run bootstrap");
            assert!(output.status.success(), "{name}: bootstrap failed");
            let stdout = String::from_utf8_lossy(&output.stdout);
            if expected_alias.is_empty() {
                assert!(
                    !stdout.contains("ls='ls --color"),
                    "{name}: unexpected alias {stdout:?}"
                );
            } else {
                assert!(
                    stdout.contains(expected_alias),
                    "{name}: expected alias {expected_alias:?}, got {stdout:?}"
                );
            }
        }

        let output = Command::new("/bin/sh")
            .arg("-c")
            .arg(format!(
                "alias ls='ls -F'; {}alias ls 2>/dev/null || true",
                bootstrap
            ))
            .env_remove("NO_COLOR")
            .env_remove("LS_COLORS")
            .env_remove("LSCOLORS")
            .output()
            .expect("run existing alias bootstrap");
        assert!(output.status.success(), "existing alias bootstrap failed");
        assert!(
            String::from_utf8_lossy(&output.stdout).contains("ls='ls -F'"),
            "existing ls alias was changed: {:?}",
            String::from_utf8_lossy(&output.stdout)
        );
    }

    #[cfg(unix)]
    #[test]
    fn linux_ls_bootstrap_preserves_ansi_from_color_capable_ls() {
        let bootstrap =
            String::from_utf8(ssh_osc7_bootstrap_input_chunks().concat()).expect("utf8 bootstrap");
        let temp = tempfile::tempdir().expect("temp dir");
        let ls_path = temp.path().join("ls");
        fs::write(
            &ls_path,
            "#!/bin/sh\ncase \"$1\" in --color=auto) printf '\\033[01;32mansi\\033[0m\\n'; exit 0;; *) exit 1;; esac\n",
        )
        .expect("fake color ls");
        fs::set_permissions(&ls_path, fs::Permissions::from_mode(0o755))
            .expect("executable fake color ls");

        let output = Command::new("/bin/sh")
            .arg("-c")
            .arg(format!("{}eval 'ls -d .'", bootstrap))
            .env("PATH", format!("{}:/bin:/usr/bin", temp.path().display()))
            .env_remove("NO_COLOR")
            .env_remove("LS_COLORS")
            .env_remove("LSCOLORS")
            .output()
            .expect("run color ls bootstrap");
        assert!(
            output.status.success(),
            "color ls bootstrap failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        assert!(
            String::from_utf8_lossy(&output.stdout).contains("\u{1b}[01;32mansi\u{1b}[0m"),
            "ANSI output was not preserved: {:?}",
            String::from_utf8_lossy(&output.stdout)
        );
    }

    #[test]
    fn linux_ls_bootstrap_preserves_existing_ls_colors_and_no_color() {
        let bootstrap =
            String::from_utf8(ssh_osc7_bootstrap_input_chunks().concat()).expect("utf8 bootstrap");
        let output = Command::new("/bin/sh")
            .arg("-c")
            .arg(format!(
                "{}printf 'LS=%s\\nBSD=%s\\nNO=%s\\n' \"$LS_COLORS\" \"$LSCOLORS\" \"$NO_COLOR\"",
                bootstrap
            ))
            .env("LS_COLORS", "di=31:*.user=32")
            .env("LSCOLORS", "Gxfxcxdx")
            .env("NO_COLOR", "1")
            .output()
            .expect("run bootstrap");
        assert!(
            output.status.success(),
            "bootstrap failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(stdout.contains("LS=di=31:*.user=32"));
        assert!(stdout.contains("BSD=Gxfxcxdx"));
        assert!(stdout.contains("NO=1"));
    }

    #[test]
    fn linux_ls_bootstrap_safely_degrades_when_capability_detection_fails() {
        let bootstrap =
            String::from_utf8(ssh_osc7_bootstrap_input_chunks().concat()).expect("utf8 bootstrap");
        let output = Command::new("/bin/sh")
            .arg("-c")
            .arg(format!(
                "{}printf 'LS=%s\\nALIAS=' \"${{LS_COLORS+x}}\"; alias ls 2>/dev/null || true",
                bootstrap
            ))
            .env("PATH", "/nonexistent")
            .env_remove("LS_COLORS")
            .env_remove("LSCOLORS")
            .env_remove("NO_COLOR")
            .output()
            .expect("run bootstrap");
        assert!(
            output.status.success(),
            "bootstrap failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(stdout.contains("LS=x"), "bootstrap output: {stdout:?}");
        assert!(!stdout.contains("alias ls='ls --color"));
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
    fn bootstrap_echo_filters_real_readline_zle_captures_with_byte_sized_reads() {
        fn decode_hex(hex: &str) -> Vec<u8> {
            hex.as_bytes().chunks_exact(2).map(|pair| {
                u8::from_str_radix(std::str::from_utf8(pair).unwrap(), 16).unwrap()
            }).collect()
        }
        let bootstrap = include_bytes!("../../tests/fixtures/ssh-bootstrap/bootstrap.txt").to_vec();
        let pattern = trim_ascii_line_ending(&bootstrap);
        for line in include_str!("../../tests/fixtures/ssh-bootstrap/readline-zle.hex").lines() {
            let fields: Vec<_> = line.split('\t').collect();
            let raw = decode_hex(fields[1]);
            let expected = decode_hex(fields[2]);
            assert!(find_subsequence(&raw, pattern).is_none(), "{} must exercise the old exact-match failure", fields[0]);
            for chunk_size in [1, 7, 128, 16 * 1024] {
                let mut worker = LiveShellWorker::new_with_bootstrap_input("fixture".into(), FakeShellChannel::new(), bootstrap.clone());
                let columns = fields[0].split('_').nth(1).unwrap().parse().unwrap();
                assert!(worker.set_initial_echo_terminal_size(columns, 24).is_empty());
                let mut visible = Vec::new();
                for chunk in raw.chunks(chunk_size) {
                    visible.extend(worker.filter_initial_input_echo(chunk.to_vec()));
                }
                visible.extend(worker.finish_initial_input_echo());
                assert_eq!(visible, expected, "{} chunk_size={chunk_size}", fields[0]);
            }
        }
    }

    #[test]
    fn bootstrap_echo_preserves_no_echo_user_output_and_near_matches() {
        let bootstrap = ssh_osc7_bootstrap_input_chunks().concat();
        for ordinary in [
            b"Last login: today\r\n\x1b]7;file://host/srv\x1b\\\x1b[?2004huser@host$ echo hello\r\nhello\r\nuser@host$ ".as_slice(),
            b"debug __stacio_with_timeout: unavailable\r\nPROMPT_COMMAND remains unchanged\r\n",
            b"{ __stacio_with_timeout() { ordinary user diagnostic\r\nhello\r\n",
            b"{ __stacio_with_timeout() { __stacio_report_cwd 2>/dev/null || true\r\n",
            b"{ \x1b[31mnot our command\r\n}\r\n",
        ] {
            let mut worker = LiveShellWorker::new_with_bootstrap_input("fixture".into(), FakeShellChannel::new(), bootstrap.clone());
            let mut visible = Vec::new();
            for byte in ordinary.chunks(1) { visible.extend(worker.filter_initial_input_echo(byte.to_vec())); }
            visible.extend(worker.finish_initial_input_echo());
            assert_eq!(visible, ordinary);
        }
        // Generic initial-input filtering must remain exact, not inherit the
        // bootstrap's interpretation of padding/CSI/backspace rendering.
        let mut worker = LiveShellWorker::new_with_initial_input_chunks("fixture".into(), FakeShellChannel::new(), vec![b"pwd\n".to_vec()]);
        let ordinary = b"p \rwd\r\n/srv\r\n";
        assert_eq!(worker.filter_initial_input_echo(ordinary.to_vec()), ordinary);
    }

    #[test]
    fn bootstrap_echo_fails_open_for_interleaved_banner_osc_and_edited_lines() {
        let bootstrap = ssh_osc7_bootstrap_input_chunks().concat();
        for inserted in [
            b"\r\nIMPORTANT LOGIN MESSAGE\r\n".as_slice(),
            "\r\n服务器登录提示\r\n".as_bytes(),
            b"\x1b]7;file://host/real-user-output\x1b\\",
            b"\n\x08\x08\n",
        ] {
            let mut input = bootstrap[..128].to_vec();
            input.extend_from_slice(inserted);
            input.extend_from_slice(&bootstrap[128..]);
            input.extend_from_slice(b"prompt$ ");
            for chunk_size in [1, 17, 16 * 1024] {
                let mut worker = LiveShellWorker::new_with_bootstrap_input("fixture".into(), FakeShellChannel::new(), bootstrap.clone());
                let mut visible = Vec::new();
                for chunk in input.chunks(chunk_size) { visible.extend(worker.filter_initial_input_echo(chunk.to_vec())); }
                visible.extend(worker.finish_initial_input_echo());
                assert_eq!(visible, input, "interleaved {:?}, chunk_size={chunk_size}", inserted);
            }
        }
    }

    #[test]
    fn bootstrap_echo_preserves_diagnostics_inside_cursor_redraws() {
        let bootstrap = ssh_osc7_bootstrap_input_chunks().concat();
        for control in [b'A', b'B', b'C', b'D', b'M', b'P'] {
            for on_separate_line in [false, true] {
                let mut input = bootstrap[..128].to_vec();
                if on_separate_line { input.extend_from_slice(b"\r\n"); }
                input.extend_from_slice(&[0x1b, b'[', b'1', control]);
                input.extend_from_slice(b"IMPORTANT LOGIN MESSAGE\r\n");
                input.extend_from_slice(&bootstrap[128..]);
                input.extend_from_slice(b"prompt$ ");
                for chunk_size in [1, 17, 16 * 1024] {
                    let mut worker = LiveShellWorker::new_with_bootstrap_input(
                        "fixture".into(), FakeShellChannel::new(), bootstrap.clone());
                    let mut visible = Vec::new();
                    for chunk in input.chunks(chunk_size) {
                        visible.extend(worker.filter_initial_input_echo(chunk.to_vec()));
                    }
                    visible.extend(worker.finish_initial_input_echo());
                    assert_eq!(visible, input,
                        "CSI {}, separate_line={on_separate_line}, chunk_size={chunk_size}", control as char);
                }
            }
        }
    }

    #[test]
    fn bootstrap_echo_preserves_styled_diagnostics_inside_cursor_redraws() {
        let bootstrap = ssh_osc7_bootstrap_input_chunks().concat();
        // Every separately styled word appears in our script; their combined
        // visible text does not. Styles must not turn them into echo evidence.
        for diagnostic in [
            b"command \x1b[31mtimeout\x1b[0m".as_slice(),
            b"hostname\x1b[0m: \x1b[1mtimeout\x1b[22m",
            b"command\x1b[38;2;255;0;0m \x1b[0mtimeout",
            b"command \x1b[38:2::255:0:0mtimeout\x1b[m",
        ] {
            for control in [b'A', b'B', b'C', b'D', b'M', b'P'] {
                for separate_line in [false, true] {
                    let mut input = bootstrap[..128].to_vec();
                    if separate_line { input.extend_from_slice(b"\r\n"); }
                    input.extend_from_slice(&[0x1b, b'[', b'1', control]);
                    input.extend_from_slice(diagnostic);
                    input.extend_from_slice(b"\r\n");
                    input.extend_from_slice(&bootstrap[128..]);
                    input.extend_from_slice(b"prompt$ ");
                    for chunk_size in [1, 17, 16 * 1024] {
                        let mut worker = LiveShellWorker::new_with_bootstrap_input(
                            "fixture".into(), FakeShellChannel::new(), bootstrap.clone());
                        let mut visible = Vec::new();
                        for chunk in input.chunks(chunk_size) {
                            visible.extend(worker.filter_initial_input_echo(chunk.to_vec()));
                        }
                        visible.extend(worker.finish_initial_input_echo());
                        assert_eq!(visible, input,
                            "diagnostic={diagnostic:?}, CSI {}, separate_line={separate_line}, chunk_size={chunk_size}", control as char);
                    }
                }
            }
        }
    }

    #[test]
    fn bootstrap_echo_preserves_diagnostics_split_by_terminal_controls() {
        let bootstrap = ssh_osc7_bootstrap_input_chunks().concat();
        for diagnostic in [
            b"command\x1b[1Ctimeout".as_slice(),
            b"\x1b[1Dcommand \x1b[Ktimeout",
            b"\x1b[1Dcommand \x1b[?25l\x1b[31mtimeout\x1b[0m\x1b[?25h",
            b"command \x1b[0Ktimeout",
            b"command \x1b[2Ktimeout",
            b"command \x1b[?25ltimeout\x1b[?25h",
            b"command \x1b[1Ptimeout",
            b"command \x1b[1Atimeout",
            b"command \x1b[1Btimeout",
            b"command \x1b[1Mtimeout",
            b"command \rtimeout",
            b"command \x08timeout",
            b"command\r\ntimeout",
            b"command", // Even a whole script word is not evidence at this position.
        ] {
            for separate_line in [false, true] {
                let mut input = bootstrap[..128].to_vec();
                if separate_line { input.extend_from_slice(b"\r\n"); }
                input.extend_from_slice(diagnostic);
                input.extend_from_slice(b"\r\n");
                input.extend_from_slice(&bootstrap[128..]);
                input.extend_from_slice(b"prompt$ ");
                for chunk_size in [1, 17, 16 * 1024] {
                    let mut worker = LiveShellWorker::new_with_bootstrap_input(
                        "fixture".into(), FakeShellChannel::new(), bootstrap.clone());
                    let mut visible = Vec::new();
                    for chunk in input.chunks(chunk_size) {
                        visible.extend(worker.filter_initial_input_echo(chunk.to_vec()));
                    }
                    visible.extend(worker.finish_initial_input_echo());
                    assert_eq!(visible, input,
                        "diagnostic={diagnostic:?}, separate_line={separate_line}, chunk_size={chunk_size}");
                }
            }
        }
    }

    #[test]
    fn bootstrap_echo_checks_cursor_counts_and_keeps_terminal_modes() {
        let bootstrap = ssh_osc7_bootstrap_input_chunks().concat();
        for backward in [3, 4, 5] {
            let mut input = bootstrap[..128].to_vec();
            input.extend_from_slice(format!("\x1b[{backward}D\x1b[?25l\x1b[31m").as_bytes());
            input.extend_from_slice(&bootstrap[123..128]);
            input.extend_from_slice(b"\x1b[0m\x1b[?25h\x1b[5D\x1b[5C\x1b[K");
            input.extend_from_slice(&bootstrap[128..]);
            input.extend_from_slice(b"prompt$ ");
            for chunk_size in [1, 17, 16 * 1024] {
                let mut worker = LiveShellWorker::new_with_bootstrap_input(
                    "fixture".into(), FakeShellChannel::new(), bootstrap.clone());
                let mut visible = Vec::new();
                for chunk in input.chunks(chunk_size) {
                    visible.extend(worker.filter_initial_input_echo(chunk.to_vec()));
                }
                visible.extend(worker.finish_initial_input_echo());
                let expected = if backward == 5 { b"\x1b[?25l\x1b[?25hprompt$ ".as_slice() } else { &input };
                assert_eq!(visible, expected, "backward={backward}, chunk_size={chunk_size}");
            }
        }
    }

    #[test]
    fn bootstrap_echo_uses_runtime_geometry_and_releases_on_resize() {
        let bootstrap = include_bytes!("../../tests/fixtures/ssh-bootstrap/bootstrap.txt").to_vec();
        for line in include_str!("../../tests/fixtures/ssh-bootstrap/readline-zle.hex").lines() {
            let fields: Vec<_> = line.split('\t').collect();
            let decode = |hex: &str| -> Vec<u8> {
                hex.as_bytes().chunks_exact(2).map(|pair|
                    u8::from_str_radix(std::str::from_utf8(pair).unwrap(), 16).unwrap()).collect()
            };
            let raw = decode(fields[1]);
            let columns = fields[0].split('_').nth(1).unwrap().parse().unwrap();
            let mut registry = TerminalRuntimeRegistry::new(64 * 1024);
            let runtime = registry.open_remote_ssh("host".into(), 22, "user".into(), columns, 24);
            let channel = FakeShellChannel::new().with_read_chunks(raw.chunks(17).map(|v| v.to_vec()).collect());
            let mut worker = LiveShellWorker::new_with_bootstrap_input(runtime.id.clone(), channel, bootstrap.clone());
            worker.poll(&mut registry).unwrap();
            assert_eq!(registry.take_output_batch(runtime.id).unwrap().bytes, decode(fields[2]), "{}", fields[0]);
        }

        let mut registry = TerminalRuntimeRegistry::new(64 * 1024);
        let runtime = registry.open_remote_ssh("host".into(), 22, "user".into(), 24, 24);
        let channel = FakeShellChannel::new().with_read_chunks(vec![bootstrap[..128].to_vec()]);
        let mut worker = LiveShellWorker::new_with_bootstrap_input(runtime.id.clone(), channel, bootstrap.clone());
        worker.poll(&mut registry).unwrap();
        assert!(registry.take_output_batch(runtime.id.clone()).unwrap().bytes.is_empty());
        registry.record_resize(runtime.id.clone(), 80, 30).unwrap();
        worker.channel.read_chunks.push(bootstrap[128..].to_vec());
        worker.poll(&mut registry).unwrap();
        assert_eq!(registry.take_output_batch(runtime.id).unwrap().bytes, bootstrap);
        assert!(worker.initial_input_echo_filters.is_empty());
    }

    #[test]
    fn bootstrap_echo_preserves_unsupported_controls_and_geometries() {
        let bootstrap = ssh_osc7_bootstrap_input_chunks().concat();
        for (columns, rows, control) in [
            (80, 24, b"\x1b[?7l".as_slice()), // Autowrap changes the coordinate model.
            (80, 24, b"\x1b[2J"),
            (80, 24, b"\x1b[999999999999999999999999999999C"),
            (0, 24, b""), (1, 1, b""), (u32::MAX, u32::MAX, b""),
        ] {
            let mut input = bootstrap[..128].to_vec();
            input.extend_from_slice(control);
            input.extend_from_slice(&bootstrap[128..]);
            let mut worker = LiveShellWorker::new_with_bootstrap_input(
                "fixture".into(), FakeShellChannel::new(), bootstrap.clone());
            assert!(worker.set_initial_echo_terminal_size(columns, rows).is_empty());
            let mut visible = worker.filter_initial_input_echo(input.clone());
            visible.extend(worker.finish_initial_input_echo());
            assert_eq!(visible, input, "geometry={columns}x{rows}, control={control:?}");
        }
    }

    #[test]
    fn bootstrap_echo_filters_styled_readline_zle_captures() {
        fn decode_hex(hex: &str) -> Vec<u8> {
            hex.as_bytes().chunks_exact(2).map(|pair| {
                u8::from_str_radix(std::str::from_utf8(pair).unwrap(), 16).unwrap()
            }).collect()
        }
        let bootstrap = include_bytes!("../../tests/fixtures/ssh-bootstrap/bootstrap.txt").to_vec();
        let word = b"precmd";
        for line in include_str!("../../tests/fixtures/ssh-bootstrap/readline-zle.hex").lines() {
            let fields: Vec<_> = line.split('\t').collect();
            let raw = decode_hex(fields[1]);
            let expected = decode_hex(fields[2]);
            let mut styled = Vec::new();
            let mut remaining = raw.as_slice();
            let mut replacements = 0;
            while let Some(start) = find_subsequence(remaining, word) {
                styled.extend_from_slice(&remaining[..start]);
                styled.extend_from_slice(b"\x1b[31mpre\x1b[1mcmd\x1b[0m");
                remaining = &remaining[start + word.len()..];
                replacements += 1;
            }
            styled.extend_from_slice(remaining);
            assert!(replacements > 0, "{} must exercise styles within the echo", fields[0]);
            for chunk_size in [1, 7, 128, 16 * 1024] {
                let mut worker = LiveShellWorker::new_with_bootstrap_input(
                    "fixture".into(), FakeShellChannel::new(), bootstrap.clone());
                let columns = fields[0].split('_').nth(1).unwrap().parse().unwrap();
                assert!(worker.set_initial_echo_terminal_size(columns, 24).is_empty());
                let mut visible = Vec::new();
                for chunk in styled.chunks(chunk_size) {
                    visible.extend(worker.filter_initial_input_echo(chunk.to_vec()));
                }
                visible.extend(worker.finish_initial_input_echo());
                assert_eq!(visible, expected, "{} chunk_size={chunk_size}", fields[0]);
            }
        }
    }

    #[test]
    fn bootstrap_echo_preserves_text_erased_by_cursor_redraw() {
        let bootstrap = ssh_osc7_bootstrap_input_chunks().concat();
        let diagnostic = b"IMPORTANT LOGIN MESSAGE";
        let mut input = bootstrap[..128].to_vec();
        input.extend_from_slice(b"\x1b[1D");
        input.extend_from_slice(diagnostic);
        input.extend(std::iter::repeat_n(b'\x08', diagnostic.len()));
        input.extend_from_slice(&bootstrap[128..]);
        input.extend_from_slice(b"prompt$ ");
        for chunk_size in [1, 17, 16 * 1024] {
            let mut worker = LiveShellWorker::new_with_bootstrap_input(
                "fixture".into(), FakeShellChannel::new(), bootstrap.clone());
            let mut visible = Vec::new();
            for chunk in input.chunks(chunk_size) {
                visible.extend(worker.filter_initial_input_echo(chunk.to_vec()));
            }
            visible.extend(worker.finish_initial_input_echo());
            assert_eq!(visible, input, "erased diagnostic, chunk_size={chunk_size}");
        }
    }

    #[test]
    fn bootstrap_echo_releases_unconfirmed_bytes_on_idle_expiry_eof_and_close() {
        let bootstrap = ssh_osc7_bootstrap_input_chunks().concat();
        let partial = bootstrap[..160].to_vec();
        for finish_mode in ["expiry", "eof", "close"] {
            let mut registry = TerminalRuntimeRegistry::new(4096);
            let runtime = registry.open_remote_ssh("host".into(), 22, "user".into(), 80, 24);
            let channel = FakeShellChannel::new().with_read_chunks(vec![partial.clone()]);
            let mut worker = LiveShellWorker::new_with_bootstrap_input(runtime.id.clone(), channel, bootstrap.clone());
            worker.poll(&mut registry).unwrap();
            assert!(registry.take_output_batch(runtime.id.clone()).unwrap().bytes.is_empty());
            match finish_mode {
                "expiry" => {
                    worker.initial_input_echo_filters[0].expires_at = Instant::now() - Duration::from_millis(1);
                    worker.poll(&mut registry).unwrap();
                }
                "eof" => { worker.channel.eof_after_poll = true; worker.poll(&mut registry).unwrap(); }
                _ => { worker.close(&mut registry).unwrap(); }
            }
            assert_eq!(registry.take_output_batch(runtime.id.clone()).unwrap().bytes, partial, "{finish_mode}");
            assert!(worker.initial_input_echo_filters.is_empty());
        }
    }

    #[test]
    fn bootstrap_echo_releases_unconfirmed_bytes_on_channel_errors() {
        struct FailingChannel { inner: FakeShellChannel, fail: &'static str }
        impl ShellChannel for FailingChannel {
            fn write_input(&mut self, bytes: &[u8]) -> io::Result<usize> {
                if self.fail == "write" { return Err(io::Error::new(io::ErrorKind::BrokenPipe, "write failed")); }
                self.inner.write_input(bytes)
            }
            fn read_output(&mut self, max: usize) -> io::Result<Vec<u8>> {
                if self.fail == "read" { return Err(io::Error::new(io::ErrorKind::BrokenPipe, "read failed")); }
                self.inner.read_output(max)
            }
            fn resize_pty(&mut self, cols: u32, rows: u32) -> io::Result<()> {
                if self.fail == "resize" { return Err(io::Error::new(io::ErrorKind::BrokenPipe, "resize failed")); }
                self.inner.resize_pty(cols, rows)
            }
            fn keepalive(&mut self) -> io::Result<()> {
                if self.fail == "keepalive" { return Err(io::Error::new(io::ErrorKind::BrokenPipe, "keepalive failed")); }
                Ok(())
            }
            fn close(&mut self) -> io::Result<()> { Ok(()) }
            fn is_eof(&self) -> bool { false }
        }
        let bootstrap = ssh_osc7_bootstrap_input_chunks().concat();
        let partial = bootstrap[..160].to_vec();
        for mode in ["read", "write", "resize", "keepalive"] {
            let mut registry = TerminalRuntimeRegistry::new(4096);
            let runtime = registry.open_remote_ssh("host".into(), 22, "user".into(), 80, 24);
            let channel = FailingChannel { inner: FakeShellChannel::new().with_read_chunks(vec![partial.clone()]), fail: "" };
            let mut worker = LiveShellWorker::new_with_bootstrap_input(runtime.id.clone(), channel, bootstrap.clone());
            worker.poll(&mut registry).unwrap();
            assert!(registry.take_output_batch(runtime.id.clone()).unwrap().bytes.is_empty());
            worker.channel.fail = mode;
            if mode == "write" { registry.write_input(runtime.id.clone(), b"user\n".to_vec()).unwrap(); }
            if mode == "resize" { registry.record_resize(runtime.id.clone(), 81, 25).unwrap(); }
            if mode == "keepalive" {
                worker.consecutive_keepalive_failures = 1;
                worker.last_keepalive_at = Some(Instant::now() - Duration::from_secs(21));
                assert_eq!(worker.poll(&mut registry).unwrap().diagnostic, "keepalive_failed");
            } else {
                assert!(worker.poll(&mut registry).is_err());
            }
            assert_eq!(registry.take_output_batch(runtime.id.clone()).unwrap().bytes, partial, "{mode}");
            assert!(worker.initial_input_echo_filters.is_empty());
        }
    }

    #[test]
    fn bootstrap_echo_fails_open_at_its_size_limit_and_does_not_delay_user_input() {
        let bootstrap = ssh_osc7_bootstrap_input_chunks().concat();
        let mut large = bootstrap[..160].to_vec();
        large.extend(vec![b'x'; OSC7_BOOTSTRAP_ECHO_MAX_BYTES + 1]);
        large.extend_from_slice(b"\r\nordinary user output\r\n");
        let mut worker = LiveShellWorker::new_with_bootstrap_input("fixture".into(), FakeShellChannel::new(), bootstrap.clone());
        let mut visible = Vec::new();
        for chunk in large.chunks(7) { visible.extend(worker.filter_initial_input_echo(chunk.to_vec())); }
        assert_eq!(visible, large);
        assert!(worker.initial_input_echo_filters.is_empty());

        let mut registry = TerminalRuntimeRegistry::new(4096);
        let runtime = registry.open_remote_ssh("host".into(), 22, "user".into(), 80, 24);
        let channel = FakeShellChannel::new().with_read_chunks(vec![bootstrap[..160].to_vec()]);
        let mut worker = LiveShellWorker::new_with_bootstrap_input(runtime.id.clone(), channel, bootstrap.clone());
        worker.poll(&mut registry).unwrap();
        registry.write_input(runtime.id.clone(), b"echo user\n".to_vec()).unwrap();
        worker.poll(&mut registry).unwrap();
        assert!(worker.channel().written_bytes().ends_with(b"echo user\n"));
    }

    #[test]
    fn bootstrap_background_pids_do_not_trigger_interactive_history_expansion() {
        let bootstrap = String::from_utf8(ssh_osc7_bootstrap_input_chunks().concat()).unwrap();
        assert!(bootstrap.contains("__stacio_command_pid=$! ;"));
        assert!(bootstrap.contains("__stacio_watchdog_pid=$! ;"));
        assert!(!bootstrap.contains("=$!;"));
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

        worker
            .poll(&mut registry)
            .expect("poll after configured interval");
        assert_eq!(worker.channel().keepalive_count, 1);

        worker.set_keepalive_interval_seconds(0);
        worker.last_keepalive_at = Some(Instant::now() - Duration::from_secs(60));
        worker
            .poll(&mut registry)
            .expect("poll with disabled keepalive");
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
