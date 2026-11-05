#!/usr/bin/env bash
# spike_provider_protocol.sh — B-04(Kimi Code Native)/B-05(MiniMax Native) 协议证据收集。
# 用法:
#   bash Tests/Evidence/spike_provider_protocol.sh --check-env
#   bash Tests/Evidence/spike_provider_protocol.sh --run --provider kimi|minimax [--reviewer <name>]
# Key 只经环境注入（KIMI_KEY / MINIMAX_KEY），只用于 Authorization 头，绝不打印、不写盘、不进入摘要。
# 输出: ~/StacioEvidence/reports/B-0[45]-<timestamp>.json（原始协议响应存 ~/StacioEvidence/raw/，脱敏）
#
# 端点来源：冻结规格 §10.3/§10.5 钉死的 Base URL；模型/对话路径为 OpenAI 兼容惯例。
# PENDING_VERIFY：本沙箱无法访问外网，以下路径须按官方文档与真实账号复核；可用环境变量覆盖。
#   官方文档（请核对）：
#   - Kimi: https://platform.moonshot.cn/docs/guide/chat  ; 模型: https://platform.moonshot.cn/docs/api/chat
#   - MiniMax: https://platform.minimaxi.com/document/  ; 模型: https://platform.minimaxi.com/document/chatCompletionV2
#   - 若实际端点不同，用 KIMI_BASE/MINIMAX_BASE/KIMI_CHAT_URL/MINIMAX_CHAT_URL 覆盖后重跑。
set -u

REVIEWER="${STACIO_EVIDENCE_REVIEWER:-Provider-Owner}"
OUT_DIR="${STACIO_EVIDENCE_DIR:-$HOME/StacioEvidence}/reports"
RAW_DIR="${STACIO_EVIDENCE_DIR:-$HOME/StacioEvidence}/raw"
mkdir -p "$OUT_DIR" "$RAW_DIR"

check_env() {
  echo "=== Provider 协议环境探针 ==="
  [ -n "${KIMI_KEY:-}" ] && echo "  KIMI_KEY: 已设置(不回显)" || echo "  KIMI_KEY: 未设置"
  [ -n "${MINIMAX_KEY:-}" ] && echo "  MINIMAX_KEY: 已设置(不回显)" || echo "  MINIMAX_KEY: 未设置"
  echo "待验项: 模型目录、流式、工具调用、Stop、额度语义、401/429/5xx、断流、空目录"
  echo "结论建议: defer（依赖非生产真实套餐 Key）"
}

emit() {
  # $1=blockerID(04/05) $2=conclusion $3=summary $4=rawfile
  local B="$1" C="$2" S="$3" RAW="$4"
  local EID="B-$B-$(date +%Y%m%d-%H%M%S)"
  local BUILD="$(git -C "$(cd "$(dirname "$0")/../.." && pwd)" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  local DEVICE="$(sw_vers -productName 2>/dev/null || echo macOS) $(sw_vers -productVersion 2>/dev/null)"
  python3 - "$EID" "$B" "$C" "$(date +%Y-%m-%dT%H:%M:%S)" "$BUILD" "$DEVICE" "$REVIEWER" "$S" "$RAW" "$OUT_DIR" <<'PYEOF'
import json, sys
eid, b, conclusion, gen, build, device, reviewer, summary, raw, outdir = sys.argv[1:11]
entry = {
  "evidenceID": eid,
  "blockerID": "B-" + b,
  "conclusion": conclusion,
  "generatedAt": gen,
  "buildCommit": build,
  "catalogSetRevision": "pending",
  "deviceSystem": device,
  "expiryCondition": "Phase 0; re-verify before Catalog GA",
  "reviewer": reviewer,
  "redactedSummary": summary,
  "checklist": [
    {"item": "模型目录 GET /models", "status": "na", "detail": "待真实 Key 执行"},
    {"item": "流式响应", "status": "na", "detail": "待真实 Key 执行"},
    {"item": "工具调用", "status": "na", "detail": "待真实 Key 执行"},
    {"item": "Stop 语义", "status": "na", "detail": "待真实 Key 执行"},
    {"item": "额度/401/429/5xx/断流/空目录", "status": "na", "detail": "待真实 Key 执行"}
  ],
  "resultPath": f"{outdir}/{eid}.json",
  "rawScope": raw
}
with open(f"{outdir}/{eid}.json", "w", encoding="utf-8") as f:
    json.dump(entry, f, ensure_ascii=False, indent=2)
print(f"已生成: {outdir}/{eid}.json（原始协议响应存 {raw}，回填用 backfill_evidence.sh）")
PYEOF
}

