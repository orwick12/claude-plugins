#!/usr/bin/env bash
# agent-guard.sh (PreToolUse on Agent) keeps the one-writer rule true without a human
# watching: one builder at a time, never for a milestone that is already accepted, and
# never while the session is still in plan mode. Everything else it leaves alone.
. "$(dirname "$0")/helpers.sh"

REPO=$(mk_repo demo)
RUN="$REPO/.claude/build-plans/demo/run"
PROMPT=$'Write hello.txt containing ok.\n\nPlan: demo  Milestone: 1.1\nPV_HOOKS: /x/hooks'

# spawn <subagent_type> <prompt> [permission_mode]
spawn() {
  jq -n --arg t "$1" --arg p "$2" --arg m "${3:-auto}" --arg cwd "$REPO" \
    '{hook_event_name:"PreToolUse",tool_name:"Agent",cwd:$cwd,permission_mode:$m,
      tool_input:{subagent_type:$t,description:"pv demo 1.1 builder",prompt:$p}}' |
    (cd "$REPO" && CLAUDE_PROJECT_DIR="$REPO" bash "$HOOKS/agent-guard.sh" 2>/dev/null)
}
decision() { [ -z "$1" ] && echo allow || jq -r '.hookSpecificOutput.permissionDecision // "allow"' <<<"$1"; }
reason()   { jq -r '.hookSpecificOutput.permissionDecisionReason // ""' <<<"${1:-}" 2>/dev/null; }

echo "agent-guard.sh"

# --- the ordinary case ---------------------------------------------------------------
rm -f "$RUN/open-builder.json"
out=$(spawn plan-and-verify:builder-sonnet "$PROMPT")
assert_eq "a first builder spawn is allowed" allow "$(decision "$out")"
assert_contains "the spawn is recorded as a heartbeat" '"actor":"hook:agent-guard"' "$(cat "$RUN/hook-events.jsonl" 2>/dev/null)"

# --- one writer ----------------------------------------------------------------------
out=$(spawn plan-and-verify:builder-sonnet "${PROMPT/1.1/1.2}")
assert_eq       "a second builder on another milestone is denied" deny "$(decision "$out")"
assert_contains "the denial names the open builder" "1.1" "$(reason "$out")"
out=$(spawn plan-and-verify:builder-opus "$PROMPT")
assert_eq "re-spawning the same milestone is allowed (escalation)" allow "$(decision "$out")"

# --- a milestone that is already accepted --------------------------------------------
rm -f "$RUN/open-builder.json"
printf 'ok' > "$REPO/hello.txt"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m "milestone(1.1): done [demo 1.1]"
out=$(spawn plan-and-verify:builder-sonnet "$PROMPT")
assert_eq       "a builder for an accepted milestone is denied" deny "$(decision "$out")"
assert_contains "the denial says it is already accepted" "already" "$(reason "$out")"

# --- plan mode -----------------------------------------------------------------------
rm -f "$RUN/open-builder.json"
out=$(spawn plan-and-verify:builder-sonnet "${PROMPT/1.1/1.3}" plan)
assert_eq "no builder may spawn while the session is in plan mode" deny "$(decision "$out")"

# --- everything that is not a plugin builder -----------------------------------------
rm -f "$RUN/open-builder.json"
assert_eq "the reviewer is not a builder"        allow "$(decision "$(spawn plan-and-verify:milestone-reviewer "$PROMPT")")"
assert_eq "a general-purpose agent is untouched" allow "$(decision "$(spawn general-purpose "look around")")"
assert_eq "Explore is untouched"                 allow "$(decision "$(spawn Explore "find the auth code")")"
out=$(spawn plan-and-verify:builder-sonnet "a prompt with no Plan: line")
assert_eq "a builder spawn with no plan reference is left alone" allow "$(decision "$out")"

finish
