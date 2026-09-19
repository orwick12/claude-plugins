#!/usr/bin/env bash
# review-start.sh PLAN ID -> token. Call BEFORE spawning the reviewer.
set -eu
HOOKS="$(cd "$(dirname "$0")" && pwd)"
. "$HOOKS/evidence.sh"
plan=${1:-}; id=${2:-}
pv_valid_ref "$plan" && pv_valid_ref "$id" || { echo 'usage: review-start.sh PLAN ID' >&2; exit 3; }
root=$(pv_root); dir="$root/.claude/build-plans/$plan"; safe=$(printf '%s' "$id" | tr ':/' '__')
[ -f "$dir/checks.json" ] || exit 3
r="$dir/results/$safe.json"
tree=$(pv_tree_sha "$root"); checks=$(pv_sha256 < "$dir/checks.json")
jq -e --arg p "$plan" --arg i "$id" --arg t "$tree" --arg c "$checks" '.plan == $p and .id == $i and .status == "PASS" and .tree_sha == $t and .checks_sha == $c' "$r" >/dev/null 2>&1 || { echo 'REFUSED: review requires current passing builder checks' >&2; exit 2; }
run=$(pv_run_dir "$root" "$plan"); mkdir -p "$run/reviews"
token="$(date +%s)-$$"
base=$(git -C "$root" rev-parse HEAD)
jq -nc --arg p "$plan" --arg i "$id" --arg t "$tree" --arg c "$checks" --arg b "$base" --arg token "$token"  '{schema_version:1,plan:$p,id:$i,tree_sha:$t,checks_sha:$c,base_commit:$b,review_id:$token}' > "$run/reviews/$safe.json"
printf '%s\n' "$token"
