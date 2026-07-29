# Stacio BLE Console Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a native macOS BLE GATT Console workflow compatible with BTerm UART profiles, while preserving the existing system `serial` workflow and freezing a BLE-first, exact-COM-only fallback contract for a later Windows implementation.

**Architecture:** StacioCore owns the versioned Console configuration, BTerm profile catalog, transport policy, validated import/export, and an external terminal runtime with no socket or serial worker. The macOS app owns CoreBluetooth scanning and GATT I/O behind injectable protocols, feeds RX byte batches into the existing terminal buffer, and sends pane input through a BLE-specific event sink. A native AppKit scanner sheet binds a user-selected peripheral, shows name and RSSI, pins recognized `NBEE_BLE_1103` devices, and never invokes SPP on macOS.

**Tech Stack:** Rust 2021, serde, uuid, UniFFI 0.29, Swift 5.10, AppKit, CoreBluetooth, SwiftTerm, SwiftPM/XCTest, shell packaging tests.

**Approved design:** `docs/superpowers/specs/2026-07-29-stacio-ble-console-architecture-design.md`

---

## File Responsibility Map

### New Core files

| Path | Single responsibility |
| --- | --- |
| `StacioCore/src/domain/console.rs` | Console v1 config, Bluetooth UUID normalization, BTerm profile matching, platform transport policy, and stable config errors. |

### New macOS application files

| Path | Single responsibility |
| --- | --- |
| `Stacio/Services/BLEConsoleModels.swift` | Pure discovery/result models, RSSI normalization, NBEE 1103 recognition, stable sorting, and localized error metadata. |
| `Stacio/Services/BLEConsoleCentral.swift` | CoreBluetooth adapter, peripheral registry, scanning, connection, service/characteristic discovery, subscription, and raw GATT operations. |
| `Stacio/Services/BLEConsoleSession.swift` | Serialized connection state machine, generation filtering, profile validation, TX chunking/backpressure, RX delivery, bounded reconnect, and idempotent close. |
| `Stacio/Services/ConsoleSessionCoordinator.swift` | External runtime creation, terminal bridge/event sink, pane lifecycle, and saved Console session startup. |
| `Stacio/Views/Dialogs/BLEConsoleScannerViewController.swift` | Native attached scanner sheet with search, 40 pt device rows, RSSI, recognition state, keyboard commands, and connect/cancel actions. |
| `Stacio/Views/Dialogs/BLEConsoleCharacteristicMapperViewController.swift` | Manual service/TX/RX/write-type selection when no built-in BTerm profile matches. |
| `Stacio/Views/Dialogs/BLEConsoleSessionEditorView.swift` | Session-settings binding summary, scan/rebind command, selected profile display, and test hooks. |

### New tests and documentation

| Path | Coverage |
| --- | --- |
| `Tests/StacioAppTests/BLEConsoleModelsTests.swift` | RSSI, recognition, sorting, throttling, and stable selection. |
| `Tests/StacioAppTests/BLEConsoleCentralTests.swift` | Bluetooth state mapping, scan lifecycle, deduplication, callback generation, and CoreBluetooth DTO mapping. |
| `Tests/StacioAppTests/BLEConsoleSessionTests.swift` | Profile discovery, subscriptions, chunking, backpressure, errors, reconnect, stale callbacks, and close. |
| `Tests/StacioAppTests/ConsoleSessionCoordinatorTests.swift` | External runtime integration, terminal input/output, pane lifecycle, retry, and no-SPP policy. |
| `Tests/StacioAppTests/BLEConsoleScannerViewControllerTests.swift` | Native controls, icons, row layout, selection, keyboard, and accessibility. |
| `docs/development/ble-console-bug-index.md` | Reproduction, error code, evidence, owner, fix status, and regression-test index. |

### Existing files changed by the feature

| Path | Change |
| --- | --- |
| `StacioCore/src/domain/mod.rs` | Export the Console domain module. |
| `StacioCore/src/domain/terminal.rs` | Test the external runtime contract. |
| `StacioCore/src/services/terminal_service.rs` | Register external runtimes without starting an I/O worker. |
| `StacioCore/src/infrastructure/session_repository.rs` | Validate, persist, copy, and export `console` configuration. |
| `StacioCore/src/services/import_service.rs` | Import validated Console configuration while preserving the existing security filter for other protocols. |
| `StacioCore/src/lib.rs` | Export Console and external-runtime UniFFI functions. |
| `Stacio/Bridge/CoreBridge.swift` | Typed wrappers for Console config/profile/policy and external runtime APIs. |
| `Stacio/Bridge/Generated/Headers/stacio_coreFFI.h` | Generated UniFFI header. |
| `Stacio/Bridge/Generated/Sources/stacio_core.swift` | Generated Swift bindings. |
| `Stacio/App/L10n.swift` | Console scanner, connection state, errors, recovery, and settings text. |
| `Stacio/Views/Dialogs/SessionSettingsViewController.swift` | Offer and persist the new `console` protocol and embed the Console editor. |
| `Stacio/Views/Sidebar/SessionSidebarSessionManagement.swift` | Add the Console form mode with fixed port `0` and no credential fields. |
| `Stacio/Views/Sidebar/SessionSidebarViewController.swift` | Use a native Console symbol for saved sessions. |
| `Stacio/Views/Terminal/RemoteTerminalPaneViewController.swift` | Add `.console` lifecycle/name handling without changing serial behavior. |
| `Stacio/Views/Workspace/WorkspaceViewController.swift` | Host a Console pane with an injected BLE bridge/sink, enable MultiExec, and disallow duplicate BLE connections. |
| `Stacio/Views/Workspace/SessionTabIconDescriptor.swift` | Add the native Console tab symbol. |
| `Stacio/Services/WorkspaceCapabilityPolicy.swift` | Allow terminal AI/diagnostics for Console while denying SSH-only capabilities. |
| `Stacio/Windows/WorkbenchWindowController.swift` | Decode saved Console config and route it to `ConsoleSessionCoordinator`. |
| `Package.swift` | Link CoreBluetooth explicitly for `StacioApp`. |
| `scripts/package-app.sh` | Add `NSBluetoothAlwaysUsageDescription`. |
| `Tests/Packaging/package_app_test.sh` | Assert the packaged Bluetooth usage description. |
| `docs/development/code-index.md` | Record only code that exists after implementation. |
| `docs/platform/windows-adaptation-plan.md` | Add the BLE-first and exact COM/SPP fallback implementation contract. |

---

