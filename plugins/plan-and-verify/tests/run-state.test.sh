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

finish
