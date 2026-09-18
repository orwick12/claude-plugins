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
    # Every plan, not only those that already have a run directory: the first tool call of
    # a session comes before anything has made one, and a preflight with no session record
    # would report a mode mismatch to a session that is in exactly the right mode.
    for p in "$ROOT"/.claude/build-plans/*/plan.md; do
      [ -f "$p" ] || continue
      slug=$(basename "$(dirname "$p")")
      d=$(pv_run_dir "$ROOT" "$slug") || continue
      jq -nc --arg m "$mode" --arg s "$(jq -r '.session_id // ""' <<<"$input")" \
            --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg cwd "$ROOT" \
        '{ts:$ts,session_id:$s,permission_mode:$m,cwd:$cwd}' > "$d/session.json" 2>/dev/null || true
    done
    exit 0 ;;

  milestone)
    # One work order, so a fresh-context orchestrator never reads the whole plan.
    plan="${2:-}"; id="${3:-}"
    [ -n "$plan" ] && [ -n "$id" ] || { echo "usage: run-state.sh milestone <plan> <id>" >&2; exit 3; }
    ROOT=$(pv_root); P="$ROOT/.claude/build-plans/$plan/plan.md"
    [ -f "$P" ] || { echo "no plan.md for $plan" >&2; exit 3; }
    awk -v id="$id" '
      $0 == "### Milestone " id {f=1; print; next}
      f && /^### Milestone / {exit}
      f && /^## / {exit}
      f {print}' "$P" ;;

  brief)
    # Where this plan stands, rebuilt from the repository: git for what is accepted,
    # plan.md for what was intended, the run log for what was decided. Anything that
    # cannot be rebuilt this way cannot be trusted after a context reset.
    plan="${2:-}"; [ -n "$plan" ] || { echo "usage: run-state.sh brief <plan>" >&2; exit 3; }
    ROOT=$(pv_root); dir="$ROOT/.claude/build-plans/$plan"; P="$dir/plan.md"
    [ -f "$P" ] || { echo "no plan.md for $plan" >&2; exit 3; }
    want=$(grep -oE '^mode:[[:space:]]*[a-z]+' "$P" | head -1 | awk '{print $2}'); [ -n "$want" ] || want=supervised
    have=unknown
    [ -f "$dir/run/session.json" ] && have=$(jq -r '.permission_mode // "unknown"' "$dir/run/session.json" 2>/dev/null)
    branch=$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo none)
    echo "plan $plan  mode: $want  session: $have  branch: $branch"
    tag=$(git -C "$ROOT" tag --list "plan/$plan/phase-*" 2>/dev/null | sort | tail -1)
    [ -n "$tag" ] && echo "phases passed: $tag"
    next=""
    for id in $(grep -oE '^### Milestone [A-Za-z0-9._:-]+' "$P" | awk '{print $3}'); do
      c=$(git -C "$ROOT" log --oneline --grep "\[$plan $id\]" 2>/dev/null | head -1)
      if [ -n "$c" ]; then printf '  %-6s accepted  %s\n' "$id" "$c"
      else printf '  %-6s pending\n' "$id"; [ -n "$next" ] || next=$id
      fi
    done
    [ -n "$next" ] && echo "next: $next" || echo "next: none (every milestone has a commit)"
    # Every milestone with a marker: open (a builder is writing) or stopped (a builder
    # finished a run but the milestone is not accepted, so the next one still waits).
    hdr=""
    for m in "$dir"/run/open/*.json; do
      [ -f "$m" ] || continue
      [ -n "$hdr" ] || { echo "open builders:"; hdr=1; }
      IFS=$(printf '\t') read -r mid mst mat <<EOF
$(jq -r '[(.id // "?"), (.state // "open"), (.agent_type // "?")] | @tsv' "$m" 2>/dev/null)
EOF
      printf '  %-6s %-7s %s\n' "$mid" "$mst" "$mat"
    done
    d="$dir/run/decisions.jsonl"
    if [ -f "$d" ]; then
      echo "last decisions:"
      tail -20 "$d" | jq -r '"  " + .ts + "  " + (.event // "?") + " " + (.id // "-") +
                             (if .class then " [class " + .class + "]" else "" end) +
                             "  " + (.decision // .trigger // "")' 2>/dev/null
    fi
    e="$dir/run/hook-events.jsonl"
    if [ -f "$e" ]; then
      echo "last enforcement events:"
      tail -10 "$e" | jq -r '"  " + .ts + "  " + (.actor // "?") + " " + (.id // "-") + " " + (.outcome // "")' 2>/dev/null
    fi ;;

  clear-open)
    # A marker is the only thing between the next spawn and a second writer in this tree,
    # so clearing one is recovery, not housekeeping. A stopped builder's marker goes
    # freely; a live one is refused unless PV_CONFIRM_CLEAR=yes says its session is dead;
    # one older than six hours is a leftover whatever it claims. With no id, every stopped
    # marker goes and a live one is merely reported.
    plan="${2:-}"; id="${3:-}"
    [ -n "$plan" ] || { echo "usage: run-state.sh clear-open <plan> [<id>]" >&2; exit 3; }
    ROOT=$(pv_root); d=$(pv_run_dir "$ROOT" "$plan") || exit 3
    now=$(date +%s); rc=0; cleared=0
    clear_one() {                                   # <marker> <strict|keep>
      local m="$1" strict="$2" mid st at
      mid=$(jq -r '.id // ""' "$m" 2>/dev/null); [ -n "$mid" ] || mid=$(basename "$m" .json)
      st=$(jq -r '.state // "open"' "$m" 2>/dev/null)
      at=$(jq -r '.epoch // 0' "$m" 2>/dev/null); case "$at" in ''|*[!0-9]*) at=0 ;; esac
      if [ "$st" != "stopped" ] && [ $((now - at)) -lt 21600 ] && [ "${PV_CONFIRM_CLEAR:-}" != "yes" ]; then
        if [ "$strict" = strict ]; then
          echo "REFUSED: milestone $mid still has an open builder (spawned $(( (now - at) / 60 )) minutes ago). Wait for it to stop. If the session that owned it is dead, re-run with PV_CONFIRM_CLEAR=yes." >&2
          rc=2
        else
          echo "kept $mid (still open; clear it by id with PV_CONFIRM_CLEAR=yes if its session is dead)"
        fi
        return 0
      fi
      rm -f "$m"; cleared=$((cleared + 1)); echo "cleared $mid ($st)"
    }
    if [ -n "$id" ]; then
      m=$(pv_marker_path "$d" "$id")
      [ -f "$m" ] || { echo "no open-builder marker for $id in $plan"; exit 0; }
      clear_one "$m" strict
    else
      for m in "$d"/open/*.json; do [ -f "$m" ] || continue; clear_one "$m" keep; done
      [ "$cleared" -gt 0 ] || echo "no stopped builders to clear in $plan"
    fi
    exit $rc ;;

  post)
    # PostToolUse hook on Agent. For a builder this fires at SPAWN time: Claude Code's
    # Agent tool is asynchronous, so this hook runs before the builder has done anything.
    # A results file only speaks for THIS spawn once it postdates it; agent-guard.sh's
    # marker for this milestone (run/open/<id>.json, written at spawn) is the only
    # record of when that was. Older or missing results are the previous run's, or none,
    # and the line has to say so instead of handing the orchestrator a stale verdict.
    input=$(cat)
    [ "$(jq -r '.tool_name // ""' <<<"$input")" = "Agent" ] || exit 0
    sub=$(jq -r '.tool_input.subagent_type // ""' <<<"$input")
    pv_is_builder "$sub" || exit 0
    prompt=$(jq -r '.tool_input.prompt // ""' <<<"$input")
    ref=$(grep -oE '^Plan:[[:space:]]*[A-Za-z0-9._-]+[[:space:]]+Milestone:[[:space:]]*[A-Za-z0-9._:-]+' <<<"$prompt" | head -1)
    [ -n "$ref" ] || exit 0
    plan=$(sed -E 's/^Plan:[[:space:]]*([A-Za-z0-9._-]+).*/\1/' <<<"$ref")
    mid=$(sed -E 's/.*Milestone:[[:space:]]*([A-Za-z0-9._:-]+).*/\1/' <<<"$ref")
    [ -n "${CLAUDE_PROJECT_DIR:-}" ] || CLAUDE_PROJECT_DIR=$(jq -r '.cwd // "."' <<<"$input")
    ROOT=$(pv_root)
    dir="$ROOT/.claude/build-plans/$plan"
    [ -f "$dir/checks.json" ] || exit 0
    safe=$(printf '%s' "$mid" | tr ':/' '__')
    res="$dir/results/$safe.json"
    rundir=$(pv_run_dir "$ROOT" "$plan")
    marker=$(pv_marker_path "$rundir" "$mid")

    spawn_epoch=""
    [ -f "$marker" ] && spawn_epoch=$(jq -r '.epoch // ""' "$marker" 2>/dev/null)
    if [ -n "$spawn_epoch" ]; then
      post_spawn=0
      if [ -f "$res" ]; then
        # fromdateiso8601 needs ran_at exactly as run-checks.sh writes it; anything else
        # (or a missing field) fails the parse, and an unparsable value counts as pre-spawn.
        ran_epoch=$(jq -r '(.ran_at // "") as $r | if $r == "" then "" else ($r|fromdateiso8601) end' "$res" 2>/dev/null)
        case "$ran_epoch" in
          ''|*[!0-9]*) ;;
          *) [ "$ran_epoch" -gt "$spawn_epoch" ] && post_spawn=1 ;;
        esac
      fi
      if [ "$post_spawn" -eq 0 ]; then
        jq -nc --arg c "pv: $plan/$mid builder spawned; this line is spawn-time and carries no verdict. Wait for the builder's completion notification, then read .claude/build-plans/$plan/results/$safe.json (status is the truth) and confirm a hook:verify-milestone line for $mid in .claude/build-plans/$plan/run/hook-events.jsonl." \
          '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$c}}'
        exit 0
      fi
    fi

    status=MISSING; [ -f "$res" ] && status=$(jq -r '.status // "MISSING"' "$res" 2>/dev/null)
    beats="$rundir/hook-events.jsonl"
    hb=no
    if [ -f "$beats" ] && [ "$(jq -s -r --arg id "$mid" \
         'any(.[]; .actor == "hook:verify-milestone" and .id == $id)' "$beats" 2>/dev/null)" = true ]; then hb=yes; fi
    att=0; [ -f "$dir/results/$safe.attempts" ] && att=$(awk '{print $NF}' "$dir/results/$safe.attempts" 2>/dev/null)
    jq -nc --arg c "pv: $plan/$mid results=$status heartbeat=$hb attempts=${att:-0}. The results file is the truth; the builder's report is commentary. Its verified report is in .claude/build-plans/$plan/results/$safe.report.md" \
      '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$c}}'
    exit 0 ;;

  lint-checks)
    # An acceptance check is a shell command run by run-checks.sh, not a tool call, so no
    # PreToolUse guard ever sees it. Unattended, that is the one place a destructive
    # command could run unnoticed, so refuse the obvious ones before the run starts.
    plan="${2:-}"; [ -n "$plan" ] || { echo "usage: run-state.sh lint-checks <plan>" >&2; exit 3; }
    ROOT=$(pv_root); C="$ROOT/.claude/build-plans/$plan/checks.json"
    [ -f "$C" ] || { echo "no checks.json for $plan" >&2; exit 3; }
    bad=0
    while IFS=$'\t' read -r where name cmd; do
      # A check that makes its own temp directory may clean it up: that is the clean-clone
      # pattern the reference recommends, and refusing it would push people to write
      # weaker checks. Only the cleanup of a variable holding mktemp's output is exempt.
      scan=$cmd
      case "$scan" in
        *"mktemp -d"*) scan=$(printf '%s' "$scan" | sed -E 's/rm[[:space:]]+-[rf][rf][[:space:]]+"?\$\{?[A-Za-z_][A-Za-z0-9_]*\}?"?//g') ;;
      esac
      hit=0
      case "$scan" in
        *"rm -rf"*|*"rm -fr"*|*"git clean"*|*"git reset --hard"*|*"git push"*|*"DROP TABLE"*|*"DROP DATABASE"*|\
        *"TRUNCATE"*|*dropdb*|*"kubectl delete"*|*"terraform apply"*|*"terraform destroy"*|*"aws s3 rm"*|*"> .env"*)
          hit=1 ;;
      esac
      # A bare pipe into sh/bash, matched as a whole word so a longer command that merely
      # contains the letters (shasum, sha256sum, bashful, ...) is not caught by the substring.
      printf '%s' "$scan" | grep -qE '\|[[:space:]]*(sh|bash)([[:space:]]|$)' && hit=1
      if [ "$hit" -eq 1 ]; then
        printf 'DESTRUCTIVE  %s %s: %s\n' "$where" "$name" "$cmd"; bad=1
      fi
    done <<EOF
