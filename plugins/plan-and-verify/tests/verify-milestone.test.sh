#!/usr/bin/env bash
# verify-milestone.sh (SubagentStop) must:
# - ignore every agent that is not a plugin builder (internal agents arrive with agent_type "")
# - find the builder's report where Claude Code puts it: a SubagentHandback tool call in the
#   agent transcript, before the stop, while last_assistant_message is a later one-liner
# - never block twice for a missing report, and never create a plan directory that does not exist
. "$(dirname "$0")/helpers.sh"

REPO=$(mk_repo demo)
T=$(tmpdir)
B=plan-and-verify:builder-sonnet
REPORT_DONE=$'MILESTONE: demo/1.1\nChanged:\nhello.txt - wrote it\nChecks: not run\nOpen questions: none\nSTATUS: DONE'
AFTER_HANDBACK='Milestone demo/1.1 complete. Final report delivered via SubagentHandback above.'

# mk_transcript <path> <handback message> <final text>: the shape of a real background builder transcript
mk_transcript() {
  jq -nc --arg r "$2" '{type:"assistant",message:{role:"assistant",content:[{type:"tool_use",id:"toolu_1",name:"SubagentHandback",input:{message:$r}}]}}' > "$1"
  jq -nc '{type:"user",message:{role:"user",content:[{type:"tool_result",tool_use_id:"toolu_1",content:"Report delivered"}]}}' >> "$1"
  jq -nc --arg f "$3" '{type:"assistant",message:{role:"assistant",content:[{type:"text",text:$f}]}}' >> "$1"
}

# stop_as <agent_id> <agent_type> <last_assistant_message|-> <transcript path> <stop_hook_active>
stop_as() {
  jq -n --arg id "$1" --arg a "$2" --arg m "$3" --arg tp "$4" --argjson act "$5" --arg cwd "$REPO" \
    '{hook_event_name:"SubagentStop",agent_type:$a,agent_id:$id,cwd:$cwd,stop_hook_active:$act,
      last_assistant_message:$m,agent_transcript_path:$tp} | if $m == "-" then del(.last_assistant_message) else . end' |
    CLAUDE_PROJECT_DIR="$REPO" bash "$HOOKS/verify-milestone.sh" 2>/dev/null
}
# stop <agent_type> <last_assistant_message|-> <transcript path> <stop_hook_active>   ("-" = key absent)
stop() { stop_as atest "$1" "$2" "$3" "$4"; }
field() { [ -z "$1" ] && echo "" || jq -r "$2 // \"\"" <<<"$1" 2>/dev/null; }
plans() { ls "$REPO/.claude/build-plans" | tr '\n' ' '; }

mk_transcript "$T/handback.jsonl" "$REPORT_DONE" "$AFTER_HANDBACK"
: > "$T/empty.jsonl"

echo "verify-milestone.sh"

# --- agents that are not builders -------------------------------------------------
out=$(stop "" - "$T/nonexistent.jsonl" false)
assert_empty "empty agent_type (internal agent), no message: no output" "$out"
out=$(stop "" - "$T/nonexistent.jsonl" true)
assert_empty "empty agent_type, stop_hook_active: no output" "$out"
out=$(stop "" $'MILESTONE: SUGGESTION-FORK/misfire\nSTATUS: BLOCKED' "$T/nonexistent.jsonl" true)
assert_empty "empty agent_type quoting a BLOCKED report: no output" "$out"
assert_path_absent "empty agent_type quoting a BLOCKED report: no plan dir created" "$REPO/.claude/build-plans/SUGGESTION-FORK"
out=$(stop plan-and-verify:milestone-reviewer $'REVIEW: demo/1.1\nVerdict: ACCEPT' "$T/empty.jsonl" false)
assert_empty "milestone-reviewer: no output" "$out"

# --- builder report delivered by SubagentHandback ---------------------------------
printf 'wrong' > "$REPO/hello.txt"
out=$(stop "$B" "$AFTER_HANDBACK" "$T/handback.jsonl" false)
assert_eq       "handback report + failing check: blocks" block "$(field "$out" .decision)"
assert_contains "handback report + failing check: reason is the check failure" "Acceptance checks FAILED" "$(field "$out" .reason)"
assert_contains "handback report + failing check: failure output included" "hello is ok" "$(field "$out" .reason)"

printf 'ok' > "$REPO/hello.txt"
out=$(stop "$B" "$AFTER_HANDBACK" "$T/handback.jsonl" true)
assert_empty "handback report + passing check: builder may stop" "$out"
assert_eq    "handback report + passing check: results file says PASS" PASS \
  "$(jq -r .status "$REPO/.claude/build-plans/demo/results/1.1.json" 2>/dev/null)"

