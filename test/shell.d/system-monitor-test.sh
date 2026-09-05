#!/bin/bash

# Headless coverage for the system monitor bar widget and its task manager
# panel. Everything worth testing lives in Model.js, so most of this runs the
# module under Node; the rest reads Panel.qml, the manifest and the default
# bar layout as source text. Nothing here launches Quickshell.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command jq

PLUGIN="$ROOT/shell/plugins/panels/system-monitor"

[[ -f $PLUGIN/manifest.json ]] || fail "the plugin ships a manifest"
[[ -f $PLUGIN/Panel.qml ]] || fail "the plugin ships a panel"
[[ -f $PLUGIN/Model.js ]] || fail "the plugin ships a model"
pass "the plugin ships a manifest, a panel and a model"

jq -e . "$PLUGIN/manifest.json" >/dev/null || fail "the manifest parses as JSON"
pass "the manifest parses as JSON"

jq -e '.kinds == ["bar-widget"] and .entryPoints.barWidget == "Panel.qml" and .id == "omarchy.system-monitor"' \
  "$PLUGIN/manifest.json" >/dev/null ||
  fail "the manifest declares one bar-widget entry point" "$(jq -c '{id, kinds, entryPoints}' "$PLUGIN/manifest.json")"
pass "the manifest declares one bar-widget entry point"

jq -e '(.bar.layout.right | map(.id)) | index("omarchy.system-monitor") != null' \
  "$ROOT/config/omarchy/shell.json" >/dev/null ||
  fail "the default bar layout carries the widget in its right section" \
    "$(jq -c '.bar.layout.right' "$ROOT/config/omarchy/shell.json")"
pass "the default bar layout carries the widget in its right section"

# The hardware drawer opens the monitor to explain a temperature or a fan, and
# processes are what explain those, so it has to ask for that view.
grep -q 'openView("processes")' "$ROOT/shell/plugins/bar/widgets/Sensors.qml" ||
  fail "the hardware drawer opens the monitor on its Processes view"
pass "the hardware drawer opens the monitor on its Processes view"

run_node_test <<'JS'
const fs = require('fs')
const monitor = requireFromRoot('shell/plugins/panels/system-monitor/Model.js')
const panel = fs.readFileSync(path.join(root, 'shell/plugins/panels/system-monitor/Panel.qml'), 'utf8')
const manifest = JSON.parse(fs.readFileSync(path.join(root, 'shell/plugins/panels/system-monitor/manifest.json'), 'utf8'))

// ------------------------------------------------------------- bar stats

assertDeepEqual(
  monitor.parseBarStats('cpu\t1000\t4000\nmemory\t42.50\nload\t1.25\n'),
  { cpuIdle: 1000, cpuTotal: 4000, memory: 42.5, load: 1.25 },
  'the bar stats line parses into counters, a percentage and a load average'
)

assertDeepEqual(
  monitor.parseBarStats(''),
  { cpuIdle: null, cpuTotal: null, memory: null, load: null },
  'empty stats output yields nulls rather than zeroes'
)

assertDeepEqual(
  monitor.parseBarStats('cpu\tnope\tnope\nmemory\t\nload\t-1\n'),
  { cpuIdle: null, cpuTotal: null, memory: null, load: null },
  'unparseable stats fields yield nulls rather than zeroes'
)

// ------------------------------------------------------------- CPU delta

const first = { cpuIdle: 1000, cpuTotal: 4000 }

assertEqual(
  monitor.cpuPercent(null, first),
  null,
  'the first sample has no previous reading, so there is no percentage to show'
)

assertEqual(
  monitor.cpuPercent(first, { cpuIdle: 1500, cpuTotal: 6000 }),
  75,
  'CPU is the busy share of the jiffies between two readings'
)

assertEqual(
  monitor.cpuPercent(first, { cpuIdle: 3000, cpuTotal: 6000 }),
  0,
  'a fully idle interval reads zero'
)

assertEqual(
  monitor.cpuPercent(first, { cpuIdle: 1000, cpuTotal: 6000 }),
  100,
  'an interval with no idle time reads one hundred'
)

