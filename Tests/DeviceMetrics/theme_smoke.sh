#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STACIO_CHECK_DIR="$(mktemp -d /tmp/stacio-theme-check.XXXXXX)"
# Use the production traversal, color-role resolver, and real inventory cells.
# This AppKit regression runs without XCTest or Metal in Command Line Tools.
python3 - "$ROOT" "$STACIO_CHECK_DIR" <<'PY'
from pathlib import Path
import sys
root, out = map(Path, sys.argv[1:])
models = (root / 'Stacio/Services/DeviceMetricsInventoryManager.swift').read_text()
start = models.index('extension CoreBridgeDeviceMetricsProvider:')
end = models.index('public enum DeviceMetricsInventoryParser', start)
(out / 'InventoryModels.swift').write_text(models[:start] + models[end:])
source = (root / 'Stacio/Views/Metrics/DeviceMetricsDashboardViewController.swift').read_text()
def declaration(marker):
    start = source.index(marker)
    brace = source.index('{', start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]
role = declaration('private enum DeviceMetricsTextColorRole:')
methods = '\n'.join(declaration(marker).replace('private func ', 'func ', 1) for marker in [
    '    private func refreshThemeForEffectiveAppearanceChange(',
    '    private func refreshTextColors(', '    private func color(',
])
template = (root / 'Tests/DeviceMetrics/ThemeChecks.swift').read_text()
(out / 'ThemeChecks.swift').write_text(template.replace('// PRODUCTION_ROLE', role).replace('// PRODUCTION_METHODS', methods))
PY
STACIO_CHECK_SDK="${STACIO_MACOS_SDK_PATH:-$(xcrun --sdk macosx --show-sdk-path)}"
swiftc -parse-as-library -sdk "$STACIO_CHECK_SDK" -o "$STACIO_CHECK_DIR/check" \
  "$STACIO_CHECK_DIR/InventoryModels.swift" \
  "$ROOT/Stacio/Views/Metrics/DeviceMetricsInventoryPanel.swift" \
  "$STACIO_CHECK_DIR/ThemeChecks.swift"
"$STACIO_CHECK_DIR/check"
