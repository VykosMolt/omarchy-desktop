// Everything the settings panel decides that is not painting: which categories
// exist, which settings sit in each, which mechanism backs every one of them,
// how a value reads as a sentence, how a command's output is parsed, and the
// exact argument vector every read and write runs. Panel.qml keeps only
// presentation and wiring, so all of this stays testable under Node without a
// compositor.

// ------------------------------------------------------------------ mechanism

// Two mechanisms, and only two.
//
//   owner "shell"   the value lives in shell.json and is read from
//                   shell.shellConfig, which the shell keeps current.
//   owner "system"  the value lives outside the shell and is read by running
//                   a command.
//
// `writeVia` is a separate question from ownership: a shell-owned setting is
// written either straight through shell.mutateShellConfig ("config") or by a
// command that owns its validation and live patching ("command"). The bar
// settings are shell-owned and still go through omarchy-bar, because the bar
// validates the position and patches the running bar itself.
//
// A row with an `option` is system-owned like any other; the command it runs is
// omarchy-hyprland-setting, which reads the live compositor and records what it
// wrote so a reload does not undo it. Naming the option rather than the command
// keeps forty Hyprland settings from being forty hand-written argument vectors.

var SECTIONS = [
  {
    id: "appearance",
    name: "Appearance",
    title: "APPEARANCE",
    caption: "Theme, icons, pointer, and type for this desktop and the apps that follow it."
  },
  {
    id: "wallpaper",
    name: "Wallpaper",
    title: "WALLPAPER",
    caption: "The image behind everything, and the folders the picker scans for more."
  },
  {
    id: "bar",
    name: "Bar",
    title: "BAR",
    caption: "Where the bar sits and whether it paints its own background."
  },
  {
    id: "windows",
    name: "Windows",
    title: "WINDOWS",
    caption: "How windows are tiled, framed, and animated. These take effect as you set them."
  },
  {
    id: "input",
    name: "Mouse & keyboard",
    title: "MOUSE & KEYBOARD",
    caption: "Pointer speed and what the keyboard does when a key is held down."
  },
  {
    id: "touchpad",
    name: "Touchpad",
    title: "TOUCHPAD",
    caption: "Scrolling, clicking, and what happens while you type."
  },
  {
    id: "display",
    name: "Display",
    title: "DISPLAY",
    caption: "The focused monitor."
  },
  {
    id: "power",
    name: "Power & lock",
    title: "POWER & LOCK",
    caption: "Each stage counts from the moment the session goes idle, and they are independent — any order is allowed, and Never turns one off."
  },
  {
    id: "notifications",
    name: "Notifications",
    title: "NOTIFICATIONS",
    caption: "Whether anything is allowed to interrupt."
  },
  {
    id: "defaults",
    name: "Default apps",
    title: "DEFAULT APPS",
    caption: "What opens a link or a file. Only what is installed is offered."
  },
  {
    id: "keys",
    name: "Keybindings",
    title: "KEYBINDINGS",
    caption: "Every chord this session answers to. Editing them opens your own bindings file."
  }
]

