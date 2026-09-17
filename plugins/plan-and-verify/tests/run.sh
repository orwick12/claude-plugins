#!/usr/bin/env bash
# run.sh — run every tests/*.test.sh. Exit 0 only if all of them pass.
# Needs bash, git and jq. Usage: bash plugins/plan-and-verify/tests/run.sh
set -u
dir="$(cd "$(dirname "$0")" && pwd)"
failed=""
for t in "$dir"/*.test.sh; do
  echo "== $(basename "$t")"
  bash "$t" || failed="$failed $(basename "$t")"
done
if [ -z "$failed" ]; then echo "ALL PASSED"; exit 0; fi
echo "FAILED:$failed"; exit 1
