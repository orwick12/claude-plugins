#!/usr/bin/env bash
# run-checks.sh <plan-slug> <milestone-id | gate:<phase>>
#
# Runs the acceptance checks for one milestone (or one phase gate) from
# .claude/build-plans/<plan>/checks.json, prints a PASS/FAIL summary, and
# writes machine-readable results to .claude/build-plans/<plan>/results/.
#
# Exit codes: 0 all checks passed, 1 at least one failed, 3 could not run
# (missing plan, missing jq, no checks defined). Exit 3 is deliberately
# distinct so the hook can tell "config problem" from "code problem".
#
# checks.json shape:
# {
#   "defaults": { "timeout": 300, "cwd": "" },
#   "milestones": {
#     "1.1": { "checks": [
#       { "name": "unit tests",     "cmd": "npm test -- src/auth", "expect": "exit0" },
#       { "name": "401 without jwt","cmd": "curl -s -o /dev/null -w '%{http_code}' localhost:3000/me",
#         "expect": "equals", "value": "401" },
#       { "name": "no debug logs",  "cmd": "grep -rn 'console.log' src/auth || true",
#         "expect": "equals", "value": "" }
#     ]}
#   },
#   "gates": { "1": { "checks": [ ... ] } }
# }
# expect values: exit0 (default) | exit (value=code) | equals | contains | not_contains

set -u
HOOKS="$(cd "$(dirname "$0")" && pwd)"
. "$HOOKS/lib.sh"
ROOT=$(pv_root)
PLAN="${1:-}"; MID="${2:-}"
[ -n "$PLAN" ] && [ -n "$MID" ] || { echo "usage: run-checks.sh <plan> <milestone|gate:N>" >&2; exit 3; }

DIR="$ROOT/.claude/build-plans/$PLAN"
CHECKS="$DIR/checks.json"
[ -f "$CHECKS" ] || { echo "no checks.json at $CHECKS" >&2; exit 3; }
command -v jq >/dev/null 2>&1 || { echo "jq is required on PATH" >&2; exit 3; }
jq -e . "$CHECKS" >/dev/null 2>&1 || { echo "checks.json is not valid JSON" >&2; exit 3; }

case "$MID" in
  gate:*) KEY=".gates[\"${MID#gate:}\"]" ;;
  *)      KEY=".milestones[\"$MID\"]" ;;
esac

COUNT=$(jq -r "$KEY.checks | length" "$CHECKS" 2>/dev/null || echo 0)
if [ -z "$COUNT" ] || [ "$COUNT" = "null" ] || [ "$COUNT" = "0" ]; then
  echo "no acceptance checks defined for $MID in $CHECKS" >&2; exit 3
fi

DEF_TO=$(jq -r '.defaults.timeout // 300' "$CHECKS")
DEF_CWD=$(jq -r '.defaults.cwd // ""' "$CHECKS")
mkdir -p "$DIR/results"
if ! command -v timeout >/dev/null 2>&1 && ! command -v gtimeout >/dev/null 2>&1 && ! command -v perl >/dev/null 2>&1; then
  echo "warning: no timeout tool (timeout/gtimeout/perl); checks run without time limits" >&2
fi
SAFE_ID=$(printf '%s' "$MID" | tr ':/' '__')
OUT="$DIR/results/$SAFE_ID.json"
ROWS=$(mktemp)
pass=0; fail=0

echo "== checks for $PLAN / $MID =="
i=0; while [ "$i" -lt "$COUNT" ]; do
  q="$KEY.checks[$i]"
  name=$(jq -r "$q.name // (\"check \" + ($i|tostring))" "$CHECKS")
  cmd=$(jq -r "$q.cmd" "$CHECKS")
  expect=$(jq -r "$q.expect // \"exit0\"" "$CHECKS")
  value=$(jq -r "$q.value // \"\"" "$CHECKS")
  to=$(jq -r "$q.timeout // empty" "$CHECKS"); to=${to:-$DEF_TO}
  cwd_rel=$(jq -r "$q.cwd // empty" "$CHECKS"); cwd_rel=${cwd_rel:-$DEF_CWD}

  actual=$(cd "$ROOT/$cwd_rel" 2>/dev/null && PV_TIMEOUT="$to" pv_timeout bash -o pipefail -c "$cmd" 2>&1)
  code=$?
  trimmed=$(printf '%s' "$actual" | sed -e 's/[[:space:]]*$//' -e 's/^[[:space:]]*//')

  ok=false
  case "$expect" in
    exit0)        [ "$code" -eq 0 ] && ok=true ;;
    exit)         [ "$code" = "$value" ] && ok=true ;;
    equals)       [ "$trimmed" = "$value" ] && ok=true ;;
    contains)     printf '%s' "$actual" | grep -qF -- "$value" && ok=true ;;
    not_contains) printf '%s' "$actual" | grep -qF -- "$value" || ok=true ;;
    *)            actual="unknown expect type: $expect" ;;
  esac
  [ "$code" -eq 124 ] && { ok=false; actual="TIMEOUT after ${to}s"$'\n'"$actual"; }

  if $ok; then
    pass=$((pass+1)); echo "PASS  $name"
  else
    fail=$((fail+1)); echo "FAIL  $name  (exit $code, expect $expect${value:+ '$value'})"
    printf '%s\n' "$actual" | tail -n 25 | sed 's/^/      | /'
  fi
  jq -nc --arg n "$name" --arg c "$cmd" --arg e "$expect" --arg v "$value" \
         --argjson code "$code" --argjson ok "$ok" \
         --arg tail "$(printf '%s' "$actual" | tail -c 2000)" \
         '{name:$n,cmd:$c,expect:$e,value:$v,exit:$code,ok:$ok,output_tail:$tail}' >> "$ROWS"
  i=$((i+1))
done

status=$([ "$fail" -eq 0 ] && echo PASS || echo FAIL)
# State fingerprints so a result can only authorise the exact code and checks it tested.
checks_sha=$(pv_sha256 < "$CHECKS") || exit 3
tree_sha=$(pv_tree_sha "$ROOT") || exit 3
jq -s --arg plan "$PLAN" --arg id "$MID" --arg status "$status" \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg sha "$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo none)" \
      --arg run "$(date +%s)-$$" --arg csha "$checks_sha" --arg tsha "$tree_sha" \
      --argjson pass "$pass" --argjson fail "$fail" \
      '{plan:$plan,id:$id,status:$status,run_id:$run,ran_at:$ts,git:$sha,tree_sha:$tsha,checks_sha:$csha,pass:$pass,fail:$fail,checks:.}' "$ROWS" > "$OUT"
rm -f "$ROWS"

echo "== $status: $pass passed, $fail failed  (results: ${OUT#$ROOT/}) =="
[ "$fail" -eq 0 ]
