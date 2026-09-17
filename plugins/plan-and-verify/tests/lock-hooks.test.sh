#!/usr/bin/env bash
# hooks.lock is how a committed file vouches for scripts that live outside the repo.
# It hashed eight scripts and nothing else, so a plugin update that changed only the
# wiring (hooks.json) or an agent definition was invisible to it (F15) — which is
# exactly the change that broke enforcement in 1.1.0.
. "$(dirname "$0")/helpers.sh"

PLUGIN="$(cd "$HOOKS/.." && pwd)"

# copy the plugin somewhere writable so a "plugin update" can be simulated
copy_plugin() { local d; d=$(tmpdir); cp -R "$PLUGIN" "$d/plugin"; printf '%s' "$d/plugin"; }

REPO=$(mk_repo demo)                     # mk_repo already wrote a lock with the real hooks
LOCK="$REPO/.claude/build-plans/demo/hooks.lock"
verify() { (cd "$REPO" && CLAUDE_PROJECT_DIR="$REPO" bash "$1/hooks/lock-hooks.sh" verify demo 2>&1; echo "exit=$?"); }

echo "lock-hooks.sh"
assert_contains "a freshly written lock verifies" "hooks match lock" "$(verify "$PLUGIN")"
assert_contains "the lock names the plugin version" "plugin plan-and-verify" "$(cat "$LOCK")"

for f in "$HOOKS"/*.sh; do
  b=$(basename "$f")
  assert_contains "lock covers hooks/$b" "$b" "$(cat "$LOCK")"
done
assert_contains "lock covers hooks.json"          "hooks.json"        "$(cat "$LOCK")"
assert_contains "lock covers the builder agent"   "builder-sonnet.md" "$(cat "$LOCK")"
assert_contains "lock covers the reviewer agent"  "milestone-reviewer.md" "$(cat "$LOCK")"

# --- a plugin whose wiring changed must no longer verify ------------------------------
P=$(copy_plugin)
jq '.hooks.PreToolUse[0].matcher = "Bash"' "$P/hooks/hooks.json" > "$P/hooks/hooks.json.new"
mv "$P/hooks/hooks.json.new" "$P/hooks/hooks.json"
out=$(verify "$P")
assert_contains "hooks.json edited: verify fails" "exit=2" "$out"

P=$(copy_plugin)
printf '\n<!-- changed -->\n' >> "$P/agents/builder-sonnet.md"
out=$(verify "$P")
assert_contains "agent definition edited: verify fails" "exit=2" "$out"

P=$(copy_plugin)
printf '\n# changed\n' >> "$P/hooks/session-start.sh"
out=$(verify "$P")
assert_contains "session-start.sh edited: verify fails" "exit=2" "$out"

finish
