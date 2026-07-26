use crate::{
    domain::{
        files::{RemoteFileEntry, RemoteFileKind},
        scp::{ScpDirection, ScpTransferJob},
    },
    infrastructure::ssh::libssh2_transport::Libssh2ConnectedSession,
    services::scp_service::{is_live_scp_transfer_cancelled, record_live_scp_transfer_progress},
};
use chrono::{DateTime, Utc};
use ssh2::{FileStat, OpenFlags, OpenType, RenameFlags, Sftp};
use std::{
    fs::{self, File},
    io::{Read, Seek, SeekFrom, Write},
    path::{Path, PathBuf},
};

const SFTP_TRANSFER_CHUNK_SIZE: usize = 256 * 1024;

pub struct Libssh2SftpEngine;

impl Libssh2SftpEngine {
    pub fn new() -> Self {
        Self
    }

    pub fn list_directory(
        &self,
        session: &Libssh2ConnectedSession,
        remote_path: &str,
    ) -> Result<Vec<RemoteFileEntry>, String> {
        let sftp = session.session().sftp().map_err(map_sftp_error)?;
        let resolved = resolve_remote_path(&sftp, remote_path)?;
        let mut entries = sftp
            .readdir(&resolved)
            .map_err(map_sftp_error)?
            .into_iter()
            .map(|(path, stat)| remote_entry(&sftp, remote_path, &path, stat))
            .collect::<Result<Vec<_>, _>>()?;
        entries.sort_by(|left, right| left.path.cmp(&right.path));
        Ok(entries)
    }

    pub fn search(
        &self,
        session: &Libssh2ConnectedSession,
        remote_path: &str,
        keyword: &str,
        depth: u32,
    ) -> Result<Vec<RemoteFileEntry>, String> {
        validate_remote_path(remote_path)?;
        let keyword = keyword.trim().to_lowercase();
        if keyword.is_empty() {
            return Ok(Vec::new());
        }
        let sftp = session.session().sftp().map_err(map_sftp_error)?;
        let resolved = resolve_remote_path(&sftp, remote_path)?;
        let mut matches = Vec::new();
        search_directory(&sftp, &resolved, remote_path, &keyword, depth, &mut matches)?;
        Ok(matches)
    }

    pub fn create_directory(
        &self,
        session: &Libssh2ConnectedSession,
        remote_path: &str,
    ) -> Result<(), String> {
        let sftp = session.session().sftp().map_err(map_sftp_error)?;
        let path = resolve_remote_path(&sftp, remote_path)?;
        sftp.mkdir(&path, 0o755).map_err(map_sftp_error)
    }

    pub fn rename(
        &self,
        session: &Libssh2ConnectedSession,
        from_path: &str,
        to_path: &str,
    ) -> Result<(), String> {
        let sftp = session.session().sftp().map_err(map_sftp_error)?;
        let from = resolve_remote_path(&sftp, from_path)?;
        let to = resolve_remote_path(&sftp, to_path)?;
        sftp.rename(&from, &to, Some(RenameFlags::OVERWRITE))
            .map_err(map_sftp_error)
    }

    pub fn delete(
        &self,
        session: &Libssh2ConnectedSession,
        remote_path: &str,
        recursive: bool,
    ) -> Result<(), String> {
        let sftp = session.session().sftp().map_err(map_sftp_error)?;
        let path = resolve_remote_path(&sftp, remote_path)?;
        let stat = sftp.lstat(&path).map_err(map_sftp_error)?;
        if stat.file_type().is_dir() {
            if recursive {
                delete_directory_children(&sftp, &path)?;
            }
            sftp.rmdir(&path).map_err(map_sftp_error)
        } else {
            sftp.unlink(&path).map_err(map_sftp_error)
        }
    }

    pub fn chmod(
        &self,
        session: &Libssh2ConnectedSession,
        remote_path: &str,
        mode: &str,
    ) -> Result<(), String> {
        let permissions = u32::from_str_radix(mode.trim(), 8)
            .map_err(|_| "FILES_INVALID_PERMISSIONS".to_string())?;
        if permissions > 0o7777 {
            return Err("FILES_INVALID_PERMISSIONS".to_string());
        }
        let sftp = session.session().sftp().map_err(map_sftp_error)?;
        let path = resolve_remote_path(&sftp, remote_path)?;
        let mut stat = sftp.lstat(&path).map_err(map_sftp_error)?;
        let file_type = stat.perm.unwrap_or(0) & 0o170000;
        stat.perm = Some(file_type | permissions);
        sftp.setstat(&path, stat).map_err(map_sftp_error)
    }

