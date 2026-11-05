use std::collections::{HashMap, HashSet, VecDeque};
use std::ffi::{CString, OsStr};
use std::io::{Read, Seek, SeekFrom, Write};
use std::os::fd::{AsFd, AsRawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::MetadataExt;
use std::path::{Component, Path, PathBuf};

use ironrdp_core::impl_as_any;
use ironrdp_pdu::{PduResult, encode_err};
use ironrdp_rdpdr::RdpdrBackend;
use ironrdp_rdpdr::pdu::RdpdrPdu;
use ironrdp_rdpdr::pdu::efs::*;
use ironrdp_rdpdr::pdu::esc::{ScardCall, ScardIoCtlCode};
use ironrdp_svc::SvcMessage;
use nix::dir::Dir;
use nix::fcntl::{AtFlags, OFlag, open, openat, renameat};
use nix::sys::stat::{FileStat, Mode, SFlag, fstatat, mkdirat};
use nix::unistd::{UnlinkatFlags, unlinkat};
use tracing::{debug, warn};

const MAX_DEVICE_READ_BYTES: u32 = 16 * 1024 * 1024;
const STATUS_SHARING_VIOLATION: u32 = 0xC000_0043;
const STATUS_DELETE_PENDING: u32 = 0xC000_0056;
const STATUS_FILE_IS_A_DIRECTORY: u32 = 0xC000_00BA;
const STATUS_INVALID_PARAMETER: u32 = 0xC000_000D;

#[derive(Debug)]
struct SharedRootIdentity {
    canonical_path: PathBuf,
    device: u64,
    inode: u64,
    directory: std::fs::File,
}

#[derive(Debug)]
struct OpenHandle {
    file: std::fs::File,
    relative_path: PathBuf,
    desired_access: DesiredAccess,
    shared_access: SharedAccess,
    is_directory: bool,
}

#[derive(Debug, Clone)]
struct DirectoryEntryInfo {
    name: String,
    creation_time: i64,
    last_access_time: i64,
    last_write_time: i64,
    change_time: i64,
    size: i64,
    attributes: FileAttributes,
}

#[derive(Debug, Default)]
struct DirectoryQueryState {
    entries: VecDeque<DirectoryEntryInfo>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum PathKind {
    File,
    Directory,
    Symlink,
    Other,
}

#[derive(Debug, Clone, Copy)]
struct PathEntry {
    kind: PathKind,
    device: u64,
    inode: u64,
}

#[derive(Debug)]
pub struct NixRdpdrBackend {
    file_id: u32,
    file_base: String,
    shared_root: Option<SharedRootIdentity>,
    handles: HashMap<u32, OpenHandle>,
    directory_queries: HashMap<u32, DirectoryQueryState>,
    delete_pending: HashSet<PathBuf>,
}

impl NixRdpdrBackend {
    pub fn new(file_base: String) -> Self {
        let shared_root = std::fs::canonicalize(&file_base)
            .ok()
            .and_then(|canonical_path| {
                let descriptor = open(
                    &canonical_path,
                    OFlag::O_RDONLY | OFlag::O_DIRECTORY | OFlag::O_NOFOLLOW | OFlag::O_CLOEXEC,
                    Mode::empty(),
                )
                .ok()?;
                let directory = std::fs::File::from(descriptor);
                let metadata = directory.metadata().ok()?;
                metadata.is_dir().then_some(SharedRootIdentity {
                    canonical_path,
                    device: metadata.dev(),
                    inode: metadata.ino(),
                    directory,
                })
            });

        Self {
            file_id: 0,
            file_base,
            shared_root,
            handles: HashMap::new(),
            directory_queries: HashMap::new(),
            delete_pending: HashSet::new(),
        }
    }

    fn checked_root(&self) -> std::io::Result<&SharedRootIdentity> {
        let shared_root = self
            .shared_root
            .as_ref()
            .ok_or_else(|| path_access_denied("RDPDR shared root was invalid at startup"))?;
        let current_root = std::fs::canonicalize(&self.file_base)?;
        let current_metadata = std::fs::metadata(&current_root)?;
        if !current_metadata.is_dir()
            || current_root != shared_root.canonical_path
            || current_metadata.dev() != shared_root.device
            || current_metadata.ino() != shared_root.inode
        {
            return Err(path_access_denied(
                "RDPDR shared root was replaced after the session started",
            ));
        }

        let descriptor_metadata = shared_root.directory.metadata()?;
        if !descriptor_metadata.is_dir()
            || descriptor_metadata.dev() != shared_root.device
            || descriptor_metadata.ino() != shared_root.inode
        {
            return Err(path_access_denied(
                "RDPDR shared root descriptor no longer identifies the original directory",
            ));
        }
        Ok(shared_root)
    }

    fn normalize_remote_path(&self, remote_path: &str) -> std::io::Result<PathBuf> {
        if remote_path.contains('\0') {
            return Err(path_access_denied("RDPDR path contains a NUL byte"));
        }
        self.checked_root()?;

        let normalized = remote_path.replace('\\', "/");
        let relative_path = normalized.trim_start_matches('/');
        let mut relative = PathBuf::new();
        for component in Path::new(relative_path).components() {
            match component {
                Component::Normal(segment) => relative.push(segment),
                Component::CurDir => {}
                Component::ParentDir | Component::RootDir | Component::Prefix(_) => {
                    return Err(path_access_denied("RDPDR path escapes the shared root"));
                }
            }
        }
        Ok(relative)
    }

    fn open_directory(&self, relative_path: &Path) -> std::io::Result<std::fs::File> {
        let root = self.checked_root()?;
        let mut current = root.directory.try_clone()?;
        for component in relative_path.components() {
            let Component::Normal(segment) = component else {
                return Err(path_access_denied(
                    "RDPDR directory path was not normalized",
                ));
            };
            let descriptor = match openat(
                &current,
                segment,
                OFlag::O_RDONLY | OFlag::O_DIRECTORY | OFlag::O_NOFOLLOW | OFlag::O_CLOEXEC,
                Mode::empty(),
            ) {
                Ok(descriptor) => descriptor,
                Err(error)
                    if error == nix::errno::Errno::ENOTDIR || error == nix::errno::Errno::ELOOP =>
                {
                    if error == nix::errno::Errno::ELOOP
                        || fstatat(&current, segment, AtFlags::AT_SYMLINK_NOFOLLOW).is_ok_and(
                            |stat| stat.st_mode & nix::libc::S_IFMT == nix::libc::S_IFLNK,
                        )
                    {
                        return Err(path_access_denied(
                            "RDPDR directory path contains a symbolic link",
                        ));
                    }
                    return Err(errno_to_io(error));
                }
                Err(error) => return Err(errno_to_io(error)),
            };
            current = std::fs::File::from(descriptor);
        }
        Ok(current)
    }

    fn open_parent<'a>(
        &self,
        relative_path: &'a Path,
    ) -> std::io::Result<(std::fs::File, &'a OsStr)> {
        let name = relative_path
            .file_name()
            .ok_or_else(|| path_access_denied("RDPDR operation cannot target the shared root"))?;
        let parent = relative_path.parent().unwrap_or_else(|| Path::new(""));
        Ok((self.open_directory(parent)?, name))
    }

    fn lstat_relative(&self, relative_path: &Path) -> std::io::Result<PathEntry> {
        if relative_path.as_os_str().is_empty() {
            let root = self.checked_root()?;
            return Ok(PathEntry {
                kind: PathKind::Directory,
                device: root.device,
                inode: root.inode,
            });
        }
        let (parent, name) = self.open_parent(relative_path)?;
        let stat = fstatat(&parent, name, AtFlags::AT_SYMLINK_NOFOLLOW).map_err(errno_to_io)?;
        Ok(path_entry_from_stat(&stat))
    }

    fn open_relative(
        &self,
        relative_path: &Path,
        flags: OFlag,
        mode: Mode,
    ) -> std::io::Result<std::fs::File> {
        if relative_path.as_os_str().is_empty() {
            return self.checked_root()?.directory.try_clone();
        }
        let (parent, name) = self.open_parent(relative_path)?;
        let descriptor = openat(
            &parent,
            name,
            flags | OFlag::O_NOFOLLOW | OFlag::O_CLOEXEC,
            mode,
        )
        .map_err(errno_to_io)?;
        Ok(std::fs::File::from(descriptor))
    }

    fn next_file_id(&mut self) -> u32 {
        loop {
            let candidate = self.file_id;
            self.file_id = self.file_id.wrapping_add(1);
            if !self.handles.contains_key(&candidate) {
                return candidate;
            }
        }
    }

    fn path_is_delete_pending(&self, path: &Path) -> bool {
        self.delete_pending
            .iter()
            .any(|pending| path == pending || path.starts_with(pending))
    }

    fn has_share_conflict(
        &self,
        path: &Path,
        desired_access: &DesiredAccess,
        shared_access: &SharedAccess,
        excluded_file_id: Option<u32>,
    ) -> bool {
        self.handles.iter().any(|(file_id, handle)| {
            if Some(*file_id) == excluded_file_id || handle.relative_path != path {
                return false;
            }
            (access_reads(desired_access)
                && !handle.shared_access.contains(SharedAccess::FILE_SHARE_READ))
                || (access_writes(desired_access)
                    && !handle
                        .shared_access
                        .contains(SharedAccess::FILE_SHARE_WRITE))
                || (access_deletes(desired_access)
                    && !handle
                        .shared_access
                        .contains(SharedAccess::FILE_SHARE_DELETE))
                || (access_reads(&handle.desired_access)
                    && !shared_access.contains(SharedAccess::FILE_SHARE_READ))
                || (access_writes(&handle.desired_access)
                    && !shared_access.contains(SharedAccess::FILE_SHARE_WRITE))
                || (access_deletes(&handle.desired_access)
                    && !shared_access.contains(SharedAccess::FILE_SHARE_DELETE))
        })
    }

    fn verify_handle_path_identity(&self, file_id: u32) -> std::io::Result<()> {
        let handle = self
            .handles
            .get(&file_id)
            .ok_or_else(|| std::io::Error::from(std::io::ErrorKind::NotFound))?;
        let metadata = handle.file.metadata()?;
        let entry = self.lstat_relative(&handle.relative_path)?;
        if metadata.dev() != entry.device || metadata.ino() != entry.inode {
            return Err(path_access_denied(
                "RDPDR handle path was replaced after it was opened",
            ));
        }
        Ok(())
    }

    fn no_open_handle_at_or_below(&self, path: &Path) -> bool {
        !self
            .handles
            .values()
            .any(|handle| handle.relative_path == path || handle.relative_path.starts_with(path))
    }

    fn delete_relative_path(&self, path: &Path, is_directory: bool) -> std::io::Result<()> {
        let (parent, name) = self.open_parent(path)?;
        unlinkat(
            &parent,
            name,
            if is_directory {
                UnlinkatFlags::RemoveDir
            } else {
                UnlinkatFlags::NoRemoveDir
            },
        )
        .map_err(errno_to_io)
    }

    fn update_paths_after_rename(&mut self, old_path: &Path, new_path: &Path) {
        for handle in self.handles.values_mut() {
            if let Ok(suffix) = handle.relative_path.strip_prefix(old_path) {
                handle.relative_path = new_path.join(suffix);
            }
        }
        self.delete_pending = self
            .delete_pending
            .drain()
            .map(|pending| {
                pending
                    .strip_prefix(old_path)
                    .map(|suffix| new_path.join(suffix))
                    .unwrap_or(pending)
            })
            .collect();
        self.directory_queries.clear();
    }
}

fn path_access_denied(message: &'static str) -> std::io::Error {
    std::io::Error::new(std::io::ErrorKind::PermissionDenied, message)
}

fn errno_to_io(error: nix::errno::Errno) -> std::io::Error {
    std::io::Error::from_raw_os_error(error as i32)
}

fn io_error_status(error: &std::io::Error) -> NtStatus {
    match error.raw_os_error() {
        Some(code) if code == nix::libc::ENOENT => NtStatus::NO_SUCH_FILE,
        Some(code) if code == nix::libc::EEXIST => NtStatus::OBJECT_NAME_COLLISION,
        Some(code)
            if code == nix::libc::EACCES
                || code == nix::libc::EPERM
                || code == nix::libc::ELOOP =>
        {
            NtStatus::ACCESS_DENIED
        }
        Some(code) if code == nix::libc::ENOTDIR => NtStatus::NOT_A_DIRECTORY,
        Some(code) if code == nix::libc::EISDIR => NtStatus::from(STATUS_FILE_IS_A_DIRECTORY),
        Some(code) if code == nix::libc::ENOTEMPTY => NtStatus::DIRECTORY_NOT_EMPTY,
        _ if error.kind() == std::io::ErrorKind::NotFound => NtStatus::NO_SUCH_FILE,
        _ if error.kind() == std::io::ErrorKind::PermissionDenied => NtStatus::ACCESS_DENIED,
        _ => NtStatus::UNSUCCESSFUL,
    }
}

fn path_entry_from_stat(stat: &FileStat) -> PathEntry {
    let file_type = SFlag::from_bits_truncate(stat.st_mode);
    let kind = if file_type.contains(SFlag::S_IFDIR) {
        PathKind::Directory
    } else if file_type.contains(SFlag::S_IFREG) {
        PathKind::File
    } else if file_type.contains(SFlag::S_IFLNK) {
        PathKind::Symlink
    } else {
        PathKind::Other
    };
    PathEntry {
        kind,
        device: stat.st_dev as u64,
        inode: stat.st_ino as u64,
    }
}

fn access_reads(access: &DesiredAccess) -> bool {
    access.intersects(
        DesiredAccess::FILE_READ_DATA_OR_FILE_LIST_DIRECTORY
            | DesiredAccess::FILE_READ_EA
            | DesiredAccess::FILE_READ_ATTRIBUTES
            | DesiredAccess::GENERIC_READ
            | DesiredAccess::GENERIC_ALL
            | DesiredAccess::MAXIMUM_ALLOWED,
    )
}

fn access_writes(access: &DesiredAccess) -> bool {
    access.intersects(
        DesiredAccess::FILE_WRITE_DATA_OR_FILE_ADD_FILE
            | DesiredAccess::FILE_APPEND_DATA_OR_FILE_ADD_SUBDIRECTORY
            | DesiredAccess::FILE_WRITE_EA
            | DesiredAccess::FILE_WRITE_ATTRIBUTES
            | DesiredAccess::GENERIC_WRITE
            | DesiredAccess::GENERIC_ALL
            | DesiredAccess::MAXIMUM_ALLOWED,
    )
}

fn access_deletes(access: &DesiredAccess) -> bool {
    access.intersects(
        DesiredAccess::DELETE
            | DesiredAccess::FILE_DELETE_CHILD
            | DesiredAccess::GENERIC_ALL
            | DesiredAccess::MAXIMUM_ALLOWED,
    )
}

fn access_open_flags(access: &DesiredAccess, force_write: bool) -> OFlag {
    let reads = access_reads(access);
    let writes = access_writes(access) || force_write;
    match (reads, writes) {
        (true, true) => OFlag::O_RDWR,
        (false, true) => OFlag::O_WRONLY,
        _ => OFlag::O_RDONLY,
    }
}

impl_as_any!(NixRdpdrBackend);

impl RdpdrBackend for NixRdpdrBackend {
    fn handle_server_device_announce_response(
        &mut self,
        _pdu: ServerDeviceAnnounceResponse,
    ) -> PduResult<()> {
        Ok(())
    }

    fn handle_scard_call(
        &mut self,
        _req: DeviceControlRequest<ScardIoCtlCode>,
        _call: ScardCall,
    ) -> PduResult<()> {
        Ok(())
    }

    fn handle_drive_io_request(&mut self, req: ServerDriveIoRequest) -> PduResult<Vec<SvcMessage>> {
        debug!("handle_drive_io_request:{:?}", req);
        match req {
            ServerDriveIoRequest::DeviceWriteRequest(req_inner) => write_device(self, req_inner),
            ServerDriveIoRequest::ServerCreateDriveRequest(req_inner) => {
                create_drive(self, req_inner)
            }
            ServerDriveIoRequest::DeviceReadRequest(req_inner) => read_device(self, req_inner),
            ServerDriveIoRequest::DeviceCloseRequest(req_inner) => close_device(self, req_inner),
            ServerDriveIoRequest::ServerDriveNotifyChangeDirectoryRequest(req_inner) => {
                Ok(vec![SvcMessage::from(
                    RdpdrPdu::ClientDriveQueryDirectoryResponse(
                        ClientDriveQueryDirectoryResponse {
                            device_io_reply: DeviceIoResponse::new(
                                req_inner.device_io_request,
                                NtStatus::NOT_SUPPORTED,
                            ),
                            buffer: None,
                        },
                    ),
                )])
            }
            ServerDriveIoRequest::ServerDriveQueryDirectoryRequest(req_inner) => {
                query_directory(self, req_inner)
            }
            ServerDriveIoRequest::ServerDriveQueryInformationRequest(req_inner) => {
                query_information(self, req_inner)
            }
            ServerDriveIoRequest::ServerDriveQueryVolumeInformationRequest(req_inner) => {
                query_volume_information(self, req_inner)
            }
            ServerDriveIoRequest::ServerDriveSetInformationRequest(req_inner) => {
                set_information(self, req_inner)
            }
            ServerDriveIoRequest::DeviceControlRequest(req_inner) => Ok(vec![SvcMessage::from(
                RdpdrPdu::DeviceControlResponse(DeviceControlResponse {
                    device_io_reply: DeviceIoResponse::new(
                        req_inner.header,
                        NtStatus::NOT_SUPPORTED,
                    ),
                    output_buffer: None,
                }),
            )]),
            ServerDriveIoRequest::ServerDriveLockControlRequest(req_inner) => {
                Ok(vec![SvcMessage::from(RdpdrPdu::DeviceControlResponse(
                    DeviceControlResponse {
                        device_io_reply: DeviceIoResponse::new(
                            req_inner.device_io_request,
                            NtStatus::NOT_SUPPORTED,
                        ),
                        output_buffer: None,
                    },
                ))])
            }
        }
    }
}

pub(crate) fn write_device(
    backend: &mut NixRdpdrBackend,
    req_inner: DeviceWriteRequest,
) -> PduResult<Vec<SvcMessage>> {
    let request = req_inner.device_io_request.clone();
    let status_and_length = match backend.handles.get_mut(&request.file_id) {
        None => (NtStatus::NO_SUCH_FILE, 0),
        Some(handle) if !access_writes(&handle.desired_access) || handle.is_directory => {
            (NtStatus::ACCESS_DENIED, 0)
        }
        Some(handle) => {
            let result = (|| -> std::io::Result<()> {
                handle.file.seek(SeekFrom::Start(req_inner.offset))?;
                handle.file.write_all(&req_inner.write_data)?;
                handle.file.flush()?;
                Ok(())
            })();
            match result {
                Ok(()) => (
                    NtStatus::SUCCESS,
                    u32::try_from(req_inner.write_data.len()).unwrap_or(u32::MAX),
                ),
                Err(error) => {
                    warn!(%error, "RDPDR write failed");
                    (io_error_status(&error), 0)
                }
            }
        }
    };
    Ok(vec![SvcMessage::from(RdpdrPdu::DeviceWriteResponse(
        DeviceWriteResponse {
            device_io_reply: DeviceIoResponse::new(request, status_and_length.0),
            length: status_and_length.1,
        },
    ))])
}

pub(crate) fn read_device(
    backend: &mut NixRdpdrBackend,
    req_inner: DeviceReadRequest,
) -> PduResult<Vec<SvcMessage>> {
    let request = req_inner.device_io_request;
    if req_inner.length > MAX_DEVICE_READ_BYTES {
        warn!(
            requested = req_inner.length,
            maximum = MAX_DEVICE_READ_BYTES,
            "Rejected oversized RDPDR read"
        );
        return Ok(vec![SvcMessage::from(RdpdrPdu::DeviceReadResponse(
            DeviceReadResponse {
                device_io_reply: DeviceIoResponse::new(request, NtStatus::UNSUCCESSFUL),
                read_data: Vec::new(),
            },
        ))]);
    }

    let (status, read_data) = match backend.handles.get_mut(&request.file_id) {
        None => (NtStatus::NO_SUCH_FILE, Vec::new()),
        Some(handle) if !access_reads(&handle.desired_access) || handle.is_directory => {
            (NtStatus::ACCESS_DENIED, Vec::new())
        }
        Some(handle) => {
            let result = (|| -> std::io::Result<Vec<u8>> {
                handle.file.seek(SeekFrom::Start(req_inner.offset))?;
                let mut buffer = vec![0; usize::try_from(req_inner.length).unwrap_or(0)];
                let length = handle.file.read(&mut buffer)?;
                buffer.truncate(length);
                Ok(buffer)
            })();
            match result {
                Ok(buffer) => (NtStatus::SUCCESS, buffer),
                Err(error) => {
                    warn!(%error, "RDPDR read failed");
                    (io_error_status(&error), Vec::new())
                }
            }
        }
    };
    Ok(vec![SvcMessage::from(RdpdrPdu::DeviceReadResponse(
        DeviceReadResponse {
            device_io_reply: DeviceIoResponse::new(request, status),
            read_data,
        },
    ))])
}

pub(crate) fn close_device(
    backend: &mut NixRdpdrBackend,
    req_inner: DeviceCloseRequest,
) -> PduResult<Vec<SvcMessage>> {
    let request = req_inner.device_io_request;
    backend.directory_queries.remove(&request.file_id);

    let mut status = NtStatus::SUCCESS;
    let pending_path = backend.handles.get(&request.file_id).and_then(|handle| {
        backend
            .delete_pending
            .contains(&handle.relative_path)
            .then(|| (handle.relative_path.clone(), handle.is_directory))
    });
    if pending_path.is_some() {
        if let Err(error) = backend.verify_handle_path_identity(request.file_id) {
            warn!(%error, "RDPDR delete-on-close identity check failed");
            status = io_error_status(&error);
        }
    }

    let removed = backend.handles.remove(&request.file_id);
    if removed.is_none() {
        status = NtStatus::NO_SUCH_FILE;
    }

    if status == NtStatus::SUCCESS {
        if let Some((path, is_directory)) = pending_path {
            if backend.no_open_handle_at_or_below(&path) {
                match backend.delete_relative_path(&path, is_directory) {
                    Ok(()) => {
                        backend.delete_pending.remove(&path);
                    }
                    Err(error) => {
                        warn!(%error, "RDPDR delete-on-close failed");
                        status = io_error_status(&error);
                        backend.delete_pending.remove(&path);
                    }
                }
            }
        }
    }

    Ok(vec![SvcMessage::from(RdpdrPdu::DeviceCloseResponse(
        DeviceCloseResponse {
            device_io_response: DeviceIoResponse::new(request, status),
        },
    ))])
}

pub(crate) fn query_information(
    backend: &mut NixRdpdrBackend,
    req_inner: ServerDriveQueryInformationRequest,
) -> PduResult<Vec<SvcMessage>> {
    let request = req_inner.device_io_request;
    let Some(handle) = backend.handles.get(&request.file_id) else {
        return query_information_response(request, NtStatus::NO_SUCH_FILE, None);
    };
    let metadata = match handle.file.metadata() {
        Ok(metadata) => metadata,
        Err(error) => {
            warn!(%error, "RDPDR metadata query failed");
            return query_information_response(request, io_error_status(&error), None);
        }
    };
    let name = handle
        .relative_path
        .file_name()
        .and_then(OsStr::to_str)
        .unwrap_or("");
    let attributes = get_file_attributes(&metadata, name);
    let buffer = if req_inner.file_info_class_lvl
        == FileInformationClassLevel::FILE_BASIC_INFORMATION
    {
        Some(FileInformationClass::Basic(FileBasicInformation {
            creation_time: transform_to_filetime(metadata.ctime()),
            last_access_time: transform_to_filetime(metadata.atime()),
            last_write_time: transform_to_filetime(metadata.mtime()),
            change_time: transform_to_filetime(metadata.ctime()),
            file_attributes: attributes,
        }))
    } else if req_inner.file_info_class_lvl == FileInformationClassLevel::FILE_STANDARD_INFORMATION
    {
        Some(FileInformationClass::Standard(FileStandardInformation {
            allocation_size: i64::try_from(metadata.size()).unwrap_or(i64::MAX),
            end_of_file: i64::try_from(metadata.size()).unwrap_or(i64::MAX),
            number_of_links: u32::try_from(metadata.nlink()).unwrap_or(u32::MAX),
            delete_pending: if backend.delete_pending.contains(&handle.relative_path) {
                Boolean::True
            } else {
                Boolean::False
            },
            directory: if metadata.is_dir() {
                Boolean::True
            } else {
                Boolean::False
            },
        }))
    } else if req_inner.file_info_class_lvl
        == FileInformationClassLevel::FILE_ATTRIBUTE_TAG_INFORMATION
    {
        Some(FileInformationClass::AttributeTag(
            FileAttributeTagInformation {
                file_attributes: attributes,
                reparse_tag: 0,
            },
        ))
    } else {
        return query_information_response(request, NtStatus::NOT_SUPPORTED, None);
    };
    query_information_response(request, NtStatus::SUCCESS, buffer)
}

fn query_information_response(
    request: DeviceIoRequest,
    status: NtStatus,
    buffer: Option<FileInformationClass>,
) -> PduResult<Vec<SvcMessage>> {
    Ok(vec![SvcMessage::from(
        RdpdrPdu::ClientDriveQueryInformationResponse(ClientDriveQueryInformationResponse {
            device_io_response: DeviceIoResponse::new(request, status),
            buffer,
        }),
    )])
}

pub(crate) fn query_volume_information(
    backend: &mut NixRdpdrBackend,
    req_inner: ServerDriveQueryVolumeInformationRequest,
) -> PduResult<Vec<SvcMessage>> {
    let request = req_inner.device_io_request;
    let Some(handle) = backend.handles.get(&request.file_id) else {
        return query_volume_response(request, NtStatus::NO_SUCH_FILE, None);
    };
    let statvfs = match nix::sys::statvfs::fstatvfs(handle.file.as_fd()) {
        Ok(value) => value,
        Err(error) => {
            return query_volume_response(request, io_error_status(&errno_to_io(error)), None);
        }
    };

    let buffer = if req_inner.fs_info_class_lvl
        == FileSystemInformationClassLevel::FILE_FS_FULL_SIZE_INFORMATION
    {
        Some(FileSystemInformationClass::FileFsFullSizeInformation(
            FileFsFullSizeInformation {
                total_alloc_units: i64::try_from(statvfs.blocks()).unwrap_or(i64::MAX),
                caller_available_alloc_units: i64::try_from(statvfs.blocks_available())
                    .unwrap_or(i64::MAX),
                actual_available_alloc_units: i64::try_from(statvfs.blocks_available())
                    .unwrap_or(i64::MAX),
                sectors_per_alloc_unit: u32::try_from(statvfs.fragment_size()).unwrap_or(u32::MAX),
                bytes_per_sector: 1,
            },
        ))
    } else if req_inner.fs_info_class_lvl
        == FileSystemInformationClassLevel::FILE_FS_ATTRIBUTE_INFORMATION
    {
        Some(FileSystemInformationClass::FileFsAttributeInformation(
            FileFsAttributeInformation {
                file_system_attributes: FileSystemAttributes::FILE_CASE_SENSITIVE_SEARCH
                    | FileSystemAttributes::FILE_CASE_PRESERVED_NAMES
                    | FileSystemAttributes::FILE_UNICODE_ON_DISK,
                max_component_name_len: 255,
                file_system_name: "POSIX".to_owned(),
            },
        ))
    } else if req_inner.fs_info_class_lvl
        == FileSystemInformationClassLevel::FILE_FS_VOLUME_INFORMATION
    {
        let metadata = match handle.file.metadata() {
            Ok(metadata) => metadata,
            Err(error) => return query_volume_response(request, io_error_status(&error), None),
        };
        Some(FileSystemInformationClass::FileFsVolumeInformation(
            FileFsVolumeInformation {
                volume_creation_time: transform_to_filetime(metadata.ctime()),
                volume_serial_number: u32::try_from(statvfs.blocks_available()).unwrap_or(u32::MAX),
                supports_objects: Boolean::False,
                volume_label: "STACIO".to_owned(),
            },
        ))
    } else if req_inner.fs_info_class_lvl
        == FileSystemInformationClassLevel::FILE_FS_SIZE_INFORMATION
    {
        Some(FileSystemInformationClass::FileFsSizeInformation(
            FileFsSizeInformation {
                total_alloc_units: i64::try_from(statvfs.blocks()).unwrap_or(i64::MAX),
                available_alloc_units: i64::try_from(statvfs.blocks_free()).unwrap_or(i64::MAX),
                sectors_per_alloc_unit: u32::try_from(statvfs.fragment_size()).unwrap_or(u32::MAX),
                bytes_per_sector: 1,
            },
        ))
    } else {
        return query_volume_response(request, NtStatus::NOT_SUPPORTED, None);
    };
    query_volume_response(request, NtStatus::SUCCESS, buffer)
}

fn query_volume_response(
    request: DeviceIoRequest,
    status: NtStatus,
    buffer: Option<FileSystemInformationClass>,
) -> PduResult<Vec<SvcMessage>> {
    Ok(vec![SvcMessage::from(
        RdpdrPdu::ClientDriveQueryVolumeInformationResponse(
            ClientDriveQueryVolumeInformationResponse {
                device_io_reply: DeviceIoResponse::new(request, status),
                buffer,
            },
        ),
    )])
}

pub(crate) fn set_information(
    backend: &mut NixRdpdrBackend,
    req_inner: ServerDriveSetInformationRequest,
) -> PduResult<Vec<SvcMessage>> {
    let file_id = req_inner.device_io_request.file_id;
    let Some(handle) = backend.handles.get(&file_id) else {
        return set_information_response(&req_inner, NtStatus::NO_SUCH_FILE);
    };
    let source_path = handle.relative_path.clone();
    let is_directory = handle.is_directory;
    let can_write = access_writes(&handle.desired_access);
    let can_delete = access_deletes(&handle.desired_access);

    let status = match &req_inner.set_buffer {
        FileInformationClass::Rename(info) => {
            if !can_delete || source_path.as_os_str().is_empty() {
                NtStatus::ACCESS_DENIED
            } else {
                rename_handle(backend, file_id, &source_path, info)
            }
        }
        FileInformationClass::Disposition(info) => {
            if !can_delete || source_path.as_os_str().is_empty() {
                NtStatus::ACCESS_DENIED
            } else if info.delete_pending == 0 {
                backend.delete_pending.remove(&source_path);
                NtStatus::SUCCESS
            } else {
                match backend.verify_handle_path_identity(file_id) {
                    Ok(()) => {
                        backend.delete_pending.insert(source_path);
                        NtStatus::SUCCESS
                    }
                    Err(error) => io_error_status(&error),
                }
            }
        }
        FileInformationClass::EndOfFile(info) => {
            if !can_write || is_directory {
                NtStatus::ACCESS_DENIED
            } else if info.end_of_file < 0 {
                NtStatus::from(STATUS_INVALID_PARAMETER)
            } else {
                match backend
                    .handles
                    .get(&file_id)
                    .expect("handle exists")
                    .file
                    .set_len(info.end_of_file as u64)
                {
                    Ok(()) => NtStatus::SUCCESS,
                    Err(error) => io_error_status(&error),
                }
            }
        }
        FileInformationClass::Allocation(info) => {
            if !can_write || is_directory {
                NtStatus::ACCESS_DENIED
            } else if info.allocation_size < 0 {
                NtStatus::from(STATUS_INVALID_PARAMETER)
            } else {
                let file = &backend.handles.get(&file_id).expect("handle exists").file;
                match file.metadata() {
                    Ok(metadata) if info.allocation_size as u64 >= metadata.len() => {
                        NtStatus::SUCCESS
                    }
                    Ok(_) => match file.set_len(info.allocation_size as u64) {
                        Ok(()) => NtStatus::SUCCESS,
                        Err(error) => io_error_status(&error),
                    },
                    Err(error) => io_error_status(&error),
                }
            }
        }
        FileInformationClass::Basic(_) => NtStatus::NOT_SUPPORTED,
        _ => NtStatus::NOT_SUPPORTED,
    };
    set_information_response(&req_inner, status)
}

fn rename_handle(
    backend: &mut NixRdpdrBackend,
    file_id: u32,
    source_path: &Path,
    info: &FileRenameInformation,
) -> NtStatus {
    let target_path = match backend.normalize_remote_path(&info.file_name) {
        Ok(path) if !path.as_os_str().is_empty() => path,
        Ok(_) => return NtStatus::ACCESS_DENIED,
        Err(error) => return io_error_status(&error),
    };
    if backend.path_is_delete_pending(&target_path) {
        return NtStatus::from(STATUS_DELETE_PENDING);
    }
    if let Err(error) = backend.verify_handle_path_identity(file_id) {
        return io_error_status(&error);
    }
    if backend.handles.iter().any(|(other_id, handle)| {
        *other_id != file_id
            && handle.relative_path == target_path
            && !handle
                .shared_access
                .contains(SharedAccess::FILE_SHARE_DELETE)
    }) {
        return NtStatus::from(STATUS_SHARING_VIOLATION);
    }

    let (source_parent, source_name) = match backend.open_parent(source_path) {
        Ok(value) => value,
        Err(error) => return io_error_status(&error),
    };
    let (target_parent, target_name) = match backend.open_parent(&target_path) {
        Ok(value) => value,
        Err(error) => return io_error_status(&error),
    };
    let rename_result = if info.replace_if_exists == Boolean::True {
        renameat(&source_parent, source_name, &target_parent, target_name).map_err(errno_to_io)
    } else {
        rename_noreplace(&source_parent, source_name, &target_parent, target_name)
    };
    match rename_result {
        Ok(()) => {
            backend.update_paths_after_rename(source_path, &target_path);
            NtStatus::SUCCESS
        }
        Err(error) => io_error_status(&error),
    }
}

#[cfg(target_os = "macos")]
fn rename_noreplace(
    source_parent: &std::fs::File,
    source_name: &OsStr,
    target_parent: &std::fs::File,
    target_name: &OsStr,
) -> std::io::Result<()> {
    let source = CString::new(source_name.as_bytes())
        .map_err(|_| path_access_denied("RDPDR source name contains a NUL byte"))?;
    let target = CString::new(target_name.as_bytes())
        .map_err(|_| path_access_denied("RDPDR target name contains a NUL byte"))?;
    let result = unsafe {
        nix::libc::renameatx_np(
            source_parent.as_raw_fd(),
            source.as_ptr(),
            target_parent.as_raw_fd(),
            target.as_ptr(),
            nix::libc::RENAME_EXCL,
        )
    };
    if result == 0 {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error())
    }
}

