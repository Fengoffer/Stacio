#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

has_fixture=0
if [[ -n "${STACIO_SSH_FIXTURE_HOST:-}" ]] \
  && [[ -n "${STACIO_SSH_FIXTURE_USERNAME:-}" ]] \
  && { [[ -n "${STACIO_SSH_FIXTURE_PASSWORD:-}" ]] || [[ -n "${STACIO_SSH_FIXTURE_PRIVATE_KEY:-}" ]]; }; then
  has_fixture=1
fi

if [[ "$has_fixture" != "1" ]]; then
  echo "SKIP live SSH fixture not configured"
  echo "Set STACIO_SSH_FIXTURE_HOST, STACIO_SSH_FIXTURE_USERNAME, and STACIO_SSH_FIXTURE_PASSWORD or STACIO_SSH_FIXTURE_PRIVATE_KEY."
  echo "Set STACIO_SSH_FIXTURE_REMOTE_DIR to also exercise remote Files and SCP paths."
  exit 0
fi

echo "Stacio live Linux stability smoke"
echo "Host: ${STACIO_SSH_FIXTURE_HOST}"
echo "User: ${STACIO_SSH_FIXTURE_USERNAME}"
echo "Port: ${STACIO_SSH_FIXTURE_PORT:-22}"

run_cmd() {
  printf '\n$'
  printf ' %q' "$@"
  printf '\n'
  "$@"
}

run_cargo_test() {
  local test_name="$1"
  run_cmd cargo test \
    --manifest-path "$ROOT_DIR/StacioCore/Cargo.toml" \
    "$test_name" \
    -- --nocapture
}

run_cargo_test connects_to_gated_ssh_fixture_when_configured
run_cargo_test opens_shell_channel_and_reads_marker_with_gated_fixture_when_configured
run_cargo_test shell_channel_reports_osc7_after_bootstrap_with_gated_fixture_when_configured

if [[ -n "${STACIO_SSH_FIXTURE_REMOTE_DIR:-}" ]]; then
  run_cargo_test live_remote_listing_handles_linux_names_with_gated_fixture_when_configured
  run_cargo_test reads_and_writes_remote_file_bytes_with_gated_ssh_fixture_when_configured
  run_cargo_test uploads_and_downloads_with_gated_ssh_fixture_when_configured
  run_cargo_test downloads_directory_recursively_with_gated_ssh_fixture_when_configured
  run_cargo_test upload_permission_failure_with_gated_ssh_fixture_maps_to_diagnostic_code
else
  echo "SKIP remote Files/SCP fixture checks: STACIO_SSH_FIXTURE_REMOTE_DIR is not set"
fi

run_cmd swift test \
  --package-path "$ROOT_DIR" \
  --filter 'SavedSessionConnectionFlowTests/testSavedSessionOpensRealEmbeddedShellWithGatedSSHFixtureWhenConfigured'

echo "PASS live Linux stability smoke"
