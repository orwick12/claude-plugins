#!/usr/bin/env bash
# capture-review.sh (SubagentStop) must:
# - ignore every agent that is not this plugin's reviewer
# - store the review next to the milestone's results, so its notes outlive the hand-back
# - enforce the severity rule: a [med] or [high] finding is a REJECT, so ACCEPT or
#   ACCEPT-WITH-NOTES alongside one is sent back once (F45)
# - never block twice, and never create a plan directory that does not exist
. "$(dirname "$0")/helpers.sh"

REPO=$(mk_repo demo)
T=$(tmpdir)
R=plan-and-verify:milestone-reviewer
FILE="$REPO/.claude/build-plans/demo/results/1.1.review.md"
EVENTS="$REPO/.claude/build-plans/demo/run/hook-events.jsonl"

HEAD=$'MILESTONE: demo/1.1\nChecks: PASS (1 passed, 0 failed)\nScope: clean'
ACCEPT="$HEAD"$'\nFindings: none\nVerdict: ACCEPT'
LOW="$HEAD"$'\nFindings:\n- [low] hello.txt:1 could name the constant\nVerdict: ACCEPT-WITH-NOTES'
MED="$HEAD"$'\nFindings:\n- [med] hello.txt:3 writes without checking the error\nVerdict: ACCEPT-WITH-NOTES'
HIGH="$HEAD"$'\nFindings:\n- [high] hello.txt:3 swallows the failure\nVerdict: ACCEPT'
REJECT="$HEAD"$'\nFindings:\n- [med] hello.txt:3 writes without checking the error\nVerdict: REJECT'
NOVERDICT="$HEAD"$'\nFindings:\n- [low] hello.txt:1 could name the constant'
AFTER_HANDBACK='Review of demo/1.1 delivered via SubagentHandback above.'

# stop <agent_type> <last_assistant_message> <transcript path> <stop_hook_active>
stop() {
  jq -n --arg a "$1" --arg m "$2" --arg tp "$3" --argjson act "$4" --arg cwd "$REPO" \
    '{hook_event_name:"SubagentStop",agent_type:$a,agent_id:"arev",cwd:$cwd,stop_hook_active:$act,
      last_assistant_message:$m,agent_transcript_path:$tp}' |
    CLAUDE_PROJECT_DIR="$REPO" bash "$HOOKS/capture-review.sh" 2>/dev/null
}
field() { [ -z "$1" ] && echo "" || jq -r "$2 // \"\"" <<<"$1" 2>/dev/null; }
outcome() { grep 'hook:capture-review' "$EVENTS" 2>/dev/null | tail -1 | jq -r '.outcome // ""'; }
plans() { ls "$REPO/.claude/build-plans" | tr '\n' ' '; }

# the shape of a real background agent transcript: the report is a hand-back, the last
# assistant message is a later one-liner
jq -nc --arg r "$LOW" '{type:"assistant",message:{role:"assistant",content:[{type:"tool_use",id:"toolu_1",name:"SubagentHandback",input:{message:$r}}]}}' > "$T/handback.jsonl"
jq -nc --arg f "$AFTER_HANDBACK" '{type:"assistant",message:{role:"assistant",content:[{type:"text",text:$f}]}}' >> "$T/handback.jsonl"
: > "$T/empty.jsonl"

echo "capture-review.sh"

# --- agents that are not the reviewer ------------------------------------------------
rm -f "$FILE"
out=$(stop "" "$ACCEPT" "$T/empty.jsonl" false)
assert_empty       "empty agent_type (internal agent): no output" "$out"
assert_path_absent "empty agent_type: nothing stored" "$FILE"
out=$(stop plan-and-verify:builder-sonnet "$ACCEPT" "$T/empty.jsonl" false)
assert_empty       "a builder stopping: no output" "$out"
assert_path_absent "a builder stopping: nothing stored" "$FILE"

# --- a clean ACCEPT -------------------------------------------------------------------
out=$(stop "$R" "$ACCEPT" "$T/empty.jsonl" false)
assert_empty    "ACCEPT: reviewer may stop" "$out"
assert_contains "ACCEPT: review stored on disk" "MILESTONE: demo/1.1" "$(cat "$FILE" 2>/dev/null)"
assert_contains "ACCEPT: review keeps the verdict" "Verdict: ACCEPT" "$(cat "$FILE" 2>/dev/null)"
assert_contains "ACCEPT: review records where it came from" "source:" "$(cat "$FILE" 2>/dev/null)"
assert_eq       "ACCEPT: logged to hook-events" ACCEPT "$(outcome)"

