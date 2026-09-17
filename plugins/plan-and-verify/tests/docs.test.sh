#!/usr/bin/env bash
# The skill, its reference, the plan template and the agent definitions have to agree
# with each other and with the scripts. Nothing here tests behaviour; it catches the
# drift that makes a plugin quietly describe a safety net it no longer has.
. "$(dirname "$0")/helpers.sh"

P="$(cd "$HOOKS/.." && pwd)"
SKILL="$P/skills/plan-and-verify/SKILL.md"
REF="$P/skills/plan-and-verify/references/autonomous-run.md"
TPL="$P/skills/plan-and-verify/assets/plan-template.md"

echo "docs"

# --- the plan carries the autonomy switch ---------------------------------------------
assert_contains "template has the mode field"        "mode: supervised | autonomous" "$(cat "$TPL")"
assert_contains "template has the budget line"       "autonomy:"      "$(cat "$TPL")"
assert_contains "template has irreversible"          "irreversible:"  "$(cat "$TPL")"
assert_contains "template asks for the environment"  "## Environment" "$(cat "$TPL")"

# --- the skill sends an autonomous run to the reference --------------------------------
assert_contains "skill points at the autonomous reference" "references/autonomous-run.md" "$(cat "$SKILL")"
assert_contains "skill runs preflight before building"     "preflight"                    "$(cat "$SKILL")"
assert_contains "skill asks the user which mode"           "mode: supervised"             "$(cat "$SKILL")"
assert_contains "skill reads the report the hook wrote"    "report.md"                    "$(cat "$SKILL")"

# --- the reference covers every stop condition and never asks a question ---------------
for c in a b c d e; do
  assert_contains "reference covers class $c" "**$c**" "$(cat "$REF")"
done
assert_contains     "reference has the halt template"      "HALT <class>"      "$(cat "$REF")"
assert_contains     "reference forbids AskUserQuestion"    "Never \`AskUserQuestion\`" "$(cat "$REF")"
assert_contains     "reference keeps one call per Bash"    "chain them with"   "$(cat "$REF")"
assert_contains     "reference verifies the citation"      "grep -F"           "$(cat "$REF")"

# --- agents ----------------------------------------------------------------------------
A="$P/agents/check-adjudicator.md"
assert_eq       "the adjudicator exists" 0 "$([ -f "$A" ]; echo $?)"
assert_contains "the adjudicator runs on opus"      "model: opus"  "$(cat "$A")"
assert_not_contains "the adjudicator cannot write"  "Write"        "$(sed -n '/^tools:/p' "$A")"
assert_contains "the adjudicator must cite the plan" "cites:"      "$(cat "$A")"
for b in builder-sonnet builder-opus; do
  assert_contains "$b asks a question when blocked"    "QUESTION:"        "$(cat "$P/agents/$b.md")"
  assert_contains "$b knows the hand-back is one-shot" "one report per run" "$(cat "$P/agents/$b.md")"
  assert_contains "$b is kept out of results files"    "results/"         "$(cat "$P/agents/$b.md")"
done
assert_contains "the reviewer puts its verdict last" "must be the last line" "$(cat "$P/agents/milestone-reviewer.md")"

# --- wiring -----------------------------------------------------------------------------
J="$HOOKS/hooks.json"
assert_contains "agent-guard is registered on Agent"   "agent-guard.sh"       "$(jq -r '.hooks.PreToolUse[] | select(.matcher == "Agent") | .hooks[0].command' "$J")"
assert_contains "the recorder is registered"           "run-state.sh"         "$(jq -r '.hooks.PreToolUse[] | .hooks[0].command' "$J" | tr '\n' ' ')"
assert_contains "post is registered on Agent"          "run-state.sh"         "$(jq -r '.hooks.PostToolUse[] | select(.matcher == "Agent") | .hooks[0].command' "$J")"

finish
