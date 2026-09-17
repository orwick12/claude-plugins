#!/usr/bin/env bash
# accept-milestone.sh <plan-slug> <milestone-id> [<milestone-id> ...]
#
# The acceptance stamp. Refuses unless, for every id given:
#   - results/<id>.json exists, status is PASS, and it was produced by
#     run-checks.sh against the working tree as it is RIGHT NOW (tree_sha and
#     checks_sha match), so a stale or earlier PASS cannot authorise this code
#   - checks.json and hooks.lock are byte-identical to HEAD, every commit that
#     changed them after they were added is a "plan(<plan>): ..." commit, and the
#     installed scripts hash to what hooks.lock says (the plugin lives outside the
#     repo, so the committed lock is how git vouches for it)
# Then sets the milestone's status line in plan.md to DONE, commits the
# working tree as one milestone commit tagged "[<plan> <ids>]" in the subject,
# and prints one line. Find a milestone's commit with: git log --grep "\[<plan> <id>\]"
# Exit 0 accepted, 2 refused (reason on stderr), 3 usage/config.
set -u
HOOKS="$(cd "$(dirname "$0")" && pwd)"
. "$HOOKS/lib.sh"
ROOT=$(pv_root)
PLAN="${1:-}"; shift || true
[ -n "$PLAN" ] && [ $# -ge 1 ] || { echo "usage: accept-milestone.sh <plan> <id> [<id>...]" >&2; exit 3; }
DIR="$ROOT/.claude/build-plans/$PLAN"; CHECKS="$DIR/checks.json"; PLANMD="$DIR/plan.md"
command -v jq >/dev/null || { echo "jq required" >&2; exit 3; }
[ -f "$CHECKS" ] && [ -f "$PLANMD" ] || { echo "missing plan.md or checks.json in $DIR" >&2; exit 3; }
cd "$ROOT" || exit 3
git rev-parse HEAD >/dev/null 2>&1 || { echo "not a git repo with commits" >&2; exit 3; }

refuse() { echo "REFUSED: $*" >&2; exit 2; }

# 1. integrity: checks.json and hooks.lock unchanged since last commit, and the
#    installed scripts are the ones the plan was locked against
LOCK="$DIR/hooks.lock"
[ -f "$LOCK" ] || refuse "no hooks.lock for this plan; run: bash \"$HOOKS/lock-hooks.sh\" write $PLAN, commit it, then re-run the checks"
[ -z "$(git diff HEAD --name-only -- "$CHECKS" "$LOCK")" ] || refuse "checks.json or hooks.lock differs from HEAD; restore (git checkout HEAD -- <path>) and re-run the checks"
# "Equal to HEAD" alone lets a committed edit through, so only the planner's plan
# commits may change these files after the commit that first added each of them.
added=""
for f in "$CHECKS" "$LOCK"; do added="$added $(git log --diff-filter=A --format=%H -- "$f" | tail -1)"; done
foreign=$(git log --format='%H %h %s' -- "$CHECKS" "$LOCK" | while read -r full short subj; do
  # (pattern) form: Bash 3.2 cannot parse "pattern)" inside $( ).
  case " $added " in (*" $full "*) continue ;; esac
  case "$subj" in ("plan($PLAN):"*) ;; (*) printf '%s "%s"; ' "$short" "$subj" ;; esac
done)
[ -z "$foreign" ] || refuse "checks.json or hooks.lock was changed by a commit that is not a plan($PLAN) commit: $foreign Only the planner changes them, in a commit titled \"plan($PLAN): ...\". Stop and show the user."
bash "$HOOKS/lock-hooks.sh" verify "$PLAN" >/dev/null 2>&1 || refuse "installed plan-and-verify scripts do not match this plan's hooks.lock (plugin updated, or scripts tampered). If the update is intended: bash \"$HOOKS/lock-hooks.sh\" write $PLAN, commit, re-run the checks."

# 2. freshness: current working-tree fingerprint must equal the one in each result
checks_sha=$(pv_sha256 < "$CHECKS") || exit 3
tree_sha=$(pv_tree_sha "$ROOT") || exit 3
for id in "$@"; do
  r="$DIR/results/$(printf '%s' "$id" | tr ':/' '__').json"
  [ -f "$r" ] || refuse "no results file for $id; run bash \"$HOOKS\"/run-checks.sh $PLAN $id"
  st=$(jq -r .status "$r")
  [ "$st" = "PASS" ] || refuse "$id result is $st, not PASS"
  [ "$(jq -r .checks_sha "$r")" = "$checks_sha" ] || refuse "$id result was produced against a different checks.json; re-run the checks"
  [ "$(jq -r .tree_sha "$r")" = "$tree_sha" ] || refuse "$id result is stale: the working tree changed after the checks ran; re-run bash \"$HOOKS\"/run-checks.sh $PLAN $id"
done

# 3. project status into plan.md, then one commit (no amend, so the sha is final)
for id in "$@"; do
  awk -v id="$id" '
    $0 ~ "^### Milestone "id"$" {f=1}
    f && /^status:/ {print "status: DONE"; f=0; next}
    /^### Milestone / && $0 !~ "^### Milestone "id"$" {f=0}
    {print}' "$PLANMD" > "$PLANMD.tmp" && mv "$PLANMD.tmp" "$PLANMD"
done
[ -n "$(git status --porcelain)" ] || refuse "nothing to commit"
ids="$*"; first="$1"
goal=$(awk -v id="$first" '$0 ~ "^### Milestone "id"$" {f=1; next} f && /^goal:/ {sub(/^goal:[ \t]*/,""); print; exit}' "$PLANMD")
git add -A
git commit -q -m "milestone($ids): ${goal:-accepted} [$PLAN $ids]" -m "checks: $(for id in "$@"; do r="$DIR/results/$(printf '%s' "$id" | tr ':/' '__').json"; printf '%s pass=%s fail=%s run=%s; ' "$id" "$(jq -r .pass "$r")" "$(jq -r .fail "$r")" "$(jq -r .run_id "$r")"; done)" || refuse "git commit failed"
echo "ACCEPTED $PLAN [$ids] -> $(git rev-parse --short HEAD)"
