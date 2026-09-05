// Pure helpers for the system monitor panel: CPU delta arithmetic, byte and
// percentage formatting, the window and process rows with their sorting,
// filtering and truncation, and every argument vector the panel runs.
// Panel.qml keeps only presentation and wiring, so all of this is reachable
// from Node.

var CPU_ICON = "󰻠"
var MEMORY_ICON = "󰍛"

function toNumber(value, fallback) {
  // Number(null) is 0 and Number("") is 0, so a setting left null or blank in
  // shell.json would read as a real zero and clamp to a minimum rather than
  // falling back to the default it was left out to get.
  if (value === null || value === undefined || value === "") return fallback
  var n = Number(value)
  return isFinite(n) ? n : fallback
}

function clamp(value, min, max) {
  var n = toNumber(value, min)
  return Math.max(min, Math.min(max, n))
}

// Number(), except that an empty or blank field is missing rather than zero.
// A truncated stats line prints "memory\t" with nothing after it, and reading
// that as 0% is the one answer worse than reading nothing.
function fieldNumber(text) {
  var s = String(text === undefined || text === null ? "" : text).replace(/^\s+|\s+$/g, "")
  if (s === "") return null
  var n = Number(s)
  return isFinite(n) ? n : null
}

// ------------------------------------------------------------------ stats

// `omarchy-system-stats --bar-widget` prints three tab-separated lines:
//   cpu    <idle>  <total>   raw /proc/stat counters
//   memory <percent>
//   load   <1-minute average>
// Missing or unparseable fields come back null rather than zero: a monitor
// that prints 0% when it does not know is worse than one that prints nothing.
function parseBarStats(raw) {
  var out = { cpuIdle: null, cpuTotal: null, memory: null, load: null }
  var lines = String(raw === undefined || raw === null ? "" : raw).split("\n")
  for (var i = 0; i < lines.length; i++) {
    var parts = lines[i].split("\t")
    if (parts.length < 2) continue
    var key = parts[0]
    if (key === "cpu" && parts.length >= 3) {
      var idle = fieldNumber(parts[1])
      var total = fieldNumber(parts[2])
      if (idle !== null && total !== null) {
        out.cpuIdle = idle
        out.cpuTotal = total
      }
    } else if (key === "memory") {
      var memory = fieldNumber(parts[1])
      if (memory !== null) out.memory = clamp(memory, 0, 100)
    } else if (key === "load") {
      var load = fieldNumber(parts[1])
      if (load !== null && load >= 0) out.load = load
    }
  }
  return out
}

// The pair of counters worth carrying to the next reading, or null when this
// reading had none. Keeping this separate from parseBarStats is what lets the
// panel store a sample without storing the memory and load that came with it.
function cpuSample(stats) {
  var s = stats || {}
  if (typeof s.cpuIdle !== "number" || typeof s.cpuTotal !== "number") return null
  if (!isFinite(s.cpuIdle) || !isFinite(s.cpuTotal)) return null
  return { cpuIdle: s.cpuIdle, cpuTotal: s.cpuTotal }
}

// Busy share of the jiffies that passed between two readings of /proc/stat.
// Returns null -- meaning "say nothing" -- for the very first sample, for a
// repeated reading with no time between it and the last, and for counters that
// went backwards, which is what a suspend/resume or a counter reset looks like.
function cpuPercent(previous, current) {
  var a = cpuSample(previous)
  var b = cpuSample(current)
  if (!a || !b) return null

  var totalDelta = b.cpuTotal - a.cpuTotal
  var idleDelta = b.cpuIdle - a.cpuIdle
  if (!(totalDelta > 0)) return null
  if (idleDelta < 0) return null
  if (idleDelta > totalDelta) return null

  return clamp(((totalDelta - idleDelta) / totalDelta) * 100, 0, 100)
}

// --------------------------------------------------------------- meminfo

