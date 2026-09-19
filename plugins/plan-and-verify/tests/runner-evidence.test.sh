#!/usr/bin/env bash
. "$(dirname "$0")/helpers.sh"
echo 'runner evidence'
R=$(mk_repo demo); D="$R/.claude/build-plans/demo"; printf ok > "$R/hello.txt"
CLAUDE_PROJECT_DIR="$R" bash "$HOOKS/run-checks.sh" demo 1.1 >/dev/null
jq '.status="BLOCKED"' "$D/results/1.1.json" > "$D/results/tmp"; mv "$D/results/tmp" "$D/results/1.1.json"
CLAUDE_PROJECT_DIR="$R" bash "$HOOKS/run-checks.sh" demo 1.1 --observe >/dev/null
assert_eq 'observe preserves primary evidence' BLOCKED "$(jq -r .status "$D/results/1.1.json")"
assert_eq 'observe writes separate evidence' PASS "$(jq -r .status "$D/results/1.1.observed.json" 2>/dev/null)"
jq '.milestones["1.1"].checks=[{name:"mutates",cmd:"echo changed > source.txt"}]' "$D/checks.json" > "$D/new"; mv "$D/new" "$D/checks.json"
CLAUDE_PROJECT_DIR="$R" bash "$HOOKS/run-checks.sh" demo 1.1 >/dev/null; RC=$?
assert_eq 'source-mutating check fails' 1 "$RC"
assert_eq 'source-mutating check never PASS' FAIL "$(jq -r .status "$D/results/1.1.json")"
# The failure must say which file the run left behind, or it reads as flaky: a rerun passes
# once the file exists, and the file is then committed with the milestone.
R=$(mk_repo demo); D="$R/.claude/build-plans/demo"; printf ok > "$R/hello.txt"
jq '.milestones["1.1"].checks=[{name:"writes coverage",cmd:"cat hello.txt; echo cov > coverage.out"}]' "$D/checks.json" > "$D/new"; mv "$D/new" "$D/checks.json"
out=$(CLAUDE_PROJECT_DIR="$R" bash "$HOOKS/run-checks.sh" demo 1.1 2>&1)
assert_eq 'a check that leaves a file behind fails' FAIL "$(jq -r .status "$D/results/1.1.json")"
assert_contains 'the failure names the file the check left behind' 'coverage.out' "$out"
assert_contains 'the recorded row names it too' 'coverage.out' "$(jq -r '.checks[-1].output_tail' "$D/results/1.1.json")"
finish