var ROWS = [
  // ---- appearance
  {
    id: "appearance.theme",
    section: "appearance",
    kind: "search",
    label: "Theme",
    owner: "system",
    writeVia: "command"
  },
  {
    id: "appearance.iconTheme",
    section: "appearance",
    kind: "search",
    label: "Icon theme",
    hint: "GTK, Qt, and KDE apps together.",
    owner: "system",
    writeVia: "command"
  },
  {
    id: "appearance.cursorTheme",
    section: "appearance",
    kind: "search",
    label: "Cursor theme",
    hint: "Apps already running keep the pointer they were handed.",
    owner: "system",
    writeVia: "command"
  },
  {
    id: "appearance.cursorSize",
    section: "appearance",
    kind: "choice",
    label: "Cursor size",
    owner: "system",
    writeVia: "command"
  },
  {
    id: "appearance.font",
    section: "appearance",
    kind: "search",
    label: "Monospace font",
    owner: "system",
    writeVia: "command"
  },
  {
    id: "appearance.textSize",
    section: "appearance",
    kind: "choice",
    label: "Text size",
    hint: "Shell, GTK apps, and terminals together.",
    owner: "system",
    writeVia: "command"
  },

  // ---- wallpaper
  {
    id: "wallpaper.image",
    section: "wallpaper",
    kind: "search",
    label: "Background",
    owner: "system",
    writeVia: "command"
  },
  {
    id: "wallpaper.next",
    section: "wallpaper",
    kind: "action",
    label: "Next background",
    actionLabel: "Shuffle",
    owner: "system",
    writeVia: "command"
  },
  {
    id: "wallpaper.folders",
    section: "wallpaper",
    kind: "action",
    label: "Wallpaper folders",
    actionLabel: "Add a folder",
    hint: "Everything one level inside a folder you add is offered above.",
    owner: "system",
    writeVia: "command",
    opensWindow: true
  },

  // ---- bar
  {
    id: "bar.position",
    section: "bar",
    kind: "group",
    label: "Position",
    owner: "shell",
    writeVia: "command",
    configPath: ["bar", "position"],
    defaultValue: "top"
  },
  {
    id: "bar.transparent",
    section: "bar",
    kind: "switch",
    label: "Transparent",
    owner: "shell",
    writeVia: "command",
    configPath: ["bar", "transparent"],
    defaultValue: false
  },

  // ---- windows
  {
    id: "windows.layout",
    section: "windows",
    kind: "group",
    label: "Tiling layout",
    owner: "system",
    writeVia: "command",
    option: "general:layout"
  },
  {
    id: "windows.gapsIn",
    section: "windows",
    kind: "slider",
    label: "Gaps between windows",
    owner: "system",
    writeVia: "command",
    option: "general:gaps_in",
    minimum: 0,
    maximum: 40,
    step: 1,
    integer: true,
    unit: "px"
  },
  {
    id: "windows.gapsOut",
    section: "windows",
    kind: "slider",
    label: "Gaps around the screen",
    owner: "system",
    writeVia: "command",
    option: "general:gaps_out",
    minimum: 0,
    maximum: 80,
    step: 1,
    integer: true,
    unit: "px"
  },
  {
    id: "windows.borderSize",
    section: "windows",
    kind: "slider",
    label: "Border width",
    owner: "system",
    writeVia: "command",
    option: "general:border_size",
    minimum: 0,
    maximum: 12,
    step: 1,
    integer: true,
    unit: "px"
  },
  {
    id: "windows.rounding",
    section: "windows",
    kind: "slider",
    label: "Corner rounding",
    owner: "system",
    writeVia: "command",
    option: "decoration:rounding",
    minimum: 0,
    maximum: 24,
    step: 1,
    integer: true,
    unit: "px"
  },
  {
    id: "windows.activeOpacity",
    section: "windows",
    kind: "slider",
    label: "Focused window opacity",
    owner: "system",
    writeVia: "command",
    option: "decoration:active_opacity",
    minimum: 0.4,
    maximum: 1,
    step: 0.05,
    percent: true
  },
  {
    id: "windows.inactiveOpacity",
    section: "windows",
    kind: "slider",
    label: "Unfocused window opacity",
    owner: "system",
    writeVia: "command",
    option: "decoration:inactive_opacity",
    minimum: 0.4,
    maximum: 1,
    step: 0.05,
    percent: true
  },
  {
    id: "windows.blur",
    section: "windows",
    kind: "switch",
    label: "Blur behind windows",
    owner: "system",
    writeVia: "command",
    option: "decoration:blur:enabled"
  },
  {
    id: "windows.shadow",
    section: "windows",
    kind: "switch",
    label: "Drop shadows",
    owner: "system",
    writeVia: "command",
    option: "decoration:shadow:enabled"
  },
  {
    id: "windows.animations",
    section: "windows",
    kind: "switch",
    label: "Animations",
    owner: "system",
    writeVia: "command",
    option: "animations:enabled"
  },

  // ---- mouse & keyboard
  {
    id: "input.sensitivity",
    section: "input",
    kind: "slider",
    label: "Pointer speed",
    hint: "0 is the speed libinput picks for the device.",
    owner: "system",
    writeVia: "command",
    option: "input:sensitivity",
    minimum: -1,
    maximum: 1,
    step: 0.05
  },
  {
    id: "input.accelProfile",
    section: "input",
    kind: "group",
    label: "Acceleration",
    owner: "system",
    writeVia: "command",
    option: "input:accel_profile"
  },
  {
    id: "input.naturalScroll",
    section: "input",
    kind: "switch",
    label: "Natural scrolling",
    owner: "system",
    writeVia: "command",
    option: "input:natural_scroll"
  },
  {
    id: "input.followMouse",
    section: "input",
    kind: "choice",
    label: "Focus follows the pointer",
    owner: "system",
    writeVia: "command",
    option: "input:follow_mouse"
  },
  {
    id: "input.repeatDelay",
    section: "input",
    kind: "slider",
    label: "Delay before a key repeats",
    owner: "system",
    writeVia: "command",
    option: "input:repeat_delay",
    minimum: 150,
    maximum: 800,
    step: 10,
    integer: true,
    unit: "ms"
  },
  {
    id: "input.repeatRate",
    section: "input",
    kind: "slider",
    label: "Repeats per second",
    owner: "system",
    writeVia: "command",
    option: "input:repeat_rate",
    minimum: 10,
    maximum: 80,
    step: 1,
    integer: true
  },
  {
    id: "input.numlock",
    section: "input",
    kind: "switch",
    label: "Num Lock on at login",
    owner: "system",
    writeVia: "command",
    option: "input:numlock_by_default"
  },

  // ---- touchpad
  {
    id: "touchpad.naturalScroll",
    section: "touchpad",
    kind: "switch",
    label: "Natural scrolling",
    owner: "system",
    writeVia: "command",
    option: "input:touchpad:natural_scroll"
  },
  {
    id: "touchpad.scrollFactor",
    section: "touchpad",
    kind: "slider",
    label: "Scroll speed",
    owner: "system",
    writeVia: "command",
    option: "input:touchpad:scroll_factor",
    minimum: 0.1,
    maximum: 2,
    step: 0.05
  },
  {
    id: "touchpad.tapToClick",
    section: "touchpad",
    kind: "switch",
    label: "Tap to click",
    owner: "system",
    writeVia: "command",
    option: "input:touchpad:tap-to-click"
  },
  {
    id: "touchpad.clickfinger",
    section: "touchpad",
    kind: "switch",
    label: "Two fingers for right click",
    hint: "Off puts right click in the lower-right corner of the pad instead.",
    owner: "system",
    writeVia: "command",
    option: "input:touchpad:clickfinger_behavior"
  },
  {
    id: "touchpad.disableWhileTyping",
    section: "touchpad",
    kind: "switch",
    label: "Ignore the pad while typing",
    owner: "system",
    writeVia: "command",
    option: "input:touchpad:disable_while_typing"
  },

  // ---- display
  {
    id: "display.scale",
    section: "display",
    kind: "choice",
    label: "Monitor scale",
    hint: "Hyprland only accepts scales that divide the mode into whole pixels, so the value can settle above the one you pick.",
    owner: "system",
    writeVia: "command"
  },

  // ---- power & lock
  {
    id: "idle.screenOff",
    section: "power",
    kind: "duration",
    label: "Turn the screen off",
    owner: "shell",
    writeVia: "config",
    configPath: ["idle", "screenOff"],
    defaultValue: 0
  },
  {
    id: "idle.lock",
    section: "power",
    kind: "duration",
    label: "Lock the session",
    owner: "shell",
    writeVia: "config",
    configPath: ["idle", "lock"],
    defaultValue: 300
  },
  {
    id: "idle.suspend",
    section: "power",
    kind: "duration",
    label: "Suspend the system",
    owner: "shell",
    writeVia: "config",
    configPath: ["idle", "suspend"],
    defaultValue: 0
  },
  {
    id: "idle.stayAwake",
    section: "power",
    kind: "switch",
    label: "Stay awake",
    hint: "Holds every stage off until you turn this back off.",
    owner: "system",
    writeVia: "command"
  },
  {
    id: "power.profile",
    section: "power",
    kind: "choice",
    label: "Power profile",
    owner: "system",
    writeVia: "command"
  },

  // ---- notifications
  {
    id: "notifications.silenced",
    section: "notifications",
    kind: "switch",
    label: "Silence notifications",
    hint: "They still arrive and still land in the history; nothing pops up.",
    owner: "system",
    writeVia: "command"
  },

  // ---- default apps
  {
    id: "defaults.browser",
    section: "defaults",
    kind: "search",
    label: "Browser",
    owner: "system",
    writeVia: "command"
  },
  {
    id: "defaults.editor",
    section: "defaults",
    kind: "search",
    label: "Editor",
    owner: "system",
    writeVia: "command"
  },

  // ---- keybindings
  {
    id: "keys.list",
    section: "keys",
    kind: "list",
    label: "Bindings",
    owner: "system",
    writeVia: "command"
  },
  {
    id: "keys.edit",
    section: "keys",
    kind: "action",
    label: "Your own bindings",
    actionLabel: "Edit",
    hint: "Opens hypr/bindings.lua, which is loaded after the defaults.",
    owner: "system",
    writeVia: "command",
    opensWindow: true
  }
]