#[cfg(target_os = "linux")]
fn rename_noreplace(
    source_parent: &std::fs::File,
    source_name: &OsStr,
    target_parent: &std::fs::File,
    target_name: &OsStr,
) -> std::io::Result<()> {
    use nix::fcntl::{RenameFlags, renameat2};
    renameat2(
        source_parent,
        source_name,
        target_parent,
        target_name,
        RenameFlags::RENAME_NOREPLACE,
    )
    .map_err(errno_to_io)
}

fn set_information_response(
    request: &ServerDriveSetInformationRequest,
    status: NtStatus,
) -> PduResult<Vec<SvcMessage>> {
    Ok(vec![SvcMessage::from(
        RdpdrPdu::ClientDriveSetInformationResponse(
            ClientDriveSetInformationResponse::new(request, status)
                .map_err(|error| encode_err!(error))?,
        ),
    )])
}

pub(crate) fn transform_to_filetime(time_in_secs: i64) -> i64 {
    time_in_secs
        .saturating_mul(10_000_000)
        .saturating_add(116_444_736_000_000_000)
}

pub(crate) fn get_file_attributes(meta: &std::fs::Metadata, file_name: &str) -> FileAttributes {
    let mut attributes = if meta.is_dir() {
        FileAttributes::FILE_ATTRIBUTE_DIRECTORY
    } else {
        FileAttributes::FILE_ATTRIBUTE_ARCHIVE
    };
    if file_name.len() > 1 && file_name.starts_with('.') && !file_name.starts_with("..") {
        attributes |= FileAttributes::FILE_ATTRIBUTE_HIDDEN;
    }
    if meta.permissions().readonly() {
        attributes |= FileAttributes::FILE_ATTRIBUTE_READONLY;
    }
    attributes
}

