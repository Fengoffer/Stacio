#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAKE_BIN_DIR="$TMP_DIR/bin"
APP_DIR="$TMP_DIR/Stacio.app"
DMG_PATH="$TMP_DIR/Stacio.dmg"
LOG_FILE="$TMP_DIR/tool-calls.log"
MOUNT_DIR="$TMP_DIR/mounted"
SOURCE_ROOT="$TMP_DIR/source"
APPCAST_FIXTURE_DIR="$TMP_DIR/appcasts"
ED25519_TEST_PUBLIC_KEY="PUAXw+hDiVqStwqnTRt+vJyYLM8uxJaMwM1V8Sr0Zgw="
ED25519_TEST_SIGNATURE="kqAJqfDUyrhyDoILX2QlQKKye1QWUD+Ps3YiI+vbadoIWsHkPhWZbkWPNhPQ8R2MOHsurrQwKu6wDSkWErsMAA=="
REAL_SWIFT="$(command -v swift)"

mkdir -p \
  "$FAKE_BIN_DIR" \
  "$APP_DIR/Contents/MacOS" \
  "$APP_DIR/Contents/Frameworks" \
  "$APP_DIR/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS" \
  "$APP_DIR/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS" \
  "$APP_DIR/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS" \
  "$APP_DIR/Contents/Adapters" \
  "$APP_DIR/Contents/Helpers" \
  "$APP_DIR/Contents/Resources/About" \
  "$APP_DIR/Contents/Resources/MonacoEditor/vs" \
  "$APP_DIR/Contents/Resources/SwiftTerm_SwiftTerm.bundle" \
  "$APP_DIR/Contents/_CodeSignature" \
  "$APPCAST_FIXTURE_DIR" \
  "$SOURCE_ROOT"

printf 'source\n' >"$SOURCE_ROOT/App.swift"
touch -t 202001010000 "$SOURCE_ROOT/App.swift"
export STACIO_RELEASE_SOURCE_ROOT="$SOURCE_ROOT"

printf '%s\n' \
  'cn.stacio.product-ops.license' \
  'stacio.product-ops.license.' \
  'credentials.vault.json' \
  'credentials.vault.key' \
  'stacio-license-vault-v1' \
  >"$APP_DIR/Contents/MacOS/Stacio"
chmod +x "$APP_DIR/Contents/MacOS/Stacio"
printf 'fake dylib\n' >"$APP_DIR/Contents/Frameworks/libstacio_core.dylib"
printf 'fake sparkle framework\n' >"$APP_DIR/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle"
ln -s "B" "$APP_DIR/Contents/Frameworks/Sparkle.framework/Versions/Current"
ln -s "Versions/Current/Sparkle" "$APP_DIR/Contents/Frameworks/Sparkle.framework/Sparkle"
printf '#!/usr/bin/env bash\nexit 0\n' >"$APP_DIR/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"
printf '#!/usr/bin/env bash\nexit 0\n' >"$APP_DIR/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater"
printf '#!/usr/bin/env bash\nexit 0\n' >"$APP_DIR/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"
printf '#!/usr/bin/env bash\nexit 0\n' >"$APP_DIR/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer"
printf 'loader\n' >"$APP_DIR/Contents/Resources/MonacoEditor/vs/loader.js"
printf 'shader\n' >"$APP_DIR/Contents/Resources/SwiftTerm_SwiftTerm.bundle/Shaders.metal"
printf '<svg xmlns="http://www.w3.org/2000/svg"/>\n' >"$APP_DIR/Contents/Resources/About/wechat-official-account.svg"
touch "$APP_DIR/Contents/Helpers/stacio" "$APP_DIR/Contents/Adapters/vnc"
chmod +x \
  "$APP_DIR/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle" \
  "$APP_DIR/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate" \
  "$APP_DIR/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater" \
  "$APP_DIR/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader" \
  "$APP_DIR/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer" \
  "$APP_DIR/Contents/Helpers/stacio" \
  "$APP_DIR/Contents/Adapters/vnc"
cat >"$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
  <key>CFBundleLocalizations</key>
  <array>
    <string>zh-Hans</string>
    <string>en</string>
  </array>
  <key>CFBundleAllowMixedLocalizations</key><true/>
  <key>CFBundleExecutable</key><string>Stacio</string>
  <key>CFBundleIdentifier</key><string>com.stacio.Stacio</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.13.3</string>
  <key>CFBundleVersion</key><string>11</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSQuitAlwaysKeepsWindows</key><false/>
  <key>StacioProductOpsProductID</key><string>stacio</string>
  <key>StacioProductOpsAPIBaseURL</key><string>https://ops.stacio.cn</string>
  <key>StacioProductOpsUpdateChannel</key><string>stable</string>
  <key>StacioProductOpsBetaUpdatesEnabled</key><false/>
  <key>StacioFeedbackProductAPIKey</key><string>feedback-public-key</string>
  <key>StacioSparkleArchitecture</key><string>arm64</string>
  <key>SUFeedURL</key><string>https://ops.stacio.cn/updates/stacio/stable/arm64/appcast.xml</string>
  <key>StacioSparkleBetaAppcastURL</key><string>https://ops.stacio.cn/updates/stacio/beta/arm64/appcast.xml</string>
  <key>SUPublicEDKey</key><string>PUAXw+hDiVqStwqnTRt+vJyYLM8uxJaMwM1V8Sr0Zgw=</string>
  <key>StacioLicensePublicEd25519Key</key><string>PUAXw+hDiVqStwqnTRt+vJyYLM8uxJaMwM1V8Sr0Zgw=</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUAutomaticallyUpdate</key><false/>
  <key>SUAllowsAutomaticUpdates</key><false/>
  <key>SUScheduledCheckInterval</key><integer>86400</integer>
