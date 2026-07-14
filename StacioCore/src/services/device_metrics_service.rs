use crate::domain::device_metrics::{
    DeviceCpuSample, DeviceDiskIOSample, DeviceDiskSample, DeviceMemorySample,
    DeviceMetricsSnapshot, DeviceNetworkSample, DeviceSystemInfo,
};
use std::collections::HashMap;

const SYSTEM_MARKER: &str = "__PD_SYSTEM__";
const OS_RELEASE_MARKER: &str = "__PD_OS_RELEASE__";
const CPUINFO_MARKER: &str = "__PD_CPUINFO__";
const CPU_MARKER: &str = "__PD_CPU__";
const MEM_MARKER: &str = "__PD_MEM__";
const NET_MARKER: &str = "__PD_NET__";
const DISKSTATS_MARKER: &str = "__PD_DISKSTATS__";
const DF_MARKER: &str = "__PD_DF__";
const MOUNTS_MARKER: &str = "__PD_MOUNTS__";
const METRICS_PARSE_FAILED: &str = "METRICS_PARSE_FAILED";
const METRICS_MISSING_CPU: &str = "METRICS_PROBE_MISSING_CPU:/proc/stat";
const METRICS_MISSING_MEMORY: &str = "METRICS_PROBE_MISSING_MEMORY:/proc/meminfo";
const METRICS_MISSING_NETWORK: &str = "METRICS_PROBE_MISSING_NETWORK:/proc/net/dev";
const METRICS_MISSING_DISK: &str = "METRICS_PROBE_MISSING_DISK:df";

pub fn build_device_metrics_probe_command() -> String {
    [
        "export LC_ALL=C",
        "export LANG=C",
        "pd_read_file() { if command -v cat >/dev/null 2>&1; then cat \"$1\" 2>/dev/null; else while IFS= read -r pd_line; do printf '%s\\n' \"$pd_line\"; done < \"$1\" 2>/dev/null; fi; }",
        concat!(
            "pd_read_first_cpu_model() { ",
            "awk -F: '{ pd_key=tolower($1); ",
            "gsub(/^[[:space:]]+|[[:space:]]+$/, \"\", pd_key); ",
            "if (pd_key == \"model name\" || pd_key == \"cpu model\" || ",
            "pd_key == \"machine\" || pd_key == \"model\" || pd_key == \"hardware\" || ",
            "pd_key == \"processor\" || pd_key == \"cpu\") { ",
            "pd_value=substr($0, index($0, \":\") + 1); ",
            "gsub(/^[[:space:]]+|[[:space:]]+$/, \"\", pd_value); ",
            "if (pd_value ~ /[[:alpha:]]/) { ",
            "printf \"%s:%s\\n\", pd_key, pd_value; exit } } }' \"$1\" 2>/dev/null; }"
        ),
        "printf '__PD_SYSTEM__\\n'",
        "pd_hostname=\"$(hostname 2>/dev/null || pd_read_file /proc/sys/kernel/hostname || true)\"",
        "printf 'hostname=%s\\n' \"$pd_hostname\"",
        "printf 'current_user=%s\\n' \"$(id -un 2>/dev/null || whoami 2>/dev/null || true)\"",
        "printf 'architecture=%s\\n' \"$(uname -m 2>/dev/null || true)\"",
        "printf 'kernel_name=%s\\n' \"$(uname -s 2>/dev/null || true)\"",
        "printf 'kernel_release=%s\\n' \"$(uname -r 2>/dev/null || true)\"",
        "pd_uptime=''",
        "IFS=' .' read -r pd_uptime _ < /proc/uptime 2>/dev/null || true",
        "printf 'uptime_seconds=%s\\n' \"$pd_uptime\"",
        "printf '__PD_OS_RELEASE__\\n'",
        "(pd_read_file /etc/os-release || pd_read_file /usr/lib/os-release || true)",
        "printf '__PD_CPUINFO__\\n'",
        "pd_read_first_cpu_model /proc/cpuinfo || true",
        "printf '__PD_CPU__\\n'",
        "pd_read_file /proc/stat",
        "printf '__PD_MEM__\\n'",
        "pd_read_file /proc/meminfo",
        "printf '__PD_NET__\\n'",
        "pd_read_file /proc/net/dev",
        "printf '__PD_DISKSTATS__\\n'",
        "pd_read_file /proc/diskstats || true",
        "printf '__PD_DF__\\n'",
        "(df -PT -B1 2>/dev/null || df -P -B1 2>/dev/null || df -P -k 2>/dev/null || df -k 2>/dev/null || true)",
        "printf '__PD_MOUNTS__\\n'",
        "pd_read_file /proc/mounts || true",
    ]
    .join("; ")
}

pub fn parse_device_metrics_probe(
    output: &str,
    sampled_at_ms: u64,
) -> Result<DeviceMetricsSnapshot, String> {
    let lines = output.lines().collect::<Vec<_>>();
    validate_probe_sections(&lines)?;
    let system = parse_system_info(&lines);
    let cpu = parse_cpu(&lines)?;
    let cpu_cores = parse_cpu_cores(&lines);
    let memory = parse_memory(&lines)?;
    let network_interfaces = parse_networks(&lines)?;
    let disk_io = parse_disk_io(&lines);
    let disks = parse_disks(&lines)?;

    Ok(DeviceMetricsSnapshot {
        sampled_at_ms,
        system,
        cpu,
        cpu_cores,
        memory,
        network_interfaces,
        disk_io,
        disks,
    })
}

fn validate_probe_sections(lines: &[&str]) -> Result<(), String> {
    let has_cpu = lines
        .iter()
        .any(|line| line.trim_start().starts_with(CPU_MARKER));
    if !has_cpu {
        return Err(METRICS_MISSING_CPU.to_string());
    }
    if !has_marker(lines, MEM_MARKER) {
        return Err(METRICS_MISSING_MEMORY.to_string());
    }
    if !has_marker(lines, NET_MARKER) {
        return Err(METRICS_MISSING_NETWORK.to_string());
    }
    if !has_marker(lines, DF_MARKER) {
        return Err(METRICS_MISSING_DISK.to_string());
    }
    Ok(())
}

fn has_marker(lines: &[&str], marker: &str) -> bool {
    lines.iter().any(|line| line.trim() == marker)
}

fn parse_system_info(lines: &[&str]) -> DeviceSystemInfo {
    let system_values = parse_key_value_section(
        &section_between(lines, SYSTEM_MARKER, OS_RELEASE_MARKER).unwrap_or_default(),
    );
    let os_release_end_marker = if has_marker(lines, CPUINFO_MARKER) {
        CPUINFO_MARKER
    } else {
        CPU_MARKER
    };
    let os_release_values = parse_key_value_section(
        &section_between(lines, OS_RELEASE_MARKER, os_release_end_marker).unwrap_or_default(),
    );
    let kernel_name = trimmed_value(system_values.get("kernel_name"));
    let cpu_info = section_between(lines, CPUINFO_MARKER, CPU_MARKER).unwrap_or_default();

    DeviceSystemInfo {
        hostname: trimmed_value(system_values.get("hostname")).unwrap_or_default(),
        current_user: trimmed_value(system_values.get("current_user")).unwrap_or_default(),
        architecture: trimmed_value(system_values.get("architecture")).unwrap_or_default(),
        operating_system: detailed_operating_system(&os_release_values, kernel_name),
        uptime_seconds: trimmed_value(system_values.get("uptime_seconds"))
            .and_then(|value| value.parse::<u64>().ok()),
        kernel_release: trimmed_value(system_values.get("kernel_release")).unwrap_or_default(),
        cpu_model: parse_cpu_model(&cpu_info),
    }
}

fn detailed_operating_system(
    os_release_values: &HashMap<String, String>,
    kernel_name: Option<String>,
) -> String {
    let version = trimmed_value(os_release_values.get("VERSION"))
        .or_else(|| trimmed_value(os_release_values.get("VERSION_ID")));
    if let Some(pretty_name) = trimmed_value(os_release_values.get("PRETTY_NAME")) {
        return append_missing_version(pretty_name, version);
    }
    if let Some(name) = trimmed_value(os_release_values.get("NAME")) {
        return append_missing_version(name, version);
    }
    kernel_name.unwrap_or_default()
}

fn append_missing_version(base: String, version: Option<String>) -> String {
    let Some(version) = version else {
        return base;
    };
    let version = version.trim();
    if version.is_empty() || base.contains(version) {
        return base;
    }
    if let Some(details_index) = version.find(" (") {
        let version_prefix = version[..details_index].trim();
        if version_prefix.is_empty() == false && base.contains(version_prefix) {
            let details = version[details_index + 1..].trim();
            if details.is_empty() || base.contains(details) {
                return base;
            }
            return format!("{base} {details}");
        }
    }
    format!("{base} {version}")
}

fn parse_cpu_model(lines: &[&str]) -> String {
    let model_keys = [
        "model name",
        "cpu model",
        "machine",
        "model",
        "hardware",
        "processor",
        "cpu",
    ];
    for line in lines {
        let Some((line_key, value)) = line.split_once(':') else {
            continue;
        };
        let line_key = line_key.trim().to_ascii_lowercase();
        let value = value.trim();
        if model_keys.contains(&line_key.as_str())
            && value.is_empty() == false
            && value.chars().any(|character| character.is_alphabetic())
        {
            return value.to_string();
        }
    }
    String::new()
}

