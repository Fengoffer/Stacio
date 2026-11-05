use crate::domain::device_metrics::{
    DeviceContainerSample, DeviceCpuSample, DeviceDiskIOSample, DeviceDiskSample,
    DeviceMemorySample, DeviceMetricsSnapshot, DeviceNetworkSample, DevicePortSample,
    DeviceProcessSample, DeviceServiceSample, DeviceSystemInfo,
};
use std::collections::{HashMap, HashSet};

const SYSTEM_MARKER: &str = "__PD_SYSTEM__";
const OS_RELEASE_MARKER: &str = "__PD_OS_RELEASE__";
const CPUINFO_MARKER: &str = "__PD_CPUINFO__";
const CPU_MARKER: &str = "__PD_CPU__";
const PROCESS_COUNTERS_MARKER: &str = "__PD_PROCESS_COUNTERS__";
const MEM_MARKER: &str = "__PD_MEM__";
const NET_MARKER: &str = "__PD_NET__";
const NET_SAMPLE_TIME_MARKER: &str = "__PD_NET_SAMPLE_UPTIME__";
const NET_TOPOLOGY_MARKER: &str = "__PD_NET_TOPOLOGY__";
const MAX_NETWORK_TOPOLOGY_RECORDS: usize = 4096;
const DISKSTATS_MARKER: &str = "__PD_DISKSTATS__";
const DISK_SAMPLE_TIME_MARKER: &str = "__PD_DISK_SAMPLE_UPTIME__";
const DISK_TOPOLOGY_MARKER: &str = "__PD_DISK_TOPOLOGY__";
const DF_MARKER: &str = "__PD_DF__";
const MOUNTS_MARKER: &str = "__PD_MOUNTS__";
const PROCESSES_CPU_MARKER: &str = "__PD_PROCESSES_CPU__";
const PROCESSES_MEMORY_MARKER: &str = "__PD_PROCESSES_MEMORY__";
const PROCESSES_NETWORK_MARKER: &str = "__PD_PROCESSES_NETWORK__";
const PROCESS_COLUMNS_RSS: &str = "__PD_PROCESS_COLUMNS_PID_CPU_MEM_RSS_COMMAND__";
const PORTS_MARKER: &str = "__PD_PORTS__";
const SERVICES_MARKER: &str = "__PD_SERVICES__";
const CONTAINERS_MARKER: &str = "__PD_CONTAINERS__";
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
        // Keep each counter timestamp beside its read. Later sysfs/df/nethogs
        // latency must not become part of the measured rate interval.
        "pd_counter_time() { pd_counter_uptime=''; IFS=' ' read -r pd_counter_uptime _ 2>/dev/null < /proc/uptime || true; printf '%s %s\\n' \"$1\" \"$pd_counter_uptime\"; }",
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
        "pd_boot_id=''; IFS= read -r pd_boot_id 2>/dev/null < /proc/sys/kernel/random/boot_id || true; printf 'boot_id=%s\\n' \"$pd_boot_id\"",
        "printf '__PD_OS_RELEASE__\\n'",
        "(pd_read_file /etc/os-release || pd_read_file /usr/lib/os-release || true)",
        "printf '__PD_CPUINFO__\\n'",
        "pd_read_first_cpu_model /proc/cpuinfo || true",
        "printf '__PD_CPU__\\n'",
        "pd_read_file /proc/stat",
        "printf '__PD_PROCESS_COUNTERS__\\n'",
        "pd_page_size=\"$(getconf PAGESIZE 2>/dev/null || getconf PAGE_SIZE 2>/dev/null || true)\"",
        "printf 'page_size=%s\\n' \"$pd_page_size\"",
        // One awk process reads every procfs stat file. getline handles a PID
        // disappearing without aborting the scan. Strip through the LAST ')'
        // because comm itself can contain spaces and parentheses; sanitize
        // embedded newlines before writing the compact one-process-per-line wire format.
        concat!(
            "awk 'BEGIN { for (i=1; i<ARGC; i++) { s=\"\"; ",
            "while ((getline l < ARGV[i]) > 0) s=s (s==\"\" ? \"\" : \" \") l; close(ARGV[i]); ",
            "if (s !~ /^[0-9]+ \\(.*\\) /) continue; ",
            "pid=s; sub(/ .*/, \"\", pid); name=s; sub(/^[^(]*\\(/, \"\", name); sub(/\\) [^)]*$/, \"\", name); ",
            "tail=s; sub(/^.*\\) /, \"\", tail); n=split(tail, f, /[[:space:]]+/); ",
            "if (n<22) continue; gsub(/[[:cntrl:]]/, \" \", name); ",
            "printf \"%s %s %s %s %s %s\\n\", pid, f[12], f[13], f[20], f[22], name; ",
            "} }' /proc/[0-9]*/stat 2>/dev/null || true"
        ),
        "printf '__PD_MEM__\\n'",
        "pd_read_file /proc/meminfo",
        "printf '__PD_NET__\\n'",
        "pd_read_file /proc/net/dev",
        "pd_counter_time __PD_NET_SAMPLE_UPTIME__",
        "printf '__PD_NET_TOPOLOGY__\\n'",
        // Builtins only: preserve actual interface names, including '@', and
        // describe bridge/bond/VLAN dependencies without spawning per-NIC tools.
        // Incomplete scans remain unknown rather than inventing physical NICs.
        concat!(
            "pd_net_topology_count=0; pd_net_topology_complete=1; ",
            "if [ -r /sys/class/net ] && [ -x /sys/class/net ]; then ",
            "for pd_net in /sys/class/net/*; do [ -d \"$pd_net\" ] || continue; ",
            "if [ ! -r \"$pd_net\" ] || [ ! -x \"$pd_net\" ]; then pd_net_topology_complete=0; continue; fi; ",
            "pd_net_topology_count=$((pd_net_topology_count + 1)); ",
            "if [ \"$pd_net_topology_count\" -gt 4096 ]; then pd_net_topology_complete=0; break; fi; ",
            "pd_net_name=${pd_net##*/}; printf 'interface %s\\n' \"$pd_net_name\"; ",
            "for pd_lower in \"$pd_net\"/lower_*; do [ -L \"$pd_lower\" ] || continue; ",
            "if [ ! -e \"$pd_lower\" ]; then pd_net_topology_complete=0; continue; fi; ",
            "pd_net_topology_count=$((pd_net_topology_count + 1)); ",
            "if [ \"$pd_net_topology_count\" -gt 4096 ]; then pd_net_topology_complete=0; break 2; fi; ",
            "pd_lower_name=${pd_lower##*/lower_}; ",
            "printf 'lower %s %s\\n' \"$pd_net_name\" \"$pd_lower_name\"; done; ",
            "done; [ \"$pd_net_topology_complete\" -eq 1 ] && printf 'complete\\n'; fi; true"
        ),
        "printf '__PD_DISKSTATS__\\n'",
        "pd_read_file /proc/diskstats || true",
        "pd_counter_time __PD_DISK_SAMPLE_UPTIME__",
        "printf '__PD_DISK_TOPOLOGY__\\n'",
        // Builtins only, with a shared bound on nodes and edges. Whole devices,
        // partitions and slaves let the parser choose one storage layer rather
        // than adding an LVM/crypt/RAID request again for every device it crosses.
        concat!(
            "pd_topology_count=0; pd_topology_complete=1; ",
            "if [ -d /sys/block ]; then for pd_block in /sys/block/*; do ",
            "[ -d \"$pd_block\" ] || continue; ",
            "pd_topology_count=$((pd_topology_count + 1)); ",
            "if [ \"$pd_topology_count\" -gt 4096 ]; then pd_topology_complete=0; break; fi; ",
            "pd_device=${pd_block##*/}; printf 'disk %s\\n' \"$pd_device\"; ",
            "[ -r \"$pd_block/slaves\" ] || pd_topology_complete=0; ",
            "for pd_slave in \"$pd_block\"/slaves/*; do [ -e \"$pd_slave\" ] || continue; ",
            "pd_topology_count=$((pd_topology_count + 1)); ",
            "if [ \"$pd_topology_count\" -gt 4096 ]; then pd_topology_complete=0; break; fi; ",
            "printf 'slave %s %s\\n' \"$pd_device\" \"${pd_slave##*/}\"; done; ",
            "for pd_partition in \"$pd_block\"/*/partition; do [ -f \"$pd_partition\" ] || continue; ",
            "pd_topology_count=$((pd_topology_count + 1)); ",
            "if [ \"$pd_topology_count\" -gt 4096 ]; then pd_topology_complete=0; break; fi; ",
            "pd_partition=${pd_partition%/partition}; ",
            "printf 'partition %s %s\\n' \"$pd_device\" \"${pd_partition##*/}\"; done; ",
            "done; [ \"$pd_topology_complete\" -eq 1 ] && printf 'complete\\n'; fi; true"
        ),
        "printf '__PD_DF__\\n'",
        "(df -PT -B1 2>/dev/null || df -P -B1 2>/dev/null || df -P -k 2>/dev/null || df -k 2>/dev/null || true)",
        "printf '__PD_MOUNTS__\\n'",
        "pd_read_file /proc/mounts || true",
        // Only use ps for RSS when the host cannot report its actual page size.
        // Its lifetime %CPU is deliberately never used for the live process chart.
        "printf '__PD_PROCESSES_MEMORY__\\n'",
        "printf '__PD_PROCESS_COLUMNS_PID_CPU_MEM_RSS_COMMAND__\\n'",
        "case \"$pd_page_size\" in ''|*[!0-9]*|0) (ps -eo pid=,%cpu=,%mem=,rss=,comm= --sort=-rss 2>/dev/null | head -n 10 || true) ;; esac",
        "printf '__PD_PROCESSES_NETWORK__\\n'",
        "(command -v nethogs >/dev/null 2>&1 && timeout 2 nethogs -t -c 1 2>/dev/null | head -n 20 || true)",
        // Full port/service/container inventories are collected only by the active
        // management tab. Keep the fast resource sampler independent of Docker
        // permissions and systemd latency; process Top 10 feeds the status bar.
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
    let processes = parse_processes(&lines);
    let ports = parse_ports(&lines);
    let services = parse_services(&lines);
    let containers = parse_containers(&lines);

    Ok(DeviceMetricsSnapshot {
        sampled_at_ms,
        system,
        cpu,
        cpu_cores,
        memory,
        network_interfaces,
        disk_io,
        disks,
        processes,
        ports,
        services,
        containers,
        // Socket timing belongs to the local transport, not remote command output.
        ssh_latency_milliseconds: None,
        network_sampled_uptime_ms: parse_counter_uptime(&lines, NET_SAMPLE_TIME_MARKER),
        disk_io_sampled_uptime_ms: parse_counter_uptime(&lines, DISK_SAMPLE_TIME_MARKER),
        boot_id: trimmed_value(parse_key_value_section(
            &section_between(&lines, SYSTEM_MARKER, OS_RELEASE_MARKER).unwrap_or_default(),
        ).get("boot_id")),
        counter_sample_clocks_present: lines.iter().any(|line| {
            matches!(line.split_whitespace().next(), Some(NET_SAMPLE_TIME_MARKER | DISK_SAMPLE_TIME_MARKER))
        }),
    })
}

