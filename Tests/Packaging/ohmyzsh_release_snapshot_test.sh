#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FIXTURE_ROOT="$TMP_DIR/repo"
RELEASE_OUT="$TMP_DIR/release"
mkdir -p \
  "$FIXTURE_ROOT/scripts" \
  "$FIXTURE_ROOT/assets" \
  "$FIXTURE_ROOT/Stacio/Resources/Fonts"
cp "$ROOT_DIR/scripts/sync-ohmyzsh-resources.sh" "$FIXTURE_ROOT/scripts/"
cp -R "$ROOT_DIR/assets/oh-my-zsh" "$FIXTURE_ROOT/assets/oh-my-zsh"
cp \
  "$ROOT_DIR/Stacio/Resources/Fonts/JetBrainsMonoNLNerdFont-Regular.ttf" \
  "$ROOT_DIR/Stacio/Resources/Fonts/NerdFonts-OFL.txt" \
  "$FIXTURE_ROOT/Stacio/Resources/Fonts/"

"$FIXTURE_ROOT/scripts/sync-ohmyzsh-resources.sh" \
  --release \
  --version "2026.08.test" \
  --out "$RELEASE_OUT"

TARBALL="$RELEASE_OUT/snapshot.tar.gz"
MANIFEST="$RELEASE_OUT/manifest.json"
test -s "$TARBALL"
test -s "$MANIFEST"
tar -tzf "$TARBALL" | grep -Fxq './fonts/JetBrainsMonoNLNerdFont-Regular.ttf'
tar -tzf "$TARBALL" | grep -Fxq './fonts/NerdFonts-OFL.txt'

EXTRACTED="$TMP_DIR/extracted"
mkdir -p "$EXTRACTED"
tar -xzf "$TARBALL" -C "$EXTRACTED"
cmp -s \
  "$ROOT_DIR/Stacio/Resources/Fonts/NerdFonts-OFL.txt" \
  "$EXTRACTED/fonts/NerdFonts-OFL.txt"

python3 - "$TARBALL" "$MANIFEST" <<'PY'
import hashlib
import json
import os
import sys

tarball, manifest_path = sys.argv[1:]
with open(tarball, "rb") as stream:
    payload = stream.read()
with open(manifest_path, "r", encoding="utf-8") as stream:
    manifest = json.load(stream)

assert manifest == {
    "version": "2026.08.test",
    "sizeBytes": os.path.getsize(tarball),
    "sha256": hashlib.sha256(payload).hexdigest(),
    "downloadPath": "snapshot.tar.gz",
}
PY

echo "oh-my-zsh release snapshot test passed"
