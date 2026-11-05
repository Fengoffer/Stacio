#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STACIO_DETAIL_CHECK_DIR="$(mktemp -d /tmp/stacio-status-detail-check.XXXXXX)"
# Compile the real AppKit detail surface and display models, avoiding the
# unrelated Rust bridge, Metal and XCTest dependencies in CLT installations.
python3 - "$ROOT" "$STACIO_DETAIL_CHECK_DIR" <<'PY'
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
STACIO_DETAIL_CHECK_SDK="${STACIO_MACOS_SDK_PATH:-$(xcrun --sdk macosx --show-sdk-path)}"
swiftc -parse-as-library -sdk "$STACIO_DETAIL_CHECK_SDK" -o "$STACIO_DETAIL_CHECK_DIR/check" \
  "$ROOT/Stacio/App/GlassCapabilityAdapter.swift" \
  "$STACIO_DETAIL_CHECK_DIR/DisplayModels.swift" \
  "$STACIO_DETAIL_CHECK_DIR/Formatter.swift" \
  "$ROOT/Stacio/Views/Metrics/DeviceMetricsStatusDetailViewController.swift" \
  "$ROOT/Tests/DeviceMetrics/StatusDetailChecks.swift"
"$STACIO_DETAIL_CHECK_DIR/check"
