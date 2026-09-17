#!/usr/bin/env bash
# capture-report.sh — PostToolUse hook on SubagentHandback.
#
# A background builder delivers its report by calling SubagentHandback, and that tool
# delivers ONE report per run: if the finish hook then sends the builder back, its
# corrected report can never reach the orchestrator through the same channel. This hook
# stores every builder hand-back next to the milestone's results, so the report is always
# readable from disk. verify-milestone.sh overwrites it with the version it actually
# verified when the builder stops.
#
# Silent on every path: it is a recorder, not a gate. Not a builder, not a hand-back, no
# MILESTONE line, or a plan this project does not have -> it does nothing.
set -u
HOOKS="$(cd "$(dirname "$0")" && pwd)"
. "$HOOKS/lib.sh"
input=$(cat)
pv_is_builder "$(jq -r '.agent_type // ""' <<<"$input")" || exit 0
[ "$(jq -r '.tool_name // ""' <<<"$input")" = "SubagentHandback" ] || exit 0
msg=$(jq -r '.tool_input.message // ""' <<<"$input")
ref=$(pv_report_ref "$msg")
[ -n "$ref" ] || exit 0
[ -n "${CLAUDE_PROJECT_DIR:-}" ] || CLAUDE_PROJECT_DIR=$(jq -r '.cwd // "."' <<<"$input")
pv_write_report "$(pv_root)" "${ref%%/*}" "${ref#*/}" "handback, delivered to the caller" \
  "$(jq -r '.agent_id // ""' <<<"$input")" "$msg"
exit 0
