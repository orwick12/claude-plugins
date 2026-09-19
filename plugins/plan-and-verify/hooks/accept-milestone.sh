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
# Required review, approval, dependency and prior-phase evidence must also hold.
# Then sets the milestone's status line in plan.md to DONE, commits the
# working tree as one milestone commit tagged "[<plan> <ids>]" in the subject,
# and prints one line. Query completion with: run-state.sh accepted <plan> <id>
# Exit 0 accepted, 2 refused (reason on stderr), 3 usage/config.
set -u
HOOKS="$(cd "$(dirname "$0")" && pwd)"
. "$HOOKS/evidence.sh"
ROOT=$(pv_root)
PLAN="${1:-}"; shift || true
[ -n "$PLAN" ] && [ $# -ge 1 ] || { echo "usage: accept-milestone.sh <plan> <id> [<id>...]" >&2; exit 3; }
NIDS=$#
pv_valid_ref "$PLAN" || { echo 'invalid plan id' >&2; exit 3; }
for id in "$@"; do pv_valid_ref "$id" || { echo 'invalid milestone id' >&2; exit 3; }; done
DIR="$ROOT/.claude/build-plans/$PLAN"; CHECKS="$DIR/checks.json"; PLANMD="$DIR/plan.md"
command -v jq >/dev/null || { echo "jq required" >&2; exit 3; }
[ -f "$CHECKS" ] && [ -f "$PLANMD" ] || { echo "missing plan.md or checks.json in $DIR" >&2; exit 3; }
cd "$ROOT" || exit 3
git rev-parse HEAD >/dev/null 2>&1 || { echo "not a git repo with commits" >&2; exit 3; }

refuse() {
  pv_log_event "$ROOT" "$PLAN" hook-events \
    "$(jq -nc --arg ids "$*" --arg id "${1:-}" '{actor:"hook:accept-milestone",outcome:"refused",detail:$ids}')"
  echo "REFUSED: $*" >&2; exit 2
}

# 1. integrity: checks.json and hooks.lock unchanged since last commit, and the
#    installed scripts are the ones the plan was locked against
LOCK="$DIR/hooks.lock"
[ -f "$LOCK" ] || refuse "no hooks.lock for this plan; run: bash \"$HOOKS/lock-hooks.sh\" write $PLAN, commit it, then re-run the checks"
[ -z "$(git diff HEAD --name-only -- "$CHECKS" "$LOCK" "$PLANMD")" ] || refuse "plan.md, checks.json or hooks.lock differs from HEAD; restore (git checkout HEAD -- <path>) and re-run the checks"
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
  jq -e --arg p "$PLAN" --arg i "$id" '.plan == $p and .id == $i' "$r" >/dev/null 2>&1 || refuse "$id result belongs to another plan or milestone"
  [ "$(jq -r .checks_sha "$r")" = "$checks_sha" ] || refuse "$id result was produced against a different checks.json; re-run the checks"
  # More than one id is a parallel group: its members edit the tree while each other's
  # checks run, so the first to finish always goes stale. Only a re-run after the LAST
  # member finished speaks for the tree this commit would carry.
  group_hint=""
  [ $NIDS -gt 1 ] && group_hint=" For a parallel group, re-run every member's checks after the last member finishes, then accept the group in one call."
  [ "$(jq -r .tree_sha "$r")" = "$tree_sha" ] || refuse "$id result is stale: the working tree changed after the checks ran; re-run bash \"$HOOKS\"/run-checks.sh $PLAN $id.$group_hint"
done

# 3. the branch must still be where this milestone was spawned from. The spawn snapshot's
#    parent is HEAD at spawn time; between spawn and acceptance only the planner commits,
#    so any other commit in that range is foreign however its subject reads.
for id in "$@"; do
  sref=$(git for-each-ref --sort=-refname --format='%(refname)' "refs/pv/snapshots/$PLAN/$id/" | grep -- '-spawn$' | head -1)
  [ -n "$sref" ] || continue                      # no snapshot: a manual run, nothing to anchor to
  sparent=$(git rev-parse -q --verify "$sref^" 2>/dev/null) || continue
  moved=$(git log --format='%h %s' "$sparent..HEAD" | while read -r short subj; do
    case "$subj" in ("plan($PLAN):"*) ;; (*) printf '%s "%s"; ' "$short" "$subj" ;; esac
  done)
  [ -z "$moved" ] || refuse "HEAD has moved since $id was spawned, by a commit that is not a plan($PLAN) commit: $moved Builders never commit and only the planner commits mid-milestone. Stop and show the user."
  # A plan title is not provenance. Every intervening commit must actually be
  # limited to the approved plan/check/lock files, never source or other evidence.
  for revision in $(git rev-list "$sparent..HEAD"); do
    parents=$(git rev-list --parents -n 1 "$revision" | wc -w | tr -d ' ')
    [ "$parents" -le 2 ] || refuse "merge commit $revision occurred during milestone $id"
    while IFS= read -r -d '' changed; do
      case "$changed" in
        ".claude/build-plans/$PLAN/plan.md"|".claude/build-plans/$PLAN/checks.json"|".claude/build-plans/$PLAN/hooks.lock") ;;
        *) refuse "plan commit $revision changed source or non-plan file: $changed" ;;
      esac
    done < <(git diff-tree --no-commit-id --name-only -r -z "$revision")
  done
done

# 4. nothing from another plan rides along in this milestone's commit
stray=$(git status --porcelain --untracked-files=all -- .claude/build-plans |
        sed 's/^...//' | grep -v "^\.claude/build-plans/$PLAN/" | tr '\n' ' ')
