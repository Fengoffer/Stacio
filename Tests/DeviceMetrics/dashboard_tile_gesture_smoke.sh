#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STACIO_DASHBOARD_TILE_CHECK_DIR="$(mktemp -d /tmp/stacio-dashboard-tile-check.XXXXXX)"

# Compile the production hit-testing and gesture delegate implementations in
# isolation so this check remains usable with the Command Line Tools SDK.
python3 - "$ROOT" "$STACIO_DASHBOARD_TILE_CHECK_DIR" <<'PY'
from pathlib import Path
import sys

root, out = map(Path, sys.argv[1:])
source = (root / "Stacio/Views/Metrics/DeviceMetricsDashboardViewController.swift").read_text()
if "historyClick.delegate = tile" not in source:
    raise SystemExit("dashboard history gesture is not delegated to the metric tile")

arrow_start = source.index("private class DeviceMetricsArrowCursorView:")
arrow_end = source.index("private class DeviceMetricStaticLabel:", arrow_start)
tile_start = source.index("private final class DeviceMetricsTileView:")
tile_end = source.index("private final class DeviceMetricsStatusDotView:", tile_start)

production = "import AppKit\n\n" + source[arrow_start:arrow_end] + source[tile_start:tile_end]
production += r'''

@MainActor
func makeProductionMetricTileForGestureCheck(frame: NSRect) -> NSView {
    DeviceMetricsTileView(frame: frame)
}

@MainActor
func installProductionMetricTileDelegate(_ recognizer: NSGestureRecognizer, on view: NSView) {
    recognizer.delegate = view as? DeviceMetricsTileView
}
'''
(out / "ProductionMetricTile.swift").write_text(production)
PY

STACIO_DASHBOARD_TILE_CHECK_SDK="${STACIO_MACOS_SDK_PATH:-$(xcrun --sdk macosx --show-sdk-path)}"
swiftc -parse-as-library -sdk "$STACIO_DASHBOARD_TILE_CHECK_SDK" \
  -o "$STACIO_DASHBOARD_TILE_CHECK_DIR/check" \
  "$STACIO_DASHBOARD_TILE_CHECK_DIR/ProductionMetricTile.swift" \
  "$ROOT/Tests/DeviceMetrics/DashboardTileGestureChecks.swift"
"$STACIO_DASHBOARD_TILE_CHECK_DIR/check"
