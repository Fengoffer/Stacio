#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAKE_BIN_DIR="$TMP_DIR/bin"
APP_DIR="$TMP_DIR/Stacio.app"
DMG_PATH="$TMP_DIR/out/Stacio.dmg"
LOG_FILE="$TMP_DIR/tool-calls.log"
MOUNT_DIR="$TMP_DIR/mount"
CUSTOM_BACKGROUND="$TMP_DIR/custom-dmg-background.png"

mkdir -p "$FAKE_BIN_DIR" "$APP_DIR/Contents/MacOS" "$(dirname "$DMG_PATH")" "$MOUNT_DIR"
touch "$APP_DIR/Contents/MacOS/Stacio"

python3 - "$CUSTOM_BACKGROUND" <<'PY'
import sys
from PIL import Image

Image.new("RGB", (1606, 979), (231, 44, 64)).save(sys.argv[1])
PY

cat >"$FAKE_BIN_DIR/hdiutil" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'hdiutil' >>"$STACIO_DMG_TEST_LOG"
for arg in "$@"; do
  printf ' %q' "$arg" >>"$STACIO_DMG_TEST_LOG"
done
printf '\n' >>"$STACIO_DMG_TEST_LOG"

if [[ "${1:-}" == "verify" ]]; then
  test -f "${2:-}"
  exit 0
fi

if [[ "${1:-}" == "info" ]]; then
  printf '<?xml version="1.0" encoding="UTF-8"?>\n'
  printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
  printf '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
  printf '<plist version="1.0"><dict><key>images</key><array>'
  if [[ -n "${STACIO_DMG_TEST_EXISTING_IMAGE_PATH:-}" ]]; then
    printf '<dict><key>image-path</key><string>%s</string>' "$STACIO_DMG_TEST_EXISTING_IMAGE_PATH"
    printf '<key>system-entities</key><array><dict><key>dev-entry</key><string>%s</string></dict></array></dict>' "${STACIO_DMG_TEST_EXISTING_DEV_ENTRY:-/dev/disk-test}"
  fi
  printf '</array></dict></plist>\n'
  exit 0
fi

if [[ "${1:-}" == "attach" ]]; then
  printf '<?xml version="1.0" encoding="UTF-8"?>\n'
  printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
  printf '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
  printf '<plist version="1.0"><dict><key>system-entities</key><array><dict>'
  printf '<key>mount-point</key><string>%s</string>' "$STACIO_DMG_TEST_MOUNT_DIR"
  printf '</dict></array></dict></plist>\n'
  exit 0
fi

if [[ "${1:-}" == "detach" ]]; then
  exit 0
fi

if [[ "${1:-}" == "create" && -n "${STACIO_DMG_EXPECT_BACKGROUND_SIZE:-}" ]]; then
  srcfolder=""
  previous=""
  for arg in "$@"; do
    if [[ "$previous" == "-srcfolder" ]]; then
      srcfolder="$arg"
    fi
    previous="$arg"
  done
  python3 - "$srcfolder/.background/background.png" "$STACIO_DMG_EXPECT_BACKGROUND_SIZE" <<'PY'
import sys
from PIL import Image

path, expected_size = sys.argv[1], sys.argv[2]
expected_width, expected_height = map(int, expected_size.split("x"))
image = Image.open(path).convert("RGB")
if image.size != (expected_width, expected_height):
    raise SystemExit(f"unexpected background size: {image.size}")
