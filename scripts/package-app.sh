#!/usr/bin/env bash
set -euo pipefail

SCRIPT_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT_DIR="${STACIO_PACKAGE_ROOT_OVERRIDE:-$SCRIPT_ROOT_DIR}"
APP_NAME="Stacio"
BUNDLE_ID="com.stacio.Stacio"
VERSION="${STACIO_VERSION:-0.13.5}"
BUILD_NUMBER="${STACIO_BUILD_NUMBER:-${GITHUB_RUN_NUMBER:-}}"
SWIFT_BUILD_TRIPLE="${STACIO_SWIFT_BUILD_TRIPLE:-}"
CARGO_BUILD_TARGET="${STACIO_CARGO_BUILD_TARGET:-}"
OUTPUT_DIR="${STACIO_OUTPUT_DIR:-$ROOT_DIR/dist}"
CODESIGN_IDENTITY="${STACIO_CODESIGN_IDENTITY:--}"
CODESIGN_ARGS=(--force)
CODESIGN_APP_ARGS=(--force)
if [[ "$CODESIGN_IDENTITY" != "-" ]]; then
  CODESIGN_ARGS+=(--options runtime --timestamp)
  CODESIGN_APP_ARGS+=(--options runtime --timestamp)
fi
SPARKLE_CODESIGN_ARGS=("${CODESIGN_ARGS[@]}" --preserve-metadata=identifier,entitlements,requirements)
PRODUCT_OPS_PRODUCT_ID="${STACIO_PRODUCT_OPS_PRODUCT_ID:-stacio}"
PRODUCT_OPS_API_BASE_URL="${STACIO_PRODUCT_OPS_API_BASE_URL:-}"
PRODUCT_OPS_UPDATE_CHANNEL="${STACIO_PRODUCT_OPS_UPDATE_CHANNEL:-stable}"
PRODUCT_OPS_BETA_UPDATES_ENABLED="${STACIO_PRODUCT_OPS_BETA_UPDATES_ENABLED:-0}"
FEEDBACK_PRODUCT_API_KEY="${STACIO_FEEDBACK_PRODUCT_API_KEY:-}"
SPARKLE_STABLE_APPCAST_URL="${STACIO_SPARKLE_STABLE_APPCAST_URL:-}"
SPARKLE_BETA_APPCAST_URL="${STACIO_SPARKLE_BETA_APPCAST_URL:-}"
SPARKLE_UPDATE_ARCHITECTURE="${STACIO_SPARKLE_ARCHITECTURE:-}"
SPARKLE_PUBLIC_ED_KEY="${STACIO_SPARKLE_PUBLIC_ED_KEY:-}"
LICENSE_PUBLIC_ED25519_KEY="${STACIO_LICENSE_PUBLIC_ED25519_KEY:-}"
ALLOW_INCOMPLETE_PRODUCT_OPS_CONFIG="${STACIO_ALLOW_INCOMPLETE_PRODUCT_OPS_CONFIG:-0}"
APP_DIR="$OUTPUT_DIR/$APP_NAME.app"
LOCK_DIR="${STACIO_PACKAGE_LOCK_DIR:-$OUTPUT_DIR/.package-app.lock}"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
ADAPTERS_DIR="$CONTENTS_DIR/Adapters"
HELPERS_DIR="$CONTENTS_DIR/Helpers"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
SWIFTTERM_RESOURCE_BUNDLE_NAME="SwiftTerm_SwiftTerm.bundle"
SWIFTTERM_RESOURCE_BUNDLE_OUTPUT="$RESOURCES_DIR/$SWIFTTERM_RESOURCE_BUNDLE_NAME"
SWIFTTERM_CHECKOUT_PATH="${STACIO_SWIFTTERM_CHECKOUT_PATH:-$ROOT_DIR/.build/checkouts/SwiftTerm}"
SWIFTTERM_RESOURCE_PATCHER="$ROOT_DIR/scripts/patch-swiftterm-macos-resources.sh"
PLIST_PATH="$CONTENTS_DIR/Info.plist"
APP_ICON_SOURCE="$ROOT_DIR/logo/icon.icns"
APP_ICON_OUTPUT="$RESOURCES_DIR/Stacio.icns"
ABOUT_RESOURCES_SOURCE="$ROOT_DIR/Stacio/Resources/About"
ABOUT_RESOURCES_OUTPUT="$RESOURCES_DIR/About"
GITHUB_ICON_SOURCE="$ROOT_DIR/Stacio/Resources/github.svg"
GITHUB_ICON_OUTPUT="$RESOURCES_DIR/github.svg"
GITEE_ICON_SOURCE="$ROOT_DIR/Stacio/Resources/gitee.svg"
GITEE_ICON_OUTPUT="$RESOURCES_DIR/gitee.svg"
SESSION_ICONS_SOURCE="$ROOT_DIR/Stacio/Resources/SessionIcons"
SESSION_ICONS_OUTPUT="$RESOURCES_DIR/SessionIcons"
IMPORT_SOURCE_ICONS_SOURCE="$ROOT_DIR/Stacio/Resources/ImportSourceIcons"
IMPORT_SOURCE_ICONS_OUTPUT="$RESOURCES_DIR/ImportSourceIcons"
MONACO_VS_SOURCE="${STACIO_MONACO_VS_PATH:-$ROOT_DIR/node_modules/monaco-editor/min/vs}"
MONACO_OUTPUT="$RESOURCES_DIR/MonacoEditor/vs"
VNC_ADAPTER_PRODUCT="StacioVNCAdapter"
CLI_PRODUCT="StacioCLI"
CLI_HELPER_NAME="stacio"
PACKAGE_TMP_DIR=""
PACKAGE_LOCK_ACQUIRED=0

