#!/usr/bin/env bash
# run-state.sh — bookkeeping for a run, especially an unattended one.
#
#   run-state.sh init <plan>              create <plan>/run/ (ignored, with its own .gitignore)
#   run-state.sh log <plan> <json>        append a decision entry (the orchestrator's own record)
#   run-state.sh record                   hook: store the session's permission mode (stdin JSON)
#
# Everything it writes lives in <plan>/run/, which ignores itself, so logging can never
# dirty the working tree, change a tree fingerprint, enter a snapshot or reach a commit.
# Two files matter:
#   decisions.jsonl   what the orchestrator decided and why (survives a context reset)
#   hook-events.jsonl what the enforcement hooks did — the heartbeat that tells an
#                     unattended run the difference between "the hook passed it" and
#                     "the hook never ran"
set -u
HOOKS="$(cd "$(dirname "$0")" && pwd)"
. "$HOOKS/lib.sh"
cmd="${1:-}"

case "$cmd" in
  init)
    plan="${2:-}"; [ -n "$plan" ] || { echo "usage: run-state.sh init <plan>" >&2; exit 3; }
    ROOT=$(pv_root)
    d=$(pv_run_dir "$ROOT" "$plan") || { echo "no plan directory for $plan" >&2; exit 3; }
    echo "${d#$ROOT/} ready" ;;

  log)
    plan="${2:-}"; obj="${3:-}"
    [ -n "$plan" ] && [ -n "$obj" ] || { echo "usage: run-state.sh log <plan> '<json object>'" >&2; exit 3; }
    jq -e . >/dev/null 2>&1 <<<"$obj" || { echo "log entry is not valid JSON" >&2; exit 3; }
    ROOT=$(pv_root)
    pv_log_event "$ROOT" "$plan" decisions "$obj"
    echo "logged" ;;

  record)
    # PreToolUse/PostToolUse hook. The plan-approval choice is not visible to any hook, so
    # the permission mode on the next hook event is the only signal for whether this
    # session can run unattended. Written for every plan that has a run directory.
    input=$(cat)
    [ -n "${CLAUDE_PROJECT_DIR:-}" ] || CLAUDE_PROJECT_DIR=$(jq -r '.cwd // "."' <<<"$input")
    ROOT=$(pv_root)
    mode=$(jq -r '.permission_mode // ""' <<<"$input")
    [ -n "$mode" ] || exit 0                      # not every event carries it
    for d in "$ROOT"/.claude/build-plans/*/run; do
      [ -d "$d" ] || continue
      jq -nc --arg m "$mode" --arg s "$(jq -r '.session_id // ""' <<<"$input")" \
            --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg cwd "$ROOT" \
        '{ts:$ts,session_id:$s,permission_mode:$m,cwd:$cwd}' > "$d/session.json" 2>/dev/null || true
    done
    exit 0 ;;

  *) sed -n '3,7p' "$0"; exit 3 ;;
esac
