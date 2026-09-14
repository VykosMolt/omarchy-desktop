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
grep -Fq '["omarchy-brightness-display", "off"]' "$service" ||
  fail "the screen off stage turns the display off"
grep -Fq 'omarchy-system-lock' "$service" || fail "the lock stage locks"
grep -Fq '["systemctl", "suspend"]' "$service" || fail "the suspend stage suspends"
grep -Fq 'root.idledThisCycle && root.screenOffThisCycle' "$service" ||
  fail "a cycle that never turned the screen off still runs a wake"
pass "each idle stage runs the command that performs it"

grep -Fq 'timeout: root.firstIdleTimeoutSeconds' "$service" ||
  fail "the idle monitor waits out the earliest stage that is on"
grep -Fq 'firstIdleTimeoutSeconds > 0' "$service" ||
  fail "idle is off entirely when every stage is off"
pass "the idle monitor follows the stages that are on"

run_node_test <<'JS'
const fs = require('fs')
const vm = require('vm')
const source = fs.readFileSync(root + '/shell/plugins/services/idle/Service.qml', 'utf8')
const timer = () => ({ running: true, interval: 0, stop() { this.running = false }, restart() { this.running = true } })
const state = { logEvent: () => {}, screenOffTimer: timer(), lockTimer: timer(), suspendTimer: timer(), idledThisCycle: true, screenOffThisCycle: true, displayDesiredOff: true, displayOff: true, displayPowerActive: true, screenOffProcess: { running: true }, wakeProcess: { running: false }, idleStartedAt: 0, Qt: { callLater: () => {} } }
state.root = state
vm.createContext(state)
for (const name of ['runProcess', 'pumpDisplayPower', 'cancelIdleCycle', 'scheduleStage', 'reconfigureStages', 'finishStayAwakeProbe']) {
  vm.runInContext(source.match(new RegExp('  function ' + name + '\\([^]*?\\n  }'))[0], state)
}
state.cancelIdleCycle('activity')
assertEqual(state.wakeProcess.running, false, 'activity waits for an in-flight screen-off command')
state.screenOffProcess.running = state.displayPowerActive = false
state.pumpDisplayPower()
assertDeepEqual(state.wakeProcess.command, ['omarchy-system-wake'], 'wake starts after screen-off settles')
assertEqual(state.displayOff, false, 'serialized display power converges on the latest active state')
state.idledThisCycle = true
state.idleEnabled = true
state.screenOffThisCycle = state.lockedThisCycle = state.suspendedThisCycle = false
state.screenOffTimeoutSeconds = 0
state.lockTimeoutSeconds = 30
state.suspendTimeoutSeconds = 0
state.firstIdleTimeoutSeconds = 5
state.idleStartedAt = Date.now() - 10000
state.lockSystem = () => {}
state.reconfigureStages()
assertEqual(state.screenOffTimer.running, false, 'live configuration cancels a disabled pending screen-off stage')
assert(state.lockTimer.interval >= 19000 && state.lockTimer.interval <= 20000, 'rescheduling accounts for inactivity already elapsed')
let applied = false
state.applyStayAwake = () => { applied = true }
state.stayAwakeGeneration = 2
state.stayAwakeWriteActive = false
state.hasPendingStayAwakePersist = false
state.stayAwakeStateDirWatcher = { reload: () => {} }
state.stayAwakeStateProbe = { pendingResult: true, outDone: true, resultExited: true, serial: 1, code: 0, output: 'no' }
state.finishStayAwakeProbe()
assertEqual(applied, false, 'an earlier file probe cannot undo a newer Stay Awake toggle')
JS