### Task 1: Add the shared Console v1 contract and BTerm profile matcher

**Files:**
- Create: `StacioCore/src/domain/console.rs`
- Modify: `StacioCore/src/domain/mod.rs`
- Modify: `StacioCore/src/lib.rs`

- [ ] **Step 1: Write failing config, profile, UUID, and policy tests**

Add tests in `StacioCore/src/domain/console.rs` with these exact cases:

```rust
#[test]
fn round_trips_nbee_console_v1_config() {
    let config = nbee_config();
    let json = serialize_console_config(config.clone()).expect("serialize console config");
    let decoded = parse_console_config(json).expect("parse console config");
    assert_eq!(decoded, config);
}

#[test]
fn normalizes_short_bluetooth_uuids() {
    assert_eq!(
        normalize_bluetooth_uuid("FFE1"),
        Some("0000ffe1-0000-1000-8000-00805f9b34fb".to_string())
    );
}

#[test]
fn matches_split_nbee_profile_before_shared_profile() {
    let matched = match_console_profile(vec![split_ffe1_service(), shared_ffe0_service()])
        .expect("profile match");
    assert_eq!(matched.profile_id, "bterm-ffe1-split-v1");
    assert_eq!(matched.write_type, "without_response");
}

#[test]
fn rejects_profile_when_rx_cannot_notify_or_indicate() {
    let mut service = split_ffe1_service();
    service.characteristics[1].supports_notify = false;
    assert_eq!(match_console_profile(vec![service]), None);
}

#[test]
fn macos_policy_never_returns_spp_fallback() {
    assert_eq!(
        resolve_console_transport_policy(ConsolePlatform::Macos, Some("COM7".to_string())),
        ConsoleTransportDecision::BleOnly
    );
}

#[test]
fn windows_policy_requires_an_exact_saved_com_port() {
    assert_eq!(
        resolve_console_transport_policy(ConsolePlatform::Windows, Some("COM7".to_string())),
        ConsoleTransportDecision::BleThenBoundSpp { windows_port: "COM7".to_string() }
    );
    assert_eq!(
        resolve_console_transport_policy(ConsolePlatform::Windows, None),
        ConsoleTransportDecision::BleOnly
    );
}
```

Also test unknown schema, wrong `kind`, invalid UUID, catalog/profile UUID mismatch, unsupported write type, and a Windows port that is not exactly `COM` plus a positive decimal number.

- [ ] **Step 2: Run the focused Rust tests and verify the module is missing**

```bash
cargo test --manifest-path StacioCore/Cargo.toml console
```

Expected: compilation fails because `domain::console` and its types do not exist.

- [ ] **Step 3: Implement the versioned records and stable enums**

Define and export these contracts from `console.rs`:

```rust
pub const CONSOLE_SCHEMA_VERSION: u32 = 1;
pub const CONSOLE_TRANSPORT_PREFER_BLE: &str = "prefer_ble";
pub const BTERM_FFE0_SHARED_PROFILE_ID: &str = "bterm-ffe0-shared-v1";
pub const BTERM_FFE1_SPLIT_PROFILE_ID: &str = "bterm-ffe1-split-v1";

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase")]
pub struct ConsoleSessionConfig {
    pub kind: String,
    pub schema_version: u32,
    pub transport_policy: String,
    pub ble: ConsoleBleConfig,
    pub spp_fallback: Option<ConsoleSppFallbackConfig>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase")]
pub struct ConsoleBleConfig {
    pub device_name: String,
    pub profile_id: String,
    pub service_uuid: String,
    pub tx_characteristic_uuid: String,
    pub rx_characteristic_uuid: String,
    pub write_type: String,
    pub platform_bindings: ConsolePlatformBindings,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase")]
pub struct ConsolePlatformBindings {
    pub mac_os_peripheral_uuid: Option<String>,
    pub windows_device_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase")]
pub struct ConsoleSppFallbackConfig {
    pub enabled_platforms: Vec<String>,
    pub windows_port: Option<String>,
    pub baud_rate: u32,
    pub data_bits: u8,
    pub stop_bits: u8,
    pub parity: String,
    pub flow_control: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ConsoleCharacteristicMetadata {
    pub uuid: String,
    pub supports_write: bool,
    pub supports_write_without_response: bool,
    pub supports_notify: bool,
    pub supports_indicate: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ConsoleServiceMetadata {
    pub uuid: String,
    pub characteristics: Vec<ConsoleCharacteristicMetadata>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ConsoleProfileMatch {
    pub profile_id: String,
    pub service_uuid: String,
    pub tx_characteristic_uuid: String,
    pub rx_characteristic_uuid: String,
    pub write_type: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum ConsolePlatform { Macos, Windows }

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum ConsoleTransportDecision {
    BleOnly,
    BleThenBoundSpp { windows_port: String },
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum ConsoleConfigError {
    #[error("BLE_CONSOLE_CONFIG_INVALID: {message}")]
    Invalid { message: String },
}
```

Implement `normalize_bluetooth_uuid`, `parse_console_config`, `serialize_console_config`, `match_console_profile`, and `resolve_console_transport_policy`. Parsing must normalize all three BLE UUIDs, validate the built-in catalog exactly, keep opaque platform IDs opaque, and never infer a MAC address.

- [ ] **Step 4: Export the APIs through UniFFI**

Add `pub mod console;` to `domain/mod.rs`, import the types in `lib.rs`, and export these functions:

```rust
#[uniffi::export]
pub fn parse_console_session_config(json: String) -> Result<ConsoleSessionConfig, ConsoleConfigError> {
    parse_console_config(json)
}

#[uniffi::export]
pub fn serialize_console_session_config(config: ConsoleSessionConfig) -> Result<String, ConsoleConfigError> {
    serialize_console_config(config)
}

#[uniffi::export]
pub fn match_ble_console_profile(services: Vec<ConsoleServiceMetadata>) -> Option<ConsoleProfileMatch> {
    match_console_profile(services)
}

#[uniffi::export]
pub fn console_transport_policy(
    platform: ConsolePlatform,
    windows_port: Option<String>,
) -> ConsoleTransportDecision {
    resolve_console_transport_policy(platform, windows_port)
}
```

- [ ] **Step 5: Run and commit the focused Core contract**

```bash
cargo test --manifest-path StacioCore/Cargo.toml console
cargo fmt --manifest-path StacioCore/Cargo.toml -- --check
git add StacioCore/src/domain/console.rs StacioCore/src/domain/mod.rs StacioCore/src/lib.rs
git commit -m "feat: add BLE console core contract"
```