fn attributes_from_stat(stat: &FileStat, file_name: &str) -> FileAttributes {
    let file_type = SFlag::from_bits_truncate(stat.st_mode);
    let mut attributes = if file_type.contains(SFlag::S_IFDIR) {
        FileAttributes::FILE_ATTRIBUTE_DIRECTORY
    } else {
        FileAttributes::FILE_ATTRIBUTE_ARCHIVE
    };
    if file_name.len() > 1 && file_name.starts_with('.') && !file_name.starts_with("..") {
        attributes |= FileAttributes::FILE_ATTRIBUTE_HIDDEN;
    }
    if stat.st_mode & 0o222 == 0 {
        attributes |= FileAttributes::FILE_ATTRIBUTE_READONLY;
    }
    attributes
}

fn directory_entry_from_stat(name: String, stat: &FileStat) -> DirectoryEntryInfo {
    DirectoryEntryInfo {
        attributes: attributes_from_stat(stat, &name),
        name,
        creation_time: transform_to_filetime(stat.st_ctime as i64),
        last_access_time: transform_to_filetime(stat.st_atime as i64),
        last_write_time: transform_to_filetime(stat.st_mtime as i64),
        change_time: transform_to_filetime(stat.st_ctime as i64),
        size: (stat.st_size as i64).max(0),
    }
}

