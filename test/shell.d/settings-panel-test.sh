#!/bin/bash

# The settings panel has no compositor in this suite, so everything worth
# testing about it lives in Model.js: which categories exist, which settings
# sit in each, which mechanism backs every one, how a value reads, the parsers
# for every command's output, and the argument vector each command runs.
# Panel.qml is asserted against as source text -- that it uses the kit's
# lifecycle and key handling, that it renders whatever the model names rather
# than wiring settings one at a time, that it never builds a command itself,
# and that it re-reads after a write instead of assuming one took.

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

assertDeepEqual(
  shellOwned.slice().sort(),
  ['bar.position', 'bar.transparent', 'idle.lock', 'idle.screenOff', 'idle.suspend'],
  'the shell-owned settings are the ones that live in shell.json'
)
assert(
  settings.rows().every(row => row.owner === 'shell' || row.owner === 'system'),
  'every setting is backed by one of the two mechanisms and no third one'
)
assert(
  settings.rows().every(row => (row.owner === 'shell') === (row.configPath !== undefined)),
  'exactly the shell-owned settings name a path in shell.json'
)
assert(
  settings.rows().every(row => row.owner === 'system' || row.option === undefined),
  'a Hyprland option is never claimed to live in shell.json'
)

// Ownership and who performs the write are separate questions. The bar's own
// command validates the position and patches the running bar, so a bar setting
// is shell-owned and still written by a command.
assertDeepEqual(
  ['idle.screenOff', 'idle.lock', 'idle.suspend'].map(settings.writeViaOf),
  ['config', 'config', 'config'],
  'the idle timings are written straight into shell.json'
)
assert(
  settings.rows().filter(row => row.writeVia === 'config').every(row => row.id.indexOf('idle.') === 0),
  'the idle timings are the only settings written without a command'
)
assertDeepEqual(
  ['bar.position', 'bar.transparent'].map(settings.writeViaOf),
  ['command', 'command'],
  'the bar settings are written through omarchy-bar so the bar validates them'
)

// Every setting shows up in exactly one category, every category has content,
// and no two settings share an id.
const sectionIds = settings.sectionIds()
assertDeepEqual(
  sectionIds,
  ['appearance', 'wallpaper', 'bar', 'windows', 'input', 'touchpad', 'display', 'power', 'notifications', 'defaults', 'keys'],
  'the panel covers appearance, wallpaper, bar, windows, input, touchpad, display, power, notifications, defaults and keys'
)
assert(sectionIds.every(id => settings.rowsInSection(id).length > 0), 'no category is empty')
assert(
  settings.rows().every(row => sectionIds.indexOf(row.section) !== -1),
  'every setting belongs to a declared category'
)
assert(
  settings.sections().every(section => section.name && section.title && section.caption),
  'every category has a sidebar name, a heading, and a line saying what it covers'
)
assertEqual(
  new Set(settings.rowIds()).size,
  settings.rowIds().length,
  'no two settings share an id'
)

// Each control kind is one the panel knows how to render.
const kinds = ['duration', 'switch', 'choice', 'search', 'group', 'slider', 'action', 'list']
assert(
  settings.rows().every(row => kinds.indexOf(row.kind) !== -1),
  'every setting names a control the panel can draw',
  settings.rows().filter(row => kinds.indexOf(row.kind) === -1).map(row => row.id + ': ' + row.kind).join(', ')
)

// ------------------------------------------------------------------ cursor

// j/k stays inside the category on screen; Tab is what moves between them.
assertEqual(settings.moveRow('bar', 0, -1), 0, 'the cursor stops at the first setting of a category')
assertEqual(settings.moveRow('bar', 1, 1), 1, 'the cursor stops at the last setting of a category')
assertEqual(settings.moveRow('bar', 0, 1), 1, 'the cursor walks a category in order')
assertEqual(settings.moveSection(0, -1), 0, 'Tab stops at the first category')
assertEqual(settings.moveSection(sectionIds.length - 1, 1), sectionIds.length - 1, 'Tab stops at the last category')
assertEqual(settings.rowIndex('bar.transparent'), 1, 'a row knows where it sits in its own category')
assertEqual(settings.firstRowIn('bar'), 'bar.position', 'a category knows which row the cursor lands on')

