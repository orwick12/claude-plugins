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
#   - not a builder              -> exit silently (the hook is registered without a
#                                   matcher and runs for every subagent, internal ones too)
#
# Reads hook JSON on stdin. The report is taken from last_assistant_message when it
# carries a MILESTONE line, else from the agent transcript: background builders hand
# their report back with a SubagentHandback tool call before they stop, and the last
# message is then only "report delivered".

set -u
HOOKS="$(cd "$(dirname "$0")" && pwd)"
. "$HOOKS/lib.sh"
input=$(cat)
pv_is_builder "$(jq -r '.agent_type // ""' <<<"$input")" || exit 0
[ -n "${CLAUDE_PROJECT_DIR:-}" ] || CLAUDE_PROJECT_DIR=$(jq -r '.cwd // "."' <<<"$input")
ROOT=$(pv_root)
active=$(jq -r '.stop_hook_active // false' <<<"$input")
MAX=${MILESTONE_MAX_ATTEMPTS:-3}
REF_RE='^MILESTONE:[[:space:]]*[A-Za-z0-9._-]+/[A-Za-z0-9._:-]+'

block() { jq -n --arg r "$1" '{decision:"block", reason:$r}'; exit 0; }
# For problems a builder may be unable to fix: block the first time only. If this stop
# already follows a block, let it stop with a note, so no agent is ever looped here.
block_once() {
  [ "$active" = "true" ] || block "$1"
  jq -n --arg r "$1" '{systemMessage:("plan-and-verify: builder allowed to stop after a second unusable finish. " + $r)}'; exit 0
}

msg=$(jq -r '.last_assistant_message // ""' <<<"$input")
src="last assistant message"
if ! grep -qE "$REF_RE" <<<"$msg"; then
  tp=$(jq -r '.agent_transcript_path // ""' <<<"$input")
  if [ -n "$tp" ] && [ -f "$tp" ]; then
    msg=$(pv_transcript_report "$tp")
    src="handback or text in the agent transcript"
  fi
fi

ref=$(grep -oE "$REF_RE" <<<"$msg" | head -1 | sed -E 's/^MILESTONE:[[:space:]]*//')
if [ -z "$ref" ]; then
  block_once "Your final message must contain a line 'MILESTONE: <plan>/<id>' and follow the report format in your work order (Changed / Checks / Open questions / STATUS). If you cannot complete the milestone, end with 'STATUS: BLOCKED' and say why."
fi
plan=${ref%%/*}; mid=${ref#*/}
if [ ! -f "$ROOT/.claude/build-plans/$plan/checks.json" ]; then
  block_once "Your report names plan '$plan', but this project has no .claude/build-plans/$plan/checks.json. Fix the MILESTONE line to the plan and id in your work order, or end with STATUS: BLOCKED explaining the problem."
fi

# Every exit path below leaves a heartbeat. An unattended orchestrator cannot otherwise
# tell "the hook ran and was happy" from "the hook never ran at all".
agent_id=$(jq -r '.agent_id // ""' <<<"$input")
# The builder is no longer writing, so its marker says "stopped" — but it stays. Stopping
# is not finishing: the orchestrator resumes a stopped builder, and until the milestone is
# accepted this tree is still mid-milestone. Only accept-milestone.sh retires a marker (F46).
rd=$(pv_run_dir "$ROOT" "$plan" 2>/dev/null) && mk=$(pv_marker_path "$rd" "$mid") && [ -f "$mk" ] && {
  jq --arg a "$agent_id" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '. + {state:"stopped",stopped_at:$ts} | if (.agent_id // "") == "" then .agent_id = $a else . end' \
    "$mk" > "$mk.tmp" 2>/dev/null && mv "$mk.tmp" "$mk" || rm -f "$mk.tmp"
}
beat() {
  pv_log_event "$ROOT" "$plan" hook-events "$(jq -nc --arg id "$mid" --arg a "$agent_id" \
    --arg o "$1" --arg d "${2:-}" '{actor:"hook:verify-milestone",id:$id,agent:$a,outcome:$o,detail:$d}')"
}

# The report the hook actually verified, kept where the orchestrator can read it: a
# builder that is sent back cannot deliver a second hand-back (F36).
pv_write_report "$ROOT" "$plan" "$mid" "$src" "$agent_id" "$msg"