[ -z "$stray" ] || refuse "these files are under .claude/build-plans but do not belong to plan $PLAN: $stray A milestone commit carries this plan's work only. Remove them, or commit them yourself as a plan(<slug>) commit, then re-run the checks."

# 5. Policy and evidence: the orchestrator cannot waive these by omitting a review.
for id in "$@"; do
  tier=$(pv_milestone_field "$PLANMD" "$id" review | awk '{print $1}')
  case "$tier" in 0|1|2) ;; *) refuse "$id is missing a valid review policy (0, 1 or 2)" ;; esac
  pending=$(pv_pending_dependencies "$ROOT" "$PLAN" "$id")
  [ -z "$pending" ] || refuse "$id has unaccepted dependencies: $pending"
  safe=$(printf '%s' "$id" | tr ':/' '__')
  if [ "$tier" != 0 ]; then
    pv_review_bound "$ROOT" "$PLAN" "$id" || refuse "$id requires a valid bound approving review"
    jq -e --arg t "$tree_sha" --arg c "$checks_sha" \
      '.tree_sha == $t and .checks_sha == $c' "$DIR/results/$safe.review.json" >/dev/null || refuse "$id review is stale"
    if pv_human_required "$PLANMD" "$id"; then
      pv_approval_valid "$DIR" "$id" || refuse "$id requires explicit recorded human approval (approve-milestone.sh)"
    fi
  fi
  phase=${id%%.*}
  case "$phase" in ''|*[!0-9]*) refuse "$id has no numeric phase" ;; esac
  for gate in $(jq -r --argjson p "$phase" '.gates // {} | keys[] | select(test("^[0-9]+$")) | select(tonumber < $p)' "$CHECKS"); do
    gatefile="$DIR/results/gate_$gate.json"
    jq -e --arg c "$checks_sha" --arg p "$PLAN" --arg i "gate:$gate" '.plan == $p and .id == $i and .status == "PASS" and .checks_sha == $c and (.base_commit | type == "string" and length > 0)' "$gatefile" >/dev/null 2>&1 || refuse "phase $gate gate has no passing evidence for these checks"
    gatebase=$(jq -r .base_commit "$gatefile")
    git merge-base --is-ancestor "$gatebase" HEAD 2>/dev/null || refuse "phase $gate gate belongs to another history"
    expected_gate_sha=$(pv_committed_sha "$ROOT" "$gatebase") || refuse "phase $gate gate revision cannot be inspected"
    [ "$(jq -r .tree_sha "$gatefile")" = "$expected_gate_sha" ] || refuse "phase $gate gate was not run against its clean accepted revision"
    # A gate is run on an accepted phase, not on an uncommitted proposed milestone.
    for prior in $(grep -oE '^### Milestone [A-Za-z0-9._:-]+' "$PLANMD" | awk '{print $3}'); do
      [ "${prior%%.*}" = "$gate" ] || continue
      accepted=$(pv_accepted "$ROOT" "$PLAN" "$prior") || refuse "phase $gate still has unaccepted milestone $prior"
      git merge-base --is-ancestor "${accepted%% *}" "$gatebase" 2>/dev/null || refuse "phase $gate gate predates acceptance of $prior"
    done
  done
done

# Structured accepted records are committed with the artifact. They retain which
# checks/review/approval authorized it; Markdown status and commit subjects are views.
for id in "$@"; do
  safe=$(printf '%s' "$id" | tr ':/' '__')
  review=null; approval=null
  [ ! -f "$DIR/results/$safe.review.json" ] || review=$(cat "$DIR/results/$safe.review.json")
  [ ! -f "$DIR/results/$safe.approval.json" ] || approval=$(cat "$DIR/results/$safe.approval.json")
  jq -nc --arg p "$PLAN" --arg i "$id" --arg b "$(git rev-parse HEAD)" \
    --arg t "$tree_sha" --arg c "$checks_sha" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson checks "$(cat "$DIR/results/$safe.json")" --argjson r "$review" --argjson a "$approval" \
    '{schema_version:1,plan:$p,id:$i,base_commit:$b,tree_sha:$t,checks_sha:$c,at:$at,
      check_run:$checks,review:$r,approval:$a}' > "$DIR/results/$safe.accepted.json" || refuse 'cannot record acceptance'
done

# 6. project status into plan.md, then one commit (no amend, so the sha is final)
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
git add -A -- . ':!.claude/build-plans'   # the project's work
git add -A -- ".claude/build-plans/$PLAN" # and this plan's own files, never another's
git commit -q -m "milestone($ids): ${goal:-accepted} [$PLAN $ids]" -m "checks: $(for id in "$@"; do r="$DIR/results/$(printf '%s' "$id" | tr ':/' '__').json"; printf '%s pass=%s fail=%s run=%s; ' "$id" "$(jq -r .pass "$r")" "$(jq -r .fail "$r")" "$(jq -r .run_id "$r")"; done)" || refuse "git commit failed"
sha=$(git rev-parse --short HEAD)
# The milestone is finished, so its open marker is retired here and nowhere else: a stop
# only pauses a builder, and the guard has to keep denying the next one until this commit
# exists (F46). A group is accepted in one call, so every id in it clears at once.
for id in "$@"; do rm -f "$DIR/run/open/$(printf '%s' "$id" | tr ':/' '__').json"; done
pv_log_event "$ROOT" "$PLAN" hook-events \
  "$(jq -nc --arg id "$ids" --arg sha "$sha" '{actor:"hook:accept-milestone",id:$id,outcome:"accepted",detail:$sha}')"
echo "ACCEPTED $PLAN [$ids] -> $sha"
