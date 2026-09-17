#!/usr/bin/env bash
# agent-guard.sh — PreToolUse hook on the Agent tool.
#
# One writer at a time is the rule the whole design rests on: milestones run one after
# another in one working tree. Attended, the orchestrator keeps to it because the skill
# says so. Unattended, this hook is what makes it true. It denies a builder spawn when
#   - another builder is still open on a different milestone
#   - the milestone already has its acceptance commit
#   - the session is still in plan mode
# and leaves every other agent (reviewers, Explore, general-purpose) completely alone.
#
# The open-builder marker lives in the plan's ignored run/ directory and is cleared by
# verify-milestone.sh when a builder stops. If a session dies mid-milestone the marker
# goes stale; it expires after six hours, and 'run-state.sh clear-open <plan>' removes it.
set -u
HOOKS="$(cd "$(dirname "$0")" && pwd)"
. "$HOOKS/lib.sh"
input=$(cat)
[ "$(jq -r '.tool_name // ""' <<<"$input")" = "Agent" ] || exit 0
sub=$(jq -r '.tool_input.subagent_type // ""' <<<"$input")
pv_is_builder "$sub" || exit 0

prompt=$(jq -r '.tool_input.prompt // ""' <<<"$input")
ref=$(grep -oE '^Plan:[[:space:]]*[A-Za-z0-9._-]+[[:space:]]+Milestone:[[:space:]]*[A-Za-z0-9._:-]+' <<<"$prompt" | head -1)
[ -n "$ref" ] || exit 0                      # no work order reference: not ours to police
plan=$(sed -E 's/^Plan:[[:space:]]*([A-Za-z0-9._-]+).*/\1/' <<<"$ref")
mid=$(sed -E 's/.*Milestone:[[:space:]]*([A-Za-z0-9._:-]+).*/\1/' <<<"$ref")

[ -n "${CLAUDE_PROJECT_DIR:-}" ] || CLAUDE_PROJECT_DIR=$(jq -r '.cwd // "."' <<<"$input")
ROOT=$(pv_root)
[ -f "$ROOT/.claude/build-plans/$plan/checks.json" ] || exit 0

beat() {
  pv_log_event "$ROOT" "$plan" hook-events "$(jq -nc --arg id "$mid" --arg t "$sub" \
    --arg o "$1" --arg d "${2:-}" '{actor:"hook:agent-guard",id:$id,agent_type:$t,outcome:$o,detail:$d}')"
}
deny() {
  beat denied "$1"
  jq -n --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

mode=$(jq -r '.permission_mode // ""' <<<"$input")
[ "$mode" != "plan" ] || deny "The session is in plan mode: finish planning and approve the plan before any builder runs."

if git -C "$ROOT" log --oneline --grep "\[$plan $mid\]" 2>/dev/null | grep -q .; then
  deny "Milestone $mid is already accepted (its milestone commit exists). Move to the next milestone; if it must be rebuilt, say so and revert the commit first."
fi

marker=$(pv_run_dir "$ROOT" "$plan")/open-builder.json
if [ -f "$marker" ]; then
  open_id=$(jq -r '.id // ""' "$marker" 2>/dev/null)
  open_at=$(jq -r '.epoch // 0' "$marker" 2>/dev/null)
  now=$(date +%s)
  case "$open_at" in ''|*[!0-9]*) open_at=0 ;; esac
  if [ -n "$open_id" ] && [ "$open_id" != "$mid" ] && [ $((now - open_at)) -lt 21600 ]; then
    deny "A builder is still open on milestone $open_id. Milestones run one at a time in one working tree. Wait for it to finish, or clear a dead run with: bash \"\$PV_HOOKS/run-state.sh\" clear-open $plan"
  fi
fi

jq -nc --arg id "$mid" --arg e "$(date +%s)" --arg t "$sub" \
  '{id:$id,epoch:($e|tonumber),agent_type:$t}' > "$marker" 2>/dev/null || true
beat allowed "spawn $sub"
exit 0
