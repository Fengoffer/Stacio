#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE=""
REPORT_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      MODE="--help"
      shift
      ;;
    --plan-only|--run-local|--require-real)
      if [[ -n "$MODE" && "$MODE" != "--help" ]]; then
        printf 'FAIL multiple modes provided: %s and %s\n' "$MODE" "$1" >&2
        exit 2
      fi
      MODE="$1"
      shift
      ;;
    --write-report)
      if [[ -z "${2:-}" ]]; then
        printf 'FAIL --write-report requires a path\n' >&2
        exit 2
      fi
      REPORT_PATH="$2"
      shift 2
      ;;
    *)
      printf 'FAIL unknown argument: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

if [[ "$MODE" == "--help" ]]; then
  cat <<'EOF'
Usage: scripts/accept-core-feature.sh [--plan-only|--run-local|--require-real] [--write-report PATH]

Creates a gated acceptance entrypoint for Stacio core file features.

Default and --plan-only:
  Print PASS/SKIP coverage status without contacting any server.

--run-local:
  Run Stacio-owned cargo/swift/package/adapter smoke filters. This still
  does not call local ssh/scp/sftp/rsync/ftp/telnet clients.

--require-real:
  Keep the normal PASS/SKIP report, but exit non-zero if any real SSH, SCP,
  or FTP gate is still SKIP because required environment variables are missing.

Real-server acceptance is intentionally manual through the Stacio app until
dedicated product-level integration tests exist. Configure the variables named
in docs/development/core-feature-acceptance.md before a real acceptance pass.

--write-report PATH:
  Write a Markdown acceptance report with PASS/SKIP/FAIL gate status and
  redacted environment readiness. Secret values are never written.
EOF
  exit 0
fi

RUN_LOCAL=0
REQUIRE_REAL=0
if [[ "$MODE" == "--run-local" || "${STACIO_ACCEPTANCE_RUN_LOCAL:-}" == "1" ]]; then
  RUN_LOCAL=1
fi
if [[ "$MODE" == "--require-real" ]]; then
  REQUIRE_REAL=1
fi

failures=0
warnings=0
real_gate_skips=0
acceptance_rows=()

pass() {
  printf 'PASS %s\n' "$1"
}

skip() {
  printf 'SKIP %s\n' "$1"
}

skip_real_gate() {
  real_gate_skips=$((real_gate_skips + 1))
  skip "$1"
  if (( REQUIRE_REAL == 1 )); then
    fail "$2"
  fi
}

warn() {
  warnings=$((warnings + 1))
  printf 'WARN %s\n' "$1"
}

fail() {
  failures=$((failures + 1))
  printf 'FAIL %s\n' "$1" >&2
}

record_acceptance_row() {
  local capability="$1"
  local status="$2"
  local detail="$3"
  acceptance_rows+=("$capability|$status|$detail")
}

require_command() {
  local command_name="$1"
  if command -v "$command_name" >/dev/null 2>&1; then
    pass "tool available: $command_name"
  else
    fail "required tool missing for local Stacio tests: $command_name"
  fi
}

has_all_vars() {
  local name
  for name in "$@"; do
    if [[ -z "${!name:-}" ]]; then
      return 1
    fi
  done
}

run_cmd() {
  printf '\n$'
  printf ' %q' "$@"
  printf '\n'
  "$@"
}

print_header() {
  printf 'Stacio core feature acceptance gate\n'
  if (( RUN_LOCAL == 1 )); then
    printf 'Mode: run-local\n'
  elif (( REQUIRE_REAL == 1 )); then
    printf 'Mode: require-real\n'
  else
    printf 'Mode: plan-only\n'
  fi
  printf 'Repository: %s\n\n' "$ROOT_DIR"
}

