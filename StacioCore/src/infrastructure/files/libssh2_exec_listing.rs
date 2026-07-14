use crate::domain::files::{parse_remote_listing, FilesError, RemoteFileEntry};
use crate::infrastructure::ssh::libssh2_transport::{
    with_temporary_blocking, Libssh2ConnectedSession,
};
use std::io::Read;

pub struct Libssh2ExecListing;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RemoteFileOperation {
    MakeDirectory { path: String },
    Rename { from_path: String, to_path: String },
    Delete { path: String, recursive: bool },
    Chmod { path: String, mode: String },
    Copy { from_path: String, to_path: String },
}

impl Libssh2ExecListing {
    pub fn new() -> Self {
        Self
    }

    pub fn build_listing_command(remote_path: &str) -> Result<String, String> {
        validate_remote_path(remote_path)?;
        let quoted = shell_path_argument(remote_path);
        Ok(format!(
            "find {quoted} -maxdepth 1 -mindepth 1 -printf '%y\\t%p\\t%s\\t%Tm-%Td %TH:%TM\\t%l\\t%u\\t%M\\n'"
        ))
    }

    pub fn build_ls_listing_command(remote_path: &str) -> Result<String, String> {
        validate_remote_path(remote_path)?;
        let quoted = shell_path_argument(remote_path);
        Ok(format!("LC_ALL=C ls -la {quoted}"))
    }

    pub fn build_search_command(
        remote_path: &str,
        keyword: &str,
        max_depth: u32,
    ) -> Result<String, String> {
        validate_remote_path(remote_path)?;
        let keyword = validate_search_keyword(keyword)?;
        let max_depth = validate_search_depth(max_depth)?;
        let quoted_directory = shell_path_argument(remote_path);
        let pattern = shell_quote(&format!("*{keyword}*"));
        Ok(format!(
            "cd {quoted_directory} && find . -maxdepth {max_depth} -name {pattern} -printf '%y\\t%p\\t%s\\t%Tm-%Td %TH:%TM\\t%l\\t%u\\t%M\\n'"
        ))
    }

    pub fn build_operation_command(operation: &RemoteFileOperation) -> Result<String, String> {
        match operation {
            RemoteFileOperation::MakeDirectory { path } => {
                validate_remote_path(path)?;
                Ok(format!("mkdir -p {}", shell_path_argument(path)))
            }
            RemoteFileOperation::Rename { from_path, to_path } => {
                validate_remote_path(from_path)?;
                validate_remote_path(to_path)?;
                Ok(format!(
                    "mv {} {}",
                    shell_path_argument(from_path),
                    shell_path_argument(to_path)
                ))
            }
            RemoteFileOperation::Delete { path, recursive } => {
                validate_remote_path(path)?;
                let flag = if *recursive { "-rf" } else { "-f" };
                Ok(format!("rm {flag} {}", shell_path_argument(path)))
            }
            RemoteFileOperation::Chmod { path, mode } => {
                validate_remote_path(path)?;
                validate_mode(mode)?;
                Ok(format!(
                    "chmod {} {}",
                    shell_quote(mode),
                    shell_path_argument(path)
                ))
            }
            RemoteFileOperation::Copy { from_path, to_path } => {
                validate_remote_path(from_path)?;
                validate_remote_path(to_path)?;
                Ok(format!(
                    "cp -p {} {}",
                    shell_path_argument(from_path),
                    shell_path_argument(to_path)
                ))
            }
        }
    }

    pub fn parse_find_listing(output: &str) -> Result<Vec<RemoteFileEntry>, FilesError> {
        let normalized = output
            .lines()
            .map(normalize_find_row)
            .collect::<Result<Vec<_>, _>>()?
            .join("\n");
        parse_remote_listing(&normalized)
    }

    pub fn parse_search_output(
        remote_path: &str,
        output: &str,
    ) -> Result<Vec<RemoteFileEntry>, FilesError> {
        validate_remote_path(remote_path).map_err(|_| FilesError::UnsafePath)?;
        let normalized = output
            .lines()
            .filter(|line| line.trim().is_empty() == false)
            .map(|line| normalize_search_row(remote_path, line))
            .collect::<Result<Vec<_>, _>>()?
            .join("\n");
        parse_remote_listing(&normalized)
    }

    pub fn parse_ls_listing(
        remote_path: &str,
        output: &str,
    ) -> Result<Vec<RemoteFileEntry>, FilesError> {
        validate_remote_path(remote_path).map_err(|_| FilesError::UnsafePath)?;
        output
            .lines()
            .filter_map(|line| normalize_ls_row(remote_path, line))
            .collect()
    }

