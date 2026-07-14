use std::collections::{BTreeMap, VecDeque};

use uuid::Uuid;

use crate::domain::terminal::{
    TerminalInputBatch, TerminalOutputBatch, TerminalRuntime, TerminalRuntimeError,
};

#[derive(Debug, Clone)]
pub struct TerminalRuntimeRegistry {
    runtimes: BTreeMap<String, TerminalRuntime>,
    output_buffers: BTreeMap<String, VecDeque<u8>>,
    input_buffers: BTreeMap<String, VecDeque<Vec<u8>>>,
    dropped_counts: BTreeMap<String, u32>,
    input_dropped_counts: BTreeMap<String, u32>,
    max_buffer_bytes: usize,
}

impl TerminalRuntimeRegistry {
    pub fn new(max_buffer_bytes: usize) -> Self {
        Self {
            runtimes: BTreeMap::new(),
            output_buffers: BTreeMap::new(),
            input_buffers: BTreeMap::new(),
            dropped_counts: BTreeMap::new(),
            input_dropped_counts: BTreeMap::new(),
            max_buffer_bytes,
        }
    }

    pub fn active_count(&self) -> usize {
        self.runtimes
            .values()
            .filter(|runtime| runtime.status == "running")
            .count()
    }

    pub fn open_local_shell(
        &mut self,
        shell_path: String,
        cols: u32,
        rows: u32,
    ) -> TerminalRuntime {
        let runtime = TerminalRuntime {
            id: format!("term_{}", Uuid::new_v4()),
            kind: "local_shell".to_string(),
            shell_path,
            remote_host: None,
            remote_port: None,
            username: None,
            cols,
            rows,
            resize_revision: 0,
            status: "running".to_string(),
            output_paused: false,
        };

        self.register_runtime(runtime)
    }

    pub fn open_remote_ssh(
        &mut self,
        host: String,
        port: u16,
        username: String,
        cols: u32,
        rows: u32,
    ) -> TerminalRuntime {
        let runtime = TerminalRuntime {
            id: format!("term_{}", Uuid::new_v4()),
            kind: "remote_ssh".to_string(),
            shell_path: String::new(),
            remote_host: Some(host),
            remote_port: Some(u32::from(port)),
            username: Some(username),
            cols,
            rows,
            resize_revision: 0,
            status: "running".to_string(),
            output_paused: false,
        };

        self.register_runtime(runtime)
    }

    pub fn open_remote_telnet(
        &mut self,
        host: String,
        port: u16,
        username: Option<String>,
        cols: u32,
        rows: u32,
    ) -> TerminalRuntime {
        let runtime = TerminalRuntime {
            id: format!("term_{}", Uuid::new_v4()),
            kind: "remote_telnet".to_string(),
            shell_path: String::new(),
            remote_host: Some(host),
            remote_port: Some(u32::from(port)),
            username,
            cols,
            rows,
            resize_revision: 0,
            status: "running".to_string(),
            output_paused: false,
        };

        self.register_runtime(runtime)
    }

    pub fn open_serial(
        &mut self,
        device_path: String,
        baud_rate: u32,
        cols: u32,
        rows: u32,
    ) -> TerminalRuntime {
        let runtime = TerminalRuntime {
            id: format!("term_{}", Uuid::new_v4()),
            kind: "remote_serial".to_string(),
            shell_path: String::new(),
            remote_host: Some(device_path),
            remote_port: Some(baud_rate),
            username: None,
            cols,
            rows,
            resize_revision: 0,
            status: "running".to_string(),
            output_paused: false,
        };

        self.register_runtime(runtime)
    }

    fn register_runtime(&mut self, runtime: TerminalRuntime) -> TerminalRuntime {
        self.output_buffers.insert(
            runtime.id.clone(),
            VecDeque::with_capacity(self.max_buffer_bytes),
        );
        self.input_buffers.insert(
            runtime.id.clone(),
            VecDeque::new(),
        );
        self.dropped_counts.insert(runtime.id.clone(), 0);
        self.input_dropped_counts.insert(runtime.id.clone(), 0);
        self.runtimes.insert(runtime.id.clone(), runtime.clone());
        runtime
    }

    pub fn record_resize(
        &mut self,
        runtime_id: String,
        cols: u32,
        rows: u32,
    ) -> Result<TerminalRuntime, TerminalRuntimeError> {
        let runtime = self.runtimes.get_mut(&runtime_id).ok_or_else(|| {
            TerminalRuntimeError::RuntimeNotFound {
                runtime_id: runtime_id.clone(),
            }
        })?;

        if runtime.cols != cols || runtime.rows != rows {
            runtime.resize_revision = runtime.resize_revision.saturating_add(1);
        }
        runtime.cols = cols;
        runtime.rows = rows;
        Ok(runtime.clone())
    }

    pub fn runtime_snapshot(
        &self,
        runtime_id: String,
    ) -> Result<TerminalRuntime, TerminalRuntimeError> {
        self.runtimes
            .get(&runtime_id)
            .cloned()
            .ok_or(TerminalRuntimeError::RuntimeNotFound { runtime_id })
    }

    pub fn set_output_paused(
        &mut self,
        runtime_id: String,
        paused: bool,
    ) -> Result<TerminalRuntime, TerminalRuntimeError> {
        let runtime = self.runtimes.get_mut(&runtime_id).ok_or_else(|| {
            TerminalRuntimeError::RuntimeNotFound {
                runtime_id: runtime_id.clone(),
            }
        })?;
        if runtime.status != "running" {
            return Err(TerminalRuntimeError::RuntimeClosed { runtime_id });
        }
        runtime.output_paused = paused;
        Ok(runtime.clone())
    }

