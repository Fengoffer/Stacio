#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

if env -i \
  PATH="$PATH" \
  HOME="$HOME" \
  "$ROOT_DIR/scripts/smoke-live-ssh-linux.sh" >"$TMP_DIR/no-fixture.out"
then
  grep -Fq "SKIP live SSH fixture not configured" "$TMP_DIR/no-fixture.out"
else
  echo "expected missing fixture to skip successfully" >&2
  cat "$TMP_DIR/no-fixture.out" >&2
  exit 1
fi

if rg -n '\b(ssh|scp|sftp|rsync)\b' "$ROOT_DIR/scripts/smoke-live-ssh-linux.sh"; then
  echo "live SSH stability smoke must use Stacio internal bridges, not local transfer/ssh commands" >&2
  exit 1
fi

echo "live_ssh_linux_stability_test passed"
