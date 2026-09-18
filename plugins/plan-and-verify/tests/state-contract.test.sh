#!/usr/bin/env bash
. "$(dirname "$0")/helpers.sh"
REPO=$(mk_repo demo); TMPS="$TMPS $REPO"
DIR="$REPO/.claude/build-plans/demo"
rs() { CLAUDE_PROJECT_DIR="$REPO" bash "$HOOKS/run-state.sh" "$@" 2>/dev/null; }
accepted() { rs accepted demo "$1" >/dev/null; echo $?; }
spawn() {
  jq -nc --arg cwd "$REPO" --arg p "Plan: demo Milestone: $1" \
    '{cwd:$cwd,tool_name:"Agent",tool_input:{subagent_type:"builder-sonnet",prompt:$p}}' |
    CLAUDE_PROJECT_DIR="$REPO" bash "$HOOKS/agent-guard.sh" |
    jq -r '.hookSpecificOutput.permissionDecision // "allow"'
}
# Literal matching must not treat dots as regex wildcards or incidental prose as acceptance.
git -C "$REPO" commit -q --allow-empty -m 'notes: [demo 1.1]'
assert_eq 'incidental bracket reference is not acceptance' 1 "$(accepted 1.1)"
git -C "$REPO" commit -q --allow-empty -m 'milestone(1x1): done [demo 1x1]'
assert_eq 'IDs are literal' 1 "$(accepted 1.1)"
git -C "$REPO" commit -q --allow-empty -m 'milestone(1.1 1.2): group done [demo 1.1 1.2]'
assert_eq 'historical group accepts first member' 0 "$(accepted 1.1)"
assert_eq 'historical group accepts second member' 0 "$(accepted 1.2)"
assert_contains 'brief sees group acceptance' '1.1    accepted' "$(rs brief demo)"
assert_eq 'guard agrees group is accepted' deny "$(spawn 1.1)"
mkdir -p "$DIR/results"
base=$(git -C "$REPO" rev-parse HEAD)
jq -nc --arg b "$base" '{schema_version:1,plan:"demo",id:"1.3",base_commit:$b,tree_sha:"abc",checks_sha:"def"}' > "$DIR/results/1.3.accepted.json"
assert_eq 'uncommitted acceptance is ignored' 1 "$(accepted 1.3)"
git -C "$REPO" add -A; git -C "$REPO" commit -q -m 'save structured acceptance'
assert_eq 'committed structured acceptance works' 0 "$(accepted 1.3)"
printf 'not json' > "$DIR/results/1.3.accepted.json"
assert_eq 'working copy cannot corrupt committed acceptance' 0 "$(accepted 1.3)"
printf '{"schema_version":1,"plan":"demo","id":"1.4"}' > "$DIR/results/1.4.accepted.json"
git -C "$REPO" add -A; git -C "$REPO" commit -q -m 'invalid record'
assert_eq 'incomplete committed acceptance refused' 1 "$(accepted 1.4)"
cat >> "$DIR/plan.md" <<'PLAN'

### Milestone 1.5
depends-on: 1.4
review: 1

### Milestone 1.6
depends-on: 1.1, 1.2
review: 1
PLAN
out=$(rs status demo 1.5)
assert_eq 'status identifies dependency block' blocked "$(jq -r .state <<<"$out")"
assert_eq 'status names unsatisfied dependency' 1.4 "$(jq -r '.dependencies.pending[0]' <<<"$out")"
assert_eq 'guard enforces dependencies' deny "$(spawn 1.5)"
assert_empty 'accepted dependencies allow fresh builder' "$(spawn 1.6)"
assert_eq 'same milestone live overlap denied' deny "$(spawn 1.6)"
jq '.state="stopped"' "$DIR/run/open/1.6.json" > "$DIR/run/open/1.6.tmp"; mv "$DIR/run/open/1.6.tmp" "$DIR/run/open/1.6.json"
assert_empty 'stopped same milestone can escalate' "$(spawn 1.6)"
rm "$DIR/run/open/1.6.json"
mkdir -p "$REPO/.claude/build-plans/other/run/open"
jq -nc --argjson e "$(date +%s)" '{id:"9.1",state:"open",epoch:$e}' > "$REPO/.claude/build-plans/other/run/open/9.1.json"
assert_eq 'other plan writer blocks spawning' deny "$(spawn 1.6)"
rm "$REPO/.claude/build-plans/other/run/open/9.1.json"
. "$HOOKS/lib.sh"
tree=$(pv_tree_sha "$REPO"); checks=$(pv_sha256 < "$DIR/checks.json")
jq -nc --arg t "$tree" --arg c "$checks" '{status:"PASS",tree_sha:$t,checks_sha:$c}' > "$DIR/results/1.6.json"
jq -nc --arg t "$tree" --arg c "$checks" --arg b "$(git -C "$REPO" rev-parse HEAD)" \
 '{schema_version:1,plan:"demo",id:"1.6",verdict:"REJECT",tree_sha:$t,checks_sha:$c,base_commit:$b}' > "$DIR/results/1.6.review.json"
out=$(rs status demo 1.6)
assert_eq 'compact check freshness' true "$(jq -r .checks.fresh <<<"$out")"
assert_eq 'compact review verdict' REJECT "$(jq -r .review.verdict <<<"$out")"
assert_eq 'compact review freshness' true "$(jq -r .review.fresh <<<"$out")"
assert_eq 'reject suggests repair' repair "$(jq -r .next_action <<<"$out")"
printf changed > "$REPO/source.txt"
out=$(rs status demo 1.6)
assert_eq 'source edit makes checks stale' false "$(jq -r .checks.fresh <<<"$out")"
assert_eq 'source edit makes review stale' false "$(jq -r .review.fresh <<<"$out")"
[ "${#out}" -lt 4096 ] && ok 'status bounded under 4KB' || bad 'status bounded under 4KB'
rs log demo '{"actor":"orchestrator","event":"decision","id":"1.6","decision":"repair"}' >/dev/null
assert_contains 'brief identifies decision actor' orchestrator "$(rs brief demo)"
finish
