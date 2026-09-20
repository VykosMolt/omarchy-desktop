import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The desktop's settings panel: every knob this session can actually drive,
// grouped into categories down the left and reachable with
//   omarchy-shell shell toggle omarchy.settings
// or SUPER + S.
//
// Standalone panel plugin, so the shell's panel loader owns the lifecycle and
// calls open()/close() -- there is no bar button and no IpcHandler of its own,
// the way every other kind: "panel" plugin here works. PanelController still
// holds the open state so the panel matches the kit's panels, and
// PanelKeyCatcher provides the same j/k/h/l/Enter/Esc navigation the bar
// panels use, with Tab walking the categories.
//
// Nothing here is hand-wired to a particular setting. Model.js names the rows,
// which control each one draws, and which command backs it; this file renders
// whatever it finds and runs whatever it is handed, so a new setting is a
// Model.js entry and nothing else.
//
// Every read is a Process, so the panel paints immediately and each value
// arrives when its command answers; only the category on screen is read, so
// opening the panel never waits on the commands behind the other ten. Every
// write is followed by a re-read, or lands in shell.json and comes back through
// shellConfig, so what the panel shows is what actually took -- and a command
// that fails puts its own message on the row instead of being swallowed.
Item {
  id: root

  // ---- host injections ----------------------------------------------------
  property var shell: null
  property var manifest: null

  readonly property string pluginId: manifest && manifest.id ? String(manifest.id) : "omarchy.settings"

  // ---- lifecycle ----------------------------------------------------------
  PanelController { id: panelController }

  readonly property bool opened: panelController.open

  function open(payloadJson) {
    panelController.show()
    root.cursorActive = false
    root.selectSection(Model.sectionIds()[0])
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

  // ---- values -------------------------------------------------------------
  // A shell-owned row reads straight off the live config, so an edit made
  // anywhere else -- omarchy-bar, a hand-edited shell.json -- shows up here
  // without the panel polling for it. A system-owned row carries what its
  // command last answered.
  readonly property var shellConfig: root.shell && root.shell.shellConfig ? root.shell.shellConfig : ({})
  property var values: ({})
  property var optionLists: ({})

  function valueOf(rowId) {
    if (Model.ownerOf(rowId) === "shell") return Model.shellValue(rowId, root.shellConfig)
    var stored = root.values[String(rowId)]
    return stored === undefined ? "" : String(stored)
  }

  function switchedOn(rowId) {
    return root.valueOf(rowId) === "true"
  }

  // Shell-owned values are in memory the moment the panel paints, and a button
  // has nothing to read; everything else shows a placeholder until its command
  // answers, which is exactly when it first has an entry here. A legitimately
  // empty answer -- an unset Hyprland option -- still counts as one.
  function isLoaded(rowId) {
    if (Model.ownerOf(rowId) === "shell") return true
    if (Model.kindOf(rowId) === "action") return true
    return root.values[String(rowId)] !== undefined
  }

  function optionsOf(rowId) {
    var stored = root.optionLists[String(rowId)]
    return Model.displayOptions(rowId, root.valueOf(rowId), stored === undefined ? [] : stored)
  }

  function storeValue(rowId, value) {
    var next = ({})
    for (var k in root.values) next[k] = root.values[k]
    next[String(rowId)] = String(value)
    root.values = next
  }

  function storeOptions(rowId, options) {
    var next = ({})
    for (var k in root.optionLists) next[k] = root.optionLists[k]
    next[String(rowId)] = options
    root.optionLists = next
  }

  // ---- failures -----------------------------------------------------------
  // rowId -> message. A row shows whatever its read, its option list, or its
  // write last failed with.
  property var errors: ({})

  function errorFor(rowId) {
    var key = String(rowId)
    return String(root.errors[key + ".write"] || root.errors[key] || root.errors[key + ".options"] || "")
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
  // One highlight, walking the rows of the category on screen. Mouse hover and
  // the keyboard both move this same state, so the two never disagree. Tab
  // moves between categories, which is why j/k can stay inside one pane.
  property string currentSection: Model.sectionIds()[0]
  property string selectedRow: Model.firstRowIn(Model.sectionIds()[0])
  property bool cursorActive: false

  // The row under the cursor registers itself, so activating or stepping a
  // value never has to search the delegates for the control it means.
  property var activeRow: null

  // A dropdown's popup is its own surface; while one is open it owns the
  // keyboard, and the panel's own j/k has to stand down or it would drive both.
  property int openPopups: 0
  readonly property bool popupBlocking: root.openPopups > 0

  onPopupBlockingChanged: {
    if (popupBlocking || !opened) return
    Qt.callLater(function() {
      if (root.opened && !root.popupBlocking && keyCatcher) keyCatcher.forceActiveFocus()
    })
  }

  function selectSection(sectionId) {
    root.currentSection = String(sectionId)
    root.selectedRow = Model.firstRowIn(root.currentSection)
    root.activeRow = null
    root.refreshSection(root.currentSection)
  }

  function moveSection(delta) {
    var index = Model.sectionIndex(root.currentSection)
    if (index < 0) index = 0
    root.selectSection(Model.sectionIds()[Model.moveSection(index, delta)])
  }

  function focusRow(rowId) {
    root.cursorActive = true
    root.selectedRow = String(rowId)
  }

  function moveCursor(delta) {
    var index = Model.rowIndex(root.selectedRow)
    if (index < 0) index = 0
    var ids = Model.rowIdsInSection(root.currentSection)
    root.selectedRow = ids[Model.moveRow(root.currentSection, index, delta)]
  }

  function activateRow() {
    if (root.activeRow) root.activeRow.activate()
  }

  function stepRow(delta) {
    if (root.activeRow) root.activeRow.step(delta)
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
  // A read already in flight was started before whatever prompted this one, so
  // its answer is stale by definition: queue another rather than settle for it.
  // Asked for by name rather than by position: an Instantiator's own order is
  // its model's, but nothing here should have to know that to find a reader.
  function readerFor(pool, rowId) {
    for (var i = 0; i < pool.count; i++) {
      var reader = pool.objectAt(i)
      if (reader && reader.rowId === String(rowId)) return reader
    }
    return null
  }

  function refreshRow(rowId) {
    var reader = root.readerFor(valueReaders, rowId)
    if (reader) reader.request()
  }

  // Only what is on screen. Reading every category at open would run forty
  // commands -- one of them the keybinding scan, which walks the whole Hyprland
  // config -- to fill rows nobody is looking at.
  function refreshSection(sectionId) {
    var ids = Model.rowIdsInSection(sectionId)
    for (var i = 0; i < ids.length; i++) {
      root.refreshRow(ids[i])
      var options = root.readerFor(optionReaders, ids[i])
      if (options) options.request()
    }
  }

  function finishRead(reader) {
    var key = reader.rowId + (reader.wantsOptions ? ".options" : "")

    if (reader.code !== 0) {
      root.setError(key, Model.commandError(reader.vector, reader.code, reader.errorText))
      return
    }
    root.clearError(key)

    if (reader.wantsOptions) {
      root.storeOptions(reader.rowId, Model.parseTabbedOptions(reader.outputText))
      return
    }

    var parsed = Model.parseValue(reader.rowId, reader.outputText)
    if (!parsed.ok) {
      root.setError(reader.rowId, Model.commandName(reader.vector) + " did not answer with a value")
      return
    }
    root.storeValue(reader.rowId, parsed.value)
  }

  // ---- writing ------------------------------------------------------------
  // The one entry point for changing anything. A shell-owned row written
  // through config goes straight into shell.json and comes back through
  // shellConfig; everything else runs its command and is then re-read.
  function apply(rowId, value) {
    if (Model.writeViaOf(rowId) === "config") {
      root.writeShellConfig(rowId, value)
      return
    }
    // Whatever this one opens needs the keyboard the panel is holding.
    if (Model.opensWindow(rowId)) root.dismiss()
    root.runWrite(rowId, value)
  }

  function writeShellConfig(rowId, value) {
    var found = Model.row(rowId)
    if (!found || !found.configPath) return
    if (!root.shell || typeof root.shell.mutateShellConfig !== "function") {
      root.setError(rowId, "the shell cannot write shell.json right now")
      return
    }
    var stage = found.configPath[found.configPath.length - 1]
    var seconds = Model.secondsFromConfig(value, 0)
    root.clearError(rowId)
    root.shell.mutateShellConfig(function(config) { Model.applyIdleSeconds(config, stage, seconds) })
  }

  // One command at a time, in the order the user asked for them. Several of
  // these restart or re-theme half the desktop; running two at once is how a
  // theme switch and a font switch end up fighting over the same shell.
  property var writeQueue: []
  property string writeRow: ""

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
    writeProcess.pendingResult = true
    writeProcess.startConfirmed = false
    writeProcess.resultExited = false
    writeProcess.errDone = false
    writeProcess.code = 0
    writeProcess.errorText = ""
    writeProcess.command = next.command
    writeProcess.running = true
  }

  function finishWrite() {
    var rowId = root.writeRow
    root.writeRow = ""
    if (writeProcess.code === 0) root.clearError(rowId + ".write")
    else root.setError(rowId + ".write", Model.commandError(writeProcess.command, writeProcess.code, writeProcess.errorText))
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
    property bool wantsOptions: false
    // The vector the model built, kept as the JS array it is. Reading it back
    // off Process.command gives a QML list, which is not a JS array, so a
    // guard that checked that would refuse every command there is.
    property var vector: []
    property bool rerun: false
    property string outputText: ""
    property string errorText: ""
    property int code: 0
    property bool resultExited: false
    property bool pendingResult: false
    property bool startConfirmed: false
    property bool outDone: false
    property bool errDone: false

    command: reader.vector

    function request() {
      if (!Model.isArgumentVector(reader.vector)) return
      reader.rerun = true
      reader.pump()
    }

    function pump() {
      if (!reader.rerun || reader.running || reader.pendingResult) return
      reader.rerun = false
      reader.pendingResult = true
      reader.startConfirmed = false
      reader.outputText = ""
      reader.errorText = ""
      reader.code = 0
      reader.resultExited = false
      reader.outDone = false
      reader.errDone = false
      reader.running = true
    }

    function settle() {
      if (!reader.pendingResult || !reader.resultExited || !reader.outDone || !reader.errDone) return
      reader.pendingResult = false
      if (!reader.rerun) root.finishRead(reader)
      Qt.callLater(reader.pump)
    }

    onStarted: reader.startConfirmed = true
    onRunningChanged: if (!running) Qt.callLater(function() {
      if (reader.pendingResult && !reader.startConfirmed && !reader.running) {
        reader.code = 127
        reader.resultExited = true
        reader.outDone = true
        reader.errDone = true
        reader.settle()
      }
      reader.pump()
    })

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { reader.outputText = text; reader.outDone = true; reader.settle() }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: { reader.errorText = text; reader.errDone = true; reader.settle() }
    }
    onExited: function(exitCode) { reader.code = exitCode; reader.resultExited = true; reader.settle() }
  }

  // One reader per row that has something to read, and one per row that has a
  // list to offer. Built from the inventory rather than declared row by row, so
  // a new setting never needs a process of its own written out here.
  readonly property var valueRowIds: {
    var out = []
    var ids = Model.rowIds()
    for (var i = 0; i < ids.length; i++) {
      if (Model.isArgumentVector(Model.readCommand(ids[i]))) out.push(ids[i])
    }
    return out
  }

  readonly property var optionRowIds: {
    var out = []
    var ids = Model.rowIds()
    for (var i = 0; i < ids.length; i++) {
      if (Model.isArgumentVector(Model.optionsCommand(ids[i]))) out.push(ids[i])
    }
    return out
  }

  Instantiator {
    id: valueReaders
    model: root.valueRowIds
    delegate: Reader {
      required property string modelData
      rowId: modelData
      vector: Model.readCommand(modelData)
    }
  }

  Instantiator {
    id: optionReaders
    model: root.optionRowIds
    delegate: Reader {
      required property string modelData
      rowId: modelData
      wantsOptions: true
      vector: Model.optionsCommand(modelData)
    }
  }

  Process {
    id: writeProcess

    property string errorText: ""
    property int code: 0
    property bool resultExited: false
    property bool pendingResult: false
    property bool startConfirmed: false
    property bool errDone: false

    function settle() {
      if (!writeProcess.pendingResult || !writeProcess.resultExited || !writeProcess.errDone) return
      writeProcess.pendingResult = false
      root.finishWrite()
    }

    onStarted: writeProcess.startConfirmed = true
    onRunningChanged: if (!running) Qt.callLater(function() {
      if (writeProcess.pendingResult && !writeProcess.startConfirmed && !writeProcess.running) {
        writeProcess.code = 127
        writeProcess.resultExited = true
        writeProcess.errDone = true
        writeProcess.settle()
      }
      root.pumpWrites()
    })

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: { writeProcess.errorText = text; writeProcess.errDone = true; writeProcess.settle() }
    }
    onExited: function(exitCode) { writeProcess.code = exitCode; writeProcess.resultExited = true; writeProcess.settle() }
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

    readonly property int cardWidth: Math.min(Style.space(880), panel.width - Style.gapsOut * 2)
    readonly property int cardHeight: Math.min(Style.space(660), panel.height - Style.gapsOut * 2)

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
        blocked: root.popupBlocking

        onMoveRequested: function(dx, dy) {
          if (!root.cursorActive) { root.cursorActive = true; return }
          if (dy !== 0) root.moveCursor(dy)
          else if (dx !== 0) root.stepRow(dx)
        }
        onTabRequested: function(direction) { root.moveSection(direction) }
        onActivateRequested: {
          if (!root.cursorActive) { root.cursorActive = true; return }
          root.activateRow()
        }
        onCloseRequested: root.dismiss()

        Row {
          anchors.fill: parent
          anchors.bottomMargin: hintLine.implicitHeight + Style.spacing.md
          spacing: Style.spacing.panelGap

          // ---- categories --------------------------------------------
          Column {
            id: sidebar
            width: Style.space(190)
            height: parent.height
            spacing: Style.spacing.xxs

            Text {
              textFormat: Text.PlainText
              text: "Settings"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              font.bold: true
              bottomPadding: Style.spacing.md
            }

            Repeater {
              model: Model.sections()

              CategoryButton {
                required property var modelData
                info: modelData
                width: sidebar.width
              }
            }
          }

          Rectangle {
            width: Style.spacing.hairline
            height: parent.height
            color: root.borderColor
            opacity: 0.5
          }

          // ---- the category on screen --------------------------------
          Column {
            id: content
            width: parent.width - sidebar.width - Style.spacing.hairline - Style.spacing.panelGap * 2
            height: parent.height
            spacing: Style.spacing.labelGap

            readonly property var info: Model.section(root.currentSection)

            PanelSectionHeader {
              text: content.info ? String(content.info.title) : ""
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              wrapMode: Text.WordWrap
              visible: text !== ""
              text: content.info ? String(content.info.caption || "") : ""
              color: root.dimForeground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              bottomPadding: Style.spacing.xs
            }

            // A category whose rows do not add up to what will actually
            // happen gets one line saying what will. Only the idle stages
            // need it, and the model is what decides that.
            Text {
              textFormat: Text.PlainText
              width: parent.width
              wrapMode: Text.WordWrap
              visible: text !== ""
              text: Model.sectionSummary(root.currentSection, root.shellConfig, root.values)
              color: root.foreground
              opacity: 0.85
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              bottomPadding: Style.spacing.xs
            }

            ScrollView {
              id: scrollArea
              width: parent.width
              height: parent.height - y
              clip: true
              ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

              Column {
                width: scrollArea.availableWidth
                spacing: Style.spacing.xxs

                Repeater {
                  model: Model.rowsInSection(root.currentSection)

                  SettingRow {
                    required property var modelData
                    info: modelData
                    width: scrollArea.availableWidth
                  }
                }
              }
            }
          }
        }

        Text {
          id: hintLine
          textFormat: Text.PlainText
          anchors.bottom: parent.bottom
          anchors.right: parent.right
          text: "Tab changes category · j/k moves · h/l adjusts · Enter opens · Esc closes"
          color: root.dimForeground
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  // Controls sit on the right of their row; the label takes what is left.
  readonly property int controlWidth: Math.max(Style.space(150), Math.min(Style.spacing.dropdownWidth, Math.round(panel.cardWidth * 0.32)))

  // ---- chrome -------------------------------------------------------------
  component CategoryButton: Button {
    id: categoryButton

    property var info: null
    readonly property string sectionId: info ? String(info.id) : ""

    text: info ? String(info.name) : ""
    leftAlign: true
    elideLabel: true
    fontFamily: root.fontFamily
    fontSize: Style.font.body
    foreground: root.foreground
    background: root.background
    accent: root.accent
    selected: root.currentSection === categoryButton.sectionId
    onClicked: root.selectSection(categoryButton.sectionId)
  }

  component SettingRow: Column {
    id: settingRow

    property var info: null
    readonly property string rowId: info ? String(info.id) : ""
    readonly property string kind: info ? String(info.kind) : ""
    readonly property string value: root.valueOf(settingRow.rowId)
    readonly property bool ready: root.isLoaded(settingRow.rowId)
    readonly property bool hasCursor: root.cursorActive && root.selectedRow === settingRow.rowId
    readonly property string errorText: root.errorFor(settingRow.rowId)
    readonly property var control: controlLoader.item

    spacing: Style.spacing.xxs

    // Enter on this row: open its dropdown, flip its switch, run its command.
    function activate() {
      if (settingRow.control && typeof settingRow.control.activate === "function") settingRow.control.activate()
    }

    // h/l on this row: walk the chips of a group or nudge a slider. A row with
    // nothing to step ignores it rather than moving the cursor somewhere the
    // user did not ask for.
    function step(delta) {
      if (settingRow.control && typeof settingRow.control.step === "function") settingRow.control.step(delta)
    }

    onHasCursorChanged: {
      if (!hasCursor) return
      root.activeRow = settingRow
      root.ensureRowVisible(this)
    }

    CursorSurface {
      id: surface
      width: parent.width
      implicitHeight: Math.max(rowLabel.implicitHeight, controlHolder.childrenRect.height, Style.spacing.controlHeight)
        + Style.spacing.controlGap * 2
      height: implicitHeight
      visible: settingRow.kind !== "list"
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
        visible: settingRow.ready
        enabled: settingRow.ready

        Loader {
          id: controlLoader
          active: settingRow.kind !== "list"
          sourceComponent: {
            switch (settingRow.kind) {
              case "switch": return switchControl
              case "group": return groupControl
              case "slider": return sliderControl
              case "action": return actionControl
              case "search": return searchControl
            }
            return dropdownControl
          }
        }
      }

      Text {
        textFormat: Text.PlainText
        anchors.right: parent.right
        anchors.rightMargin: Style.spacing.rowPaddingX
        anchors.verticalCenter: parent.verticalCenter
        visible: !settingRow.ready
        text: "reading…"
        color: root.dimForeground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
    }

    // A list is the row: a chord and what it does, as many times as the
    // session has bindings. It has no control and nothing to set.
    Loader {
      width: parent.width
      active: settingRow.kind === "list"
      sourceComponent: Column {
        spacing: Style.spacing.xxs

        Repeater {
          model: Model.parseLines(settingRow.value)

          Text {
            required property string modelData
            textFormat: Text.PlainText
            width: settingRow.width
            leftPadding: Style.spacing.rowPaddingX
            text: modelData
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
          }
        }

        Text {
          textFormat: Text.PlainText
          visible: !settingRow.ready
          leftPadding: Style.spacing.rowPaddingX
          text: "reading…"
          color: root.dimForeground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
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

    // ---- controls ------------------------------------------------------
    // One component per kind, each answering activate() and step() so the
    // keyboard never has to know which kind it is driving.
    Component {
      id: switchControl

      ToggleSwitch {
        function activate() { flip() }
        function step(delta) { if ((delta > 0) !== root.switchedOn(settingRow.rowId)) flip() }
        function flip() {
          root.focusRow(settingRow.rowId)
          root.apply(settingRow.rowId, !root.switchedOn(settingRow.rowId))
        }

        checked: root.switchedOn(settingRow.rowId)
        busy: root.busyFor(settingRow.rowId)
        foreground: root.foreground
        accent: root.accent
        hasCursor: settingRow.hasCursor
        onHovered: function(isHovered) { if (isHovered) root.focusRow(settingRow.rowId) }
        onToggled: flip()
      }
    }

    Component {
      id: groupControl

      ButtonGroup {
        id: group

        // The chip the cursor is on, which is not the chosen one until Enter.
        property int cursorAt: Math.max(0, indexOfValue(settingRow.value))

        function indexOfValue(value) {
          for (var i = 0; i < group.options.length; i++) {
            if (String(group.options[i].value) === String(value)) return i
          }
          return -1
        }

        function activate() {
          if (group.cursorAt < 0 || group.cursorAt >= group.options.length) return
          root.apply(settingRow.rowId, group.options[group.cursorAt].value)
        }

        function step(delta) {
          group.cursorAt = Math.max(0, Math.min(group.options.length - 1, group.cursorAt + delta))
        }

        focusable: false
        fontFamily: root.fontFamily
        fontSize: Style.font.bodySmall
        foreground: root.foreground
        background: root.background
        accent: root.accent
        options: root.optionsOf(settingRow.rowId)
        value: settingRow.value
        cursorIndex: settingRow.hasCursor ? group.cursorAt : -1
        onChanged: function(v) { root.apply(settingRow.rowId, v) }
        onHovered: function(index, isHovered) {
          if (!isHovered) return
          root.focusRow(settingRow.rowId)
          group.cursorAt = index
        }
      }
    }

    Component {
      id: sliderControl

      Row {
        id: sliderRow

        function step(delta) {
          var spec = Model.sliderSpec(settingRow.rowId)
          if (!spec) return
          root.focusRow(settingRow.rowId)
          root.apply(settingRow.rowId, Model.sliderValue(settingRow.rowId, Number(settingRow.value) + delta * spec.step))
        }

        readonly property var spec: Model.sliderSpec(settingRow.rowId)

        spacing: Style.spacing.controlGap

        Text {
          textFormat: Text.PlainText
          anchors.verticalCenter: parent.verticalCenter
          horizontalAlignment: Text.AlignRight
          width: Style.space(52)
          text: Model.sliderLabel(settingRow.rowId, settingRow.value)
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        PanelSlider {
          anchors.verticalCenter: parent.verticalCenter
          width: root.controlWidth - Style.space(52) - Style.spacing.controlGap
          bar: root
          minimum: sliderRow.spec ? sliderRow.spec.minimum : 0
          maximum: sliderRow.spec ? sliderRow.spec.maximum : 1
          step: sliderRow.spec ? sliderRow.spec.step : 0.05
          integer: sliderRow.spec ? sliderRow.spec.integer : false
          value: Number(settingRow.value)
          // Only on release: a Hyprland option set on every pixel of a drag
          // would run a command per frame.
          onReleased: function(v) {
            root.focusRow(settingRow.rowId)
            root.apply(settingRow.rowId, Model.sliderValue(settingRow.rowId, v))
          }
        }
      }
    }

    Component {
      id: actionControl

      Button {
        function activate() { run() }
        function run() {
          root.focusRow(settingRow.rowId)
          root.apply(settingRow.rowId, "")
        }

        text: settingRow.info && settingRow.info.actionLabel ? String(settingRow.info.actionLabel) : "Run"
        bordered: true
        focusable: false
        fontFamily: root.fontFamily
        fontSize: Style.font.bodySmall
        foreground: root.foreground
        background: root.background
        accent: root.accent
        hasCursor: settingRow.hasCursor
        onHovered: function(isHovered) { if (isHovered) root.focusRow(settingRow.rowId) }
        onClicked: run()
      }
    }

    Component {
      id: dropdownControl

      Dropdown {
        function activate() { toggle() }

        width: root.controlWidth
        showLabel: false
        fontFamily: root.fontFamily
        foreground: root.foreground
        background: root.background
        popupBorder: root.borderColor
        accent: root.accent
        options: root.optionsOf(settingRow.rowId)
        value: settingRow.value
        hasCursor: settingRow.hasCursor
        onPopupOpenChanged: root.openPopups += popupOpen ? 1 : -1
        onHovered: function(isHovered) { if (isHovered) root.focusRow(settingRow.rowId) }
        onChanged: function(v) {
          root.apply(settingRow.rowId, v)
          // Dropdown assigns its own `value` before it emits, which drops the
          // binding; put it back so the row keeps showing the setting rather
          // than the last thing clicked.
          value = Qt.binding(function() { return settingRow.value })
        }
      }
    }

    Component {
      id: searchControl

      SearchableDropdown {
        function activate() { toggle() }

        width: root.controlWidth
        showLabel: false
        placeholderText: "Search…"
        fontFamily: root.fontFamily
        foreground: root.foreground
        background: root.background
        popupBorder: root.borderColor
        accent: root.accent
        options: root.optionsOf(settingRow.rowId)
        value: settingRow.value
        hasCursor: settingRow.hasCursor
        onPopupOpenChanged: root.openPopups += popupOpen ? 1 : -1
        onHovered: function(isHovered) { if (isHovered) root.focusRow(settingRow.rowId) }
        onChanged: function(v) {
          root.apply(settingRow.rowId, v)
          value = Qt.binding(function() { return settingRow.value })
        }
      }
    }
  }
}
