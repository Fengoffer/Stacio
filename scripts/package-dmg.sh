#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${1:-$ROOT_DIR/dist/Stacio.app}"
DMG_PATH="${2:-$ROOT_DIR/dist/Stacio.dmg}"
VOLUME_NAME="${STACIO_DMG_VOLUME_NAME:-Stacio}"
WINDOW_WIDTH="${STACIO_DMG_WINDOW_WIDTH:-960}"
WINDOW_HEIGHT="${STACIO_DMG_WINDOW_HEIGHT:-720}"
ICON_SIZE="${STACIO_DMG_ICON_SIZE:-128}"
APP_ICON_X="${STACIO_DMG_APP_ICON_X:-180}"
APP_ICON_Y="${STACIO_DMG_APP_ICON_Y:-415}"
APPLICATIONS_ICON_X="${STACIO_DMG_APPLICATIONS_ICON_X:-778}"
APPLICATIONS_ICON_Y="${STACIO_DMG_APPLICATIONS_ICON_Y:-415}"
SKIP_FINDER_LAYOUT="${STACIO_DMG_SKIP_FINDER_LAYOUT:-0}"
DEFAULT_BACKGROUND_PATH="$ROOT_DIR/packaging/dmg-background.png"
CUSTOM_BACKGROUND_PATH="${STACIO_DMG_BACKGROUND_PATH:-$DEFAULT_BACKGROUND_PATH}"
BACKGROUND_NAME="background.png"
STAGING_DIR=""
RW_DMG_PATH=""
MOUNT_DIR=""

fail() {
  printf 'FAIL %s\n' "$1" >&2
  exit 1
}

cleanup() {
  if [[ -n "$MOUNT_DIR" && -d "$MOUNT_DIR" ]]; then
    hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || true
  fi
  if [[ -n "$STAGING_DIR" ]]; then
    rm -rf "$STAGING_DIR"
  fi
  if [[ -n "$RW_DMG_PATH" ]]; then
    rm -f "$RW_DMG_PATH"
  fi
}
trap cleanup EXIT

detach_existing_dmg_mounts() {
  local target_path="$1"
  local info_plist
  info_plist="$(mktemp)"
  hdiutil info -plist > "$info_plist"
  local detach_targets
  detach_targets="$(python3 - "$target_path" "$info_plist" <<'PY'
import os
import plistlib
import sys

target = os.path.realpath(sys.argv[1])
with open(sys.argv[2], "rb") as handle:
    payload = plistlib.load(handle)

for image in payload.get("images", []):
    image_path = image.get("image-path")
    if not image_path or os.path.realpath(image_path) != target:
        continue
    entities = image.get("system-entities", [])
    mount_points = [entity.get("mount-point") for entity in entities if entity.get("mount-point")]
    if mount_points:
        for mount_point in mount_points:
            print(mount_point)
        continue
    for entity in entities:
        dev_entry = entity.get("dev-entry")
        if dev_entry:
            print(dev_entry)
            break
PY
)"
  rm -f "$info_plist"

  local target
  while IFS= read -r target; do
    [[ -n "$target" ]] || continue
    hdiutil detach "$target" >/dev/null
  done <<< "$detach_targets"
}

command -v hdiutil >/dev/null 2>&1 || fail "hdiutil not found; package-dmg.sh requires macOS hdiutil"
command -v python3 >/dev/null 2>&1 || fail "python3 not found; package-dmg.sh requires python3 to prepare the DMG background"
[[ -d "$APP_DIR" ]] || fail "app bundle missing: $APP_DIR"

mkdir -p "$(dirname "$DMG_PATH")"
detach_existing_dmg_mounts "$DMG_PATH"
rm -f "$DMG_PATH"

STAGING_DIR="$(mktemp -d)"
RW_DMG_PATH="$STAGING_DIR/Stacio-rw.dmg"
DMG_ROOT="$STAGING_DIR/root"
BACKGROUND_DIR="$DMG_ROOT/.background"
BACKGROUND_OUTPUT="$BACKGROUND_DIR/$BACKGROUND_NAME"
mkdir -p "$BACKGROUND_DIR"

cp -R "$APP_DIR" "$DMG_ROOT/Stacio.app"
ln -s /Applications "$DMG_ROOT/Applications"

if [[ -n "$CUSTOM_BACKGROUND_PATH" ]]; then
  [[ -f "$CUSTOM_BACKGROUND_PATH" ]] || fail "custom DMG background missing: $CUSTOM_BACKGROUND_PATH"
  python3 - "$CUSTOM_BACKGROUND_PATH" "$BACKGROUND_OUTPUT" "$WINDOW_WIDTH" "$WINDOW_HEIGHT" <<'PY'
import sys
from PIL import Image, ImageOps

source_path = sys.argv[1]
output_path = sys.argv[2]
width = int(sys.argv[3])
height = int(sys.argv[4])

source = Image.open(source_path).convert("RGB")
resample = getattr(Image, "Resampling", Image).LANCZOS
image = ImageOps.fit(source, (width, height), method=resample, centering=(0.5, 0.5))
image.save(output_path)
PY
else
  python3 - "$BACKGROUND_OUTPUT" "$WINDOW_WIDTH" "$WINDOW_HEIGHT" "$APP_ICON_X" "$APP_ICON_Y" "$APPLICATIONS_ICON_X" "$APPLICATIONS_ICON_Y" <<'PY'
import sys
from PIL import Image, ImageDraw, ImageFont

