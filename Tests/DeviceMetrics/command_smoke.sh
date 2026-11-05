#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STACIO_COMMAND_CHECK_DIR="$(mktemp -d /tmp/stacio-command-check-build.XXXXXX)"
trap 'rm -rf "$STACIO_COMMAND_CHECK_DIR"' EXIT
STACIO_COMMAND_CHECK_SDK="${STACIO_MACOS_SDK_PATH:-$(xcrun --sdk macosx --show-sdk-path)}"
# macOS lacks the setsid executable; this fixture invokes the real system call
# so the production process-group branch is exercised without GNU coreutils.
cat > "$STACIO_COMMAND_CHECK_DIR/setsid.c" <<'C'
#include <unistd.h>
int main(int argc, char **argv) {
    if (argc < 2 || setsid() < 0) return 125;
    execvp(argv[1], argv + 1);
    return 126;
}
C
cc -isysroot "$STACIO_COMMAND_CHECK_SDK" -o "$STACIO_COMMAND_CHECK_DIR/setsid" "$STACIO_COMMAND_CHECK_DIR/setsid.c"
swiftc -parse-as-library -sdk "$STACIO_COMMAND_CHECK_SDK" -o "$STACIO_COMMAND_CHECK_DIR/check" \
  "$ROOT/Stacio/Services/DeviceMetricsInventoryManager.swift" \
  "$ROOT/Tests/DeviceMetrics/CommandChecks.swift"
STACIO_TEST_SETSID_HELPER="$STACIO_COMMAND_CHECK_DIR/setsid" "$STACIO_COMMAND_CHECK_DIR/check"
