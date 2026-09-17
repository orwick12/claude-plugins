#!/usr/bin/env bash
# lib.sh — portability helpers shared by the plan-and-verify hooks.
# Works on Linux, macOS (stock Bash 3.2, no coreutils) and Windows Git Bash.

# Project root: honour CLAUDE_PROJECT_DIR, translate Windows paths under MSYS/Git Bash.
pv_root() {
  local r="${CLAUDE_PROJECT_DIR:-$(pwd)}"
  case "$r" in
    [A-Za-z]:\\*|[A-Za-z]:/*) command -v cygpath >/dev/null 2>&1 && r=$(cygpath -u "$r") ;;
  esac
  printf '%s' "${r%/}"
}

# True when an agent_type names one of this plugin's builders. Claude Code reports
# plugin agents namespaced ("plan-and-verify:builder-sonnet") and some internal
# agents with an empty agent_type, so match the suffix exactly and nothing else.
pv_is_builder() {
  case "${1:-}" in
    builder-sonnet|builder-opus|*:builder-sonnet|*:builder-opus) return 0 ;;
  esac
  return 1
}

# Print the git subcommand of every git invocation in a command string, one per line.
# A regex over the raw text misses the spellings that still reach git: leading
# whitespace, "VAR=val git ...", "env VAR=val git ...", and git's own global options
# ("git -C dir commit", "git -c k=v commit", "git --no-pager stash"). Splitting on the
# shell's command separators and walking the tokens catches all of them, and keeps
# lookalikes such as git-crypt out.
pv_git_subcommands() {
  printf '%s\n' "${1:-}" | tr '\n' ';' | sed 's/&&/;/g; s/||/;/g; s/|/;/g' | tr ';' '\n' | while IFS= read -r seg; do
    set -- $seg                                    # deliberate word splitting
    while [ $# -gt 0 ]; do                         # env assignments and env(1)
      case "$1" in
        [A-Za-z_]*=*|env) shift ;;              # VAR=val (a bracket matches one char, so no second class here)
        *) break ;;
      esac
    done
    [ $# -gt 0 ] || continue
    case "$1" in git|*/git) shift ;; *) continue ;; esac
    while [ $# -gt 0 ]; do                         # git's global options
      case "$1" in
        -C|-c|--git-dir|--work-tree|--namespace|--exec-path) shift; [ $# -gt 0 ] && shift ;;
        -*) shift ;;
        *) printf '%s\n' "$1"; break ;;
      esac
    done
  done
}

# SHA-256 of stdin, first 16 hex chars. Tries every common tool; never returns empty.
pv_sha256() {
  local out=""
  if command -v sha256sum >/dev/null 2>&1; then out=$(sha256sum | cut -c1-16)
  elif command -v shasum >/dev/null 2>&1; then out=$(shasum -a 256 | cut -c1-16)
  elif command -v openssl >/dev/null 2>&1; then out=$(openssl dgst -sha256 | sed 's/^.*= *//' | cut -c1-16)
  elif command -v python3 >/dev/null 2>&1; then out=$(python3 -c 'import sys,hashlib;print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest()[:16])')
  fi
  [ -n "$out" ] || { echo "no sha256 tool found (need sha256sum, shasum, openssl or python3)" >&2; return 1; }
  printf '%s' "$out"
}

# Run "$@" with a time limit of $PV_TIMEOUT seconds. Uses timeout/gtimeout when
# present, else a perl alarm, else runs unlimited (run-checks.sh warns once).
pv_timeout() {
  local t="$PV_TIMEOUT"
  if command -v timeout >/dev/null 2>&1; then timeout "$t" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$t" "$@"
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'alarm shift; exec @ARGV' "$t" "$@"; local c=$?; [ $c -eq 142 ] && c=124; return $c
  else "$@"
  fi
}

# The "MILESTONE: <plan>/<id>" line a builder's report must carry, and the ref in it.
PV_REF_RE='^MILESTONE:[[:space:]]*[A-Za-z0-9._-]+/[A-Za-z0-9._:-]+'
pv_report_ref() { grep -oE "$PV_REF_RE" <<<"${1:-}" | head -1 | sed -E 's/^MILESTONE:[[:space:]]*//'; }

# Keep a builder's report next to its results: <root> <plan> <id> <source> <agent id> <report>.
# SubagentHandback delivers one report per run, so a builder sent back by the finish hook
# cannot deliver its corrected one; disk is where the orchestrator reads it instead. Never
# creates a directory for a plan this project does not have.
pv_write_report() {
  local root="$1" plan="$2" mid="$3" src="$4" agent="$5" msg="$6" d f
  d="$root/.claude/build-plans/$plan"
  [ -f "$d/checks.json" ] || return 0
  mkdir -p "$d/results" || return 0
  f="$d/results/$(printf '%s' "$mid" | tr ':/' '__').report.md"
  { printf -- '---\nsource: %s\nagent: %s\nat: %s\n---\n\n' \
      "$src" "${agent:-unknown}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '%s\n' "$msg"
  } > "$f"
}

# Fingerprint of the working tree (diff vs HEAD + untracked files), excluding results dirs.
pv_tree_sha() {
  local root="$1"
  ( git -C "$root" diff HEAD --binary -- . ':!*/results/*' 2>/dev/null
    git -C "$root" ls-files --others --exclude-standard 2>/dev/null | grep -v '/results/' | LC_ALL=C sort |
      while IFS= read -r f; do printf '%s\n' "$f"; cat "$root/$f" 2>/dev/null; done
  ) | pv_sha256
}
