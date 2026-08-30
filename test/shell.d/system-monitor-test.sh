#!/bin/bash

# Headless coverage for the system monitor bar widget and panel. Everything
# worth testing lives in Model.js, so most of this runs the module under Node;
# the rest reads Panel.qml, the manifest and the default bar layout as source
# text. Nothing here launches Quickshell.

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
assertDeepEqual(monitor.sortProcesses(null, 'cpu'), [], 'sorting nothing yields an empty list')
assertDeepEqual(monitor.parseProcesses('not json'), [], 'unparseable process output yields an empty list')
assertDeepEqual(monitor.parseProcesses('{"pid": 1}'), [], 'a non-array payload yields an empty list')
assertDeepEqual(monitor.parseProcesses('[{"pid": 0}, {"pid": -3}]'), [], 'rows without a usable pid are dropped')

// ------------------------------------------- hostile names and truncation

// A process names itself. Newlines, tabs, control characters, quotes,
// backslashes and shell metacharacters are all legal in a comm or a cmdline,
// and every one of them is attacker-influenced.
const hostile = "evil$(touch /tmp/pwned) `id`; rm -rf ~ \"dq\" 'sq' \\back\ttab\nnewline\u001b[31mESC"

const clean = monitor.sanitizeText(hostile, 0)
assert(clean.indexOf('\n') < 0, 'a newline in a process name never survives into a label')
assert(clean.indexOf('\t') < 0, 'a tab in a process name never survives into a label')
assert(clean.indexOf('\u001b') < 0, 'an escape sequence in a process name never survives into a label')
assert(clean.indexOf('\u0000') < 0, 'a NUL in a process name never survives into a label')

assertEqual(monitor.sanitizeText('abcdefghij', 5), 'abcd…', 'long values truncate with an ellipsis')
assertEqual(monitor.sanitizeText('abcde', 5), 'abcde', 'a value at the limit is left alone')
assertEqual(monitor.sanitizeText('  spaced   out  ', 0), 'spaced out', 'runs of whitespace collapse')
assertEqual(monitor.sanitizeText(null, 10), '', 'a missing value sanitizes to an empty string')
assertEqual(monitor.processName({ name: '' }), 'process', 'a nameless row still has something to render')
assert(monitor.processName({ name: 'x'.repeat(500) }).length <= 32, 'a very long name is truncated for the row')
assert(monitor.processDetail({ command: 'y'.repeat(5000) }).length <= 120, 'a very long command line is truncated for the detail line')
assert(monitor.processTooltip({ pid: 7, command: 'z'.repeat(5000) }).length <= 420, 'a very long command line is truncated for the tooltip')

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

const listArgv = monitor.processesCommand(25, 0.5)
assertDeepEqual(
  listArgv,
  ['omarchy-system-processes', '--limit', '25', '--interval', '0.5'],
  'the panel lists processes through an argument vector'
)
assertDeepEqual(
  monitor.processesCommand(99999, 0),
  ['omarchy-system-processes', '--limit', '100'],
  'the process limit is clamped and a zero interval is left to the command'
)
assertDeepEqual(monitor.meminfoCommand(), ['cat', '/proc/meminfo'], 'memory detail is read through an argument vector')

const killArgv = monitor.terminateCommand(hostileRows[0].pid)
assertDeepEqual(killArgv, ['kill', '-s', 'TERM', '4242'], 'ending a process sends SIGTERM to its pid')

const everyArgv = [].concat(statsArgv, listArgv, monitor.meminfoCommand(), killArgv)
assert(
  everyArgv.every(arg => arg.indexOf('evil') < 0 && arg.indexOf('rm -rf') < 0 && arg.indexOf('$(') < 0),
  'no part of a hostile process name reaches any command',
  everyArgv.join(' | ')
)
assert(
  everyArgv.every(arg => typeof arg === 'string' && arg.indexOf('\n') < 0 && arg.indexOf('\t') < 0),
  'every command argument is a plain single-line string'
)

// -------------------------------------------------------------- terminate

assert(
  killArgv.indexOf('sudo') < 0 && killArgv.indexOf('pkexec') < 0 && killArgv.indexOf('bash') < 0 && killArgv.indexOf('sh') < 0,
  'ending a process asks for no privilege and no shell'
)
assert(
  killArgv.indexOf('-9') < 0 && killArgv.indexOf('KILL') < 0 && killArgv.indexOf('SIGKILL') < 0,
  'ending a process never sends SIGKILL'
)

assertEqual(monitor.terminateCommand(0), null, 'pid 0 is every process in the group, so it is refused')
assertEqual(monitor.terminateCommand(1), null, 'pid 1 is refused')
assertEqual(monitor.terminateCommand(-4242), null, 'a negative pid is a process group, so it is refused')
assertEqual(monitor.terminateCommand(12.5), null, 'a fractional pid is refused')
assertEqual(monitor.terminateCommand('12; rm -rf ~'), null, 'a pid that is not a plain number is refused')
assertEqual(monitor.terminateCommand(null), null, 'a missing pid is refused')

const message = monitor.terminateMessage(hostileRows[0])
assert(message.indexOf('4242') >= 0, 'the confirmation names the pid')
assert(message.indexOf('SIGTERM') >= 0, 'the confirmation says which signal is sent')
assert(message.indexOf('\n') < 0 && message.indexOf('\u001b') < 0, 'the confirmation renders the name sanitized')

assertEqual(monitor.terminateFailure(0, '', hostileRows[0]), '', 'a successful signal reports nothing')
const failure = monitor.terminateFailure(1, 'kill: (4242): Operation not permitted\n', hostileRows[0])
assert(failure.indexOf('Operation not permitted') >= 0, 'a refused signal surfaces what the kernel said')
assert(failure.indexOf('\n') < 0, 'the failure line stays on one line')
assert(
  monitor.terminateFailure(1, '', hostileRows[0]).indexOf('exited 1') >= 0,
  'a silent failure still reports the exit code rather than passing as success'
)

// ------------------------------------------------------------ panel source

assert(/moduleName: "omarchy.system-monitor"/.test(panel), 'the panel declares its module name')
assert(/WidgetButton \{/.test(panel), 'the bar item is built from the shared widget button')
assert(/KeyboardPanel \{/.test(panel) && /PanelKeyCatcher \{/.test(panel), 'the popup uses the shared keyboard panel and key catcher')
assert(/ButtonGroup \{/.test(panel), 'the sort choice is a shared ButtonGroup')
assert(/ConfirmDialog \{/.test(panel), 'ending a process goes through the shared confirm dialog')

// Nothing reaches a shell, and nothing is escalated.
assert(!/sudo|pkexec/.test(panel), 'the panel asks for no privilege')
assert(!/SIGKILL|"-9"|"KILL"/.test(panel), 'the panel never sends SIGKILL')
assert(!/execDetached|shellQuote|"bash"|"-lc"/.test(panel), 'the panel never hands anything to a shell')
assert(/terminateProc\.command = argv/.test(panel), 'the terminate command comes from the model as a vector')
assert(/Model\.terminateCommand\(row\.pid\)/.test(panel), 'only the pid crosses into the terminate command')
assert(/if \(!argv\)/.test(panel), 'a refused pid never reaches the process')

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
