//! Embedded RDP client session built on IronRDP (pure-Rust RDP stack).
//!
//! The session renders the remote desktop in-process (no external xfreerdp
//! window) and exposes decoded RGBA frames plus pointer state to Swift through
//! a UniFFI callback interface, so the desktop can be embedded as an inline
//! tab / detachable window just like the SSH terminal.

use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

use ironrdp_client::rdp::{RdpClient, RdpInputEvent, RdpOutputEvent};
use ironrdp_cliprdr::backend::{ClipboardMessage, CliprdrBackend};
use ironrdp_cliprdr::pdu::{
    ClipboardFormat, ClipboardFormatId, ClipboardGeneralCapabilityFlags, FileContentsRequest,
    FileContentsResponse, FormatDataRequest, FormatDataResponse, LockDataId,
};
use ironrdp_core::{impl_as_any, IntoOwned as _};
use ironrdp_graphics::pointer::DecodedPointer;
use ironrdp_input::{Database, MouseButton, MousePosition, Operation, Scancode, WheelRotations};
use ironrdp_pdu::input::fast_path::FastPathInputEvent;
use ironrdp_pdu::rdp::client_info::PerformanceFlags;
use smallvec::SmallVec;
use tokio::runtime::Runtime;
use tokio::sync::mpsc;