// ------------------------------------------------------------------ durations

assertDeepEqual(
  settings.displayOptions('idle.lock', 0, []).map(option => Number(option.value)),
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

// The panel carries every value as a string, so a shell-owned row has to hand
// one back in the same shape a command-backed row would.
assertEqual(settings.shellValue('idle.lock', config), '300', 'a shell-owned timeout reads back as a string')
assertEqual(settings.shellValue('bar.transparent', config), 'true', 'a shell-owned switch reads back as true or false')
assertEqual(settings.shellValue('bar.position', config), 'left', 'a shell-owned choice reads back as its value')
assertEqual(settings.shellValue('appearance.theme', config), '', 'a command-backed row has no value in shell.json')

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

assertDeepEqual(
  settings.barPositionOptions(),
  [
    { value: 'top', label: 'Top' },
    { value: 'bottom', label: 'Bottom' },
    { value: 'left', label: 'Left' },
    { value: 'right', label: 'Right' }
  ],
  'the bar can sit on any edge, each labelled for a person'
)

const textSizes = settings.textSizeOptions(12)
assertEqual(textSizes.length, 12, 'text size offers the 9 to 20 px range omarchy-display-text-size accepts')
assertEqual(textSizes[0].value, '9', 'text size starts at the smallest size the command accepts')
assertEqual(textSizes[textSizes.length - 1].value, '20', 'text size stops at the largest size the command accepts')
assertEqual(textSizes[3].label, '12 px (default)', 'the shell default text size is marked as the default')
assertEqual(settings.textSizeOptions(24).length, 13, 'a text size set outside the range is still offered')

// omarchy-cursor-theme accepts 8 to 128 px, so every size offered has to sit
// inside that or the panel offers a value the command refuses.
const cursorSizes = settings.cursorSizeOptions(24)
assert(
  cursorSizes.every(option => Number(option.value) >= 8 && Number(option.value) <= 128),
  'every cursor size offered is one omarchy-cursor-theme accepts'
)
assertEqual(settings.cursorSizeOptions(23).length, cursorSizes.length + 1, 'a cursor size set outside the presets is still offered')

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

// A row whose choices come from a command shows what the command listed, plus
// whatever is actually in force -- a theme installed and then removed would
// otherwise show as nothing at all.
const listed = [{ value: 'Papirus', label: 'Papirus' }]
assertDeepEqual(
  settings.displayOptions('appearance.iconTheme', 'Papirus', listed),
  listed,
  'a value the command listed is not offered twice'
)
assertDeepEqual(
  settings.displayOptions('appearance.iconTheme', 'Gone', listed).map(option => option.value),
  ['Papirus', 'Gone'],
  'a value nothing listed is still shown, so the row never reads as empty'
)
assertDeepEqual(
  settings.displayOptions('bar.position', 'top', []).map(option => option.value),
  ['top', 'bottom', 'left', 'right'],
  'a row with fixed choices ignores whatever a command might have listed'
)
assertDeepEqual(
  settings.displayOptions('input.followMouse', '1', []).find(option => option.value === '1'),
  { value: '1', label: 'Focus follows the pointer' },
  'a choice offers a label a person can read, not the number Hyprland stores'
)

// ------------------------------------------------------------------ sliders

const gaps = settings.sliderSpec('windows.gapsIn')
assertEqual(gaps.integer, true, 'a pixel setting steps in whole pixels')
assertEqual(settings.sliderValue('windows.gapsIn', 7.4), '7', 'a slider snaps to a value the option accepts')
assertEqual(settings.sliderValue('windows.gapsIn', -5), '0', 'a slider never sends a value below its floor')
assertEqual(settings.sliderValue('windows.gapsIn', 500), '40', 'a slider never sends a value above its ceiling')
assertEqual(settings.sliderLabel('windows.gapsIn', 5), '5 px', 'a pixel setting reads in pixels')
assertEqual(settings.sliderLabel('windows.activeOpacity', 0.87), '85%', 'an opacity reads as a percentage of its own step')
assertEqual(settings.sliderLabel('input.repeatRate', 40), '40', 'a setting with no unit reads as a bare number')
assertEqual(settings.sliderSpec('bar.position'), null, 'a row that is not a slider has no slider to describe')
assert(
  settings.rows().filter(row => row.kind === 'slider').every(row => {
    const spec = settings.sliderSpec(row.id)
    return spec && isFinite(spec.minimum) && isFinite(spec.maximum) && spec.step > 0 && spec.maximum > spec.minimum
  }),
  'every slider names a range and a step it can actually walk'
)

// ------------------------------------------------------------------ parsing

assertDeepEqual(
  settings.parseLines('  Tokyo Night \n\nCatppuccin\nTokyo Night\n'),
  ['Tokyo Night', 'Catppuccin'],
  'a command list is trimmed and deduplicated in the order it arrived'
)
assertEqual(settings.parseFirstLine('Tokyo Night\nCatppuccin\n'), 'Tokyo Night', 'the current value is the first line')
assertEqual(settings.parseFirstLine(''), '', 'no output is no value')

assertDeepEqual(
  settings.parseTabbedOptions('Tokyo Night\nCatppuccin\n'),
  [{ value: 'Tokyo Night', label: 'Tokyo Night' }, { value: 'Catppuccin', label: 'Catppuccin' }],
  'a list of bare names is read as values that are their own labels'
)
assertDeepEqual(
  settings.parseTabbedOptions('/pics/a b.png\tA B\nzen\tZen\n'),
  [{ value: '/pics/a b.png', label: 'A B' }, { value: 'zen', label: 'Zen' }],
  'a list that names a value and a label keeps them apart, spaces and all'
)

assertEqual(settings.parseIdleStatus('{"stayAwake":true,"enabled":false}').stayAwake, true, 'Stay Awake is read off the idle service status')
assertEqual(settings.parseIdleStatus('{"stayAwake":false}').stayAwake, false, 'the idle service reports Stay Awake off')
assertEqual(settings.parseIdleStatus('omarchy-shell is not running').ok, false, 'an unparseable idle status is a failed read, not a false')

assertEqual(settings.parseTextSize('text size: 16 px\ngtk text-scaling-factor: 1.3636\nterminal font: 12 pt\n').px, 16,
  'a pinned text size is read from the first line')
assertEqual(settings.parseTextSize('text size: 12 (default) px\ngtk text-scaling-factor: 1.0\nterminal font: 9 pt\n').px, 12,
  'an unpinned text size still reports the size in force')
assertEqual(settings.parseTextSize('command not found').ok, false, 'unreadable text size output is a failed read')

assertEqual(settings.parseMonitorScale('1.6\n').scale, '1.6', 'the focused monitor scale is read from the scaling command')
assertEqual(settings.parseMonitorScale('').ok, false, 'no scale output is a failed read')

assertEqual(
  settings.parseActiveProfile('power-saver\t0\nbalanced\t0\nperformance\t1\n'),
  'performance',
  'the power profile in force is the one marked active'
)
assertEqual(settings.parseActiveProfile('power-saver\t0\nbalanced\t0\n'), '', 'no active profile is no value')

// A css option such as gaps_in reads back as four numbers and is set with one,
// and hyprctl spells an unset string option "[[EMPTY]]".
assertEqual(settings.parseOptionValue('windows.gapsIn', '5 5 5 5\n'), '5', 'a four-value gap reads back as the one number that set it')
assertEqual(settings.parseOptionValue('input.accelProfile', '[[EMPTY]]\n'), '', 'an unset string option reads as unset, not as the word hyprctl prints')
assertEqual(settings.parseOptionValue('windows.layout', 'dwindle\n'), 'dwindle', 'a string option reads back as itself')

// One answer shape for every read, whatever the command said.
assertDeepEqual(settings.parseValue('idle.stayAwake', '{"stayAwake":true}'), { ok: true, value: 'true' }, 'a switch reads back as true or false')
assertDeepEqual(settings.parseValue('windows.blur', 'false\n'), { ok: true, value: 'false' }, 'a Hyprland switch reads back as true or false')
assertDeepEqual(settings.parseValue('windows.gapsIn', '5 5 5 5\n'), { ok: true, value: '5' }, 'a Hyprland slider reads back as one number')
assertDeepEqual(settings.parseValue('appearance.theme', 'Tokyo Night\n'), { ok: true, value: 'Tokyo Night' }, 'a name reads back as itself')
assertEqual(settings.parseValue('appearance.theme', '').ok, false, 'a command that said nothing is a failed read')
assertEqual(settings.parseValue('input.accelProfile', '[[EMPTY]]\n').ok, true, 'a string option that is legitimately unset is still a successful read')
assertEqual(settings.parseValue('keys.list', 'SUPER + Q\t→ Close\n').value.length > 0, true, 'the keybinding list keeps every line it was given')

assertDeepEqual(
  settings.parseLines('SUPER + Q  → Close window\n\nSUPER + S  → Settings\n'),
  ['SUPER + Q  → Close window', 'SUPER + S  → Settings'],
  'the keybinding list drops blank lines and keeps the order the menu produced'
)

// ----------------------------------------------------------------- commands

// Theme, icon-theme, font and wallpaper names carry spaces and quotes. Every
// command is an argument vector, so a name is one argument and never a
// fragment of a shell string.
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
  settings.writeCommand('appearance.cursorTheme', hostile),
  ['omarchy-cursor-theme', 'set', hostile],
  'a cursor theme name reaches the command as a single unmodified argument'
)
assertDeepEqual(
  settings.writeCommand('appearance.font', hostile),
  ['omarchy-font-set', hostile],
  'a font name reaches the command as a single unmodified argument'
)
assertDeepEqual(
  settings.writeCommand('wallpaper.image', '/pics/a b".png'),
  ['omarchy-theme-bg-set', '/pics/a b".png'],
  'a wallpaper path reaches the command as a single unmodified argument'
)

