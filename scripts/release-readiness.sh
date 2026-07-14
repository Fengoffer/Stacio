#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${STACIO_RELEASE_APP_PATH:-$ROOT_DIR/dist/Stacio.app}"
DMG_PATH="${STACIO_RELEASE_DMG_PATH:-$ROOT_DIR/dist/Stacio.dmg}"
RUN_PACKAGE="${STACIO_RELEASE_SKIP_PACKAGE:-0}"
REQUESTED_REQUIRE_DEVELOPER_ID="${STACIO_RELEASE_REQUIRE_DEVELOPER_ID:-0}"
REQUESTED_REQUIRE_NOTARY="${STACIO_RELEASE_REQUIRE_NOTARY:-0}"
LOCAL_SMOKE="${STACIO_RELEASE_LOCAL_SMOKE:-0}"
REQUIRE_DEVELOPER_ID="$REQUESTED_REQUIRE_DEVELOPER_ID"
REQUIRE_NOTARY="$REQUESTED_REQUIRE_NOTARY"
SOURCE_ROOT="${STACIO_RELEASE_SOURCE_ROOT:-$ROOT_DIR}"
RELEASE_LOCK_DIR="${STACIO_RELEASE_LOCK_DIR:-$(dirname "$APP_DIR")/.release-readiness.lock}"
RELEASE_LOCK_ACQUIRED=0
REMOTE_TEMP_DIR=""
if [[ "$LOCAL_SMOKE" != "1" ]]; then
  REQUIRE_DEVELOPER_ID=1
  REQUIRE_NOTARY=1
fi

failures=0
warnings=0
skips=0

pass() {
  printf 'PASS %s\n' "$1"
}

warn() {
  warnings=$((warnings + 1))
  printf 'WARN %s\n' "$1"
}

skip() {
  skips=$((skips + 1))
  printf 'SKIP %s\n' "$1"
}

fail() {
  failures=$((failures + 1))
  printf 'FAIL %s\n' "$1" >&2
}

run_cmd() {
  printf '\n$'
  printf ' %q' "$@"
  printf '\n'
  "$@"
}

require_tool() {
  local name="$1"
  if command -v "$name" >/dev/null 2>&1; then
    pass "tool available: $name"
  else
    fail "required release tool missing: $name"
  fi
}

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true
}

cleanup_release_lock() {
  if [[ -n "$REMOTE_TEMP_DIR" ]]; then
    rm -rf "$REMOTE_TEMP_DIR"
  fi
  if [[ "$RELEASE_LOCK_ACQUIRED" == "1" ]]; then
    rm -rf "$RELEASE_LOCK_DIR"
  fi
}
trap cleanup_release_lock EXIT

acquire_release_lock() {
  mkdir -p "$(dirname "$RELEASE_LOCK_DIR")"
  if mkdir "$RELEASE_LOCK_DIR" 2>/dev/null; then
    RELEASE_LOCK_ACQUIRED=1
    printf '%s\n' "$$" >"$RELEASE_LOCK_DIR/pid"
    return
  fi
  local holder_pid=""
  if [[ -f "$RELEASE_LOCK_DIR/pid" ]]; then
    holder_pid="$(cat "$RELEASE_LOCK_DIR/pid" 2>/dev/null || true)"
  fi
  if [[ "$holder_pid" =~ ^[0-9]+$ ]] && ! kill -0 "$holder_pid" 2>/dev/null; then
    rm -rf "$RELEASE_LOCK_DIR"
    mkdir "$RELEASE_LOCK_DIR"
    RELEASE_LOCK_ACQUIRED=1
    printf '%s\n' "$$" >"$RELEASE_LOCK_DIR/pid"
    return
  fi
  fail "another Stacio release-readiness process is using $RELEASE_LOCK_DIR"
}

valid_ed25519_public_key() {
  local value="$1"
  local format="$2"
  python3 - "$value" "$format" <<'PY'
import base64
import binascii
import sys

configured, key_format = sys.argv[1:3]
spki_prefix = bytes([
    0x30, 0x2A,
    0x30, 0x05,
    0x06, 0x03, 0x2B, 0x65, 0x70,
    0x03, 0x21, 0x00,
])

def decode_base64(value):
    return base64.b64decode("".join(value.split()), validate=True)

def decode_pem(value):
    body = value.replace("-----BEGIN PUBLIC KEY-----", "").replace("-----END PUBLIC KEY-----", "")
    return decode_base64(body)

def valid_license_key(value):
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
    valid = len(decode_base64(configured)) == 32 if key_format == "sparkle" else valid_license_key(configured)
except (ValueError, binascii.Error):
    valid = False
raise SystemExit(0 if valid else 1)
PY
}

developer_id_identity() {
  security find-identity -p codesigning -v 2>/dev/null \
    | awk '/Developer ID Application:/ { sub(/^[[:space:]]*[0-9]+\) [[:xdigit:]]+ "/, ""); sub(/"$/, ""); print; exit }'
}

notary_configured() {
  [[ -n "${STACIO_NOTARY_PROFILE:-}" ]] \
    || { [[ -n "${APPLE_ID:-}" ]] && [[ -n "${APPLE_TEAM_ID:-}" ]] && [[ -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]]; }
}

