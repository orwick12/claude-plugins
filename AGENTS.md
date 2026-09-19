# Claude plugins

The current plugin is `plugins/plan-and-verify`. Read its README and skill contract before
changing workflow behavior. The implementation plan is maintained in
`../plantest/docs/plans/2026-09-18-verified-orchestration.md`; that sibling project also owns
live evaluation evidence and benchmarks.

`make help` lists commands; `make check` is the gate (Bash syntax, JSON, all script tests).
Scripts support stock macOS Bash 3.2 plus Git and jq. Tests use temporary Git repositories
and synthetic hook payloads; passing them is not proof that Claude hook wiring works live.

Write behavior tests and confirm the intended failure before implementation. Commit tests
before implementing and do not change tests just to make implementation pass. Record any
intentional fixture/contract migrations explicitly. Keep source, review, approval and
acceptance identity consistent. Missing/invalid evidence must refuse acceptance.

No target installs, publishes, pushes, merges, destroys data or changes the installed
plugin cache. Installation is a separate user action. Never read secrets/environment files.
Do not claim token, cost or cache savings without a controlled comparison. Preserve old
acceptance compatibility, but require fresh evidence when upgrading in-flight plans.
