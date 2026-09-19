---
name: plan-and-verify
description: Turn a feature, refactor, or project request into a verified build plan of phases and milestones, then execute it with subagents. Use this whenever the user asks to plan, roadmap, break down, or build something with more than one step, says "make a plan", "phases", "milestones", "work through this", or wants work validated instead of just claimed done. Also use it when resuming or executing an existing plan under .claude/build-plans/. Every milestone gets a model, a scope, and runnable acceptance checks that a hook enforces.
---

# Plan and verify

The enforcement scripts ship with the plugin, not the repo. Their directory is exported as `$PV_HOOKS` in every Bash call (the SessionStart hook sets it and states the path in context). Every script call below is `bash "$PV_HOOKS/<script>"`. If `$PV_HOOKS` is empty, the plugin's session hook did not run; stop and tell the user to check `/hooks`.

Two modes, decided by the request:
- **Plan**: produce `.claude/build-plans/<slug>/plan.md` and `checks.json`, then stop and show the user the plan.
- **Execute**: run an existing plan milestone by milestone through builder subagents, verify, gate each phase.

Never combine planning and building in one turn. A plan the user has not seen is a guess.

## Step 0, both modes: make sure there is a git repo

Run `bash "$PV_HOOKS/ensure-repo.sh"` before anything else. Everything below (hooks.lock, snapshots, milestone commits) needs a repository with at least one commit.
- `git repo ready`: continue.
- `INITIALISED: ...`: it created the repo (branch `main`, starter `.gitignore` if there was none, initial commit). Tell the user in one line what it did, then continue.
- `NOTE: ... inside the git repo at ...`: the project is a subfolder of a bigger repo. Tell the user and ask whether that is intended before continuing.
- `REFUSED` (home directory or drive root) or `NEEDS USER` (no git identity, or files over 5 MB): stop, show the user the message and the commands it suggests, and wait. Do not set git user.name/email yourself and do not commit large files.


## Mode: Plan

### 1. Understand before you write
- Read the request and any files it names. For anything else, spawn the built-in `Explore` subagent with a narrow question ("which modules touch auth? list files, no explanations"). Do not read the codebase yourself in the main conversation; that context stays with you for the whole run.
- Find the existing test, build, lint and typecheck commands (package.json scripts, Makefile, pyproject, CI config). You need them for checks. Record them under `## Project commands` in the plan.
- If a hard requirement is unclear, ask the user now. One round of questions, then commit.

### 2. Shape phases and milestones
A **phase** is a group of milestones that leaves the project in a working state when it ends. A **milestone** is one subagent's job.

Sizing rules:
- A milestone is one uninterrupted burst of work: roughly 5 to 30 tool calls, one module or one concern. Split anything larger. Bundle anything that would take fewer than ~5 calls into a neighbour; every subagent has startup and context overhead; cache reuse depends on the runtime.
- A milestone touches files it owns. If two milestones edit the same file, they are one milestone or they are sequential.
- Milestones run one at a time, in one working tree, with one writer. This is the default and it is not a compromise: parallel builders add coordination overhead and primarily target wall-clock time; token savings require measurement. A hook enforces it on spawn and on resume, and the only exception it makes is a `parallel-group`.

### 3. Fill in every milestone
Copy `assets/plan-template.md`. Each milestone has all of these fields; no field is optional:

| Field | Rule |
|---|---|
| `id` | `<phase>.<n>`, e.g. `2.3` |
| `goal` | One sentence a reviewer can check the diff against |
| `scope` | Files/dirs it may edit. `out-of-scope` lists the tempting neighbours it must not |
| `depends-on` | Milestone ids that must be DONE first. Empty means it can start at phase start |
| `parallel-group` | Default `none`. Set a letter only when the user asked for parallel work AND the members are same-phase, have no dependencies, edit disjoint top-level directories, and are review tier 1 or higher. Otherwise leave it `none` and order them. The spawn guard allows concurrent builders only for members of the same `parallel-group`, so a group is the one place the one-writer rule bends: every member's checks must be scoped to its own directories (a sibling is editing the tree while they run), and the whole group is accepted in one `accept-milestone.sh` call after every member's checks have been re-run |
| `model` | `sonnet` or `opus` (see routing) |
| `needs-planning` | `yes` or `no` (see triggers). `yes` means a narrow `milestone-planner` runs just before this milestone, after its dependencies finish |
| `review` | `0`, `1`, or `2` (see tiers) |
| `irreversible` | `yes` when the milestone deletes data, migrates a schema, rotates a secret, touches payments, or changes anything outside the repo; else `no`. In an autonomous run this is the only thing that still pauses a tier-2 milestone |
| `checks` | Names of the checks in `checks.json` for this id. At least two, one of which exercises behaviour, not just compilation |
| `context` | The work order text the builder gets. Everything it needs, nothing else: decisions already made, exact commands, interfaces it must match |