center = image.getpixel((expected_width // 2, expected_height // 2))
if center != (231, 44, 64):
    raise SystemExit(f"unexpected custom background center pixel: {center}")
PY
fi

if [[ "${1:-}" == "convert" ]]; then
  out=""
  previous=""
  for arg in "$@"; do
    if [[ "$previous" == "-o" ]]; then
      out="$arg"
    fi
    previous="$arg"
  done
  mkdir -p "$(dirname "$out")"
  printf 'fake dmg\n' >"$out"
  exit 0
fi

out="${@: -1}"
mkdir -p "$(dirname "$out")"
printf 'fake dmg\n' >"$out"
EOF
chmod +x "$FAKE_BIN_DIR/hdiutil"

cat >"$FAKE_BIN_DIR/osascript" <<'EOF'
#!/usr/bin/env bash
script="$(cat)"
printf 'osascript args' >>"$STACIO_DMG_TEST_LOG"
for arg in "$@"; do
  printf ' %q' "$arg" >>"$STACIO_DMG_TEST_LOG"
done
printf '\n' >>"$STACIO_DMG_TEST_LOG"
printf 'osascript\n%s\n' "$script" >>"$STACIO_DMG_TEST_LOG"
if [[ "${STACIO_DMG_TEST_OSASCRIPT_FAIL:-0}" == "1" ]]; then
  printf 'layout failed\n' >&2
  exit 7
fi
[[ "$script" == *'background picture'* ]]
[[ "$script" == *'open targetFolder'* ]]
[[ "$script" == *'Stacio.app'* ]]
[[ "$script" == *'Applications'* ]]
printf 'finder layout\n' >"$STACIO_DMG_TEST_MOUNT_DIR/.DS_Store"
EOF
chmod +x "$FAKE_BIN_DIR/osascript"

cat >"$FAKE_BIN_DIR/SetFile" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$FAKE_BIN_DIR/SetFile"

PATH="$FAKE_BIN_DIR:$PATH" \
STACIO_DMG_TEST_LOG="$LOG_FILE" \
STACIO_DMG_TEST_MOUNT_DIR="$MOUNT_DIR" \
"$ROOT_DIR/scripts/package-dmg.sh" "$APP_DIR" "$DMG_PATH"

test -f "$DMG_PATH"
test -f "$MOUNT_DIR/.DS_Store"
grep -Fq -- "hdiutil create" "$LOG_FILE"
grep -Fq -- "-volname Stacio" "$LOG_FILE"
grep -Fq -- "-format UDRW" "$LOG_FILE"
grep -Fq -- "hdiutil attach" "$LOG_FILE"
grep -Fq -- "-plist" "$LOG_FILE"
grep -Fq -- "-format UDZO" "$LOG_FILE"
grep -Fq -- "$DMG_PATH" "$LOG_FILE"
grep -Fq -- "hdiutil verify $DMG_PATH" "$LOG_FILE"
grep -Fq -- "background picture" "$LOG_FILE"
grep -Fq -- "set icon size of theViewOptions to iconSize" "$LOG_FILE"
grep -Fq -- "osascript args - Stacio" "$LOG_FILE"
grep -Fq -- " 128 180 415 778 415 background.png" "$LOG_FILE"

EXISTING_LOG_FILE="$TMP_DIR/existing-mounted-tool-calls.log"
PATH="$FAKE_BIN_DIR:$PATH" \
STACIO_DMG_TEST_LOG="$EXISTING_LOG_FILE" \
STACIO_DMG_TEST_MOUNT_DIR="$MOUNT_DIR" \
STACIO_DMG_TEST_EXISTING_IMAGE_PATH="$TMP_DIR/existing-mounted.dmg" \
STACIO_DMG_TEST_EXISTING_DEV_ENTRY="/dev/disk-test" \
STACIO_DMG_SKIP_FINDER_LAYOUT=1 \
"$ROOT_DIR/scripts/package-dmg.sh" "$APP_DIR" "$TMP_DIR/existing-mounted.dmg" >"$TMP_DIR/existing-mounted.out"

grep -Fq -- "hdiutil detach /dev/disk-test" "$EXISTING_LOG_FILE"
grep -Fq -- "hdiutil verify $TMP_DIR/existing-mounted.dmg" "$EXISTING_LOG_FILE"

CUSTOM_LOG_FILE="$TMP_DIR/custom-background-tool-calls.log"
PATH="$FAKE_BIN_DIR:$PATH" \
STACIO_DMG_TEST_LOG="$CUSTOM_LOG_FILE" \
STACIO_DMG_TEST_MOUNT_DIR="$MOUNT_DIR" \
STACIO_DMG_BACKGROUND_PATH="$CUSTOM_BACKGROUND" \
STACIO_DMG_EXPECT_BACKGROUND_SIZE=960x720 \
STACIO_DMG_SKIP_FINDER_LAYOUT=1 \
"$ROOT_DIR/scripts/package-dmg.sh" "$APP_DIR" "$TMP_DIR/custom-background.dmg" >"$TMP_DIR/custom-background.out"

test -f "$TMP_DIR/custom-background.dmg"
grep -Fq -- "hdiutil verify $TMP_DIR/custom-background.dmg" "$CUSTOM_LOG_FILE"

SKIP_LOG_FILE="$TMP_DIR/skip-tool-calls.log"
rm -f "$MOUNT_DIR/.DS_Store"
PATH="$FAKE_BIN_DIR:$PATH" \
STACIO_DMG_TEST_LOG="$SKIP_LOG_FILE" \
STACIO_DMG_TEST_MOUNT_DIR="$MOUNT_DIR" \
STACIO_DMG_SKIP_FINDER_LAYOUT=1 \
"$ROOT_DIR/scripts/package-dmg.sh" "$APP_DIR" "$TMP_DIR/skip-layout.dmg" >"$TMP_DIR/skip-layout.out"

test -f "$TMP_DIR/skip-layout.dmg"
grep -Fq -- "SKIP Finder DMG layout" "$TMP_DIR/skip-layout.out"
if grep -Fq -- "osascript" "$SKIP_LOG_FILE"; then
  echo "expected Finder layout skip to avoid osascript" >&2
  exit 1
fi
if [[ -f "$MOUNT_DIR/.DS_Store" ]]; then
  echo "expected Finder layout skip to avoid creating .DS_Store" >&2
  exit 1
fi
grep -Fq -- "hdiutil verify $TMP_DIR/skip-layout.dmg" "$SKIP_LOG_FILE"

if PATH="$FAKE_BIN_DIR:$PATH" \
  STACIO_DMG_TEST_LOG="$LOG_FILE" \
  STACIO_DMG_TEST_MOUNT_DIR="$MOUNT_DIR" \
  STACIO_DMG_TEST_OSASCRIPT_FAIL=1 \
  "$ROOT_DIR/scripts/package-dmg.sh" "$APP_DIR" "$TMP_DIR/layout-failure.dmg" >"$TMP_DIR/layout-failure.out" 2>&1; then
  echo "expected Finder layout failure to fail packaging" >&2
  exit 1
fi
grep -Fq -- "failed to apply Finder DMG layout" "$TMP_DIR/layout-failure.out"

if "$ROOT_DIR/scripts/package-dmg.sh" "$TMP_DIR/missing.app" "$TMP_DIR/missing.dmg" >"$TMP_DIR/missing.out" 2>&1; then
  echo "expected missing app to fail" >&2
  exit 1
fi
grep -Fq -- "app bundle missing" "$TMP_DIR/missing.out"

echo "package_dmg_test passed"