    pub fn copy(
        &self,
        session: &Libssh2ConnectedSession,
        from_path: &str,
        to_path: &str,
    ) -> Result<(), String> {
        let sftp = session.session().sftp().map_err(map_sftp_error)?;
        let from = resolve_remote_path(&sftp, from_path)?;
        let to = resolve_remote_path(&sftp, to_path)?;
        copy_remote_path(&sftp, &from, &to)
    }

    pub fn read_file(
        &self,
        session: &Libssh2ConnectedSession,
        remote_path: &str,
        offset: u64,
        length: Option<u64>,
    ) -> Result<Vec<u8>, String> {
        let sftp = session.session().sftp().map_err(map_sftp_error)?;
        let path = resolve_remote_path(&sftp, remote_path)?;
        let mut file = sftp.open(&path).map_err(map_sftp_error)?;
        file.seek(SeekFrom::Start(offset)).map_err(map_io_error)?;
        let mut bytes = Vec::new();
        match length {
            Some(length) => {
                Read::by_ref(&mut file)
                    .take(length)
                    .read_to_end(&mut bytes)
                    .map_err(map_io_error)?;
            }
            None => {
                file.read_to_end(&mut bytes).map_err(map_io_error)?;
            }
        }
        Ok(bytes)
    }

    pub fn write_file(
        &self,
        session: &Libssh2ConnectedSession,
        remote_path: &str,
        contents: &[u8],
    ) -> Result<u64, String> {
        let sftp = session.session().sftp().map_err(map_sftp_error)?;
        let path = resolve_remote_path(&sftp, remote_path)?;
        let mut file = sftp
            .open_mode(
                &path,
                OpenFlags::WRITE | OpenFlags::CREATE | OpenFlags::TRUNCATE,
                0o644,
                OpenType::File,
            )
            .map_err(map_sftp_error)?;
        file.write_all(contents).map_err(map_io_error)?;
        file.flush().map_err(map_io_error)?;
        Ok(contents.len() as u64)
    }

    pub fn transfer(
        &self,
        session: &Libssh2ConnectedSession,
        job: &ScpTransferJob,
    ) -> Result<u64, String> {
        let sftp = session.session().sftp().map_err(map_sftp_error)?;
        let bytes_total = match job.direction {
            ScpDirection::Upload => local_path_size(Path::new(&job.source_path))?,
            ScpDirection::Download => {
                let remote = resolve_remote_path(&sftp, &job.source_path)?;
                remote_path_size(&sftp, &remote)?
            }
        };
        let mut bytes_done = 0_u64;
        match job.direction {
            ScpDirection::Upload => {
                let remote = resolve_remote_path(&sftp, &job.destination_path)?;
                upload_local_path(
                    &sftp,
                    Path::new(&job.source_path),
                    &remote,
                    job,
                    bytes_total,
                    &mut bytes_done,
                )?;
            }
            ScpDirection::Download => {
                let remote = resolve_remote_path(&sftp, &job.source_path)?;
                download_remote_path(
                    &sftp,
                    &remote,
                    Path::new(&job.destination_path),
                    job,
                    bytes_total,
                    &mut bytes_done,
                )?;
            }
        }
        Ok(bytes_done)
    }
}

fn search_directory(
    sftp: &Sftp,
    resolved_directory: &Path,
    display_directory: &str,
    keyword: &str,
    depth: u32,
    matches: &mut Vec<RemoteFileEntry>,
) -> Result<(), String> {
    for (path, stat) in sftp.readdir(resolved_directory).map_err(map_sftp_error)? {
        let entry = remote_entry(sftp, display_directory, &path, stat.clone())?;
        let name = path
            .file_name()
            .and_then(|value| value.to_str())
            .ok_or_else(|| "FILES_UNSUPPORTED_FILE_NAME".to_string())?;
        if name.to_lowercase().contains(keyword) {
            matches.push(entry.clone());
        }
        if depth > 0 && stat.file_type().is_dir() {
            search_directory(
                sftp,
                &path,
                &join_display_path(display_directory, name),
                keyword,
                depth - 1,
                matches,
            )?;
        }
    }
    Ok(())
}

