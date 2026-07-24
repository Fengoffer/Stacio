use std::io::{self, Read, Write};
use std::os::fd::AsRawFd;
use std::time::Duration;

use serialport::{DataBits, FlowControl, Parity, StopBits, TTYPort};

use crate::domain::{
    serial::{validate_serial_config, SerialConnectionConfig},
    ssh::{redact_ssh_diagnostic, SshRuntimeError},
};
use crate::services::live_shell_service::{ShellChannel, ShellWaitInterest};

#[derive(Debug)]
pub struct SerialShellChannel {
    device: TTYPort,
    eof: bool,
    maps_delete_to_backspace: bool,
}

impl SerialShellChannel {
    pub fn open(device_path: &str, baud_rate: u32) -> Result<Self, SshRuntimeError> {
        Self::open_with_config(SerialConnectionConfig {
            device_path: device_path.to_string(),
            baud_rate,
            data_bits: 8,
            stop_bits: 1,
            parity: "none".to_string(),
            flow_control: "none".to_string(),
            backspace_mode: "del".to_string(),
        })
    }

    pub fn open_with_config(config: SerialConnectionConfig) -> Result<Self, SshRuntimeError> {
        validate_serial_config(&config)?;
        let device_path = resolved_serial_device_path(config.device_path.trim());
        let device = serialport::new(device_path, config.baud_rate)
            .data_bits(serial_data_bits(config.data_bits))
            .parity(serial_parity(&config.parity))
            .stop_bits(serial_stop_bits(config.stop_bits))
            .flow_control(serial_flow_control(&config.flow_control))
            .timeout(Duration::from_millis(10))
            .open_native()
            .map_err(|error| serial_transport_error(&error.to_string()))?;

        Ok(Self {
            device,
            eof: false,
            maps_delete_to_backspace: config.backspace_mode.trim().eq_ignore_ascii_case("ctrl_h"),
        })
    }
}

fn resolved_serial_device_path(device_path: &str) -> String {
    if let Some(tty_path) = nbee_tty_counterpart(device_path) {
        if std::path::Path::new(&tty_path).exists() {
            return tty_path;
        }
    }
    device_path.to_string()
}

fn nbee_tty_counterpart(device_path: &str) -> Option<String> {
    const CALLOUT_PREFIX: &str = "/dev/cu.";
    let suffix = device_path.strip_prefix(CALLOUT_PREFIX)?;
    if !suffix.to_ascii_lowercase().contains("nbee_spp_") {
        return None;
    }
    Some(format!("/dev/tty.{suffix}"))
}

impl ShellChannel for SerialShellChannel {
    fn write_input(&mut self, bytes: &[u8]) -> io::Result<usize> {
        if self.maps_delete_to_backspace && bytes.contains(&0x7f) {
            let mut remapped = bytes.to_vec();
            for byte in remapped.iter_mut() {
                if *byte == 0x7f {
                    *byte = 0x08;
                }
            }
            self.device.write(&remapped)
        } else {
            self.device.write(bytes)
        }
    }

    fn read_output(&mut self, max_bytes: usize) -> io::Result<Vec<u8>> {
        let mut buffer = vec![0_u8; max_bytes];
        match self.device.read(&mut buffer) {
            Ok(0) => {
                self.eof = true;
                Ok(Vec::new())
            }
            Ok(count) => {
                buffer.truncate(count);
                Ok(buffer)
            }
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock
                ) =>
            {
                Ok(Vec::new())
            }
            Err(error) => Err(error),
        }
    }

    fn resize_pty(&mut self, _cols: u32, _rows: u32) -> io::Result<()> {
        Ok(())
    }

    fn close(&mut self) -> io::Result<()> {
        self.eof = true;
        Ok(())
    }

    fn is_eof(&self) -> bool {
        self.eof
    }

    fn wait_interest(&self) -> Option<ShellWaitInterest> {
        Some(ShellWaitInterest::readable(self.device.as_raw_fd()))
    }
}

fn serial_data_bits(value: u8) -> DataBits {
    match value {
        5 => DataBits::Five,
        6 => DataBits::Six,
        7 => DataBits::Seven,
        _ => DataBits::Eight,
    }
}