assertDeepEqual(settings.writeCommand('bar.transparent', true), ['omarchy-bar', 'transparent', 'true'], 'bar transparency goes through omarchy-bar')
assertDeepEqual(settings.writeCommand('bar.transparent', false), ['omarchy-bar', 'transparent', 'false'], 'bar transparency can be turned off through omarchy-bar')

// Silencing is the notification service's own do-not-disturb, which is what
// the bar indicator and the keybinding both drive. Writing a toggle flag
// instead flipped a file nothing reads.
assertDeepEqual(settings.parseValue('notifications.silenced', 'on\n'), { ok: true, value: 'true' }, 'the service answers on or off; the panel carries true or false')
assertDeepEqual(settings.parseValue('notifications.silenced', 'off\n'), { ok: true, value: 'false' }, 'silencing off reads as a switch that is off')
assertEqual(settings.parseValue('notifications.silenced', '').ok, false, 'no answer from the service is a failed read, not a false')
assertDeepEqual(settings.writeCommand('notifications.silenced', true), ['omarchy-shell', 'notifications', 'setDnd', 'true'], 'silencing is set on the service that owns it')

// Stay Awake is the idle service's state, not shell.json's, and on means idle
// off -- so the command is the inverse of the switch.
assertDeepEqual(settings.writeCommand('idle.stayAwake', true), ['omarchy-shell', 'idle', 'disable'], 'turning Stay Awake on disables idle')
assertDeepEqual(settings.writeCommand('idle.stayAwake', false), ['omarchy-shell', 'idle', 'enable'], 'turning Stay Awake off re-enables idle')

