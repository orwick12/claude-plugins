#!/usr/bin/env bash
# snapshot.sh <plan> <milestone-id> [label]       -> take a snapshot, print its ref
# snapshot.sh list <plan> [milestone-id]          -> list snapshots, newest last
# snapshot.sh diff <ref>                          -> what changed in the tree since <ref>
# snapshot.sh restore <ref>                       -> DESTRUCTIVE: make the tree match <ref>
#
# A snapshot is a commit object of the whole working tree (tracked changes and
# untracked files, minus ignored files and results/) stored under
# refs/pv/snapshots/<plan>/<id>/<n>-<label>. It is built through a temporary
# index, so it never touches the branch, the real index, the working tree or
# the review diff. It is the undo for a builder's uncommitted work.
#
# Builders may run this (it is a bash script, not a git subcommand the guard
# blocks). Only the main agent runs restore, and only with the user's approval.
set -u
HOOKS="$(cd "$(dirname "$0")" && pwd)"
. "$HOOKS/lib.sh"
ROOT=$(pv_root); cd "$ROOT" || exit 3
git rev-parse HEAD >/dev/null 2>&1 || { echo "not a git repo with commits" >&2; exit 3; }

cmd="${1:-}"
case "$cmd" in
  list)
    plan="${2:-}"; id="${3:-}"; [ -n "$plan" ] || { echo "usage: snapshot.sh list <plan> [id]" >&2; exit 3; }
    git for-each-ref --sort=creatordate --format='%(refname:short)  %(creatordate:iso-strict)  %(subject)' "refs/pv/snapshots/$plan/${id:+$id/}" ;;
  diff)
    ref="${2:-}"; [ -n "$ref" ] || { echo "usage: snapshot.sh diff <ref>" >&2; exit 3; }
    tmp=$(mktemp); cp .git/index "$tmp" 2>/dev/null || true
    GIT_INDEX_FILE="$tmp" git add -A -- . ':!*/results/*' 2>/dev/null
    now=$(GIT_INDEX_FILE="$tmp" git write-tree); rm -f "$tmp"
    git diff --stat "$ref" "$now"; echo; git diff "$ref" "$now" ;;
  restore)
    ref="${2:-}"; [ -n "$ref" ] || { echo "usage: snapshot.sh restore <ref>" >&2; exit 3; }
    git rev-parse --verify -q "$ref^{commit}" >/dev/null || { echo "no such snapshot: $ref" >&2; exit 3; }
    [ "${PV_CONFIRM_RESTORE:-}" = "yes" ] || { echo "restore is destructive. Re-run with PV_CONFIRM_RESTORE=yes after the user approves." >&2; exit 2; }
    # Bring tracked+untracked files back to the snapshot. Results dirs are not in
    # snapshots, so park them and put them back afterwards.
    park=$(mktemp -d)
    for d in .claude/build-plans/*/results; do [ -d "$d" ] && mkdir -p "$park/$d" && cp -R "$d/." "$park/$d/"; done
    git ls-files --others --exclude-standard | grep -v '/results/' | while IFS= read -r f; do rm -f -- "$f"; done
    git read-tree --reset -u "$ref" || { echo "restore failed" >&2; exit 1; }
    git reset -q  # index back to HEAD so the review diff is intact
    (cd "$park" && find . -type d -name results) | while IFS= read -r d; do mkdir -p "$d" && cp -R "$park/$d/." "$d/"; done
    rm -rf "$park"
    echo "restored working tree to $ref" ;;
  ""|-h|--help) sed -n '2,8p' "$0"; exit 3 ;;
  *)
    plan="$cmd"; id="${2:-}"; label="${3:-manual}"
    [ -n "$id" ] || { echo "usage: snapshot.sh <plan> <id> [label]" >&2; exit 3; }
    tmp=$(mktemp); cp .git/index "$tmp" 2>/dev/null || true
    GIT_INDEX_FILE="$tmp" git add -A -- . ':!*/results/*' 2>/dev/null
    tree=$(GIT_INDEX_FILE="$tmp" git write-tree); rm -f "$tmp"
    base="refs/pv/snapshots/$plan/$id"
    n=$(git for-each-ref --format='%(refname)' "$base/" | wc -l | tr -d ' '); n=$((n+1))
    label=$(printf '%s' "$label" | tr -c 'A-Za-z0-9_-' '_')
    ref="$base/$(printf '%03d' "$n")-$label"
    # Skip if identical to the previous snapshot
    prevref=$(git for-each-ref --sort=-refname --format='%(refname)' "$base/" | head -1)
    if [ -n "$prevref" ] && [ "$(git rev-parse "$prevref^{tree}")" = "$tree" ]; then
      echo "unchanged since ${prevref#refs/}"; exit 0
    fi
    c=$(GIT_AUTHOR_NAME=plan-and-verify GIT_AUTHOR_EMAIL=pv@local GIT_COMMITTER_NAME=plan-and-verify GIT_COMMITTER_EMAIL=pv@local \
        git commit-tree "$tree" -p HEAD -m "snapshot $plan/$id $label")
    git update-ref "$ref" "$c"
    echo "$ref" ;;
esac
