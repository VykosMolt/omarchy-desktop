import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

// The shared gauge-cluster overlay (SpeedTestOverlay) dressed for the
// internet speed test: download and upload dials in Mbps, titled with the
// connection under test.
//
// Standalone panel plugin: summoning it starts a fresh run, dismissing it
// stops the traffic, so the download workers never keep saturating the link
// behind a closed overlay. The payload may carry the connection's display
// name -- {"connection": "MyWifi"} -- and the panel looks it up itself via
// omarchy-network-status when the caller doesn't know it.
Item {
  id: root

  property var shell: null
  property var manifest: null

  property bool opened: false
  property string connectionName: ""

  property bool running: false
  property bool expectedStop: false
  property int requestSerial: 0
  property string pendingPhase: ""
  property bool lookupConnection: false
  property bool statusQueued: false
  property string phase: ""        // "down" | "up" | ""
  property string stderrText: ""
  property string downloadMbps: ""
  property string uploadMbps: ""
  property string error: ""

  readonly property real downloadValue: toMbps(downloadMbps)
  readonly property real uploadValue: toMbps(uploadMbps)

  function toMbps(raw) {
    var value = parseFloat(raw)
    return isFinite(value) && value > 0 ? value : 0
  }

  function open(payloadJson) {
    var payload = {}
    try { payload = JSON.parse(payloadJson || "{}") || {} } catch (e) {}
    root.lookupConnection = payload.connection === undefined
    if (!root.lookupConnection) root.connectionName = String(payload.connection)
    root.opened = true
    runSpeedTest()
  }

  function close() {
    root.requestSerial++
    root.opened = false
    root.pendingPhase = ""
    root.statusQueued = false
    phaseTimer.stop()
    // Clear the phase before killing the process: onExited advances to the
    // upload phase when it still reads "down".
    root.phase = ""
    root.running = false
    if (speedTestProc.running) {
      root.expectedStop = true
      speedTestProc.running = false
    }
  }

  function dismiss() {
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "omarchy.speedtest")
    else close()
  }

  function refreshConnectionName() {
    root.connectionName = ""
    root.statusQueued = true
    root.pumpStatus()
  }

  function pumpStatus() {
    if (!root.opened || !root.lookupConnection || !root.statusQueued || statusProc.running || statusProc.pendingResult) return
    root.statusQueued = false
    statusProc.startConfirmed = false
    statusProc.serial = root.requestSerial
    statusProc.pendingResult = true
    statusProc.resultExited = false
    statusProc.outDone = false
    statusProc.output = ""
    statusProc.running = true
  }

  function finishStatus() {
    if (!statusProc.pendingResult || !statusProc.resultExited || !statusProc.outDone) return
    statusProc.pendingResult = false
    if (root.opened && root.lookupConnection && statusProc.serial === root.requestSerial && statusProc.code === 0) {
      var fields = statusProc.output.trim().split("\t")
      if (fields[0] === "wifi") root.connectionName = fields[1] || "Wi-Fi"
      else if (fields[0] === "ethernet") root.connectionName = "Ethernet"
    }
    Qt.callLater(root.pumpStatus)
  }

  function updateSpeedTestLine(line) {
    if (!root.opened || speedTestProc.serial !== root.requestSerial) return
    var value = parseFloat(line)
    if (!isFinite(value) || value < 0) return
    if (phase === "down") downloadMbps = String(value)
    else if (phase === "up") uploadMbps = String(value)
  }

  function updateSpeedTestOutput(text) {
    var end = String(text).lastIndexOf("\n")
    if (end < 0) return
    var lines = String(text).slice(0, end).split("\n")
    root.updateSpeedTestLine(lines[lines.length - 1])
  }

  function runSpeedTest() {
    if (!root.opened) return
    root.requestSerial++
    error = ""
    downloadMbps = ""
    uploadMbps = ""
    running = true
    phase = ""
    pendingPhase = "down"
    phaseTimer.stop()
    if (speedTestProc.running) {
      expectedStop = true
      speedTestProc.running = false
    }
    if (root.lookupConnection) root.refreshConnectionName()
    root.pumpPhase()
  }

  function pumpPhase() {
    if (!root.opened || root.pendingPhase === "" || speedTestProc.running || speedTestProc.pendingResult) return
    var nextPhase = root.pendingPhase
    root.pendingPhase = ""
    root.startPhase(nextPhase)
  }

  function startPhase(nextPhase) {
    expectedStop = false
    phase = nextPhase
    stderrText = ""
    speedTestProc.startConfirmed = false
    speedTestProc.serial = root.requestSerial
    speedTestProc.pendingResult = true
    speedTestProc.resultExited = false
    speedTestProc.outDone = false
    speedTestProc.errDone = false
    speedTestProc.command = ["omarchy-network-speedtest", nextPhase]
    speedTestProc.running = true
    phaseTimer.restart()
  }

  function stopPhase() {
    phaseTimer.stop()
    if (speedTestProc.pendingResult) {
      expectedStop = true
      if (speedTestProc.running) speedTestProc.running = false
      return
    }
    finishPhase()
  }

  function finishPhase() {
    if (!root.opened) return
    if (phase === "down") root.pendingPhase = "up"
    else {
      phase = ""
      running = false
      expectedStop = false
    }
    Qt.callLater(root.pumpPhase)
  }

  function settleSpeedTest() {
    if (!speedTestProc.pendingResult || !speedTestProc.resultExited || !speedTestProc.outDone || !speedTestProc.errDone) return
    speedTestProc.pendingResult = false
    if (root.opened && speedTestProc.serial === root.requestSerial) {
      if (!root.expectedStop && speedTestProc.code !== 0) {
        root.error = root.stderrText || "Speed test failed"
        root.phase = ""
        root.running = false
      } else root.finishPhase()
    }
    Qt.callLater(root.pumpPhase)
  }

  Process {
    id: speedTestProc
    property bool startConfirmed: false
    onStarted: startConfirmed = true
    property int serial: -1
    property bool pendingResult: false
    property bool resultExited: false
    property bool outDone: false
    property bool errDone: false
    property int code: 0
    stdout: StdioCollector {
      waitForEnd: false
      onDataChanged: root.updateSpeedTestOutput(text)
      onStreamFinished: {
        root.updateSpeedTestOutput(text)
        speedTestProc.outDone = true
        root.settleSpeedTest()
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (speedTestProc.serial === root.requestSerial) root.stderrText = String(text || "").trim()
        speedTestProc.errDone = true
        root.settleSpeedTest()
      }
    }
    onExited: function(exitCode) {
      phaseTimer.stop()
      speedTestProc.code = exitCode
      speedTestProc.resultExited = true
      root.settleSpeedTest()
    }
    onRunningChanged: if (!running) Qt.callLater(function() {
      if (speedTestProc.pendingResult && !speedTestProc.startConfirmed && !speedTestProc.running) {
        speedTestProc.code = 127
        speedTestProc.outDone = true
        speedTestProc.resultExited = true
        speedTestProc.errDone = true
        phaseTimer.stop()
        root.settleSpeedTest()
      }
      root.pumpPhase()
    })
  }

  Timer {
    id: phaseTimer
    interval: 5000
    repeat: false
    onTriggered: root.stopPhase()
  }

  // Names the connection under test when the summoner didn't. First tab
  // field is the kind, second the SSID (wifi) or device (ethernet).
  Process {
    id: statusProc
    property bool startConfirmed: false
    onStarted: startConfirmed = true
    property int serial: -1
    property bool pendingResult: false
    property bool resultExited: false
    property bool outDone: false
    property int code: 0
    property string output: ""
    command: ["omarchy-network-status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { statusProc.output = text; statusProc.outDone = true; root.finishStatus() }
    }
    onExited: function(exitCode) {
      statusProc.code = exitCode
      statusProc.resultExited = true
      root.finishStatus()
    }
    onRunningChanged: if (!running) Qt.callLater(function() {
      if (statusProc.pendingResult && !statusProc.startConfirmed && !statusProc.running) {
        statusProc.code = 127
        statusProc.outDone = true
        statusProc.resultExited = true
        root.finishStatus()
      }
      root.pumpStatus()
    })
  }

  SpeedTestOverlay {
    fontFamily: Style.font.family
    layerNamespace: "omarchy-network-speedtest"
    title: root.connectionName
    leftLabel: "DOWNLOAD"
    rightLabel: "UPLOAD"
    runAgainTooltip: "Measure again via fast.com"
    running: root.running
    leftValue: root.downloadValue
    rightValue: root.uploadValue
    leftLive: root.running && root.phase === "down"
    rightLive: root.running && root.phase === "up"
    error: root.error
    open: root.opened
    onCloseRequested: root.dismiss()
    onRunAgainRequested: root.runSpeedTest()
  }
}
