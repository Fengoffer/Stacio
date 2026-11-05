#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STACIO_CHECK_DIR="$(mktemp -d /tmp/stacio-lifecycle-check.XXXXXX)"
# Exercise the actual controller methods with deferred provider completions.
# This avoids XCTest and Metal dependencies in Command Line Tools installations.
python3 - "$ROOT" "$STACIO_CHECK_DIR" <<'PY'
from pathlib import Path
import sys
root, out = map(Path, sys.argv[1:])
source = (root / 'Stacio/Views/Metrics/DeviceMetricsDashboardViewController.swift').read_text()
def method(name):
    start = source.index('    ', source.rfind('\n', 0, source.index('func ' + name + '(')))
    brace = source.index('{', start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end].replace('private func ', 'func ', 1)
fields = source[source.index('    private var managementLoads'):source.index('    private var selectedNetworkNames')]
methods = '\n'.join(method(name) for name in [
    'startPollingIfNeeded', 'stopPolling', 'scheduleManagementWarmupIfNeeded',
    'cancelManagementWarmup', 'runNextManagementWarmup',
    'executeInventoryAction', 'authorizeManagement',
    'refreshAuthorizedManagementPanels', 'loadManagementData',
])
template = (root / 'Tests/DeviceMetrics/LifecycleChecks.swift').read_text()
(out / 'LifecycleChecks.swift').write_text(template.replace('// PRODUCTION_STATE', fields).replace('// PRODUCTION_METHODS', methods))
PY
STACIO_CHECK_SDK="${STACIO_MACOS_SDK_PATH:-$(xcrun --sdk macosx --show-sdk-path)}"
swiftc -parse-as-library -sdk "$STACIO_CHECK_SDK" -o "$STACIO_CHECK_DIR/check" "$STACIO_CHECK_DIR/LifecycleChecks.swift"
"$STACIO_CHECK_DIR/check"
