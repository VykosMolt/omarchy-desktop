import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Ui
import qs.Commons
import "Model.js" as Model

// CPU and memory in the bar, and a task manager in the popup.
//
// Same shape as the power plugin: one bar-widget entry point that is both the
// bar item and the panel it opens. The bar polls
// `omarchy-system-stats --bar-widget` on a timer and turns two consecutive
// readings of /proc/stat into a percentage; the panel adds /proc/meminfo, the
// open windows straight off Hyprland's toplevel list, and every process from
// `omarchy-system-processes`, and only while it is open.
//
// The panel has two views over the same machine. Apps is one row per window,
// which is what "kill that app" means to a user: close it the way its own
// close button would, or end its process. Processes is the full ranking with
// a filter, for the thing that has no window. Both share one keyboard model:
// j/k walk rows, h/l switch views, `/` or just typing filters, `x` ends, `c`
// closes a window, Enter focuses one.
//
// Ending is SIGTERM behind a confirmation. SIGKILL exists, because a task
// manager that cannot kill a hung app is not one, but it is only ever offered
// for a pid this panel already sent SIGTERM to and that is still running --
// the row's action turns into Force kill -- and it sits behind its own
// confirmation naming what is lost.
//
// Every command is an argument vector. Process names, window titles and
// command lines are whatever the process chose to call itself, so nothing
// from a row is ever interpolated into a command, and everything painted goes
// through Model.sanitizeText first.
Panel {
  id: root
  moduleName: "omarchy.system-monitor"
  ipcTarget: "omarchy.system-monitor"
  // The IPC target grows two view methods, so this file owns the handler.
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property color hoverFill: Style.hoverFillFor(foreground, Color.accent)
  readonly property color selectedFill: Style.selectedFillFor(foreground, Color.accent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool vertical: bar ? bar.vertical : false
  readonly property var appLibrary: bar && bar.shell && bar.shell.appLibrary ? bar.shell.appLibrary : null

  // ---- settings -----------------------------------------------------------
  readonly property int barIntervalMs: Model.clampSeconds(setting("barIntervalSec", 3), 3, 2, 60) * 1000
  readonly property int processIntervalMs: Model.clampSeconds(setting("processIntervalSec", 4), 4, 2, 60) * 1000
  readonly property int processLimit: Model.clampLimit(setting("processLimit", 25))

  // ---- live state ---------------------------------------------------------
  // The previous pair of /proc/stat counters. A percentage needs two readings,
  // so until there is a previous one there is nothing honest to print: -1 is
  // the "not known yet" sentinel every formatter renders as an em dash.
  property var previousCpuSample: null
  property string processError: ""
  property int emptyProcessReads: 0
  property real cpuPercent: -1
  property real memoryPercent: -1
  property real loadAverage: -1
  property var memoryInfo: ({})
  property var processes: []
  property var windows: []

  // A percentage needs two readings, so at the interval the bar polls at the
  // widget would sit on an em dash for the first few seconds of a session.
  // These are the extra early reads that close that gap, capped so a machine
  // whose counters never advance cannot turn them into a fast poll loop.
  property int primeAttempts: 0
  readonly property int primeAttemptLimit: 2

  // ---- view state ---------------------------------------------------------
  // Remembered across open and close within a session: someone who switched
  // to Processes is looking at processes.
  property string view: "apps"
  property string sortKey: "cpu"
  property string filterText: ""
  property bool cursorActive: false
  property int selectedIndex: -1

  readonly property bool appsView: view === "apps"
  readonly property var visibleProcesses: Model.limitProcesses(
    Model.filterProcesses(Model.sortProcesses(processes, sortKey), filterText), processLimit, filterText)
  readonly property var visibleWindows: Model.filterWindows(
    Model.attachUsage(Model.sortWindows(windows), processes), filterText)
  readonly property var visibleRows: appsView ? visibleWindows : visibleProcesses

  // ---- signals ------------------------------------------------------------
  // `terminatedPids` is the set of pids this panel has sent SIGTERM to, pruned
  // to the ones still running on every process sample: a row whose pid is in
  // it offers Force kill instead of End. `confirmRow` non-null means the
  // dialog is up; `signalingRow` is the row a signal is in flight for.
  property var terminatedPids: ({})
  property var confirmRow: null
  property string confirmSignal: Model.TERM
  property var signalingRow: null
  property string signalingSignal: Model.TERM
  property string terminateError: ""

  readonly property bool confirming: confirmRow !== null

  function refreshStats() {
    if (statsProc.running) return
    statsProc.running = true
  }

  function refreshMemory() {
    if (meminfoProc.running) return
    meminfoProc.running = true
  }

  // One sample in flight at a time. omarchy-system-processes costs its own
  // sampling interval plus change, which is longer than a fast timer tick.
  function refreshProcesses() {
    if (processesProc.running) return
    processesProc.command = Model.processesCommand(0.5)
    processesProc.running = true
  }

  // Windows come off the toplevel handles Quickshell already holds for the
  // workspaces widget, so this costs no process. The pid and class live on the
  // handle's IPC object, which lags a fresh window by a beat; the refresh asks
  // Hyprland for them and the settle timer rebuilds once they have arrived.
  function refreshWindows() {
    var handles = Hyprland.toplevels.values || []
    var list = []
    for (var i = 0; i < handles.length; i++) {
      var t = handles[i]
      if (!t) continue
      var ipc = t.lastIpcObject || {}
      var wayland = t.wayland
      var appId = wayland ? String(wayland.appId || "") : ""
      var className = String(ipc["class"] || ipc.initialClass || appId || "")
      var entry = root.lookupEntry(className, appId)
      list.push({
        address: t.address,
        pid: ipc.pid,
        appId: appId,
        className: className,
        title: t.title,
        workspaceId: t.workspace ? t.workspace.id : (ipc.workspace ? ipc.workspace.id : null),
        mapped: ipc.mapped,
        hidden: ipc.hidden,
        activated: t.activated === true,
        name: entry ? entry.name : "",
        icon: entry ? entry.icon : "",
        handle: t
      })
    }
    root.windows = Model.parseWindows(list)
  }

  function requestWindowRefresh() {
    Hyprland.refreshToplevels()
    root.refreshWindows()
    windowSettle.restart()
  }

  // The desktop entry behind a window class, for its name and icon. Hyprland
  // reports the class as the app set it, which is the desktop id for most
  // Wayland apps and a bare binary name for the rest; the heuristic lookup
  // covers both, and a miss just leaves the class as the name.
  function lookupEntry(className, appId) {
    var candidates = [className, appId]
    for (var i = 0; i < candidates.length; i++) {
      var key = String(candidates[i] || "")
      if (key === "") continue
      var entry = DesktopEntries.heuristicLookup(key)
      if (entry) return entry
    }
    return null
  }

  function iconSource(row) {
    var r = row || {}
    if (r.icon && root.appLibrary) return root.appLibrary.iconSource(r.icon)
    if (r.icon) return Quickshell.iconPath(String(r.icon), true)
    if (r.className) return Quickshell.iconPath(String(r.className), true)
    return ""
  }

  function applyStats(raw) {
    var stats = Model.parseBarStats(raw)
    var percent = Model.cpuPercent(root.previousCpuSample, stats)
    var sample = Model.cpuSample(stats)

    // Only replace the stored sample when this reading actually carried one,
    // so a single garbled read costs one tick rather than resetting the delta.
    if (sample) root.previousCpuSample = sample
    if (percent !== null) root.cpuPercent = percent
    if (stats.memory !== null) root.memoryPercent = stats.memory
    if (stats.load !== null) root.loadAverage = stats.load

    if (root.cpuPercent < 0 && root.previousCpuSample && root.primeAttempts < root.primeAttemptLimit) {
      root.primeAttempts++
      primeTimer.restart()
    }
  }

  function applyMemory(raw) {
    var info = Model.parseMeminfo(raw)
    // Keep the last good reading rather than collapsing the section on a
    // truncated read.
    if (info.totalKb === undefined) return
    root.memoryInfo = info
  }

  function applyProcesses(raw) {
    var rows = Model.parseProcesses(raw)
    // An empty answer is what a sampling race in the command looks like; the
    // machine always has processes, so keep the list that is on screen. Two
    // in a row is not a race any more, and silently repainting a stale table
    // forever is worse than admitting the reading failed -- which is exactly
    // what happened when one process with a tab in its arguments made every
    // sample fail.
    if (rows.length === 0) {
      root.emptyProcessReads += 1
      if (root.emptyProcessReads >= 2 && root.processError === "") {
        root.processError = "Process list is not updating"
      }
      return
    }

    root.emptyProcessReads = 0
    root.processError = ""
    root.processes = rows
    // A pid that is gone has nothing left to force kill; one that is still
    // here after SIGTERM keeps its offer.
    root.terminatedPids = Model.pruneTerminated(root.terminatedPids, rows)
    root.clampSelection()
  }

  function clampSelection() {
    root.selectedIndex = root.selectedIndex < 0
      ? -1
      : Model.clampIndex(root.selectedIndex, root.visibleRows.length)
  }

  function setSort(key) {
    root.sortKey = Model.normalizeSortKey(key)
    if (root.selectedIndex >= 0) root.selectedIndex = 0
  }

  function setView(view) {
    var next = Model.normalizeView(view)
    if (next === root.view) return
    root.view = next
    root.selectedIndex = root.cursorActive && root.visibleRows.length > 0 ? 0 : -1
  }

  function openView(view) {
    root.setView(view)
    if (!root.opened) root.open()
  }

  function selectedRow() {
    var list = root.visibleRows
    if (root.selectedIndex < 0 || root.selectedIndex >= list.length) return null
    return list[root.selectedIndex]
  }

  function focusRow(index) {
    root.cursorActive = true
    root.selectedIndex = Model.clampIndex(index, root.visibleRows.length)
  }

  function focusFilter() {
    filterField.forceActiveFocus()
    filterField.selectAll()
  }

  function blurFilter() {
    keyCatcher.forceActiveFocus()
  }

  function clearFilter() {
    root.filterText = ""
    filterField.text = ""
  }

  function moveCursor(dx, dy) {
    if (root.confirming) {
      if (dx !== 0) root.toggleConfirmChoice()
      return
    }

    if (dx !== 0) {
      // Left/right switches the view wherever the cursor is: Apps and
      // Processes are the two things this panel is, and the sort has its own
      // key.
      root.setView(Model.viewForIndex(Model.viewIndexFor(root.view) + dx))
      return
    }

    if (!root.cursorActive) {
      root.cursorActive = true
      root.selectedIndex = root.visibleRows.length > 0 ? 0 : -1
      return
    }

    if (dy < 0 && root.selectedIndex <= 0) {
      // Up off the top of the list lands in the filter, the way the eye reads
      // the panel.
      root.cursorActive = false
      root.selectedIndex = -1
      root.focusFilter()
      return
    }
    root.selectedIndex = Model.clampIndex(root.selectedIndex + dy, root.visibleRows.length)
  }

  function activateCursor() {
    if (root.confirming) {
      if (confirmDialog.selectedIndex === 1) root.confirmSignalRequest()
      else root.cancelSignalRequest()
      return
    }
    if (!root.cursorActive) {
      root.cursorActive = true
      root.selectedIndex = root.visibleRows.length > 0 ? 0 : -1
      return
    }
    if (root.appsView) root.focusWindow(root.selectedRow())
  }

  function handleTab(direction) {
    if (root.confirming) {
      root.toggleConfirmChoice()
      return
    }
    root.switchPanel(direction)
  }

  function handleClose() {
    if (root.confirming) {
      root.cancelSignalRequest()
      return
    }
    root.close()
  }

  // Single letters that are not navigation. Anything else printable starts a
  // filter, so the panel can be searched by just typing into it.
  function handleTextKey(text) {
    if (root.confirming) return
    var key = String(text || "")
    if (key === "/") {
      root.focusFilter()
      return
    }
    if (key === "s" || key === "S") {
      if (!root.appsView) root.setSort(Model.otherSortKey(root.sortKey))
      return
    }
    if (key === "c" || key === "C") {
      if (root.appsView) root.closeWindow(root.selectedRow())
      return
    }
    if (key.length !== 1 || key === " ") return
    if (/[\u0000-\u001f\u007f]/.test(key)) return
    root.filterText = root.filterText + key
    filterField.text = root.filterText
    filterField.forceActiveFocus()
    filterField.cursorPosition = filterField.text.length
  }

  // ---- window actions -----------------------------------------------------

  // What the window's own close button does: the app gets to ask about
  // unsaved work. Nothing to confirm here, because nothing is lost by it.
  function closeWindow(row) {
    if (!row || !row.handle || !row.handle.wayland) return
    row.handle.wayland.close()
    windowSettle.restart()
  }

  function focusWindow(row) {
    if (!row || !row.handle || !row.handle.wayland) return
    row.handle.wayland.activate()
    root.close()
  }

  // ---- signals ------------------------------------------------------------

  // The dialog owns which button is selected -- its own mouse hover writes
  // there too -- so the panel reads and writes that rather than mirroring it.
  function toggleConfirmChoice() {
    confirmDialog.selectedIndex = confirmDialog.selectedIndex === 0 ? 1 : 0
  }

  function requestSignal(row) {
    if (!row || signalProc.running) return
    if (!(row.pid > 1)) {
      root.terminateError = "No process is known for " + Model.rowName(row, root.appsView) + " yet"
      return
    }
    root.terminateError = ""
    // Cancel is the landing point: this is the one destructive thing here, so
    // a stray Enter must not end a process.
    confirmDialog.selectedIndex = 0
    root.confirmSignal = Model.signalFor(row, root.terminatedPids)
    root.confirmRow = row
  }

  function requestSignalSelected() {
    if (root.confirming) return
    root.requestSignal(root.selectedRow())
  }

  function cancelSignalRequest() {
    root.confirmRow = null
  }

  function confirmSignalRequest() {
    var row = root.confirmRow
    var name = root.confirmSignal
    root.confirmRow = null
    if (!row || signalProc.running) return

    // Re-derived at the moment of sending, not taken from the dialog: KILL is
    // only sent to a pid this panel has already sent TERM to.
    if (name === Model.KILL && !Model.canForceKill(row, root.terminatedPids)) name = Model.TERM

    var argv = Model.signalCommand(row.pid, name)
    if (!argv) {
      root.terminateError = "Refusing to signal " + Model.rowName(row, root.appsView)
      return
    }

    root.signalingRow = row
    root.signalingSignal = name
    root.terminateError = ""
    signalProc.command = argv
    signalProc.running = true
  }

  onOpenedChanged: {
    if (opened) {
      cursorActive = false
      selectedIndex = -1
      confirmRow = null
      terminateError = ""
      refreshStats()
      refreshMemory()
      refreshProcesses()
      requestWindowRefresh()
    } else {
      confirmRow = null
      // A pid can be reused while nobody is watching, and the offer to force
      // kill must never land on a different process than the one asked.
      terminatedPids = ({})
      clearFilter()
    }
  }

  onFilterTextChanged: clampSelection()

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // Horizontally the bar item is a text block rather than an icon, so the
  // open-panel mark takes the painted label width; vertically it is a stack of
  // icon-sized lines, so it takes one line's worth.
  readonly property real openPanelIndicatorWidth: button.labelWidth
  readonly property real openPanelIndicatorHeight: Math.max(Style.space(10), Math.round(Style.bar.iconSlot * 0.55))

  readonly property var barLines: Model.barLines(cpuPercent, memoryPercent)

  // ---- ipc --------------------------------------------------------------

  IpcHandler {
    target: "omarchy.system-monitor"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function apps(): void { root.openView("apps") }
    function processes(): void { root.openView("processes") }
  }

  // ---- data -------------------------------------------------------------

  Process {
    id: statsProc
    command: Model.statsCommand()
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyStats(text)
    }
  }

  Process {
    id: meminfoProc
    command: Model.meminfoCommand()
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyMemory(text)
    }
  }

  Process {
    id: processesProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyProcesses(text)
    }
    stderr: StdioCollector {
      id: processesStderr
      waitForEnd: true
    }
    // Without this a failing sampler was invisible: the collector handed over
    // an empty string, applyProcesses read that as a race, and the panel kept
    // painting the last good table with nothing to say a reading had failed.
    onExited: function(exitCode) {
      if (exitCode === 0) return
      root.processError = Model.processFailure(exitCode, processesStderr.text)
    }
  }

  Process {
    id: signalProc
    stderr: StdioCollector {
      id: signalStderr
      waitForEnd: true
    }
    onExited: function(exitCode) {
      var row = root.signalingRow
      var name = root.signalingSignal
      root.terminateError = Model.signalFailure(exitCode, signalStderr.text, row, name, root.appsView)
      // Delivered TERM is what earns the Force kill offer; one that was
      // refused earns nothing, since KILL would be refused the same way.
      if (exitCode === 0 && name === Model.TERM && row) {
        root.terminatedPids = Model.markTerminated(root.terminatedPids, row.pid)
      }
      root.signalingRow = null
      // Give the process a beat to go away before re-listing, so a successful
      // signal does not leave the row on screen until the next poll.
      terminateSettle.restart()
    }
  }

  Connections {
    target: Hyprland.toplevels
    function onValuesChanged() { if (root.opened) root.requestWindowRefresh() }
  }

  Timer {
    id: primeTimer
    interval: 800
    repeat: false
    onTriggered: root.refreshStats()
  }

  Timer {
    id: terminateSettle
    interval: 400
    repeat: false
    onTriggered: {
      if (!root.opened) return
      root.refreshProcesses()
      root.requestWindowRefresh()
    }
  }

  Timer {
    id: windowSettle
    interval: 350
    repeat: false
    onTriggered: if (root.opened) root.refreshWindows()
  }

  // The bar sample. Stops with the widget: nothing samples in the background
  // once the bar item is gone.
  Timer {
    id: statsTimer
    interval: root.opened ? Math.min(root.barIntervalMs, 2000) : root.barIntervalMs
    repeat: true
    running: root.visible || root.opened
    triggeredOnStart: true
    onTriggered: {
      root.refreshStats()
      if (root.opened) root.refreshMemory()
    }
  }

  // The process list only exists while someone is looking at it. Windows
  // refresh on the same tick so their titles and figures keep up.
  Timer {
    id: processTimer
    interval: root.processIntervalMs
    repeat: true
    running: root.opened
    onTriggered: {
      root.refreshProcesses()
      root.refreshWindows()
    }
  }

  // ---- bar item ---------------------------------------------------------

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.vertical ? "" : Model.barLabel(root.cpuPercent, root.memoryPercent)
    labelVisible: !root.vertical
    hasVisualContent: true
    fixedHeight: root.vertical ? root.barLines.length * Style.bar.iconSlot : -1
    tooltipText: Model.barTooltip(root.cpuPercent, root.memoryPercent, root.loadAverage)

    onPressed: function(b) { root.toggle() }

    Column {
      visible: root.vertical
      anchors.fill: parent

      Repeater {
        model: root.barLines

        OpticalGlyph {
          required property string modelData
          width: button.width
          height: Style.bar.iconSlot
          text: modelData
          fontFamily: button.fontFamily
          fontSize: button.fontSize
          color: button.foreground
        }
      }
    }
  }

  // ---- panel ------------------------------------------------------------

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(460))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // While the filter has focus every key is a character for it; the field
      // hands focus back on Escape, Enter, Down and Tab.
      blocked: filterField.activeFocus

      onMoveRequested: function(dx, dy) { root.moveCursor(dx, dy) }
      onActivateRequested: root.activateCursor()
      onCloseRequested: root.handleClose()
      onDeleteRequested: root.requestSignalSelected()
      onTabRequested: function(direction) { root.handleTab(direction) }
      onTextKey: function(text) { root.handleTextKey(text) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // ---------- CPU and memory ----------
        Row {
          id: gauges
          width: parent.width
          spacing: Style.space(20)

          readonly property real columnWidth: (width - spacing) / 2

          Column {
            width: gauges.columnWidth
            spacing: Style.space(6)

            PanelSectionHeader {
              text: "CPU"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              textFormat: Text.PlainText
              text: Model.formatPercent(root.cpuPercent, 0)
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.displayLarge
              font.bold: true
            }

            Gauge {
              width: parent.width
              fraction: Model.fraction(root.cpuPercent)
            }

            InfoPair {
              label: "Load 1m"
              value: Model.formatLoad(root.loadAverage)
            }
          }

          Column {
            width: gauges.columnWidth
            spacing: Style.space(6)

            PanelSectionHeader {
              text: "MEMORY"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              textFormat: Text.PlainText
              text: Model.formatPercent(root.memoryPercent, 0)
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.displayLarge
              font.bold: true
            }

            Gauge {
              width: parent.width
              fraction: Model.fraction(root.memoryPercent)
            }

            InfoPair {
              label: "Used"
              value: Model.formatUsage(root.memoryInfo.usedKb, root.memoryInfo.totalKb)
            }

            InfoPair {
              label: "Cached"
              value: Model.formatKb(root.memoryInfo.cachedKb === undefined ? -1 : root.memoryInfo.cachedKb)
            }

            InfoPair {
              visible: root.memoryInfo.swapTotalKb > 0
              label: "Swap"
              value: Model.formatUsage(root.memoryInfo.swapUsedKb, root.memoryInfo.swapTotalKb)
            }
          }
        }

        // ---------- tasks ----------
        PanelSeparator {
          foreground: root.foreground
        }

        Item {
          width: parent.width
          implicitHeight: Math.max(viewGroup.implicitHeight, sortGroup.implicitHeight)

          ButtonGroup {
            id: viewGroup
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            focusable: false
            options: Model.viewOptions()
            value: root.view
            foreground: root.foreground
            background: Color.popups.background
            accent: Color.accent
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            onChanged: function(v) { root.setView(v) }
          }

          ButtonGroup {
            id: sortGroup
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            visible: !root.appsView
            focusable: false
            options: Model.sortOptions()
            value: root.sortKey
            foreground: root.foreground
            background: Color.popups.background
            accent: Color.accent
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            onChanged: function(v) { root.setSort(v) }
          }
        }

        TextField {
          id: filterField
          width: parent.width
          placeholderText: root.appsView ? "Filter apps — type, or press /" : "Filter processes — type, or press /"
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          foreground: root.foreground
          verticalPadding: Style.spacing.controlPaddingY

          onTextChanged: if (text !== root.filterText) root.filterText = text

          // Escape clears and leaves; Down, Enter and Tab leave for the list
          // with the filter kept. A second Escape then closes the panel.
          Keys.onEscapePressed: {
            root.clearFilter()
            root.blurFilter()
          }
          Keys.onDownPressed: {
            root.blurFilter()
            root.focusRow(0)
          }
          Keys.onReturnPressed: {
            root.blurFilter()
            root.focusRow(0)
          }
          Keys.onEnterPressed: {
            root.blurFilter()
            root.focusRow(0)
          }
          Keys.onTabPressed: root.blurFilter()
        }

        Text {
          textFormat: Text.PlainText
          visible: root.terminateError !== "" || root.processError !== ""
          width: parent.width
          text: root.terminateError !== "" ? root.terminateError : root.processError
          color: root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        Text {
          textFormat: Text.PlainText
          visible: root.visibleRows.length === 0
          width: parent.width
          text: Model.emptyMessage(root.view, root.filterText, root.processes.length === 0)
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        // Capped so a long list cannot push the popup off screen. ListView
        // rather than Repeater for positionViewAtIndex, which is what keeps
        // the keyboard-selected row on screen as j/k walk past the window.
        ListView {
          id: taskList
          visible: root.visibleRows.length > 0
          width: parent.width
          height: Math.min(contentHeight, Style.space(300))
          spacing: Style.space(2)
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height

          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          model: root.visibleRows
          currentIndex: root.selectedIndex
          onCurrentIndexChanged: if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain)

          // The delegate context does not bind into a nested `component`
          // declaration, so the wrapper takes the required properties and
          // hands them down explicitly.
          delegate: Item {
            required property var modelData
            required property int index

            width: ListView.view.width
            implicitHeight: taskRow.implicitHeight

            TaskRow {
              id: taskRow
              width: parent.width
              row: parent.modelData
              rowIndex: parent.index
              isWindow: root.appsView
            }
          }
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: root.appsView
            ? "j/k move · Enter focus · c close · x end · / filter"
            : "j/k move · s sort · x end · / filter"
          color: root.dim
          opacity: 0.7
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      ConfirmDialog {
        id: confirmDialog
        anchors.fill: parent
        z: 10
        opened: root.confirming
        message: Model.signalMessage(root.confirmRow, root.confirmSignal, root.appsView)
        confirmText: Model.signalActionLabel(root.confirmSignal)
        // The dialog sits on the popup card, not on the bar, so it takes the
        // popup ground rather than the bar's.
        background: Color.popups.background
        foreground: root.foreground
        fontFamily: root.fontFamily
        onCanceled: root.cancelSignalRequest()
        onConfirmed: root.confirmSignalRequest()
      }
    }
  }

  // ---- components -------------------------------------------------------

  // Track-and-fill bar, the same shape the power panel uses for charge.
  component Gauge: Item {
    id: gauge
    property real fraction: 0

    implicitHeight: Style.space(6)

    Rectangle {
      id: gaugeTrack
      anchors.fill: parent
      radius: height / 2
      color: Util.alpha(root.foreground, 0.12)
    }

    Rectangle {
      anchors.left: gaugeTrack.left
      anchors.verticalCenter: gaugeTrack.verticalCenter
      height: gaugeTrack.height
      radius: gaugeTrack.radius
      color: root.foreground
      width: Math.max(gaugeTrack.height, gaugeTrack.width * gauge.fraction)

      Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
    }
  }

  component InfoPair: Item {
    id: pair
    property string label: ""
    property string value: ""

    width: parent ? parent.width : implicitWidth
    implicitWidth: pairLabel.implicitWidth + pairValue.implicitWidth + Style.space(8)
    implicitHeight: visible ? Math.max(pairLabel.implicitHeight, pairValue.implicitHeight) : 0

    Text {
      id: pairLabel
      textFormat: Text.PlainText
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: pair.label
      color: root.foreground
      opacity: 0.6
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Text {
      id: pairValue
      textFormat: Text.PlainText
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: pair.value
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
      width: Math.min(implicitWidth, Math.max(0, pair.width - pairLabel.implicitWidth - Style.space(8)))
    }
  }

  // One window or one process. The name leads, the title or command line
  // follows as a truncated detail line with the fuller value in the tooltip,
  // and the two numbers sit in fixed columns so the list reads as a table
  // rather than ragged text. Windows carry their app icon and a close action;
  // both kinds carry End, which becomes Force kill once SIGTERM was ignored.
  component TaskRow: CursorSurface {
    id: taskRowItem
    required property var row
    required property int rowIndex
    property bool isWindow: false

    readonly property bool rowSelected: root.cursorActive && root.selectedIndex === rowIndex
    readonly property bool showActions: rowSelected || rowMouse.containsMouse
    // The action buttons carry their own tooltips, so the row's steps aside
    // while the pointer is on one rather than stacking two tooltips on a row.
    property bool actionHovered: false
    readonly property bool signaling: root.signalingRow !== null
      && root.signalingRow.pid === taskRowItem.row.pid
      && taskRowItem.row.pid > 0
    readonly property string pendingSignal: Model.signalFor(taskRowItem.row, root.terminatedPids)
    readonly property bool escalated: pendingSignal === Model.KILL
    readonly property bool hasPid: taskRowItem.row.pid > 1
    readonly property string workspaceLabel: isWindow ? Model.windowWorkspaceLabel(taskRowItem.row) : ""
    readonly property string iconUrl: isWindow ? root.iconSource(taskRowItem.row) : ""

    hasCursor: rowSelected
    foreground: root.foreground
    fill: root.hoverFill
    currentFill: root.selectedFill
    implicitHeight: rowContent.implicitHeight + Style.spacing.lg

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.LeftButton
      cursorShape: taskRowItem.isWindow ? Qt.PointingHandCursor : Qt.ArrowCursor
      onContainsMouseChanged: if (containsMouse) root.focusRow(taskRowItem.rowIndex)
      onClicked: if (taskRowItem.isWindow) root.focusWindow(taskRowItem.row)
    }

    PanelToolTip {
      visible: rowMouse.containsMouse && !taskRowItem.actionHovered
      text: taskRowItem.isWindow ? Model.windowTooltip(taskRowItem.row) : Model.processTooltip(taskRowItem.row)
      fontFamily: root.fontFamily
    }

    Item {
      id: rowContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      implicitHeight: Math.max(rowLabels.implicitHeight, actions.implicitHeight, appIcon.height)

      Image {
        id: appIcon
        visible: taskRowItem.isWindow && status === Image.Ready
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        width: Style.font.iconLarge
        height: Style.font.iconLarge
        fillMode: Image.PreserveAspectFit
        // Decode at twice the logical size so PNG icons stay crisp on HiDPI.
        sourceSize.width: width * 2
        sourceSize.height: height * 2
        source: taskRowItem.iconUrl
        asynchronous: true
      }

      Text {
        id: appGlyph
        textFormat: Text.PlainText
        visible: taskRowItem.isWindow && !appIcon.visible
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        width: Style.font.iconLarge
        horizontalAlignment: Text.AlignHCenter
        text: "󰣆"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
      }

      Column {
        id: rowLabels
        anchors.left: parent.left
        anchors.leftMargin: taskRowItem.isWindow ? Style.font.iconLarge + Style.space(8) : 0
        anchors.right: rowFigures.left
        anchors.rightMargin: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(1)

        Row {
          width: parent.width
          spacing: Style.space(6)

          Text {
            id: nameText
            textFormat: Text.PlainText
            width: Math.min(implicitWidth, parent.width - (workspaceTag.visible ? workspaceTag.width + parent.spacing : 0))
            text: taskRowItem.isWindow ? Model.windowName(taskRowItem.row) : Model.processName(taskRowItem.row)
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: taskRowItem.isWindow && taskRowItem.row.activated === true
            elide: Text.ElideRight
          }

          Text {
            id: workspaceTag
            textFormat: Text.PlainText
            visible: taskRowItem.workspaceLabel !== ""
            anchors.verticalCenter: parent.verticalCenter
            text: "ws " + taskRowItem.workspaceLabel
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: taskRowItem.signaling
            ? (root.signalingSignal === Model.KILL ? "Killing…" : "Ending…")
            : (taskRowItem.escalated
              ? "Still running after SIGTERM — force kill is available"
              : (taskRowItem.isWindow ? Model.windowDetail(taskRowItem.row) : Model.processDetail(taskRowItem.row)))
          color: taskRowItem.escalated ? root.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Row {
        id: rowFigures
        anchors.right: actions.left
        anchors.rightMargin: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(10)

        Text {
          textFormat: Text.PlainText
          text: Model.formatPercent(taskRowItem.row.cpu, 1)
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          horizontalAlignment: Text.AlignRight
          width: Style.space(52)
        }

        Text {
          textFormat: Text.PlainText
          text: Model.processMemory(taskRowItem.row)
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          horizontalAlignment: Text.AlignRight
          width: Style.space(62)
        }
      }

      Item {
        id: actions
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        readonly property int gap: Style.space(2)
        // Reserve the space whether or not the buttons are showing, so the
        // figures do not jump when the pointer arrives. An Item rather than a
        // Row: a Row sizes itself to its visible children, which is exactly
        // the jump this avoids.
        implicitWidth: signalButton.size + (taskRowItem.isWindow ? signalButton.size + gap : 0)
        implicitHeight: signalButton.size
        width: implicitWidth
        height: implicitHeight

        PanelActionButton {
          id: closeButton
          visible: taskRowItem.isWindow && taskRowItem.showActions
          anchors.right: signalButton.left
          anchors.rightMargin: actions.gap
          anchors.verticalCenter: parent.verticalCenter
          iconText: "󰅖"
          tooltipText: "Close window"
          foreground: root.foreground
          hoverColor: root.foreground
          fontFamily: root.fontFamily
          onHovered: function(isHovered) {
            taskRowItem.actionHovered = isHovered
            if (isHovered) root.focusRow(taskRowItem.rowIndex)
          }
          onClicked: root.closeWindow(taskRowItem.row)
        }

        PanelActionButton {
          id: signalButton
          visible: taskRowItem.showActions
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          enabled: taskRowItem.hasPid
          iconText: Model.signalIcon(taskRowItem.pendingSignal)
          tooltipText: taskRowItem.hasPid ? Model.signalTooltip(taskRowItem.pendingSignal) : "No process known for this window yet"
          foreground: taskRowItem.escalated ? root.urgent : root.foreground
          hoverColor: root.urgent
          fontFamily: root.fontFamily
          onHovered: function(isHovered) {
            taskRowItem.actionHovered = isHovered
            if (isHovered) root.focusRow(taskRowItem.rowIndex)
          }
          onClicked: root.requestSignal(taskRowItem.row)
        }
      }
    }
  }
}