fn directory_information(
    entry: DirectoryEntryInfo,
    file_class: &FileInformationClassLevel,
) -> Option<FileInformationClass> {
    if *file_class == FileInformationClassLevel::FILE_BOTH_DIRECTORY_INFORMATION {
        Some(FileInformationClass::BothDirectory(
            FileBothDirectoryInformation::new(
                entry.creation_time,
                entry.last_access_time,
                entry.last_write_time,
                entry.change_time,
                entry.size,
                entry.attributes,
                entry.name,
            ),
        ))
    } else if *file_class == FileInformationClassLevel::FILE_FULL_DIRECTORY_INFORMATION {
        Some(FileInformationClass::FullDirectory(
            FileFullDirectoryInformation::new(
                entry.creation_time,
                entry.last_access_time,
                entry.last_write_time,
                entry.change_time,
                entry.size,
                entry.attributes,
                entry.name,
            ),
        ))
    } else if *file_class == FileInformationClassLevel::FILE_DIRECTORY_INFORMATION {
        Some(FileInformationClass::Directory(
            FileDirectoryInformation::new(
                entry.creation_time,
                entry.last_access_time,
                entry.last_write_time,
                entry.change_time,
                entry.size,
                entry.attributes,
                entry.name,
            ),
        ))
    } else if *file_class == FileInformationClassLevel::FILE_NAMES_INFORMATION {
        Some(FileInformationClass::Names(FileNamesInformation::new(
            entry.name,
        )))
    } else {
        None
    }
}

