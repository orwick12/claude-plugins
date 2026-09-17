#!/usr/bin/env bash
# verify-milestone.sh — Stop hook for the milestone-builder subagents.
#
# When a builder tries to finish, this hook re-runs the milestone's acceptance
# checks itself (via run-checks.sh). It does not trust the builder's report.
#   - all checks pass            -> builder may stop
#   - checks fail                -> block, feed the failures back, builder keeps working
#   - fails MAX_ATTEMPTS times   -> allow stop; results/<id>.json says FAIL and
#                                   the main agent must read it (see SKILL.md)
#   - report ends STATUS: BLOCKED -> allow stop (builder is honestly stuck)
#   - no MILESTONE: line         -> block once, ask for the report format
#
# Reads hook JSON on stdin; uses last_assistant_message (documented for
# Stop/SubagentStop) rather than the transcript, which can lag.

set -u
HOOKS="$(cd "$(dirname "$0")" && pwd)"
. "$HOOKS/lib.sh"
input=$(cat)
[ -n "${CLAUDE_PROJECT_DIR:-}" ] || CLAUDE_PROJECT_DIR=$(jq -r '.cwd // "."' <<<"$input")
ROOT=$(pv_root)
msg=$(jq -r '.last_assistant_message // ""' <<<"$input")
MAX=${MILESTONE_MAX_ATTEMPTS:-3}

block() { jq -n --arg r "$1" '{decision:"block", reason:$r}'; exit 0; }

ref=$(grep -oE '^MILESTONE:[[:space:]]*[A-Za-z0-9._-]+/[A-Za-z0-9._:-]+' <<<"$msg" | head -1 | sed -E 's/^MILESTONE:[[:space:]]*//')
if [ -z "$ref" ]; then
  block "Your final message must contain a line 'MILESTONE: <plan>/<id>' and follow the report format in your work order (Changed / Checks / Open questions / STATUS). If you cannot complete the milestone, end with 'STATUS: BLOCKED' and say why."
fi
plan=${ref%%/*}; mid=${ref#*/}

# Honest "I am stuck" lets the builder stop, but a BLOCKED result must
# overwrite any earlier PASS so it can never authorise acceptance.
if grep -qE '^STATUS:[[:space:]]*BLOCKED' <<<"$msg"; then
  d="$ROOT/.claude/build-plans/$plan/results"; mkdir -p "$d"
  jq -n --arg plan "$plan" --arg id "$mid" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{plan:$plan,id:$id,status:"BLOCKED",ran_at:$ts,pass:0,fail:0,checks:[]}' > "$d/$(printf '%s' "$mid" | tr ':/' '__').json"
  exit 0
fi

res_dir="$ROOT/.claude/build-plans/$plan/results"; mkdir -p "$res_dir"
# Recovery point on every finish attempt, so a bad fix round can be undone.
bash "$HOOKS/snapshot.sh" "$plan" "$mid" finish-attempt >/dev/null 2>&1 || true
attempts_file="$res_dir/$(printf '%s' "$mid" | tr ':/' '__').attempts"
n=$(cat "$attempts_file" 2>/dev/null || echo 0)

if ! lockmsg=$(bash "$HOOKS/lock-hooks.sh" verify "$plan" 2>&1); then
  block "This plan's hooks.lock does not match the installed plan-and-verify scripts (or is missing): $(printf '%s' "$lockmsg" | head -c 600). Nothing you can fix in code; end with STATUS: BLOCKED so the main agent can re-lock and commit."
fi
out=$(bash "$HOOKS/run-checks.sh" "$plan" "$mid" 2>&1); code=$?
out=$(printf '%s' "$out" | tail -c 6000)   # stay under the 10k hook output cap

if [ "$code" -eq 0 ]; then
  echo 0 > "$attempts_file"
  exit 0
fi

if [ "$code" -eq 3 ]; then
  block "Acceptance checks could not run (config problem, not a code problem):
$out
Either the MILESTONE line names the wrong plan/id, or checks.json has no checks for it. Fix that, or end with STATUS: BLOCKED explaining the problem."
fi

n=$((n+1)); echo "$n" > "$attempts_file"
if [ "$n" -ge "$MAX" ]; then
  # Give up looping. Results file records FAIL; main agent must not accept this milestone.
  jq -n --arg n "$n" --arg id "$ref" \
    '{systemMessage:("Milestone " + $id + " still failing acceptance checks after " + $n + " attempts. Builder allowed to stop; results file records FAIL.")}'
  exit 0
fi

block "Acceptance checks FAILED (attempt $n of $MAX). Do not report success. Read the failures below, fix the code (not the checks), re-run 'bash \"$HOOKS/run-checks.sh\" $plan $mid' yourself, then finish with the report format again.
$out"
