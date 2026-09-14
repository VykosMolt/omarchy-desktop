#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

run_node_test <<'JS'
const monitor = requireFromRoot('shell/plugins/panels/monitor/Model.js')

assertEqual(monitor.clampBrightness(0), 1, 'monitor clamps minimum brightness')
assertEqual(monitor.clampBrightness(101), 100, 'monitor clamps maximum brightness')
assertEqual(monitor.clampBrightness(42.4), 42, 'monitor rounds brightness')
assertEqual(monitor.clampBrightness('nope'), 1, 'monitor rejects invalid brightness')

assertEqual(monitor.normalizeScale('1.250'), '1.25', 'monitor normalizes fractional scale')
assertEqual(monitor.normalizeScale('nope'), '', 'monitor rejects invalid scale')
assertEqual(monitor.cleanScale(3, 1280, 800), '3.2', 'monitor matches clean VM scale')
assertEqual(monitor.cleanScale(1.25, 1280, 800), '1.25', 'monitor preserves an already clean scale')
assertEqual(monitor.cleanScale(1.25, 6016, 3384), '1.33', 'monitor matches clean physical display scale')
assertEqual(monitor.cleanScale(1.6, 0, 800), '', 'monitor rejects a missing display mode')
assertEqual(
  monitor.matchingScaleIndex(['1', '1.25', '1.6', '2', '3', '4'], 3.2, 1280, 800),
  4,
  'monitor selects an approximated VM scale'
)
assertEqual(
  monitor.matchingScaleIndex(['1', '1.25', '1.6', '2', '3', '4'], 4, 4, 4),
  5,
  'monitor selects an exact preset'
)
assertDeepEqual(
  monitor.availableScales(['1', '1.25', '1.6', '2', '3', '4'], 1280, 800),
  ['1', '1.25', '1.6', '2', '3', '4'],
  'monitor keeps distinct approximated VM scales'
)
assertDeepEqual(
  monitor.availableScales(['1', '1.25', '1.6', '2', '3', '4'], 6016, 3384),
  ['1', '1.25', '1.6', '2', '3', '4'],
  'monitor keeps distinct approximated physical display scales'
)
assertDeepEqual(
  monitor.availableScales(['1', '1.25', '1.6', '2', '3', '4'], 1280, 804),
  ['1', '1.25', '2', '4'],
  'monitor collapses presets with duplicate effective scales'
)
assertDeepEqual(
  monitor.availableScales(['1', '1.25', '1.6', '2', '3', '4'], 5968, 3230),
  ['1', '2'],
  'monitor hides presets the current mode cannot reach'
)
assertDeepEqual(
  monitor.availableScales(['1', '1.25', '1.6', '2', '3', '4'], 0, 0),
  ['1', '1.25', '1.6', '2', '3', '4'],
  'monitor keeps presets until display dimensions are known'
)

assertEqual(monitor.brightnessName(96), 'Sun blast', 'monitor names very bright displays')
assertEqual(monitor.brightnessName(12), 'Candlelit', 'monitor names dim displays')

assertDeepEqual(
  monitor.parseDisplays(JSON.stringify([
    { name: 'eDP-1', enabled: true, focused: false, width: 1920, height: 1080 },
    { name: 'HDMI-A-1', enabled: false, focused: false, width: 0, height: 0 },
    { name: 'DP-1', enabled: true, focused: true, width: 1280, height: 800 }
  ])),
  {
    displays: [
      { name: 'eDP-1', enabled: true, focused: false, width: 1920, height: 1080 },
      { name: 'HDMI-A-1', enabled: false, focused: false, width: 0, height: 0 },
      { name: 'DP-1', enabled: true, focused: true, width: 1280, height: 800 }
    ],
    enabledDisplayCount: 2
  },
  'monitor parses display state'
)

assertDeepEqual(monitor.parseDisplays('{'), { displays: [], enabledDisplayCount: 0 }, 'monitor handles invalid display JSON')
JS

# The display guard runs entirely against a fake compositor. Concurrent
# callers both wanting to disable an output must leave one active.
monitor_tmp=$(mktemp -d)
trap 'rm -rf "$monitor_tmp"' EXIT
mkdir -p "$monitor_tmp/bin"
export MONITOR_TEST_STATE="$monitor_tmp/monitors.json"
cat > "$monitor_tmp/bin/hyprctl" <<'PY'
#!/usr/bin/python3
import json
import os
from pathlib import Path
import sys
import time

state = Path(os.environ['MONITOR_TEST_STATE'])
if sys.argv[1:] in (['monitors', 'all', '-j'], ['monitors', '-j']):
    print(state.read_text())
elif sys.argv[1:3] == ['keyword', 'monitor']:
    name, action, *_ = sys.argv[3].split(',')
    time.sleep(0.05)
    data = json.loads(state.read_text())
    for row in data:
        if row['name'] == name:
            row['disabled'] = action == 'disable'
    state.write_text(json.dumps(data))
elif sys.argv[1] == 'eval':
    state.with_suffix('.eval').write_text(sys.argv[2])
else:
    sys.exit(1)