assertEqual(
  monitor.cpuPercent(first, first),
  null,
  'two identical readings have no time between them, so there is nothing to divide by'
)

assertEqual(
  monitor.cpuPercent(first, { cpuIdle: 500, cpuTotal: 2000 }),
  null,
  'a total counter that went backwards yields no percentage'
)

assertEqual(
  monitor.cpuPercent(first, { cpuIdle: 900, cpuTotal: 6000 }),
  null,
  'an idle counter that went backwards yields no percentage'
)

assertEqual(
  monitor.cpuPercent(first, { cpuIdle: 9000, cpuTotal: 6000 }),
  null,
  'more idle than total is not a reading this can use'
)

assertEqual(monitor.cpuSample({ cpuIdle: null, cpuTotal: 4000 }), null, 'a half-read sample is not carried forward')
assertDeepEqual(monitor.cpuSample(first), first, 'a complete sample is carried forward')

// ------------------------------------------------------------ formatting

assertEqual(monitor.formatKb(0), '0 KB', 'zero bytes formats without a decimal')
assertEqual(monitor.formatKb(512), '512 KB', 'sub-megabyte values stay in KB')
assertEqual(monitor.formatKb(1536), '1.5 MB', 'kilobytes roll up into megabytes')
assertEqual(monitor.formatKb(16 * 1024 * 1024), '16.0 GB', 'kilobytes roll up into gigabytes')
assertEqual(monitor.formatKb(-1), '—', 'an unknown byte count prints an em dash, not a zero')
assertEqual(monitor.formatKb('nonsense'), '—', 'an unparseable byte count prints an em dash')

assertEqual(monitor.formatPercent(42.4, 0), '42%', 'percentages round to whole numbers by default')
assertEqual(monitor.formatPercent(42.44, 1), '42.4%', 'percentages can carry a decimal')
assertEqual(monitor.formatPercent(-1, 0), '—', 'the not-known-yet sentinel prints an em dash')
assertEqual(monitor.formatPercent(null, 0), '—', 'a missing percentage prints an em dash')

assertEqual(monitor.formatLoad(1.5), '1.50', 'load averages carry two decimals')
assertEqual(monitor.formatLoad(-1), '—', 'an unknown load average prints an em dash')

assertEqual(monitor.formatUsage(1024 * 1024, 4 * 1024 * 1024), '1.0 GB / 4.0 GB', 'used and total render as one pair')
assertEqual(monitor.formatUsage(1024, 0), '—', 'a zero total has no usage to report')

assertEqual(monitor.fraction(-1), 0, 'an unknown percentage fills nothing')
assertEqual(monitor.fraction(250), 1, 'a fraction never overfills its gauge')

// ---------------------------------------------------------------- memory

const meminfo = monitor.parseMeminfo([
  'MemTotal:       16000000 kB',
  'MemFree:         1000000 kB',
  'MemAvailable:    6000000 kB',
  'Buffers:          500000 kB',
  'Cached:          4000000 kB',
  'SReclaimable:     500000 kB',
  'SwapTotal:       8000000 kB',
  'SwapFree:        6000000 kB',
  ''
].join('\n'))

assertEqual(meminfo.totalKb, 16000000, 'meminfo reports the total')
assertEqual(meminfo.usedKb, 10000000, 'used memory is total minus available')
assertEqual(meminfo.cachedKb, 5000000, 'cache is page cache plus buffers plus reclaimable slab')
assertEqual(meminfo.swapUsedKb, 2000000, 'swap in use is total minus free')
assertDeepEqual(monitor.parseMeminfo('garbage'), {}, 'an unreadable meminfo yields nothing rather than zeroes')

// ----------------------------------------------------------------- views

assertEqual(monitor.normalizeView('processes'), 'processes', 'the processes view is a view')
assertEqual(monitor.normalizeView('nonsense'), 'apps', 'anything else is the apps view')
assertEqual(monitor.viewForIndex(1), 'processes', 'the second chip is the processes view')
assertEqual(monitor.viewForIndex(-3), 'apps', 'an index off the left lands on apps')
assertEqual(monitor.otherView('apps'), 'processes', 'the other view of apps is processes')
assertDeepEqual(monitor.viewOptions().map(o => o.value), ['apps', 'processes'], 'apps leads the view chips')

