pub const CONSOLE_SCHEMA_VERSION: u32 = 1;
pub const CONSOLE_TRANSPORT_PREFER_BLE: &str = "prefer_ble";
pub const BTERM_FFE0_SHARED_PROFILE_ID: &str = "bterm-ffe0-shared-v1";
pub const BTERM_FFE1_SPLIT_PROFILE_ID: &str = "bterm-ffe1-split-v1";
pub const CUSTOM_CONSOLE_PROFILE_ID: &str = "custom-v1";

const BLUETOOTH_BASE_UUID_SUFFIX: &str = "-0000-1000-8000-00805f9b34fb";
const FFE0_UUID: &str = "0000ffe0-0000-1000-8000-00805f9b34fb";
const FFE1_UUID: &str = "0000ffe1-0000-1000-8000-00805f9b34fb";
const FFE2_UUID: &str = "0000ffe2-0000-1000-8000-00805f9b34fb";
const FFE3_UUID: &str = "0000ffe3-0000-1000-8000-00805f9b34fb";

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase")]
pub struct ConsoleSessionConfig {
    pub kind: String,
    pub schema_version: u32,
    pub transport_policy: String,
    pub ble: ConsoleBleConfig,
    pub spp_fallback: Option<ConsoleSppFallbackConfig>,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase")]
pub struct ConsoleBleConfig {
    pub device_name: String,
    #[serde(rename = "profileID")]
    pub profile_id: String,
    #[serde(rename = "serviceUUID")]
    pub service_uuid: String,
    #[serde(rename = "txCharacteristicUUID")]
    pub tx_characteristic_uuid: String,
    #[serde(rename = "rxCharacteristicUUID")]
    pub rx_characteristic_uuid: String,
    pub write_type: String,
    pub platform_bindings: ConsolePlatformBindings,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct ConsolePlatformBindings {
    #[serde(rename = "macOSPeripheralUUID")]
    pub mac_os_peripheral_uuid: Option<String>,
    #[serde(rename = "windowsDeviceID")]
    pub windows_device_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase")]
pub struct ConsoleSppFallbackConfig {
    pub enabled_platforms: Vec<String>,
    pub windows_port: Option<String>,
    pub baud_rate: u32,
    pub data_bits: u8,
    pub stop_bits: u8,
    pub parity: String,
    pub flow_control: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ConsoleCharacteristicMetadata {
    pub uuid: String,
    pub supports_write: bool,
    pub supports_write_without_response: bool,
    pub supports_notify: bool,
    pub supports_indicate: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ConsoleServiceMetadata {
    pub uuid: String,
    pub characteristics: Vec<ConsoleCharacteristicMetadata>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ConsoleProfileMatch {
    pub profile_id: String,
    pub service_uuid: String,
    pub tx_characteristic_uuid: String,
    pub rx_characteristic_uuid: String,
    pub write_type: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum ConsolePlatform {
    Macos,
    Windows,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum ConsoleTransportDecision {
    BleOnly,
    BleThenBoundSpp { windows_port: String },
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum ConsoleConfigError {
    #[error("BLE_CONSOLE_CONFIG_INVALID: {message}")]
    Invalid { message: String },
}

pub fn normalize_bluetooth_uuid(value: &str) -> Option<String> {
    let trimmed = value.trim();
    if matches!(trimmed.len(), 4 | 8) && trimmed.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        let prefix = if trimmed.len() == 4 {
            format!("0000{}", trimmed.to_ascii_lowercase())
        } else {
            trimmed.to_ascii_lowercase()
        };
        return Some(format!("{prefix}{BLUETOOTH_BASE_UUID_SUFFIX}"));
    }

    uuid::Uuid::parse_str(trimmed)
        .ok()
        .map(|uuid| uuid.hyphenated().to_string())
}

pub fn parse_console_config(json: String) -> Result<ConsoleSessionConfig, ConsoleConfigError> {
    let config = serde_json::from_str::<ConsoleSessionConfig>(&json)
        .map_err(|_| invalid_config("JSON does not match Console v1"))?;
    validate_and_normalize_config(config)
}

pub fn serialize_console_config(
    config: ConsoleSessionConfig,
) -> Result<String, ConsoleConfigError> {
    let normalized = validate_and_normalize_config(config)?;
    serde_json::to_string(&normalized)
        .map_err(|_| invalid_config("Console v1 could not be serialized"))
}

pub fn match_console_profile(services: Vec<ConsoleServiceMetadata>) -> Option<ConsoleProfileMatch> {
    match_split_profile(&services).or_else(|| match_shared_profile(&services))
}

pub fn resolve_console_transport_policy(
    platform: ConsolePlatform,
    windows_port: Option<String>,
) -> ConsoleTransportDecision {
    if !matches!(platform, ConsolePlatform::Windows) {
        return ConsoleTransportDecision::BleOnly;
    }

    match windows_port.filter(|port| is_exact_windows_com_port(port)) {
        Some(windows_port) => ConsoleTransportDecision::BleThenBoundSpp { windows_port },
        None => ConsoleTransportDecision::BleOnly,
    }
}

fn validate_and_normalize_config(
    mut config: ConsoleSessionConfig,
) -> Result<ConsoleSessionConfig, ConsoleConfigError> {
    if config.kind != "console" {
        return Err(invalid_config("kind must be console"));
    }
    if config.schema_version != CONSOLE_SCHEMA_VERSION {
        return Err(invalid_config("unsupported schemaVersion"));
    }
    if config.transport_policy != CONSOLE_TRANSPORT_PREFER_BLE {
        return Err(invalid_config("transportPolicy must be prefer_ble"));
    }

    let device_name = config.ble.device_name.trim();
    if device_name.is_empty() || device_name.chars().any(char::is_control) {
        return Err(invalid_config("deviceName is invalid"));
    }
    config.ble.device_name = device_name.to_string();

    config.ble.service_uuid = normalized_config_uuid(&config.ble.service_uuid, "serviceUUID")?;
    config.ble.tx_characteristic_uuid =
        normalized_config_uuid(&config.ble.tx_characteristic_uuid, "txCharacteristicUUID")?;
    config.ble.rx_characteristic_uuid =
        normalized_config_uuid(&config.ble.rx_characteristic_uuid, "rxCharacteristicUUID")?;

    if !matches!(
        config.ble.write_type.as_str(),
        "without_response" | "with_response"
    ) {
        return Err(invalid_config("writeType is unsupported"));
    }

    match config.ble.profile_id.as_str() {
        BTERM_FFE1_SPLIT_PROFILE_ID => {
            validate_catalog_uuids(&config.ble, FFE1_UUID, FFE3_UUID, FFE2_UUID)?
        }
        BTERM_FFE0_SHARED_PROFILE_ID => {
            validate_catalog_uuids(&config.ble, FFE0_UUID, FFE1_UUID, FFE1_UUID)?
        }
        CUSTOM_CONSOLE_PROFILE_ID => {}
        _ => return Err(invalid_config("profileID is unsupported")),
    }

    validate_opaque_binding(
        config
            .ble
            .platform_bindings
            .mac_os_peripheral_uuid
            .as_deref(),
        "macOSPeripheralUUID",
    )?;
    validate_opaque_binding(
        config.ble.platform_bindings.windows_device_id.as_deref(),
        "windowsDeviceID",
    )?;

    if let Some(fallback) = config.spp_fallback.as_ref() {
        validate_spp_fallback(fallback)?;
    }

    Ok(config)
}

fn normalized_config_uuid(value: &str, field: &str) -> Result<String, ConsoleConfigError> {
    normalize_bluetooth_uuid(value).ok_or_else(|| invalid_config(format!("{field} is invalid")))
}

fn validate_catalog_uuids(
    config: &ConsoleBleConfig,
    service_uuid: &str,
    tx_characteristic_uuid: &str,
    rx_characteristic_uuid: &str,
) -> Result<(), ConsoleConfigError> {
    if config.service_uuid != service_uuid
        || config.tx_characteristic_uuid != tx_characteristic_uuid
        || config.rx_characteristic_uuid != rx_characteristic_uuid
    {
        return Err(invalid_config(
            "profile UUIDs do not match the built-in catalog",
        ));
    }
    Ok(())
}

fn validate_opaque_binding(value: Option<&str>, field: &str) -> Result<(), ConsoleConfigError> {
    if value.is_some_and(|value| value.trim().is_empty() || value.chars().any(char::is_control)) {
        return Err(invalid_config(format!("{field} is invalid")));
    }
    Ok(())
}

fn validate_spp_fallback(fallback: &ConsoleSppFallbackConfig) -> Result<(), ConsoleConfigError> {
    let windows_count = fallback
        .enabled_platforms
        .iter()
        .filter(|platform| platform.as_str() == "windows")
        .count();
    if windows_count != fallback.enabled_platforms.len() || windows_count > 1 {
        return Err(invalid_config(
            "sppFallback is supported only for one windows binding",
        ));
    }
    if fallback
        .windows_port
        .as_ref()
        .is_some_and(|port| !is_exact_windows_com_port(port))
    {
        return Err(invalid_config("windowsPort must be an exact COM endpoint"));
    }
    if fallback.baud_rate == 0
        || !matches!(fallback.data_bits, 5 | 6 | 7 | 8)
        || !matches!(fallback.stop_bits, 1 | 2)
        || !matches!(fallback.parity.as_str(), "none" | "odd" | "even")
        || !matches!(
            fallback.flow_control.as_str(),
            "none" | "rtscts" | "xonxoff"
        )
    {
        return Err(invalid_config("sppFallback serial settings are invalid"));
    }
    Ok(())
}

fn match_split_profile(services: &[ConsoleServiceMetadata]) -> Option<ConsoleProfileMatch> {
    let service = find_service(services, FFE1_UUID)?;
    let tx = find_characteristic(&service.characteristics, FFE3_UUID)?;
    let rx = find_characteristic(&service.characteristics, FFE2_UUID)?;
    let write_type = supported_write_type(tx)?;
    if !supports_receive(rx) {
        return None;
    }

    Some(ConsoleProfileMatch {
        profile_id: BTERM_FFE1_SPLIT_PROFILE_ID.to_string(),
        service_uuid: FFE1_UUID.to_string(),
        tx_characteristic_uuid: FFE3_UUID.to_string(),
        rx_characteristic_uuid: FFE2_UUID.to_string(),
        write_type: write_type.to_string(),
    })
}

fn match_shared_profile(services: &[ConsoleServiceMetadata]) -> Option<ConsoleProfileMatch> {
    let service = find_service(services, FFE0_UUID)?;
    let characteristic = find_characteristic(&service.characteristics, FFE1_UUID)?;
    let write_type = supported_write_type(characteristic)?;
    if !supports_receive(characteristic) {
        return None;
    }

    Some(ConsoleProfileMatch {
        profile_id: BTERM_FFE0_SHARED_PROFILE_ID.to_string(),
        service_uuid: FFE0_UUID.to_string(),
        tx_characteristic_uuid: FFE1_UUID.to_string(),
        rx_characteristic_uuid: FFE1_UUID.to_string(),
        write_type: write_type.to_string(),
    })
}

fn find_service<'a>(
    services: &'a [ConsoleServiceMetadata],
    expected_uuid: &str,
) -> Option<&'a ConsoleServiceMetadata> {
    services
        .iter()
        .find(|service| normalize_bluetooth_uuid(&service.uuid).as_deref() == Some(expected_uuid))
}

fn find_characteristic<'a>(
    characteristics: &'a [ConsoleCharacteristicMetadata],
    expected_uuid: &str,
) -> Option<&'a ConsoleCharacteristicMetadata> {
    characteristics.iter().find(|characteristic| {
        normalize_bluetooth_uuid(&characteristic.uuid).as_deref() == Some(expected_uuid)
    })
}

fn supported_write_type(characteristic: &ConsoleCharacteristicMetadata) -> Option<&'static str> {
    if characteristic.supports_write_without_response {
        Some("without_response")
    } else if characteristic.supports_write {
        Some("with_response")
    } else {
        None
    }
}

fn supports_receive(characteristic: &ConsoleCharacteristicMetadata) -> bool {
    characteristic.supports_notify || characteristic.supports_indicate
}

fn is_exact_windows_com_port(value: &str) -> bool {
    let Some(number) = value.strip_prefix("COM") else {
        return false;
    };
    !number.is_empty()
        && number.bytes().all(|byte| byte.is_ascii_digit())
        && number.parse::<u32>().is_ok_and(|number| number > 0)
}

fn invalid_config(message: impl Into<String>) -> ConsoleConfigError {
    ConsoleConfigError::Invalid {
        message: message.into(),
    }
}

#[cfg(test)]
mod tests {
    use super::{
        match_console_profile, normalize_bluetooth_uuid, parse_console_config,
        resolve_console_transport_policy, serialize_console_config, ConsoleBleConfig,
        ConsoleCharacteristicMetadata, ConsolePlatform, ConsolePlatformBindings,
        ConsoleServiceMetadata, ConsoleSessionConfig, ConsoleSppFallbackConfig,
        ConsoleTransportDecision, BTERM_FFE0_SHARED_PROFILE_ID, BTERM_FFE1_SPLIT_PROFILE_ID,
    };

    const FFE0: &str = "0000ffe0-0000-1000-8000-00805f9b34fb";
    const FFE1: &str = "0000ffe1-0000-1000-8000-00805f9b34fb";
    const FFE2: &str = "0000ffe2-0000-1000-8000-00805f9b34fb";
    const FFE3: &str = "0000ffe3-0000-1000-8000-00805f9b34fb";

    fn characteristic(
        uuid: &str,
        supports_write: bool,
        supports_write_without_response: bool,
        supports_notify: bool,
        supports_indicate: bool,
    ) -> ConsoleCharacteristicMetadata {
        ConsoleCharacteristicMetadata {
            uuid: uuid.to_string(),
            supports_write,
            supports_write_without_response,
            supports_notify,
            supports_indicate,
        }
    }

    fn split_ffe1_service() -> ConsoleServiceMetadata {
        ConsoleServiceMetadata {
            uuid: "FFE1".to_string(),
            characteristics: vec![
                characteristic("FFE3", true, true, false, false),
                characteristic("FFE2", false, false, true, false),
            ],
        }
    }

    fn shared_ffe0_service() -> ConsoleServiceMetadata {
        ConsoleServiceMetadata {
            uuid: "FFE0".to_string(),
            characteristics: vec![characteristic("FFE1", true, true, true, false)],
        }
    }

    fn nbee_config() -> ConsoleSessionConfig {
        ConsoleSessionConfig {
            kind: "console".to_string(),
            schema_version: 1,
            transport_policy: "prefer_ble".to_string(),
            ble: ConsoleBleConfig {
                device_name: "NBEE_BLE_1103".to_string(),
                profile_id: BTERM_FFE1_SPLIT_PROFILE_ID.to_string(),
                service_uuid: "FFE1".to_string(),
                tx_characteristic_uuid: "FFE3".to_string(),
                rx_characteristic_uuid: "FFE2".to_string(),
                write_type: "without_response".to_string(),
                platform_bindings: ConsolePlatformBindings {
                    mac_os_peripheral_uuid: Some("opaque-corebluetooth-uuid".to_string()),
                    windows_device_id: Some("opaque-winrt-device-id".to_string()),
                },
            },
            spp_fallback: Some(ConsoleSppFallbackConfig {
                enabled_platforms: vec!["windows".to_string()],
                windows_port: Some("COM7".to_string()),
                baud_rate: 9_600,
                data_bits: 8,
                stop_bits: 1,
                parity: "none".to_string(),
                flow_control: "none".to_string(),
            }),
        }
    }

    #[test]
    fn round_trips_nbee_console_v1_config_with_stable_json_keys() {
        let mut expected = nbee_config();
        expected.ble.service_uuid = FFE1.to_string();
        expected.ble.tx_characteristic_uuid = FFE3.to_string();
        expected.ble.rx_characteristic_uuid = FFE2.to_string();

        let json = serialize_console_config(nbee_config()).expect("serialize console config");
        let decoded = parse_console_config(json.clone()).expect("parse console config");

        assert_eq!(decoded, expected);
        assert!(json.contains(r#""profileID":"bterm-ffe1-split-v1""#));
        assert!(json.contains(r#""serviceUUID":"0000ffe1-0000-1000-8000-00805f9b34fb""#));
        assert!(json.contains(r#""macOSPeripheralUUID":"opaque-corebluetooth-uuid""#));
        assert!(json.contains(r#""windowsDeviceID":"opaque-winrt-device-id""#));
        assert!(!json.contains("macAddress"));
    }

    #[test]
    fn normalizes_short_and_full_bluetooth_uuids() {
        assert_eq!(normalize_bluetooth_uuid(" FFE1 "), Some(FFE1.to_string()));
        assert_eq!(
            normalize_bluetooth_uuid("1234ABCD"),
            Some("1234abcd-0000-1000-8000-00805f9b34fb".to_string())
        );
        assert_eq!(
            normalize_bluetooth_uuid("0000FFE2-0000-1000-8000-00805F9B34FB"),
            Some(FFE2.to_string())
        );
        assert_eq!(normalize_bluetooth_uuid("0xFFE1"), None);
        assert_eq!(normalize_bluetooth_uuid("FFE"), None);
        assert_eq!(normalize_bluetooth_uuid("not-a-uuid"), None);
    }

    #[test]
    fn matches_split_nbee_profile_before_shared_profile() {
        let matched = match_console_profile(vec![shared_ffe0_service(), split_ffe1_service()])
            .expect("profile match");

        assert_eq!(matched.profile_id, BTERM_FFE1_SPLIT_PROFILE_ID);
        assert_eq!(matched.service_uuid, FFE1);
        assert_eq!(matched.tx_characteristic_uuid, FFE3);
        assert_eq!(matched.rx_characteristic_uuid, FFE2);
        assert_eq!(matched.write_type, "without_response");
    }

    #[test]
    fn matches_shared_profile_and_falls_back_to_with_response_write() {
        let mut service = shared_ffe0_service();
        service.characteristics[0].supports_write_without_response = false;

        let matched = match_console_profile(vec![service]).expect("shared profile match");

        assert_eq!(matched.profile_id, BTERM_FFE0_SHARED_PROFILE_ID);
        assert_eq!(matched.service_uuid, FFE0);
        assert_eq!(matched.tx_characteristic_uuid, FFE1);
        assert_eq!(matched.rx_characteristic_uuid, FFE1);
        assert_eq!(matched.write_type, "with_response");
    }

    #[test]
    fn rejects_profile_when_tx_or_rx_properties_are_missing() {
        let mut no_rx = split_ffe1_service();
        no_rx.characteristics[1].supports_notify = false;
        assert_eq!(match_console_profile(vec![no_rx]), None);

        let mut no_tx = split_ffe1_service();
        no_tx.characteristics[0].supports_write = false;
        no_tx.characteristics[0].supports_write_without_response = false;
        assert_eq!(match_console_profile(vec![no_tx]), None);
    }

    #[test]
    fn parser_rejects_unknown_schema_kind_policy_and_profile() {
        let mutations: [fn(&mut ConsoleSessionConfig); 4] = [
            |config: &mut ConsoleSessionConfig| config.schema_version = 2,
            |config: &mut ConsoleSessionConfig| config.kind = "serial".to_string(),
            |config: &mut ConsoleSessionConfig| config.transport_policy = "prefer_spp".to_string(),
            |config: &mut ConsoleSessionConfig| config.ble.profile_id = "unknown-v1".to_string(),
        ];
        for mutation in mutations {
            let mut config = nbee_config();
            mutation(&mut config);
            let raw = serde_json::to_string(&config).expect("raw invalid config");

            let error = parse_console_config(raw).expect_err("reject invalid contract");
            assert!(error.to_string().starts_with("BLE_CONSOLE_CONFIG_INVALID:"));
        }
    }

    #[test]
    fn parser_rejects_invalid_or_mismatched_profile_uuids() {
        for service_uuid in ["invalid", "FFE0"] {
            let mut config = nbee_config();
            config.ble.service_uuid = service_uuid.to_string();
            let raw = serde_json::to_string(&config).expect("raw invalid UUID config");

            parse_console_config(raw).expect_err("reject invalid or mismatched profile UUID");
        }
    }

    #[test]
    fn parser_rejects_unsupported_write_type_and_mac_spp_platform() {
        let mut invalid_write = nbee_config();
        invalid_write.ble.write_type = "automatic".to_string();
        let raw = serde_json::to_string(&invalid_write).expect("raw invalid write type");
        parse_console_config(raw).expect_err("reject unsupported write type");

        let mut mac_fallback = nbee_config();
        mac_fallback
            .spp_fallback
            .as_mut()
            .expect("fallback")
            .enabled_platforms = vec!["macos".to_string()];
        let raw = serde_json::to_string(&mac_fallback).expect("raw mac fallback");
        parse_console_config(raw).expect_err("reject macOS SPP fallback");
    }

    #[test]
    fn parser_accepts_custom_profile_and_preserves_opaque_bindings() {
        let mut config = nbee_config();
        config.ble.profile_id = "custom-v1".to_string();
        config.ble.service_uuid = "12345678-1234-5678-1234-56789ABCDEF0".to_string();
        config.ble.tx_characteristic_uuid = "12345678-1234-5678-1234-56789ABCDEF1".to_string();
        config.ble.rx_characteristic_uuid = "12345678-1234-5678-1234-56789ABCDEF2".to_string();
        config.ble.platform_bindings.mac_os_peripheral_uuid =
            Some("opaque value with spaces".to_string());
        let raw = serde_json::to_string(&config).expect("raw custom profile");

        let decoded = parse_console_config(raw).expect("valid custom profile");

        assert_eq!(
            decoded
                .ble
                .platform_bindings
                .mac_os_peripheral_uuid
                .as_deref(),
            Some("opaque value with spaces")
        );
        assert_eq!(
            decoded.ble.service_uuid,
            "12345678-1234-5678-1234-56789abcdef0"
        );
    }

    #[test]
    fn macos_policy_never_returns_spp_fallback() {
        for windows_port in [None, Some("COM7".to_string())] {
            assert_eq!(
                resolve_console_transport_policy(ConsolePlatform::Macos, windows_port),
                ConsoleTransportDecision::BleOnly
            );
        }
    }

    #[test]
    fn windows_policy_requires_an_exact_saved_com_port() {
        assert_eq!(
            resolve_console_transport_policy(ConsolePlatform::Windows, Some("COM7".to_string())),
            ConsoleTransportDecision::BleThenBoundSpp {
                windows_port: "COM7".to_string()
            }
        );

        for windows_port in [
            None,
            Some("COM0"),
            Some("com7"),
            Some(" COM7"),
            Some("COM7x"),
        ] {
            assert_eq!(
                resolve_console_transport_policy(
                    ConsolePlatform::Windows,
                    windows_port.map(str::to_string)
                ),
                ConsoleTransportDecision::BleOnly
            );
        }
    }
}
