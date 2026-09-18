#!/usr/bin/env bash
# capture-review.sh — Stop hook for the milestone-reviewer subagents.
#
# An unattended run reads the reviewer's `Verdict:` token and nothing else, and its
# findings used to live only in a hand-back message no one stored. So this hook keeps the
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
. "$HOOKS/lib.sh"
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

verdict=$(grep -E '^Verdict:' <<<"$msg" | tail -1 | sed -E 's/^Verdict:[[:space:]]*//' | awk '{print $1}')
if [ -z "$verdict" ]; then
  log no-verdict "review has no Verdict: line"
  block_once "Your review has no 'Verdict:' line. An unattended run reads that token and nothing else to decide what happens to this milestone, so finish with 'Verdict: ACCEPT | ACCEPT-WITH-NOTES | REJECT' as the last line of your report."
fi

case "$verdict" in
  ACCEPT|ACCEPT-WITH-NOTES)
    if grep -qiE '^[[:space:]]*-[[:space:]]*\[(med|high)\]' <<<"$msg"; then
      log verdict-mismatch "verdict $verdict alongside a med or high finding"
      block_once "Your report has a med/high finding but the verdict is $verdict. A med or high finding is a REJECT. Either change the verdict to REJECT, or downgrade the finding to [low] with one line saying why it does not block acceptance, then finish with Verdict: as the last line."
    fi ;;
esac

log "$verdict" "review stored at results/$safe.review.md"
exit 0
