#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAKE_BIN_DIR="$TMP_DIR/bin"
APP_DIR="$TMP_DIR/Stacio.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
LOG_FILE="$TMP_DIR/tool-calls.log"
STATE_FILE="$TMP_DIR/window-polls"

mkdir -p "$FAKE_BIN_DIR" "$MACOS_DIR"
touch "$STATE_FILE"

cat >"$CONTENTS_DIR/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>Stacio</string>
</dict>
</plist>
EOF

cat >"$MACOS_DIR/Stacio" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$MACOS_DIR/Stacio"

cat >"$FAKE_BIN_DIR/open" <<'EOF'
#!/usr/bin/env bash
printf 'open' >>"$STACIO_GUI_SMOKE_LOG"
for arg in "$@"; do
  printf ' %q' "$arg" >>"$STACIO_GUI_SMOKE_LOG"
done
printf '\n' >>"$STACIO_GUI_SMOKE_LOG"
EOF
chmod +x "$FAKE_BIN_DIR/open"

cat >"$FAKE_BIN_DIR/swift" <<'EOF'
#!/usr/bin/env bash
polls="$(wc -l <"$STACIO_GUI_SMOKE_STATE" | tr -d ' ')"
printf 'swift %s\n' "$polls" >>"$STACIO_GUI_SMOKE_LOG"
printf '.\n' >>"$STACIO_GUI_SMOKE_STATE"
if [[ "$polls" -lt 1 ]]; then
  printf '0\n'
else
  printf '1\n'
fi
EOF
chmod +x "$FAKE_BIN_DIR/swift"

cat >"$FAKE_BIN_DIR/osascript" <<'EOF'
#!/usr/bin/env bash
printf 'osascript unexpected\n' >>"$STACIO_GUI_SMOKE_LOG"
printf '0\n'
EOF
chmod +x "$FAKE_BIN_DIR/osascript"

cat >"$FAKE_BIN_DIR/pkill" <<'EOF'
#!/usr/bin/env bash
printf 'pkill' >>"$STACIO_GUI_SMOKE_LOG"
for arg in "$@"; do
  printf ' %q' "$arg" >>"$STACIO_GUI_SMOKE_LOG"
done
printf '\n' >>"$STACIO_GUI_SMOKE_LOG"
EOF
chmod +x "$FAKE_BIN_DIR/pkill"

PATH="$FAKE_BIN_DIR:$PATH" \
STACIO_GUI_SMOKE_LOG="$LOG_FILE" \
STACIO_GUI_SMOKE_STATE="$STATE_FILE" \
STACIO_GUI_SMOKE_TIMEOUT_SECONDS=2 \
STACIO_GUI_SMOKE_POLL_INTERVAL=0.01 \
"$ROOT_DIR/scripts/smoke-launch-window.sh" "$APP_DIR"

grep -Fq "open -n $APP_DIR" "$LOG_FILE"
grep -Fq "swift 0" "$LOG_FILE"
grep -Fq "swift 1" "$LOG_FILE"
grep -Fq "pkill -x Stacio" "$LOG_FILE"

cat >"$FAKE_BIN_DIR/swift" <<'EOF'
#!/usr/bin/env bash
printf 'swift error\n' >>"$STACIO_GUI_SMOKE_LOG"
exit 1
EOF
chmod +x "$FAKE_BIN_DIR/swift"

cat >"$FAKE_BIN_DIR/osascript" <<'EOF'
#!/usr/bin/env bash
printf 'osascript error\n' >>"$STACIO_GUI_SMOKE_LOG"
exit 1
EOF
chmod +x "$FAKE_BIN_DIR/osascript"

if PATH="$FAKE_BIN_DIR:$PATH" \
  STACIO_GUI_SMOKE_LOG="$LOG_FILE" \
  STACIO_GUI_SMOKE_STATE="$STATE_FILE" \
  STACIO_GUI_SMOKE_TIMEOUT_SECONDS=1 \
  STACIO_GUI_SMOKE_POLL_INTERVAL=0.01 \
  STACIO_GUI_SMOKE_ALLOW_PERMISSION_SKIP=1 \
  "$ROOT_DIR/scripts/smoke-launch-window.sh" "$APP_DIR" >"$TMP_DIR/permission-skip.out"; then
  grep -Fq "SKIP unable to query Stacio windows through System Events" "$TMP_DIR/permission-skip.out"
else
  echo "expected permission-limited smoke to skip successfully" >&2
  exit 1
fi

echo "smoke_launch_window_test passed"