// /proc/meminfo, read straight through `cat`. Every value is in kB.
// "cached" follows top's buff/cache: page cache plus buffers plus the
// reclaimable half of slab.
function parseMeminfo(raw) {
  var fields = {}
  var lines = String(raw === undefined || raw === null ? "" : raw).split("\n")
  for (var i = 0; i < lines.length; i++) {
    var match = lines[i].match(/^([A-Za-z0-9_()]+):\s+(\d+)(?:\s+kB)?\s*$/)
    if (!match) continue
    fields[match[1]] = Number(match[2])
  }

  var total = toNumber(fields.MemTotal, 0)
  if (total <= 0) return {}

  // Neither key present means "unknown", and unknown is not zero: reporting 0
  // available paints the maximum-alarm reading, 100% used, which is the one
  // answer worse than saying nothing. Drop the whole reading instead.
  var reported = fields.MemAvailable !== undefined
    ? fields.MemAvailable
    : fields.MemFree
  if (reported === undefined) return {}
  var available = Math.max(0, Math.min(total, toNumber(reported, 0)))
  var swapTotal = Math.max(0, toNumber(fields.SwapTotal, 0))
  var swapFree = Math.max(0, Math.min(swapTotal, toNumber(fields.SwapFree, 0)))

  return {
    totalKb: total,
    availableKb: available,
    usedKb: total - available,
    cachedKb: Math.max(0, toNumber(fields.Cached, 0) + toNumber(fields.Buffers, 0) + toNumber(fields.SReclaimable, 0)),
    swapTotalKb: swapTotal,
    swapUsedKb: swapTotal - swapFree
  }
}

// -------------------------------------------------------------- formatting

// Binary steps with decimal labels, matching what omarchy-system-stats already
// prints for memory.
function formatKb(kb, digits) {
  var n = fieldNumber(kb)
  if (n === null || n < 0) return "—"

  var units = ["KB", "MB", "GB", "TB", "PB"]
  var index = 0
  while (n >= 1024 && index < units.length - 1) {
    n /= 1024
    index++
  }

  var places = digits === undefined || digits === null
    ? (index === 0 ? 0 : 1)
    : Math.max(0, Math.round(toNumber(digits, 0)))
  return n.toFixed(places) + " " + units[index]
}

function formatPercent(value, digits) {
  var n = fieldNumber(value)
  if (n === null || n < 0) return "—"
  return n.toFixed(Math.max(0, Math.round(toNumber(digits, 0)))) + "%"
}

function formatLoad(value) {
  var n = fieldNumber(value)
  if (n === null || n < 0) return "—"
  return n.toFixed(2)
}

function formatUsage(usedKb, totalKb) {
  var used = fieldNumber(usedKb)
  var total = fieldNumber(totalKb)
  if (used === null || total === null || total <= 0) return "—"
  return formatKb(used) + " / " + formatKb(total)
}

// 0..1, for the gauge fills. Out-of-range and unknown both read as empty.
function fraction(percent) {
  var n = fieldNumber(percent)
  if (n === null || n < 0) return 0
  return clamp(n / 100, 0, 1)
}

// ------------------------------------------------------------------- bar

function barLabel(cpu, memory) {
  return CPU_ICON + " " + formatPercent(cpu, 0) + "  " + MEMORY_ICON + " " + formatPercent(memory, 0)
}

// Vertical bars paint one glyph per slot, so the label becomes four stacked
// lines rather than one string.
function barLines(cpu, memory) {
  return [CPU_ICON, formatPercent(cpu, 0), MEMORY_ICON, formatPercent(memory, 0)]
}

function barTooltip(cpu, memory, load) {
  return "CPU " + formatPercent(cpu, 0) + " · Memory " + formatPercent(memory, 0) + " · Load " + formatLoad(load)
}

// ------------------------------------------------------------------ views

// The panel is two lists over the same machine: the windows the user can see,
// and every process behind them. Apps is the default because the question
// that opens a task manager is nearly always "which of my apps is stuck".
function normalizeView(view) {
  return String(view) === "processes" ? "processes" : "apps"
}

function viewOptions() {
  return [
    { value: "apps", label: "Apps" },
    { value: "processes", label: "Processes" }
  ]
}

function viewIndexFor(view) {
  return normalizeView(view) === "processes" ? 1 : 0
}

