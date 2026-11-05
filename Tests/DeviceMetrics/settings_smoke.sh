#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STACIO_SETTINGS_CHECK_DIR="$(mktemp -d /tmp/stacio-metrics-settings.XXXXXX)"
python3 - "$ROOT" "$STACIO_SETTINGS_CHECK_DIR" <<'PY'
from pathlib import Path
import sys
root, out = map(Path, sys.argv[1:])
def method(source, name):
    marker = 'func ' + name + '('
    start = source.rfind('\n', 0, source.index(marker)) + 1
    brace = source.index('{', start)
    depth, end = 1, brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end].replace('private func ', 'func ', 1)
dashboard = (root / 'Stacio/Views/Metrics/DeviceMetricsDashboardViewController.swift').read_text()
workspace = (root / 'Stacio/Views/Workspace/WorkspaceViewController.swift').read_text()
dashboard_methods = '\n'.join(method(dashboard, name) for name in [
    'startPollingIfNeeded', 'stopPolling', 'applyMetricsSettings',
    'refreshMetrics', 'render', 'renderError', 'renderUnavailableSnapshot', 'makeDiskRow', 'makeUnavailableDiskHistoryRow', 'showDiskHistory', 'uniqueDiskMounts', 'renderDisks', 'replaceDiskRows',
    'updateCollectionStatus', 'updateCPUCoreButton', 'updateThresholdStyles',
    'makeChartRow', 'makeMetricTileRow', 'makeDashboardBodyStack',
    'updateOverviewVisibility', 'renderDashboardBody'
])
workspace_methods = '\n'.join(method(workspace, name) for name in ['refreshDeviceMetricsDisplayLocation', 'installDeviceDashboard'])
template = (root / 'Tests/DeviceMetrics/SettingsChecks.swift').read_text()
(out / 'Checks.swift').write_text(template.replace('// PRODUCTION_DASHBOARD_METHODS', dashboard_methods)
                                .replace('// PRODUCTION_WORKSPACE_METHODS', workspace_methods))
PY
STACIO_SETTINGS_CHECK_SDK="${STACIO_MACOS_SDK_PATH:-$(xcrun --sdk macosx --show-sdk-path)}"
swiftc -parse-as-library -sdk "$STACIO_SETTINGS_CHECK_SDK" -o "$STACIO_SETTINGS_CHECK_DIR/check" "$STACIO_SETTINGS_CHECK_DIR/Checks.swift"
if [[ "${STACIO_SETTINGS_CHECK_COMPILE_ONLY:-0}" == "1" ]]; then
  echo "$STACIO_SETTINGS_CHECK_DIR/check"
  exit 0
fi
"$STACIO_SETTINGS_CHECK_DIR/check"