function sections() {
  return SECTIONS.slice()
}

function sectionIds() {
  var out = []
  for (var i = 0; i < SECTIONS.length; i++) out.push(SECTIONS[i].id)
  return out
}

function section(id) {
  for (var i = 0; i < SECTIONS.length; i++) {
    if (SECTIONS[i].id === String(id)) return SECTIONS[i]
  }
  return null
}

function sectionIndex(id) {
  for (var i = 0; i < SECTIONS.length; i++) {
    if (SECTIONS[i].id === String(id)) return i
  }
  return -1
}

// Clamped rather than wrapping, the same way the row cursor is: the ends of a
// list are where a user expects a cursor to stop.
function moveSection(index, delta) {
  var next = Number(index) + Number(delta)
  if (!isFinite(next)) return 0
  if (next < 0) return 0
  if (next > SECTIONS.length - 1) return SECTIONS.length - 1
  return next
}

function rows() {
  return ROWS.slice()
}

function rowIds() {
  var out = []
  for (var i = 0; i < ROWS.length; i++) out.push(ROWS[i].id)
  return out
}

function row(id) {
  for (var i = 0; i < ROWS.length; i++) {
    if (ROWS[i].id === String(id)) return ROWS[i]
  }
  return null
}

function rowsInSection(sectionId) {
  var out = []
  for (var i = 0; i < ROWS.length; i++) {
    if (ROWS[i].section === String(sectionId)) out.push(ROWS[i])
  }
  return out
}

function rowIdsInSection(sectionId) {
  var found = rowsInSection(sectionId)
  var out = []
  for (var i = 0; i < found.length; i++) out.push(found[i].id)
  return out
}

