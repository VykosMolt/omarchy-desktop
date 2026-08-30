#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

run_node_test <<'JS'
const idle = requireFromRoot('shell/plugins/services/idle/IdleModel.js')

assertEqual(idle.secondsFromConfig('42.9', 10), 42, 'idle floors configured seconds')
assertEqual(idle.secondsFromConfig('-1', 10), 10, 'idle rejects negative seconds')
assertEqual(idle.secondsFromConfig('nope', 10), 10, 'idle rejects invalid seconds')

// The compositor's idle monitor carries one timeout, so the stages that are on
// decide which one it waits out and the rest run relative to it.
assertDeepEqual(idle.enabledTimeouts([0, 300, 0]), [300], 'idle counts only the stages that are on')
assertDeepEqual(idle.enabledTimeouts([900, 300, 600]), [300, 600, 900], 'idle orders stages by when they fire')
assertDeepEqual(idle.enabledTimeouts([600, 300]), [300, 600], 'idle allows a screen off after the lock')
assertDeepEqual(idle.enabledTimeouts([0, 0, 0]), [], 'idle has nothing to wait for when every stage is off')

JS

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

test_home="$test_tmp/home"
mkdir -p "$test_home"

HOME="$test_home" "$ROOT/bin/omarchy-toggle-idle" stay-awake >/dev/null
[[ -f $test_home/.local/state/omarchy/indicators/stay-awake ]] || fail "Stay Awake toggle persists enabled state"

HOME="$test_home" "$ROOT/bin/omarchy-toggle-idle" allow-idle >/dev/null
[[ ! -f $test_home/.local/state/omarchy/indicators/stay-awake ]] || fail "Stay Awake toggle persists disabled state"

if rg -q 'omarchy-shell' "$ROOT/bin/omarchy-toggle-idle"; then
  fail "Stay Awake toggle avoids reentrant shell IPC"
fi

pass "Stay Awake toggle persists state without reentrant shell IPC"

service="$ROOT/shell/plugins/services/idle/Service.qml"

# Each stage runs the command that actually performs it, and turning the screen
# back on is what a wake is for -- so a cycle that never turned it off has
# nothing to undo.
grep -Fq 'omarchy-brightness-display off' "$service" ||
  fail "the screen off stage turns the display off"
grep -Fq 'omarchy-system-lock' "$service" || fail "the lock stage locks"
grep -Fq 'systemctl suspend' "$service" || fail "the suspend stage suspends"
grep -Fq 'root.idledThisCycle && root.screenOffThisCycle' "$service" ||
  fail "a cycle that never turned the screen off still runs a wake"
pass "each idle stage runs the command that performs it"

grep -Fq 'timeout: root.firstIdleTimeoutSeconds' "$service" ||
  fail "the idle monitor waits out the earliest stage that is on"
grep -Fq 'firstIdleTimeoutSeconds > 0' "$service" ||
  fail "idle is off entirely when every stage is off"
pass "the idle monitor follows the stages that are on"
