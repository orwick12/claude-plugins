#!/usr/bin/env bash
# capture-review.sh — Stop hook for the milestone-reviewer subagents.
#
# Acceptance reads structured, artifact-bound review evidence; raw Markdown is
# diagnostic. Findings used to live only in a hand-back message. This hook keeps the
# review next to the milestone's results and holds the reviewer to the severity rule in
# its own contract: a [med] or [high] finding is a REJECT (F45).
#   - review captured                          -> results/<id>.review.md, verdict logged
#   - ACCEPT/ACCEPT-WITH-NOTES with [med]/[high] -> block once, the verdict must change
#   - no Verdict: line                         -> block once, ask for it
#   - no MILESTONE: line                       -> block once, ask for the report format
#   - a plan this project does not have        -> exit silently, create nothing
#   - not a reviewer                           -> exit silently (the hook is registered
#                                                 without a matcher, like the builder one)
#
# Reads hook JSON on stdin. The report is taken from last_assistant_message when it
# carries a MILESTONE line, else from the agent transcript, exactly as verify-milestone.sh
# does it: a background reviewer hands its report back before it stops.

set -u
HOOKS="$(cd "$(dirname "$0")" && pwd)"
. "$HOOKS/evidence.sh"
input=$(cat)
pv_is_reviewer "$(jq -r '.agent_type // ""' <<<"$input")" || exit 0
[ -n "${CLAUDE_PROJECT_DIR:-}" ] || CLAUDE_PROJECT_DIR=$(jq -r '.cwd // "."' <<<"$input")
ROOT=$(pv_root)
active=$(jq -r '.stop_hook_active // false' <<<"$input")
agent_id=$(jq -r '.agent_id // ""' <<<"$input")

# A reviewer cannot always fix what it is asked for, so block the first time only: if this
# stop already follows a block, let it stop with a note rather than loop the agent here.
block_once() {
  if [ "$active" != "true" ]; then jq -n --arg r "$1" '{decision:"block", reason:$r}'; exit 0; fi
  jq -n --arg r "$1" '{systemMessage:("plan-and-verify: reviewer allowed to stop after a second unusable review. " + $r)}'; exit 0
}

msg=$(jq -r '.last_assistant_message // ""' <<<"$input")
src="last assistant message"
if [ -z "$(pv_report_ref "$msg")" ]; then
  from_tp=$(pv_transcript_report "$(jq -r '.agent_transcript_path // ""' <<<"$input")")
  if [ -n "$from_tp" ]; then msg="$from_tp"; src="handback or text in the agent transcript"; fi
fi

ref=$(pv_report_ref "$msg")
if [ -z "$ref" ]; then
  block_once "Your review must contain a line 'MILESTONE: <plan>/<id>' naming the milestone you reviewed, grade every finding as a '- [low]', '- [med]' or '- [high]' bullet, and end with 'Verdict: ACCEPT | ACCEPT-WITH-NOTES | REJECT' as its last line."
fi
plan=${ref%%/*}; mid=${ref#*/}
# A misfired MILESTONE line must never make a directory for a plan this project lacks.
[ -f "$ROOT/.claude/build-plans/$plan/checks.json" ] || exit 0

log() {
  pv_log_event "$ROOT" "$plan" hook-events "$(jq -nc --arg id "$mid" --arg a "$agent_id" \
    --arg o "$1" --arg d "${2:-}" '{actor:"hook:capture-review",id:$id,agent:$a,outcome:$o,detail:$d}')"
}

# Stored before any block: the notes are what the orchestrator acts on, and a reviewer
# that is sent back cannot deliver this report a second time.
safe=$(printf '%s' "$mid" | tr ':/' '__')
pv_write_report "$ROOT" "$plan" "$mid" "$src" "$agent_id" "$msg" review.md

# Raw Markdown is diagnostic only. Acceptance consumes the validated JSON below.
verdict=$(grep -E '^Verdict:' <<<"$msg" | tail -1 | sed -E 's/^Verdict:[[:space:]]*//')
token=$(grep -E '^REVIEW-ID:' <<<"$msg" | tail -1 | awk '{print $2}')
start="$ROOT/.claude/build-plans/$plan/run/reviews/$safe.json"
anchor='{}'; [ ! -f "$start" ] || anchor=$(cat "$start")
valid_verdict=$verdict; problem=''; event=$verdict
case "$verdict" in
  '') problem="Your review has no 'Verdict:' line. Finish with Verdict: ACCEPT | ACCEPT-WITH-NOTES | REJECT."; event=no-verdict ;;
  ACCEPT|ACCEPT-WITH-NOTES|REJECT) ;;
  *) problem='Unknown verdict; use exactly ACCEPT, ACCEPT-WITH-NOTES or REJECT.'; event=invalid-verdict ;;
