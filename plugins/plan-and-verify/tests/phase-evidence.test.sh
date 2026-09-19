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
finish
