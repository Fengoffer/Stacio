use crate::domain::ssh::RemoteOperatingSystemInfo;
use std::collections::HashMap;

const OS_RELEASE_MARKER: &str = "__PD_OS_RELEASE__";
const FALLBACK_MARKER: &str = "__PD_OS_FALLBACK__";
const UNAME_MARKER: &str = "__PD_UNAME__";
const OS_PROBE_PARSE_FAILED: &str = "OS_PROBE_PARSE_FAILED";

pub fn build_remote_os_probe_command() -> String {
    [
        "export LC_ALL=C",
        "export LANG=C",
        "pd_read_file() { if command -v cat >/dev/null 2>&1; then cat \"$1\" 2>/dev/null; else while IFS= read -r pd_line; do printf '%s\\n' \"$pd_line\"; done < \"$1\" 2>/dev/null; fi; }",
        "printf '__PD_OS_RELEASE__\\n'",
        "if [ -r /etc/os-release ]; then pd_read_file /etc/os-release; elif [ -r /usr/lib/os-release ]; then pd_read_file /usr/lib/os-release; fi",
        "printf '__PD_OS_FALLBACK__\\n'",
        "for pd_file in /etc/redhat-release /etc/centos-release /etc/rocky-release /etc/almalinux-release /etc/oracle-release /etc/system-release /etc/SuSE-release /etc/debian_version /etc/alpine-release /etc/openEuler-release /etc/anolis-release /etc/kylin-release /etc/uos-release /etc/lsb-release; do if [ -r \"$pd_file\" ]; then printf '%s=' \"$pd_file\"; pd_read_file \"$pd_file\" | head -n 1; fi; done",
        "printf '__PD_UNAME__\\n'",
        "printf 'kernel_name='; (uname -s 2>/dev/null || true)",
        "printf 'kernel_release='; (uname -r 2>/dev/null || true)",
        "printf 'architecture='; (uname -m 2>/dev/null || true)",
    ]
    .join("; ")
}