Expected: all Console tests pass and formatting reports no changes.

---

### Task 2: Persist and import Console sessions without weakening existing import security

**Files:**
- Modify: `StacioCore/src/infrastructure/session_repository.rs`
- Modify: `StacioCore/src/services/import_service.rs`

- [ ] **Step 1: Add failing repository and import tests**

Add repository tests proving a `console` draft uses `config_json` as the source of truth, forces `port == 0`, preserves opaque macOS/Windows bindings, strips unrelated keys, survives duplicate/export, and rejects invalid schema/UUIDs. Add import tests with this invariant:

```rust
let preview = preview_stacio_json_import(&console_export_json(), vec![]).expect("preview");
assert_eq!(preview.sessions.len(), 1);
assert_eq!(preview.sessions[0].protocol, "console");
assert_eq!(preview.sessions[0].port, 0);
let config = preview.sessions[0].config_json.as_deref().expect("console config");
assert!(config.contains("bterm-ffe1-split-v1"));
assert!(config.contains("macOSPeripheralUUID"));
assert!(!config.contains("postConnectScript"));
assert!(!config.contains("password"));
```

Retain existing tests proving SSH imports keep only approved safe metadata.

- [ ] **Step 2: Run the tests and verify Console records are currently omitted**

```bash
cargo test --manifest-path StacioCore/Cargo.toml session_repository_tests::persists_console
cargo test --manifest-path StacioCore/Cargo.toml import_service::tests::previews_stacio_json_console
```

Expected: the first test has no `console` match arm and the importer drops the record.

- [ ] **Step 3: Add a dedicated Console repository sanitizer**

In `protocol_config_json_for_session_with_override`, add only this new protocol branch:

```rust
"console" => {
    if session.port != 0 || session.host.trim().is_empty() {
        return Err(SessionError::InvalidPort);
    }
    let raw = config_json_override.ok_or(SessionError::InvalidPort)?;
    let config = parse_console_config(raw.to_string()).map_err(|error| SessionError::Database {
        message: error.to_string(),
    })?;
    serialize_console_config(config).map_err(|error| SessionError::Database {
        message: error.to_string(),
    })?
}
```

Do not route `console` through `serial_config_for_session`; do not read baud rate from `SessionRecord.port`; do not migrate old `serial` records.

- [ ] **Step 4: Make Stacio JSON import protocol-aware**

Change `stacio_json_preview_session` so `console` accepts port `0`, requires a non-empty name/host summary, parses the full Console config through `parse_console_config`, reserializes the validated value, and clears credential/private-key fields. Keep `sanitized_import_config_json` unchanged for SSH/SFTP/SCP/FTP/Telnet/VNC so executable automation remains filtered.

- [ ] **Step 5: Run repository/import regression tests and commit**

```bash
cargo test --manifest-path StacioCore/Cargo.toml session_repository_tests
cargo test --manifest-path StacioCore/Cargo.toml import_service
git add StacioCore/src/infrastructure/session_repository.rs StacioCore/src/services/import_service.rs
git commit -m "feat: persist BLE console sessions"
```

Expected: Console round-trip/import tests pass and existing import security tests remain green.

---

### Task 3: Add an external terminal runtime and regenerate bindings

**Files:**
- Modify: `StacioCore/src/domain/terminal.rs`
- Modify: `StacioCore/src/services/terminal_service.rs`
- Modify: `StacioCore/src/lib.rs`
- Modify: `Stacio/Bridge/Generated/Headers/stacio_coreFFI.h`
- Modify: `Stacio/Bridge/Generated/Headers/module.modulemap`
- Modify: `Stacio/Bridge/Generated/Sources/stacio_core.swift`
- Modify: `Stacio/Bridge/CoreBridge.swift`
- Test: `Tests/StacioAppTests/CoreBridgeTests.swift`

- [ ] **Step 1: Add a failing external-runtime Rust test**

```rust
#[test]
fn external_runtime_uses_existing_buffers_without_a_worker() {
    let mut registry = TerminalRuntimeRegistry::new(8);
    let runtime = registry.open_external(
        "ble_console".to_string(),
        "NBEE_BLE_1103".to_string(),
        80,
        24,
    ).expect("open external runtime");
    assert_eq!(runtime.kind, "ble_console");
    assert_eq!(runtime.remote_host.as_deref(), Some("NBEE_BLE_1103"));
    registry.record_output(runtime.id.clone(), b"ok".to_vec()).expect("record RX");
    assert_eq!(registry.take_output_batch(runtime.id.clone()).expect("batch").bytes, b"ok");
    registry.close(runtime.id.clone()).expect("close");
    assert!(matches!(
        registry.write_input(runtime.id.clone(), b"x".to_vec()),
        Err(TerminalRuntimeError::RuntimeClosed { .. })
    ));
}
```

Also test empty/unsafe kind and endpoint rejection.

- [ ] **Step 2: Run the focused test and verify `open_external` is absent**

```bash
cargo test --manifest-path StacioCore/Cargo.toml external_runtime
```

Expected: compilation fails on `open_external`.

- [ ] **Step 3: Implement and export external runtime creation**

Add this registry API:

```rust
pub fn open_external(
    &mut self,
    kind: String,
    endpoint: String,
    cols: u32,
    rows: u32,
) -> Result<TerminalRuntime, TerminalRuntimeError> {
    let kind = kind.trim();
    let endpoint = endpoint.trim();
    if kind != "ble_console" || endpoint.is_empty() || endpoint.chars().any(char::is_control) {
        return Err(TerminalRuntimeError::RuntimeIo { message: "invalid external runtime".to_string() });
    }
    Ok(self.register_runtime(TerminalRuntime {
        id: format!("term_{}", Uuid::new_v4()),
        kind: kind.to_string(),
        shell_path: String::new(),
        remote_host: Some(endpoint.to_string()),
        remote_port: None,
        username: None,
        cols,
        rows,
        resize_revision: 0,
        status: "running".to_string(),
        output_paused: false,
    }))
}
```

Export `open_external_terminal_runtime(kind:endpoint:cols:rows:)` from `lib.rs`. It must not register a live-shell channel or wake a serial/SSH worker.

- [ ] **Step 4: Regenerate UniFFI and add CoreBridge wrappers**

```bash
./scripts/generate-uniffi.sh
```

