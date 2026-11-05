#!/usr/bin/env bash
# Feature-flag drain drill gate. Policy unit tests are a preflight only; an
# executable control-plane harness and a validated cleanup report are required.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
MANIFEST="$SCRIPT_DIR/scenarios.json"
SCHEMA="$SCRIPT_DIR/report.schema.json"
SCENARIO="${1:-}"

if [ -z "$SCENARIO" ]; then
  echo "usage: run_drain.sh <scenario-id>" >&2
  exit 64
fi

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

REPORT="${STACIO_V2_DRAIN_REPORT:-$REPO_ROOT/.build/v2-drain-reports/$SCENARIO.json}"
mkdir -p "$(dirname "$REPORT")"
BUILD_COMMIT="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || printf unknown)"

write_blocked_report() {
  local reason="$1"
  python3 - "$REPORT" "$SCENARIO" "$BUILD_COMMIT" "$reason" <<'PY'
import json, os, sys
path, scenario_id, commit, reason = sys.argv[1:]
payload = {
    "scenarioID": scenario_id,
    "buildCommit": commit,
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

HARNESS="${STACIO_V2_DRAIN_HARNESS:-}"
if [ -z "$HARNESS" ] || [ ! -x "$HARNESS" ]; then
  write_blocked_report "BLOCKED: STACIO_V2_DRAIN_HARNESS is not an executable control-plane harness"
  echo "BLOCKED: drain harness is unavailable; policy tests alone are not E2E evidence; report: $REPORT" >&2
  exit 78
fi

if ! (cd "$REPO_ROOT" && swift test --filter V2DrainDrillTests); then
  echo "FAIL: V2DrainDrillTests policy preflight failed" >&2
  exit 1
fi

STACIO_DRAIN_TMP="$(mktemp -d "${TMPDIR:-/tmp}/stacio-v2-drain.XXXXXX")"
cleanup() {
  rm -rf "$STACIO_DRAIN_TMP"
}
trap cleanup EXIT

set +e
STACIO_V2_DRAIN_SCENARIO_JSON="$SCENARIO_JSON" \
STACIO_V2_DRAIN_MANIFEST="$MANIFEST" \
STACIO_V2_DRAIN_SCHEMA="$SCHEMA" \
STACIO_V2_DRAIN_REPORT="$REPORT" \
STACIO_V2_DRAIN_ISOLATION_DIR="$STACIO_DRAIN_TMP" \
STACIO_V2_DRAIN_BUILD_COMMIT="$BUILD_COMMIT" \
  "$HARNESS" "$SCENARIO"
HARNESS_STATUS=$?
set -e

if [ ! -f "$REPORT" ]; then
  echo "FAIL: harness returned $HARNESS_STATUS without producing report: $REPORT" >&2
  exit 1
fi

python3 - "$REPORT" "$SCENARIO" "$BUILD_COMMIT" "$STACIO_DRAIN_TMP" "$HARNESS_STATUS" <<'PY'
import json, os, sys
report_path, scenario_id, commit, isolation_dir, harness_status = sys.argv[1:]
with open(report_path, encoding="utf-8") as stream:
    report = json.load(stream)
required = {
    "scenarioID": str,
    "buildCommit": str,
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
if int(harness_status) != 0:
    errors.append(f"harness exit {harness_status}")
if report.get("result") != "pass":
    errors.append(f"result is {report.get('result')!r}")
if report.get("cleanupVerification") is not True:
    errors.append("cleanupVerification is not true")
if os.path.isdir(isolation_dir) and os.listdir(isolation_dir):
    errors.append("isolation directory is not empty")
if errors:
    print("FAIL: " + "; ".join(errors), file=sys.stderr)
    raise SystemExit(1)
PY

echo "PASS: V2 drain drill $SCENARIO; report: $REPORT"
