#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
cleanup() {
  local status="$1"
  if (( status != 0 )) && [[ -f "${LOG_FILE:-}" ]]; then
    cat "$LOG_FILE" >&2
  fi
  rm -rf "$TMP_DIR"
  exit "$status"
}
trap 'cleanup $?' EXIT

FAKE_BIN_DIR="$TMP_DIR/bin"
SWIFT_BIN_DIR="$TMP_DIR/swift-release"
CORE_DIR="$TMP_DIR/core-release"
MONACO_VS_DIR="$TMP_DIR/monaco-vs"
OUT_DIR="$TMP_DIR/out"
LOG_FILE="$TMP_DIR/tool-calls.log"
ED25519_TEST_PUBLIC_KEY="PUAXw+hDiVqStwqnTRt+vJyYLM8uxJaMwM1V8Sr0Zgw="

unset GITHUB_RUN_NUMBER

mkdir -p \
  "$FAKE_BIN_DIR" \
  "$SWIFT_BIN_DIR" \
  "$CORE_DIR" \
  "$MONACO_VS_DIR" \
  "$SWIFT_BIN_DIR/SwiftTerm_SwiftTerm.bundle" \
  "$SWIFT_BIN_DIR/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS" \
  "$SWIFT_BIN_DIR/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS" \
  "$SWIFT_BIN_DIR/Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS" \
  "$SWIFT_BIN_DIR/Sparkle.framework/Versions/B/Resources"

SWIFTTERM_PATCH_TEST_CHECKOUT="$TMP_DIR/swiftterm-checkout"
SWIFTTERM_PATCH_TEST_SOURCE="$SWIFTTERM_PATCH_TEST_CHECKOUT/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift"
mkdir -p "$(dirname "$SWIFTTERM_PATCH_TEST_SOURCE")"
cat >"$SWIFTTERM_PATCH_TEST_SOURCE" <<'EOF'
private final class MetalTerminalRenderer {
    private static func candidateBundles() -> [Bundle] {
        var bundles: [Bundle] = []
        #if SWIFT_PACKAGE
        bundles.append(Bundle.module)
        #endif
        bundles.append(Bundle(for: MetalTerminalRenderer.self))
        bundles.append(Bundle.main)
        return bundles
    }
}
EOF
"$ROOT_DIR/scripts/patch-swiftterm-macos-resources.sh" "$SWIFTTERM_PATCH_TEST_CHECKOUT"
grep -Fq "Stacio macOS packages keep SwiftPM resources under Contents/Resources." "$SWIFTTERM_PATCH_TEST_SOURCE"
grep -Fq "if bundles.isEmpty" "$SWIFTTERM_PATCH_TEST_SOURCE"
test ! -e "$SWIFTTERM_PATCH_TEST_SOURCE.orig"
"$ROOT_DIR/scripts/patch-swiftterm-macos-resources.sh" "$SWIFTTERM_PATCH_TEST_CHECKOUT"

cat >"$SWIFT_BIN_DIR/Stacio" <<'EOF'
#!/usr/bin/env bash
echo "fake Stacio"
EOF
chmod +x "$SWIFT_BIN_DIR/Stacio"

cat >"$SWIFT_BIN_DIR/StacioCLI" <<'EOF'
#!/usr/bin/env bash
echo "fake stacio CLI"
EOF
chmod +x "$SWIFT_BIN_DIR/StacioCLI"

cat >"$SWIFT_BIN_DIR/StacioVNCAdapter" <<'EOF'
#!/usr/bin/env bash
echo "fake VNC adapter"
EOF
chmod +x "$SWIFT_BIN_DIR/StacioVNCAdapter"

printf 'fake dylib\n' >"$CORE_DIR/libstacio_core.dylib"
printf 'fake sparkle framework\n' >"$SWIFT_BIN_DIR/Sparkle.framework/Sparkle"
printf 'fake autoupdate\n' >"$SWIFT_BIN_DIR/Sparkle.framework/Versions/B/Autoupdate"
printf 'fake updater\n' >"$SWIFT_BIN_DIR/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater"
printf 'fake downloader\n' >"$SWIFT_BIN_DIR/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"
printf 'fake installer\n' >"$SWIFT_BIN_DIR/Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer"
cat >"$SWIFT_BIN_DIR/Sparkle.framework/Versions/B/Resources/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleShortVersionString</key>
  <string>2.9.4</string>