fn parse_counter_uptime(lines: &[&str], marker: &str) -> Option<u64> {
    let value = lines.iter().find_map(|line| {
        let mut fields = line.split_whitespace();
        (fields.next()? == marker).then(|| fields.next()).flatten()
    })?;
    let (seconds, fractional) = value.split_once('.').unwrap_or((value, ""));
    if seconds.is_empty() || !seconds.bytes().all(|byte| byte.is_ascii_digit())
        || !fractional.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    let seconds = seconds.parse::<u64>().ok()?;
    // Parse decimal uptime exactly, without floating-point rounding or shell
    // integer arithmetic. Linux normally supplies hundredths of a second.
    let millis = fractional.bytes().take(3).enumerate().fold(0_u64, |total, (index, byte)| {
        total + u64::from(byte - b'0') * [100, 10, 1][index]
    });
    seconds.checked_mul(1_000)?.checked_add(millis)
}

fn parse_processes(lines: &[&str]) -> Vec<DeviceProcessSample> {
    let mut processes = std::collections::BTreeMap::<u32, DeviceProcessSample>::new();
    let has_counters = lines.iter().any(|line| line.trim() == PROCESS_COUNTERS_MARKER);
    let counter_lines = section_after_until(lines, PROCESS_COUNTERS_MARKER, Some(MEM_MARKER));
    let page_size = counter_lines.iter().find_map(|line| {
        line.strip_prefix("page_size=")?.parse::<u64>().ok().filter(|size| *size > 0)
    });
    let total_memory = parse_memory(lines).ok().map(|memory| memory.total_bytes);
    for line in counter_lines {
        let mut fields = line.splitn(6, ' ');
        let parsed = (|| {
            let pid = fields.next()?.parse::<u32>().ok().filter(|pid| *pid > 0)?;
            let user = fields.next()?.parse::<u64>().ok()?;
            let system = fields.next()?.parse::<u64>().ok()?;
            let start = fields.next()?.parse::<u64>().ok()?;
            let resident_pages = fields.next()?.parse::<u64>().ok();
            let name = fields.next()?.trim();
            if name.is_empty() { return None; }
            let resident_bytes = resident_pages.zip(page_size).and_then(|(pages, size)| pages.checked_mul(size));
            let memory_percent_basis_points = resident_bytes.zip(total_memory)
                .filter(|(_, total)| *total > 0)
                .map(|(resident, total)| ((u128::from(resident) * 10_000) / u128::from(total)).min(u128::from(u32::MAX)) as u32)
                .unwrap_or(0);
            Some(DeviceProcessSample {
                pid, name: name.to_owned(), cpu_percent_basis_points: 0,
                memory_percent_basis_points, network_bytes_per_second: 0,
                resident_bytes, cpu_time_ticks: user.checked_add(system), start_time_ticks: Some(start),
            })
        })();
        if let Some(process) = parsed { processes.insert(process.pid, process); }
    }
    for marker in [PROCESSES_CPU_MARKER, PROCESSES_MEMORY_MARKER] {
        let mut has_rss_columns = false;
        for line in section_after_until(lines, marker, next_inventory_marker(lines, marker)) {
            if line.trim() == PROCESS_COLUMNS_RSS {
                has_rss_columns = true;
                continue;
            }
            let parts = line.split_whitespace().collect::<Vec<_>>();
            if parts.len() < if has_rss_columns { 5 } else { 4 } {
                continue;
            }
            let Ok(pid) = parts[0].parse::<u32>() else {
                continue;
            };
            let Ok(cpu) = parse_percent_basis_points(parts[if has_rss_columns { 1 } else { 2 }]) else {
                continue;
            };
            let Ok(memory) = parse_percent_basis_points(parts[if has_rss_columns { 2 } else { 3 }]) else {
                continue;
            };
            let (name, resident_bytes) = if has_rss_columns {
                // Keep the command at the end: Linux comm may contain spaces,
                // including numeric words which must not shift the RSS column.
                let resident_bytes = parts[3].parse::<u64>().ok().and_then(|kb| kb.checked_mul(1024));
                (parts[4..].join(" "), resident_bytes)
            } else {
                (parts[1].to_string(), None)
            };
            let entry = processes.entry(pid).or_insert(DeviceProcessSample {
                pid,
                name: name.clone(),
                cpu_percent_basis_points: 0,
                memory_percent_basis_points: 0,
                network_bytes_per_second: 0,
                resident_bytes: None,
                cpu_time_ticks: None,
                start_time_ticks: None,
            });
            entry.name = name;
            if resident_bytes.is_some() {
                entry.resident_bytes = resident_bytes;
            }
            entry.cpu_percent_basis_points = if has_counters { 0 } else { cpu };
            entry.memory_percent_basis_points = memory;
        }
    }
    for line in section_after_until(lines, PROCESSES_NETWORK_MARKER, Some(PORTS_MARKER)) {
        let parts = line.split_whitespace().collect::<Vec<_>>();
        if parts.len() < 3 {
            continue;
        }
        let rate = parse_rate_bytes(parts.last().copied().unwrap_or_default())
            .or_else(|_| parse_nethogs_rate(&parts))
            .unwrap_or(0);
        let process_token = parts.first().copied().unwrap_or_default();
        let (process_name, process_pid) = parse_nethogs_process(process_token);
        // Trace output carries an exact PID. Do not let a same-name process
        // earlier in the map steal that process's network sample.
        let entry = if let Some(pid) = process_pid {
            processes.get_mut(&pid)
        } else {
            processes.values_mut().find(|entry| {
                entry.name == process_name
                    || process_name.contains(&entry.name)
                    || entry.name.contains(process_name)
            })
        };
        if let Some(entry) = entry {
            entry.network_bytes_per_second = rate;
        } else if let Some(pid) = process_pid {
            processes.insert(
                pid,
                DeviceProcessSample {
                    pid,
                    name: process_name.to_string(),
                    cpu_percent_basis_points: 0,
                    memory_percent_basis_points: 0,
                    network_bytes_per_second: rate,
                    resident_bytes: None,
                    cpu_time_ticks: None,
                    start_time_ticks: None,
                },
            );
        }
    }
    let mut result = processes.into_values().collect::<Vec<_>>();
    result.sort_by(|a, b| b.cpu_percent_basis_points.cmp(&a.cpu_percent_basis_points));
    // Keep CPU/memory leaders together with the bounded nethogs sample. The
    // client independently sorts this set for each resource and shows its own
    // Top 10; retaining the network-only entries prevents them from being
    // discarded by the CPU sort.
    // The interval CPU leaders cannot be known until the next sample. Retain
    // every procfs record; only legacy pre-ranked ps/nethogs data is bounded.
    if !has_counters { result.truncate(40); }
    result
}

