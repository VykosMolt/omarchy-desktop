#!/bin/bash

# The settings panel has no compositor in this suite, so everything worth
# testing about it lives in Model.js: which settings exist, which mechanism
# backs each one, the duration choices and how they read, the parsers for every
# command's output, and the argument vector each command runs. Panel.qml is
# asserted against as source text -- that it uses the kit's lifecycle and key
# handling, that it never builds a command itself, and that it re-reads after a
# write instead of assuming one took.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

run_node_test <<'JS'
const fs = require('fs')
const settings = requireFromRoot('shell/plugins/panels/settings/Model.js')
const idle = requireFromRoot('shell/plugins/services/idle/IdleModel.js')
const panelSource = fs.readFileSync(path.join(root, 'shell/plugins/panels/settings/Panel.qml'), 'utf8')
const manifest = JSON.parse(fs.readFileSync(path.join(root, 'shell/plugins/panels/settings/manifest.json'), 'utf8'))
const menuSource = fs.readFileSync(path.join(root, 'default/omarchy/omarchy-menu.jsonc'), 'utf8')
const defaultShellConfig = JSON.parse(fs.readFileSync(path.join(root, 'config/omarchy/shell.json'), 'utf8'))

// ---------------------------------------------------------------- the module

assertEqual(manifest.id, 'omarchy.settings', 'the settings panel is omarchy.settings')
assertDeepEqual(manifest.kinds, ['panel'], 'the settings panel is a standalone panel, not a bar widget')
assertEqual(manifest.entryPoints.panel, 'Panel.qml', 'the panel entry point is Panel.qml')
assert(manifest.keepLoaded !== true, 'the settings panel loads on demand rather than at startup')

// ------------------------------------------------------------- the inventory

const shellOwned = settings.rows().filter(row => row.owner === 'shell').map(row => row.id)
const systemOwned = settings.rows().filter(row => row.owner === 'system').map(row => row.id)

assertDeepEqual(
  shellOwned,
  ['idle.screenOff', 'idle.lock', 'idle.suspend', 'bar.position', 'bar.transparent'],
  'the shell-owned settings are the ones that live in shell.json'
)
assertDeepEqual(
  systemOwned,
  [
    'idle.stayAwake',
    'appearance.theme',
    'appearance.iconTheme',
    'appearance.font',
    'appearance.textSize',
    'display.scale',
  ],
  'the system-owned settings are the ones a command reads and writes'
)
assert(
  settings.rows().every(row => row.owner === 'shell' || row.owner === 'system'),
  'every setting is backed by one of the two mechanisms and no third one'
)
assert(
  settings.rows().every(row => (row.owner === 'shell') === (row.configPath !== undefined)),
  'exactly the shell-owned settings name a path in shell.json'
)

// Ownership and who performs the write are separate questions. The bar's own
// command validates the position and patches the running bar, so a bar setting
// is shell-owned and still written by a command.
assertDeepEqual(
  ['idle.screenOff', 'idle.lock', 'idle.suspend'].map(settings.writeViaOf),
  ['config', 'config', 'config'],
  'the idle timings are written straight into shell.json'
)
assertDeepEqual(
  ['bar.position', 'bar.transparent'].map(settings.writeViaOf),
  ['command', 'command'],
  'the bar settings are written through omarchy-bar so the bar validates them'
)
assert(
  systemOwned.every(id => settings.writeViaOf(id) === 'command'),
  'every system-owned setting is written by running a command'
)

// Every setting shows up in exactly one section, and every section has content.
const sectionIds = settings.sections().map(section => section.id)
assertDeepEqual(sectionIds, ['power', 'appearance', 'bar', 'display'], 'the panel has four sections')
assert(
  sectionIds.every(id => settings.rowsInSection(id).length > 0),
  'no section is empty'
)
assert(
  settings.rows().every(row => sectionIds.indexOf(row.section) !== -1),
  'every setting belongs to a declared section'
)