</dict>
</plist>
EOF
printf 'fake SwiftTerm shader\n' >"$SWIFT_BIN_DIR/SwiftTerm_SwiftTerm.bundle/Shaders.metal"
chmod 444 "$SWIFT_BIN_DIR/SwiftTerm_SwiftTerm.bundle/Shaders.metal"
chmod +x \
  "$SWIFT_BIN_DIR/Sparkle.framework/Sparkle" \
  "$SWIFT_BIN_DIR/Sparkle.framework/Versions/B/Autoupdate" \
  "$SWIFT_BIN_DIR/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater" \
  "$SWIFT_BIN_DIR/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader" \
  "$SWIFT_BIN_DIR/Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer"
printf 'fake monaco loader\n' >"$MONACO_VS_DIR/loader.js"
printf 'fake monaco editor\n' >"$MONACO_VS_DIR/editor.main.js"

cat >"$FAKE_BIN_DIR/install_name_tool" <<'EOF'
#!/usr/bin/env bash
printf 'install_name_tool %q' "$1" >>"$STACIO_PACKAGE_TEST_LOG"
shift
for arg in "$@"; do
  printf ' %q' "$arg" >>"$STACIO_PACKAGE_TEST_LOG"
done
printf '\n' >>"$STACIO_PACKAGE_TEST_LOG"
EOF
chmod +x "$FAKE_BIN_DIR/install_name_tool"

cat >"$FAKE_BIN_DIR/codesign" <<'EOF'
#!/usr/bin/env bash
printf 'codesign' >>"$STACIO_PACKAGE_TEST_LOG"
for arg in "$@"; do
  printf ' %q' "$arg" >>"$STACIO_PACKAGE_TEST_LOG"
done
printf '\n' >>"$STACIO_PACKAGE_TEST_LOG"
EOF
chmod +x "$FAKE_BIN_DIR/codesign"

cat >"$FAKE_BIN_DIR/git" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"rev-parse --is-shallow-repository"* ]]; then
  if [[ "${STACIO_PACKAGE_TEST_SHALLOW_REPOSITORY:-0}" == "1" ]]; then
    printf 'true\n'
  else
    printf 'false\n'
  fi
  exit 0
fi
if [[ "$*" == *"rev-list --count HEAD"* ]]; then
  printf '211\n'
  exit 0
fi
exec /usr/bin/git "$@"
EOF
chmod +x "$FAKE_BIN_DIR/git"

HELD_LOCK_DIR="$TMP_DIR/held-package.lock"
LOCKED_LOG="$TMP_DIR/locked-package.log"
mkdir -p "$HELD_LOCK_DIR"
printf '%s\n' "$$" >"$HELD_LOCK_DIR/pid"
if STACIO_SKIP_BUILD=1 \
  STACIO_PACKAGE_LOCK_DIR="$HELD_LOCK_DIR" \
  STACIO_PACKAGE_LOCK_TIMEOUT_SECONDS=0 \
  "$ROOT_DIR/scripts/package-app.sh" >"$LOCKED_LOG" 2>&1; then
  echo "expected package lock timeout to fail" >&2
  exit 1
fi
grep -Fq "Another Stacio package-app.sh appears to be running" "$LOCKED_LOG"
rm -rf "$HELD_LOCK_DIR"

expect_missing_product_ops_config_failure() {
  local missing_name="$1"
  local failure_log="$TMP_DIR/missing-$missing_name.log"
  if env \
    PATH="$FAKE_BIN_DIR:$PATH" \
    STACIO_PACKAGE_TEST_LOG="$LOG_FILE" \
    STACIO_SKIP_BUILD=1 \
    STACIO_SWIFT_BIN_PATH="$SWIFT_BIN_DIR" \
    STACIO_CORE_DYLIB_PATH="$CORE_DIR/libstacio_core.dylib" \
    STACIO_CORE_LOAD_PATH="/old/build/libstacio_core.dylib" \
    STACIO_MONACO_VS_PATH="$MONACO_VS_DIR" \
    STACIO_OUTPUT_DIR="$OUT_DIR" \
    STACIO_PRODUCT_OPS_API_BASE_URL="https://ops.example.test" \
    STACIO_FEEDBACK_PRODUCT_API_KEY="public-feedback-key" \
    STACIO_SPARKLE_PUBLIC_ED_KEY="$ED25519_TEST_PUBLIC_KEY" \
    STACIO_LICENSE_PUBLIC_ED25519_KEY="$ED25519_TEST_PUBLIC_KEY" \
    "$missing_name=" \
    "$ROOT_DIR/scripts/package-app.sh" >"$failure_log" 2>&1; then
    echo "expected packaging without $missing_name to fail" >&2
    exit 1
  fi
  grep -Fq "$missing_name" "$failure_log"
  grep -Fq "STACIO_ALLOW_INCOMPLETE_PRODUCT_OPS_CONFIG=1" "$failure_log"
}

