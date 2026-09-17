# Plan: <slug>

Request: <one paragraph, the user's words where possible>
Branch: plan/<slug>   Base: <ref>   (execution creates the branch; one commit per accepted milestone, one tag per passed phase; never pushed by Claude)
Main model: <fixed for the whole run; never change it mid-run>

## Project commands
test: <cmd>   build: <cmd>   typecheck: <cmd>   lint: <cmd>   dev server: <cmd>

## Decisions already made
- <decisions the planner took so builders do not re-decide them>

## Phase 1: <name>
Working state at end: <what is true and demonstrable when this phase ends>
Gate: `run-checks.sh <slug> gate:1`

### Milestone 1.1
goal: <one sentence>
scope: <paths>
out-of-scope: <paths>
depends-on: <ids or none>
parallel-group: none   (opt-in only; see SKILL.md field rules)
model: sonnet | opus
needs-planning: no | yes — <what the planning step must produce>
review: 0 | 1 | 2
checks: <check names from checks.json>
status: TODO | DONE | ABANDONED <why>   (DONE is written by accept-milestone.sh; the commit is `git log --grep '[<slug> <id>]'`)
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
