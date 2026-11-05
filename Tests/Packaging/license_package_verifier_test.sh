#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

APP_DIR="$TMP_DIR/Stacio.app"
PLIST="$APP_DIR/Contents/Info.plist"
EXECUTABLE="$APP_DIR/Contents/MacOS/Stacio"
TRUST_CONFIG="$TMP_DIR/license-trust-anchors.json"
mkdir -p "$(dirname "$EXECUTABLE")"

cat >"$TRUST_CONFIG" <<'JSON'
{
  "schemaVersion": 1,
  "productID": "stacio",
  "apiBaseURL": "https://ops.example.test",
  "onlineAuthorization": {
    "algorithm": "Ed25519",
    "signatureKeyID": "online-test",
    "publicKeyBase64": "PUAXw+hDiVqStwqnTRt+vJyYLM8uxJaMwM1V8Sr0Zgw="
  },
  "offlineLicense": {
    "exchangeURL": "https://ops.example.test/offline-license/exchange",
    "request": {
      "protocol": "stacio-offline-request",
      "version": 1,
      "keyID": "offline-request-test",
      "publicKeyBase64": "K9OVBGEgLiQvK66DwHcRnVukrjAFg9frt5I7Im2FM0M="
    },
    "authorization": {
      "algorithm": "Ed25519",
      "signatureKeyID": "offline-signing-test",
      "publicKeyBase64": "7WpHo52oabVEYVXkCy2T8ePwFnviZzK656PvnY46P9M="
    }
  },
  "storage": {
    "contractID": "stacio-license-vault-v1",
    "schemaVersion": 1
  }
}
JSON

cat >"$PLIST" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.stacio.Stacio</string>
  <key>StacioProductOpsProductID</key><string>stacio</string>
  <key>StacioProductOpsAPIBaseURL</key><string>https://ops.example.test</string>
  <key>StacioLicensePublicEd25519Key</key><string>PUAXw+hDiVqStwqnTRt+vJyYLM8uxJaMwM1V8Sr0Zgw=</string>
  <key>StacioOnlineLicenseSignatureKeyID</key><string>online-test</string>
  <key>StacioOfflineLicenseExchangeURL</key><string>https://ops.example.test/offline-license/exchange</string>
  <key>StacioOfflineRequestKeyID</key><string>offline-request-test</string>
  <key>StacioOfflineExchangePublicKey</key><string>K9OVBGEgLiQvK66DwHcRnVukrjAFg9frt5I7Im2FM0M=</string>
  <key>StacioOfflineSignatureKeyID</key><string>offline-signing-test</string>
  <key>StacioOfflineLicensePublicKey</key><string>7WpHo52oabVEYVXkCy2T8ePwFnviZzK656PvnY46P9M=</string>
  <key>StacioLicenseStorageContractID</key><string>stacio-license-vault-v1</string>
  <key>StacioLicenseStorageSchemaVersion</key><integer>1</integer>
</dict></plist>
PLIST

cat >"$EXECUTABLE" <<'EOF'
#!/usr/bin/env bash
# Static package markers emitted by the production Stacio binary.
: cn.stacio.product-ops.license
: stacio.product-ops.license.
: stacio-license-vault-v1
: credentials.vault.json
: credentials.vault.key
EOF
chmod +x "$EXECUTABLE"

"$ROOT_DIR/scripts/verify-license-package.sh" "$APP_DIR" "$TRUST_CONFIG"

/usr/libexec/PlistBuddy -c \
  "Set :StacioLicensePublicEd25519Key AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" \
  "$PLIST"
if "$ROOT_DIR/scripts/verify-license-package.sh" "$APP_DIR" "$TRUST_CONFIG" \
  >"$TMP_DIR/mismatch.log" 2>&1; then
  echo "expected a mismatched packaged online license key to fail" >&2
  exit 1
fi
grep -Fq "StacioLicensePublicEd25519Key" "$TMP_DIR/mismatch.log"

echo "license_package_verifier_test passed"
