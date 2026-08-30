import QtQuick
import Quickshell.Io
import qs.Ui

BarIndicator {
  id: root

  // Not "state": QQuickItem already has one, and it drives QML's state machine.
  // Redeclaring it shadows the base for QML while the C++ side keeps its own, so
  // the two disagree the moment anything up the chain declares states or
  // transitions. Nothing does today, which is why this was harmless rather than
  // broken.
  property string mode: "idle"
  property string icon: ""

  active: mode === "recording"
  activeText: icon
  inactiveText: "󰍬"
  activeTooltipText: mode
  inactiveTooltipText: "Dictate"

  function update(raw) {
    var data = extractData(raw)

    mode = String(data.alt || data.class || "idle")
    if (mode === "recording") icon = "󰍬"
    else if (mode === "transcribing") icon = "󰔟"
    else icon = ""
  }

  Process {
    command: ["bash", "-c", "omarchy-voxtype-status"]
    running: true
    stdout: SplitParser {
      onRead: function(data) { root.update(data) }
    }
  }

  onPressed: function() {
    if (!root.bar) return
    root.bar.run("omarchy-voxtype-config")
  }
}