function viewForIndex(index) {
  return Math.round(toNumber(index, 0)) === 1 ? "processes" : "apps"
}

function otherView(view) {
  return normalizeView(view) === "apps" ? "processes" : "apps"
}

// -------------------------------------------------------------- processes

// A process name and command line are whatever the process chose to call
// itself: newlines, tabs, control characters and shell metacharacters are all
// legal there. Everything the panel paints goes through here first, so a row
// stays one line and a terminal escape never reaches a label. The untouched
// value stays on the row as data.
function sanitizeText(value, max) {
  var s = String(value === undefined || value === null ? "" : value)
  // C0 and DEL, and the bidi overrides with them: a process gets to choose its
  // own name, and the one dialog that renders it is the confirmation asking
  // whether to end it. U+202E would let a process reverse that sentence.
  s = s.replace(/[\u0000-\u001f\u007f\u200e\u200f\u202a-\u202e\u2066-\u2069]/g, " ")
    .replace(/\s+/g, " ").replace(/^ +| +$/g, "")

  var limit = Math.round(Number(max))
  if (!isFinite(limit) || limit <= 0 || s.length <= limit) return s

  // slice() counts UTF-16 code units, so cutting mid-pair leaves a lone
  // surrogate that renders as a replacement character. An emoji anywhere near
  // the cut is enough, and browser and Electron command lines carry them.
  var cut = Math.max(1, limit - 1)
  var code = s.charCodeAt(cut - 1)
  if (code >= 0xd800 && code <= 0xdbff) cut -= 1
  return s.slice(0, Math.max(1, cut)) + "…"
}

function parseProcesses(raw) {
  var parsed
  try {
    parsed = JSON.parse(String(raw === undefined || raw === null ? "" : raw) || "[]")
  } catch (e) {
    return []
  }
  if (!Array.isArray(parsed)) return []

  var rows = []
  for (var i = 0; i < parsed.length; i++) {
    var row = parsed[i]
    if (!row || typeof row !== "object") continue

    var pid = Math.round(Number(row.pid))
    if (!isFinite(pid) || pid <= 0) continue

    rows.push({
      pid: pid,
      name: String(row.name === undefined || row.name === null ? "" : row.name),
      command: String(row.command === undefined || row.command === null ? "" : row.command),
      cpu: Math.max(0, toNumber(row.cpu, 0)),
      memory: Math.max(0, toNumber(row.memory, 0)),
      rssKb: Math.max(0, toNumber(row.rssKb, 0)),
      uid: Math.round(toNumber(row.uid, -1))
    })
  }
  return rows
}

function normalizeSortKey(key) {
  return String(key) === "memory" ? "memory" : "cpu"
}

function sortOptions() {
  return [
    { value: "cpu", label: "CPU" },
    { value: "memory", label: "Memory" }
  ]
}

function sortIndexFor(key) {
  return normalizeSortKey(key) === "memory" ? 1 : 0
}

function sortKeyForIndex(index) {
  return Math.round(toNumber(index, 0)) === 1 ? "memory" : "cpu"
}

function otherSortKey(key) {
  return normalizeSortKey(key) === "cpu" ? "memory" : "cpu"
}

// Descending on the chosen key, then on the other one, then on pid so the list
// does not reshuffle between samples when two processes are both idle.
function sortProcesses(rows, key) {
  var list = Array.isArray(rows) ? rows.slice() : []
  var primary = normalizeSortKey(key)
  var secondary = primary === "cpu" ? "memory" : "cpu"

  list.sort(function(a, b) {
    var av = toNumber(a && a[primary], -1)
    var bv = toNumber(b && b[primary], -1)
    if (bv !== av) return bv - av

    var ao = toNumber(a && a[secondary], -1)
    var bo = toNumber(b && b[secondary], -1)
    if (bo !== ao) return bo - ao

    return toNumber(a && a.pid, 0) - toNumber(b && b.pid, 0)
  })
  return list
}