</dict>
</plist>
PLIST
python3 - "$APP_DIR/Contents/Info.plist" "$ROOT_DIR/config/license-trust-anchors.json" <<'PY'
import json
import plistlib
import sys

plist_path, trust_path = sys.argv[1:]
with open(plist_path, "rb") as stream:
    plist = plistlib.load(stream)
with open(trust_path, "r", encoding="utf-8") as stream:
    trust = json.load(stream)

online = trust["onlineAuthorization"]
offline = trust["offlineLicense"]
request = offline["request"]
authorization = offline["authorization"]
storage = trust["storage"]
plist.update({
    "StacioLicensePublicEd25519Key": online["publicKeyBase64"],
    "StacioOnlineLicenseSignatureKeyID": online["signatureKeyID"],
    "StacioOfflineLicenseExchangeURL": offline["exchangeURL"],
    "StacioOfflineExchangePublicKey": request["publicKeyBase64"],
    "StacioOfflineRequestKeyID": request["keyID"],
    "StacioOfflineSignatureKeyID": authorization["signatureKeyID"],
    "StacioOfflineLicensePublicKey": authorization["publicKeyBase64"],
    "StacioLicenseStorageContractID": storage["contractID"],
    "StacioLicenseStorageSchemaVersion": int(storage["schemaVersion"]),
})
with open(plist_path, "wb") as stream:
    plistlib.dump(plist, stream, fmt=plistlib.FMT_XML, sort_keys=False)
PY
printf '\x72' >"$DMG_PATH"

write_stable_appcast() {
  local output_path="$1"
  local version="$2"
  local build="$3"
  local enclosure_url="$4"
  local length="$5"
  local signature="$6"
  cat >"$output_path" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Stacio Stable Updates</title>
    <item>
      <title>Stacio $version</title>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:version>$build</sparkle:version>
      <enclosure url="$enclosure_url" length="$length" type="application/octet-stream" sparkle:edSignature="$signature" />
    </item>
  </channel>
</rss>
EOF
}

write_stable_appcast \
  "$APPCAST_FIXTURE_DIR/stable-valid.xml" \
  "0.13.3" \
  "11" \
  "Stacio-0.13.3.dmg" \
  "1" \
  "$ED25519_TEST_SIGNATURE"
write_stable_appcast \
  "$APPCAST_FIXTURE_DIR/stable-missing-version.xml" \
  "" \
  "11" \
  "Stacio-0.13.3.dmg" \
  "1" \
  "$ED25519_TEST_SIGNATURE"
write_stable_appcast \
  "$APPCAST_FIXTURE_DIR/stable-missing-build.xml" \
  "0.13.3" \
  "" \
  "Stacio-0.13.3.dmg" \
  "1" \
  "$ED25519_TEST_SIGNATURE"
write_stable_appcast \
  "$APPCAST_FIXTURE_DIR/stable-missing-url.xml" \
  "0.13.3" \
  "11" \
  "" \
  "1" \
  "$ED25519_TEST_SIGNATURE"
write_stable_appcast \
  "$APPCAST_FIXTURE_DIR/stable-missing-length.xml" \
  "0.13.3" \
  "11" \
  "Stacio-0.13.3.dmg" \
  "" \
  "$ED25519_TEST_SIGNATURE"
write_stable_appcast \
  "$APPCAST_FIXTURE_DIR/stable-missing-signature.xml" \
  "0.13.3" \
  "11" \
  "Stacio-0.13.3.dmg" \
  "1" \
  ""
write_stable_appcast \
  "$APPCAST_FIXTURE_DIR/stable-length-mismatch.xml" \
  "0.13.3" \
  "11" \
  "Stacio-0.13.3.dmg" \
  "2" \
  "$ED25519_TEST_SIGNATURE"
write_stable_appcast \
  "$APPCAST_FIXTURE_DIR/stable-wrong-target.xml" \
  "0.13.2-Beta" \
  "10" \
  "Stacio-0.13.2-Beta.dmg" \
  "1" \
  "$ED25519_TEST_SIGNATURE"
write_stable_appcast \
  "$APPCAST_FIXTURE_DIR/stable-invalid-signature.xml" \
  "0.13.3" \
  "11" \
  "Stacio-0.13.3.dmg" \
  "1" \
  "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=="
cat >"$APPCAST_FIXTURE_DIR/stable-with-history.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Stacio Stable Updates</title>
    <item>
      <title>Stacio 0.13.3</title>
      <sparkle:shortVersionString>0.13.3</sparkle:shortVersionString>
      <sparkle:version>11</sparkle:version>
      <enclosure url="Stacio-0.13.3.dmg" length="1" type="application/octet-stream" sparkle:edSignature="$ED25519_TEST_SIGNATURE" />
    </item>
    <item>
      <title>Stacio 0.1.0</title>
      <sparkle:shortVersionString>0.1.0</sparkle:shortVersionString>
      <sparkle:version>1</sparkle:version>
      <enclosure url="removed-history.dmg" length="999" type="application/octet-stream" />
    </item>
  </channel>
</rss>
EOF
cat >"$APPCAST_FIXTURE_DIR/stable-wrong-namespace.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:wrong="https://wrong.example/ns">
  <channel>
    <item>
      <wrong:shortVersionString>0.13.3</wrong:shortVersionString>
      <wrong:version>11</wrong:version>
      <enclosure url="Stacio-0.13.3.dmg" length="1" wrong:edSignature="$ED25519_TEST_SIGNATURE" />
    </item>
  </channel>
