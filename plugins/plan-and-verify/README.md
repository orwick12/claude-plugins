# plan-and-verify

A planning skill for Claude Code that produces phases and milestones with per-milestone model routing, runnable acceptance checks, a hook that will not let a builder finish until those checks pass, git recovery points, and one-writer-per-tree execution. Delivered as a plugin; see the marketplace README for install.

```
plugins/plan-and-verify/
├── .claude-plugin/plugin.json
├── skills/plan-and-verify/         SKILL.md, references/acceptance-checks.md, assets/plan-template.md
├── agents/                         builder-sonnet, builder-opus (no Agent tool), milestone-reviewer
├── tests/                          script tests: bash tests/run.sh (needs bash, git, jq)
└── hooks/
    ├── hooks.json                  SessionStart (exports PV_HOOKS, warns on stale locks),
    │                               SubagentStop (verify-milestone), PreToolUse (guard-builder)
    ├── run-checks.sh               deterministic check runner; fingerprints code + checks
    ├── verify-milestone.sh         the SubagentStop hook; lock check; auto-snapshot; BLOCKED overwrites PASS
    ├── accept-milestone.sh         acceptance stamp: lock + fresh PASS + integrity, then the milestone commit
    ├── snapshot.sh                 recovery points under refs/pv/snapshots
    ├── guard-builder.sh            denies git commit/push/... and checks.json edits, builders only
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

Commit `.claude/build-plans/` in your repo; plans, checks and results are part of the project's history.

## How enforcement works

| Layer | What it guarantees |
|---|---|
| Builder tools | `Read, Edit, Write, Grep, Glob, Bash` only; `disallowedTools: Agent, Task, NotebookEdit`. A builder cannot fork or delegate, so it is the only writer in the tree |
| Bash guards | `git commit/push/stash/reset/checkout/rebase/merge/switch/restore` and edits to `checks.json`, `hooks.lock`, `plan.md` denied for builders. Regexes over the command text: they stop mistakes, not a builder set on getting around them |
| Stop hook | runs for every subagent and acts only on the plugin's builders; finds the report in the builder's hand-back; re-runs the milestone's checks as a script; blocks the builder on failure (3 rounds max); honest `STATUS: BLOCKED` may stop; never blocks twice for a missing report; every attempt takes a snapshot |
| Results file | written by the runner, stamped with fingerprints of the tree and `checks.json` |
| Acceptance script | refuses unless the result is PASS against exactly the tree and checks on disk now, and `checks.json`/`hooks.lock` match `HEAD` and were changed only by `plan(<slug>): ...` commits; then makes the one milestone commit |
| Reviewer | fresh context; diffs against the spawn snapshot; rejects on weakened tests, out-of-scope files, or `checks.json` in the diff |
| Snapshots | whole-tree recovery points at spawn, per file batch, per finish attempt; never on the branch |

## Where it still falls down

- Weak checks pass trivially. The reference file exists to make you write good ones; nothing else can.
- A builder can weaken a test inside the code. That is what review tier 1 is for.
- The lock proves the scripts at acceptance time match what the plan was written against; it cannot stop a builder from editing the plugin cache mid-milestone, only catch it at the next hook or acceptance.
- `guard-builder.sh` and `verify-milestone.sh` identify builders by the `agent_type` Claude Code reports (`plan-and-verify:builder-sonnet`, `plan-and-verify:builder-opus`). Claude Code ignores `hooks:`, `permissionMode` and `mcpServers` in a *plugin's* agent frontmatter, so every guard here lives in `hooks/hooks.json`; the builder agents carry no frontmatter hooks at all, because one would read as a safety net that never fires.
- Checks that need a live service need that service; give it a milestone 0.x.
- Parallel groups are opt-in and rare; the hooks assume one working tree.
- No wall-clock limit on a subagent; builders have `maxTurns: 60`, checks have timeouts. Size milestones accordingly.
- Snapshots capture file state, not reasoning; Claude Code does not persist a stopped agent's transcript.
- Snapshot refs accumulate per plan; prune with `git for-each-ref --format='%(refname)' refs/pv/snapshots/<slug>/ | xargs -n1 git update-ref -d` after the branch is merged.
- Script tests (`tests/run.sh`) pass on macOS with bash 3.2 and 5. 1.1.0 was probed through a real plugin install on macOS, which found the wiring bugs fixed in 1.1.1; 1.1.1 itself has not yet been probed in a real install. Not tested on real Windows. Check `/hooks` and the session-start message before your first plan.
- Remove any earlier copies of these agents from `~/.claude/agents` or `<project>/.claude/agents`; same-named agents shadow the plugin's.