fn parse_nethogs_process(value: &str) -> (&str, Option<u32>) {
    // nethogs trace identifiers end with /PID/UID; the UID is numeric too.
    // Split from the right so numeric directories do not affect the PID.
    let Some((process_and_pid, uid)) = value.rsplit_once('/') else {
        return (value, None);
    };
    let Some((process, pid)) = process_and_pid.rsplit_once('/') else {
        return (value, None);
    };
    let Some(pid) = pid.parse::<u32>().ok().filter(|pid| *pid > 0) else {
        return (value, None);
    };
    let name = process.rsplit('/').next().unwrap_or_default();
    if uid.parse::<u32>().is_err() || name.is_empty() {
        return (value, None);
    }
    (name, Some(pid))
}

fn parse_nethogs_rate(parts: &[&str]) -> Result<u64, String> {
    let numeric = parts
        .iter()
        .rev()
        .filter_map(|value| value.parse::<f64>().ok())
        .take(2)
        .collect::<Vec<_>>();
    if numeric.is_empty() {
        return Err(METRICS_PARSE_FAILED.to_string());
    }
    Ok((numeric.into_iter().sum::<f64>() * 1024.0).max(0.0).round() as u64)
}

fn next_inventory_marker<'a>(_lines: &[&'a str], marker: &str) -> Option<&'a str> {
    let markers = [
        PROCESSES_CPU_MARKER,
        PROCESSES_MEMORY_MARKER,
        PROCESSES_NETWORK_MARKER,
        PORTS_MARKER,
        SERVICES_MARKER,
        CONTAINERS_MARKER,
    ];
    let index = markers.iter().position(|value| *value == marker)?;
    markers.get(index + 1).copied()
}

fn parse_percent_basis_points(value: &str) -> Result<u32, String> {
    let value = value.trim().trim_end_matches('%');
    let parsed = value
        .parse::<f64>()
        .map_err(|_| METRICS_PARSE_FAILED.to_string())?;
    Ok((parsed.max(0.0) * 100.0).round().min(u32::MAX as f64) as u32)
}

fn parse_rate_bytes(value: &str) -> Result<u64, String> {
    let value = value.trim().to_ascii_lowercase();
    let (number, multiplier) = if let Some(value) = value.strip_suffix("kb/s") {
        (value, 1024.0)
    } else if let Some(value) = value.strip_suffix("mb/s") {
        (value, 1024.0 * 1024.0)
    } else if let Some(value) = value.strip_suffix("b/s") {
        (value, 1.0)
    } else {
        return Err(METRICS_PARSE_FAILED.to_string());
    };
    let parsed = number
        .trim()
        .parse::<f64>()
        .map_err(|_| METRICS_PARSE_FAILED.to_string())?;
    Ok((parsed.max(0.0) * multiplier).round() as u64)
}

fn parse_ports(lines: &[&str]) -> Vec<DevicePortSample> {
    section_after_until(lines, PORTS_MARKER, Some(SERVICES_MARKER))
        .into_iter()
        .filter_map(|line| {
            let parts = line.split_whitespace().collect::<Vec<_>>();
            if parts.len() < 4
                || parts[0].eq_ignore_ascii_case("netid")
                || parts[0].eq_ignore_ascii_case("proto")
            {
                return None;
            }
            let protocol = parts[0].to_ascii_uppercase();
            // `ss -lntup` emits State/Recv-Q/Send-Q/Local/Peer, while
            // `netstat -lntup` emits Recv-Q/Send-Q/Local/Peer/State/PID.
            // Select the local endpoint from the format instead of relying
            // on one fixed column so fallback probing remains correct.
            let local_index = if parts.get(1).is_some_and(|value| {
                value.eq_ignore_ascii_case("LISTEN")
                    || value.eq_ignore_ascii_case("UNCONN")
                    || value.eq_ignore_ascii_case("CLOSE-WAIT")
                    || value.eq_ignore_ascii_case("SYN-RECV")
            }) {
                4
            } else {
                3
            };
            let address = parts.get(local_index).or_else(|| parts.get(3))?.to_string();
            let process = line
                .split("users:(")
                .nth(1)
                .map(|value| value.trim_end_matches(')').to_string())
                .filter(|value| !value.is_empty())
                .or_else(|| parts.get(6).map(|value| (*value).to_string()))
                .unwrap_or_default();
            Some(DevicePortSample {
                address,
                protocol,
                process,
            })
        })
        .collect()
}

fn parse_services(lines: &[&str]) -> Vec<DeviceServiceSample> {
    section_after_until(lines, SERVICES_MARKER, Some(CONTAINERS_MARKER))
        .into_iter()
        .filter_map(|line| {
            let parts = line.split_whitespace().collect::<Vec<_>>();
            if parts.len() < 3 {
                return None;
            }
            let name = parts[0].to_string();
            let state = parts.get(2).copied().unwrap_or("unknown").to_string();
            let description = parts[3..].join(" ");
            Some(DeviceServiceSample {
                name,
                description,
                state,
            })
        })
        .collect()
}

fn parse_containers(lines: &[&str]) -> Vec<DeviceContainerSample> {
    section_after_until(lines, CONTAINERS_MARKER, None)
        .into_iter()
        .filter_map(|line| {
            let parts = line.split('\t').collect::<Vec<_>>();
            if parts.len() < 4 {
                return None;
            }
            let status = parts[3].to_string();
            Some(DeviceContainerSample {
                id: parts[0].to_string(),
                name: parts[1].to_string(),
                image: parts[2].to_string(),
                running: status.to_ascii_lowercase().starts_with("up"),
                status,
            })
        })
        .collect()
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
            index.parse::<u32>().ok()?;
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
    // guest and guest_nice (fields 9/10) are already included in user/nice.
    // Counting them twice inflates the interval denominator on VM hosts.
    let total_ticks = ticks.iter().take(8).try_fold(0u64, |total, ticks| total.checked_add(*ticks))
        .ok_or_else(|| METRICS_PARSE_FAILED.to_string())?;
    let idle_ticks = ticks.get(3).copied().unwrap_or(0).checked_add(ticks.get(4).copied().unwrap_or(0))
        .ok_or_else(|| METRICS_PARSE_FAILED.to_string())?;

    Ok(DeviceCpuSample {
        total_ticks,
        idle_ticks,
        core_index: parts[0].strip_prefix("cpu").and_then(|index| index.parse().ok()),
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
    let mut swap_total_kb = None;
    let mut swap_free_kb = None;

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
            Some("SwapTotal:") => swap_total_kb = parse_kb(parts.next()),
            Some("SwapFree:") => swap_free_kb = parse_kb(parts.next()),
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
        free_bytes: free_kb.map(|value| value.saturating_mul(1024).min(total_bytes)),
        buffers_bytes: buffers_kb.map(|value| value.saturating_mul(1024).min(total_bytes)),
        cached_bytes: cached_kb.map(|value| {
            value
                .saturating_add(reclaimable_kb.unwrap_or(0))
                .saturating_mul(1024)
                .min(total_bytes)
        }),
        swap_total_bytes: swap_total_kb.map(|value| value.saturating_mul(1024)),
        swap_free_bytes: swap_free_kb.map(|value| {
            let value = value.saturating_mul(1024);
            swap_total_kb
                .map(|total| value.min(total.saturating_mul(1024)))
                .unwrap_or(value)
        }),
    })
}

fn parse_networks(lines: &[&str]) -> Result<Vec<DeviceNetworkSample>, String> {
    let section = section_between(lines, NET_MARKER, NET_TOPOLOGY_MARKER)
        .or_else(|| section_between(lines, NET_MARKER, DISKSTATS_MARKER))
        .or_else(|| section_between(lines, NET_MARKER, DF_MARKER))
        .unwrap_or_default();
    let topology = parse_network_topology(lines);
    let mut samples = Vec::new();
    let mut seen = HashSet::new();
    for line in section {
        let Some((name, values)) = line.rsplit_once(':') else {
            continue;
        };
        // procfs reports the real name, not `ip link`'s decorative @peer suffix.
        let name = name.trim();
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
        if !seen.insert(name) {
            continue;
        }
        samples.push(DeviceNetworkSample {
            name: name.to_owned(),
            receive_bytes,
            transmit_bytes,
            lower_interface_names: topology.as_ref().and_then(|graph| graph.get(name).cloned()),
        });
    }
    Ok(samples)
}

fn parse_network_topology(lines: &[&str]) -> Option<HashMap<String, Vec<String>>> {
    let section = section_between(lines, NET_TOPOLOGY_MARKER, DISKSTATS_MARKER)
        .or_else(|| section_between(lines, NET_TOPOLOGY_MARKER, DF_MARKER))?;
    let mut graph = HashMap::<String, Vec<String>>::new();
    let mut edges = HashSet::new();
    let mut complete = false;
    for (index, line) in section.iter().enumerate() {
        let parts = line.split_whitespace().collect::<Vec<_>>();
        if complete || index > MAX_NETWORK_TOPOLOGY_RECORDS {
            return None;
        }
        if parts.as_slice() == ["complete"] {
            complete = true;
            continue;
        }
        if index >= MAX_NETWORK_TOPOLOGY_RECORDS {
            return None;
        }
        match parts.as_slice() {
            ["interface", name] => { graph.entry((*name).to_owned()).or_default(); }
            ["lower", name, lower] => {
                let interfaces = graph.get_mut(*name)?;
                if edges.insert(((*name).to_owned(), (*lower).to_owned())) {
                    interfaces.push((*lower).to_owned());
                }
            }
            _ => return None,
        }
    }
    complete.then_some(graph)
}

