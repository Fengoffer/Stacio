#!/usr/bin/env bash
# run_all_spikes.sh — 编排 B-01..B-06 证据 spike 的 --check-env 安全探测，并打印真实 --run 用法。
# 不会发起任何需要真实账号/Key/签名构建/目标机的操作。
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"

echo "======================================================"
echo " Stacio V2 阶段 0 证据 spike 编排（--check-env 安全模式）"
echo "======================================================"
for spike in spike_containment spike_plan_compat spike_provider_protocol spike_macos27; do
  echo
  echo ">>> $spike --check-env"
  bash "$DIR/$spike.sh" --check-env
done

echo
echo "======================================================"
echo " 真实证据收集（需外部资源，在目标环境执行）"
echo "======================================================"
cat <<EOF
  B-01: bash Tests/Evidence/spike_containment.sh --run <notarized_app_path>
        # 需 Developer ID/Hardened Runtime/notarized 构建 + managed profile
  B-02: PLAN_KEY_ALIYUN=<...> bash Tests/Evidence/spike_plan_compat.sh --run --plan aliyun --cli <path>
  B-03: PLAN_KEY_GLM=<...> bash Tests/Evidence/spike_plan_compat.sh --run --plan glm --cli <path>
  B-04: KIMI_KEY=<...> bash Tests/Evidence/spike_provider_protocol.sh --run --provider kimi
  B-05: MINIMAX_KEY=<...> bash Tests/Evidence/spike_provider_protocol.sh --run --provider minimax
  B-06: bash Tests/Evidence/spike_macos27.sh --run     # 需在 SDK27/macOS27 目标机执行

  每项输出 ~/StacioEvidence/reports/<evidenceID>.json，随后:
  bash Tests/Evidence/backfill_evidence.sh ~/StacioEvidence/reports/<evidenceID>.json
EOF
