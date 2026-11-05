#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct DeviceCpuSample {
    pub total_ticks: u64,
    pub idle_ticks: u64,
    /// Kernel CPU number; absent for the aggregate and legacy snapshots.
    #[serde(default)]
    #[uniffi(default = None)]
    pub core_index: Option<u32>,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct DeviceMemorySample {
    pub total_bytes: u64,
    pub available_bytes: u64,
    #[serde(default)]
    #[uniffi(default = None)]
    pub free_bytes: Option<u64>,
    #[serde(default)]
    #[uniffi(default = None)]
    pub buffers_bytes: Option<u64>,
    /// Page cache plus reclaimable slab, kept separate from MemAvailable.
    #[serde(default)]
    #[uniffi(default = None)]
    pub cached_bytes: Option<u64>,
    #[serde(default)]
    #[uniffi(default = None)]
    pub swap_total_bytes: Option<u64>,
    #[serde(default)]
    #[uniffi(default = None)]
    pub swap_free_bytes: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct DeviceNetworkSample {
    pub name: String,
    pub receive_bytes: u64,
    pub transmit_bytes: u64,
    /// Direct lower interfaces from a complete sysfs topology probe.
    /// None means unavailable; Some([]) means no lower interface was reported.
    #[serde(default)]
    #[uniffi(default = None)]
    pub lower_interface_names: Option<Vec<String>>,
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
pub struct DeviceProcessSample {
    pub pid: u32,
    pub name: String,
    pub cpu_percent_basis_points: u32,
    pub memory_percent_basis_points: u32,
    pub network_bytes_per_second: u64,
    /// Resident set size reported by procfs (or legacy ps), converted to bytes.
    #[serde(default)]
    #[uniffi(default = None)]
    pub resident_bytes: Option<u64>,
    /// Cumulative user + system CPU ticks; the client derives interval usage.
    #[serde(default)]
    #[uniffi(default = None)]
    pub cpu_time_ticks: Option<u64>,
    /// Kernel process start tick, used with PID to reject PID reuse.
    #[serde(default)]
    #[uniffi(default = None)]
    pub start_time_ticks: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct DevicePortSample {
    pub address: String,
    pub protocol: String,
    pub process: String,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct DeviceServiceSample {
    pub name: String,
    pub description: String,
    pub state: String,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct DeviceContainerSample {
    pub id: String,
    pub name: String,
    pub image: String,
    pub status: String,
    pub running: bool,
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
    #[uniffi(default = [])]
    pub processes: Vec<DeviceProcessSample>,
    #[uniffi(default = [])]
    pub ports: Vec<DevicePortSample>,
    #[uniffi(default = [])]
    pub services: Vec<DeviceServiceSample>,
    #[uniffi(default = [])]
    pub containers: Vec<DeviceContainerSample>,
    /// Smoothed TCP round-trip time of this authenticated SSH connection.
    /// macOS reports whole milliseconds; zero means less than one millisecond.
    #[serde(default)]
    #[uniffi(default = None)]
    pub ssh_latency_milliseconds: Option<u32>,
    /// Remote boot-relative clock read immediately after /proc/net/dev.
    #[serde(default)]
    #[uniffi(default = None)]
    pub network_sampled_uptime_ms: Option<u64>,
    /// Remote boot-relative clock read immediately after /proc/diskstats.
    #[serde(default)]
    #[uniffi(default = None)]
    pub disk_io_sampled_uptime_ms: Option<u64>,
    /// Kernel boot identity, when readable; never a local wall-clock timestamp.
    #[serde(default)]
    #[uniffi(default = None)]
    pub boot_id: Option<String>,
    /// The probe emitted counter clock markers, even if both clock reads failed.
    /// False identifies legacy payloads without this timing protocol.
    #[serde(default)]
    #[uniffi(default = false)]
    pub counter_sample_clocks_present: bool,
}

#[cfg(test)]
mod tests {
    use super::{DeviceCpuSample, DeviceMetricsSnapshot, DeviceNetworkSample, DeviceProcessSample};

    #[test]
    fn core_identity_and_network_topology_preserve_legacy_payloads() {
        let mut cpu: DeviceCpuSample = serde_json::from_str(r#"{"total_ticks":100,"idle_ticks":50}"#).unwrap();
        assert_eq!(cpu.core_index, None);
        cpu.core_index = Some(2);
        assert_eq!(serde_json::from_value::<DeviceCpuSample>(serde_json::to_value(&cpu).unwrap()).unwrap(), cpu);
        let mut network: DeviceNetworkSample = serde_json::from_str(r#"{"name":"br0","receive_bytes":100,"transmit_bytes":200}"#).unwrap();
        assert_eq!(network.lower_interface_names, None);
        for lower in [vec![], vec!["eth0".into(), "eth0@vlan".into()]] {
            network.lower_interface_names = Some(lower);
            assert_eq!(serde_json::from_value::<DeviceNetworkSample>(serde_json::to_value(&network).unwrap()).unwrap(), network);
        }
    }

    #[test]
    fn process_rss_preserves_old_payloads_and_zero_resident_samples() {
        let payload = serde_json::json!({
            "pid": 12, "name": "worker", "cpu_percent_basis_points": 125,
            "memory_percent_basis_points": 250, "network_bytes_per_second": 0
        });
        let mut process: DeviceProcessSample = serde_json::from_value(payload).unwrap();
        assert_eq!(process.resident_bytes, None);
        assert_eq!(process.cpu_time_ticks, None);
        assert_eq!(process.start_time_ticks, None);
        for resident in [0, 1024, u64::MAX] {
            process.resident_bytes = Some(resident);
            process.cpu_time_ticks = Some(resident);
            process.start_time_ticks = Some(resident);
            let decoded: DeviceProcessSample =
                serde_json::from_str(&serde_json::to_string(&process).unwrap()).unwrap();
            assert_eq!(decoded.resident_bytes, Some(resident));
            assert_eq!(decoded.cpu_time_ticks, Some(resident));
            assert_eq!(decoded.start_time_ticks, Some(resident));
        }
    }

    #[test]
    fn snapshot_latency_preserves_old_payloads_and_zero_millisecond_samples() {
        let payload = serde_json::json!({
            "sampled_at_ms": 1000,
            "system": {
                "hostname": "test", "current_user": "test", "architecture": "arm64",
                "operating_system": "Linux", "uptime_seconds": null,
                "kernel_release": "test", "cpu_model": "test"
            },
            "cpu": {"total_ticks": 100, "idle_ticks": 80}, "cpu_cores": [],
            "memory": {"total_bytes": 1000, "available_bytes": 500},
            "network_interfaces": [], "disk_io": null, "disks": [],
            "processes": [], "ports": [], "services": [], "containers": []
        });
        let mut snapshot: DeviceMetricsSnapshot = serde_json::from_value(payload).unwrap();
        assert_eq!(snapshot.ssh_latency_milliseconds, None);
        assert_eq!(snapshot.network_sampled_uptime_ms, None);
        assert_eq!(snapshot.disk_io_sampled_uptime_ms, None);
        assert_eq!(snapshot.boot_id, None);
        assert!(!snapshot.counter_sample_clocks_present);
        snapshot.counter_sample_clocks_present = true;
        snapshot.network_sampled_uptime_ms = Some(0);
        snapshot.disk_io_sampled_uptime_ms = Some(1500);
        snapshot.boot_id = Some("boot-a".into());
        for latency in [0, 12, 250] {
            snapshot.ssh_latency_milliseconds = Some(latency);
            let decoded: DeviceMetricsSnapshot =
                serde_json::from_str(&serde_json::to_string(&snapshot).unwrap()).unwrap();
            assert_eq!(decoded.ssh_latency_milliseconds, Some(latency));
            assert_eq!(decoded.network_sampled_uptime_ms, Some(0));
            assert_eq!(decoded.disk_io_sampled_uptime_ms, Some(1500));
            assert_eq!(decoded.boot_id.as_deref(), Some("boot-a"));
            assert!(decoded.counter_sample_clocks_present);
        }
    }
}