check_real_server_gates() {
  if has_all_vars STACIO_ACCEPT_SSH_HOST STACIO_ACCEPT_SSH_USER; then
    pass "real SSH shell acceptance configured"
    record_acceptance_row "SSH shell" "PASS" "configured"
  else
    record_acceptance_row "SSH shell" "SKIP" "missing STACIO_ACCEPT_SSH_HOST or STACIO_ACCEPT_SSH_USER"
    skip_real_gate \
      "real SSH shell acceptance: set STACIO_ACCEPT_SSH_HOST and STACIO_ACCEPT_SSH_USER" \
      "real SSH shell acceptance requires STACIO_ACCEPT_SSH_HOST and STACIO_ACCEPT_SSH_USER"
  fi

  if has_all_vars STACIO_ACCEPT_SSH_HOST STACIO_ACCEPT_SSH_USER STACIO_ACCEPT_SCP_REMOTE_DIR STACIO_ACCEPT_SCP_LOCAL_FILE; then
    pass "real SCP list/upload/download acceptance configured"
    record_acceptance_row "SCP list/upload/download" "PASS" "configured"
  else
    record_acceptance_row "SCP list/upload/download" "SKIP" "missing SSH/SCP acceptance variables"
    skip_real_gate \
      "real SCP list/upload/download acceptance: set STACIO_ACCEPT_SSH_HOST, STACIO_ACCEPT_SSH_USER, STACIO_ACCEPT_SCP_REMOTE_DIR, STACIO_ACCEPT_SCP_LOCAL_FILE" \
      "real SCP list/upload/download acceptance requires STACIO_ACCEPT_SSH_HOST, STACIO_ACCEPT_SSH_USER, STACIO_ACCEPT_SCP_REMOTE_DIR, and STACIO_ACCEPT_SCP_LOCAL_FILE"
  fi

  if has_all_vars STACIO_ACCEPT_FTP_HOST STACIO_ACCEPT_FTP_USER STACIO_ACCEPT_FTP_PASSWORD STACIO_ACCEPT_FTP_REMOTE_DIR STACIO_ACCEPT_FTP_LOCAL_FILE; then
    pass "real FTP list/upload/download acceptance configured"
    record_acceptance_row "FTP list/upload/download" "PASS" "configured"
  else
    record_acceptance_row "FTP list/upload/download" "SKIP" "missing FTP acceptance variables"
    skip_real_gate \
      "real FTP list/upload/download acceptance: set STACIO_ACCEPT_FTP_HOST, STACIO_ACCEPT_FTP_USER, STACIO_ACCEPT_FTP_PASSWORD, STACIO_ACCEPT_FTP_REMOTE_DIR, STACIO_ACCEPT_FTP_LOCAL_FILE" \
      "real FTP list/upload/download acceptance requires STACIO_ACCEPT_FTP_HOST, STACIO_ACCEPT_FTP_USER, STACIO_ACCEPT_FTP_PASSWORD, STACIO_ACCEPT_FTP_REMOTE_DIR, and STACIO_ACCEPT_FTP_LOCAL_FILE"
  fi
}

report_var_state() {
  local name="$1"
  if [[ -n "${!name:-}" ]]; then
    printf '%s=<set>\n' "$name"
  else
    printf '%s=<missing>\n' "$name"
  fi
}