check_app_bundle() {
  [[ -d "$APP_DIR" ]] || { fail "app bundle missing: $APP_DIR"; return; }
  pass "app bundle exists: $APP_DIR"

  local plist="$APP_DIR/Contents/Info.plist"
  [[ -f "$plist" ]] || { fail "Info.plist missing"; return; }
  run_cmd plutil -lint "$plist"

  local executable bundle_id package_type min_system short_version build_number
  executable="$(plist_value "$plist" CFBundleExecutable)"
  bundle_id="$(plist_value "$plist" CFBundleIdentifier)"
  package_type="$(plist_value "$plist" CFBundlePackageType)"
  min_system="$(plist_value "$plist" LSMinimumSystemVersion)"
  short_version="$(plist_value "$plist" CFBundleShortVersionString)"
  build_number="$(plist_value "$plist" CFBundleVersion)"

  [[ "$executable" == "Stacio" ]] && pass "CFBundleExecutable=Stacio" || fail "unexpected CFBundleExecutable: ${executable:-<empty>}"
  [[ "$bundle_id" == "com.stacio.Stacio" ]] && pass "CFBundleIdentifier=com.stacio.Stacio" || fail "unexpected CFBundleIdentifier: ${bundle_id:-<empty>}"
  [[ "$package_type" == "APPL" ]] && pass "CFBundlePackageType=APPL" || fail "unexpected CFBundlePackageType: ${package_type:-<empty>}"
  [[ "$min_system" == "14.0" ]] && pass "LSMinimumSystemVersion=14.0" || warn "unexpected LSMinimumSystemVersion: ${min_system:-<empty>}"
  [[ -n "${short_version//[[:space:]]/}" ]] && pass "CFBundleShortVersionString=$short_version" || fail "CFBundleShortVersionString must not be empty"
  [[ "$build_number" =~ ^[1-9][0-9]*$ ]] && pass "CFBundleVersion=$build_number" || fail "CFBundleVersion must be a positive integer: ${build_number:-<empty>}"
  if [[ -n "${STACIO_RELEASE_PREVIOUS_BUILD_NUMBER:-}" ]]; then
    if [[ ! "$STACIO_RELEASE_PREVIOUS_BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
      fail "STACIO_RELEASE_PREVIOUS_BUILD_NUMBER must be a positive integer"
    elif [[ "$build_number" =~ ^[1-9][0-9]*$ ]] && (( build_number > STACIO_RELEASE_PREVIOUS_BUILD_NUMBER )); then
      pass "CFBundleVersion is newer than previous build $STACIO_RELEASE_PREVIOUS_BUILD_NUMBER"
    else
      fail "CFBundleVersion must be greater than previous build $STACIO_RELEASE_PREVIOUS_BUILD_NUMBER"
    fi
  fi

  run_cmd "$ROOT_DIR/scripts/smoke-local-app.sh" "$APP_DIR"
}

check_product_ops_configuration() {
  local app_path="${1:-$APP_DIR}"
  local label="${2:-}"
  local plist="$app_path/Contents/Info.plist"
  [[ -f "$plist" ]] || return

  if [[ "$LOCAL_SMOKE" == "1" ]]; then
    skip "${label}Product Ops configuration completeness by explicit local-smoke mode"
    return
  fi

  local key value
  local required_keys=(
    StacioProductOpsProductID
    StacioProductOpsAPIBaseURL
    StacioProductOpsUpdateChannel
    StacioProductOpsBetaUpdatesEnabled
    StacioFeedbackProductAPIKey
    SUFeedURL
    StacioSparkleBetaAppcastURL
    SUPublicEDKey
    StacioLicensePublicEd25519Key
    SUEnableAutomaticChecks
    SUAutomaticallyUpdate
    SUAllowsAutomaticUpdates
    SUScheduledCheckInterval
  )
  for key in "${required_keys[@]}"; do
    value="$(plist_value "$plist" "$key")"
    if [[ -n "${value//[[:space:]]/}" ]]; then
      pass "${label}required Product Ops configuration present: $key"
    else
      fail "${label}required Product Ops configuration missing: $key"
    fi
  done

  local api_base_url update_channel stable_appcast_url beta_appcast_url
  api_base_url="$(plist_value "$plist" StacioProductOpsAPIBaseURL)"
  update_channel="$(plist_value "$plist" StacioProductOpsUpdateChannel)"
  stable_appcast_url="$(plist_value "$plist" SUFeedURL)"
  beta_appcast_url="$(plist_value "$plist" StacioSparkleBetaAppcastURL)"
  [[ "$api_base_url" == https://* ]] \
    && pass "${label}Product Ops API base URL uses HTTPS" \
    || fail "${label}Product Ops API base URL must use HTTPS for release: ${api_base_url:-<empty>}"
  [[ "$stable_appcast_url" == https://* ]] \
    && pass "${label}stable Appcast URL uses HTTPS" \
    || fail "${label}stable Appcast URL must use HTTPS for release: ${stable_appcast_url:-<empty>}"
  [[ "$beta_appcast_url" == https://* ]] \
    && pass "${label}beta Appcast URL uses HTTPS" \
    || fail "${label}beta Appcast URL must use HTTPS for release: ${beta_appcast_url:-<empty>}"
  case "$update_channel" in
    stable|beta)
      pass "${label}Product Ops update channel is valid: $update_channel"
      ;;
    *)
      fail "${label}Product Ops update channel must be stable or beta: ${update_channel:-<empty>}"
      ;;
  esac

  local automatic_key automatic_value
  for automatic_key in SUEnableAutomaticChecks SUAutomaticallyUpdate SUAllowsAutomaticUpdates; do
    automatic_value="$(plist_value "$plist" "$automatic_key")"
    if [[ "$automatic_value" == "false" ]]; then
      pass "${label}$automatic_key=false"
    else
      fail "${label}$automatic_key must be false"
    fi
  done
  local scheduled_interval
  scheduled_interval="$(plist_value "$plist" SUScheduledCheckInterval)"
  if [[ "$scheduled_interval" == "0" ]]; then
    pass "${label}SUScheduledCheckInterval=0"
  else
    fail "${label}SUScheduledCheckInterval must be 0"
  fi

  local sparkle_key license_key
  sparkle_key="$(plist_value "$plist" SUPublicEDKey)"
  license_key="$(plist_value "$plist" StacioLicensePublicEd25519Key)"
  if valid_ed25519_public_key "$sparkle_key" sparkle; then
    pass "${label}SUPublicEDKey is a valid Ed25519 public key"
  else
    fail "${label}SUPublicEDKey must contain a valid Ed25519 public key"
  fi
  if valid_ed25519_public_key "$license_key" license; then
    pass "${label}StacioLicensePublicEd25519Key is a valid Ed25519 public key"
  else
    fail "${label}StacioLicensePublicEd25519Key must contain a valid Ed25519 public key"
  fi
}

fetch_appcast() {
  local channel="$1"
  local url="$2"
  local output_path="$3"
  local error_path="$4"

  if [[ "$url" != https://* ]]; then
    fail "$channel Appcast URL must be a valid HTTPS URL before remote verification: ${url:-<empty>}"
    return 1
  fi

  if curl \
    --fail \
    --location \
    --proto '=https' \
    --proto-redir '=https' \
    --silent \
    --show-error \
    --connect-timeout 10 \
    --max-time 30 \
    --output "$output_path" \
    "$url" 2>"$error_path"; then
    pass "$channel Appcast fetched over HTTPS"
    return 0
  fi

  local details
  details="$(tr '\n' ' ' <"$error_path" 2>/dev/null || true)"
  fail "$channel Appcast fetch failed for $url: ${details:-network or HTTP error}"
  return 1
}

parse_appcast() {
  local input_path="$1"
  local output_path="$2"
  local error_path="$3"
  local feed_url="$4"
  local target_version="$5"
  local target_build="$6"

  python3 - "$input_path" "$feed_url" "$target_version" "$target_build" >"$output_path" 2>"$error_path" <<'PY'
import sys
import xml.etree.ElementTree as ET
import base64
import binascii
from urllib.parse import urljoin, urlparse

path, feed_url, target_version, target_build = sys.argv[1:5]
sparkle_namespace = "http://www.andymatuschak.org/xml-namespaces/sparkle"
sparkle_tag = lambda name: f"{{{sparkle_namespace}}}{name}"

try:
    root = ET.parse(path).getroot()
except (ET.ParseError, OSError) as error:
    print(str(error), file=sys.stderr)
    raise SystemExit(2)

if root.tag != "rss":
    print("Appcast root element must be rss", file=sys.stderr)
    raise SystemExit(3)
channels = root.findall("channel")
if len(channels) != 1:
    print("Appcast must contain exactly one channel", file=sys.stderr)
    raise SystemExit(3)
items = channels[0].findall("item")
print(f"COUNT\t{len(items)}")

def child_text(element, name):
    child = element.find(sparkle_tag(name))
    return (child.text or "").strip() if child is not None else ""

def sparkle_attribute(element, name):
    return (element.attrib.get(sparkle_tag(name), "") if element is not None else "").strip()

def is_safe_field(value):
    return bool(value) and not any(ord(character) < 32 or ord(character) == 127 for character in value)

namespace_error = False
target_records = []
for index, item in enumerate(items, start=1):
    enclosure = item.find("enclosure")
    for child in item:
        local_name = child.tag.rsplit("}", 1)[-1]
        if local_name in {"version", "shortVersionString"} and child.tag != sparkle_tag(local_name):
            namespace_error = True
    if enclosure is not None:
        for name in enclosure.attrib:
            local_name = name.rsplit("}", 1)[-1].rsplit(":", 1)[-1]
            if local_name in {"version", "shortVersionString", "edSignature"} and name != sparkle_tag(local_name):
                namespace_error = True

    version = sparkle_attribute(enclosure, "shortVersionString") or child_text(item, "shortVersionString")
    build = sparkle_attribute(enclosure, "version") or child_text(item, "version")
    if not version and build == target_build:
        print(f"ERROR\t{index}\tversion")
    if not build and version == target_version:
        print(f"ERROR\t{index}\tbuild")
    if version != target_version or build != target_build:
        continue

    enclosure_url = (enclosure.attrib.get("url", "") if enclosure is not None else "").strip()
    enclosure_length = (enclosure.attrib.get("length", "") if enclosure is not None else "").strip()
    signature = sparkle_attribute(enclosure, "edSignature")
    resolved_enclosure_url = urljoin(feed_url, enclosure_url)

    errors = []
    parsed_url = urlparse(resolved_enclosure_url)
    if (
        not is_safe_field(enclosure_url)
        or not is_safe_field(resolved_enclosure_url)
        or parsed_url.scheme.lower() != "https"
        or not parsed_url.hostname
        or parsed_url.username is not None
        or parsed_url.password is not None
    ):
        errors.append("url")

    if not enclosure_length.isdigit() or int(enclosure_length) <= 0:
        errors.append("length")
    if not is_safe_field(signature):
        errors.append("signature")
    else:
        try:
            decoded_signature = base64.b64decode(signature, validate=True)
        except (ValueError, binascii.Error):
            decoded_signature = b""
        if len(decoded_signature) != 64:
            errors.append("signature_format")

    if errors:
        for error in errors:
            print(f"ERROR\t{index}\t{error}")
        continue

    target_records.append((index, version, build, resolved_enclosure_url, enclosure_length, signature))

if namespace_error:
    print("NAMESPACE_ERROR")
print(f"TARGET_COUNT\t{len(target_records)}")
for record in target_records:
    print("TARGET\t" + "\t".join(str(value) for value in record))
PY
}

prepare_ed25519_verification_files() {
  local public_key="$1"
  local signature="$2"
  local public_key_path="$3"
  local signature_path="$4"

  python3 - "$public_key" "$signature" "$public_key_path" "$signature_path" <<'PY'
import base64
import binascii
import sys

configured_key, configured_signature, public_key_path, signature_path = sys.argv[1:]

try:
    raw_key = base64.b64decode("".join(configured_key.split()), validate=True)
    signature = base64.b64decode("".join(configured_signature.split()), validate=True)
except (ValueError, binascii.Error) as error:
    print(f"invalid base64: {error}", file=sys.stderr)
    raise SystemExit(1)

if len(raw_key) != 32:
    print(f"Sparkle public key must be 32 bytes, got {len(raw_key)}", file=sys.stderr)
    raise SystemExit(1)
if len(signature) != 64:
    print(f"Sparkle Ed25519 signature must be 64 bytes, got {len(signature)}", file=sys.stderr)
    raise SystemExit(1)

with open(public_key_path, "wb") as handle:
    handle.write(raw_key)
with open(signature_path, "wb") as handle:
    handle.write(signature)
PY
}

write_ed25519_verifier() {
  local helper_path="$1"
  cat >"$helper_path" <<'SWIFT'
import CryptoKit
import Darwin
import Foundation

guard CommandLine.arguments.count == 4 else {
    FileHandle.standardError.write(Data("expected public-key, signature, and archive paths\n".utf8))
    exit(2)
}

do {
    let publicKeyData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    let signatureData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
    let archiveData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]), options: .mappedIfSafe)
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
    guard publicKey.isValidSignature(signatureData, for: archiveData) else {
        FileHandle.standardError.write(Data("CryptoKit rejected the Sparkle Ed25519 signature\n".utf8))
        exit(1)
    }
} catch {
    FileHandle.standardError.write(Data("CryptoKit verification error: \(error)\n".utf8))
    exit(2)
}
SWIFT
}

download_and_verify_appcast_enclosure() {
  local channel="$1"
  local item_index="$2"
  local url="$3"
  local signature="$4"
  local public_key="$5"
  local declared_length="$6"
  local local_dmg_path="$7"
  local verifier_path="$8"
  local temp_dir="$9"
  local archive_path="$temp_dir/$channel-item-$item_index.enclosure"
  local public_key_path="$temp_dir/$channel-item-$item_index-public.bin"
  local signature_path="$temp_dir/$channel-item-$item_index-signature.bin"
  local download_error="$temp_dir/$channel-item-$item_index-download.err"
  local preparation_error="$temp_dir/$channel-item-$item_index-key.err"
  local verification_output="$temp_dir/$channel-item-$item_index-verify.out"

  if curl \
    --fail \
    --location \
    --proto '=https' \
    --proto-redir '=https' \
    --silent \
    --show-error \
    --connect-timeout 10 \
    --max-time 600 \
    --output "$archive_path" \
    "$url" 2>"$download_error"; then
    pass "$channel Appcast item $item_index enclosure is accessible"
  else
    local details
    details="$(tr '\n' ' ' <"$download_error" 2>/dev/null || true)"
    fail "$channel Appcast item $item_index enclosure is not accessible: $url (${details:-network or HTTP error})"
    return
  fi

  local actual_length
  actual_length="$(wc -c <"$archive_path" | tr -d '[:space:]')"
  if [[ "$actual_length" == "$declared_length" ]]; then
    pass "$channel Appcast item $item_index enclosure length matches downloaded bytes"
  else
    fail "$channel Appcast item $item_index enclosure length does not match downloaded bytes: declared $declared_length, downloaded $actual_length"
  fi

  if cmp -s "$archive_path" "$local_dmg_path"; then
    pass "$channel Appcast item $item_index enclosure matches local release DMG"
  else
    fail "$channel Appcast item $item_index enclosure does not match local release DMG"
  fi

  local details
  if ! prepare_ed25519_verification_files \
    "$public_key" \
    "$signature" \
    "$public_key_path" \
    "$signature_path" 2>"$preparation_error"; then
    details="$(tr '\n' ' ' <"$preparation_error" 2>/dev/null || true)"
    fail "$channel Appcast item $item_index Sparkle Ed25519 verification inputs are invalid: ${details:-key or signature decoding failed}"
    return
  fi

  if swift "$verifier_path" "$public_key_path" "$signature_path" "$archive_path" >"$verification_output" 2>&1; then
    pass "$channel Appcast item $item_index Sparkle Ed25519 signature verifies"
  else
    details="$(tr '\n' ' ' <"$verification_output" 2>/dev/null || true)"
    fail "$channel Appcast item $item_index Sparkle Ed25519 signature verification failed: ${details:-CryptoKit rejected the signature}"
  fi
}

check_remote_appcast_channel() {
  local channel="$1"
  local url="$2"
  local items_required="$3"
  local target_required="$4"
  local public_key="$5"
  local current_version="$6"
  local current_build="$7"
  local verifier_path="$8"
  local temp_dir="$9"
  local xml_path="$temp_dir/$channel-appcast.xml"
  local fetch_error_path="$temp_dir/$channel-fetch.err"
  local parse_output_path="$temp_dir/$channel-parse.out"
  local parse_error_path="$temp_dir/$channel-parse.err"

  if ! fetch_appcast "$channel" "$url" "$xml_path" "$fetch_error_path"; then
    return
  fi
  if ! parse_appcast \
    "$xml_path" \
    "$parse_output_path" \
    "$parse_error_path" \
    "$url" \
    "$current_version" \
    "$current_build"; then
    local details
    details="$(tr '\n' ' ' <"$parse_error_path" 2>/dev/null || true)"
    fail "$channel Appcast XML is malformed: ${details:-unable to parse XML}"
    return
  fi

  if grep -Fxq "NAMESPACE_ERROR" "$parse_output_path"; then
    fail "$channel Appcast uses an invalid Sparkle XML namespace"
    return
  fi

  local item_count
  item_count="$(awk -F '\t' '$1 == "COUNT" { print $2; exit }' "$parse_output_path")"
  if [[ ! "$item_count" =~ ^[0-9]+$ ]]; then
    fail "$channel Appcast parser did not return an item count"
    return
  fi
  if (( item_count == 0 )); then
    if [[ "$items_required" == "1" ]]; then
      if [[ "$channel" == "beta" ]]; then
        fail "beta Appcast contains no update items while beta updates are enabled"
      else
        fail "$channel Appcast contains no update items"
      fi
    else
      skip "$channel Appcast contains no update items; beta updates are disabled"
    fi
    return
  fi
  pass "$channel Appcast contains $item_count update item(s)"

  if [[ "$target_required" != "1" ]]; then
    skip "$channel Appcast is not the configured release target; historical items were not downloaded"
    return
  fi

  local record item_index value_one value_two value_three value_four value_five
  local metadata_error_count=0
  while IFS=$'\t' read -r record item_index value_one value_two value_three value_four value_five; do
    [[ "$record" == "ERROR" ]] || continue
    metadata_error_count=$((metadata_error_count + 1))
    case "$value_one" in
      version)
        fail "$channel Appcast item $item_index version must not be empty"
        ;;
      build)
        fail "$channel Appcast item $item_index build must not be empty"
        ;;
      url)
        fail "$channel Appcast item $item_index enclosure URL must be a valid HTTPS URL"
        ;;
      length)
        fail "$channel Appcast item $item_index enclosure length must be a positive integer"
        ;;
      signature)
        fail "$channel Appcast item $item_index Sparkle Ed25519 signature is missing"
        ;;
      signature_format)
        fail "$channel Appcast item $item_index Sparkle Ed25519 signature must be valid base64 encoding of 64 bytes"
        ;;
      *)
        fail "$channel Appcast item $item_index has an unknown validation error: $value_one"
        ;;
    esac
  done <"$parse_output_path"
  if (( metadata_error_count > 0 )); then
    return
  fi

  local target_count
  target_count="$(awk -F '\t' '$1 == "TARGET_COUNT" { print $2; exit }' "$parse_output_path")"
  if [[ "$target_count" != "1" ]]; then
    if [[ "$target_count" =~ ^[0-9]+$ ]] && (( target_count > 1 )); then
      fail "$channel Appcast contains multiple entries for current release $current_version (build $current_build)"
    else
      fail "$channel Appcast does not contain current release $current_version (build $current_build)"
    fi
    return
  fi

  local version build enclosure_url declared_length signature
  while IFS=$'\t' read -r record item_index value_one value_two value_three value_four value_five; do
    [[ "$record" == "TARGET" ]] || continue
    version="$value_one"
    build="$value_two"
    enclosure_url="$value_three"
    declared_length="$value_four"
    signature="$value_five"
    pass "$channel Appcast item $item_index has version $version and build $build"
    pass "$channel Appcast item $item_index enclosure URL is valid HTTPS"
    pass "$channel Appcast item $item_index has a positive enclosure length"
    pass "$channel Appcast item $item_index has a Sparkle Ed25519 signature"
    download_and_verify_appcast_enclosure \
      "$channel" \
      "$item_index" \
      "$enclosure_url" \
      "$signature" \
      "$public_key" \
      "$declared_length" \
      "$DMG_PATH" \
      "$verifier_path" \
      "$temp_dir"
  done <"$parse_output_path"
}

