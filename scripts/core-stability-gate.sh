#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FULL_GATE="${STACIO_STABILITY_FULL:-0}"
SKIP_LIVE="${STACIO_STABILITY_SKIP_LIVE:-0}"

if ! command -v cargo >/dev/null 2>&1 && [[ -x "$HOME/.cargo/bin/cargo" ]]; then
  export PATH="$HOME/.cargo/bin:$PATH"
fi

export DYLD_LIBRARY_PATH="$ROOT_DIR/StacioCore/target/debug:${DYLD_LIBRARY_PATH:-}"

run_cmd() {
  printf '\n$'
  printf ' %q' "$@"
  printf '\n'
  "$@"
}

run_swift_filter() {
  local filter="$1"
  local output_file
  output_file="$(mktemp "${TMPDIR:-/tmp}/stacio-stability-swift.XXXXXX")"
  printf '\n$'
  printf ' %q' swift test --package-path "$ROOT_DIR" --filter "$filter"
  printf '\n'
  if ! swift test --package-path "$ROOT_DIR" --filter "$filter" 2>&1 | tee "$output_file"; then
    rm -f "$output_file"
    return 1
  fi
  if grep -Fq "No matching test cases" "$output_file"; then
    printf 'FAIL Swift test filter matched no tests: %s\n' "$filter" >&2
    rm -f "$output_file"
    return 1
  fi
  rm -f "$output_file"
}

printf 'Stacio core stability gate\n'
printf 'Repository: %s\n' "$ROOT_DIR"
printf 'Mode: %s\n' "$([[ "$FULL_GATE" == "1" ]] && printf 'full' || printf 'targeted')"

run_cmd swift build --package-path "$ROOT_DIR" --product StacioCLI
run_cmd cargo test --manifest-path "$ROOT_DIR/StacioCore/Cargo.toml"
run_cmd cargo check --manifest-path "$ROOT_DIR/StacioCore/Cargo.toml"

swift_filters=(
  AIAssistantPanelViewControllerTests
  AgentExecutionCoordinatorTests
  AgentTaskOrchestratorTests
  SSHBridgeTests
  SSHConnectionCoordinatorTests
  SavedSessionConnectionFlowTests
  SerialSessionCoordinatorTests
  FilesCoordinatorTests
  FilesViewControllerTests
  RemoteTextEditorViewControllerTests
  TransferQueueCoordinatorTests
  TransferQueueViewControllerTests
  TunnelsViewControllerTests
  MultiExecBridgeTests
  MultiExecCoordinatorTests
  WorkspaceLocalShellTests
  SessionSettingsViewControllerTests
)

for filter in "${swift_filters[@]}"; do
  run_swift_filter "$filter"
done

if [[ "$FULL_GATE" == "1" ]]; then
  run_cmd swift test --package-path "$ROOT_DIR"
  run_cmd "$ROOT_DIR/scripts/release-readiness.sh"
fi

if [[ "$SKIP_LIVE" == "1" ]]; then
  printf '\nSKIP live Linux SSH smoke: STACIO_STABILITY_SKIP_LIVE=1\n'
else
  run_cmd "$ROOT_DIR/scripts/smoke-live-ssh-linux.sh"
fi

printf '\nPASS Stacio core stability gate\n'