</rss>
EOF
cat >"$APPCAST_FIXTURE_DIR/stable-empty.xml" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel><title>Stacio Stable Updates</title></channel>
</rss>
EOF
cat >"$APPCAST_FIXTURE_DIR/beta-empty.xml" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel><title>Stacio Beta Updates</title></channel>
</rss>
EOF
printf '<rss><channel><item>\n' >"$APPCAST_FIXTURE_DIR/stable-malformed.xml"
export STACIO_RELEASE_TEST_APPCAST_FIXTURE_DIR="$APPCAST_FIXTURE_DIR"

write_tool() {
  local name="$1"
  cat >"$FAKE_BIN_DIR/$name"
  chmod +x "$FAKE_BIN_DIR/$name"
}

write_tool plutil <<'EOF'
#!/usr/bin/env bash
printf 'plutil %s\n' "$*" >>"$STACIO_RELEASE_TEST_LOG"
exit 0
EOF

write_tool codesign <<'EOF'
#!/usr/bin/env bash
printf 'codesign %s\n' "$*" >>"$STACIO_RELEASE_TEST_LOG"
if [[ "$*" == *"-dvvv"* ]]; then
  case "${STACIO_RELEASE_TEST_SIGNATURE_MODE:-adhoc}" in
    developer-runtime)
      printf 'Executable=/tmp/Stacio\nAuthority=Developer ID Application: Stacio Test\nflags=0x10000(runtime)\n'
      ;;
    developer-no-runtime)
      printf 'Executable=/tmp/Stacio\nAuthority=Developer ID Application: Stacio Test\nflags=0x0(none)\n'
      ;;
    *)
      printf 'Executable=/tmp/Stacio\nSignature=adhoc\nflags=0x2(adhoc)\n'
      ;;
  esac
fi
exit 0
EOF

write_tool spctl <<'EOF'
#!/usr/bin/env bash
printf 'spctl %s\n' "$*" >>"$STACIO_RELEASE_TEST_LOG"
if [[ "${1:-}" == "--status" ]]; then
  if [[ "${STACIO_RELEASE_TEST_GATEKEEPER_DISABLED:-0}" == "1" ]]; then
    printf 'assessments disabled\n'
  else
    printf 'assessments enabled\n'
  fi
  exit 0
fi
if [[ "${STACIO_RELEASE_TEST_GATEKEEPER_DISABLED:-0}" == "1" ]]; then
  printf '%s: accepted\noverride=security disabled\n' "${@: -1}"
  exit 0
fi
if [[ "${STACIO_RELEASE_TEST_SIGNATURE_MODE:-adhoc}" == developer-* ]]; then
  exit 0
fi
printf 'rejected (the code is valid but unsigned)\n' >&2
exit 1
EOF

write_tool xcrun <<'EOF'
#!/usr/bin/env bash
printf 'xcrun %s\n' "$*" >>"$STACIO_RELEASE_TEST_LOG"
if [[ "$*" == "stapler validate"* && "${STACIO_RELEASE_TEST_STAPLER_FAIL:-0}" == "1" ]]; then
  printf 'The validate action failed.\n' >&2
  exit 1
fi
exit 0
EOF

write_tool security <<'EOF'
#!/usr/bin/env bash
printf 'security %s\n' "$*" >>"$STACIO_RELEASE_TEST_LOG"
if [[ "${STACIO_RELEASE_TEST_SIGNATURE_MODE:-adhoc}" == developer-* ]]; then
  printf '  1) ABCDEF1234567890 "Developer ID Application: Stacio Test"\n'
fi
exit 0
EOF

write_tool otool <<'EOF'
#!/usr/bin/env bash
printf 'otool %s\n' "$*" >>"$STACIO_RELEASE_TEST_LOG"
case "${1:-}" in
  -L)
    printf '%s:\n\t@executable_path/../Frameworks/libstacio_core.dylib\n\t@rpath/Sparkle.framework/Versions/B/Sparkle\n' "${@: -1}"
    ;;
  -l)
    printf 'cmd LC_RPATH\n'
    printf 'path @executable_path/../Frameworks (offset 12)\n'
    ;;
  -D)
    printf '%s:\n\t@rpath/libstacio_core.dylib\n' "${@: -1}"
    ;;
esac
exit 0
EOF

write_tool hdiutil <<'EOF'
#!/usr/bin/env bash
printf 'hdiutil %s\n' "$*" >>"$STACIO_RELEASE_TEST_LOG"
if [[ "${1:-}" == "verify" ]]; then
  test -f "${2:-}"
  exit 0
fi
if [[ "${1:-}" == "attach" ]]; then
  mountpoint=""
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "-mountpoint" ]]; then
      mountpoint="$2"
      break
    fi
    shift
  done
  source_app="${STACIO_RELEASE_TEST_DMG_APP_PATH:-$STACIO_RELEASE_APP_PATH}"
  cp -R "$source_app" "$mountpoint/Stacio.app"
  exit 0
fi
if [[ "${1:-}" == "detach" ]]; then
  rm -rf "${2:-}"
  exit 0
fi
exit 0
EOF

write_tool curl <<'EOF'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >>"$STACIO_RELEASE_TEST_LOG"
if [[ " $* " != *" --proto =https "* || " $* " != *" --proto-redir =https "* ]]; then
  printf 'curl must restrict initial and redirected requests to HTTPS\n' >&2
  exit 2
