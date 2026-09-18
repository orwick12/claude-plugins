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
assert_contains "skill says the spawn-time line carries no verdict" "spawn-time"           "$(cat "$SKILL")"
assert_not_contains "skill no longer claims the pv: line states both" \
  "a \`pv: <slug>/<id> results=" "$(cat "$SKILL")"

# --- the reference covers every stop condition and never asks a question ---------------
for c in a b c d e; do
  assert_contains "reference covers class $c" "**$c**" "$(cat "$REF")"
done
assert_contains     "reference has the halt template"      "HALT <class>"      "$(cat "$REF")"
assert_contains     "reference forbids AskUserQuestion"    "Never \`AskUserQuestion\`" "$(cat "$REF")"
assert_contains     "reference keeps one call per Bash"    "chain them with"   "$(cat "$REF")"
assert_contains     "reference verifies the citation"      "grep -F"           "$(cat "$REF")"

# --- F40: the pv: line at spawn carries no verdict, the results file does --------------
assert_contains     "reference says the spawn-time line carries no verdict" "spawn-time" "$(cat "$REF")"
assert_not_contains "reference no longer claims the line carries all three" \
  "carries the first three at once" "$(cat "$REF")"
assert_contains "reference's class e is keyed to the completion notification" \
  "After the completion notification" "$(cat "$REF")"

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
# F45: the verdict is machine-read and the notes are machine-stored, so the contract has
# to name the milestone and grade every finding.
REV="$P/agents/milestone-reviewer.md"
assert_contains "the reviewer names the milestone the hook parses" "MILESTONE:" "$(cat "$REV")"
for sev in low med high; do
  assert_contains "the reviewer grades findings [$sev]" "[$sev]" "$(cat "$REV")"
done
assert_contains "the reviewer says a med or high finding is a REJECT" "REJECT" "$(cat "$REV")"
assert_contains "the reviewer says where its notes go" "review.md" "$(cat "$REV")"
for f in "$SKILL" "$REF"; do
  assert_contains "$(basename "$f") knows ACCEPT-WITH-NOTES" "ACCEPT-WITH-NOTES" "$(cat "$f")"
  assert_contains "$(basename "$f") says where the notes land" "review.md" "$(cat "$f")"
done

# --- wiring -----------------------------------------------------------------------------
J="$HOOKS/hooks.json"
assert_contains "agent-guard is registered on Agent"   "agent-guard.sh"       "$(jq -r '.hooks.PreToolUse[] | select(.matcher == "Agent") | .hooks[0].command' "$J")"
assert_contains "the recorder is registered"           "run-state.sh"         "$(jq -r '.hooks.PreToolUse[] | .hooks[0].command' "$J" | tr '\n' ' ')"
assert_contains "post is registered on Agent"          "run-state.sh"         "$(jq -r '.hooks.PostToolUse[] | select(.matcher == "Agent") | .hooks[0].command' "$J")"

# --- F46/F44/F23/F24: the docs describe the guard that now exists -----------------------
RD="$P/README.md"
REFA="$P/skills/plan-and-verify/references/acceptance-checks.md"
assert_contains "README says a resume is guarded through SubagentStart" "SubagentStart" "$(cat "$RD")"
assert_contains "README says parallel groups are honoured"              "parallel-group" "$(cat "$RD")"
assert_contains "README says how a dead session's marker is cleared"    "PV_CONFIRM_CLEAR" "$(cat "$RD")"

assert_contains "skill says only one group may build concurrently" "members of the same \`parallel-group\`" "$(cat "$SKILL")"
assert_contains "skill says a member's checks stay in its own directories" "scoped to its own directories" "$(cat "$SKILL")"
assert_contains "skill says a group is re-checked before the one-call accept" "re-run every member's checks" "$(cat "$SKILL")"
assert_contains "skill passes the sibling scopes to the reviewer of a group member" "sibling" "$(cat "$SKILL")"
assert_contains "template repeats the group rule" "members of the same \`parallel-group\`" "$(cat "$TPL")"
assert_contains "the autonomous loop re-runs every member's checks before accepting" \
  "re-run every member's checks" "$(cat "$REF")"

assert_contains "the reviewer is given its siblings' scopes"              "sibling" "$(cat "$REV")"
assert_contains "the reviewer does not call a sibling's files out of scope" "out of scope" "$(cat "$REV")"
assert_contains "the check reference has a group-safe out-of-scope pattern" "sibling" "$(cat "$REFA")"

finish
