#!/usr/bin/env bash
# capture-review.sh — Stop hook for the milestone-reviewer subagents.
#
# Acceptance reads structured, artifact-bound review evidence; raw Markdown is
# diagnostic. Findings used to live only in a hand-back message. This hook keeps the
# review next to the milestone's results and holds the reviewer to the severity rule in
# its own contract: a [med] or [high] finding is a REJECT (F45).
#   - review captured                          -> results/<id>.review.md, verdict logged, and
#                                                 results/<id>.review.json bound to the tree
#                                                 and checks at stop (INVALID unless the
#                                                 builder's checks are a current PASS)
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
# Bind the review to the artifact as it stands when the reviewer stops, and only to a tree
# whose primary builder result is a current PASS: that is the thing it was asked to judge.
# Acceptance refuses the review once the tree or checks move on. A reviewer cannot fix
# either problem, so they make the evidence INVALID without sending it back.
dir="$ROOT/.claude/build-plans/$plan"
tree=$(pv_tree_sha "$ROOT"); checks=$(pv_sha256 < "$dir/checks.json")
if ! jq -e --arg p "$plan" --arg i "$mid" --arg t "$tree" --arg c "$checks" \
  '.plan == $p and .id == $i and .status == "PASS" and .tree_sha == $t and .checks_sha == $c' "$dir/results/$safe.json" >/dev/null 2>&1; then
  valid_verdict=INVALID; reason='the reviewed tree has no current passing builder checks; re-run them, then review again'
fi
[ -n "$agent_id" ] || { valid_verdict=INVALID; reason='missing reviewer identity'; }
# review_id names this one review, so an approval of it cannot carry over to a later one.
jq -nc --arg p "$plan" --arg i "$mid" --arg rid "$(date +%s)-$$-$RANDOM" --arg b "$(git -C "$ROOT" rev-parse HEAD)" \
  --arg t "$tree" --arg c "$checks" --arg v "$valid_verdict" --arg declared "$verdict" --arg agent "$agent_id" \
  --arg reason "$reason" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{schema_version:1,plan:$p,id:$i,review_id:$rid,base_commit:$b,tree_sha:$t,checks_sha:$c,agent_id:$agent,
    verdict:$v,reported_verdict:$declared,reason:$reason,at:$at}' \
  > "$dir/results/$safe.review.json"
log "$event" "review=$valid_verdict; $reason; results/$safe.review.md"
[ -z "$problem" ] || block_once "$problem"
exit 0