fn parse_key_value_section(lines: &[&str]) -> HashMap<String, String> {
    lines
        .iter()
        .filter_map(|line| {
            let (key, value) = line.split_once('=')?;
            Some((key.trim().to_string(), normalize_key_value(value)))
        })
        .collect()
}

fn trimmed_value(value: Option<&String>) -> Option<String> {
    let trimmed = value?.trim();
    (trimmed.is_empty() == false).then(|| trimmed.to_string())
}

fn normalize_key_value(value: &str) -> String {
    let trimmed = value.trim();
    let unquoted = if trimmed.len() >= 2 && trimmed.starts_with('"') && trimmed.ends_with('"') {
        &trimmed[1..trimmed.len() - 1]
    } else {
        trimmed
    };
    unquoted.replace("\\\"", "\"").replace("\\\\", "\\")
}

fn parse_cpu(lines: &[&str]) -> Result<DeviceCpuSample, String> {
    let cpu_lines = cpu_stat_lines(lines);
    let line = cpu_lines
        .iter()
        .copied()
        .find(|line| line.split_whitespace().next() == Some("cpu"))
        .ok_or_else(|| METRICS_PARSE_FAILED.to_string())?;
    parse_cpu_sample_line(line)
}

fn parse_cpu_cores(lines: &[&str]) -> Vec<DeviceCpuSample> {
    cpu_stat_lines(lines)
        .into_iter()
        .filter_map(|line| {
            let first = line.split_whitespace().next()?;
            let index = first.strip_prefix("cpu")?;
            if index.is_empty() || index.chars().any(|character| !character.is_ascii_digit()) {
                return None;
            }
            parse_cpu_sample_line(line).ok()
        })
        .collect()
}