fn remote_entry(
    sftp: &Sftp,
    display_directory: &str,
    path: &Path,
    stat: FileStat,
) -> Result<RemoteFileEntry, String> {
    let name = path
        .file_name()
        .and_then(|value| value.to_str())
        .ok_or_else(|| "FILES_UNSUPPORTED_FILE_NAME".to_string())?;
    validate_remote_child_name(name)?;
    let file_type = stat.file_type();
    let kind = if file_type.is_dir() {
        RemoteFileKind::Directory
    } else if file_type.is_symlink() {
        RemoteFileKind::Symlink
    } else {
        RemoteFileKind::File
    };
    let link_target = if file_type.is_symlink() {
        sftp.readlink(path)
            .ok()
            .and_then(|target| target.to_str().map(str::to_string))
    } else {
        None
    };
    Ok(RemoteFileEntry {
        kind: kind.clone(),
        path: join_display_path(display_directory, name),
        size: stat.size.unwrap_or(0),
        modified_time: stat.mtime.and_then(format_modified_time),
        link_target,
        owner: stat.uid.map(|uid| uid.to_string()),
        permissions: stat
            .perm
            .map(|permissions| permissions_text(&kind, permissions)),
    })
}

fn resolve_remote_path(sftp: &Sftp, remote_path: &str) -> Result<PathBuf, String> {
    validate_remote_path(remote_path)?;
    let trimmed = remote_path.trim();
    if trimmed == "~" {
        return sftp.realpath(Path::new(".")).map_err(map_sftp_error);
    }
    if let Some(relative) = trimmed.strip_prefix("~/") {
        return sftp
            .realpath(Path::new("."))
            .map(|home| home.join(relative))
            .map_err(map_sftp_error);
    }
    Ok(PathBuf::from(trimmed))
}

fn validate_remote_path(path: &str) -> Result<(), String> {
    let trimmed = path.trim();
    if trimmed.is_empty()
        || trimmed == ".."
        || trimmed.starts_with("../")
        || trimmed.ends_with("/..")
        || trimmed.contains("../")
        || trimmed.chars().any(char::is_control)
    {
        return Err("FILES_UNSAFE_PATH".to_string());
    }
    Ok(())
}

fn validate_remote_child_name(name: &str) -> Result<(), String> {
    if name.is_empty()
        || name == "."
        || name == ".."
        || name.contains('/')
        || name.chars().any(char::is_control)
    {
        return Err("FILES_UNSAFE_PATH".to_string());
    }
    Ok(())
}

fn join_display_path(directory: &str, name: &str) -> String {
    let directory = directory.trim();
    if directory == "/" {
        format!("/{name}")
    } else if directory == "~" {
        format!("~/{name}")
    } else {
        format!("{}/{name}", directory.trim_end_matches('/'))
    }
}

fn permissions_text(kind: &RemoteFileKind, permissions: u32) -> String {
    let first = match kind {
        RemoteFileKind::Directory => 'd',
        RemoteFileKind::Symlink => 'l',
        RemoteFileKind::File => '-',
    };
    let mut result = String::with_capacity(10);
    result.push(first);
    for (read, write, execute) in [
        (0o400, 0o200, 0o100),
        (0o040, 0o020, 0o010),
        (0o004, 0o002, 0o001),
    ] {
        result.push(if permissions & read != 0 { 'r' } else { '-' });
        result.push(if permissions & write != 0 { 'w' } else { '-' });
        result.push(if permissions & execute != 0 { 'x' } else { '-' });
    }
    result
}

fn format_modified_time(seconds: u64) -> Option<String> {
    DateTime::<Utc>::from_timestamp(seconds as i64, 0)
        .map(|date| date.format("%m-%d %H:%M").to_string())
}

fn delete_directory_children(sftp: &Sftp, directory: &Path) -> Result<(), String> {
    for (path, stat) in sftp.readdir(directory).map_err(map_sftp_error)? {
        if stat.file_type().is_dir() {
            delete_directory_children(sftp, &path)?;
            sftp.rmdir(&path).map_err(map_sftp_error)?;
        } else {
            sftp.unlink(&path).map_err(map_sftp_error)?;
        }
    }
    Ok(())
}

