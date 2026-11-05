#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STACIO_CONTAINER_CHECK_DIR="$(mktemp -d /tmp/stacio-container-panel.XXXXXX)"
trap 'rm -rf "$STACIO_CONTAINER_CHECK_DIR"' EXIT
python3 - "$ROOT" "$STACIO_CONTAINER_CHECK_DIR" <<'PY'
from pathlib import Path
import sys
root, out = map(Path, sys.argv[1:])
source = (root / 'Stacio/Services/DeviceMetricsInventoryManager.swift').read_text()
start = source.index('extension CoreBridgeDeviceMetricsProvider:')
end = source.index('public enum DeviceMetricsInventoryParser', start)
(out / 'Models.swift').write_text(source[:start] + source[end:])
dashboard = (root / 'Stacio/Views/Metrics/DeviceMetricsDashboardViewController.swift').read_text()
start = dashboard.index('    private func portRows(')
end = dashboard.index('    private func serviceRows(', start)
port_rows = dashboard[start:end].replace('private func ', 'func ', 1)
template = (root / 'Tests/DeviceMetrics/ContainerPanelChecks.swift').read_text()
(out / 'ContainerPanelChecks.swift').write_text(template.replace('// PORT_ROW_METHOD', port_rows))
PY
STACIO_CONTAINER_CHECK_SDK="${STACIO_MACOS_SDK_PATH:-$(xcrun --sdk macosx --show-sdk-path)}"
swiftc -parse-as-library -sdk "$STACIO_CONTAINER_CHECK_SDK" -o "$STACIO_CONTAINER_CHECK_DIR/check" \
  "$STACIO_CONTAINER_CHECK_DIR/Models.swift" \
  "$ROOT/Stacio/Views/Metrics/DeviceMetricsInventoryPanel.swift" \
  "$STACIO_CONTAINER_CHECK_DIR/ContainerPanelChecks.swift"
"$STACIO_CONTAINER_CHECK_DIR/check"