PY
chmod +x "$monitor_tmp/bin/hyprctl"
monitor_toggle() {
  PATH="$monitor_tmp/bin:$PATH" OMARCHY_PATH="$ROOT" "$ROOT/bin/omarchy-monitor-toggle" "$@"
}
printf '%s\n' '[{"name":"A","disabled":false},{"name":"B","disabled":false}]' > "$MONITOR_TEST_STATE"
monitor_toggle A disable > "$monitor_tmp/a.log" 2>&1 &
first_toggle=$!
monitor_toggle B disable > "$monitor_tmp/b.log" 2>&1 &
second_toggle=$!
first_status=0
second_status=0
wait "$first_toggle" || first_status=$?
wait "$second_toggle" || second_status=$?
[[ $((first_status + second_status)) == 1 ]] || fail "exactly one simultaneous disable succeeds"
[[ $(jq '[.[] | select(.disabled != true)] | length' "$MONITOR_TEST_STATE") == 1 ]] || fail "simultaneous disables preserve the last display"
pass "simultaneous display disables recheck state under the mutation lock"

before=$(cat "$MONITOR_TEST_STATE")
if monitor_toggle 'A,disable' disable 2>/dev/null; then fail "unsafe display name is rejected"; fi
if monitor_toggle Missing disable 2>/dev/null; then fail "disconnected display is rejected"; fi
[[ $(cat "$MONITOR_TEST_STATE") == "$before" ]] || fail "rejected toggles do not change displays"
pass "unsafe and disconnected display targets cannot reach a mutation"

printf '%s\n' '[{"name":"A","disabled":false,"mirrorOf":"none"},{"name":"B","disabled":false,"mirrorOf":"A"}]' > "$MONITOR_TEST_STATE"
if monitor_toggle A disable 2>/dev/null; then fail "a mirrored output cannot substitute for its only source"; fi
monitor_toggle B disable
monitor_toggle B enable
[[ $(jq '[.[] | select(.disabled != true)] | length' "$MONITOR_TEST_STATE") == 2 ]] || fail "a disabled output can be enabled"
pass "mirroring keeps its source active and a disabled display can be restored"

printf '%s\n' '[{"name":"A","focused":false,"width":1920,"height":1080,"refreshRate":60,"scale":1},{"name":"B","focused":true,"width":2560,"height":1440,"refreshRate":60,"scale":1}]' > "$MONITOR_TEST_STATE"
PATH="$monitor_tmp/bin:$PATH" OMARCHY_PATH="$ROOT" "$ROOT/bin/omarchy-hyprland-monitor-scaling" --monitor A 2
rg -q 'output = "A".*scale = 2' "$monitor_tmp/monitors.eval" || fail "explicit scaling keeps its requested output after focus changes"
if PATH="$monitor_tmp/bin:$PATH" OMARCHY_PATH="$ROOT" "$ROOT/bin/omarchy-hyprland-monitor-scaling" --monitor Missing 2 2>/dev/null; then
  fail "explicit scaling refuses a disconnected display"
fi
pass "explicit scale targets remain fixed when compositor focus moves"

run_node_test <<'JS'
const fs = require('fs')
const vm = require('vm')
const source = fs.readFileSync(root + '/shell/plugins/panels/monitor/Panel.qml', 'utf8')
const state = { focusedMonitor: 'A', actionQueue: [], actionActive: true, actionProc: { running: true }, brightnessWriteActive: true, brightnessSetQueued: false, brightnessGeneration: 0, setBrightnessProc: { running: true }, textSizeWriteActive: true, textScaleProc: { running: true }, pendingTextSizePx: 0, textSizeStops: [9, 10, 11, 12, 14, 16, 20], markReflowing: () => {}, Model: requireFromRoot('shell/plugins/panels/monitor/Model.js') }
state.root = state
vm.createContext(state)
for (const name of ['enqueueAction', 'pumpAction', 'setScale', 'setBrightness', 'pumpBrightness', 'nearestTextStop', 'setTextSize', 'pumpTextSize']) {
  vm.runInContext(source.match(new RegExp('  function ' + name + '\\([^]*?\\n  }'))[0], state)
}
state.setScale('1.25')
state.setScale('1.6')
state.focusedMonitor = 'B'
state.actionProc.running = state.actionActive = false
state.pumpAction()
assertDeepEqual(state.actionProc.command, ['omarchy-hyprland-monitor-scaling', '--monitor', 'A', '1.6'], 'queued scaling retains its intended display and latest value')
state.setBrightness(42)
state.focusedMonitor = 'C'
state.setBrightnessProc.running = state.brightnessWriteActive = false
state.pumpBrightness()
assertDeepEqual(state.setBrightnessProc.command, ['omarchy-brightness-display', '--no-osd', '--monitor', 'B', '42%'], 'queued brightness cannot follow a newly focused monitor')
state.setTextSize(14)
state.setTextSize(16)
state.setTextSize(20)
state.textScaleProc.running = state.textSizeWriteActive = false
state.pumpTextSize()
assertDeepEqual(state.textScaleProc.command, ['omarchy-display-text-size', '20'], 'rapid text-size requests apply the latest pending stop')
JS