fn cpu_stat_lines<'a>(lines: &'a [&'a str]) -> Vec<&'a str> {
    for line in lines {
        let trimmed = line.trim_start();
        if let Some(inline_cpu) = trimmed.strip_prefix(CPU_MARKER) {
            let inline_cpu = inline_cpu.trim();
            if inline_cpu.is_empty() == false {
                return vec![inline_cpu];
            }
            return section_between(lines, CPU_MARKER, MEM_MARKER).unwrap_or_default();
        }
    }
    Vec::new()
}

fn parse_cpu_sample_line(line: &str) -> Result<DeviceCpuSample, String> {
    let parts = line.split_whitespace().collect::<Vec<_>>();
    if parts.len() < 5 {
        return Err(METRICS_PARSE_FAILED.to_string());
    }
    let ticks = parts[1..]
        .iter()
        .map(|part| part.parse::<u64>())
        .collect::<Result<Vec<_>, _>>()
        .map_err(|_| METRICS_PARSE_FAILED.to_string())?;
    let total_ticks = ticks.iter().sum();
    let idle_ticks = ticks.get(3).copied().unwrap_or(0) + ticks.get(4).copied().unwrap_or(0);

    Ok(DeviceCpuSample {
        total_ticks,
        idle_ticks,
    })
}

fn parse_memory(lines: &[&str]) -> Result<DeviceMemorySample, String> {
    let section = section_between(lines, MEM_MARKER, NET_MARKER).unwrap_or_default();
    let mut total_kb = None;
    let mut available_kb = None;
    let mut free_kb = None;
    let mut buffers_kb = None;
    let mut cached_kb = None;
    let mut reclaimable_kb = None;
    let mut shared_kb = None;

    for line in section {
        let mut parts = line.split_whitespace();
        match parts.next() {
            Some("MemTotal:") => total_kb = parse_kb(parts.next()),
            Some("MemAvailable:") => available_kb = parse_kb(parts.next()),
            Some("MemFree:") => free_kb = parse_kb(parts.next()),
            Some("Buffers:") => buffers_kb = parse_kb(parts.next()),
            Some("Cached:") => cached_kb = parse_kb(parts.next()),
            Some("SReclaimable:") => reclaimable_kb = parse_kb(parts.next()),
            Some("Shmem:") => shared_kb = parse_kb(parts.next()),
            _ => {}
        }
    }

    let total_bytes = total_kb
        .ok_or_else(|| METRICS_PARSE_FAILED.to_string())?
        .saturating_mul(1024);
    let legacy_available_kb = free_kb.map(|free| {
        free.saturating_add(buffers_kb.unwrap_or(0))
            .saturating_add(cached_kb.unwrap_or(0))
            .saturating_add(reclaimable_kb.unwrap_or(0))
            .saturating_sub(shared_kb.unwrap_or(0))
    });
    let available_bytes = available_kb
        .or(legacy_available_kb)
        .ok_or_else(|| METRICS_PARSE_FAILED.to_string())?
        .saturating_mul(1024);

    Ok(DeviceMemorySample {
        total_bytes,
        available_bytes: available_bytes.min(total_bytes),
    })
}

fn parse_networks(lines: &[&str]) -> Result<Vec<DeviceNetworkSample>, String> {
    let section = section_between(lines, NET_MARKER, DISKSTATS_MARKER)
        .or_else(|| section_between(lines, NET_MARKER, DF_MARKER))
        .unwrap_or_default();
    let mut samples = Vec::new();
    for line in section {
        let Some((name, values)) = line.rsplit_once(':') else {
            continue;
        };
        let name = normalize_network_interface_name(name.trim());
        if name.is_empty() || name == "lo" {
            continue;
        }
        let values = values.split_whitespace().collect::<Vec<_>>();
        if values.len() < 16 {
            continue;
        }
        let Ok(receive_bytes) = values[0].parse::<u64>() else {
            continue;
        };
        let Ok(transmit_bytes) = values[8].parse::<u64>() else {
            continue;
        };
        samples.push(DeviceNetworkSample {
            name,
            receive_bytes,
            transmit_bytes,
        });
    }
    Ok(samples)
}

fn parse_disk_io(lines: &[&str]) -> Option<DeviceDiskIOSample> {
    let section = section_between(lines, DISKSTATS_MARKER, DF_MARKER)?;
    let mut total_read_sectors = 0_u64;
    let mut total_write_sectors = 0_u64;
    let mut has_device = false;

    for line in section {
        let parts = line.split_whitespace().collect::<Vec<_>>();
        if parts.len() < 10 {
            continue;
        }
        let device_name = parts[2];
        if !is_included_disk_io_device(device_name) {
            continue;
        }
        let Ok(read_sectors) = parts[5].parse::<u64>() else {
            continue;
        };
        let Ok(write_sectors) = parts[9].parse::<u64>() else {
            continue;
        };
        has_device = true;
        total_read_sectors = total_read_sectors.saturating_add(read_sectors);
        total_write_sectors = total_write_sectors.saturating_add(write_sectors);
    }

    has_device.then(|| DeviceDiskIOSample {
        read_bytes: total_read_sectors.saturating_mul(512),
        write_bytes: total_write_sectors.saturating_mul(512),
    })
}

fn is_included_disk_io_device(name: &str) -> bool {
    let lowercased = name.to_ascii_lowercase();
    if lowercased.starts_with("loop")
        || lowercased.starts_with("ram")
        || lowercased.starts_with("fd")
        || lowercased.starts_with("sr")
    {
        return false;
    }
    if is_lettered_partition(&lowercased, "sd")
        || is_lettered_partition(&lowercased, "vd")
        || is_lettered_partition(&lowercased, "xvd")
        || is_lettered_partition(&lowercased, "hd")
        || is_nvme_partition(&lowercased)
        || is_mmc_partition(&lowercased)
    {
        return false;
    }
    true
}

fn is_lettered_partition(name: &str, prefix: &str) -> bool {
    let Some(suffix) = name.strip_prefix(prefix) else {
        return false;
    };
    let split_index = suffix
        .char_indices()
        .find_map(|(index, character)| character.is_ascii_digit().then_some(index));
    let Some(split_index) = split_index else {
        return false;
    };
    let (letters, digits) = suffix.split_at(split_index);
    !letters.is_empty()
        && letters
            .chars()
            .all(|character| character.is_ascii_lowercase())
        && !digits.is_empty()
        && digits.chars().all(|character| character.is_ascii_digit())
}

fn is_nvme_partition(name: &str) -> bool {
    let Some(partition_index) = name.rfind('p') else {
        return false;
    };
    let (disk_name, partition) = name.split_at(partition_index);
    if partition.len() <= 1
        || !partition[1..]
            .chars()
            .all(|character| character.is_ascii_digit())
    {
        return false;
    }
    let Some(namespace_index) = disk_name.rfind('n') else {
        return false;
    };
    let (controller, namespace) = disk_name.split_at(namespace_index);
    controller.strip_prefix("nvme").is_some_and(|value| {
        !value.is_empty() && value.chars().all(|character| character.is_ascii_digit())
    }) && namespace.len() > 1
        && namespace[1..]
            .chars()
            .all(|character| character.is_ascii_digit())
}

fn is_mmc_partition(name: &str) -> bool {
    let Some(partition_index) = name.rfind('p') else {
        return false;
    };
    let (disk_name, partition) = name.split_at(partition_index);
    disk_name.strip_prefix("mmcblk").is_some_and(|value| {
        !value.is_empty() && value.chars().all(|character| character.is_ascii_digit())
    }) && partition.len() > 1
        && partition[1..]
            .chars()
            .all(|character| character.is_ascii_digit())
}

fn normalize_network_interface_name(name: &str) -> String {
    name.split('@').next().unwrap_or(name).trim().to_string()
}

fn parse_disks(lines: &[&str]) -> Result<Vec<DeviceDiskSample>, String> {
    let section = section_after_until(lines, DF_MARKER, Some(MOUNTS_MARKER));
    let mount_types = parse_mount_types(lines);
    let mut all_disks = Vec::new();
    let mut physical_disks = Vec::new();
    let mut root_disks = Vec::new();
    let mut block_multiplier = 1_u64;
    let mut has_type_column = false;

    let mut pending_filesystem: Option<&str> = None;

    for line in section {
        let parts = line.split_whitespace().collect::<Vec<_>>();
        let has_wrapped_filesystem = pending_filesystem.is_some() && parts.len() >= 5;
        if parts.len() < 6 && has_wrapped_filesystem == false {
            if parts.len() == 1 && parts[0] != DF_MARKER {
                pending_filesystem = Some(parts[0]);
            }
            continue;
        }
        if parts[0] == "Filesystem" || parts[0] == "文件系统" {
            has_type_column = matches!(parts.get(1).copied(), Some("Type") | Some("类型"));
            let block_header_index = if has_type_column { 2 } else { 1 };
            block_multiplier = disk_block_multiplier(parts.get(block_header_index).copied());
            continue;
        }
        let (filesystem, fs_type_from_df, total_index, used_index, mount_index) =
            if let Some(filesystem) = pending_filesystem.take() {
                if has_type_column {
                    (filesystem, parts.first().copied(), 1, 2, 5)
                } else {
                    (filesystem, None, 0, 1, 4)
                }
            } else if has_type_column {
                (parts[0], parts.get(1).copied(), 2, 3, 6)
            } else {
                (parts[0], None, 1, 2, 5)
            };
        let Ok(total_blocks) = parts[total_index].parse::<u64>() else {
            continue;
        };
        let Ok(used_blocks) = parts[used_index].parse::<u64>() else {
            continue;
        };
        let total_bytes = total_blocks.saturating_mul(block_multiplier);
        let used_bytes = used_blocks.saturating_mul(block_multiplier);
        if total_bytes == 0 {
            continue;
        }
        let mount_path = parts[mount_index..].join(" ");
        let fs_type = fs_type_from_df
            .map(str::to_string)
            .or_else(|| mount_types.get(&mount_path).cloned());
        if should_skip_disk(filesystem, fs_type.as_deref(), &mount_path) {
            continue;
        }
        let disk = DeviceDiskSample {
            mount_path: mount_path.clone(),
            used_bytes: used_bytes.min(total_bytes),
            total_bytes,
        };
        if filesystem.starts_with("/dev/") {
            physical_disks.push(disk.clone());
        } else if mount_path == "/" {
            root_disks.push(disk.clone());
        }
        all_disks.push(disk);
    }

    if physical_disks.is_empty() {
        if all_disks.is_empty() {
            Ok(root_disks)
        } else {
            Ok(all_disks)
        }
    } else {
        Ok(physical_disks)
    }
}

fn parse_mount_types(lines: &[&str]) -> HashMap<String, String> {
    section_after_until(lines, MOUNTS_MARKER, None)
        .into_iter()
        .filter_map(|line| {
            let parts = line.split_whitespace().collect::<Vec<_>>();
            if parts.len() < 3 {
                return None;
            }
            Some((decode_proc_mount_field(parts[1]), parts[2].to_string()))
        })
        .collect()
}

fn should_skip_disk(filesystem: &str, fs_type: Option<&str>, mount_path: &str) -> bool {
    if fs_type == Some("overlay") && mount_path == "/" {
        return false;
    }
    if filesystem == "overlay" && mount_path == "/" {
        return false;
    }
    let normalized_fs = filesystem.trim();
    let normalized_type = fs_type.unwrap_or_default().trim();
    is_pseudo_filesystem(normalized_fs)
        || is_pseudo_filesystem(normalized_type)
        || is_network_filesystem(normalized_fs)
        || is_network_filesystem(normalized_type)
        || is_snap_loop_mount(mount_path)
}

fn is_pseudo_filesystem(value: &str) -> bool {
    matches!(
        value,
        "autofs"
            | "binfmt_misc"
            | "cgroup"
            | "cgroup2"
            | "configfs"
            | "debugfs"
            | "devpts"
            | "devtmpfs"
            | "efivarfs"
            | "fusectl"
            | "fuse.lxcfs"
            | "hugetlbfs"
            | "mqueue"
            | "nsfs"
            | "overlay"
            | "proc"
            | "pstore"
            | "ramfs"
            | "rpc_pipefs"
            | "securityfs"
            | "squashfs"
            | "sysfs"
            | "tmpfs"
            | "tracefs"
            | "udev"
    )
}

fn is_network_filesystem(value: &str) -> bool {
    matches!(
        value,
        "9p" | "afpfs"
            | "ceph"
            | "cifs"
            | "davfs"
            | "fuse.rclone"
            | "fuse.sshfs"
            | "glusterfs"
            | "nfs"
            | "nfs4"
            | "smb3"
            | "smbfs"
            | "sshfs"
            | "virtiofs"
    )
}

fn is_snap_loop_mount(mount_path: &str) -> bool {
    mount_path == "/run/snapd/ns"
        || mount_path.starts_with("/snap/")
        || mount_path.starts_with("/var/lib/snapd/snap/")
}

fn decode_proc_mount_field(value: &str) -> String {
    value
        .replace("\\040", " ")
        .replace("\\011", "\t")
        .replace("\\012", "\n")
        .replace("\\134", "\\")
}

fn disk_block_multiplier(header: Option<&str>) -> u64 {
    match header.unwrap_or_default() {
        "1K-blocks" | "1K-块" | "1024-blocks" | "1024-块" => 1024,
        _ => 1,
    }
}

fn section_between<'a>(lines: &'a [&'a str], start: &str, end: &str) -> Option<Vec<&'a str>> {
    let mut found_start = false;
    let mut found_end = false;
    let mut result = Vec::new();
    for line in lines {
        let trimmed = line.trim();
        if trimmed == start {
            found_start = true;
            continue;
        }
        if found_start && trimmed == end {
            found_end = true;
            break;
        }
        if found_start {
            result.push(*line);
        }
    }
    (found_start && found_end).then_some(result)
}

fn section_after_until<'a>(lines: &'a [&'a str], start: &str, end: Option<&str>) -> Vec<&'a str> {
    let mut found_start = false;
    let mut result = Vec::new();
    for line in lines {
        let trimmed = line.trim();
        if trimmed == start {
            found_start = true;
            continue;
        }
        if found_start && end.is_some_and(|end| trimmed == end) {
            break;
        }
        if found_start {
            result.push(*line);
        }
    }
    result
}

fn parse_kb(value: Option<&str>) -> Option<u64> {
    value?.parse::<u64>().ok()
}

#[cfg(test)]
mod tests {
    use super::{build_device_metrics_probe_command, parse_cpu_model, parse_device_metrics_probe};

    #[test]
    fn builds_probe_command_without_local_ssh_or_transfer_tools() {
        let command = build_device_metrics_probe_command();

        assert!(command.contains("export LC_ALL=C"));
        assert!(command.contains("printf '__PD_SYSTEM__"));
        assert!(command.contains("hostname"));
        assert!(command.contains("id -un"));
        assert!(command.contains("whoami"));
        assert!(command.contains("uname -m"));
        assert!(command.contains("uname -r"));
        assert!(command.contains("/proc/uptime"));
        assert!(command.contains("printf '__PD_OS_RELEASE__"));
        assert!(command.contains("/etc/os-release"));
        assert!(command.contains("/usr/lib/os-release"));
        assert!(command.contains("printf '__PD_CPUINFO__"));
        assert!(command.contains("pd_read_first_cpu_model()"));
        assert!(command.contains("pd_read_first_cpu_model /proc/cpuinfo"));
        assert!(!command.contains("pd_read_file /proc/cpuinfo"));
        assert!(command.contains("/proc/stat"));
        assert!(command.contains("printf '__PD_CPU__"));
        assert!(command.contains("pd_read_file /proc/stat"));
        assert!(command.contains("/proc/meminfo"));
        assert!(command.contains("pd_read_file()"));
        assert!(command.contains("pd_read_file /proc/meminfo"));
        assert!(command.contains("pd_read_file /proc/net/dev"));
        assert!(command.contains("pd_read_file /proc/diskstats || true"));
        assert!(command.contains("pd_read_file /proc/mounts"));
        assert!(command.contains("/proc/net/dev"));
        assert!(command.contains("/proc/diskstats"));
        assert!(command.contains("df -PT -B1"));
        assert!(command.contains("df -P -B1"));
        assert!(command.contains("df -P -k"));
        assert!(command.contains("df -k"));
        assert!(command.contains("/proc/mounts"));
        assert!(command.contains("|| true"));
        assert!(!command.contains("ssh "));
        assert!(!command.contains("sftp "));
        assert!(!command.contains("scp "));
        assert!(!command.contains("rsync "));
    }

    #[test]
    fn parses_system_info_from_probe_output() {
        let output = "\
__PD_SYSTEM__
hostname=worker-01
current_user=deploy
architecture=x86_64
kernel_name=Linux
kernel_release=6.8.0-64-generic
uptime_seconds=1210200
__PD_OS_RELEASE__
NAME=\"Ubuntu\"
VERSION_ID=\"25.10\"
VERSION=\"25.10 (Questing Quokka)\"
PRETTY_NAME=\"Ubuntu 25.10\"
__PD_CPUINFO__
model name  : Intel(R) Xeon(R) Gold 6338 CPU @ 2.00GHz
__PD_CPU__
cpu  1000 0 500 8500 0 0 0 0 0 0
__PD_MEM__
MemTotal:       16384000 kB
MemAvailable:   11384000 kB
__PD_NET__
ens160: 12000000 0 0 0 0 0 0 0 1500000 0 0 0 0 0 0 0
__PD_DF__
Filesystem     1B-blocks       Used Available Use% Mounted on
/dev/sda1     96000000000 12000000000 84000000000  13% /
";

        let snapshot = parse_device_metrics_probe(output, 1_000).expect("snapshot");

        assert_eq!(snapshot.system.hostname, "worker-01");
        assert_eq!(snapshot.system.current_user, "deploy");
        assert_eq!(snapshot.system.architecture, "x86_64");
        assert_eq!(
            snapshot.system.operating_system,
            "Ubuntu 25.10 (Questing Quokka)"
        );
        assert_eq!(snapshot.system.uptime_seconds, Some(1_210_200));
        assert_eq!(snapshot.system.kernel_release, "6.8.0-64-generic");
        assert_eq!(
            snapshot.system.cpu_model,
            "Intel(R) Xeon(R) Gold 6338 CPU @ 2.00GHz"
        );
    }

    #[test]
    fn appends_detailed_version_when_pretty_name_omits_it() {
        let output = "\
__PD_SYSTEM__
hostname=legacy-node
current_user=root
architecture=aarch64
kernel_name=Linux
kernel_release=4.19.90
uptime_seconds=120
__PD_OS_RELEASE__
NAME=\"Anolis OS\"
VERSION=\"8.8 (RHCK)\"
PRETTY_NAME=\"Anolis OS\"
__PD_CPUINFO__
Hardware    : ARMv8 Processor rev 4
__PD_CPU__
cpu  1000 0 500 8500 0 0 0 0 0 0
__PD_MEM__
MemTotal:       16384000 kB
MemAvailable:   11384000 kB
__PD_NET__
ens160: 12000000 0 0 0 0 0 0 0 1500000 0 0 0 0 0 0 0
__PD_DF__
Filesystem     1B-blocks       Used Available Use% Mounted on
/dev/sda1     96000000000 12000000000 84000000000  13% /
";

        let snapshot = parse_device_metrics_probe(output, 1_000).expect("snapshot");

        assert_eq!(snapshot.system.operating_system, "Anolis OS 8.8 (RHCK)");
        assert_eq!(snapshot.system.cpu_model, "ARMv8 Processor rev 4");
    }

    #[test]
    fn parses_first_valid_cpu_model_across_common_linux_keys() {
        let cases: Vec<(Vec<&str>, &str)> = vec![
            (
                vec![
                    "processor : 0",
                    "model name : Intel(R) Xeon(R) Gold 6338 CPU @ 2.00GHz",
                ],
                "Intel(R) Xeon(R) Gold 6338 CPU @ 2.00GHz",
            ),
            (
                vec!["processor : 0", "cpu model : POWER9, altivec supported"],
                "POWER9, altivec supported",
            ),
            (
                vec![
                    "processor : 0",
                    "machine : Loongson-3A5000-HV-7A2000-1w-V0.1",
                ],
                "Loongson-3A5000-HV-7A2000-1w-V0.1",
            ),
            (
                vec!["processor : 0", "model : MIPS 24Kc V7.4"],
                "MIPS 24Kc V7.4",
            ),
            (
                vec!["processor : 0", "Processor : ARMv8 Processor rev 4"],
                "ARMv8 Processor rev 4",
            ),
        ];

        for (lines, expected) in cases {
            assert_eq!(parse_cpu_model(&lines), expected);
        }
    }

    #[test]
    fn parses_full_proc_stat_cpu_cores() {
        let output = "\
__PD_CPU__
cpu  1000 0 500 8500 0 0 0 0 0 0
cpu0 100 0 50 850 0 0 0 0 0 0
cpu1 200 0 100 700 0 0 0 0 0 0
intr 0
ctxt 0
__PD_MEM__
MemTotal:       16384000 kB
MemAvailable:   11384000 kB
__PD_NET__
ens160: 12000000 0 0 0 0 0 0 0 1500000 0 0 0 0 0 0 0
__PD_DF__
Filesystem     1B-blocks       Used Available Use% Mounted on
/dev/sda1     96000000000 12000000000 84000000000  13% /
";

        let snapshot = parse_device_metrics_probe(output, 1_000).expect("snapshot");

        assert_eq!(snapshot.cpu.total_ticks, 10_000);
        assert_eq!(snapshot.cpu.idle_ticks, 8_500);
        assert_eq!(snapshot.cpu_cores.len(), 2);
        assert_eq!(snapshot.cpu_cores[0].total_ticks, 1_000);
        assert_eq!(snapshot.cpu_cores[0].idle_ticks, 850);
        assert_eq!(snapshot.cpu_cores[1].total_ticks, 1_000);
        assert_eq!(snapshot.cpu_cores[1].idle_ticks, 700);
    }

    #[test]
    fn parses_diskstats_as_optional_read_write_counters() {
        let output = "\
__PD_CPU__ cpu  100 0 50 850 0 0 0 0 0 0
__PD_MEM__
MemTotal:       16384000 kB
MemAvailable:   11384000 kB
__PD_NET__
ens160: 12000000 0 0 0 0 0 0 0 1500000 0 0 0 0 0 0 0
__PD_DISKSTATS__
   7       0 loop0 1 0 2 0 3 0 4 0 0 0 0 0 0 0 0
   8       0 sda 10 0 1000 0 20 0 2000 0 0 0 0 0 0 0 0
   8       1 sda1 10 0 300 0 20 0 400 0 0 0 0 0 0 0 0
 259       0 nvme0n1 10 0 3000 0 20 0 4000 0 0 0 0 0 0 0 0
 259       1 nvme0n1p1 10 0 500 0 20 0 600 0 0 0 0 0 0 0 0
 253       0 dm-0 10 0 7000 0 20 0 8000 0 0 0 0 0 0 0 0
__PD_DF__
Filesystem     1B-blocks       Used Available Use% Mounted on
/dev/sda1     96000000000 12000000000 84000000000  13% /
";

        let snapshot = parse_device_metrics_probe(output, 1_000).expect("snapshot");
        let disk_io = snapshot.disk_io.expect("disk io");

        assert_eq!(disk_io.read_bytes, 11_000 * 512);
        assert_eq!(disk_io.write_bytes, 14_000 * 512);
    }

    #[test]
    fn parses_legacy_df_kilobyte_output_when_byte_units_are_unavailable() {
        let output = "\
__PD_CPU__ cpu  100 0 50 850 0 0 0 0 0 0
__PD_MEM__
MemTotal:        8009048 kB
MemFree:          914800 kB
Buffers:          125000 kB
Cached:          4123000 kB
__PD_NET__
Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
  eth0: 3456000 0 0 0 0 0 0 0 734000 0 0 0 0 0 0 0
__PD_DF__
Filesystem       1K-blocks     Used Available Use% Mounted on
/dev/mapper/root  52428800 20971520  31457280  40% /
";

        let snapshot = parse_device_metrics_probe(output, 2_000).expect("snapshot");

        assert_eq!(snapshot.disks.len(), 1);
        assert_eq!(snapshot.disks[0].mount_path, "/");
        assert_eq!(snapshot.disks[0].used_bytes, 21_474_836_480);
        assert_eq!(snapshot.disks[0].total_bytes, 53_687_091_200);
    }

    #[test]
    fn parses_linux_probe_output_into_raw_metric_snapshot() {
        let output = "\
__PD_CPU__ cpu  100 0 50 850 0 0 0 0 0 0
__PD_MEM__
MemTotal:       16384000 kB
MemFree:         2000000 kB
MemAvailable:   11384000 kB
__PD_NET__
Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
    lo: 100 0 0 0 0 0 0 0 200 0 0 0 0 0 0 0
ens160: 12000000 0 0 0 0 0 0 0 1500000 0 0 0 0 0 0 0
__PD_DF__
Filesystem     1B-blocks       Used Available Use% Mounted on
/dev/sda1     96000000000 12000000000 84000000000  13% /
tmpfs          1000000000   100000000  900000000  10% /run
/dev/sdb1    100000000000 78000000000 22000000000  78% /data
";

        let snapshot = parse_device_metrics_probe(output, 1_000).expect("snapshot");

        assert_eq!(snapshot.sampled_at_ms, 1_000);
        assert_eq!(snapshot.cpu.total_ticks, 1_000);
        assert_eq!(snapshot.cpu.idle_ticks, 850);
        assert_eq!(snapshot.memory.total_bytes, 16_777_216_000);
        assert_eq!(snapshot.memory.available_bytes, 11_657_216_000);
        assert_eq!(snapshot.network_interfaces.len(), 1);
        assert_eq!(snapshot.network_interfaces[0].name, "ens160");
        assert_eq!(snapshot.network_interfaces[0].receive_bytes, 12_000_000);
        assert_eq!(snapshot.network_interfaces[0].transmit_bytes, 1_500_000);
        assert_eq!(snapshot.disks.len(), 2);
        assert_eq!(snapshot.disks[0].mount_path, "/");
        assert_eq!(snapshot.disks[1].mount_path, "/data");
        assert_eq!(snapshot.disks[1].used_bytes, 78_000_000_000);
    }

    #[test]
    fn parses_centos7_probe_output_with_localized_df_header() {
        let output = "\
__PD_CPU__ cpu  4705 0 2648 241812 20 0 194 0 0 0
__PD_MEM__
MemTotal:        8009048 kB
MemFree:          914800 kB
Buffers:          125000 kB
Cached:          4123000 kB
__PD_NET__
Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
    lo: 100 0 0 0 0 0 0 0 200 0 0 0 0 0 0 0
  eth0: 3456000 0 0 0 0 0 0 0 734000 0 0 0 0 0 0 0
__PD_DF__
文件系统                    1B-块        已用        可用 已用% 挂载点
/dev/mapper/centos-root 53687091200 21474836480 32212254720   40% /
/dev/sda1              1073741824   268435456  805306368   25% /boot
";

        let snapshot = parse_device_metrics_probe(output, 2_000).expect("snapshot");

        assert_eq!(snapshot.memory.total_bytes, 8_201_265_152);
        assert_eq!(snapshot.memory.available_bytes, 5_286_707_200);
        assert_eq!(snapshot.network_interfaces[0].name, "eth0");
        assert_eq!(snapshot.disks.len(), 2);
        assert_eq!(snapshot.disks[0].mount_path, "/");
        assert_eq!(snapshot.disks[1].mount_path, "/boot");
    }

    #[test]
    fn skips_malformed_network_rows_without_losing_centos7_snapshot() {
        let output = "\
__PD_CPU__ cpu  100 0 50 850 0 0 0 0 0 0
__PD_MEM__
MemTotal:        8009048 kB
MemFree:          914800 kB
Buffers:          125000 kB
Cached:          4123000 kB
__PD_NET__
Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
  eth0: 3456000 0 0 0 0 0 0 0 734000 0 0 0 0 0 0 0
  sit0: unavailable 0 0 0 0 0 0 0 unavailable 0 0 0 0 0 0 0
__PD_DF__
Filesystem        1B-blocks       Used  Available Use% Mounted on
/dev/mapper/root 53687091200 21474836480 32212254720  40% /
";

        let snapshot = parse_device_metrics_probe(output, 2_500).expect("snapshot");

        assert_eq!(snapshot.network_interfaces.len(), 1);
        assert_eq!(snapshot.network_interfaces[0].name, "eth0");
        assert_eq!(snapshot.disks[0].mount_path, "/");
    }

    #[test]
    fn parses_old_enterprise_linux_wrapped_df_rows() {
        let output = "\
__PD_CPU__ cpu  4705 0 2648 241812 20 0 194 0 0 0
__PD_MEM__
MemTotal:        8009048 kB
MemFree:          914800 kB
Buffers:          125000 kB
Cached:          4123000 kB
SReclaimable:      50000 kB
Shmem:             40000 kB
__PD_NET__
Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
  eth0: 3456000 0 0 0 0 0 0 0 734000 0 0 0 0 0 0 0
__PD_DF__
Filesystem           1K-blocks      Used Available Use% Mounted on
/dev/mapper/vg_root-lv_root
                      51606140  11977456  37006624  25% /
/dev/sda1               495844    112456    357788  24% /boot
";

        let snapshot = parse_device_metrics_probe(output, 3_000).expect("snapshot");

        assert_eq!(snapshot.memory.available_bytes, 5_296_947_200);
        assert_eq!(snapshot.disks.len(), 2);
        assert_eq!(snapshot.disks[0].mount_path, "/");
        assert_eq!(snapshot.disks[0].used_bytes, 12_264_914_944);
        assert_eq!(snapshot.disks[0].total_bytes, 52_844_687_360);
        assert_eq!(snapshot.disks[1].mount_path, "/boot");
    }

    #[test]
    fn parses_busybox_alpine_df_when_only_overlay_disk_is_available() {
        let output = "\
__PD_CPU__ cpu  100 0 50 850 0 0 0 0 0 0
__PD_MEM__
MemTotal:        2048000 kB
MemFree:          512000 kB
MemAvailable:    1536000 kB
__PD_NET__
Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
  eth0: 24000 0 0 0 0 0 0 0 12000 0 0 0 0 0 0 0
__PD_DF__
Filesystem           1024-blocks    Used Available Capacity Mounted on
overlay                  10485760 2097152   8388608      20% /
tmpfs                      262144       0    262144       0% /run
";

        let snapshot = parse_device_metrics_probe(output, 4_000).expect("snapshot");

        assert_eq!(snapshot.disks.len(), 1);
        assert_eq!(snapshot.disks[0].mount_path, "/");
        assert_eq!(snapshot.disks[0].total_bytes, 10_737_418_240);
        assert_eq!(snapshot.disks[0].used_bytes, 2_147_483_648);
    }

    #[test]
    fn skips_container_and_firmware_pseudo_filesystems_when_overlay_root_is_the_only_real_disk() {
        let output = "\
__PD_CPU__ cpu  100 0 50 850 0 0 0 0 0 0
__PD_MEM__
MemTotal:        2048000 kB
MemAvailable:    1536000 kB
__PD_NET__
Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
  eth0: 24000 0 0 0 0 0 0 0 12000 0 0 0 0 0 0 0
__PD_DF__
Filesystem           Type       1B-blocks    Used Available Use% Mounted on
overlay              overlay   10737418240 2147483648 8589934592  20% /
efivarfs             efivarfs       131072       4096     126976   4% /sys/firmware/efi/efivars
ramfs                ramfs         1048576          0    1048576   0% /run/credentials/systemd-sysusers.service
fuse.lxcfs           fuse.lxcfs 10737418240          0 10737418240 0% /proc/cpuinfo
";

        let snapshot = parse_device_metrics_probe(output, 11_000).expect("snapshot");

        assert_eq!(snapshot.disks.len(), 1);
        assert_eq!(snapshot.disks[0].mount_path, "/");
        assert_eq!(snapshot.disks[0].total_bytes, 10_737_418_240);
    }

    #[test]
    fn parses_centos6_probe_output_with_proc_mounts_and_legacy_memory_fields() {
        let output = "\
Red Hat Enterprise Linux Server release 6.10
__PD_CPU__ cpu  10000 20 4000 900000 100 0 250 0 0 0
__PD_MEM__
MemTotal:        3923000 kB
MemFree:          512000 kB
Buffers:          128000 kB
Cached:          1600000 kB
__PD_NET__
Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
    lo: 100 0 0 0 0 0 0 0 200 0 0 0 0 0 0 0
  eth1: 11111111 0 0 0 0 0 0 0 22222222 0 0 0 0 0 0 0
__PD_DF__
Filesystem           1K-blocks      Used Available Use% Mounted on
/dev/mapper/vg_old-lv_root
                      51606140  11977456  37006624  25% /
/dev/sda1               495844    112456    357788  24% /boot
tmpfs                  1961500         0   1961500   0% /dev/shm
__PD_MOUNTS__
/dev/mapper/vg_old-lv_root / ext4 rw 0 0
/dev/sda1 /boot ext4 rw 0 0
tmpfs /dev/shm tmpfs rw 0 0
";

        let snapshot = parse_device_metrics_probe(output, 9_000).expect("snapshot");

        assert_eq!(snapshot.memory.available_bytes, 2_293_760_000);
        assert_eq!(snapshot.network_interfaces.len(), 1);
        assert_eq!(snapshot.network_interfaces[0].name, "eth1");
        assert_eq!(snapshot.disks.len(), 2);
        assert_eq!(snapshot.disks[0].mount_path, "/");
        assert_eq!(snapshot.disks[1].mount_path, "/boot");
    }

    #[test]
    fn parses_disk_mount_paths_with_spaces_using_proc_mounts_and_df_columns() {
        let output = "\
__PD_CPU__ cpu  100 0 50 850 0 0 0 0 0 0
__PD_MEM__
MemTotal:        2048000 kB
MemAvailable:    1536000 kB
__PD_NET__
Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
  ens3: 24000 0 0 0 0 0 0 0 12000 0 0 0 0 0 0 0
__PD_DF__
Filesystem           1B-blocks    Used Available Use% Mounted on
/dev/sdb1           1000000000 200000000 800000000  20% /srv/shared data
tmpfs                256000000         0 256000000   0% /run/user/1000
__PD_MOUNTS__
/dev/sdb1 /srv/shared\\040data xfs rw 0 0
tmpfs /run/user/1000 tmpfs rw 0 0
";

        let snapshot = parse_device_metrics_probe(output, 10_000).expect("snapshot");

        assert_eq!(snapshot.disks.len(), 1);
        assert_eq!(snapshot.disks[0].mount_path, "/srv/shared data");
        assert_eq!(snapshot.disks[0].used_bytes, 200_000_000);
        assert_eq!(snapshot.disks[0].total_bytes, 1_000_000_000);
    }

    #[test]
    fn parses_probe_output_with_login_noise_and_systemd_pseudo_filesystems() {
        let output = "\
Last login: Sat Jun  6 12:00:00 2026 from 10.0.0.2
Welcome to Ubuntu 22.04.5 LTS
__PD_CPU__ cpu  1822 0 632 116744 90 0 77 0 0 0
__PD_MEM__
MemTotal:        4039560 kB
MemFree:          515040 kB
MemAvailable:   2480944 kB
Buffers:          145000 kB
Cached:          1690000 kB
__PD_NET__
Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
    lo: 100 0 0 0 0 0 0 0 200 0 0 0 0 0 0 0
  ens3: 987654321 0 0 0 0 0 0 0 123456789 0 0 0 0 0 0 0
__PD_DF__
Filesystem     1B-blocks       Used Available Use% Mounted on
udev          2030000000          0 2030000000   0% /dev
tmpfs          405000000    1200000  403800000   1% /run
/dev/vda1    25769803776 8589934592 17179869184  34% /
cgroup2                0          0          0    - /sys/fs/cgroup
overlay      10737418240 2147483648 8589934592  20% /var/lib/docker/overlay2/abc/merged
deploy@host:~$ ";

        let snapshot = parse_device_metrics_probe(output, 6_000).expect("snapshot");

        assert_eq!(snapshot.cpu.total_ticks, 119_365);
        assert_eq!(snapshot.memory.available_bytes, 2_540_486_656);
        assert_eq!(snapshot.network_interfaces.len(), 1);
        assert_eq!(snapshot.network_interfaces[0].name, "ens3");
        assert_eq!(snapshot.disks.len(), 1);
        assert_eq!(snapshot.disks[0].mount_path, "/");
        assert_eq!(snapshot.disks[0].used_bytes, 8_589_934_592);
    }

    #[test]
    fn parses_ubuntu_debian_probe_output_without_snap_loop_mounts() {
        let output = "\
Debian GNU/Linux 12
__PD_CPU__ cpu  7000 0 2200 140000 350 0 88 0 0 0
__PD_MEM__
MemTotal:        8144000 kB
MemFree:          930000 kB
MemAvailable:   5120000 kB
Buffers:          320000 kB
Cached:          2100000 kB
__PD_NET__
Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
    lo: 100 0 0 0 0 0 0 0 200 0 0 0 0 0 0 0
  enp1s0: 765432100 0 0 0 0 0 0 0 234567800 0 0 0 0 0 0 0
__PD_DF__
Filesystem     Type      1B-blocks       Used Available Use% Mounted on
/dev/vda2      ext4    107374182400 32212254720 75161927680  30% /
/dev/vdb1      ext4    214748364800 64424509440 150323855360 30% /data
/dev/loop0     squashfs    65536000    65536000          0 100% /snap/core20/2318
/dev/loop1     squashfs    85000000    85000000          0 100% /var/lib/snapd/snap/lxd/29351
tmpfs          tmpfs      1073741824           0 1073741824   0% /run/user/1000
nsfs           nsfs          4096        4096          0 100% /run/snapd/ns/lxd.mnt
__PD_MOUNTS__
/dev/vda2 / ext4 rw,relatime 0 0
/dev/vdb1 /data ext4 rw,relatime 0 0
/dev/loop0 /snap/core20/2318 squashfs ro,nodev,relatime 0 0
/dev/loop1 /var/lib/snapd/snap/lxd/29351 squashfs ro,nodev,relatime 0 0
tmpfs /run/user/1000 tmpfs rw,nosuid,nodev 0 0
nsfs /run/snapd/ns/lxd.mnt nsfs rw 0 0
";

        let snapshot = parse_device_metrics_probe(output, 14_000).expect("snapshot");

        assert_eq!(snapshot.memory.available_bytes, 5_242_880_000);
        assert_eq!(snapshot.network_interfaces.len(), 1);
        assert_eq!(snapshot.network_interfaces[0].name, "enp1s0");
        assert_eq!(snapshot.disks.len(), 2);
        assert_eq!(snapshot.disks[0].mount_path, "/");
        assert_eq!(snapshot.disks[1].mount_path, "/data");
        assert_eq!(snapshot.disks[1].used_bytes, 64_424_509_440);
        assert!(snapshot
            .disks
            .iter()
            .all(|disk| !disk.mount_path.contains("/snap/")));
    }

    #[test]
    fn parses_old_debian_without_memavailable_and_ignores_network_mounts() {
        let output = "\
Debian GNU/Linux 8
__PD_CPU__ cpu  3200 0 800 96000 120 0 64 0 0 0
__PD_MEM__
MemTotal:        2048000 kB
MemFree:          256000 kB
Buffers:          128000 kB
Cached:           512000 kB
__PD_NET__
Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
    lo: 100 0 0 0 0 0 0 0 200 0 0 0 0 0 0 0
  eth0: 76543210 0 0 0 0 0 0 0 23456780 0 0 0 0 0 0 0
__PD_DF__
Filesystem           Type     1K-blocks      Used Available Use% Mounted on
/dev/xvda1           ext4       10485760   4194304   6291456  40% /
server:/exports/app  nfs4      524288000 104857600 419430400  20% /mnt/shared
//nas/backup         cifs     1048576000 524288000 524288000  50% /mnt/backup
tmpfs                tmpfs       1024000         0   1024000   0% /run
__PD_MOUNTS__
/dev/xvda1 / ext4 rw,relatime 0 0
server:/exports/app /mnt/shared nfs4 rw,relatime 0 0
//nas/backup /mnt/backup cifs rw,relatime 0 0
tmpfs /run tmpfs rw,nosuid,nodev 0 0
";

        let snapshot = parse_device_metrics_probe(output, 20_000).expect("snapshot");

        assert_eq!(snapshot.memory.available_bytes, 917_504_000);
        assert_eq!(snapshot.network_interfaces.len(), 1);
        assert_eq!(snapshot.network_interfaces[0].name, "eth0");
        assert_eq!(snapshot.disks.len(), 1);
        assert_eq!(snapshot.disks[0].mount_path, "/");
        assert_eq!(snapshot.disks[0].used_bytes, 4_294_967_296);
    }

    #[test]
    fn ignores_network_filesystems_when_no_local_block_disk_is_reported() {
        let output = "\
Ubuntu 18.04 LTS
__PD_CPU__ cpu  1200 0 300 18500 20 0 18 0 0 0
__PD_MEM__
MemTotal:        2048000 kB
MemAvailable:    1536000 kB
__PD_NET__
Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
  ens3: 76543210 0 0 0 0 0 0 0 23456780 0 0 0 0 0 0 0
__PD_DF__
Filesystem          1K-blocks      Used Available Use% Mounted on
server:/exports/app 524288000 104857600 419430400  20% /mnt/shared
//nas/backup       1048576000 524288000 524288000  50% /mnt/backup
sshfs#ops@host:/srv  52428800  10485760  41943040  20% /mnt/sshfs
tmpfs                 1024000         0   1024000   0% /run
__PD_MOUNTS__
server:/exports/app /mnt/shared nfs4 rw,relatime 0 0
//nas/backup /mnt/backup cifs rw,relatime 0 0
sshfs#ops@host:/srv /mnt/sshfs fuse.sshfs rw,nosuid,nodev 0 0
tmpfs /run tmpfs rw,nosuid,nodev 0 0
";

        let snapshot = parse_device_metrics_probe(output, 21_000).expect("snapshot");

        assert_eq!(snapshot.disks.len(), 0);
    }

    #[test]
    fn keeps_loop_backed_data_disks_when_they_are_not_snap_mounts() {
        let output = "\
Ubuntu 22.04.5 LTS
__PD_CPU__ cpu  7000 0 2200 140000 350 0 88 0 0 0
__PD_MEM__
MemTotal:        8144000 kB
MemAvailable:   5120000 kB
__PD_NET__
Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
  ens3: 765432100 0 0 0 0 0 0 0 234567800 0 0 0 0 0 0 0
__PD_DF__
Filesystem     Type      1B-blocks       Used Available Use% Mounted on
/dev/vda2      ext4    107374182400 32212254720 75161927680  30% /
/dev/loop7     ext4     53687091200 10737418240 42949672960  20% /mnt/image-data
/dev/loop8     squashfs    65536000    65536000          0 100% /snap/core20/2318
__PD_MOUNTS__
/dev/vda2 / ext4 rw,relatime 0 0
/dev/loop7 /mnt/image-data ext4 rw,relatime 0 0
/dev/loop8 /snap/core20/2318 squashfs ro,nodev,relatime 0 0
";

        let snapshot = parse_device_metrics_probe(output, 15_000).expect("snapshot");

        assert_eq!(snapshot.disks.len(), 2);
        assert_eq!(snapshot.disks[0].mount_path, "/");
        assert_eq!(snapshot.disks[1].mount_path, "/mnt/image-data");
        assert_eq!(snapshot.disks[1].used_bytes, 10_737_418_240);
    }

    #[test]
    fn parses_rhel_family_probe_output_with_indented_markers_and_nvme_xfs_disk() {
        let output = "\
Amazon Linux 2023
  __PD_CPU__ cpu  9500 120 3500 650000 2500 0 420 0 0 0
__PD_MEM__
MemTotal:       32768000 kB
MemFree:         2048000 kB
Buffers:          512000 kB
Cached:         16777216 kB
SReclaimable:     768000 kB
Shmem:            256000 kB
__PD_NET__
Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
    lo: 100 0 0 0 0 0 0 0 200 0 0 0 0 0 0 0
ens192: 9876543210 0 0 0 0 0 0 0 1234567890 0 0 0 0 0 0 0
__PD_DF__
Filesystem              1B-blocks       Used   Available Use% Mounted on
/dev/mapper/rl-root  536870912000 214748364800 322122547200  40% /
/dev/nvme0n1p1          1073741824    268435456    805306368  25% /boot
tmpfs                   17179869184            0  17179869184   0% /dev/shm
";

        let snapshot = parse_device_metrics_probe(output, 7_000).expect("snapshot");

        assert_eq!(snapshot.cpu.total_ticks, 666_040);
        assert_eq!(snapshot.memory.available_bytes, 20_325_597_184);
        assert_eq!(snapshot.network_interfaces.len(), 1);
        assert_eq!(snapshot.network_interfaces[0].name, "ens192");
        assert_eq!(snapshot.disks.len(), 2);
        assert_eq!(snapshot.disks[0].mount_path, "/");
        assert_eq!(snapshot.disks[0].used_bytes, 214_748_364_800);
        assert_eq!(snapshot.disks[1].mount_path, "/boot");
    }

    #[test]
    fn parses_rhel_clone_probe_output_with_bond_vlan_and_lvm_disks() {
        let output = "\
Oracle Linux Server release 8.10
__PD_CPU__ cpu  26000 120 6500 980000 850 0 1200 0 0 0
__PD_MEM__
MemTotal:       65536000 kB
MemFree:         4096000 kB
Buffers:         1024000 kB
Cached:         32768000 kB
SReclaimable:    2048000 kB
Shmem:            512000 kB
__PD_NET__
Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
    lo: 100 0 0 0 0 0 0 0 200 0 0 0 0 0 0 0
 bond0: 123456789012 0 0 0 0 0 0 0 9876543210 0 0 0 0 0 0 0
bond0.42: 3456789012 0 0 0 0 0 0 0 456789012 0 0 0 0 0 0 0
__PD_DF__
Filesystem                   1B-blocks         Used    Available Use% Mounted on
/dev/mapper/ol-root        214748364800  53687091200 161061273600  25% /
/dev/mapper/ol-var         107374182400  75161927680  32212254720  70% /var
/dev/sda1                    1073741824    268435456    805306368  25% /boot
tmpfs                       34359738368            0  34359738368   0% /dev/shm
";

        let snapshot = parse_device_metrics_probe(output, 8_000).expect("snapshot");

        assert_eq!(snapshot.cpu.total_ticks, 1_014_670);
        assert_eq!(snapshot.memory.available_bytes, 40_370_176_000);
        assert_eq!(snapshot.network_interfaces.len(), 2);
        assert_eq!(snapshot.network_interfaces[0].name, "bond0");
        assert_eq!(snapshot.network_interfaces[1].name, "bond0.42");
        assert_eq!(snapshot.disks.len(), 3);
        assert_eq!(snapshot.disks[0].mount_path, "/");
        assert_eq!(snapshot.disks[1].mount_path, "/var");
        assert_eq!(snapshot.disks[1].used_bytes, 75_161_927_680);
        assert_eq!(snapshot.disks[2].mount_path, "/boot");
    }

    #[test]
    fn parses_legacy_network_alias_interfaces_with_colons() {
        let output = "\
CentOS release 6.10
__PD_CPU__ cpu  1200 0 300 18500 20 0 18 0 0 0
__PD_MEM__
MemTotal:        2048000 kB
MemFree:          512000 kB
Buffers:          128000 kB
Cached:           768000 kB
__PD_NET__
Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
  eth0:0: 555000 0 0 0 0 0 0 0 777000 0 0 0 0 0 0 0
__PD_DF__
Filesystem           1K-blocks      Used Available Use% Mounted on
/dev/mapper/vg-root   10485760   2097152   8388608  20% /
";

        let snapshot = parse_device_metrics_probe(output, 12_000).expect("snapshot");

        assert_eq!(snapshot.network_interfaces.len(), 1);
        assert_eq!(snapshot.network_interfaces[0].name, "eth0:0");
        assert_eq!(snapshot.network_interfaces[0].receive_bytes, 555_000);
        assert_eq!(snapshot.network_interfaces[0].transmit_bytes, 777_000);
        assert_eq!(snapshot.disks[0].mount_path, "/");
    }

    #[test]
    fn normalizes_network_peer_suffixes_from_proc_net_dev() {
        let output = "\
Ubuntu 20.04
__PD_CPU__ cpu  1200 0 300 18500 20 0 18 0 0 0
__PD_MEM__
MemTotal:        2048000 kB
MemAvailable:    1536000 kB
__PD_NET__
Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
  eth0@if7: 1000000 0 0 0 0 0 0 0 2000000 0 0 0 0 0 0 0
  vethabcd@if42: 3000000 0 0 0 0 0 0 0 4000000 0 0 0 0 0 0 0
__PD_DF__
Filesystem           1K-blocks      Used Available Use% Mounted on
/dev/mapper/vg-root   10485760   2097152   8388608  20% /
";

        let snapshot = parse_device_metrics_probe(output, 16_000).expect("snapshot");

        assert_eq!(
            snapshot
                .network_interfaces
                .iter()
                .map(|interface| interface.name.as_str())
                .collect::<Vec<_>>(),
            ["eth0", "vethabcd"]
        );
        assert_eq!(snapshot.network_interfaces[0].receive_bytes, 1_000_000);
        assert_eq!(snapshot.network_interfaces[1].transmit_bytes, 4_000_000);
    }

    #[test]
    fn parses_suse_btrfs_root_disk_without_proc_mount_filtering_it_out() {
        let output = "\
openSUSE Leap 15.6
__PD_CPU__ cpu  4705 0 2648 241812 20 0 194 0 0 0
__PD_MEM__
MemTotal:        8009048 kB
MemFree:          914800 kB
Buffers:          125000 kB
Cached:          4123000 kB
SReclaimable:      50000 kB
Shmem:             40000 kB
__PD_NET__
Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
  eth0: 3456000 0 0 0 0 0 0 0 734000 0 0 0 0 0 0 0
__PD_DF__
Filesystem     Type 1K-blocks     Used Available Use% Mounted on
/dev/sda2      btrfs  41943040 10485760  31457280  25% /
/dev/sda2      btrfs  41943040 10485760  31457280  25% /.snapshots
tmpfs          tmpfs   1024000        0   1024000   0% /run
__PD_MOUNTS__
/dev/sda2 / btrfs rw,relatime,space_cache=v2,subvolid=256,subvol=/@ 0 0
/dev/sda2 /.snapshots btrfs rw,relatime,space_cache=v2,subvolid=257,subvol=/@/.snapshots 0 0
tmpfs /run tmpfs rw,nosuid,nodev 0 0
";

        let snapshot = parse_device_metrics_probe(output, 13_000).expect("snapshot");

        assert_eq!(snapshot.disks.len(), 2);
        assert_eq!(snapshot.disks[0].mount_path, "/");
        assert_eq!(snapshot.disks[0].used_bytes, 10_737_418_240);
        assert_eq!(snapshot.disks[0].total_bytes, 42_949_672_960);
        assert_eq!(snapshot.disks[1].mount_path, "/.snapshots");
    }

    #[test]
    fn parses_fedora_family_probe_output_with_xfs_var_and_zram_swap_noise() {
        let output = "\
Fedora Linux 40
__PD_CPU__ cpu  18000 50 4600 780000 900 0 220 0 0 0
__PD_MEM__
MemTotal:       16384000 kB
MemFree:         1024000 kB
Buffers:          512000 kB
Cached:          8192000 kB
SReclaimable:     768000 kB
Shmem:            256000 kB
__PD_NET__
Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
    lo: 100 0 0 0 0 0 0 0 200 0 0 0 0 0 0 0
  enp2s0: 4567890123 0 0 0 0 0 0 0 987654321 0 0 0 0 0 0 0
__PD_DF__
Filesystem     Type     1B-blocks       Used Available Use% Mounted on
/dev/mapper/fedora-root xfs  85899345920 21474836480 64424509440  25% /
/dev/mapper/fedora-var  xfs  53687091200 32212254720 21474836480  60% /var
/dev/nvme0n1p2          ext4 1073741824    268435456   805306368  25% /boot
tmpfs          tmpfs     8589934592          0 8589934592   0% /run
zram0          tmpfs     4096000000          0 4096000000   0% /run/zram
__PD_MOUNTS__
/dev/mapper/fedora-root / xfs rw,relatime 0 0
/dev/mapper/fedora-var /var xfs rw,relatime 0 0
/dev/nvme0n1p2 /boot ext4 rw,relatime 0 0
tmpfs /run tmpfs rw,nosuid,nodev 0 0
zram0 /run/zram tmpfs rw,nosuid,nodev 0 0
";

        let snapshot = parse_device_metrics_probe(output, 17_000).expect("snapshot");

        assert_eq!(snapshot.memory.available_bytes, 10_485_760_000);
        assert_eq!(snapshot.network_interfaces.len(), 1);
        assert_eq!(snapshot.network_interfaces[0].name, "enp2s0");
        assert_eq!(snapshot.disks.len(), 3);
        assert_eq!(snapshot.disks[0].mount_path, "/");
        assert_eq!(snapshot.disks[1].mount_path, "/var");
        assert_eq!(snapshot.disks[1].used_bytes, 32_212_254_720);
        assert_eq!(snapshot.disks[2].mount_path, "/boot");
    }

    #[test]
    fn parses_modern_rhel9_clone_with_xfs_lvm_and_virtual_network_noise() {
        let output = "\
Rocky Linux release 9.4
__PD_CPU__ cpu  91000 100 32000 4200000 6000 0 1800 0 0 0
__PD_MEM__
MemTotal:       131072000 kB
MemFree:         8192000 kB
MemAvailable:   98765432 kB
Buffers:         2048000 kB
Cached:         65536000 kB
SReclaimable:    4096000 kB
Shmem:           1024000 kB
__PD_NET__
Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
    lo: 100 0 0 0 0 0 0 0 200 0 0 0 0 0 0 0
  ens18: 987654321098 0 0 0 0 0 0 0 123456789012 0 0 0 0 0 0 0
  virbr0: 1200 0 0 0 0 0 0 0 800 0 0 0 0 0 0 0
  tun0@if5: 777000 0 0 0 0 0 0 0 888000 0 0 0 0 0 0 0
__PD_DF__
Filesystem                 Type     1B-blocks        Used   Available Use% Mounted on
/dev/mapper/rl-root        xfs   214748364800  53687091200 161061273600  25% /
/dev/mapper/rl-home        xfs   429496729600 107374182400 322122547200  25% /home
/dev/mapper/rl-var_log     xfs   107374182400  85899345920  21474836480  80% /var/log
/dev/nvme0n1p1             xfs     1073741824    268435456    805306368  25% /boot
tmpfs                      tmpfs   67108864000           0  67108864000   0% /dev/shm
devtmpfs                   devtmpfs    4096000           0      4096000   0% /dev
__PD_MOUNTS__
/dev/mapper/rl-root / xfs rw,relatime,seclabel,attr2,inode64,logbufs=8 0 0
/dev/mapper/rl-home /home xfs rw,relatime,seclabel,attr2,inode64,logbufs=8 0 0
/dev/mapper/rl-var_log /var/log xfs rw,relatime,seclabel,attr2,inode64,logbufs=8 0 0
/dev/nvme0n1p1 /boot xfs rw,relatime,seclabel,attr2,inode64,logbufs=8 0 0
tmpfs /dev/shm tmpfs rw,nosuid,nodev,seclabel,inode64 0 0
devtmpfs /dev devtmpfs rw,nosuid,seclabel,size=4096000k,nr_inodes=1024000 0 0
";

        let snapshot = parse_device_metrics_probe(output, 18_000).expect("snapshot");

        assert_eq!(snapshot.cpu.total_ticks, 4_330_900);
        assert_eq!(snapshot.memory.available_bytes, 101_135_802_368);
        assert_eq!(
            snapshot
                .network_interfaces
                .iter()
                .map(|interface| interface.name.as_str())
                .collect::<Vec<_>>(),
            ["ens18", "virbr0", "tun0"]
        );
        assert_eq!(snapshot.network_interfaces[2].transmit_bytes, 888_000);
        assert_eq!(snapshot.disks.len(), 4);
        assert_eq!(snapshot.disks[0].mount_path, "/");
        assert_eq!(snapshot.disks[1].mount_path, "/home");
        assert_eq!(snapshot.disks[2].mount_path, "/var/log");
        assert_eq!(snapshot.disks[2].used_bytes, 85_899_345_920);
        assert_eq!(snapshot.disks[3].mount_path, "/boot");
    }

    #[test]
    fn parses_alma_rocky_legacy_df_without_type_column_using_proc_mounts() {
        let output = "\
AlmaLinux release 8.9
__PD_CPU__ cpu  41000 200 12000 1800000 700 0 900 0 0 0
__PD_MEM__
MemTotal:       32768000 kB
MemFree:         2097152 kB
Buffers:          524288 kB
Cached:         12582912 kB
SReclaimable:    1048576 kB
Shmem:            262144 kB
__PD_NET__
Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
    lo: 100 0 0 0 0 0 0 0 200 0 0 0 0 0 0 0
  ens160: 123456789 0 0 0 0 0 0 0 98765432 0 0 0 0 0 0 0
  br-9f2: 24000 0 0 0 0 0 0 0 12000 0 0 0 0 0 0 0
  vethabc@if4: 64000 0 0 0 0 0 0 0 32000 0 0 0 0 0 0 0
__PD_DF__
Filesystem              1K-blocks      Used Available Use% Mounted on
/dev/mapper/alma-root   83886080  20971520  62914560  25% /
/dev/mapper/alma-var    52428800  31457280  20971520  60% /var
/dev/sda1                1048576    262144    786432  25% /boot
tmpfs                   16777216         0  16777216   0% /run
zram0                    4194304         0   4194304   0% /run/zram
__PD_MOUNTS__
/dev/mapper/alma-root / xfs rw,relatime,seclabel,attr2,inode64 0 0
/dev/mapper/alma-var /var xfs rw,relatime,seclabel,attr2,inode64 0 0
/dev/sda1 /boot ext4 rw,relatime,seclabel 0 0
tmpfs /run tmpfs rw,nosuid,nodev,seclabel 0 0
zram0 /run/zram tmpfs rw,nosuid,nodev,seclabel 0 0
";

        let snapshot = parse_device_metrics_probe(output, 19_000).expect("snapshot");

        assert_eq!(snapshot.memory.available_bytes, 16_374_562_816);
        assert_eq!(
            snapshot
                .network_interfaces
                .iter()
                .map(|interface| interface.name.as_str())
                .collect::<Vec<_>>(),
            ["ens160", "br-9f2", "vethabc"]
        );
        assert_eq!(snapshot.disks.len(), 3);
        assert_eq!(snapshot.disks[0].mount_path, "/");
        assert_eq!(snapshot.disks[0].total_bytes, 85_899_345_920);
        assert_eq!(snapshot.disks[1].mount_path, "/var");
        assert_eq!(snapshot.disks[1].used_bytes, 32_212_254_720);
        assert_eq!(snapshot.disks[2].mount_path, "/boot");
    }

    #[test]
    fn reports_missing_probe_sections_with_actionable_diagnostics() {
        let missing_cpu = "\
__PD_MEM__
MemTotal:        2048000 kB
MemAvailable:    1536000 kB
__PD_NET__
__PD_DF__
Filesystem 1B-blocks Used Available Use% Mounted on
";
        let missing_memory = "\
__PD_CPU__ cpu  100 0 50 850 0 0 0 0 0 0
__PD_NET__
__PD_DF__
Filesystem 1B-blocks Used Available Use% Mounted on
";
        let missing_network = "\
__PD_CPU__ cpu  100 0 50 850 0 0 0 0 0 0
__PD_MEM__
MemTotal:        2048000 kB
MemAvailable:    1536000 kB
__PD_DF__
Filesystem 1B-blocks Used Available Use% Mounted on
";
        let missing_disk = "\
__PD_CPU__ cpu  100 0 50 850 0 0 0 0 0 0
__PD_MEM__
MemTotal:        2048000 kB
MemAvailable:    1536000 kB
__PD_NET__
  eth0: 24000 0 0 0 0 0 0 0 12000 0 0 0 0 0 0 0
";

        assert_eq!(
            parse_device_metrics_probe(missing_cpu, 5_000).unwrap_err(),
            "METRICS_PROBE_MISSING_CPU:/proc/stat"
        );
        assert_eq!(
            parse_device_metrics_probe(missing_memory, 5_000).unwrap_err(),
            "METRICS_PROBE_MISSING_MEMORY:/proc/meminfo"
        );
        assert_eq!(
            parse_device_metrics_probe(missing_network, 5_000).unwrap_err(),
            "METRICS_PROBE_MISSING_NETWORK:/proc/net/dev"
        );
        assert_eq!(
            parse_device_metrics_probe(missing_disk, 5_000).unwrap_err(),
            "METRICS_PROBE_MISSING_DISK:df"
        );
    }
}