expect_missing_product_ops_config_failure "STACIO_PRODUCT_OPS_API_BASE_URL"
expect_missing_product_ops_config_failure "STACIO_FEEDBACK_PRODUCT_API_KEY"
expect_missing_product_ops_config_failure "STACIO_SPARKLE_PUBLIC_ED_KEY"
expect_missing_product_ops_config_failure "STACIO_LICENSE_PUBLIC_ED25519_KEY"

expect_invalid_public_key_failure() {
  local invalid_name="$1"
  local failure_log="$TMP_DIR/invalid-$invalid_name.log"
  if env \
    PATH="$FAKE_BIN_DIR:$PATH" \
    STACIO_PACKAGE_TEST_LOG="$LOG_FILE" \
    STACIO_SKIP_BUILD=1 \
    STACIO_SWIFT_BIN_PATH="$SWIFT_BIN_DIR" \
    STACIO_CORE_DYLIB_PATH="$CORE_DIR/libstacio_core.dylib" \
    STACIO_CORE_LOAD_PATH="/old/build/libstacio_core.dylib" \
    STACIO_MONACO_VS_PATH="$MONACO_VS_DIR" \
    STACIO_OUTPUT_DIR="$OUT_DIR" \
    STACIO_PRODUCT_OPS_API_BASE_URL="https://ops.example.test" \
    STACIO_FEEDBACK_PRODUCT_API_KEY="public-feedback-key" \
    STACIO_SPARKLE_PUBLIC_ED_KEY="$ED25519_TEST_PUBLIC_KEY" \
    STACIO_LICENSE_PUBLIC_ED25519_KEY="$ED25519_TEST_PUBLIC_KEY" \
    "$invalid_name=not-a-valid-ed25519-key" \
    "$ROOT_DIR/scripts/package-app.sh" >"$failure_log" 2>&1; then
    echo "expected packaging with invalid $invalid_name to fail" >&2
    exit 1
  fi
  grep -Fq "$invalid_name" "$failure_log"
  grep -Fq "valid Ed25519 public key" "$failure_log"
}

expect_invalid_public_key_failure "STACIO_SPARKLE_PUBLIC_ED_KEY"
expect_invalid_public_key_failure "STACIO_LICENSE_PUBLIC_ED25519_KEY"

if env \
  PATH="$FAKE_BIN_DIR:$PATH" \
  STACIO_PACKAGE_TEST_SHALLOW_REPOSITORY=1 \
  STACIO_SKIP_BUILD=1 \
  STACIO_SWIFT_BIN_PATH="$SWIFT_BIN_DIR" \
  STACIO_CORE_DYLIB_PATH="$CORE_DIR/libstacio_core.dylib" \
  STACIO_CORE_LOAD_PATH="/old/build/libstacio_core.dylib" \
  STACIO_MONACO_VS_PATH="$MONACO_VS_DIR" \
  STACIO_OUTPUT_DIR="$OUT_DIR" \
  STACIO_PRODUCT_OPS_API_BASE_URL="https://ops.example.test" \
  STACIO_FEEDBACK_PRODUCT_API_KEY="public-feedback-key" \
  STACIO_SPARKLE_PUBLIC_ED_KEY="$ED25519_TEST_PUBLIC_KEY" \
  STACIO_LICENSE_PUBLIC_ED25519_KEY="$ED25519_TEST_PUBLIC_KEY" \
  "$ROOT_DIR/scripts/package-app.sh" >"$TMP_DIR/shallow-build-number.log" 2>&1; then
  echo "expected shallow packaging without an explicit build number to fail" >&2
  exit 1
fi
grep -Fq "STACIO_BUILD_NUMBER or GITHUB_RUN_NUMBER is required for a shallow checkout" "$TMP_DIR/shallow-build-number.log"

