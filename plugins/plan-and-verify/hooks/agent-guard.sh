#!/usr/bin/env bash
# agent-guard.sh — the one-writer guard. Two entry points, one set of markers.
#
#   agent-guard.sh          PreToolUse on the Agent tool: may this builder spawn?
#   agent-guard.sh start    SubagentStart: a builder just started, or was RESUMED.
#
# One writer at a time is the rule the whole design rests on: milestones run one after
# another in one working tree. Attended, the orchestrator keeps to it because the skill
# says so. Unattended, this hook is what makes it true. It denies a builder spawn when
#   - another milestone's builder is still open, or stopped and not yet accepted
#   - the milestone already has its acceptance commit
#   - the session is still in plan mode
# and leaves every other agent (reviewers, Explore, general-purpose) completely alone.
# The one exception is a parallel group: two milestones that carry the same non-none
# "parallel-group:" value in plan.md are allowed to build at the same time (F44).
#
# One marker per builder milestone, in the plan's ignored run/ directory:
#   run/open/<id>.json  {id, agent_type, state: open|stopped, epoch, agent_id?, stopped_at?}
# Written here at spawn, paired with its agent (and re-opened on a resume) by the start
# path, set to "stopped" by verify-milestone.sh, and removed by accept-milestone.sh.
# Stopping is not finishing: a resumed builder writes the same tree, so only acceptance
# retires a marker (F46). If a session dies mid-milestone the marker goes stale; it expires
# after six hours, and 'run-state.sh clear-open <plan> [<id>]' removes it before that.
set -u
HOOKS="$(cd "$(dirname "$0")" && pwd)"
. "$HOOKS/state.sh"
input=$(cat)

# --- SubagentStart: the only event a RESUMED builder raises ---------------------------
# A resume is not an Agent tool call, so the PreToolUse path never sees it and the marker
# of the builder that just came back to life would stay "stopped" — the guard would believe
# the tree was free and let a second writer in. SubagentStart fires for both spawn and
# resume, and carries agent_id and agent_type but no prompt, so there is no plan reference
# here: walk the markers that already exist, and never create anything for a plan that
# does not have one.
if [ "${1:-}" = "start" ]; then
  atype=$(jq -r '.agent_type // ""' <<<"$input")
  pv_is_builder "$atype" || exit 0
  aid=$(jq -r '.agent_id // ""' <<<"$input")
  [ -n "$aid" ] || exit 0
  [ -n "${CLAUDE_PROJECT_DIR:-}" ] || CLAUDE_PROJECT_DIR=$(jq -r '.cwd // "."' <<<"$input")
  ROOT=$(pv_root)
  start_beat() {                                   # <marker> <outcome>
    local rel plan id
    rel=${1#"$ROOT"/.claude/build-plans/}; plan=${rel%%/*}
    id=$(jq -r '.id // ""' "$1" 2>/dev/null)
    pv_log_event "$ROOT" "$plan" hook-events "$(jq -nc --arg id "$id" --arg t "$atype" \
      --arg a "$aid" --arg o "$2" '{actor:"hook:agent-guard",id:$id,agent_type:$t,agent:$a,outcome:$o}')"
  }
  unpaired=""; n=0
  for m in "$ROOT"/.claude/build-plans/*/run/open/*.json; do
    [ -f "$m" ] || continue
    own=$(jq -r '.agent_id // ""' "$m" 2>/dev/null)
    if [ -n "$own" ] && [ "$own" = "$aid" ]; then
      jq 'del(.stopped_at) + {state:"open"}' "$m" > "$m.tmp" 2>/dev/null && mv "$m.tmp" "$m" || rm -f "$m.tmp"
      start_beat "$m" resumed
      exit 0
    fi
    [ -n "$own" ] || { unpaired=$m; n=$((n+1)); }
  done
  # A fresh spawn: the PreToolUse path wrote a marker with no agent id a moment ago. Pair
  # them only when there is exactly one candidate; with two (a parallel group starting)
  # there is nothing here to tell them apart, and a wrong pairing is worse than none.
  [ "$n" -eq 1 ] || exit 0
  jq --arg a "$aid" '. + {agent_id:$a}' "$unpaired" > "$unpaired.tmp" 2>/dev/null &&
    mv "$unpaired.tmp" "$unpaired" || rm -f "$unpaired.tmp"
  start_beat "$unpaired" started
  exit 0
fi

# --- PreToolUse on Agent: may this builder spawn? -------------------------------------
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

if pv_accepted "$ROOT" "$plan" "$mid" >/dev/null; then
  deny "Milestone $mid is already accepted (its milestone commit exists). Move to the next milestone; if it must be rebuilt, say so and revert the commit first."
fi

pending=$(pv_pending_dependencies "$ROOT" "$plan" "$mid")
[ -z "$pending" ] || deny "Milestone $mid has unaccepted dependencies: $pending"
PLANMD="$ROOT/.claude/build-plans/$plan/plan.md"
rundir=$(pv_run_dir "$ROOT" "$plan")
mygroup=$(pv_parallel_group "$PLANMD" "$mid")
now=$(date +%s)
for m in "$ROOT"/.claude/build-plans/*/run/open/*.json; do
  [ -f "$m" ] || continue
  oid=$(jq -r '.id // ""' "$m" 2>/dev/null)
  [ -n "$oid" ] || continue
  rel=${m#"$ROOT"/.claude/build-plans/}; otherplan=${rel%%/*}
  oat=$(jq -r '.epoch // 0' "$m" 2>/dev/null)
  case "$oat" in ''|*[!0-9]*) oat=0 ;; esac
  [ $((now - oat)) -lt 21600 ] || continue               # six hours: a dead session's marker
  if [ "$otherplan" = "$plan" ] && [ "$oid" = "$mid" ]; then
    [ "$(jq -r '.state // "open"' "$m")" = stopped ] && continue
    deny "A builder is still open on milestone $mid. Wait for completion before escalating. If no builder is running (the session that spawned it died), clear its marker with: bash \"$HOOKS/run-state.sh\" clear-open $plan $mid"
  fi
  # Members of one parallel group are the one case where two builders share the tree: the
  # plan says they own disjoint directories, and the group is accepted in one call.
  if [ "$otherplan" = "$plan" ] && [ -n "$mygroup" ] && [ "$mygroup" = "$(pv_parallel_group "$PLANMD" "$oid")" ]; then continue; fi
  if [ "$(jq -r '.state // "open"' "$m" 2>/dev/null)" = "stopped" ]; then
    deny "Milestone $oid has a builder that stopped but is not accepted yet, so this tree is still mid-milestone. Finish $oid — read its results file, review it, accept it — before spawning $mid. Two builders may only run together as members of the same parallel-group."
  fi
  deny "A builder is still open on milestone $oid. Milestones run one at a time in one working tree. Wait for it to finish and be accepted before spawning $mid; two builders may only run together as members of the same parallel-group."
done

mkdir -p "$rundir/open" 2>/dev/null || true
# A respawn of the same milestone replaces its marker: new builder, new spawn time, and no
# agent id until the start path pairs this one with it.
jq -nc --arg id "$mid" --arg e "$now" --arg t "$sub" \
  '{id:$id,agent_type:$t,state:"open",epoch:($e|tonumber)}' > "$(pv_marker_path "$rundir" "$mid")" 2>/dev/null || true
beat allowed "spawn $sub"
exit 0