function firstRowIn(sectionId) {
  var ids = rowIdsInSection(sectionId)
  return ids.length > 0 ? ids[0] : ""
}

function sectionOf(rowId) {
  var found = row(rowId)
  return found ? found.section : ""
}

function rowIndex(id) {
  var ids = rowIdsInSection(sectionOf(id))
  for (var i = 0; i < ids.length; i++) {
    if (ids[i] === String(id)) return i
  }
  return -1
}

// One cursor, walking the rows of the category on screen. Moving between
// categories is Tab's job, so j/k never walks out of the pane it is in.
function moveRow(sectionId, index, delta) {
  var ids = rowIdsInSection(sectionId)
  if (ids.length === 0) return 0
  var next = Number(index) + Number(delta)
  if (!isFinite(next)) return 0
  if (next < 0) return 0
  if (next > ids.length - 1) return ids.length - 1
  return next
}

function ownerOf(id) {
  var found = row(id)
  return found ? found.owner : ""
}

function writeViaOf(id) {
  var found = row(id)
  return found ? found.writeVia : ""
}

function kindOf(id) {
  var found = row(id)
  return found ? found.kind : ""
}

function optionOf(id) {
  var found = row(id)
  return found && found.option ? found.option : ""
}

// A row whose command puts a window on screen -- a folder picker, an editor.
// The panel holds the keyboard while it is open, so it has to get out of the
// way before one of these runs or the window it opened cannot be typed into.
function opensWindow(id) {
  var found = row(id)
  return !!found && found.opensWindow === true
}

// --------------------------------------------------------------- durations

// The offered stops. 0 is Never, and a hand-edited shell.json value that is not
// one of these is offered alongside them rather than silently rounded away.
var DURATION_CHOICES = [0, 60, 120, 300, 600, 900, 1800, 2700, 3600]

function plural(count, noun) {
  return String(count) + " " + noun + (count === 1 ? "" : "s")
}

// Seconds as a sentence fragment. 0 is off, and the panel says so in words
// rather than showing a number that means the opposite of what it looks like.
function durationLabel(seconds) {
  var total = Math.floor(Number(seconds))
  if (!isFinite(total) || total <= 0) return "Never"
  if (total < 60) return plural(total, "second")

  var hours = Math.floor(total / 3600)
  var minutes = Math.floor((total % 3600) / 60)
  var rest = total % 60
  var parts = []
  if (hours > 0) parts.push(plural(hours, "hour"))
  if (minutes > 0) parts.push(plural(minutes, "minute"))
  if (rest > 0) parts.push(plural(rest, "second"))
  return parts.join(" ")
}

// Dropdown options carry string values, so the panel never has to guess a type
// back out of a signal.
function durationOptions(currentSeconds) {
  var current = Math.floor(Number(currentSeconds))
  if (!isFinite(current) || current < 0) current = 0

  var values = DURATION_CHOICES.slice()
  if (values.indexOf(current) === -1) {
    values.push(current)
    values.sort(function(a, b) { return a - b })
  }

  var out = []
  for (var i = 0; i < values.length; i++) {
    out.push({ value: String(values[i]), label: durationLabel(values[i]) })
  }
  return out
}

// Same rule the idle service applies, so the panel never shows a value the
// service would reject. Kept in step with services/idle/IdleModel.js.
function secondsFromConfig(value, fallback) {
  var n = Number(value)
  if (!isFinite(n) || n < 0) return fallback
  return Math.floor(n)
}

// ------------------------------------------------------------ shell.json read

function isPlainObject(value) {
  return !!value && typeof value === "object" && !Array.isArray(value)
}

function configValue(config, path, fallback) {
  var node = config
  for (var i = 0; i < path.length; i++) {
    if (!isPlainObject(node)) return fallback
    node = node[path[i]]
  }
  return node === undefined || node === null ? fallback : node
}

function idleSeconds(config, stage) {
  var found = row("idle." + stage)
  if (!found) return 0
  return secondsFromConfig(configValue(config, found.configPath, found.defaultValue), found.defaultValue)
}

function barPosition(config) {
  var value = String(configValue(config, ["bar", "position"], "top"))
  return BAR_POSITIONS.indexOf(value) === -1 ? "top" : value
}

function barTransparent(config) {
  return configValue(config, ["bar", "transparent"], false) === true
}

// The mutator body handed to shell.mutateShellConfig. It edits the copy in
// place, which is the contract that function expects.
function applyIdleSeconds(config, stage, seconds) {
  if (!isPlainObject(config)) return config
  if (!isPlainObject(config.idle)) config.idle = {}
  config.idle[stage] = secondsFromConfig(seconds, 0)
  return config
}

// A shell-owned row reads straight off the live config rather than out of the
// value map the command-backed rows share.
function shellValue(rowId, config) {
  switch (String(rowId)) {
    case "idle.screenOff": return String(idleSeconds(config, "screenOff"))
    case "idle.lock": return String(idleSeconds(config, "lock"))
    case "idle.suspend": return String(idleSeconds(config, "suspend"))
    case "bar.position": return barPosition(config)
    case "bar.transparent": return barTransparent(config) ? "true" : "false"
  }
  return ""
}

