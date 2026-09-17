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

# --- F17: the git rule must survive the spellings that slipped past 1.1.1 ----------
b=plan-and-verify:builder-sonnet
g() { decision "$(guard "$b" Bash "$(jq -n --arg c "$1" '{command:$c}')")"; }
assert_eq "F17 git -C <dir> commit denied"            deny  "$(g 'git -C . commit -m x')"
assert_eq "F17 git -c k=v commit denied"              deny  "$(g 'git -c user.name=x commit -m x')"
assert_eq "F17 GIT_DIR=... git commit denied"         deny  "$(g 'GIT_DIR=.git git commit -m x')"
assert_eq "F17 env VAR=1 git push denied"             deny  "$(g 'env GIT_PAGER=cat git push')"
assert_eq "F17 single-letter VAR=1 git push denied"   deny  "$(g 'A=1 git push')"
assert_eq "F17 leading whitespace git push denied"    deny  "$(g '  git   push')"
assert_eq "F17 --no-pager before subcommand denied"   deny  "$(g 'git --no-pager stash list')"
assert_eq "F17 chained after && still denied"         deny  "$(g 'cd sub && git commit -m x')"
assert_eq "F17 read-only git log still allowed"       allow "$(g 'git log --oneline -5')"
assert_eq "F17 read-only git -C . status allowed"     allow "$(g 'git -C . status --porcelain')"
assert_eq "F17 git-crypt lookalike allowed"           allow "$(g 'git-crypt unlock')"

# --- F38: results files are evidence; a builder may run the checks, never write them
res='{"file_path":"/work/proj/.claude/build-plans/p/results/1.1.json","content":"x"}'
assert_eq "F38 Write results json denied"             deny  "$(decision "$(guard "$b" Write "$res")")"
assert_eq "F38 Edit results json denied"              deny  "$(decision "$(guard "$b" Edit "$res")")"
assert_eq "F38 redirect into results denied"          deny  "$(g 'echo x > .claude/build-plans/p/results/1.1.json')"
assert_eq "F38 rm of a results file denied"           deny  "$(g 'rm .claude/build-plans/p/results/1.1.attempts')"
assert_eq "F38 running the checks still allowed"      allow "$(g 'bash "$PV_HOOKS/run-checks.sh" p 1.1')"
assert_eq "F38 reading a results file still allowed"  allow "$(g 'cat .claude/build-plans/p/results/1.1.json')"
assert_eq "F38 snapshot.sh still allowed"             allow "$(g 'bash "$PV_HOOKS/snapshot.sh" p 1.1 wip')"
finish
