# plan-and-verify

A Claude Code plugin for scoped milestone work, deterministic acceptance checks,
independent review, and resumable execution. Version 1.4.0 strengthens acceptance and
reduces routine orchestration context. Efficiency is a hypothesis to measure, not a
release guarantee.

## Workflow

1. `/plan-and-verify <request>` produces a plan and concrete checks. Review and approve
   the plan; choose supervised or autonomous execution.
2. `/plan-and-verify execute <slug>` runs sequential milestones. A narrow read-only
   `milestone-planner` resolves remaining design questions just before their milestones,
   after dependencies finish. Builders receive scoped work orders and cannot delegate.
3. Checks run independently at builder completion. For review tiers 1/2, a reviewer judges
   the result; its verdict is bound to the code and checks as they stand when it stops.
4. `accept-milestone.sh` validates check freshness, required current review, dependencies,
   a PASS for each earlier phase gate's current checks and explicit approval where required. It commits the
   milestone together with structured acceptance evidence.
5. Each phase finishes with its gate, run on a clean tree after the phase's last acceptance. No automated push, merge or publication.

Small mechanical work can use tier 0 with strong checks. Use independent review where
judgment adds value. A task need not be split into tiny agents merely because delegation
exists. Parallelism targets elapsed time; cost and quality must be measured separately.

## Compact decisions and recovery

```sh
bash "$PV_HOOKS/run-state.sh" brief <slug>
bash "$PV_HOOKS/run-state.sh" status <slug> <id>
bash "$PV_HOOKS/run-state.sh" accepted <slug> <id>
bash "$PV_HOOKS/run-state.sh" milestone <slug> <id>
```

`status` emits compact JSON: check status/freshness, review verdict/freshness/binding,
unsatisfied dependencies, and suggested next action. It never embeds full logs or reports.
`accept` revalidates the authoritative conditions; a suggested action is not authorization.
Read detailed evidence only for an exception that needs judgment. `brief` is for phase or
session boundaries and includes decision actors.

`accepted` reads committed `results/<id>.accepted.json`. Historical milestone commit
subjects are parsed literally, including group commits. Uncommitted evidence and Markdown
`status: DONE` do not establish completion. This avoids the previous regex/group mismatch.

## Evidence contract

- A code fingerprint includes HEAD and the complete proposed source tree through a
  private Git index. Only plugin plan `results/` and `run/` paths are excluded; application
  directories named `results` remain source. The real staging index is not changed.
- Checks compare source/check identity before and after running. A mutating check fails
  and names the files it changed; it cannot stamp the code it happened to leave behind as
  verified. Gitignore generated files or write them to a temp dir.
- `run-checks.sh <slug> <id> --observe` writes `<id>.observed.json`, preserving the builder's
  primary PASS/FAIL/BLOCKED record. Reviewers and adjudicators use this mode.
- When a reviewer stops, the hook records its verdict with the reviewer's identity, a
  review id, and the tree/checks at that moment. It is INVALID unless the builder's checks
  are a current PASS for that tree. Unknown, contradictory or stale reviews cannot
  authorize acceptance. An invalid reviewer may stop after one retry, but its evidence stays INVALID.
- `approve-milestone.sh <slug> <id> --by <name> --reason <approval-reference>` records an
  explicit user's approval of the current review/artifact. Required for supervised tier 2,
  and autonomous tier 2 with `irreversible: yes`. Never infer or fabricate this decision.
  This is an auditable assertion, not authentication against arbitrary shell access.
- `results/<id>.accepted.json` keeps check-run, review and approval evidence with the
  artifact. It is committed, unlike transient run bookkeeping.

A reviewer inspects changes against HEAD and checks that intervening plan commits contain
only plan/check/lock amendments. An upstream interface contradicting a work order is a
BLOCKED question, not a reason to invent an adapter solely to evade scope ownership.

## State and concurrency

The builder guard handles spawn and resume through PreToolUse and SubagentStart. It checks
accepted dependencies and markers across plans, refuses a duplicate live same-milestone
spawn, and allows escalation after a builder stops. A stopped marker remains until acceptance.
Use `run-state.sh clear-open <slug> [<id>]` for recovery; a live marker requires
`PV_CONFIRM_CLEAR=yes` when its owning session is known dead.

New benchmark runs use `parallel-group: none`. Existing `parallel-group` plans retain
compatibility: members must own disjoint directories, scope their checks, and be reviewed
against the final shared artifact after all writers finish. Re-run every member's checks,
start fresh reviews, then accept the group in one call. Shared-tree parallelism remains an
advanced path, not the default. This guard is cooperative workflow enforcement, not an
atomic scheduler or an OS security sandbox; unrelated general-purpose agents are not
controlled by builder-specific hooks.

## Installation and upgrades

See the marketplace README for install/update commands. Repository changes do not update
an installed plugin cache. Pin both the actual installed version and source commit when
benchmarking. `$PV_HOOKS` is exported by SessionStart and must point at that installed copy.

`hooks.lock` pins scripts, wiring and agent definitions. Upgrade an existing plan only with
an intentional `plan(<slug>): ...` commit containing the new lock. Plans must have explicit
`review: 0|1|2` fields; missing policy fails closed. Re-run checks and obtain new reviews:
1.3 results/reviews cannot serve as fresh 1.4 acceptance evidence. Existing acceptance commits
remain readable, including historical group acceptance.

If no repository exists, `ensure-repo.sh` can initialize one; inspect its proposed files
before using it in a nonempty directory. Existing starter-repo secret-handling findings
are not addressed by this release. Do not use initialization as a credential audit.

## Verification and limits

From the marketplace repository, `make check` runs Bash syntax/JSON validation and all
script regression tests. It never installs or publishes the plugin. Tests use temporary
repositories and synthetic hook payloads. Live Claude event ordering, hook installation,
planner permissions and subscription usage still require a fresh real-session probe.

Strong checks remain essential. Review can miss defects; neither tokens nor test counts
are quality by themselves. Shell-command deny lists are not a sandbox. A user/model with
unrestricted filesystem access can forge records or change guard files; these controls
catch workflow errors, not a hostile actor. Approval records do not verify a person's identity.

Remaining areas for evaluation include actual context/cost improvement, Windows behavior,
interruptions during acceptance, simultaneous spawn races, robust shared-tree parallelism,
and previously recorded starter-repo/runner edge cases. Consult plantest's tracked benchmark
approach and handoff; do not feed its evaluator notes to executing benchmark agents.
