#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STACIO_DASHBOARD_HOVER_CHECK_DIR="$(mktemp -d /tmp/stacio-dashboard-hover-check.XXXXXX)"
# Compile production AppKit views and models without unrelated Metal/XCTest.
python3 - "$ROOT" "$STACIO_DASHBOARD_HOVER_CHECK_DIR" <<'PY'
from pathlib import Path
import sys
root, out = map(Path, sys.argv[1:])
source = (root / 'Stacio/Services/DeviceMetricsProvider.swift').read_text()
models = source[:source.index('public protocol DeviceMetricsProviding:')]
models = models.replace('import StacioCoreBindings\n', '')
models += source[source.index('private extension UInt64 {'):]
(out / 'DisplayModels.swift').write_text(models)
formatter = (root / 'Stacio/Views/Metrics/DeviceMetricHistoryDetailViewController.swift').read_text()
(out / 'Formatter.swift').write_text(formatter[:formatter.index('public struct DeviceMetricHistorySample:')])
PY
STACIO_DASHBOARD_HOVER_CHECK_SDK="${STACIO_MACOS_SDK_PATH:-$(xcrun --sdk macosx --show-sdk-path)}"
swiftc -parse-as-library -sdk "$STACIO_DASHBOARD_HOVER_CHECK_SDK" -o "$STACIO_DASHBOARD_HOVER_CHECK_DIR/check" \
  "$ROOT/Stacio/App/GlassCapabilityAdapter.swift" \
  "$STACIO_DASHBOARD_HOVER_CHECK_DIR/DisplayModels.swift" \
  "$STACIO_DASHBOARD_HOVER_CHECK_DIR/Formatter.swift" \
  "$ROOT/Stacio/Views/Metrics/DeviceMetricsStatusDetailViewController.swift" \
  "$ROOT/Stacio/Views/Metrics/DeviceMetricsDashboardHoverPresenter.swift" \
  "$ROOT/Tests/DeviceMetrics/DashboardHoverChecks.swift"
"$STACIO_DASHBOARD_HOVER_CHECK_DIR/check"
