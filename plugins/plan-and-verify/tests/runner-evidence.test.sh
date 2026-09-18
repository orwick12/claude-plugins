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
finish
