#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

mock_bin="$tmpdir/bin"
call_log="$tmpdir/calls"
mkdir -p "$mock_bin"

for command in omarchy-shell hyprctl omarchy-cmd-present timeout flock; do
  cat >"$mock_bin/$command" <<'SH'
#!/bin/bash
printf '%s %s\n' "$(basename "$0")" "$*" >>"$CALL_LOG"
SH
done

# Nothing to lock out of: no 1Password running.
cat >"$mock_bin/pgrep" <<'SH'
#!/bin/bash
exit 1
SH
chmod +x "$mock_bin"/*

PATH="$mock_bin:$PATH" CALL_LOG="$call_log" "$ROOT/bin/omarchy-system-lock"

grep -Fxq 'omarchy-shell lock lock' "$call_log" ||
  fail "system lock asks the shell to lock" "calls: $(<"$call_log")"
pass "system lock asks the shell to lock"

grep -Fxq 'hyprctl switchxkblayout all 0' "$call_log" ||
  fail "system lock resets the keyboard layout so the password can be typed" "calls: $(<"$call_log")"
pass "system lock resets the keyboard layout before the password prompt"

# The lock screen is the only thing this may reach for. Killing windows by
# pattern is how a lock takes something unrelated down with it.
! grep -qE '^(pkill|killall) ' "$call_log" ||
  fail "system lock kills processes by pattern" "calls: $(<"$call_log")"
pass "system lock kills nothing by pattern"
