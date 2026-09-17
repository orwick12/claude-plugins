#!/usr/bin/env bash
# SessionStart hook. Tells the session where the plan-and-verify scripts live,
# both as a shell variable (PV_HOOKS, via CLAUDE_ENV_FILE) and as context.
# Also warns if any plan in this project was locked against different hooks.
set -u
HOOKS="$(cd "$(dirname "$0")" && pwd)"
. "$HOOKS/lib.sh"
ROOT=$(pv_root)
ver=$(jq -r .version "$HOOKS/../.claude-plugin/plugin.json" 2>/dev/null || echo unknown)

# Export for every Bash tool call in this session, when Claude Code offers the env file.
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  printf 'export PV_HOOKS=%q\n' "$HOOKS" >> "$CLAUDE_ENV_FILE"
fi

warn=""
for lock in "$ROOT"/.claude/build-plans/*/hooks.lock; do
  [ -f "$lock" ] || continue
  if ! bash "$HOOKS/lock-hooks.sh" verify "$(basename "$(dirname "$lock")")" >/dev/null 2>&1; then
    warn="$warn $(basename "$(dirname "$lock")")"
  fi
done

ctx="plan-and-verify v$ver is installed. Its scripts are in PV_HOOKS=$HOOKS (exported for Bash). Run them as: bash \"\$PV_HOOKS/run-checks.sh\" <plan> <id>, bash \"\$PV_HOOKS/accept-milestone.sh\" <plan> <id>, bash \"\$PV_HOOKS/snapshot.sh\" .... Plans live in .claude/build-plans/<slug>/."
[ -n "$warn" ] && ctx="$ctx WARNING: plans locked against different hook versions:$warn. Run bash \"\$PV_HOOKS/lock-hooks.sh\" write <slug> (and commit) before executing them."
jq -n --arg c "$ctx" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}'
