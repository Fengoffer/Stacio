use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd};

use crate::domain::{
    serial::{validate_serial_config, SerialConnectionConfig},
    ssh::{redact_ssh_diagnostic, SshRuntimeError},
};
use crate::services::live_shell_service::{ShellChannel, ShellWaitInterest};

#[derive(Debug)]
pub struct SerialShellChannel {
    device: std::fs::File,
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
        let speed = standard_baud_to_speed(config.baud_rate);
        let trimmed_path = config.device_path.trim();
        let path =
            std::ffi::CString::new(trimmed_path).map_err(|_| SshRuntimeError::InvalidConfig)?;
        let fd = unsafe {
            libc::open(
                path.as_ptr(),
                libc::O_RDWR | libc::O_NOCTTY | libc::O_NONBLOCK,
            )
        };
        if fd < 0 {
            return Err(serial_transport_error(
                &io::Error::last_os_error().to_string(),
            ));
        }

        let mut channel = Self {
            device: unsafe { std::fs::File::from_raw_fd(fd) },
            eof: false,
            maps_delete_to_backspace: config.backspace_mode.trim().eq_ignore_ascii_case("ctrl_h"),
        };
        if let Err(error) = configure_serial_fd(channel.device.as_raw_fd(), speed, &config) {
            let _ = channel.close();
            return Err(serial_transport_error(&error.to_string()));
        }
        Ok(channel)
    }
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
            return self.device.write(&remapped);
        }
        self.device.write(bytes)
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
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => Ok(Vec::new()),
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

fn configure_serial_fd(
    fd: i32,
    speed: Option<libc::speed_t>,
    config: &SerialConnectionConfig,
) -> io::Result<()> {
    let mut termios = std::mem::MaybeUninit::<libc::termios>::uninit();
    if unsafe { libc::tcgetattr(fd, termios.as_mut_ptr()) } != 0 {
        return Err(io::Error::last_os_error());
    }
    let mut termios = unsafe { termios.assume_init() };
    unsafe {
        libc::cfmakeraw(&mut termios);
    }
    let uses_custom_baud_rate = config.baud_rate != 0 && speed.is_none();
    let termios_speed = if uses_custom_baud_rate {
        Some(libc::B9600)
    } else {
        speed
    };
    if let Some(termios_speed) = termios_speed {
        if unsafe { libc::cfsetspeed(&mut termios, termios_speed) } != 0 {
            return Err(io::Error::last_os_error());
        }
    }
    apply_serial_options(&mut termios, config)?;
    termios.c_cflag |= libc::CLOCAL | libc::CREAD;
    termios.c_cc[libc::VMIN] = 0;
    termios.c_cc[libc::VTIME] = 0;
    if unsafe { libc::tcsetattr(fd, libc::TCSANOW, &termios) } != 0 {
        return Err(io::Error::last_os_error());
    }
    if uses_custom_baud_rate {
        apply_custom_baud_rate(fd, config.baud_rate)?;
    }
    Ok(())
}

fn apply_serial_options(
    termios: &mut libc::termios,
    config: &SerialConnectionConfig,
) -> io::Result<()> {
    validate_serial_config(config).map_err(|_| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            "invalid serial connection config",
        )
    })?;

    termios.c_cflag &= !libc::CSIZE;
    termios.c_cflag |= match config.data_bits {
        5 => libc::CS5,
        6 => libc::CS6,
        7 => libc::CS7,
        8 => libc::CS8,
        _ => unreachable!("validated data bits"),
    };

    termios.c_cflag &= !libc::CSTOPB;
    if config.stop_bits == 2 {
        termios.c_cflag |= libc::CSTOPB;
    }

    termios.c_cflag &= !(libc::PARENB | libc::PARODD);
    match config.parity.trim().to_ascii_lowercase().as_str() {
        "none" => {}
        "even" => {
            termios.c_cflag |= libc::PARENB;
        }
        "odd" => {
            termios.c_cflag |= libc::PARENB | libc::PARODD;
        }
        _ => unreachable!("validated parity"),
    }

    termios.c_cflag &= !libc::CRTSCTS;
    termios.c_iflag &= !(libc::IXON | libc::IXOFF);
    match config.flow_control.trim().to_ascii_lowercase().as_str() {
        "none" => {}
        "rtscts" => {
            termios.c_cflag |= libc::CRTSCTS;
        }
        "xonxoff" => {
            termios.c_iflag |= libc::IXON | libc::IXOFF;
        }
        _ => unreachable!("validated flow control"),
    }

    Ok(())
}

fn standard_baud_to_speed(baud_rate: u32) -> Option<libc::speed_t> {
    match baud_rate {
        1_200 => Some(libc::B1200),
        2_400 => Some(libc::B2400),
        4_800 => Some(libc::B4800),
        9_600 => Some(libc::B9600),
        19_200 => Some(libc::B19200),
        38_400 => Some(libc::B38400),
        57_600 => Some(libc::B57600),
        115_200 => Some(libc::B115200),
        230_400 => Some(libc::B230400),
        _ => None,
    }
}

#[cfg(target_os = "macos")]
fn apply_custom_baud_rate(fd: i32, baud_rate: u32) -> io::Result<()> {
    const IOSSIOSPEED: libc::c_ulong = 0x8008_5402;
    let mut speed = libc::speed_t::from(baud_rate);
    if unsafe { libc::ioctl(fd, IOSSIOSPEED, &mut speed) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

#[cfg(not(target_os = "macos"))]
fn apply_custom_baud_rate(_fd: i32, _baud_rate: u32) -> io::Result<()> {
    Err(io::Error::new(
        io::ErrorKind::Unsupported,
        "custom serial baud rates require macOS IOSSIOSPEED support",
    ))
}

fn serial_transport_error(message: &str) -> SshRuntimeError {
    SshRuntimeError::Transport {
        message: redact_ssh_diagnostic(message),
    }
}

#[cfg(test)]
mod tests {
    use super::{apply_serial_options, SerialShellChannel};
    use crate::services::live_shell_service::ShellChannel;
    use std::ffi::CStr;
    use std::io::{Read, Write};
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    use std::time::{Duration, Instant};

    #[test]
    fn serial_channel_reads_and_writes_using_pseudo_terminal() {
        let fixture = PseudoTerminalFixture::new();
        let mut channel =
            SerialShellChannel::open(&fixture.slave_path, 9_600).expect("open serial fixture");

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
                baud_rate: 9_600,
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
    fn serial_options_configure_data_bits_parity_stop_bits_and_flow_control() {
        let mut termios = unsafe { std::mem::zeroed::<libc::termios>() };
        let config = crate::domain::serial::SerialConnectionConfig {
            device_path: "/dev/cu.usbserial-001".to_string(),
            baud_rate: 115_200,
            data_bits: 7,
            stop_bits: 2,
            parity: "even".to_string(),
            flow_control: "rtscts".to_string(),
            backspace_mode: "del".to_string(),
        };

        apply_serial_options(&mut termios, &config).expect("apply serial options");

        assert_eq!(termios.c_cflag & libc::CSIZE, libc::CS7);
        assert_ne!(termios.c_cflag & libc::CSTOPB, 0);
        assert_ne!(termios.c_cflag & libc::PARENB, 0);
        assert_eq!(termios.c_cflag & libc::PARODD, 0);
        assert_ne!(termios.c_cflag & libc::CRTSCTS, 0);
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
        let deadline = Instant::now() + Duration::from_secs(2);
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
