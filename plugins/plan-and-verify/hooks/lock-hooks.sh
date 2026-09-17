#!/usr/bin/env bash
# lock-hooks.sh write <plan>    -> write .claude/build-plans/<plan>/hooks.lock
# lock-hooks.sh verify <plan>   -> exit 0 if installed hooks match the lock, 2 if not, 3 if no lock
#
# The lock pins the plugin version and a SHA-256 of every enforcement script.
# It is committed with the plan, so acceptance can prove the scripts that ran
# are the ones the plan was written against, even though the plugin itself
# lives outside the repo.
set -u
HOOKS="$(cd "$(dirname "$0")" && pwd)"
. "$HOOKS/lib.sh"
ROOT=$(pv_root)
cmd="${1:-}"; plan="${2:-}"
[ -n "$cmd" ] && [ -n "$plan" ] || { echo "usage: lock-hooks.sh write|verify <plan>" >&2; exit 3; }
LOCK="$ROOT/.claude/build-plans/$plan/hooks.lock"
ver=$(jq -r .version "$HOOKS/../.claude-plugin/plugin.json" 2>/dev/null || echo unknown)
current() {
  echo "plugin plan-and-verify $ver"
  for f in lib run-checks verify-milestone accept-milestone snapshot guard-builder lock-hooks ensure-repo; do
    printf '%s  %s.sh\n' "$(pv_sha256 < "$HOOKS/$f.sh")" "$f"
  done
}
case "$cmd" in
  write)
    mkdir -p "$(dirname "$LOCK")"; current > "$LOCK"; echo "wrote ${LOCK#$ROOT/}"; cat "$LOCK" ;;
  verify)
    [ -f "$LOCK" ] || { echo "no hooks.lock for plan $plan (run: lock-hooks.sh write $plan)" >&2; exit 3; }
    if diff -q <(current) "$LOCK" >/dev/null; then echo "hooks match lock for $plan"; exit 0; fi
    echo "installed hooks differ from ${LOCK#$ROOT/}:" >&2; diff <(current) "$LOCK" >&2 || true; exit 2 ;;
  *) echo "usage: lock-hooks.sh write|verify <plan>" >&2; exit 3 ;;
esac