// ------------------------------------------------------------------ durations

assertDeepEqual(
  settings.durationChoices(),
  [0, 60, 120, 300, 600, 900, 1800, 2700, 3600],
  'the duration choices are never, 1, 2, 5, 10, 15, 30 and 45 minutes, and an hour'
)
assertEqual(settings.durationLabel(0), 'Never', 'zero seconds reads as Never rather than as a number')
assertEqual(settings.durationLabel(-5), 'Never', 'a negative timeout reads as Never')
assertEqual(settings.durationLabel(30), '30 seconds', 'a sub-minute timeout reads in seconds')
assertEqual(settings.durationLabel(60), '1 minute', 'one minute is singular')
assertEqual(settings.durationLabel(300), '5 minutes', 'five minutes reads in minutes')
assertEqual(settings.durationLabel(2700), '45 minutes', 'forty-five minutes stays in minutes')
assertEqual(settings.durationLabel(3600), '1 hour', 'an hour reads as an hour')
assertEqual(settings.durationLabel(7200), '2 hours', 'two hours is plural')
assertEqual(settings.durationLabel(5400), '1 hour 30 minutes', 'a mixed timeout reads as both parts')

assertEqual(settings.durationOptions(300).length, 9, 'a timeout already on the list adds no option')
assertDeepEqual(
  settings.durationOptions(300)[3],
  { value: '300', label: '5 minutes' },
  'duration options carry string values so no type has to be guessed back'
)
// A hand-edited shell.json is not overruled by the panel: its value is offered
// alongside the presets rather than rounded into one of them.
const odd = settings.durationOptions(420)
assertEqual(odd.length, 10, 'a hand-edited timeout is offered alongside the presets')
assertDeepEqual(odd[4], { value: '420', label: '7 minutes' }, 'a hand-edited timeout keeps its own place in the list')

// The panel must never offer a value the idle service would reject, so it
// applies the same rule the service does.
for (const probe of ['42.9', '-1', 'nope', '0', '300', '']) {
  assertEqual(
    settings.secondsFromConfig(probe, 300),
    idle.secondsFromConfig(probe, 300),
    `the panel reads "${probe}" seconds exactly as the idle service does`
  )
}

// --------------------------------------------------------------- shell.json

const config = { version: 1, idle: { screenOff: 0, lock: 300, suspend: 900 }, bar: { position: 'left', transparent: true } }
assertEqual(settings.idleSeconds(config, 'screenOff'), 0, 'a stage set to zero reads as zero')
assertEqual(settings.idleSeconds(config, 'lock'), 300, 'the lock stage reads its configured seconds')
assertEqual(settings.idleSeconds(config, 'suspend'), 900, 'the suspend stage reads its configured seconds')
assertEqual(settings.idleSeconds({}, 'lock'), 300, 'a missing lock falls back to the shipped default')
assertEqual(settings.idleSeconds({}, 'screenOff'), 0, 'a missing screen off falls back to off')
assertEqual(settings.idleSeconds({}, 'suspend'), 0, 'a missing suspend falls back to off')
assertEqual(settings.barPosition(config), 'left', 'the bar position reads from shell.json')
assertEqual(settings.barPosition({ bar: { position: 'sideways' } }), 'top', 'an unknown bar position falls back to top')
assertEqual(settings.barTransparent(config), true, 'bar transparency reads from shell.json')
assertEqual(settings.barTransparent({}), false, 'a missing bar transparency reads as opaque')

// The defaults this port ships have to be readable by the panel that edits
// them, or the first thing a user sees is a wrong value.
assertEqual(settings.idleSeconds(defaultShellConfig, 'lock'), 300, 'the shipped defaults lock at five minutes')
assertEqual(settings.barPosition(defaultShellConfig), 'top', 'the shipped defaults put the bar on top')

