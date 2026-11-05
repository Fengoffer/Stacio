#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STACIO_AUTH_CHECK_DIR="$(mktemp -d /tmp/stacio-authorization-check-build.XXXXXX)"
trap 'rm -rf "$STACIO_AUTH_CHECK_DIR"' EXIT
STACIO_AUTH_CHECK_SDK="${STACIO_MACOS_SDK_PATH:-$(xcrun --sdk macosx --show-sdk-path)}"
swiftc -parse-as-library -sdk "$STACIO_AUTH_CHECK_SDK" -o "$STACIO_AUTH_CHECK_DIR/check" \
  "$ROOT/Stacio/Services/DeviceMetricsInventoryManager.swift" \
  "$ROOT/Tests/DeviceMetrics/AuthorizationChecks.swift"
"$STACIO_AUTH_CHECK_DIR/check"