// The sampler returns every process, so the panel can search all of them; the
// Processes view still shows only the top of the ranking until a filter is
// typed, because five hundred rows is a dump rather than a monitor. A filter
// lifts the cap: the point of typing "discord" is to find it wherever it ranks.
function limitProcesses(rows, limit, query) {
  var list = Array.isArray(rows) ? rows : []
  if (normalizeQuery(query) !== "") return list
  return list.slice(0, clampLimit(limit))
}

function clampIndex(index, length) {
  if (length <= 0) return -1
  return Math.max(0, Math.min(length - 1, Math.round(toNumber(index, 0))))
}

function processName(row) {
  return sanitizeText((row || {}).name, 32) || "process"
}

function processDetail(row) {
  var r = row || {}
  var command = sanitizeText(r.command, 120)
  return command || sanitizeText(r.name, 120)
}

function processTooltip(row) {
  var r = row || {}
  var command = sanitizeText(r.command, 400)
  var pid = Math.round(toNumber(r.pid, 0))
  var head = pid > 0 ? "pid " + pid : ""
  if (!command) return head
  return head ? head + "  ·  " + command : command
}

function processMemory(row) {
  return formatKb(toNumber((row || {}).rssKb, -1))
}

// ---------------------------------------------------------------- windows

// One row per window the compositor shows. The panel lifts plain values off
// Hyprland's toplevel handles -- address, pid, class, title, workspace -- and
// this keeps only what parses: a row has to have an address to be a window at
// all, and a pid is optional, because a fresh window's IPC object can lag a
// beat behind its handle. Rows without a pid can still be closed; they only
// cannot be signalled. `handle` is the live toplevel, passed through untouched
// so the panel can close or activate it; everything else is data.
function parseWindows(list) {
  var input = Array.isArray(list) ? list : []
  var rows = []
  for (var i = 0; i < input.length; i++) {
    var w = input[i]
    if (!w || typeof w !== "object") continue

    var address = String(w.address === undefined || w.address === null ? "" : w.address)
    if (address === "") continue
    // Hyprland hides a window it has swallowed or moved to a special
    // workspace; an unmapped one has not been shown yet. Neither is anything
    // the user would call an open app.
    if (w.mapped === false || w.hidden === true) continue

    var pid = Math.round(toNumber(w.pid, 0))
    if (!isFinite(pid) || pid <= 0) pid = 0

    var workspaceId = fieldNumber(w.workspaceId)

    rows.push({
      address: address,
      pid: pid,
      appId: String(w.appId === undefined || w.appId === null ? "" : w.appId),
      className: String(w.className === undefined || w.className === null ? "" : w.className),
      title: String(w.title === undefined || w.title === null ? "" : w.title),
      name: String(w.name === undefined || w.name === null ? "" : w.name),
      icon: String(w.icon === undefined || w.icon === null ? "" : w.icon),
      workspaceId: workspaceId === null ? null : Math.round(workspaceId),
      activated: w.activated === true,
      handle: w.handle === undefined ? null : w.handle
    })
  }
  return rows
}

// The name a user knows the app by: the desktop entry's name when one matched
// the window class, otherwise the class itself, otherwise the Wayland app id.
function windowName(row) {
  var r = row || {}
  return sanitizeText(r.name, 32) || sanitizeText(r.className, 32) || sanitizeText(r.appId, 32) || "window"
}

function windowTitle(row) {
  return sanitizeText((row || {}).title, 120)
}

function windowDetail(row) {
  var title = windowTitle(row)
  if (title !== "") return title
  return sanitizeText((row || {}).className, 120)
}

function windowWorkspaceLabel(row) {
  var id = (row || {}).workspaceId
  if (id === null || id === undefined) return ""
  var n = Number(id)
  if (!isFinite(n)) return ""
  // Negative ids are Hyprland's special workspaces, named rather than numbered
  // on the bar, so a number there would mean nothing to the user.
  if (n < 0) return "special"
  return String(Math.round(n))
}

function windowTooltip(row) {
  var r = row || {}
  var parts = []
  var pid = Math.round(toNumber(r.pid, 0))
  if (pid > 0) parts.push("pid " + pid)
  var cls = sanitizeText(r.className, 80)
  if (cls !== "") parts.push(cls)
  var ws = windowWorkspaceLabel(r)
  if (ws !== "") parts.push("workspace " + ws)
  var title = sanitizeText(r.title, 400)
  if (title !== "") parts.push(title)
  return parts.join("  ·  ")
}