fi

output_path=""
url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output|-o)
      output_path="${2:-}"
      shift 2
      ;;
    --range)
      shift 2
      ;;
    --*)
      shift
      ;;
    *)
      url="$1"
      shift
      ;;
  esac
done

mode="${STACIO_RELEASE_TEST_APPCAST_MODE:-valid}"
stable_url="https://ops.stacio.cn/updates/stacio/stable/arm64/appcast.xml"
beta_url="https://ops.stacio.cn/updates/stacio/beta/arm64/appcast.xml"
enclosure_url="https://ops.stacio.cn/updates/stacio/stable/arm64/Stacio-0.13.3.dmg"
history_url="https://ops.stacio.cn/updates/stacio/stable/arm64/removed-history.dmg"

if [[ "$url" == "$stable_url" ]]; then
  case "$mode" in
    stable-http-404)
      printf 'curl: (22) The requested URL returned error: 404\n' >&2
      exit 22
      ;;
    stable-network-error)
      printf 'curl: (6) Could not resolve host: ops.stacio.cn\n' >&2
      exit 6
      ;;
    stable-empty|stable-malformed|stable-missing-version|stable-missing-build|stable-missing-url|stable-missing-length|stable-missing-signature|stable-length-mismatch|stable-wrong-target|stable-wrong-namespace)
      cp "$STACIO_RELEASE_TEST_APPCAST_FIXTURE_DIR/$mode.xml" "$output_path"
      ;;
    signature-invalid)
      cp "$STACIO_RELEASE_TEST_APPCAST_FIXTURE_DIR/stable-invalid-signature.xml" "$output_path"
      ;;
    *)
      cp "$STACIO_RELEASE_TEST_APPCAST_FIXTURE_DIR/stable-with-history.xml" "$output_path"
      ;;
  esac
  exit 0
fi

if [[ "$url" == "$beta_url" ]]; then
  cp "$STACIO_RELEASE_TEST_APPCAST_FIXTURE_DIR/beta-empty.xml" "$output_path"
  exit 0
fi

if [[ "$url" == "$enclosure_url" ]]; then
  if [[ "$mode" == "enclosure-http-404" ]]; then
    printf 'curl: (22) The requested URL returned error: 404\n' >&2
    exit 22
  fi
  if [[ "$mode" == "remote-package-mismatch" ]]; then
    printf '\x73' >"$output_path"
  else
    printf '\x72' >"$output_path"
  fi
  exit 0
fi

if [[ "$url" == "$history_url" ]]; then
  printf 'historical enclosure must not be downloaded\n' >&2
  exit 22
fi

printf 'curl: (22) The requested URL returned error: 404\n' >&2
exit 22
EOF

export STACIO_RELEASE_TEST_REAL_SWIFT="$REAL_SWIFT"
write_tool swift <<'EOF'
#!/usr/bin/env bash
printf 'swift %s\n' "$*" >>"$STACIO_RELEASE_TEST_LOG"
exec "$STACIO_RELEASE_TEST_REAL_SWIFT" "$@"
EOF
export STACIO_RELEASE_TEST_SIGNATURE_MODE=developer-runtime
export STACIO_NOTARY_PROFILE="test-profile"

PATH="$FAKE_BIN_DIR:$PATH" \
STACIO_RELEASE_TEST_LOG="$LOG_FILE" \
STACIO_RELEASE_TEST_SIGNATURE_MODE=developer-runtime \
STACIO_NOTARY_PROFILE="test-profile" \
STACIO_RELEASE_APP_PATH="$APP_DIR" \
STACIO_RELEASE_DMG_PATH="$DMG_PATH" \
STACIO_RELEASE_SKIP_PACKAGE=1 \
"$ROOT_DIR/scripts/release-readiness.sh" >"$TMP_DIR/readiness.out"

grep -Fq "PASS app bundle exists" "$TMP_DIR/readiness.out"
grep -Fq "PASS Developer ID Application signature present" "$TMP_DIR/readiness.out"
grep -Fq "PASS notarization tickets validate for App and DMG" "$TMP_DIR/readiness.out"
grep -Fq "PASS DMG root contains Stacio.app" "$TMP_DIR/readiness.out"
grep -Fq "PASS stable Appcast contains 2 update item(s)" "$TMP_DIR/readiness.out"
grep -Fq "PASS stable Appcast item 1 has version 0.13.3 and build 11" "$TMP_DIR/readiness.out"
grep -Fq "PASS stable Appcast item 1 has a positive enclosure length" "$TMP_DIR/readiness.out"
grep -Fq "PASS stable Appcast item 1 has a Sparkle Ed25519 signature" "$TMP_DIR/readiness.out"
grep -Fq "PASS stable Appcast item 1 enclosure is accessible" "$TMP_DIR/readiness.out"
grep -Fq "PASS stable Appcast item 1 Sparkle Ed25519 signature verifies" "$TMP_DIR/readiness.out"
grep -Fq "PASS stable Appcast item 1 enclosure length matches downloaded bytes" "$TMP_DIR/readiness.out"
grep -Fq "PASS stable Appcast item 1 enclosure matches local release DMG" "$TMP_DIR/readiness.out"
grep -Fq "SKIP beta Appcast contains no update items; beta updates are disabled" "$TMP_DIR/readiness.out"
grep -Fq "Summary: 0 failure(s)" "$TMP_DIR/readiness.out"
grep -Fq "hdiutil verify $DMG_PATH" "$LOG_FILE"
grep -Fq "hdiutil attach $DMG_PATH" "$LOG_FILE"
grep -Fq "swift " "$LOG_FILE"
if grep -Fq "removed-history.dmg" "$LOG_FILE"; then
  echo "release readiness must not download historical Appcast items" >&2
  exit 1