check_remote_appcasts() {
  if [[ "$LOCAL_SMOKE" == "1" ]]; then
    skip "remote Appcast verification by explicit local-smoke mode"
    return
  fi

  local plist="$APP_DIR/Contents/Info.plist"
  [[ -f "$plist" ]] || return

  local stable_url beta_url update_channel beta_updates_enabled effective_update_channel beta_required sparkle_public_key current_version current_build
  stable_url="$(plist_value "$plist" SUFeedURL)"
  beta_url="$(plist_value "$plist" StacioSparkleBetaAppcastURL)"
  update_channel="$(plist_value "$plist" StacioProductOpsUpdateChannel)"
  beta_updates_enabled="$(plist_value "$plist" StacioProductOpsBetaUpdatesEnabled)"
  sparkle_public_key="$(plist_value "$plist" SUPublicEDKey)"
  current_version="$(plist_value "$plist" CFBundleShortVersionString)"
  current_build="$(plist_value "$plist" CFBundleVersion)"
  effective_update_channel="$update_channel"
  if [[ "$beta_updates_enabled" != "true" ]]; then
    effective_update_channel="stable"
  fi
  beta_required=0
  [[ "$effective_update_channel" == "beta" ]] && beta_required=1

  REMOTE_TEMP_DIR="$(mktemp -d)"
  local verifier_path="$REMOTE_TEMP_DIR/verify-ed25519.swift"
  write_ed25519_verifier "$verifier_path"
  local stable_target=0 beta_target=0
  [[ "$effective_update_channel" == "stable" ]] && stable_target=1
  [[ "$effective_update_channel" == "beta" ]] && beta_target=1
  check_remote_appcast_channel \
    stable "$stable_url" 1 "$stable_target" "$sparkle_public_key" "$current_version" "$current_build" "$verifier_path" "$REMOTE_TEMP_DIR"
  check_remote_appcast_channel \
    beta "$beta_url" "$beta_required" "$beta_target" "$sparkle_public_key" "$current_version" "$current_build" "$verifier_path" "$REMOTE_TEMP_DIR"
  rm -rf "$REMOTE_TEMP_DIR"
  REMOTE_TEMP_DIR=""
}