Add `CoreBridge.parseConsoleSessionConfig`, `serializeConsoleSessionConfig`, `matchBLEConsoleProfile`, `consoleTransportPolicy`, and `openExternalTerminalRuntime` wrappers. Add a Swift bridge test that opens `ble_console`, records bytes, takes the same bytes, resizes, pauses/resumes, and closes it.

- [ ] **Step 5: Run bridge tests and commit generated output with the source**

```bash
swift test --filter CoreBridgeTests
git add StacioCore/src/domain/terminal.rs StacioCore/src/services/terminal_service.rs StacioCore/src/lib.rs Stacio/Bridge/CoreBridge.swift Stacio/Bridge/Generated/Headers Stacio/Bridge/Generated/Sources Tests/StacioAppTests/CoreBridgeTests.swift
git commit -m "feat: add external BLE terminal runtime"
```

Expected: CoreBridge tests pass and generated checksums match the current Rust library.

---

### Task 4: Build pure discovery, recognition, sorting, and error models

**Files:**
- Create: `Stacio/Services/BLEConsoleModels.swift`
- Create: `Tests/StacioAppTests/BLEConsoleModelsTests.swift`
- Modify: `Stacio/App/L10n.swift`

- [ ] **Step 1: Write failing pure-model tests**

Cover exact and suffixed `NBEE_BLE_1103` recognition, case/whitespace normalization, nonmatching `NBEE_SPP_1103`, RSSI `127`, probable `FFE0`/`FFE1` consoles, stable identifier selection, 500 ms reorder throttling, stale-result eviction after a 10-second scan window, and sort order. Use this expected ordering:

```swift
XCTAssertEqual(
    BLEConsoleDeviceOrdering.sorted([otherStrong, probable, nbeeWeak]).map(\.identifier),
    [nbeeWeak.identifier, probable.identifier, otherStrong.identifier]
)
XCTAssertNil(BLEConsoleRSSI(rawValue: 127).decibels)
XCTAssertEqual(BLEConsoleRecognition(deviceName: " nbee_ble_1103-fw1 "), .nbee1103)
XCTAssertEqual(BLEConsoleRecognition(deviceName: "NBEE_SPP_1103"), .ordinary)
```

- [ ] **Step 2: Run the model tests and verify the types do not exist**

```bash
swift test --filter BLEConsoleModelsTests
```

Expected: compilation fails for missing BLE Console model types.

- [ ] **Step 3: Implement immutable presentation models**

Define `BLEConsoleDiscoveredDevice`, `BLEConsoleRSSI`, `BLEConsoleRecognition`, `BLEConsoleDiscoverySnapshot`, and `BLEConsoleDeviceOrdering`. Device identity must be the opaque `UUID` from CoreBluetooth; name is display-only. Sort by recognition group, probable-profile group, valid RSSI descending, case-insensitive name, then identifier. Preserve a selected identifier across snapshot replacement.

Define `BLEConsoleErrorCode` for every code frozen in the design and expose `title`, `message`, and `recovery` through `L10n.BLEConsole`. Diagnostics may include state/profile/RSSI/byte counts but never payload bytes or a full opaque platform identifier.

- [ ] **Step 4: Run tests and commit**

```bash
swift test --filter BLEConsoleModelsTests
git add Stacio/Services/BLEConsoleModels.swift Stacio/App/L10n.swift Tests/StacioAppTests/BLEConsoleModelsTests.swift
git commit -m "feat: add BLE console discovery models"
```

---

### Task 5: Add the injectable CoreBluetooth adapter

**Files:**
- Create: `Stacio/Services/BLEConsoleCentral.swift`
- Create: `Tests/StacioAppTests/BLEConsoleCentralTests.swift`
- Modify: `Package.swift`

- [ ] **Step 1: Write failing adapter-contract tests with a fake driver**

Test state mapping for unauthorized, powered off, unsupported, resetting, and powered on; no-filter scanning; a scheduler-driven 10-second scan timeout; cancellation/replacement of that timeout on stop/rescan; duplicate advertisement coalescing by identifier; eviction of devices not seen in the active scan window; latest RSSI/name; `retrievePeripherals` for a saved binding; characteristic property mapping; and generation propagation on every callback.

The fake must conform to this boundary:

```swift
protocol BLEConsoleCentralDriving: AnyObject {
    var eventHandler: (@Sendable (BLEConsoleCentralEvent) -> Void)? { get set }
    func startScan()
    func stopScan()
    func connect(identifier: UUID, generation: UInt64)
    func discoverProfile(identifier: UUID, generation: UInt64)
    func subscribe(identifier: UUID, characteristicUUID: String, generation: UInt64)
    func maximumWriteLength(identifier: UUID, withoutResponse: Bool) -> Int
    func canSendWriteWithoutResponse(identifier: UUID) -> Bool
    func write(identifier: UUID, characteristicUUID: String, data: Data, withoutResponse: Bool, generation: UInt64)
    func disconnect(identifier: UUID, generation: UInt64)
}
```

- [ ] **Step 2: Run the focused tests**

```bash
swift test --filter BLEConsoleCentralTests
```

Expected: compilation fails because the driver and event model are absent.

- [ ] **Step 3: Implement `CoreBluetoothBLEConsoleCentralDriver`**

Use a dedicated serial dispatch queue for `CBCentralManager`. Scan exactly with `scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])`. A scan generation owns an injected 10-second timeout; stopping or rescanning cancels the prior timeout, and results not observed in the active generation are removed before the final snapshot. Keep `[UUID: CBPeripheral]`, set each peripheral delegate before discovery, and convert CoreBluetooth objects into value DTOs before dispatching events.

The driver must emit events for state, advertisement, connected, connect failure, disconnected, services discovered, subscribed, RX data, write acknowledgement, and ready-to-send-without-response. Every connection event carries the generation supplied by the caller; scan events do not select or connect a device.

Map properties as booleans into generated `ConsoleCharacteristicMetadata`. Do not expose `CBPeripheral`, `CBService`, or `CBCharacteristic` outside this file.

- [ ] **Step 4: Add the explicit framework link and run tests**

Add `.linkedFramework("CoreBluetooth")` next to IOKit for `StacioApp`, then run:

```bash
swift test --filter BLEConsoleCentralTests
swift test --filter PackageManifestTests
```

Expected: all selected tests pass.

- [ ] **Step 5: Commit the adapter**

```bash
git add Package.swift Stacio/Services/BLEConsoleCentral.swift Tests/StacioAppTests/BLEConsoleCentralTests.swift Tests/StacioAppTests/PackageManifestTests.swift
git commit -m "feat: add CoreBluetooth console adapter"
```