fi

grep -Fq 'STACIO_RELEASE_LOCAL_SMOKE: "1"' "$ROOT_DIR/.github/workflows/stacio-ci.yml"
grep -Fq 'STACIO_ALLOW_INCOMPLETE_PRODUCT_OPS_CONFIG: "1"' "$ROOT_DIR/.github/workflows/stacio-ci.yml"
grep -Fq 'STACIO_BUILD_NUMBER: "${{ github.run_number }}"' "$ROOT_DIR/.github/workflows/stacio-ci.yml"

expect_missing_product_ops_field_failure() {
  local key="$1"
  local missing_app="$TMP_DIR/missing-$key.app"
  local output="$TMP_DIR/missing-$key.out"
  cp -R "$APP_DIR" "$missing_app"
  /usr/libexec/PlistBuddy -c "Delete :$key" "$missing_app/Contents/Info.plist"
  if PATH="$FAKE_BIN_DIR:$PATH" \
    STACIO_RELEASE_TEST_LOG="$LOG_FILE" \
    STACIO_RELEASE_APP_PATH="$missing_app" \
    STACIO_RELEASE_DMG_PATH="$DMG_PATH" \
    STACIO_RELEASE_SKIP_PACKAGE=1 \
    "$ROOT_DIR/scripts/release-readiness.sh" >"$output" 2>&1; then
    echo "expected release readiness without $key to fail" >&2
    exit 1
  fi
  if ! grep -Fq "FAIL required Product Ops configuration missing: $key" "$output"; then
    cat "$output" >&2
    exit 1
  fi
}

expect_missing_product_ops_field_failure "StacioProductOpsProductID"
expect_missing_product_ops_field_failure "StacioProductOpsAPIBaseURL"
expect_missing_product_ops_field_failure "StacioProductOpsUpdateChannel"
expect_missing_product_ops_field_failure "StacioFeedbackProductAPIKey"
expect_missing_product_ops_field_failure "StacioSparkleArchitecture"
expect_missing_product_ops_field_failure "SUFeedURL"
expect_missing_product_ops_field_failure "StacioSparkleBetaAppcastURL"
expect_missing_product_ops_field_failure "SUPublicEDKey"
expect_missing_product_ops_field_failure "StacioLicensePublicEd25519Key"
expect_missing_product_ops_field_failure "StacioOnlineLicenseSignatureKeyID"
expect_missing_product_ops_field_failure "StacioOfflineLicenseExchangeURL"
expect_missing_product_ops_field_failure "StacioOfflineExchangePublicKey"
expect_missing_product_ops_field_failure "StacioOfflineRequestKeyID"
expect_missing_product_ops_field_failure "StacioOfflineSignatureKeyID"
expect_missing_product_ops_field_failure "StacioOfflineLicensePublicKey"
expect_missing_product_ops_field_failure "StacioLicenseStorageContractID"
expect_missing_product_ops_field_failure "StacioLicenseStorageSchemaVersion"
expect_missing_product_ops_field_failure "SUEnableAutomaticChecks"
expect_missing_product_ops_field_failure "SUAutomaticallyUpdate"
expect_missing_product_ops_field_failure "SUAllowsAutomaticUpdates"
expect_missing_product_ops_field_failure "SUScheduledCheckInterval"

expect_product_ops_value_failure() {
  local key="$1"
  local value="$2"
  local expected_message="$3"
  local invalid_app="$TMP_DIR/invalid-$key.app"
  local output="$TMP_DIR/invalid-$key.out"
  cp -R "$APP_DIR" "$invalid_app"
  /usr/libexec/PlistBuddy -c "Set :$key $value" "$invalid_app/Contents/Info.plist"
  if PATH="$FAKE_BIN_DIR:$PATH" \
    STACIO_RELEASE_TEST_LOG="$LOG_FILE" \
    STACIO_RELEASE_APP_PATH="$invalid_app" \
    STACIO_RELEASE_DMG_PATH="$DMG_PATH" \
    STACIO_RELEASE_SKIP_PACKAGE=1 \
    "$ROOT_DIR/scripts/release-readiness.sh" >"$output" 2>&1; then
    echo "expected release readiness with invalid $key to fail" >&2
    exit 1
  fi
  if ! grep -Fq "$expected_message" "$output"; then
    cat "$output" >&2
    exit 1
  fi
}

expect_product_ops_value_failure "SUEnableAutomaticChecks" "false" "SUEnableAutomaticChecks must be true"
expect_product_ops_value_failure "SUAutomaticallyUpdate" "true" "SUAutomaticallyUpdate must be false"
expect_product_ops_value_failure "SUAllowsAutomaticUpdates" "true" "SUAllowsAutomaticUpdates must be false"
expect_product_ops_value_failure "SUScheduledCheckInterval" "3600" "SUScheduledCheckInterval must be 86400"
expect_product_ops_value_failure "StacioSparkleArchitecture" "unsupported" "StacioSparkleArchitecture must be arm64 or x86_64"
expect_product_ops_value_failure "SUPublicEDKey" "not-base64" "SUPublicEDKey must contain a valid Ed25519 public key"
expect_product_ops_value_failure "StacioLicensePublicEd25519Key" "not-base64" "StacioLicensePublicEd25519Key must contain a valid Ed25519 public key"
expect_product_ops_value_failure "StacioOfflineLicensePublicKey" "not-base64" "StacioOfflineLicensePublicKey must contain a valid Ed25519 public key"
expect_product_ops_value_failure "StacioOfflineExchangePublicKey" "not-base64" "StacioOfflineExchangePublicKey must contain a valid X25519 public key"