// mutateShellConfig hands the mutator a copy to edit in place.
const mutated = { version: 1 }
settings.applyIdleSeconds(mutated, 'lock', '600')
assertDeepEqual(mutated.idle, { lock: 600 }, 'writing a stage creates the idle block when there is none')
settings.applyIdleSeconds(mutated, 'lock', 0)
assertEqual(mutated.idle.lock, 0, 'a stage can be turned off')
settings.applyIdleSeconds(mutated, 'suspend', -30)
assertEqual(mutated.idle.suspend, 0, 'a negative timeout is written as off, never as a negative')
assertEqual(mutated.version, 1, 'writing a stage leaves the rest of shell.json alone')

// ---------------------------------------------------------- idle timeline

// The three stages are independent: any order is legal and any of them may be
// off, so the panel describes them by when they fire rather than implying a
// fixed sequence.
assertDeepEqual(
  settings.idleTimeline({ idle: { screenOff: 600, lock: 300, suspend: 900 } }).map(stage => stage.stage),
  ['lock', 'screenOff', 'suspend'],
  'the timeline is ordered by when each stage fires, not by how it is listed'
)
assertDeepEqual(
  settings.idleTimeline({ idle: { screenOff: 0, lock: 0, suspend: 1800 } }).map(stage => stage.stage),
  ['suspend'],
  'a stage set to never is left out of the timeline entirely'
)
assertEqual(
  settings.idleSummary({ idle: { screenOff: 600, lock: 300, suspend: 0 } }, false),
  'After 5 minutes → lock, then 10 minutes → screen off',
  'the summary states each stage and when it fires'
)
assertEqual(
  settings.idleSummary({ idle: { screenOff: 0, lock: 0, suspend: 0 } }, false),
  'Nothing happens when the session goes idle.',
  'the summary says so plainly when every stage is off'
)
assertEqual(
  settings.idleSummary({ idle: { lock: 300 } }, true),
  'Staying awake: no idle stage will fire.',
  'Stay Awake overrides the timeline in the summary, the way it overrides it in the service'
)

// ------------------------------------------------------------------ choices

assertDeepEqual(settings.barPositionValues(), ['top', 'bottom', 'left', 'right'], 'the bar can sit on any edge')
assertDeepEqual(
  settings.barPositionOptions().map(option => option.label),
  ['Top', 'Bottom', 'Left', 'Right'],
  'bar positions are labelled for a person'
)

const textSizes = settings.textSizeOptions(12)
assertEqual(textSizes.length, 12, 'text size offers the 9 to 20 px range omarchy-display-text-size accepts')
assertEqual(textSizes[0].value, '9', 'text size starts at the smallest size the command accepts')
assertEqual(textSizes[textSizes.length - 1].value, '20', 'text size stops at the largest size the command accepts')
assertEqual(textSizes[3].label, '12 px (default)', 'the shell default text size is marked as the default')
assertEqual(settings.textSizeOptions(24).length, 13, 'a text size set outside the range is still offered')

assertDeepEqual(
  settings.monitorScaleOptions(1.6).map(option => option.value),
  ['1', '1.25', '1.6', '2', '3', '4'],
  'monitor scale offers the presets the scaling command names'
)
assertEqual(settings.scaleLabel('1.25'), '125%', 'a scale reads as a percentage')
// Hyprland rounds a requested scale up to one that divides the mode into whole
// pixels, so the scale in force is often not one of the presets. It has to be
// offered, or the panel would show the monitor sitting on a value it claims
// does not exist.
assertDeepEqual(
  settings.monitorScaleOptions(1.5).map(option => option.value),
  ['1', '1.25', '1.5', '1.6', '2', '3', '4'],
  'a monitor already on an off-preset scale keeps that scale in the list'
)
assertEqual(settings.normalizeScale('1.600000'), '1.6', 'hyprctl float noise compares equal to the preset it means')
assertEqual(settings.normalizeScale('0'), '', 'a scale of zero is no scale at all')