fn query_directory_response(
    request: DeviceIoRequest,
    status: NtStatus,
    buffer: Option<FileInformationClass>,
) -> PduResult<Vec<SvcMessage>> {
    Ok(vec![SvcMessage::from(
        RdpdrPdu::ClientDriveQueryDirectoryResponse(ClientDriveQueryDirectoryResponse {
            device_io_reply: DeviceIoResponse::new(request, status),
            buffer,
        }),
    )])
}

pub(crate) fn query_directory(
    backend: &mut NixRdpdrBackend,
    req_inner: ServerDriveQueryDirectoryRequest,
) -> PduResult<Vec<SvcMessage>> {
    let request = req_inner.device_io_request;
    let Some(handle) = backend.handles.get(&request.file_id) else {
        return query_directory_response(request, NtStatus::NO_SUCH_FILE, None);
    };
    if !handle.is_directory {
        return query_directory_response(request, NtStatus::NOT_A_DIRECTORY, None);
    }

    let entry = if req_inner.initial_query > 0 {
        let mut state = match build_directory_query_state(backend, handle, &req_inner.path) {
            Ok(state) => state,
            Err(error) => {
                return query_directory_response(request, io_error_status(&error), None);
            }
        };
        let first = state.entries.pop_front();
        backend.directory_queries.insert(request.file_id, state);
        first
    } else {
        backend
            .directory_queries
            .get_mut(&request.file_id)
            .and_then(|state| state.entries.pop_front())
    };

    match entry {
        Some(entry) => match directory_information(entry, &req_inner.file_info_class_lvl) {
            Some(buffer) => query_directory_response(request, NtStatus::SUCCESS, Some(buffer)),
            None => query_directory_response(request, NtStatus::NOT_SUPPORTED, None),
        },
        None => query_directory_response(
            request,
            if req_inner.initial_query > 0 {
                NtStatus::NO_SUCH_FILE
            } else {
                NtStatus::NO_MORE_FILES
            },
            None,
        ),
    }
}