// ------------------------------------------------------------- processes

const rows = monitor.parseProcesses(JSON.stringify([
  { pid: 10, name: 'a', command: 'a --flag', cpu: 5, memory: 40, rssKb: 4000, uid: 1000 },
  { pid: 20, name: 'b', command: 'b', cpu: 90, memory: 1, rssKb: 100, uid: 1000 },
  { pid: 30, name: 'c', command: 'c', cpu: 50, memory: 20, rssKb: 2000, uid: 0 }
]))

assertEqual(rows.length, 3, 'the JSON array parses into rows')
assertDeepEqual(
  monitor.sortProcesses(rows, 'cpu').map(r => r.pid),
  [20, 30, 10],
  'sorting by CPU puts the busiest process first'
)
assertDeepEqual(
  monitor.sortProcesses(rows, 'memory').map(r => r.pid),
  [10, 30, 20],
  'sorting by memory puts the largest process first'
)
assertDeepEqual(
  monitor.sortProcesses(rows, 'nonsense').map(r => r.pid),
  [20, 30, 10],
  'an unknown sort key falls back to CPU'
)
assertDeepEqual(
  monitor.sortProcesses([{ pid: 9, cpu: 1, memory: 1 }, { pid: 2, cpu: 1, memory: 1 }], 'cpu').map(r => r.pid),
  [2, 9],
  'processes tied on both figures order by pid so the list does not reshuffle between samples'
)
assertEqual(monitor.otherSortKey('cpu'), 'memory', 'the sort key toggles to memory')
assertEqual(monitor.otherSortKey('memory'), 'cpu', 'and back to CPU')
assertDeepEqual(monitor.sortProcesses(null, 'cpu'), [], 'sorting nothing yields an empty list')
assertDeepEqual(monitor.parseProcesses('not json'), [], 'unparseable process output yields an empty list')
assertDeepEqual(monitor.parseProcesses('{"pid": 1}'), [], 'a non-array payload yields an empty list')
assertDeepEqual(monitor.parseProcesses('[{"pid": 0}, {"pid": -3}]'), [], 'rows without a usable pid are dropped')

// The sampler returns everything; the view caps the ranking until a filter
// lifts the cap.
const many = []
for (let i = 1; i <= 40; i++) many.push({ pid: i, name: 'p' + i, command: 'p' + i, cpu: 40 - i, memory: 0 })
assertEqual(monitor.limitProcesses(many, 10, '').length, 10, 'without a filter the list is capped at the configured limit')
assertEqual(monitor.limitProcesses(many, 10, 'p').length, 40, 'a filter lifts the cap so a search reaches every process')
assertEqual(monitor.limitProcesses(many, 2, '').length, 5, 'the cap never drops below five rows')
assertEqual(monitor.limitProcesses(many, 500, '').length, 40, 'the cap never exceeds the list')

// ----------------------------------------------------------------- filter

assertEqual(monitor.normalizeQuery('  Dis  CORD '), 'dis cord', 'queries fold case and whitespace')
assert(monitor.matchesQuery(['Discord', '/usr/bin/discord'], 'disc'), 'a filter matches a substring of any field')
assert(monitor.matchesQuery(['Zen Browser', 'zen'], 'zen brow'), 'every word of a filter has to match somewhere')
assert(!monitor.matchesQuery(['Zen Browser'], 'zen kitty'), 'a word that matches nothing fails the filter')
assert(monitor.matchesQuery(['a(b'], '('), 'a filter is a plain substring, never a regular expression')
assert(monitor.matchesQuery(['anything'], ''), 'an empty filter matches everything')
assertDeepEqual(
  monitor.filterProcesses(rows, 'FLAG').map(r => r.pid),
  [10],
  'processes filter on their command line'
)
assertDeepEqual(
  monitor.filterProcesses(rows, '20').map(r => r.pid),
  [20],
  'processes filter on their pid'
)
assertEqual(monitor.filterProcesses(rows, '').length, 3, 'an empty filter keeps every process')

