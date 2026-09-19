# Plan: <slug>

Request: <one paragraph, the user's words where possible>
Branch: plan/<slug>   Base: <ref>   (execution creates the branch; one commit per accepted milestone, one tag per passed phase; never pushed by Claude)
Main model: <fixed for the whole run; never change it mid-run>
mode: supervised | autonomous   (autonomous runs milestone to milestone on its own and stops only for the five
                                 conditions in references/autonomous-run.md; changing it is a plan(<slug>) commit)
autonomy: builder-runs-per-milestone=3  check-fixes-per-run=2  repairs-per-gate=2

## Project commands
test: <cmd>   build: <cmd>   typecheck: <cmd>   lint: <cmd>   dev server: <cmd>

## Decisions already made
- <decisions the planner took so builders do not re-decide them>

## Environment
- <every env var a check or command needs, and where it comes from. An autonomous run refuses to start
  when one is missing rather than letting a builder invent a value.>

## Phase 1: <name>
Working state at end: <what is true and demonstrable when this phase ends>
Gate: `run-checks.sh <slug> gate:1`

### Milestone 1.1
goal: <one sentence>
scope: <paths>
out-of-scope: <paths>
depends-on: <ids or none>
parallel-group: none   (keep none for benchmark/new sequential plans; legacy opt-in only; see SKILL.md field rules. The spawn guard lets builders run at the same time
                        only for members of the same `parallel-group`; each member's checks stay scoped to its own
                        directories, and the group is accepted in one call after every member's checks are re-run)
model: sonnet | opus
needs-planning: no | yes — <what the planning step must produce>
review: 0 | 1 | 2
irreversible: no | yes   (yes = deletes data, migrates a schema, rotates a secret, touches payments, or
                          changes anything outside this repo. The only thing that still pauses an autonomous run at tier 2.)
checks: <check names from checks.json>
status: TODO | DONE | ABANDONED <why>   (DONE is written by accept-milestone.sh; completion is queried with `run-state.sh accepted <slug> <id>`)
context: |
  <The full work order. Include: the goal again, the exact files, interfaces
  to match (paste signatures), the project commands it should use, decisions
  it must not revisit, and the run-checks command. Nothing about other
  milestones unless it must match their output.>

### Milestone 1.2
...

## Phase 2: <name>
...

## Example (delete when filled in)

### Milestone 1.1
goal: Reject requests with expired JWTs at the auth middleware with a 401 and no body.
scope: src/auth/middleware.ts, src/auth/__tests__/middleware.test.ts
out-of-scope: src/auth/tokens.ts (token issuing is milestone 1.2), src/routes/**
depends-on: none
parallel-group: none
model: sonnet
needs-planning: no
review: 1
irreversible: no
checks: auth middleware tests, typecheck, expired token 401, valid token 200
status: TODO
context: |
  Goal: reject requests with expired JWTs at the middleware with 401 and empty body.
  Edit only src/auth/middleware.ts and its test file. Do not touch tokens.ts.
  The middleware signature is `export function requireAuth(req, res, next)` and must stay.
  Use `jwt.verify` (already imported); on TokenExpiredError respond `res.status(401).end()`.
  Add a test for the expired case and one for the valid case in the existing test file.
  Commands: tests `npm test -- src/auth`, typecheck `npx tsc --noEmit`.
  Dev server for the behaviour checks is already running on :3000 (started by milestone 0.1).
  When done run `bash "$PV_HOOKS/run-checks.sh" <slug> 1.1` and paste its output in your report.