check_signing() {
  [[ -d "$APP_DIR" ]] || return

  if codesign --verify --deep --strict --verbose=2 "$APP_DIR"; then
    pass "codesign deep strict verification"
  else
    fail "codesign deep strict verification failed"
  fi

  local signing_details
  signing_details="$(codesign -dvvv "$APP_DIR" 2>&1 || true)"
  local developer_id_present=0
  if grep -Fq "Authority=Developer ID Application:" <<<"$signing_details"; then
    developer_id_present=1
    pass "Developer ID Application signature present"
  elif grep -Fq "Signature=adhoc" <<<"$signing_details"; then
    if [[ "$REQUIRE_DEVELOPER_ID" == "1" ]]; then
      fail "app is ad-hoc signed; set STACIO_CODESIGN_IDENTITY to a Developer ID Application identity"
    else
      skip "Developer ID Application signature not present; current app is ad-hoc signed"
    fi
  else
    if [[ "$REQUIRE_DEVELOPER_ID" == "1" ]]; then
      fail "Developer ID Application signature not present"
    else
      skip "Developer ID Application signature not present"
    fi
  fi

  if [[ "$REQUIRE_DEVELOPER_ID" == "1" || "$developer_id_present" == "1" ]]; then
    if grep -Eq 'flags=.*\([^)]*runtime[^)]*\)' <<<"$signing_details"; then
      pass "Hardened Runtime enabled"
    else
      fail "Hardened Runtime is not enabled for the release app"
    fi
  fi

  local gatekeeper_status
  gatekeeper_status="$(spctl --status 2>&1 || true)"
  if grep -Fqi "assessments disabled" <<<"$gatekeeper_status"; then
    if [[ "$LOCAL_SMOKE" == "1" ]]; then
      skip "Gatekeeper assessments are disabled; local-smoke mode cannot prove distribution acceptance"
    else
      fail "Gatekeeper assessments are disabled; distribution acceptance cannot be verified"
    fi
    return
  fi

  local spctl_output_file spctl_output
  spctl_output_file="$(mktemp)"
  if spctl -a -vv "$APP_DIR" >"$spctl_output_file" 2>&1; then
    spctl_output="$(cat "$spctl_output_file" 2>/dev/null || true)"
    if grep -Fqi "override=security disabled" <<<"$spctl_output"; then
      if [[ "$LOCAL_SMOKE" == "1" ]]; then
        skip "Gatekeeper returned a security-disabled override"
      else
        fail "Gatekeeper assessments are disabled; distribution acceptance cannot be verified"
      fi
    else
      pass "spctl assessment accepted app"
    fi
  else
    spctl_output="$(cat "$spctl_output_file" 2>/dev/null || true)"
    if [[ "$REQUIRE_DEVELOPER_ID" == "1" ]]; then
      fail "spctl assessment rejected app: ${spctl_output//$'\n'/ }"
    else
      skip "spctl assessment not accepted for local test app: ${spctl_output//$'\n'/ }"
    fi
  fi
  rm -f "$spctl_output_file"
}