// ---------------------------------------------------------------- windows

const windows = monitor.parseWindows([
  { address: '0x2', pid: 200, appId: 'zen', className: 'zen', title: 'Second tab', workspaceId: 2, mapped: true, name: 'Zen Browser', icon: 'zen', handle: { id: 'h2' } },
  { address: '0x1', pid: 100, appId: 'kitty', className: 'kitty', title: 'shell', workspaceId: 1, mapped: true, name: '', icon: '' },
  { address: '0x3', pid: 200, appId: 'zen', className: 'zen', title: 'First tab', workspaceId: 2, mapped: true, name: 'Zen Browser', icon: 'zen' },
  { address: '0x4', appId: 'fresh', className: 'fresh', title: 'no pid yet', workspaceId: 3 },
  { address: '', pid: 5, className: 'ghost' },
  { address: '0x5', pid: 6, className: 'special', title: 'hidden', hidden: true },
  { address: '0x6', pid: 7, className: 'unmapped', title: 'not yet', mapped: false },
  null,
  'nonsense'
])

assertEqual(windows.length, 4, 'a window needs an address and has to be mapped and not hidden')
assertEqual(windows.find(w => w.address === '0x4').pid, 0, 'a window without a pid keeps a zero pid rather than being dropped')
assertEqual(windows.find(w => w.address === '0x2').handle.id, 'h2', 'the live toplevel handle rides along untouched')
assertDeepEqual(
  monitor.sortWindows(windows).map(w => w.address),
  ['0x4', '0x1', '0x3', '0x2'],
  'windows group by app name, then by workspace and title'
)
assertEqual(monitor.windowName(windows.find(w => w.address === '0x2')), 'Zen Browser', 'a window is named by its desktop entry when one matched')
assertEqual(monitor.windowName(windows.find(w => w.address === '0x1')), 'kitty', 'a window with no entry falls back to its class')
assertEqual(monitor.windowName({ appId: 'foo' }), 'foo', 'a window with no class falls back to its app id')
assertEqual(monitor.windowName({}), 'window', 'a nameless window still has something to render')
assertEqual(monitor.windowDetail(windows.find(w => w.address === '0x1')), 'shell', 'the detail line is the title')
assertEqual(monitor.windowDetail({ className: 'kitty', title: '' }), 'kitty', 'an untitled window shows its class as detail')
assertEqual(monitor.windowWorkspaceLabel({ workspaceId: 3 }), '3', 'workspaces are labelled by number')
assertEqual(monitor.windowWorkspaceLabel({ workspaceId: -98 }), 'special', 'special workspaces are labelled as such')
assertEqual(monitor.windowWorkspaceLabel({}), '', 'an unknown workspace has no label')
const tooltip = monitor.windowTooltip(windows.find(w => w.address === '0x2'))
assert(tooltip.indexOf('pid 200') >= 0 && tooltip.indexOf('workspace 2') >= 0 && tooltip.indexOf('Second tab') >= 0, 'the window tooltip names pid, workspace and title')

const withUsage = monitor.attachUsage(monitor.sortWindows(windows), [
  { pid: 200, cpu: 12.5, rssKb: 4096 },
  { pid: 999, cpu: 1, rssKb: 1 }
])
assertEqual(withUsage.find(w => w.address === '0x2').cpu, 12.5, 'a window takes the CPU of its main process')
assertEqual(withUsage.find(w => w.address === '0x2').rssKb, 4096, 'a window takes the memory of its main process')
assertEqual(withUsage.find(w => w.address === '0x1').cpu, null, 'a window whose pid was not sampled reads unknown, not zero')
assertEqual(withUsage.find(w => w.address === '0x4').cpu, null, 'a window without a pid reads unknown')
assertEqual(monitor.formatPercent(withUsage.find(w => w.address === '0x1').cpu, 1), '—', 'unknown CPU renders as an em dash')
assertEqual(monitor.processMemory(withUsage.find(w => w.address === '0x1')), '—', 'unknown memory renders as an em dash')

