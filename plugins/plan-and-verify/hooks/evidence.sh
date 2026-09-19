#!/usr/bin/env bash
# Shared evidence checks; callers supply already validated plan/milestone IDs.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/state.sh"
# An approving, well-formed review record written by capture-review.sh. Callers compare
# its tree_sha/checks_sha with the current ones; this only says the record can authorize.
pv_review_bound() {
  local root="$1" plan="$2" id="$3" safe
  safe=$(printf '%s' "$id" | tr ':/' '__')
  jq -e --arg p "$plan" --arg i "$id" '.schema_version == 1 and .plan == $p and .id == $i
    and ([.review_id, .agent_id, .tree_sha, .checks_sha, .base_commit] | all(.[]; type == "string" and length > 0))
    and (.verdict == "ACCEPT" or .verdict == "ACCEPT-WITH-NOTES")' \
    "$root/.claude/build-plans/$plan/results/$safe.review.json" >/dev/null 2>&1
}

pv_human_required() {
  local p="$1" id="$2" tier mode irreversible
  tier=$(pv_milestone_field "$p" "$id" review | awk '{print $1}')
  [ "$tier" = 2 ] || return 1
  mode=$(awk '/^mode:/ {print $2; exit}' "$p")
  irreversible=$(pv_milestone_field "$p" "$id" irreversible | awk '{print $1}')
  [ "$mode" != autonomous ] || [ "$irreversible" != no ]
}

pv_approval_valid() {
  local d="$1" id="$2" safe
  safe=$(printf '%s' "$id" | tr ':/' '__')
  [ -f "$d/results/$safe.approval.json" ] && [ -f "$d/results/$safe.review.json" ] || return 1
  jq -e -s '.[0] as $a | .[1] as $r | $a.schema_version == 1 and $a.actor == "human"
    and ($a.by | type == "string" and length > 0) and ($a.reason | type == "string" and length > 0)
    and $a.plan == $r.plan and $a.id == $r.id and $a.review_id == $r.review_id
    and $a.tree_sha == $r.tree_sha and $a.checks_sha == $r.checks_sha
    and $a.base_commit == $r.base_commit' "$d/results/$safe.approval.json" "$d/results/$safe.review.json" >/dev/null 2>&1
}