touch -t 201001010000 "$SWIFT_BIN_DIR/Stacio"
if env \
  PATH="$FAKE_BIN_DIR:$PATH" \
  STACIO_PACKAGE_TEST_LOG="$LOG_FILE" \
  STACIO_SKIP_BUILD=1 \
  STACIO_SWIFT_BIN_PATH="$SWIFT_BIN_DIR" \
  STACIO_CORE_DYLIB_PATH="$CORE_DIR/libstacio_core.dylib" \
  STACIO_CORE_LOAD_PATH="/old/build/libstacio_core.dylib" \
  STACIO_MONACO_VS_PATH="$MONACO_VS_DIR" \
  STACIO_OUTPUT_DIR="$OUT_DIR" \
  STACIO_BUILD_NUMBER=11 \
  STACIO_PRODUCT_OPS_API_BASE_URL="https://ops.example.test" \
  STACIO_FEEDBACK_PRODUCT_API_KEY="public-feedback-key" \
  STACIO_SPARKLE_PUBLIC_ED_KEY="$ED25519_TEST_PUBLIC_KEY" \
  STACIO_LICENSE_PUBLIC_ED25519_KEY="$ED25519_TEST_PUBLIC_KEY" \
  "$ROOT_DIR/scripts/package-app.sh" >"$TMP_DIR/stale-prebuilt.log" 2>&1; then
  echo "expected packaging with a stale prebuilt executable to fail" >&2
  exit 1
fi
grep -Fq "Prebuilt Stacio executable is older than source input" "$TMP_DIR/stale-prebuilt.log"
touch "$SWIFT_BIN_DIR/Stacio"

MISMATCHED_SPARKLE_DIR="$TMP_DIR/sparkle-version-mismatch"
cp -R "$SWIFT_BIN_DIR/Sparkle.framework" "$MISMATCHED_SPARKLE_DIR"
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 0.0.0' "$MISMATCHED_SPARKLE_DIR/Versions/B/Resources/Info.plist"
if env \
  PATH="$FAKE_BIN_DIR:$PATH" \
  STACIO_PACKAGE_TEST_LOG="$LOG_FILE" \
  STACIO_SKIP_BUILD=1 \
  STACIO_SWIFT_BIN_PATH="$SWIFT_BIN_DIR" \
  STACIO_SPARKLE_FRAMEWORK_PATH="$MISMATCHED_SPARKLE_DIR" \
  STACIO_CORE_DYLIB_PATH="$CORE_DIR/libstacio_core.dylib" \
  STACIO_CORE_LOAD_PATH="/old/build/libstacio_core.dylib" \
  STACIO_MONACO_VS_PATH="$MONACO_VS_DIR" \
  STACIO_OUTPUT_DIR="$OUT_DIR" \
  STACIO_BUILD_NUMBER=11 \
  STACIO_PRODUCT_OPS_API_BASE_URL="https://ops.example.test" \
  STACIO_FEEDBACK_PRODUCT_API_KEY="public-feedback-key" \
  STACIO_SPARKLE_PUBLIC_ED_KEY="$ED25519_TEST_PUBLIC_KEY" \
  STACIO_LICENSE_PUBLIC_ED25519_KEY="$ED25519_TEST_PUBLIC_KEY" \
  "$ROOT_DIR/scripts/package-app.sh" >"$TMP_DIR/stale-sparkle.log" 2>&1; then
  echo "expected packaging with a mismatched Sparkle framework to fail" >&2
  exit 1
fi
grep -Fq "Sparkle.framework version 0.0.0 does not match Package.resolved 2.9.4." "$TMP_DIR/stale-sparkle.log"

MISSING_SPARKLE_DIR="$TMP_DIR/sparkle-missing-downloader-binary"
cp -R "$SWIFT_BIN_DIR/Sparkle.framework" "$MISSING_SPARKLE_DIR"
rm -f "$MISSING_SPARKLE_DIR/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"
if env \
  PATH="$FAKE_BIN_DIR:$PATH" \
  STACIO_PACKAGE_TEST_LOG="$LOG_FILE" \
  STACIO_SKIP_BUILD=1 \
  STACIO_SWIFT_BIN_PATH="$SWIFT_BIN_DIR" \
  STACIO_SPARKLE_FRAMEWORK_PATH="$MISSING_SPARKLE_DIR" \
  STACIO_CORE_DYLIB_PATH="$CORE_DIR/libstacio_core.dylib" \
  STACIO_CORE_LOAD_PATH="/old/build/libstacio_core.dylib" \
  STACIO_MONACO_VS_PATH="$MONACO_VS_DIR" \
  STACIO_OUTPUT_DIR="$OUT_DIR" \
  STACIO_BUILD_NUMBER=11 \
  STACIO_PRODUCT_OPS_API_BASE_URL="https://ops.example.test" \
  STACIO_FEEDBACK_PRODUCT_API_KEY="public-feedback-key" \
  STACIO_SPARKLE_PUBLIC_ED_KEY="$ED25519_TEST_PUBLIC_KEY" \
  STACIO_LICENSE_PUBLIC_ED25519_KEY="$ED25519_TEST_PUBLIC_KEY" \
  "$ROOT_DIR/scripts/package-app.sh" >"$TMP_DIR/missing-sparkle-component.log" 2>&1; then
  echo "expected packaging with a missing Sparkle installation component to fail" >&2
  exit 1