assertDeepEqual(monitor.filterWindows(windows, 'ZEN').map(w => w.address).sort(), ['0x2', '0x3'], 'windows filter on their name and class')
assertDeepEqual(monitor.filterWindows(windows, 'second').map(w => w.address), ['0x2'], 'windows filter on their title')
assertDeepEqual(monitor.filterWindows(windows, '100').map(w => w.address), ['0x1'], 'windows filter on their pid')
assertEqual(monitor.filterWindows(windows, '').length, 4, 'an empty filter keeps every window')

assertEqual(monitor.emptyMessage('apps', '', true), 'No open windows', 'an empty apps view says so')
assertEqual(monitor.emptyMessage('apps', 'x', true), 'No open window matches', 'an empty filtered apps view says so')
assertEqual(monitor.emptyMessage('processes', '', true), 'Sampling…', 'a process view with no sample yet is sampling')
assertEqual(monitor.emptyMessage('processes', 'x', false), 'No process matches', 'an empty filtered process view says so')

// ------------------------------------------- hostile names and truncation

// A process names itself, and a window titles itself. Newlines, tabs, control
// characters, quotes, backslashes and shell metacharacters are all legal in a
// comm, a cmdline or a title, and every one of them is attacker-influenced.
const hostile = "evil$(touch /tmp/pwned) `id`; rm -rf ~ \"dq\" 'sq' \\back\ttab\nnewline\u001b[31mESC\u202ereversed"

const clean = monitor.sanitizeText(hostile, 0)
assert(clean.indexOf('\n') < 0, 'a newline in a process name never survives into a label')
assert(clean.indexOf('\t') < 0, 'a tab in a process name never survives into a label')
assert(clean.indexOf('\u001b') < 0, 'an escape sequence in a process name never survives into a label')
assert(clean.indexOf('\u0000') < 0, 'a NUL in a process name never survives into a label')
assert(clean.indexOf('\u202e') < 0, 'a bidi override in a process name never survives into a label')

assertEqual(monitor.sanitizeText('abcdefghij', 5), 'abcd…', 'long values truncate with an ellipsis')
assertEqual(monitor.sanitizeText('abcde', 5), 'abcde', 'a value at the limit is left alone')
assertEqual(monitor.sanitizeText('  spaced   out  ', 0), 'spaced out', 'runs of whitespace collapse')
assertEqual(monitor.sanitizeText(null, 10), '', 'a missing value sanitizes to an empty string')
assertEqual(monitor.processName({ name: '' }), 'process', 'a nameless row still has something to render')
assert(monitor.processName({ name: 'x'.repeat(500) }).length <= 32, 'a very long name is truncated for the row')
assert(monitor.processDetail({ command: 'y'.repeat(5000) }).length <= 120, 'a very long command line is truncated for the detail line')
assert(monitor.processTooltip({ pid: 7, command: 'z'.repeat(5000) }).length <= 420, 'a very long command line is truncated for the tooltip')
assert(monitor.windowName({ name: hostile }).indexOf('\n') < 0, 'a hostile window name renders sanitized')
assert(monitor.windowTitle({ title: 'w'.repeat(5000) }).length <= 120, 'a very long title is truncated for the row')
assert(monitor.windowTooltip({ pid: 7, title: hostile }).indexOf('\u001b') < 0, 'a hostile title renders sanitized in the tooltip')

// ---------------------------------------------------------- argument vectors

// Every command is an argument vector, and the only value that ever crosses
// into one is a pid.
const hostileRows = monitor.parseProcesses(JSON.stringify([
  { pid: 4242, name: hostile, command: hostile, cpu: 1, memory: 1, rssKb: 10, uid: 1000 }
]))
assertEqual(hostileRows.length, 1, 'a hostile row still parses')
assertEqual(hostileRows[0].name, hostile, 'the untouched name is kept as data')

const statsArgv = monitor.statsCommand()
assertDeepEqual(statsArgv, ['omarchy-system-stats', '--bar-widget'], 'the bar reads stats through an argument vector')