esac
if [ -z "$problem" ] && [ "$(printf '%s\n' "$msg" | sed '/^[[:space:]]*$/d' | tail -1)" != "Verdict: $verdict" ]; then
  problem='Verdict: must be the last nonempty line.'; event=invalid-verdict
fi
case "$verdict" in
  ACCEPT|ACCEPT-WITH-NOTES)
    if grep -qiE '^[[:space:]]*-[[:space:]]*\[(med|high)\]' <<<"$msg"; then
      problem="Your report has a med/high finding but the verdict is $verdict. A med or high finding is a REJECT. Correct the verdict, or justify a [low] downgrade."
      event=verdict-mismatch
    fi ;;
esac
if [ -z "$problem" ] && [ "$(grep -c '^Verdict:' <<<"$msg")" != 1 ]; then
  problem='Report must have exactly one Verdict: line.'; event=invalid-verdict
fi
case "$verdict" in
  ACCEPT|ACCEPT-WITH-NOTES)
    if [ -z "$problem" ] && grep -qE '^Checks:[[:space:]]*(FAIL|BLOCKED)' <<<"$msg"; then
      problem='An approving verdict contradicts failed checks.'; event=verdict-mismatch
    fi
    if [ -z "$problem" ] && grep -E '^[[:space:]]*-[[:space:]]' <<<"$msg" | grep -qvE '^[[:space:]]*-[[:space:]]*\[(low|med|high)\]'; then
      problem='Every finding must have an explicit low, med or high grade.'; event=invalid-verdict
    fi
    if [ -z "$problem" ] && [ "$verdict" = ACCEPT ] && grep -qE '^[[:space:]]*-[[:space:]]*\[low\]' <<<"$msg"; then
      problem='Use ACCEPT-WITH-NOTES for low findings; ACCEPT means no findings.'; event=verdict-mismatch
    fi ;;
esac
if [ -n "$problem" ]; then valid_verdict=INVALID; fi
reason=$problem
# Even well-formed legacy Markdown cannot authorize acceptance without a pinned start.
if ! jq -e --arg p "$plan" --arg i "$mid" --arg token "$token" \
  '.schema_version == 1 and .plan == $p and .id == $i and ($token | length > 0) and .review_id == $token' >/dev/null 2>&1 <<<"$anchor"; then
  valid_verdict=INVALID; reason="missing or mismatched review-start token"
elif [ "$(jq -r .tree_sha <<<"$anchor")" != "$(pv_tree_sha "$ROOT")" ] || \
     [ "$(jq -r .checks_sha <<<"$anchor")" != "$(pv_sha256 < "$ROOT/.claude/build-plans/$plan/checks.json")" ]; then
  valid_verdict=INVALID; reason='code or checks changed since review started'
fi
[ -n "$agent_id" ] || { valid_verdict=INVALID; reason='missing reviewer identity'; }
jq -nc --argjson a "$anchor" --arg p "$plan" --arg i "$mid" --arg v "$valid_verdict" \
  --arg declared "$verdict" --arg agent "$agent_id" --arg reason "$reason" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{schema_version:1,plan:$p,id:$i,review_id:($a.review_id // ""),base_commit:($a.base_commit // ""),
    tree_sha:($a.tree_sha // ""),checks_sha:($a.checks_sha // ""),agent_id:$agent,verdict:$v,
    reported_verdict:$declared,reason:$reason,at:$at}' \
  > "$ROOT/.claude/build-plans/$plan/results/$safe.review.json"
log "$event" "review=$valid_verdict; $reason; results/$safe.review.md"
[ -z "$problem" ] || block_once "$problem"
# A legacy report may stop, but its machine evidence is INVALID. For a scheduled
# review tell the reviewer about binding/staleness; a second stop remains INVALID.
if [ "$valid_verdict" = INVALID ] && [ -f "$start" ]; then block_once "$reason. Ask the orchestrator to start a fresh review; never invent a REVIEW-ID."; fi
exit 0