cleanup_tmp() {
  if [[ -n "$PACKAGE_TMP_DIR" ]]; then
    rm -rf "$PACKAGE_TMP_DIR"
  fi
  if [[ "$PACKAGE_LOCK_ACQUIRED" == "1" ]]; then
    rm -rf "$LOCK_DIR"
  fi
}
trap cleanup_tmp EXIT

acquire_package_lock() {
  if [[ "${STACIO_SKIP_PACKAGE_LOCK:-0}" == "1" ]]; then
    return
  fi

  mkdir -p "$OUTPUT_DIR"
  local timeout_seconds="${STACIO_PACKAGE_LOCK_TIMEOUT_SECONDS:-120}"
  local waited_seconds=0

  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    local holder_pid=""
    if [[ -f "$LOCK_DIR/pid" ]]; then
      holder_pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
    fi
    if [[ "$holder_pid" =~ ^[0-9]+$ ]] && ! kill -0 "$holder_pid" 2>/dev/null; then
      rm -rf "$LOCK_DIR"
      continue
    fi
    if (( waited_seconds >= timeout_seconds )); then
      echo "Another Stacio package-app.sh appears to be running for $OUTPUT_DIR." >&2
      echo "Lock: $LOCK_DIR" >&2
      echo "Set STACIO_PACKAGE_LOCK_TIMEOUT_SECONDS to wait longer, or STACIO_SKIP_PACKAGE_LOCK=1 to bypass intentionally." >&2
      exit 1
    fi
    sleep 1
    waited_seconds=$((waited_seconds + 1))
  done

  PACKAGE_LOCK_ACQUIRED=1
  printf '%s\n' "$$" >"$LOCK_DIR/pid"
}