assertEqual(settings.moveRow(0, -1), 0, 'the cursor stops at the first setting')
assertEqual(settings.moveRow(settings.rowIds().length - 1, 1), settings.rowIds().length - 1, 'the cursor stops at the last setting')
assertEqual(settings.moveRow(0, 1), 1, 'the cursor walks the settings in order')

// ------------------------------------------------------------------ parsing

assertDeepEqual(
  settings.parseLines('  Tokyo Night \n\nCatppuccin\nTokyo Night\n'),
  ['Tokyo Night', 'Catppuccin'],
  'a command list is trimmed and deduplicated in the order it arrived'
)
assertEqual(settings.parseFirstLine('Tokyo Night\nCatppuccin\n'), 'Tokyo Night', 'the current value is the first line')
assertEqual(settings.parseFirstLine(''), '', 'no output is no value')

assertEqual(settings.parseIdleStatus('{"stayAwake":true,"enabled":false}').stayAwake, true, 'Stay Awake is read off the idle service status')
assertEqual(settings.parseIdleStatus('{"stayAwake":false}').stayAwake, false, 'the idle service reports Stay Awake off')
assertEqual(settings.parseIdleStatus('omarchy-shell is not running').ok, false, 'an unparseable idle status is a failed read, not a false')


const pinnedSize = settings.parseTextSize('text size: 16 px\ngtk text-scaling-factor: 1.3636\nterminal font: 12 pt\n')
assertEqual(pinnedSize.px, 16, 'a pinned text size is read from the first line')
assertEqual(pinnedSize.isDefault, false, 'a pinned text size is not the default')
const defaultSize = settings.parseTextSize('text size: 12 (default) px\ngtk text-scaling-factor: 1.0\nterminal font: 9 pt\n')
assertEqual(defaultSize.px, 12, 'an unpinned text size still reports the size in force')
assertEqual(defaultSize.isDefault, true, 'an unpinned text size is reported as the default')
assertEqual(settings.parseTextSize('command not found').ok, false, 'unreadable text size output is a failed read')

assertEqual(settings.parseMonitorScale('1.6\n').scale, '1.6', 'the focused monitor scale is read from the scaling command')
assertEqual(settings.parseMonitorScale('').ok, false, 'no scale output is a failed read')

// ----------------------------------------------------------------- commands

// Theme, icon-theme and font names carry spaces and quotes. Every command is
// an argument vector, so a name is one argument and never a fragment of a
// shell string.
const hostile = 'Tokyo Night"; rm -rf $HOME #'
assertDeepEqual(
  settings.writeCommand('appearance.theme', hostile),
  ['omarchy-theme-set', hostile],
  'a theme name reaches the command as a single unmodified argument'
)
assertDeepEqual(
  settings.writeCommand('appearance.iconTheme', hostile),
  ['omarchy-icon-theme', 'set', hostile],
  'an icon theme name reaches the command as a single unmodified argument'
)
assertDeepEqual(
  settings.writeCommand('appearance.font', hostile),
  ['omarchy-font-set', hostile],
  'a font name reaches the command as a single unmodified argument'
)