fi
grep -Fq "Required Sparkle component missing" "$TMP_DIR/missing-sparkle-component.log"

PATH="$FAKE_BIN_DIR:$PATH" \
STACIO_PACKAGE_TEST_LOG="$LOG_FILE" \
STACIO_SKIP_BUILD=1 \
STACIO_SWIFT_BIN_PATH="$SWIFT_BIN_DIR" \
STACIO_CORE_DYLIB_PATH="$CORE_DIR/libstacio_core.dylib" \
STACIO_CORE_LOAD_PATH="/old/build/libstacio_core.dylib" \
STACIO_MONACO_VS_PATH="$MONACO_VS_DIR" \
STACIO_OUTPUT_DIR="$OUT_DIR" \
STACIO_VERSION="0.13.3" \
STACIO_BUILD_NUMBER="11" \
STACIO_PRODUCT_OPS_API_BASE_URL="https://ops.example.test" \
STACIO_PRODUCT_OPS_UPDATE_CHANNEL="beta" \
STACIO_PRODUCT_OPS_BETA_UPDATES_ENABLED="1" \
STACIO_FEEDBACK_PRODUCT_API_KEY="public-feedback-key" \
STACIO_SPARKLE_PUBLIC_ED_KEY="$ED25519_TEST_PUBLIC_KEY" \
STACIO_LICENSE_PUBLIC_ED25519_KEY="$ED25519_TEST_PUBLIC_KEY" \
"$ROOT_DIR/scripts/package-app.sh"

APP_DIR="$OUT_DIR/Stacio.app"
EXECUTABLE="$APP_DIR/Contents/MacOS/Stacio"
CLI_HELPER="$APP_DIR/Contents/Helpers/stacio"
LEGACY_HELPER_NAME="port""desk"
RDP_ADAPTER="$APP_DIR/Contents/Adapters/rdp"
RDP_VIEWER="$APP_DIR/Contents/Adapters/rdp-viewer"
RDP_VIEWER_APP="$APP_DIR/Contents/Adapters/StacioRDPViewer.app"
VNC_ADAPTER="$APP_DIR/Contents/Adapters/vnc"
DYLIB="$APP_DIR/Contents/Frameworks/libstacio_core.dylib"
SPARKLE_FRAMEWORK="$APP_DIR/Contents/Frameworks/Sparkle.framework"
SPARKLE_UPDATER="$SPARKLE_FRAMEWORK/Versions/B/Updater.app"
SPARKLE_DOWNLOADER="$SPARKLE_FRAMEWORK/Versions/B/XPCServices/Downloader.xpc"
SPARKLE_INSTALLER="$SPARKLE_FRAMEWORK/Versions/B/XPCServices/Installer.xpc"
SPARKLE_AUTOUPDATE="$SPARKLE_FRAMEWORK/Versions/B/Autoupdate"
SWIFTTERM_SHADER="$APP_DIR/Contents/Resources/SwiftTerm_SwiftTerm.bundle/Shaders.metal"
INVALID_ROOT_SWIFTTERM_SHADER="$APP_DIR/SwiftTerm_SwiftTerm.bundle/Shaders.metal"
ICON="$APP_DIR/Contents/Resources/Stacio.icns"
GITHUB_ICON="$APP_DIR/Contents/Resources/github.svg"
GITEE_ICON="$APP_DIR/Contents/Resources/gitee.svg"
SESSION_ICON_UBUNTU="$APP_DIR/Contents/Resources/SessionIcons/ubuntu.svg"
SESSION_ICON_LINUX="$APP_DIR/Contents/Resources/SessionIcons/linux-generic.svg"
SESSION_ICON_ALIYUN="$APP_DIR/Contents/Resources/SessionIcons/aliyun.svg"
SESSION_ICON_RAINCLOUD="$APP_DIR/Contents/Resources/SessionIcons/raincloud.png"
MONACO_LOADER="$APP_DIR/Contents/Resources/MonacoEditor/vs/loader.js"
ABOUT_QR="$APP_DIR/Contents/Resources/About/wechat-qrcode.jpg"
ABOUT_WECHAT_ICON="$APP_DIR/Contents/Resources/About/wechat-official-account.svg"
PLIST="$APP_DIR/Contents/Info.plist"
SOURCE_ICON="$ROOT_DIR/logo/icon.icns"
SOURCE_GITHUB_ICON="$ROOT_DIR/Stacio/Resources/github.svg"
SOURCE_GITEE_ICON="$ROOT_DIR/Stacio/Resources/gitee.svg"
SOURCE_ABOUT_QR="$ROOT_DIR/Stacio/Resources/About/wechat-qrcode.jpg"
SOURCE_ABOUT_WECHAT_ICON="$ROOT_DIR/Stacio/Resources/About/wechat-official-account.svg"