---

### Task 6: Implement the BLE connection state machine and write queue

**Files:**
- Create: `Stacio/Services/BLEConsoleSession.swift`
- Create: `Tests/StacioAppTests/BLEConsoleSessionTests.swift`

- [ ] **Step 1: Write failing state, profile, TX, RX, and reconnect tests**

Use a fake `BLEConsoleCentralDriving` and an injected scheduler. Cover:

1. `idle -> connecting -> discovering -> subscribing -> connected` only after RX subscription succeeds.
2. Saved profile first, split FFE1 second, shared FFE0 third, mapper-required otherwise.
3. `.withoutResponse` uses the runtime maximum length and pauses while `canSendWriteWithoutResponse` is false.
4. `.withResponse` sends one chunk and waits for the matching acknowledgement.
5. 1, 20, 21, MTU-boundary, and 4 KiB byte sequences preserve order.
6. Queue overflow throws `BLE_CONSOLE_TX_QUEUE_FULL` without truncating accepted bytes.
7. RX `Data` is delivered unchanged as one byte batch and is never decoded as text.
8. Stale-generation callbacks are ignored.
9. Unexpected disconnect schedules only 1, 2, and 4 second retries.
10. Close/cancel clears callbacks, queue, and retry work and never reconnects.

Use explicit assertions:

```swift
let bytes: [UInt8] = (0..<21).map { UInt8($0) }
try session.enqueueWrite(bytes)
XCTAssertEqual(driver.writes.map(\.data.count), [20, 1])
XCTAssertEqual(driver.writes.flatMap { Array($0.data) }, bytes)

session.handle(.disconnected(identifier: deviceID, error: nil, generation: 1))
XCTAssertEqual(scheduler.delays, [1])
session.close()
scheduler.runAll()
XCTAssertEqual(driver.connectCalls.count, 1)
```

- [ ] **Step 2: Run the focused tests**

```bash
swift test --filter BLEConsoleSessionTests
```

Expected: compilation fails because `BLEConsoleSession` is missing.

- [ ] **Step 3: Implement the serialized session**

Make `BLEConsoleSession` `@MainActor` and define `BLEConsoleSessionState` with `idle`, `connecting`, `discovering`, `subscribing`, `connected`, `reconnecting(attempt:)`, `failed(code:)`, and `closed`.

Keep a monotonically increasing `generation`, selected device identifier, resolved profile, TX deque, queued byte count, in-flight with-response chunk, byte counters, and close flag. The queue limit is exactly `256 * 1024` bytes. Prefer without-response when both properties are present. Never use a fixed 20-byte limit; use the driver's maximum for the active write type.

Expose callbacks for state, RX bytes, profile-mapper request, and diagnostics. Unexpected disconnect may call only the same BLE driver; the initializer must not accept a serial starter, device path, or SPP adapter.

- [ ] **Step 4: Run tests and commit**

```bash
swift test --filter BLEConsoleSessionTests
git add Stacio/Services/BLEConsoleSession.swift Tests/StacioAppTests/BLEConsoleSessionTests.swift
git commit -m "feat: add BLE console session state machine"
```

---

### Task 7: Attach BLE sessions to the existing terminal pane

**Files:**
- Create: `Stacio/Services/ConsoleSessionCoordinator.swift`
- Create: `Tests/StacioAppTests/ConsoleSessionCoordinatorTests.swift`
- Modify: `Stacio/Views/Terminal/RemoteTerminalPaneViewController.swift`
- Modify: `Stacio/Views/Workspace/WorkspaceViewController.swift`
- Modify: `Tests/StacioAppTests/RemoteTerminalPaneViewControllerTests.swift`

- [ ] **Step 1: Write failing coordinator and pane tests**

Test that startup creates a `ble_console` external runtime, opens a connecting `.console` pane, attaches only after subscription, writes RX through `recordTerminalOutput`, sends pane input directly to `BLEConsoleSession.enqueueWrite`, forwards resize/pause, treats keepalive as no-op, and closes session/runtime idempotently.

Assert the macOS dependency graph contains no SPP fallback:

```swift
let coordinator = ConsoleSessionCoordinator(
    runtime: fakeRuntime,
    sessionFactory: { config in fakeSession(config: config) },
    workspace: workspace
)
_ = try coordinator.openSessionTab(config: nbeeConfig, title: "Core Switch")
XCTAssertEqual(fakeRuntime.openedKinds, ["ble_console"])
XCTAssertEqual(workspace.connectionKinds, [.console])
XCTAssertTrue(workspace.serialOpenRequests.isEmpty)
```

Add pane tests that `.console` reports protocol name `Console`, Return retries a stopped Console like Serial, and Console panes cannot be split/duplicated into a second connection.

- [ ] **Step 2: Run the focused tests**

```bash
swift test --filter 'ConsoleSessionCoordinatorTests|RemoteTerminalPaneViewControllerTests'
```

Expected: missing `.console`, coordinator, bridge, and event sink failures.

- [ ] **Step 3: Implement the runtime bridge and event sink**

Create:

```swift
final class BLEConsoleTerminalEventSink: TerminalEventSink {
    private weak var session: BLEConsoleSession?
    private let runtimeID: String
    func terminalDidResize(runtimeID: String, cols: Int, rows: Int) throws
    func terminalDidProduceOutput(runtimeID: String, bytes: [UInt8]) throws
    func terminalDidReceiveInput(runtimeID: String, bytes: [UInt8]) throws
    func terminalDidClose(runtimeID: String) throws
}

final class BLEConsoleRemoteTerminalBridge: RemoteTerminalBridging {
    private weak var session: BLEConsoleSession?
    func pollLiveSSHShell(runtimeID: String) throws -> LiveShellStatus
    func takeTerminalOutputBatch(runtimeID: String) throws -> TerminalOutputBatch
    func setTerminalOutputPaused(runtimeID: String, paused: Bool) throws -> TerminalRuntime
    func setLiveShellKeepaliveInterval(runtimeID: String, seconds: UInt32) throws
    func closeLiveSSHShell(runtimeID: String) throws -> LiveShellStatus
}
```

The bridge's poll status is `running` only while the BLE session is connected, reads output from CoreBridge, and performs no keepalive. Both close paths call one idempotent owner that stops BLE first and then closes the external runtime.

- [ ] **Step 4: Implement `ConsoleSessionCoordinator` and Console workspace opening**