fn build_directory_query_state(
    backend: &NixRdpdrBackend,
    handle: &OpenHandle,
    raw_query_path: &str,
) -> std::io::Result<DirectoryQueryState> {
    let normalized = backend.normalize_remote_path(raw_query_path)?;
    let trailing_separator = raw_query_path.ends_with('\\') || raw_query_path.ends_with('/');
    let (parent_path, pattern) = if normalized.as_os_str().is_empty() {
        (handle.relative_path.clone(), "*".to_owned())
    } else if trailing_separator {
        (normalized, "*".to_owned())
    } else {
        let pattern = normalized
            .file_name()
            .and_then(OsStr::to_str)
            .ok_or_else(|| path_access_denied("RDPDR query pattern is not valid UTF-8"))?
            .to_owned();
        (
            normalized
                .parent()
                .unwrap_or_else(|| Path::new(""))
                .to_path_buf(),
            pattern,
        )
    };
    let parent = backend.open_directory(&parent_path)?;
    let mut entries = Vec::new();

    if pattern.contains('*') || pattern.contains('?') {
        let directory = Dir::openat(
            &parent,
            Path::new("."),
            OFlag::O_RDONLY | OFlag::O_DIRECTORY | OFlag::O_CLOEXEC,
            Mode::empty(),
        )
        .map_err(errno_to_io)?;
        for result in directory.into_iter() {
            let entry = result.map_err(errno_to_io)?;
            let name_bytes = entry.file_name().to_bytes();
            if name_bytes == b"." || name_bytes == b".." {
                continue;
            }
            let name = String::from_utf8_lossy(name_bytes).into_owned();
            if !windows_wildcard_match(&pattern, &name) {
                continue;
            }
            let stat = fstatat(&parent, entry.file_name(), AtFlags::AT_SYMLINK_NOFOLLOW)
                .map_err(errno_to_io)?;
            entries.push(directory_entry_from_stat(name, &stat));
        }
    } else {
        let name = OsStr::new(&pattern);
        let stat = fstatat(&parent, name, AtFlags::AT_SYMLINK_NOFOLLOW).map_err(errno_to_io)?;
        entries.push(directory_entry_from_stat(pattern, &stat));
    }

    entries.sort_by(|left, right| left.name.to_lowercase().cmp(&right.name.to_lowercase()));
    Ok(DirectoryQueryState {
        entries: entries.into(),
    })
}

