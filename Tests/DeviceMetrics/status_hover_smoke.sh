#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STACIO_HOVER_CHECK_DIR="$(mktemp -d /tmp/stacio-status-hover-check.XXXXXX)"
python3 - "$ROOT" "$STACIO_HOVER_CHECK_DIR" <<'PY'
from pathlib import Path
import sys
root, out = map(Path, sys.argv[1:])
source = (root / 'Stacio/Services/DeviceMetricsProvider.swift').read_text()
models = source[:source.index('public final class CoreBridgeDeviceMetricsProvider:')]
models = models.replace('import StacioCoreBindings\n', '')
models += source[source.index('private extension UInt64 {'):]
(out / 'DisplayModels.swift').write_text(models)
formatter = (root / 'Stacio/Views/Metrics/DeviceMetricHistoryDetailViewController.swift').read_text()
(out / 'Formatter.swift').write_text(formatter[:formatter.index('public enum DeviceMetricHistoryGranularity:')])
alerts = (root / 'Stacio/Services/DeviceMetricsAlertCoordinator.swift').read_text()
# Exercise the actual threshold/consecutive-breach implementation. Only the
# system notification adapter (unrelated to this in-process test) is omitted.
alerts = alerts[:alerts.index('public final class StacioUserNotificationDeviceMetricsAlertNotifier:')] + alerts[alerts.index('public final class DeviceMetricsAlertCoordinator {'):]
(out / 'Alerts.swift').write_text(alerts.replace('public ', ''))
PY
STACIO_HOVER_CHECK_SDK="${STACIO_MACOS_SDK_PATH:-$(xcrun --sdk macosx --show-sdk-path)}"
swiftc -parse-as-library -sdk "$STACIO_HOVER_CHECK_SDK" -o "$STACIO_HOVER_CHECK_DIR/check" \
  "$ROOT/Stacio/App/GlassCapabilityAdapter.swift" \
  "$STACIO_HOVER_CHECK_DIR/DisplayModels.swift" \
  "$STACIO_HOVER_CHECK_DIR/Formatter.swift" \
  "$STACIO_HOVER_CHECK_DIR/Alerts.swift" \
  "$ROOT/Stacio/Views/Metrics/DeviceMetricsStatusBarViewController.swift" \
  "$ROOT/Stacio/Views/Metrics/DeviceMetricsStatusDetailViewController.swift" \
  "$ROOT/Tests/DeviceMetrics/StatusHoverChecks.swift"
"$STACIO_HOVER_CHECK_DIR/check"
