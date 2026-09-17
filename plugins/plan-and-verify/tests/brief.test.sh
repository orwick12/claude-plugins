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

finish
