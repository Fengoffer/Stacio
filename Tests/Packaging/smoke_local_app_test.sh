#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAKE_BIN_DIR="$TMP_DIR/bin"
mkdir -p "$FAKE_BIN_DIR"

cat >"$FAKE_BIN_DIR/otool" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  -L)
    printf '%s:\n' "${2:-}"
    printf '\t@executable_path/../Frameworks/libstacio_core.dylib (compatibility version 0.0.0, current version 0.0.0)\n'
    printf '\t@rpath/Sparkle.framework/Versions/B/Sparkle (compatibility version 1.6.0, current version 2.9.4)\n'
    ;;
  -l)
    printf '          cmd LC_RPATH\n'
    printf '         path @executable_path/../Frameworks (offset 12)\n'
    ;;
  -D)
    printf '%s:\n' "${2:-}"
    printf '@rpath/libstacio_core.dylib\n'
    ;;
  *)
    exit 1
    ;;
esac
EOF
chmod +x "$FAKE_BIN_DIR/otool"

cat >"$FAKE_BIN_DIR/codesign" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$FAKE_BIN_DIR/codesign"

cat >"$FAKE_BIN_DIR/nm" <<'EOF'
#!/usr/bin/env bash
target="${@: -1}"
if grep -Fq 'CLI_ENTRY' "$target" 2>/dev/null; then
  printf '_StacioCLI_main\n'
else
  printf '_StacioMain_main\n'
fi
EOF
chmod +x "$FAKE_BIN_DIR/nm"

make_fake_app() {
  local app_dir="$1"
  local minimum_system="$2"
  local entry_marker="${3:-APP_ENTRY}"
  local contents_dir="$app_dir/Contents"
  local macos_dir="$contents_dir/MacOS"
  local frameworks_dir="$contents_dir/Frameworks"
  local adapters_dir="$contents_dir/Adapters"
  local resources_dir="$contents_dir/Resources"
  mkdir -p \
    "$macos_dir" \
    "$frameworks_dir" \
    "$adapters_dir" \
    "$resources_dir/About" \
    "$resources_dir/SwiftTerm_SwiftTerm.bundle" \
    "$resources_dir/MonacoEditor/vs" \
    "$contents_dir/_CodeSignature"

  cat >"$contents_dir/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>Stacio</string>
  <key>CFBundleDevelopmentRegion</key>
  <string>zh-Hans</string>
  <key>CFBundleLocalizations</key>
  <array>
    <string>zh-Hans</string>
    <string>en</string>
  </array>
  <key>CFBundleAllowMixedLocalizations</key>
  <true/>
  <key>CFBundleIdentifier</key>
  <string>com.stacio.Stacio</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$minimum_system</string>
  <key>NSQuitAlwaysKeepsWindows</key>
  <false/>
</dict>
</plist>
PLIST

  printf '#!/usr/bin/env bash\n# %s\nexit 0\n' "$entry_marker" >"$macos_dir/Stacio"
  mkdir -p "$contents_dir/Helpers"
  printf '#!/usr/bin/env bash\necho "fake stacio CLI"\n' >"$contents_dir/Helpers/stacio"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$adapters_dir/vnc"
  printf 'fake dylib\n' >"$frameworks_dir/libstacio_core.dylib"
  mkdir -p \
    "$frameworks_dir/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS" \
    "$frameworks_dir/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS" \
    "$frameworks_dir/Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS"
  printf 'fake sparkle framework\n' >"$frameworks_dir/Sparkle.framework/Sparkle"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$frameworks_dir/Sparkle.framework/Versions/B/Autoupdate"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$frameworks_dir/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$frameworks_dir/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$frameworks_dir/Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer"
  printf 'fake monaco loader\n' >"$resources_dir/MonacoEditor/vs/loader.js"
  printf '<svg xmlns="http://www.w3.org/2000/svg"/>\n' >"$resources_dir/About/wechat-official-account.svg"
  printf 'fake SwiftTerm shader\n' >"$resources_dir/SwiftTerm_SwiftTerm.bundle/Shaders.metal"
  chmod +x \
    "$macos_dir/Stacio" \
    "$contents_dir/Helpers/stacio" \
    "$adapters_dir/vnc" \
    "$frameworks_dir/Sparkle.framework/Sparkle" \
    "$frameworks_dir/Sparkle.framework/Versions/B/Autoupdate" \
    "$frameworks_dir/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater" \
    "$frameworks_dir/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader" \
    "$frameworks_dir/Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer"
}

VALID_APP="$TMP_DIR/valid/Stacio.app"
make_fake_app "$VALID_APP" "14.0"

PATH="$FAKE_BIN_DIR:$PATH" \
  "$ROOT_DIR/scripts/smoke-local-app.sh" "$VALID_APP" >"$TMP_DIR/valid.out"

grep -Fq "PASS LSMinimumSystemVersion=14.0" "$TMP_DIR/valid.out"
grep -Fq "PASS NSQuitAlwaysKeepsWindows=false" "$TMP_DIR/valid.out"
grep -Fq "PASS Stacio VNC adapter" "$TMP_DIR/valid.out"
grep -Fq "PASS Sparkle Installer XPC" "$TMP_DIR/valid.out"
grep -Fq "PASS SwiftTerm Metal shader" "$TMP_DIR/valid.out"
grep -Fq "Summary: 0 failure(s), 0 warning(s)" "$TMP_DIR/valid.out"

