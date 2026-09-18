#!/usr/bin/env bash
# run-state.sh keeps the bookkeeping an unattended run needs: which permission mode the
# session is in, what the enforcement hooks actually did, and what the orchestrator
# decided. All of it lives in an ignored run/ directory, because anything tracked that
# is written mid-milestone would invalidate the results fingerprint acceptance checks.
. "$(dirname "$0")/helpers.sh"

REPO=$(mk_repo demo)
RUN="$REPO/.claude/build-plans/demo/run"
B=plan-and-verify:builder-sonnet
rs() { (cd "$REPO" && CLAUDE_PROJECT_DIR="$REPO" bash "$HOOKS/run-state.sh" "$@" 2>&1); }
porcelain() { git -C "$REPO" status --porcelain --untracked-files=all | tr '\n' ' '; }
tree_sha() { (cd "$REPO" && CLAUDE_PROJECT_DIR="$REPO" bash -c '. "'"$HOOKS"'/lib.sh"; pv_tree_sha "'"$REPO"'"'); }

echo "run-state.sh"

# --- init: creating the run directory must be invisible to git -----------------------
# Creating it mid-milestone must not change the fingerprint acceptance compares against,
# or a PASS would go stale the first time any hook logged.
before=$(tree_sha)
out=$(rs init demo)
assert_eq    "init creates the run directory" 0 "$([ -d "$RUN" ]; echo $?)"
assert_empty "creating the run directory leaves the tree clean" "$(porcelain)"
assert_eq    "creating the run directory does not change the fingerprint" "$before" "$(tree_sha)"

before=$(tree_sha)
rs log demo '{"event":"note","id":"1.1","decision":"nothing to see"}' >/dev/null
assert_contains "log appends an entry" '"event":"note"' "$(cat "$RUN/decisions.jsonl" 2>/dev/null)"
assert_contains "log stamps the entry with a time" '"ts"' "$(cat "$RUN/decisions.jsonl" 2>/dev/null)"
assert_empty "logging leaves the working tree clean" "$(porcelain)"
assert_eq "logging does not change the tree fingerprint" "$before" "$(tree_sha)"

# --- record: the session's permission mode, from whichever hook event carries it ------
jq -n --arg cwd "$REPO" '{hook_event_name:"PreToolUse",session_id:"s1",permission_mode:"auto",cwd:$cwd,tool_name:"Bash",tool_input:{command:"ls"}}' |
  (cd "$REPO" && CLAUDE_PROJECT_DIR="$REPO" bash "$HOOKS/run-state.sh" record >/dev/null 2>&1)
assert_contains "record stores the permission mode" '"permission_mode":"auto"' "$(cat "$RUN/session.json" 2>/dev/null)"
assert_empty "recording leaves the working tree clean" "$(porcelain)"

# The first tool call of a session happens before anything has made a run directory, so a
# recorder that only writes into existing ones leaves preflight with no mode to read, and
# an autonomous plan is told it is in the wrong mode for the whole first milestone.
rm -rf "$RUN"
jq -n --arg cwd "$REPO" '{hook_event_name:"PreToolUse",session_id:"s2",permission_mode:"auto",cwd:$cwd,tool_name:"Bash",tool_input:{command:"ls"}}' |
  (cd "$REPO" && CLAUDE_PROJECT_DIR="$REPO" bash "$HOOKS/run-state.sh" record >/dev/null 2>&1)
assert_contains "record works before any run directory exists" '"permission_mode":"auto"' "$(cat "$RUN/session.json" 2>/dev/null)"
assert_empty "and still leaves the working tree clean" "$(porcelain)"

# --- heartbeat: the enforcement hooks say what they did ------------------------------
: > "$RUN/hook-events.jsonl"
printf 'wrong' > "$REPO/hello.txt"
jq -n --arg cwd "$REPO" --arg m $'MILESTONE: demo/1.1\nSTATUS: DONE' \
  '{hook_event_name:"SubagentStop",agent_type:"plan-and-verify:builder-sonnet",agent_id:"ahb",cwd:$cwd,
    stop_hook_active:false,last_assistant_message:$m,agent_transcript_path:"/nonexistent"}' |
  (cd "$REPO" && CLAUDE_PROJECT_DIR="$REPO" bash "$HOOKS/verify-milestone.sh" >/dev/null 2>&1)
