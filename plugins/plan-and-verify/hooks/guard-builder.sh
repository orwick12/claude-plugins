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
    for sub in $(pv_git_subcommands "$cmd"); do
      case "$sub" in
        commit|push|stash|reset|checkout|rebase|merge|switch|restore)
          deny "Builders never run git commit/push/stash/reset/checkout/rebase/merge/switch/restore. The main agent commits accepted work; your job ends at the report." ;;
      esac
    done
    if grep -qE 'checks\.json|hooks\.lock' <<<"$cmd" && grep -qE '(>|>>|sed\s+-i|tee|mv|cp|rm|jq\s.*>\s)' <<<"$cmd"; then
      deny "checks.json and hooks.lock are owned by the planner. If a check is wrong, report STATUS: BLOCKED."
    fi
    # Results files are the evidence acceptance trusts. Builders produce them only by
    # running the checks; writing one by hand would forge that evidence.
    if grep -qE 'build-plans/[^ ]*/results' <<<"$cmd" && grep -qE '(>|>>|sed\s+-i|tee|mv|cp|rm|truncate|jq\s.*>\s)' <<<"$cmd"; then
      deny "results files are written by run-checks.sh and the finish hook, never by you. Run 'bash \"\$PV_HOOKS/run-checks.sh\" <plan> <id>' instead; if a check is wrong, report STATUS: BLOCKED."
    fi ;;
  Edit|Write|MultiEdit)
    path=$(jq -r '.tool_input.file_path // ""' <<<"$input")
    case "$path" in
      */.claude/build-plans/*/checks.json|*/.claude/build-plans/*/hooks.lock|*/.claude/build-plans/*/plan.md)
        deny "$(basename "$path") is owned by the planner and the main agent. If something in it is wrong, report STATUS: BLOCKED." ;;
      */.claude/build-plans/*/results/*)
        deny "results files are written by run-checks.sh and the finish hook, never by you. Run 'bash \"\$PV_HOOKS/run-checks.sh\" <plan> <id>' instead; if a check is wrong, report STATUS: BLOCKED." ;;
    esac ;;
esac
exit 0