// The idle timings are shell.json's, so no command writes them.
for (const id of ['idle.screenOff', 'idle.lock', 'idle.suspend']) {
  assertDeepEqual(settings.writeCommand(id, 300), [], `${id} is written through shell.json, not through a command`)
}

// ------------------------------------------------------- the Hyprland rows

// Naming an option rather than a command is what keeps thirty Hyprland
// settings from being thirty hand-written vectors, so the generated vectors
// are what has to be pinned.
const optionRows = settings.rows().filter(row => row.option !== undefined)
assert(optionRows.length >= 20, 'the panel reaches Hyprland for the settings Hyprland owns', String(optionRows.length))
assert(
  optionRows.every(row => /^[a-z]+(:[a-z_-]+)+$/.test(row.option)),
  'every Hyprland setting names an option the way Hyprland names it',
  optionRows.filter(row => !/^[a-z]+(:[a-z_-]+)+$/.test(row.option)).map(row => row.id).join(', ')
)
assertEqual(
  new Set(optionRows.map(row => row.option)).size,
  optionRows.length,
  'no two settings claim the same Hyprland option'
)
assert(
  optionRows.every(row => {
    const read = settings.readCommand(row.id)
    const write = settings.writeCommand(row.id, '1')
    return read[0] === 'omarchy-hyprland-setting' && read[1] === 'get' && read[2] === row.option &&
      write[0] === 'omarchy-hyprland-setting' && write[1] === 'set' && write[2] === row.option
  }),
  'every Hyprland setting is read and written through the one command that records what it set'
)
assertDeepEqual(
  settings.writeCommand('windows.blur', true),
  ['omarchy-hyprland-setting', 'set', 'decoration:blur:enabled', 'true'],
  'a switch is written as the word Hyprland expects, not as a number'
)
// hyprctl has no way of being handed nothing, so clearing an option is a reset
// -- which is also the only way to hand a key back to the config files.
assertDeepEqual(
  settings.writeCommand('input.accelProfile', ''),
  ['omarchy-hyprland-setting', 'reset', 'input:accel_profile'],
  'choosing the device default drops the override rather than writing an empty string'
)