write_acceptance_report() {
  local path="$1"
  local mode_label="plan-only"
  if (( RUN_LOCAL == 1 )); then
    mode_label="run-local"
  elif (( REQUIRE_REAL == 1 )); then
    mode_label="require-real"
  fi
  mkdir -p "$(dirname "$path")"
  {
    printf '# Stacio Core Feature Acceptance Report\n\n'
    printf 'Mode: %s\n\n' "$mode_label"
    printf 'Repository: %s\n\n' "$ROOT_DIR"
    printf 'Summary: %d failure(s), %d warning(s)\n\n' "$failures" "$warnings"
    printf '## Real Server Gates\n\n'
    printf '| Capability | Status | Detail |\n'
    printf '| --- | --- | --- |\n'
    local row capability status detail
    for row in "${acceptance_rows[@]}"; do
      IFS='|' read -r capability status detail <<<"$row"
      printf '| %s | %s | %s |\n' "$capability" "$status" "$detail"
    done
    printf '\n## Redacted Environment\n\n'
    for name in \
      STACIO_ACCEPT_SSH_HOST \
      STACIO_ACCEPT_SSH_PORT \
      STACIO_ACCEPT_SSH_USER \
      STACIO_ACCEPT_SSH_AUTH \
      STACIO_ACCEPT_SSH_PASSWORD \
      STACIO_ACCEPT_SSH_KEY_PATH \
      STACIO_ACCEPT_SSH_KEY_PASSPHRASE \
      STACIO_ACCEPT_SCP_REMOTE_DIR \
      STACIO_ACCEPT_SCP_LOCAL_FILE \
      STACIO_ACCEPT_FTP_HOST \
      STACIO_ACCEPT_FTP_PORT \
      STACIO_ACCEPT_FTP_USER \
      STACIO_ACCEPT_FTP_PASSWORD \
      STACIO_ACCEPT_FTP_REMOTE_DIR \
      STACIO_ACCEPT_FTP_LOCAL_FILE \
      STACIO_ACCEPT_APP_PATH \
      STACIO_ACCEPT_DMG_PATH; do
      report_var_state "$name"
    done
    printf '\n## Manual Acceptance Notes\n\n'
    printf -- '- Run product-level SSH/SCP/FTP actions through Stacio.app, not local protocol clients.\n'
    printf -- '- Record host OS, auth method, network condition, commit, artifact path, and sanitized diagnostics.\n'
    printf -- '- Keep passwords, tokens, private key contents, and passphrases out of this report.\n'
  } >"$path"
  printf 'Report written: %s\n' "$path"
}

print_coverage_entries() {
  pass "SSH shell coverage entry: StacioCore live shell tests and StacioApp RemoteSSHSessionCoordinator/SavedSessionConnectionFlow filters"
  pass "SCP list/upload/download coverage entry: StacioCore scp and libssh2 listing tests plus StacioApp FilesCoordinator/Transfer filters"
  pass "FTP list/upload/download coverage entry: StacioCore ftp_control tests plus StacioApp FTP FilesCoordinator/Transfer filters"
  pass "diagnostic redaction coverage entry: StacioCore diagnostics/ssh redaction tests and StacioApp diagnostics/file-error filters"
  pass "import session coverage entry: StacioCore import_service tests and StacioApp SessionImportCoordinator filters"
  pass "AI agent execution coverage entry: StacioApp AI panel, built-in fallback multi-step diagnostics, approval policy, execution coordinator, realtime follow, and StacioAgentBridge protocol filters"
  pass "AI/settings UX coverage entry: AppSettingsWindowController grouped settings, AI provider compatibility, runtime policy, and task workspace filters"
  pass "terminal highlighting coverage entry: TerminalThemeImport plus TerminalPane/RemoteTerminalPane command hint filters for docker, kubectl mutating/session commands, systemd, package managers, themes, shell-wrapped risk and quoted diagnostic false-positive filters"
  pass "device metrics compatibility coverage entry: StacioCore device_metrics_service and StacioApp dashboard filters for mainstream Linux probes including old Debian memory fallback, Ubuntu/Debian snap loop filtering, network filesystem filtering, and non-snap loop data disks"
  pass "launch/package coverage entry: Tests/Packaging app, DMG, window, VNC adapter smoke scripts, and Workbench VNC credential launch filters"
}