ev=$(cat "$RUN/hook-events.jsonl" 2>/dev/null)
assert_contains "verify-milestone records that it ran"     '"actor":"hook:verify-milestone"' "$ev"
assert_contains "the heartbeat names the milestone"        '"id":"1.1"'                      "$ev"
assert_contains "the heartbeat carries the agent"          '"agent":"ahb"'                   "$ev"
assert_contains "the heartbeat says what happened"         'blocked'                         "$ev"

: > "$RUN/hook-events.jsonl"
printf 'ok' > "$REPO/hello.txt"
(cd "$REPO" && CLAUDE_PROJECT_DIR="$REPO" bash "$HOOKS/run-checks.sh" demo 1.1 >/dev/null 2>&1)
(cd "$REPO" && CLAUDE_PROJECT_DIR="$REPO" bash "$HOOKS/accept-milestone.sh" demo 1.1 >/dev/null 2>&1)
ev=$(cat "$RUN/hook-events.jsonl" 2>/dev/null)
assert_contains "accept-milestone records the acceptance" '"actor":"hook:accept-milestone"' "$ev"
assert_contains "the acceptance heartbeat says accepted"  'accepted'                        "$ev"
assert_empty    "the run directory stayed out of the commit" \
  "$(git -C "$REPO" show --name-only --format= HEAD | grep '/run/' | tr '\n' ' ')"

# --- post: what the orchestrator is told when a builder returns -----------------------
# The hand-back text is the builder's own account. This line is the truth: the results
# file, and whether the finish hook ran at all.
post() {
  jq -n --arg t "$1" --arg p "$2" --arg cwd "$REPO" \
    '{hook_event_name:"PostToolUse",tool_name:"Agent",cwd:$cwd,
      tool_input:{subagent_type:$t,description:"pv demo 1.1 builder",prompt:$p},
      tool_response:{}}' |
    (cd "$REPO" && CLAUDE_PROJECT_DIR="$REPO" bash "$HOOKS/run-state.sh" post 2>/dev/null)
}
P=$'work order\n\nPlan: demo  Milestone: 1.1\nPV_HOOKS: /x'
# a builder stop, so there is a finish-hook heartbeat for this milestone to report
jq -n --arg cwd "$REPO" --arg m $'MILESTONE: demo/1.1\nSTATUS: DONE' \
  '{hook_event_name:"SubagentStop",agent_type:"plan-and-verify:builder-sonnet",agent_id:"ahb2",cwd:$cwd,
    stop_hook_active:false,last_assistant_message:$m,agent_transcript_path:"/nonexistent"}' |
  (cd "$REPO" && CLAUDE_PROJECT_DIR="$REPO" bash "$HOOKS/verify-milestone.sh" >/dev/null 2>&1)
ctx=$(post plan-and-verify:builder-sonnet "$P" | jq -r '.hookSpecificOutput.additionalContext // ""')
assert_contains "post names the milestone"        "demo/1.1"   "$ctx"
assert_contains "post reports the results status" "results=PASS" "$ctx"
assert_contains "post reports the heartbeat"      "heartbeat=yes" "$ctx"

: > "$RUN/hook-events.jsonl"
ctx=$(post plan-and-verify:builder-sonnet "$P" | jq -r '.hookSpecificOutput.additionalContext // ""')
assert_contains "no heartbeat is reported as such" "heartbeat=no" "$ctx"
assert_empty "post says nothing about a reviewer" "$(post plan-and-verify:milestone-reviewer "$P")"