# Honest "I am stuck" lets the builder stop, but a BLOCKED result must
# overwrite any earlier PASS so it can never authorise acceptance. It must not overwrite
# the evidence: the last run's failing checks are what the orchestrator adjudicates next,
# and a stub of zero checks told it the builder gave up for no recorded reason (F42).
if grep -qE '^STATUS:[[:space:]]*BLOCKED' <<<"$msg"; then
  d="$ROOT/.claude/build-plans/$plan/results"; mkdir -p "$d"
  f="$d/$(printf '%s' "$mid" | tr ':/' '__').json"
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  if [ -f "$f" ] && jq -e . "$f" >/dev/null 2>&1; then
    jq --arg ts "$ts" '. + {previous_status:(.status // "none"), status:"BLOCKED", blocked_at:$ts}' "$f" \
      > "$f.tmp" && mv "$f.tmp" "$f" || rm -f "$f.tmp"
  else
    jq -n --arg plan "$plan" --arg id "$mid" --arg ts "$ts" \
      '{plan:$plan,id:$id,status:"BLOCKED",ran_at:$ts,blocked_at:$ts,pass:0,fail:0,checks:[]}' > "$f"
  fi
  beat blocked-by-builder "builder reported STATUS: BLOCKED"
  exit 0
fi

res_dir="$ROOT/.claude/build-plans/$plan/results"; mkdir -p "$res_dir"
# Recovery point on every finish attempt, so a bad fix round can be undone.
bash "$HOOKS/snapshot.sh" "$plan" "$mid" finish-attempt >/dev/null 2>&1 || true
attempts_file="$res_dir/$(printf '%s' "$mid" | tr ':/' '__').attempts"
# The budget belongs to the agent, not to the milestone: a second builder on the same
# milestone (an escalation to opus) must get its own fix rounds, while a resumed builder
# keeps counting. The file holds "<agent id> <n>"; a bare number is the pre-1.2.0 shape.
prev=$(cat "$attempts_file" 2>/dev/null || echo "")
prev_agent=${prev% *}; prev_n=${prev##* }
case "$prev" in *\ *) ;; *) prev_agent=""; prev_n=$prev ;; esac
case "$prev_n" in ''|*[!0-9]*) prev_n=0 ;; esac
if [ -n "$agent_id" ] && [ -n "$prev_agent" ] && [ "$prev_agent" != "$agent_id" ]; then
  n=0                      # a different builder: fresh budget
else
  n=$prev_n
fi
write_attempts() { printf '%s %s\n' "${agent_id:-unknown}" "$1" > "$attempts_file"; }

if ! lockmsg=$(bash "$HOOKS/lock-hooks.sh" verify "$plan" 2>&1); then
  beat lock-mismatch "installed scripts differ from hooks.lock"
  block "This plan's hooks.lock does not match the installed plan-and-verify scripts (or is missing): $(printf '%s' "$lockmsg" | head -c 600). Nothing you can fix in code; end with STATUS: BLOCKED so the main agent can re-lock and commit."
fi
out=$(bash "$HOOKS/run-checks.sh" "$plan" "$mid" 2>&1); code=$?
out=$(printf '%s' "$out" | tail -c 6000)   # stay under the 10k hook output cap

if [ "$code" -eq 0 ]; then
  write_attempts 0
  beat checks-passed "builder allowed to stop"
  exit 0
fi

if [ "$code" -eq 3 ]; then
  beat checks-unrunnable "run-checks.sh exit 3"
  block_once "Acceptance checks could not run (config problem, not a code problem):
$out
Either the MILESTONE line names the wrong plan/id, or checks.json has no checks for it. Fix that, or end with STATUS: BLOCKED explaining the problem."
fi

n=$((n+1)); write_attempts "$n"
if [ "$n" -ge "$MAX" ]; then
  # Give up looping. Results file records FAIL; main agent must not accept this milestone.
  beat attempts-exhausted "still failing after $n attempts"
  jq -n --arg n "$n" --arg id "$ref" \
    '{systemMessage:("Milestone " + $id + " still failing acceptance checks after " + $n + " attempts. Builder allowed to stop; results file records FAIL.")}'
  exit 0
fi

beat blocked "checks failed, attempt $n of $MAX"
block "Acceptance checks FAILED (attempt $n of $MAX). Do not report success. Read the failures below, fix the code (not the checks), re-run 'bash \"$HOOKS/run-checks.sh\" $plan $mid' yourself, then finish. Do NOT call SubagentHandback again: it delivers one report per run and a second call is refused. End with your report as your final message instead.
$out"