assertDeepEqual(settings.readCommand('appearance.theme'), ['omarchy-theme-current'], 'the current theme is read with omarchy-theme-current')
assertDeepEqual(settings.optionsCommand('appearance.theme'), ['omarchy-theme-list'], 'the theme choices come from omarchy-theme-list')
assertDeepEqual(settings.readCommand('appearance.iconTheme'), ['omarchy-icon-theme', 'get'], 'the icon theme is read with omarchy-icon-theme get')
assertDeepEqual(settings.optionsCommand('appearance.iconTheme'), ['omarchy-icon-theme', 'list'], 'the icon theme choices come from omarchy-icon-theme list')
assertDeepEqual(settings.readCommand('appearance.font'), ['omarchy-font-current'], 'the monospace font is read with omarchy-font-current')
assertDeepEqual(settings.optionsCommand('appearance.font'), ['omarchy-font-list'], 'the font choices come from omarchy-font-list')
assertDeepEqual(settings.readCommand('appearance.textSize'), ['omarchy-display-text-size'], 'the text size is read with omarchy-display-text-size')
assertDeepEqual(settings.writeCommand('appearance.textSize', 16), ['omarchy-display-text-size', '16'], 'the text size is written with omarchy-display-text-size')
assertDeepEqual(settings.readCommand('display.scale'), ['omarchy-hyprland-monitor-scaling'], 'the monitor scale is read with the scaling command')
assertDeepEqual(settings.writeCommand('display.scale', '1.6'), ['omarchy-hyprland-monitor-scaling', '1.6'], 'the monitor scale is written with the scaling command')
assertDeepEqual(settings.writeCommand('bar.position', 'left'), ['omarchy-bar', 'position', 'left'], 'the bar position goes through omarchy-bar')
assertDeepEqual(settings.writeCommand('bar.transparent', true), ['omarchy-bar', 'transparent', 'true'], 'bar transparency goes through omarchy-bar')
assertDeepEqual(settings.writeCommand('bar.transparent', false), ['omarchy-bar', 'transparent', 'false'], 'bar transparency can be turned off through omarchy-bar')

// Stay Awake is the idle service's state, not shell.json's, and on means idle
// off -- so the command is the inverse of the switch.
assertDeepEqual(settings.readCommand('idle.stayAwake'), ['omarchy-shell', 'idle', 'status'], 'Stay Awake is read over the idle service IPC')
assertDeepEqual(settings.writeCommand('idle.stayAwake', true), ['omarchy-shell', 'idle', 'disable'], 'turning Stay Awake on disables idle')
assertDeepEqual(settings.writeCommand('idle.stayAwake', false), ['omarchy-shell', 'idle', 'enable'], 'turning Stay Awake off re-enables idle')

// The idle timings are shell.json's, so no command writes them.
for (const id of ['idle.screenOff', 'idle.lock', 'idle.suspend']) {
  assertDeepEqual(settings.writeCommand(id, 300), [], `${id} is written through shell.json, not through a command`)
}

assert(settings.isArgumentVector(['omarchy-theme-set', 'Tokyo Night']), 'a full argument vector is usable')
assert(!settings.isArgumentVector([]), 'an empty vector is not a command')
assert(!settings.isArgumentVector(['omarchy-theme-set', undefined]), 'a vector with a missing argument is refused rather than run short')
assert(!settings.isArgumentVector(['omarchy-theme-set', '']), 'a vector with an empty argument is refused')
assert(!settings.isArgumentVector('omarchy-theme-set "Tokyo Night"'), 'a command string is not an argument vector')

assertEqual(
  settings.commandError(['omarchy-theme-set', 'Nope'], 1, "Theme 'nope' does not exist\n"),
  "omarchy-theme-set: Theme 'nope' does not exist",
  'a failure reports what the command said'
)
assertEqual(
  settings.commandError(['omarchy-bar', 'position', 'left'], 3, ''),
  'omarchy-bar exited 3',
  'a silent failure still reports the exit code'
)

// ------------------------------------------------------------- the panel QML