# --- ACCEPT-WITH-NOTES, every finding low --------------------------------------------
out=$(stop "$R" "$LOW" "$T/empty.jsonl" false)
assert_empty    "ACCEPT-WITH-NOTES with only low findings: reviewer may stop" "$out"
assert_contains "ACCEPT-WITH-NOTES: the notes are stored" "[low] hello.txt:1" "$(cat "$FILE" 2>/dev/null)"
assert_eq       "ACCEPT-WITH-NOTES: logged with its verdict" ACCEPT-WITH-NOTES "$(outcome)"

# --- the severity rule: med or high is a REJECT ---------------------------------------
out=$(stop "$R" "$MED" "$T/empty.jsonl" false)
assert_eq       "ACCEPT-WITH-NOTES with a med finding: blocks" block "$(field "$out" .decision)"
assert_contains "med finding: the reason says it is a REJECT" "REJECT" "$(field "$out" .reason)"
assert_contains "med finding: the reason offers the downgrade" "[low]" "$(field "$out" .reason)"
assert_contains "med finding: the reason names the verdict given" "ACCEPT-WITH-NOTES" "$(field "$out" .reason)"
assert_eq       "med finding: logged as a mismatch" verdict-mismatch "$(outcome)"
assert_contains "med finding: the review is stored anyway" "[med] hello.txt:3" "$(cat "$FILE" 2>/dev/null)"

out=$(stop "$R" "$HIGH" "$T/empty.jsonl" false)
assert_eq "ACCEPT with a high finding: blocks" block "$(field "$out" .decision)"

out=$(stop "$R" "$MED" "$T/empty.jsonl" true)
assert_not_contains "med finding, stop_hook_active: does not block again" '"block"' "$out"
assert_contains     "med finding, stop_hook_active: says so in a system message" "REJECT" "$(field "$out" .systemMessage)"

out=$(stop "$R" "$REJECT" "$T/empty.jsonl" false)
assert_empty "REJECT with a med finding: reviewer may stop" "$out"
assert_eq    "REJECT: logged with its verdict" REJECT "$(outcome)"

# --- a report with no verdict at all ---------------------------------------------------
out=$(stop "$R" "$NOVERDICT" "$T/empty.jsonl" false)
assert_eq       "no Verdict line: blocks" block "$(field "$out" .decision)"
assert_contains "no Verdict line: asks for it" "Verdict:" "$(field "$out" .reason)"
assert_eq       "no Verdict line: logged as no-verdict" no-verdict "$(outcome)"
out=$(stop "$R" "$NOVERDICT" "$T/empty.jsonl" true)
assert_not_contains "no Verdict line, stop_hook_active: does not block again" '"block"' "$out"

# --- no MILESTONE line anywhere ---------------------------------------------------------
out=$(stop "$R" "looks fine to me" "$T/empty.jsonl" false)
assert_eq       "no MILESTONE line: blocks" block "$(field "$out" .decision)"
assert_contains "no MILESTONE line: asks for the report format" "MILESTONE:" "$(field "$out" .reason)"
out=$(stop "$R" "looks fine to me" "$T/empty.jsonl" true)
assert_not_contains "no MILESTONE line, stop_hook_active: does not block again" '"block"' "$out"

# --- a plan this project does not have ---------------------------------------------------
before=$(plans)
out=$(stop "$R" $'MILESTONE: nosuch/9.9\nVerdict: ACCEPT' "$T/empty.jsonl" false)
assert_empty       "review naming a plan that does not exist: no output" "$out"
assert_path_absent "review naming a plan that does not exist: no plan dir created" "$REPO/.claude/build-plans/nosuch"
assert_eq          "review naming a plan that does not exist: build-plans unchanged" "$before" "$(plans)"

# --- the report delivered by SubagentHandback, as a background reviewer sends it ---------
rm -f "$FILE"
out=$(stop "$R" "$AFTER_HANDBACK" "$T/handback.jsonl" false)
assert_empty    "handback review: reviewer may stop" "$out"
assert_contains "handback review: found in the transcript and stored" "[low] hello.txt:1" "$(cat "$FILE" 2>/dev/null)"
assert_contains "handback review: records that it came from the transcript" "transcript" "$(cat "$FILE" 2>/dev/null)"

finish