// ------------------------------------------------------------- idle timeline

// What the three stages actually do, in the order they will fire. The stages
// are independent, so this is the only honest way to describe them: sorted by
// their own timeouts, with the ones that are off left out entirely.
function idleTimeline(config) {
  var stages = [
    { stage: "screenOff", label: "screen off", seconds: idleSeconds(config, "screenOff") },
    { stage: "lock", label: "lock", seconds: idleSeconds(config, "lock") },
    { stage: "suspend", label: "suspend", seconds: idleSeconds(config, "suspend") }
  ]
  var out = []
  for (var i = 0; i < stages.length; i++) {
    if (stages[i].seconds > 0) out.push(stages[i])
  }
  out.sort(function(a, b) { return a.seconds - b.seconds })
  return out
}

// A category can have one line of its own above its rows, for the case where
// the rows do not add up to what will actually happen. The idle stages are
// independent, so three timeouts read as a sequence they are not.
function sectionSummary(sectionId, config, values) {
  if (String(sectionId) !== "power") return ""
  var stayAwake = !!values && String(values["idle.stayAwake"]) === "true"
  return idleSummary(config, stayAwake)
}

function idleSummary(config, stayAwake) {
  if (stayAwake === true) return "Staying awake: no idle stage will fire."

  var timeline = idleTimeline(config)
  if (timeline.length === 0) return "Nothing happens when the session goes idle."

  var parts = []
  for (var i = 0; i < timeline.length; i++) {
    parts.push(durationLabel(timeline[i].seconds) + " → " + timeline[i].label)
  }
  return "After " + parts.join(", then ")
}

// ------------------------------------------------------------------ choices

var BAR_POSITIONS = ["top", "bottom", "left", "right"]

function titleCase(value) {
  var text = String(value)
  return text.charAt(0).toUpperCase() + text.slice(1)
}

function labelled(values) {
  var out = []
  for (var i = 0; i < values.length; i++) {
    out.push({ value: values[i], label: titleCase(values[i]) })
  }
  return out
}

function barPositionOptions() {
  return labelled(BAR_POSITIONS)
}

// bin/omarchy-display-text-size accepts an integer from 9 to 20 px and anchors
// everything to the shell default of 12.
var TEXT_SIZE_MIN = 9
var TEXT_SIZE_MAX = 20
var TEXT_SIZE_DEFAULT = 12

function textSizeOptions(currentPx) {
  var values = []
  for (var px = TEXT_SIZE_MIN; px <= TEXT_SIZE_MAX; px++) values.push(px)

  var current = Math.floor(Number(currentPx))
  if (isFinite(current) && current > 0 && values.indexOf(current) === -1) {
    values.push(current)
    values.sort(function(a, b) { return a - b })
  }

  var out = []
  for (var i = 0; i < values.length; i++) {
    out.push({
      value: String(values[i]),
      label: values[i] === TEXT_SIZE_DEFAULT ? values[i] + " px (default)" : values[i] + " px"
    })
  }
  return out
}

// What bin/omarchy-cursor-theme will accept, around the sizes cursor themes
// actually ship art for.
var CURSOR_SIZES = [16, 18, 20, 24, 28, 32, 36, 40, 48, 64]

function cursorSizeOptions(currentPx) {
  var values = CURSOR_SIZES.slice()
  var current = Math.floor(Number(currentPx))
  if (isFinite(current) && current > 0 && values.indexOf(current) === -1) {
    values.push(current)
    values.sort(function(a, b) { return a - b })
  }

  var out = []
  for (var i = 0; i < values.length; i++) {
    out.push({ value: String(values[i]), label: values[i] + " px" })
  }
  return out
}

// The scales bin/omarchy-hyprland-monitor-scaling names as its own presets.
var MONITOR_SCALES = ["1", "1.25", "1.6", "2", "3", "4"]

function scaleLabel(scale) {
  var n = Number(scale)
  if (!isFinite(n) || n <= 0) return String(scale)
  return String(Math.round(n * 100)) + "%"
}

function monitorScaleOptions(currentScale) {
  var values = MONITOR_SCALES.slice()
  var current = normalizeScale(currentScale)
  if (current !== "" && values.indexOf(current) === -1) {
    values.push(current)
    values.sort(function(a, b) { return Number(a) - Number(b) })
  }

  var out = []
  for (var i = 0; i < values.length; i++) {
    out.push({ value: values[i], label: scaleLabel(values[i]) })
  }
  return out
}

// hyprctl reports floats, so 1.60000 and 1.6 have to compare equal before the
// dropdown can find the row the monitor is actually on.
function normalizeScale(value) {
  var n = Number(value)
  if (!isFinite(n) || n <= 0) return ""
  return String(Math.round(n * 1000000) / 1000000)
}

var WINDOW_LAYOUTS = ["dwindle", "master", "scrolling"]

// An empty accel_profile is libinput's own choice for the device, which is not
// the same as asking for adaptive and is what every untouched install has.
var ACCEL_PROFILES = [
  { value: "", label: "Device default" },
  { value: "adaptive", label: "Adaptive" },
  { value: "flat", label: "Flat" }
]

