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

## Mode: Plan

### 1. Understand before you write
- Read the request and any files it names. For anything else, spawn the built-in `Explore` subagent with a narrow question ("which modules touch auth? list files, no explanations"). Do not read the codebase yourself in the main conversation; that context stays with you for the whole run.
- Find the existing test, build, lint and typecheck commands (package.json scripts, Makefile, pyproject, CI config). You need them for checks. Record them under `## Project commands` in the plan.
- If a hard requirement is unclear, ask the user now. One round of questions, then commit.

### 2. Shape phases and milestones
A **phase** is a group of milestones that leaves the project in a working state when it ends. A **milestone** is one subagent's job.

Sizing rules:
- A milestone is one uninterrupted burst of work: roughly 5 to 30 tool calls, one module or one concern. Split anything larger. Bundle anything that would take fewer than ~5 calls into a neighbour; every subagent pays a cold cache start.
- A milestone touches files it owns. If two milestones edit the same file, they are one milestone or they are sequential.
- Milestones run one at a time, in one working tree, with one writer. This is the default and it is not a compromise: parallel builders never saved tokens (each pays its own cold start), they only saved wall-clock time, and one collision costs more than a week of that.

### 3. Fill in every milestone
Copy `assets/plan-template.md`. Each milestone has all of these fields; no field is optional:

| Field | Rule |
|---|---|
| `id` | `<phase>.<n>`, e.g. `2.3` |
| `goal` | One sentence a reviewer can check the diff against |
| `scope` | Files/dirs it may edit. `out-of-scope` lists the tempting neighbours it must not |
| `depends-on` | Milestone ids that must be DONE first. Empty means it can start at phase start |
| `parallel-group` | Default `none`. Set a letter only when the user asked for parallel work AND the members are same-phase, have no dependencies, edit disjoint top-level directories, and are review tier 1 or higher. Otherwise leave it `none` and order them |
| `model` | `sonnet` or `opus` (see routing) |
| `needs-planning` | `yes` or `no` (see triggers). `yes` means an Opus planning fork runs before the build |
| `review` | `0`, `1`, or `2` (see tiers) |
| `checks` | Names of the checks in `checks.json` for this id. At least two, one of which exercises behaviour, not just compilation |
| `context` | The work order text the builder gets. Everything it needs, nothing else: decisions already made, exact commands, interfaces it must match |

### 4. Model routing
Default to `sonnet`. Route to `opus` when any of these is true:
- the goal requires a design decision the plan does not already make
- scope spans more than one module or more than ~6 files
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

For these, the plan says what the planning step must produce: a sub-plan appended to `plan.md` under that milestone, with the checks it adds to `checks.json`. Execution runs that step first, on `opus`, as a read-only fork.

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

### 8. Finish the plan
Write `plan.md` and `checks.json`, then lock the hooks: `bash "$PV_HOOKS/lock-hooks.sh" write <slug>`. This writes `hooks.lock` (plugin version + hash of every enforcement script) next to the plan; acceptance later refuses if the installed scripts differ from it, which is how a committed file vouches for scripts that live outside the repo. Commit all three files together. Validate: `jq . .claude/build-plans/<slug>/checks.json` and confirm every milestone id in the plan has an entry. Then show the user the phase list, the milestone count per model, the tier-2 pauses, and any `needs-planning` items. Stop. Do not start building.

## Mode: Execute

Before the first milestone:
- Do not touch `/model` or effort for the rest of the run. Read `plan.md` once; from then on read only the milestone you are about to run.
- Lock check, once: `bash "$PV_HOOKS/lock-hooks.sh" verify <slug>`. If it fails because the plugin was updated since the plan was written, re-lock (`write <slug>`), commit, and continue; if you did not update the plugin, stop and tell the user the scripts changed unexpectedly.
- Git setup, once: confirm the working tree is clean (`git status --porcelain` is empty; if not, stop and ask). Create or check out the plan branch: `git checkout -b plan/<slug> <base>` on a fresh start, or `git checkout plan/<slug>` on resume. Record the branch in `plan.md` if it is not there.
- On resume: `git log --oneline --grep '\[<slug> ' plan/<slug>` shows one commit per accepted milestone. Trust that over the `status:` lines; fix `plan.md` if they disagree. Results files are evidence for one run only and are never a reason to skip a milestone; if a milestone has no commit, it is not done.