# --- report in last_assistant_message (foreground-style) still works --------------
printf 'wrong' > "$REPO/hello.txt"
out=$(stop "$B" "$REPORT_DONE" "$T/empty.jsonl" false)
assert_eq "report in last message + failing check: blocks" block "$(field "$out" .decision)"
assert_contains "report in last message + failing check: reason is the check failure" "Acceptance checks FAILED" "$(field "$out" .reason)"

# --- no report anywhere: block once, never loop ------------------------------------
out=$(stop "$B" "done." "$T/empty.jsonl" false)
assert_eq       "no MILESTONE anywhere, first stop: blocks" block "$(field "$out" .decision)"
assert_contains "no MILESTONE anywhere, first stop: asks for the report format" "MILESTONE:" "$(field "$out" .reason)"
out=$(stop "$B" "done." "$T/empty.jsonl" true)
assert_not_contains "no MILESTONE anywhere, stop_hook_active: does not block again" '"block"' "$out"

# --- BLOCKED reports -----------------------------------------------------------------
before=$(plans)
out=$(stop "$B" $'MILESTONE: nosuch/1.1\nSTATUS: BLOCKED' "$T/empty.jsonl" false)
assert_path_absent "BLOCKED report for a plan that does not exist: no plan dir created" "$REPO/.claude/build-plans/nosuch"
assert_eq "BLOCKED report for a plan that does not exist: build-plans unchanged" "$before" "$(plans)"

out=$(stop "$B" $'MILESTONE: demo/1.1\nChanged: none\nOpen questions: check is wrong\nSTATUS: BLOCKED' "$T/empty.jsonl" false)
assert_empty "BLOCKED report for a real plan: builder may stop" "$out"
assert_eq    "BLOCKED report for a real plan: results file says BLOCKED" BLOCKED \
  "$(jq -r .status "$REPO/.claude/build-plans/demo/results/1.1.json" 2>/dev/null)"

# --- F13: the attempts budget belongs to the agent, not to the milestone -------------
ATTEMPTS="$REPO/.claude/build-plans/demo/results/1.1.attempts"
printf 'wrong' > "$REPO/hello.txt"; rm -f "$ATTEMPTS"
out=$(stop_as one "$B" "$AFTER_HANDBACK" "$T/handback.jsonl" false)
assert_contains "F13 builder one, first failed finish"  "attempt 1 of 3" "$(field "$out" .reason)"
out=$(stop_as one "$B" "$AFTER_HANDBACK" "$T/handback.jsonl" true)
assert_contains "F13 builder one, second failed finish" "attempt 2 of 3" "$(field "$out" .reason)"
out=$(stop_as one "$B" "$AFTER_HANDBACK" "$T/handback.jsonl" true)
assert_not_contains "F13 builder one exhausts its budget: allowed to stop" '"block"' "$out"
assert_contains     "F13 exhausted budget says so" "after 3 attempts" "$(field "$out" .systemMessage)"

out=$(stop_as two "$B" "$AFTER_HANDBACK" "$T/handback.jsonl" false)
assert_eq       "F13 a different builder is blocked, not waved through" block "$(field "$out" .decision)"
assert_contains "F13 a different builder gets a fresh budget" "attempt 1 of 3" "$(field "$out" .reason)"
out=$(stop_as two "$B" "$AFTER_HANDBACK" "$T/handback.jsonl" true)
assert_contains "F13 the same builder keeps counting" "attempt 2 of 3" "$(field "$out" .reason)"

# --- F36: the verified report is left on disk, and the block does not ask for a second hand-back
REPORT="$REPO/.claude/build-plans/demo/results/1.1.report.md"
assert_contains "F36 block tells the builder not to hand back twice" "SubagentHandback" "$(field "$out" .reason)"
assert_not_contains "F36 block no longer says to finish with the report format again" \
  "finish with the report format again" "$(field "$out" .reason)"
assert_contains "F36 report file written on a failed finish" "MILESTONE: demo/1.1" "$(cat "$REPORT" 2>/dev/null)"

rm -f "$REPORT"; printf 'ok' > "$REPO/hello.txt"
out=$(stop_as three "$B" "$AFTER_HANDBACK" "$T/handback.jsonl" false)
assert_empty    "F36 passing finish still lets the builder stop" "$out"
assert_contains "F36 report file written on a passing finish" "STATUS: DONE" "$(cat "$REPORT" 2>/dev/null)"
assert_contains "F36 report file records where the report came from" "handback" "$(cat "$REPORT" 2>/dev/null)"

rm -f "$REPORT"
out=$(stop_as four "$B" "$REPORT_DONE" "$T/empty.jsonl" false)
assert_contains "F36 report from the last message is captured too" "MILESTONE: demo/1.1" "$(cat "$REPORT" 2>/dev/null)"