test -x "$EXECUTABLE"
test -x "$CLI_HELPER"
test ! -e "$APP_DIR/Contents/Helpers/$LEGACY_HELPER_NAME"
test ! -e "$RDP_ADAPTER"
test ! -e "$RDP_VIEWER"
test ! -e "$RDP_VIEWER_APP"
test -x "$VNC_ADAPTER"
grep -q 'fake Stacio' "$EXECUTABLE"
grep -q 'fake stacio CLI' "$CLI_HELPER"
grep -q 'fake VNC adapter' "$VNC_ADAPTER"
test -f "$DYLIB"
test -d "$SPARKLE_FRAMEWORK"
grep -q 'fake sparkle framework' "$SPARKLE_FRAMEWORK/Sparkle"
test -f "$SWIFTTERM_SHADER"
grep -q 'fake SwiftTerm shader' "$SWIFTTERM_SHADER"
test ! -e "$INVALID_ROOT_SWIFTTERM_SHADER"
test -s "$ICON"
test -s "$GITHUB_ICON"
cmp -s "$SOURCE_GITHUB_ICON" "$GITHUB_ICON"
test -s "$GITEE_ICON"
cmp -s "$SOURCE_GITEE_ICON" "$GITEE_ICON"
test -s "$SESSION_ICON_UBUNTU"
test -s "$SESSION_ICON_LINUX"
test -s "$SESSION_ICON_ALIYUN"
test -s "$SESSION_ICON_RAINCLOUD"
if /usr/bin/xattr -lr "$APP_DIR/Contents/Resources/SessionIcons" \
  | grep -Eq 'com\.apple\.(FinderInfo|ResourceFork)'; then
  echo "session icon resources contain signing-incompatible extended attributes" >&2
  exit 1
fi
test -f "$MONACO_LOADER"
grep -q 'fake monaco loader' "$MONACO_LOADER"
test -f "$ABOUT_QR"
cmp -s "$SOURCE_ABOUT_QR" "$ABOUT_QR"
test -s "$ABOUT_WECHAT_ICON"
cmp -s "$SOURCE_ABOUT_WECHAT_ICON" "$ABOUT_WECHAT_ICON"
test -f "$PLIST"
test -f "$SOURCE_ICON"
grep -q '<string>com.stacio.Stacio</string>' "$PLIST"
grep -q '<string>Stacio</string>' "$PLIST"
grep -q '<key>CFBundleDevelopmentRegion</key>' "$PLIST"
grep -q '<string>zh-Hans</string>' "$PLIST"
grep -q '<key>CFBundleLocalizations</key>' "$PLIST"
grep -q '<key>CFBundleAllowMixedLocalizations</key>' "$PLIST"
grep -q '<key>CFBundleIconFile</key>' "$PLIST"
grep -q '<string>Stacio.icns</string>' "$PLIST"
grep -q '<key>CFBundleIconName</key>' "$PLIST"
grep -q '<string>Stacio</string>' "$PLIST"
grep -q '<key>CFBundleURLTypes</key>' "$PLIST"
grep -q '<string>stacio</string>' "$PLIST"
if grep -q "<string>$LEGACY_HELPER_NAME</string>" "$PLIST"; then
  echo "package-app should not expose the legacy $LEGACY_HELPER_NAME URL scheme" >&2
  exit 1
