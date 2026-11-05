#!/usr/bin/env bash
# spike_plan_compat.sh — B-02(阿里 Coding Plan)/B-03(GLM Coding Plan) managed 兼容证据收集。
# 用法:
#   bash Tests/Evidence/spike_plan_compat.sh --check-env                 # 环境探针（安全）
#   bash Tests/Evidence/spike_plan_compat.sh --run --plan aliyun|glm --cli <path> [--reviewer <name>]
# 输出: ~/StacioEvidence/reports/B-0[23]-<timestamp>.json
# 说明: 需要真实套餐测试账号与官方 CLI；OAuth/Key 只经 env（PLAN_KEY_ALIYUN / PLAN_KEY_GLM）注入，绝不落盘或打印。
#
# PENDING_VERIFY（本沙箱无法访问外网，须官方文档/真实账号复核）：
#   阿里 Coding Plan: 端点 https://coding.dashscope.aliyuncs.com/v1（规格 §10.3），授权限于交互式编程工具，须经受支持 Local Agent；
#     具名 CLI 候选：Qwen Code CLI（qwen）/ 通义灵码 CLI —— 须官方文档确认版本范围、鉴权注入方式与 managed profile。
#   GLM Coding Plan: 端点 https://open.bigmodel.cn/api/coding/paas/v4（规格 §10.3），/models 无 Key 返回 401；
#     具名 CLI 候选：GLM 官方编程 CLI / CodeGeeX —— 须官方文档确认。
#   官方文档（请核对）：
#   - 阿里: https://help.aliyun.com/zh/model-studio/  ;  https://bailian.console.aliyun.com/
#   - GLM:  https://open.bigmodel.cn/dev/api  ;  https://bigmodel.cn/coding-plan/personal/overview
set -u

REVIEWER="${STACIO_EVIDENCE_REVIEWER:-Provider-LocalAgent-Owner}"
OUT_DIR="${STACIO_EVIDENCE_DIR:-$HOME/StacioEvidence}/reports"
mkdir -p "$OUT_DIR"

check_env() {
  echo "=== Coding Plan 兼容环境探针 ==="
  echo "已配置账号 Key 环境变量:"
  [ -n "${PLAN_KEY_ALIYUN:-}" ] && echo "  PLAN_KEY_ALIYUN: 已设置(不回显值)" || echo "  PLAN_KEY_ALIYUN: 未设置"
  [ -n "${PLAN_KEY_GLM:-}" ] && echo "  PLAN_KEY_GLM: 已设置(不回显值)" || echo "  PLAN_KEY_GLM: 未设置"
  echo "待验项: 官方授权/文档、套餐测试账号、具名 CLI 版本范围、PlanAgentCompatibility descriptor 字段、真实模型/工具/Stop/失败恢复"
  echo "结论建议: defer（依赖真实套餐账号与具名 CLI）"
}

emit() {
  # $1=blockerID(02/03) $2=conclusion $3=summary
  local B="$1" C="$2" S="$3"
  local EID="B-$B-$(date +%Y%m%d-%H%M%S)"
  local BUILD="$(git -C "$(cd "$(dirname "$0")/../.." && pwd)" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  local DEVICE="$(sw_vers -productName 2>/dev/null || echo macOS) $(sw_vers -productVersion 2>/dev/null)"
  python3 - "$EID" "$B" "$C" "$(date +%Y-%m-%dT%H:%M:%S)" "$BUILD" "$DEVICE" "$REVIEWER" "$S" "$OUT_DIR" <<'PYEOF'
import json, sys
eid, b, conclusion, gen, build, device, reviewer, summary, outdir = sys.argv[1:10]
entry = {
  "evidenceID": eid,
  "blockerID": "B-" + b,
  "conclusion": conclusion,
  "generatedAt": gen,
  "buildCommit": build,
  "catalogSetRevision": "pending",
  "deviceSystem": device,
  "expiryCondition": "Phase 0 + phase 10 release gate",
  "reviewer": reviewer,
  "redactedSummary": summary,
  "checklist": [
    {"item": "官方授权/文档", "status": "na", "detail": "需官方资料"},
    {"item": "套餐测试账号", "status": "na", "detail": "需真实套餐账号"},
    {"item": "具名 CLI 版本范围", "status": "na", "detail": "需官方 CLI"},
    {"item": "PlanAgentCompatibility descriptor", "status": "na", "detail": "需本地 agent catalog + 版本范围 + 鉴权注入方式 + required managed profile + containment revision + 授权说明"},
    {"item": "真实模型/工具/Stop/失败恢复", "status": "na", "detail": "需真实套餐端到端"}
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
    PLAN=""; CLI=""
    while [ $# -gt 0 ]; do
      case "$1" in --plan) PLAN="$2"; shift 2;; --cli) CLI="$2"; shift 2;; --reviewer) REVIEWER="$2"; shift 2;; *) echo "未知参数 $1"; exit 2;; esac
    done
    [ -n "$PLAN" ] || { echo "--plan aliyun|glm 必填"; exit 2; }
    [ -n "$CLI" ] || { echo "--cli <path> 必填"; exit 2; }
    [ -x "$CLI" ] || { echo "CLI 不可执行: $CLI"; exit 2; }
    KEY="${PLAN_KEY_ALIYUN:-}${PLAN_KEY_GLM:-}"
    if [ -z "$KEY" ]; then
      echo "未配置对应套餐 Key 环境变量，结论 defer"
      [ "$PLAN" = "aliyun" ] && emit "02" "defer" "阿里 Coding Plan：账号未配置，仅登记环境与待验项"
      [ "$PLAN" = "glm" ] && emit "03" "defer" "GLM Coding Plan：账号未配置，仅登记环境与待验项"
      exit 0
    fi
    # 具名 CLI 版本与能力探针（不回显 Key）
    echo "CLI: $CLI"; "$CLI" --version 2>/dev/null | head -3 | sed 's/^/  /'
    [ "$PLAN" = "aliyun" ] && emit "02" "defer" "已探测 CLI 版本；PlanAgentCompatibility 端到端待真实套餐执行后回填"
    [ "$PLAN" = "glm" ] && emit "03" "defer" "已探测 CLI 版本；PlanAgentCompatibility 端到端待真实套餐执行后回填"
    ;;
  *)
    echo "用法: $0 --check-env | --run --plan aliyun|glm --cli <path>"; exit 2
    ;;
esac