// Every vector, spelled out. A command that exists is not the same as a
// command called the way it takes its arguments: a power profile handed to
// omarchy-powerprofiles-set without the power source in front of it lands in
// the wrong argument, and a silencing switch written to a toggle flag nothing
// reads flips happily while notifications keep arriving. Both shipped. A row
// added or rewired has to be written down here too, where it can be read
// against the command it names.
const expectedReads = {
  'appearance.theme': ['omarchy-theme-current'],
  'appearance.iconTheme': ['omarchy-icon-theme', 'get'],
  'appearance.cursorTheme': ['omarchy-cursor-theme', 'get'],
  'appearance.cursorSize': ['omarchy-cursor-theme', 'size'],
  'appearance.font': ['omarchy-font-current'],
  'appearance.textSize': ['omarchy-display-text-size'],
  'wallpaper.image': ['omarchy-theme-bg-current', '--path'],
  'display.scale': ['omarchy-hyprland-monitor-scaling'],
  'idle.stayAwake': ['omarchy-shell', 'idle', 'status'],
  'power.profile': ['omarchy-powerprofiles-list', '--active-state'],
  'notifications.silenced': ['omarchy-shell', 'notifications', 'dndState'],
  'defaults.browser': ['omarchy-default-browser'],
  'defaults.editor': ['omarchy-default-editor'],
  'keys.list': ['omarchy-menu-keybindings', '--print']
}
const expectedOptions = {
  'appearance.theme': ['omarchy-theme-list'],
  'appearance.iconTheme': ['omarchy-icon-theme', 'list'],
  'appearance.cursorTheme': ['omarchy-cursor-theme', 'list'],
  'appearance.font': ['omarchy-font-list'],
  'wallpaper.image': ['omarchy-theme-bg-list'],
  'power.profile': ['omarchy-powerprofiles-list'],
  'defaults.browser': ['omarchy-default-browser', '--list'],
  'defaults.editor': ['omarchy-default-editor', '--list']
}
const expectedWrites = {
  'idle.stayAwake': ['omarchy-shell', 'idle', 'enable'],
  'appearance.theme': ['omarchy-theme-set', 'X'],
  'appearance.iconTheme': ['omarchy-icon-theme', 'set', 'X'],
  'appearance.cursorTheme': ['omarchy-cursor-theme', 'set', 'X'],
  'appearance.cursorSize': ['omarchy-cursor-theme', 'size', 'X'],
  'appearance.font': ['omarchy-font-set', 'X'],
  'appearance.textSize': ['omarchy-display-text-size', 'X'],
  'wallpaper.image': ['omarchy-theme-bg-set', 'X'],
  'wallpaper.next': ['omarchy-theme-bg-next'],
  'wallpaper.folders': ['omarchy-menu-theme-bg-dir', 'add'],
  'bar.position': ['omarchy-bar', 'position', 'X'],
  'bar.transparent': ['omarchy-bar', 'transparent', 'false'],
  'display.scale': ['omarchy-hyprland-monitor-scaling', 'X'],
  'power.profile': ['omarchy-powerprofiles-set', 'autodetect', 'X'],
  'notifications.silenced': ['omarchy-shell', 'notifications', 'setDnd', 'false'],
  'defaults.browser': ['omarchy-default-browser', 'X'],
  'defaults.editor': ['omarchy-default-editor', 'X'],
  'keys.edit': ['omarchy-launch-config-editor', 'hypr/bindings.lua']
}

