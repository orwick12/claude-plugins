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

# The reviewer stops through the same event, and its verdict is what an unattended run
# acts on, so its report is captured and its severity rule enforced there too (F45).
assert_contains "SubagentStop runs capture-review.sh" "capture-review.sh" \
  "$(jq -r '.hooks.SubagentStop[].hooks[].command' "$J" | tr '\n' ' ')"
assert_eq "every SubagentStop entry runs without a matcher" "false false" \
  "$(jq -r '[.hooks.SubagentStop[] | has("matcher")] | join(" ")' "$J")"

# The hand-back carries the builder's report, and the tool delivers one per run (F36),
# so the report has to be captured as it is delivered.
assert_eq       "PostToolUse matches SubagentHandback" "SubagentHandback" "$(jq -r '.hooks.PostToolUse[0].matcher' "$J")"
assert_contains "PostToolUse runs capture-report.sh" "capture-report.sh" "$(jq -r '.hooks.PostToolUse[0].hooks[0].command' "$J")"

# Frontmatter hooks in a plugin's agent definitions are ignored by Claude Code, so the
# builders must not carry any: they would read as a safety net that does not exist (F11).
for a in "$HOOKS"/../agents/*.md; do
  assert_eq "$(basename "$a") has no frontmatter hooks" 0 \
    "$(awk '/^---$/{n++; next} n==1 && /^hooks:/{print "1"; exit}' "$a" | wc -l | tr -d ' ')"
done
finish
