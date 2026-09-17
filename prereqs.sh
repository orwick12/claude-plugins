#!/usr/bin/env bash
# One-time prerequisites for plan-and-verify on macOS / Linux: git, jq, bash.
missing=""; for t in git jq bash; do command -v "$t" >/dev/null 2>&1 || missing="$missing $t"; done
if [ -n "$missing" ]; then
  case "$(uname -s)" in
    Darwin) echo "run: brew install$missing" ;;
    *)      echo "run: sudo apt install$missing   (or your package manager)" ;;
  esac; exit 1
fi
command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1 || command -v perl >/dev/null 2>&1 || echo "note: no timeout tool; check timeouts will not apply (macOS: brew install coreutils)"
echo "prerequisites ok"
