#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAKE_BIN_DIR="$TMP_DIR/bin"
LOG_FILE="$TMP_DIR/tool-calls.log"
OUT_FILE="$TMP_DIR/stability.out"

mkdir -p "$FAKE_BIN_DIR"

cat >"$FAKE_BIN_DIR/swift" <<'EOF'
#!/usr/bin/env bash
printf 'swift' >>"$STACIO_STABILITY_TEST_LOG"
for arg in "$@"; do
  printf ' %q' "$arg" >>"$STACIO_STABILITY_TEST_LOG"
done
printf '\n' >>"$STACIO_STABILITY_TEST_LOG"
exit 0
EOF
chmod +x "$FAKE_BIN_DIR/swift"

cat >"$FAKE_BIN_DIR/cargo" <<'EOF'
#!/usr/bin/env bash
printf 'cargo' >>"$STACIO_STABILITY_TEST_LOG"
for arg in "$@"; do
  printf ' %q' "$arg" >>"$STACIO_STABILITY_TEST_LOG"
done
printf '\n' >>"$STACIO_STABILITY_TEST_LOG"
exit 0
EOF
chmod +x "$FAKE_BIN_DIR/cargo"

PATH="$FAKE_BIN_DIR:$PATH" \
STACIO_STABILITY_TEST_LOG="$LOG_FILE" \
STACIO_STABILITY_SKIP_LIVE=1 \
"$ROOT_DIR/scripts/core-stability-gate.sh" >"$OUT_FILE"

grep -Fq "Stacio core stability gate" "$OUT_FILE"
grep -Fq "SKIP live Linux SSH smoke" "$OUT_FILE"
grep -Fq "PASS Stacio core stability gate" "$OUT_FILE"

grep -Fq "swift build --package-path $ROOT_DIR --product StacioCLI" "$LOG_FILE"
grep -Fq "cargo test --manifest-path $ROOT_DIR/StacioCore/Cargo.toml" "$LOG_FILE"
grep -Fq "cargo check --manifest-path $ROOT_DIR/StacioCore/Cargo.toml" "$LOG_FILE"

for filter in \
  AIAssistantPanelViewControllerTests \
  AgentExecutionCoordinatorTests \
  AgentTaskOrchestratorTests \
  SSHBridgeTests \
  SSHConnectionCoordinatorTests \
  SavedSessionConnectionFlowTests \
  SerialSessionCoordinatorTests \
  FilesCoordinatorTests \
  FilesViewControllerTests \
  RemoteTextEditorViewControllerTests \
  TransferQueueCoordinatorTests \
  TransferQueueViewControllerTests \
  TunnelsViewControllerTests \
  MultiExecBridgeTests \
  MultiExecCoordinatorTests \
  WorkspaceLocalShellTests \
  SessionSettingsViewControllerTests
do
  grep -Fq "swift test --package-path $ROOT_DIR --filter $filter" "$LOG_FILE"
done

cat >"$FAKE_BIN_DIR/swift" <<'EOF'
#!/usr/bin/env bash
printf 'swift' >>"$STACIO_STABILITY_TEST_LOG"
for arg in "$@"; do
  printf ' %q' "$arg" >>"$STACIO_STABILITY_TEST_LOG"
done
printf '\n' >>"$STACIO_STABILITY_TEST_LOG"
for arg in "$@"; do
  if [[ "$arg" == "SSHBridgeTests" ]]; then
    printf 'warning: No matching test cases were run\n' >&2
    break
  fi
done
exit 0
EOF
chmod +x "$FAKE_BIN_DIR/swift"

NO_MATCH_OUT_FILE="$TMP_DIR/stability-no-match.out"
if PATH="$FAKE_BIN_DIR:$PATH" \
  STACIO_STABILITY_TEST_LOG="$LOG_FILE" \
  STACIO_STABILITY_SKIP_LIVE=1 \
  "$ROOT_DIR/scripts/core-stability-gate.sh" >"$NO_MATCH_OUT_FILE" 2>&1; then
  echo "expected core-stability-gate to fail when a Swift filter matches no tests" >&2
  exit 1
fi
grep -Fq "No matching test cases" "$NO_MATCH_OUT_FILE"

echo "core_stability_gate_test passed"
