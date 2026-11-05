#!/usr/bin/env bash
set -euo pipefail

APP_DIR="${1:?Usage: verify-license-package.sh <Stacio.app> [trust-anchors.json]}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRUST_CONFIG="${2:-$ROOT_DIR/config/license-trust-anchors.json}"
PLIST="$APP_DIR/Contents/Info.plist"
EXECUTABLE="$APP_DIR/Contents/MacOS/Stacio"

[[ -d "$APP_DIR" ]] || { echo "Stacio app bundle missing: $APP_DIR" >&2; exit 1; }
[[ -f "$PLIST" ]] || { echo "Info.plist missing: $PLIST" >&2; exit 1; }
[[ -x "$EXECUTABLE" ]] || { echo "Stacio executable missing or not executable: $EXECUTABLE" >&2; exit 1; }
[[ -f "$TRUST_CONFIG" ]] || { echo "License trust-anchor config missing: $TRUST_CONFIG" >&2; exit 1; }

python3 - "$PLIST" "$TRUST_CONFIG" <<'PY'
import base64
import binascii
import json
import plistlib
import sys
from urllib.parse import urlparse

plist_path, config_path = sys.argv[1:]
with open(plist_path, "rb") as stream:
    plist = plistlib.load(stream)
with open(config_path, "r", encoding="utf-8") as stream:
    config = json.load(stream)

def required(mapping, *path):
    value = mapping
    for part in path:
        if not isinstance(value, dict) or part not in value:
            raise SystemExit(f"License trust-anchor config missing: {'.'.join(path)}")
        value = value[part]
    if value == "":
        raise SystemExit(f"License trust-anchor config contains an empty value: {'.'.join(path)}")
    return value

def check_plist(key, expected):
    actual = plist.get(key)
    if actual != expected:
        raise SystemExit(f"{key} mismatch: expected {expected!r}, got {actual!r}")

def check_key(name, value, size=32):
    try:
        decoded = base64.b64decode("".join(value.split()), validate=True)
    except (ValueError, binascii.Error):
        raise SystemExit(f"{name} must contain a valid base64 public key")
    if len(decoded) != size:
        raise SystemExit(f"{name} must contain a {size}-byte raw public key")

product_id = str(required(config, "productID"))
api_base_url = str(required(config, "apiBaseURL"))
online = config["onlineAuthorization"]
offline = config["offlineLicense"]
request = offline["request"]
authorization = offline["authorization"]
storage = config["storage"]

if urlparse(api_base_url).scheme != "https":
    raise SystemExit("apiBaseURL must use HTTPS")
exchange_url = str(required(offline, "exchangeURL"))
if urlparse(exchange_url).scheme != "https":
    raise SystemExit("offlineLicense.exchangeURL must use HTTPS")
if required(online, "algorithm") != "Ed25519":
    raise SystemExit("onlineAuthorization.algorithm must be Ed25519")
if required(authorization, "algorithm") != "Ed25519":
    raise SystemExit("offlineLicense.authorization.algorithm must be Ed25519")
check_key("onlineAuthorization.publicKeyBase64", str(required(online, "publicKeyBase64")))
check_key("offlineLicense.request.publicKeyBase64", str(required(request, "publicKeyBase64")))
check_key("offlineLicense.authorization.publicKeyBase64", str(required(authorization, "publicKeyBase64")))

check_plist("CFBundleIdentifier", "com.stacio.Stacio")
check_plist("StacioProductOpsProductID", product_id)
check_plist("StacioProductOpsAPIBaseURL", api_base_url)
check_plist("StacioLicensePublicEd25519Key", str(required(online, "publicKeyBase64")))
check_plist("StacioOnlineLicenseSignatureKeyID", str(required(online, "signatureKeyID")))
check_plist("StacioOfflineLicenseExchangeURL", exchange_url)
check_plist("StacioOfflineRequestKeyID", str(required(request, "keyID")))
check_plist("StacioOfflineExchangePublicKey", str(required(request, "publicKeyBase64")))
check_plist("StacioOfflineSignatureKeyID", str(required(authorization, "signatureKeyID")))
check_plist("StacioOfflineLicensePublicKey", str(required(authorization, "publicKeyBase64")))
check_plist("StacioLicenseStorageContractID", str(required(storage, "contractID")))
check_plist("StacioLicenseStorageSchemaVersion", int(required(storage, "schemaVersion")))

print("License package trust-anchor metadata verified")
PY

for marker in \
  "cn.stacio.product-ops.license" \
  "stacio.product-ops.license." \
  "credentials.vault.json" \
  "credentials.vault.key" \
  "stacio-license-vault-v1"
do
  if ! grep -aFq "$marker" "$EXECUTABLE"; then
    echo "Stacio executable is missing License storage marker: $marker" >&2
    exit 1
  fi
done

echo "License package binary markers verified"
