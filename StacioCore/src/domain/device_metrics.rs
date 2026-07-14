#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct DeviceCpuSample {
    pub total_ticks: u64,
    pub idle_ticks: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct DeviceMemorySample {
    pub total_bytes: u64,
    pub available_bytes: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct DeviceNetworkSample {
    pub name: String,
    pub receive_bytes: u64,
    pub transmit_bytes: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct DeviceDiskSample {
    pub mount_path: String,
    pub used_bytes: u64,
    pub total_bytes: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct DeviceDiskIOSample {
    pub read_bytes: u64,
    pub write_bytes: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct DeviceSystemInfo {
    pub hostname: String,
    pub current_user: String,
    pub architecture: String,
    pub operating_system: String,
    pub uptime_seconds: Option<u64>,
    pub kernel_release: String,
    pub cpu_model: String,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct DeviceMetricsSnapshot {
    pub sampled_at_ms: u64,
    pub system: DeviceSystemInfo,
    pub cpu: DeviceCpuSample,
    pub cpu_cores: Vec<DeviceCpuSample>,
    pub memory: DeviceMemorySample,
    pub network_interfaces: Vec<DeviceNetworkSample>,
    pub disk_io: Option<DeviceDiskIOSample>,
    pub disks: Vec<DeviceDiskSample>,
}
