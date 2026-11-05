#!/usr/bin/env bash
# 校验本地私密证据目录 ~/StacioEvidence/ 的 manifest.json schema。
# 该目录永不提交；本脚本只校验本地私密证据字段完整。
# 通过：输出 "schema OK" 并退出 0；失败：列出缺失字段，退出非零。
set -u

PRIVATE_DIR="${STACIO_EVIDENCE_DIR:-$HOME/StacioEvidence}"
MANIFEST="$PRIVATE_DIR/manifest.json"
PY=python3

if [ ! -f "$MANIFEST" ]; then
  echo "FAIL: 本地私密证据 manifest 不存在: $MANIFEST（请创建 $PRIVATE_DIR/manifest.json）"
  exit 1
fi

# 私密 manifest 必填字段（与计划 P0-0 私密 schema 一致；永不入库）
REQUIRED_KEYS="evidenceID reportPath testAccountScope rawRecordPath generatedAt reviewer"

"$PY" - "$MANIFEST" "$REQUIRED_KEYS" <<'PYEOF'
import json, sys

manifest_path, req_keys = sys.argv[1], sys.argv[2].split()
try:
    with open(manifest_path, encoding="utf-8") as f:
        doc = json.load(f)
except Exception as e:
    print(f"FAIL: 无法解析 JSON: {e}")
    sys.exit(1)

errors = []
if not isinstance(doc, dict):
    print("FAIL: manifest 必须为对象")
    sys.exit(1)
for k in req_keys:
    if k not in doc:
        errors.append(f"缺失私密字段 {k}")

if errors:
    print("FAIL: 本地私密证据 manifest 校验未通过")
    for e in errors:
        print("  -", e)
    sys.exit(1)

print("schema OK: 本地私密证据 manifest 字段完整（永不提交）")
sys.exit(0)
PYEOF
