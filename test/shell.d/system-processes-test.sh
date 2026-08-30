#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command jq

processes="$ROOT/bin/omarchy-system-processes"

run() {
  PATH="$ROOT/bin:$PATH" "$processes" "$@"
}

# --------------------------------------------------------------- arguments

for bad in "--limit" "--limit x" "--limit -1" "--interval" "--interval nope" "--nonsense"; do
  # shellcheck disable=SC2086
  if run $bad >/dev/null 2>&1; then
    fail "rejects bad arguments" "accepted: $bad"
  fi
done
pass "rejects arguments it cannot act on"

run --help >/dev/null || fail "--help works without sampling"
pass "--help works without sampling"

# ------------------------------------------------------------------ output

output=$(run --limit 5 --interval 0.1)

jq -e 'type == "array"' <<<"$output" >/dev/null || fail "output is a JSON array" "$output"
pass "output is a JSON array"

jq -e 'length > 0 and length <= 5' <<<"$output" >/dev/null ||
  fail "--limit caps the number of rows" "got $(jq length <<<"$output")"
pass "--limit caps the number of rows"

jq -e 'all(.[]; has("pid") and has("name") and has("command") and has("cpu") and has("memory") and has("rssKb") and has("uid"))' <<<"$output" >/dev/null ||
  fail "every row carries the fields the panel renders" "$output"
pass "every row carries the fields the panel renders"

jq -e 'all(.[]; (.pid | type) == "number" and (.cpu | type) == "number" and (.memory | type) == "number")' <<<"$output" >/dev/null ||
  fail "numbers are JSON numbers, not strings" "$output"
pass "numbers are JSON numbers, not strings"

# The panel renders the list as it arrives, so the order is the command's job.
jq -e '[.[].cpu] == ([.[].cpu] | sort | reverse)' <<<"$output" >/dev/null ||
  fail "rows arrive sorted by CPU descending" "$(jq -c '[.[].cpu]' <<<"$output")"
pass "rows arrive sorted by CPU descending"

# A share of one core. A single-threaded process cannot exceed 100, and nothing
# may exceed every core at once.
cores=$(nproc)
jq -e --argjson cores "$cores" 'all(.[]; .cpu >= 0 and .cpu <= 100 * $cores)' <<<"$output" >/dev/null ||
  fail "CPU is a share of the machine, not an unbounded number" "$(jq -c '[.[].cpu]' <<<"$output")"
pass "CPU stays within what the machine can do"

jq -e 'all(.[]; .memory >= 0 and .memory <= 100)' <<<"$output" >/dev/null ||
  fail "memory is a percentage" "$(jq -c '[.[].memory]' <<<"$output")"
pass "memory is a percentage of total RAM"

# A process whose name or arguments contain a quote, a tab, a newline or a
# backslash must not be able to break the JSON the shell parses. This has to
# create such a process rather than hope one is running: the rows are
# tab-separated before jq sees them, so a tab in argv used to shift every field
# and kill the whole command, and an assertion over whatever happened to be
# running could not see it. It also has to sample deep enough to reach the row
# -- the failure only fires if the process is inside --limit -- and it has to
# check the command survived at all, because the failure mode is an empty
# result and `all` over an empty array is vacuously true.
hostile_arg=$(printf 'tabby\targ "quoted" back\\slash $dollar')
perl -e 'my $end = time + 20; while (time < $end) {}' "$hostile_arg" &
hostile_pid=$!
# shellcheck disable=SC2064
trap "kill $hostile_pid 2>/dev/null || true" EXIT

hostile_output=$(run --limit 60) ||
  fail "a process with a tab in its arguments takes the whole command down"

jq -e 'type == "array" and length > 0' <<<"$hostile_output" >/dev/null ||
  fail "a process with a tab in its arguments empties the result" "$hostile_output"

jq -e 'all(.[]; (.name | type) == "string" and (.command | type) == "string")' <<<"$hostile_output" >/dev/null ||
  fail "names and command lines survive as strings" "$hostile_output"

jq -e --argjson pid "$hostile_pid" 'any(.[]; .pid == $pid)' <<<"$hostile_output" >/dev/null ||
  fail "the process with a tab in its arguments is missing from the table"

jq -e --argjson pid "$hostile_pid" 'any(.[]; .pid == $pid and (.command | test("tabby") and test("quoted") and test("dollar")))' <<<"$hostile_output" >/dev/null ||
  fail "a hostile command line is mangled rather than carried through" \
    "$(jq -c --argjson pid "$hostile_pid" '.[] | select(.pid == $pid)' <<<"$hostile_output")"

kill "$hostile_pid" 2>/dev/null || true
trap - EXIT
pass "a tab, a quote, a backslash or a dollar in argv cannot break the table"

# ------------------------------------------------------------------ timing

# Sampling twice is the whole point: a reading divided by an assumed interval
# rather than the time that actually passed was several times too high.
grep -F 'EPOCHREALTIME' "$processes" >/dev/null ||
  fail "the command assumes an interval instead of measuring one"
grep -F 'used / elapsed' "$processes" >/dev/null ||
  fail "CPU is not computed against the measured elapsed time"
pass "CPU is computed against the time that actually passed"

# A process that exits between the glob expanding and awk opening its stat file
# makes awk exit 2 even though it read every other file, which under set -e
# printed nothing at all. Sampling a machine that is churning processes must
# still answer.
churn() {
  local i
  for (( i = 0; i < 40; i++ )); do
    ( true ) &
  done
  wait 2>/dev/null || true
}

for attempt in 1 2 3 4 5; do
  churn
  churned=$(run --limit 3 --interval 0.05) ||
    fail "a process exiting mid-scan takes the whole command down"
  jq -e 'type == "array" and length > 0' <<<"$churned" >/dev/null ||
    fail "a process exiting mid-scan empties the result" "attempt $attempt: $churned"
done
pass "sampling survives processes exiting while it runs"

# One awk over every stat file, not one per process: at four hundred processes
# the fork cost exceeded the sampling window.
(( $(grep -c "awk '" "$processes") <= 4 )) ||
  fail "sampling forks per process again" "$(grep -c "awk '" "$processes") awk invocations"
pass "sampling walks every process in one pass"
