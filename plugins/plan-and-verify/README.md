# plan-and-verify

A planning skill for Claude Code that produces phases and milestones with per-milestone model routing, runnable acceptance checks, a hook that will not let a builder finish until those checks pass, git recovery points, and one-writer-per-tree execution. Delivered as a plugin; see the marketplace README for install.

```
plugins/plan-and-verify/
├── .claude-plugin/plugin.json
├── skills/plan-and-verify/         SKILL.md, references/{acceptance-checks,autonomous-run}.md, assets/plan-template.md
├── agents/                         builder-sonnet, builder-opus (no Agent tool), milestone-reviewer, check-adjudicator
├── tests/                          script tests: bash tests/run.sh (needs bash, git, jq)
└── hooks/
    ├── hooks.json                  SessionStart (exports PV_HOOKS, warns on stale locks), SubagentStart
    │                               (agent-guard start), SubagentStop (verify-milestone), PreToolUse
    │                               (guard-builder, agent-guard, run-state record), PostToolUse
    │                               (capture-report, run-state post)
    ├── run-checks.sh               deterministic check runner; fingerprints code + checks
    ├── verify-milestone.sh         the SubagentStop hook; lock check; auto-snapshot; BLOCKED overwrites PASS
    ├── accept-milestone.sh         acceptance stamp: lock + fresh PASS + integrity, then the milestone commit
    ├── snapshot.sh                 recovery points under refs/pv/snapshots
    ├── guard-builder.sh            denies git commit/push/..., planner files and results writes, builders only
    ├── agent-guard.sh              one builder at a time (spawn and resume); none for an accepted milestone or in plan mode
    ├── capture-report.sh           stores a builder's hand-back report as it is delivered
    ├── run-state.sh                run bookkeeping: preflight, brief, milestone, log, lint-checks
    ├── lock-hooks.sh               writes/verifies <plan>/hooks.lock
    ├── ensure-repo.sh              creates a git repo + initial commit when a project has none
    └── lib.sh                      portability (sha256, timeout, Windows paths)
```

## Projects without git

The skill runs `ensure-repo.sh` before planning or executing. If the folder is not a repo it runs `git init` on branch `main`, adds a starter `.gitignore` (dependencies, build output, `.env`, editor files) only if none exists, and makes an initial commit. It refuses to run in your home directory or a drive root, will not commit files over 5 MB, never sets your git name/email for you, and warns instead of nesting when the folder is already inside a bigger repo. The session-start message also notes when a project has no repo yet.

## Scripts outside the repo, verified by the repo

The plugin lives in Claude Code's plugin cache, not in your project. So each plan carries `hooks.lock`: the plugin version and a SHA-256 of every enforcement script, written by `lock-hooks.sh` when the plan is created and committed with it. `verify-milestone.sh` and `accept-milestone.sh` both refuse to certify anything unless the installed scripts hash to what the lock says and the lock itself is unchanged from `HEAD`. Tampering with a script therefore requires editing a committed file, which shows up in the reviewer's diff and gets rejected. Updating the plugin deliberately means re-locking each in-flight plan and committing.

`$PV_HOOKS` is exported into the session's shell by the SessionStart hook (through Claude Code's `CLAUDE_ENV_FILE`) and also stated in context, so the skill and agents call scripts as `bash "$PV_HOOKS/<script>"` on every OS.

## Use

- Plan: `/plan-and-verify <what you want built>` (or just describe it; the skill triggers on plan/phases/milestones language). Claude writes `.claude/build-plans/<slug>/plan.md` and `checks.json` in the project, shows a summary, and stops.
- Review the plan. Spend your attention on the checks; a milestone with weak checks is one the hook cannot protect.
- Execute: `/plan-and-verify execute <slug>`. Claude creates `plan/<slug>`, runs milestones one at a time, snapshots before each, reads `results/<id>.json` as the truth, reviews tier 1/2, pauses on tier 2, commits accepted work via `accept-milestone.sh`, tags each passed phase, and never pushes.
- Resume after a lost session: same command; `git log --grep '[<slug> '` is the source of truth.
- Undo: `bash "$PV_HOOKS/snapshot.sh" list <slug> <id>` then `restore <ref>`; restore refuses without `PV_CONFIRM_RESTORE=yes`.
- Where a run stands, at any time: `bash "$PV_HOOKS/run-state.sh" brief <slug>`.