source_snapshot() {
  local paths=()
  local candidate
  for candidate in \
    "$ROOT_DIR/Package.swift" \
    "$ROOT_DIR/Package.resolved" \
    "$ROOT_DIR/Stacio" \
    "$ROOT_DIR/StacioAdapters" \
    "$ROOT_DIR/StacioAgentBridge" \
    "$ROOT_DIR/StacioCLI" \
    "$ROOT_DIR/StacioExecutable" \
    "$ROOT_DIR/StacioCore/Cargo.toml" \
    "$ROOT_DIR/StacioCore/Cargo.lock" \
    "$ROOT_DIR/StacioCore/migrations" \
    "$ROOT_DIR/StacioCore/src" \
    "$ROOT_DIR/StacioCore/uniffi-bindgen-swift.rs" \
    "$APP_ICON_SOURCE" \
    "$GITHUB_ICON_SOURCE" \
    "$GITEE_ICON_SOURCE" \
    "$SESSION_ICONS_SOURCE" \
    "$IMPORT_SOURCE_ICONS_SOURCE" \
    "$ABOUT_RESOURCES_SOURCE" \
    "$MONACO_VS_SOURCE" \
    "$ROOT_DIR/scripts/package-app.sh"
  do
    if [[ -e "$candidate" ]]; then
      paths+=("$candidate")
    fi
  done

  if (( ${#paths[@]} == 0 )); then
    printf 'empty\n'
    return
  fi

  find "${paths[@]}" -type f -print0 \
    | xargs -0 stat -f '%m %z %N' \
    | LC_ALL=C sort \
    | shasum \
    | awk '{print $1}'
}

resolve_build_number() {
  if [[ -n "$BUILD_NUMBER" ]]; then
    return
  fi

  local shallow_state
  shallow_state="$(git -C "$ROOT_DIR" rev-parse --is-shallow-repository 2>/dev/null || printf 'unknown')"
  if [[ "$shallow_state" == "true" ]]; then
    echo "STACIO_BUILD_NUMBER or GITHUB_RUN_NUMBER is required for a shallow checkout." >&2
    exit 1
  fi

  BUILD_NUMBER="$(git -C "$ROOT_DIR" rev-list --count HEAD 2>/dev/null || true)"
  if [[ -z "$BUILD_NUMBER" ]]; then
    echo "Unable to derive STACIO_BUILD_NUMBER; set STACIO_BUILD_NUMBER explicitly." >&2
    exit 1
  fi
}

check_prebuilt_artifact_freshness() {
  local label="$1"
  local artifact="$2"
  shift 2

  python3 - "$label" "$artifact" "$@" <<'PY'
import os
import sys

label, artifact, *roots = sys.argv[1:]
excluded = {".git", ".build", ".swiftpm", "Resources", "dist", "node_modules", "target", "后台", "官网"}
newest_path = None
newest_ns = -1

def consider(path):
    global newest_path, newest_ns
    try:
        modified = os.stat(path).st_mtime_ns
    except OSError:
        return
    if modified > newest_ns:
        newest_path = path
        newest_ns = modified

for root in roots:
    if os.path.isfile(root):
        consider(root)
        continue
    if not os.path.isdir(root):
        continue
    for current, directories, files in os.walk(root):
        directories[:] = [name for name in directories if name not in excluded]
        for filename in files:
            consider(os.path.join(current, filename))

if newest_path is None:
    raise SystemExit(f"No source inputs found for {label} freshness verification.")
try:
    artifact_ns = os.stat(artifact).st_mtime_ns
except OSError:
    raise SystemExit(f"Prebuilt {label} is missing: {artifact}")
if artifact_ns <= newest_ns:
    raise SystemExit(f"Prebuilt {label} is older than source input: {newest_path}")
PY
}

wait_for_source_quiescence() {
  if [[ "${STACIO_SKIP_SOURCE_QUIESCENCE:-0}" == "1" ]]; then
    return
  fi

  local quiet_seconds="${STACIO_SOURCE_QUIET_SECONDS:-2}"
  local timeout_seconds="${STACIO_SOURCE_QUIET_TIMEOUT_SECONDS:-30}"
  local started_at
  started_at="$(date +%s)"

  while true; do
    local before after elapsed
    before="$(source_snapshot)"
    sleep "$quiet_seconds"
    after="$(source_snapshot)"
    if [[ "$before" == "$after" ]]; then
      return
    fi

    elapsed=$(($(date +%s) - started_at))
    if (( elapsed >= timeout_seconds )); then
    echo "Stacio source files are still changing; wait for concurrent edits to finish before packaging." >&2
      echo "Set STACIO_SKIP_SOURCE_QUIESCENCE=1 to bypass this guard intentionally." >&2
      exit 1
    fi
    echo "Waiting for Stacio source files to stop changing before packaging..." >&2
  done
}

acquire_package_lock

resolve_build_number

if [[ "$ALLOW_INCOMPLETE_PRODUCT_OPS_CONFIG" != "0" && "$ALLOW_INCOMPLETE_PRODUCT_OPS_CONFIG" != "1" ]]; then
  echo "STACIO_ALLOW_INCOMPLETE_PRODUCT_OPS_CONFIG must be 0 or 1." >&2
  exit 1
fi

if [[ -z "${VERSION//[[:space:]]/}" ]]; then
  echo "STACIO_VERSION must not be empty." >&2
  exit 1
fi

if [[ ! "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  echo "STACIO_BUILD_NUMBER must be a positive integer." >&2
  exit 1
fi

if [[ -n "${STACIO_PREVIOUS_BUILD_NUMBER:-}" ]]; then
  if [[ ! "$STACIO_PREVIOUS_BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
    echo "STACIO_PREVIOUS_BUILD_NUMBER must be a positive integer." >&2
    exit 1
  fi
  if (( BUILD_NUMBER <= STACIO_PREVIOUS_BUILD_NUMBER )); then
    echo "STACIO_BUILD_NUMBER must be greater than STACIO_PREVIOUS_BUILD_NUMBER." >&2
    exit 1
  fi
fi

if [[ -n "$SWIFT_BUILD_TRIPLE" && -z "$CARGO_BUILD_TARGET" ]] \
  || [[ -z "$SWIFT_BUILD_TRIPLE" && -n "$CARGO_BUILD_TARGET" ]]; then
  echo "STACIO_SWIFT_BUILD_TRIPLE and STACIO_CARGO_BUILD_TARGET must be set together." >&2
  exit 1
fi

EXPECTED_NATIVE_ARCH=""
SWIFT_BUILD_TARGET_ARGS=()
CARGO_BUILD_TARGET_ARGS=()
CORE_TARGET_DIR="$ROOT_DIR/StacioCore/target"
CORE_LINK_LIBRARY_DIR="$CORE_TARGET_DIR/debug"
CORE_DYLIB_DEFAULT="$CORE_TARGET_DIR/release/libstacio_core.dylib"
CORE_LOAD_PATH_DEFAULT="$CORE_TARGET_DIR/debug/deps/libstacio_core.dylib"
if [[ -n "$SWIFT_BUILD_TRIPLE" ]]; then
  EXPECTED_NATIVE_ARCH="${SWIFT_BUILD_TRIPLE%%-*}"
  case "$EXPECTED_NATIVE_ARCH:$CARGO_BUILD_TARGET" in
    arm64:aarch64-apple-darwin|x86_64:x86_64-apple-darwin)
      ;;
    *)
      echo "Unsupported Stacio cross-build target pair: $SWIFT_BUILD_TRIPLE / $CARGO_BUILD_TARGET" >&2
      exit 1
      ;;
  esac
  SWIFT_BUILD_TARGET_ARGS=(--triple "$SWIFT_BUILD_TRIPLE")
  CARGO_BUILD_TARGET_ARGS=(--target "$CARGO_BUILD_TARGET")
  CORE_TARGET_DIR="$CORE_TARGET_DIR/$CARGO_BUILD_TARGET"
  CORE_LINK_LIBRARY_DIR="$CORE_TARGET_DIR/release"
  CORE_DYLIB_DEFAULT="$CORE_TARGET_DIR/release/libstacio_core.dylib"
  CORE_LOAD_PATH_DEFAULT="$CORE_TARGET_DIR/release/deps/libstacio_core.dylib"
fi

if [[ -z "$SPARKLE_UPDATE_ARCHITECTURE" ]]; then
  SPARKLE_UPDATE_ARCHITECTURE="${EXPECTED_NATIVE_ARCH:-$(uname -m)}"
fi
case "$SPARKLE_UPDATE_ARCHITECTURE" in
  arm64|x86_64)
    ;;
  *)
    echo "STACIO_SPARKLE_ARCHITECTURE must be arm64 or x86_64: $SPARKLE_UPDATE_ARCHITECTURE" >&2
    exit 1
    ;;
esac
if [[ -z "$SPARKLE_STABLE_APPCAST_URL" ]]; then
  SPARKLE_STABLE_APPCAST_URL="https://ops.stacio.cn/updates/stacio/stable/$SPARKLE_UPDATE_ARCHITECTURE/appcast.xml"
fi
if [[ -z "$SPARKLE_BETA_APPCAST_URL" ]]; then
  SPARKLE_BETA_APPCAST_URL="https://ops.stacio.cn/updates/stacio/beta/$SPARKLE_UPDATE_ARCHITECTURE/appcast.xml"
fi
if [[ "$ALLOW_INCOMPLETE_PRODUCT_OPS_CONFIG" != "1" ]]; then
  for appcast_url in "$SPARKLE_STABLE_APPCAST_URL" "$SPARKLE_BETA_APPCAST_URL"; do
    if [[ "$appcast_url" != */"$SPARKLE_UPDATE_ARCHITECTURE"/appcast.xml ]]; then
      echo "Sparkle appcast URLs must target $SPARKLE_UPDATE_ARCHITECTURE packages: $appcast_url" >&2
      exit 1
    fi
  done
fi

swift_release_build() {
  if (( ${#SWIFT_BUILD_TARGET_ARGS[@]} == 0 )); then
    STACIO_CORE_LIBRARY_DIR="$CORE_LINK_LIBRARY_DIR" \
      swift build -c release --package-path "$ROOT_DIR" "$@"
  else
    STACIO_CORE_LIBRARY_DIR="$CORE_LINK_LIBRARY_DIR" \
      swift build -c release "${SWIFT_BUILD_TARGET_ARGS[@]}" --package-path "$ROOT_DIR" "$@"
  fi
}

verify_expected_native_architecture() {
  local label="$1"
  local binary_path="$2"
  [[ -n "$EXPECTED_NATIVE_ARCH" ]] || return 0

  local architectures
  architectures="$(lipo -archs "$binary_path" 2>/dev/null || true)"
  if ! tr ' ' '\n' <<<"$architectures" | grep -Fxq "$EXPECTED_NATIVE_ARCH"; then
    echo "$label does not contain expected $EXPECTED_NATIVE_ARCH architecture: ${architectures:-<unreadable>}" >&2
    exit 1
  fi
}

validate_ed25519_public_key() {
  local name="$1"
  local value="$2"
  local format="$3"
  python3 - "$name" "$value" "$format" <<'PY'
import base64
import binascii
import sys

name, configured, key_format = sys.argv[1:4]
spki_prefix = bytes([
    0x30, 0x2A,
    0x30, 0x05,
    0x06, 0x03, 0x2B, 0x65, 0x70,
    0x03, 0x21, 0x00,
])

def decode_base64(value):
    compact = "".join(value.split())
    return base64.b64decode(compact, validate=True)

def decode_pem(value):
    body = value.replace("-----BEGIN PUBLIC KEY-----", "").replace("-----END PUBLIC KEY-----", "")
    return decode_base64(body)

def is_license_key(value):
    try:
        if "-----BEGIN PUBLIC KEY-----" in value:
            decoded = decode_pem(value)
            return len(decoded) == 44 and decoded.startswith(spki_prefix)
        decoded = decode_base64(value)
        if len(decoded) == 32:
            return True
        if len(decoded) == 44 and decoded.startswith(spki_prefix):
            return True
        try:
            decoded_text = decoded.decode("utf-8")
        except UnicodeDecodeError:
            return False
        if "-----BEGIN PUBLIC KEY-----" not in decoded_text:
            return False
        pem_decoded = decode_pem(decoded_text)
        return len(pem_decoded) == 44 and pem_decoded.startswith(spki_prefix)
    except (ValueError, binascii.Error):
        return False

try:
    valid = (
        len(decode_base64(configured)) == 32
        if key_format == "sparkle"
        else is_license_key(configured)
    )
except (ValueError, binascii.Error):
    valid = False

if not valid:
    raise SystemExit(f"{name} must contain a valid Ed25519 public key.")
PY
}

if [[ "$ALLOW_INCOMPLETE_PRODUCT_OPS_CONFIG" != "1" ]]; then
  missing_product_ops_config=()
  [[ -n "${PRODUCT_OPS_API_BASE_URL//[[:space:]]/}" ]] || missing_product_ops_config+=("STACIO_PRODUCT_OPS_API_BASE_URL")
  [[ -n "${FEEDBACK_PRODUCT_API_KEY//[[:space:]]/}" ]] || missing_product_ops_config+=("STACIO_FEEDBACK_PRODUCT_API_KEY")
  [[ -n "${SPARKLE_PUBLIC_ED_KEY//[[:space:]]/}" ]] || missing_product_ops_config+=("STACIO_SPARKLE_PUBLIC_ED_KEY")
  [[ -n "${LICENSE_PUBLIC_ED25519_KEY//[[:space:]]/}" ]] || missing_product_ops_config+=("STACIO_LICENSE_PUBLIC_ED25519_KEY")
  if (( ${#missing_product_ops_config[@]} > 0 )); then
    echo "Required Product Ops packaging configuration is missing:" >&2
    printf '  %s\n' "${missing_product_ops_config[@]}" >&2
    echo "Set STACIO_ALLOW_INCOMPLETE_PRODUCT_OPS_CONFIG=1 only for a local development smoke build." >&2
    exit 1
  fi
  validate_ed25519_public_key "STACIO_SPARKLE_PUBLIC_ED_KEY" "$SPARKLE_PUBLIC_ED_KEY" sparkle
  validate_ed25519_public_key "STACIO_LICENSE_PUBLIC_ED25519_KEY" "$LICENSE_PUBLIC_ED25519_KEY" license
fi

if [[ "${STACIO_SKIP_BUILD:-0}" != "1" ]]; then
  wait_for_source_quiescence
  if [[ ! -f "$SWIFTTERM_CHECKOUT_PATH/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift" ]]; then
    swift package resolve --package-path "$ROOT_DIR"
  fi
  "$SWIFTTERM_RESOURCE_PATCHER" "$SWIFTTERM_CHECKOUT_PATH"
  if (( ${#CARGO_BUILD_TARGET_ARGS[@]} == 0 )); then
    cargo build --manifest-path "$ROOT_DIR/StacioCore/Cargo.toml" --release
  else
    cargo build --manifest-path "$ROOT_DIR/StacioCore/Cargo.toml" --release "${CARGO_BUILD_TARGET_ARGS[@]}"
  fi
  swift_release_build --product "$APP_NAME"
  swift_release_build --product "$CLI_PRODUCT"
  swift_release_build --product "$VNC_ADAPTER_PRODUCT"
fi

SWIFT_BIN_PATH="${STACIO_SWIFT_BIN_PATH:-$(swift_release_build --show-bin-path)}"
EXECUTABLE_SOURCE="$SWIFT_BIN_PATH/$APP_NAME"
CLI_SOURCE="${STACIO_CLI_PATH:-$SWIFT_BIN_PATH/$CLI_PRODUCT}"
VNC_ADAPTER_SOURCE="${STACIO_VNC_ADAPTER_PATH:-$SWIFT_BIN_PATH/$VNC_ADAPTER_PRODUCT}"
SWIFTTERM_RESOURCE_BUNDLE_SOURCE="${STACIO_SWIFTTERM_RESOURCE_BUNDLE_PATH:-$SWIFT_BIN_PATH/$SWIFTTERM_RESOURCE_BUNDLE_NAME}"
CORE_DYLIB_SOURCE="${STACIO_CORE_DYLIB_PATH:-$CORE_DYLIB_DEFAULT}"
CORE_LOAD_PATH="${STACIO_CORE_LOAD_PATH:-$CORE_LOAD_PATH_DEFAULT}"
SPARKLE_FRAMEWORK_SOURCE="${STACIO_SPARKLE_FRAMEWORK_PATH:-$SWIFT_BIN_PATH/Sparkle.framework}"

if [[ ! -x "$EXECUTABLE_SOURCE" ]]; then
  echo "Stacio executable not found or not executable: $EXECUTABLE_SOURCE" >&2
  exit 1
fi

if [[ ! -x "$CLI_SOURCE" ]]; then
  echo "Stacio CLI helper not found or not executable: $CLI_SOURCE" >&2
  exit 1
fi

if [[ ! -f "$CORE_DYLIB_SOURCE" ]]; then
  echo "Stacio Core dylib not found: $CORE_DYLIB_SOURCE" >&2
  exit 1
fi

if [[ ! -x "$VNC_ADAPTER_SOURCE" ]]; then
  echo "Stacio VNC adapter not found or not executable: $VNC_ADAPTER_SOURCE" >&2
  exit 1
fi

if [[ ! -f "$SWIFTTERM_RESOURCE_BUNDLE_SOURCE/Shaders.metal" ]]; then
  echo "SwiftTerm shader resource not found: $SWIFTTERM_RESOURCE_BUNDLE_SOURCE/Shaders.metal" >&2
  exit 1
fi

if [[ ! -d "$SPARKLE_FRAMEWORK_SOURCE" ]]; then
  echo "Sparkle.framework not found: $SPARKLE_FRAMEWORK_SOURCE" >&2
  echo "Run 'swift build -c release --product $APP_NAME' or set STACIO_SPARKLE_FRAMEWORK_PATH." >&2
  exit 1
fi

SPARKLE_SOURCE_VERSION_DIR="$SPARKLE_FRAMEWORK_SOURCE/Versions/Current"
if [[ ! -d "$SPARKLE_SOURCE_VERSION_DIR" ]]; then
  SPARKLE_SOURCE_VERSION_DIR="$SPARKLE_FRAMEWORK_SOURCE/Versions/B"
fi
required_sparkle_components=(
  "$SPARKLE_FRAMEWORK_SOURCE/Sparkle"
  "$SPARKLE_SOURCE_VERSION_DIR/Autoupdate"
  "$SPARKLE_SOURCE_VERSION_DIR/Updater.app/Contents/MacOS/Updater"
  "$SPARKLE_SOURCE_VERSION_DIR/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"
  "$SPARKLE_SOURCE_VERSION_DIR/XPCServices/Installer.xpc/Contents/MacOS/Installer"
  "$SPARKLE_SOURCE_VERSION_DIR/Resources/Info.plist"
)
for sparkle_component in "${required_sparkle_components[@]}"; do
  if [[ ! -x "$sparkle_component" ]]; then
    if [[ "$sparkle_component" == *.plist && -f "$sparkle_component" ]]; then
      continue
    fi
    echo "Required Sparkle component missing: $sparkle_component" >&2
    exit 1
  fi
done

SPARKLE_RESOLVED_VERSION="$(python3 - "$ROOT_DIR/Package.resolved" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    payload = json.load(handle)

for pin in payload.get("pins", []):
    if pin.get("identity") == "sparkle":
        version = pin.get("state", {}).get("version")
        if version:
            print(version)
            break
else:
    raise SystemExit("Package.resolved does not contain a Sparkle version pin.")
PY
)"
SPARKLE_FRAMEWORK_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SPARKLE_SOURCE_VERSION_DIR/Resources/Info.plist" 2>/dev/null || true)"
if [[ -z "$SPARKLE_FRAMEWORK_VERSION" || "$SPARKLE_FRAMEWORK_VERSION" != "$SPARKLE_RESOLVED_VERSION" ]]; then
  echo "Sparkle.framework version ${SPARKLE_FRAMEWORK_VERSION:-<missing>} does not match Package.resolved $SPARKLE_RESOLVED_VERSION." >&2
  exit 1
fi

if [[ ! -f "$MONACO_VS_SOURCE/loader.js" ]]; then
  echo "Monaco Editor resources not found: $MONACO_VS_SOURCE" >&2
  echo "Run 'npm install' or set STACIO_MONACO_VS_PATH to a monaco-editor/min/vs directory." >&2
  exit 1
fi

verify_expected_native_architecture "Stacio executable" "$EXECUTABLE_SOURCE"
verify_expected_native_architecture "Stacio CLI" "$CLI_SOURCE"
verify_expected_native_architecture "Stacio VNC adapter" "$VNC_ADAPTER_SOURCE"
verify_expected_native_architecture "Stacio Core dylib" "$CORE_DYLIB_SOURCE"
verify_expected_native_architecture "Sparkle framework" "$SPARKLE_FRAMEWORK_SOURCE/Sparkle"

if [[ "${STACIO_SKIP_ARTIFACT_FRESHNESS:-0}" != "1" ]]; then
  check_prebuilt_artifact_freshness \
    "Stacio executable" \
    "$EXECUTABLE_SOURCE" \
    "$ROOT_DIR/Package.swift" \
    "$ROOT_DIR/Package.resolved" \
    "$ROOT_DIR/Stacio" \
    "$ROOT_DIR/StacioAgentBridge" \
    "$ROOT_DIR/StacioExecutable"
  check_prebuilt_artifact_freshness \
    "Stacio CLI" \
    "$CLI_SOURCE" \
    "$ROOT_DIR/Package.swift" \
    "$ROOT_DIR/Package.resolved" \
    "$ROOT_DIR/StacioAgentBridge" \
    "$ROOT_DIR/StacioCLI"
  check_prebuilt_artifact_freshness \
    "Stacio VNC adapter" \
    "$VNC_ADAPTER_SOURCE" \
    "$ROOT_DIR/Package.swift" \
    "$ROOT_DIR/Package.resolved" \
    "$ROOT_DIR/StacioAdapters/VNC"
  check_prebuilt_artifact_freshness \
    "Stacio Core dylib" \
    "$CORE_DYLIB_SOURCE" \
    "$ROOT_DIR/StacioCore/Cargo.toml" \
    "$ROOT_DIR/StacioCore/Cargo.lock" \
    "$ROOT_DIR/StacioCore/migrations" \
    "$ROOT_DIR/StacioCore/src" \
    "$ROOT_DIR/StacioCore/uniffi-bindgen-swift.rs"
fi

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$FRAMEWORKS_DIR" "$ADAPTERS_DIR" "$HELPERS_DIR" "$RESOURCES_DIR"

cp "$EXECUTABLE_SOURCE" "$MACOS_DIR/$APP_NAME"
cp "$CLI_SOURCE" "$HELPERS_DIR/$CLI_HELPER_NAME"
cp "$CORE_DYLIB_SOURCE" "$FRAMEWORKS_DIR/libstacio_core.dylib"
cp "$VNC_ADAPTER_SOURCE" "$ADAPTERS_DIR/vnc"
cp -R "$SWIFTTERM_RESOURCE_BUNDLE_SOURCE" "$SWIFTTERM_RESOURCE_BUNDLE_OUTPUT"
chmod -R u+w "$SWIFTTERM_RESOURCE_BUNDLE_OUTPUT"
/usr/bin/xattr -cr "$SWIFTTERM_RESOURCE_BUNDLE_OUTPUT"
cp -R "$SPARKLE_FRAMEWORK_SOURCE" "$FRAMEWORKS_DIR/Sparkle.framework"
if [[ -d "$ABOUT_RESOURCES_SOURCE" ]]; then
  mkdir -p "$ABOUT_RESOURCES_OUTPUT"
  cp -R "$ABOUT_RESOURCES_SOURCE/." "$ABOUT_RESOURCES_OUTPUT/"
fi
cp "$GITHUB_ICON_SOURCE" "$GITHUB_ICON_OUTPUT"
cp "$GITEE_ICON_SOURCE" "$GITEE_ICON_OUTPUT"
mkdir -p "$SESSION_ICONS_OUTPUT"
cp -R "$SESSION_ICONS_SOURCE/." "$SESSION_ICONS_OUTPUT/"
/usr/bin/xattr -cr "$SESSION_ICONS_OUTPUT"
mkdir -p "$IMPORT_SOURCE_ICONS_OUTPUT"
cp -R "$IMPORT_SOURCE_ICONS_SOURCE/." "$IMPORT_SOURCE_ICONS_OUTPUT/"
/usr/bin/xattr -cr "$IMPORT_SOURCE_ICONS_OUTPUT"
mkdir -p "$(dirname "$MONACO_OUTPUT")"
cp -R "$MONACO_VS_SOURCE" "$MONACO_OUTPUT"
chmod 755 "$MACOS_DIR/$APP_NAME" "$HELPERS_DIR/$CLI_HELPER_NAME" "$FRAMEWORKS_DIR/libstacio_core.dylib" "$ADAPTERS_DIR/vnc"
cp "$APP_ICON_SOURCE" "$APP_ICON_OUTPUT"

cat >"$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>zh-Hans</string>
  <key>CFBundleLocalizations</key>
  <array>
    <string>zh-Hans</string>
    <string>en</string>
  </array>
  <key>CFBundleAllowMixedLocalizations</key>
  <true/>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>Stacio.icns</string>
  <key>CFBundleIconName</key>
  <string>Stacio</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key>
      <string>$BUNDLE_ID</string>
      <key>CFBundleURLSchemes</key>
      <array>
        <string>stacio</string>
      </array>
    </dict>
  </array>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHumanReadableCopyright</key>
  <string>Copyright © 2026 Stacio</string>
  <key>NSQuitAlwaysKeepsWindows</key>
  <false/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

python3 - "$PLIST_PATH" "$PRODUCT_OPS_PRODUCT_ID" "$PRODUCT_OPS_API_BASE_URL" "$PRODUCT_OPS_UPDATE_CHANNEL" "$PRODUCT_OPS_BETA_UPDATES_ENABLED" "$FEEDBACK_PRODUCT_API_KEY" "$SPARKLE_STABLE_APPCAST_URL" "$SPARKLE_BETA_APPCAST_URL" "$SPARKLE_PUBLIC_ED_KEY" "$LICENSE_PUBLIC_ED25519_KEY" "$SPARKLE_UPDATE_ARCHITECTURE" <<'PY'
import plistlib
import sys
from urllib.parse import urlparse

(
    plist_path,
    product_id,
    api_base_url,
    update_channel,
    beta_updates_enabled,
    feedback_product_api_key,
    stable_appcast_url,
    beta_appcast_url,
    sparkle_public_ed_key,
    license_public_ed25519_key,
    sparkle_architecture,
) = sys.argv[1:12]
product_id = (product_id or "stacio").strip() or "stacio"
api_base_url = (api_base_url or "").strip()
update_channel = (update_channel or "stable").strip().lower() or "stable"
feedback_product_api_key = (feedback_product_api_key or "").strip()
stable_appcast_url = (stable_appcast_url or "").strip()
beta_appcast_url = (beta_appcast_url or "").strip()
license_public_ed25519_key = (license_public_ed25519_key or "").strip()
sparkle_architecture = (sparkle_architecture or "").strip()
if update_channel not in {"stable", "beta"}:
    raise SystemExit(f"Invalid STACIO_PRODUCT_OPS_UPDATE_CHANNEL: {update_channel}")

def validate_url(name, value, allow_empty=False):
    if not value:
        if allow_empty:
            return
        raise SystemExit(f"{name} is required")
    parsed = urlparse(value)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise SystemExit(f"Invalid {name}: {value}")
    if parsed.scheme == "http" and parsed.hostname not in {"localhost", "127.0.0.1", "::1"}:
        raise SystemExit(f"{name} must use HTTPS outside localhost: {value}")

raw_beta = (beta_updates_enabled or "0").strip().lower()
if raw_beta in {"1", "true", "yes", "on"}:
    beta_enabled = True
elif raw_beta in {"0", "false", "no", "off", ""}:
    beta_enabled = False
else:
    raise SystemExit(f"Invalid STACIO_PRODUCT_OPS_BETA_UPDATES_ENABLED: {beta_updates_enabled}")

with open(plist_path, "rb") as handle:
    payload = plistlib.load(handle)

payload["StacioProductOpsProductID"] = product_id
payload["StacioProductOpsUpdateChannel"] = update_channel
payload["StacioProductOpsBetaUpdatesEnabled"] = beta_enabled
payload["StacioSparkleArchitecture"] = sparkle_architecture
validate_url("STACIO_SPARKLE_STABLE_APPCAST_URL", stable_appcast_url)
validate_url("STACIO_SPARKLE_BETA_APPCAST_URL", beta_appcast_url)
payload["SUFeedURL"] = stable_appcast_url
payload["StacioSparkleBetaAppcastURL"] = beta_appcast_url
payload["SUEnableAutomaticChecks"] = True
payload["SUAutomaticallyUpdate"] = False
payload["SUAllowsAutomaticUpdates"] = False
payload["SUScheduledCheckInterval"] = 86400

if api_base_url:
    validate_url("STACIO_PRODUCT_OPS_API_BASE_URL", api_base_url)
    payload["StacioProductOpsAPIBaseURL"] = api_base_url
else:
    payload.pop("StacioProductOpsAPIBaseURL", None)

if feedback_product_api_key:
    payload["StacioFeedbackProductAPIKey"] = feedback_product_api_key
else:
    payload.pop("StacioFeedbackProductAPIKey", None)

if sparkle_public_ed_key:
    payload["SUPublicEDKey"] = sparkle_public_ed_key
else:
    payload.pop("SUPublicEDKey", None)

if license_public_ed25519_key:
    payload["StacioLicensePublicEd25519Key"] = license_public_ed25519_key
else:
    payload.pop("StacioLicensePublicEd25519Key", None)

with open(plist_path, "wb") as handle:
    plistlib.dump(payload, handle, sort_keys=False)
PY

install_name_tool -id "@rpath/libstacio_core.dylib" "$FRAMEWORKS_DIR/libstacio_core.dylib"
install_name_tool \
  -change "$CORE_LOAD_PATH" \
  "@executable_path/../Frameworks/libstacio_core.dylib" \
  "$MACOS_DIR/$APP_NAME"
if ! otool -l "$MACOS_DIR/$APP_NAME" \
  | awk '
      $1 == "cmd" && $2 == "LC_RPATH" { in_rpath = 1; next }
      in_rpath && $1 == "path" { print $2; in_rpath = 0 }
    ' \
  | grep -Fxq "@executable_path/../Frameworks"; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS_DIR/$APP_NAME"
fi

SPARKLE_VERSION_DIR="$FRAMEWORKS_DIR/Sparkle.framework/Versions/Current"
if [[ ! -d "$SPARKLE_VERSION_DIR" ]]; then
  SPARKLE_VERSION_DIR="$FRAMEWORKS_DIR/Sparkle.framework/Versions/B"
fi
for sparkle_component in \
  "$SPARKLE_VERSION_DIR/XPCServices/Downloader.xpc" \
  "$SPARKLE_VERSION_DIR/XPCServices/Installer.xpc" \
  "$SPARKLE_VERSION_DIR/Updater.app" \
  "$SPARKLE_VERSION_DIR/Autoupdate"
do
  codesign "${SPARKLE_CODESIGN_ARGS[@]}" --sign "$CODESIGN_IDENTITY" "$sparkle_component"
done

codesign "${CODESIGN_ARGS[@]}" --sign "$CODESIGN_IDENTITY" "$FRAMEWORKS_DIR/libstacio_core.dylib"
codesign "${SPARKLE_CODESIGN_ARGS[@]}" --sign "$CODESIGN_IDENTITY" "$FRAMEWORKS_DIR/Sparkle.framework"
codesign "${CODESIGN_ARGS[@]}" --sign "$CODESIGN_IDENTITY" "$HELPERS_DIR/$CLI_HELPER_NAME"
codesign "${CODESIGN_ARGS[@]}" --sign "$CODESIGN_IDENTITY" "$ADAPTERS_DIR/vnc"
codesign "${CODESIGN_APP_ARGS[@]}" --sign "$CODESIGN_IDENTITY" "$APP_DIR"

echo "Packaged $APP_DIR"
