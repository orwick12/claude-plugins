#!/usr/bin/env bash
# hooks.json wiring. Claude Code reports plugin agents as "plan-and-verify:builder-sonnet"
# and a SubagentStop matcher of "builder-sonnet|builder-opus" never fired for them, while it
# did fire for internal agents with an empty agent_type. So the SubagentStop entry must not
# depend on a matcher; verify-milestone.sh decides which agents it acts on.
. "$(dirname "$0")/helpers.sh"
J="$HOOKS/hooks.json"

echo "hooks.json"
assert_eq "valid JSON" 0 "$(jq -e . "$J" >/dev/null 2>&1; echo $?)"
assert_eq "SubagentStop entry has no matcher" false "$(jq '.hooks.SubagentStop[0] | has("matcher")' "$J")"
assert_contains "SubagentStop runs verify-milestone.sh" "verify-milestone.sh" "$(jq -r '.hooks.SubagentStop[0].hooks[0].command' "$J")"
assert_contains "PreToolUse runs guard-builder.sh" "guard-builder.sh" "$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$J")"
finish