Define `ConsoleSessionStarting` and a narrow `ConsoleWorkspaceOpening` protocol. `WorkspaceViewController.openConnectingConsole` must accept the coordinator-created event sink and bridge, create a `.console` pane with the real external runtime ID, call `displayConnectionStarting`, and use `SessionTabIconDescriptor.console`.

Add `.console` to `RemoteTerminalConnectionKind`. Do not register a duplicate-tab handler for Console and make `splitCurrentTerminal` return `WorkspaceTabActionError.unsupportedDuplicate` for `.console`; one peripheral binding must not silently create a second simultaneous GATT connection.

- [ ] **Step 5: Run tests and commit**

```bash
swift test --filter 'ConsoleSessionCoordinatorTests|RemoteTerminalPaneViewControllerTests|WorkspaceLocalShellTests'
git add Stacio/Services/ConsoleSessionCoordinator.swift Stacio/Views/Terminal/RemoteTerminalPaneViewController.swift Stacio/Views/Workspace/WorkspaceViewController.swift Tests/StacioAppTests/ConsoleSessionCoordinatorTests.swift Tests/StacioAppTests/RemoteTerminalPaneViewControllerTests.swift
git commit -m "feat: connect BLE sessions to terminal panes"
```

---

### Task 8: Build the native scanner sheet and characteristic mapper

**Files:**
- Create: `Stacio/Views/Dialogs/BLEConsoleScannerViewController.swift`
- Create: `Stacio/Views/Dialogs/BLEConsoleCharacteristicMapperViewController.swift`
- Create: `Tests/StacioAppTests/BLEConsoleScannerViewControllerTests.swift`

- [ ] **Step 1: Write failing AppKit contract tests**

Assert the scanner uses `NSSearchField`, view-based `NSTableView`, `NSScrollView`, indeterminate `NSProgressIndicator`, native Cancel/default Connect buttons, and an icon-only `arrow.clockwise` rescan button with tooltip. Assert Connect is disabled without selection, Return connects, Escape cancels, Command-R rescans, and discovery never auto-selects or auto-connects NBEE.

For each 40 pt row, assert:

```swift
XCTAssertEqual(controller.tableViewForTesting.rowHeight, 40)
XCTAssertEqual(controller.rowModel(at: 0).leadingSymbolName, "antenna.radiowaves.left.and.right")
XCTAssertEqual(controller.rowModel(at: 0).signalSymbolName, "cellularbars")
XCTAssertEqual(controller.rowModel(at: 0).rssiText, "-54 dBm")
XCTAssertEqual(controller.rowModel(at: 0).recognitionSymbolName, "checkmark.circle.fill")
XCTAssertEqual(controller.rowModel(at: 1).rssiText, "-- dBm")
```

Test search, long names, Light/Dark semantic colors, recognition tint distinct from selection, and `Stacio.BLEConsole.*` accessibility identifiers/labels.

- [ ] **Step 2: Run the UI tests**

```bash
swift test --filter BLEConsoleScannerViewControllerTests
```

Expected: compilation fails for missing scanner/mapper controllers.

- [ ] **Step 3: Implement the scanner sheet**

Use an attached `NSWindow` sheet with no decorative card containers. Device list updates are driven by `BLEConsoleDiscoverySnapshot`; throttle reordering to 500 ms and restore selection by identifier. Recognized NBEE devices remain in the first group with a low-intensity semantic accent background, but selection uses the normal system selection highlight.

The Connect action stops scanning, connects to the selected identifier, discovers characteristics, and asks CoreBridge to match a built-in profile. It returns a complete `ConsoleSessionConfig`, not a name-only candidate. This settings-time connection is only a binding probe: after the profile/config is confirmed, disconnect the peripheral before completing the sheet so saving settings never leaves the BLE Console occupied. Add a test that both built-in and custom-profile confirmation perform this disconnect exactly once.

- [ ] **Step 4: Implement the mapper for unknown profiles**

Show native popups for service, writable TX, notifiable/indicatable RX, and write type. Disable confirmation unless the selection satisfies the property contract. Save unknown mappings with `profileID == "custom-v1"` and normalized UUIDs. Cancel returns to the scanner without saving or connecting another device.

- [ ] **Step 5: Run tests and commit**

```bash
swift test --filter BLEConsoleScannerViewControllerTests
git add Stacio/Views/Dialogs/BLEConsoleScannerViewController.swift Stacio/Views/Dialogs/BLEConsoleCharacteristicMapperViewController.swift Tests/StacioAppTests/BLEConsoleScannerViewControllerTests.swift
git commit -m "feat: add native BLE console scanner"
```

---

### Task 9: Add Console to saved-session settings

**Files:**
- Create: `Stacio/Views/Dialogs/BLEConsoleSessionEditorView.swift`
- Modify: `Stacio/Views/Dialogs/SessionSettingsViewController.swift`
- Modify: `Stacio/Views/Sidebar/SessionSidebarSessionManagement.swift`
- Modify: `Tests/StacioAppTests/SessionSettingsViewControllerTests.swift`
- Modify: `Tests/StacioAppTests/SessionSidebarSessionFormTests.swift`

- [ ] **Step 1: Write failing settings and draft tests**

Assert `Console（蓝牙/串口）` is offered with storage key `console` and native `antenna.radiowaves.left.and.right`; its form hides port/user/auth/private-key/credential fields; the persisted port is exactly `0`; and save stays disabled for a new Console session until the user confirms a scanned device/profile.

Assert the resulting draft:

```swift
XCTAssertEqual(draft.protocol, "console")
XCTAssertEqual(draft.host, "NBEE_BLE_1103 (BLE)")
XCTAssertEqual(draft.port, 0)
XCTAssertNil(draft.username)
XCTAssertNil(draft.privateKeyPath)
XCTAssertNil(draft.credentialId)
let decoded = try CoreBridge.parseConsoleSessionConfig(json: try XCTUnwrap(draft.configJson))
XCTAssertEqual(decoded.ble.profileId, "bterm-ffe1-split-v1")
XCTAssertEqual(decoded.ble.platformBindings.macOsPeripheralUuid, deviceID.uuidString)
```

Also prove selecting old `serial` neither starts a BLE scan nor changes NBEE `/dev/tty` discovery.

- [ ] **Step 2: Run the focused tests**

```bash
swift test --filter 'SessionSettingsViewControllerTests|SessionSidebarSessionFormTests'
```

Expected: failures for the missing `console` protocol/form/editor.

- [ ] **Step 3: Implement the Console form mode and editor**