check_developer_identity() {
  local identity
  identity="$(developer_id_identity)"
  if [[ -n "$identity" ]]; then
    pass "Developer ID identity available: $identity"
  elif [[ "$REQUIRE_DEVELOPER_ID" == "1" ]]; then
    fail "Developer ID Application identity missing from keychain"
  else
    skip "Developer ID Application identity missing from keychain"
  fi
}

check_dmg() {
  [[ -f "$DMG_PATH" ]] || { fail "DMG missing: $DMG_PATH"; return; }
  pass "DMG exists: $DMG_PATH"

  run_cmd hdiutil verify "$DMG_PATH"

  local mount_dir
  mount_dir="$(mktemp -d)"
  local attached=0
  if hdiutil attach "$DMG_PATH" -readonly -nobrowse -mountpoint "$mount_dir" >/tmp/stacio-hdiutil-attach.out 2>&1; then
    attached=1
    pass "DMG attaches read-only"
    local mounted_app="$mount_dir/Stacio.app"
    if [[ -d "$mounted_app" ]]; then
      pass "DMG root contains Stacio.app"
      local diff_output
      diff_output="$(mktemp)"
      if diff -qr "$APP_DIR" "$mounted_app" >"$diff_output" 2>&1; then
        pass "DMG Stacio.app matches release app bundle"
      else
        fail "DMG Stacio.app does not match release app bundle: $(head -n 1 "$diff_output" 2>/dev/null || true)"
      fi
      rm -f "$diff_output"

      if codesign --verify --deep --strict --verbose=2 "$mounted_app"; then
        pass "DMG Stacio.app codesign deep strict verification"
      else
        fail "DMG Stacio.app codesign deep strict verification failed"
      fi
      if "$ROOT_DIR/scripts/smoke-local-app.sh" "$mounted_app"; then
        pass "DMG Stacio.app local smoke"
      else
        fail "DMG Stacio.app local smoke failed"
      fi
      check_product_ops_configuration "$mounted_app" "DMG "
    else
      fail "DMG root does not contain Stacio.app"
    fi
  else
    fail "DMG attach failed: $(tr '\n' ' ' </tmp/stacio-hdiutil-attach.out 2>/dev/null || true)"
  fi

  if (( attached == 1 )); then
    hdiutil detach "$mount_dir" -quiet || warn "could not detach DMG mountpoint: $mount_dir"
  fi
  rm -f /tmp/stacio-hdiutil-attach.out
  rmdir "$mount_dir" 2>/dev/null || true
}