    pub fn list_directory(
        &self,
        session: &Libssh2ConnectedSession,
        remote_path: &str,
    ) -> Result<Vec<RemoteFileEntry>, String> {
        match Self::run_listing_command(session, &Self::build_listing_command(remote_path)?) {
            Ok(output) => Self::parse_find_listing(&output)
                .map_err(|_| "FILES_REMOTE_LIST_PARSE_FAILED".to_string())
                .or_else(|_| self.list_directory_with_ls(session, remote_path)),
            Err(_) => self.list_directory_with_ls(session, remote_path),
        }
    }

    pub fn search_directory(
        &self,
        session: &Libssh2ConnectedSession,
        remote_path: &str,
        keyword: &str,
        max_depth: u32,
    ) -> Result<Vec<RemoteFileEntry>, String> {
        let command = Self::build_search_command(remote_path, keyword, max_depth)?;
        let output = Self::run_listing_command(session, &command)?;
        Self::parse_search_output(remote_path, &output)
            .map_err(|_| "FILES_REMOTE_SEARCH_PARSE_FAILED".to_string())
    }

    pub fn apply_operation(
        &self,
        session: &Libssh2ConnectedSession,
        operation: &RemoteFileOperation,
    ) -> Result<(), String> {
        let command = Self::build_operation_command(operation)?;
        run_exec_command(session, &command)
    }

    pub fn run_raw_command(
        session: &Libssh2ConnectedSession,
        command: &str,
    ) -> Result<String, String> {
        Self::run_listing_command(session, command)
    }

    fn list_directory_with_ls(
        &self,
        session: &Libssh2ConnectedSession,
        remote_path: &str,
    ) -> Result<Vec<RemoteFileEntry>, String> {
        let command = Self::build_ls_listing_command(remote_path)?;
        let output = Self::run_listing_command(session, &command)?;
        Self::parse_ls_listing(remote_path, &output)
            .map_err(|_| "FILES_REMOTE_LIST_PARSE_FAILED".to_string())
    }

    fn run_listing_command(
        session: &Libssh2ConnectedSession,
        command: &str,
    ) -> Result<String, String> {
        with_temporary_blocking(session.session(), true, || {
            let mut channel = session
                .session()
                .channel_session()
                .map_err(|_| "FILES_REMOTE_COMMAND_FAILED".to_string())?;
            channel
                .exec(command)
                .map_err(|_| "FILES_REMOTE_COMMAND_FAILED".to_string())?;

            let output = read_remote_command_output(&mut channel)?;
            channel
                .wait_close()
                .map_err(|_| "FILES_REMOTE_COMMAND_FAILED".to_string())?;

            let exit_status = channel
                .exit_status()
                .map_err(|_| "FILES_REMOTE_COMMAND_FAILED".to_string())?;
            if exit_status != 0 {
                return Err("FILES_REMOTE_COMMAND_FAILED".to_string());
            }

            Ok(output)
        })
    }
}

fn run_exec_command(session: &Libssh2ConnectedSession, command: &str) -> Result<(), String> {
    with_temporary_blocking(session.session(), true, || {
        let mut channel = session
            .session()
            .channel_session()
            .map_err(|_| "FILES_REMOTE_COMMAND_FAILED".to_string())?;
        channel
            .exec(command)
            .map_err(|_| "FILES_REMOTE_COMMAND_FAILED".to_string())?;

        let _output = read_remote_command_output(&mut channel)?;
        channel
            .wait_close()
            .map_err(|_| "FILES_REMOTE_COMMAND_FAILED".to_string())?;

        let exit_status = channel
            .exit_status()
            .map_err(|_| "FILES_REMOTE_COMMAND_FAILED".to_string())?;
        if exit_status != 0 {
            return Err("FILES_REMOTE_COMMAND_FAILED".to_string());
        }

        Ok(())
    })
}

fn read_remote_command_output<R: Read>(reader: &mut R) -> Result<String, String> {
    let mut output = Vec::new();
    reader
        .read_to_end(&mut output)
        .map_err(|_| "FILES_REMOTE_COMMAND_FAILED".to_string())?;
    Ok(decode_remote_command_output(&output))
}

fn decode_remote_command_output(output: &[u8]) -> String {
    String::from_utf8_lossy(output).into_owned()
}

