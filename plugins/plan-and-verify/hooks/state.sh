#!/usr/bin/env bash
# Shared state queries. Committed structured acceptance is authoritative; older
# releases are supported through literal parsing of their milestone commit subjects.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
pv_accepted() {
  local root="$1" plan="$2" id="$3" path record line sha subject ids base
  pv_valid_ref "$plan" && pv_valid_ref "$id" || return 1
  path=".claude/build-plans/$plan/results/$(printf '%s' "$id" | tr ':/' '__').accepted.json"
  if git -C "$root" cat-file -e "HEAD:$path" 2>/dev/null; then
    record=$(git -C "$root" show "HEAD:$path" 2>/dev/null) || return 1
    jq -e --arg p "$plan" --arg i "$id" '.schema_version == 1 and .plan == $p and .id == $i
      and ([.base_commit,.tree_sha,.checks_sha] | all(.[]; type == "string" and length > 0))' >/dev/null 2>&1 <<<"$record" || return 1
    base=$(jq -r .base_commit <<<"$record")
    git -C "$root" merge-base --is-ancestor "$base" HEAD 2>/dev/null || return 1
    git -C "$root" log -1 --format='%h %s' -- "$path"
    return 0
  fi
  while IFS= read -r line; do
    sha=${line%% *}; subject=${line#* }
    case "$subject" in 'milestone('*'):'*) ;; *) continue ;; esac
    ids=${subject#milestone(}; ids=${ids%%):*}
    case "$subject" in *"[$plan $ids]") ;; *) continue ;; esac
    case " $ids " in *" $id "*) printf '%s %s\n' "$sha" "$subject"; return 0 ;; esac
  done < <(git -C "$root" log --format='%h %s' 2>/dev/null)
  return 1
}

pv_pending_dependencies() {
  local root="$1" plan="$2" id="$3" dep deps
  deps=$(pv_milestone_field "$root/.claude/build-plans/$plan/plan.md" "$id" depends-on)
  deps=${deps%%#*}
  for dep in $(printf '%s' "$deps" | tr ',[]' '   '); do
    case "$dep" in none|None|NONE) continue ;; esac
    pv_accepted "$root" "$plan" "$dep" >/dev/null || printf '%s\n' "$dep"
  done
}
