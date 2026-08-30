// Everything the settings panel decides that is not painting: which settings
// exist, which mechanism backs each one, how a duration reads as a sentence,
// how a command's output is parsed, and the exact argument vector every write
// runs. Panel.qml keeps only presentation and wiring, so all of this stays
// testable under Node without a compositor.

// ------------------------------------------------------------------ inventory

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
var SECTIONS = [
  {
    id: "power",
    title: "POWER & LOCK",
    caption: "Each stage counts from the moment the session goes idle, and they are independent — any order is allowed, and Never turns one off."
  },
  {
    id: "appearance",
    title: "APPEARANCE",
    caption: "Theme, icons, and type for this desktop and the apps that follow it."
  },
  {
    id: "bar",
    title: "BAR",
    caption: "Where the bar sits and whether it paints its own background."
  },
  {
    id: "display",
    title: "DISPLAY",
    caption: "The focused monitor, and the screen's colour temperature."
  }
]

var ROWS = [
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
  {
    id: "display.scale",
    section: "display",
    kind: "choice",
    label: "Monitor scale",
    hint: "Hyprland only accepts scales that divide the mode into whole pixels, so the value can settle above the one you pick.",
    owner: "system",
    writeVia: "command"
  }
]

function sections() {
  return SECTIONS.slice()
}

function section(id) {
  for (var i = 0; i < SECTIONS.length; i++) {
    if (SECTIONS[i].id === String(id)) return SECTIONS[i]
  }
  return null
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

function rowIndex(id) {
  for (var i = 0; i < ROWS.length; i++) {
    if (ROWS[i].id === String(id)) return i
  }
  return -1
}

function ownerOf(id) {
  var found = row(id)
  return found ? found.owner : ""
}

function writeViaOf(id) {
  var found = row(id)
  return found ? found.writeVia : ""
}

// One cursor for the whole panel, walking every row in every section in order.
// Clamped rather than wrapping: the ends of the list are where a user expects
// the cursor to stop.
function moveRow(index, delta) {
  var next = Number(index) + Number(delta)
  if (!isFinite(next)) return 0
  if (next < 0) return 0
  if (next > ROWS.length - 1) return ROWS.length - 1
  return next
}

// --------------------------------------------------------------- durations

// The offered stops. 0 is Never, and a hand-edited shell.json value that is not
// one of these is offered alongside them rather than silently rounded away.
var DURATION_CHOICES = [0, 60, 120, 300, 600, 900, 1800, 2700, 3600]

function durationChoices() {
  return DURATION_CHOICES.slice()
}

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

function secondsFromOption(value) {
  return secondsFromConfig(value, 0)
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

function barPositionValues() {
  return BAR_POSITIONS.slice()
}

function barPositionOptions() {
  var out = []
  for (var i = 0; i < BAR_POSITIONS.length; i++) {
    var value = BAR_POSITIONS[i]
    out.push({ value: value, label: value.charAt(0).toUpperCase() + value.slice(1) })
  }
  return out
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
  if (!match) return { ok: false, px: 0, isDefault: false }
  return {
    ok: true,
    px: parseInt(match[1], 10),
    isDefault: /\(default\)/.test(String(raw || ""))
  }
}

function parseMonitorScale(raw) {
  var scale = normalizeScale(parseFirstLine(raw))
  return { ok: scale !== "", scale: scale }
}

// --------------------------------------------------------------- commands

// Every command is built as an argument vector. Theme, icon-theme and font
// names carry spaces and quotes, and a value interpolated into a string would
// be a shell injection with the user's own settings as the payload.
function readCommand(rowId) {
  switch (String(rowId)) {
    case "idle.stayAwake": return ["omarchy-shell", "idle", "status"]
    case "appearance.theme": return ["omarchy-theme-current"]
    case "appearance.iconTheme": return ["omarchy-icon-theme", "get"]
    case "appearance.font": return ["omarchy-font-current"]
    case "appearance.textSize": return ["omarchy-display-text-size"]
    case "display.scale": return ["omarchy-hyprland-monitor-scaling"]
  }
  return []
}

function optionsCommand(rowId) {
  switch (String(rowId)) {
    case "appearance.theme": return ["omarchy-theme-list"]
    case "appearance.iconTheme": return ["omarchy-icon-theme", "list"]
    case "appearance.font": return ["omarchy-font-list"]
  }
  return []
}

function writeCommand(rowId, value) {
  switch (String(rowId)) {
    // Stay Awake on means idle off. The idle service owns both, so the write
    // goes to it rather than to the state file underneath it.
    case "idle.stayAwake":
      return ["omarchy-shell", "idle", value === true ? "disable" : "enable"]
    case "appearance.theme": return ["omarchy-theme-set", String(value)]
    case "appearance.iconTheme": return ["omarchy-icon-theme", "set", String(value)]
    case "appearance.font": return ["omarchy-font-set", String(value)]
    case "appearance.textSize": return ["omarchy-display-text-size", String(value)]
    // The bar validates the position and patches the running bar itself, so
    // the write goes through it rather than straight into shell.json.
    case "bar.position": return ["omarchy-bar", "position", String(value)]
    case "bar.transparent": return ["omarchy-bar", "transparent", value === true ? "true" : "false"]
    case "display.scale": return ["omarchy-hyprland-monitor-scaling", String(value)]
    // The only command there is: it flips the temperature, so the panel asks
    // for a flip and then re-reads what actually happened.
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
    section: section,
    rows: rows,
    rowIds: rowIds,
    row: row,
    rowsInSection: rowsInSection,
    rowIndex: rowIndex,
    ownerOf: ownerOf,
    writeViaOf: writeViaOf,
    moveRow: moveRow,
    durationChoices: durationChoices,
    durationLabel: durationLabel,
    durationOptions: durationOptions,
    secondsFromConfig: secondsFromConfig,
    secondsFromOption: secondsFromOption,
    configValue: configValue,
    idleSeconds: idleSeconds,
    barPosition: barPosition,
    barTransparent: barTransparent,
    applyIdleSeconds: applyIdleSeconds,
    idleTimeline: idleTimeline,
    idleSummary: idleSummary,
    barPositionValues: barPositionValues,
    barPositionOptions: barPositionOptions,
    textSizeOptions: textSizeOptions,
    scaleLabel: scaleLabel,
    monitorScaleOptions: monitorScaleOptions,
    normalizeScale: normalizeScale,
    parseLines: parseLines,
    parseFirstLine: parseFirstLine,
    parseIdleStatus: parseIdleStatus,
    parseTextSize: parseTextSize,
    parseMonitorScale: parseMonitorScale,
    readCommand: readCommand,
    optionsCommand: optionsCommand,
    writeCommand: writeCommand,
    isArgumentVector: isArgumentVector,
    commandName: commandName,
    commandError: commandError
  }
}
