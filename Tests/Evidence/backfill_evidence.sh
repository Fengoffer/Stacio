#!/usr/bin/env bash
# backfill_evidence.sh — 把 spike 生成的证据结果回填到公开索引与本地私密清单。
# 用法: bash Tests/Evidence/backfill_evidence.sh <~/StacioEvidence/reports/<evidenceID>.json>
# 行为:
#   1. 校验结果文件必填字段（证据ID/阻塞ID/结论/时间/设备/失效条件/审核人/脱敏摘要/检查清单）。
#   2. 对 redactedSummary 与 checklist detail 做敏感扫描；命中即拒绝回填。
#   3. 向 Tests/Evidence/evidence-index.json 追加一条脱敏公开条目（不含 resultPath/原始记录）。
#   4. 向 ~/StacioEvidence/manifest.json 追加私密条目（resultPath/rawScope/checklist）。
#   5. 重新运行两套 schema 校验；任一失败则回滚本脚本对该文件的改动。
set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INDEX="$REPO_ROOT/Tests/Evidence/evidence-index.json"
PRIVATE_DIR="${STACIO_EVIDENCE_DIR:-$HOME/StacioEvidence}"
PRIVATE_MANIFEST="$PRIVATE_DIR/manifest.json"
PY=python3

if [ $# -lt 1 ]; then
  echo "用法: $0 <result.json>"
  exit 2
fi
RESULT="$1"
if [ ! -f "$RESULT" ]; then
  echo "FAIL: 结果文件不存在: $RESULT"
  exit 1
fi

# 备份索引以便失败回滚
cp "$INDEX" /tmp/evidence-index.bak.$$.json
cp "$PRIVATE_MANIFEST" /tmp/evidence-manifest.bak.$$.json

"$PY" - "$RESULT" "$INDEX" "$PRIVATE_MANIFEST" <<'PYEOF'
import json, sys, datetime, os, re

result_path, index_path, manifest_path = sys.argv[1], sys.argv[2], sys.argv[3]
SENS = ["secret","password","token","apikey","api-key","privatekey","authorization","oauth","credential"]

def walk(v):
    found=[]
    if isinstance(v,str):
        low=v.lower()
        for s in SENS:
            if s in low: found.append(s)
    elif isinstance(v,list):
        for it in v: found.extend(walk(it))
    elif isinstance(v,dict):
        for it in v.values(): found.extend(walk(it))
    return found

try:
    with open(result_path, encoding="utf-8") as f:
        r = json.load(f)
except Exception as e:
    print(f"FAIL: 无法解析结果文件: {e}")
    sys.exit(1)

required = ["evidenceID","blockerID","conclusion","generatedAt","deviceSystem","expiryCondition","reviewer","redactedSummary","checklist"]
missing = [k for k in required if k not in r]
if missing:
    print("FAIL: 结果文件缺失字段:", missing)
    sys.exit(1)
if r["conclusion"] not in ("pass","fail","defer"):
    print("FAIL: conclusion 非法:", r["conclusion"])
    sys.exit(1)
hits = walk({"redactedSummary": r["redactedSummary"], "checklist": r["checklist"]})
if hits:
    print("FAIL: 结果含敏感内容，拒绝回填:", hits)
    sys.exit(1)

# 公开条目（脱敏，不含 resultPath/rawScope）
public_entry = {
    "evidenceID": r["evidenceID"],
    "buildCommit": r.get("buildCommit",""),
    "catalogSetRevision": r.get("catalogSetRevision",""),
    "deviceSystem": r["deviceSystem"],
    "generatedAt": r["generatedAt"],
    "expiryCondition": r["expiryCondition"],
    "reviewer": r["reviewer"],
    "conclusion": r["conclusion"],
    "redactedSummary": r["redactedSummary"],
    "blockerIDs": [r["blockerID"]],
}
# 私密条目（含 resultPath/rawScope/完整 checklist）
private_entry = {
    "evidenceID": r["evidenceID"],
    "blockerID": r["blockerID"],
    "resultPath": r.get("resultPath", result_path),
    "rawScope": r.get("rawScope", ""),
    "checklist": r["checklist"],
    "generatedAt": r["generatedAt"],
    "reviewer": r["reviewer"],
}

with open(index_path, encoding="utf-8") as f:
    idx = json.load(f)
# 幂等：同一 evidenceID 更新而非追加
idx["entries"] = [e for e in idx.get("entries", []) if e.get("evidenceID") != r["evidenceID"]]
idx["entries"].append(public_entry)
with open(index_path, "w", encoding="utf-8") as f:
    json.dump(idx, f, ensure_ascii=False, indent=2)

with open(manifest_path, encoding="utf-8") as f:
    man = json.load(f)
man.setdefault("entries", [])
man["entries"] = [e for e in man["entries"] if e.get("evidenceID") != r["evidenceID"]]
man["entries"].append(private_entry)
with open(manifest_path, "w", encoding="utf-8") as f:
    json.dump(man, f, ensure_ascii=False, indent=2)

print("OK: 已回填", r["evidenceID"], "-> 公开索引 + 私密清单")
sys.exit(0)
PYEOF

rc=$?
if [ $rc -ne 0 ]; then
  cp /tmp/evidence-index.bak.$$.json "$INDEX"
  cp /tmp/evidence-manifest.bak.$$.json "$PRIVATE_MANIFEST"
  rm -f /tmp/evidence-index.bak.$$.json /tmp/evidence-manifest.bak.$$.json
  echo "已回滚：公开索引与私密清单保持原状"
  exit $rc
fi
rm -f /tmp/evidence-index.bak.$$.json /tmp/evidence-manifest.bak.$$.json

# 回填后重校验
echo "--- 重校验 ---"
bash "$REPO_ROOT/Tests/Evidence/evidence_schema_test.sh" || { echo "公开索引校验失败"; exit 1; }
bash "$REPO_ROOT/Tests/Evidence/private_evidence_schema_test.sh" || { echo "私密清单校验失败"; exit 1; }
echo "回填完成且校验通过"