Add `.console` to `SessionSettingsProtocol` and `.console` to `SessionSidebarSessionFormMode`. The form mode uses a read-only endpoint summary field, fixed hidden port `0`, no credentials, and normal session name/tags. Embed `BLEConsoleSessionEditorView` beside the common fields; it shows the selected device/profile and an icon-plus-text scan/rebind command.

Inject `BLEConsoleScannerPresenting` into `SessionSettingsViewController` so tests never access Bluetooth. Decode an existing valid Console config for editing. An imported config with no current macOS binding remains saveable but visibly requires rebind before connection.

- [ ] **Step 4: Encode only the Console contract on save**

For `console`, bypass serial advanced config, set host to a readable `"<deviceName> (BLE)"` summary, set port to `0`, and call `CoreBridge.serializeConsoleSessionConfig`. Keep automation fields out of Console v1 config; do not merge SSH post-connect scripts into a device Console config.

- [ ] **Step 5: Run tests and commit**

```bash
swift test --filter 'SessionSettingsViewControllerTests|SessionSidebarSessionFormTests'
git add Stacio/Views/Dialogs/BLEConsoleSessionEditorView.swift Stacio/Views/Dialogs/SessionSettingsViewController.swift Stacio/Views/Sidebar/SessionSidebarSessionManagement.swift Tests/StacioAppTests/SessionSettingsViewControllerTests.swift Tests/StacioAppTests/SessionSidebarSessionFormTests.swift
git commit -m "feat: add BLE console session settings"
```

---

### Task 10: Route saved Console sessions and complete terminal capability integration

**Files:**
- Modify: `Stacio/Windows/WorkbenchWindowController.swift`
- Modify: `Stacio/Views/Sidebar/SessionSidebarViewController.swift`
- Modify: `Stacio/Views/Workspace/SessionTabIconDescriptor.swift`
- Modify: `Stacio/Views/Workspace/WorkspaceViewController.swift`
- Modify: `Stacio/Services/WorkspaceCapabilityPolicy.swift`
- Modify: `Tests/StacioAppTests/SavedSessionConnectionFlowTests.swift`
- Modify: `Tests/StacioAppTests/SessionTabIconDescriptorTests.swift`
- Modify: `Tests/StacioAppTests/WorkspaceCapabilityPolicyTests.swift`
- Modify: `Tests/StacioAppTests/MultiExecCoordinatorTests.swift`

- [ ] **Step 1: Write failing saved-session and capability tests**

Inject a `ConsoleSessionStarting` spy into Workbench. Assert saved `console` config is decoded and opened, invalid/unknown schema is rejected with `BLE_CONSOLE_CONFIG_INVALID`, and success is marked opened without touching `SerialSessionStarting`.

Assert Sidebar and tab descriptors use `antenna.radiowaves.left.and.right`; Console panes are eligible MultiExec targets; terminal macro and Agent input call the same pane input path; and policy results are:

```swift
XCTAssertTrue(WorkspaceCapabilityPolicy.allows(.ai, for: .console))
XCTAssertTrue(WorkspaceCapabilityPolicy.allows(.diagnostics, for: .console))
XCTAssertFalse(WorkspaceCapabilityPolicy.allows(.files, for: .console))
XCTAssertFalse(WorkspaceCapabilityPolicy.allows(.tunnels, for: .console))
XCTAssertFalse(WorkspaceCapabilityPolicy.allows(.deviceDashboard, for: .console))
```

- [ ] **Step 2: Run the focused tests**

```bash
swift test --filter 'SavedSessionConnectionFlowTests|SessionTabIconDescriptorTests|WorkspaceCapabilityPolicyTests|MultiExecCoordinatorTests'
```

Expected: `.console` routing, icon, and policy assertions fail.

- [ ] **Step 3: Add Workbench routing**

Add optional injected `consoleSessionStarter`, lazy `resolvedConsoleSessionStarter()`, and a `normalizedProtocol == "console"` branch before unsupported-protocol handling. Fetch config with `CoreBridge.getSessionConfigJSON`, parse it with CoreBridge, require a current macOS binding before connecting, call `openSessionTab`, and mark the saved session opened. Never call `resolvedSerialSessionStarter` from this branch.

- [ ] **Step 4: Add native icons and terminal-only capabilities**

Add `WorkspaceSessionProtocol.console`, `RemoteTerminalConnectionKind.console` mappings, MultiExec eligibility, Agent summary kind `console`, and a `SessionTabIconDescriptor.console` that uses only the verified SF Symbol. Do not create a custom Bluetooth logo or modify the existing Serial `cable.connector` icon.

Make device-dashboard creation return nil for Console. Leave Files, Tunnels, remote OS probing, and SSH upload-drop support disabled.

- [ ] **Step 5: Run tests and commit**

```bash
swift test --filter 'SavedSessionConnectionFlowTests|SessionTabIconDescriptorTests|WorkspaceCapabilityPolicyTests|MultiExecCoordinatorTests|WorkspaceSessionGroupTests'
git add Stacio/Windows/WorkbenchWindowController.swift Stacio/Views/Sidebar/SessionSidebarViewController.swift Stacio/Views/Workspace/SessionTabIconDescriptor.swift Stacio/Views/Workspace/WorkspaceViewController.swift Stacio/Services/WorkspaceCapabilityPolicy.swift Tests/StacioAppTests/SavedSessionConnectionFlowTests.swift Tests/StacioAppTests/SessionTabIconDescriptorTests.swift Tests/StacioAppTests/WorkspaceCapabilityPolicyTests.swift Tests/StacioAppTests/MultiExecCoordinatorTests.swift
git commit -m "feat: open saved BLE console sessions"
```

---

### Task 11: Add packaged Bluetooth permission metadata

**Files:**
- Modify: `scripts/package-app.sh`
- Modify: `Tests/Packaging/package_app_test.sh`
- Modify: `Tests/StacioAppTests/PackageManifestTests.swift`

- [ ] **Step 1: Add a failing package assertion**

After the test package is created, assert:

```bash
/usr/libexec/PlistBuddy -c 'Print :NSBluetoothAlwaysUsageDescription' "$PLIST" \
  | grep -Fxq 'Stacio 使用蓝牙连接你选择的 BLE Console 设备。'
```

Also assert `Package.swift` links `CoreBluetooth`.

- [ ] **Step 2: Run the packaging contract test**

```bash
bash Tests/Packaging/package_app_test.sh
```

Expected: failure because the key is absent.

- [ ] **Step 3: Add the usage description to the generated Info.plist**