assert(/PanelController \{/.test(panelSource), 'the panel holds its open state in a PanelController')
assert(/PanelKeyCatcher \{/.test(panelSource), 'the panel navigates with the kit key catcher')
assert(/onCloseRequested: root\.dismiss\(\)/.test(panelSource), 'Escape closes the panel')
assert(/onMoveRequested/.test(panelSource) && /onActivateRequested/.test(panelSource), 'the panel walks and activates its rows from the keyboard')
assert(/blocked: root\.popupBlocking/.test(panelSource), 'an open dropdown owns the keyboard instead of double-driving the cursor')

// Every command lives in Model.js. The panel builds none of its own, so there
// is nowhere in it for a value to be interpolated into one.
const panelCode = panelSource.split('\n').filter(line => !/^\s*\/\//.test(line)).join('\n')
assert(!/\[\s*"omarchy-/.test(panelCode), 'the panel writes no command vector of its own')
const commandBindings = panelCode.match(/^\s*(?:\w+\.)?command\s*[:=][^\n]*/gm) || []
assert(commandBindings.length > 0, 'the panel runs commands')
assert(
  commandBindings.every(line => /Model\.(read|options|write)Command|next\.command/.test(line)),
  'every command the panel runs is one the model built',
  commandBindings.join('\n')
)
assert(!/\bbash\b/.test(panelCode), 'the panel runs no shell, so nothing it runs can be a string')
assert(!/\/bin\//.test(panelCode), 'the panel resolves commands on PATH rather than through a path')
assert(!/Quickshell\.shellDir/.test(panelSource), 'the panel does not derive paths from the shell directory')
assert(!/#[0-9a-fA-F]{3,8}\b/.test(panelSource), 'the panel hardcodes no colour')

// Reading is asynchronous and writing is honest.
assert(/component Reader: Process \{/.test(panelSource), 'every system-owned value is read by running a process')
assert(
  /function finishWrite\(\) \{[\s\S]*?root\.refreshRow\(rowId\)/.test(panelSource),
  'a write is followed by a re-read rather than by an assumption that it took'
)
assert(
  /root\.setError\(rowId, Model\.commandError\(writeProcess\.command/.test(panelSource),
  'a failed write puts the command failure on the row instead of swallowing it'
)
assert(
  /shell\.mutateShellConfig\(function\(config\) \{ Model\.applyIdleSeconds/.test(panelSource),
  'the idle timings are written through the shell config mutator'
)
assert(
  /readonly property var shellConfig: root\.shell && root\.shell\.shellConfig/.test(panelSource),
  'shell-owned values are read from the live shell config, never from a private copy'
)

// ------------------------------------------------------------------ the menu

const settingsRow = menuSource.split('\n').find(line => line.includes('"setup.settings"'))
assert(!!settingsRow, 'the menu carries a Settings row under Setup')
assert(settingsRow.includes('"label":"Settings"'), 'the Settings row is labelled Settings')
assert(
  settingsRow.includes('omarchy-shell shell toggle omarchy.settings'),
  'the Settings row toggles the settings panel'
)
assert(!settingsRow.includes('aliases'), 'a new menu entry ships no aliases')

// The panel is reachable but not imposed: it is not on the default bar and it
// takes no keybinding.
const shippedLayout = JSON.stringify(defaultShellConfig.bar.layout)
assert(!shippedLayout.includes('omarchy.settings'), 'the settings panel is not put on the default bar')
JS

# Every command any row of the panel can run has to exist in this checkout, or
# a setting is a dead control.
commands=$(ROOT="$ROOT" node -e '
const model = require(process.env.ROOT + "/shell/plugins/panels/settings/Model.js")
const out = new Set()
for (const id of model.rowIds()) {
  for (const command of [model.readCommand(id), model.optionsCommand(id), model.writeCommand(id, "probe")]) {
    if (Array.isArray(command) && command.length > 0) out.add(command[0])
  }
}
process.stdout.write([...out].sort().join("\n"))
')

[[ -n $commands ]] || fail "the settings panel names at least one command"

while IFS= read -r command; do
  [[ -x "$ROOT/bin/$command" ]] || fail "every command the settings panel runs exists in bin/" "missing: $command"
done <<<"$commands"
pass "every command the settings panel runs exists in bin/"

# The panel is a first-party plugin, so it is discovered and enabled without a
# shell.json entry; nothing may quietly add one.
if rg -q 'omarchy\.settings' "$ROOT/config/omarchy/shell.json"; then
  fail "the settings panel is not written into the shipped shell.json"
fi
pass "the settings panel needs no shell.json entry"

if rg -q 'omarchy\.settings' "$ROOT/config/hypr" "$ROOT/default/hypr"; then
  fail "the settings panel takes no keybinding"
fi
pass "the settings panel takes no keybinding"