var FOLLOW_MOUSE = [
  { value: "0", label: "Never" },
  { value: "1", label: "Focus follows the pointer" },
  { value: "2", label: "Pointer keeps the keyboard" },
  { value: "3", label: "Focus follows, click does not raise" }
]

// Rows whose choices are fixed rather than read off the machine. Everything
// else gets its options from a command.
function fixedOptions(rowId, currentValue) {
  switch (String(rowId)) {
    case "idle.screenOff":
    case "idle.lock":
    case "idle.suspend":
      return durationOptions(currentValue)
    case "bar.position": return barPositionOptions()
    case "appearance.textSize": return textSizeOptions(currentValue)
    case "appearance.cursorSize": return cursorSizeOptions(currentValue)
    case "display.scale": return monitorScaleOptions(currentValue)
    case "windows.layout": return labelled(WINDOW_LAYOUTS)
    case "input.accelProfile": return ACCEL_PROFILES.slice()
    case "input.followMouse": return FOLLOW_MOUSE.slice()
  }
  return []
}

// What a dropdown shows: the fixed choices, or the ones a command listed with
// the current value folded in so a value nothing offered is still visible.
function displayOptions(rowId, currentValue, loadedOptions) {
  var fixed = fixedOptions(rowId, currentValue)
  if (fixed.length > 0) return fixed

  var out = Array.isArray(loadedOptions) ? loadedOptions.slice() : []
  var current = String(currentValue === undefined || currentValue === null ? "" : currentValue)
  if (current === "") return out

  for (var i = 0; i < out.length; i++) {
    if (String(out[i].value) === current) return out
  }
  out.push({ value: current, label: current })
  return out
}

// ------------------------------------------------------------------ sliders

function sliderSpec(rowId) {
  var found = row(rowId)
  if (!found || found.kind !== "slider") return null
  return {
    minimum: Number(found.minimum),
    maximum: Number(found.maximum),
    step: Number(found.step),
    integer: found.integer === true,
    percent: found.percent === true,
    unit: found.unit ? String(found.unit) : ""
  }
}

// Sliders emit a float wherever they are dropped; the option only accepts what
// its own step allows, and a value off the end of the track is never sent.
function sliderValue(rowId, value) {
  var spec = sliderSpec(rowId)
  if (!spec) return ""

  var n = Number(value)
  if (!isFinite(n)) n = spec.minimum

  var steps = Math.round((n - spec.minimum) / spec.step)
  var snapped = spec.minimum + steps * spec.step
  if (snapped < spec.minimum) snapped = spec.minimum
  if (snapped > spec.maximum) snapped = spec.maximum

  if (spec.integer) return String(Math.round(snapped))
  return String(Math.round(snapped * 100) / 100)
}

function sliderLabel(rowId, value) {
  var spec = sliderSpec(rowId)
  if (!spec) return String(value)

  var text = sliderValue(rowId, value)
  if (text === "") return ""
  if (spec.percent) return String(Math.round(Number(text) * 100)) + "%"
  if (spec.unit !== "") return text + " " + spec.unit
  return text
}

// ------------------------------------------------------------------ parsing

function parseLines(raw) {
  var lines = String(raw === undefined || raw === null ? "" : raw).split("\n")
  var seen = {}
  var out = []
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].replace(/^\s+|\s+$/g, "")
    if (line === "" || seen[line] === true) continue
    seen[line] = true
    out.push(line)
  }
  return out
}

function parseFirstLine(raw) {
  var lines = parseLines(raw)
  return lines.length > 0 ? lines[0] : ""
}

// A command that lists things answers either with bare names or with a value
// and the name to show for it, separated by a tab. Both shapes are read the
// same way so a caller never has to know which one it asked for.
function parseTabbedOptions(raw) {
  var lines = String(raw === undefined || raw === null ? "" : raw).split("\n")
  var seen = {}
  var out = []
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].replace(/\s+$/g, "")
    if (line.replace(/^\s+/g, "") === "") continue
    var parts = line.split("\t")
    var value = parts[0].replace(/^\s+|\s+$/g, "")
    if (value === "" || seen[value] === true) continue
    seen[value] = true
    var label = parts.length > 1 ? parts[1].replace(/^\s+|\s+$/g, "") : value
    out.push({ value: value, label: label === "" ? value : label })
  }
  return out
}

// `omarchy-shell idle status` answers with the idle service's own JSON. Its
// `stayAwake` is the Stay Awake state; `enabled` is the inverse plus whether
// any stage is on at all, which is not the same question.
function parseIdleStatus(raw) {
  try {
    var parsed = JSON.parse(String(raw || ""))
    if (!isPlainObject(parsed)) return { ok: false, stayAwake: false }
    return { ok: true, stayAwake: parsed.stayAwake === true }
  } catch (e) {
    return { ok: false, stayAwake: false }
  }
}

