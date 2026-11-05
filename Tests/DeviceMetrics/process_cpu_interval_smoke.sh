#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STACIO_CPU_CHECK_DIR="$(mktemp -d /tmp/stacio-process-cpu-check.XXXXXX)"
python3 - "$ROOT" "$STACIO_CPU_CHECK_DIR" <<'PY'
from pathlib import Path
import sys
root, out = map(Path, sys.argv[1:])
source = (root / 'Stacio/Services/DeviceMetricsProvider.swift').read_text()
(out / 'Provider.swift').write_text(source.replace('import StacioCoreBindings\n', ''))
bindings = (root / 'Stacio/Bridge/Generated/Sources/stacio_core.swift').read_text()
names = ['DeviceMetricsSnapshot', 'DeviceProcessSample', 'DeviceCpuSample',
         'DeviceSystemInfo', 'DeviceMemorySample', 'DeviceNetworkSample',
         'DeviceDiskSample', 'DeviceDiskIoSample', 'DevicePortSample',
         'DeviceServiceSample', 'DeviceContainerSample']
records = ['import Foundation\n']
for name in names:
    start = bindings.index(f'public struct {name} {{')
    end = bindings.index('\n#if compiler', start)
    records.append(bindings[start:end])
(out / 'CoreRecords.swift').write_text('\n'.join(records))
PY
STACIO_CPU_CHECK_SDK="${STACIO_MACOS_SDK_PATH:-$(xcrun --sdk macosx --show-sdk-path)}"
swiftc -parse-as-library -sdk "$STACIO_CPU_CHECK_SDK" -o "$STACIO_CPU_CHECK_DIR/check" \
  "$STACIO_CPU_CHECK_DIR/CoreRecords.swift" \
  "$STACIO_CPU_CHECK_DIR/Provider.swift" \
  "$ROOT/Tests/DeviceMetrics/ProcessCPUIntervalChecks.swift"
"$STACIO_CPU_CHECK_DIR/check"