fn parse_disk_io(lines: &[&str]) -> Option<DeviceDiskIOSample> {
    let section = section_between(lines, DISKSTATS_MARKER, DF_MARKER)?;
    let counters = section
        .iter()
        .filter_map(|line| {
            let parts = line.split_whitespace().collect::<Vec<_>>();
            if parts.len() < 10 || !is_included_disk_io_device(parts[2]) {
                return None;
            }
            Some((
                parts[2],
                (parts[5].parse::<u64>().ok()?, parts[9].parse::<u64>().ok()?),
            ))
        })
        .collect::<HashMap<_, _>>();
    let topology = DiskIOTopology::parse(lines);
    let selected = topology.select_devices(&counters);
    if selected.is_empty() {
        return None;
    }
    let (read_sectors, write_sectors) =
        selected
            .into_iter()
            .fold((0_u64, 0_u64), |(read, write), name| {
                let (device_read, device_write) = counters[name];
                (
                    read.saturating_add(device_read),
                    write.saturating_add(device_write),
                )
            });
    Some(DeviceDiskIOSample {
        read_bytes: read_sectors.saturating_mul(512),
        write_bytes: write_sectors.saturating_mul(512),
    })
}

#[derive(Default)]
struct DiskIOTopology<'a> {
    disks: HashSet<&'a str>,
    partitions: HashMap<&'a str, &'a str>,
    slaves: HashMap<&'a str, Vec<&'a str>>,
    complete: bool,
}

impl<'a> DiskIOTopology<'a> {
    fn parse(lines: &'a [&'a str]) -> Self {
        let mut topology = Self::default();
        for line in section_after_until(lines, DISK_TOPOLOGY_MARKER, Some(DF_MARKER)) {
            let parts = line.split_whitespace().collect::<Vec<_>>();
            match parts.as_slice() {
                ["disk", name] => {
                    topology.disks.insert(name);
                }
                ["partition", parent, name] => {
                    topology.partitions.insert(name, parent);
                }
                ["slave", parent, name] => {
                    topology.slaves.entry(parent).or_default().push(name);
                }
                ["complete"] => topology.complete = true,
                _ => {}
            }
        }
        topology
    }

    fn select_devices(&self, counters: &HashMap<&'a str, (u64, u64)>) -> HashSet<&'a str> {
        if self.complete && !self.disks.is_empty() {
            let candidates = counters
                .keys()
                .copied()
                .filter(|name| self.disks.contains(name))
                .collect::<HashSet<_>>();
            if !candidates.is_empty() {
                // Choose the lowest visible device with usable counters in each
                // stack. Partition counters are already covered by their parent
                // disk. Retain a virtual disk when its backing device is hidden.
                return candidates
                    .iter()
                    .copied()
                    .filter(|name| !self.has_counted_backing_device(name, &candidates))
                    .collect();
            }
        }
        // Old probes and restricted sysfs cannot describe dependencies. Prefer
        // physical whole disks; otherwise md backs dm in the common RAID+LVM
        // layout. Never sum both layers merely because both report counters.
        let physical = counters
            .keys()
            .copied()
            .filter(|name| !is_stacked_disk_io_device(name))
            .collect::<HashSet<_>>();
        if !physical.is_empty() {
            return physical;
        }
        let raid = counters
            .keys()
            .copied()
            .filter(|name| name.starts_with("md"))
            .collect::<HashSet<_>>();
        if !raid.is_empty() {
            raid
        } else {
            counters.keys().copied().collect()
        }
    }

    fn has_counted_backing_device(&self, name: &str, candidates: &HashSet<&str>) -> bool {
        let mut pending = self.slaves.get(name).cloned().unwrap_or_default();
        let mut visited = HashSet::new();
        while let Some(slave) = pending.pop() {
            let device = self.partitions.get(slave).copied().unwrap_or(slave);
            if device == name || !visited.insert(device) {
                continue;
            }
            if candidates.contains(device) {
                return true;
            }
            if let Some(backing) = self.slaves.get(device) {
                pending.extend(backing.iter().copied());
            }
        }
        false
    }
}

fn is_stacked_disk_io_device(name: &str) -> bool {
    name.starts_with("dm-") || name.starts_with("md")
}