for (const id of settings.rowIds()) {
  const option = settings.row(id).option
  const read = settings.readCommand(id)
  const write = settings.writeCommand(id, 'X')

  if (option) {
    assertDeepEqual(read, ['omarchy-hyprland-setting', 'get', option], `${id} reads its Hyprland option`)
    assertDeepEqual(write, ['omarchy-hyprland-setting', 'set', option, 'X'], `${id} writes its Hyprland option`)
    continue
  }

  assertDeepEqual(read, expectedReads[id] || [], `${id} reads with the arguments its command takes`)
  assertDeepEqual(write, expectedWrites[id] || [], `${id} writes with the arguments its command takes`)
  assertDeepEqual(settings.optionsCommand(id), expectedOptions[id] || [], `${id} lists its choices with the arguments its command takes`)
}
pass('every command runs with the arguments the command it names actually takes')

assertDeepEqual(
  settings.rowIds().filter(settings.opensWindow),
  ['wallpaper.folders', 'keys.edit'],
  'the rows whose command puts a window on screen are the folder picker and the editor'
)

assert(settings.isArgumentVector(['omarchy-theme-set', 'Tokyo Night']), 'a full argument vector is usable')
assert(!settings.isArgumentVector([]), 'an empty vector is not a command')
assert(!settings.isArgumentVector(['omarchy-theme-set', undefined]), 'a vector with a missing argument is refused rather than run short')
assert(!settings.isArgumentVector(['omarchy-theme-set', '']), 'a vector with an empty argument is refused')
assert(!settings.isArgumentVector('omarchy-theme-set "Tokyo Night"'), 'a command string is not an argument vector')