# --- F42: a BLOCKED report must keep the previous run's evidence ----------------------
# The orchestrator adjudicates the failing checks after a builder gives up, so replacing
# the results file with an empty stub destroys exactly what it needs next. BLOCKED still
# has to overwrite an earlier PASS, so it can never authorise acceptance.
RES="$REPO/.claude/build-plans/demo/results/1.1.json"
printf 'wrong' > "$REPO/hello.txt"
(cd "$REPO" && CLAUDE_PROJECT_DIR="$REPO" bash "$HOOKS/run-checks.sh" demo 1.1 >/dev/null 2>&1)
assert_eq "F42 precondition: a FAIL results file with one check" FAIL "$(jq -r .status "$RES")"
tree_before=$(jq -r .tree_sha "$RES")
out=$(stop "$B" $'MILESTONE: demo/1.1\nChanged: none\nOpen questions: the check disagrees with the plan\nSTATUS: BLOCKED' "$T/empty.jsonl" false)
assert_empty    "F42 BLOCKED after a failed run: builder may stop" "$out"
assert_eq       "F42 status is BLOCKED"           BLOCKED "$(jq -r .status "$RES")"
assert_eq       "F42 the status it replaced is recorded" FAIL "$(jq -r .previous_status "$RES")"
assert_eq       "F42 the failing check survives"  1 "$(jq -r '.checks | length' "$RES")"
assert_eq       "F42 the fail count survives"     1 "$(jq -r .fail "$RES")"
assert_eq       "F42 the tree fingerprint survives" "$tree_before" "$(jq -r .tree_sha "$RES")"
assert_contains "F42 blocked_at is stamped"       "Z" "$(jq -r .blocked_at "$RES")"

acc=$(cd "$REPO" && CLAUDE_PROJECT_DIR="$REPO" bash "$HOOKS/accept-milestone.sh" demo 1.1 2>&1); acc_code=$?
assert_eq       "F42 acceptance still refuses a BLOCKED milestone" 2 "$acc_code"
assert_contains "F42 the refusal names the status" "BLOCKED" "$acc"

# no earlier results file: the stub is still written, and it still says BLOCKED
R2=$(mk_repo demo)
R2RES="$R2/.claude/build-plans/demo/results/1.1.json"
out=$(jq -n --arg cwd "$R2" \
  '{hook_event_name:"SubagentStop",agent_type:"plan-and-verify:builder-sonnet",agent_id:"afresh",cwd:$cwd,
    stop_hook_active:false,last_assistant_message:"MILESTONE: demo/1.1\nSTATUS: BLOCKED",agent_transcript_path:""}' |
  CLAUDE_PROJECT_DIR="$R2" bash "$HOOKS/verify-milestone.sh" 2>/dev/null)
assert_empty    "F42 BLOCKED with no earlier run: builder may stop" "$out"
assert_eq       "F42 BLOCKED with no earlier run: stub says BLOCKED" BLOCKED "$(jq -r .status "$R2RES")"
assert_eq       "F42 BLOCKED with no earlier run: no checks claimed" 0 "$(jq -r '.checks | length' "$R2RES")"
assert_contains "F42 BLOCKED with no earlier run: blocked_at is stamped" "Z" "$(jq -r .blocked_at "$R2RES")"

# --- F46: a stop leaves the milestone's marker behind, stopped -------------------------
# The marker is how the guard knows a milestone is still unfinished. Deleting it at the
# stop made the tree look free while the builder was only paused, so the next spawn
# started a second writer. The marker is retired by acceptance, not by stopping.
R3=$(mk_repo demo)
OPEN3="$R3/.claude/build-plans/demo/run/open"
mkdir -p "$OPEN3"
jq -nc --arg t "$B" --arg e "$(date +%s)" '{id:"1.1",agent_type:$t,state:"open",epoch:($e|tonumber)}' > "$OPEN3/1.1.json"
printf 'ok' > "$R3/hello.txt"
out=$(jq -n --arg cwd "$R3" --arg m "$REPORT_DONE" \
  '{hook_event_name:"SubagentStop",agent_type:"plan-and-verify:builder-sonnet",agent_id:"astop",cwd:$cwd,
    stop_hook_active:false,last_assistant_message:$m,agent_transcript_path:"/nonexistent"}' |
  CLAUDE_PROJECT_DIR="$R3" bash "$HOOKS/verify-milestone.sh" 2>/dev/null)
assert_empty    "F46 a passing stop is still allowed"        "$out"
assert_eq       "F46 the marker survives the stop"           0 "$([ -f "$OPEN3/1.1.json" ]; echo $?)"
assert_eq       "F46 the marker says the builder stopped"    stopped "$(jq -r '.state // ""' "$OPEN3/1.1.json")"
assert_eq       "F46 the marker records the agent that stopped" astop "$(jq -r '.agent_id // ""' "$OPEN3/1.1.json")"
assert_contains "F46 stopped_at is stamped"                  "Z" "$(jq -r '.stopped_at // ""' "$OPEN3/1.1.json")"

finish