INCOMPLETE_APP_DIR="$TMP_DIR/incomplete-local-smoke.app"
cp -R "$APP_DIR" "$INCOMPLETE_APP_DIR"
/usr/libexec/PlistBuddy -c "Delete :StacioFeedbackProductAPIKey" "$INCOMPLETE_APP_DIR/Contents/Info.plist"
LOCAL_SMOKE_LOG="$TMP_DIR/local-smoke-tools.log"
PATH="$FAKE_BIN_DIR:$PATH" \
STACIO_RELEASE_TEST_LOG="$LOCAL_SMOKE_LOG" \
STACIO_RELEASE_APP_PATH="$INCOMPLETE_APP_DIR" \
STACIO_RELEASE_DMG_PATH="$DMG_PATH" \
STACIO_RELEASE_SKIP_PACKAGE=1 \
STACIO_RELEASE_LOCAL_SMOKE=1 \
"$ROOT_DIR/scripts/release-readiness.sh" >"$TMP_DIR/local-smoke.out"
grep -Fq "SKIP Product Ops configuration completeness by explicit local-smoke mode" "$TMP_DIR/local-smoke.out"
grep -Fq "SKIP remote Appcast verification by explicit local-smoke mode" "$TMP_DIR/local-smoke.out"
grep -Fq "Summary: 0 failure(s)" "$TMP_DIR/local-smoke.out"
if grep -Fq "curl " "$LOCAL_SMOKE_LOG"; then
  echo "local-smoke mode must not contact remote Appcasts" >&2
  exit 1
fi
if grep -Fq "swift " "$LOCAL_SMOKE_LOG"; then
  echo "local-smoke mode must not invoke Appcast signature verification" >&2
  exit 1
fi

expect_remote_appcast_failure() {
  local mode="$1"
  local expected_message="$2"
  local output="$TMP_DIR/$mode.out"
  if PATH="$FAKE_BIN_DIR:$PATH" \
    STACIO_RELEASE_TEST_LOG="$LOG_FILE" \
    STACIO_RELEASE_TEST_APPCAST_MODE="$mode" \
    STACIO_RELEASE_APP_PATH="$APP_DIR" \
    STACIO_RELEASE_DMG_PATH="$DMG_PATH" \
    STACIO_RELEASE_SKIP_PACKAGE=1 \
    "$ROOT_DIR/scripts/release-readiness.sh" >"$output" 2>&1; then
    echo "expected release readiness with Appcast mode $mode to fail" >&2
    exit 1
  fi
  if ! grep -Fq "$expected_message" "$output"; then
    cat "$output" >&2
    exit 1
  fi
}

expect_remote_appcast_failure "stable-http-404" "FAIL stable Appcast fetch failed"
expect_remote_appcast_failure "stable-network-error" "FAIL stable Appcast fetch failed"
expect_remote_appcast_failure "stable-malformed" "FAIL stable Appcast XML is malformed"
expect_remote_appcast_failure "stable-empty" "FAIL stable Appcast contains no update items"
expect_remote_appcast_failure "stable-missing-version" "FAIL stable Appcast item 1 version must not be empty"
expect_remote_appcast_failure "stable-missing-build" "FAIL stable Appcast item 1 build must not be empty"
expect_remote_appcast_failure "stable-missing-url" "FAIL stable Appcast item 1 enclosure URL must be a valid HTTPS URL"
expect_remote_appcast_failure "stable-missing-length" "FAIL stable Appcast item 1 enclosure length must be a positive integer"
expect_remote_appcast_failure "stable-missing-signature" "FAIL stable Appcast item 1 Sparkle Ed25519 signature is missing"
expect_remote_appcast_failure "enclosure-http-404" "FAIL stable Appcast item 1 enclosure is not accessible"
expect_remote_appcast_failure "signature-invalid" "FAIL stable Appcast item 1 Sparkle Ed25519 signature verification failed"
expect_remote_appcast_failure "stable-length-mismatch" "FAIL stable Appcast item 1 enclosure length does not match downloaded bytes"
expect_remote_appcast_failure "stable-wrong-target" "FAIL stable Appcast does not contain current release 0.13.3 (build 11)"
expect_remote_appcast_failure "stable-wrong-namespace" "FAIL stable Appcast uses an invalid Sparkle XML namespace"
expect_remote_appcast_failure "remote-package-mismatch" "FAIL stable Appcast item 1 enclosure does not match local release DMG"

if PATH="$FAKE_BIN_DIR:$PATH" \
  STACIO_RELEASE_TEST_LOG="$LOG_FILE" \
  STACIO_RELEASE_TEST_SIGNATURE_MODE=adhoc \
  STACIO_NOTARY_PROFILE= \
  STACIO_RELEASE_REQUIRE_DEVELOPER_ID=0 \
  STACIO_RELEASE_REQUIRE_NOTARY=0 \
  STACIO_RELEASE_APP_PATH="$APP_DIR" \
  STACIO_RELEASE_DMG_PATH="$DMG_PATH" \
  STACIO_RELEASE_SKIP_PACKAGE=1 \
  "$ROOT_DIR/scripts/release-readiness.sh" >"$TMP_DIR/formal-bypass.out" 2>&1; then
  echo "formal release readiness must not allow Developer ID or notarization opt-out" >&2
  exit 1