fn copy_remote_path(sftp: &Sftp, source: &Path, destination: &Path) -> Result<(), String> {
    let stat = sftp.lstat(source).map_err(map_sftp_error)?;
    if stat.file_type().is_dir() {
        ensure_remote_directory(sftp, destination)?;
        for (child, _) in sftp.readdir(source).map_err(map_sftp_error)? {
            let name = child
                .file_name()
                .ok_or_else(|| "FILES_UNSUPPORTED_FILE_NAME".to_string())?;
            copy_remote_path(sftp, &child, &destination.join(name))?;
        }
        return Ok(());
    }
    let mut reader = sftp.open(source).map_err(map_sftp_error)?;
    let mut writer = sftp
        .open_mode(
            destination,
            OpenFlags::WRITE | OpenFlags::CREATE | OpenFlags::TRUNCATE,
            0o644,
            OpenType::File,
        )
        .map_err(map_sftp_error)?;
    std::io::copy(&mut reader, &mut writer).map_err(map_io_error)?;
    writer.flush().map_err(map_io_error)
}

fn upload_local_path(
    sftp: &Sftp,
    local: &Path,
    remote: &Path,
    job: &ScpTransferJob,
    bytes_total: u64,
    bytes_done: &mut u64,
) -> Result<(), String> {
    check_cancelled(job)?;
    let metadata = fs::metadata(local).map_err(map_io_error)?;
    if metadata.is_dir() {
        ensure_remote_directory(sftp, remote)?;
        for entry in fs::read_dir(local).map_err(map_io_error)? {
            let entry = entry.map_err(map_io_error)?;
            upload_local_path(
                sftp,
                &entry.path(),
                &remote.join(entry.file_name()),
                job,
                bytes_total,
                bytes_done,
            )?;
        }
        return Ok(());
    }
    let mut reader = File::open(local).map_err(map_io_error)?;
    let mut writer = sftp
        .open_mode(
            remote,
            OpenFlags::WRITE | OpenFlags::CREATE | OpenFlags::TRUNCATE,
            0o644,
            OpenType::File,
        )
        .map_err(map_sftp_error)?;
    copy_with_progress(&mut reader, &mut writer, job, bytes_total, bytes_done)?;
    writer.flush().map_err(map_io_error)
}

fn download_remote_path(
    sftp: &Sftp,
    remote: &Path,
    local: &Path,
    job: &ScpTransferJob,
    bytes_total: u64,
    bytes_done: &mut u64,
) -> Result<(), String> {
    check_cancelled(job)?;
    let stat = sftp.lstat(remote).map_err(map_sftp_error)?;
    if stat.file_type().is_dir() {
        fs::create_dir_all(local).map_err(map_io_error)?;
        for (child, _) in sftp.readdir(remote).map_err(map_sftp_error)? {
            let name = child
                .file_name()
                .ok_or_else(|| "FILES_UNSUPPORTED_FILE_NAME".to_string())?;
            download_remote_path(
                sftp,
                &child,
                &local.join(name),
                job,
                bytes_total,
                bytes_done,
            )?;
        }
        return Ok(());
    }
    if let Some(parent) = local.parent() {
        fs::create_dir_all(parent).map_err(map_io_error)?;
    }
    let mut reader = sftp.open(remote).map_err(map_sftp_error)?;
    let mut writer = File::create(local).map_err(map_io_error)?;
    copy_with_progress(&mut reader, &mut writer, job, bytes_total, bytes_done)?;
    writer.flush().map_err(map_io_error)
}

fn copy_with_progress<R: Read, W: Write>(
    reader: &mut R,
    writer: &mut W,
    job: &ScpTransferJob,
    bytes_total: u64,
    bytes_done: &mut u64,
) -> Result<(), String> {
    let mut buffer = vec![0_u8; SFTP_TRANSFER_CHUNK_SIZE];
    loop {
        check_cancelled(job)?;
        let count = reader.read(&mut buffer).map_err(map_io_error)?;
        if count == 0 {
            break;
        }
        writer.write_all(&buffer[..count]).map_err(map_io_error)?;
        *bytes_done = bytes_done.saturating_add(count as u64);
        record_live_scp_transfer_progress(crate::domain::scp::ScpTransferProgress {
            job_id: job.id.clone(),
            bytes_done: *bytes_done,
            bytes_total,
            status: "running".to_string(),
        });
    }
    Ok(())
}

