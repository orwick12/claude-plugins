#!/usr/bin/env bash
# guard-builder.sh must act on plugin builders as Claude Code names them
# (plan-and-verify:builder-sonnet), and on nothing else.
. "$(dirname "$0")/helpers.sh"

# guard <agent_type|-> <tool> <tool_input json>   ("-" = no agent_type key, as for the main agent)
guard() {
  if [ "$1" = "-" ]; then
    jq -n --arg t "$2" --argjson i "$3" '{hook_event_name:"PreToolUse",tool_name:$t,tool_input:$i}'
  else
    jq -n --arg a "$1" --arg t "$2" --argjson i "$3" '{hook_event_name:"PreToolUse",agent_type:$a,tool_name:$t,tool_input:$i}'
  fi | bash "$HOOKS/guard-builder.sh"
}
decision() { [ -z "$1" ] && echo allow || jq -r '.hookSpecificOutput.permissionDecision // "allow"' <<<"$1"; }

sw='{"command":"git switch -h"}'
planmd='{"file_path":"/work/proj/.claude/build-plans/p/plan.md","content":"x"}'
checks='{"file_path":"/work/proj/.claude/build-plans/p/checks.json","content":"x"}'

echo "guard-builder.sh"
assert_eq "namespaced sonnet builder: git switch denied"    deny  "$(decision "$(guard plan-and-verify:builder-sonnet Bash "$sw")")"
assert_eq "namespaced opus builder: git commit denied"      deny  "$(decision "$(guard plan-and-verify:builder-opus Bash '{"command":"git commit -m x"}')")"
assert_eq "namespaced builder: Write plan.md denied"        deny  "$(decision "$(guard plan-and-verify:builder-sonnet Write "$planmd")")"
assert_eq "namespaced builder: Edit checks.json denied"     deny  "$(decision "$(guard plan-and-verify:builder-opus Edit "$checks")")"
assert_eq "namespaced builder: ordinary command allowed"    allow "$(decision "$(guard plan-and-verify:builder-sonnet Bash '{"command":"ls -la"}')")"
assert_eq "bare builder-sonnet: git switch still denied"    deny  "$(decision "$(guard builder-sonnet Bash "$sw")")"
assert_eq "main agent (no agent_type): git commit allowed"  allow "$(decision "$(guard - Bash '{"command":"git commit -m x"}')")"
assert_eq "empty agent_type: git commit allowed"            allow "$(decision "$(guard "" Bash '{"command":"git commit -m x"}')")"
assert_eq "milestone-reviewer: git stash allowed"           allow "$(decision "$(guard plan-and-verify:milestone-reviewer Bash '{"command":"git stash list"}')")"
assert_eq "lookalike type builder-sonnet-x: not a builder"  allow "$(decision "$(guard plan-and-verify:builder-sonnet-x Bash "$sw")")"
finish
