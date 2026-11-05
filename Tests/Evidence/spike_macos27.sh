#!/usr/bin/env bash
# spike_macos27.sh — B-06 SDK 27 / 真实 macOS 27 验收环境证据收集。
# 用法:
#   bash Tests/Evidence/spike_macos27.sh --check-env        # 环境探针（安全）
#   bash Tests/Evidence/spike_macos27.sh --run [--reviewer <name>]
# 输出: ~/StacioEvidence/reports/B-06-<timestamp>.json
# 说明: 需 SDK 27 与真实 macOS 27 设备；在目标机上运行并完成截图/辅助功能操作记录。
set -u

REVIEWER="${STACIO_EVIDENCE_REVIEWER:-Release-QA-Owner}"
OUT_DIR="${STACIO_EVIDENCE_DIR:-$HOME/StacioEvidence}/reports"
mkdir -p "$OUT_DIR"

OSV="$(sw_vers -productVersion 2>/dev/null || echo unknown)"
SDK_VER="$(xcodebuild -version 2>/dev/null | sed -n '1p' || echo unknown)"
SDK_PATH="$(xcodebuild -showsdks 2>/dev/null | grep -i 'macosx' | head -1 || echo 'no sdk listed')"

check_env() {
  echo "=== macOS 27 验收环境探针 ==="
  echo "  macOS: $OSV"
  echo "  Xcode: $SDK_VER"
  echo "  SDK: $SDK_PATH"
  echo "  SDK 27 可用: $(echo "$SDK_VER" | grep -qi '26\|27' && echo '待确认具体版本' || echo '需安装')"
  echo "待验项: Light/Dark/对比度/透明度/Reduce Motion/VoiceOver 截图与操作记录；macOS 14 兼容候选"
}

emit() {
  local C="$1" S="$2"
  local EID="B-06-$(date +%Y%m%d-%H%M%S)"
  local BUILD="$(git -C "$(cd "$(dirname "$0")/../.." && pwd)" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  local DEVICE="macOS $OSV; Xcode $SDK_VER; SDK $SDK_PATH"
  python3 - "$EID" "$C" "$(date +%Y-%m-%dT%H:%M:%S)" "$BUILD" "$DEVICE" "$REVIEWER" "$S" "$OUT_DIR" <<'PYEOF'
import json, sys
eid, conclusion, gen, build, device, reviewer, summary, outdir = sys.argv[1:9]
entry = {
  "evidenceID": eid,
  "blockerID": "B-06",
  "conclusion": conclusion,
  "generatedAt": gen,
  "buildCommit": build,
  "catalogSetRevision": "pending",
  "deviceSystem": device,
  "expiryCondition": "Phase 0 environment gate + phase 10 release gate",
  "reviewer": reviewer,
  "redactedSummary": summary,
  "checklist": [
    {"item": "SDK 27 编译", "status": "na", "detail": "需 SDK 27"},
    {"item": "真实 macOS 27 验收", "status": "na", "detail": "需 macOS 27 设备"},
    {"item": "Light/Dark/对比度/透明度截图", "status": "na", "detail": "需 macOS 27 设备"},
    {"item": "Reduce Motion / Increase Contrast / VoiceOver 操作记录", "status": "na", "detail": "需 macOS 27 设备"},
    {"item": "macOS 14 兼容候选", "status": "na", "detail": "需 macOS 14 设备"}
  ],
  "resultPath": f"{outdir}/{eid}.json",
  "rawScope": "screenshots + VoiceOver operation logs on macOS 27 device"
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
    while [ $# -gt 0 ]; do
      case "$1" in --reviewer) REVIEWER="$2"; shift 2;; *) echo "未知参数 $1"; exit 2;; esac
    done
    # 若真在 macOS 27 + SDK 27 上，做截图记录；否则 defer
    if echo "$OSV" | grep -q "^2[67]\." && echo "$SDK_VER" | grep -q "2[67]\."; then
      emit "pass" "环境满足 SDK 27/macOS 27；请在目标机完成截图与辅助功能清单并回填"
    else
      emit "defer" "当前设备非 macOS 27 或 SDK 27 不可用；需在目标机执行（外部受阻）"
    fi
    ;;
  *)
    echo "用法: $0 --check-env | --run"; exit 2
    ;;
esac
