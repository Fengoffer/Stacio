#!/usr/bin/env bash
set -euo pipefail

# Repeat the AppKit/Metal + real Rust output-buffer fixture without SSH access.
# Logs include CPU time, scheduling counts, byte equality and rendered end markers.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
OUTPUT_DIR="${1:-$ROOT_DIR/tmp/terminal-performance/$(date +%Y%m%d-%H%M%S)}"
RUN_COUNT="${2:-3}"
if ! [[ "$RUN_COUNT" =~ ^[1-9][0-9]*$ ]]; then
  echo 'Run count must be a positive integer.' >&2
  exit 2
fi
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
export DYLD_LIBRARY_PATH="$ROOT_DIR/StacioCore/target/debug${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
./scripts/build-core.sh > "$OUTPUT_DIR/core-build.log" 2>&1
# Compile with the opt-in workload disabled before preparing test-only resources.
STACIO_TERMINAL_PERFORMANCE=0 swift test --build-system native \
  --filter TerminalOutputPerformanceTests > "$OUTPUT_DIR/swift-build.log" 2>&1
BIN_DIR="$(swift build --build-system native --show-bin-path 2>/dev/null)"
TEST_RESOURCES="$BIN_DIR/StacioPackageTests.xctest/Contents/Resources"
mkdir -p "$TEST_RESOURCES"
cp "$ROOT_DIR/Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/Shaders.metal" \
  "$TEST_RESOURCES/Shaders.metal"
for ((run = 1; run <= RUN_COUNT; run++)); do
  echo "Terminal workload $run/$RUN_COUNT"
  STACIO_TERMINAL_PERFORMANCE=1 swift test --build-system native --skip-build \
    --filter TerminalOutputPerformanceTests > "$OUTPUT_DIR/run-$run.log" 2>&1
  rg '^TERMINAL_' "$OUTPUT_DIR/run-$run.log"
done
echo "Logs: $OUTPUT_DIR"