pub fn parse_remote_os_probe(output: &str) -> Result<RemoteOperatingSystemInfo, String> {
    let lines = output.lines().collect::<Vec<_>>();
    let release = parse_key_value_section(&section_after_until(
        &lines,
        OS_RELEASE_MARKER,
        Some(FALLBACK_MARKER),
    ));
    let fallback = section_after_until(&lines, FALLBACK_MARKER, Some(UNAME_MARKER));
    let uname = parse_key_value_section(&section_after_until(&lines, UNAME_MARKER, None));

    let fallback_text = fallback
        .iter()
        .filter_map(|line| line.split_once('=').map(|(_, value)| value.trim()))
        .find(|value| !value.is_empty())
        .unwrap_or_default()
        .to_string();

    let mut id = release
        .get("ID")
        .cloned()
        .unwrap_or_else(|| fallback_id(&fallback, &fallback_text));
    let mut name = release
        .get("NAME")
        .cloned()
        .unwrap_or_else(|| fallback_name(&id, &fallback_text));
    let mut pretty_name = release
        .get("PRETTY_NAME")
        .cloned()
        .unwrap_or_else(|| fallback_pretty_name(&name, &fallback_text));
    let version = release
        .get("VERSION")
        .cloned()
        .unwrap_or_else(|| fallback_version(&fallback_text));
    let version_id = release
        .get("VERSION_ID")
        .cloned()
        .unwrap_or_else(|| fallback_version_id(&version, &fallback_text));
    let id_like = release
        .get("ID_LIKE")
        .map(|value| {
            value
                .split_whitespace()
                .map(normalize_token)
                .filter(|value| !value.is_empty())
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    let kernel_name = uname.get("kernel_name").cloned().unwrap_or_default();
    let kernel_release = uname.get("kernel_release").cloned().unwrap_or_default();
    let architecture = uname.get("architecture").cloned().unwrap_or_default();

    if id.is_empty() {
        id = fallback_kernel_id(&kernel_name);
    }
    if name.is_empty() {
        name = id.clone();
    }
    if pretty_name.is_empty() {
        pretty_name = name.clone();
    }

    if id.is_empty() && kernel_name.is_empty() {
        return Err(OS_PROBE_PARSE_FAILED.to_string());
    }

    Ok(RemoteOperatingSystemInfo {
        id,
        id_like,
        name,
        pretty_name,
        version,
        version_id,
        kernel_name,
        kernel_release,
        architecture,
    })
}

fn parse_key_value_section(lines: &[&str]) -> HashMap<String, String> {
    lines
        .iter()
        .filter_map(|line| parse_key_value(line))
        .collect()
}

fn parse_key_value(line: &str) -> Option<(String, String)> {
    let trimmed = line.trim();
    if trimmed.is_empty() || trimmed.starts_with('#') {
        return None;
    }
    let (key, raw_value) = trimmed.split_once('=')?;
    let key = key.trim();
    if key.is_empty() {
        return None;
    }
    Some((key.to_string(), unquote_os_release_value(raw_value.trim())))
}

fn unquote_os_release_value(value: &str) -> String {
    let trimmed = value.trim();
    if trimmed.len() >= 2 {
        let first = trimmed.as_bytes()[0] as char;
        let last = trimmed.as_bytes()[trimmed.len() - 1] as char;
        if (first == '"' && last == '"') || (first == '\'' && last == '\'') {
            return trimmed[1..trimmed.len() - 1]
                .replace("\\\"", "\"")
                .replace("\\'", "'")
                .replace("\\\\", "\\");
        }
    }
    trimmed.to_string()
}

fn fallback_id(fallback: &[&str], text: &str) -> String {
    let joined = fallback.join("\n").to_ascii_lowercase();
    let text = text.to_ascii_lowercase();
    let candidates = [
        ("openEuler", "openeuler"),
        ("Anolis", "anolis"),
        ("Kylin", "kylin"),
        ("UOS", "uos"),
        ("AlmaLinux", "almalinux"),
        ("Rocky Linux", "rocky"),
        ("Oracle Linux", "ol"),
        ("CentOS", "centos"),
        ("Red Hat", "rhel"),
        ("Fedora", "fedora"),
        ("SUSE", "opensuse"),
        ("Debian", "debian"),
        ("Alpine", "alpine"),
        ("Amazon Linux", "amzn"),
    ];
    for (needle, id) in candidates {
        if joined.contains(&needle.to_ascii_lowercase())
            || text.contains(&needle.to_ascii_lowercase())
        {
            return id.to_string();
        }
    }
    String::new()
}

fn fallback_name(id: &str, fallback_text: &str) -> String {
    if !fallback_text.is_empty() {
        return fallback_text.to_string();
    }
    match id {
        "amzn" => "Amazon Linux".to_string(),
        "ol" => "Oracle Linux".to_string(),
        "rhel" => "Red Hat Enterprise Linux".to_string(),
        "opensuse" => "SUSE Linux".to_string(),
        "openeuler" => "openEuler".to_string(),
        _ => id.to_string(),
    }
}

fn fallback_pretty_name(name: &str, fallback_text: &str) -> String {
    if !fallback_text.is_empty() {
        fallback_text.to_string()
    } else {
        name.to_string()
    }
}

fn fallback_version(fallback_text: &str) -> String {
    fallback_text
        .split_whitespace()
        .find(|part| part.chars().any(|character| character.is_ascii_digit()))
        .unwrap_or_default()
        .trim_matches(|character: char| character == '"' || character == ',' || character == ';')
        .to_string()
}

fn fallback_version_id(version: &str, fallback_text: &str) -> String {
    if !version.is_empty() {
        return version
            .chars()
            .filter(|character| character.is_ascii_digit() || *character == '.')
            .collect::<String>();
    }
    fallback_text
        .chars()
        .filter(|character| character.is_ascii_digit() || *character == '.')
        .collect::<String>()
}

fn fallback_kernel_id(kernel_name: &str) -> String {
    match kernel_name.to_ascii_lowercase().as_str() {
        "darwin" => "darwin".to_string(),
        "linux" => "linux".to_string(),
        "freebsd" => "freebsd".to_string(),
        value if value.contains("windows") || value.contains("mingw") || value.contains("msys") => {
            "windows".to_string()
        }
        _ => String::new(),
    }
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

fn normalize_token(value: &str) -> String {
    value
        .trim()
        .trim_matches('"')
        .trim_matches('\'')
        .to_ascii_lowercase()
}

#[cfg(test)]
mod tests {
    use super::{build_remote_os_probe_command, parse_remote_os_probe};

    #[test]
    fn builds_probe_without_local_ssh_or_transfer_tools() {
        let command = build_remote_os_probe_command();

        assert!(command.contains("/etc/os-release"));
        assert!(command.contains("/etc/redhat-release"));
        assert!(command.contains("uname -s"));
        assert!(!command.contains("ssh "));
        assert!(!command.contains("sftp "));
        assert!(!command.contains("scp "));
        assert!(!command.contains("rsync "));
    }

    #[test]
    fn parses_ubuntu_os_release_with_uname() {
        let output = "\
__PD_OS_RELEASE__
PRETTY_NAME=\"Ubuntu 22.04.4 LTS\"
NAME=\"Ubuntu\"
VERSION_ID=\"22.04\"
VERSION=\"22.04.4 LTS (Jammy Jellyfish)\"
ID=ubuntu
ID_LIKE=debian
__PD_OS_FALLBACK__
__PD_UNAME__
kernel_name=Linux
kernel_release=5.15.0-91-generic
architecture=x86_64
";

        let info = parse_remote_os_probe(output).expect("os info");

        assert_eq!(info.id, "ubuntu");
        assert_eq!(info.id_like, ["debian"]);
        assert_eq!(info.pretty_name, "Ubuntu 22.04.4 LTS");
        assert_eq!(info.version_id, "22.04");
        assert_eq!(info.kernel_name, "Linux");
        assert_eq!(info.architecture, "x86_64");
    }

    #[test]
    fn parses_centos7_fallback_release() {
        let output = "\
__PD_OS_RELEASE__
__PD_OS_FALLBACK__
/etc/centos-release=CentOS Linux release 7.9.2009 (Core)
__PD_UNAME__
kernel_name=Linux
kernel_release=3.10.0-1160.el7.x86_64
architecture=x86_64
";

        let info = parse_remote_os_probe(output).expect("os info");

        assert_eq!(info.id, "centos");
        assert_eq!(info.name, "CentOS Linux release 7.9.2009 (Core)");
        assert_eq!(info.version_id, "7.9.2009");
        assert_eq!(info.kernel_release, "3.10.0-1160.el7.x86_64");
    }

    #[test]
    fn falls_back_to_kernel_family_when_release_files_are_absent() {
        let output = "\
__PD_OS_RELEASE__
__PD_OS_FALLBACK__
__PD_UNAME__
kernel_name=Darwin
kernel_release=25.0.0
architecture=arm64
";

        let info = parse_remote_os_probe(output).expect("os info");

        assert_eq!(info.id, "darwin");
        assert_eq!(info.pretty_name, "darwin");
    }
}