fn normalize_find_row(line: &str) -> Result<String, FilesError> {
    let parts = line.split('\t').collect::<Vec<_>>();
    if parts.len() < 4 {
        return Err(FilesError::InvalidListingRow);
    }
    let kind = match parts[0] {
        "f" => "file",
        "d" => "dir",
        "l" => "symlink",
        _ => return Err(FilesError::InvalidFileKind),
    };
    let modified_time = parts.get(3).copied().unwrap_or("");
    let link_target = parts.get(4).copied().unwrap_or("");
    let owner = parts.get(5).copied().unwrap_or("");
    let permissions = parts.get(6).copied().unwrap_or("");

    if link_target.is_empty() {
        Ok(format!(
            "{kind}\t{}\t{}\t{modified_time}\t-\t{owner}\t{permissions}",
            parts[1], parts[2]
        ))
    } else {
        Ok(format!(
            "{kind}\t{}\t{}\t{modified_time}\t{link_target}\t{owner}\t{permissions}",
            parts[1], parts[2]
        ))
    }
}

fn normalize_search_row(remote_path: &str, line: &str) -> Result<String, FilesError> {
    let parts = line.split('\t').collect::<Vec<_>>();
    if parts.len() < 4 {
        return Err(FilesError::InvalidListingRow);
    }
    let relative_path = normalize_find_relative_path(parts[1])?;
    let full_path = join_relative_remote_path(remote_path, &relative_path);
    let kind = match parts[0] {
        "f" => "file",
        "d" => "dir",
        "l" => "symlink",
        _ => return Err(FilesError::InvalidFileKind),
    };
    let modified_time = parts.get(3).copied().unwrap_or("");
    let link_target = parts.get(4).copied().unwrap_or("");
    let owner = parts.get(5).copied().unwrap_or("");
    let permissions = parts.get(6).copied().unwrap_or("");

    if link_target.is_empty() {
        Ok(format!(
            "{kind}\t{full_path}\t{}\t{modified_time}\t-\t{owner}\t{permissions}",
            parts[2]
        ))
    } else {
        Ok(format!(
            "{kind}\t{full_path}\t{}\t{modified_time}\t{link_target}\t{owner}\t{permissions}",
            parts[2]
        ))
    }
}

fn normalize_find_relative_path(path: &str) -> Result<String, FilesError> {
    let trimmed = path.trim();
    let relative = trimmed.strip_prefix("./").unwrap_or(trimmed);
    if relative.is_empty()
        || relative == "."
        || relative == ".."
        || relative.starts_with('/')
        || relative.starts_with("../")
        || relative.contains("/../")
        || relative.ends_with("/..")
        || relative.split('/').any(|component| {
            component.is_empty()
                || component == "."
                || component == ".."
                || component.contains('\0')
        })
    {
        return Err(FilesError::UnsafePath);
    }
    Ok(relative.to_string())
}