fi
grep -q '<key>CFBundleShortVersionString</key>' "$PLIST"
grep -q '<string>0.13.3</string>' "$PLIST"
/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST" | grep -Fq "11"
/usr/libexec/PlistBuddy -c "Print :NSQuitAlwaysKeepsWindows" "$PLIST" | grep -Fq "false"
/usr/libexec/PlistBuddy -c "Print :StacioProductOpsProductID" "$PLIST" | grep -Fq "stacio"
/usr/libexec/PlistBuddy -c "Print :StacioProductOpsAPIBaseURL" "$PLIST" | grep -Fq "https://ops.example.test"
/usr/libexec/PlistBuddy -c "Print :StacioProductOpsUpdateChannel" "$PLIST" | grep -Fq "beta"
/usr/libexec/PlistBuddy -c "Print :StacioProductOpsBetaUpdatesEnabled" "$PLIST" | grep -Fq "true"
/usr/libexec/PlistBuddy -c "Print :StacioFeedbackProductAPIKey" "$PLIST" | grep -Fq "public-feedback-key"
/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$PLIST" | grep -Fq "$ED25519_TEST_PUBLIC_KEY"
/usr/libexec/PlistBuddy -c "Print :StacioLicensePublicEd25519Key" "$PLIST" | grep -Fq "$ED25519_TEST_PUBLIC_KEY"
/usr/libexec/PlistBuddy -c "Print :SUEnableAutomaticChecks" "$PLIST" | grep -Fq "false"
/usr/libexec/PlistBuddy -c "Print :SUAutomaticallyUpdate" "$PLIST" | grep -Fq "false"
/usr/libexec/PlistBuddy -c "Print :SUAllowsAutomaticUpdates" "$PLIST" | grep -Fq "false"
/usr/libexec/PlistBuddy -c "Print :SUScheduledCheckInterval" "$PLIST" | grep -Fq "0"

grep -Fq "install_name_tool -id @rpath/libstacio_core.dylib $DYLIB" "$LOG_FILE"
grep -Fq "install_name_tool -change /old/build/libstacio_core.dylib @executable_path/../Frameworks/libstacio_core.dylib $EXECUTABLE" "$LOG_FILE"
grep -Fq "install_name_tool -add_rpath @executable_path/../Frameworks $EXECUTABLE" "$LOG_FILE"
grep -Fq "codesign --force --sign - $DYLIB" "$LOG_FILE"
grep -Fq "codesign --force --preserve-metadata=identifier\\,entitlements\\,requirements --sign - $SPARKLE_DOWNLOADER" "$LOG_FILE"
grep -Fq "codesign --force --preserve-metadata=identifier\\,entitlements\\,requirements --sign - $SPARKLE_INSTALLER" "$LOG_FILE"
grep -Fq "codesign --force --preserve-metadata=identifier\\,entitlements\\,requirements --sign - $SPARKLE_UPDATER" "$LOG_FILE"
grep -Fq "codesign --force --preserve-metadata=identifier\\,entitlements\\,requirements --sign - $SPARKLE_AUTOUPDATE" "$LOG_FILE"
grep -Fq "codesign --force --preserve-metadata=identifier\\,entitlements\\,requirements --sign - $SPARKLE_FRAMEWORK" "$LOG_FILE"
grep -Fq "codesign --force --sign - $CLI_HELPER" "$LOG_FILE"
if grep -Fq "Contents/Adapters/rdp" "$LOG_FILE"; then
  echo "package-app should not sign removed RDP adapter assets" >&2
  exit 1
fi
grep -Fq "codesign --force --sign - $VNC_ADAPTER" "$LOG_FILE"
grep -Fq "codesign --force --sign - $APP_DIR" "$LOG_FILE"
if grep -Fq "codesign --force --deep --sign - $APP_DIR" "$LOG_FILE"; then
  echo "package-app should sign nested code explicitly instead of using codesign --deep" >&2
  exit 1
fi

cmp -s "$SOURCE_ICON" "$ICON"

: >"$LOG_FILE"
PATH="$FAKE_BIN_DIR:$PATH" \
STACIO_PACKAGE_TEST_LOG="$LOG_FILE" \
STACIO_SKIP_BUILD=1 \
STACIO_SWIFT_BIN_PATH="$SWIFT_BIN_DIR" \
STACIO_CORE_DYLIB_PATH="$CORE_DIR/libstacio_core.dylib" \
STACIO_CORE_LOAD_PATH="/old/build/libstacio_core.dylib" \
STACIO_MONACO_VS_PATH="$MONACO_VS_DIR" \
STACIO_OUTPUT_DIR="$OUT_DIR" \
GITHUB_RUN_NUMBER="4321" \
STACIO_PRODUCT_OPS_API_BASE_URL="https://ops.example.test" \
STACIO_FEEDBACK_PRODUCT_API_KEY="public-feedback-key" \
STACIO_SPARKLE_PUBLIC_ED_KEY="$ED25519_TEST_PUBLIC_KEY" \
STACIO_LICENSE_PUBLIC_ED25519_KEY="$ED25519_TEST_PUBLIC_KEY" \
"$ROOT_DIR/scripts/package-app.sh"
/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST" | grep -Fxq "4321"