fn is_included_disk_io_device(name: &str) -> bool {
    let lowercased = name.to_ascii_lowercase();
    if lowercased.starts_with("loop")
        || lowercased.starts_with("zram")
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
        || ["mmcblk", "md", "nbd", "rbd", "dm-"]
            .iter()
            .any(|prefix| is_numbered_partition(&lowercased, prefix))
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

fn is_numbered_partition(name: &str, prefix: &str) -> bool {
    let Some(partition_index) = name.rfind('p') else {
        return false;
    };
    let (disk_name, partition) = name.split_at(partition_index);
    disk_name.strip_prefix(prefix).is_some_and(|value| {
        !value.is_empty() && value.chars().all(|character| character.is_ascii_digit())
    }) && partition.len() > 1
        && partition[1..]
            .chars()
            .all(|character| character.is_ascii_digit())
}

fn parse_disks(lines: &[&str]) -> Result<Vec<DeviceDiskSample>, String> {
    let section = section_after_until(lines, DF_MARKER, Some(MOUNTS_MARKER));
    let mount_types = parse_mount_types(lines);
    let mut all_disks = Vec::new();
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
        all_disks.push(disk);
    }

    // A valid local filesystem need not be named /dev/... (for example ZFS
    // pools and datasets). The type filter above, not another mount's source,
    // determines whether it belongs in the disk list.
    Ok(all_disks)
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
        || (normalized_type.is_empty()
            && (normalized_fs.contains(":/") || normalized_fs.starts_with("//")))
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
    use super::{
        build_device_metrics_probe_command, parse_cpu_model, parse_cpu_sample_line, parse_device_metrics_probe,
        parse_counter_uptime, parse_cpu_cores, parse_disk_io, parse_disks, parse_memory, parse_networks,
        parse_network_topology, parse_nethogs_process, parse_processes,
    };

    #[test]
    fn cpu_totals_do_not_double_count_guest_time_or_overflow() {
        let sample = parse_cpu_sample_line("cpu 100 20 30 400 5 6 7 8 50 10").unwrap();
        assert_eq!(sample.total_ticks, 576);
        assert_eq!(sample.idle_ticks, 405);
        assert_eq!(sample.core_index, None);
        assert!(parse_cpu_sample_line("cpu 18446744073709551615 1 0 0").is_err());
    }

    #[test]
    fn counter_clock_parses_exact_milliseconds_and_rejects_invalid_times() {
        for (value, expected) in [
            ("0.00", Some(0)), ("123.4", Some(123400)), ("123.45", Some(123450)),
            ("123.4567", Some(123456)), ("18446744073709551.615", Some(u64::MAX)),
            ("18446744073709551.616", None), ("-1.00", None), ("1e3", None),
            ("NaN", None), ("1.2.3", None), ("", None),
        ] {
            let line = format!("__PD_NET_SAMPLE_UPTIME__ {value}");
            assert_eq!(parse_counter_uptime(&[&line], "__PD_NET_SAMPLE_UPTIME__"), expected, "{value}");
        }
        assert_eq!(parse_counter_uptime(&["other 123.45"], "__PD_NET_SAMPLE_UPTIME__"), None);
    }

    #[test]
    fn counter_clocks_are_independent_and_do_not_pollute_network_or_disk_topology() {
        let fixture = [
            "__PD_SYSTEM__", "boot_id=boot-a", "__PD_OS_RELEASE__",
            "__PD_CPU__ cpu 100 0 0 900", "__PD_MEM__", "MemTotal: 1000 kB", "MemAvailable: 500 kB",
            "__PD_NET__", "eth0: 100 0 0 0 0 0 0 0 200 0 0 0 0 0 0 0",
            "__PD_NET_SAMPLE_UPTIME__ 100.25", "__PD_NET_TOPOLOGY__", "interface eth0", "complete",
            "__PD_DISKSTATS__", "8 0 sda 1 0 100 0 1 0 200 0 0 0 0",
            "__PD_DISK_SAMPLE_UPTIME__ 101.50", "__PD_DISK_TOPOLOGY__", "disk sda", "complete",
            "__PD_DF__", "Filesystem 1B-blocks Used Available Use% Mounted on", "/dev/sda1 10000 5000 5000 50% /",
        ].join("\n");
        let sample = parse_device_metrics_probe(&fixture, 900_000).unwrap();
        assert_eq!(sample.sampled_at_ms, 900_000);
        assert_eq!(sample.network_sampled_uptime_ms, Some(100_250));
        assert_eq!(sample.disk_io_sampled_uptime_ms, Some(101_500));
        assert_eq!(sample.boot_id.as_deref(), Some("boot-a"));
        assert!(sample.counter_sample_clocks_present);
        assert_eq!(sample.network_interfaces.len(), 1);
        assert_eq!(sample.network_interfaces[0].lower_interface_names, Some(vec![]));
        assert_eq!(sample.disk_io.unwrap().read_bytes, 100 * 512);
        let old = fixture.lines().filter(|line| !line.contains("SAMPLE_UPTIME") && !line.starts_with("boot_id="))
            .collect::<Vec<_>>().join("\n");
        let legacy = parse_device_metrics_probe(&old, 900_000).unwrap();
        assert_eq!(legacy.network_sampled_uptime_ms, None);
        assert_eq!(legacy.disk_io_sampled_uptime_ms, None);
        assert_eq!(legacy.boot_id, None);
        assert!(!legacy.counter_sample_clocks_present);
        // Unreadable or malformed clocks still identify the modern protocol.
        // They must never enable command-completion timing in the client.
        for marker in ["__PD_NET_SAMPLE_UPTIME__", "__PD_DISK_SAMPLE_UPTIME__"] {
            for value in ["", "NaN", "-1", "18446744073709551.616"] {
                let unavailable = parse_device_metrics_probe(&format!("{old}\n{marker} {value}"), 900_000).unwrap();
                assert!(unavailable.counter_sample_clocks_present);
                assert_eq!(unavailable.network_sampled_uptime_ms, None);
                assert_eq!(unavailable.disk_io_sampled_uptime_ms, None);
                assert_eq!(unavailable.boot_id, None);
            }
        }
        let lookalike = parse_device_metrics_probe(&format!("{old}\n__PD_NET_SAMPLE_UPTIME__invalid 10"), 900_000).unwrap();
        assert!(!lookalike.counter_sample_clocks_present);
    }

    #[test]
    fn counter_clock_probe_uses_posix_builtins_at_each_counter_read() {
        let command = build_device_metrics_probe_command();
        assert!(command.contains("pd_read_file /proc/net/dev; pd_counter_time __PD_NET_SAMPLE_UPTIME__; printf '__PD_NET_TOPOLOGY__"));
        assert!(command.contains("pd_read_file /proc/diskstats || true; pd_counter_time __PD_DISK_SAMPLE_UPTIME__; printf '__PD_DISK_TOPOLOGY__"));
        let directory = tempfile::tempdir().unwrap();
        let uptime = directory.path().join("uptime");
        std::fs::write(&uptime, "12345.67 99999.00\n").unwrap();
        let start = command.find("pd_counter_time() {").unwrap();
        let end = command[start..].find("; pd_read_first_cpu_model").unwrap() + start;
        let function = command[start..end].replace("/proc/uptime", &format!("'{}'", uptime.display()));
        let run = || std::process::Command::new("/bin/sh").arg("-c")
            .arg(format!("{function}; pd_counter_time __PD_NET_SAMPLE_UPTIME__; pd_counter_time __PD_DISK_SAMPLE_UPTIME__"))
            .env("PATH", "/nonexistent").output().unwrap();
        let output = run();
        assert!(output.status.success());
        assert_eq!(String::from_utf8(output.stdout).unwrap(), "__PD_NET_SAMPLE_UPTIME__ 12345.67\n__PD_DISK_SAMPLE_UPTIME__ 12345.67\n");
        std::fs::remove_file(uptime).unwrap();
        let missing = run();
        assert!(missing.status.success());
        assert!(missing.stderr.is_empty());
        assert_eq!(String::from_utf8(missing.stdout).unwrap(), "__PD_NET_SAMPLE_UPTIME__ \n__PD_DISK_SAMPLE_UPTIME__ \n");
    }

    #[test]
    fn cpu_cores_keep_kernel_identity_across_offline_and_reordered_cores() {
        let cores = parse_cpu_cores(&[
            "__PD_CPU__", "cpu 1000 0 500 8500", "cpu2 100 0 50 850",
            "cpu0 200 0 100 700", "cpu4294967296 100 0 50 850", "__PD_MEM__",
        ]);
        assert_eq!(cores.iter().map(|core| core.core_index).collect::<Vec<_>>(), [Some(2), Some(0)]);
        assert_eq!(cores[0].idle_ticks, 850);
        assert_eq!(cores[1].idle_ticks, 700);
    }

    #[test]
    fn network_names_preserve_at_signs_and_repeated_records_do_not_create_collisions() {
        let networks = parse_networks(&[
            "__PD_NET__",
            "eth0: 100 0 0 0 0 0 0 0 200 0 0 0 0 0 0 0",
            "eth0@vlan: 300 0 0 0 0 0 0 0 400 0 0 0 0 0 0 0",
            "eth0: 500 0 0 0 0 0 0 0 600 0 0 0 0 0 0 0",
            "__PD_DF__",
        ]).unwrap();
        assert_eq!(networks.iter().map(|net| net.name.as_str()).collect::<Vec<_>>(), ["eth0", "eth0@vlan"]);
        assert_eq!(networks[0].receive_bytes, 100);
        assert_eq!(networks[1].receive_bytes, 300);
        assert!(networks.iter().all(|net| net.lower_interface_names.is_none()));
    }

    #[test]
    fn network_topology_distinguishes_leaf_from_missing_and_preserves_layer_edges() {
        let networks = parse_networks(&[
            "__PD_NET__",
            "eth0: 100 0 0 0 0 0 0 0 200 0 0 0 0 0 0 0",
            "bond0: 100 0 0 0 0 0 0 0 200 0 0 0 0 0 0 0",
            "br0: 100 0 0 0 0 0 0 0 200 0 0 0 0 0 0 0",
            "new0: 100 0 0 0 0 0 0 0 200 0 0 0 0 0 0 0",
            "__PD_NET_TOPOLOGY__",
            "interface br0", "lower br0 bond0", "lower br0 bond0",
            "interface bond0", "lower bond0 eth0", "interface eth0", "complete",
            "__PD_DISKSTATS__",
        ]).unwrap();
        assert_eq!(networks.len(), 4);
        assert_eq!(networks[0].lower_interface_names, Some(vec![]));
        assert_eq!(networks[1].lower_interface_names, Some(vec!["eth0".into()]));
        assert_eq!(networks[2].lower_interface_names, Some(vec!["bond0".into()]));
        assert_eq!(networks[3].lower_interface_names, None);
    }

    #[test]
    fn network_topology_is_unknown_when_missing_truncated_malformed_or_over_limit() {
        for lines in [
            vec!["__PD_NET__", "__PD_DF__"],
            vec!["__PD_NET_TOPOLOGY__", "interface eth0", "__PD_DF__"],
            vec!["__PD_NET_TOPOLOGY__", "lower eth0 bond0", "complete", "__PD_DF__"],
            vec!["__PD_NET_TOPOLOGY__", "interface eth0", "complete", "interface bond0", "__PD_DF__"],
        ] {
            assert!(parse_network_topology(&lines).is_none(), "{lines:?}");
        }
        let mut lines = vec!["__PD_NET_TOPOLOGY__"];
        lines.extend(std::iter::repeat_n("interface eth0", 4096));
        lines.extend(["complete", "__PD_DF__"]);
        assert!(parse_network_topology(&lines).is_some());
        lines.insert(1, "interface bond0");
        assert!(parse_network_topology(&lines).is_none());
    }

    #[test]
    fn network_topology_probe_uses_bounded_posix_builtins_and_real_lower_link_names() {
        let directory = tempfile::tempdir().unwrap();
        let root = directory.path();
        for name in ["eth0", "eth0@vlan", "bond0", "br0"] {
            std::fs::create_dir_all(root.join(name)).unwrap();
        }
        for (parent, lower) in [("br0", "bond0"), ("bond0", "eth0"), ("eth0@vlan", "eth0")] {
            std::os::unix::fs::symlink(root.join(lower), root.join(parent).join(format!("lower_{lower}"))).unwrap();
        }
        let command = build_device_metrics_probe_command();
        let start = command.find("pd_net_topology_count=0").unwrap();
        let end = command[start..].find("; printf '__PD_DISKSTATS__").unwrap() + start;
        let probe = command[start..end].replace("/sys/class/net", &format!("'{}'", root.display()));
        let run = |probe: &str| {
            let output = std::process::Command::new("/bin/sh").arg("-c").arg(probe)
                .env("PATH", "/nonexistent").output().unwrap();
            assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
            String::from_utf8(output.stdout).unwrap()
        };
        let output = run(&probe);
        for expected in ["interface eth0@vlan", "lower eth0@vlan eth0", "lower br0 bond0", "lower bond0 eth0", "complete"] {
            assert!(output.lines().any(|line| line == expected), "missing {expected}: {output}");
        }
        let bounded = run(&probe.replace("-gt 4096", "-gt 2"));
        assert_eq!(bounded.lines().count(), 2);
        assert!(!bounded.lines().any(|line| line == "complete"));
        std::os::unix::fs::symlink(root.join("missing"), root.join("eth0/lower_missing")).unwrap();
        assert!(!run(&probe).lines().any(|line| line == "complete"));
    }

    #[test]
    fn preserves_memory_breakdown_without_changing_available_memory() {
        let memory = parse_memory(&[
            "__PD_MEM__",
            "MemTotal: 10000 kB",
            "MemAvailable: 6500 kB",
            "MemFree: 1000 kB",
            "Buffers: 500 kB",
            "Cached: 4000 kB",
            "SReclaimable: 500 kB",
            "Shmem: 200 kB",
            "SwapTotal: 2000 kB",
            "SwapFree: 250 kB",
            "__PD_NET__",
        ])
        .expect("memory details");

        assert_eq!(memory.total_bytes, 10000 * 1024);
        assert_eq!(memory.available_bytes, 6500 * 1024);
        assert_eq!(memory.free_bytes, Some(1000 * 1024));
        assert_eq!(memory.buffers_bytes, Some(500 * 1024));
        assert_eq!(memory.cached_bytes, Some(4500 * 1024));
        assert_eq!(memory.swap_total_bytes, Some(2000 * 1024));
        assert_eq!(memory.swap_free_bytes, Some(250 * 1024));
    }

    #[test]
    fn distinguishes_missing_memory_details_from_zero_values() {
        let missing = parse_memory(&[
            "__PD_MEM__",
            "MemTotal: 10000 kB",
            "MemAvailable: 6500 kB",
            "Buffers: invalid kB",
            "SwapFree: invalid kB",
            "__PD_NET__",
        ])
        .expect("minimal memory sample");
        assert_eq!(missing.free_bytes, None);
        assert_eq!(missing.buffers_bytes, None);
        assert_eq!(missing.cached_bytes, None);
        assert_eq!(missing.swap_total_bytes, None);
        assert_eq!(missing.swap_free_bytes, None);

        let zero = parse_memory(&[
            "__PD_MEM__",
            "MemTotal: 10000 kB",
            "MemFree: 1000 kB",
            "Buffers: 0 kB",
            "Cached: 0 kB",
            "SwapTotal: 0 kB",
            "SwapFree: 0 kB",
            "__PD_NET__",
        ])
        .expect("memory sample without swap or cache");
        assert_eq!(zero.available_bytes, 1000 * 1024);
        assert_eq!(zero.buffers_bytes, Some(0));
        assert_eq!(zero.cached_bytes, Some(0));
        assert_eq!(zero.swap_total_bytes, Some(0));
        assert_eq!(zero.swap_free_bytes, Some(0));
    }

    #[test]
    fn memory_details_saturate_and_bound_inconsistent_counters() {
        let memory = parse_memory(&[
            "__PD_MEM__",
            "MemTotal: 10000 kB",
            "MemAvailable: 6500 kB",
            "MemFree: 18446744073709551615 kB",
            "Buffers: 18446744073709551615 kB",
            "Cached: 18446744073709551615 kB",
            "SReclaimable: 18446744073709551615 kB",
            "SwapTotal: 2000 kB",
            "SwapFree: 18446744073709551615 kB",
            "__PD_NET__",
        ])
        .expect("memory sample with inconsistent optional counters");
        assert_eq!(memory.available_bytes, 6500 * 1024);
        assert_eq!(memory.free_bytes, Some(memory.total_bytes));
        assert_eq!(memory.buffers_bytes, Some(memory.total_bytes));
        assert_eq!(memory.cached_bytes, Some(memory.total_bytes));
        assert_eq!(memory.swap_free_bytes, memory.swap_total_bytes);
    }

    #[test]
    fn legacy_memory_json_does_not_require_breakdown_fields() {
        let memory: crate::domain::device_metrics::DeviceMemorySample =
            serde_json::from_str(r#"{"total_bytes":10000,"available_bytes":6500}"#)
                .expect("legacy memory record");
        assert_eq!(memory.total_bytes, 10000);
        assert_eq!(memory.available_bytes, 6500);
        assert_eq!(memory.free_bytes, None);
        assert_eq!(memory.buffers_bytes, None);
        assert_eq!(memory.cached_bytes, None);
        assert_eq!(memory.swap_total_bytes, None);
        assert_eq!(memory.swap_free_bytes, None);
    }

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
        assert!(!command.contains("systemctl"));
        assert!(!command.contains("docker ps"));
        assert!(!command.contains("ss -lntup"));
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

        assert_eq!(disk_io.read_bytes, 4_000 * 512);
        assert_eq!(disk_io.write_bytes, 6_000 * 512);
    }

    #[test]
    fn disk_topology_probe_reads_sysfs_links_with_posix_shell_and_no_external_commands() {
        let directory = tempfile::tempdir().unwrap();
        let root = directory.path();
        for name in ["sda", "dm-0", "dm-1"] {
            std::fs::create_dir_all(root.join(name).join("slaves")).unwrap();
        }
        std::fs::create_dir_all(root.join("sda/sda1")).unwrap();
        std::fs::write(root.join("sda/sda1/partition"), "1").unwrap();
        std::os::unix::fs::symlink(root.join("sda/sda1"), root.join("dm-0/slaves/sda1")).unwrap();
        std::os::unix::fs::symlink(root.join("dm-0"), root.join("dm-1/slaves/dm-0")).unwrap();
        let command = build_device_metrics_probe_command();
        let start = command.find("pd_topology_count=0").unwrap();
        let end = command[start..].find("; printf '__PD_DF__").unwrap() + start;
        let probe = command[start..end].replace("/sys/block", &format!("'{}'", root.display()));
        let output = std::process::Command::new("/bin/sh")
            .arg("-c")
            .arg(&probe)
            .env("PATH", "/nonexistent")
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        let stdout = String::from_utf8(output.stdout).unwrap();
        for expected in [
            "disk sda",
            "partition sda sda1",
            "slave dm-0 sda1",
            "slave dm-1 dm-0",
            "complete",
        ] {
            assert!(
                stdout.lines().any(|line| line == expected),
                "missing {expected}: {stdout}"
            );
        }
        // With unreadable/missing topology, avoid declaring a complete graph.
        std::fs::remove_dir(root.join("sda/slaves")).unwrap();
        let output = std::process::Command::new("/bin/sh")
            .arg("-c")
            .arg(&probe)
            .output()
            .unwrap();
        assert!(output.status.success());
        assert!(!String::from_utf8(output.stdout)
            .unwrap()
            .lines()
            .any(|line| line == "complete"));
    }

    #[test]
    fn disk_topology_probe_bounds_output_on_hosts_with_thousands_of_block_devices() {
        let directory = tempfile::tempdir().unwrap();
        for index in 0..4097 {
            std::fs::create_dir(directory.path().join(format!("disk{index:04}"))).unwrap();
        }
        let command = build_device_metrics_probe_command();
        let start = command.find("pd_topology_count=0").unwrap();
        let end = command[start..].find("; printf '__PD_DF__").unwrap() + start;
        let probe =
            command[start..end].replace("/sys/block", &format!("'{}'", directory.path().display()));
        let output = std::process::Command::new("/bin/sh")
            .arg("-c")
            .arg(probe)
            .output()
            .unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8(output.stdout).unwrap();
        assert_eq!(stdout.lines().count(), 4096);
        assert!(!stdout.lines().any(|line| line == "complete"));
    }

    #[test]
    fn disk_io_counts_lvm_and_encryption_backing_disk_only_once() {
        let lines = [
            "__PD_DISKSTATS__",
            "8 0 sda 1 0 2048 0 1 0 4096 0",
            "8 1 sda1 1 0 2048 0 1 0 4096 0",
            "253 0 dm-0 1 0 2048 0 1 0 4096 0",
            "253 1 dm-1 1 0 2048 0 1 0 4096 0",
            "__PD_DISK_TOPOLOGY__",
            "disk sda",
            "partition sda sda1",
            "disk dm-0",
            "slave dm-0 sda1",
            "disk dm-1",
            "slave dm-1 dm-0",
            "complete",
            "__PD_DF__",
        ];
        let sample = parse_disk_io(&lines).unwrap();
        assert_eq!(sample.read_bytes, 1024 * 1024);
        assert_eq!(sample.write_bytes, 2 * 1024 * 1024);
    }

    #[test]
    fn disk_io_uses_physical_raid_members_and_independent_disks() {
        let lines = [
            "__PD_DISKSTATS__",
            "8 0 sda 1 0 1024 0 1 0 2048 0",
            "8 1 sda1 1 0 1024 0 1 0 2048 0",
            "8 16 sdb 1 0 1024 0 1 0 2048 0",
            "8 17 sdb1 1 0 1024 0 1 0 2048 0",
            "8 32 sdc 1 0 256 0 1 0 512 0",
            "9 0 md0 1 0 1024 0 1 0 2048 0",
            "259 0 md0p1 1 0 1024 0 1 0 2048 0",
            "253 0 dm-0 1 0 1024 0 1 0 2048 0",
            "252 0 zram0 1 0 9999999 0 1 0 9999999 0",
            "__PD_DISK_TOPOLOGY__",
            "disk sda",
            "partition sda sda1",
            "disk sdb",
            "partition sdb sdb1",
            "disk sdc",
            "disk md0",
            "partition md0 md0p1",
            "slave md0 sda1",
            "slave md0 sdb1",
            "disk dm-0",
            "slave dm-0 md0p1",
            "disk zram0",
            "complete",
            "__PD_DF__",
        ];
        let sample = parse_disk_io(&lines).unwrap();
        // RAID replication is real physical I/O; md/dm are not extra disks.
        assert_eq!(sample.read_bytes, 2304 * 512);
        assert_eq!(sample.write_bytes, 4608 * 512);
    }

    #[test]
    fn disk_io_keeps_virtual_disks_when_backing_counters_are_hidden() {
        let lines = [
            "__PD_DISKSTATS__",
            "8 0 sda 1 0 500 0 1 0 1000 0",
            "253 0 dm-0 1 0 100 0 1 0 200 0",
            "253 1 dm-1 1 0 100 0 1 0 200 0",
            "__PD_DISK_TOPOLOGY__",
            "disk sda",
            "disk dm-0",
            "slave dm-0 hidden-device",
            "disk dm-1",
            "slave dm-1 dm-0",
            "complete",
            "__PD_DF__",
        ];
        let sample = parse_disk_io(&lines).unwrap();
        assert_eq!(sample.read_bytes, 600 * 512);
        assert_eq!(sample.write_bytes, 1200 * 512);
    }

    #[test]
    fn disk_io_sysfs_excludes_nonstandard_partition_names() {
        let lines = [
            "__PD_DISKSTATS__",
            "104 0 cciss!c0d0 1 0 100 0 1 0 200 0",
            "104 1 cciss!c0d0p1 1 0 100 0 1 0 200 0",
            "253 0 dm-0 1 0 100 0 1 0 200 0",
            "__PD_DISK_TOPOLOGY__",
            "disk cciss!c0d0",
            "partition cciss!c0d0 cciss!c0d0p1",
            "disk dm-0",
            "slave dm-0 cciss!c0d0p1",
            "complete",
            "__PD_DF__",
        ];
        assert_eq!(parse_disk_io(&lines).unwrap().read_bytes, 100 * 512);
    }

    #[test]
    fn disk_io_legacy_and_incomplete_topology_do_not_add_md_and_dm_layers() {
        for topology in [vec![], vec!["__PD_DISK_TOPOLOGY__", "disk dm-0"]] {
            let mut lines = vec![
                "__PD_DISKSTATS__",
                "9 0 md0 1 0 100 0 1 0 200 0",
                "259 0 md0p1 1 0 100 0 1 0 200 0",
                "253 0 dm-0 1 0 100 0 1 0 200 0",
            ];
            lines.extend(topology);
            lines.push("__PD_DF__");
            assert_eq!(parse_disk_io(&lines).unwrap().read_bytes, 100 * 512);
        }
        let only_mapper = [
            "__PD_DISKSTATS__",
            "253 0 dm-0 1 0 100 0 1 0 200 0",
            "__PD_DF__",
        ];
        assert_eq!(parse_disk_io(&only_mapper).unwrap().read_bytes, 100 * 512);
        assert!(parse_disk_io(&[
            "__PD_DISKSTATS__",
            "252 0 zram0 1 0 100 0 1 0 200 0",
            "__PD_DF__"
        ])
        .is_none());
    }

    #[test]
    fn keeps_zfs_root_and_datasets_alongside_efi_and_filters_remote_and_pseudo_mounts() {
        let lines = [
            "__PD_DF__",
            "Filesystem Type 1B-blocks Used Available Use% Mounted on",
            "rpool/ROOT/default zfs 100000 40000 60000 40% /",
            "rpool/home zfs 100000 20000 80000 20% /home",
            "/dev/nvme0n1p1 vfat 1000 100 900 10% /boot/efi",
            "tmpfs tmpfs 1000 100 900 10% /run",
            "pool/srv nfs4 1000 100 900 10% /remote",
            "//nas/srv cifs 1000 100 900 10% /backup",
            "overlay overlay 1000 100 900 10% /var/lib/docker/merged",
            "__PD_MOUNTS__",
        ];
        let disks = parse_disks(&lines).unwrap();
        assert_eq!(
            disks
                .iter()
                .map(|disk| disk.mount_path.as_str())
                .collect::<Vec<_>>(),
            vec!["/", "/home", "/boot/efi"]
        );
        assert_eq!(disks[0].used_bytes, 40000);
        assert_eq!(disks[1].total_bytes, 100000);
    }

    #[test]
    fn keeps_zfs_datasets_with_legacy_df_and_mount_type_lookup() {
        let lines = [
            "__PD_DF__",
            "Filesystem 1K-blocks Used Available Use% Mounted on",
            "pool/root 100000 40000 60000 40% /",
            "pool/home 100000 20000 80000 20% /home",
            "/dev/sda1 1000 100 900 10% /boot/efi",
            "server:/srv 1000 100 900 10% /remote",
            "//nas/srv 1000 100 900 10% /backup",
            "tmpfs 1000 100 900 10% /run",
            "__PD_MOUNTS__",
            "pool/root / zfs rw 0 0",
            "pool/home /home zfs rw 0 0",
            "/dev/sda1 /boot/efi vfat rw 0 0",
            "tmpfs /run tmpfs rw 0 0",
        ];
        let disks = parse_disks(&lines).unwrap();
        assert_eq!(
            disks
                .iter()
                .map(|disk| disk.mount_path.as_str())
                .collect::<Vec<_>>(),
            vec!["/", "/home", "/boot/efi"]
        );
        assert_eq!(disks[1].used_bytes, 20000 * 1024);
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
    fn preserves_literal_network_at_names_from_proc_net_dev() {
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
            ["eth0@if7", "vethabcd@if42"]
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
            ["ens18", "virbr0", "tun0@if5"]
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
    fn parses_optional_inventory_sections_without_affecting_core_metrics() {
        let output = "\
__PD_CPU__ cpu  10 0 0 90 0 0 0 0 0 0
__PD_MEM__
MemTotal: 1024 kB
MemAvailable: 512 kB
__PD_NET__
eth0: 1 0 0 0 0 0 0 0 2 0 0 0 0 0 0 0
__PD_DF__
Filesystem 1B-blocks Used Available Use% Mounted on
/dev/sda1 1024 512 512 50% /
__PD_MOUNTS__
/dev/sda1 / ext4 rw 0 0
__PD_PROCESSES_CPU__
  12 worker 9.5 1.2
  13 shell 1.0 4.5
__PD_PROCESSES_MEMORY__
  13 shell 1.0 4.5
  12 worker 9.5 1.2
__PD_PROCESSES_NETWORK__
/usr/sbin/sshd/12/0 0.5 1.25
/opt/vendor/collector/99/1000 2.0 0.0
__PD_PORTS__
tcp LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:((\"sshd\",pid=12,fd=3))
__PD_SERVICES__
sshd.service loaded active running OpenSSH server
__PD_CONTAINERS__
abc123\tweb\tnginx:latest\tUp 2 hours
";
        let snapshot = parse_device_metrics_probe(output, 1_000).expect("snapshot");
        assert_eq!(snapshot.processes.len(), 3);
        assert_eq!(snapshot.processes[0].pid, 12);
        assert_eq!(snapshot.processes[0].cpu_percent_basis_points, 950);
        assert_eq!(snapshot.processes[0].network_bytes_per_second, 1_792);
        assert_eq!(
            snapshot
                .processes
                .iter()
                .find(|process| process.pid == 99)
                .map(|process| process.network_bytes_per_second),
            Some(2_048)
        );
        assert_eq!(snapshot.ports.len(), 1);
        assert_eq!(snapshot.ports[0].protocol, "TCP");
        assert_eq!(snapshot.ports[0].address, "0.0.0.0:22");
        assert_eq!(snapshot.services[0].name, "sshd.service");
        assert_eq!(snapshot.containers[0].name, "web");
        assert!(snapshot.containers[0].running);
    }

    #[test]
    fn parses_netstat_port_layout_using_local_endpoint_column() {
        let output = "\
__PD_CPU__ cpu  10 0 0 90 0 0 0 0 0 0
__PD_MEM__
MemTotal: 1024 kB
MemAvailable: 512 kB
__PD_NET__
eth0: 1 0 0 0 0 0 0 0 2 0 0 0 0 0 0 0
__PD_DF__
Filesystem 1B-blocks Used Available Use% Mounted on
/dev/sda1 1024 512 512 50% /
__PD_PORTS__
Proto Recv-Q Send-Q Local Address Foreign Address State PID/Program name
tcp 0 0 0.0.0.0:23 0.0.0.0:* LISTEN 12/telnetd
__PD_SERVICES__
__PD_CONTAINERS__
";
        let snapshot = parse_device_metrics_probe(output, 1_000).expect("snapshot");
        assert_eq!(snapshot.ports.len(), 1);
        assert_eq!(snapshot.ports[0].address, "0.0.0.0:23");
        assert_eq!(snapshot.ports[0].process, "12/telnetd");
    }

    #[test]
    fn parses_nethogs_pid_after_numeric_path_segments() {
        assert_eq!(
            parse_nethogs_process("/opt/123/bin/collector/99/1000"),
            ("collector", Some(99))
        );
        assert_eq!(
            parse_nethogs_process("/usr/sbin/sshd/412/0"),
            ("sshd", Some(412))
        );
        assert_eq!(parse_nethogs_process("unknown TCP/0/0").1, None);
        assert_eq!(parse_nethogs_process("/opt/123/bin/collector").1, None);
    }

    #[test]
    fn process_rss_schema_preserves_names_and_combines_leader_samples() {
        let lines = [
            "__PD_PROCESSES_CPU__",
            "__PD_PROCESS_COLUMNS_PID_CPU_MEM_RSS_COMMAND__",
            "12 216.5 0.0 1500 worker 1 main",
            "13 0.1 2.5 0 zombie",
            "__PD_PROCESSES_MEMORY__",
            "__PD_PROCESS_COLUMNS_PID_CPU_MEM_RSS_COMMAND__",
            "12 220.0 0.1 1600 worker 1 main",
            "14 0.2 12.1 1234567 123 numeric name",
            "__PD_PROCESSES_NETWORK__",
            "/opt/worker/12/0 0.5 1.25",
            "/opt/netonly/15/0 1.0 0.0",
            "__PD_PORTS__",
        ];
        let processes = parse_processes(&lines);
        let find = |pid| processes.iter().find(|process| process.pid == pid).unwrap();
        assert_eq!(find(12).name, "worker 1 main");
        assert_eq!(find(12).resident_bytes, Some(1600 * 1024));
        assert_eq!(find(12).cpu_percent_basis_points, 22000);
        assert_eq!(find(12).memory_percent_basis_points, 10);
        assert_eq!(find(12).network_bytes_per_second, 1792);
        assert_eq!(find(13).resident_bytes, Some(0));
        assert_eq!(find(13).memory_percent_basis_points, 250);
        assert_eq!(find(14).resident_bytes, Some(1234567 * 1024));
        assert_eq!(find(14).name, "123 numeric name");
        assert_eq!(find(15).resident_bytes, None);
    }

    #[test]
    fn process_rss_unknown_values_do_not_fabricate_bytes_or_drop_processes() {
        let lines = [
            "__PD_PROCESSES_CPU__",
            "12 old 1.0 0.0",
            "__PD_PROCESSES_MEMORY__",
            "__PD_PROCESS_COLUMNS_PID_CPU_MEM_RSS_COMMAND__",
            "13 0.1 0.1 -1 negative",
            "14 0.1 0.1 18446744073709551615 overflow",
            "15 0.1 0.1 n/a missing",
            "16 0.1 0.1 1.5 fractional",
            "17 0.1 0.1",
            "__PD_PROCESSES_NETWORK__",
            "__PD_PORTS__",
        ];
        let processes = parse_processes(&lines);
        assert_eq!(processes.len(), 5);
        assert!(processes.iter().all(|process| process.resident_bytes.is_none()));
        assert_eq!(processes[0].pid, 12);
    }

    #[test]
    fn probe_collects_all_process_counters_without_lifetime_cpu_or_per_pid_commands() {
        let command = build_device_metrics_probe_command();
        assert_eq!(command.matches("ps -eo pid=,%cpu=,%mem=,rss=,comm=").count(), 1);
        assert!(command.contains("--sort=-rss"));
        assert!(!command.contains("--sort=-%cpu"));
        assert_eq!(command.matches("head -n 10").count(), 1);
        assert!(command.contains("/proc/[0-9]*/stat"));
        assert!(command.contains("getconf PAGESIZE"));
        assert!(command.find("__PD_PROCESS_COUNTERS__").unwrap() < command.find("__PD_MEM__").unwrap());
        assert!(!command.contains("/status"));
    }

    #[test]
    fn process_counters_preserve_all_pids_and_actual_rss() {
        let mut lines = vec!["__PD_PROCESS_COUNTERS__".to_owned(), "page_size=65536".to_owned()];
        for pid in 1..=80 {
            lines.push(format!("{pid} 50 70 100 2 worker {pid} (main)"));
        }
        lines.extend(["__PD_MEM__", "MemTotal: 1024 kB", "MemAvailable: 512 kB", "__PD_NET__"].map(str::to_owned));
        let borrowed = lines.iter().map(String::as_str).collect::<Vec<_>>();
        let processes = parse_processes(&borrowed);
        assert_eq!(processes.len(), 80);
        assert!(processes.iter().all(|p| p.cpu_time_ticks == Some(120) && p.start_time_ticks == Some(100)));
        assert!(processes.iter().all(|p| p.resident_bytes == Some(131072) && p.memory_percent_basis_points == 1250));
        assert!(processes.iter().all(|p| p.cpu_percent_basis_points == 0));
        assert_eq!(processes[79].name, "worker 80 (main)");
    }

    #[test]
    fn process_counter_invalid_and_unavailable_data_does_not_fabricate_usage() {
        let lines = [
            "__PD_PROCESS_COUNTERS__", "page_size=4096",
            "10 0 0 0 0 kernel", "11 1 2 40 -1 worker",
            "12 18446744073709551615 1 41 18446744073709551615 overflow",
            "13 invalid 2 44 10 malformed", "0 1 2 44 0 invalid-pid",
            "__PD_MEM__", "MemTotal: 1024 kB", "MemAvailable: 512 kB", "__PD_NET__",
        ];
        let processes = parse_processes(&lines);
        assert_eq!(processes.len(), 3);
        assert_eq!(processes[0].cpu_time_ticks, Some(0));
        assert_eq!(processes[0].start_time_ticks, Some(0));
        assert_eq!(processes[0].resident_bytes, Some(0));
        assert_eq!(processes[1].resident_bytes, None);
        assert_eq!(processes[2].cpu_time_ticks, None);
        assert_eq!(processes[2].resident_bytes, None);
        assert!(processes.iter().all(|p| p.cpu_percent_basis_points == 0));
    }

    #[test]
    fn unknown_page_size_preserves_ps_rss_without_using_lifetime_cpu() {
        let lines = [
            "__PD_PROCESS_COUNTERS__", "page_size=", "10 30 40 50 100 worker",
            "11 20 40 60 200 another", "__PD_MEM__", "MemTotal: 1024 kB", "__PD_NET__",
            "__PD_PROCESSES_MEMORY__", "__PD_PROCESS_COLUMNS_PID_CPU_MEM_RSS_COMMAND__",
            "10 600.0 10.0 100 worker", "12 900.0 20.0 200 new-worker", "__PD_PROCESSES_NETWORK__",
        ];
        let processes = parse_processes(&lines);
        let process = |pid| processes.iter().find(|p| p.pid == pid).unwrap();
        assert_eq!(process(10).resident_bytes, Some(102400));
        assert_eq!(process(10).cpu_time_ticks, Some(70));
        assert_eq!(process(11).resident_bytes, None);
        assert_eq!(process(12).cpu_time_ticks, None);
        assert!(processes.iter().all(|p| p.cpu_percent_basis_points == 0));
    }

    #[test]
    fn proc_stat_probe_handles_parentheses_newlines_and_disappearing_pids() {
        let directory = tempfile::tempdir().unwrap();
        let mut paths = Vec::new();
        for (pid, name) in [(1, "worker main) (io)"), (2, "line\nbreak\tprocess"), (3, "normal")] {
            let path = directory.path().join(format!("{pid}.stat"));
            let mut fields = vec!["0"; 50];
            fields[0] = "R";
            fields[11] = "120";
            fields[12] = "30";
            fields[19] = "4100";
            fields[21] = "128";
            std::fs::write(&path, format!("{pid} ({name}) {}\n", fields.join(" "))).unwrap();
            paths.push(format!("'{}'", path.display()));
        }
        paths.insert(1, format!("'{}'", directory.path().join("vanished.stat").display()));
        let command = build_device_metrics_probe_command();
        let start = command.find("awk 'BEGIN { for").unwrap();
        let end = command[start..].find(" /proc/[0-9]*/stat").unwrap() + start;
        let output = std::process::Command::new("sh").arg("-c")
            .arg(format!("{} {}", &command[start..end], paths.join(" "))).output().unwrap();
        assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
        let stdout = String::from_utf8(output.stdout).unwrap();
        assert_eq!(stdout.lines().count(), 3);
        assert!(stdout.contains("1 120 30 4100 128 worker main) (io)\n"));
        assert!(stdout.contains("2 120 30 4100 128 line break process\n"));
        assert!(stdout.contains("3 120 30 4100 128 normal\n"));
    }

    #[test]
    fn attributes_network_samples_to_pid_even_when_process_names_match() {
        let lines = [
            "__PD_PROCESSES_CPU__",
            "12 worker 9.5 1.2",
            "13 worker 1.0 4.5",
            "__PD_PROCESSES_MEMORY__",
            "__PD_PROCESSES_NETWORK__",
            "/usr/bin/worker/13/0 0.5 1.25",
            "/opt/123/bin/worker/99/0 2.0 0.0",
            "/opt/collector/100/1000 3.0 0.0",
            "__PD_PORTS__",
        ];
        let processes = parse_processes(&lines);
        assert_eq!(processes.len(), 4);
        let rates = processes
            .iter()
            .map(|process| (process.pid, process.network_bytes_per_second))
            .collect::<std::collections::BTreeMap<_, _>>();
        assert_eq!(rates.get(&12), Some(&0));
        assert_eq!(rates.get(&13), Some(&1792));
        assert_eq!(rates.get(&99), Some(&2048));
        assert_eq!(rates.get(&100), Some(&3072));
        assert_eq!(
            processes
                .iter()
                .find(|process| process.pid == 99)
                .unwrap()
                .name,
            "worker"
        );
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
            ["ens160", "br-9f2", "vethabc@if4"]
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