Commit `.claude/build-plans/` in your repo; plans, checks and results are part of the project's history.

## Autonomous mode

A plan's header carries `mode: supervised` (the default) or `mode: autonomous`. The skill asks once while planning, and because the answer lives in the plan, granting autonomy is a commit you can read and revert. An autonomous run works milestone to milestone on its own and stops only for:

**(a)** a design question the plan does not answer (the builder reports `STATUS: BLOCKED` with a `QUESTION:` line) · **(b)** a check that looks wrong and cannot be shown wrong by the plan's own words · **(c)** anything destructive or outside the repo, including a tier-2 milestone marked `irreversible: yes` · **(d)** a milestone still failing after escalation to `builder-opus` · **(e)** enforcement that looks broken: no results file, no hook heartbeat, or a lock mismatch at the same plugin version.

Everything else self-corrects — retries, reviewer rejections, escalation, re-locking after a plugin update, and correcting a check the plan itself contradicts — and every decision is written to `.claude/build-plans/<slug>/run/decisions.jsonl`, which the end-of-run report reads back. That directory ignores its own contents, so logging never reaches a commit or disturbs the fingerprints acceptance depends on.

Claude Code tells no hook which plan-approval option you chose, so the run compares the plan's `mode:` with the session's `permission_mode` instead:

| Session mode | What happens |
|---|---|
| `auto`, `dontAsk`, `bypassPermissions` | runs unattended |
| `acceptEdits` | runs, but Bash calls can still prompt, so the log marks the run attended |
| `default` (Manual) | says so once, names the fix, and carries on attended — prompts will interrupt |
| `plan` | refuses to spawn a builder until the plan is approved |

For a genuinely unattended run, start the session with `claude --permission-mode auto` (or `claude -p --permission-mode dontAsk --permission-prompts none` for a scripted one) and allow the plugin's own commands, one per rule, in your settings:

```json
{ "permissions": { "allow": [
  "Bash(bash \"$PV_HOOKS/run-checks.sh\"*)", "Bash(bash \"$PV_HOOKS/accept-milestone.sh\"*)",
  "Bash(bash \"$PV_HOOKS/snapshot.sh\"*)",   "Bash(bash \"$PV_HOOKS/run-state.sh\"*)",
  "Bash(bash \"$PV_HOOKS/lock-hooks.sh\"*)", "Bash(git log*)", "Bash(git status*)", "Bash(git tag*)"
] } }
```

An allow rule matches each `&&`/`;`/`|` subcommand separately, which is why the skill runs one plugin command per Bash call and never chains them.

## How enforcement works

| Layer | What it guarantees |
|---|---|
| Builder tools | `Read, Edit, Write, Grep, Glob, Bash` only; `disallowedTools: Agent, Task, NotebookEdit`. A builder cannot fork or delegate, so it is the only writer in the tree |
| Bash guards | `git commit/push/stash/reset/checkout/rebase/merge/switch/restore` denied for builders, resolved from the real subcommand so `git -C dir commit`, `VAR=1 git push` and an indented command are caught too; edits to `checks.json`, `hooks.lock`, `plan.md` and anything under `results/` denied as well, since a results file is the evidence acceptance trusts |
| Spawn guard | one builder at a time, none for a milestone that already has its commit, none while the session is in plan mode; reviewers and other agents pass through. Each builder milestone holds a marker in `run/open/` from its spawn until its acceptance commit, so a builder that merely stopped still blocks the next one, and a *resumed* builder re-arms its own marker through `SubagentStart` (a resume is not an Agent tool call, so the PreToolUse guard never sees it). The one exception is a `parallel-group`: milestones carrying the same non-`none` `parallel-group:` value in `plan.md` may build at the same time, and are accepted in one call. A marker left behind by a session that died is cleared with `run-state.sh clear-open <slug> [<id>]`, which refuses a live builder unless you set `PV_CONFIRM_CLEAR=yes` |
| Stop hook | runs for every subagent and acts only on the plugin's builders; finds the report in the builder's hand-back; re-runs the milestone's checks as a script; blocks the builder on failure (3 rounds max); honest `STATUS: BLOCKED` may stop; never blocks twice for a missing report; every attempt takes a snapshot |
| Results file | written by the runner, stamped with fingerprints of the tree and `checks.json` |
| Acceptance script | refuses unless the result is PASS against exactly the tree and checks on disk now, `checks.json`/`hooks.lock` match `HEAD` and were changed only by `plan(<slug>): ...` commits, `HEAD` is still where the milestone was spawned from, and nothing from another plan is waiting to be committed; then makes the one milestone commit, staging this plan's files and the project's work only |
| Heartbeats | every enforcement hook records what it did in `run/hook-events.jsonl`, so a run can tell "the hook passed it" from "the hook never ran" — the failure that made 1.1.0 look healthy while nothing was enforced |
| Reviewer | fresh context; diffs against the spawn snapshot; rejects on weakened tests, out-of-scope files, or `checks.json` in the diff; grades every finding `[low]`/`[med]`/`[high]` |
| Review hook | stores each review at `results/<id>.review.md` so its notes outlive the hand-back, logs the verdict, and enforces the severity rule: `ACCEPT` and `ACCEPT-WITH-NOTES` are for reports whose findings are all `[low]`, so a verdict that waves a `[med]` or `[high]` finding through is sent back once as a REJECT |
| Snapshots | whole-tree recovery points at spawn, per file batch, per finish attempt; never on the branch |