fn windows_wildcard_match(pattern: &str, name: &str) -> bool {
    let normalized_pattern = if pattern == "*.*" { "*" } else { pattern };
    let pattern_chars: Vec<char> = normalized_pattern.to_lowercase().chars().collect();
    let name_chars: Vec<char> = name.to_lowercase().chars().collect();
    let mut memo = vec![vec![None; name_chars.len() + 1]; pattern_chars.len() + 1];

    fn matches(
        pattern: &[char],
        name: &[char],
        pattern_index: usize,
        name_index: usize,
        memo: &mut [Vec<Option<bool>>],
    ) -> bool {
        if let Some(value) = memo[pattern_index][name_index] {
            return value;
        }
        let value = if pattern_index == pattern.len() {
            name_index == name.len()
        } else if pattern[pattern_index] == '*' {
            matches(pattern, name, pattern_index + 1, name_index, memo)
                || (name_index < name.len()
                    && matches(pattern, name, pattern_index, name_index + 1, memo))
        } else if name_index < name.len()
            && (pattern[pattern_index] == '?' || pattern[pattern_index] == name[name_index])
        {
            matches(pattern, name, pattern_index + 1, name_index + 1, memo)
        } else {
            false
        };
        memo[pattern_index][name_index] = Some(value);
        value
    }

    matches(&pattern_chars, &name_chars, 0, 0, &mut memo)
}

fn create_drive_response(
    request: DeviceIoRequest,
    status: NtStatus,
    file_id: u32,
    information: Information,
) -> PduResult<Vec<SvcMessage>> {
    Ok(vec![SvcMessage::from(RdpdrPdu::DeviceCreateResponse(
        DeviceCreateResponse {
            device_io_reply: DeviceIoResponse::new(request, status),
            file_id,
            information,
        },
    ))])
}

fn create_information(disposition: CreateDisposition, existed: bool) -> Information {
    if !existed {
        Information::from_bits_retain(2)
    } else if disposition == CreateDisposition::FILE_OVERWRITE
        || disposition == CreateDisposition::FILE_OVERWRITE_IF
    {
        Information::FILE_OVERWRITTEN
    } else if disposition == CreateDisposition::FILE_SUPERSEDE {
        Information::FILE_SUPERSEDED
    } else {
        Information::FILE_OPENED
    }
}

pub(crate) fn create_drive(
    backend: &mut NixRdpdrBackend,
    req_inner: DeviceCreateRequest,
) -> PduResult<Vec<SvcMessage>> {
    let request = req_inner.device_io_request.clone();
    let path = match backend.normalize_remote_path(&req_inner.path) {
        Ok(path) => path,
        Err(error) => {
            return create_drive_response(
                request,
                io_error_status(&error),
                0,
                Information::empty(),
            );
        }
    };
    if backend.path_is_delete_pending(&path) {
        return create_drive_response(
            request,
            NtStatus::from(STATUS_DELETE_PENDING),
            0,
            Information::empty(),
        );
    }
    if req_inner
        .create_options
        .contains(CreateOptions::FILE_DELETE_ON_CLOSE)
        && !access_deletes(&req_inner.desired_access)
    {
        return create_drive_response(request, NtStatus::ACCESS_DENIED, 0, Information::empty());
    }
    if matches!(
        req_inner.create_disposition,
        CreateDisposition::FILE_SUPERSEDE
            | CreateDisposition::FILE_OVERWRITE
            | CreateDisposition::FILE_OVERWRITE_IF
    ) && !access_writes(&req_inner.desired_access)
    {
        return create_drive_response(request, NtStatus::ACCESS_DENIED, 0, Information::empty());
    }

    let existing = match backend.lstat_relative(&path) {
        Ok(entry) => Some(entry),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
        Err(error) => {
            return create_drive_response(
                request,
                io_error_status(&error),
                0,
                Information::empty(),
            );
        }
    };
    if existing.is_some()
        && backend.has_share_conflict(
            &path,
            &req_inner.desired_access,
            &req_inner.shared_access,
            None,
        )
    {
        return create_drive_response(
            request,
            NtStatus::from(STATUS_SHARING_VIOLATION),
            0,
            Information::empty(),
        );
    }

    let wants_directory = req_inner
        .create_options
        .contains(CreateOptions::FILE_DIRECTORY_FILE);
    let forbids_directory = req_inner
        .create_options
        .contains(CreateOptions::FILE_NON_DIRECTORY_FILE);
    if existing.is_some_and(|entry| entry.kind == PathKind::Symlink) {
        return create_drive_response(request, NtStatus::ACCESS_DENIED, 0, Information::empty());
    }
    if wants_directory {
        create_directory_handle(backend, request, path, existing, req_inner)
    } else {
        if existing.is_some_and(|entry| entry.kind == PathKind::Directory)
            || (!forbids_directory && path.as_os_str().is_empty())
        {
            return create_drive_response(
                request,
                NtStatus::from(STATUS_FILE_IS_A_DIRECTORY),
                0,
                Information::empty(),
            );
        }
        create_file_handle(backend, request, path, existing, req_inner)
    }
}

