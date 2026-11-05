#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STACIO_DISK_HISTORY_CHECK_DIR="$(mktemp -d /tmp/stacio-disk-history-popover.XXXXXX)"
python3 - "$ROOT" "$STACIO_DISK_HISTORY_CHECK_DIR" <<'PY'
from pathlib import Path
import sys
root, out = map(Path, sys.argv[1:])
source = (root / 'Stacio/Views/Metrics/DeviceMetricsDashboardViewController.swift').read_text()
def block(marker):
    start = source.rfind('\n', 0, source.index(marker)) + 1
    brace = source.index('{', start)
    depth, end = 1, brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end].replace('private func ', 'func ', 1)
methods = '\n'.join(block('func ' + name + '(') for name in [
    'uniqueDiskMounts', 'renderDisks', 'replaceDiskRows', 'renderUnavailableSnapshot',
    'makeDiskRow', 'makeUnavailableDiskHistoryRow', 'showDiskHistory',
    'metricText', 'percentText', 'byteText', 'selectInventoryTab'
])
methods += '\n' + block('func showHistoryDetail(\n        title:')
views = '\n'.join(block(marker) for marker in [
    'class DeviceMetricStaticLabel:', 'class DeviceDiskPieView:'
])
template = (root / 'Tests/DeviceMetrics/DiskHistoryPopoverChecks.swift').read_text()
(out / 'Checks.swift').write_text(template.replace('// PRODUCTION_DASHBOARD_METHODS', methods)
    .replace('// PRODUCTION_DISK_VIEWS', views))
PY
STACIO_DISK_HISTORY_CHECK_SDK="${STACIO_MACOS_SDK_PATH:-$(xcrun --sdk macosx --show-sdk-path)}"
swiftc -parse-as-library -sdk "$STACIO_DISK_HISTORY_CHECK_SDK" \
  "$STACIO_DISK_HISTORY_CHECK_DIR/Checks.swift" \
  "$ROOT/Stacio/Views/Metrics/DeviceMetricHistoryDetailViewController.swift" \
  -o "$STACIO_DISK_HISTORY_CHECK_DIR/check"
if [[ "${STACIO_DISK_HISTORY_CHECK_COMPILE_ONLY:-0}" == "1" ]]; then
  echo "$STACIO_DISK_HISTORY_CHECK_DIR/check"
  exit 0
fi
"$STACIO_DISK_HISTORY_CHECK_DIR/check"