: >"$LOG_FILE"
PATH="$FAKE_BIN_DIR:$PATH" \
STACIO_PACKAGE_TEST_LOG="$LOG_FILE" \
STACIO_SKIP_BUILD=1 \
STACIO_SWIFT_BIN_PATH="$SWIFT_BIN_DIR" \
STACIO_CORE_DYLIB_PATH="$CORE_DIR/libstacio_core.dylib" \
STACIO_CORE_LOAD_PATH="/old/build/libstacio_core.dylib" \
STACIO_MONACO_VS_PATH="$MONACO_VS_DIR" \
STACIO_OUTPUT_DIR="$OUT_DIR" \
STACIO_ALLOW_INCOMPLETE_PRODUCT_OPS_CONFIG=1 \
"$ROOT_DIR/scripts/package-app.sh"

test ! -e "$RDP_ADAPTER"
test ! -e "$RDP_VIEWER"
test ! -e "$RDP_VIEWER_APP"
test -x "$VNC_ADAPTER"

: >"$LOG_FILE"
PATH="$FAKE_BIN_DIR:$PATH" \
STACIO_PACKAGE_TEST_LOG="$LOG_FILE" \
STACIO_SKIP_BUILD=1 \
STACIO_SWIFT_BIN_PATH="$SWIFT_BIN_DIR" \
STACIO_CORE_DYLIB_PATH="$CORE_DIR/libstacio_core.dylib" \
STACIO_CORE_LOAD_PATH="/old/build/libstacio_core.dylib" \
STACIO_MONACO_VS_PATH="$MONACO_VS_DIR" \
STACIO_OUTPUT_DIR="$OUT_DIR" \
STACIO_CODESIGN_IDENTITY="Developer ID Application: Stacio Test" \
STACIO_PRODUCT_OPS_API_BASE_URL="https://ops.example.test" \
STACIO_FEEDBACK_PRODUCT_API_KEY="public-feedback-key" \
STACIO_SPARKLE_PUBLIC_ED_KEY="$ED25519_TEST_PUBLIC_KEY" \
STACIO_LICENSE_PUBLIC_ED25519_KEY="$ED25519_TEST_PUBLIC_KEY" \
"$ROOT_DIR/scripts/package-app.sh"

grep -Fq "codesign --force --options runtime --timestamp --sign Developer\\ ID\\ Application:\\ Stacio\\ Test $DYLIB" "$LOG_FILE"
grep -Fq "codesign --force --options runtime --timestamp --preserve-metadata=identifier\\,entitlements\\,requirements --sign Developer\\ ID\\ Application:\\ Stacio\\ Test $SPARKLE_DOWNLOADER" "$LOG_FILE"
grep -Fq "codesign --force --options runtime --timestamp --preserve-metadata=identifier\\,entitlements\\,requirements --sign Developer\\ ID\\ Application:\\ Stacio\\ Test $SPARKLE_INSTALLER" "$LOG_FILE"
grep -Fq "codesign --force --options runtime --timestamp --preserve-metadata=identifier\\,entitlements\\,requirements --sign Developer\\ ID\\ Application:\\ Stacio\\ Test $SPARKLE_UPDATER" "$LOG_FILE"
grep -Fq "codesign --force --options runtime --timestamp --preserve-metadata=identifier\\,entitlements\\,requirements --sign Developer\\ ID\\ Application:\\ Stacio\\ Test $SPARKLE_AUTOUPDATE" "$LOG_FILE"
grep -Fq "codesign --force --options runtime --timestamp --preserve-metadata=identifier\\,entitlements\\,requirements --sign Developer\\ ID\\ Application:\\ Stacio\\ Test $SPARKLE_FRAMEWORK" "$LOG_FILE"
grep -Fq "codesign --force --options runtime --timestamp --sign Developer\\ ID\\ Application:\\ Stacio\\ Test $CLI_HELPER" "$LOG_FILE"
grep -Fq "codesign --force --options runtime --timestamp --sign Developer\\ ID\\ Application:\\ Stacio\\ Test $VNC_ADAPTER" "$LOG_FILE"
grep -Fq "codesign --force --options runtime --timestamp --sign Developer\\ ID\\ Application:\\ Stacio\\ Test $APP_DIR" "$LOG_FILE"
if grep -Fq "codesign --force --deep --options runtime --timestamp --sign Developer\\ ID\\ Application:\\ Stacio\\ Test $APP_DIR" "$LOG_FILE"; then
  echo "Developer ID packaging should not use codesign --deep" >&2
  exit 1
fi

echo "package_app_test passed"