fn serial_parity(value: &str) -> Parity {
    match value.trim().to_ascii_lowercase().as_str() {
        "odd" => Parity::Odd,
        "even" => Parity::Even,
        _ => Parity::None,
    }
}

fn serial_stop_bits(value: u8) -> StopBits {
    match value {
        2 => StopBits::Two,
        _ => StopBits::One,
    }
}

fn serial_flow_control(value: &str) -> FlowControl {
    match value.trim().to_ascii_lowercase().as_str() {
        "rtscts" => FlowControl::Hardware,
        "xonxoff" => FlowControl::Software,
        _ => FlowControl::None,
    }
}

fn serial_transport_error(message: &str) -> SshRuntimeError {
    SshRuntimeError::Transport {
        message: redact_ssh_diagnostic(message),
    }
}

#[cfg(test)]
mod tests {
    use super::{nbee_tty_counterpart, SerialShellChannel};
    use crate::services::live_shell_service::ShellChannel;
    use std::ffi::CStr;
    use std::io::{Read, Write};
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    use std::time::{Duration, Instant};

    #[test]
    fn serial_channel_reads_and_writes_using_pseudo_terminal() {
        let fixture = PseudoTerminalFixture::new();
        let mut channel =
            SerialShellChannel::open(&fixture.slave_path, 0).expect("open serial fixture");

        fixture
            .master_file()
            .write_all(b"bootloader> ")
            .expect("write fixture output");
        let output = read_until_non_empty(&mut channel);
        channel.write_input(b"help\r").expect("write serial input");

        let mut input = [0_u8; 5];
        fixture
            .master_file()
            .read_exact(&mut input)
            .expect("read channel input");

        assert_eq!(output, b"bootloader> ".to_vec());
        assert_eq!(&input, b"help\r");
        assert_eq!(
            channel.wait_interest().map(|interest| interest.readable),
            Some(true)
        );
    }

    #[test]
    fn serial_channel_clears_nonblocking_mode_after_open() {
        let fixture = PseudoTerminalFixture::new();
        let channel =
            SerialShellChannel::open(&fixture.slave_path, 0).expect("open serial fixture");

        let flags = unsafe { libc::fcntl(channel.device.as_raw_fd(), libc::F_GETFL) };

        assert!(flags >= 0, "read serial file status flags");
        assert_eq!(flags & libc::O_NONBLOCK, 0);
    }

    #[test]
    fn serial_channel_opens_device_exclusively() {
        let fixture = PseudoTerminalFixture::new();
        let _channel =
            SerialShellChannel::open(&fixture.slave_path, 0).expect("open serial fixture");

        let second_open = SerialShellChannel::open(&fixture.slave_path, 0);

        assert!(second_open.is_err());
    }

    #[test]
    fn nbee_console_maps_callout_path_to_vendor_documented_tty_path() {
        assert_eq!(
            nbee_tty_counterpart("/dev/cu.NBEE_SPP_1103"),
            Some("/dev/tty.NBEE_SPP_1103".to_string())
        );
        assert_eq!(nbee_tty_counterpart("/dev/cu.Other-Bluetooth"), None);
        assert_eq!(nbee_tty_counterpart("/dev/cu.usbserial-001"), None);
    }

    #[test]
    fn serial_channel_reports_transport_error_when_custom_baud_ioctl_fails() {
        let fixture = PseudoTerminalFixture::new();

        let error =
            SerialShellChannel::open(&fixture.slave_path, 12_345).expect_err("custom baud on pty");

        assert!(matches!(
            error,
            crate::domain::ssh::SshRuntimeError::Transport { .. }
        ));
    }

