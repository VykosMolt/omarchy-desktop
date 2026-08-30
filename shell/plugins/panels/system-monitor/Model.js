// Pure helpers for the system monitor panel: CPU delta arithmetic, byte and
// percentage formatting, process sorting and truncation, and every argument
// vector the panel runs. Panel.qml keeps only presentation and wiring, so all
// of this is reachable from Node.

var CPU_ICON = "󰻠"
var MEMORY_ICON = "󰍛"

function toNumber(value, fallback) {
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

  var reported = fields.MemAvailable === undefined
    ? toNumber(fields.MemFree, 0)
    : toNumber(fields.MemAvailable, 0)
  var available = Math.max(0, Math.min(total, reported))
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

// -------------------------------------------------------------- processes

// A process name and command line are whatever the process chose to call
// itself: newlines, tabs, control characters and shell metacharacters are all
// legal there. Everything the panel paints goes through here first, so a row
// stays one line and a terminal escape never reaches a label. The untouched
// value stays on the row as data.
function sanitizeText(value, max) {
  var s = String(value === undefined || value === null ? "" : value)
  s = s.replace(/[\u0000-\u001f\u007f]/g, " ").replace(/\s+/g, " ").replace(/^ +| +$/g, "")

  var limit = Math.round(Number(max))
  if (!isFinite(limit) || limit <= 0 || s.length <= limit) return s
  return s.slice(0, Math.max(1, limit - 1)) + "…"
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

// ------------------------------------------------------------- settings

function clampLimit(value) {
  return Math.round(clamp(Math.round(toNumber(value, 25)), 5, 100))
}

function clampSeconds(value, fallback, min, max) {
  return Math.round(clamp(Math.round(toNumber(value, fallback)), min, max))
}

// -------------------------------------------------------------- commands

// Every command is an argument vector. Nothing built from a process name or a
// command line is ever interpolated into one -- the only value that crosses
// into a command is a pid, and terminateCommand refuses anything that is not a
// plain positive integer.
function statsCommand() {
  return ["omarchy-system-stats", "--bar-widget"]
}

function processesCommand(limit, interval) {
  var argv = ["omarchy-system-processes", "--limit", String(clampLimit(limit))]
  var seconds = Number(interval)
  if (isFinite(seconds) && seconds > 0) argv.push("--interval", String(seconds))
  return argv
}

function meminfoCommand() {
  return ["cat", "/proc/meminfo"]
}

// SIGTERM, never SIGKILL, and never with privilege: no sudo, no pkexec. A
// process the user does not own fails here, and the panel says so.
//
// pid 1 and anything below it is refused outright: a negative pid is a process
// group and 0 is every process in the caller's group, so neither may reach
// kill(1) whatever produced it.
function terminateCommand(pid) {
  var n = Number(pid)
  if (!isFinite(n) || Math.floor(n) !== n || n <= 1) return null
  return ["kill", "-s", "TERM", String(n)]
}

function terminateMessage(row) {
  var r = row || {}
  var pid = Math.round(toNumber(r.pid, 0))
  var name = processName(r)
  if (pid <= 0) return "End " + name + "?"
  return "Send SIGTERM to " + name + " (pid " + pid + ")?"
}

// A failure has to be shown rather than swallowed: a process owned by another
// user is exactly the case this panel cannot do anything about, and silence
// would read as success.
function terminateFailure(exitCode, stderr, row) {
  var code = Math.round(toNumber(exitCode, -1))
  if (code === 0) return ""

  var detail = sanitizeText(stderr, 140)
  if (!detail) detail = "kill exited " + code
  return "Could not end " + processName(row) + ": " + detail
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
    sanitizeText: sanitizeText,
    parseProcesses: parseProcesses,
    normalizeSortKey: normalizeSortKey,
    sortOptions: sortOptions,
    sortIndexFor: sortIndexFor,
    sortKeyForIndex: sortKeyForIndex,
    sortProcesses: sortProcesses,
    clampIndex: clampIndex,
    processName: processName,
    processDetail: processDetail,
    processTooltip: processTooltip,
    processMemory: processMemory,
    clampLimit: clampLimit,
    clampSeconds: clampSeconds,
    statsCommand: statsCommand,
    processesCommand: processesCommand,
    meminfoCommand: meminfoCommand,
    terminateCommand: terminateCommand,
    terminateMessage: terminateMessage,
    terminateFailure: terminateFailure
  }
}