run_local_filters() {
  require_command cargo
  require_command swift
  require_command bash

  if (( failures > 0 )); then
    return
  fi

  run_cmd cargo test --manifest-path "$ROOT_DIR/StacioCore/Cargo.toml" live_shell
  run_cmd cargo test --manifest-path "$ROOT_DIR/StacioCore/Cargo.toml" scp
  run_cmd cargo test --manifest-path "$ROOT_DIR/StacioCore/Cargo.toml" ftp_control
  run_cmd cargo test --manifest-path "$ROOT_DIR/StacioCore/Cargo.toml" import_service
  run_cmd cargo test --manifest-path "$ROOT_DIR/StacioCore/Cargo.toml" diagnostic
  run_cmd cargo test --manifest-path "$ROOT_DIR/StacioCore/Cargo.toml" device_metrics_service

  run_cmd swift test --package-path "$ROOT_DIR" --filter StacioAppTests.RemoteSSHSessionCoordinatorTests
  run_cmd swift test --package-path "$ROOT_DIR" --filter StacioAppTests.SavedSessionConnectionFlowTests
  run_cmd swift test --package-path "$ROOT_DIR" --filter StacioAppTests.FilesCoordinatorTests
  run_cmd swift test --package-path "$ROOT_DIR" --filter StacioAppTests.TransferQueueCoordinatorTests
  run_cmd swift test --package-path "$ROOT_DIR" --filter StacioAppTests.DiagnosticsViewControllerTests
  run_cmd swift test --package-path "$ROOT_DIR" --filter StacioAppTests.SessionImportCoordinatorTests
  run_cmd swift test --package-path "$ROOT_DIR" --filter "StacioAppTests.AIAssistantPanelViewControllerTests|StacioAppTests.AgentExecutionCoordinatorTests|StacioAppTests.AgentActionAuthorizerTests|StacioAppTests.AgentRealtimeFollowTests"
  run_cmd swift test --package-path "$ROOT_DIR" --filter StacioAgentBridgeTests.AgentBridgeProtocolTests
  run_cmd swift test --package-path "$ROOT_DIR" --filter "StacioAppTests.AppSettingsWindowControllerTests|StacioAppTests.TerminalThemeImportTests|StacioAppTests.TerminalPaneViewControllerTests/testLocalTerminalShowsEnhancedCommandHintForTypedOpsCommand|StacioAppTests.TerminalPaneViewControllerTests/testLocalTerminalCommandHintHighlightsKubectlMutatingSubcommands|StacioAppTests.TerminalPaneViewControllerTests/testLocalTerminalDoesNotShowCommandHintWhenEnhancedHighlightingIsDisabled|StacioAppTests.RemoteTerminalPaneViewControllerTests/testRemoteTerminalShowsEnhancedCommandHintForTypedOpsCommandWithoutExtraInput|StacioAppTests.DeviceMetricsDashboardViewControllerTests"
  run_cmd swift test --package-path "$ROOT_DIR" --filter "StacioAppTests.WorkbenchWindowControllerTests/testWorkbenchOpenSavedVNCSessionPassesSavedPasswordToPackagedAdapterWithoutLeakingIt|StacioAppTests.WorkbenchWindowControllerTests/testWorkbenchOpenSavedVNCSessionPromptsForMissingPasswordBeforeLaunchingAdapter|StacioAppTests.SessionSettingsViewControllerTests/testVNCProtocolStoresPasswordCredentialReferenceForAdapterLaunch|StacioAppTests.GraphicsRuntimeManagerTests"

  run_cmd bash "$ROOT_DIR/Tests/Packaging/package_app_test.sh"
  run_cmd bash "$ROOT_DIR/Tests/Packaging/package_dmg_test.sh"
  run_cmd bash "$ROOT_DIR/Tests/Packaging/release_readiness_test.sh"
  run_cmd bash "$ROOT_DIR/Tests/Packaging/smoke_launch_window_test.sh"
  run_cmd bash "$ROOT_DIR/Tests/Packaging/vnc_adapter_tcp_smoke_test.sh"
}

print_header
if (( REQUIRE_REAL == 1 )); then
  printf 'Real server gates: required\n'
else
  printf 'Real server gates: optional\n'
fi
check_real_server_gates
print_coverage_entries

if (( RUN_LOCAL == 1 )); then
  run_local_filters
else
  skip "local Stacio test filters: run scripts/accept-core-feature.sh --run-local to execute them"
fi

printf '\nSummary: %d failure(s), %d warning(s)\n' "$failures" "$warnings"
if (( REQUIRE_REAL == 1 && real_gate_skips > 0 )); then
  printf 'Real server configuration missing for %d gate(s)\n' "$real_gate_skips"
fi
if [[ -n "$REPORT_PATH" ]]; then
  write_acceptance_report "$REPORT_PATH"
fi
if (( failures > 0 )); then
  exit 1
fi
