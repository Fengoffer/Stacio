#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/accept-core-feature.sh"

output="$("$SCRIPT" --plan-only 2>&1)"
help_output="$("$SCRIPT" --help 2>&1)"

grep -Fq "SKIP real SSH shell acceptance" <<<"$output"
grep -Fq "SKIP real SCP list/upload/download acceptance" <<<"$output"
grep -Fq "SKIP real FTP list/upload/download acceptance" <<<"$output"
grep -Fq "PASS diagnostic redaction coverage entry" <<<"$output"
grep -Fq "PASS import session coverage entry" <<<"$output"
grep -Fq "PASS AI agent execution coverage entry: StacioApp AI panel, built-in fallback multi-step diagnostics" <<<"$output"
grep -Fq "PASS AI/settings UX coverage entry" <<<"$output"
grep -Fq "PASS terminal highlighting coverage entry: TerminalThemeImport plus TerminalPane/RemoteTerminalPane command hint filters" <<<"$output"
grep -Fq "kubectl mutating/session commands" <<<"$output"
grep -Fq "shell-wrapped risk and quoted diagnostic false-positive filters" <<<"$output"
grep -Fq "PASS device metrics compatibility coverage entry" <<<"$output"
grep -Fq "old Debian memory fallback" <<<"$output"
grep -Fq "Ubuntu/Debian snap loop filtering" <<<"$output"
grep -Fq "network filesystem filtering" <<<"$output"
grep -Fq "non-snap loop data disks" <<<"$output"
grep -Fq "PASS launch/package coverage entry: Tests/Packaging app, DMG, window, VNC adapter smoke scripts, and Workbench VNC credential launch filters" <<<"$output"
grep -Fq -- "--require-real" <<<"$help_output"
if grep -Fq 'Tests/Packaging/rdp_adapter_probe_smoke_test.sh' "$SCRIPT"; then
  echo "accept-core-feature should not reference removed RDP adapter smoke" >&2
  exit 1
fi
grep -Fq 'Tests/Packaging/vnc_adapter_tcp_smoke_test.sh' "$SCRIPT"
grep -Fq 'StacioAppTests.AIAssistantPanelViewControllerTests|StacioAppTests.AgentExecutionCoordinatorTests|StacioAppTests.AgentActionAuthorizerTests|StacioAppTests.AgentRealtimeFollowTests' "$SCRIPT"
grep -Fq 'StacioAgentBridgeTests.AgentBridgeProtocolTests' "$SCRIPT"
grep -Fq 'StacioAppTests.AppSettingsWindowControllerTests|StacioAppTests.TerminalThemeImportTests|StacioAppTests.TerminalPaneViewControllerTests/testLocalTerminalShowsEnhancedCommandHintForTypedOpsCommand' "$SCRIPT"
grep -Fq 'StacioAppTests.TerminalPaneViewControllerTests/testLocalTerminalCommandHintHighlightsKubectlMutatingSubcommands' "$SCRIPT"
grep -Fq 'StacioAppTests.RemoteTerminalPaneViewControllerTests/testRemoteTerminalShowsEnhancedCommandHintForTypedOpsCommandWithoutExtraInput' "$SCRIPT"
grep -Fq 'StacioAppTests.WorkbenchWindowControllerTests/testWorkbenchOpenSavedVNCSessionPassesSavedPasswordToPackagedAdapterWithoutLeakingIt|StacioAppTests.WorkbenchWindowControllerTests/testWorkbenchOpenSavedVNCSessionPromptsForMissingPasswordBeforeLaunchingAdapter|StacioAppTests.SessionSettingsViewControllerTests/testVNCProtocolStoresPasswordCredentialReferenceForAdapterLaunch|StacioAppTests.GraphicsRuntimeManagerTests' "$SCRIPT"

set +e
require_real_output="$("$SCRIPT" --require-real 2>&1)"
require_real_status=$?
set -e

if [[ "$require_real_status" -eq 0 ]]; then
  echo "expected --require-real to fail when real server env vars are missing" >&2
  exit 1
fi

grep -Fq "SKIP real SSH shell acceptance" <<<"$require_real_output"
grep -Fq "SKIP real SCP list/upload/download acceptance" <<<"$require_real_output"
grep -Fq "SKIP real FTP list/upload/download acceptance" <<<"$require_real_output"

set +e
require_real_configured_output="$(
  STACIO_ACCEPT_SSH_HOST=example \
  STACIO_ACCEPT_SSH_USER=user \
  STACIO_ACCEPT_SCP_REMOTE_DIR=/tmp \
  STACIO_ACCEPT_SCP_LOCAL_FILE=/tmp/file \
  STACIO_ACCEPT_FTP_HOST=example \
  STACIO_ACCEPT_FTP_USER=user \
  STACIO_ACCEPT_FTP_PASSWORD=secret \
  STACIO_ACCEPT_FTP_REMOTE_DIR=/tmp \
  STACIO_ACCEPT_FTP_LOCAL_FILE=/tmp/file \
  "$SCRIPT" --require-real 2>&1
)"
require_real_configured_status=$?
set -e

if [[ "$require_real_configured_status" -ne 0 ]]; then
  echo "expected --require-real to pass when required real server env vars are present" >&2
  exit 1
fi

grep -Fq "PASS real SSH shell acceptance configured" <<<"$require_real_configured_output"
grep -Fq "PASS real SCP list/upload/download acceptance configured" <<<"$require_real_configured_output"
grep -Fq "PASS real FTP list/upload/download acceptance configured" <<<"$require_real_configured_output"

REPORT_PATH="$(mktemp)"
set +e
report_output="$(
  STACIO_ACCEPT_SSH_HOST=example \
  STACIO_ACCEPT_SSH_USER=user \
  STACIO_ACCEPT_SCP_REMOTE_DIR=/tmp \
  STACIO_ACCEPT_SCP_LOCAL_FILE=/tmp/file \
  STACIO_ACCEPT_FTP_HOST=example \
  STACIO_ACCEPT_FTP_USER=user \
  STACIO_ACCEPT_FTP_PASSWORD=super-secret \
  STACIO_ACCEPT_FTP_REMOTE_DIR=/tmp \
  STACIO_ACCEPT_FTP_LOCAL_FILE=/tmp/file \
  "$SCRIPT" --plan-only --write-report "$REPORT_PATH" 2>&1
)"
report_status=$?
set -e

if [[ "$report_status" -ne 0 ]]; then
  echo "expected --write-report to succeed" >&2
  exit 1
fi

grep -Fq "Report written: $REPORT_PATH" <<<"$report_output"
grep -Fq "# Stacio Core Feature Acceptance Report" "$REPORT_PATH"
grep -Fq "Mode: plan-only" "$REPORT_PATH"
grep -Fq "| SSH shell | PASS | configured |" "$REPORT_PATH"
grep -Fq "| FTP list/upload/download | PASS | configured |" "$REPORT_PATH"
grep -Fq "STACIO_ACCEPT_FTP_PASSWORD=<set>" "$REPORT_PATH"
if grep -Fq "super-secret" "$REPORT_PATH"; then
  echo "acceptance report leaked FTP password" >&2
  exit 1
fi

echo "accept_core_feature_entrypoint_test passed"
