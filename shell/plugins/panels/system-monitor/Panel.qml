import QtQuick
import QtQuick.Controls
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

// CPU and memory in the bar, and the processes behind them in the popup.
//
// Same shape as the power plugin: one bar-widget entry point that is both the
// bar item and the panel it opens. The bar polls
// `omarchy-system-stats --bar-widget` on a timer and turns two consecutive
// readings of /proc/stat into a percentage; the panel adds /proc/meminfo and
// `omarchy-system-processes`, and only while it is open.
//
// Every command is an argument vector. Process names and command lines are
// whatever the process chose to call itself, so nothing from a row is ever
// interpolated into a command, and everything painted goes through
// Model.sanitizeText first.
Panel {
  id: root
  moduleName: "omarchy.system-monitor"
  ipcTarget: "omarchy.system-monitor"

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property color hoverFill: Style.hoverFillFor(foreground, Color.accent)
  readonly property color selectedFill: Style.selectedFillFor(foreground, Color.accent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool vertical: bar ? bar.vertical : false

  // ---- settings -----------------------------------------------------------
  readonly property int barIntervalMs: Model.clampSeconds(setting("barIntervalSec", 3), 3, 2, 60) * 1000
  readonly property int processIntervalMs: Model.clampSeconds(setting("processIntervalSec", 4), 4, 2, 60) * 1000
  readonly property int processLimit: Model.clampLimit(setting("processLimit", 25))

  // ---- live state ---------------------------------------------------------
  // The previous pair of /proc/stat counters. A percentage needs two readings,
  // so until there is a previous one there is nothing honest to print: -1 is
  // the "not known yet" sentinel every formatter renders as an em dash.
  property var previousCpuSample: null
  property real cpuPercent: -1
  property real memoryPercent: -1
  property real loadAverage: -1
  property var memoryInfo: ({})
  property var processes: []

  // A percentage needs two readings, so at the interval the bar polls at the
  // widget would sit on an em dash for the first few seconds of a session.
  // These are the extra early reads that close that gap, capped so a machine
  // whose counters never advance cannot turn them into a fast poll loop.
  property int primeAttempts: 0
  readonly property int primeAttemptLimit: 2

  readonly property var visibleProcesses: Model.sortProcesses(processes, sortKey)

  property string sortKey: "cpu"
  property bool cursorActive: false
  property string focusSection: "processes"  // "sort" | "processes"
  property int sortIndex: 0
  property int selectedIndex: -1

  // ---- terminate ----------------------------------------------------------
  // The one destructive thing here, so it is always SIGTERM, always behind the
  // confirm dialog, and never escalated. `terminateRow` non-null means the
  // dialog is up; `terminatingRow` is the row a signal is in flight for.
  property var terminateRow: null
  property var terminatingRow: null
  property string terminateError: ""

  readonly property bool confirming: terminateRow !== null

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
    processesProc.command = Model.processesCommand(root.processLimit, 0.5)
    processesProc.running = true
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
    // machine always has processes, so keep the list that is on screen.
    if (rows.length === 0) return
    root.processes = rows
    root.selectedIndex = root.selectedIndex < 0
      ? -1
      : Model.clampIndex(root.selectedIndex, rows.length)
  }

  function setSort(key) {
    root.sortKey = Model.normalizeSortKey(key)
    root.sortIndex = Model.sortIndexFor(root.sortKey)
    if (root.selectedIndex >= 0) root.selectedIndex = 0
  }

  function selectedProcess() {
    var list = root.visibleProcesses
    if (root.selectedIndex < 0 || root.selectedIndex >= list.length) return null
    return list[root.selectedIndex]
  }

  function focusProcess(index) {
    root.cursorActive = true
    root.focusSection = "processes"
    root.selectedIndex = Model.clampIndex(index, root.visibleProcesses.length)
  }

  function moveCursor(dx, dy) {
    if (root.confirming) {
      if (dx !== 0) root.toggleTerminateChoice()
      return
    }

    if (!root.cursorActive) {
      root.cursorActive = true
      root.focusSection = "processes"
      root.selectedIndex = root.visibleProcesses.length > 0 ? 0 : -1
      return
    }

    if (dy !== 0) {
      if (root.focusSection === "sort") {
        if (dy > 0 && root.visibleProcesses.length > 0) {
          root.focusSection = "processes"
          root.selectedIndex = 0
        }
        return
      }
      if (dy < 0 && root.selectedIndex <= 0) {
        root.focusSection = "sort"
        root.selectedIndex = -1
        return
      }
      root.selectedIndex = Model.clampIndex(root.selectedIndex + dy, root.visibleProcesses.length)
      return
    }

    if (dx !== 0) {
      // Left/right switches the sort wherever the cursor is: it is the only
      // horizontal choice on the panel.
      root.focusSection = "sort"
      root.sortIndex = Math.max(0, Math.min(1, root.sortIndex + dx))
      root.setSort(Model.sortKeyForIndex(root.sortIndex))
    }
  }

  function activateCursor() {
    if (root.confirming) {
      if (terminateConfirm.selectedIndex === 1) root.confirmTerminate()
      else root.cancelTerminate()
      return
    }
    if (!root.cursorActive) {
      root.cursorActive = true
      return
    }
    if (root.focusSection === "sort") root.setSort(Model.sortKeyForIndex(root.sortIndex))
  }

  function handleTab(direction) {
    if (root.confirming) {
      root.toggleTerminateChoice()
      return
    }
    root.switchPanel(direction)
  }

  function handleClose() {
    if (root.confirming) {
      root.cancelTerminate()
      return
    }
    root.close()
  }

  // The dialog owns which button is selected -- its own mouse hover writes
  // there too -- so the panel reads and writes that rather than mirroring it.
  function toggleTerminateChoice() {
    terminateConfirm.selectedIndex = terminateConfirm.selectedIndex === 0 ? 1 : 0
  }

  function requestTerminate(row) {
    if (!row || terminateProc.running) return
    root.terminateError = ""
    // Cancel is the landing point: this is the one destructive thing here, so
    // a stray Enter must not end a process.
    terminateConfirm.selectedIndex = 0
    root.terminateRow = row
  }

  function requestTerminateSelected() {
    if (root.confirming) return
    root.requestTerminate(root.selectedProcess())
  }

  function cancelTerminate() {
    root.terminateRow = null
  }

  function confirmTerminate() {
    var row = root.terminateRow
    root.terminateRow = null
    if (!row || terminateProc.running) return

    var argv = Model.terminateCommand(row.pid)
    if (!argv) {
      root.terminateError = "Refusing to signal " + Model.processName(row)
      return
    }

    root.terminatingRow = row
    root.terminateError = ""
    terminateProc.command = argv
    terminateProc.running = true
  }

  onOpenedChanged: {
    if (opened) {
      cursorActive = false
      focusSection = "processes"
      selectedIndex = -1
      sortIndex = Model.sortIndexFor(sortKey)
      terminateRow = null
      terminateError = ""
      refreshStats()
      refreshMemory()
      refreshProcesses()
    } else {
      terminateRow = null
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // Horizontally the bar item is a text block rather than an icon, so the
  // open-panel mark takes the painted label width; vertically it is a stack of
  // icon-sized lines, so it takes one line's worth.
  readonly property real openPanelIndicatorWidth: button.labelWidth
  readonly property real openPanelIndicatorHeight: Math.max(Style.space(10), Math.round(Style.bar.iconSlot * 0.55))

  readonly property var barLines: Model.barLines(cpuPercent, memoryPercent)

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
  }

  Process {
    id: terminateProc
    stderr: StdioCollector {
      id: terminateStderr
      waitForEnd: true
    }
    onExited: function(exitCode) {
      root.terminateError = Model.terminateFailure(exitCode, terminateStderr.text, root.terminatingRow)
      root.terminatingRow = null
      // Give the process a beat to go away before re-listing, so a successful
      // SIGTERM does not leave the row on screen until the next poll.
      terminateSettle.restart()
    }
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
    onTriggered: if (root.opened) root.refreshProcesses()
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

  // The process list only exists while someone is looking at it.
  Timer {
    id: processTimer
    interval: root.processIntervalMs
    repeat: true
    running: root.opened
    onTriggered: root.refreshProcesses()
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
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) { root.moveCursor(dx, dy) }
      onActivateRequested: root.activateCursor()
      onCloseRequested: root.handleClose()
      onDeleteRequested: root.requestTerminateSelected()
      onTabRequested: function(direction) { root.handleTab(direction) }

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

        // ---------- processes ----------
        PanelSeparator {
          foreground: root.foreground
        }

        Item {
          width: parent.width
          implicitHeight: Math.max(processHeader.implicitHeight, sortGroup.implicitHeight)

          PanelSectionHeader {
            id: processHeader
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "PROCESSES"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          ButtonGroup {
            id: sortGroup
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            focusable: false
            options: Model.sortOptions()
            value: root.sortKey
            foreground: root.foreground
            background: Color.popups.background
            accent: Color.accent
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            cursorIndex: root.cursorActive && root.focusSection === "sort" ? root.sortIndex : -1
            onChanged: function(v) { root.setSort(v) }
            onHovered: function(index, isHovered) {
              if (!isHovered) return
              root.cursorActive = true
              root.focusSection = "sort"
              root.sortIndex = index
            }
          }
        }

        Text {
          textFormat: Text.PlainText
          visible: root.terminateError !== ""
          width: parent.width
          text: root.terminateError
          color: root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        Text {
          textFormat: Text.PlainText
          visible: root.visibleProcesses.length === 0
          width: parent.width
          text: "Sampling…"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        // Capped so a long list cannot push the popup off screen. ListView
        // rather than Repeater for positionViewAtIndex, which is what keeps
        // the keyboard-selected row on screen as j/k walk past the window.
        ListView {
          id: processList
          visible: root.visibleProcesses.length > 0
          width: parent.width
          height: Math.min(contentHeight, Style.space(260))
          spacing: Style.space(2)
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height

          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          model: root.visibleProcesses
          currentIndex: root.selectedIndex
          onCurrentIndexChanged: if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain)

          // The delegate context does not bind into a nested `component`
          // declaration, so the wrapper takes the required properties and
          // hands them down explicitly.
          delegate: Item {
            required property var modelData
            required property int index

            width: ListView.view.width
            implicitHeight: processRow.implicitHeight

            ProcessRow {
              id: processRow
              width: parent.width
              row: parent.modelData
              rowIndex: parent.index
            }
          }
        }
      }

      ConfirmDialog {
        id: terminateConfirm
        anchors.fill: parent
        z: 10
        opened: root.confirming
        message: Model.terminateMessage(root.terminateRow)
        confirmText: "End"
        // The dialog sits on the popup card, not on the bar, so it takes the
        // popup ground rather than the bar's.
        background: Color.popups.background
        foreground: root.foreground
        fontFamily: root.fontFamily
        onCanceled: root.cancelTerminate()
        onConfirmed: root.confirmTerminate()
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

  // One process. The name leads, the command line follows as a truncated
  // detail line with the fuller value in the tooltip, and the two numbers sit
  // in fixed columns so the list reads as a table rather than ragged text.
  component ProcessRow: CursorSurface {
    id: processRowItem
    required property var row
    required property int rowIndex

    readonly property bool rowSelected: root.cursorActive
      && root.focusSection === "processes"
      && root.selectedIndex === rowIndex
    readonly property bool showEndButton: rowSelected || rowMouse.containsMouse
    // The end button carries its own tooltip, so the row's steps aside while
    // the pointer is on it rather than stacking two tooltips on one row.
    property bool actionHovered: false
    readonly property bool terminating: root.terminatingRow !== null
      && root.terminatingRow.pid === processRowItem.row.pid

    hasCursor: rowSelected
    foreground: root.foreground
    fill: root.hoverFill
    currentFill: root.selectedFill
    implicitHeight: rowContent.implicitHeight + Style.spacing.lg

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      onContainsMouseChanged: if (containsMouse) root.focusProcess(processRowItem.rowIndex)
    }

    PanelToolTip {
      visible: rowMouse.containsMouse && !processRowItem.actionHovered
      text: Model.processTooltip(processRowItem.row)
      fontFamily: root.fontFamily
    }

    Item {
      id: rowContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      implicitHeight: Math.max(rowLabels.implicitHeight, endButton.implicitHeight)

      Column {
        id: rowLabels
        anchors.left: parent.left
        anchors.right: rowFigures.left
        anchors.rightMargin: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: Model.processName(processRowItem.row)
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: processRowItem.terminating
            ? "Ending…"
            : Model.processDetail(processRowItem.row)
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Row {
        id: rowFigures
        anchors.right: endButton.left
        anchors.rightMargin: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(10)

        Text {
          textFormat: Text.PlainText
          text: Model.formatPercent(processRowItem.row.cpu, 1)
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          horizontalAlignment: Text.AlignRight
          width: Style.space(52)
        }

        Text {
          textFormat: Text.PlainText
          text: Model.processMemory(processRowItem.row)
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          horizontalAlignment: Text.AlignRight
          width: Style.space(62)
        }
      }

      PanelActionButton {
        id: endButton
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        visible: processRowItem.showEndButton
        iconText: "󰅙"
        tooltipText: "End process (SIGTERM)"
        foreground: root.foreground
        hoverColor: root.urgent
        fontFamily: root.fontFamily
        onHovered: function(isHovered) {
          processRowItem.actionHovered = isHovered
          if (isHovered) root.focusProcess(processRowItem.rowIndex)
        }
        onClicked: root.requestTerminate(processRowItem.row)
      }
    }
  }
}
