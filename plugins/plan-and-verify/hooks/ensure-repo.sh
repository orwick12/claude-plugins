#!/usr/bin/env bash
# ensure-repo.sh [--check]
#
# Makes sure the project is a git repository with at least one commit, so
# plans, snapshots and milestone commits have something to stand on.
#
#   no repo              -> git init (branch main), write a starter .gitignore
#                           if none exists, make an initial commit
#   repo, no commits     -> make the initial commit
#   repo with commits    -> nothing to do
#   --check              -> report only, change nothing (used by SessionStart)
#
# Refuses to create a repo in the home directory or a filesystem root, and
# warns when the project is inside a larger repo instead of creating a nested
# one. Never sets git user.name/email for you.
#
# Exit codes: 0 ready, 2 refused or needs the user, 3 usage/config.
set -u
HOOKS="$(cd "$(dirname "$0")" && pwd)"
. "$HOOKS/lib.sh"
ROOT=$(pv_root)
CHECK=0; [ "${1:-}" = "--check" ] && CHECK=1
command -v git >/dev/null 2>&1 || { echo "git is not installed" >&2; exit 3; }

home=$(cd ~ 2>/dev/null && pwd)
case "$ROOT" in
  ""|/|[A-Za-z]:|[A-Za-z]:/|/[a-z]) echo "REFUSED: $ROOT is a filesystem root; open Claude Code in a project folder" >&2; exit 2 ;;
esac
if [ -n "$home" ] && [ "$ROOT" = "$home" ]; then
  echo "REFUSED: $ROOT is your home directory; open Claude Code in a project folder" >&2; exit 2
fi
cd "$ROOT" || { echo "project dir not found: $ROOT" >&2; exit 3; }

top=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ -n "$top" ]; then
  top=$(cd "$top" && pwd)
  if [ "$top" != "$ROOT" ]; then
    echo "NOTE: $ROOT is inside the git repo at $top; plans will commit to that repo. If that is wrong, run 'git init' in this folder yourself." >&2
  fi
  if git rev-parse --verify -q HEAD >/dev/null; then
    echo "git repo ready ($(git branch --show-current 2>/dev/null || echo detached))"; exit 0
  fi
  [ $CHECK = 1 ] && { echo "git repo has no commits yet; ensure-repo.sh will make the initial commit"; exit 2; }
  state="existing repo with no commits"
else
  [ $CHECK = 1 ] && { echo "no git repo; ensure-repo.sh will create one"; exit 2; }
  git init -q -b main 2>/dev/null || { git init -q && git symbolic-ref HEAD refs/heads/main; } || { echo "git init failed" >&2; exit 3; }
  state="new repo"
fi

if [ -z "$(git config user.name)" ] || [ -z "$(git config user.email)" ]; then
  echo "NEEDS USER: git has no identity. Ask the user to run:" >&2
  echo "  git config --global user.name \"Your Name\"" >&2
  echo "  git config --global user.email \"you@example.com\"" >&2
  echo "then re-run ensure-repo.sh. ($state created; nothing committed yet)" >&2
  exit 2
fi

made_ignore=0
if [ ! -f .gitignore ]; then
  cat > .gitignore <<'EOF'
# Created by plan-and-verify. Edit freely.
# Dependencies and build output
node_modules/
vendor/
dist/
build/
out/
target/
bin/
obj/
.venv/
venv/
__pycache__/
*.pyc
.gradle/
.godot/
.import/
# Secrets and local config
.env
.env.*
!.env.example
*.pem
*.key
# Editors and OS
.vs/
.idea/
.vscode/*
!.vscode/settings.json
.DS_Store
Thumbs.db
# Logs
*.log
EOF
  made_ignore=1
fi

git add -A
# Do not sweep large files into the first commit silently.
big=$(git diff --cached --name-only -z | xargs -0 -I{} sh -c 's=$(wc -c < "{}" 2>/dev/null || echo 0); [ "$s" -gt 5242880 ] && echo "{} ($((s/1048576)) MB)"' 2>/dev/null)
if [ -n "$big" ]; then
  git reset -q
  echo "NEEDS USER: these files are over 5 MB and were not committed:" >&2
  printf '  %s\n' "$big" >&2
  echo "Add them to .gitignore (or use Git LFS), then re-run ensure-repo.sh. ($state; nothing committed yet)" >&2
  exit 2
fi

count=$(git diff --cached --name-only | wc -l | tr -d ' ')
git commit -q --allow-empty -m "Initial commit (created by plan-and-verify)" || { echo "initial commit failed" >&2; exit 3; }
echo "INITIALISED: $state, branch $(git branch --show-current), initial commit $(git rev-parse --short HEAD) with $count file(s)$([ $made_ignore = 1 ] && echo ', starter .gitignore added')"
