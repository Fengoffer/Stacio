#!/usr/bin/env bash
# spike_containment.sh — B-01 managed Local Agent OS containment 证据收集。
# 用法:
#   bash Tests/Evidence/spike_containment.sh --check-env    # 仅报告当前环境能否运行（安全，不触碰业务）
#   bash Tests/Evidence/spike_containment.sh --run <app_path> [--cli <path>] [--profile <id>] [--reviewer <name>]
# 输出: ~/StacioEvidence/reports/B-01-<timestamp>.json（回填用 backfill_evidence.sh）
# 说明: 需要 Developer ID 签名 + Hardened Runtime + notarized 的最终分发构建与 managed profile；
#       本脚本只做可复现的隔离/越界探针，绝不在未受控环境执行破坏性命令。
set -u

APP="${STACIO_APP:-$HOME/Stacio.app}"
REVIEWER="${STACIO_EVIDENCE_REVIEWER:-macOS-Runtime-Owner}"
OUT_DIR="${STACIO_EVIDENCE_DIR:-$HOME/StacioEvidence}/reports"
mkdir -p "$OUT_DIR"

check_env() {
  echo "=== B-01 环境探针 ==="
  sw_vers
  if [ -d "$APP" ]; then
    echo "App 存在: $APP"
    codesign -dv --verbose=2 "$APP" 2>&1 | sed 's/^/  /' || echo "  无法读取签名"
    echo "notarized 复验:"
    spctl -a -vv "$APP" 2>&1 | sed 's/^/  /' || echo "  未通过（外部受阻）"
  else
    echo "未找到 App（外部受阻：需 Developer ID/notarized 构建）"
  fi
  echo
  echo "检查清单（本次未运行，仅列待验项）:"
  for item in "进程隔离(seatbelt/sandbox)" "文件系统越界" "网络 egress" "Stacio 工具代理绕过" "symlink/TOCTOU" "auth scope" "workspace 隔离" "helper 子进程" "持久写入" "scratch 清理" "Broker peer/capability"; do
    echo "  [ ] $item"
  done
  echo "结论建议: defer（依赖最终分发构建 + managed profile）"
}

emit() {
  # $1=conclusion $2=summary
  local EID="B-01-$(date +%Y%m%d-%H%M%S)"
  local BUILD="$(git -C "$(cd "$(dirname "$0")/../.." && pwd)" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  local DEVICE="$(sw_vers -productName 2>/dev/null || echo macOS) $(sw_vers -productVersion 2>/dev/null)"
  python3 - "$EID" "$1" "$(date +%Y-%m-%dT%H:%M:%S)" "$BUILD" "$DEVICE" "$REVIEWER" "$2" "$OUT_DIR" <<'PYEOF'
import json, sys
eid, conclusion, gen, build, device, reviewer, summary, outdir = sys.argv[1:9]
entry = {
  "evidenceID": eid,
  "blockerID": "B-01",
  "conclusion": conclusion,
  "generatedAt": gen,
  "buildCommit": build,
  "catalogSetRevision": "pending",
  "deviceSystem": device,
  "expiryCondition": "Phase 0 gate; re-verify on each GA CLI version change",
  "reviewer": reviewer,
  "redactedSummary": summary,
  "checklist": [
    {"item": "进程隔离", "status": "na", "detail": "需 managed profile 落实"},
    {"item": "文件系统越界", "status": "na", "detail": "需 managed profile 落实"},
    {"item": "网络 egress", "status": "na", "detail": "需 managed profile 落实"},
    {"item": "Stacio 工具代理绕过", "status": "na", "detail": "需 managed profile 落实"},
    {"item": "symlink/TOCTOU", "status": "na", "detail": "需 launch 期 realpath 校验"},
    {"item": "auth scope / workspace / helper / 持久写入 / scratch 清理", "status": "na", "detail": "需 managed profile 落实"},
    {"item": "Broker peer/capability", "status": "na", "detail": "需 Broker 实现"}
  ],
  "resultPath": f"{outdir}/{eid}.json",
  "rawScope": "not provisioned"
}
with open(f"{outdir}/{eid}.json", "w", encoding="utf-8") as f:
    json.dump(entry, f, ensure_ascii=False, indent=2)
print(f"已生成: {outdir}/{eid}.json（使用 backfill_evidence.sh 回填）")
PYEOF
}

case "${1:---check-env}" in
  --check-env)
    check_env
    ;;
  --run)
    shift
    [ $# -ge 1 ] || { echo "用法: --run <app_path> [--cli <path>] [--profile <id>] [--reviewer <name>]"; exit 2; }
    APP="$1"
    EID="B-01-$(date +%Y%m%d-%H%M%S)"
    # 本 spike 仅登记环境与待验项；真实 containment 探针须在 P8 managed profile + 签名构建就绪后实现
    emit "defer" "managed containment 探针待 P8 profile 与最终签名构建就绪；当前仅登记环境基线与待验项"
    ;;
  *)
    echo "用法: $0 --check-env | --run <app_path>"; exit 2
    ;;
esac