path = sys.argv[1]
width = int(sys.argv[2])
height = int(sys.argv[3])
app_icon_x = int(sys.argv[4])
app_icon_y = int(sys.argv[5])
applications_icon_x = int(sys.argv[6])
applications_icon_y = int(sys.argv[7])
image = Image.new("RGB", (width, height), (247, 248, 250))
draw = ImageDraw.Draw(image)

def font(size, bold=False):
    candidates = [
        "/System/Library/Fonts/PingFang.ttc",
        "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
    ]
    for candidate in candidates:
        try:
            return ImageFont.truetype(candidate, size)
        except Exception:
            continue
    return ImageFont.load_default()

title_font = font(30, True)
body_font = font(18)
caption_font = font(14)

draw.rounded_rectangle((24, 24, width - 24, height - 24), radius=28, fill=(255, 255, 255), outline=(220, 226, 235), width=2)
title = "Stacio"
instruction = "拖动 Stacio.app 到 Applications 完成安装"
title_box = draw.textbbox((0, 0), title, font=title_font)
instruction_box = draw.textbbox((0, 0), instruction, font=body_font)
draw.text(((width - (title_box[2] - title_box[0])) / 2, 42), title, font=title_font, fill=(30, 42, 58))
draw.text(((width - (instruction_box[2] - instruction_box[0])) / 2, 84), instruction, font=body_font, fill=(73, 84, 99))

left_center = (app_icon_x, app_icon_y)
right_center = (applications_icon_x, applications_icon_y)
draw.line((left_center[0] + 78, left_center[1], right_center[0] - 92, right_center[1]), fill=(76, 121, 255), width=8)
arrow_tip = (right_center[0] - 72, right_center[1])
draw.polygon([
    arrow_tip,
    (arrow_tip[0] - 30, arrow_tip[1] - 20),
    (arrow_tip[0] - 30, arrow_tip[1] + 20),
], fill=(76, 121, 255))

draw.text((42, height - 62), "首次打开如遇 macOS 安全提示，请在系统设置中允许打开。", font=caption_font, fill=(105, 116, 132))

image.save(path)
PY
fi

hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$DMG_ROOT" \
  -ov \
  -format UDRW \
  "$RW_DMG_PATH"

ATTACH_PLIST="$STAGING_DIR/attach.plist"
hdiutil attach "$RW_DMG_PATH" -readwrite -noverify -noautoopen -plist > "$ATTACH_PLIST"
MOUNT_DIR="$(python3 - "$ATTACH_PLIST" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as handle:
    payload = plistlib.load(handle)

for entity in payload.get("system-entities", []):
    mount_point = entity.get("mount-point")
    if mount_point:
        print(mount_point)
        break
PY
)"
[[ -n "$MOUNT_DIR" && -d "$MOUNT_DIR" ]] || fail "failed to mount read-write DMG"

if [[ "$SKIP_FINDER_LAYOUT" == "1" || "$SKIP_FINDER_LAYOUT" == "true" ]]; then
  printf 'SKIP Finder DMG layout by STACIO_DMG_SKIP_FINDER_LAYOUT=%s\n' "$SKIP_FINDER_LAYOUT"
elif ! osascript - "$VOLUME_NAME" "$MOUNT_DIR" "$WINDOW_WIDTH" "$WINDOW_HEIGHT" "$ICON_SIZE" "$APP_ICON_X" "$APP_ICON_Y" "$APPLICATIONS_ICON_X" "$APPLICATIONS_ICON_Y" "$BACKGROUND_NAME" <<'OSA' >/dev/null; then
on run argv
  set volumeName to item 1 of argv
  set mountPath to item 2 of argv
  set windowWidth to (item 3 of argv) as integer
  set windowHeight to (item 4 of argv) as integer
  set iconSize to (item 5 of argv) as integer
  set appIconX to (item 6 of argv) as integer
  set appIconY to (item 7 of argv) as integer
  set applicationsIconX to (item 8 of argv) as integer
  set applicationsIconY to (item 9 of argv) as integer
  set backgroundName to item 10 of argv
  set targetFolder to POSIX file mountPath as alias
  set backgroundPath to POSIX file (mountPath & "/.background/" & backgroundName) as alias
  set rightBound to 100 + windowWidth
  set bottomBound to 100 + windowHeight

  tell application "Finder"
    open targetFolder
    delay 0.5
    set containerWindow to front Finder window
    set current view of containerWindow to icon view
    set toolbar visible of containerWindow to false
    set statusbar visible of containerWindow to false
    set bounds of containerWindow to {100, 100, rightBound, bottomBound}
    set theViewOptions to the icon view options of containerWindow
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to iconSize
    set background picture of theViewOptions to backgroundPath
    set position of item "Stacio.app" of containerWindow to {appIconX, appIconY}
    set position of item "Applications" of containerWindow to {applicationsIconX, applicationsIconY}
    update targetFolder without registering applications
    delay 1
    close containerWindow
  end tell
end run
OSA
  fail "failed to apply Finder DMG layout"
fi

if [[ "$SKIP_FINDER_LAYOUT" != "1" && "$SKIP_FINDER_LAYOUT" != "true" ]]; then
  SetFile -a V "$MOUNT_DIR/.background" 2>/dev/null || true
  for _ in {1..10}; do
    sync
    [[ -f "$MOUNT_DIR/.DS_Store" ]] && break
    sleep 0.5
  done
  [[ -f "$MOUNT_DIR/.DS_Store" ]] || fail "Finder DMG layout did not create .DS_Store"
fi
hdiutil detach "$MOUNT_DIR"
MOUNT_DIR=""

hdiutil convert "$RW_DMG_PATH" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$DMG_PATH"

hdiutil verify "$DMG_PATH"

printf 'Packaged %s\n' "$DMG_PATH"