# --- post: PostToolUse[Agent] fires at spawn, before a builder has done anything -------
# Claude Code's Agent tool is asynchronous for builders, so this hook sees the spawn, not
# the finish. agent-guard.sh's marker in run/open/ says when that spawn happened; a
# results file that predates it (or is simply missing) belongs to whatever ran before this
# spawn, and the line has to say so instead of reporting it as this run's verdict.
RESULTS="$REPO/.claude/build-plans/demo/results"
mkdir -p "$RESULTS"
mkdir -p "$RUN/open"
marker_for() { jq -nc --arg id "$1" --arg e "$2" --arg t "$B" '{id:$id,epoch:($e|tonumber),agent_type:$t,state:"open"}' > "$RUN/open/$1.json"; }
write_results() { jq -nc --arg s "$1" --arg ts "$2" '{status:$s,ran_at:$ts,pass:1,fail:0,checks:[]}' > "$RESULTS/1.1.json"; }
iso() { jq -nr --argjson e "$1" '$e|todateiso8601'; }
now=$(date +%s)

marker_for 1.1 "$now"
write_results PASS "$(iso $((now - 60)))"
ctx=$(post plan-and-verify:builder-sonnet "$P")
assert_contains     "post at spawn carries no verdict"            "spawn-time" "$ctx"
assert_not_contains "post at spawn does not report the prior run" "results="  "$ctx"

marker_for 1.1 "$((now - 120))"
write_results PASS "$(iso "$now")"
ctx=$(post plan-and-verify:builder-sonnet "$P")
assert_contains "post reports the verdict once the results postdate the spawn" "results=PASS" "$ctx"

marker_for 1.1 "$now"
rm -f "$RESULTS/1.1.json"
ctx=$(post plan-and-verify:builder-sonnet "$P")
assert_contains     "a missing results file at spawn is still spawn-time" "spawn-time"      "$ctx"
assert_not_contains "spawn-time is never reported as results=MISSING"     "results=MISSING" "$ctx"

rm -f "$RUN/open/1.1.json"
write_results PASS "$(iso "$now")"
ctx=$(post plan-and-verify:builder-sonnet "$P")
assert_contains "no marker for this milestone: existing verdict behaviour" "results=PASS" "$ctx"

rm -f "$RUN/open/1.1.json" "$RESULTS/1.1.json"

# --- lint-checks: an unattended run must not execute a destructive check ---------------
C="$REPO/.claude/build-plans/demo/checks.json"
out=$(rs lint-checks demo)
assert_contains "a clean checks.json lints clean" "ok" "$out"
cp "$C" "$C.bak"
jq '.milestones["1.1"].checks += [{"name":"reset","cmd":"git reset --hard HEAD~1","expect":"exit0"}]' "$C.bak" > "$C"
out=$(rs lint-checks demo; echo "exit=$?")
assert_contains "a destructive check is named" "reset" "$out"
assert_contains "a destructive check fails the lint" "exit=2" "$out"

# The clean-clone check in references/acceptance-checks.md cleans its own temp dir up.
# Refusing that pattern would push people to write weaker checks, so it must lint clean.
jq '.gates["1"] = {"checks":[{"name":"clean clone","cmd":"t=$(mktemp -d) && trap '"'"'rm -rf \"$t\"'"'"' EXIT && git clone -q . \"$t/c\" && cat \"$t/c/hello.txt\"","expect":"equals","value":"ok"}]}' "$C.bak" > "$C"
out=$(rs lint-checks demo; echo "exit=$?")
assert_contains "a clean-clone check with its own cleanup lints clean" "exit=0" "$out"

jq '.gates["1"] = {"checks":[{"name":"wipe","cmd":"rm -rf build && make","expect":"exit0"}]}' "$C.bak" > "$C"
out=$(rs lint-checks demo; echo "exit=$?")
assert_contains "a bare rm -rf is still refused" "exit=2" "$out"