// Grouped by app, so a browser's six windows sit together, then by workspace
// and title within the app, and finally by address so the order holds still
// between refreshes.
function sortWindows(rows) {
  var list = Array.isArray(rows) ? rows.slice() : []
  list.sort(function(a, b) {
    var an = windowName(a).toLowerCase()
    var bn = windowName(b).toLowerCase()
    if (an !== bn) return an < bn ? -1 : 1

    var aw = toNumber(a && a.workspaceId, 0)
    var bw = toNumber(b && b.workspaceId, 0)
    if (aw !== bw) return aw - bw

    var at = windowTitle(a).toLowerCase()
    var bt = windowTitle(b).toLowerCase()
    if (at !== bt) return at < bt ? -1 : 1

    var aa = String((a || {}).address || "")
    var ba = String((b || {}).address || "")
    return aa < ba ? -1 : (aa > ba ? 1 : 0)
  })
  return list
}

// A window's figures are its main process's. Electron apps and browsers fan
// out into renderers that carry the real load, but without parent ids there is
// no honest way to sum them, and a figure that describes the wrong thing is
// worse than an em dash. Windows whose pid is missing from the sample read
// unknown, never zero.
function attachUsage(windows, processes) {
  var byPid = {}
  var procs = Array.isArray(processes) ? processes : []
  for (var i = 0; i < procs.length; i++) {
    var p = procs[i]
    if (p && p.pid > 0) byPid[p.pid] = p
  }

  var list = Array.isArray(windows) ? windows : []
  var out = []
  for (var j = 0; j < list.length; j++) {
    var w = list[j]
    if (!w) continue
    var row = {}
    for (var key in w) row[key] = w[key]
    var match = w.pid > 0 ? byPid[w.pid] : undefined
    row.cpu = match ? match.cpu : null
    row.rssKb = match ? match.rssKb : null
    out.push(row)
  }
  return out
}

// --------------------------------------------------------------- filtering

function normalizeQuery(text) {
  return String(text === undefined || text === null ? "" : text)
    .toLowerCase().replace(/\s+/g, " ").replace(/^ | $/g, "")
}

// Every word typed has to appear in one of the row's fields. Case-insensitive
// substring, no regex: the query is the user's, but a stray "(" in it must
// not turn into a syntax error.
function matchesQuery(fields, query) {
  var q = normalizeQuery(query)
  if (q === "") return true
  var haystack = []
  var list = Array.isArray(fields) ? fields : [fields]
  for (var i = 0; i < list.length; i++) {
    var f = list[i]
    if (f === undefined || f === null) continue
    haystack.push(String(f).toLowerCase())
  }
  var words = q.split(" ")
  for (var w = 0; w < words.length; w++) {
    var found = false
    for (var h = 0; h < haystack.length && !found; h++) {
      if (haystack[h].indexOf(words[w]) >= 0) found = true
    }
    if (!found) return false
  }
  return true
}

function filterProcesses(rows, query) {
  var list = Array.isArray(rows) ? rows : []
  if (normalizeQuery(query) === "") return list
  var out = []
  for (var i = 0; i < list.length; i++) {
    var r = list[i]
    if (!r) continue
    if (matchesQuery([r.name, r.command, r.pid], query)) out.push(r)
  }
  return out
}

function filterWindows(rows, query) {
  var list = Array.isArray(rows) ? rows : []
  if (normalizeQuery(query) === "") return list
  var out = []
  for (var i = 0; i < list.length; i++) {
    var r = list[i]
    if (!r) continue
    if (matchesQuery([r.name, r.className, r.appId, r.title, r.pid], query)) out.push(r)
  }
  return out
}

function emptyMessage(view, query, sampling) {
  var filtered = normalizeQuery(query) !== ""
  if (normalizeView(view) === "apps") {
    return filtered ? "No open window matches" : "No open windows"
  }
  if (filtered) return "No process matches"
  return sampling ? "Sampling…" : "No processes"
}