check_artifact_freshness() {
  [[ -d "$APP_DIR" && -f "$DMG_PATH" ]] || return

  local source_paths=()
  if [[ "$SOURCE_ROOT" != "$ROOT_DIR" ]]; then
    source_paths+=("$SOURCE_ROOT")
  else
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
      "$ROOT_DIR/logo/icon.icns" \
      "$ROOT_DIR/node_modules/monaco-editor/min/vs" \
      "$ROOT_DIR/scripts/package-app.sh" \
      "$ROOT_DIR/scripts/package-dmg.sh" \
      "$ROOT_DIR/scripts/release-readiness.sh" \
      "$ROOT_DIR/scripts/smoke-local-app.sh"
    do
      [[ -e "$candidate" ]] && source_paths+=("$candidate")
    done
  fi

  local freshness_details
  if freshness_details="$(python3 - "$APP_DIR" "$DMG_PATH" "${source_paths[@]}" <<'PY'
import os
import sys

app_path, dmg_path, *roots = sys.argv[1:]
excluded = {".git", ".build", ".swiftpm", "dist", "node_modules", "后台", "官网"}
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
    for current, directories, files in os.walk(root):
        directories[:] = [name for name in directories if name not in excluded]
        for filename in files:
            consider(os.path.join(current, filename))

if newest_path is None:
    print("no App source files were found for freshness verification")
    raise SystemExit(1)

app_ns = os.stat(app_path).st_mtime_ns
dmg_ns = os.stat(dmg_path).st_mtime_ns
if app_ns <= newest_ns or dmg_ns <= newest_ns:
    print(f"newest source is {newest_path}")
    raise SystemExit(1)
print(f"newest source is {newest_path}")
PY
)"; then
    pass "release artifacts are newer than App source ($freshness_details)"
  else
    fail "release artifacts are older than App source ($freshness_details)"
  fi

  local executable_source_paths=()
  if [[ "$SOURCE_ROOT" != "$ROOT_DIR" ]]; then
    executable_source_paths+=("$SOURCE_ROOT")
  else
    local executable_candidate
    for executable_candidate in \
      "$ROOT_DIR/Package.swift" \
      "$ROOT_DIR/Package.resolved" \
      "$ROOT_DIR/Stacio" \
      "$ROOT_DIR/StacioAgentBridge" \
      "$ROOT_DIR/StacioExecutable"
    do
      [[ -e "$executable_candidate" ]] && executable_source_paths+=("$executable_candidate")
    done
  fi

  local executable_freshness
  if executable_freshness="$(python3 - "$APP_DIR/Contents/MacOS/Stacio" "${executable_source_paths[@]}" <<'PY'