const listArgv = monitor.processesCommand(0.5)
assertDeepEqual(
  listArgv,
  ['omarchy-system-processes', '--interval', '0.5'],
  'the panel lists every process through an argument vector, with no limit'
)
assertDeepEqual(
  monitor.processesCommand(0),
  ['omarchy-system-processes'],
  'a zero interval is left to the command'
)
assertDeepEqual(monitor.meminfoCommand(), ['cat', '/proc/meminfo'], 'memory detail is read through an argument vector')

const termArgv = monitor.terminateCommand(hostileRows[0].pid)
assertDeepEqual(termArgv, ['kill', '-s', 'TERM', '4242'], 'ending a process sends SIGTERM to its pid')
const killArgv = monitor.forceKillCommand(hostileRows[0].pid)
assertDeepEqual(killArgv, ['kill', '-s', 'KILL', '4242'], 'force killing a process sends SIGKILL to its pid')
assertDeepEqual(monitor.signalCommand(4242, 'nonsense'), termArgv, 'an unknown signal name is SIGTERM, never anything stronger')

const everyArgv = [].concat(statsArgv, listArgv, monitor.meminfoCommand(), termArgv, killArgv)
assert(
  everyArgv.every(arg => arg.indexOf('evil') < 0 && arg.indexOf('rm -rf') < 0 && arg.indexOf('$(') < 0),
  'no part of a hostile process name reaches any command',
  everyArgv.join(' | ')
)
assert(
  everyArgv.every(arg => typeof arg === 'string' && arg.indexOf('\n') < 0 && arg.indexOf('\t') < 0),
  'every command argument is a plain single-line string'
)

// ---------------------------------------------------------------- signals

for (const argv of [termArgv, killArgv]) {
  assert(
    argv.indexOf('sudo') < 0 && argv.indexOf('pkexec') < 0 && argv.indexOf('bash') < 0 && argv.indexOf('sh') < 0,
    'signalling a process asks for no privilege and no shell'
  )
}

for (const command of [monitor.terminateCommand, monitor.forceKillCommand]) {
  assertEqual(command(0), null, 'pid 0 is every process in the group, so it is refused')
  assertEqual(command(1), null, 'pid 1 is refused')
  assertEqual(command(-4242), null, 'a negative pid is a process group, so it is refused')
  assertEqual(command(12.5), null, 'a fractional pid is refused')
  assertEqual(command('12; rm -rf ~'), null, 'a pid that is not a plain number is refused')
  assertEqual(command(null), null, 'a missing pid is refused')
}

// SIGKILL is an escalation, never a first move: a row offers it only once
// this panel has sent SIGTERM to its pid and the pid is still running.
const row = hostileRows[0]
assertEqual(monitor.signalFor(row, {}), 'TERM', 'a row nothing was sent to gets SIGTERM')
assertEqual(monitor.canForceKill(row, {}), false, 'a row nothing was sent to cannot be force killed')
const terminated = monitor.markTerminated({}, row.pid)
assertEqual(monitor.signalFor(row, terminated), 'KILL', 'a row already sent SIGTERM offers SIGKILL')
assertEqual(monitor.signalFor({ pid: 4243 }, terminated), 'TERM', 'the offer is per pid, not per panel')
assertEqual(monitor.canForceKill({ pid: 1 }, monitor.markTerminated({}, 1)), false, 'pid 1 is never force-killable, marked or not')
assertDeepEqual(monitor.markTerminated({}, 0), {}, 'marking pid 0 records nothing')
assertDeepEqual(monitor.markTerminated({}, -5), {}, 'marking a process group records nothing')
assertDeepEqual(
  monitor.pruneTerminated(terminated, [{ pid: 4243 }]),
  {},
  'a pid gone from the process list loses its offer'
)
assertDeepEqual(
  monitor.pruneTerminated(terminated, [{ pid: 4242 }, { pid: 4243 }]),
  { '4242': true },
  'a pid still running after SIGTERM keeps its offer'
)

