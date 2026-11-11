#!/usr/bin/env bash
#把本地工作分支同步到公开仓库（GitHub / Gitee）。
#
#用法：
# ./scripts/publish-snapshot.sh --dry-run #只看会做什么
# ./scripts/publish-snapshot.sh #执行
# ./scripts/publish-snapshot.sh --full #额外跑完整验证
#
#设计说明：
#发布线（release/snapshot-*）与工作分支历史不同源，用 cherry-pick
#会重复应用或冲突。真正的要求只有一条：发布线的**文件内容**必须与
#工作分支一致。所以这里直接同步树，而不是搬运提交。
#
#这保证：
# -发布线不会漏文件（比 cherry-pick可靠）
# -树一致性有强制校验，不一致就不推送
# -推送前必须通过边界检查与验证

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

WORK_BRANCH="${STACIO_WORK_BRANCH:-codex/local-source-integration-20261016}"
RELEASE_BRANCH="${STACIO_RELEASE_BRANCH:-release/snapshot-0.15.3}"
DRY_RUN=0
RUN_FULL=0

for arg in "$@"; do
 case "$arg" in
 --dry-run) DRY_RUN=1 ;;
 --full) RUN_FULL=1 ;;
 *) echo "未知参数：$arg" >&2; exit 2 ;;
 esac
done

say() { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

say "=== Stacio发布快照 ==="
say "工作分支：$WORK_BRANCH"
say "发布分支：$RELEASE_BRANCH"
say ""

# ----1.前置校验 ----
say "[1/5]前置校验"

CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$CURRENT_BRANCH" != "$WORK_BRANCH" ]]; then
 fail "当前在 $CURRENT_BRANCH，必须先切到 $WORK_BRANCH"
fi

if [[ -n "$(git status --porcelain)" ]]; then
 fail "工作区有未提交改动，先提交再发布"
fi

if ! python3 scripts/verify-public-repo-boundary.py >/dev/null 2>&1; then
 python3 scripts/verify-public-repo-boundary.py >&2 || true
 fail "公开仓库边界检查未通过"
fi

if [[ "$RUN_FULL" == "1" ]]; then
 say "运行完整验证（含全部测试）……"
 ./scripts/verify-all.sh --full || fail "验证未通过"
else
 say "运行快速验证……"
 ./scripts/verify-all.sh >/dev/null || fail "验证未通过"
fi
say " OK:工作区干净、边界通过、验证通过"

git rev-parse --verify "$RELEASE_BRANCH" >/dev/null 2>&1 || \
 fail "发布分支 $RELEASE_BRANCH不存在"

WORK_TREE="$(git rev-parse "$WORK_BRANCH^{tree}")"
RELEASE_TREE="$(git rev-parse "$RELEASE_BRANCH^{tree}")"

say ""
if [[ "$WORK_TREE" == "$RELEASE_TREE" ]]; then
 say "[2/5]发布线已与工作分支一致（树 $WORK_TREE），无需同步"
 SYNCED=0
else
 say "[2/5]需要同步"
 DIFF_COUNT="$(git diff --name-only "$RELEASE_BRANCH" "$WORK_BRANCH" | wc -l | tr -d ' ')"
 say "差异文件数：$DIFF_COUNT"
 SYNCED=1
fi
say ""

if [[ "$DRY_RUN" == "1" ]]; then
 say "[3/5] [dry-run]将同步树并推送到 gitee与 origin"
 say ""
 say "=== dry-run结束，未做任何改动 ==="
 exit 0
fi

# ----3.同步树 ----
if [[ "$SYNCED" == "1" ]]; then
 say "[3/5]同步树到发布分支"
 git checkout "$RELEASE_BRANCH" >/dev/null

 #用工作分支内容覆盖发布线
 git checkout "$WORK_BRANCH" -- . >/dev/null 2>&1 || true

 #删除发布线有、工作分支没有的文件
 DELETED="$(git diff --name-only --diff-filter=D "$WORK_BRANCH" HEAD || true)"
 if [[ -n "$DELETED" ]]; then
 printf '%s\n' "$DELETED" | while IFS= read -r f; do
 [[ -n "$f" ]] || continue
 git rm -q --cached "$f" >/dev/null 2>&1 || true
 rm -f "$f"
 done
 fi

 if git diff --quiet HEAD && [[ -z "$(git status --porcelain)" ]]; then
 say "无实际变化"
 else
 git add -A >/dev/null
 SUBJECT="$(git log -1 --format='%s' "$WORK_BRANCH")"
 git commit -q -m "release: sync snapshot from $WORK_BRANCH" \
 -m "同步内容：$SUBJECT"
 say "已提交同步"
 fi
else
 say "[3/5]无需同步"
fi
say ""

# ----4.树一致性强制校验 ----
say "[4/5]验证树一致性"
RELEASE_TREE_AFTER="$(git rev-parse "$RELEASE_BRANCH^{tree}")"
if [[ "$RELEASE_TREE_AFTER" != "$WORK_TREE" ]]; then
 git checkout "$WORK_BRANCH" >/dev/null
 fail "发布分支树(${RELEASE_TREE_AFTER})与工作分支树(${WORK_TREE})不一致，已取消推送"
fi
say " OK:树一致（$RELEASE_TREE_AFTER）"
say ""

# ----5.推送 ----
say "[5/5]推送到公开仓库"
PUSHED=0
for remote in gitee origin; do
 say "推送 $remote ……"
 if GIT_TERMINAL_PROMPT=0 git push "$remote" "HEAD:refs/heads/main" 2>&1 | grep -E -- "->|up-to-date" | sed 's/^/ /'; then
 PUSHED=$((PUSHED +1))
 else
 say " WARN: $remote推送失败（网络？），稍后重试：git push $remote HEAD:main"
 fi
done

git checkout "$WORK_BRANCH" >/dev/null
say ""
say "当前分支：$(git rev-parse --abbrev-ref HEAD)"
if [[ "$PUSHED" -eq 2 ]]; then
 say "===完成：两个仓库都已同步 ==="
else
 say "===部分完成：$PUSHED/2 ==="
 exit 1
fi
