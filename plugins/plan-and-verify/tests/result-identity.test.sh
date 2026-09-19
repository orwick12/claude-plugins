#!/usr/bin/env bash
. "$(dirname "$0")/helpers.sh"
echo 'result identity'
R=$(mk_repo demo); TMPS="$TMPS $R"; D="$R/.claude/build-plans/demo"
printf ok > "$R/hello.txt"
CLAUDE_PROJECT_DIR="$R" bash "$HOOKS/run-checks.sh" demo 1.1 >/dev/null
jq '.id="1.2"' "$D/results/1.1.json" > "$D/results/copied.json"
mv "$D/results/copied.json" "$D/results/1.1.json"
CLAUDE_PROJECT_DIR="$R" bash "$HOOKS/accept-milestone.sh" demo 1.1 >/dev/null 2>&1
assert_eq 'matching fingerprints cannot authorize another milestone result' 2 "$?"
finish
