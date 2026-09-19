#!/usr/bin/env bash
. "$(dirname "$0")/helpers.sh"
echo 'phase evidence'
setup() {
 R=$(mk_repo demo); TMPS="$TMPS $R"; D="$R/.claude/build-plans/demo"
 cat >> "$D/plan.md" <<'PLAN'

## Phase 2: next
### Milestone 2.1
review: 0
irreversible: no
depends-on: 1.1
goal: Write bye.txt.
status: TODO
PLAN
 jq '.milestones["2.1"]={checks:[{name:"bye",cmd:"cat bye.txt",expect:"equals",value:"bye"}]} | .gates["1"]={checks:[{name:"phase one",cmd:"cat hello.txt",expect:"equals",value:"ok"}]}' "$D/checks.json" > "$D/new"
 mv "$D/new" "$D/checks.json"
 git -C "$R" add -A; git -C "$R" commit -qm 'plan(demo): two phases'
 printf ok > "$R/hello.txt"
 CLAUDE_PROJECT_DIR="$R" bash "$HOOKS/run-checks.sh" demo 1.1 >/dev/null
 CLAUDE_PROJECT_DIR="$R" bash "$HOOKS/accept-milestone.sh" demo 1.1 >/dev/null
}
accept_two() {
 printf bye > "$R/bye.txt"
 CLAUDE_PROJECT_DIR="$R" bash "$HOOKS/run-checks.sh" demo 2.1 >/dev/null
 CLAUDE_PROJECT_DIR="$R" bash "$HOOKS/accept-milestone.sh" demo 2.1 >/dev/null 2>&1; code=$?
}
setup
CLAUDE_PROJECT_DIR="$R" bash "$HOOKS/run-checks.sh" demo gate:1 >/dev/null
accept_two
assert_eq 'clean accepted phase gate allows next phase' 0 "$code"
setup
printf unaccepted > "$R/leak.txt"
CLAUDE_PROJECT_DIR="$R" bash "$HOOKS/run-checks.sh" demo gate:1 >/dev/null
rm "$R/leak.txt"
accept_two
assert_eq 'gate from unaccepted source tree cannot authorize next phase' 2 "$code"
setup
printf unaccepted > "$R/leak.txt"
out=$(CLAUDE_PROJECT_DIR="$R" bash "$HOOKS/run-checks.sh" demo gate:1 2>&1); gcode=$?
assert_eq 'a gate refuses to run on an uncommitted tree' 3 "$gcode"
assert_contains 'the refusal names the uncommitted file' 'leak.txt' "$out"
# A gate is evidence about ITS OWN checks. The documented check-fix path amends a later
# milestone's check with a plan commit mid-milestone; that must not strand the earlier gate.
fix_check() {
 jq "$1" "$D/checks.json" > "$D/new"; mv "$D/new" "$D/checks.json"
 git -C "$R" add "$D/checks.json"; git -C "$R" commit -qm "plan(demo): $2"
}
setup
CLAUDE_PROJECT_DIR="$R" bash "$HOOKS/run-checks.sh" demo gate:1 >/dev/null
fix_check '.milestones["2.1"].checks[0].name="bye file"' 'fix check 2.1'
accept_two
assert_eq "a later milestone's check fix keeps the earlier gate valid" 0 "$code"
setup
CLAUDE_PROJECT_DIR="$R" bash "$HOOKS/run-checks.sh" demo gate:1 >/dev/null
fix_check '.gates["1"].checks[0].name="phase one ok"' 'fix gate 1 check'
accept_two
assert_eq "changing the gate's own checks makes its evidence stale" 2 "$code"
finish