fn normalize_ls_row(remote_path: &str, line: &str) -> Option<Result<RemoteFileEntry, FilesError>> {
    let trimmed = line.trim();
    if trimmed.is_empty() || trimmed.starts_with("total ") {
        return None;
    }

    let parts = trimmed.split_whitespace().collect::<Vec<_>>();
    if parts.len() < 9 {
        return Some(Err(FilesError::InvalidListingRow));
    }

    let kind = match parts[0].chars().next() {
        Some('d') => crate::domain::files::RemoteFileKind::Directory,
        Some('l') => crate::domain::files::RemoteFileKind::Symlink,
        Some('-') => crate::domain::files::RemoteFileKind::File,
        Some('b') | Some('c') | Some('p') | Some('s') => return None,
        _ => return Some(Err(FilesError::InvalidFileKind)),
    };

    let size = match parts[4].parse::<u64>() {
        Ok(size) => size,
        Err(_) => return Some(Err(FilesError::InvalidFileSize)),
    };
    let modified_time = Some(format!("{} {} {}", parts[5], parts[6], parts[7]));

    let name_and_link = parts[8..].join(" ");
    let (name, link_target) = match kind {
        crate::domain::files::RemoteFileKind::Symlink => match name_and_link.split_once(" -> ") {
            Some((name, target)) => (name.trim(), Some(target.trim().to_string())),
            None => (name_and_link.trim(), None),
        },
        _ => (name_and_link.trim(), None),
    };

    if name.is_empty() || name == "." || name == ".." || name.contains('/') || name.contains("../")
    {
        if name == "." || name == ".." {
            return None;
        }
        return Some(Err(FilesError::UnsafePath));
    }

    let path = join_remote_path(remote_path, name);
    Some(Ok(RemoteFileEntry {
        kind,
        path,
        size,
        modified_time,
        link_target,
        owner: Some(parts[2].to_string()),
        permissions: Some(parts[0].to_string()),
    }))
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

fn join_relative_remote_path(base_path: &str, relative_path: &str) -> String {
    let base = base_path.trim();
    if base == "/" {
        return format!("/{}", relative_path.trim_start_matches('/'));
    }
    if base == "~" {
        return format!("~/{}", relative_path.trim_start_matches('/'));
    }
    format!(
        "{}/{}",
        base.trim_end_matches('/'),
        relative_path.trim_start_matches('/')
    )
}

fn validate_remote_path(path: &str) -> Result<(), String> {
    let trimmed = path.trim();
    if trimmed.is_empty()
        || trimmed.chars().any(char::is_control)
        || trimmed.contains("../")
        || trimmed.starts_with("../")
        || trimmed == ".."
        || trimmed.ends_with("/..")
        || trimmed
            .split('/')
            .any(|component| component.starts_with('-'))
    {
        return Err("FILES_UNSAFE_PATH".to_string());
    }

    Ok(())
}

fn validate_search_keyword(keyword: &str) -> Result<String, String> {
    let trimmed = keyword.trim();
    if trimmed.is_empty() || trimmed.chars().any(char::is_control) {
        return Err("FILES_UNSAFE_SEARCH_KEYWORD".to_string());
    }
    Ok(trimmed.to_string())
}

fn validate_search_depth(max_depth: u32) -> Result<u32, String> {
    if (1..=20).contains(&max_depth) {
        Ok(max_depth)
    } else {
        Err("FILES_UNSAFE_SEARCH_DEPTH".to_string())
    }
}

fn validate_mode(mode: &str) -> Result<(), String> {
    let trimmed = mode.trim();
    let valid = trimmed.len() >= 3
        && trimmed.len() <= 4
        && trimmed
            .chars()
            .all(|character| ('0'..='7').contains(&character));
    if valid {
        Ok(())
    } else {
        Err("FILES_UNSAFE_MODE".to_string())
    }
}

fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

fn shell_path_argument(path: &str) -> String {
    let trimmed = path.trim();
    if trimmed == "~" {
        return "~".to_string();
    }
    if let Some(rest) = trimmed.strip_prefix("~/") {
        return format!("~/{}", shell_quote(rest));
    }
    shell_quote(trimmed)
}

#[cfg(test)]
mod libssh2_exec_listing_tests {
    use super::{decode_remote_command_output, Libssh2ExecListing, RemoteFileOperation};

    #[test]
    fn builds_remote_listing_command_without_system_file_transfer_tools() {
        let command = Libssh2ExecListing::build_listing_command("/var/log").expect("command");

        assert!(command.contains("find"));
        assert!(command.contains("%Tm-%Td %TH:%TM"));
        assert!(command.contains("/var/log"));
        assert!(!command.contains("sftp "));
        assert!(!command.contains("scp "));
        assert!(!command.contains("rsync "));
    }

    #[test]
    fn rejects_unsafe_remote_listing_paths() {
        let error = Libssh2ExecListing::build_listing_command("../etc").expect_err("unsafe path");

        assert_eq!(error, "FILES_UNSAFE_PATH");
    }

    #[test]
    fn rejects_parent_directory_segments_at_path_end() {
        let listing_error =
            Libssh2ExecListing::build_listing_command("/srv/app/..").expect_err("unsafe path");
        let operation_error =
            Libssh2ExecListing::build_operation_command(&RemoteFileOperation::Delete {
                path: "/srv/app/..".to_string(),
                recursive: false,
            })
            .expect_err("unsafe operation path");

        assert_eq!(listing_error, "FILES_UNSAFE_PATH");
        assert_eq!(operation_error, "FILES_UNSAFE_PATH");
    }

    #[test]
    fn rejects_control_characters_in_remote_listing_and_operation_paths() {
        let listing_error = Libssh2ExecListing::build_listing_command("/srv/app/\u{1b}[31m.log")
            .expect_err("unsafe listing path");
        let operation_error =
            Libssh2ExecListing::build_operation_command(&RemoteFileOperation::Delete {
                path: "/srv/app/bad\0name.log".to_string(),
                recursive: false,
            })
            .expect_err("unsafe operation path");

        assert_eq!(listing_error, "FILES_UNSAFE_PATH");
        assert_eq!(operation_error, "FILES_UNSAFE_PATH");
    }

    #[test]
    fn parses_find_listing_output_into_remote_entries() {
        let output = "d\t/var/log/nginx\t0\t06-02 20:25\t\nf\t/var/log/syslog\t128\t06-02 20:26\t\nl\t/var/log/current\t7\t06-02 20:27\t/var/log/syslog\n";

        let entries = Libssh2ExecListing::parse_find_listing(output).expect("entries");

        assert_eq!(entries.len(), 3);
        assert_eq!(entries[0].path, "/var/log/nginx");
        assert_eq!(entries[1].size, 128);
        assert_eq!(entries[1].modified_time.as_deref(), Some("06-02 20:26"));
        assert_eq!(entries[1].owner, None);
        assert_eq!(entries[1].permissions, None);
        assert_eq!(entries[2].modified_time.as_deref(), Some("06-02 20:27"));
        assert_eq!(entries[2].link_target, Some("/var/log/syslog".to_string()));
    }

    #[test]
    fn parses_find_listing_owner_and_permissions_into_remote_entries() {
        let output = "\
d\t/var/log/nginx\t0\t06-02 20:25\t\troot\tdrwxr-xr-x
f\t/var/log/syslog\t128\t06-02 20:26\t\troot\t-rw-r--r--
l\t/var/log/current\t7\t06-02 20:27\t/var/log/syslog\troot\tlrwxrwxrwx
";

        let entries = Libssh2ExecListing::parse_find_listing(output).expect("entries");

        assert_eq!(entries[0].owner.as_deref(), Some("root"));
        assert_eq!(entries[0].permissions.as_deref(), Some("drwxr-xr-x"));
        assert_eq!(entries[1].owner.as_deref(), Some("root"));
        assert_eq!(entries[1].permissions.as_deref(), Some("-rw-r--r--"));
        assert_eq!(entries[2].link_target.as_deref(), Some("/var/log/syslog"));
        assert_eq!(entries[2].owner.as_deref(), Some("root"));
        assert_eq!(entries[2].permissions.as_deref(), Some("lrwxrwxrwx"));
    }

    #[test]
    fn builds_remote_search_command_with_quoted_keyword_pattern() {
        let command = Libssh2ExecListing::build_search_command("/srv/app", "release'; rm -rf /", 5)
            .expect("command");

        assert!(command.starts_with("cd '/srv/app' && find . "));
        assert!(command.contains("-maxdepth 5"));
        assert!(command.contains("-name '*release'\\''; rm -rf /*'"));
        assert!(command.contains("-printf '%y\\t%p\\t%s\\t%Tm-%Td %TH:%TM\\t%l\\t%u\\t%M\\n'"));
        assert!(!command.contains("ssh "));
        assert!(!command.contains("scp "));
        assert!(!command.contains("rsync "));
    }

    #[test]
    fn parses_search_find_output_into_entries_under_base_directory() {
        let output =
            "f\t./logs/app.log\t128\t06-02 20:26\t\nf\t./config/logging.yml\t64\t06-02 20:27\t\n";

        let entries = Libssh2ExecListing::parse_search_output("/srv/app", output).expect("entries");

        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].path, "/srv/app/logs/app.log");
        assert_eq!(entries[0].size, 128);
        assert_eq!(entries[0].modified_time.as_deref(), Some("06-02 20:26"));
        assert_eq!(entries[1].path, "/srv/app/config/logging.yml");
    }

    #[test]
    fn decodes_remote_listing_output_lossily_so_invalid_filenames_do_not_block_directory() {
        let mut output = b"f\t/srv/app/valid.log\t12\t06-12 09:00\t\nf\t/srv/app/".to_vec();
        output.extend_from_slice(&[0xff, 0xfe]);
        output.extend_from_slice(b".bin\t4\t06-12 09:01\t\n");

        let decoded = decode_remote_command_output(&output);
        let entries = Libssh2ExecListing::parse_find_listing(&decoded).expect("entries");

        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].path, "/srv/app/valid.log");
        assert!(
            entries[1].path.contains('\u{fffd}'),
            "lossy replacement should keep the rest of the directory visible instead of failing the whole listing"
        );
        assert_eq!(entries[1].size, 4);
    }

    #[test]
    fn builds_ls_listing_fallback_command_without_system_file_transfer_tools() {
        let command = Libssh2ExecListing::build_ls_listing_command("/var/log").expect("command");

        assert!(command.contains("ls -la"));
        assert!(command.contains("/var/log"));
        assert!(
            !command.contains(" -- "),
            "fallback listing should avoid GNU-specific option separators so it keeps working on minimal Linux userlands"
        );
        assert!(!command.contains("sftp "));
        assert!(!command.contains("scp "));
        assert!(!command.contains("rsync "));
        assert!(!command.contains("ssh "));
    }

    #[test]
    fn listing_commands_allow_shell_to_expand_home_directory_alias() {
        let find_command = Libssh2ExecListing::build_listing_command("~").expect("find command");
        let ls_command =
            Libssh2ExecListing::build_ls_listing_command("~/logs").expect("ls command");
        let spaced_command =
            Libssh2ExecListing::build_ls_listing_command("~/my logs").expect("spaced command");

        assert!(find_command.contains("find ~ "));
        assert!(!find_command.contains("'~'"));
        assert!(ls_command.contains("ls -la ~/'logs'"));
        assert!(!ls_command.contains("'~/logs'"));
        assert!(spaced_command.contains("ls -la ~/'my logs'"));
        assert!(!spaced_command.contains("'~/my logs'"));
    }

    #[test]
    fn file_operation_commands_allow_shell_to_expand_home_directory_alias() {
        let mkdir_command =
            Libssh2ExecListing::build_operation_command(&RemoteFileOperation::MakeDirectory {
                path: "~/release".to_string(),
            })
            .expect("mkdir command");
        let rename_command =
            Libssh2ExecListing::build_operation_command(&RemoteFileOperation::Rename {
                from_path: "~/old name.txt".to_string(),
                to_path: "~/new name.txt".to_string(),
            })
            .expect("rename command");

        assert_eq!(mkdir_command, "mkdir -p ~/'release'");
        assert_eq!(rename_command, "mv ~/'old name.txt' ~/'new name.txt'");
        assert!(!mkdir_command.contains(" -- "));
        assert!(!rename_command.contains(" -- "));
        assert!(!mkdir_command.contains("'~/release'"));
        assert!(!rename_command.contains("'~/old name.txt'"));
    }

    #[test]
    fn parses_ls_listing_output_into_remote_entries() {
        let output = "\
total 8
drwxr-xr-x  2 root wheel   64 Jan  1 12:00 logs
-rw-r--r--  1 root wheel  128 Jan  1 12:00 read me.txt
lrwxr-xr-x  1 root wheel    9 Jan  1 12:00 current -> logs
";

        let entries = Libssh2ExecListing::parse_ls_listing("/var/app", output).expect("entries");

        assert_eq!(entries.len(), 3);
        assert_eq!(
            entries[0].kind,
            crate::domain::files::RemoteFileKind::Directory
        );
        assert_eq!(entries[0].path, "/var/app/logs");
        assert_eq!(entries[1].kind, crate::domain::files::RemoteFileKind::File);
        assert_eq!(entries[1].path, "/var/app/read me.txt");
        assert_eq!(entries[1].size, 128);
        assert_eq!(entries[1].modified_time.as_deref(), Some("Jan 1 12:00"));
        assert_eq!(entries[1].owner.as_deref(), Some("root"));
        assert_eq!(entries[1].permissions.as_deref(), Some("-rw-r--r--"));
        assert_eq!(
            entries[2].kind,
            crate::domain::files::RemoteFileKind::Symlink
        );
        assert_eq!(entries[2].modified_time.as_deref(), Some("Jan 1 12:00"));
        assert_eq!(entries[2].link_target, Some("logs".to_string()));
    }

    #[test]
    fn parses_linux_ls_listing_with_acl_context_years_and_spaced_names() {
        let output = "\
total 16
drwxr-xr-x.  3 deploy deploy 4096 Jun  6  2024 releases
-rw-r-----+  1 deploy deploy  128 Jun 12 09:18 current build.log
lrwxrwxrwx.  1 deploy deploy   16 Jun 12 09:19 latest -> releases/v1
";

        let entries = Libssh2ExecListing::parse_ls_listing("/srv/app", output).expect("entries");

        assert_eq!(entries.len(), 3);
        assert_eq!(entries[0].path, "/srv/app/releases");
        assert_eq!(entries[0].modified_time.as_deref(), Some("Jun 6 2024"));
        assert_eq!(entries[0].owner.as_deref(), Some("deploy"));
        assert_eq!(entries[0].permissions.as_deref(), Some("drwxr-xr-x."));
        assert_eq!(entries[1].path, "/srv/app/current build.log");
        assert_eq!(entries[1].modified_time.as_deref(), Some("Jun 12 09:18"));
        assert_eq!(entries[1].permissions.as_deref(), Some("-rw-r-----+"));
        assert_eq!(entries[2].path, "/srv/app/latest");
        assert_eq!(entries[2].link_target, Some("releases/v1".to_string()));
    }

    #[test]
    fn parses_linux_ls_listing_without_failing_on_special_device_rows() {
        let output = "\
total 8
drwxr-xr-x.  2 1001 1001    4096 Jun 12 09:18 发布 目录
crw-rw-rw-.  1 root root  1,   3 Jun 12 09:18 null
srw-rw-rw-.  1 root root       0 Jun 12 09:18 agent.sock
prw-r--r--.  1 root root       0 Jun 12 09:18 worker.pipe
-rw-r--r--.  1 1001 1001      42 Jun 12 09:19 config final.txt
lrwxrwxrwx.  1 root root      23 Jun 12 09:20 current config -> config final.txt
";

        let entries = Libssh2ExecListing::parse_ls_listing("/srv/app", output).expect("entries");

        assert_eq!(entries.len(), 3);
        assert_eq!(entries[0].path, "/srv/app/发布 目录");
        assert_eq!(entries[1].path, "/srv/app/config final.txt");
        assert_eq!(entries[1].size, 42);
        assert_eq!(entries[2].path, "/srv/app/current config");
        assert_eq!(entries[2].link_target, Some("config final.txt".to_string()));
    }

    #[test]
    fn live_remote_listing_handles_linux_names_with_gated_fixture_when_configured() {
        let Some((config, secret, remote_dir)) = ssh_fixture_config() else {
            return;
        };
        let ssh = crate::infrastructure::ssh::libssh2_transport::Libssh2Transport::new()
            .connect_with_secret(&config, secret)
            .expect("fixture ssh connection");
        let listing = Libssh2ExecListing::new();
        let fixture_root = format!(
            "{}/stacio-files-linux-fixture-{}",
            remote_dir.trim_end_matches('/'),
            std::process::id()
        );
        listing
            .apply_operation(
                &ssh,
                &RemoteFileOperation::MakeDirectory {
                    path: fixture_root.clone(),
                },
            )
            .expect("create fixture directory");
        let cleanup = || {
            let _ = listing.apply_operation(
                &ssh,
                &RemoteFileOperation::Delete {
                    path: fixture_root.clone(),
                    recursive: true,
                },
            );
        };

        Libssh2ExecListing::run_raw_command(
            &ssh,
            &format!(
                "printf '%s\\n' stacio > {}/{}",
                super::shell_path_argument(&fixture_root),
                super::shell_quote("配置 文件.txt")
            ),
        )
        .expect("create spaced unicode fixture file");

        let entries = listing
            .list_directory(&ssh, &fixture_root)
            .expect("list fixture directory");
        cleanup();

        assert!(
            entries
                .iter()
                .any(|entry| entry.path == format!("{fixture_root}/配置 文件.txt")),
            "fixture listing should include unicode/spaced file name: {entries:?}"
        );
    }

    #[test]
    fn skips_dot_entries_in_ls_listing_output() {
        let output = "\
total 0
drwxr-xr-x  3 root wheel   96 Jan  1 12:00 .
drwxr-xr-x  5 root wheel  160 Jan  1 12:00 ..
-rw-r--r--  1 root wheel    1 Jan  1 12:00 app.log
";

        let entries = Libssh2ExecListing::parse_ls_listing("/var/app", output).expect("entries");

        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].path, "/var/app/app.log");
    }

    #[test]
    fn builds_remote_file_operation_commands_without_file_transfer_tools() {
        let operations = [
            RemoteFileOperation::MakeDirectory {
                path: "/srv/app/new dir".to_string(),
            },
            RemoteFileOperation::Rename {
                from_path: "/srv/app/old.txt".to_string(),
                to_path: "/srv/app/new.txt".to_string(),
            },
            RemoteFileOperation::Delete {
                path: "/srv/app/tmp".to_string(),
                recursive: true,
            },
            RemoteFileOperation::Chmod {
                path: "/srv/app/run.sh".to_string(),
                mode: "755".to_string(),
            },
            RemoteFileOperation::Copy {
                from_path: "/srv/app/config.txt".to_string(),
                to_path: "/srv/app/config.txt-202606040912.bak".to_string(),
            },
        ];

        let commands = operations
            .iter()
            .map(Libssh2ExecListing::build_operation_command)
            .collect::<Result<Vec<_>, _>>()
            .expect("commands");

        assert_eq!(commands[0], "mkdir -p '/srv/app/new dir'");
        assert_eq!(commands[1], "mv '/srv/app/old.txt' '/srv/app/new.txt'");
        assert_eq!(commands[2], "rm -rf '/srv/app/tmp'");
        assert_eq!(commands[3], "chmod '755' '/srv/app/run.sh'");
        assert_eq!(
            commands[4],
            "cp -p '/srv/app/config.txt' '/srv/app/config.txt-202606040912.bak'"
        );
        for command in commands {
            assert!(
                !command.contains(" -- "),
                "file operation command should avoid GNU-specific option separators so it works across Linux userlands: {command}"
            );
            assert!(!command.contains("sftp "));
            assert!(!command.contains("scp "));
            assert!(!command.contains("rsync "));
        }
    }

    #[test]
    fn rejects_unsafe_remote_file_operations() {
        let mkdir_error =
            Libssh2ExecListing::build_operation_command(&RemoteFileOperation::MakeDirectory {
                path: "../etc".to_string(),
            })
            .expect_err("unsafe path");
        let chmod_error =
            Libssh2ExecListing::build_operation_command(&RemoteFileOperation::Chmod {
                path: "/srv/app/run.sh".to_string(),
                mode: "7;rm -rf /".to_string(),
            })
            .expect_err("unsafe mode");

        assert_eq!(mkdir_error, "FILES_UNSAFE_PATH");
        assert_eq!(chmod_error, "FILES_UNSAFE_MODE");
    }

    #[test]
    fn rejects_option_like_remote_path_components_without_relying_on_double_dash() {
        let unsafe_paths = [
            "-relative",
            "/srv/app/-flag",
            "~/--flag",
            "/srv/app/nested/-flag",
        ];

        for path in unsafe_paths {
            let error = Libssh2ExecListing::build_operation_command(&RemoteFileOperation::Delete {
                path: path.to_string(),
                recursive: false,
            })
            .expect_err("unsafe option-like path");

            assert_eq!(error, "FILES_UNSAFE_PATH", "path: {path}");
        }
    }

    fn ssh_fixture_config() -> Option<(
        crate::domain::ssh::SshConnectionConfig,
        Option<crate::infrastructure::ssh::libssh2_transport::SshSecret>,
        String,
    )> {
        let host = std::env::var("STACIO_SSH_FIXTURE_HOST").ok()?;
        let username = std::env::var("STACIO_SSH_FIXTURE_USERNAME").ok()?;
        let remote_dir = std::env::var("STACIO_SSH_FIXTURE_REMOTE_DIR").ok()?;
        let port = std::env::var("STACIO_SSH_FIXTURE_PORT")
            .ok()
            .and_then(|value| value.parse::<u16>().ok())
            .unwrap_or(22);
        let password = std::env::var("STACIO_SSH_FIXTURE_PASSWORD").ok();
        let private_key = std::env::var("STACIO_SSH_FIXTURE_PRIVATE_KEY").ok();
        let passphrase = std::env::var("STACIO_SSH_FIXTURE_PRIVATE_KEY_PASSPHRASE").ok();

        if let Some(password) = password {
            return Some((
                crate::domain::ssh::SshConnectionConfig {
                    host,
                    port,
                    username,
                    auth_method: crate::domain::ssh::SshAuthMethod::Password {
                        credential_ref: "fixture-password".to_string(),
                    },
                    connect_timeout_ms: 5_000,
                },
                Some(crate::infrastructure::ssh::libssh2_transport::SshSecret::Password(password)),
                remote_dir,
            ));
        }

        private_key.map(|private_key_pem| {
            (
                crate::domain::ssh::SshConnectionConfig {
                    host,
                    port,
                    username,
                    auth_method: crate::domain::ssh::SshAuthMethod::PrivateKey {
                        key_path: "fixture-memory-key".to_string(),
                        passphrase_ref: passphrase
                            .as_ref()
                            .map(|_| "fixture-passphrase".to_string()),
                    },
                    connect_timeout_ms: 5_000,
                },
                Some(
                    crate::infrastructure::ssh::libssh2_transport::SshSecret::PrivateKey {
                        private_key_pem,
                        passphrase,
                    },
                ),
                remote_dir,
            )
        })
    }
}