    #[test]
    fn serial_channel_opens_without_configuring_baud_rate() {
        let fixture = PseudoTerminalFixture::new();
        let mut channel =
            SerialShellChannel::open(&fixture.slave_path, 0).expect("open serial fixture");

        fixture
            .master_file()
            .write_all(b"ready> ")
            .expect("write fixture output");
        let output = read_until_non_empty(&mut channel);
        channel
            .write_input(b"status\r")
            .expect("write serial input");

        let mut input = [0_u8; 7];
        fixture
            .master_file()
            .read_exact(&mut input)
            .expect("read channel input");

        assert_eq!(output, b"ready> ".to_vec());
        assert_eq!(&input, b"status\r");
    }

    #[test]
    fn serial_channel_can_remap_delete_to_control_h() {
        let fixture = PseudoTerminalFixture::new();
        let mut channel =
            SerialShellChannel::open_with_config(crate::domain::serial::SerialConnectionConfig {
                device_path: fixture.slave_path.clone(),
                baud_rate: 0,
                data_bits: 8,
                stop_bits: 1,
                parity: "none".to_string(),
                flow_control: "none".to_string(),
                backspace_mode: "ctrl_h".to_string(),
            })
            .expect("open serial fixture");

        channel.write_input(&[0x7f]).expect("write serial input");

        let mut input = [0_u8; 1];
        fixture
            .master_file()
            .read_exact(&mut input)
            .expect("read channel input");

        assert_eq!(input, [0x08]);
    }

    #[test]
    #[ignore = "requires STACIO_LIVE_SERIAL_DEVICE connected to a responsive console"]
    fn live_serial_console_opens_writes_and_reads() {
        let device_path = std::env::var("STACIO_LIVE_SERIAL_DEVICE")
            .expect("set STACIO_LIVE_SERIAL_DEVICE to a connected serial console");
        let baud_rate = std::env::var("STACIO_LIVE_SERIAL_BAUD")
            .ok()
            .and_then(|value| value.parse::<u32>().ok())
            .unwrap_or(9_600);
        let mut channel =
            SerialShellChannel::open_with_config(crate::domain::serial::SerialConnectionConfig {
                device_path,
                baud_rate,
                data_bits: 8,
                stop_bits: 1,
                parity: "none".to_string(),
                flow_control: "none".to_string(),
                backspace_mode: "del".to_string(),
            })
            .expect("open live serial console");

        std::thread::sleep(Duration::from_secs(2));
        let mut output = Vec::new();
        for _ in 0..3 {
            channel.write_input(b"\r").expect("write console wakeup");
            output = read_until_non_empty_with_timeout(&mut channel, Duration::from_secs(2));
            if !output.is_empty() {
                break;
            }
        }

        assert!(
            !output.is_empty(),
            "serial console returned no data after wakeup"
        );
    }

    struct PseudoTerminalFixture {
        master_fd: OwnedFd,
        slave_path: String,
    }

    impl PseudoTerminalFixture {
        fn new() -> Self {
            let mut master = 0;
            let mut slave = 0;
            let mut name = [0_i8; 128];
            let result = unsafe {
                libc::openpty(
                    &mut master,
                    &mut slave,
                    name.as_mut_ptr(),
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                )
            };
            assert_eq!(result, 0, "openpty failed");
            let slave_path = unsafe { CStr::from_ptr(name.as_ptr()) }
                .to_string_lossy()
                .into_owned();
            unsafe {
                libc::close(slave);
            }
            Self {
                master_fd: unsafe { OwnedFd::from_raw_fd(master) },
                slave_path,
            }
        }

        fn master_file(&self) -> std::fs::File {
            let duplicated = unsafe { libc::dup(self.master_fd.as_raw_fd()) };
            assert!(duplicated >= 0, "dup master fd");
            unsafe { std::fs::File::from_raw_fd(duplicated) }
        }
    }

    fn read_until_non_empty(channel: &mut SerialShellChannel) -> Vec<u8> {
        read_until_non_empty_with_timeout(channel, Duration::from_secs(2))
    }

    fn read_until_non_empty_with_timeout(
        channel: &mut SerialShellChannel,
        timeout: Duration,
    ) -> Vec<u8> {
        let deadline = Instant::now() + timeout;
        while Instant::now() < deadline {
            let output = channel.read_output(1024).expect("read serial output");
            if !output.is_empty() {
                return output;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        Vec::new()
    }
}
