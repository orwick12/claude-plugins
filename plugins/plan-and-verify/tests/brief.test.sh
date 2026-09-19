#!/usr/bin/env bash
# An autonomous run has to survive a context reset, so the orchestrator's picture of
# where it is must be rebuildable from the repository alone: git says what is accepted,
# plan.md says what was intended, the run log says what was decided. brief prints that
# picture; milestone hands back one work order without reading the whole plan.
. "$(dirname "$0")/helpers.sh"

REPO=$(mk_repo demo)
DIR="$REPO/.claude/build-plans/demo"
rs() { (cd "$REPO" && CLAUDE_PROJECT_DIR="$REPO" bash "$HOOKS/run-state.sh" "$@" 2>&1); }

# a second milestone, so "what is next" is a real question
cat >> "$DIR/plan.md" <<'EOF'

### Milestone 1.2
goal: Write bye.txt containing see-you.
status: TODO
irreversible: no
context: |
  Write bye.txt containing exactly see-you.
EOF
jq '.milestones["1.2"] = {"checks":[{"name":"bye is see-you","cmd":"cat bye.txt","expect":"equals","value":"see-you"}]}' \
  "$DIR/checks.json" > "$DIR/checks.json.new" && mv "$DIR/checks.json.new" "$DIR/checks.json"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m "plan(demo): add milestone 1.2"

echo "run-state.sh brief / milestone"

# --- milestone: one work order, not the whole plan ------------------------------------
out=$(rs milestone demo 1.1)
assert_contains     "milestone prints the goal"              "Write hello.txt" "$out"
assert_not_contains "milestone does not leak the next one"   "bye.txt"         "$out"
out=$(rs milestone demo 1.2)
assert_contains     "milestone prints the right block"       "see-you"         "$out"
assert_contains     "milestone keeps the work order"         "exactly see-you" "$out"

# --- milestone stops at the next phase heading, not just the next milestone -----------
# A plan has "## Phase N" headers between phases; the last milestone of a phase has no
# "### Milestone" after it until the next phase's first one, so it used to swallow the
# phase heading (and anything under it) along with its own block.
cat >> "$DIR/plan.md" <<'EOF'

## Phase 2: next
Phase 2 starts here.

### Milestone 2.1
goal: Write next.txt containing next.
status: TODO
irreversible: no
context: |
  Write next.txt containing exactly next.
EOF
out=$(rs milestone demo 1.2)
assert_not_contains "the last milestone of a phase does not leak the next phase's heading" "Phase 2" "$out"
assert_contains     "the last milestone of a phase still prints its own lines"             "see-you" "$out"
out=$(rs milestone demo 2.1)
assert_contains "the next phase's milestone prints intact" "Write next.txt"              "$out"
assert_contains "the next phase's milestone keeps its context" "exactly next"            "$out"

# Commit the plan amendment before acceptance (approved fixture correction).
git -C "$REPO" add "$DIR/plan.md"
git -C "$REPO" commit -q -m "plan(demo): add next phase"

# --- brief before anything is built ---------------------------------------------------
out=$(rs brief demo)
assert_contains "brief names the plan"                 "demo"       "$out"
assert_contains "brief shows the milestone as pending" "1.1"        "$out"
assert_contains "brief says what to run next"          "next: 1.1"  "$out"

# --- brief after a milestone is accepted ----------------------------------------------
printf 'ok' > "$REPO/hello.txt"
(cd "$REPO" && CLAUDE_PROJECT_DIR="$REPO" bash "$HOOKS/run-checks.sh" demo 1.1 >/dev/null 2>&1)
(cd "$REPO" && CLAUDE_PROJECT_DIR="$REPO" bash "$HOOKS/accept-milestone.sh" demo 1.1 >/dev/null 2>&1)
sha=$(git -C "$REPO" rev-parse --short HEAD)
out=$(rs brief demo)
assert_contains "brief reports the accepted milestone" "1.1" "$out"
assert_contains "brief cites the milestone commit"     "$sha" "$out"
assert_contains "brief moves on to the next one"       "next: 1.2" "$out"

# --- the run directory can be thrown away: git is the source of truth ------------------
rm -rf "$DIR/run"
out=$(rs brief demo)
assert_contains "brief still knows 1.1 is accepted without any run state" "$sha" "$out"
assert_contains "brief still knows what is next"                          "next: 1.2" "$out"

# --- decisions are shown back ----------------------------------------------------------
rs log demo '{"event":"halt","id":"1.2","class":"a","decision":"builder asked which store to use"}' >/dev/null
out=$(rs brief demo)
assert_contains "brief shows the last decision"   "builder asked which store" "$out"
assert_contains "brief shows its class"           "a"                         "$out"

# --- the markers of the builders that are open, or stopped and not yet accepted ---------
mkdir -p "$DIR/run/open"
jq -nc '{id:"1.2",agent_type:"plan-and-verify:builder-sonnet",state:"stopped",epoch:0,agent_id:"a1"}' \
  > "$DIR/run/open/1.2.json"
jq -nc '{id:"2.1",agent_type:"plan-and-verify:builder-opus",state:"open",epoch:0}' \
  > "$DIR/run/open/2.1.json"
out=$(rs brief demo)
assert_contains "brief lists the open builders"     "open builders:"  "$out"
assert_contains "brief says a stopped one stopped"  "stopped"         "$out"
assert_contains "brief says an open one is open"    "2.1    open"     "$out"
assert_contains "brief names the agent type"        "builder-opus"    "$out"
rm -rf "$DIR/run/open"

finish
