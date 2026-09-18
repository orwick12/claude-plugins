# Autonomous runs

Read this before executing a plan whose header says `mode: autonomous`. Supervised runs do not need it.

An autonomous run does the same work as a supervised one and reaches the same gates. The difference is who decides what happens after each milestone. Here, you decide, from evidence on disk, and you stop only for the five conditions below. Everything else self-corrects and goes in the log.

## What you trust

| Question | Answer comes from | Never from |
|---|---|---|
| Is this milestone done? | a milestone commit: `git log --grep '[<slug> <id>]'` | `status:` in plan.md, a builder saying DONE |
| Did the checks pass? | `results/<id>.json`, and only while its `tree_sha` still matches the tree | the builder's pasted check output |
| Did enforcement run? | a `hook:verify-milestone` line in `run/hook-events.jsonl` | the absence of a complaint |
| What did the builder report? | `results/<id>.report.md`, written by the hook | the hand-back message, which is stale after any block |
| What did the reviewer find? | `results/<id>.review.md`, written by the hook | the verdict token on its own |
| What happened earlier in this run? | `run/decisions.jsonl` via `run-state.sh brief <slug>` | your own memory of it |

The `pv:` line is injected at spawn (Claude Code's Agent tool is asynchronous, so PostToolUse[Agent] fires before the builder has done anything). It is spawn-time and carries no verdict; it says so and names the files to check. The truth is `results/<id>.json`, read AFTER the builder's completion notification, plus the `hook:verify-milestone` heartbeat for that stop.

## The loop, per milestone

1. `bash "$PV_HOOKS/run-state.sh" brief <slug>` — where the plan stands. On the first milestone of a session also run `preflight <slug>` and act on its verdict (see below).
2. `bash "$PV_HOOKS/run-state.sh" milestone <slug> <id>` — the work order, on its own.
3. `needs-planning: yes` → the planning fork first, then commit its sub-plan as `plan(<slug>): sub-plan for <id>`.
4. `snapshot.sh <slug> <id> spawn`, then spawn exactly one builder with the work order.
5. When it returns, read the results file. `PASS` → review tier decides; `FAIL`/`BLOCKED`/missing → classify below.
6. Tier 1, or tier 2 with `irreversible: no` → reviewer; `Verdict:` is the only line that decides: `ACCEPT` and `ACCEPT-WITH-NOTES` go on to step 7, `REJECT` does not. Read its findings in `results/<id>.review.md` and keep every note for the end report. Tier 2 with `irreversible: yes` → stop and show the user (class c).
7. `accept-milestone.sh <slug> <id>`. For a parallel group, re-run every member's checks after the last member finishes — each member's results went stale while its siblings worked — then accept the whole group in one call. On refusal, do what the message says once; a second refusal of the same kind is class (e).
8. Log every decision as you make it: `run-state.sh log <slug> '<json>'`.

One `$PV_HOOKS` call per Bash invocation. Do not chain them with `&&`: an allow-rule has to match each subcommand separately, and a chained call is what turns an unattended run into a permission prompt.

## When to stop, and when to carry on

| What you see | Class | What you do |
|---|---|---|
| `STATUS: BLOCKED` with a `QUESTION:` the plan does not answer | **a** | Stop. Show the question and the evidence block. |
| `STATUS: BLOCKED` whose question the plan does answer | — | Resume the builder once, quoting the passage. A second identical block is class (a). |
| A check fails and adjudication returns CHECK-WRONG with a verified citation, in an allowed category | — | Fix the check in a `plan(<slug>): fix check <name> for <id>` commit, re-run the checks, note it in the end report. Budget: 2 per run. |
| A check fails, adjudication returns AMBIGUOUS, or the citation does not match plan.md, or the milestone is `irreversible: yes` | **b** | Stop. Show the check, the output, and the adjudication. |
| A check needs a command the plan never provides (exit 127) | **b** | Stop. Name the tool. Print the install command; do not run it. |
| Anything destructive or outside the repo: snapshot restore, `git reset`, deleting data, a secret you would have to create | **c** | Stop. Print the exact command for the user to run. Never run it yourself. |
| Tier 2 milestone with `irreversible: yes` | **c** | Stop after the review. |
| Still failing after the escalation to `builder-opus` | **d** | Stop with both builders' reports. |
| A gate fails and the repair budget (2) is spent | **d** | Stop. |
| After the completion notification: no results file newer than the spawn and no `hook:verify-milestone` heartbeat for that stop | **e** | Stop: enforcement is not wired. Do not resume the builder as if it had merely failed. |
| `hooks.lock` mismatch, same plugin version | **e** | Stop: the scripts changed under a plan that vouched for them. |
| `hooks.lock` mismatch, different plugin version | — | Re-lock, commit as `plan(<slug>): re-lock hooks for <version>`, carry on. |
| A `$PV_HOOKS` call is denied by the permission system | **e** | Stop: the session cannot run its own enforcement. |
| Builder failed, budget left | — | Resume the same builder with the failures. |
| Reviewer says ACCEPT-WITH-NOTES | — | Accept. Its notes are all `[low]`; they are in `results/<id>.review.md` and every one of them goes in the end report. |
| Reviewer says REJECT, budget left | — | Resume the same builder with the findings; second REJECT escalates to `builder-opus`. |
| The tree is byte-identical before and after a builder run | — | Count it as a failed run immediately and escalate; a builder that changed nothing will not change anything next time either. |

Anything not in this table: carry on and log a `note`. Stopping six times a phase is its own failure — it is the outcome the mode exists to avoid.

## Deciding that a check is wrong

Never decide this yourself: you have been reading this milestone's code all along and you are the last one who should judge whether its checks are fair.

1. Spawn `check-adjudicator` (read-only, opus) with the failing check, the milestone text and the builder's report.
2. Take `verdict:` only when `cites:` is a literal passage of `plan.md`. Verify it: `grep -F -q -- "<the cited text>" .claude/build-plans/<slug>/plan.md`. No match means AMBIGUOUS, whatever the agent said.
3. Only these change without a human: a broken command, an expectation the plan contradicts, or setup the plan puts in a later milestone. Never delete a check, drop below two checks or the one behaviour check, weaken an assertion the goal names, or touch a `gates` entry.
4. Commit the edit on its own as `plan(<slug>): fix check ...`, re-run the checks (the fix changed `checks.json`, so the previous PASS is stale), then accept.

## Stopping

A halt is a plain message. Never `AskUserQuestion`: it does not exist under `--permission-prompts none`, and permission prompts never resolve on their own, so an unattended run that asks a question simply stops dead without saying why.

```
HALT <class>  plan <slug>  milestone <id>
Why: <one line>
Last accepted: <sha> <subject>
Truth: results/<id>.json status=<X> ran_at=<..>; heartbeat=<yes|no>
Evidence:
  <the failing check, its output, or the refusal text — 25 lines at most>
Tried, in order:
  1. <what you did> -> <what happened>
Not done: <what you deliberately did not do>
Snapshots: <spawn ref> ... <latest ref>
Options:
  A <exact command>
  B <exact command>
```

Then stop. Do not start the next milestone.

## Modes

`preflight` compares the plan's `mode:` with the session's `permission_mode`, because no hook can see which plan-approval option the user chose.

- `AUTONOMOUS OK` — carry on.
- `AUTONOMOUS DEGRADED` (acceptEdits) — run, but label the run attended in the log: Bash calls can still prompt.
- `MODE MISMATCH` (Manual) — say so once, name the way out (`/permissions`, `claude --permission-mode auto`, or `claude -p --permission-mode dontAsk`), then carry on attended. Prompts will interrupt; that is the user's to fix, not yours to route around.
- `REFUSED` (plan mode) — no builder spawns. Finish planning first.

## Resuming

Everything above is rebuilt from the repository: `run-state.sh brief <slug>` plus `git log`. Two things cannot be:

- **A stopped builder's reasoning.** Resuming "the same builder" only works inside one session. In a new session it is a fresh spawn carrying the findings text, it loses the warm cache, and it still costs a builder run from the budget.
- **Whether a human really reviewed a tier-2 pause.** If the user says continue, log it as `actor: human`; it is their word, recorded, not proof.

## The end report

When the last gate passes, report: the branch, the commit count, the tags, then — in this order — every check fix with its citation, every self-correction by class, every ACCEPT-WITH-NOTES note, escalations to opus, repair milestones added, re-locks, and budgets consumed. `run-state.sh brief` gives you all of it. Say plainly what was never verified by a human.