// `omarchy-display-text-size` with no arguments prints three lines; the first
// carries the shell base size, and reads "12 (default)" when nothing is pinned.
function parseTextSize(raw) {
  var match = String(raw || "").match(/text size:\s*([0-9]+)/)
  if (!match) return { ok: false, px: 0 }
  return { ok: true, px: parseInt(match[1], 10) }
}

function parseMonitorScale(raw) {
  var scale = normalizeScale(parseFirstLine(raw))
  return { ok: scale !== "", scale: scale }
}

// `omarchy-powerprofiles-list --active-state` prints every profile with a 1
// against the one in force.
function parseActiveProfile(raw) {
  var lines = parseLines(raw)
  for (var i = 0; i < lines.length; i++) {
    var parts = lines[i].split("\t")
    if (parts.length > 1 && parts[1].replace(/^\s+|\s+$/g, "") === "1") {
      return parts[0].replace(/^\s+|\s+$/g, "")
    }
  }
  return ""
}

// A css option such as gaps_in reads back as "5 5 5 5" and is set with one
// number, so the first field is the whole answer. "[[EMPTY]]" is how hyprctl
// spells a string option nobody has set.
function parseOptionValue(rowId, raw) {
  var text = parseFirstLine(raw)
  if (text === "[[EMPTY]]") return ""
  if (kindOf(rowId) === "slider") return text.split(/\s+/)[0]
  return text
}

// One answer shape for every read: did the command say something usable, and
// what is the value as the panel carries it -- always a string, with a switch
// carrying "true" or "false".
function parseValue(rowId, raw) {
  var id = String(rowId)

  switch (id) {
    case "idle.stayAwake":
      var status = parseIdleStatus(raw)
      return { ok: status.ok, value: status.stayAwake ? "true" : "false" }
    case "appearance.textSize":
      var size = parseTextSize(raw)
      return { ok: size.ok, value: String(size.px) }
    case "display.scale":
      var scale = parseMonitorScale(raw)
      return { ok: scale.ok, value: scale.scale }
    case "power.profile":
      var profile = parseActiveProfile(raw)
      return { ok: profile !== "", value: profile }
    case "keys.list":
      return { ok: true, value: String(raw === undefined || raw === null ? "" : raw) }
    case "notifications.silenced":
      var dnd = parseFirstLine(raw)
      return { ok: dnd === "on" || dnd === "off", value: dnd === "on" ? "true" : "false" }
  }

  if (optionOf(id) !== "") {
    var option = parseOptionValue(id, raw)
    return { ok: option !== "" || kindOf(id) === "group", value: option }
  }

  var first = parseFirstLine(raw)
  return { ok: first !== "", value: first }
}

// --------------------------------------------------------------- commands

// Every command is built as an argument vector. Theme, icon-theme, font and
// wallpaper names carry spaces and quotes, and a value interpolated into a
// string would be a shell injection with the user's own settings as the
// payload.
function readCommand(rowId) {
  var id = String(rowId)
  var option = optionOf(id)
  if (option !== "") return ["omarchy-hyprland-setting", "get", option]

  switch (id) {
    case "idle.stayAwake": return ["omarchy-shell", "idle", "status"]
    case "appearance.theme": return ["omarchy-theme-current"]
    case "appearance.iconTheme": return ["omarchy-icon-theme", "get"]
    case "appearance.cursorTheme": return ["omarchy-cursor-theme", "get"]
    case "appearance.cursorSize": return ["omarchy-cursor-theme", "size"]
    case "appearance.font": return ["omarchy-font-current"]
    case "appearance.textSize": return ["omarchy-display-text-size"]
    case "wallpaper.image": return ["omarchy-theme-bg-current", "--path"]
    case "display.scale": return ["omarchy-hyprland-monitor-scaling"]
    case "power.profile": return ["omarchy-powerprofiles-list", "--active-state"]
    case "notifications.silenced": return ["omarchy-shell", "notifications", "dndState"]
    case "defaults.browser": return ["omarchy-default-browser"]
    case "defaults.editor": return ["omarchy-default-editor"]
    case "keys.list": return ["omarchy-menu-keybindings", "--print"]
  }
  return []
}

function optionsCommand(rowId) {
  switch (String(rowId)) {
    case "appearance.theme": return ["omarchy-theme-list"]
    case "appearance.iconTheme": return ["omarchy-icon-theme", "list"]
    case "appearance.cursorTheme": return ["omarchy-cursor-theme", "list"]
    case "appearance.font": return ["omarchy-font-list"]
    case "wallpaper.image": return ["omarchy-theme-bg-list"]
    case "power.profile": return ["omarchy-powerprofiles-list"]
    case "defaults.browser": return ["omarchy-default-browser", "--list"]
    case "defaults.editor": return ["omarchy-default-editor", "--list"]
  }
  return []
}