### 4. Model routing
Default to `sonnet`. Route to `opus` when any of these is true:
- the goal requires a design decision the plan does not already make
- it changes a public interface, schema, or data migration
- it is `needs-planning: yes`
- a previous attempt at this milestone failed review

Never route the main conversation. The main model stays fixed for the whole run; only subagents vary.

### 5. Needs-planning triggers
Mark `needs-planning: yes` when:
- you could not write a concrete acceptance check for it (this is the strongest signal: if you cannot say how to verify it, you do not yet understand it)
- it depends on the output shape of an earlier milestone that does not exist yet
- it touches concurrency, auth, payments, or destructive data operations
- the user said "not sure how" or "figure out" about this part

For these, the plan says what the planning step must produce: a sub-plan appended to `plan.md` under that milestone, with the checks it adds to `checks.json`. Execution invokes `milestone-planner` with only this work order, the relevant interfaces and unresolved question. It has Read/Grep/Glob only and returns a proposal; the orchestrator writes the approved plan/check changes. Never use `context: fork` for this step.

### 6. Acceptance checks
Write `checks.json` for every milestone and a `gates` entry for every phase. Read `references/acceptance-checks.md` before writing them; it has the runner's format, a pattern catalogue, and good/bad examples. The rules that matter most:
- A check is a command with an expected result. "Confirm it works" is not a check.
- Every milestone has at least one behaviour check (runs the code, hits the endpoint, executes the CLI) and one static check (test, build, typecheck, lint on the scope).
- Checks must be runnable from a clean checkout of the branch with the project's documented setup. If a check needs a running service, the check starts it or the plan has a milestone that does.
- A phase gate runs the full suite plus anything that proves the phase's "working state" claim.

### 7. Review tiers
- `0`: hook only. The builder cannot finish until checks pass. Use for mechanical work with strong checks.
- `1`: hook, then `milestone-reviewer` reads the diff. Use for anything on the `opus` routing list, and for any milestone whose checks are weak (say so in the plan).
- `2`: tier 1 plus a human pause: execution stops and shows the review to the user before the next milestone. Use for auth, payments, data migrations, public API, deletions.

### 8. Supervised or autonomous
Ask the user once, before writing the plan: should execution stop after every milestone for them to read, or run on its own? Write the answer into the plan header as `mode: supervised` or `mode: autonomous`, with the `autonomy:` budget line from the template. Default to `supervised` when they have no preference; autonomy is theirs to grant, and because it lives in the plan it is granted by a commit they can see and revert.

For `mode: autonomous`, before you show the plan: every milestone needs `irreversible:` set honestly, every env var a check needs must be listed under `## Environment`, and `bash "$PV_HOOKS/run-state.sh" lint-checks <slug>` must pass — a check is a shell command that no tool guard ever sees, so a destructive one would run unwatched. Tell the user which milestones will still pause (tier 2 with `irreversible: yes`) and what the run will fix on its own.

### 9. Finish the plan
Write `plan.md` and `checks.json`, then lock the hooks: `bash "$PV_HOOKS/lock-hooks.sh" write <slug>`. This writes `hooks.lock` (plugin version + hash of every enforcement script) next to the plan; acceptance later refuses if the installed scripts differ from it, which is how a committed file vouches for scripts that live outside the repo. Commit all three files together in one commit titled `plan(<slug>): <summary>`. Every later change to `checks.json` or `hooks.lock` (a sub-plan, a re-lock, a corrected check) is also a `plan(<slug>): ...` commit: acceptance refuses changes to those files from any other commit. Validate: `jq . .claude/build-plans/<slug>/checks.json` and confirm every milestone id in the plan has an entry. Then show the user the phase list, the milestone count per model, the tier-2 pauses, and any `needs-planning` items. Stop. Do not start building.

## Mode: Execute