case "${1:---check-env}" in
  --check-env)
    check_env
    ;;
  --run)
    shift
    PROVIDER=""
    while [ $# -gt 0 ]; do
      case "$1" in --provider) PROVIDER="$2"; shift 2;; --reviewer) REVIEWER="$2"; shift 2;; *) echo "未知参数 $1"; exit 2;; esac
    done
    [ "$PROVIDER" = "kimi" ] || [ "$PROVIDER" = "minimax" ] || { echo "--provider kimi|minimax 必填"; exit 2; }
    if [ "$PROVIDER" = "kimi" ]; then
      KEY="${KIMI_KEY:-}"; BASE="${KIMI_BASE:-https://api.kimi.com/coding/v1}"; B="04"
      MODELS_URL="${KIMI_MODELS_URL:-$BASE/models}"; CHAT_URL="${KIMI_CHAT_URL:-$BASE/chat/completions}"
    else
      KEY="${MINIMAX_KEY:-}"; BASE="${MINIMAX_BASE:-https://api.minimaxi.com/v1}"; B="05"
      MODELS_URL="${MINIMAX_MODELS_URL:-$BASE/models}"; CHAT_URL="${MINIMAX_CHAT_URL:-$BASE/text/chatcompletion_v2}"
    fi
    if [ -z "$KEY" ]; then
      emit "$B" "defer" "Provider 未配置非生产真实 Key，仅登记环境与待验项" "$RAW_DIR/$PROVIDER-nokeys.txt"
      exit 0
    fi
    RAW="$RAW_DIR/$PROVIDER-$(date +%Y%m%d-%H%M%S).raw"
    # 模型目录（脱敏：只保留状态码与模型 ID 计数，不打印响应正文中的敏感内容）
    CODE=$(curl -s -o "$RAW.models" -w "%{http_code}" --max-time 20 -H "Authorization: Bearer $KEY" "$MODELS_URL" 2>/dev/null)
    MODEL_COUNT=$(grep -o '"id"' "$RAW.models" 2>/dev/null | wc -l | tr -d ' ')
    echo "  GET $MODELS_URL -> HTTP $CODE, 模型 ID 计数=$MODEL_COUNT"
    # 最小流式请求（带工具声明），max-time 限流以观察 Stop/断流；模型名 __probe__ 预期 4xx（须真实模型复核）
    CODE2=$(curl -s -o "$RAW.stream" -w "%{http_code}" --max-time 15 \
      -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
      -d '{"model":"__probe__","stream":true,"messages":[{"role":"user","content":"hi"}],"tools":[{"type":"function","function":{"name":"p","description":"probe","parameters":{"type":"object","properties":{}}}}]}' \
      "$CHAT_URL" 2>/dev/null)
    echo "  流式请求 -> HTTP $CODE2（响应存 $RAW.stream，脱敏；模型名 __probe__ 预期 4xx，真实模型名由模型目录回填）"
    # 错误语义抽样：无 Key 请求应 401（用于对比，不泄露 Key）
    CODE401=$(curl -s -o "$RAW.401" -w "%{http_code}" --max-time 15 "$MODELS_URL" 2>/dev/null)
    echo "  无 Key 模型目录 -> HTTP $CODE401（预期 401）"
    emit "$B" "defer" "已捕获模型目录与流式探针原始响应（HTTP $CODE/$CODE2，无Key对比 $CODE401）；真实套餐端到端与 GA 证据待回填" "$RAW"
    ;;
  *)
    echo "用法: $0 --check-env | --run --provider kimi|minimax"; exit 2
    ;;
esac