const termMessage = monitor.signalMessage(row, 'TERM', false)
assert(termMessage.indexOf('4242') >= 0, 'the SIGTERM confirmation names the pid')
assert(termMessage.indexOf('SIGTERM') >= 0 && termMessage.indexOf('SIGKILL') < 0, 'the SIGTERM confirmation says which signal is sent')
assert(termMessage.indexOf('\n') < 0 && termMessage.indexOf('\u001b') < 0 && termMessage.indexOf('\u202e') < 0, 'the confirmation renders the name sanitized')
assertEqual(monitor.terminateMessage(row), termMessage, 'terminateMessage is the SIGTERM confirmation')

const killMessage = monitor.signalMessage(row, 'KILL', false)
assert(killMessage.indexOf('4242') >= 0, 'the SIGKILL confirmation names the pid')
assert(killMessage.indexOf('SIGKILL') >= 0 && killMessage.indexOf('SIGTERM') >= 0, 'the SIGKILL confirmation says SIGTERM was ignored and SIGKILL follows')
assert(/unsaved/i.test(killMessage), 'the SIGKILL confirmation says what is lost')
assert(monitor.signalMessage({ pid: 200, name: 'zen', className: 'zen', title: 't' }, 'TERM', true).indexOf('zen') >= 0, 'a window confirmation names the window')

assertEqual(monitor.signalActionLabel('TERM'), 'End', 'SIGTERM is labelled End')
assertEqual(monitor.signalActionLabel('KILL'), 'Force kill', 'SIGKILL is labelled Force kill')
assert(monitor.signalIcon('TERM') !== monitor.signalIcon('KILL'), 'the two signals have different icons')
assert(monitor.signalTooltip('KILL').indexOf('SIGKILL') >= 0, 'the force kill tooltip names the signal')

assertEqual(monitor.signalFailure(0, '', row, 'TERM', false), '', 'a successful signal reports nothing')
const failure = monitor.signalFailure(1, 'kill: (4242): Operation not permitted\n', row, 'TERM', false)
assert(failure.indexOf('Operation not permitted') >= 0, 'a refused signal surfaces what the kernel said')
assert(failure.indexOf('\n') < 0, 'the failure line stays on one line')
assert(
  monitor.signalFailure(1, '', row, 'TERM', false).indexOf('exited 1') >= 0,
  'a silent failure still reports the exit code rather than passing as success'
)
assert(monitor.signalFailure(1, '', row, 'KILL', false).indexOf('force kill') >= 0, 'a failed SIGKILL says which it was')
assertEqual(monitor.terminateFailure(1, 'x', row), monitor.signalFailure(1, 'x', row, 'TERM', false), 'terminateFailure is the SIGTERM failure')

// ------------------------------------------------------------ panel source

