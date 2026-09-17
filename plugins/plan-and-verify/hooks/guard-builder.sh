#!/usr/bin/env bash
# PreToolUse guard. Only acts when the tool call comes from a builder subagent
# (agent_type plan-and-verify:builder-sonnet|opus, see pv_is_builder); for the main
# agent and every other agent it is a no-op, so the orchestrator can still commit,
# tag and branch. The patterns below are regexes over the command text: they stop
# honest mistakes, not a builder determined to get around them. Acceptance is the
# real control.
set -u
HOOKS="$(cd "$(dirname "$0")" && pwd)"
. "$HOOKS/lib.sh"
input=$(cat)
agent=$(jq -r '.agent_type // ""' <<<"$input")
pv_is_builder "$agent" || exit 0
tool=$(jq -r '.tool_name // ""' <<<"$input")
deny() { jq -n --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'; exit 0; }
case "$tool" in
  Bash)
    cmd=$(jq -r '.tool_input.command // ""' <<<"$input")
    if grep -qE '(^|[;&|]\s*)git\s+(commit|push|stash|reset|checkout|rebase|merge|switch|restore)\b' <<<"$cmd"; then
      deny "Builders never run git commit/push/stash/reset/checkout/rebase/merge/switch/restore. The main agent commits accepted work; your job ends at the report."
    fi
    if grep -qE 'checks\.json|hooks\.lock' <<<"$cmd" && grep -qE '(>|>>|sed\s+-i|tee|mv|cp|rm|jq\s.*>\s)' <<<"$cmd"; then
      deny "checks.json and hooks.lock are owned by the planner. If a check is wrong, report STATUS: BLOCKED."
    fi ;;
  Edit|Write|MultiEdit)
    path=$(jq -r '.tool_input.file_path // ""' <<<"$input")
    case "$path" in
      */.claude/build-plans/*/checks.json|*/.claude/build-plans/*/hooks.lock|*/.claude/build-plans/*/plan.md)
        deny "$(basename "$path") is owned by the planner and the main agent. If something in it is wrong, report STATUS: BLOCKED." ;;
    esac ;;
esac
exit 0