fi
grep -Fq "FAIL app is ad-hoc signed" "$TMP_DIR/formal-bypass.out"
grep -Fq "FAIL notary credentials missing" "$TMP_DIR/formal-bypass.out"

PATH="$FAKE_BIN_DIR:$PATH" \
  STACIO_RELEASE_TEST_LOG="$LOG_FILE" \
  STACIO_RELEASE_TEST_SIGNATURE_MODE=adhoc \
  STACIO_NOTARY_PROFILE= \
  STACIO_RELEASE_DISTRIBUTION_MODE=adhoc \
  STACIO_RELEASE_APP_PATH="$APP_DIR" \
  STACIO_RELEASE_DMG_PATH="$DMG_PATH" \
  STACIO_RELEASE_SKIP_PACKAGE=1 \
  "$ROOT_DIR/scripts/release-readiness.sh" >"$TMP_DIR/formal-adhoc.out"
grep -Fq "Distribution mode: adhoc" "$TMP_DIR/formal-adhoc.out"
grep -Fq "WARN ad-hoc distribution will require users to bypass normal macOS Gatekeeper trust prompts" "$TMP_DIR/formal-adhoc.out"
grep -Fq "SKIP Developer ID Application signature not present; current app is ad-hoc signed" "$TMP_DIR/formal-adhoc.out"
grep -Fq "SKIP notarization and staple validation are not available in ad-hoc distribution mode" "$TMP_DIR/formal-adhoc.out"
grep -Fq "PASS formal release update channel is stable" "$TMP_DIR/formal-adhoc.out"
grep -Fq "PASS stable Appcast item 1 has version 0.13.3 and build 11" "$TMP_DIR/formal-adhoc.out"
grep -Fq "Summary: 0 failure(s)" "$TMP_DIR/formal-adhoc.out"

BETA_REQUIRED_APP_DIR="$TMP_DIR/beta-required.app"
cp -R "$APP_DIR" "$BETA_REQUIRED_APP_DIR"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 0.13.3-Beta" "$BETA_REQUIRED_APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :StacioProductOpsUpdateChannel beta" "$BETA_REQUIRED_APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :StacioProductOpsBetaUpdatesEnabled true" "$BETA_REQUIRED_APP_DIR/Contents/Info.plist"
if PATH="$FAKE_BIN_DIR:$PATH" \
  STACIO_RELEASE_TEST_LOG="$LOG_FILE" \
  STACIO_RELEASE_APP_PATH="$BETA_REQUIRED_APP_DIR" \
  STACIO_RELEASE_DMG_PATH="$DMG_PATH" \
  STACIO_RELEASE_SKIP_PACKAGE=1 \
  STACIO_RELEASE_EXPECTED_CHANNEL=beta \
  "$ROOT_DIR/scripts/release-readiness.sh" >"$TMP_DIR/beta-required.out" 2>&1; then
  echo "expected beta-enabled release readiness with an empty beta Appcast to fail" >&2
  exit 1
fi
grep -Fq "FAIL beta Appcast contains no update items while beta updates are enabled" "$TMP_DIR/beta-required.out"

BETA_ENABLED_STABLE_APP_DIR="$TMP_DIR/beta-enabled-stable.app"
cp -R "$APP_DIR" "$BETA_ENABLED_STABLE_APP_DIR"
/usr/libexec/PlistBuddy -c "Set :StacioProductOpsBetaUpdatesEnabled true" "$BETA_ENABLED_STABLE_APP_DIR/Contents/Info.plist"
if PATH="$FAKE_BIN_DIR:$PATH" \
  STACIO_RELEASE_TEST_LOG="$LOG_FILE" \
  STACIO_RELEASE_APP_PATH="$BETA_ENABLED_STABLE_APP_DIR" \
  STACIO_RELEASE_DMG_PATH="$DMG_PATH" \
  STACIO_RELEASE_SKIP_PACKAGE=1 \
  "$ROOT_DIR/scripts/release-readiness.sh" >"$TMP_DIR/beta-enabled-stable.out" 2>&1; then
  echo "expected stable release readiness with Beta updates enabled to fail" >&2
  exit 1
fi
grep -Fq "FAIL formal stable release requires StacioProductOpsBetaUpdatesEnabled=false" "$TMP_DIR/beta-enabled-stable.out"

MISMATCH_APP_DIR="$TMP_DIR/mismatched-dmg.app"
cp -R "$APP_DIR" "$MISMATCH_APP_DIR"
printf 'different binary\n' >>"$MISMATCH_APP_DIR/Contents/MacOS/Stacio"
if PATH="$FAKE_BIN_DIR:$PATH" \
  STACIO_RELEASE_TEST_LOG="$LOG_FILE" \
  STACIO_RELEASE_TEST_DMG_APP_PATH="$MISMATCH_APP_DIR" \
  STACIO_RELEASE_APP_PATH="$APP_DIR" \
  STACIO_RELEASE_DMG_PATH="$DMG_PATH" \
  STACIO_RELEASE_SKIP_PACKAGE=1 \
  "$ROOT_DIR/scripts/release-readiness.sh" >"$TMP_DIR/mismatched-dmg.out" 2>&1; then
  echo "expected release readiness with mismatched DMG app to fail" >&2
  exit 1
fi
grep -Fq "FAIL DMG Stacio.app does not match release app bundle" "$TMP_DIR/mismatched-dmg.out"

