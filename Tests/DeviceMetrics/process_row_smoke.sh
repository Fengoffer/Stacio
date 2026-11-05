#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STACIO_ROW_CHECK_DIR="$(mktemp -d /tmp/stacio-process-row-check.XXXXXX)"
python3 - "$ROOT" "$STACIO_ROW_CHECK_DIR" <<'PY'
from pathlib import Path
import sys
root, out = map(Path, sys.argv[1:])
models = (root / 'Stacio/Services/DeviceMetricsInventoryManager.swift').read_text()
start = models.index('extension CoreBridgeDeviceMetricsProvider:')
end = models.index('public enum DeviceMetricsInventoryParser', start)
(out / 'Models.swift').write_text(models[:start] + models[end:])
source = (root / 'Stacio/Views/Metrics/DeviceMetricsDashboardViewController.swift').read_text()
start = source.index('    private func processRows(')
brace = source.index('{', start)
depth, end = 1, brace + 1
while depth:
    depth += (source[end] == '{') - (source[end] == '}')
    end += 1
method = source[start:end].replace('private func ', 'func ', 1)
template = (root / 'Tests/DeviceMetrics/ProcessRowChecks.swift').read_text()
(out / 'Checks.swift').write_text(template.replace('// PRODUCTION_ROWS', method))
PY
STACIO_ROW_CHECK_SDK="${STACIO_MACOS_SDK_PATH:-$(xcrun --sdk macosx --show-sdk-path)}"
swiftc -parse-as-library -sdk "$STACIO_ROW_CHECK_SDK" -o "$STACIO_ROW_CHECK_DIR/check" \
  "$STACIO_ROW_CHECK_DIR/Models.swift" \
  "$ROOT/Stacio/Views/Metrics/DeviceMetricsInventoryPanel.swift" \
  "$STACIO_ROW_CHECK_DIR/Checks.swift"
"$STACIO_ROW_CHECK_DIR/check"