const MAX_CLIPBOARD_TEXT_BYTES: usize = 1024 * 1024;
const MAX_POINTER_RGBA_BYTES: usize = 4 * 1024 * 1024;
const MAX_DESKTOP_DIMENSION: u32 = 8_192;
const MAX_DESKTOP_FRAME_BYTES: usize =
    MAX_DESKTOP_DIMENSION as usize * MAX_DESKTOP_DIMENSION as usize * 4;

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum RdpSecurityMode {
    Nla,
    Tls,
    Rdp,
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
enum RdpConfigurationError {
    #[error("legacy RDP security is unsupported; select NLA or TLS")]
    UnsupportedLegacySecurity,
    #[error("desktop dimensions must be between 1 and 8192: {width}x{height}")]
    InvalidDesktopSize { width: u32, height: u32 },
    #[error("drive name and local path must either both be provided or both be omitted")]
    IncompleteDriveConfiguration,
    #[error("drive name must contain only letters, digits, spaces, '.', '_' or '-'")]
    UnsafeDriveName,
    #[error("drive path does not exist: {0}")]
    DrivePathDoesNotExist(String),
    #[error("drive path is not a directory: {0}")]
    DrivePathIsNotDirectory(String),
    #[error("drive path cannot be canonicalized: {0}")]
    DrivePathCannotBeCanonicalized(String),
    #[cfg(not(feature = "rdpdr"))]
    #[error("drive redirection is unavailable in this build")]
    DriveRedirectionUnavailable,
    #[error("invalid IronRDP configuration: {0}")]
    InvalidClientConfiguration(String),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct SecurityPolicy {
    enable_credssp: bool,
    enable_tls: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct RdpTransportProfile {
    color_depth: u32,
    performance_flags: PerformanceFlags,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct ValidatedDrive {
    name: String,
    local_path: PathBuf,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct PointerBitmapPayload {
    width: u32,
    height: u32,
    hotspot_x: u32,
    hotspot_y: u32,
    rgba: Vec<u8>,
}

type RemoteClipboardCallback = Arc<dyn Fn(String) + Send + Sync + 'static>;

#[derive(Clone, Debug)]
struct ConnectionActivity {
    active: Arc<AtomicBool>,
}

impl ConnectionActivity {
    fn active() -> Self {
        Self {
            active: Arc::new(AtomicBool::new(true)),
        }
    }

    fn inactive() -> Self {
        Self {
            active: Arc::new(AtomicBool::new(false)),
        }
    }

    fn activate(&self) {
        self.active.store(true, Ordering::Release);
    }

    fn deactivate(&self) {
        self.active.store(false, Ordering::Release);
    }

    fn is_active(&self) -> bool {
        self.active.load(Ordering::Acquire)
    }
}

/// Callback surface implemented in Swift. Every method is invoked from a
/// background Tokio worker thread, so implementations must hop to the main
/// thread before touching AppKit.
#[uniffi::export(callback_interface)]
pub trait RdpSessionDelegate: Send + Sync {
    /// A dirty desktop rectangle in tightly packed opaque BGRA8888 format.
    fn on_frame(
        &self,
        desktop_width: u32,
        desktop_height: u32,
        x: u32,
        y: u32,
        width: u32,
        height: u32,
        bgra: Vec<u8>,
    );
    /// Remote cursor visibility changed.
    fn on_pointer_visibility(&self, visible: bool);
    /// Remote cursor moved (server-side pointer).
    fn on_pointer_position(&self, x: u32, y: u32);
    /// Remote cursor bitmap in tightly packed RGBA8888 format.
    fn on_pointer_bitmap(
        &self,
        width: u32,
        height: u32,
        hotspot_x: u32,
        hotspot_y: u32,
        rgba: Vec<u8>,
    );
    /// Remote clipboard text received through CLIPRDR.
    fn on_clipboard(&self, text: String);
    /// Server-measured network RTT reported through RDP Network Auto-Detect.
    fn on_network_status(&self, rtt_ms: u32, mode: String);
    /// The session ended (gracefully or via error). `reason` is user-facing.
    fn on_disconnected(&self, reason: String);
}

/// UniFFI object wrapping a live IronRDP client task.
#[derive(uniffi::Object)]
pub struct RdpSession {
    input: Arc<Mutex<Option<mpsc::UnboundedSender<RdpInputEvent>>>>,
    clipboard_text: Arc<Mutex<Option<String>>>,
    database: Mutex<Database>,
    transport_profile: Mutex<Option<RdpTransportProfile>>,
    forward_handle: Mutex<Option<tokio::task::JoinHandle<()>>>,
    active_connection: Mutex<Option<ConnectionActivity>>,
    lifecycle_lock: Mutex<()>,
    runtime: Arc<Runtime>,
}

fn shared_runtime() -> Arc<Runtime> {
    static RUNTIME: OnceLock<Arc<Runtime>> = OnceLock::new();
    RUNTIME
        .get_or_init(|| {
            Arc::new(
                tokio::runtime::Builder::new_multi_thread()
                    .worker_threads(2)
                    .enable_all()
                    .thread_name("stacio-rdp")
                    .build()
                    .expect("failed to build RDP tokio runtime"),
            )
        })
        .clone()
}

#[uniffi::export]
impl RdpSession {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            input: Arc::new(Mutex::new(None)),
            clipboard_text: Arc::new(Mutex::new(None)),
            database: Mutex::new(Database::new()),
            transport_profile: Mutex::new(None),
            forward_handle: Mutex::new(None),
            active_connection: Mutex::new(None),
            lifecycle_lock: Mutex::new(()),
            runtime: shared_runtime(),
        })
    }

    /// Start the connection. Returns immediately; progress is reported via `delegate`.
    pub fn connect(
        self: Arc<Self>,
        host: String,
        port: u16,
        username: String,
        password: String,
        domain: Option<String>,
        width: u16,
        height: u16,
        quality: u8,
        security: RdpSecurityMode,
        ignore_certificate: bool,
        drive_name: Option<String>,
        drive_path: Option<String>,
        delegate: Box<dyn RdpSessionDelegate>,
    ) {
        let delegate: Arc<dyn RdpSessionDelegate> = Arc::from(delegate);
        let drive = match validate_drive(drive_name, drive_path) {
            Ok(drive) => drive,
            Err(error) => {
                delegate.on_disconnected(format!("RDP 配置无效：{error}"));
                return;
            }
        };

        let activity = ConnectionActivity::inactive();
        let clipboard_input = Arc::new(Mutex::new(None));
        let clipboard_bridge =
            ClipboardMessageBridge::with_input(clipboard_input.clone(), activity.clone());
        let clipboard = ClipboardChannelConfiguration {
            state: self.clipboard_text.clone(),
            bridge: clipboard_bridge,
            callback: remote_clipboard_callback(activity.clone(), delegate.clone()),
        };
        let initial_transport_profile = transport_profile_for_quality(quality);
        let config = match build_config(
            host,
            port,
            username,
            password,
            domain,
            width,
            height,
            quality,
            security,
            ignore_certificate,
            Some(clipboard),
            drive,
        ) {
            Ok(config) => config,
            Err(error) => {
                delegate.on_disconnected(format!("RDP 配置无效：{error}"));
                return;
            }
        };

        // Image events are latest-only and coalesced in ironrdp-client. A
        // small channel bounds in-flight 4K buffers while leaving room for
        // pointer/network/lifecycle events.
        let (output_tx, output_rx) = mpsc::channel::<RdpOutputEvent>(4);
        let client = RdpClient::new(config, output_tx);
        let input_sender = client.input_sender();
        *clipboard_input.lock().unwrap() = Some(input_sender.clone());

        let _lifecycle = self.lifecycle_lock.lock().unwrap();
        self.stop_current_connection_locked();
        *self.database.lock().unwrap() = Database::new();
        *self.transport_profile.lock().unwrap() = Some(initial_transport_profile);
        *self.input.lock().unwrap() = Some(input_sender);
        activity.activate();
        *self.active_connection.lock().unwrap() = Some(activity.clone());

        // client.run()'s future is not Send across all of its await points, so
        // it must be driven on a dedicated single-threaded runtime.
        let connection_activity = activity.clone();
        std::thread::Builder::new()
            .name("stacio-rdp-conn".into())
            .spawn(move || {
                if !connection_activity.is_active() {
                    return;
                }
                let rt = tokio::runtime::Builder::new_current_thread()
                    .enable_all()
                    .build()
                    .expect("rdp conn runtime");
                let local = tokio::task::LocalSet::new();
                local.block_on(&rt, async move {
                    client.run().await;
                });
            })
            .expect("spawn rdp conn thread");

        // Forward output events to the Swift delegate on the shared runtime.
        let forward = self
            .runtime
            .spawn(forward_output_events(output_rx, delegate, activity));

        *self.forward_handle.lock().unwrap() = Some(forward);
    }

    /// Send pointer move/button state. `buttons` is a bitmask (bit0=left, bit1=right, bit2=middle).
    pub fn send_pointer(&self, x: u32, y: u32, buttons: u32) {
        let _lifecycle = self.lifecycle_lock.lock().unwrap();
        let mut db = self.database.lock().unwrap();
        let mut ops: Vec<Operation> = vec![Operation::MouseMove(MousePosition {
            x: x as u16,
            y: y as u16,
        })];
        sync_button(&mut ops, MouseButton::Left, buttons & 0b001 != 0, &db);
        sync_button(&mut ops, MouseButton::Right, buttons & 0b010 != 0, &db);
        sync_button(&mut ops, MouseButton::Middle, buttons & 0b100 != 0, &db);
        sync_button(&mut ops, MouseButton::X1, buttons & 0b1_000 != 0, &db);
        sync_button(&mut ops, MouseButton::X2, buttons & 0b10_000 != 0, &db);
        let events = db.apply(ops);
        self.dispatch_locked(events);
    }

    /// Send a scroll event. `delta` positive = up/right, negative = down/left.
    pub fn send_scroll(&self, delta: i32, horizontal: bool) {
        let _lifecycle = self.lifecycle_lock.lock().unwrap();
        let mut db = self.database.lock().unwrap();
        let events = db.apply([Operation::WheelRotations(WheelRotations {
            is_vertical: !horizontal,
            rotation_units: delta.clamp(-255, 255) as i16,
        })]);
        self.dispatch_locked(events);
    }

    /// Apply a real RDP graphics profile. IronRDP reconnects the transport so
    /// the new color depth and performance flags are negotiated with Windows.
    pub fn set_quality(&self, quality: u8) {
        let profile = transport_profile_for_quality(quality);
        let _lifecycle = self.lifecycle_lock.lock().unwrap();
        let mut current = self.transport_profile.lock().unwrap();
        if current.as_ref() == Some(&profile) {
            return;
        }
        if let Some(sender) = self.input.lock().unwrap().as_ref() {
            if sender
                .send(RdpInputEvent::GraphicsProfile {
                    color_depth: profile.color_depth,
                    performance_flags: profile.performance_flags,
                })
                .is_ok()
            {
                *current = Some(profile);
            }
        }
    }

    /// Send a key event by Windows scancode. `down` true = press, false = release.
    pub fn send_key(&self, scancode: u32, down: bool) {
        let _lifecycle = self.lifecycle_lock.lock().unwrap();
        let mut db = self.database.lock().unwrap();
        let sc = Scancode::from_u16(scancode as u16);
        let op = if down {
            Operation::KeyPressed(sc)
        } else {
            Operation::KeyReleased(sc)
        };
        let events = db.apply([op]);
        self.dispatch_locked(events);
    }

    /// Send a Unicode character (for text input).
    pub fn send_unicode(&self, character: String, down: bool) {
        let Some(ch) = character.chars().next() else {
            return;
        };
        let _lifecycle = self.lifecycle_lock.lock().unwrap();
        let mut db = self.database.lock().unwrap();
        let op = if down {
            Operation::UnicodeKeyPressed(ch)
        } else {
            Operation::UnicodeKeyReleased(ch)
        };
        let events = db.apply([op]);
        self.dispatch_locked(events);
    }

    /// Advertise bounded Unicode text on the local clipboard through CLIPRDR.
    pub fn send_clipboard_text(&self, text: String) {
        if !clipboard_text_fits(&text) {
            return;
        }
        let _lifecycle = self.lifecycle_lock.lock().unwrap();
        *self.clipboard_text.lock().unwrap() = Some(text);
        if let Some(sender) = self.input.lock().unwrap().as_ref() {
            let _ = sender.send(RdpInputEvent::Clipboard(
                ClipboardMessage::SendInitiateCopy(unicode_text_formats()),
            ));
        }
    }

    /// Ask the server to resize the desktop (Display Control channel).
    pub fn request_resize(&self, width: u32, height: u32) {
        let Ok((width, height)) = validate_desktop_size(width, height) else {
            return;
        };
        let _lifecycle = self.lifecycle_lock.lock().unwrap();
        if let Some(sender) = self.input.lock().unwrap().as_ref() {
            let _ = sender.send(RdpInputEvent::Resize {
                width,
                height,
                scale_factor: 100,
                physical_size: None,
            });
        }
    }

    /// Terminate the session.
    pub fn close(&self) {
        let _lifecycle = self.lifecycle_lock.lock().unwrap();
        self.stop_current_connection_locked();
        *self.database.lock().unwrap() = Database::new();
    }
}

impl RdpSession {
    fn stop_current_connection_locked(&self) {
        if let Some(activity) = self.active_connection.lock().unwrap().take() {
            activity.deactivate();
        }
        if let Some(sender) = self.input.lock().unwrap().take() {
            let _ = sender.send(RdpInputEvent::Close);
        }
        if let Some(handle) = self.forward_handle.lock().unwrap().take() {
            handle.abort();
        }
        *self.transport_profile.lock().unwrap() = None;
    }

    fn dispatch_locked(&self, events: SmallVec<[FastPathInputEvent; 2]>) {
        if events.is_empty() {
            return;
        }
        if let Some(sender) = self.input.lock().unwrap().as_ref() {
            let _ = sender.send(RdpInputEvent::FastPath(events));
        }
    }
}

impl Drop for RdpSession {
    fn drop(&mut self) {
        if let Some(activity) = self.active_connection.get_mut().unwrap().take() {
            activity.deactivate();
        }
        if let Some(sender) = self.input.lock().unwrap().take() {
            let _ = sender.send(RdpInputEvent::Close);
        }
        if let Some(handle) = self.forward_handle.get_mut().unwrap().take() {
            handle.abort();
        }
        *self.transport_profile.get_mut().unwrap() = None;
    }
}

async fn forward_output_events(
    mut output_rx: mpsc::Receiver<RdpOutputEvent>,
    delegate: Arc<dyn RdpSessionDelegate>,
    activity: ConnectionActivity,
) {
    while let Some(event) = output_rx.recv().await {
        if !activity.is_active() {
            break;
        }
        match event {
            RdpOutputEvent::Image {
                buffer,
                x,
                y,
                width,
                height,
                desktop_width,
                desktop_height,
            } => {
                let desktop_width = u32::from(desktop_width.get());
                let desktop_height = u32::from(desktop_height.get());
                let x = u32::from(x);
                let y = u32::from(y);
                let width = u32::from(width.get());
                let height = u32::from(height.get());
                if let Some(bgra) =
                    bgra_region_bytes(buffer, desktop_width, desktop_height, x, y, width, height)
                {
                    delegate.on_frame(desktop_width, desktop_height, x, y, width, height, bgra);
                }
            }
            RdpOutputEvent::PointerDefault => delegate.on_pointer_visibility(true),
            RdpOutputEvent::PointerHidden => delegate.on_pointer_visibility(false),
            RdpOutputEvent::PointerPosition { x, y } => {
                delegate.on_pointer_position(u32::from(x), u32::from(y))
            }
            RdpOutputEvent::PointerBitmap(pointer) => {
                if let Some(payload) = pointer_bitmap_payload(&pointer) {
                    delegate.on_pointer_bitmap(
                        payload.width,
                        payload.height,
                        payload.hotspot_x,
                        payload.hotspot_y,
                        payload.rgba,
                    );
                }
            }
            RdpOutputEvent::NetworkCharacteristics { average_rtt_ms, .. } => {
                delegate.on_network_status(
                    average_rtt_ms,
                    network_mode_for_rtt(average_rtt_ms).to_owned(),
                );
            }
            RdpOutputEvent::ConnectionFailure(err) => {
                delegate.on_disconnected(format!("RDP 连接失败：{err}"));
            }
            RdpOutputEvent::Terminated(result) => match result {
                Ok(reason) => delegate.on_disconnected(format!("RDP 会话已结束：{reason:?}")),
                Err(err) => delegate.on_disconnected(format!("RDP 会话错误：{err}")),
            },
        }
    }
}

fn sync_button(ops: &mut Vec<Operation>, button: MouseButton, pressed: bool, db: &Database) {
    let currently = db.is_mouse_button_pressed(button);
    match (currently, pressed) {
        (false, true) => ops.push(Operation::MouseButtonPressed(button)),
        (true, false) => ops.push(Operation::MouseButtonReleased(button)),
        _ => {}
    }
}

fn validate_desktop_size(width: u32, height: u32) -> Result<(u16, u16), RdpConfigurationError> {
    if width == 0 || height == 0 || width > MAX_DESKTOP_DIMENSION || height > MAX_DESKTOP_DIMENSION
    {
        return Err(RdpConfigurationError::InvalidDesktopSize { width, height });
    }

    Ok((width as u16, height as u16))
}

/// Validate the advertised geometry before forwarding the BGRA bytes produced
/// by the IronRDP worker.
fn bgra_region_bytes(
    buffer: Vec<u8>,
    desktop_width: u32,
    desktop_height: u32,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
) -> Option<Vec<u8>> {
    validate_desktop_size(desktop_width, desktop_height).ok()?;
    if width == 0
        || height == 0
        || x >= desktop_width
        || y >= desktop_height
        || width > desktop_width - x
        || height > desktop_height - y
    {
        return None;
    }
    let pixel_count = usize::try_from(width)
        .ok()?
        .checked_mul(usize::try_from(height).ok()?)?;
    let expected_bytes = pixel_count.checked_mul(4)?;
    if buffer.len() != expected_bytes || expected_bytes > MAX_DESKTOP_FRAME_BYTES {
        return None;
    }
    Some(buffer)
}

fn security_policy(mode: RdpSecurityMode) -> Result<SecurityPolicy, RdpConfigurationError> {
    match mode {
        RdpSecurityMode::Nla => Ok(SecurityPolicy {
            enable_credssp: true,
            enable_tls: false,
        }),
        RdpSecurityMode::Tls => Ok(SecurityPolicy {
            enable_credssp: false,
            enable_tls: true,
        }),
        RdpSecurityMode::Rdp => Err(RdpConfigurationError::UnsupportedLegacySecurity),
    }
}

fn validate_drive(
    name: Option<String>,
    local_path: Option<String>,
) -> Result<Option<ValidatedDrive>, RdpConfigurationError> {
    let (name, local_path) = match (name, local_path) {
        (None, None) => return Ok(None),
        (Some(name), Some(local_path)) => (name, local_path),
        _ => return Err(RdpConfigurationError::IncompleteDriveConfiguration),
    };

    let name = name.trim().to_owned();
    let is_safe_name = !name.is_empty()
        && name.chars().count() <= 32
        && name
            .chars()
            .any(|character| character.is_ascii_alphanumeric())
        && name.chars().all(|character| {
            character.is_ascii_alphanumeric() || matches!(character, ' ' | '.' | '_' | '-')
        });
    if !is_safe_name {
        return Err(RdpConfigurationError::UnsafeDriveName);
    }

    let local_path = local_path.trim();
    let metadata = std::fs::metadata(local_path)
        .map_err(|_| RdpConfigurationError::DrivePathDoesNotExist(local_path.to_owned()))?;
    if !metadata.is_dir() {
        return Err(RdpConfigurationError::DrivePathIsNotDirectory(
            local_path.to_owned(),
        ));
    }
    let canonical_path = std::fs::canonicalize(local_path).map_err(|_| {
        RdpConfigurationError::DrivePathCannotBeCanonicalized(local_path.to_owned())
    })?;

    Ok(Some(ValidatedDrive {
        name,
        local_path: canonical_path,
    }))
}

fn pointer_bitmap_payload(pointer: &DecodedPointer) -> Option<PointerBitmapPayload> {
    let width = usize::from(pointer.width);
    let height = usize::from(pointer.height);
    let expected_bytes = width.checked_mul(height)?.checked_mul(4)?;
    if width == 0
        || height == 0
        || expected_bytes > MAX_POINTER_RGBA_BYTES
        || pointer.bitmap_data.len() != expected_bytes
        || usize::from(pointer.hotspot_x) >= width
        || usize::from(pointer.hotspot_y) >= height
    {
        return None;
    }

    Some(PointerBitmapPayload {
        width: u32::from(pointer.width),
        height: u32::from(pointer.height),
        hotspot_x: u32::from(pointer.hotspot_x),
        hotspot_y: u32::from(pointer.hotspot_y),
        rgba: pointer.bitmap_data.clone(),
    })
}

fn clipboard_text_fits(text: &str) -> bool {
    let maximum_code_units = MAX_CLIPBOARD_TEXT_BYTES.saturating_sub(2) / 2;
    text.encode_utf16().count() <= maximum_code_units
}

fn unicode_text_formats() -> Vec<ClipboardFormat> {
    vec![ClipboardFormat::new(ClipboardFormatId::CF_UNICODETEXT)]
}

#[derive(Clone, Debug)]
struct ClipboardMessageBridge {
    input: Arc<Mutex<Option<mpsc::UnboundedSender<RdpInputEvent>>>>,
    activity: ConnectionActivity,
}

impl Default for ClipboardMessageBridge {
    fn default() -> Self {
        Self {
            input: Arc::new(Mutex::new(None)),
            activity: ConnectionActivity::active(),
        }
    }
}

impl ClipboardMessageBridge {
    fn with_input(
        input: Arc<Mutex<Option<mpsc::UnboundedSender<RdpInputEvent>>>>,
        activity: ConnectionActivity,
    ) -> Self {
        Self { input, activity }
    }

    #[cfg(test)]
    fn set_input_sender(&self, sender: mpsc::UnboundedSender<RdpInputEvent>) {
        *self.input.lock().unwrap() = Some(sender);
    }

    fn send(&self, message: ClipboardMessage) {
        if !self.activity.is_active() {
            return;
        }
        if let Some(sender) = self.input.lock().unwrap().as_ref() {
            let _ = sender.send(RdpInputEvent::Clipboard(message));
        }
    }
}

fn remote_clipboard_callback(
    activity: ConnectionActivity,
    delegate: Arc<dyn RdpSessionDelegate>,
) -> RemoteClipboardCallback {
    Arc::new(move |text| {
        if activity.is_active() {
            delegate.on_clipboard(text);
        }
    })
}

#[derive(Clone)]
struct ClipboardChannelConfiguration {
    state: Arc<Mutex<Option<String>>>,
    bridge: ClipboardMessageBridge,
    callback: RemoteClipboardCallback,
}

struct TextClipboardBackend {
    state: Arc<Mutex<Option<String>>>,
    bridge: ClipboardMessageBridge,
    callback: RemoteClipboardCallback,
}

impl core::fmt::Debug for TextClipboardBackend {
    fn fmt(&self, formatter: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        formatter
            .debug_struct("TextClipboardBackend")
            .finish_non_exhaustive()
    }
}

impl_as_any!(TextClipboardBackend);

impl TextClipboardBackend {
    fn new(
        state: Arc<Mutex<Option<String>>>,
        bridge: ClipboardMessageBridge,
        callback: RemoteClipboardCallback,
    ) -> Self {
        Self {
            state,
            bridge,
            callback,
        }
    }

    fn advertise_local_text(&self) {
        if self.state.lock().unwrap().is_some() {
            self.bridge
                .send(ClipboardMessage::SendInitiateCopy(unicode_text_formats()));
        }
    }
}

impl CliprdrBackend for TextClipboardBackend {
    fn temporary_directory(&self) -> &str {
        ".stacio-cliprdr"
    }

    fn client_capabilities(&self) -> ClipboardGeneralCapabilityFlags {
        ClipboardGeneralCapabilityFlags::empty()
    }

    fn on_ready(&mut self) {}

    fn on_request_format_list(&mut self) {
        self.advertise_local_text();
    }

    fn on_process_negotiated_capabilities(
        &mut self,
        _capabilities: ClipboardGeneralCapabilityFlags,
    ) {
    }

    fn on_remote_copy(&mut self, available_formats: &[ClipboardFormat]) {
        if available_formats
            .iter()
            .any(|format| format.id() == ClipboardFormatId::CF_UNICODETEXT)
        {
            self.bridge.send(ClipboardMessage::SendInitiatePaste(
                ClipboardFormatId::CF_UNICODETEXT,
            ));
        }
    }

    fn on_format_data_request(&mut self, request: FormatDataRequest) {
        let response = if request.format == ClipboardFormatId::CF_UNICODETEXT {
            self.state
                .lock()
                .unwrap()
                .as_ref()
                .filter(|text| clipboard_text_fits(text))
                .map(|text| FormatDataResponse::new_unicode_string(text).into_owned())
                .unwrap_or_else(|| FormatDataResponse::new_error().into_owned())
        } else {
            FormatDataResponse::new_error().into_owned()
        };
        self.bridge.send(ClipboardMessage::SendFormatData(response));
    }

    fn on_format_data_response(&mut self, response: FormatDataResponse<'_>) {
        let data = response.data();
        if response.is_error()
            || data.len() < 2
            || data.len() > MAX_CLIPBOARD_TEXT_BYTES
            || data.len() % 2 != 0
            || !data.ends_with(&[0, 0])
        {
            return;
        }
        if let Ok(text) = response.to_unicode_string() {
            if clipboard_text_fits(&text) {
                (self.callback)(text);
            }
        }
    }

    fn on_file_contents_request(&mut self, _request: FileContentsRequest) {}

    fn on_file_contents_response(&mut self, _response: FileContentsResponse<'_>) {}

    fn on_lock(&mut self, _data_id: LockDataId) {}

    fn on_unlock(&mut self, _data_id: LockDataId) {}
}

fn network_mode_for_rtt(rtt_ms: u32) -> &'static str {
    match rtt_ms {
        ..=99 => "normal",
        100..=300 => "poor",
        _ => "very_poor",
    }
}

fn transport_profile_for_quality(quality: u8) -> RdpTransportProfile {
    if quality.clamp(1, 10) <= 6 {
        RdpTransportProfile {
            color_depth: 16,
            performance_flags: PerformanceFlags::DISABLE_WALLPAPER
                | PerformanceFlags::DISABLE_FULLWINDOWDRAG
                | PerformanceFlags::DISABLE_MENUANIMATIONS
                | PerformanceFlags::DISABLE_THEMING
                | PerformanceFlags::DISABLE_CURSOR_SHADOW
                | PerformanceFlags::DISABLE_CURSORSETTINGS,
        }
    } else {
        RdpTransportProfile {
            color_depth: 32,
            performance_flags: PerformanceFlags::default(),
        }
    }
}

fn build_config(
    host: String,
    port: u16,
    username: String,
    password: String,
    domain: Option<String>,
    width: u16,
    height: u16,
    quality: u8,
    security: RdpSecurityMode,
    ignore_certificate: bool,
    clipboard: Option<ClipboardChannelConfiguration>,
    drive: Option<ValidatedDrive>,
) -> Result<ironrdp_client::config::Config, RdpConfigurationError> {
    use ironrdp_client::config::{ClipboardType, ConfigBuilder, Destination, TransportKind};

    let (width, height) = validate_desktop_size(u32::from(width), u32::from(height))?;
    let security = security_policy(security)?;
    let transport_profile = transport_profile_for_quality(quality);
    let destination = Destination::from_parts(host, port);
    let mut builder = ConfigBuilder::new()
        .with_destination(destination)
        .with_username(username)
        .with_password(password)
        .with_client_build(1)
        .with_client_dir("")
        .with_client_name("Stacio")
        .with_platform(ironrdp_pdu::rdp::capability_sets::MajorPlatformType::OSX)
        .with_desktop_width(width)
        .with_desktop_height(height)
        .with_color_depth(transport_profile.color_depth)
        .with_performance_flags(transport_profile.performance_flags)
        .with_credssp(security.enable_credssp)
        .with_tls(security.enable_tls)
        .with_ignore_certificate(ignore_certificate)
        .with_transport(TransportKind::Direct)
        .with_autologon(true)
        .with_server_pointer(true)
        .with_pointer_software_rendering(false)
        .with_clipboard(ClipboardType::External);

    // `ironrdp-client` otherwise installs a built-in RDPDR channel backed by
    // `NoopRdpdrBackend`. Stacio registers only the confined drive backend
    // below, so the automatic channel must stay disabled even when the Cargo
    // feature is enabled.
    #[cfg(feature = "rdpdr")]
    {
        builder = builder.with_rdpdr(false);
    }

    if let Some(clipboard) = clipboard {
        builder = builder.with_static_channel(move |_| {
            Some(ironrdp_cliprdr::CliprdrClient::new(Box::new(
                TextClipboardBackend::new(
                    clipboard.state.clone(),
                    clipboard.bridge.clone(),
                    clipboard.callback.clone(),
                ),
            )))
        });
    }

    #[cfg(feature = "rdpdr")]
    if let Some(drive) = drive {
        let name = drive.name;
        let mut local_path = drive.local_path.to_string_lossy().into_owned();
        if !local_path.ends_with('/') {
            local_path.push('/');
        }
        builder = builder.with_static_channel(move |_| {
            let backend = ironrdp_rdpdr_native::backend::NixRdpdrBackend::new(local_path.clone());
            Some(
                ironrdp_rdpdr::Rdpdr::new(Box::new(backend), "Stacio".to_owned())
                    .with_drives(Some(vec![(1, name.clone())])),
            )
        });
    }

    #[cfg(not(feature = "rdpdr"))]
    if drive.is_some() {
        return Err(RdpConfigurationError::DriveRedirectionUnavailable);
    }

    if let Some(domain) = domain.filter(|d| !d.trim().is_empty()) {
        builder = builder.with_domain(domain);
    }

    builder
        .build()
        .map_err(|error| RdpConfigurationError::InvalidClientConfiguration(error.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use ironrdp_cliprdr::backend::ClipboardMessage;
    use ironrdp_cliprdr::pdu::{
        ClipboardFormat, ClipboardFormatId, FormatDataRequest, FormatDataResponse,
    };
    use ironrdp_graphics::pointer::DecodedPointer;
    #[cfg(feature = "rdpdr")]
    use ironrdp_rdpdr::pdu::efs::{
        AnyIoCtlCode, Boolean, CreateDisposition, CreateOptions, DesiredAccess, DeviceCloseRequest,
        DeviceControlRequest, DeviceCreateRequest, DeviceIoRequest, DeviceReadRequest,
        DeviceWriteRequest, FileAttributes, FileDispositionInformation, FileInformationClass,
        FileInformationClassLevel, FileRenameInformation, MajorFunction, MinorFunction, NtStatus,
        ServerDriveIoRequest, ServerDriveLockControlRequest,
        ServerDriveNotifyChangeDirectoryRequest, ServerDriveQueryDirectoryRequest,
        ServerDriveQueryInformationRequest, ServerDriveSetInformationRequest, SharedAccess,
    };
    #[cfg(feature = "rdpdr")]
    use ironrdp_rdpdr::RdpdrBackend;
    use tokio::sync::mpsc::error::TryRecvError;

    #[test]
    fn nla_security_enables_credssp_only() {
        let policy = security_policy(RdpSecurityMode::Nla).expect("NLA policy");

        assert!(policy.enable_credssp);
        assert!(!policy.enable_tls);
    }

    #[test]
    fn tls_security_enables_tls_only() {
        let policy = security_policy(RdpSecurityMode::Tls).expect("TLS policy");

        assert!(!policy.enable_credssp);
        assert!(policy.enable_tls);
    }

    #[test]
    fn legacy_rdp_security_is_rejected() {
        let error = security_policy(RdpSecurityMode::Rdp).expect_err("legacy RDP must fail");

        assert_eq!(error, RdpConfigurationError::UnsupportedLegacySecurity);
    }

    #[test]
    fn desktop_size_rejects_zero_and_oversized_dimensions() {
        assert_eq!(
            validate_desktop_size(0, 800),
            Err(RdpConfigurationError::InvalidDesktopSize {
                width: 0,
                height: 800,
            })
        );
        assert_eq!(
            validate_desktop_size(8_193, 1),
            Err(RdpConfigurationError::InvalidDesktopSize {
                width: 8_193,
                height: 1,
            })
        );
    }

    #[test]
    fn network_status_uses_protocol_rtt_thresholds() {
        assert_eq!(network_mode_for_rtt(99), "normal");
        assert_eq!(network_mode_for_rtt(100), "poor");
        assert_eq!(network_mode_for_rtt(300), "poor");
        assert_eq!(network_mode_for_rtt(301), "very_poor");
    }

    #[test]
    fn client_surfaces_server_network_characteristics() {
        use ironrdp_client::rdp::network_characteristics_output;
        use ironrdp_pdu::rdp::autodetect::AutoDetectRequest;

        let event =
            network_characteristics_output(AutoDetectRequest::NetworkCharacteristicsResult {
                sequence_number: 7,
                request_type: 0x08c0,
                base_rtt_ms: Some(41),
                bandwidth_kbps: Some(12_000),
                average_rtt_ms: 187,
            })
            .expect("network event");

        match event {
            RdpOutputEvent::NetworkCharacteristics {
                base_rtt_ms,
                bandwidth_kbps,
                average_rtt_ms,
            } => {
                assert_eq!(base_rtt_ms, Some(41));
                assert_eq!(bandwidth_kbps, Some(12_000));
                assert_eq!(average_rtt_ms, 187);
            }
            other => panic!("unexpected event: {other:?}"),
        }
    }

    #[test]
    fn request_resize_rejects_dimensions_that_would_wrap() {
        let session = RdpSession::new();
        let (sender, mut receiver) = mpsc::unbounded_channel();
        *session.input.lock().expect("input lock") = Some(sender);

        session.request_resize(65_536, 800);
        assert!(matches!(receiver.try_recv(), Err(TryRecvError::Empty)));

        session.request_resize(8_192, 8_191);
        match receiver.try_recv().expect("resize event") {
            RdpInputEvent::Resize { width, height, .. } => {
                assert_eq!(width, 8_192);
                assert_eq!(height, 8_191);
            }
            other => panic!("unexpected event: {other:?}"),
        }
    }

    #[test]
    fn frame_conversion_validates_geometry_before_allocating() {
        assert!(bgra_region_bytes(vec![0x11, 0x22, 0x33, 0x44], 8_193, 1, 0, 0, 1, 1).is_none());
        assert!(bgra_region_bytes(vec![0x11, 0x22, 0x33, 0x44], 2, 1, 1, 0, 2, 1).is_none());
        assert!(bgra_region_bytes(vec![0x11, 0x22, 0x33, 0x44], 2, 1, 0, 0, 2, 1).is_none());
        assert_eq!(
            bgra_region_bytes(vec![0x33, 0x22, 0x11, 0x44], 2, 2, 1, 1, 1, 1),
            Some(vec![0x33, 0x22, 0x11, 0x44])
        );
    }

    #[test]
    fn frame_conversion_accepts_producer_bgra_bytes_without_repacking() {
        let producer = vec![0x00, 0x00, 0xFF, 0xFF];
        assert_eq!(
            bgra_region_bytes(producer.clone(), 2, 2, 1, 1, 1, 1),
            Some(producer)
        );
    }

    #[test]
    fn config_preserves_per_connection_certificate_policy() {
        let strict = test_config(RdpSecurityMode::Nla, false);
        let ignored = test_config(RdpSecurityMode::Nla, true);

        assert!(!strict.ignore_certificate());
        assert!(ignored.ignore_certificate());
    }

    #[test]
    fn low_quality_config_reduces_color_depth_and_visual_effects() {
        use ironrdp_pdu::rdp::client_info::PerformanceFlags;

        let config = test_config_with_quality(RdpSecurityMode::Nla, false, 2);
        let bitmap = config.connector().bitmap.as_ref().expect("bitmap config");

        assert_eq!(bitmap.color_depth, 16);
        assert!(config.connector().performance_flags.contains(
            PerformanceFlags::DISABLE_WALLPAPER
                | PerformanceFlags::DISABLE_FULLWINDOWDRAG
                | PerformanceFlags::DISABLE_MENUANIMATIONS
                | PerformanceFlags::DISABLE_THEMING
                | PerformanceFlags::DISABLE_CURSOR_SHADOW
                | PerformanceFlags::DISABLE_CURSORSETTINGS
        ));
        assert!(!config
            .connector()
            .performance_flags
            .contains(PerformanceFlags::ENABLE_FONT_SMOOTHING));
        assert!(!config
            .connector()
            .performance_flags
            .contains(PerformanceFlags::ENABLE_DESKTOP_COMPOSITION));
    }

    #[test]
    fn normal_quality_config_keeps_full_color_default_effects() {
        use ironrdp_pdu::rdp::client_info::PerformanceFlags;

        let config = test_config_with_quality(RdpSecurityMode::Nla, false, 8);
        let bitmap = config.connector().bitmap.as_ref().expect("bitmap config");

        assert_eq!(bitmap.color_depth, 32);
        assert_eq!(
            config.connector().performance_flags,
            PerformanceFlags::default()
        );
    }

    #[test]
    fn config_uses_external_clipboard_mode_without_native_stub() {
        let config = test_config(RdpSecurityMode::Nla, false);

        assert_eq!(
            config.channels().clipboard,
            ironrdp_client::config::ClipboardType::External
        );
    }

    #[cfg(feature = "rdpdr")]
    #[test]
    fn config_disables_builtin_noop_rdpdr_channel() {
        let config = test_config(RdpSecurityMode::Nla, false);

        assert!(
            !config.channels().rdpdr.enabled,
            "only an explicitly configured confined drive backend may enable RDPDR"
        );
    }

    #[test]
    fn drive_validation_canonicalizes_existing_directory() {
        let directory = tempfile::tempdir().expect("temp dir");

        let drive = validate_drive(
            Some("Shared".to_owned()),
            Some(directory.path().to_string_lossy().into_owned()),
        )
        .expect("valid drive")
        .expect("configured drive");

        assert_eq!(drive.name, "Shared");
        assert_eq!(
            drive.local_path,
            directory.path().canonicalize().expect("canonical path")
        );
    }

    #[test]
    fn drive_validation_rejects_unsafe_name() {
        let directory = tempfile::tempdir().expect("temp dir");

        let error = validate_drive(
            Some("../escape".to_owned()),
            Some(directory.path().to_string_lossy().into_owned()),
        )
        .expect_err("unsafe drive name must fail");

        assert_eq!(error, RdpConfigurationError::UnsafeDriveName);
    }

    #[test]
    fn drive_validation_rejects_partial_configuration() {
        let error = validate_drive(Some("Shared".to_owned()), None)
            .expect_err("partial drive config must fail");

        assert_eq!(error, RdpConfigurationError::IncompleteDriveConfiguration);
    }

    #[cfg(feature = "rdpdr")]
    #[test]
    fn drive_backend_rejects_parent_traversal_during_create() {
        let directory = tempfile::tempdir().expect("temp dir");
        let shared_root = directory.path().join("shared");
        std::fs::create_dir(&shared_root).expect("shared root");
        let escaped_file = directory.path().join("escaped.txt");
        let mut backend = ironrdp_rdpdr_native::backend::NixRdpdrBackend::new(format!(
            "{}/",
            shared_root.display()
        ));

        let responses = backend
            .handle_drive_io_request(ServerDriveIoRequest::ServerCreateDriveRequest(
                create_request(0, r"\..\escaped.txt", CreateDisposition::FILE_OPEN_IF),
            ))
            .expect("create response");

        assert_eq!(
            response_status(&responses[0]),
            u32::from(NtStatus::ACCESS_DENIED)
        );
        assert!(
            !escaped_file.exists(),
            "request escaped the shared drive root"
        );
    }

    #[cfg(feature = "rdpdr")]
    #[test]
    fn drive_backend_does_not_follow_shared_root_replacement() {
        let directory = tempfile::tempdir().expect("temp dir");
        let shared_root = directory.path().join("shared");
        let moved_root = directory.path().join("shared-moved");
        let outside_root = directory.path().join("outside");
        std::fs::create_dir(&shared_root).expect("shared root");
        std::fs::create_dir(&outside_root).expect("outside root");
        let mut backend = ironrdp_rdpdr_native::backend::NixRdpdrBackend::new(format!(
            "{}/",
            shared_root.display()
        ));
        std::fs::rename(&shared_root, &moved_root).expect("move shared root");
        std::os::unix::fs::symlink(&outside_root, &shared_root).expect("replace root with symlink");

        let responses = backend
            .handle_drive_io_request(ServerDriveIoRequest::ServerCreateDriveRequest(
                create_request(0, r"\escaped.txt", CreateDisposition::FILE_OPEN_IF),
            ))
            .expect("create response");

        assert_eq!(
            response_status(&responses[0]),
            u32::from(NtStatus::ACCESS_DENIED)
        );
        assert!(
            !outside_root.join("escaped.txt").exists(),
            "replacement redirected the shared drive outside its original root"
        );
    }

    #[cfg(feature = "rdpdr")]
    #[test]
    fn drive_backend_rejects_same_path_shared_root_replacement() {
        let directory = tempfile::tempdir().expect("temp dir");
        let shared_root = directory.path().join("shared");
        let moved_root = directory.path().join("shared-moved");
        std::fs::create_dir(&shared_root).expect("shared root");
        let mut backend = ironrdp_rdpdr_native::backend::NixRdpdrBackend::new(format!(
            "{}/",
            shared_root.display()
        ));
        std::fs::rename(&shared_root, &moved_root).expect("move shared root");
        std::fs::create_dir(&shared_root).expect("replace shared root at same path");

        let responses = backend
            .handle_drive_io_request(ServerDriveIoRequest::ServerCreateDriveRequest(
                create_request(0, r"\replacement.txt", CreateDisposition::FILE_OPEN_IF),
            ))
            .expect("create response");

        assert_eq!(
            response_status(&responses[0]),
            u32::from(NtStatus::ACCESS_DENIED)
        );
        assert!(
            !shared_root.join("replacement.txt").exists(),
            "a new directory at the same path must not inherit the old share"
        );
    }

    #[cfg(feature = "rdpdr")]
    #[test]
    fn drive_backend_rejects_symlink_escape_during_create() {
        let directory = tempfile::tempdir().expect("temp dir");
        let shared_root = directory.path().join("shared");
        let outside_root = directory.path().join("outside");
        std::fs::create_dir(&shared_root).expect("shared root");
        std::fs::create_dir(&outside_root).expect("outside root");
        std::os::unix::fs::symlink(&outside_root, shared_root.join("outside-link"))
            .expect("outside symlink");
        let escaped_file = outside_root.join("escaped.txt");
        let mut backend = ironrdp_rdpdr_native::backend::NixRdpdrBackend::new(format!(
            "{}/",
            shared_root.display()
        ));

        let responses = backend
            .handle_drive_io_request(ServerDriveIoRequest::ServerCreateDriveRequest(
                create_request(
                    0,
                    r"\outside-link\escaped.txt",
                    CreateDisposition::FILE_OPEN_IF,
                ),
            ))
            .expect("create response");

        assert_eq!(
            response_status(&responses[0]),
            u32::from(NtStatus::ACCESS_DENIED)
        );
        assert!(
            !escaped_file.exists(),
            "request followed a symlink outside the shared drive root"
        );
    }

    #[cfg(feature = "rdpdr")]
    #[test]
    fn drive_backend_rejects_parent_traversal_during_directory_query() {
        let directory = tempfile::tempdir().expect("temp dir");
        let shared_root = directory.path().join("shared");
        std::fs::create_dir(&shared_root).expect("shared root");
        std::fs::write(directory.path().join("outside.txt"), b"outside").expect("outside file");
        let mut backend = ironrdp_rdpdr_native::backend::NixRdpdrBackend::new(format!(
            "{}/",
            shared_root.display()
        ));
        backend
            .handle_drive_io_request(ServerDriveIoRequest::ServerCreateDriveRequest(
                create_directory_request(0, r"\"),
            ))
            .expect("open shared root");

        let responses = backend
            .handle_drive_io_request(ServerDriveIoRequest::ServerDriveQueryDirectoryRequest(
                ServerDriveQueryDirectoryRequest {
                    device_io_request: device_io_request(
                        0,
                        MajorFunction::DirectoryControl,
                        MinorFunction::IRP_MN_QUERY_DIRECTORY,
                    ),
                    file_info_class_lvl: FileInformationClassLevel::FILE_BOTH_DIRECTORY_INFORMATION,
                    initial_query: 1,
                    path: r"\..\outside.txt".to_owned(),
                },
            ))
            .expect("query response");

        assert_eq!(
            response_status(&responses[0]),
            u32::from(NtStatus::ACCESS_DENIED)
        );
    }

    #[cfg(feature = "rdpdr")]
    #[test]
    fn drive_directory_query_does_not_follow_symlink_outside_shared_root() {
        let directory = tempfile::tempdir().expect("temp dir");
        let shared_root = directory.path().join("shared");
        let outside_file = directory.path().join("outside.txt");
        let link = shared_root.join("outside-link");
        std::fs::create_dir(&shared_root).expect("shared root");
        std::fs::write(&outside_file, vec![b'x'; 16_384]).expect("outside file");
        std::os::unix::fs::symlink(&outside_file, &link).expect("outside symlink");
        let link_size = std::fs::symlink_metadata(&link)
            .expect("link metadata")
            .len() as i64;
        let mut backend = ironrdp_rdpdr_native::backend::NixRdpdrBackend::new(format!(
            "{}/",
            shared_root.display()
        ));
        backend
            .handle_drive_io_request(ServerDriveIoRequest::ServerCreateDriveRequest(
                create_directory_request(0, r"\"),
            ))
            .expect("open shared root");

        let responses = backend
            .handle_drive_io_request(ServerDriveIoRequest::ServerDriveQueryDirectoryRequest(
                ServerDriveQueryDirectoryRequest {
                    device_io_request: device_io_request(
                        0,
                        MajorFunction::DirectoryControl,
                        MinorFunction::IRP_MN_QUERY_DIRECTORY,
                    ),
                    file_info_class_lvl: FileInformationClassLevel::FILE_BOTH_DIRECTORY_INFORMATION,
                    initial_query: 1,
                    path: r"\*".to_owned(),
                },
            ))
            .expect("query response");

        assert_eq!(response_status(&responses[0]), u32::from(NtStatus::SUCCESS));
        assert_eq!(response_end_of_file(&responses[0]), link_size);
    }

    #[cfg(feature = "rdpdr")]
    #[test]
    fn drive_backend_rejects_parent_traversal_during_rename() {
        let directory = tempfile::tempdir().expect("temp dir");
        let shared_root = directory.path().join("shared");
        std::fs::create_dir(&shared_root).expect("shared root");
        let shared_file = shared_root.join("inside.txt");
        let escaped_file = directory.path().join("renamed-outside.txt");
        std::fs::write(&shared_file, b"inside").expect("shared file");
        let mut backend = ironrdp_rdpdr_native::backend::NixRdpdrBackend::new(format!(
            "{}/",
            shared_root.display()
        ));
        backend
            .handle_drive_io_request(ServerDriveIoRequest::ServerCreateDriveRequest(
                create_request(0, r"\inside.txt", CreateDisposition::FILE_OPEN),
            ))
            .expect("open shared file");

        let responses = backend
            .handle_drive_io_request(ServerDriveIoRequest::ServerDriveSetInformationRequest(
                ServerDriveSetInformationRequest {
                    device_io_request: device_io_request(
                        0,
                        MajorFunction::SetInformation,
                        MinorFunction::from(0),
                    ),
                    set_buffer: FileInformationClass::Rename(FileRenameInformation {
                        replace_if_exists: Boolean::False,
                        file_name: r"\..\renamed-outside.txt".to_owned(),
                    }),
                },
            ))
            .expect("rename response");

        assert_eq!(
            response_status(&responses[0]),
            u32::from(NtStatus::ACCESS_DENIED)
        );
        assert!(
            shared_file.exists(),
            "source file was moved outside the shared root"
        );
        assert!(
            !escaped_file.exists(),
            "rename escaped the shared drive root"
        );
    }

    #[cfg(feature = "rdpdr")]
    #[test]
    fn drive_backend_rejects_oversized_read_before_allocating() {
        let directory = tempfile::tempdir().expect("temp dir");
        let shared_root = directory.path().join("shared");
        std::fs::create_dir(&shared_root).expect("shared root");
        std::fs::write(shared_root.join("small.txt"), b"small").expect("shared file");
        let mut backend = ironrdp_rdpdr_native::backend::NixRdpdrBackend::new(format!(
            "{}/",
            shared_root.display()
        ));
        backend
            .handle_drive_io_request(ServerDriveIoRequest::ServerCreateDriveRequest(
                create_request(0, r"\small.txt", CreateDisposition::FILE_OPEN),
            ))
            .expect("open shared file");

        let responses = backend
            .handle_drive_io_request(ServerDriveIoRequest::DeviceReadRequest(DeviceReadRequest {
                device_io_request: device_io_request(
                    0,
                    MajorFunction::Read,
                    MinorFunction::from(0),
                ),
                length: 32 * 1024 * 1024,
                offset: 0,
            }))
            .expect("read response");

        assert_eq!(
            response_status(&responses[0]),
            u32::from(NtStatus::UNSUCCESSFUL)
        );
    }

    #[cfg(feature = "rdpdr")]
    #[test]
    fn drive_backend_reports_create_information_and_supersede_truncates() {
        let directory = tempfile::tempdir().expect("temp dir");
        let shared_root = directory.path().join("shared");
        std::fs::create_dir(&shared_root).expect("shared root");
        let shared_file = shared_root.join("item.txt");
        let mut backend = ironrdp_rdpdr_native::backend::NixRdpdrBackend::new(format!(
            "{}/",
            shared_root.display()
        ));
        let access = DesiredAccess::GENERIC_READ | DesiredAccess::GENERIC_WRITE;

        let created = backend
            .handle_drive_io_request(ServerDriveIoRequest::ServerCreateDriveRequest(
                create_request_with_access(
                    0,
                    r"\item.txt",
                    CreateDisposition::FILE_CREATE,
                    access.clone(),
                    all_shared_access(),
                ),
            ))
            .expect("create response");
        assert_eq!(response_status(&created[0]), u32::from(NtStatus::SUCCESS));
        assert_eq!(response_create_information(&created[0]), 2);
        close_handle(&mut backend, response_file_id(&created[0]));

        std::fs::write(&shared_file, b"content").expect("seed file");
        let opened = backend
            .handle_drive_io_request(ServerDriveIoRequest::ServerCreateDriveRequest(
                create_request_with_access(
                    0,
                    r"\item.txt",
                    CreateDisposition::FILE_OPEN,
                    access.clone(),
                    all_shared_access(),
                ),
            ))
            .expect("open response");
        assert_eq!(response_create_information(&opened[0]), 1);
        close_handle(&mut backend, response_file_id(&opened[0]));

        let overwritten = backend
            .handle_drive_io_request(ServerDriveIoRequest::ServerCreateDriveRequest(
                create_request_with_access(
                    0,
                    r"\item.txt",
                    CreateDisposition::FILE_OVERWRITE,
                    access.clone(),
                    all_shared_access(),
                ),
            ))
            .expect("overwrite response");
        assert_eq!(response_create_information(&overwritten[0]), 3);
        assert_eq!(std::fs::metadata(&shared_file).expect("metadata").len(), 0);
        close_handle(&mut backend, response_file_id(&overwritten[0]));

        std::fs::write(&shared_file, b"content again").expect("reseed file");
        let superseded = backend
            .handle_drive_io_request(ServerDriveIoRequest::ServerCreateDriveRequest(
                create_request_with_access(
                    0,
                    r"\item.txt",
                    CreateDisposition::FILE_SUPERSEDE,
                    access,
                    all_shared_access(),
                ),
            ))
            .expect("supersede response");
        assert_eq!(response_create_information(&superseded[0]), 0);
        assert_eq!(std::fs::metadata(&shared_file).expect("metadata").len(), 0);
    }

    #[cfg(feature = "rdpdr")]
    #[test]
    fn drive_backend_defers_delete_until_last_handle_closes() {
        let directory = tempfile::tempdir().expect("temp dir");
        let shared_root = directory.path().join("shared");
        std::fs::create_dir(&shared_root).expect("shared root");
        let shared_file = shared_root.join("pending.txt");
        std::fs::write(&shared_file, b"pending").expect("shared file");
        let mut backend = ironrdp_rdpdr_native::backend::NixRdpdrBackend::new(format!(
            "{}/",
            shared_root.display()
        ));

        let deleting = backend
            .handle_drive_io_request(ServerDriveIoRequest::ServerCreateDriveRequest(
                create_request_with_access(
                    0,
                    r"\pending.txt",
                    CreateDisposition::FILE_OPEN,
                    DesiredAccess::GENERIC_READ | DesiredAccess::DELETE,
                    all_shared_access(),
                ),
            ))
            .expect("delete handle");
        let deleting_id = response_file_id(&deleting[0]);
        let observer = backend
            .handle_drive_io_request(ServerDriveIoRequest::ServerCreateDriveRequest(
                create_request_with_access(
                    0,
                    r"\pending.txt",
                    CreateDisposition::FILE_OPEN,
                    DesiredAccess::GENERIC_READ,
                    all_shared_access(),
                ),
            ))
            .expect("observer handle");
        let observer_id = response_file_id(&observer[0]);

        let disposition = backend
            .handle_drive_io_request(ServerDriveIoRequest::ServerDriveSetInformationRequest(
                disposition_request(deleting_id, true),
            ))
            .expect("disposition response");
        assert_eq!(
            response_status(&disposition[0]),
            u32::from(NtStatus::SUCCESS)
        );

        let standard = backend
            .handle_drive_io_request(ServerDriveIoRequest::ServerDriveQueryInformationRequest(
                ServerDriveQueryInformationRequest {
                    device_io_request: device_io_request(
                        observer_id,
                        MajorFunction::QueryInformation,
                        MinorFunction::from(0),
                    ),
                    file_info_class_lvl: FileInformationClassLevel::FILE_STANDARD_INFORMATION,
                },
            ))
            .expect("standard information");
        assert!(response_standard_delete_pending(&standard[0]));

        let rejected = backend
            .handle_drive_io_request(ServerDriveIoRequest::ServerCreateDriveRequest(
                create_request_with_access(
                    0,
                    r"\pending.txt",
                    CreateDisposition::FILE_OPEN,
                    DesiredAccess::GENERIC_READ,
                    all_shared_access(),
                ),
            ))
            .expect("pending open response");
        assert_eq!(response_status(&rejected[0]), 0xC000_0056);

        close_handle(&mut backend, deleting_id);
        assert!(
            shared_file.exists(),
            "first close removed a still-open file"
        );
        close_handle(&mut backend, observer_id);
        assert!(
            !shared_file.exists(),
            "last close did not delete pending file"
        );
    }

    #[cfg(feature = "rdpdr")]
    #[test]
    fn drive_backend_delete_pending_removes_empty_directory() {
        let directory = tempfile::tempdir().expect("temp dir");
        let shared_root = directory.path().join("shared");
        let empty_directory = shared_root.join("empty");
        std::fs::create_dir(&shared_root).expect("shared root");
        std::fs::create_dir(&empty_directory).expect("empty directory");
        let mut backend = ironrdp_rdpdr_native::backend::NixRdpdrBackend::new(format!(
            "{}/",
            shared_root.display()
        ));
        let mut request = create_directory_request(0, r"\empty");
        request.desired_access = DesiredAccess::DELETE;
        request.shared_access = all_shared_access();
        let opened = backend
            .handle_drive_io_request(ServerDriveIoRequest::ServerCreateDriveRequest(request))
            .expect("directory open");
        let file_id = response_file_id(&opened[0]);

        let disposition = backend
            .handle_drive_io_request(ServerDriveIoRequest::ServerDriveSetInformationRequest(
                disposition_request(file_id, true),
            ))
            .expect("directory disposition");
        assert_eq!(
            response_status(&disposition[0]),
            u32::from(NtStatus::SUCCESS)
        );
        close_handle(&mut backend, file_id);
        assert!(!empty_directory.exists());
    }

    #[cfg(feature = "rdpdr")]
    #[test]
    fn drive_backend_rename_honors_replace_and_updates_open_handle_path() {
        let directory = tempfile::tempdir().expect("temp dir");
        let shared_root = directory.path().join("shared");
        let source = shared_root.join("source.txt");
        let target = shared_root.join("target.txt");
        std::fs::create_dir(&shared_root).expect("shared root");
        std::fs::write(&source, b"source").expect("source file");
        std::fs::write(&target, b"target").expect("target file");
        let mut backend = ironrdp_rdpdr_native::backend::NixRdpdrBackend::new(format!(
            "{}/",
            shared_root.display()
        ));
        let opened = backend
            .handle_drive_io_request(ServerDriveIoRequest::ServerCreateDriveRequest(
                create_request_with_access(
                    0,
                    r"\source.txt",
                    CreateDisposition::FILE_OPEN,
                    DesiredAccess::GENERIC_READ | DesiredAccess::DELETE,
                    all_shared_access(),
                ),
            ))
            .expect("source open");
        let file_id = response_file_id(&opened[0]);

        let collision = backend
            .handle_drive_io_request(ServerDriveIoRequest::ServerDriveSetInformationRequest(
                rename_request(file_id, r"\target.txt", false),
            ))
            .expect("rename collision");
        assert_eq!(
            response_status(&collision[0]),
            u32::from(NtStatus::OBJECT_NAME_COLLISION)
        );
        assert_eq!(std::fs::read(&target).expect("target content"), b"target");

        let replaced = backend
            .handle_drive_io_request(ServerDriveIoRequest::ServerDriveSetInformationRequest(
                rename_request(file_id, r"\target.txt", true),
            ))
            .expect("replace rename");
        assert_eq!(response_status(&replaced[0]), u32::from(NtStatus::SUCCESS));
        assert!(!source.exists());
        assert_eq!(std::fs::read(&target).expect("target content"), b"source");

        let pending = backend
            .handle_drive_io_request(ServerDriveIoRequest::ServerDriveSetInformationRequest(
                disposition_request(file_id, true),
            ))
            .expect("renamed handle disposition");
        assert_eq!(response_status(&pending[0]), u32::from(NtStatus::SUCCESS));
        close_handle(&mut backend, file_id);
        assert!(
            !target.exists(),
            "renamed handle retained its stale source path"
        );
    }

    #[cfg(feature = "rdpdr")]
    #[test]
    fn drive_backend_enforces_bidirectional_share_access() {
        let directory = tempfile::tempdir().expect("temp dir");
        let shared_root = directory.path().join("shared");
        std::fs::create_dir(&shared_root).expect("shared root");
        std::fs::write(shared_root.join("locked.txt"), b"locked").expect("shared file");
        let mut backend = ironrdp_rdpdr_native::backend::NixRdpdrBackend::new(format!(
            "{}/",
            shared_root.display()
        ));
        let first = backend
            .handle_drive_io_request(ServerDriveIoRequest::ServerCreateDriveRequest(
                create_request_with_access(
                    0,
                    r"\locked.txt",
                    CreateDisposition::FILE_OPEN,
                    DesiredAccess::GENERIC_READ,
                    SharedAccess::empty(),
                ),
            ))
            .expect("exclusive open");
        assert_eq!(response_status(&first[0]), u32::from(NtStatus::SUCCESS));

        let second = backend
            .handle_drive_io_request(ServerDriveIoRequest::ServerCreateDriveRequest(
                create_request_with_access(
                    0,
                    r"\locked.txt",
                    CreateDisposition::FILE_OPEN,
                    DesiredAccess::GENERIC_READ,
                    all_shared_access(),
                ),
            ))
            .expect("conflicting open response");
        assert_eq!(response_status(&second[0]), 0xC000_0043);
    }

    #[cfg(feature = "rdpdr")]
    #[test]
    fn drive_backend_completes_unsupported_notify_lock_and_control_requests() {
        let directory = tempfile::tempdir().expect("temp dir");
        let mut backend = ironrdp_rdpdr_native::backend::NixRdpdrBackend::new(
            directory.path().to_string_lossy().into_owned(),
        );

        let mut notify_header = device_io_request(
            7,
            MajorFunction::DirectoryControl,
            MinorFunction::IRP_MN_NOTIFY_CHANGE_DIRECTORY,
        );
        notify_header.completion_id = 101;
        let notify = backend
            .handle_drive_io_request(
                ServerDriveIoRequest::ServerDriveNotifyChangeDirectoryRequest(
                    ServerDriveNotifyChangeDirectoryRequest {
                        device_io_request: notify_header,
                        watch_tree: 1,
                        completion_filter: u32::MAX,
                    },
                ),
            )
            .expect("notify completion");
        assert_eq!(notify.len(), 1);
        assert_eq!(
            response_status(&notify[0]),
            u32::from(NtStatus::NOT_SUPPORTED)
        );
        assert_eq!(response_completion_id(&notify[0]), 101);

        let mut lock_header =
            device_io_request(7, MajorFunction::LockControl, MinorFunction::from(0));
        lock_header.completion_id = 102;
        let lock = backend
            .handle_drive_io_request(ServerDriveIoRequest::ServerDriveLockControlRequest(
                ServerDriveLockControlRequest {
                    device_io_request: lock_header,
                },
            ))
            .expect("lock completion");
        assert_eq!(lock.len(), 1);
        assert_eq!(
            response_status(&lock[0]),
            u32::from(NtStatus::NOT_SUPPORTED)
        );
        assert_eq!(response_completion_id(&lock[0]), 102);

        let mut control_header =
            device_io_request(7, MajorFunction::DeviceControl, MinorFunction::from(0));
        control_header.completion_id = 103;
        let control = backend
            .handle_drive_io_request(ServerDriveIoRequest::DeviceControlRequest(
                DeviceControlRequest {
                    header: control_header,
                    output_buffer_length: 0,
                    input_buffer_length: 0,
                    io_control_code: AnyIoCtlCode(0xDEAD_BEEF),
                },
            ))
            .expect("control completion");
        assert_eq!(control.len(), 1);
        assert_eq!(
            response_status(&control[0]),
            u32::from(NtStatus::NOT_SUPPORTED)
        );
        assert_eq!(response_completion_id(&control[0]), 103);
    }

    #[cfg(feature = "rdpdr")]
    #[test]
    fn drive_backend_supports_windows_wildcards_and_directory_information_classes() {
        let directory = tempfile::tempdir().expect("temp dir");
        let shared_root = directory.path().join("shared");
        std::fs::create_dir(&shared_root).expect("shared root");
        std::fs::write(shared_root.join("alpha.txt"), b"a").expect("alpha file");
        std::fs::write(shared_root.join("beta.log"), b"b").expect("beta file");
        std::fs::write(shared_root.join("README"), b"r").expect("readme file");
        let mut backend = ironrdp_rdpdr_native::backend::NixRdpdrBackend::new(format!(
            "{}/",
            shared_root.display()
        ));
        let root_open = backend
            .handle_drive_io_request(ServerDriveIoRequest::ServerCreateDriveRequest(
                create_directory_request(0, r"\"),
            ))
            .expect("root open");
        let root_id = response_file_id(&root_open[0]);

        assert_eq!(
            query_directory_names(&mut backend, root_id, r"\*.*"),
            vec!["alpha.txt", "beta.log", "README"]
        );
        assert_eq!(
            query_directory_names(&mut backend, root_id, r"\*.txt"),
            vec!["alpha.txt"]
        );

        for information_class in [
            FileInformationClassLevel::FILE_DIRECTORY_INFORMATION,
            FileInformationClassLevel::FILE_FULL_DIRECTORY_INFORMATION,
            FileInformationClassLevel::FILE_BOTH_DIRECTORY_INFORMATION,
            FileInformationClassLevel::FILE_NAMES_INFORMATION,
        ] {
            let response = backend
                .handle_drive_io_request(ServerDriveIoRequest::ServerDriveQueryDirectoryRequest(
                    ServerDriveQueryDirectoryRequest {
                        device_io_request: device_io_request(
                            root_id,
                            MajorFunction::DirectoryControl,
                            MinorFunction::IRP_MN_QUERY_DIRECTORY,
                        ),
                        file_info_class_lvl: information_class,
                        initial_query: 1,
                        path: r"\alpha.txt".to_owned(),
                    },
                ))
                .expect("directory class response");
            assert_eq!(response_status(&response[0]), u32::from(NtStatus::SUCCESS));
        }
    }

    #[cfg(feature = "rdpdr")]
    #[test]
    fn drive_backend_rejects_replaced_handle_path_before_delete() {
        let directory = tempfile::tempdir().expect("temp dir");
        let shared_root = directory.path().join("shared");
        let outside_file = directory.path().join("outside.txt");
        let shared_file = shared_root.join("inside.txt");
        let moved_file = shared_root.join("moved.txt");
        std::fs::create_dir(&shared_root).expect("shared root");
        std::fs::write(&shared_file, b"inside").expect("inside file");
        std::fs::write(&outside_file, b"outside").expect("outside file");
        let mut backend = ironrdp_rdpdr_native::backend::NixRdpdrBackend::new(format!(
            "{}/",
            shared_root.display()
        ));
        let opened = backend
            .handle_drive_io_request(ServerDriveIoRequest::ServerCreateDriveRequest(
                create_request_with_access(
                    0,
                    r"\inside.txt",
                    CreateDisposition::FILE_OPEN,
                    DesiredAccess::DELETE,
                    all_shared_access(),
                ),
            ))
            .expect("inside open");
        let file_id = response_file_id(&opened[0]);

        std::fs::rename(&shared_file, &moved_file).expect("move opened file");
        std::os::unix::fs::symlink(&outside_file, &shared_file).expect("replace with symlink");
        let disposition = backend
            .handle_drive_io_request(ServerDriveIoRequest::ServerDriveSetInformationRequest(
                disposition_request(file_id, true),
            ))
            .expect("disposition response");
        assert_eq!(
            response_status(&disposition[0]),
            u32::from(NtStatus::ACCESS_DENIED)
        );
        assert_eq!(
            std::fs::read(&outside_file).expect("outside content"),
            b"outside"
        );
        assert!(shared_file.is_symlink());
    }

    #[cfg(feature = "rdpdr")]
    #[test]
    fn drive_backend_enforces_read_and_write_access_per_handle() {
        let directory = tempfile::tempdir().expect("temp dir");
        let shared_root = directory.path().join("shared");
        let shared_file = shared_root.join("access.txt");
        std::fs::create_dir(&shared_root).expect("shared root");
        std::fs::write(&shared_file, b"original").expect("shared file");
        let mut backend = ironrdp_rdpdr_native::backend::NixRdpdrBackend::new(format!(
            "{}/",
            shared_root.display()
        ));

        let read_only = backend
            .handle_drive_io_request(ServerDriveIoRequest::ServerCreateDriveRequest(
                create_request_with_access(
                    0,
                    r"\access.txt",
                    CreateDisposition::FILE_OPEN,
                    DesiredAccess::GENERIC_READ,
                    all_shared_access(),
                ),
            ))
            .expect("read-only open");
        let read_only_id = response_file_id(&read_only[0]);
        let write = backend
            .handle_drive_io_request(ServerDriveIoRequest::DeviceWriteRequest(
                DeviceWriteRequest {
                    device_io_request: device_io_request(
                        read_only_id,
                        MajorFunction::Write,
                        MinorFunction::from(0),
                    ),
                    offset: 0,
                    write_data: b"changed".to_vec(),
                },
            ))
            .expect("write response");
        assert_eq!(
            response_status(&write[0]),
            u32::from(NtStatus::ACCESS_DENIED)
        );
        assert_eq!(std::fs::read(&shared_file).expect("content"), b"original");
        close_handle(&mut backend, read_only_id);

        let write_only = backend
            .handle_drive_io_request(ServerDriveIoRequest::ServerCreateDriveRequest(
                create_request_with_access(
                    0,
                    r"\access.txt",
                    CreateDisposition::FILE_OPEN,
                    DesiredAccess::GENERIC_WRITE,
                    all_shared_access(),
                ),
            ))
            .expect("write-only open");
        let read = backend
            .handle_drive_io_request(ServerDriveIoRequest::DeviceReadRequest(DeviceReadRequest {
                device_io_request: device_io_request(
                    response_file_id(&write_only[0]),
                    MajorFunction::Read,
                    MinorFunction::from(0),
                ),
                length: 8,
                offset: 0,
            }))
            .expect("read response");
        assert_eq!(
            response_status(&read[0]),
            u32::from(NtStatus::ACCESS_DENIED)
        );
    }

    #[test]
    fn reconnect_closes_previous_input_and_aborts_previous_forwarder() {
        let session = RdpSession::new();
        let (old_input, mut old_events) = mpsc::unbounded_channel();
        *session.input.lock().expect("input lock") = Some(old_input);
        let old_forward = session.runtime.spawn(std::future::pending::<()>());
        let old_abort = old_forward.abort_handle();
        *session.forward_handle.lock().expect("forward lock") = Some(old_forward);

        session.clone().connect(
            "127.0.0.1".to_owned(),
            9,
            "tester".to_owned(),
            "secret".to_owned(),
            None,
            1280,
            800,
            7,
            RdpSecurityMode::Tls,
            true,
            None,
            None,
            Box::new(NoopRdpSessionDelegate),
        );

        let old_received_close = matches!(old_events.try_recv(), Ok(RdpInputEvent::Close));
        let old_forward_stopped = (0..100).any(|_| {
            if old_abort.is_finished() {
                true
            } else {
                std::thread::sleep(std::time::Duration::from_millis(1));
                false
            }
        });

        session.close();
        old_abort.abort();

        assert!(
            old_received_close,
            "the replaced RDP input did not receive Close"
        );
        assert!(
            old_forward_stopped,
            "the replaced RDP output forwarder remained active"
        );
    }

    #[test]
    fn reconnect_resets_previous_input_state() {
        let session = RdpSession::new();
        let scancode = Scancode::from_u16(0x1e);
        session
            .database
            .lock()
            .expect("database lock")
            .apply([Operation::KeyPressed(scancode)]);
        assert!(session
            .database
            .lock()
            .expect("database lock")
            .is_key_pressed(scancode));

        session.clone().connect(
            "127.0.0.1".to_owned(),
            9,
            "tester".to_owned(),
            "secret".to_owned(),
            None,
            1280,
            800,
            7,
            RdpSecurityMode::Tls,
            true,
            None,
            None,
            Box::new(NoopRdpSessionDelegate),
        );

        let key_is_still_pressed = session
            .database
            .lock()
            .expect("database lock")
            .is_key_pressed(scancode);
        session.close();

        assert!(
            !key_is_still_pressed,
            "the new RDP connection inherited a pressed key"
        );
    }

    #[test]
    fn inactive_connection_drops_queued_output_events() {
        let activity = ConnectionActivity::inactive();
        let delegate = Arc::new(RecordingRdpSessionDelegate::default());
        let (sender, receiver) = mpsc::channel(1);

        shared_runtime().block_on(async {
            sender
                .send(RdpOutputEvent::PointerHidden)
                .await
                .expect("queue pointer event");
            drop(sender);
            forward_output_events(receiver, delegate.clone(), activity).await;
        });

        assert!(delegate
            .pointer_visibility
            .lock()
            .expect("pointer visibility lock")
            .is_empty());
    }

    #[test]
    fn inactive_clipboard_bridge_does_not_send_to_replacement_input() {
        let activity = ConnectionActivity::active();
        let shared_input = Arc::new(Mutex::new(None));
        let bridge = ClipboardMessageBridge::with_input(shared_input.clone(), activity.clone());
        activity.deactivate();
        let (replacement_sender, mut replacement_events) = mpsc::unbounded_channel();
        *shared_input.lock().expect("input lock") = Some(replacement_sender);

        bridge.send(ClipboardMessage::SendInitiateCopy(unicode_text_formats()));

        assert!(matches!(
            replacement_events.try_recv(),
            Err(TryRecvError::Empty)
        ));
    }

    #[test]
    fn inactive_connection_drops_remote_clipboard_callback() {
        let activity = ConnectionActivity::active();
        let delegate = Arc::new(RecordingRdpSessionDelegate::default());
        let callback = remote_clipboard_callback(activity.clone(), delegate.clone());
        activity.deactivate();

        callback("stale clipboard".to_owned());

        assert!(delegate
            .clipboard
            .lock()
            .expect("clipboard lock")
            .is_empty());
    }

    #[test]
    fn input_dispatch_waits_for_connection_transition() {
        let session = RdpSession::new();
        let (input_sender, _input_events) = mpsc::unbounded_channel();
        *session.input.lock().expect("input lock") = Some(input_sender);
        let lifecycle = session.lifecycle_lock.lock().expect("lifecycle lock");
        let (started_sender, started_receiver) = std::sync::mpsc::channel();
        let (finished_sender, finished_receiver) = std::sync::mpsc::channel();
        let worker_session = session.clone();
        let worker = std::thread::spawn(move || {
            started_sender.send(()).expect("signal worker start");
            worker_session.send_key(0x1e, true);
            finished_sender.send(()).expect("signal worker finish");
        });
        started_receiver.recv().expect("worker start");

        let completed_during_transition = finished_receiver
            .recv_timeout(std::time::Duration::from_millis(100))
            .is_ok();
        drop(lifecycle);
        if !completed_during_transition {
            finished_receiver
                .recv_timeout(std::time::Duration::from_secs(1))
                .expect("input dispatch after transition");
        }
        worker.join().expect("input worker");

        assert!(
            !completed_during_transition,
            "RDP input crossed an in-progress connection transition"
        );
    }

    #[test]
    fn local_clipboard_text_advertises_only_unicode_text() {
        let session = RdpSession::new();
        let (sender, mut receiver) = mpsc::unbounded_channel();
        *session.input.lock().expect("input lock") = Some(sender);

        session.send_clipboard_text("hello 世界".to_owned());

        match receiver.try_recv().expect("clipboard event") {
            RdpInputEvent::Clipboard(ClipboardMessage::SendInitiateCopy(formats)) => {
                assert_eq!(
                    formats,
                    vec![ClipboardFormat::new(ClipboardFormatId::CF_UNICODETEXT)]
                );
            }
            other => panic!("unexpected event: {other:?}"),
        }
    }

    #[test]
    fn local_clipboard_text_is_bounded() {
        let session = RdpSession::new();
        let (sender, mut receiver) = mpsc::unbounded_channel();
        *session.input.lock().expect("input lock") = Some(sender);

        session.send_clipboard_text("x".repeat(MAX_CLIPBOARD_TEXT_BYTES));

        assert!(matches!(receiver.try_recv(), Err(TryRecvError::Empty)));
    }

    #[test]
    fn remote_data_request_returns_current_unicode_text() {
        let session = RdpSession::new();
        let (mut backend, mut receiver, _) = clipboard_backend(session.clipboard_text.clone());
        *session.clipboard_text.lock().expect("clipboard state") = Some("hello 世界".to_owned());

        backend.on_format_data_request(FormatDataRequest {
            format: ClipboardFormatId::CF_UNICODETEXT,
        });

        match clipboard_message(&mut receiver) {
            ClipboardMessage::SendFormatData(response) => {
                assert_eq!(
                    response.to_unicode_string().expect("unicode text"),
                    "hello 世界"
                );
            }
            other => panic!("unexpected clipboard message: {other:?}"),
        }
    }

    #[test]
    fn remote_unicode_format_list_requests_paste() {
        let state = Arc::new(Mutex::new(None));
        let (mut backend, mut receiver, _) = clipboard_backend(state);

        backend.on_remote_copy(&[
            ClipboardFormat::new(ClipboardFormatId::CF_TEXT),
            ClipboardFormat::new(ClipboardFormatId::CF_UNICODETEXT),
        ]);

        match clipboard_message(&mut receiver) {
            ClipboardMessage::SendInitiatePaste(format) => {
                assert_eq!(format, ClipboardFormatId::CF_UNICODETEXT);
            }
            other => panic!("unexpected clipboard message: {other:?}"),
        }
    }

    #[test]
    fn remote_unicode_response_reaches_delegate_callback() {
        let state = Arc::new(Mutex::new(None));
        let (mut backend, _, received) = clipboard_backend(state);

        backend.on_format_data_response(FormatDataResponse::new_unicode_string("remote 文本"));

        assert_eq!(
            *received.lock().expect("received lock"),
            vec!["remote 文本"]
        );
    }

    #[test]
    fn remote_oversized_unicode_response_is_ignored() {
        let state = Arc::new(Mutex::new(None));
        let (mut backend, _, received) = clipboard_backend(state);
        let oversized = vec![0_u8; MAX_CLIPBOARD_TEXT_BYTES + 2];

        backend.on_format_data_response(FormatDataResponse::new_data(oversized));

        assert!(received.lock().expect("received lock").is_empty());
    }

    #[test]
    fn pointer_mapping_preserves_geometry_hotspot_and_rgba() {
        let pointer = DecodedPointer {
            width: 2,
            height: 1,
            hotspot_x: 1,
            hotspot_y: 0,
            bitmap_data: vec![1, 2, 3, 4, 5, 6, 7, 8],
        };

        let payload = pointer_bitmap_payload(&pointer).expect("valid pointer");

        assert_eq!(payload.width, 2);
        assert_eq!(payload.height, 1);
        assert_eq!(payload.hotspot_x, 1);
        assert_eq!(payload.hotspot_y, 0);
        assert_eq!(payload.rgba, vec![1, 2, 3, 4, 5, 6, 7, 8]);
    }

    fn clipboard_backend(
        state: Arc<Mutex<Option<String>>>,
    ) -> (
        TextClipboardBackend,
        mpsc::UnboundedReceiver<RdpInputEvent>,
        Arc<Mutex<Vec<String>>>,
    ) {
        let bridge = ClipboardMessageBridge::default();
        let (sender, receiver) = mpsc::unbounded_channel();
        bridge.set_input_sender(sender);
        let received = Arc::new(Mutex::new(Vec::new()));
        let callback_received = received.clone();
        let callback: RemoteClipboardCallback = Arc::new(move |text| {
            callback_received.lock().expect("callback lock").push(text);
        });
        (
            TextClipboardBackend::new(state, bridge, callback),
            receiver,
            received,
        )
    }

    fn clipboard_message(
        receiver: &mut mpsc::UnboundedReceiver<RdpInputEvent>,
    ) -> ClipboardMessage {
        match receiver.try_recv().expect("clipboard event") {
            RdpInputEvent::Clipboard(message) => message,
            other => panic!("unexpected event: {other:?}"),
        }
    }

    fn test_config(
        security: RdpSecurityMode,
        ignore_certificate: bool,
    ) -> ironrdp_client::config::Config {
        test_config_with_quality(security, ignore_certificate, 7)
    }

    fn test_config_with_quality(
        security: RdpSecurityMode,
        ignore_certificate: bool,
        quality: u8,
    ) -> ironrdp_client::config::Config {
        build_config(
            "rdp.example.test".to_owned(),
            3389,
            "tester".to_owned(),
            "secret".to_owned(),
            None,
            1280,
            800,
            quality,
            security,
            ignore_certificate,
            None,
            None,
        )
        .expect("test config")
    }

    #[cfg(feature = "rdpdr")]
    fn create_request(
        file_id: u32,
        path: &str,
        disposition: CreateDisposition,
    ) -> DeviceCreateRequest {
        DeviceCreateRequest {
            device_io_request: device_io_request(
                file_id,
                MajorFunction::Create,
                MinorFunction::from(0),
            ),
            desired_access: DesiredAccess::empty(),
            allocation_size: 0,
            file_attributes: FileAttributes::empty(),
            shared_access: SharedAccess::empty(),
            create_disposition: disposition,
            create_options: CreateOptions::FILE_NON_DIRECTORY_FILE,
            path: path.to_owned(),
        }
    }

    #[cfg(feature = "rdpdr")]
    fn create_request_with_access(
        file_id: u32,
        path: &str,
        disposition: CreateDisposition,
        desired_access: DesiredAccess,
        shared_access: SharedAccess,
    ) -> DeviceCreateRequest {
        let mut request = create_request(file_id, path, disposition);
        request.desired_access = desired_access;
        request.shared_access = shared_access;
        request
    }

    #[cfg(feature = "rdpdr")]
    fn all_shared_access() -> SharedAccess {
        SharedAccess::FILE_SHARE_READ
            | SharedAccess::FILE_SHARE_WRITE
            | SharedAccess::FILE_SHARE_DELETE
    }

    #[cfg(feature = "rdpdr")]
    fn create_directory_request(file_id: u32, path: &str) -> DeviceCreateRequest {
        let mut request = create_request(file_id, path, CreateDisposition::FILE_OPEN);
        request.create_options = CreateOptions::FILE_DIRECTORY_FILE;
        request
    }

    #[cfg(feature = "rdpdr")]
    fn device_io_request(
        file_id: u32,
        major_function: MajorFunction,
        minor_function: MinorFunction,
    ) -> DeviceIoRequest {
        DeviceIoRequest {
            device_id: 1,
            file_id,
            completion_id: 1,
            major_function,
            minor_function,
        }
    }

    #[cfg(feature = "rdpdr")]
    fn close_handle(backend: &mut ironrdp_rdpdr_native::backend::NixRdpdrBackend, file_id: u32) {
        let response = backend
            .handle_drive_io_request(ServerDriveIoRequest::DeviceCloseRequest(
                DeviceCloseRequest {
                    device_io_request: device_io_request(
                        file_id,
                        MajorFunction::Close,
                        MinorFunction::from(0),
                    ),
                },
            ))
            .expect("close response");
        assert_eq!(response_status(&response[0]), u32::from(NtStatus::SUCCESS));
    }

    #[cfg(feature = "rdpdr")]
    fn disposition_request(file_id: u32, delete_pending: bool) -> ServerDriveSetInformationRequest {
        ServerDriveSetInformationRequest {
            device_io_request: device_io_request(
                file_id,
                MajorFunction::SetInformation,
                MinorFunction::from(0),
            ),
            set_buffer: FileInformationClass::Disposition(FileDispositionInformation {
                delete_pending: u8::from(delete_pending),
            }),
        }
    }

    #[cfg(feature = "rdpdr")]
    fn rename_request(
        file_id: u32,
        target_path: &str,
        replace_if_exists: bool,
    ) -> ServerDriveSetInformationRequest {
        ServerDriveSetInformationRequest {
            device_io_request: device_io_request(
                file_id,
                MajorFunction::SetInformation,
                MinorFunction::from(0),
            ),
            set_buffer: FileInformationClass::Rename(FileRenameInformation {
                replace_if_exists: if replace_if_exists {
                    Boolean::True
                } else {
                    Boolean::False
                },
                file_name: target_path.to_owned(),
            }),
        }
    }

    #[cfg(feature = "rdpdr")]
    fn query_directory_names(
        backend: &mut ironrdp_rdpdr_native::backend::NixRdpdrBackend,
        file_id: u32,
        pattern: &str,
    ) -> Vec<String> {
        let mut names = Vec::new();
        let mut initial_query = 1;
        loop {
            let response = backend
                .handle_drive_io_request(ServerDriveIoRequest::ServerDriveQueryDirectoryRequest(
                    ServerDriveQueryDirectoryRequest {
                        device_io_request: device_io_request(
                            file_id,
                            MajorFunction::DirectoryControl,
                            MinorFunction::IRP_MN_QUERY_DIRECTORY,
                        ),
                        file_info_class_lvl: FileInformationClassLevel::FILE_NAMES_INFORMATION,
                        initial_query,
                        path: pattern.to_owned(),
                    },
                ))
                .expect("directory response");
            let status = response_status(&response[0]);
            if status == u32::from(NtStatus::SUCCESS) {
                names.push(response_directory_name(&response[0]));
                initial_query = 0;
            } else if status == u32::from(NtStatus::NO_MORE_FILES)
                || status == u32::from(NtStatus::NO_SUCH_FILE)
            {
                break;
            } else {
                panic!("unexpected directory query status {status:#010x}");
            }
        }
        names
    }

    #[cfg(feature = "rdpdr")]
    fn response_status(response: &ironrdp_svc::SvcMessage) -> u32 {
        let encoded = response
            .encode_unframed_pdu()
            .expect("encoded RDPDR response");
        u32::from_le_bytes(encoded[12..16].try_into().expect("NTSTATUS bytes"))
    }

    #[cfg(feature = "rdpdr")]
    fn response_completion_id(response: &ironrdp_svc::SvcMessage) -> u32 {
        let encoded = response
            .encode_unframed_pdu()
            .expect("encoded RDPDR response");
        u32::from_le_bytes(encoded[8..12].try_into().expect("completion ID bytes"))
    }

    #[cfg(feature = "rdpdr")]
    fn response_file_id(response: &ironrdp_svc::SvcMessage) -> u32 {
        let encoded = response
            .encode_unframed_pdu()
            .expect("encoded RDPDR response");
        u32::from_le_bytes(encoded[16..20].try_into().expect("file ID bytes"))
    }

    #[cfg(feature = "rdpdr")]
    fn response_create_information(response: &ironrdp_svc::SvcMessage) -> u8 {
        response
            .encode_unframed_pdu()
            .expect("encoded RDPDR response")[20]
    }

    #[cfg(feature = "rdpdr")]
    fn response_standard_delete_pending(response: &ironrdp_svc::SvcMessage) -> bool {
        response
            .encode_unframed_pdu()
            .expect("encoded RDPDR response")[40]
            != 0
    }

    #[cfg(feature = "rdpdr")]
    fn response_directory_name(response: &ironrdp_svc::SvcMessage) -> String {
        let encoded = response
            .encode_unframed_pdu()
            .expect("encoded RDPDR response");
        let byte_length = u32::from_le_bytes(
            encoded[28..32]
                .try_into()
                .expect("directory name length bytes"),
        ) as usize;
        let utf16: Vec<u16> = encoded[32..32 + byte_length]
            .chunks_exact(2)
            .map(|chunk| u16::from_le_bytes([chunk[0], chunk[1]]))
            .collect();
        String::from_utf16(&utf16).expect("directory name UTF-16")
    }

    #[cfg(feature = "rdpdr")]
    fn response_end_of_file(response: &ironrdp_svc::SvcMessage) -> i64 {
        let encoded = response
            .encode_unframed_pdu()
            .expect("encoded RDPDR response");
        i64::from_le_bytes(encoded[60..68].try_into().expect("EndOfFile bytes"))
    }

    struct NoopRdpSessionDelegate;

    impl RdpSessionDelegate for NoopRdpSessionDelegate {
        fn on_frame(
            &self,
            _desktop_width: u32,
            _desktop_height: u32,
            _x: u32,
            _y: u32,
            _width: u32,
            _height: u32,
            _bgra: Vec<u8>,
        ) {
        }

        fn on_pointer_visibility(&self, _visible: bool) {}

        fn on_pointer_position(&self, _x: u32, _y: u32) {}

        fn on_pointer_bitmap(
            &self,
            _width: u32,
            _height: u32,
            _hotspot_x: u32,
            _hotspot_y: u32,
            _rgba: Vec<u8>,
        ) {
        }

        fn on_clipboard(&self, _text: String) {}

        fn on_network_status(&self, _rtt_ms: u32, _mode: String) {}

        fn on_disconnected(&self, _reason: String) {}
    }

    #[derive(Default)]
    struct RecordingRdpSessionDelegate {
        pointer_visibility: Mutex<Vec<bool>>,
        clipboard: Mutex<Vec<String>>,
    }

    impl RdpSessionDelegate for RecordingRdpSessionDelegate {
        fn on_frame(
            &self,
            _desktop_width: u32,
            _desktop_height: u32,
            _x: u32,
            _y: u32,
            _width: u32,
            _height: u32,
            _bgra: Vec<u8>,
        ) {
        }

        fn on_pointer_visibility(&self, visible: bool) {
            self.pointer_visibility
                .lock()
                .expect("pointer visibility lock")
                .push(visible);
        }

        fn on_pointer_position(&self, _x: u32, _y: u32) {}

        fn on_pointer_bitmap(
            &self,
            _width: u32,
            _height: u32,
            _hotspot_x: u32,
            _hotspot_y: u32,
            _rgba: Vec<u8>,
        ) {
        }

        fn on_clipboard(&self, text: String) {
            self.clipboard.lock().expect("clipboard lock").push(text);
        }

        fn on_network_status(&self, _rtt_ms: u32, _mode: String) {}

        fn on_disconnected(&self, _reason: String) {}
    }
}