For each phase, in order:
1. Handle `needs-planning: yes` milestones first: spawn a `context: fork` planning pass on `opus` with the milestone text and the question "produce the sub-plan and its checks". Append the result to `plan.md`, merge its checks into `checks.json`, and commit both with `plan(<slug>): sub-plan for <id>` before building.
2. Take the spawn snapshot: `bash "$PV_HOOKS/snapshot.sh" <slug> <id> spawn`. It records the tree before any builder touches it; the reviewer diffs against it and it is the undo if the milestone goes wrong. Then spawn exactly one builder. The prompt is the milestone's `context` block plus the lines `Plan: <slug>  Milestone: <id>` and `PV_HOOKS: <the path>`. Nothing else. Use `builder-sonnet` or `builder-opus` per the milestone's `model`. Builders never commit; the commit is the acceptance stamp and belongs to you. Builders have no Agent tool, so they cannot fork or delegate; do not try to give them one. Do not spawn the next builder until this milestone is accepted or abandoned. For an opt-in parallel group (rare, see the field rules), spawn the members in one message and take one `spawn` snapshot per member first.
3. When a builder returns, read `.claude/build-plans/<slug>/results/<id>.json` before you read its report. `status` there is the truth; the report is commentary. If it says FAIL, the milestone is not done regardless of what the report says.
4. For review tier 1 or 2, spawn `milestone-reviewer` with the plan slug, id, goal, scope, and the builder's report. It diffs the working tree against `HEAD`, which is the last accepted milestone, so it sees exactly this milestone's change. On REJECT, resume the same builder (do not spawn a new one; the resumed run reads its warmed cache) with the reviewer's findings as the prompt. Second REJECT: route to `builder-opus` and re-review. Third: stop and ask the user, proposing `bash "$PV_HOOKS/snapshot.sh" restore <spawn-ref>` (it refuses without `PV_CONFIRM_RESTORE=yes`, which you set only after the user says yes).
5. For tier 2, stop after the review and show the user; continue only when they say so.
6. Accept: run `bash "$PV_HOOKS/accept-milestone.sh" <slug> <id> [<id>...]` (one call for a parallel group). It refuses, with the reason on stderr, if the results file is missing, not PASS, produced against different code or a different `checks.json` than what is on disk now, or if `checks.json` differs from `HEAD`. On refusal, do what the message says (usually re-run the checks, or restore a tampered file and re-run); never work around it. On success it sets `status: DONE` in `plan.md` and makes the one milestone commit `milestone(<ids>): <goal> [<slug> <ids>]`. If a milestone is abandoned, set its status to `ABANDONED <why>` and, with the user's approval, restore the spawn snapshot so the next milestone starts from the accepted state.
7. At the end of the phase run `bash "$PV_HOOKS/run-checks.sh" <slug> gate:<phase>`. Do not start the next phase on a failing gate; a failing gate with all milestones green means a milestone's checks were too narrow, so add a check and treat the fix as a new milestone `<phase>.<n+1>`. On pass, tag it: `git tag plan/<slug>/phase-<n>` and commit the gate's results file if it is not already in.

When the last gate passes, report the branch name, the commit count, and the tags, and stop. Never push, never merge, never open a PR; those are the user's actions. Say: "branch `plan/<slug>` is ready to push."

Limits: builders stop after `maxTurns` (60 in the agent files; raise it in the file if a milestone legitimately needs more, do not split the run to dodge it) and every check has a timeout. There is no elapsed-time limit on a subagent; if a milestone could plausibly run for hours, that is a sizing problem in the plan, not something to supervise around.

Three sources of truth, three roles: git holds accepted milestones; `results/*.json` holds evidence for one specific run against one specific tree (the acceptance script checks the fingerprints); `plan.md` `status:` lines are a readable projection that can be rebuilt from `git log`.

Git rules for the whole run:
- Commit only after the results file says PASS and, for tier 1/2, the review says ACCEPT. Nothing else ever gets committed on this branch.
- Never `git stash`, `rebase`, or `reset` past a milestone commit without asking. `git reset --hard <last milestone sha>` is the recovery move, and you propose it, the user approves it.
- Recovery points are snapshots, not commits: `bash "$PV_HOOKS/snapshot.sh" <slug> <id> <label>` at spawn (you), after each file batch (builder) and at every finish attempt (hook). They live under `refs/pv/snapshots/` and never appear in the review diff or the branch. `snapshot.sh list`/`diff` are free to use; `restore` is destructive and needs the user's approval.
- Keep builders in the main working tree. Worktree isolation is unsupported by the hooks for now (results and acceptance assume one tree); revisit only if you later need real parallelism.

Context discipline for the main agent:
- Do not read diffs. That is the reviewer's job. You read results files, reports and `snapshot.sh list` output.
- Do not paste builder reports into your own messages; refer to the id.
- Run `/compact` only at a phase boundary, after the gate passes and the tag exists, never mid-phase.

## What this skill does not do
- It does not make checks good. A plan with vague checks passes the hook trivially. Spend planning effort on checks first, prose second.
- It cannot stop a builder from weakening a check inside the code (skipping a test, loosening an assertion). The reviewer is there for that; use tier 1 whenever the checks could be gamed.
- It does not manage secrets, environments, or services. If a check needs a database, the plan must say how it gets one.
