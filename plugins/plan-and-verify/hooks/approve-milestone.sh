#!/usr/bin/env bash
# Record a user's explicit approval. This records an assertion, not authentication.
# approve-milestone.sh PLAN ID --by NAME --reason TEXT
set -eu
HOOKS="$(cd "$(dirname "$0")" && pwd)"
. "$HOOKS/evidence.sh"
plan=${1:-}; id=${2:-}; shift 2 || exit 3
by=''; reason=''
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || exit 3
  case "$1" in --by) by=$2 ;; --reason) reason=$2 ;; *) exit 3 ;; esac
  shift 2
done
pv_valid_ref "$plan" && pv_valid_ref "$id" && [ -n "$by" ] && [ -n "$reason" ] || { echo 'usage: approve-milestone.sh PLAN ID --by NAME --reason TEXT' >&2; exit 3; }
root=$(pv_root); dir="$root/.claude/build-plans/$plan"; safe=$(printf '%s' "$id" | tr ':/' '__')
pv_review_bound "$root" "$plan" "$id" || { echo 'REFUSED: a bound approving review is required' >&2; exit 2; }
tree=$(pv_tree_sha "$root"); checks=$(pv_sha256 < "$dir/checks.json")
jq -e --arg t "$tree" --arg c "$checks" '.tree_sha == $t and .checks_sha == $c' "$dir/results/$safe.review.json" >/dev/null || { echo 'REFUSED: stale review' >&2; exit 2; }
jq --arg by "$by" --arg reason "$reason" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"  '{schema_version:1,plan,id,review_id,tree_sha,checks_sha,base_commit,actor:"human",by:$by,reason:$reason,at:$at}'  "$dir/results/$safe.review.json" > "$dir/results/$safe.approval.json"
echo "approval recorded for $plan/$id"