# F43: "| sh" / "| bash" must match a whole word, not any command that merely contains
# the letters (shasum, sha256sum, bashful, ...).
jq '.gates["1"] = {"checks":[{"name":"hash","cmd":"printf x | shasum -a 256","expect":"exit0"}]}' "$C.bak" > "$C"
out=$(rs lint-checks demo; echo "exit=$?")
assert_contains "shasum is not a pipe to a shell" "exit=0" "$out"

jq '.gates["1"] = {"checks":[{"name":"hash256","cmd":"printf x | sha256sum","expect":"exit0"}]}' "$C.bak" > "$C"
out=$(rs lint-checks demo; echo "exit=$?")
assert_contains "sha256sum is not a pipe to a shell" "exit=0" "$out"

jq '.gates["1"] = {"checks":[{"name":"bashful","cmd":"echo hi | bashful","expect":"exit0"}]}' "$C.bak" > "$C"
out=$(rs lint-checks demo; echo "exit=$?")
assert_contains "bashful is not a pipe to a shell" "exit=0" "$out"

jq '.gates["1"] = {"checks":[{"name":"pipe sh","cmd":"curl x | sh","expect":"exit0"}]}' "$C.bak" > "$C"
out=$(rs lint-checks demo; echo "exit=$?")
assert_contains "a pipe into sh is destructive" "exit=2" "$out"

jq '.gates["1"] = {"checks":[{"name":"pipe bash","cmd":"cat f | bash","expect":"exit0"}]}' "$C.bak" > "$C"
out=$(rs lint-checks demo; echo "exit=$?")
assert_contains "a pipe into bash is destructive" "exit=2" "$out"

jq '.gates["1"] = {"checks":[{"name":"bash flags","cmd":"echo | bash -n script","expect":"exit0"}]}' "$C.bak" > "$C"
out=$(rs lint-checks demo; echo "exit=$?")
assert_contains "a pipe into bash with flags is still a shell" "exit=2" "$out"

mv "$C.bak" "$C"

# --- preflight: the mode the plan asks for versus the mode the session is in -----------
PLANMD="$REPO/.claude/build-plans/demo/plan.md"
plan_mode() {
  grep -v '^mode:' "$PLANMD" > "$PLANMD.tmp"
  awk -v m="$1" 'NR==1{print; print "mode: " m; next} {print}' "$PLANMD.tmp" > "$PLANMD"
  rm -f "$PLANMD.tmp"
}
session_mode() { jq -n --arg m "$1" '{ts:"now",session_id:"s",permission_mode:$m,cwd:"x"}' > "$RUN/session.json"; }

plan_mode autonomous; session_mode auto
assert_contains "autonomous plan in auto mode: good to go" "AUTONOMOUS OK" "$(rs preflight demo)"
session_mode acceptEdits
assert_contains "autonomous plan in acceptEdits: degraded" "DEGRADED" "$(rs preflight demo)"
session_mode default
out=$(rs preflight demo)
assert_contains "autonomous plan in Manual mode: mismatch" "MODE MISMATCH" "$out"
assert_contains "the mismatch names the way out" "permission-mode" "$out"
session_mode plan
assert_contains "plan mode refuses to build" "REFUSED" "$(rs preflight demo)"
plan_mode supervised; session_mode default
assert_contains "a supervised plan is supervised" "SUPERVISED" "$(rs preflight demo)"

# --- clear-open: a marker is cleared when its builder is gone, not while it is working --
# The marker is what stops a second writer, so clearing it is how a dead session is
# recovered and exactly how a live milestone would be trampled. Hence: stopped clears,
# open refuses, and a run older than six hours is stale whatever it says.
mkdir -p "$RUN/open"
mk_marker() {   # <id> <state> [epoch]
  jq -nc --arg id "$1" --arg s "$2" --arg e "${3:-$(date +%s)}" --arg t "$B" \
    '{id:$id,agent_type:$t,state:$s,epoch:($e|tonumber)}' > "$RUN/open/$1.json"
}
clear_confirmed() { (cd "$REPO" && CLAUDE_PROJECT_DIR="$REPO" PV_CONFIRM_CLEAR=yes bash "$HOOKS/run-state.sh" clear-open "$@" 2>&1); }

