#!/usr/bin/env bash
. "$(dirname "$0")/helpers.sh"
. "$HOOKS/lib.sh"
setup() {
 R=$(mk_repo demo); D="$R/.claude/build-plans/demo"
 sed -i.bak 's/review: 0/review: 1/' "$D/plan.md"; rm "$D/plan.md.bak"
 git -C "$R" add .; git -C "$R" commit -qm 'plan(demo): evidence policy'
 printf ok > "$R/hello.txt"
 CLAUDE_PROJECT_DIR="$R" bash "$HOOKS/run-checks.sh" demo 1.1 >/dev/null
}
accept() { CLAUDE_PROJECT_DIR="$R" bash "$HOOKS/accept-milestone.sh" demo 1.1 >"$R-out" 2>&1; RC=$?; }
start() { TOKEN=$(CLAUDE_PROJECT_DIR="$R" bash "$HOOKS/review-start.sh" demo 1.1 2>/dev/null); }
review() { jq -nc --arg m "MILESTONE: demo/1.1
REVIEW-ID: ${TOKEN:-missing}
$1" '{agent_type:"milestone-reviewer",agent_id:"reviewer",stop_hook_active:true,last_assistant_message:$m}' | CLAUDE_PROJECT_DIR="$R" bash "$HOOKS/capture-review.sh" >/dev/null; }
echo 'structured evidence'
setup; accept; assert_eq 'missing required review refuses' 2 "$RC"
setup; start; review 'Verdict: REJECT'; accept; assert_eq 'reject refuses' 2 "$RC"
setup; start; review $'- [high] broken\nVerdict: ACCEPT'; assert_eq 'invalid second report remains INVALID' INVALID "$(jq -r .verdict "$D/results/1.1.review.json" 2>/dev/null)"; accept; assert_eq 'invalid second report refuses acceptance' 2 "$RC"
setup; start; printf changed > "$R/app.txt"; CLAUDE_PROJECT_DIR="$R" bash "$HOOKS/run-checks.sh" demo 1.1 >/dev/null; review 'Verdict: ACCEPT'; accept; assert_eq 'checks rerun cannot renew review-start identity' 2 "$RC"
setup; start; review 'Verdict: ACCEPT'; accept; assert_eq 'fresh approving review accepts' 0 "$RC"
assert_eq 'structured acceptance committed' 1 "$(git -C "$R" show HEAD:.claude/build-plans/demo/results/1.1.accepted.json 2>/dev/null | jq -r .schema_version)"
setup; a=$(pv_tree_sha "$R"); mkdir -p "$R/app/results"; printf changed > "$R/app/results/data"; b=$(pv_tree_sha "$R"); [ "$a" != "$b" ] && ok 'application results included' || bad 'application results included'
setup; a=$(pv_tree_sha "$R"); git -C "$R" commit --allow-empty -qm 'plan(demo): moved'; b=$(pv_tree_sha "$R"); [ "$a" != "$b" ] && ok 'HEAD included' || bad 'HEAD included'
setup; sed -i.bak 's/review: 1/review: 2/' "$D/plan.md"; rm "$D/plan.md.bak"; git -C "$R" add "$D/plan.md"; git -C "$R" commit -qm 'plan(demo): tier two'; CLAUDE_PROJECT_DIR="$R" bash "$HOOKS/run-checks.sh" demo 1.1 >/dev/null; start; review 'Verdict: ACCEPT'; accept; assert_eq 'tier two supervised needs recorded approval' 2 "$RC"
CLAUDE_PROJECT_DIR="$R" bash "$HOOKS/approve-milestone.sh" demo 1.1 --by 'test human' --reason 'explicit test approval' >/dev/null 2>&1; accept; assert_eq 'recorded approval allows tier two' 0 "$RC"
setup; sed -i.bak 's/depends-on: none/depends-on: 0.1/' "$D/plan.md"; rm "$D/plan.md.bak"; git -C "$R" add "$D/plan.md"; git -C "$R" commit -qm 'plan(demo): dependency'; CLAUDE_PROJECT_DIR="$R" bash "$HOOKS/run-checks.sh" demo 1.1 >/dev/null; start; review 'Verdict: ACCEPT'; accept; assert_eq 'unaccepted dependency refuses' 2 "$RC"
setup; start; review 'Verdict: ACCEPT'; start; accept; assert_eq 'new review attempt invalidates previous approval' 2 "$RC"
setup; sed -i.bak '/^review:/d' "$D/plan.md"; rm "$D/plan.md.bak"; git -C "$R" add "$D/plan.md"; git -C "$R" commit -qm 'plan(demo): missing policy'; CLAUDE_PROJECT_DIR="$R" bash "$HOOKS/run-checks.sh" demo 1.1 >/dev/null; accept; assert_eq 'missing review policy refuses' 2 "$RC"
setup; sed -i.bak 's/1.1/2.1/g' "$D/plan.md"; rm "$D/plan.md.bak"
jq '.milestones["2.1"] = .milestones["1.1"] | del(.milestones["1.1"]) | .gates["1"]={checks:[{name:"gate",cmd:"true"}]}' "$D/checks.json" > "$D/new"; mv "$D/new" "$D/checks.json"
git -C "$R" add "$D/plan.md" "$D/checks.json"; git -C "$R" commit -qm 'plan(demo): next phase'
CLAUDE_PROJECT_DIR="$R" bash "$HOOKS/run-checks.sh" demo 2.1 >/dev/null
TOKEN=$(CLAUDE_PROJECT_DIR="$R" bash "$HOOKS/review-start.sh" demo 2.1 2>/dev/null)
jq -nc --arg m "MILESTONE: demo/2.1
REVIEW-ID: $TOKEN
Verdict: ACCEPT" '{agent_type:"milestone-reviewer",agent_id:"reviewer",last_assistant_message:$m}' | CLAUDE_PROJECT_DIR="$R" bash "$HOOKS/capture-review.sh" >/dev/null
CLAUDE_PROJECT_DIR="$R" bash "$HOOKS/accept-milestone.sh" demo 2.1 >/dev/null 2>&1; RC=$?
assert_eq 'declared previous phase gate required' 2 "$RC"
finish