import os
import sys

artifact, *roots = sys.argv[1:]
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
    for current, directories, files in os.walk(root):
        directories[:] = [name for name in directories if name not in excluded]
        for filename in files:
            consider(os.path.join(current, filename))

if newest_path is None:
    print("no executable source files were found")
    raise SystemExit(1)
try:
    artifact_ns = os.stat(artifact).st_mtime_ns
except OSError:
    print(f"packaged executable missing: {artifact}")
    raise SystemExit(1)
if artifact_ns <= newest_ns:
    print(f"newest executable source is {newest_path}")
    raise SystemExit(1)
print(f"newest executable source is {newest_path}")
PY
)"; then
    pass "packaged Stacio executable is newer than App source ($executable_freshness)"
  else
    fail "packaged Stacio executable is older than App source ($executable_freshness)"
  fi
}

check_notary_readiness() {
  if [[ "$REQUIRE_NOTARY" == "1" ]]; then
    if notary_configured; then
      pass "notary credentials are configured"
    else
      fail "notary credentials missing; configure STACIO_NOTARY_PROFILE or APPLE_ID/APPLE_TEAM_ID/APPLE_APP_SPECIFIC_PASSWORD"
    fi
    if xcrun stapler validate "$APP_DIR" >/dev/null 2>&1 \
      && xcrun stapler validate "$DMG_PATH" >/dev/null 2>&1; then
      pass "notarization tickets validate for App and DMG"
    else
      fail "notarization ticket validation failed for App or DMG"
    fi
    return
  fi

  if notary_configured; then
    pass "notary credentials are configured"
    skip "notarization ticket validation not required in local-smoke mode; set STACIO_RELEASE_REQUIRE_NOTARY=1 to opt in"
  else
    skip "notary credentials missing; formal notarization not attempted"
  fi
}

