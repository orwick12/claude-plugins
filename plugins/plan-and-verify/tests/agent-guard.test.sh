#!/usr/bin/env bash
# agent-guard.sh keeps the one-writer rule true without a human watching. It runs twice:
# as PreToolUse on the Agent tool (may this builder spawn?) and on SubagentStart (a builder
# just started or was resumed — re-arm its marker). One marker per builder milestone lives
# in <plan>/run/open/, so a resumed builder is still visible to the guard (F46) and the
# members of one parallel-group may run together (F44).
. "$(dirname "$0")/helpers.sh"

REPO=$(mk_repo demo)
RUN="$REPO/.claude/build-plans/demo/run"
OPEN="$RUN/open"
PROMPT=$'Write hello.txt containing ok.\n\nPlan: demo  Milestone: 1.1\nPV_HOOKS: /x/hooks'
B=plan-and-verify:builder-sonnet

# spawn <subagent_type> <prompt> [permission_mode]
spawn() {
  jq -n --arg t "$1" --arg p "$2" --arg m "${3:-auto}" --arg cwd "$REPO" \
    '{hook_event_name:"PreToolUse",tool_name:"Agent",cwd:$cwd,permission_mode:$m,
      tool_input:{subagent_type:$t,description:"pv demo 1.1 builder",prompt:$p}}' |
    (cd "$REPO" && CLAUDE_PROJECT_DIR="$REPO" bash "$HOOKS/agent-guard.sh" 2>/dev/null)
}
# start_in <repo> <agent_type> <agent_id>: the SubagentStart event, which fires on a fresh
# spawn AND on a resume, and carries no prompt and no plan reference.
start_in() {
  jq -n --arg t "$2" --arg a "$3" --arg cwd "$1" \
    '{hook_event_name:"SubagentStart",agent_type:$t,agent_id:$a,cwd:$cwd,session_id:"s1",
      transcript_path:"/nonexistent"}' |
    (cd "$1" && CLAUDE_PROJECT_DIR="$1" bash "$HOOKS/agent-guard.sh" start 2>/dev/null)
}
start() { start_in "$REPO" "$1" "$2"; }
decision() { [ -z "$1" ] && echo allow || jq -r '.hookSpecificOutput.permissionDecision // "allow"' <<<"$1"; }
reason()   { jq -r '.hookSpecificOutput.permissionDecisionReason // ""' <<<"${1:-}" 2>/dev/null; }
mfield()   { jq -r "(.$2 // \"\")" "$OPEN/$1.json" 2>/dev/null; }
markers()  { ls "$OPEN" 2>/dev/null | tr '\n' ' '; }

echo "agent-guard.sh"

# --- the ordinary case ---------------------------------------------------------------
rm -rf "$OPEN"
out=$(spawn "$B" "$PROMPT")
assert_eq "a first builder spawn is allowed" allow "$(decision "$out")"
assert_contains "the spawn is recorded as a heartbeat" '"actor":"hook:agent-guard"' "$(cat "$RUN/hook-events.jsonl" 2>/dev/null)"
assert_eq "the spawn writes one marker for the milestone" "1.1.json " "$(markers)"
assert_eq "the marker is open"                    open "$(mfield 1.1 state)"
assert_eq "the marker has no agent yet"           ""   "$(mfield 1.1 agent_id)"

# --- one writer ----------------------------------------------------------------------
out=$(spawn "$B" "${PROMPT/1.1/1.2}")
assert_eq           "a second builder on another milestone is denied" deny "$(decision "$out")"
assert_contains     "the denial names the open builder" "1.1" "$(reason "$out")"
assert_contains     "the denial says to wait for it"    "Wait" "$(reason "$out")"
assert_not_contains "the denial does not offer to clear a live builder" "clear-open" "$(reason "$out")"
out=$(spawn plan-and-verify:builder-opus "$PROMPT")
assert_eq "re-spawning a live milestone is refused (one writer)" deny "$(decision "$out")"

# A stopped builder is not a finished milestone: until it is accepted, the tree is still
# mid-milestone and the next builder waits.
jq '.state = "stopped" | .agent_id = "a-one"' "$OPEN/1.1.json" > "$OPEN/1.1.tmp" && mv "$OPEN/1.1.tmp" "$OPEN/1.1.json"
out=$(spawn "$B" "${PROMPT/1.1/1.2}")
assert_eq       "a stopped but unaccepted milestone still denies the next builder" deny "$(decision "$out")"
assert_contains "that denial names the milestone that has not been accepted" "1.1" "$(reason "$out")"

# --- F46: SubagentStart re-arms the marker, because a resume is not an Agent call ------
out=$(start "$B" a-one)
assert_empty "SubagentStart says nothing to the transcript" "$out"
assert_eq    "a resumed builder's marker is open again" open "$(mfield 1.1 state)"
assert_contains "the resume is recorded as a heartbeat" '"outcome":"resumed"' "$(cat "$RUN/hook-events.jsonl" 2>/dev/null)"
out=$(spawn "$B" "${PROMPT/1.1/1.2}")
assert_eq "the resumed builder still blocks a second writer" deny "$(decision "$out")"