function writeCommand(rowId, value) {
  var id = String(rowId)
  var option = optionOf(id)
  if (option !== "") {
    var text = value === true ? "true" : (value === false ? "false" : String(value))
    // An option Hyprland spells as an empty string is reset rather than set:
    // hyprctl has no way to be handed nothing.
    if (text === "") return ["omarchy-hyprland-setting", "reset", option]
    return ["omarchy-hyprland-setting", "set", option, text]
  }

  switch (id) {
    // Stay Awake on means idle off. The idle service owns both, so the write
    // goes to it rather than to the state file underneath it.
    case "idle.stayAwake":
      return ["omarchy-shell", "idle", value === true ? "disable" : "enable"]
    case "appearance.theme": return ["omarchy-theme-set", String(value)]
    case "appearance.iconTheme": return ["omarchy-icon-theme", "set", String(value)]
    case "appearance.cursorTheme": return ["omarchy-cursor-theme", "set", String(value)]
    case "appearance.cursorSize": return ["omarchy-cursor-theme", "size", String(value)]
    case "appearance.font": return ["omarchy-font-set", String(value)]
    case "appearance.textSize": return ["omarchy-display-text-size", String(value)]
    case "wallpaper.image": return ["omarchy-theme-bg-set", String(value)]
    case "wallpaper.next": return ["omarchy-theme-bg-next"]
    case "wallpaper.folders": return ["omarchy-menu-theme-bg-dir", "add"]
    // The bar validates the position and patches the running bar itself, so
    // the write goes through it rather than straight into shell.json.
    case "bar.position": return ["omarchy-bar", "position", String(value)]
    case "bar.transparent": return ["omarchy-bar", "transparent", value === true ? "true" : "false"]
    case "display.scale": return ["omarchy-hyprland-monitor-scaling", String(value)]
    case "power.profile": return ["omarchy-powerprofiles-set", "autodetect", String(value)]
    case "notifications.silenced":
      return ["omarchy-shell", "notifications", "setDnd", value === true ? "true" : "false"]
    case "defaults.browser": return ["omarchy-default-browser", String(value)]
    case "defaults.editor": return ["omarchy-default-editor", String(value)]
    case "keys.edit": return ["omarchy-launch-config-editor", "hypr/bindings.lua"]
  }
  return []
}

// A vector is only usable if every element is a non-empty string: an undefined
// argument would silently shift the rest of them along.
function isArgumentVector(command) {
  if (!Array.isArray(command) || command.length === 0) return false
  for (var i = 0; i < command.length; i++) {
    if (typeof command[i] !== "string" || command[i] === "") return false
  }
  return true
}

function commandName(command) {
  return Array.isArray(command) && command.length > 0 ? String(command[0]) : ""
}

// A failed write is reported, never swallowed. The command's own message is
// what a user can act on, so it leads; the exit code is the fallback when the
// command said nothing.
function commandError(command, exitCode, stderr) {
  var name = commandName(command) || "command"
  var detail = String(stderr || "").replace(/\s+$/g, "").split("\n")
  var message = ""
  for (var i = detail.length - 1; i >= 0; i--) {
    if (detail[i].replace(/^\s+|\s+$/g, "") !== "") { message = detail[i].replace(/^\s+|\s+$/g, ""); break }
  }
  if (message !== "") return name + ": " + message
  return name + " exited " + String(exitCode)
}

if (typeof module !== "undefined") {
  module.exports = {
    sections: sections,
    sectionIds: sectionIds,
    section: section,
    sectionIndex: sectionIndex,
    moveSection: moveSection,
    rows: rows,
    rowIds: rowIds,
    row: row,
    rowsInSection: rowsInSection,
    rowIdsInSection: rowIdsInSection,
    firstRowIn: firstRowIn,
    rowIndex: rowIndex,
    moveRow: moveRow,
    ownerOf: ownerOf,
    writeViaOf: writeViaOf,
    kindOf: kindOf,
    opensWindow: opensWindow,
    durationLabel: durationLabel,
    durationOptions: durationOptions,
    secondsFromConfig: secondsFromConfig,
    idleSeconds: idleSeconds,
    barPosition: barPosition,
    barTransparent: barTransparent,
    applyIdleSeconds: applyIdleSeconds,
    shellValue: shellValue,
    idleTimeline: idleTimeline,
    idleSummary: idleSummary,
    sectionSummary: sectionSummary,
    barPositionOptions: barPositionOptions,
    textSizeOptions: textSizeOptions,
    cursorSizeOptions: cursorSizeOptions,
    scaleLabel: scaleLabel,
    monitorScaleOptions: monitorScaleOptions,
    normalizeScale: normalizeScale,
    displayOptions: displayOptions,
    sliderSpec: sliderSpec,
    sliderValue: sliderValue,
    sliderLabel: sliderLabel,
    parseLines: parseLines,
    parseFirstLine: parseFirstLine,
    parseTabbedOptions: parseTabbedOptions,
    parseIdleStatus: parseIdleStatus,
    parseTextSize: parseTextSize,
    parseMonitorScale: parseMonitorScale,
    parseActiveProfile: parseActiveProfile,
    parseOptionValue: parseOptionValue,
    parseValue: parseValue,
    readCommand: readCommand,
    optionsCommand: optionsCommand,
    writeCommand: writeCommand,
    isArgumentVector: isArgumentVector,
    commandName: commandName,
    commandError: commandError
  }
}
