#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STACIO_CHECK_DIR="$(mktemp -d /tmp/stacio-inventory-check.XXXXXX)"
# Compile the production model/parser/command code without its SSH provider extension.
# This AppKit executable does not require the XCTest modules missing from CLT.
python3 - "$ROOT" "$STACIO_CHECK_DIR" <<'PY'
from pathlib import Path
import sys
root, out = map(Path, sys.argv[1:])
s = (root / 'Stacio/Services/DeviceMetricsInventoryManager.swift').read_text()
a = s.index('extension CoreBridgeDeviceMetricsProvider:')
b = s.index('public enum DeviceMetricsInventoryParser', a)
(out / 'InventoryModels.swift').write_text(s[:a] + s[b:])
PY
STACIO_CHECK_SDK="${STACIO_MACOS_SDK_PATH:-$(xcrun --sdk macosx --show-sdk-path)}"
swiftc -parse-as-library -sdk "$STACIO_CHECK_SDK" -o "$STACIO_CHECK_DIR/check" \
  "$STACIO_CHECK_DIR/InventoryModels.swift" \
  "$ROOT/Stacio/Views/Metrics/DeviceMetricsInventoryPanel.swift" \
  "$ROOT/Tests/DeviceMetrics/InventoryChecks.swift"
"$STACIO_CHECK_DIR/check"
