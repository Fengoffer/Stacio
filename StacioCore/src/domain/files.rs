#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Enum)]
pub enum RemoteFileKind {
    File,
    Directory,
    Symlink,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct RemoteFileEntry {
    pub kind: RemoteFileKind,
    pub path: String,
    pub size: u64,
    pub modified_time: Option<String>,
    pub link_target: Option<String>,
    pub owner: Option<String>,
    pub permissions: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum FilesError {
    #[error("invalid listing row")]
    InvalidListingRow,
    #[error("invalid remote file kind")]
    InvalidFileKind,
    #[error("invalid file size")]
    InvalidFileSize,
    #[error("unsafe remote path")]
    UnsafePath,
}

pub fn parse_remote_listing(input: &str) -> Result<Vec<RemoteFileEntry>, FilesError> {
    input
        .lines()
        .filter(|line| !line.trim().is_empty())
        .map(parse_remote_listing_line)
        .collect()
}

pub fn parse_ftp_list_listing(
    base_path: &str,
    input: &str,
) -> Result<Vec<RemoteFileEntry>, FilesError> {
    validate_remote_path(base_path)?;
    input
        .lines()
        .filter(|line| {
            let trimmed = line.trim();
            !trimmed.is_empty() && trimmed != "." && trimmed != ".."
        })
        .map(|line| parse_ftp_list_line(base_path, line))
        .collect()
}

fn parse_remote_listing_line(line: &str) -> Result<RemoteFileEntry, FilesError> {
    let parts = line.split('\t').collect::<Vec<_>>();
    if parts.len() < 3 {
        return Err(FilesError::InvalidListingRow);
    }

    let kind = match parts[0] {
        "file" => RemoteFileKind::File,
        "dir" => RemoteFileKind::Directory,
        "symlink" => RemoteFileKind::Symlink,
        _ => return Err(FilesError::InvalidFileKind),
    };
    let path = parts[1].trim();
    validate_remote_path(path)?;
    let size = parts[2]
        .parse::<u64>()
        .map_err(|_| FilesError::InvalidFileSize)?;
    let (modified_time, link_target, owner, permissions) = match parts.len() {
        3 => (None, None, None, None),
        4 if matches!(kind, RemoteFileKind::Symlink) => {
            (None, optional_listing_value(parts[3]), None, None)
        }
        4 => (optional_listing_value(parts[3]), None, None, None),
        5 => (
            optional_listing_value(parts[3]),
            optional_listing_value(parts[4]),
            None,
            None,
        ),
        6 => (
            optional_listing_value(parts[3]),
            optional_listing_value(parts[4]),
            optional_listing_value(parts[5]),
            None,
        ),
        _ => (
            optional_listing_value(parts[3]),
            optional_listing_value(parts[4]),
            optional_listing_value(parts[5]),
            optional_listing_value(parts[6]),
        ),
    };

    Ok(RemoteFileEntry {
        kind,
        path: path.to_string(),
        size,
        modified_time,
        link_target,
        owner,
        permissions,
    })
}

fn optional_listing_value(value: &str) -> Option<String> {
    let trimmed = value.trim();
    if trimmed.is_empty() || trimmed == "-" {
        None
    } else {
        Some(trimmed.to_string())
    }
}

fn validate_remote_path(path: &str) -> Result<(), FilesError> {
    let trimmed = path.trim();
    if trimmed.is_empty()
        || trimmed.chars().any(char::is_control)
        || trimmed.contains("../")
        || trimmed == ".."
        || trimmed.starts_with("../")
        || trimmed.ends_with("/..")
    {
        return Err(FilesError::UnsafePath);
    }
    Ok(())
}

fn parse_ftp_list_line(base_path: &str, line: &str) -> Result<RemoteFileEntry, FilesError> {
    let parts = line.split_whitespace().collect::<Vec<_>>();
    if parts.len() < 9 {
        return Err(FilesError::InvalidListingRow);
    }
    let permissions = parts[0];
    let kind = match permissions.chars().next() {
        Some('d') => RemoteFileKind::Directory,
        Some('l') => RemoteFileKind::Symlink,
        Some('-') => RemoteFileKind::File,
        _ => return Err(FilesError::InvalidFileKind),
    };
    let size = parts[4]
        .parse::<u64>()
        .map_err(|_| FilesError::InvalidFileSize)?;
    let modified_time = Some(format!("{} {} {}", parts[5], parts[6], parts[7]));
    let name_and_link = parts[8..].join(" ");
    let (name, link_target) = match kind {
        RemoteFileKind::Symlink => match name_and_link.split_once(" -> ") {
            Some((name, target)) => (name.trim(), Some(target.trim().to_string())),
            None => (name_and_link.trim(), None),
        },
        _ => (name_and_link.trim(), None),
    };
    if name.is_empty() || name == "." || name == ".." || name.contains('/') || name.contains("../")
    {
        return Err(FilesError::UnsafePath);
    }
    let path = join_remote_path(base_path, name);
    validate_remote_path(&path)?;

    Ok(RemoteFileEntry {
        kind,
        path,
        size,
        modified_time,
        link_target,
        owner: optional_listing_value(parts[2]),
        permissions: optional_listing_value(permissions),
    })
}

fn join_remote_path(base_path: &str, name: &str) -> String {
    let base = base_path.trim();
    if base == "/" {
        return format!("/{name}");
    }
    if base == "~" {
        return format!("~/{name}");
    }
    format!("{}/{}", base.trim_end_matches('/'), name)
}

#[cfg(test)]
mod remote_file_tests {
    use super::{parse_ftp_list_listing, parse_remote_listing, FilesError, RemoteFileKind};

    #[test]
    fn parses_exec_listing_rows() {
        let listing = "\
file\t/etc/hosts\t128\t06-02 20:25
dir\t/var/log\t0\t06-02 20:26
symlink\t/usr/bin/python\t9\t06-02 20:27\t/usr/bin/python3
";

        let entries = parse_remote_listing(listing).expect("parse listing");

        assert_eq!(entries.len(), 3);
        assert_eq!(entries[0].kind, RemoteFileKind::File);
        assert_eq!(entries[0].path, "/etc/hosts");
        assert_eq!(entries[0].size, 128);
        assert_eq!(entries[0].modified_time.as_deref(), Some("06-02 20:25"));
        assert_eq!(entries[0].owner, None);
        assert_eq!(entries[0].permissions, None);
        assert_eq!(entries[1].kind, RemoteFileKind::Directory);
        assert_eq!(entries[1].modified_time.as_deref(), Some("06-02 20:26"));
        assert_eq!(entries[2].kind, RemoteFileKind::Symlink);
        assert_eq!(entries[2].modified_time.as_deref(), Some("06-02 20:27"));
        assert_eq!(entries[2].link_target, Some("/usr/bin/python3".to_string()));
    }

    #[test]
    fn parses_exec_listing_owner_and_permissions_when_present() {
        let listing = "\
file\t/etc/hosts\t128\t06-02 20:25\t-\troot\t-rw-r--r--
dir\t/var/log\t0\t06-02 20:26\t-\troot\tdrwxr-xr-x
symlink\t/usr/bin/python\t9\t06-02 20:27\t/usr/bin/python3\troot\tlrwxrwxrwx
";

        let entries = parse_remote_listing(listing).expect("parse listing");

        assert_eq!(entries[0].owner.as_deref(), Some("root"));
        assert_eq!(entries[0].permissions.as_deref(), Some("-rw-r--r--"));
        assert_eq!(entries[1].owner.as_deref(), Some("root"));
        assert_eq!(entries[1].permissions.as_deref(), Some("drwxr-xr-x"));
        assert_eq!(entries[2].link_target.as_deref(), Some("/usr/bin/python3"));
        assert_eq!(entries[2].owner.as_deref(), Some("root"));
        assert_eq!(entries[2].permissions.as_deref(), Some("lrwxrwxrwx"));
    }

    #[test]
    fn rejects_unsafe_relative_parent_paths() {
        let error = parse_remote_listing("file\t../etc/passwd\t1").expect_err("reject unsafe");

        assert_eq!(error, FilesError::UnsafePath);
    }

    #[test]
    fn rejects_parent_directory_segments_at_path_end() {
        let error = parse_remote_listing("file\t/srv/app/..\t1").expect_err("reject unsafe");

        assert_eq!(error, FilesError::UnsafePath);
    }

    #[test]
    fn rejects_control_characters_in_exec_listing_paths() {
        for path in ["/srv/app/\u{1b}[31m.log", "/srv/app/bad\0name.log"] {
            let listing = format!("file\t{path}\t1");
            let error = parse_remote_listing(&listing).expect_err("reject unsafe");

            assert_eq!(error, FilesError::UnsafePath, "path: {path:?}");
        }
    }

    #[test]
    fn parses_ftp_list_rows_into_remote_entries() {
        let listing = "\
drwxr-xr-x  2 deploy staff       0 Jan 01 12:00 releases
-rw-r--r--  1 deploy staff     128 Jan 01 12:00 app.log
lrwxrwxrwx  1 deploy staff       8 Jan 01 12:00 current -> releases
";

        let entries = parse_ftp_list_listing("/", listing).expect("parse ftp list");

        assert_eq!(entries.len(), 3);
        assert_eq!(entries[0].kind, RemoteFileKind::Directory);
        assert_eq!(entries[0].path, "/releases");
        assert_eq!(entries[1].kind, RemoteFileKind::File);
        assert_eq!(entries[1].path, "/app.log");
        assert_eq!(entries[1].size, 128);
        assert_eq!(entries[1].modified_time.as_deref(), Some("Jan 01 12:00"));
        assert_eq!(entries[1].owner.as_deref(), Some("deploy"));
        assert_eq!(entries[1].permissions.as_deref(), Some("-rw-r--r--"));
        assert_eq!(entries[2].kind, RemoteFileKind::Symlink);
        assert_eq!(entries[2].modified_time.as_deref(), Some("Jan 01 12:00"));
        assert_eq!(entries[2].link_target, Some("releases".to_string()));
    }

    #[test]
    fn rejects_unsafe_ftp_listing_base_path() {
        let error =
            parse_ftp_list_listing("../etc", "-rw-r--r-- 1 root wheel 1 Jan 01 12:00 passwd")
                .expect_err("reject unsafe ftp path");

        assert_eq!(error, FilesError::UnsafePath);
    }

    #[test]
    fn rejects_control_characters_in_ftp_listing_names() {
        let listing = "-rw-r--r-- 1 root wheel 1 Jan 01 12:00 bad\u{1b}[31m.log";

        let error = parse_ftp_list_listing("/tmp", listing).expect_err("reject unsafe ftp path");

        assert_eq!(error, FilesError::UnsafePath);
    }
}