Add exactly:

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>Stacio 使用蓝牙连接你选择的 BLE Console 设备。</string>
```

Do not add a speculative sandbox entitlement; the current package is not sandboxed.

- [ ] **Step 4: Run tests and commit**

```bash
bash Tests/Packaging/package_app_test.sh
swift test --filter PackageManifestTests
git add scripts/package-app.sh Tests/Packaging/package_app_test.sh Tests/StacioAppTests/PackageManifestTests.swift
git commit -m "fix: declare BLE console permission"
```

---

### Task 12: Write the Bug index and Windows handoff, then update the real code index

**Files:**
- Create: `docs/development/ble-console-bug-index.md`
- Modify: `docs/platform/windows-adaptation-plan.md`
- Modify: `docs/development/code-index.md`

- [ ] **Step 1: Create the independent BLE Console Bug index**

Use columns `ID`, `Error code`, `Symptom`, `Reproduction`, `Evidence`, `Owner`, `Fix`, `Regression test`, and `Status`. Seed entries for RSSI 127, duplicate/reordered rows, BTerm/mobile occupancy, stale generation, duplicate subscription, without-response deadlock, paste truncation/order/replay, close-after-reconnect, sleep/wake binding loss, missing usage description, Windows wrong-COM fallback, and legacy Serial regression.

Every row must point to a concrete test or the NBEE manual matrix; use `Not reproduced`, `Covered`, `Needs hardware`, or `Windows future` rather than claiming an unverified fix.

- [ ] **Step 2: Add a Windows BLE/SPP section**

Document the shared DTO/profile/policy APIs, WinRT mapping (`DeviceWatcher`, `BluetoothLEDevice`, `GattDeviceService`, `GattCharacteristic`), exact saved COM validation, BLE retry before fallback, and the prohibition on name-based/random COM selection. State that macOS ignores `sppFallback` even when synchronized.

- [ ] **Step 3: Update `code-index.md` from the implemented tree**

Add only files that exist and describe their observed responsibilities. Change current protocol lists to include Console where the code now supports it, while preserving Serial as its own path. Do not copy planned filenames that were not created.

- [ ] **Step 4: Check and commit documentation**

```bash
rg -n 'TB[D]|TO[D]O|FIXM[E]|待[补]|占[位]' docs/development/ble-console-bug-index.md docs/platform/windows-adaptation-plan.md docs/development/code-index.md
git diff --check -- docs/development/ble-console-bug-index.md docs/platform/windows-adaptation-plan.md docs/development/code-index.md
git add -f docs/development/ble-console-bug-index.md docs/platform/windows-adaptation-plan.md docs/development/code-index.md
git commit -m "docs: add BLE console implementation handoff"
```

Expected: placeholder scan has no output and diff check succeeds.

---

### Task 13: Run full regression and hardware acceptance without packaging or publishing

**Files:**
- Verify all files changed in Tasks 1-12
- Update: `docs/development/ble-console-bug-index.md` only with observed results

- [ ] **Step 1: Run Rust tests serially**

```bash
cargo test --manifest-path StacioCore/Cargo.toml
cargo fmt --manifest-path StacioCore/Cargo.toml -- --check
```

Expected: zero failures; existing Serial/NBEE path tests remain unchanged and pass.

- [ ] **Step 2: Regenerate bindings once and run Swift tests serially**

```bash
./scripts/generate-uniffi.sh
swift test --filter 'BLEConsole|ConsoleSession|SessionSettingsViewControllerTests|SavedSessionConnectionFlowTests|RemoteTerminalPaneViewControllerTests|WorkspaceCapabilityPolicyTests|MultiExecCoordinatorTests|CoreBridgeTests|SerialSessionCoordinatorTests'
swift test
```

Expected: zero failures. Do not run Swift builds/tests concurrently because this checkout shares one `.build` lock.

- [ ] **Step 3: Run packaging metadata and source hygiene checks**

```bash
bash Tests/Packaging/package_app_test.sh
git diff --check
rg -n 'NBEE_SPP_|/dev/cu\.|SerialRuntimeStarting' Stacio/Services/BLEConsoleModels.swift Stacio/Services/BLEConsoleCentral.swift Stacio/Services/BLEConsoleSession.swift Stacio/Services/ConsoleSessionCoordinator.swift
```

Expected: package test passes, diff check is clean, and the macOS BLE implementation grep has no output.

- [ ] **Step 4: Perform the NBEE hardware matrix from a development build**

With phone BTerm disconnected, verify discovery within 10 seconds, NBEE pin/highlight without auto-connect, valid RSSI, FFE1/FFE3/FFE2 matching, prompt bytes after CR, 10 connect/disconnect cycles, 1/20/21/MTU/4 KiB writes, phone occupancy, power loss, range loss, Bluetooth off, and sleep/wake. Confirm no `/dev/cu.NBEE_SPP_*` node is opened during every failure case.

Record only observed outcomes in the Bug index. A hardware item that was not run remains `Needs hardware`; do not mark end-to-end BLE Console complete from unit tests alone.

- [ ] **Step 5: Review the final diff and commit only feature-owned changes**

```bash
git status --short -uall
git diff --stat 4c9003a6..HEAD
git diff --check 4c9003a6..HEAD
```

Inspect every path before the final commit. Preserve the unrelated Files/SCP/PPT/video work already present in `/Users/mac/Documents/Stacio`. Do not package an App/DMG, push, publish, or deploy without separate authorization.

---

## Completion Evidence

Implementation is complete only when all of the following are true:

1. Core contract, repository/import, external runtime, CoreBluetooth adapter, BLE session, coordinator, UI, settings, Workbench routing, permission metadata, and documentation tasks are implemented.
2. macOS Console code has no SPP/serial fallback dependency and no BLE failure path opens `/dev/cu.*`.
3. `NBEE_BLE_1103` is pinned and highlighted but still requires explicit user selection.
4. All visible devices show a name fallback, native signal icon, and numeric RSSI or `-- dBm`.
5. FFE1/FFE3/FFE2 and FFE0/FFE1 profiles pass contract tests; unknown profiles use the validated mapper.
6. TX backpressure/chunking and RX byte preservation pass deterministic tests.
7. Existing Serial, USB, manual SPP, SSH, Telnet, Files, MultiExec, macro, and Agent regressions pass.
8. The packaged Info.plist contract includes the Bluetooth purpose string.
9. Bug index and Windows BLE-first/exact-COM handoff are current.
10. Real NBEE communication is reported separately from automated evidence and is not overclaimed.