printf 'Stacio release readiness\n'
printf 'Repository: %s\n' "$ROOT_DIR"
printf 'App: %s\n' "$APP_DIR"
printf 'DMG: %s\n\n' "$DMG_PATH"

require_tool plutil
require_tool codesign
require_tool spctl
require_tool hdiutil
require_tool security
require_tool python3
require_tool diff
require_tool cmp
if [[ "$LOCAL_SMOKE" != "1" ]]; then
  require_tool curl
  require_tool swift
fi
if [[ "$REQUIRE_NOTARY" == "1" ]]; then
  require_tool xcrun
fi

if [[ "$LOCAL_SMOKE" != "0" && "$LOCAL_SMOKE" != "1" ]]; then
  fail "STACIO_RELEASE_LOCAL_SMOKE must be 0 or 1"
fi
if [[ "$RUN_PACKAGE" != "0" && "$RUN_PACKAGE" != "1" ]]; then
  fail "STACIO_RELEASE_SKIP_PACKAGE must be 0 or 1"
fi
if [[ "$REQUESTED_REQUIRE_DEVELOPER_ID" != "0" && "$REQUESTED_REQUIRE_DEVELOPER_ID" != "1" ]]; then
  fail "STACIO_RELEASE_REQUIRE_DEVELOPER_ID must be 0 or 1"
fi
if [[ "$REQUESTED_REQUIRE_NOTARY" != "0" && "$REQUESTED_REQUIRE_NOTARY" != "1" ]]; then
  fail "STACIO_RELEASE_REQUIRE_NOTARY must be 0 or 1"
fi

acquire_release_lock

if (( failures == 0 )) && [[ "$RUN_PACKAGE" != "1" ]]; then
  run_cmd "$ROOT_DIR/scripts/package-app.sh"
  run_cmd "$ROOT_DIR/scripts/package-dmg.sh" "$APP_DIR" "$DMG_PATH"
elif [[ "$RUN_PACKAGE" == "1" ]]; then
  skip "packaging skipped by STACIO_RELEASE_SKIP_PACKAGE=1"
fi

check_app_bundle
check_product_ops_configuration
check_remote_appcasts
check_signing
check_developer_identity
check_dmg
check_artifact_freshness
check_notary_readiness

printf '\nSummary: %d failure(s), %d warning(s), %d skip(s)\n' "$failures" "$warnings" "$skips"
if (( failures > 0 )); then
  exit 1
fi
