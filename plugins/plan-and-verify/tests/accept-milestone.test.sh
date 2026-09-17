#!/usr/bin/env bash
# accept-milestone.sh must refuse any PASS that does not vouch for the code and checks on disk,
# including a checks.json edit that was committed by something other than a plan commit.
. "$(dirname "$0")/helpers.sh"

# accept <repo> -> "<exit code>|<stderr+stdout>"
accept() { local o c; o=$(cd "$1" && CLAUDE_PROJECT_DIR="$1" bash "$HOOKS/accept-milestone.sh" demo 1.1 2>&1); c=$?; printf '%s|%s' "$c" "$o"; }
checks() { (cd "$1" && CLAUDE_PROJECT_DIR="$1" bash "$HOOKS/run-checks.sh" demo 1.1 >/dev/null 2>&1); }
code() { printf '%s' "${1%%|*}"; }
msg()  { printf '%s' "${1#*|}"; }

echo "accept-milestone.sh"

# --- T1-T5: one repo, restored between cases ---------------------------------------
R=$(mk_repo demo); C="$R/.claude/build-plans/demo/checks.json"; RES="$R/.claude/build-plans/demo/results/1.1.json"
printf 'ok' > "$R/hello.txt"; checks "$R"
BK=$(tmpdir); cp "$C" "$BK/checks.json"; cp "$RES" "$BK/results.json"
restore() { cp "$BK/checks.json" "$C"; cp "$BK/results.json" "$RES"; rm -f "$R/extra.txt"; }
head0=$(git -C "$R" rev-parse HEAD)

printf 'x' > "$R/extra.txt"; r=$(accept "$R")
assert_eq "T1 file added after PASS: refused" 2 "$(code "$r")"; assert_contains "T1 reason: stale" "stale" "$(msg "$r")"; restore

sed -i.sed 's/"value": "ok"/"value": "okX"/' "$C" && rm -f "$C.sed"; r=$(accept "$R")
assert_eq "T2 checks.json edited, not re-run: refused" 2 "$(code "$r")"; restore

jq '.milestones["1.1"].checks = [{"name":"always","cmd":"true"}]' "$BK/checks.json" > "$C"; checks "$R"; r=$(accept "$R")
assert_eq "T3 checks.json gutted and re-run to PASS: refused" 2 "$(code "$r")"; restore

printf '\n' >> "$C"; r=$(accept "$R")
assert_eq "T4 checks.json whitespace edit: refused" 2 "$(code "$r")"; restore

assert_eq "T1-T4 left HEAD alone" "$head0" "$(git -C "$R" rev-parse HEAD)"
r=$(accept "$R")
assert_eq "T5 clean PASS: accepted" 0 "$(code "$r")"; assert_contains "T5 prints ACCEPTED" "ACCEPTED demo [1.1]" "$(msg "$r")"

# --- T6: checks.json gutted and COMMITTED by a non-plan commit ---------------------
R=$(mk_repo demo); C="$R/.claude/build-plans/demo/checks.json"
printf 'ok' > "$R/hello.txt"
jq '.milestones["1.1"].checks = [{"name":"always","cmd":"true"},{"name":"always2","cmd":"true"}]' "$C" > "$C.new" && mv "$C.new" "$C"
git -C "$R" commit -q -m "wip" -- "$C"; wip=$(git -C "$R" rev-parse --short HEAD)
checks "$R"; r=$(accept "$R")
assert_eq       "T6 checks.json changed by a non-plan commit: refused" 2 "$(code "$r")"
assert_contains "T6 reason names the commit" "$wip" "$(msg "$r")"
assert_eq       "T6 HEAD not moved" "$wip" "$(git -C "$R" rev-parse --short HEAD)"

# --- T7: the same change made by a plan commit is legitimate -----------------------
R=$(mk_repo demo); C="$R/.claude/build-plans/demo/checks.json"
printf 'ok ' > "$R/hello.txt"
jq '.milestones["1.1"].checks[0].expect = "contains"' "$C" > "$C.new" && mv "$C.new" "$C"
git -C "$R" commit -q -m "plan(demo): loosen hello check to contains" -- "$C"
checks "$R"; r=$(accept "$R")
assert_eq "T7 checks.json changed by a plan(<slug>) commit: accepted" 0 "$(code "$r")"

# --- T8: a plan commit for a different slug does not count -------------------------
R=$(mk_repo demo); C="$R/.claude/build-plans/demo/checks.json"
printf 'ok' > "$R/hello.txt"
jq '.milestones["1.1"].checks = [{"name":"always","cmd":"true"}]' "$C" > "$C.new" && mv "$C.new" "$C"
git -C "$R" commit -q -m "plan(other): unrelated" -- "$C"
checks "$R"; r=$(accept "$R")
assert_eq "T8 checks.json changed by another plan's commit: refused" 2 "$(code "$r")"

# --- T9-T11 (F37): HEAD must still be where the milestone was spawned from -----------
# The spawn snapshot's parent records HEAD at spawn. Only the planner commits between
# spawn and accept, so any other commit in that range is foreign, whatever its subject.
snap() { (cd "$1" && CLAUDE_PROJECT_DIR="$1" bash "$HOOKS/snapshot.sh" demo 1.1 spawn >/dev/null); }

R=$(mk_repo demo); printf 'ok' > "$R/hello.txt"; snap "$R"
printf 'src' > "$R/app.txt"; git -C "$R" add app.txt; git -C "$R" commit -q -m "sneak in some code"
sneak=$(git -C "$R" rev-parse --short HEAD)
checks "$R"; r=$(accept "$R")
assert_eq       "T9 a foreign commit after the spawn snapshot: refused" 2 "$(code "$r")"
assert_contains "T9 reason names the commit" "$sneak" "$(msg "$r")"

R=$(mk_repo demo); printf 'ok ' > "$R/hello.txt"; snap "$R"
C="$R/.claude/build-plans/demo/checks.json"
jq '.milestones["1.1"].checks[0].expect = "contains"' "$C" > "$C.new" && mv "$C.new" "$C"
git -C "$R" commit -q -m "plan(demo): fix the hello check" -- "$C"
checks "$R"; r=$(accept "$R")
assert_eq "T10 a plan(<slug>) commit after the spawn snapshot: accepted" 0 "$(code "$r")"

R=$(mk_repo demo); printf 'ok' > "$R/hello.txt"; checks "$R"; r=$(accept "$R")
assert_eq "T11 no spawn snapshot at all (manual run): still accepted" 0 "$(code "$r")"

# --- T12-T13 (F5): the milestone commit carries this milestone's work, nothing else ---
R=$(mk_repo demo); printf 'ok' > "$R/hello.txt"
mkdir -p "$R/.claude/build-plans/STRAY/results"
printf '{}' > "$R/.claude/build-plans/STRAY/results/hook-misfire.json"
checks "$R"; r=$(accept "$R")
assert_eq       "T12 a stray plan directory: refused" 2 "$(code "$r")"
assert_contains "T12 reason names the stray path" "STRAY" "$(msg "$r")"

rm -rf "$R/.claude/build-plans/STRAY"
printf 'note' > "$R/scratch.txt"
checks "$R"; r=$(accept "$R")
assert_eq        "T13 ordinary project files are still committed" 0 "$(code "$r")"
files=$(git -C "$R" show --stat --format= --name-only HEAD | tr '\n' ' ')
assert_contains  "T13 the milestone's own work is in the commit" "hello.txt" "$files"
assert_contains  "T13 unrelated project files still ride along" "scratch.txt" "$files"
assert_contains  "T13 this plan's results are in the commit" "results/1.1.json" "$files"

finish
