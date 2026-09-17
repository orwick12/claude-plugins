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

# stop <agent_type> <last_assistant_message|-> <transcript path> <stop_hook_active>   ("-" = key absent)
stop() {
  jq -n --arg a "$1" --arg m "$2" --arg tp "$3" --argjson act "$4" --arg cwd "$REPO" \
    '{hook_event_name:"SubagentStop",agent_type:$a,agent_id:"atest",cwd:$cwd,stop_hook_active:$act,
      last_assistant_message:$m,agent_transcript_path:$tp} | if $m == "-" then del(.last_assistant_message) else . end' |
    CLAUDE_PROJECT_DIR="$REPO" bash "$HOOKS/verify-milestone.sh" 2>/dev/null
}
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

finish
