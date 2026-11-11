#!/usr/bin/env bash
#把本地工作分支的新提交同步到公开仓库（GitHub / Gitee）。
#
#用法：
# ./scripts/publish-snapshot.sh --dry-run #只看会推什么，不实际推
# ./scripts/publish-snapshot.sh #执行
# ./scripts/publish-snapshot.sh --full #额外跑完整验证
#
#这个脚本替代了之前需要手工执行的6步流程，避免顺序错误与命令拼接失误。
#
#前提：
#1.工作区必须干净（未提交改动会导致构建不可复现）
#2.公开仓库边界检查必须通过
#3.本地改动必须在工作分支上，不能直接改 release分支
#
#流程：
#1.校验工作区、分支、边界
#2.找出工作分支相对发布线的独有提交
#3.逐个 cherry-pick到发布线
#4.验证发布线与工作分支的树完全一致
#5.推送到 GitHub与 Gitee
#6.回到工作分支

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
say "[1/6]前置校验"

CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$CURRENT_BRANCH" != "$WORK_BRANCH" ]]; then
 fail "当前在 $CURRENT_BRANCH，必须先切到 $WORK_BRANCH再发布"
fi

if [[ -n "$(git status --porcelain)" ]]; then
 fail "工作区有未提交改动，先提交再发布"
fi

if ! python3 scripts/verify-public-repo-boundary.py >/dev/null 2>&1; then
 say "边界检查失败："
 python3 scripts/verify-public-repo-boundary.py >&2 || true
 fail "公开仓库边界检查未通过，拒绝发布"
fi

if [[ "$RUN_FULL" == "1" ]]; then
 say "运行完整验证……"
 if ! ./scripts/verify-all.sh --full; then
 fail "验证未通过，拒绝发布"
 fi
else
 say "运行快速验证……"
 if ! ./scripts/verify-all.sh >/dev/null; then
 fail "验证未通过，拒绝发布"
 fi
fi

say " OK:工作区干净、边界通过、验证通过"

# ----2.找出待同步的提交 ----
say ""
say "[2/6]计算待同步提交"

git rev-parse --verify "$RELEASE_BRANCH" >/dev/null 2>&1 || \
 fail "发布分支 $RELEASE_BRANCH不存在"

WORK_TREE="$(git rev-parse "$WORK_BRANCH^{tree}")"
RELEASE_TREE="$(git rev-parse "$RELEASE_BRANCH^{tree}")"

if [[ "$WORK_TREE" == "$RELEASE_TREE" ]]; then
 say " OK:发布线已与工作分支一致（树 $WORK_TREE），无需同步"
 PENDING=""
else
 #用树差异找出需要搬运的提交（两分支历史不同源，不能直接用 commit范围）
 #取工作分支最近N个提交中，其变更文件涉及当前差异的
 DIFF_FILES="$(git diff --name-only "$RELEASE_BRANCH" "$WORK_BRANCH")"
 say "差异文件："
 printf '%s\n' "$DIFF_FILES" | sed 's/^/ /'
 PENDING="$(git log --oneline -20 --format='%H' "$WORK_BRANCH" -- $DIFF_FILES | head -10)"
fi

say ""

# ----3. cherry-pick ----
say "[3/6]同步到发布分支"

if [[ "$DRY_RUN" == "1" ]]; then
 say " [dry-run]将执行：git checkout $RELEASE_BRANCH"
 if [[ -n "$PENDING" ]]; then
 say " [dry-run]将 cherry-pick："
 printf '%s\n' "$PENDING" | sed 's/^/ /'
 else
 say " [dry-run]无待搬运提交"
 fi
 say " [dry-run]将推送到 gitee与 origin"
 say ""
 say "=== dry-run结束，未做任何改动 ==="
 exit 0
fi

git checkout "$RELEASE_BRANCH"

if [[ -n "$PENDING" ]]; then
 #从旧到新逐个 cherry-pick
 for sha in $(printf '%s\n' "$PENDING" | tail -r); do
 say " cherry-pick ${sha:0:8}"
 git cherry-pick "$sha" >/dev/null || {
 git cherry-pick --abort || true
 git checkout "$WORK_BRANCH" || true
 fail "cherry-pick ${sha:0:8}失败，已回到 $WORK_BRANCH"
 }
 done
fi

# ----4.树一致性验证 ----
say ""
say "[4/6]验证树一致性"

RELEASE_TREE_AFTER="$(git rev-parse "$RELEASE_BRANCH^{tree}")"
if [[ "$RELEASE_TREE_AFTER" != "$WORK_TREE" ]]; then
 git checkout "$WORK_BRANCH"
 fail "发布分支树($RELEASE_TREE_AFTER)与工作分支树($WORK_TREE)不一致，已取消推送"
fi
say " OK:树一致（$RELEASE_TREE_AFTER）"

# ----5.推送 ----
say ""
say "[5/6]推送到公开仓库"

PUSHED=0
for remote in gitee origin; do
 say "推送 $remote ……"
 if GIT_TERMINAL_PROMPT=0 git push "$remote" "HEAD:refs/heads/main" 2>&1 | grep -E "->|up-to-date" | sed 's/^/ /'; then
 PUSHED=$((PUSHED +1))
 else
 say " WARN: $remote推送失败（网络问题？），稍后重试"
 fi
done

# ----6.回到工作分支 ----
say ""
say "[6/6]回到工作分支"
git checkout "$WORK_BRANCH" >/dev/null
say " OK:当前在 $WORK_BRANCH"

say ""
if [[ "$PUSHED" -eq 2 ]]; then
 say "===完成：两个仓库都已同步 ==="
else
 say "===部分完成：$PUSHED/2个仓库推送成功 ==="
 say "失败的稍后用 git push <remote> HEAD:main重试"
 exit 1
fi