MISSING_SWIFTTERM_SHADER_APP="$TMP_DIR/missing-swiftterm-shader/Stacio.app"
make_fake_app "$MISSING_SWIFTTERM_SHADER_APP" "14.0"
rm "$MISSING_SWIFTTERM_SHADER_APP/Contents/Resources/SwiftTerm_SwiftTerm.bundle/Shaders.metal"

if PATH="$FAKE_BIN_DIR:$PATH" \
  "$ROOT_DIR/scripts/smoke-local-app.sh" "$MISSING_SWIFTTERM_SHADER_APP" >"$TMP_DIR/missing-swiftterm-shader.out" 2>&1; then
  echo "expected missing SwiftTerm shader to fail" >&2
  exit 1
fi

grep -Fq "SwiftTerm Metal shader missing" "$TMP_DIR/missing-swiftterm-shader.out"

INVALID_ROOT_SWIFTTERM_LOCATION_APP="$TMP_DIR/invalid-root-swiftterm-location/Stacio.app"
make_fake_app "$INVALID_ROOT_SWIFTTERM_LOCATION_APP" "14.0"
mkdir -p "$INVALID_ROOT_SWIFTTERM_LOCATION_APP/SwiftTerm_SwiftTerm.bundle"
mv \
  "$INVALID_ROOT_SWIFTTERM_LOCATION_APP/Contents/Resources/SwiftTerm_SwiftTerm.bundle/Shaders.metal" \
  "$INVALID_ROOT_SWIFTTERM_LOCATION_APP/SwiftTerm_SwiftTerm.bundle/Shaders.metal"

if PATH="$FAKE_BIN_DIR:$PATH" \
  "$ROOT_DIR/scripts/smoke-local-app.sh" "$INVALID_ROOT_SWIFTTERM_LOCATION_APP" >"$TMP_DIR/invalid-root-swiftterm-location.out" 2>&1; then
  echo "expected root SwiftTerm resource location to fail" >&2
  exit 1
fi

grep -Fq "SwiftTerm Metal shader missing" "$TMP_DIR/invalid-root-swiftterm-location.out"

MISSING_VNC_ADAPTER_APP="$TMP_DIR/missing-vnc-adapter/Stacio.app"
make_fake_app "$MISSING_VNC_ADAPTER_APP" "14.0"
rm "$MISSING_VNC_ADAPTER_APP/Contents/Adapters/vnc"

if PATH="$FAKE_BIN_DIR:$PATH" \
  "$ROOT_DIR/scripts/smoke-local-app.sh" "$MISSING_VNC_ADAPTER_APP" >"$TMP_DIR/missing-vnc-adapter.out" 2>&1; then
  echo "expected missing VNC adapter to fail" >&2
  exit 1
fi

grep -Fq "Stacio VNC adapter missing or not executable" "$TMP_DIR/missing-vnc-adapter.out"

MISSING_SPARKLE_COMPONENT_APP="$TMP_DIR/missing-sparkle-component/Stacio.app"
make_fake_app "$MISSING_SPARKLE_COMPONENT_APP" "14.0"
rm "$MISSING_SPARKLE_COMPONENT_APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer"

if PATH="$FAKE_BIN_DIR:$PATH" \
  "$ROOT_DIR/scripts/smoke-local-app.sh" "$MISSING_SPARKLE_COMPONENT_APP" >"$TMP_DIR/missing-sparkle-component.out" 2>&1; then
  echo "expected missing Sparkle installer to fail" >&2
  exit 1
fi

grep -Fq "Sparkle Installer XPC missing or not executable" "$TMP_DIR/missing-sparkle-component.out"

INVALID_APP="$TMP_DIR/invalid/Stacio.app"
make_fake_app "$INVALID_APP" "13.0"

if PATH="$FAKE_BIN_DIR:$PATH" \
  "$ROOT_DIR/scripts/smoke-local-app.sh" "$INVALID_APP" >"$TMP_DIR/invalid.out" 2>&1; then
  echo "expected invalid LSMinimumSystemVersion to fail" >&2
  exit 1
fi

grep -Fq "LSMinimumSystemVersion expected 14.0, got 13.0" "$TMP_DIR/invalid.out"

CLI_ENTRY_APP="$TMP_DIR/cli-entry/Stacio.app"
make_fake_app "$CLI_ENTRY_APP" "14.0" "CLI_ENTRY"

if PATH="$FAKE_BIN_DIR:$PATH" \
  "$ROOT_DIR/scripts/smoke-local-app.sh" "$CLI_ENTRY_APP" >"$TMP_DIR/cli-entry.out" 2>&1; then
  echo "expected CLI entry point app executable to fail" >&2
  exit 1
fi

grep -Fq "Stacio app executable is the CLI entry point" "$TMP_DIR/cli-entry.out"

echo "smoke_local_app_test passed"
