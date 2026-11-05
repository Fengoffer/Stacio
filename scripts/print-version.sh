#!/usr/bin/env bash
# 打印 Stacio 的版本号，并可与已打包的 .app 交叉核对。
#
# 用法：
#   ./scripts/print-version.sh                     只打印版本
#   ./scripts/print-version.sh --json              输出 JSON
#   ./scripts/print-version.sh --check-app <app>   核对 .app 的 Info.plist 是否与 config/release.json 一致
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$ROOT_DIR/config/release.json"

if [[ ! -f "$CONFIG" ]]; then
  echo "缺少版本配置文件：$CONFIG" >&2
  exit 1
fi

MODE="${1:-}"

case "$MODE" in
  --check-app)
    APP="${2:-}"
    if [[ -z "$APP" || ! -d "$APP" ]]; then
      echo "用法：print-version.sh --check-app <Stacio.app 路径>" >&2
      exit 2
    fi
    python3 - "$CONFIG" "$APP/Contents/Info.plist" <<'PY'
import json
import plistlib
import sys

config_path, plist_path = sys.argv[1], sys.argv[2]
with open(config_path, "r", encoding="utf-8") as stream:
    expected = json.load(stream)["version"]
with open(plist_path, "rb") as stream:
    actual = plistlib.load(stream).get("CFBundleShortVersionString")
if actual != expected:
    print(f"版本不一致：config/release.json = {expected}，Info.plist = {actual}", file=sys.stderr)
    raise SystemExit(1)
print(f"版本一致：{actual}")
PY
    ;;
  --json)
    python3 - "$CONFIG" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as stream:
    config = json.load(stream)
print(json.dumps({"version": config["version"], "minimumSystemVersion": config.get("minimumSystemVersion")}, ensure_ascii=False))
PY
    ;;
  "")
    python3 - "$CONFIG" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as stream:
    config = json.load(stream)
print(config["version"])
PY
    ;;
  *)
    echo "未知参数：$MODE" >&2
    echo "用法：print-version.sh [--json | --check-app <path>]" >&2
    exit 2
    ;;
esac
