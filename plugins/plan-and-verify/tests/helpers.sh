#!/usr/bin/env bash
# helpers.sh — shared helpers for the plan-and-verify script tests.
# Source it from a *.test.sh file. Tests feed hook scripts JSON on stdin inside
# throwaway git repos; nothing touches the network, Claude, or the caller's repo.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS="$(cd "$TESTS_DIR/../hooks" && pwd)"
PASS=0; FAIL=0; TMPS=""
trap 'for d in $TMPS; do rm -rf "$d"; done' EXIT

ok()   { PASS=$((PASS+1)); echo "  ok   $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/       | /'; return 0; }

assert_eq()           { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected: $2"$'\n'"actual:   $3"; }
assert_contains()     { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "expected to contain: $2"$'\n'"actual: $3" ;; esac; }
assert_not_contains() { case "$3" in *"$2"*) bad "$1" "expected NOT to contain: $2"$'\n'"actual: $3" ;; *) ok "$1" ;; esac; }
assert_empty()        { [ -z "$2" ] && ok "$1" || bad "$1" "expected empty, got: $2"; }
assert_path_absent()  { [ ! -e "$2" ] && ok "$1" || bad "$1" "path exists: $2"; }

tmpdir() { local d; d=$(mktemp -d "${TMPDIR:-/tmp}/pv-test.XXXXXX"); TMPS="$TMPS $d"; printf '%s' "$d"; }

# mk_repo <slug> -> repo path. One milestone (1.1) whose only check is "hello.txt equals ok",
# plan.md, checks.json and hooks.lock committed as "plan(<slug>): test plan".
mk_repo() {
  local slug=${1:-demo} d
  d=$(tmpdir)
  git -C "$d" init -q -b main
  git -C "$d" config user.name test && git -C "$d" config user.email test@example.com
  git -C "$d" commit -q --allow-empty -m init
  mkdir -p "$d/.claude/build-plans/$slug"
  printf '# Plan: %s\n\n### Milestone 1.1\ngoal: Write hello.txt containing ok.\nstatus: TODO\n' "$slug" \
    > "$d/.claude/build-plans/$slug/plan.md"
  cat > "$d/.claude/build-plans/$slug/checks.json" <<'EOF'
{
  "defaults": { "timeout": 30, "cwd": "" },
  "milestones": {
    "1.1": { "checks": [ { "name": "hello is ok", "cmd": "cat hello.txt", "expect": "equals", "value": "ok" } ] }
  },
  "gates": {}
}
EOF
  (cd "$d" && CLAUDE_PROJECT_DIR="$d" bash "$HOOKS/lock-hooks.sh" write "$slug" >/dev/null)
  git -C "$d" add -A && git -C "$d" commit -q -m "plan($slug): test plan"
  printf '%s' "$d"
}

finish() { echo "  -- $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; }