fn create_directory_handle(
    backend: &mut NixRdpdrBackend,
    request: DeviceIoRequest,
    path: PathBuf,
    existing: Option<PathEntry>,
    req_inner: DeviceCreateRequest,
) -> PduResult<Vec<SvcMessage>> {
    if existing.is_some_and(|entry| entry.kind != PathKind::Directory) {
        return create_drive_response(request, NtStatus::NOT_A_DIRECTORY, 0, Information::empty());
    }
    let existed = match req_inner.create_disposition {
        disposition if disposition == CreateDisposition::FILE_OPEN => {
            if existing.is_none() {
                return create_drive_response(
                    request,
                    NtStatus::NO_SUCH_FILE,
                    0,
                    Information::empty(),
                );
            }
            true
        }
        disposition if disposition == CreateDisposition::FILE_CREATE => {
            if existing.is_some() || path.as_os_str().is_empty() {
                return create_drive_response(
                    request,
                    NtStatus::OBJECT_NAME_COLLISION,
                    0,
                    Information::empty(),
                );
            }
            let (parent, name) = match backend.open_parent(&path) {
                Ok(value) => value,
                Err(error) => {
                    return create_drive_response(
                        request,
                        io_error_status(&error),
                        0,
                        Information::empty(),
                    );
                }
            };
            if let Err(error) = mkdirat(&parent, name, Mode::from_bits_truncate(0o755)) {
                return create_drive_response(
                    request,
                    io_error_status(&errno_to_io(error)),
                    0,
                    Information::empty(),
                );
            }
            false
        }
        disposition if disposition == CreateDisposition::FILE_OPEN_IF => {
            if existing.is_some() || path.as_os_str().is_empty() {
                true
            } else {
                let (parent, name) = match backend.open_parent(&path) {
                    Ok(value) => value,
                    Err(error) => {
                        return create_drive_response(
                            request,
                            io_error_status(&error),
                            0,
                            Information::empty(),
                        );
                    }
                };
                match mkdirat(&parent, name, Mode::from_bits_truncate(0o755)) {
                    Ok(()) => false,
                    Err(nix::errno::Errno::EEXIST) => true,
                    Err(error) => {
                        return create_drive_response(
                            request,
                            io_error_status(&errno_to_io(error)),
                            0,
                            Information::empty(),
                        );
                    }
                }
            }
        }
        _ => {
            return create_drive_response(
                request,
                NtStatus::from(STATUS_INVALID_PARAMETER),
                0,
                Information::empty(),
            );
        }
    };

    let file = match backend.open_directory(&path) {
        Ok(file) => file,
        Err(error) => {
            return create_drive_response(
                request,
                io_error_status(&error),
                0,
                Information::empty(),
            );
        }
    };
    finish_create_handle(backend, request, path, file, true, existed, req_inner)
}

fn create_file_handle(
    backend: &mut NixRdpdrBackend,
    request: DeviceIoRequest,
    path: PathBuf,
    existing: Option<PathEntry>,
    req_inner: DeviceCreateRequest,
) -> PduResult<Vec<SvcMessage>> {
    if existing.is_some_and(|entry| entry.kind != PathKind::File) {
        return create_drive_response(request, NtStatus::ACCESS_DENIED, 0, Information::empty());
    }
    let mode = Mode::from_bits_truncate(0o644);
    let disposition = req_inner.create_disposition;
    let (file, existed) = if disposition == CreateDisposition::FILE_CREATE {
        if existing.is_some() {
            return create_drive_response(
                request,
                NtStatus::OBJECT_NAME_COLLISION,
                0,
                Information::empty(),
            );
        }
        match backend.open_relative(
            &path,
            access_open_flags(&req_inner.desired_access, false) | OFlag::O_CREAT | OFlag::O_EXCL,
            mode,
        ) {
            Ok(file) => (file, false),
            Err(error) => {
                return create_drive_response(
                    request,
                    io_error_status(&error),
                    0,
                    Information::empty(),
                );
            }
        }
    } else if disposition == CreateDisposition::FILE_OPEN {
        if existing.is_none() {
            return create_drive_response(request, NtStatus::NO_SUCH_FILE, 0, Information::empty());
        }
        match backend.open_relative(
            &path,
            access_open_flags(&req_inner.desired_access, false),
            Mode::empty(),
        ) {
            Ok(file) => (file, true),
            Err(error) => {
                return create_drive_response(
                    request,
                    io_error_status(&error),
                    0,
                    Information::empty(),
                );
            }
        }
    } else if disposition == CreateDisposition::FILE_OVERWRITE {
        if existing.is_none() {
            return create_drive_response(request, NtStatus::NO_SUCH_FILE, 0, Information::empty());
        }
        match backend.open_relative(
            &path,
            access_open_flags(&req_inner.desired_access, true) | OFlag::O_TRUNC,
            Mode::empty(),
        ) {
            Ok(file) => (file, true),
            Err(error) => {
                return create_drive_response(
                    request,
                    io_error_status(&error),
                    0,
                    Information::empty(),
                );
            }
        }
    } else if disposition == CreateDisposition::FILE_OPEN_IF
        || disposition == CreateDisposition::FILE_OVERWRITE_IF
        || disposition == CreateDisposition::FILE_SUPERSEDE
    {
        let force_write = disposition != CreateDisposition::FILE_OPEN_IF;
        match backend.open_relative(
            &path,
            access_open_flags(&req_inner.desired_access, force_write)
                | OFlag::O_CREAT
                | OFlag::O_EXCL,
            mode,
        ) {
            Ok(file) => (file, false),
            Err(error) if error.raw_os_error() == Some(nix::libc::EEXIST) => {
                let entry = match backend.lstat_relative(&path) {
                    Ok(entry) if entry.kind == PathKind::File => entry,
                    Ok(_) => {
                        return create_drive_response(
                            request,
                            NtStatus::ACCESS_DENIED,
                            0,
                            Information::empty(),
                        );
                    }
                    Err(error) => {
                        return create_drive_response(
                            request,
                            io_error_status(&error),
                            0,
                            Information::empty(),
                        );
                    }
                };
                let _ = entry;
                if backend.has_share_conflict(
                    &path,
                    &req_inner.desired_access,
                    &req_inner.shared_access,
                    None,
                ) {
                    return create_drive_response(
                        request,
                        NtStatus::from(STATUS_SHARING_VIOLATION),
                        0,
                        Information::empty(),
                    );
                }
                let truncate = disposition != CreateDisposition::FILE_OPEN_IF;
                match backend.open_relative(
                    &path,
                    access_open_flags(&req_inner.desired_access, truncate)
                        | if truncate {
                            OFlag::O_TRUNC
                        } else {
                            OFlag::empty()
                        },
                    Mode::empty(),
                ) {
                    Ok(file) => (file, true),
                    Err(error) => {
                        return create_drive_response(
                            request,
                            io_error_status(&error),
                            0,
                            Information::empty(),
                        );
                    }
                }
            }
            Err(error) => {
                return create_drive_response(
                    request,
                    io_error_status(&error),
                    0,
                    Information::empty(),
                );
            }
        }
    } else {
        return create_drive_response(
            request,
            NtStatus::from(STATUS_INVALID_PARAMETER),
            0,
            Information::empty(),
        );
    };

    if !existed && req_inner.allocation_size > 0 && access_writes(&req_inner.desired_access) {
        if let Err(error) = file.set_len(req_inner.allocation_size) {
            return create_drive_response(
                request,
                io_error_status(&error),
                0,
                Information::empty(),
            );
        }
    }
    finish_create_handle(backend, request, path, file, false, existed, req_inner)
}

fn finish_create_handle(
    backend: &mut NixRdpdrBackend,
    request: DeviceIoRequest,
    path: PathBuf,
    file: std::fs::File,
    is_directory: bool,
    existed: bool,
    req_inner: DeviceCreateRequest,
) -> PduResult<Vec<SvcMessage>> {
    let file_id = backend.next_file_id();
    let delete_on_close = req_inner
        .create_options
        .contains(CreateOptions::FILE_DELETE_ON_CLOSE);
    backend.handles.insert(
        file_id,
        OpenHandle {
            file,
            relative_path: path.clone(),
            desired_access: req_inner.desired_access,
            shared_access: req_inner.shared_access,
            is_directory,
        },
    );
    if delete_on_close {
        backend.delete_pending.insert(path);
    }
    create_drive_response(
        request,
        NtStatus::SUCCESS,
        file_id,
        create_information(req_inner.create_disposition, existed),
    )
}