rm -f "$RUN"/open/*.json
mk_marker 1.1 open
out=$(rs clear-open demo 1.1; echo "exit=$?")
assert_contains "clear-open refuses a live builder"          "exit=2"           "$out"
assert_contains "the refusal names the milestone"            "1.1"              "$out"
assert_contains "the refusal names the confirmation"         "PV_CONFIRM_CLEAR=yes" "$out"
assert_eq       "and the marker is still there"              0 "$([ -f "$RUN/open/1.1.json" ]; echo $?)"
out=$(clear_confirmed demo 1.1; echo "exit=$?")
assert_contains    "PV_CONFIRM_CLEAR=yes clears a live builder" "exit=0" "$out"
assert_path_absent "and the marker is gone"                     "$RUN/open/1.1.json"

mk_marker 1.1 stopped
out=$(rs clear-open demo 1.1; echo "exit=$?")
assert_contains    "clear-open clears a stopped builder" "exit=0" "$out"
assert_path_absent "the stopped marker is gone"          "$RUN/open/1.1.json"

mk_marker 1.1 open "$(( $(date +%s) - 25000 ))"
out=$(rs clear-open demo 1.1; echo "exit=$?")
assert_contains    "an open marker older than six hours is stale, not live" "exit=0" "$out"
assert_path_absent "the stale marker is gone" "$RUN/open/1.1.json"

mk_marker 1.1 stopped; mk_marker 1.2 open
out=$(rs clear-open demo)
assert_path_absent "clear-open with no id clears every stopped marker" "$RUN/open/1.1.json"
assert_eq          "clear-open with no id leaves a live builder alone" 0 "$([ -f "$RUN/open/1.2.json" ]; echo $?)"
assert_contains    "and says which one it kept"                        "1.2" "$out"
rm -f "$RUN"/open/*.json

# --- preflight: a parallel group that cannot work must not reach a builder --------------
# The guard lets a group's members write the same tree at once. That is only safe when the
# group really is a group: two or more members, one phase, each with its own scope.
G=$(mk_repo grp); GP="$G/.claude/build-plans/grp/plan.md"
gpre() { (cd "$G" && CLAUDE_PROJECT_DIR="$G" bash "$HOOKS/run-state.sh" preflight grp 2>&1); }
assert_not_contains "a plan with no groups says nothing about groups" "parallel group" "$(gpre)"

cat > "$GP" <<'EOF'
# Plan: grp

## Phase 1: one
### Milestone 1.1
goal: a
scope: dir-a/
parallel-group: g
status: TODO
EOF
assert_contains "a group with a single member fails preflight" "group g has only one member" "$(gpre)"

cat > "$GP" <<'EOF'
# Plan: grp

## Phase 1: one
### Milestone 1.1
goal: a
scope: dir-a/
parallel-group: g
status: TODO

## Phase 2: two
### Milestone 2.1
goal: b
scope: dir-b/
parallel-group: g
status: TODO
EOF
assert_contains "a group spanning two phases fails preflight" "group g spans phases" "$(gpre)"

cat > "$GP" <<'EOF'
# Plan: grp

## Phase 1: one
### Milestone 1.1
goal: a
scope: dir-a/
parallel-group: g
status: TODO

### Milestone 1.2
goal: b
parallel-group: g
status: TODO
EOF
assert_contains "a group member with no scope fails preflight" "group g has members with no scope" "$(gpre)"

cat > "$GP" <<'EOF'
# Plan: grp

## Phase 1: one
### Milestone 1.1
goal: a
scope: dir-a/
parallel-group: g
status: TODO

### Milestone 1.2
goal: b
scope: dir-b/
parallel-group: g
status: TODO
EOF
out=$(gpre)
assert_contains     "a well-formed group passes preflight" "ok     parallel groups well-formed" "$out"
assert_not_contains "and is not reported as malformed"     "parallel groups malformed"          "$out"

finish