$(jq -r '(.milestones // {} | to_entries[] | .key as $k | .value.checks[]? | [$k, .name, .cmd]),
         (.gates // {} | to_entries[] | ("gate:" + .key) as $k | .value.checks[]? | [$k, .name, .cmd])
         | @tsv' "$C" 2>/dev/null)
EOF
    [ "$bad" -eq 0 ] && { echo "checks lint ok"; exit 0; }
    echo "Refusing autonomous mode: a check would run a destructive command. Fix it in a plan($plan) commit, or run supervised." >&2
    exit 2 ;;

  preflight)
    # Everything that must hold before a milestone runs, ending in the one comparison the
    # harness cannot make for us: the mode the plan asks for against the mode this session
    # is actually in. No hook can see which plan-approval option the user chose.
    plan="${2:-}"; [ -n "$plan" ] || { echo "usage: run-state.sh preflight <plan>" >&2; exit 3; }
    ROOT=$(pv_root); dir="$ROOT/.claude/build-plans/$plan"
    [ -f "$dir/plan.md" ] && [ -f "$dir/checks.json" ] || { echo "no plan at ${dir#$ROOT/}" >&2; exit 3; }
    fail=0
    say() { printf '%-6s %s\n' "$1" "$2"; [ "$1" = "FAIL" ] && fail=1; return 0; }
    jq -e . "$dir/checks.json" >/dev/null 2>&1 && say ok "checks.json parses" || say FAIL "checks.json is not valid JSON"
    if git -C "$ROOT" rev-parse HEAD >/dev/null 2>&1; then
      [ -z "$(git -C "$ROOT" status --porcelain)" ] && say ok "working tree is clean" || say FAIL "working tree is dirty: commit or clean it before building"
    else say FAIL "not a git repo with commits"; fi
    if bash "$HOOKS/lock-hooks.sh" verify "$plan" >/dev/null 2>&1; then say ok "hooks match hooks.lock"
    else say FAIL "hooks.lock does not match the installed scripts: re-lock and commit as plan($plan): re-lock"; fi
    missing=""
    for id in $(grep -oE '^### Milestone [A-Za-z0-9._:-]+' "$dir/plan.md" | awk '{print $3}'); do
      jq -e --arg i "$id" '.milestones[$i].checks | length > 0' "$dir/checks.json" >/dev/null 2>&1 || missing="$missing $id"
    done
    [ -z "$missing" ] && say ok "every milestone has checks" || say FAIL "milestones with no checks:$missing"
    pv_run_dir "$ROOT" "$plan" >/dev/null && say ok "run directory ready" || say FAIL "cannot create the run directory"

    # Parallel groups: the guard lets the members of one group write this tree at the same
    # time, so a group that is not really a group is how two builders collide. A member
    # needs company, a phase in common (a group runs inside one phase) and its own scope.
    # Only printed when the plan uses a group at all; most plans never do.
    groups=""
    for id in $(grep -oE '^### Milestone [A-Za-z0-9._:-]+' "$dir/plan.md" | awk '{print $3}'); do
      g=$(pv_parallel_group "$dir/plan.md" "$id")
      [ -n "$g" ] || continue
      sc=yes; [ -n "$(pv_milestone_field "$dir/plan.md" "$id" scope)" ] || sc=no
      groups="$groups$g $id ${id%%.*} $sc
"
    done
    if [ -n "$groups" ]; then
      bad=$(printf '%s' "$groups" | awk '
        { n[$1]++; members[$1] = members[$1] " " $2
          if (first[$1] == "") first[$1] = $3; else if ($3 != first[$1]) cross[$1] = 1
          if ($4 == "no") noscope[$1] = noscope[$1] " " $2 }
        END { for (g in n) {
                if (n[g] < 2)         printf "group %s has only one member (%s)\n", g, members[g]
                if (cross[g])         printf "group %s spans phases:%s\n", g, members[g]
                if (noscope[g] != "") printf "group %s has members with no scope:%s\n", g, noscope[g]
        } }' | LC_ALL=C sort | tr '\n' ';' | sed 's/;/; /g')
      [ -z "$bad" ] && say ok "parallel groups well-formed" \
        || say FAIL "parallel groups malformed: ${bad%%; }A group is two or more milestones in one phase, each with its own scope, edited at the same time by the guard's permission."
    fi

    want=$(grep -oE '^mode:[[:space:]]*[a-z]+' "$dir/plan.md" | head -1 | awk '{print $2}')
    [ -n "$want" ] || want=supervised
    have=$(jq -r '.permission_mode // "unknown"' "$(pv_run_dir "$ROOT" "$plan")/session.json" 2>/dev/null || echo unknown)
    if [ "$want" != "autonomous" ]; then verdict="SUPERVISED (plan mode: $want, session: $have)"
    else
      case "$have" in
        auto|dontAsk|bypassPermissions) verdict="AUTONOMOUS OK (session: $have)" ;;
        acceptEdits) verdict="AUTONOMOUS DEGRADED (session: acceptEdits; edits are automatic but Bash calls may still prompt, so treat this run as attended)" ;;
        plan) verdict="REFUSED (session is in plan mode; no builder may spawn until the plan is approved)"; fail=1 ;;
        *) verdict="MODE MISMATCH (plan asks for autonomous, session is '$have'). Switch with /permissions, restart with --permission-mode auto, or run unattended with claude -p --permission-mode dontAsk. Continuing attended: expect permission prompts, and nothing auto-resolves them." ;;
      esac
    fi
    echo "verdict $verdict"
    [ "$fail" -eq 0 ] || exit 2
    ;;

  *) sed -n '3,9p' "$0"; exit 3 ;;
esac