Before the first milestone:
- Do not touch `/model` or effort for the rest of the run. Read the plan's header once (`mode:` decides how this run behaves); from then on read only the milestone you are about to run, with `bash "$PV_HOOKS/run-state.sh" milestone <slug> <id>`.
- `bash "$PV_HOOKS/run-state.sh" preflight <slug>`. It checks the tree, the lock, the checks and the run directory, and ends with a verdict comparing the plan's mode with this session's permission mode. **If the plan says `mode: autonomous`, read `references/autonomous-run.md` now and follow it for the rest of the run**; this file's per-milestone loop still applies, that one decides what you do with each outcome and when you stop.
- Lock check, once: `bash "$PV_HOOKS/lock-hooks.sh" verify <slug>`. If it fails because the plugin was updated since the plan was written, re-lock (`write <slug>`), commit it as `plan(<slug>): re-lock hooks for <version>`, and continue; if you did not update the plugin, stop and tell the user the scripts changed unexpectedly.
- Git setup, once: confirm the working tree is clean (`git status --porcelain` is empty; if not, stop and ask). Create or check out the plan branch: `git checkout -b plan/<slug> <base>` on a fresh start, or `git checkout plan/<slug>` on resume. Record the branch in `plan.md` if it is not there.
- On resume: use `run-state.sh brief <slug>` and `run-state.sh accepted <slug> <id>`. They share the same committed-acceptance lookup, including historical group commits. Never invent a grep expression to decide completion. `status:` lines are a readable projection; uncommitted acceptance files and PASS results cannot establish completion.

For each phase, in order:
1. Take the next milestone only after its dependencies are accepted. If it is `needs-planning: yes`, spawn `milestone-planner` with a narrow question and the milestone work order. Do this just in time, not for all future milestones at phase start. Commit the returned sub-plan/check changes as `plan(<slug>): sub-plan for <id>`. Stop for a user decision when the proposal goes beyond the approved design.
2. Take the spawn snapshot: `bash "$PV_HOOKS/snapshot.sh" <slug> <id> spawn`. It records the tree before any builder touches it; it anchors provenance and recovery if the milestone goes wrong; the review diff uses HEAD after approved plan-only amendments. Then spawn exactly one builder. The prompt is the milestone's `context` block plus the lines `Plan: <slug>  Milestone: <id>` and `PV_HOOKS: <the path>`. Nothing else. Use `builder-sonnet` or `builder-opus` per the milestone's `model`. Builders never commit; the commit is the acceptance stamp and belongs to you. Builders have no Agent tool, so they cannot fork or delegate; do not try to give them one. Do not spawn the next builder until this milestone is accepted or abandoned. For an opt-in parallel group (rare, see the field rules), spawn the members in one message and take one `spawn` snapshot per member first.
3. When a builder finishes, run `run-state.sh status <slug> <id>` before reading its report. The summary reads `.claude/build-plans/<slug>/results/<id>.json` and checks freshness; the report is commentary. If it says FAIL, the milestone is not done regardless of what the report says. The `pv: <slug>/<id> …` line you see right after spawning is spawn-time and carries no verdict — Claude Code's Agent tool is asynchronous, so PostToolUse[Agent] fires before the builder has done anything. Wait for the agent's completion notification, not that line or the hand-back message, then read the compact status and confirm a `hook:verify-milestone` heartbeat for `<id>`. The hand-back is also delivered once per run, so after the hook sends a builder back its corrected report never arrives that way: read `results/<id>.report.md`, which the hook writes from the report it actually verified. If there is no results file newer than the spawn and no heartbeat after completion, the verify hook did not run: stop and tell the user enforcement is not wired, instead of resuming the builder.
4. Read `run-state.sh status <slug> <id>` for a compact evidence summary. For tier 1 or 2, call `review-start.sh <slug> <id>` BEFORE spawning `milestone-reviewer`; pass its returned token as `REVIEW-ID: <token>` along with goal, scope and the report path. This pins the code/check identity before review. Pass sibling scopes for historical parallel groups. The reviewer inspects the diff against `HEAD`; source commits slipped in since the spawn are not legitimate plan changes. It may run `run-checks.sh <slug> <id> --observe`, which writes separate evidence and preserves a builder's BLOCKED result. Read the structured `results/<id>.review.json` verdict/freshness via `status`; raw `review.md` is diagnostic. ACCEPT (no findings) and ACCEPT-WITH-NOTES (only low findings) can proceed; REJECT resumes the same builder with findings. INVALID or stale evidence requires a new review-start and review. A second invalid report may stop to avoid a loop, but it stays INVALID and cannot authorize acceptance. Re-review after repairs; never reuse the previous token. Second REJECT escalates to builder-opus; third stops for the user.
5. For tier 2 in supervised mode, or tier 2 with `irreversible: yes` in autonomous mode, show the review and wait for explicit user approval. Only after the user approves, run `approve-milestone.sh <slug> <id> --by <user-name> --reason <approval-reference>`. This records their actual decision against the current review; it is not authentication and must never be fabricated. Changed code/checks or a new review require renewed approval.
6. Accept: run `bash "$PV_HOOKS/accept-milestone.sh" <slug> <id> [<id>...]` (one call for a parallel group). A group's members go stale as each other work, so re-run every member's checks after the last member finishes, then accept the group in that one call. It refuses, with the reason on stderr, if the results file is missing, not PASS, produced against different code or a different `checks.json` than what is on disk now, or if `checks.json` or `hooks.lock` differs from `HEAD` or was changed by any commit other than a `plan(<slug>): ...` commit. On refusal, do what the message says (usually re-run the checks, or restore a tampered file and re-run); never work around it. It also requires the committed review policy, accepted dependencies, declared preceding phase gates, and current bound review/approval where required. It commits `results/<id>.accepted.json` containing the authorizing evidence. On success it sets `status: DONE` in `plan.md` and makes the one milestone commit `milestone(<ids>): <goal> [<slug> <ids>]`. If a milestone is abandoned, set its status to `ABANDONED <why>` and, with the user's approval, restore the spawn snapshot so the next milestone starts from the accepted state.
7. At the end of the phase run `bash "$PV_HOOKS/run-checks.sh" <slug> gate:<phase>`. Do not start the next phase on a failing gate; a failing gate with all milestones green means a milestone's checks were too narrow, so add a check and treat the fix as a new milestone `<phase>.<n+1>`. On pass, tag it: `git tag plan/<slug>/phase-<n>` and commit the gate's results file if it is not already in.

