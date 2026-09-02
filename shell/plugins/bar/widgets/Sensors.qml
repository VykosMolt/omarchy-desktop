import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

// Hardware readings that nothing else on the bar reports: whether the discrete
// GPU is awake, which power profile is in force, package temperature and fan
// speed. Laid out like the tray it replaces - anything worth acting on stays
// pinned and visible, the rest lives behind a chevron that slides open.
//
// The power profile is the one reading here that is also a control: a click
// on it cycles to the next profile. Temperature and fan speed are symptoms of
// what the processor is doing, and the system monitor next door is where that
// gets explained, so a click on the chevron or on either of them opens the
// same process panel the CPU/memory readout does. The discrete GPU reading
// is only a reading: nothing on this bar explains a woken GPU, so it answers
// with its tooltip and nothing else.
BarWidget {
  id: root
  moduleName: "omarchy.sensors"

  property bool expanded: false
  property var readings: ({})

  readonly property int pollInterval: Math.max(1000, Number(setting("interval", 5000)))
  readonly property int tempWarning: Number(setting("tempWarning", 85))

  // Match the tray's drawer transition so replacing it changes no motion.
  readonly property int animationDuration: 600
  property real revealProgress: expanded ? 1 : 0

  readonly property var items: buildItems()
  readonly property var pinnedItems: partition(true)
  readonly property var drawerItems: partition(false)

  // Every reading lives behind the chevron. `notable` only colours an item
  // inside the drawer - it never promotes one out of it, so the collapsed
  // widget stays a chevron and nothing appears in the bar unbidden.
  function partition(outside) {
    var all = items
    var out = []
    for (var i = 0; i < all.length; i++) {
      if ((all[i].pinned === true) === outside) out.push(all[i])
    }
    return out
  }

  function profileGlyph(profile) {
    if (profile === "performance") return "󰓅"
    if (profile === "power-saver" || profile === "low-power") return "󰌪"
    return "󰾅"
  }

  function nextProfile(profile) {
    if (profile === "power-saver" || profile === "low-power") return "balanced"
    if (profile === "balanced") return "performance"
    return "power-saver"
  }

  // Reading `readings` here is what binds `items` to each new sample.
  function buildItems() {
    var r = root.readings
    var out = []

    if (r.dgpu !== undefined) {
      var awake = r.dgpu === "active"
      out.push({
        key: "dgpu",
        glyph: "󰢮",
        value: "",
        pinned: false,
        // A woken discrete GPU is the one reading here worth interrupting for:
        // on this machine the integrated GPU draws the desktop, so a second
        // card powering up means something asked for it.
        notable: awake,
        tooltip: awake ? "Discrete GPU awake" : "Discrete GPU " + r.dgpu,
        inert: true
      })
    }

    if (r.profile !== undefined) {
      out.push({
        key: "profile",
        glyph: profileGlyph(r.profile),
        value: "",
        pinned: false,
        notable: r.profile === "performance",
        tooltip: "Power profile: " + r.profile + "\nClick to switch to " + nextProfile(r.profile),
        command: "powerprofilesctl set " + nextProfile(r.profile)
      })
    }

    if (r.cputemp !== undefined) {
      var temp = Number(r.cputemp)
      out.push({
        key: "cputemp",
        glyph: "󰔏",
        value: temp + "°",
        pinned: false,
        notable: temp >= root.tempWarning,
        tooltip: "CPU package " + temp + " °C"
      })
    }

    if (r.fan !== undefined) {
      out.push({
        key: "fan",
        glyph: "󰈐",
        value: "",
        pinned: false,
        notable: false,
        tooltip: r.fan + " rpm"
      })
    }

    return out
  }

  function applySample(text) {
    var next = {}
    var lines = String(text).split("\n")
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      if (line === "") continue
      var tab = line.indexOf("\t")
      if (tab <= 0) continue
      next[line.substring(0, tab)] = line.substring(tab + 1)
    }
    root.readings = next
  }

  function refresh() {
    if (sampleProc.running) return
    sampleProc.running = true
  }

  function openSystemMonitor() {
    if (!root.bar || !root.bar.shell || typeof root.bar.shell.toggle !== "function") return
    root.bar.shell.toggle("omarchy.system-monitor")
  }

  // A reading with a command is a control and runs it; an inert one does
  // nothing; the rest open the panel that explains them.
  function activate(item) {
    if (!item || item.inert === true) return
    if (!item.command) {
      openSystemMonitor()
      return
    }
    if (!root.bar) return
    root.bar.run(item.command)
    // Give the daemon a beat to apply it before re-reading.
    settleTimer.restart()
  }

  visible: items.length > 0
  implicitWidth: root.vertical ? root.barSize : content.implicitWidth
  implicitHeight: root.vertical ? content.implicitHeight : root.barSize

  Behavior on revealProgress {
    NumberAnimation { duration: root.animationDuration; easing.type: Easing.OutCubic }
  }

  Component.onCompleted: refresh()

  Process {
    id: sampleProc
    command: ["omarchy-hw-sensors"]
    stdout: StdioCollector {
      onStreamFinished: root.applySample(text)
    }
  }

  Timer {
    id: pollTimer
    interval: root.pollInterval
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  Timer {
    id: settleTimer
    interval: 400
    onTriggered: root.refresh()
  }

  Loader {
    id: content
    anchors.fill: parent
    sourceComponent: root.vertical ? verticalLayout : horizontalLayout
  }

  Component {
    id: horizontalLayout

    Item {
      id: horizontalRoot

      readonly property int drawerExtent: drawerRow.implicitWidth
      readonly property real revealExtent: drawerExtent * root.revealProgress
      readonly property int drawerBlockWidth: root.drawerItems.length > 0 ? chevron.implicitWidth + drawerExtent : 0

      implicitWidth: drawerBlockWidth + pinnedRow.implicitWidth
      implicitHeight: root.barSize

      // The collapsed drawer reserves the width its contents will slide into.
      // Without a mask that empty strip would catch hover and clicks meant for
      // the widget next door.
      containmentMask: QtObject {
        function contains(point: point): bool {
          if (point.y < 0 || point.y > horizontalRoot.height) return false
          var chevronX = horizontalRoot.drawerExtent - horizontalRoot.revealExtent
          if (point.x >= chevronX && point.x <= horizontalRoot.drawerBlockWidth) return true
          return point.x >= horizontalRoot.drawerBlockWidth && point.x <= horizontalRoot.implicitWidth
        }
      }

      Item {
        id: drawerArea
        x: 0
        width: horizontalRoot.drawerBlockWidth
        height: root.barSize
        visible: root.drawerItems.length > 0

        HoverHandler {
          onHoveredChanged: root.expanded = hovered
        }

        BarIconButton {
          id: chevron
          bar: root.bar
          width: implicitWidth
          height: implicitHeight
          x: horizontalRoot.drawerExtent - horizontalRoot.revealExtent
          text: ""
          tooltipText: "Hardware"
          onPressed: function(button) {
            if (button === Qt.LeftButton) root.openSystemMonitor()
          }
        }

        Item {
          x: chevron.width
          anchors.verticalCenter: parent.verticalCenter
          width: horizontalRoot.drawerExtent
          height: root.barSize
          clip: true

          Row {
            id: drawerRow
            x: horizontalRoot.drawerExtent - horizontalRoot.revealExtent
            anchors.verticalCenter: parent.verticalCenter
            spacing: 0
            layer.enabled: true

            Repeater {
              model: root.drawerItems
              SensorItem { required property var modelData; item: modelData }
            }
          }
        }
      }

      Row {
        id: pinnedRow
        x: horizontalRoot.drawerBlockWidth
        anchors.verticalCenter: parent.verticalCenter
        spacing: 0

        Repeater {
          model: root.pinnedItems
          SensorItem { required property var modelData; item: modelData }
        }
      }
    }
  }

  Component {
    id: verticalLayout

    Column {
      spacing: 0

      Repeater {
        model: root.items
        SensorItem {
          required property var modelData
          item: modelData
          // A vertical bar has no room for a value beside the glyph.
          showValue: false
        }
      }
    }
  }

  component SensorItem: WidgetButton {
    id: sensorItem

    property var item: null
    property bool showValue: !root.vertical

    bar: root.bar
    text: item ? (showValue && item.value !== "" ? item.glyph + " " + item.value : item.glyph) : ""
    labelVisible: true
    fontSize: Style.bar.iconFont
    active: item ? item.notable === true : false
    tooltipText: item ? item.tooltip : ""
    pressable: item ? item.inert !== true : false
    onPressed: function(button) {
      if (button === Qt.LeftButton) root.activate(sensorItem.item)
    }
  }
}
