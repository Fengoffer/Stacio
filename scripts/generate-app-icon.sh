#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <source.icon> <output.icns>" >&2
  exit 64
fi

SOURCE_ICON="$1"
OUTPUT_ICNS="$2"
ICON_COMPOSER_CLI="${STACIO_ICON_COMPOSER_CLI:-/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool}"
ICON_SPECS=(
  "icon_16x16.png:16:1"
  "icon_16x16@2x.png:16:2"
  "icon_32x32.png:32:1"
  "icon_32x32@2x.png:32:2"
  "icon_128x128.png:128:1"
  "icon_128x128@2x.png:128:2"
  "icon_256x256.png:256:1"
  "icon_256x256@2x.png:256:2"
  "icon_512x512.png:512:1"
  "icon_512x512@2x.png:512:2"
)

generate_fallback_iconset() {
  local iconset_dir="$1"

  python3 - "$iconset_dir" <<'PY'
import math
import os
import struct
import sys
import zlib

out_dir = sys.argv[1]
specs = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]


def png_chunk(kind, data):
    return (
        struct.pack(">I", len(data))
        + kind
        + data
        + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    )


def write_png(path, width, height, pixels):
    raw = bytearray()
    stride = width * 4
    for y in range(height):
        raw.append(0)
        start = y * stride
        raw.extend(pixels[start:start + stride])
    payload = b"".join([
        b"\x89PNG\r\n\x1a\n",
        png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)),
        png_chunk(b"IDAT", zlib.compress(bytes(raw), 9)),
        png_chunk(b"IEND", b""),
    ])
    with open(path, "wb") as handle:
        handle.write(payload)


def inside_round_rect(x, y, size, radius):
    left = radius
    right = size - radius - 1
    top = radius
    bottom = size - radius - 1
    if left <= x <= right or top <= y <= bottom:
        return True
    cx = left if x < left else right
    cy = top if y < top else bottom
    return (x - cx) * (x - cx) + (y - cy) * (y - cy) <= radius * radius


def render(size):
    pixels = bytearray(size * size * 4)
    radius = max(3, int(size * 0.22))
    inset = max(1, int(size * 0.06))
    logo_y = int(size * 0.36)
    logo_h = max(2, int(size * 0.24))
    logo_thickness = max(2, int(size * 0.08))
    bar_y = int(size * 0.62)
    bar_h = max(2, int(size * 0.09))
    bar_x0 = int(size * 0.34)
    bar_x1 = int(size * 0.66)

    for y in range(size):
        for x in range(size):
            idx = (y * size + x) * 4
            if not inside_round_rect(x, y, size, radius):
                pixels[idx:idx + 4] = b"\x00\x00\x00\x00"
                continue

            vertical = y / max(1, size - 1)
            red = int(242 - 86 * vertical)
            green = int(255 - 86 * vertical)
            blue = int(255 - 8 * vertical)
            alpha = 255

            if (
                inset <= x < size - inset
                and inset <= y < size - inset
                and not inside_round_rect(x - inset, y - inset, size - inset * 2, max(1, radius - inset))
            ):
                red, green, blue = 255, 255, 255

            left_diag = abs((x - int(size * 0.28)) - (y - logo_y)) <= logo_thickness
            right_diag = abs((int(size * 0.72) - x) - (y - logo_y)) <= logo_thickness
            logo_band = logo_y <= y <= logo_y + logo_h
            center_bar = bar_x0 <= x <= bar_x1 and bar_y <= y <= bar_y + bar_h
            if logo_band and (left_diag or right_diag or center_bar):
                red, green, blue = 12, 18, 44

            pixels[idx:idx + 4] = bytes((red, green, blue, alpha))
    return pixels


os.makedirs(out_dir, exist_ok=True)
for filename, size in specs:
    write_png(os.path.join(out_dir, filename), size, size, render(size))
PY
}

if [[ ! -d "$SOURCE_ICON" ]]; then
  echo "Icon Composer document not found: $SOURCE_ICON" >&2
  exit 1
fi

if [[ ! -x "$ICON_COMPOSER_CLI" ]]; then
  if [[ "${STACIO_ALLOW_FALLBACK_APP_ICON:-0}" == "1" || "${STACIO_ALLOW_FALLBACK_APP_ICON:-0}" == "true" ]]; then
    TMP_DIR="$(mktemp -d)"
    trap 'rm -rf "$TMP_DIR"' EXIT
    ICONSET_DIR="$TMP_DIR/Stacio.iconset"
    mkdir -p "$ICONSET_DIR" "$(dirname "$OUTPUT_ICNS")"
    echo "WARN Icon Composer renderer unavailable; generating fallback app icon" >&2
    generate_fallback_iconset "$ICONSET_DIR"
    iconutil --convert icns --output "$OUTPUT_ICNS" "$ICONSET_DIR"
    exit 0
  fi
  echo "Icon Composer command-line renderer not found: $ICON_COMPOSER_CLI" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
ICONSET_DIR="$TMP_DIR/Stacio.iconset"
mkdir -p "$ICONSET_DIR" "$(dirname "$OUTPUT_ICNS")"

for spec in "${ICON_SPECS[@]}"; do
  IFS=":" read -r filename points scale <<<"$spec"
  "$ICON_COMPOSER_CLI" "$SOURCE_ICON" \
    --export-image \
    --output-file "$ICONSET_DIR/$filename" \
    --platform macOS \
    --rendition Default \
    --width "$points" \
    --height "$points" \
    --scale "$scale" >/dev/null
done

iconutil --convert icns --output "$OUTPUT_ICNS" "$ICONSET_DIR"