## Where it still falls down

- Weak checks pass trivially. The reference file exists to make you write good ones; nothing else can.
- A builder can weaken a test inside the code. That is what review tier 1 is for.
- The lock proves the scripts at acceptance time match what the plan was written against; it cannot stop a builder from editing the plugin cache mid-milestone, only catch it at the next hook or acceptance.
- `guard-builder.sh` and `verify-milestone.sh` identify builders by the `agent_type` Claude Code reports (`plan-and-verify:builder-sonnet`, `plan-and-verify:builder-opus`). Claude Code ignores `hooks:`, `permissionMode` and `mcpServers` in a *plugin's* agent frontmatter, so every guard here lives in `hooks/hooks.json`; the builder agents carry no frontmatter hooks at all, because one would read as a safety net that never fires.
- Checks that need a live service need that service; give it a milestone 0.x.
- Parallel groups are opt-in and rare: the guard honours them, but the hooks still assume one working tree, so the members must own disjoint directories, scope their checks to those directories, and be re-checked after the last member finishes before the group is accepted in one call. `run-state.sh preflight` fails a group that has one member, spans two phases, or has a member with no `scope:`.
- No wall-clock limit on a subagent; builders have `maxTurns: 60`, checks have timeouts. Size milestones accordingly.
- Snapshots capture file state, not reasoning; Claude Code does not persist a stopped agent's transcript. So "resume the same builder" works only inside one session; after a restart it is a fresh spawn carrying the findings, and it still costs a retry from the budget.
- In an autonomous run, deciding a check is wrong rests on the adjudicator finding a passage of your plan that contradicts it, quoted and matched literally. A vague plan therefore produces AMBIGUOUS and stops, which is the intended outcome but is only as good as the prose you wrote.
- `lint-checks` is a deny-list over the commands in `checks.json`, not a sandbox: an acceptance check is a shell command no tool guard ever sees, so an autonomous run is only as safe as the checks you approved.
- The acceptance rules now catch a commit slipped in mid-milestone, but a commit whose subject reads `plan(<slug>): ...` is still taken at its word. The guards make that hard for a builder to produce; they do not make it impossible.
- Snapshot refs accumulate per plan; prune with `git for-each-ref --format='%(refname)' refs/pv/snapshots/<slug>/ | xargs -n1 git update-ref -d` after the branch is merged.
- Script tests (`tests/run.sh`) pass on macOS with bash 3.2 and 5. 1.1.0 was probed through a real plugin install on macOS, which found the wiring bugs fixed in 1.1.1; 1.1.1 was then re-probed the same way and its guards, finish hook and acceptance rules all fired. 1.2.2's autonomous mode was then run end to end on a real project (12 milestones, 3 gates), which is where the resume hole, the group denial, the spawn-time `pv:` line, the evidence-erasing BLOCKED stub, the `| shasum` lint refusal and the ungraded reviewer verdict were found; **1.3.0 fixes all of those, but the fixes themselves are covered by script tests only until the next live run.** Not tested on real Windows. Check `/hooks` and the session-start message before your first plan.
- Remove any earlier copies of these agents from `~/.claude/agents` or `<project>/.claude/agents`; same-named agents shadow the plugin's.