assert(/moduleName: "omarchy.system-monitor"/.test(panel), 'the panel declares its module name')
assert(/WidgetButton \{/.test(panel), 'the bar item is built from the shared widget button')
assert(/KeyboardPanel \{/.test(panel) && /PanelKeyCatcher \{/.test(panel), 'the popup uses the shared keyboard panel and key catcher')
assert((panel.match(/ButtonGroup \{/g) || []).length === 2, 'the view and the sort are shared ButtonGroups')
assert(/TextField \{/.test(panel), 'the filter is the shared text field')
assert(/blocked: filterField\.activeFocus/.test(panel), 'the key catcher steps aside while the filter has focus')
assert(/ConfirmDialog \{/.test(panel), 'signalling a process goes through the shared confirm dialog')
assert(/function apps\(\): void/.test(panel) && /function processes\(\): void/.test(panel), 'the IPC target can open either view')

// Nothing reaches a shell, nothing is escalated by the panel itself, and
// nothing spells a signal or a command outside the model.
assert(!/sudo|pkexec/.test(panel), 'the panel asks for no privilege')
assert(!/"-9"|"-s"|"kill"|"KILL"|"TERM"/.test(panel), 'the panel never spells a kill command or a signal name itself')
assert(!/execDetached|shellQuote|"bash"|"-lc"|hyprctl/.test(panel), 'the panel never hands anything to a shell')
assert(/signalProc\.command = argv/.test(panel), 'the signal command comes from the model as a vector')
assert(/Model\.signalCommand\(row\.pid, name\)/.test(panel), 'only the pid crosses into the signal command')
assert(/if \(!argv\)/.test(panel), 'a refused pid never reaches the process')
assert(
  /if \(name === Model\.KILL && !Model\.canForceKill\(row, root\.terminatedPids\)\) name = Model\.TERM/.test(panel),
  'SIGKILL is re-checked against the terminated set at the moment of sending'
)
assert(/Model\.signalFor\(/.test(panel), 'which signal a row offers comes from the model')
assert(/exitCode === 0 && name === Model\.TERM/.test(panel), 'only a delivered SIGTERM earns the force kill offer')
assert(/Model\.pruneTerminated\(root\.terminatedPids, rows\)/.test(panel), 'the force kill offer is pruned to running pids on every sample')
assert(/terminatedPids = \(\{\}\)/.test(panel), 'the force kill offers are dropped when the panel closes')
assert(/handle\.wayland\.close\(\)/.test(panel), 'closing a window asks the window, through its toplevel handle')
assert(/handle\.wayland\.activate\(\)/.test(panel), 'focusing a window goes through its toplevel handle')

// Every command the panel runs is a vector built in the model, never a string.
const commandLines = panel.split('\n').filter(line => /^\s*command:|\.command =/.test(line))
assert(commandLines.length > 0, 'the panel runs commands')
assert(
  commandLines.every(line => /Model\.[A-Za-z]+Command\(|= argv/.test(line)),
  'every command the panel runs is an argument vector built in the model',
  commandLines.join('\n')
)

// Reads are asynchronous and never overlap.
assert(/if \(statsProc\.running\) return/.test(panel), 'stats reads never overlap')
assert(/if \(meminfoProc\.running\) return/.test(panel), 'memory reads never overlap')
assert(/if \(processesProc\.running\) return/.test(panel), 'process reads never overlap')
assert(/StdioCollector/.test(panel) && !/blockingRead|waitForFinished/.test(panel), 'reads are collected asynchronously')

// Polling stops when nobody is looking.
assert(/running: root\.opened\n/.test(panel + '\n'), 'the process list only samples while the panel is open')
assert(/running: root\.visible \|\| root\.opened/.test(panel), 'the bar stops sampling once its item is gone')
assert(/if \(root\.opened\) root\.requestWindowRefresh\(\)/.test(panel), 'window changes only refresh the list while the panel is open')

// The first sample has nothing to subtract from.
assert(/property real cpuPercent: -1/.test(panel), 'CPU starts unknown rather than zero')
assert(/if \(percent !== null\) root\.cpuPercent = percent/.test(panel), 'a reading with no delta leaves the displayed value alone')

// Text that renders external data says so. A Text element left on
// Text.AutoText promotes a string that looks like markup to rich text, and a
// process can name itself anything at all.
const panelLines = panel.split('\n')
const bareText = []
for (let i = 0; i < panelLines.length; i++) {
  const opener = panelLines[i].match(/^(\s*)Text \{\s*$/)
  if (!opener) continue
  const indent = opener[1]
  let declared = false
  for (let j = i + 1; j < panelLines.length; j++) {
    if (panelLines[j] === indent + '}') break
    if (/^\s*textFormat: Text\.PlainText$/.test(panelLines[j])) declared = true
  }
  if (!declared) bareText.push('line ' + (i + 1))
}
assert(/^\s*Text \{$/m.test(panel), 'the panel paints text')
assertDeepEqual(bareText, [], 'every Text in the panel declares a plain text format')

// ----------------------------------------------------------------- manifest

assertEqual(manifest.id, 'omarchy.system-monitor', 'the manifest id matches the module name')
assertEqual(manifest.barWidget.allowMultiple, false, 'only one system monitor belongs on a bar')
assert(Array.isArray(manifest.barWidget.schema), 'the widget declares a settings schema')
assertDeepEqual(
  manifest.barWidget.schema.map(entry => entry.key).sort(),
  ['barIntervalSec', 'processIntervalSec', 'processLimit'],
  'the schema covers the poll intervals and the process limit'
)
assert(
  manifest.barWidget.schema.every(entry => entry.type === 'integer' && entry.min > 0 && entry.max >= entry.min),
  'every schema entry is a bounded integer'
)
JS
