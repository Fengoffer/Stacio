#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${1:-$ROOT_DIR/dist/Stacio.app}"
PLIST_PATH="$APP_DIR/Contents/Info.plist"
PLIST_BUDDY="/usr/libexec/PlistBuddy"
TIMEOUT_SECONDS="${STACIO_GUI_SMOKE_TIMEOUT_SECONDS:-10}"
POLL_INTERVAL="${STACIO_GUI_SMOKE_POLL_INTERVAL:-0.25}"
ALLOW_PERMISSION_SKIP="${STACIO_GUI_SMOKE_ALLOW_PERMISSION_SKIP:-0}"

fail() {
  printf 'FAIL %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'PASS %s\n' "$1"
}

skip() {
  printf 'SKIP %s\n' "$1"
  exit 0
}

plist_value() {
  local key="$1"
  "$PLIST_BUDDY" -c "Print :$key" "$PLIST_PATH" 2>/dev/null || true
}

coregraphics_window_count() {
  swift - <<'SWIFT' 2>/dev/null || printf 'ERROR\n'
import CoreGraphics
import Foundation

func numericValue(_ value: Any?) -> Double? {
    if let number = value as? NSNumber {
        return number.doubleValue
    }
    if let double = value as? Double {
        return double
    }
    if let int = value as? Int {
        return Double(int)
    }
    return nil
}

func boolValue(_ value: Any?) -> Bool? {
    if let bool = value as? Bool {
        return bool
    }
    if let number = value as? NSNumber {
        return number.boolValue
    }
    return nil
}

let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
let count = windows.filter { window in
    guard (window[kCGWindowOwnerName as String] as? String) == "Stacio" else {
        return false
    }
    guard numericValue(window[kCGWindowLayer as String]) == 0 else {
        return false
    }
    if let alpha = numericValue(window[kCGWindowAlpha as String]), alpha <= 0 {
        return false
    }
    if let onscreen = boolValue(window[kCGWindowIsOnscreen as String]), !onscreen {
        return false
    }
    return true
}.count

print(count)
SWIFT
}

system_events_window_count() {
  osascript <<'APPLESCRIPT' 2>/dev/null || printf 'ERROR\n'
tell application "System Events"
  if exists process "Stacio" then
    return count of windows of process "Stacio"
  else
    return 0
  end if
end tell
APPLESCRIPT
}

window_count() {
  local count
  count="$(coregraphics_window_count)"
  if [[ "$count" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$count"
    return
  fi

  system_events_window_count
}

printf 'Stacio GUI launch smoke\n'
printf 'App: %s\n\n' "$APP_DIR"

[[ -d "$APP_DIR" ]] || fail "app bundle missing: $APP_DIR"
[[ -f "$PLIST_PATH" ]] || fail "Info.plist missing: $PLIST_PATH"

executable_name="$(plist_value CFBundleExecutable)"
[[ "$executable_name" == "Stacio" ]] || fail "CFBundleExecutable expected Stacio, got ${executable_name:-<empty>}"
[[ -x "$APP_DIR/Contents/MacOS/$executable_name" ]] || fail "app executable missing or not executable"

open -n "$APP_DIR"
trap 'pkill -x Stacio >/dev/null 2>&1 || true' EXIT

deadline=$((SECONDS + TIMEOUT_SECONDS))
last_count=""
while (( SECONDS <= deadline )); do
  last_count="$(window_count)"
  if [[ "$last_count" =~ ^[0-9]+$ ]] && (( last_count >= 1 )); then
    pass "Stacio launched with at least one visible app window"
    exit 0
  fi
  sleep "$POLL_INTERVAL"
done

if [[ "$last_count" == "ERROR" ]]; then
  if [[ "$ALLOW_PERMISSION_SKIP" == "1" || "$ALLOW_PERMISSION_SKIP" == "true" ]]; then
    skip "unable to query Stacio windows through System Events; grant Accessibility permission for strict GUI smoke"
  fi
  fail "unable to query Stacio windows through System Events; grant Accessibility permission or run bundle smoke instead"
fi

fail "Stacio launched but no app window was observed within ${TIMEOUT_SECONDS}s"
