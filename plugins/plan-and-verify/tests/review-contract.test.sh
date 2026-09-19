#!/usr/bin/env bash
. "$(dirname "$0")/helpers.sh"
echo 'review contract'
R=$(mk_repo demo); TMPS="$TMPS $R"; D="$R/.claude/build-plans/demo"
printf ok > "$R/hello.txt"
CLAUDE_PROJECT_DIR="$R" bash "$HOOKS/run-checks.sh" demo 1.1 >/dev/null
review() {
  jq -nc --arg m "MILESTONE: demo/1.1
$1" '{agent_type:"milestone-reviewer",agent_id:"reviewer",last_assistant_message:$m,stop_hook_active:true}' |
    CLAUDE_PROJECT_DIR="$R" bash "$HOOKS/capture-review.sh" >/dev/null
  jq -r .verdict "$D/results/1.1.review.json"
}
assert_eq 'unknown verdict invalid' INVALID "$(review 'Verdict: FINE')"
assert_eq 'accept cannot contradict failed checks' INVALID "$(review $'Checks: FAIL\nVerdict: ACCEPT')"
assert_eq 'ungraded finding cannot authorize acceptance' INVALID "$(review $'Findings:\n- drops errors\nVerdict: ACCEPT')"
assert_eq 'multiple verdicts invalid' INVALID "$(review $'Verdict: REJECT\nVerdict: ACCEPT')"
assert_eq 'ACCEPT means no low findings either' INVALID "$(review $'- [low] naming\nVerdict: ACCEPT')"
assert_eq 'graded low note accepts with notes' ACCEPT-WITH-NOTES "$(review $'- [low] naming\nVerdict: ACCEPT-WITH-NOTES')"
finish
