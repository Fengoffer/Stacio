#!/usr/bin/env bash
# Real Provider E2E gate. A missing credential or executable harness is a
# blocked run (exit 78), never a passing E2E result.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
MANIFEST="$SCRIPT_DIR/scenarios.json"
SCHEMA="$SCRIPT_DIR/report.schema.json"
SCENARIO="${1:-}"

if [ -z "$SCENARIO" ]; then
  echo "usage: run_e2e.sh <scenario-id>" >&2
  exit 64
fi

REPORT="${STACIO_V2_E2E_REPORT:-$REPO_ROOT/.build/v2-e2e-reports/$SCENARIO.json}"
mkdir -p "$(dirname "$REPORT")"

SCENARIO_JSON="$(python3 - "$MANIFEST" "$SCENARIO" <<'PY'
import json, sys
manifest_path, scenario_id = sys.argv[1:]
with open(manifest_path, encoding="utf-8") as stream:
    manifest = json.load(stream)
matches = [item for item in manifest.get("scenarios", []) if item.get("id") == scenario_id]
if len(matches) != 1:
    print(f"unknown or duplicate scenario: {scenario_id}", file=sys.stderr)
    raise SystemExit(64)
print(json.dumps(matches[0], separators=(",", ":")))
PY
)"

BUILD_COMMIT="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || printf unknown)"
CATALOG_REVISION="$(python3 - "$REPO_ROOT/Stacio/Resources/RuntimeCatalog/runtime-catalog-manifest-v1.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    print(int(json.load(stream)["catalogSetRevision"]))
PY
)"

write_blocked_report() {
  local reason="$1"
  python3 - "$REPORT" "$SCENARIO" "$BUILD_COMMIT" "$CATALOG_REVISION" "$reason" <<'PY'
import json, os, sys
path, scenario_id, commit, revision, reason = sys.argv[1:]
payload = {
    "scenarioID": scenario_id,
    "buildCommit": commit,
    "catalogRevision": int(revision),
    "result": "blocked",
    "statusReason": reason,
    "redactedSummary": reason,
    "cleanupVerification": False,
}
temporary = path + ".tmp"
with open(temporary, "w", encoding="utf-8") as stream:
    json.dump(payload, stream, ensure_ascii=False, indent=2, sort_keys=True)
    stream.write("\n")
os.replace(temporary, path)
PY
}

HARNESS="${STACIO_V2_E2E_HARNESS:-}"
if [ -z "$HARNESS" ] || [ ! -x "$HARNESS" ]; then
  write_blocked_report "BLOCKED: STACIO_V2_E2E_HARNESS is not an executable real-integration harness"
  echo "BLOCKED: real Provider E2E harness is unavailable; report: $REPORT" >&2
  exit 78
fi

MISSING_ENV="$(python3 - "$SCENARIO_JSON" <<'PY'
import json, os, sys
scenario = json.loads(sys.argv[1])
missing = [name for name in scenario.get("requiredEnvironment", []) if not os.environ.get(name, "").strip()]
print(",".join(missing))
PY
)"
if [ -n "$MISSING_ENV" ]; then
  write_blocked_report "BLOCKED: missing required environment references: $MISSING_ENV"
  echo "BLOCKED: missing required environment references: $MISSING_ENV; report: $REPORT" >&2
  exit 78
fi

STACIO_E2E_TMP="$(mktemp -d "${TMPDIR:-/tmp}/stacio-v2-e2e.XXXXXX")"
cleanup() {
  rm -rf "$STACIO_E2E_TMP"
}
trap cleanup EXIT

set +e
STACIO_V2_E2E_SCENARIO_JSON="$SCENARIO_JSON" \
STACIO_V2_E2E_MANIFEST="$MANIFEST" \
STACIO_V2_E2E_SCHEMA="$SCHEMA" \
STACIO_V2_E2E_REPORT="$REPORT" \
STACIO_V2_E2E_ISOLATION_DIR="$STACIO_E2E_TMP" \
STACIO_V2_E2E_BUILD_COMMIT="$BUILD_COMMIT" \
STACIO_V2_E2E_CATALOG_REVISION="$CATALOG_REVISION" \
  "$HARNESS" "$SCENARIO"
HARNESS_STATUS=$?
set -e

if [ ! -f "$REPORT" ]; then
  echo "FAIL: harness returned $HARNESS_STATUS without producing report: $REPORT" >&2
  exit 1
fi

python3 - "$REPORT" "$SCENARIO" "$BUILD_COMMIT" "$CATALOG_REVISION" "$STACIO_E2E_TMP" "$HARNESS_STATUS" <<'PY'
import json, os, sys
report_path, scenario_id, commit, revision, isolation_dir, harness_status = sys.argv[1:]
with open(report_path, encoding="utf-8") as stream:
    report = json.load(stream)
required = {
    "scenarioID": str,
    "buildCommit": str,
    "catalogRevision": int,
    "result": str,
    "redactedSummary": str,
    "cleanupVerification": bool,
}
errors = []
for key, expected_type in required.items():
    if key not in report or not isinstance(report[key], expected_type):
        errors.append(f"invalid {key}")
if report.get("scenarioID") != scenario_id:
    errors.append("scenarioID mismatch")
if report.get("buildCommit") != commit:
    errors.append("buildCommit mismatch")
if report.get("catalogRevision") != int(revision):
    errors.append("catalogRevision mismatch")
if int(harness_status) != 0:
    errors.append(f"harness exit {harness_status}")
if report.get("result") != "pass":
    errors.append(f"result is {report.get('result')!r}")
if report.get("cleanupVerification") is not True:
    errors.append("cleanupVerification is not true")
if os.path.isdir(isolation_dir) and os.listdir(isolation_dir):
    errors.append("isolation directory is not empty")

# Credentials stay in the harness environment. A report containing an exact
# configured secret is rejected without printing the secret itself.
serialized = json.dumps(report, ensure_ascii=False)
for name, value in os.environ.items():
    if (name.endswith("_API_KEY") or name.endswith("_TOKEN")) and len(value) >= 8 and value in serialized:
        errors.append(f"report contains secret from {name}")

if errors:
    print("FAIL: " + "; ".join(errors), file=sys.stderr)
    raise SystemExit(1)
PY

echo "PASS: real Provider E2E $SCENARIO; report: $REPORT"
