use crate::domain::ssh::SshRuntimeError;

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct SerialConnectionConfig {
    pub device_path: String,
    pub baud_rate: u32,
    pub data_bits: u8,
    pub stop_bits: u8,
    pub parity: String,
    pub flow_control: String,
    pub backspace_mode: String,
}

pub fn validate_serial_config(config: &SerialConnectionConfig) -> Result<(), SshRuntimeError> {
    if config.device_path.trim().is_empty() || config.device_path.chars().any(char::is_control) {
        return Err(SshRuntimeError::InvalidConfig);
    }
    if !matches!(config.data_bits, 5 | 6 | 7 | 8) {
        return Err(SshRuntimeError::InvalidConfig);
    }
    if !matches!(config.stop_bits, 1 | 2) {
        return Err(SshRuntimeError::InvalidConfig);
    }
    if !matches!(
        config.parity.trim().to_ascii_lowercase().as_str(),
        "none" | "odd" | "even"
    ) {
        return Err(SshRuntimeError::InvalidConfig);
    }
    if !matches!(
        config.flow_control.trim().to_ascii_lowercase().as_str(),
        "none" | "rtscts" | "xonxoff"
    ) {
        return Err(SshRuntimeError::InvalidConfig);
    }
    if !matches!(
        config.backspace_mode.trim().to_ascii_lowercase().as_str(),
        "del" | "ctrl_h"
    ) {
        return Err(SshRuntimeError::InvalidConfig);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{validate_serial_config, SerialConnectionConfig};
    use crate::domain::ssh::SshRuntimeError;

    #[test]
    fn rejects_empty_device_path() {
        let config = SerialConnectionConfig {
            device_path: " ".to_string(),
            baud_rate: 9_600,
            data_bits: 8,
            stop_bits: 1,
            parity: "none".to_string(),
            flow_control: "none".to_string(),
            backspace_mode: "del".to_string(),
        };

        let error = validate_serial_config(&config).expect_err("invalid serial config");

        assert_eq!(error, SshRuntimeError::InvalidConfig);
    }

    #[test]
    fn rejects_device_paths_with_control_characters() {
        for device_path in [
            "/dev/cu.usbserial-001\n",
            "/dev/cu.usbserial-001\r",
            "/dev/cu.usbserial-001\u{1b}",
            "/dev/cu.usbserial-001\0extra",
        ] {
            let config = SerialConnectionConfig {
                device_path: device_path.to_string(),
                baud_rate: 9_600,
                data_bits: 8,
                stop_bits: 1,
                parity: "none".to_string(),
                flow_control: "none".to_string(),
                backspace_mode: "del".to_string(),
            };

            let error = validate_serial_config(&config).expect_err("unsafe serial device path");

            assert_eq!(error, SshRuntimeError::InvalidConfig);
        }
    }

    #[test]
    fn accepts_unspecified_baud_rate() {
        let config = SerialConnectionConfig {
            device_path: "/dev/cu.usbserial-001".to_string(),
            baud_rate: 0,
            data_bits: 8,
            stop_bits: 1,
            parity: "none".to_string(),
            flow_control: "none".to_string(),
            backspace_mode: "del".to_string(),
        };

        validate_serial_config(&config).expect("unspecified baud rate");
    }

    #[test]
    fn accepts_custom_and_high_speed_baud_rates() {
        for baud_rate in [74_880, 250_000, 460_800, 921_600] {
            let config = SerialConnectionConfig {
                device_path: "/dev/cu.usbserial-001".to_string(),
                baud_rate,
                data_bits: 8,
                stop_bits: 1,
                parity: "none".to_string(),
                flow_control: "none".to_string(),
                backspace_mode: "del".to_string(),
            };

            validate_serial_config(&config).expect("custom baud rate");
        }
    }

    #[test]
    fn accepts_supported_advanced_serial_options() {
        let config = SerialConnectionConfig {
            device_path: "/dev/cu.usbserial-001".to_string(),
            baud_rate: 115_200,
            data_bits: 7,
            stop_bits: 2,
            parity: "even".to_string(),
            flow_control: "rtscts".to_string(),
            backspace_mode: "del".to_string(),
        };

        validate_serial_config(&config).expect("advanced serial config");
    }

    #[test]
    fn rejects_unsupported_advanced_serial_options() {
        for config in [
            SerialConnectionConfig {
                device_path: "/dev/cu.usbserial-001".to_string(),
                baud_rate: 115_200,
                data_bits: 9,
                stop_bits: 1,
                parity: "none".to_string(),
                flow_control: "none".to_string(),
                backspace_mode: "del".to_string(),
            },
            SerialConnectionConfig {
                device_path: "/dev/cu.usbserial-001".to_string(),
                baud_rate: 115_200,
                data_bits: 8,
                stop_bits: 3,
                parity: "none".to_string(),
                flow_control: "none".to_string(),
                backspace_mode: "del".to_string(),
            },
            SerialConnectionConfig {
                device_path: "/dev/cu.usbserial-001".to_string(),
                baud_rate: 115_200,
                data_bits: 8,
                stop_bits: 1,
                parity: "mark".to_string(),
                flow_control: "none".to_string(),
                backspace_mode: "del".to_string(),
            },
            SerialConnectionConfig {
                device_path: "/dev/cu.usbserial-001".to_string(),
                baud_rate: 115_200,
                data_bits: 8,
                stop_bits: 1,
                parity: "none".to_string(),
                flow_control: "hardware".to_string(),
                backspace_mode: "del".to_string(),
            },
        ] {
            let error = validate_serial_config(&config).expect_err("invalid serial config");
            assert_eq!(error, SshRuntimeError::InvalidConfig);
        }
    }

    #[test]
    fn serial_config_debug_contains_no_system_command_or_secret() {
        let config = SerialConnectionConfig {
            device_path: "/dev/cu.usbserial-001".to_string(),
            baud_rate: 115_200,
            data_bits: 8,
            stop_bits: 1,
            parity: "none".to_string(),
            flow_control: "none".to_string(),
            backspace_mode: "del".to_string(),
        };

        validate_serial_config(&config).expect("valid config");

        let debug = format!("{config:?}");
        assert!(!debug.contains("screen "));
        assert!(!debug.contains("cu "));
        assert!(!debug.contains("minicom "));
        assert!(!debug.contains("password"));
        assert!(!debug.contains("secret"));
    }
}
