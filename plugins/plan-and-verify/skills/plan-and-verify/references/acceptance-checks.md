# Acceptance checks

Read this before writing `checks.json`. The runner is `"$PV_HOOKS/run-checks.sh"`; the Stop hook on every builder calls it, so the checks you write here are the only thing standing between "Claude says it's done" and "it is done".

## Runner format

```json
{
  "defaults": { "timeout": 300, "cwd": "" },
  "milestones": {
    "1.1": {
      "checks": [
        { "name": "auth unit tests", "cmd": "npm test -- --runInBand src/auth", "expect": "exit0" },
        { "name": "typecheck",       "cmd": "npx tsc --noEmit -p tsconfig.json", "expect": "exit0" },
        { "name": "401 without token",
          "cmd": "curl -s -o /dev/null -w '%{http_code}' http://localhost:3000/api/me",
          "expect": "equals", "value": "401", "timeout": 20 }
      ]
    }
  },
  "gates": {
    "1": { "checks": [ { "name": "full suite", "cmd": "npm test", "expect": "exit0", "timeout": 900 } ] }
  }
}
```

`expect` values:

| expect | passes when |
|---|---|
| `exit0` (default) | command exits 0 |
| `exit` | exit code equals `value` |
| `equals` | trimmed stdout+stderr equals `value` exactly |
| `contains` | output contains `value` |
| `not_contains` | output does not contain `value` |

Per-check `timeout` (seconds) and `cwd` (relative to project root) override `defaults`. Commands run with `bash -o pipefail -c`, so a failing command in a pipe fails the check.

Results land in `.claude/build-plans/<slug>/results/<id>.json` with `status`, per-check `ok`, exit codes, and the last 2000 chars of output. The main agent reads `status` from here, never from the builder's prose.

## The one rule

A check is a command plus an expected result that a stranger could run. If you find yourself writing "verify that", "make sure", or "confirm", you have written a wish, not a check. Convert it or mark the milestone `needs-planning: yes`.

A check must not leave non-ignored files behind (coverage reports, build output outside `dist/`/`build/`, logs). The runner fails a run that changes the source tree and names the files; gitignore them in the plan or write them to a temp dir.

## Two checks minimum, of different kinds

- **Static**: tests, build, typecheck, lint, scoped to the milestone's files so they run fast. Proves the code compiles and the tests the builder wrote pass.
- **Behaviour**: run the thing. A CLI invocation, an HTTP call, a script that imports the module and calls it, a DB query after a migration. Proves the code does what the goal says. Static checks alone let a builder pass by writing tests that assert the wrong thing.

## Pattern catalogue

Tests (scope them; the phase gate runs everything):
- `npm test -- src/auth` / `pytest tests/auth -q` / `go test ./internal/auth/...` / `cargo test -p auth`
- A specific new test must exist and pass: `pytest tests/auth/test_refresh.py::test_expired_token_rejected -q`

Build and types:
- `npx tsc --noEmit`, `go build ./...`, `cargo check`, `python -m compileall -q src`

Behaviour via HTTP (start the server in a prior milestone or in the check):
- `curl -sf http://localhost:3000/health` (exit0; `-f` fails on 4xx/5xx)
- `curl -s -o /dev/null -w '%{http_code}' URL` with `equals` `"401"`
- `curl -s URL | jq -e '.items | length > 0'` (exit0 only if true)

Behaviour via CLI or script:
- `node -e "const m=require('./dist/slug'); process.exit(m.slug('Héllo World')==='hello-world'?0:1)"`
- `python -c "from app.pricing import total; assert total([2,3])==5"`
- `./bin/tool --version` with `contains` `"2."`

Absence checks (regressions, hygiene):
- `grep -rn 'console.log' src/auth || true` with `equals` `""`
- `grep -rn 'TODO(milestone-2.3)' src || true` with `equals` `""` (builder must resolve its own markers)
- `git diff --name-only HEAD | grep -vE '^(src/auth/|\.claude/build-plans/)' || true` with `equals` `""` (nothing outside scope changed; `HEAD` is the last accepted milestone because execution commits per milestone)
- in a `parallel-group`, the same check must also exclude the sibling members' scopes: `git diff --name-only HEAD | grep -vE '^(src/auth/|src/billing/|\.claude/build-plans/)' || true` with `equals` `""` (a sibling builder is editing `src/billing/` while your checks run, so a scope-only pattern reports its files as yours and the check fails for work you did not do)

Data and migrations:
- `psql "$DATABASE_URL" -tAc "select count(*) from information_schema.columns where table_name='users' and column_name='deleted_at'"` with `equals` `"1"`
- `alembic current 2>/dev/null | grep -c head` with `equals` `"1"`

Files and artefacts:
- `test -f dist/index.js && test -s dist/index.js`
- `du -k dist/bundle.js | cut -f1` with a shell comparison: `[ $(du -k dist/bundle.js | cut -f1) -lt 250 ]`

Things the runner cannot check well (send these to review tier 1 instead): visual layout, "reads cleanly", performance without a benchmark harness, anything needing a browser unless you already have Playwright wired up.

## Good versus bad

Bad: `{ "name": "works", "cmd": "npm test" }` on a milestone that touched one module. Slow, and passes if the builder wrote no tests at all.
Good: scoped tests plus one behaviour call, plus `not_contains "skip"` on the test file if skipping is a known habit.

Bad: `{ "name": "endpoint added", "cmd": "grep -rn '/api/refresh' src" }`. Proves a string exists.
Good: `curl -s -X POST localhost:3000/api/refresh -H 'Authorization: Bearer expired' -o /dev/null -w '%{http_code}'` with `equals "401"`, and a second call with a valid token expecting `200`.

Bad: `{ "name": "migration ran", "cmd": "ls migrations | grep add_deleted_at" }`.
Good: the `information_schema` query above, run against the test database.

Bad: a check that passes before the milestone starts. Every behaviour check should fail on the current code; if it already passes, it proves nothing. When writing the plan, note "expected to fail now" beside each one.

## Gaming, and what to do about it

Builders can pass checks by:
- editing `checks.json` (the builder rules forbid it; the reviewer diffs it; you can add a `PreToolUse` deny on `Edit(.claude/build-plans/**)` for subagents if it happens)
- skipping or deleting tests: add `not_contains` checks for `.skip(`, `xit(`, `@pytest.mark.skip`, or `[ $(git diff HEAD --numstat -- 'src/**/*.test.*' | awk '{d+=$2} END{print d+0}') -lt 20 ]` to fail if more than 20 test lines were deleted
- hard-coding the expected value: the reviewer's second question exists for this; tier 1 any milestone where a constant could satisfy the check

None of this is paranoia about the model. It is the same discipline you would apply to a contractor: the check defines done, and someone other than the builder confirms it.
