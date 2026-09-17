#!/usr/bin/env bash
# capture-report.sh (PostToolUse on SubagentHandback) must store a builder's report the
# moment it is delivered. SubagentHandback delivers one report per run, so a builder that
# is sent back by the finish hook can never deliver its corrected report (F36): the
# orchestrator reads it from disk instead.
. "$(dirname "$0")/helpers.sh"

REPO=$(mk_repo demo)
B=plan-and-verify:builder-sonnet
REPORT=$'MILESTONE: demo/1.1\nChanged:\nhello.txt - wrote it\nChecks: not run\nOpen questions: none\nSTATUS: DONE'
FILE="$REPO/.claude/build-plans/demo/results/1.1.report.md"

# handback <agent_type> <message>
handback() {
  jq -n --arg a "$1" --arg m "$2" --arg cwd "$REPO" \
    '{hook_event_name:"PostToolUse",agent_type:$a,agent_id:"acap",cwd:$cwd,
      tool_name:"SubagentHandback",tool_input:{message:$m}}' |
    CLAUDE_PROJECT_DIR="$REPO" bash "$HOOKS/capture-report.sh" 2>/dev/null
}

echo "capture-report.sh"

rm -f "$FILE"
out=$(handback "$B" "$REPORT")
assert_empty    "delivered report: hook stays silent" "$out"
assert_contains "delivered report: stored on disk" "MILESTONE: demo/1.1" "$(cat "$FILE" 2>/dev/null)"
assert_contains "delivered report: keeps the status line" "STATUS: DONE" "$(cat "$FILE" 2>/dev/null)"
assert_contains "delivered report: records that it was delivered" "delivered" "$(cat "$FILE" 2>/dev/null)"

rm -f "$FILE"
out=$(handback "" "$REPORT")
assert_path_absent "internal agent (empty agent_type): nothing stored" "$FILE"
out=$(handback plan-and-verify:milestone-reviewer "$REPORT")
assert_path_absent "reviewer hand-back: nothing stored" "$FILE"

before=$(ls "$REPO/.claude/build-plans" | tr '\n' ' ')
out=$(handback "$B" $'MILESTONE: nosuch/9.9\nSTATUS: DONE')
assert_path_absent "report naming a plan that does not exist: no plan dir created" "$REPO/.claude/build-plans/nosuch"
assert_eq "report naming a plan that does not exist: build-plans unchanged" "$before" "$(ls "$REPO/.claude/build-plans" | tr '\n' ' ')"

out=$(handback "$B" "no milestone line here")
assert_path_absent "hand-back without a MILESTONE line: nothing stored" "$FILE"

finish