// A control with nothing behind it is a dead row, so every row has to be
// reachable by one of the two mechanisms.
assert(
  settings.rows().every(row =>
    row.owner === 'shell' ||
    settings.isArgumentVector(settings.readCommand(row.id)) ||
    settings.isArgumentVector(settings.writeCommand(row.id, 'probe'))),
  'no row is a control with nothing behind it',
  settings.rows().filter(row => row.owner === 'system' &&
    !settings.isArgumentVector(settings.readCommand(row.id)) &&
    !settings.isArgumentVector(settings.writeCommand(row.id, 'probe'))).map(row => row.id).join(', ')
)
// A row the user can change but the panel cannot read back would show the last
// thing clicked rather than what took.
assert(
  settings.rows().every(row =>
    row.kind === 'action' ||
    row.owner === 'shell' ||
    settings.isArgumentVector(settings.readCommand(row.id))),
  'every setting the panel can change, it can also read back'
)

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
assert(/onTabRequested: function\(direction\) \{ root\.moveSection\(direction\) \}/.test(panelSource), 'Tab walks the categories')
assert(/blocked: root\.popupBlocking/.test(panelSource), 'an open dropdown owns the keyboard instead of double-driving the cursor')

// The panel renders the inventory rather than repeating it. A setting named in
// Panel.qml is a setting that would have to be added twice.
const panelCode = panelSource.split('\n').filter(line => !/^\s*\/\//.test(line)).join('\n')
const namedRows = settings.rowIds().filter(id => panelCode.includes('"' + id + '"'))
assertDeepEqual(namedRows, [], 'the panel names no setting of its own; it draws what the model lists')
assert(
  /Repeater \{\s*model: Model\.rowsInSection\(root\.currentSection\)/.test(panelCode),
  'the rows on screen are the ones the model puts in the category on screen'
)
assert(
  /Repeater \{\s*model: Model\.sections\(\)/.test(panelCode),
  'the categories down the side are the ones the model declares'
)

// Every command lives in Model.js. The panel builds none of its own, so there
// is nowhere in it for a value to be interpolated into one.
assert(!/\[\s*"omarchy-/.test(panelCode), 'the panel writes no command vector of its own')
// Two hops now: a reader holds the vector the model built and binds its
// command to it, and the write process is handed one straight from the queue.
// Both ends have to trace back to Model.js and nowhere else.
const commandBindings = panelCode.match(/^\s*(?:\w+\.)?command\s*[:=][^\n]*/gm) || []
const vectorBindings = panelCode.match(/^\s*vector\s*:[^\n]*/gm) || []
assert(commandBindings.length > 0 && vectorBindings.length > 0, 'the panel runs commands')
assert(
  commandBindings.every(line => /reader\.vector|next\.command/.test(line)),
  'the panel only ever runs a vector it was handed',
  commandBindings.join('\n')
)
assert(
  vectorBindings.every(line => /Model\.(read|options)Command/.test(line)),
  'every vector a reader is handed is one the model built',
  vectorBindings.join('\n')
)
assert(
  /root\.writeQueue = root\.writeQueue\.concat\(\[\{ rowId: String\(rowId\), command: command \}\]\)/.test(panelCode) &&
  /var command = Model\.writeCommand\(rowId, value\)/.test(panelCode),
  'the only thing the write queue ever carries is a vector the model built'
)
assert(!/\bbash\b/.test(panelCode), 'the panel runs no shell, so nothing it runs can be a string')
assert(!/\/bin\//.test(panelCode), 'the panel resolves commands on PATH rather than through a path')
assert(!/Quickshell\.shellDir/.test(panelSource), 'the panel does not derive paths from the shell directory')
assert(!/#[0-9a-fA-F]{3,8}\b/.test(panelSource), 'the panel hardcodes no colour')

// Reading is asynchronous, lazy, and writing is honest.
assert(/component Reader: Process \{/.test(panelSource), 'every system-owned value is read by running a process')
assert(
  /function refreshSection\(sectionId\)/.test(panelSource) && !/function refreshAll\(/.test(panelSource),
  'the panel reads the category on screen rather than every command it knows'
)
assert(
  /function finishWrite\(\) \{[\s\S]*?root\.refreshRow\(rowId\)/.test(panelSource),
  'a write is followed by a re-read rather than by an assumption that it took'
)
assert(
  /root\.setError\(rowId \+ "\.write", Model\.commandError\(writeProcess\.command/.test(panelSource),
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
assert(
  /if \(Model\.opensWindow\(rowId\)\) root\.dismiss\(\)/.test(panelSource),
  'the panel gets out of the way before running a command that opens a window of its own'
)
// A slider that wrote on every frame of a drag would run a command per pixel.
assert(
  /onReleased: function\(v\) \{[\s\S]{0,200}?root\.apply\(/.test(panelSource) && !/onMoved: function\(v\) \{[\s\S]{0,120}?root\.apply\(/.test(panelSource),
  'a slider writes when it is let go, not on every pixel of the drag'
)

// Exercise error persistence through the mandatory read after a failed write.
const vm = require('vm')
const state = {
  errors: {},
  values: {},
  optionLists: {},
  writeRow: 'appearance.font',
  writeProcess: { code: 1, command: ['omarchy-font-set', 'bad'], errorText: 'font unavailable' },
  Model: settings,
  refreshRow: () => {},
  pumpWrites: () => {},
  Qt: { callLater: () => {} }
}
state.root = state
vm.createContext(state)
for (const name of ['errorFor', 'setError', 'clearError', 'valueOf', 'isLoaded', 'storeValue', 'storeOptions', 'finishRead', 'finishWrite']) {
  const fn = panelSource.match(new RegExp('  function ' + name + '\\([^]*?\\n  }'))
  vm.runInContext(fn[0], state)
}
state.finishWrite()
state.finishRead({ rowId: 'appearance.font', wantsOptions: false, code: 0, outputText: 'previous font', vector: ['omarchy-font-current'] })
assert(state.errorFor('appearance.font').includes('font unavailable'), 'successful reread cannot erase a failed write error')
assertEqual(state.values['appearance.font'], 'previous font', 'a successful read stores what the command answered')
state.writeRow = 'appearance.font'
state.writeProcess.code = 0
state.finishWrite()
assertEqual(state.errorFor('appearance.font'), '', 'a successful retry clears the write error')

// A row is showing a value exactly when its command has answered, and an
// answer of "" is an answer: an unset Hyprland option reads as nothing, and a
// row that called that "still reading" would sit on a placeholder forever.
assertEqual(state.isLoaded('windows.blur'), false, 'a row that has not been read yet says so')
state.storeValue('windows.blur', 'false')
assertEqual(state.isLoaded('windows.blur'), true, 'a row that has been read is done reading')
state.storeValue('input.accelProfile', '')
assertEqual(state.isLoaded('input.accelProfile'), true, 'an option that is legitimately unset has still been read')
assertEqual(state.valueOf('input.accelProfile'), '', 'an unset option reads back as unset')

// A command that exits non-zero must not leave the old value on screen as if
// it were still true.
state.finishRead({ rowId: 'appearance.theme', wantsOptions: false, code: 127, vector: ['omarchy-theme-current'], errorText: '' })
assert(state.errorFor('appearance.theme').includes('omarchy-theme-current'), 'a failed read names the command that failed')

// ------------------------------------------------------------------ the menu

const settingsRow = menuSource.split('\n').find(line => line.includes('"setup.settings"'))
assert(!!settingsRow, 'the menu carries a Settings row under Setup')
assert(settingsRow.includes('"label":"Settings"'), 'the Settings row is labelled Settings')
assert(
  settingsRow.includes('omarchy-shell shell toggle omarchy.settings'),
  'the Settings row toggles the settings panel'
)
assert(!settingsRow.includes('aliases'), 'a new menu entry ships no aliases')

// Reachable from the menu and from SUPER + S, but not imposed: it is not on
// the default bar.
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
