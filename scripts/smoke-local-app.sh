#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${1:-$ROOT_DIR/dist/Stacio.app}"
CONTENTS_DIR="$APP_DIR/Contents"
PLIST_PATH="$CONTENTS_DIR/Info.plist"
MACOS_DIR="$CONTENTS_DIR/MacOS"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
ADAPTERS_DIR="$CONTENTS_DIR/Adapters"
HELPERS_DIR="$CONTENTS_DIR/Helpers"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
CORE_DYLIB="$FRAMEWORKS_DIR/libstacio_core.dylib"
SPARKLE_FRAMEWORK="$FRAMEWORKS_DIR/Sparkle.framework"
CLI_HELPER="$HELPERS_DIR/stacio"
MONACO_LOADER="$RESOURCES_DIR/MonacoEditor/vs/loader.js"
ABOUT_WECHAT_ICON="$RESOURCES_DIR/About/wechat-official-account.svg"
RDP_ADAPTER="$ADAPTERS_DIR/rdp"
RDP_VIEWER="$ADAPTERS_DIR/rdp-viewer"
RDP_VIEWER_APP="$ADAPTERS_DIR/StacioRDPViewer.app"
VNC_ADAPTER="$ADAPTERS_DIR/vnc"
PLIST_BUDDY="/usr/libexec/PlistBuddy"
EXPECTED_MINIMUM_SYSTEM_VERSION="14.0"

failures=0
warnings=0

pass() {
  printf 'PASS %s\n' "$1"
}

warn() {
  warnings=$((warnings + 1))
  printf 'WARN %s\n' "$1"
}

fail() {
  failures=$((failures + 1))
  printf 'FAIL %s\n' "$1" >&2
}

require_path() {
  local kind="$1"
  local path="$2"
  local label="$3"

  case "$kind" in
    dir)
      [[ -d "$path" ]] && pass "$label: $path" || fail "$label missing: $path"
      ;;
    file)
      [[ -f "$path" ]] && pass "$label: $path" || fail "$label missing: $path"
      ;;
    executable)
      [[ -x "$path" ]] && pass "$label: $path" || fail "$label missing or not executable: $path"
      ;;
    *)
      fail "unknown path check kind: $kind"
      ;;
  esac
}

plist_value() {
  local key="$1"
  "$PLIST_BUDDY" -c "Print :$key" "$PLIST_PATH" 2>/dev/null || true
}

printf 'Stacio local app smoke\n'
printf 'App: %s\n\n' "$APP_DIR"

require_path dir "$APP_DIR" "app bundle"
require_path dir "$CONTENTS_DIR" "Contents directory"
require_path file "$PLIST_PATH" "Info.plist"
require_path dir "$MACOS_DIR" "MacOS directory"
require_path dir "$FRAMEWORKS_DIR" "Frameworks directory"
require_path dir "$ADAPTERS_DIR" "Adapters directory"
require_path dir "$HELPERS_DIR" "Helpers directory"
require_path dir "$RESOURCES_DIR" "Resources directory"
require_path file "$CORE_DYLIB" "UniFFI/Rust core dylib"
require_path dir "$SPARKLE_FRAMEWORK" "Sparkle 2 framework"
SPARKLE_VERSION_DIR="$SPARKLE_FRAMEWORK/Versions/Current"
if [[ ! -d "$SPARKLE_VERSION_DIR" ]]; then
  SPARKLE_VERSION_DIR="$SPARKLE_FRAMEWORK/Versions/B"
fi
require_path executable "$SPARKLE_FRAMEWORK/Sparkle" "Sparkle framework binary"
require_path executable "$SPARKLE_VERSION_DIR/Autoupdate" "Sparkle Autoupdate"
require_path executable "$SPARKLE_VERSION_DIR/Updater.app/Contents/MacOS/Updater" "Sparkle Updater"
require_path executable "$SPARKLE_VERSION_DIR/XPCServices/Downloader.xpc/Contents/MacOS/Downloader" "Sparkle Downloader XPC"
require_path executable "$SPARKLE_VERSION_DIR/XPCServices/Installer.xpc/Contents/MacOS/Installer" "Sparkle Installer XPC"
require_path executable "$CLI_HELPER" "Stacio CLI helper"
require_path file "$MONACO_LOADER" "Monaco Editor loader"
require_path file "$ABOUT_WECHAT_ICON" "About WeChat official account icon"
if [[ -e "$RDP_ADAPTER" || -e "$RDP_VIEWER" || -e "$RDP_VIEWER_APP" ]]; then
  fail "removed RDP assets should not be packaged under Contents/Adapters"
else
  pass "RDP assets absent"
fi
require_path executable "$VNC_ADAPTER" "Stacio VNC adapter"