touch "$SOURCE_ROOT/App.swift"
if PATH="$FAKE_BIN_DIR:$PATH" \
  STACIO_RELEASE_TEST_LOG="$LOG_FILE" \
  STACIO_RELEASE_APP_PATH="$APP_DIR" \
  STACIO_RELEASE_DMG_PATH="$DMG_PATH" \
  STACIO_RELEASE_SKIP_PACKAGE=1 \
  "$ROOT_DIR/scripts/release-readiness.sh" >"$TMP_DIR/stale-artifacts.out" 2>&1; then
  echo "expected release readiness with stale artifacts to fail" >&2
  exit 1
fi
grep -Fq "FAIL release artifacts are older than App source" "$TMP_DIR/stale-artifacts.out"
touch -t 202001010000 "$SOURCE_ROOT/App.swift"

touch -t 201901010000 "$APP_DIR/Contents/MacOS/Stacio"
if PATH="$FAKE_BIN_DIR:$PATH" \
  STACIO_RELEASE_TEST_LOG="$LOG_FILE" \
  STACIO_RELEASE_APP_PATH="$APP_DIR" \
  STACIO_RELEASE_DMG_PATH="$DMG_PATH" \
  STACIO_RELEASE_SKIP_PACKAGE=1 \
  "$ROOT_DIR/scripts/release-readiness.sh" >"$TMP_DIR/stale-binary.out" 2>&1; then
  echo "expected release readiness with a stale packaged executable to fail" >&2
  exit 1
fi
grep -Fq "FAIL packaged Stacio executable is older than App source" "$TMP_DIR/stale-binary.out"
touch "$APP_DIR/Contents/MacOS/Stacio"

if PATH="$FAKE_BIN_DIR:$PATH" \
  STACIO_RELEASE_TEST_LOG="$LOG_FILE" \
  STACIO_RELEASE_TEST_SIGNATURE_MODE=developer-runtime \
  STACIO_RELEASE_TEST_GATEKEEPER_DISABLED=1 \
  STACIO_RELEASE_APP_PATH="$APP_DIR" \
  STACIO_RELEASE_DMG_PATH="$DMG_PATH" \
  STACIO_RELEASE_SKIP_PACKAGE=1 \
  STACIO_RELEASE_REQUIRE_DEVELOPER_ID=1 \
  "$ROOT_DIR/scripts/release-readiness.sh" >"$TMP_DIR/gatekeeper-disabled.out" 2>&1; then
  echo "expected disabled Gatekeeper to fail a Developer ID readiness check" >&2
  exit 1
fi
grep -Fq "FAIL Gatekeeper assessments are disabled" "$TMP_DIR/gatekeeper-disabled.out"

if PATH="$FAKE_BIN_DIR:$PATH" \
  STACIO_RELEASE_TEST_LOG="$LOG_FILE" \
  STACIO_RELEASE_TEST_SIGNATURE_MODE=developer-runtime \
  STACIO_RELEASE_TEST_STAPLER_FAIL=1 \
  STACIO_NOTARY_PROFILE="test-profile" \
  STACIO_RELEASE_APP_PATH="$APP_DIR" \
  STACIO_RELEASE_DMG_PATH="$DMG_PATH" \
  STACIO_RELEASE_SKIP_PACKAGE=1 \
  STACIO_RELEASE_REQUIRE_DEVELOPER_ID=1 \
  STACIO_RELEASE_REQUIRE_NOTARY=1 \
  "$ROOT_DIR/scripts/release-readiness.sh" >"$TMP_DIR/notary-ticket-missing.out" 2>&1; then
  echo "expected missing notarization ticket to fail" >&2
  exit 1
fi
grep -Fq "FAIL notarization ticket validation failed" "$TMP_DIR/notary-ticket-missing.out"

if PATH="$FAKE_BIN_DIR:$PATH" \
  STACIO_RELEASE_TEST_LOG="$LOG_FILE" \
  STACIO_RELEASE_TEST_SIGNATURE_MODE=developer-no-runtime \
  STACIO_RELEASE_APP_PATH="$APP_DIR" \
  STACIO_RELEASE_DMG_PATH="$DMG_PATH" \
  STACIO_RELEASE_SKIP_PACKAGE=1 \
  STACIO_RELEASE_REQUIRE_DEVELOPER_ID=1 \
  "$ROOT_DIR/scripts/release-readiness.sh" >"$TMP_DIR/missing-runtime.out" 2>&1; then
  echo "expected Developer ID app without Hardened Runtime to fail" >&2
  exit 1
fi
grep -Fq "FAIL Hardened Runtime is not enabled" "$TMP_DIR/missing-runtime.out"

PATH="$FAKE_BIN_DIR:$PATH" \
STACIO_RELEASE_TEST_LOG="$LOG_FILE" \
STACIO_RELEASE_TEST_SIGNATURE_MODE=developer-runtime \
STACIO_RELEASE_APP_PATH="$APP_DIR" \
STACIO_RELEASE_DMG_PATH="$DMG_PATH" \
STACIO_RELEASE_SKIP_PACKAGE=1 \
STACIO_RELEASE_REQUIRE_DEVELOPER_ID=1 \
"$ROOT_DIR/scripts/release-readiness.sh" >"$TMP_DIR/runtime-ready.out"
grep -Fq "PASS Hardened Runtime enabled" "$TMP_DIR/runtime-ready.out"
grep -Fq "Summary: 0 failure(s)" "$TMP_DIR/runtime-ready.out"

printf 'release_readiness_test passed\n'