// ------------------------------------------------------------- settings

function clampLimit(value) {
  return Math.round(clamp(Math.round(toNumber(value, 25)), 5, 100))
}

function clampSeconds(value, fallback, min, max) {
  return Math.round(clamp(Math.round(toNumber(value, fallback)), min, max))
}

// -------------------------------------------------------------- commands

// Every command is an argument vector. Nothing built from a process name, a
// window title or a command line is ever interpolated into one -- the only
// value that crosses into a command is a pid, and signalCommand refuses
// anything that is not a plain positive integer above 1.
function statsCommand() {
  return ["omarchy-system-stats", "--bar-widget"]
}

// No --limit: the panel filters and caps the list itself, so a search reaches
// every process rather than the top of the ranking. The sampler's cost is the
// scan over /proc, which does not change with the number of rows it prints.
function processesCommand(interval) {
  var argv = ["omarchy-system-processes"]
  var seconds = Number(interval)
  if (isFinite(seconds) && seconds > 0) argv.push("--interval", String(seconds))
  return argv
}

function meminfoCommand() {
  return ["cat", "/proc/meminfo"]
}

// The two signals the panel can send, and the order it sends them in. TERM
// asks; KILL cannot be asked. KILL is only ever offered for a pid this panel
// has already sent TERM to and that is still running afterwards, which is
// what `canForceKill` checks, so nothing here escalates on its own.
var TERM = "TERM"
var KILL = "KILL"

function normalizeSignal(name) {
  return String(name) === KILL ? KILL : TERM
}

// Never with privilege: no sudo, no pkexec. A process the user does not own
// fails here, and the panel says so.
//
// pid 1 and anything below it is refused outright: a negative pid is a process
// group and 0 is every process in the caller's group, so neither may reach
// kill(1) whatever produced it.
function signalCommand(pid, name) {
  var n = Number(pid)
  if (!isFinite(n) || Math.floor(n) !== n || n <= 1) return null
  return ["kill", "-s", normalizeSignal(name), String(n)]
}

function terminateCommand(pid) {
  return signalCommand(pid, TERM)
}

function forceKillCommand(pid) {
  return signalCommand(pid, KILL)
}

// The set of pids this panel has sent TERM to, kept by the panel as a plain
// object. Force kill is offered for a row only while its pid is in that set,
// and the set is pruned to the pids still running, so the offer disappears
// with the process.
function markTerminated(terminated, pid) {
  var next = {}
  for (var key in (terminated || {})) next[key] = true
  var n = Math.round(toNumber(pid, 0))
  if (n > 1) next[String(n)] = true
  return next
}

function pruneTerminated(terminated, processes) {
  var alive = {}
  var procs = Array.isArray(processes) ? processes : []
  for (var i = 0; i < procs.length; i++) {
    var p = procs[i]
    if (p && p.pid > 0) alive[String(p.pid)] = true
  }
  var next = {}
  for (var key in (terminated || {})) {
    if (alive[key] === true) next[key] = true
  }
  return next
}

function canForceKill(row, terminated) {
  var pid = Math.round(toNumber((row || {}).pid, 0))
  if (pid <= 1) return false
  return !!(terminated && terminated[String(pid)] === true)
}

// Which signal a request on this row means right now.
function signalFor(row, terminated) {
  return canForceKill(row, terminated) ? KILL : TERM
}

function rowName(row, isWindow) {
  return isWindow ? windowName(row) : processName(row)
}

function signalMessage(row, name, isWindow) {
  var r = row || {}
  var pid = Math.round(toNumber(r.pid, 0))
  var label = rowName(r, isWindow)
  var where = pid > 0 ? " (pid " + pid + ")" : ""
  if (normalizeSignal(name) === KILL) {
    return label + where + " did not end after SIGTERM. Force kill it with SIGKILL? Unsaved work is lost."
  }
  return "Send SIGTERM to " + label + where + "?"
}

function terminateMessage(row) {
  return signalMessage(row, TERM, false)
}

