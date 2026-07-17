#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKOUT_DIR="${1:?SwiftTerm checkout directory is required}"
PATCH_FILE="${2:-$SCRIPT_DIR/patches/swiftterm-macos-app-resources.patch}"
SOURCE_FILE="$CHECKOUT_DIR/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift"
PATCH_MARKER="Stacio macOS packages keep SwiftPM resources under Contents/Resources."

if [[ ! -f "$SOURCE_FILE" ]]; then
  echo "SwiftTerm Metal renderer source not found: $SOURCE_FILE" >&2
  exit 1
fi

rm -f "$SOURCE_FILE.orig"

if grep -Fq "$PATCH_MARKER" "$SOURCE_FILE"; then
  exit 0
fi

if [[ ! -f "$PATCH_FILE" ]]; then
  echo "SwiftTerm resource patch not found: $PATCH_FILE" >&2
  exit 1
fi

/usr/bin/patch --batch --forward -p1 -d "$CHECKOUT_DIR" <"$PATCH_FILE"
rm -f "$SOURCE_FILE.orig"

if ! grep -Fq "$PATCH_MARKER" "$SOURCE_FILE"; then
  echo "SwiftTerm resource patch did not update $SOURCE_FILE" >&2
  exit 1
fi
