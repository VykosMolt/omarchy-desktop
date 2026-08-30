import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The desktop's settings panel: the knobs this session can actually drive,
// grouped into sections and reachable with
//   omarchy-shell shell toggle omarchy.settings
//
// Standalone panel plugin, so the shell's panel loader owns the lifecycle and
// calls open()/close() -- there is no bar button and no IpcHandler of its own,
// the way every other kind: "panel" plugin here works. PanelController still
// holds the open state so the panel matches the kit's panels, and
// PanelKeyCatcher provides the same j/k/h/l/Enter/Esc navigation the bar
// panels use.
//
// Two mechanisms back these settings and no third one:
//
//   shell-owned   the value lives in shell.json. It is read from
//                 shell.shellConfig -- which the shell keeps current, so the
//                 panel is always showing the file, never a cached copy of it
//                 -- and written either through shell.mutateShellConfig or
//                 through the command that owns the setting's validation.
//   system-owned  the value lives outside the shell and is read and written by
//                 running one of the port's commands.
//
// Every read is a Process, so the panel paints immediately and each value
// arrives when its command answers; nothing here ever blocks. Every write is
// followed by a re-read (system-owned) or lands in shell.json and comes back
// through shellConfig (shell-owned), so what the panel shows is what actually
// took. A command that fails puts its own message on the row instead of being
// swallowed.
//
// Model.js holds every rule worth testing -- the setting inventory and its
// ownership, the duration choices and their labels, the output parsers, and
// each command's argument vector. This file is presentation and wiring.
Item {
  id: root

  // ---- host injections ----------------------------------------------------
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  readonly property string pluginId: manifest && manifest.id ? String(manifest.id) : "omarchy.settings"

  // ---- lifecycle ----------------------------------------------------------
  PanelController { id: panelController }

  readonly property bool opened: panelController.open

  function open(payloadJson) {
    panelController.show()
    root.cursorActive = false
    root.selectedRow = Model.rowIds()[0]
    root.syncGroupIndex()
    refreshAll()
    // The window is instantiated hidden, so a `focus: true` inside it is
    // evaluated before the surface maps and Escape would land nowhere.
    Qt.callLater(function() {
      if (root.opened && keyCatcher) keyCatcher.forceActiveFocus()
    })
  }

  // Host-initiated close (`omarchy-shell shell hide`). The host already knows.
  function close() {
    panelController.hide()
  }

  // User-initiated close. Tell the shell so its openPanelIds map stays
  // consistent and the next toggle opens rather than closes.
  function dismiss() {
    panelController.hide()
    if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId)
  }

  function toggle() {
    if (root.opened) dismiss()
    else open("{}")
  }

  // ---- surface ------------------------------------------------------------
  // Shares the [menu] surface tokens: this is a summoned card over the
  // desktop, the same shape the menu and the emoji picker are, so a theme that
  // styles those styles this too.
  readonly property color background: Color.menu.background
  readonly property color foreground: Color.menu.text
  readonly property color borderColor: Color.menu.border
  readonly property color scrim: Color.menu.scrim
  readonly property color accent: Color.accent
  readonly property color urgent: Color.urgent
  readonly property var cardBorderSpec: Border.surfaceSpec("menu", "border", borderColor, Math.max(1, Style.space(2)))
  readonly property string fontFamily: Style.font.family
  readonly property color dimForeground: Qt.darker(foreground, 1.4)

  // ---- shell-owned values -------------------------------------------------
  // Read straight off the live config the shell holds, so an edit made
  // anywhere else -- omarchy-bar, a hand-edited shell.json -- shows up here
  // without the panel polling for it.
  readonly property var shellConfig: root.shell && root.shell.shellConfig ? root.shell.shellConfig : ({})
  readonly property int screenOffSeconds: Model.idleSeconds(shellConfig, "screenOff")
  readonly property int lockSeconds: Model.idleSeconds(shellConfig, "lock")
  readonly property int suspendSeconds: Model.idleSeconds(shellConfig, "suspend")
  readonly property string barPositionValue: Model.barPosition(shellConfig)
  readonly property bool barTransparentValue: Model.barTransparent(shellConfig)
  readonly property string idleSummary: Model.idleSummary(shellConfig, root.stayAwakeLoaded && root.stayAwake)

  // ---- system-owned values ------------------------------------------------
  // Each starts unloaded and its row shows a placeholder until its command
  // answers.
  property bool stayAwake: false
  property bool stayAwakeLoaded: false
  property string themeName: ""
  property bool themeLoaded: false
  property var themeOptions: []
  property string iconThemeName: ""
  property bool iconThemeLoaded: false
  property var iconThemeOptions: []
  property string fontName: ""
  property bool fontLoaded: false
  property var fontOptions: []
  property int textSizePx: 0
  property bool textSizeLoaded: false
  property string monitorScale: ""
  property bool monitorScaleLoaded: false

  // ---- failures -----------------------------------------------------------
  // rowId -> message. A row shows whatever its read, its option list, or its
  // write last failed with.
  property var errors: ({})

  function errorFor(rowId) {
    var key = String(rowId)
    return String(root.errors[key] || root.errors[key + ".options"] || "")
  }

  function setError(key, message) {
    var next = ({})
    for (var k in root.errors) next[k] = root.errors[k]
    next[String(key)] = String(message)
    root.errors = next
  }

  function clearError(key) {
    if (root.errors[String(key)] === undefined) return
    var next = ({})
    for (var k in root.errors) if (k !== String(key)) next[k] = root.errors[k]
    root.errors = next
  }

  // ---- cursor -------------------------------------------------------------
  // One highlight for the whole panel, walking every row of every section.
  // Mouse hover and the keyboard both move this same state, so the two never
  // disagree. Same recipe as the bar panels.
  property string selectedRow: Model.rowIds()[0]
  property bool cursorActive: false
  property int groupIndex: 0

  readonly property bool popupBlocking: themeDropdown.popupOpen || iconThemeDropdown.popupOpen
    || fontDropdown.popupOpen || textSizeDropdown.popupOpen || monitorScaleDropdown.popupOpen
    || screenOffDropdown.popupOpen || lockDropdown.popupOpen || suspendDropdown.popupOpen

  // A dropdown's popup is its own surface, so when it closes the panel has to
  // take the keyboard back or j/k lands nowhere.
  onPopupBlockingChanged: {
    if (popupBlocking || !opened) return
    Qt.callLater(function() {
      if (root.opened && !root.popupBlocking && keyCatcher) keyCatcher.forceActiveFocus()
    })
  }

  function focusRow(rowId) {
    root.cursorActive = true
    root.selectedRow = String(rowId)
    if (rowId === "bar.position") root.syncGroupIndex()
  }

  function syncGroupIndex() {
    var index = Model.barPositionValues().indexOf(root.barPositionValue)
    root.groupIndex = index < 0 ? 0 : index
  }

  function moveCursor(delta) {
    var index = Model.rowIndex(root.selectedRow)
    if (index < 0) index = 0
    root.selectedRow = Model.rowIds()[Model.moveRow(index, delta)]
    if (root.selectedRow === "bar.position") root.syncGroupIndex()
  }

  function moveWithinRow(delta) {
    if (root.selectedRow !== "bar.position") return
    var values = Model.barPositionValues()
    var next = root.groupIndex + delta
    root.groupIndex = Math.max(0, Math.min(values.length - 1, next))
  }

  function activateRow() {
    switch (root.selectedRow) {
      case "idle.screenOff": screenOffDropdown.toggle(); return
      case "idle.lock": lockDropdown.toggle(); return
      case "idle.suspend": suspendDropdown.toggle(); return
      case "idle.stayAwake": root.setStayAwake(!root.stayAwake); return
      case "appearance.theme": themeDropdown.toggle(); return
      case "appearance.iconTheme": iconThemeDropdown.toggle(); return
      case "appearance.font": fontDropdown.toggle(); return
      case "appearance.textSize": textSizeDropdown.toggle(); return
      case "bar.position":
        var values = Model.barPositionValues()
        if (root.groupIndex >= 0 && root.groupIndex < values.length) root.setBarPosition(values[root.groupIndex])
        return
      case "bar.transparent": root.setBarTransparent(!root.barTransparentValue); return
      case "display.scale": monitorScaleDropdown.toggle(); return
    }
  }

  // Keep the highlighted row on screen as j/k walks past the fold.
  function ensureRowVisible(item) {
    if (!item || !scrollArea) return
    var flick = scrollArea.contentItem
    if (!flick || flick.contentY === undefined) return
    var point = item.mapToItem(flick.contentItem || flick, 0, 0)
    var top = point.y
    var bottom = top + (item.height || 0)
    var margin = Style.space(12)
    if (top < flick.contentY + margin) flick.contentY = Math.max(0, top - margin)
    else if (bottom > flick.contentY + flick.height - margin)
      flick.contentY = bottom + margin - flick.height
  }

  // ---- reading ------------------------------------------------------------
  function readerFor(rowId) {
    switch (String(rowId)) {
      case "idle.stayAwake": return stayAwakeReader
      case "appearance.theme": return themeReader
      case "appearance.iconTheme": return iconThemeReader
      case "appearance.font": return fontReader
      case "appearance.textSize": return textSizeReader
      case "display.scale": return monitorScaleReader
    }
    return null
  }

  // A read already in flight was started before whatever prompted this one, so
  // its answer is stale by definition: queue another rather than settle for it.
  function refreshRow(rowId) {
    var reader = readerFor(rowId)
    if (!reader) return
    if (reader.running) reader.rerun = true
    else reader.running = true
  }

  function refreshAll() {
    var ids = Model.rowIds()
    for (var i = 0; i < ids.length; i++) {
      if (Model.ownerOf(ids[i]) === "system") refreshRow(ids[i])
    }
    if (!themeOptionsReader.running) themeOptionsReader.running = true
    if (!iconThemeOptionsReader.running) iconThemeOptionsReader.running = true
    if (!fontOptionsReader.running) fontOptionsReader.running = true
  }

  function finishRead(reader) {
    if (reader.code === 0) {
      root.clearError(reader.rowId)
      if (reader.apply) reader.apply(reader.outputText)
      return
    }
    root.setError(reader.rowId, Model.commandError(reader.command, reader.code, reader.errorText))
  }

  // ---- writing ------------------------------------------------------------
  // Shell-owned, written straight into shell.json. The displayed value is
  // bound to shell.shellConfig, which mutateShellConfig replaces, so the row
  // shows the file rather than the request.
  function setIdleStage(stage, secondsText) {
    var rowId = "idle." + stage
    if (!root.shell || typeof root.shell.mutateShellConfig !== "function") {
      root.setError(rowId, "the shell cannot write shell.json right now")
      return
    }
    var seconds = Model.secondsFromOption(secondsText)
    root.clearError(rowId)
    root.shell.mutateShellConfig(function(config) { Model.applyIdleSeconds(config, stage, seconds) })
  }

  // Shell-owned, written through omarchy-bar so the bar's own validation and
  // live patching run rather than being bypassed by a raw file write.
  function setBarPosition(position) {
    root.runWrite("bar.position", position)
  }

  function setBarTransparent(value) {
    root.runWrite("bar.transparent", value === true)
  }

  function setStayAwake(value) {
    root.runWrite("idle.stayAwake", value === true)
  }

  // One command at a time, in the order the user asked for them. Several of
  // these restart or re-theme half the desktop; running two at once is how a
  // theme switch and a font switch end up fighting over the same shell.
  property var writeQueue: []
  property string writeRow: ""

  readonly property bool busy: root.writeRow !== ""

  function busyFor(rowId) {
    return root.writeRow === String(rowId)
  }

  function runWrite(rowId, value) {
    var command = Model.writeCommand(rowId, value)
    if (!Model.isArgumentVector(command)) {
      root.setError(rowId, "no command backs " + rowId)
      return
    }
    root.writeQueue = root.writeQueue.concat([{ rowId: String(rowId), command: command }])
    root.pumpWrites()
  }

  function pumpWrites() {
    if (root.writeRow !== "" || writeProcess.running || root.writeQueue.length === 0) return
    var next = root.writeQueue[0]
    root.writeQueue = root.writeQueue.slice(1)
    root.writeRow = next.rowId
    writeProcess.command = next.command
    writeProcess.running = true
  }

  function finishWrite() {
    var rowId = root.writeRow
    root.writeRow = ""
    if (writeProcess.code === 0) root.clearError(rowId)
    else root.setError(rowId, Model.commandError(writeProcess.command, writeProcess.code, writeProcess.errorText))
    // Honest either way: ask the setting what it is now rather than assuming
    // the write took. A shell-owned row has no reader -- its value comes back
    // through shellConfig when the command reloads the shell's config.
    root.refreshRow(rowId)
    // Process.running has not necessarily dropped by the time the exit handler
    // runs, so the next command in the queue starts a tick later.
    Qt.callLater(root.pumpWrites)
  }

  // ---- processes ----------------------------------------------------------
  // A command's exit and its streams finish in no guaranteed order, so nothing
  // is decided until all three have landed.
  component Reader: Process {
    id: reader

    property string rowId: ""
    property var apply: null
    property bool rerun: false
    property string outputText: ""
    property string errorText: ""
    property int code: 0
    property bool exited: false
    property bool outDone: false
    property bool errDone: false

    function settle() {
      if (!reader.exited || !reader.outDone || !reader.errDone) return
      root.finishRead(reader)
    }

    onRunningChanged: {
      if (running) {
        reader.outputText = ""
        reader.errorText = ""
        reader.code = 0
        reader.exited = false
        reader.outDone = false
        reader.errDone = false
      } else if (reader.rerun) {
        reader.rerun = false
        Qt.callLater(function() { if (!reader.running) reader.running = true })
      }
    }

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { reader.outputText = text; reader.outDone = true; reader.settle() }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: { reader.errorText = text; reader.errDone = true; reader.settle() }
    }
    onExited: function(exitCode) { reader.code = exitCode; reader.exited = true; reader.settle() }
  }

  Reader {
    id: stayAwakeReader
    rowId: "idle.stayAwake"
    command: Model.readCommand("idle.stayAwake")
    apply: function(text) {
      var status = Model.parseIdleStatus(text)
      if (!status.ok) {
        root.setError("idle.stayAwake", "could not read the idle service's status")
        return
      }
      root.stayAwake = status.stayAwake
      root.stayAwakeLoaded = true
    }
  }

  Reader {
    id: themeReader
    rowId: "appearance.theme"
    command: Model.readCommand("appearance.theme")
    apply: function(text) {
      root.themeName = Model.parseFirstLine(text)
      root.themeLoaded = true
    }
  }

  Reader {
    id: themeOptionsReader
    rowId: "appearance.theme.options"
    command: Model.optionsCommand("appearance.theme")
    apply: function(text) { root.themeOptions = Model.parseLines(text) }
  }

  Reader {
    id: iconThemeReader
    rowId: "appearance.iconTheme"
    command: Model.readCommand("appearance.iconTheme")
    apply: function(text) {
      root.iconThemeName = Model.parseFirstLine(text)
      root.iconThemeLoaded = true
    }
  }

  Reader {
    id: iconThemeOptionsReader
    rowId: "appearance.iconTheme.options"
    command: Model.optionsCommand("appearance.iconTheme")
    apply: function(text) { root.iconThemeOptions = Model.parseLines(text) }
  }

  Reader {
    id: fontReader
    rowId: "appearance.font"
    command: Model.readCommand("appearance.font")
    apply: function(text) {
      root.fontName = Model.parseFirstLine(text)
      root.fontLoaded = true
    }
  }

  Reader {
    id: fontOptionsReader
    rowId: "appearance.font.options"
    command: Model.optionsCommand("appearance.font")
    apply: function(text) { root.fontOptions = Model.parseLines(text) }
  }

  Reader {
    id: textSizeReader
    rowId: "appearance.textSize"
    command: Model.readCommand("appearance.textSize")
    apply: function(text) {
      var size = Model.parseTextSize(text)
      if (!size.ok) {
        root.setError("appearance.textSize", "could not read the current text size")
        return
      }
      root.textSizePx = size.px
      root.textSizeLoaded = true
    }
  }

  Reader {
    id: monitorScaleReader
    rowId: "display.scale"
    command: Model.readCommand("display.scale")
    apply: function(text) {
      var scale = Model.parseMonitorScale(text)
      if (!scale.ok) {
        root.setError("display.scale", "could not read the focused monitor's scale")
        return
      }
      root.monitorScale = scale.scale
      root.monitorScaleLoaded = true
    }
  }

  Process {
    id: writeProcess

    property string errorText: ""
    property int code: 0
    property bool exited: false
    property bool errDone: false

    function settle() {
      if (!writeProcess.exited || !writeProcess.errDone) return
      root.finishWrite()
    }

    onRunningChanged: {
      if (running) {
        writeProcess.errorText = ""
        writeProcess.code = 0
        writeProcess.exited = false
        writeProcess.errDone = false
      } else {
        Qt.callLater(root.pumpWrites)
      }
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: { writeProcess.errorText = text; writeProcess.errDone = true; writeProcess.settle() }
    }
    onExited: function(exitCode) { writeProcess.code = exitCode; writeProcess.exited = true; writeProcess.settle() }
  }

  // ---- window -------------------------------------------------------------
  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "omarchy-settings"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

    readonly property int cardWidth: Math.min(Style.space(620), panel.width - Style.gapsOut * 2)
    readonly property int cardHeight: Math.min(Style.space(700), panel.height - Style.gapsOut * 2)

    Rectangle {
      anchors.fill: parent
      color: root.scrim

      MouseArea {
        anchors.fill: parent
        onClicked: root.dismiss()
      }
    }

    BorderSurface {
      id: card
      width: panel.cardWidth
      height: panel.cardHeight
      radius: Style.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.cardBorderSpec
      padding: Style.spacing.panelPadding

      // Swallow clicks so only the scrim outside the card dismisses.
      MouseArea { anchors.fill: parent; onClicked: {} }

      PanelKeyCatcher {
        id: keyCatcher
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        // A dropdown's popup owns the keyboard while it is open; without this
        // j/k would drive the popup and the panel cursor at once.
        blocked: root.popupBlocking

        onMoveRequested: function(dx, dy) {
          if (!root.cursorActive) { root.cursorActive = true; return }
          if (dy !== 0) root.moveCursor(dy)
          else if (dx !== 0) root.moveWithinRow(dx)
        }
        onActivateRequested: {
          if (!root.cursorActive) { root.cursorActive = true; return }
          root.activateRow()
        }
        onCloseRequested: root.dismiss()

        ScrollView {
          id: scrollArea
          anchors.fill: parent
          clip: true
          ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

          Column {
            id: content
            width: scrollArea.availableWidth
            spacing: Style.spacing.panelGap

            // ---- header ------------------------------------------------
            Column {
              width: parent.width
              spacing: Style.spacing.labelGap

              Text {
                textFormat: Text.PlainText
                text: "Settings"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.heading
                font.bold: true
              }

              Text {
                textFormat: Text.PlainText
                width: parent.width
                wrapMode: Text.WordWrap
                text: "j/k or arrows move, h/l pick within a row, Enter opens or toggles, Esc closes."
                color: root.dimForeground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            // ---- power & lock ------------------------------------------
            SectionHeader { sectionId: "power" }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              wrapMode: Text.WordWrap
              text: root.idleSummary
              color: root.foreground
              opacity: 0.85
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            SettingRow {
              rowId: "idle.screenOff"

              Dropdown {
                id: screenOffDropdown
                width: root.controlWidth
                showLabel: false
                fontFamily: root.fontFamily
                foreground: root.foreground
                background: root.background
                popupBorder: root.borderColor
                accent: root.accent
                options: Model.durationOptions(root.screenOffSeconds)
                value: String(root.screenOffSeconds)
                hasCursor: root.cursorActive && root.selectedRow === "idle.screenOff"
                onHovered: function(isHovered) { if (isHovered) root.focusRow("idle.screenOff") }
                onChanged: function(v) {
                  root.setIdleStage("screenOff", v)
                  // Dropdown assigns its own `value` before it emits, which
                  // drops the binding; put it back so the row keeps showing
                  // shell.json rather than the last thing clicked.
                  value = Qt.binding(function() { return String(root.screenOffSeconds) })
                }
              }
            }

            SettingRow {
              rowId: "idle.lock"

              Dropdown {
                id: lockDropdown
                width: root.controlWidth
                showLabel: false
                fontFamily: root.fontFamily
                foreground: root.foreground
                background: root.background
                popupBorder: root.borderColor
                accent: root.accent
                options: Model.durationOptions(root.lockSeconds)
                value: String(root.lockSeconds)
                hasCursor: root.cursorActive && root.selectedRow === "idle.lock"
                onHovered: function(isHovered) { if (isHovered) root.focusRow("idle.lock") }
                onChanged: function(v) {
                  root.setIdleStage("lock", v)
                  value = Qt.binding(function() { return String(root.lockSeconds) })
                }
              }
            }

            SettingRow {
              rowId: "idle.suspend"

              Dropdown {
                id: suspendDropdown
                width: root.controlWidth
                showLabel: false
                fontFamily: root.fontFamily
                foreground: root.foreground
                background: root.background
                popupBorder: root.borderColor
                accent: root.accent
                options: Model.durationOptions(root.suspendSeconds)
                value: String(root.suspendSeconds)
                hasCursor: root.cursorActive && root.selectedRow === "idle.suspend"
                onHovered: function(isHovered) { if (isHovered) root.focusRow("idle.suspend") }
                onChanged: function(v) {
                  root.setIdleStage("suspend", v)
                  value = Qt.binding(function() { return String(root.suspendSeconds) })
                }
              }
            }

            SettingRow {
              rowId: "idle.stayAwake"
              loaded: root.stayAwakeLoaded

              ToggleSwitch {
                checked: root.stayAwake
                busy: root.busyFor("idle.stayAwake")
                foreground: root.foreground
                accent: root.accent
                hasCursor: root.cursorActive && root.selectedRow === "idle.stayAwake"
                onHovered: function(isHovered) { if (isHovered) root.focusRow("idle.stayAwake") }
                onToggled: {
                  root.focusRow("idle.stayAwake")
                  root.setStayAwake(!root.stayAwake)
                }
              }
            }

            // ---- appearance --------------------------------------------
            SectionHeader { sectionId: "appearance" }

            SettingRow {
              rowId: "appearance.theme"
              loaded: root.themeLoaded

              SearchableDropdown {
                id: themeDropdown
                width: root.controlWidth
                showLabel: false
                placeholderText: "Search themes…"
                fontFamily: root.fontFamily
                foreground: root.foreground
                background: root.background
                popupBorder: root.borderColor
                accent: root.accent
                options: root.themeOptions
                value: root.themeName
                hasCursor: root.cursorActive && root.selectedRow === "appearance.theme"
                onHovered: function(isHovered) { if (isHovered) root.focusRow("appearance.theme") }
                onChanged: function(v) {
                  root.runWrite("appearance.theme", v)
                  value = Qt.binding(function() { return root.themeName })
                }
              }
            }

            SettingRow {
              rowId: "appearance.iconTheme"
              loaded: root.iconThemeLoaded

              SearchableDropdown {
                id: iconThemeDropdown
                width: root.controlWidth
                showLabel: false
                placeholderText: "Search icon themes…"
                fontFamily: root.fontFamily
                foreground: root.foreground
                background: root.background
                popupBorder: root.borderColor
                accent: root.accent
                options: root.iconThemeOptions
                value: root.iconThemeName
                hasCursor: root.cursorActive && root.selectedRow === "appearance.iconTheme"
                onHovered: function(isHovered) { if (isHovered) root.focusRow("appearance.iconTheme") }
                onChanged: function(v) {
                  root.runWrite("appearance.iconTheme", v)
                  value = Qt.binding(function() { return root.iconThemeName })
                }
              }
            }

            SettingRow {
              rowId: "appearance.font"
              loaded: root.fontLoaded

              SearchableDropdown {
                id: fontDropdown
                width: root.controlWidth
                showLabel: false
                placeholderText: "Search fonts…"
                fontFamily: root.fontFamily
                foreground: root.foreground
                background: root.background
                popupBorder: root.borderColor
                accent: root.accent
                options: root.fontOptions
                value: root.fontName
                hasCursor: root.cursorActive && root.selectedRow === "appearance.font"
                onHovered: function(isHovered) { if (isHovered) root.focusRow("appearance.font") }
                onChanged: function(v) {
                  root.runWrite("appearance.font", v)
                  value = Qt.binding(function() { return root.fontName })
                }
              }
            }

            SettingRow {
              rowId: "appearance.textSize"
              loaded: root.textSizeLoaded

              Dropdown {
                id: textSizeDropdown
                width: root.controlWidth
                showLabel: false
                fontFamily: root.fontFamily
                foreground: root.foreground
                background: root.background
                popupBorder: root.borderColor
                accent: root.accent
                options: Model.textSizeOptions(root.textSizePx)
                value: String(root.textSizePx)
                hasCursor: root.cursorActive && root.selectedRow === "appearance.textSize"
                onHovered: function(isHovered) { if (isHovered) root.focusRow("appearance.textSize") }
                onChanged: function(v) {
                  root.runWrite("appearance.textSize", v)
                  value = Qt.binding(function() { return String(root.textSizePx) })
                }
              }
            }

            // ---- bar ---------------------------------------------------
            SectionHeader { sectionId: "bar" }

            SettingRow {
              rowId: "bar.position"

              ButtonGroup {
                id: barPositionGroup
                focusable: false
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                foreground: root.foreground
                background: root.background
                accent: root.accent
                options: Model.barPositionOptions()
                value: root.barPositionValue
                cursorIndex: root.cursorActive && root.selectedRow === "bar.position" ? root.groupIndex : -1
                onChanged: function(v) { root.setBarPosition(v) }
                onHovered: function(index, isHovered) {
                  if (!isHovered) return
                  root.focusRow("bar.position")
                  root.groupIndex = index
                }
              }
            }

            SettingRow {
              rowId: "bar.transparent"

              ToggleSwitch {
                checked: root.barTransparentValue
                busy: root.busyFor("bar.transparent")
                foreground: root.foreground
                accent: root.accent
                hasCursor: root.cursorActive && root.selectedRow === "bar.transparent"
                onHovered: function(isHovered) { if (isHovered) root.focusRow("bar.transparent") }
                onToggled: {
                  root.focusRow("bar.transparent")
                  root.setBarTransparent(!root.barTransparentValue)
                }
              }
            }

            // ---- display -----------------------------------------------
            SectionHeader { sectionId: "display" }

            SettingRow {
              rowId: "display.scale"
              loaded: root.monitorScaleLoaded

              Dropdown {
                id: monitorScaleDropdown
                width: root.controlWidth
                showLabel: false
                fontFamily: root.fontFamily
                foreground: root.foreground
                background: root.background
                popupBorder: root.borderColor
                accent: root.accent
                options: Model.monitorScaleOptions(root.monitorScale)
                value: root.monitorScale
                hasCursor: root.cursorActive && root.selectedRow === "display.scale"
                onHovered: function(isHovered) { if (isHovered) root.focusRow("display.scale") }
                onChanged: function(v) {
                  root.runWrite("display.scale", v)
                  value = Qt.binding(function() { return root.monitorScale })
                }
              }
            }

          }
        }
      }
    }
  }

  // Controls sit on the right of their row; the label takes what is left.
  readonly property int controlWidth: Math.max(Style.space(150), Math.min(Style.spacing.dropdownWidth, Math.round(panel.cardWidth * 0.45)))

  // ---- row chrome ---------------------------------------------------------
  component SectionHeader: Column {
    id: sectionHeader

    property string sectionId: ""
    readonly property var info: Model.section(sectionId)

    width: parent ? parent.width : 0
    spacing: Style.spacing.labelGap
    topPadding: Style.spacing.md

    PanelSeparator { foreground: root.foreground }

    Item { width: Style.spacing.hairline; height: Style.spacing.xs }

    PanelSectionHeader {
      text: sectionHeader.info ? sectionHeader.info.title : ""
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    Text {
      textFormat: Text.PlainText
      width: sectionHeader.width
      wrapMode: Text.WordWrap
      visible: text !== ""
      text: sectionHeader.info ? String(sectionHeader.info.caption || "") : ""
      color: root.dimForeground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  component SettingRow: Column {
    id: settingRow

    property string rowId: ""
    readonly property var info: Model.row(rowId)
    // A shell-owned value is in memory the moment the panel paints; a
    // system-owned one shows a placeholder until its command answers.
    property bool loaded: true
    readonly property bool hasCursor: root.cursorActive && root.selectedRow === settingRow.rowId
    readonly property string errorText: root.errorFor(settingRow.rowId)

    default property alias controlData: controlHolder.data

    width: parent ? parent.width : 0
    spacing: Style.spacing.xxs

    onHasCursorChanged: if (hasCursor) root.ensureRowVisible(this)

    CursorSurface {
      id: surface
      width: parent.width
      implicitHeight: Math.max(rowLabel.implicitHeight, controlHolder.childrenRect.height, Style.spacing.controlHeight)
        + Style.spacing.controlGap * 2
      height: implicitHeight
      hasCursor: settingRow.hasCursor
      foreground: root.foreground
      accent: root.accent

      HoverHandler {
        onHoveredChanged: if (hovered) root.focusRow(settingRow.rowId)
      }

      Text {
        id: rowLabel
        textFormat: Text.PlainText
        anchors.left: parent.left
        anchors.leftMargin: Style.spacing.rowPaddingX
        anchors.right: controlHolder.left
        anchors.rightMargin: Style.spacing.controlGap
        anchors.verticalCenter: parent.verticalCenter
        text: settingRow.info ? String(settingRow.info.label) : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }

      Item {
        id: controlHolder
        anchors.right: parent.right
        anchors.rightMargin: Style.spacing.rowPaddingX
        anchors.verticalCenter: parent.verticalCenter
        width: childrenRect.width
        height: childrenRect.height
        visible: settingRow.loaded
        enabled: settingRow.loaded
      }

      Text {
        textFormat: Text.PlainText
        anchors.right: parent.right
        anchors.rightMargin: Style.spacing.rowPaddingX
        anchors.verticalCenter: parent.verticalCenter
        visible: !settingRow.loaded
        text: "reading…"
        color: root.dimForeground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      wrapMode: Text.WordWrap
      leftPadding: Style.spacing.rowPaddingX
      visible: text !== ""
      text: settingRow.info && settingRow.info.hint ? String(settingRow.info.hint) : ""
      color: root.dimForeground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      wrapMode: Text.WordWrap
      leftPadding: Style.spacing.rowPaddingX
      visible: settingRow.errorText !== ""
      text: settingRow.errorText
      color: root.urgent
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }
}