function signalActionLabel(name) {
  return normalizeSignal(name) === KILL ? "Force kill" : "End"
}

function signalIcon(name) {
  // close-circle for a polite end, close-octagon for the one that is not.
  return normalizeSignal(name) === KILL ? "󰅜" : "󰅙"
}

function signalTooltip(name) {
  return normalizeSignal(name) === KILL
    ? "Force kill (SIGKILL) — it ignored SIGTERM"
    : "End process (SIGTERM)"
}

// A failure has to be shown rather than swallowed: a process owned by another
// user is exactly the case this panel cannot do anything about, and silence
// would read as success.
// A sampler that exits non-zero has to say so: the panel would otherwise keep
// repainting the last good table, which looks identical to a machine that has
// stopped changing.
function processFailure(exitCode, stderr) {
  var code = Math.round(toNumber(exitCode, -1))
  if (code === 0) return ""

  var detail = sanitizeText(stderr, 140)
  if (!detail) detail = "sampler exited " + code
  return "Could not read processes: " + detail
}

function signalFailure(exitCode, stderr, row, name, isWindow) {
  var code = Math.round(toNumber(exitCode, -1))
  if (code === 0) return ""

  var detail = sanitizeText(stderr, 140)
  if (!detail) detail = "kill exited " + code
  var verb = normalizeSignal(name) === KILL ? "force kill" : "end"
  return "Could not " + verb + " " + rowName(row, isWindow) + ": " + detail
}

function terminateFailure(exitCode, stderr, row) {
  return signalFailure(exitCode, stderr, row, TERM, false)
}

if (typeof module !== "undefined") {
  module.exports = {
    parseBarStats: parseBarStats,
    cpuSample: cpuSample,
    cpuPercent: cpuPercent,
    parseMeminfo: parseMeminfo,
    formatKb: formatKb,
    formatPercent: formatPercent,
    formatLoad: formatLoad,
    formatUsage: formatUsage,
    fraction: fraction,
    barLabel: barLabel,
    barLines: barLines,
    barTooltip: barTooltip,
    normalizeView: normalizeView,
    viewOptions: viewOptions,
    viewIndexFor: viewIndexFor,
    viewForIndex: viewForIndex,
    otherView: otherView,
    sanitizeText: sanitizeText,
    parseProcesses: parseProcesses,
    normalizeSortKey: normalizeSortKey,
    sortOptions: sortOptions,
    sortIndexFor: sortIndexFor,
    sortKeyForIndex: sortKeyForIndex,
    otherSortKey: otherSortKey,
    sortProcesses: sortProcesses,
    limitProcesses: limitProcesses,
    clampIndex: clampIndex,
    processName: processName,
    processDetail: processDetail,
    processTooltip: processTooltip,
    processMemory: processMemory,
    parseWindows: parseWindows,
    windowName: windowName,
    windowTitle: windowTitle,
    windowDetail: windowDetail,
    windowWorkspaceLabel: windowWorkspaceLabel,
    windowTooltip: windowTooltip,
    sortWindows: sortWindows,
    attachUsage: attachUsage,
    normalizeQuery: normalizeQuery,
    matchesQuery: matchesQuery,
    filterProcesses: filterProcesses,
    filterWindows: filterWindows,
    emptyMessage: emptyMessage,
    clampLimit: clampLimit,
    clampSeconds: clampSeconds,
    statsCommand: statsCommand,
    processesCommand: processesCommand,
    meminfoCommand: meminfoCommand,
    TERM: TERM,
    KILL: KILL,
    normalizeSignal: normalizeSignal,
    signalCommand: signalCommand,
    terminateCommand: terminateCommand,
    forceKillCommand: forceKillCommand,
    markTerminated: markTerminated,
    pruneTerminated: pruneTerminated,
    canForceKill: canForceKill,
    signalFor: signalFor,
    signalMessage: signalMessage,
    terminateMessage: terminateMessage,
    signalActionLabel: signalActionLabel,
    signalIcon: signalIcon,
    signalTooltip: signalTooltip,
    processFailure: processFailure,
    signalFailure: signalFailure,
    terminateFailure: terminateFailure
  }
}