fn ensure_remote_directory(sftp: &Sftp, path: &Path) -> Result<(), String> {
    if sftp
        .stat(path)
        .map(|stat| stat.file_type().is_dir())
        .unwrap_or(false)
    {
        return Ok(());
    }
    sftp.mkdir(path, 0o755).map_err(map_sftp_error)
}

fn local_path_size(path: &Path) -> Result<u64, String> {
    let metadata = fs::metadata(path).map_err(map_io_error)?;
    if metadata.is_file() {
        return Ok(metadata.len());
    }
    if !metadata.is_dir() {
        return Err("FILES_LOCAL_FILE_MISSING".to_string());
    }
    let mut size = 0_u64;
    for entry in fs::read_dir(path).map_err(map_io_error)? {
        size = size.saturating_add(local_path_size(&entry.map_err(map_io_error)?.path())?);
    }
    Ok(size)
}

fn remote_path_size(sftp: &Sftp, path: &Path) -> Result<u64, String> {
    let stat = sftp.lstat(path).map_err(map_sftp_error)?;
    if !stat.file_type().is_dir() {
        return Ok(stat.size.unwrap_or(0));
    }
    let mut size = 0_u64;
    for (child, _) in sftp.readdir(path).map_err(map_sftp_error)? {
        size = size.saturating_add(remote_path_size(sftp, &child)?);
    }
    Ok(size)
}

fn check_cancelled(job: &ScpTransferJob) -> Result<(), String> {
    if is_live_scp_transfer_cancelled(&job.id) {
        Err("SFTP_TRANSFER_CANCELLED".to_string())
    } else {
        Ok(())
    }
}

fn map_sftp_error(error: ssh2::Error) -> String {
    let message = error.message().to_ascii_lowercase();
    if message.contains("permission") || message.contains("denied") {
        "FILES_PERMISSION_DENIED".to_string()
    } else if message.contains("no such file") {
        "FILES_REMOTE_FILE_MISSING".to_string()
    } else if message.contains("timed out") {
        "FILES_TRANSFER_TIMEOUT".to_string()
    } else {
        "FILES_SFTP_OPERATION_FAILED".to_string()
    }
}

fn map_io_error(error: std::io::Error) -> String {
    match error.kind() {
        std::io::ErrorKind::PermissionDenied => "FILES_PERMISSION_DENIED".to_string(),
        std::io::ErrorKind::NotFound => "FILES_LOCAL_FILE_MISSING".to_string(),
        std::io::ErrorKind::TimedOut => "FILES_TRANSFER_TIMEOUT".to_string(),
        _ if error.raw_os_error() == Some(28) => "FILES_DISK_FULL".to_string(),
        _ => "FILES_TRANSFER_INTERRUPTED".to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::{join_display_path, local_path_size, permissions_text, validate_remote_path};
    use crate::domain::files::RemoteFileKind;

    #[test]
    fn keeps_home_and_absolute_display_paths_stable() {
        assert_eq!(join_display_path("~", "logs"), "~/logs");
        assert_eq!(join_display_path("/", "logs"), "/logs");
        assert_eq!(join_display_path("/srv/app/", "logs"), "/srv/app/logs");
    }

    #[test]
    fn rejects_parent_and_control_segments() {
        assert!(validate_remote_path("../etc").is_err());
        assert!(validate_remote_path("/srv/app/..").is_err());
        assert!(validate_remote_path("/srv/\napp").is_err());
    }

    #[test]
    fn renders_posix_permissions_for_remote_rows() {
        assert_eq!(
            permissions_text(&RemoteFileKind::Directory, 0o40755),
            "drwxr-xr-x"
        );
        assert_eq!(
            permissions_text(&RemoteFileKind::File, 0o100640),
            "-rw-r-----"
        );
    }

    #[test]
    fn totals_nested_local_directory_bytes_for_recursive_upload() {
        let temp = tempfile::tempdir().expect("temp dir");
        let nested = temp.path().join("nested");
        std::fs::create_dir(&nested).expect("create nested dir");
        std::fs::write(temp.path().join("first.txt"), b"abc").expect("write first file");
        std::fs::write(nested.join("second.txt"), b"de").expect("write second file");

        assert_eq!(local_path_size(temp.path()).expect("directory size"), 5);
    }
}
