#!/usr/bin/env bash
. "$(dirname "$0")/helpers.sh"
echo 'artifact integrity'
R=$(mk_repo demo); TMPS="$TMPS $R"; D="$R/.claude/build-plans/demo"
mkdir -p "$R/app/results" "$D/results"
printf 'source-data' > "$R/app/results/value.txt"
printf 'evidence' > "$D/results/diagnostic.txt"
ref=$(CLAUDE_PROJECT_DIR="$R" bash "$HOOKS/snapshot.sh" demo 1.1 spawn)
assert_eq 'snapshot includes application results files' source-data "$(git -C "$R" show "$ref:app/results/value.txt" 2>/dev/null)"
git -C "$R" cat-file -e "$ref:.claude/build-plans/demo/results/diagnostic.txt" 2>/dev/null
code=$?
[ "$code" -ne 0 ] && ok 'snapshot excludes plugin evidence only' || bad 'snapshot excludes plugin evidence only'
printf ok > "$R/hello.txt"
printf hidden > "$R/hidden-source.txt"
git -C "$R" add hidden-source.txt; git -C "$R" commit -qm 'plan(demo): hide source in plan title'
CLAUDE_PROJECT_DIR="$R" bash "$HOOKS/run-checks.sh" demo 1.1 >/dev/null
CLAUDE_PROJECT_DIR="$R" bash "$HOOKS/accept-milestone.sh" demo 1.1 >/dev/null 2>&1
assert_eq 'plan-titled source commit since spawn is refused' 2 "$?"
finish
