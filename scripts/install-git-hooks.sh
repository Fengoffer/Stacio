#!/usr/bin/env bash
# 安装公开仓库预推送守卫到当前仓库的 .git/hooks。
# 钩子本身不在版本控制里，所以每次重新克隆仓库后需要再跑一次。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK_PATH="$ROOT_DIR/.git/hooks/pre-push"
SOURCE="$ROOT_DIR/scripts/pre-push-public-repo-guard.sh"

if [[ ! -f "$SOURCE" ]]; then
  echo "找不到守卫脚本：$SOURCE" >&2
  exit 1
fi

if [[ -f "$HOOK_PATH" ]] && ! grep -q "pre-push-public-repo-guard" "$HOOK_PATH" 2>/dev/null; then
  BACKUP="$HOOK_PATH.bak.$(date +%Y%m%d%H%M%S)"
  cp "$HOOK_PATH" "$BACKUP"
  echo "已备份原有钩子：$BACKUP"
fi

cp "$SOURCE" "$HOOK_PATH"
chmod +x "$HOOK_PATH"
echo "已安装预推送守卫：$HOOK_PATH"
echo "验证：python3 scripts/verify-public-repo-boundary.py --skip-secrets"