When the last gate passes, report the branch name, the commit count, and the tags, and stop. Never push, never merge, never open a PR; those are the user's actions. Say: "branch `plan/<slug>` is ready to push."

Limits: builders stop after `maxTurns` (60 in the agent files; raise it in the file if a milestone legitimately needs more, do not split the run to dodge it) and every check has a timeout. There is no elapsed-time limit on a subagent; if a milestone could plausibly run for hours, that is a sizing problem in the plan, not something to supervise around.

Committed structured acceptance records establish completion; `run-state.sh accepted` also understands legacy milestone commits. Check/review JSON holds evidence for one artifact and attempt. Markdown status and commit subjects are readable projections. Missing review policy fails closed; upgrading a legacy plan requires explicit `review:` fields, a new hooks.lock and fresh checks/reviews.

Git rules for the whole run:
- Commit only after the results file says PASS and, for tier 1/2, the review says ACCEPT or ACCEPT-WITH-NOTES with current bound evidence. Plan amendments use `plan(<slug>): ...`; phase gate evidence may be committed separately after verification.
- Never `git stash`, `rebase`, or `reset` past a milestone commit without asking. `git reset --hard <last milestone sha>` is the recovery move, and you propose it, the user approves it.
- Recovery points are snapshots, not commits: `bash "$PV_HOOKS/snapshot.sh" <slug> <id> <label>` at spawn (you), after each file batch (builder) and at every finish attempt (hook). They live under `refs/pv/snapshots/` and never appear in the review diff or the branch. `snapshot.sh list`/`diff` are free to use; `restore` is destructive and needs the user's approval.
- Keep builders in the main working tree. Worktree isolation is unsupported by the hooks for now (results and acceptance assume one tree); revisit only if you later need real parallelism.

Context discipline for the main agent:
- For routine decisions, read `run-state.sh status <slug> <id>` only. It summarizes check freshness, review verdict/binding and dependencies without loading reports. Read the relevant report or code only for an exception that requires judgment. Do not paste logs or full reviews into the main context.
- Do not carry the run's history in your head. `bash "$PV_HOOKS/run-state.sh" brief <slug>` rebuilds it from git and the run log, which is also what makes a context reset survivable; `run-state.sh log <slug> '<json>'` is where each decision goes as you make it.
- Do not paste builder reports into your own messages; refer to the id.
- At phase boundaries, save decisions and use a context reset/compaction if needed; resume from brief and status. Never carry an evaluator's test plan, predictions or findings register in this execution conversation. Cache-hit rate is a diagnostic, not evidence of savings.

## What this skill does not do
- It does not make checks good. A plan with vague checks passes the hook trivially. Spend planning effort on checks first, prose second.
- It cannot stop a builder from weakening a check inside the code (skipping a test, loosening an assertion). The reviewer is there for that; use tier 1 whenever the checks could be gamed.
- It does not manage secrets, environments, or services. If a check needs a database, the plan must say how it gets one.

## Benchmark profile

Use sequential milestones (`parallel-group: none`) for new comparative runs. Existing opt-in groups remain supported for compatibility; do not expand their use while measuring the sequential workflow. Keep the main model/effort fixed, provide identical requirements to baseline runs, and include planning, orchestration, review and retries in totals. No token or cost savings are guaranteed.
