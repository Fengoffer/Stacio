#!/usr/bin/env bash
# 预推送守卫：目标仓库是公开仓库（GitHub / Gitee）时，拒绝推送越界内容。
#
# 安装：./scripts/install-git-hooks.sh
# 绕过：git push --no-verify（明确知道自己在做什么时）
#
# 边界定义：config/public-repo-boundary.json
set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"
REMOTE_URL="${2:-}"

if [[ -z "$REMOTE_URL" ]]; then
  exit 0
fi

IS_PUBLIC="$(BOUNDARY_ROOT="$ROOT_DIR" BOUNDARY_URL="$REMOTE_URL" python3 - <<'PY'
import json
import os

root = os.environ["BOUNDARY_ROOT"]
url = os.environ["BOUNDARY_URL"].rstrip("/")
with open(os.path.join(root, "config", "public-repo-boundary.json"), "r", encoding="utf-8") as stream:
    config = json.load(stream)
public = {item.rstrip("/") for item in config.get("publicRepositories", [])}
print("yes" if url in public else "no")
PY
)"

if [[ "$IS_PUBLIC" != "yes" ]]; then
  exit 0
fi

echo "推送目标为公开仓库：$REMOTE_URL"
echo "正在检查公开仓库边界（config/public-repo-boundary.json）……"

FAILED=0
while read -r local_ref local_sha remote_ref remote_sha; do
  [[ -z "${local_sha:-}" ]] && continue
  if [[ "$local_sha" =~ ^0+$ ]]; then
    continue
  fi
  if ! python3 "$ROOT_DIR/scripts/verify-public-repo-boundary.py" \
      --ref "$local_sha" --skip-secrets; then
    FAILED=1
  fi
done

if [[ "$FAILED" != "0" ]]; then
  echo
  echo "已阻止推送：内容超出公开仓库边界。"
  echo "处理方式：把越界文件移出版本控制（git rm --cached），或修改 config/public-repo-boundary.json。"
  echo "如果确认要重写历史后再推送，请先与仓库所有者确认。"
  exit 1
fi

echo "边界检查通过。"
exit 0
