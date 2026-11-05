#!/usr/bin/env bash
# 校验公开证据索引 Tests/Evidence/evidence-index.json。
# 通过：输出 "schema OK" 并退出 0。
# 失败：输出缺失/非法项，退出非零。绝不触碰任何业务文件。
set -u

INDEX="$(cd "$(dirname "$0")" && pwd)/evidence-index.json"
PY=python3

if [ ! -f "$INDEX" ]; then
  echo "FAIL: 公开证据索引不存在: $INDEX"
  exit 1
fi

# 每个条目必填字段（与计划 P0-0 公开索引 schema 一致）
REQUIRED_KEYS="evidenceID buildCommit catalogSetRevision deviceSystem generatedAt expiryCondition reviewer conclusion redactedSummary blockerIDs"
# 合法结论
VALID_CONCLUSIONS="pass fail defer"
# 禁止出现在键名中的字段（公开索引不得含私密）
FORBIDDEN_KEYS="testAccount authorizationScope rawRecord credential secret"
# 敏感关键词（大小写不敏感），值中出现即失败
SENSITIVE_SUBSTRINGS="secret password token apikey api-key privatekey authorization oauth credential"

"$PY" - "$INDEX" "$REQUIRED_KEYS" "$VALID_CONCLUSIONS" "$FORBIDDEN_KEYS" "$SENSITIVE_SUBSTRINGS" <<'PYEOF'
import json, sys, re

index_path, req_keys, valid_conc, forb_keys, sens_subs = sys.argv[1], sys.argv[2].split(), sys.argv[3].split(), sys.argv[4].split(), sys.argv[5].split()

try:
    with open(index_path, encoding="utf-8") as f:
        doc = json.load(f)
except Exception as e:
    print(f"FAIL: 无法解析 JSON: {e}")
    sys.exit(1)

if not isinstance(doc, dict) or "entries" not in doc or not isinstance(doc["entries"], list):
    print("FAIL: 顶层必须为对象且含 entries 数组")
    sys.exit(1)

errors = []
for i, entry in enumerate(doc["entries"]):
    if not isinstance(entry, dict):
        errors.append(f"entries[{i}]: 不是对象")
        continue
    for k in req_keys:
        if k not in entry:
            errors.append(f"entries[{i}]: 缺失必填字段 {k}")
    if "conclusion" in entry and entry["conclusion"] not in valid_conc:
        errors.append(f"entries[{i}]: conclusion 非法 {entry['conclusion']}")
    # 禁止键名
    for k in entry:
        if any(fk in k.lower() for fk in forb_keys):
            errors.append(f"entries[{i}]: 公开索引含禁止键 {k}")
    # 敏感值扫描（脱敏摘要应不含）
    def walk(v):
        found = []
        if isinstance(v, str):
            low = v.lower()
            for s in sens_subs:
                if s in low:
                    found.append(s)
        elif isinstance(v, list):
            for it in v:
                found.extend(walk(it))
        elif isinstance(v, dict):
            for it in v.values():
                found.extend(walk(it))
        return found
    for hit in walk(entry):
        errors.append(f"entries[{i}]: 敏感关键词 {hit} 出现在公开索引（禁止）")

if errors:
    print("FAIL: 公开证据索引校验未通过")
    for e in errors:
        print("  -", e)
    sys.exit(1)

print("schema OK: 公开证据索引字段完整且不含敏感内容")
sys.exit(0)
PYEOF