    pub fn record_output(
        &mut self,
        runtime_id: String,
        bytes: Vec<u8>,
    ) -> Result<(), TerminalRuntimeError> {
        if !self.runtimes.contains_key(&runtime_id) {
            return Err(TerminalRuntimeError::RuntimeNotFound { runtime_id });
        }

        let buffer = self
            .output_buffers
            .entry(runtime_id.clone())
            .or_insert_with(VecDeque::new);
        let dropped = self.dropped_counts.entry(runtime_id).or_insert(0);

        for byte in bytes {
            if buffer.len() < self.max_buffer_bytes {
                buffer.push_back(byte);
            } else {
                *dropped += 1;
            }
        }

        Ok(())
    }

    pub fn write_input(
        &mut self,
        runtime_id: String,
        bytes: Vec<u8>,
    ) -> Result<(), TerminalRuntimeError> {
        self.ensure_running(&runtime_id)?;

        let buffer = self
            .input_buffers
            .entry(runtime_id.clone())
            .or_insert_with(VecDeque::new);
        let dropped = self.input_dropped_counts.entry(runtime_id).or_insert(0);
        let buffered_len = buffer.iter().map(Vec::len).sum::<usize>();
        let available_len = self.max_buffer_bytes.saturating_sub(buffered_len);
        let accepted_len = bytes.len().min(available_len);

        if accepted_len > 0 {
            buffer.push_back(bytes[..accepted_len].to_vec());
        }
        if accepted_len < bytes.len() {
            *dropped = (*dropped).saturating_add((bytes.len() - accepted_len) as u32);
        }

        Ok(())
    }

    fn ensure_running(&self, runtime_id: &str) -> Result<(), TerminalRuntimeError> {
        match self.runtimes.get(runtime_id) {
            Some(runtime) if runtime.status == "running" => Ok(()),
            Some(_) => Err(TerminalRuntimeError::RuntimeClosed {
                runtime_id: runtime_id.to_string(),
            }),
            None => Err(TerminalRuntimeError::RuntimeNotFound {
                runtime_id: runtime_id.to_string(),
            }),
        }
    }

    pub fn take_output_batch(
        &mut self,
        runtime_id: String,
    ) -> Result<TerminalOutputBatch, TerminalRuntimeError> {
        if !self.runtimes.contains_key(&runtime_id) {
            return Err(TerminalRuntimeError::RuntimeNotFound { runtime_id });
        }
        if self
            .runtimes
            .get(&runtime_id)
            .map(|runtime| runtime.output_paused)
            .unwrap_or(false)
        {
            let buffered_byte_count = self
                .output_buffers
                .get(&runtime_id)
                .map(VecDeque::len)
                .unwrap_or(0)
                .min(u32::MAX as usize) as u32;
            let dropped_byte_count = self.dropped_counts.get(&runtime_id).copied().unwrap_or(0);
            return Ok(TerminalOutputBatch {
                runtime_id,
                bytes: Vec::new(),
                dropped_byte_count,
                protection_active: dropped_byte_count > 0 || buffered_byte_count > 0,
                buffered_byte_count,
            });
        }

        let buffer = self
            .output_buffers
            .entry(runtime_id.clone())
            .or_insert_with(VecDeque::new);
        let buffered_byte_count = buffer.len().min(u32::MAX as usize) as u32;
        let bytes = buffer.drain(..).collect::<Vec<_>>();
        let dropped_byte_count = self.dropped_counts.remove(&runtime_id).unwrap_or(0);
        self.dropped_counts.insert(runtime_id.clone(), 0);

        Ok(TerminalOutputBatch {
            runtime_id,
            bytes,
            dropped_byte_count,
            protection_active: dropped_byte_count > 0,
            buffered_byte_count,
        })
    }

    pub fn take_input_batch(
        &mut self,
        runtime_id: String,
    ) -> Result<TerminalInputBatch, TerminalRuntimeError> {
        if !self.runtimes.contains_key(&runtime_id) {
            return Err(TerminalRuntimeError::RuntimeNotFound { runtime_id });
        }

        let (chunks, dropped_byte_count) = self.take_input_chunks(runtime_id.clone())?;
        let bytes = chunks.into_iter().flatten().collect();

        Ok(TerminalInputBatch {
            runtime_id,
            bytes,
            dropped_byte_count,
        })
    }

    pub fn take_input_chunks(
        &mut self,
        runtime_id: String,
    ) -> Result<(Vec<Vec<u8>>, u32), TerminalRuntimeError> {
        if !self.runtimes.contains_key(&runtime_id) {
            return Err(TerminalRuntimeError::RuntimeNotFound { runtime_id });
        }

        let buffer = self
            .input_buffers
            .entry(runtime_id.clone())
            .or_insert_with(VecDeque::new);
        let chunks = buffer.drain(..).collect::<Vec<_>>();
        let dropped_byte_count = self.input_dropped_counts.remove(&runtime_id).unwrap_or(0);
        self.input_dropped_counts.insert(runtime_id, 0);

        Ok((chunks, dropped_byte_count))
    }

    pub fn close(&mut self, runtime_id: String) -> Result<TerminalRuntime, TerminalRuntimeError> {
        let runtime = self.runtimes.get_mut(&runtime_id).ok_or_else(|| {
            TerminalRuntimeError::RuntimeNotFound {
                runtime_id: runtime_id.clone(),
            }
        })?;

        runtime.status = "closed".to_string();
        Ok(runtime.clone())
    }
}

#[cfg(test)]
mod tests {}