# a fresh spawn: the one marker with no agent yet is the one that just started
rm -rf "$OPEN"; spawn "$B" "$PROMPT" >/dev/null
start "$B" a-fresh >/dev/null
assert_eq "SubagentStart pairs a fresh spawn with its agent id" a-fresh "$(mfield 1.1 agent_id)"
assert_contains "the pairing is recorded as a heartbeat" '"outcome":"started"' "$(cat "$RUN/hook-events.jsonl" 2>/dev/null)"

# an unknown agent with every marker already paired: nothing to re-arm, nothing to write
jq '.state = "stopped"' "$OPEN/1.1.json" > "$OPEN/1.1.tmp" && mv "$OPEN/1.1.tmp" "$OPEN/1.1.json"
start "$B" a-stranger >/dev/null
assert_eq "an unknown builder does not adopt someone else's marker" a-fresh "$(mfield 1.1 agent_id)"
assert_eq "and does not re-open it"                               stopped "$(mfield 1.1 state)"

# non-builders are not writers: SubagentStart leaves everything alone
start plan-and-verify:milestone-reviewer a-rev >/dev/null
assert_eq "a reviewer's start changes no marker" a-fresh "$(mfield 1.1 agent_id)"
assert_eq "a reviewer's start writes no marker of its own" "1.1.json " "$(markers)"

# SubagentStart carries no plan reference, so it walks the plans that exist; it must never
# invent one for a project that has no build plans at all.
BARE=$(tmpdir)
start_in "$BARE" "$B" a-nowhere >/dev/null
assert_path_absent "SubagentStart creates nothing in a project with no plans" "$BARE/.claude"

# --- F44: the members of one parallel-group may run together --------------------------
GREPO=$(mk_repo grp)
cat >> "$GREPO/.claude/build-plans/grp/plan.md" <<'EOF'

## Phase 2: parallel
### Milestone 2.1
goal: Write a.
scope: dir-a/
parallel-group: g
status: TODO

### Milestone 2.2
goal: Write b.
scope: dir-b/
parallel-group: g
status: TODO

### Milestone 2.3
goal: Write c.
scope: dir-c/
parallel-group: none
status: TODO
EOF
git -C "$GREPO" add -A && git -C "$GREPO" commit -q -m "plan(grp): add the parallel phase"
REPO=$GREPO; RUN="$REPO/.claude/build-plans/grp/run"; OPEN="$RUN/open"
GP=$'work order\n\nPlan: grp  Milestone: 2.1\nPV_HOOKS: /x/hooks'

rm -rf "$OPEN"
assert_eq "the first member of a group is allowed"  allow "$(decision "$(spawn "$B" "$GP")")"
assert_eq "the second member of the same group is allowed too" allow "$(decision "$(spawn "$B" "${GP/2.1/2.2}")")"
assert_eq "both members hold a marker" "2.1.json 2.2.json " "$(markers)"
out=$(spawn "$B" "${GP/2.1/2.3}")
assert_eq           "a milestone outside the group is denied" deny "$(decision "$out")"
assert_not_contains "that denial does not offer to clear a live builder" "clear-open" "$(reason "$out")"
out=$(spawn "$B" "${GP/2.1/1.1}")
assert_eq "a milestone with no parallel-group at all is denied" deny "$(decision "$out")"

# --- a milestone that is already accepted --------------------------------------------
REPO=$(mk_repo demo); RUN="$REPO/.claude/build-plans/demo/run"; OPEN="$RUN/open"
printf 'ok' > "$REPO/hello.txt"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m "milestone(1.1): done [demo 1.1]"
out=$(spawn "$B" "$PROMPT")
assert_eq       "a builder for an accepted milestone is denied" deny "$(decision "$out")"
assert_contains "the denial says it is already accepted" "already" "$(reason "$out")"

# --- plan mode -----------------------------------------------------------------------
rm -rf "$OPEN"
out=$(spawn "$B" "${PROMPT/1.1/1.3}" plan)
assert_eq "no builder may spawn while the session is in plan mode" deny "$(decision "$out")"

# --- everything that is not a plugin builder -----------------------------------------
rm -rf "$OPEN"
assert_eq "the reviewer is not a builder"        allow "$(decision "$(spawn plan-and-verify:milestone-reviewer "$PROMPT")")"
assert_eq "a general-purpose agent is untouched" allow "$(decision "$(spawn general-purpose "look around")")"
assert_eq "Explore is untouched"                 allow "$(decision "$(spawn Explore "find the auth code")")"
out=$(spawn "$B" "a prompt with no Plan: line")
assert_eq "a builder spawn with no plan reference is left alone" allow "$(decision "$out")"
assert_empty "and leaves no marker behind" "$(markers)"

# --- acceptance is what retires a marker ----------------------------------------------
REPO=$(mk_repo demo); RUN="$REPO/.claude/build-plans/demo/run"; OPEN="$RUN/open"
spawn "$B" "$PROMPT" >/dev/null
printf 'ok' > "$REPO/hello.txt"
(cd "$REPO" && CLAUDE_PROJECT_DIR="$REPO" bash "$HOOKS/run-checks.sh" demo 1.1 >/dev/null 2>&1)
(cd "$REPO" && CLAUDE_PROJECT_DIR="$REPO" bash "$HOOKS/accept-milestone.sh" demo 1.1 >/dev/null 2>&1)
assert_path_absent "accepting the milestone removes its marker" "$OPEN/1.1.json"

finish