if [[ -f "$PLIST_PATH" ]]; then
  if plutil -lint "$PLIST_PATH" >/dev/null; then
    pass "Info.plist syntax"
  else
    fail "Info.plist syntax invalid"
  fi

  executable_name="$(plist_value CFBundleExecutable)"
  bundle_id="$(plist_value CFBundleIdentifier)"
  package_type="$(plist_value CFBundlePackageType)"
  minimum_system="$(plist_value LSMinimumSystemVersion)"
  development_region="$(plist_value CFBundleDevelopmentRegion)"
  quit_always_keeps_windows="$(plist_value NSQuitAlwaysKeepsWindows)"

  [[ "$executable_name" == "Stacio" ]] && pass "CFBundleExecutable=$executable_name" || fail "CFBundleExecutable expected Stacio, got ${executable_name:-<empty>}"
  [[ "$bundle_id" == "com.stacio.Stacio" ]] && pass "CFBundleIdentifier=$bundle_id" || fail "CFBundleIdentifier expected com.stacio.Stacio, got ${bundle_id:-<empty>}"
  [[ "$package_type" == "APPL" ]] && pass "CFBundlePackageType=$package_type" || fail "CFBundlePackageType expected APPL, got ${package_type:-<empty>}"
  [[ "$minimum_system" == "$EXPECTED_MINIMUM_SYSTEM_VERSION" ]] && pass "LSMinimumSystemVersion=$minimum_system" || fail "LSMinimumSystemVersion expected $EXPECTED_MINIMUM_SYSTEM_VERSION, got ${minimum_system:-<empty>}"
  [[ "$development_region" == "zh-Hans" ]] && pass "CFBundleDevelopmentRegion=$development_region" || fail "CFBundleDevelopmentRegion expected zh-Hans, got ${development_region:-<empty>}"
  [[ "$quit_always_keeps_windows" == "false" ]] && pass "NSQuitAlwaysKeepsWindows=$quit_always_keeps_windows" || fail "NSQuitAlwaysKeepsWindows expected false, got ${quit_always_keeps_windows:-<empty>}"
  if /usr/libexec/PlistBuddy -c "Print :CFBundleLocalizations" "$PLIST_PATH" 2>/dev/null | grep -Fq "zh-Hans"; then
    pass "CFBundleLocalizations includes zh-Hans"
  else
    fail "CFBundleLocalizations missing zh-Hans"
  fi
  if /usr/libexec/PlistBuddy -c "Print :CFBundleAllowMixedLocalizations" "$PLIST_PATH" 2>/dev/null | grep -Fq "true"; then
    pass "CFBundleAllowMixedLocalizations=true"
  else
    fail "CFBundleAllowMixedLocalizations expected true"
  fi

  if [[ -n "$executable_name" ]]; then
    require_path executable "$MACOS_DIR/$executable_name" "app executable"
  fi
fi

if [[ -x "$MACOS_DIR/Stacio" ]]; then
  app_symbols="$(nm -gj "$MACOS_DIR/Stacio" 2>/dev/null || true)"
  if [[ "$app_symbols" == *"_StacioCLI_main"* ]]; then
    fail "Stacio app executable is the CLI entry point"
  elif [[ "$app_symbols" == *"_StacioMain_main"* ]]; then
    pass "Stacio app executable uses the AppKit entry point"
  fi

  if ! otool -L "$MACOS_DIR/Stacio" | grep -Fq 'libstacio_core.dylib'; then
    pass "Stacio executable has no direct libstacio_core.dylib load command"
  elif otool -L "$MACOS_DIR/Stacio" | grep -Fq '@executable_path/../Frameworks/libstacio_core.dylib'; then
    pass "Stacio executable links bundled libstacio_core.dylib"
  else
    fail "Stacio executable does not reference @executable_path/../Frameworks/libstacio_core.dylib"
  fi

  if otool -L "$MACOS_DIR/Stacio" | grep -Fq '@rpath/Sparkle.framework/Versions/B/Sparkle'; then
    pass "Stacio executable links Sparkle.framework through @rpath"
  else
    fail "Stacio executable does not link Sparkle.framework through @rpath"
  fi

  if otool -l "$MACOS_DIR/Stacio" \
    | awk '
        $1 == "cmd" && $2 == "LC_RPATH" { in_rpath = 1; next }
        in_rpath && $1 == "path" { print $2; in_rpath = 0 }
      ' \
    | grep -Fxq '@executable_path/../Frameworks'; then
    pass "Stacio executable has Frameworks rpath"
  else
    fail "Stacio executable missing @executable_path/../Frameworks rpath"
  fi
fi

if [[ -f "$CORE_DYLIB" ]]; then
  if otool -D "$CORE_DYLIB" | grep -Fq '@rpath/libstacio_core.dylib'; then
    pass "libstacio_core.dylib install name is @rpath/libstacio_core.dylib"
  else
    warn "libstacio_core.dylib install name is not @rpath/libstacio_core.dylib"
  fi
fi

if [[ -d "$CONTENTS_DIR/_CodeSignature" ]]; then
  pass "CodeSignature directory exists"
else
  warn "CodeSignature directory missing; package may still be local-only but Gatekeeper behavior can differ"
fi

if codesign --verify --deep --strict --verbose=2 "$APP_DIR" >/dev/null 2>&1; then
  pass "codesign verification"
else
  warn "codesign verification failed; this is not a notarization check"
fi

printf '\nSummary: %d failure(s), %d warning(s)\n' "$failures" "$warnings"
if (( failures > 0 )); then
  exit 1
fi
