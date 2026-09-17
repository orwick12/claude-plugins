#!/usr/bin/env bash
# run-checks.sh must bound a check in wall-clock time even when the check leaves
# children behind (F1). Two separate failures are covered:
#   - the timeout kills only the direct child, so a grandchild keeps running
#   - the runner captures output through a pipe, so an orphan holding that pipe
#     blocks the runner long after the timeout has passed
# These tests take a few seconds by nature; they are the only slow ones in the suite.
. "$(dirname "$0")/helpers.sh"

REPO=$(mk_repo demo)
MARKER="$REPO/orphan-marker.txt"
C="$REPO/.claude/build-plans/demo/checks.json"

# one_check <name> <cmd> <timeout>: rewrite the plan's checks to a single command
one_check() {
  jq --arg n "$1" --arg c "$2" --argjson t "$3" \
    '.defaults.timeout = $t | .milestones["1.1"].checks = [{name:$n,cmd:$c,expect:"exit0"}]' "$C" > "$C.new"
  mv "$C.new" "$C"
}
run() { (cd "$REPO" && CLAUDE_PROJECT_DIR="$REPO" bash "$HOOKS/run-checks.sh" demo 1.1 >/dev/null 2>&1); }
result() { jq -r "$1" "$REPO/.claude/build-plans/demo/results/1.1.json" 2>/dev/null; }

echo "run-checks.sh"

# --- a check that backgrounds a child which outlives the timeout ---------------------
rm -f "$MARKER"
# the child writes its marker at 3s and holds the runner's output pipe until 8s
one_check "backgrounds a child" "( sleep 3; touch '$MARKER'; sleep 5 ) & echo started; sleep 10" 1
t0=$(date +%s); run; t1=$(date +%s); elapsed=$((t1-t0))
[ "$elapsed" -lt 6 ] && ok "orphaned child does not stall the runner (${elapsed}s)" \
                     || bad "orphaned child does not stall the runner" "took ${elapsed}s, expected under 6"
assert_eq       "timed-out check fails" FAIL "$(result .status)"
assert_contains "timed-out check says TIMEOUT" "TIMEOUT" "$(result '.checks[0].output_tail')"
sleep 4
assert_path_absent "the backgrounded grandchild was killed with its group" "$MARKER"

# --- a check that reads stdin must not wait for input --------------------------------
one_check "reads stdin" "cat" 2
t0=$(date +%s); run; t1=$(date +%s); elapsed=$((t1-t0))
[ "$elapsed" -lt 6 ] && ok "a check reading stdin returns immediately (${elapsed}s)" \
                     || bad "a check reading stdin returns immediately" "took ${elapsed}s, expected under 6"

# --- ordinary checks still behave ----------------------------------------------------
one_check "quick pass" "echo hi" 5
run
assert_eq "an ordinary check still passes" PASS "$(result .status)"
one_check "quick fail" "exit 3" 5
run
assert_eq "an ordinary failure is still a failure" FAIL "$(result .status)"
assert_eq "the real exit code is recorded" 3 "$(result '.checks[0].exit')"

finish
