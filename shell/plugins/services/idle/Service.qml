import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "IdleModel.js" as IdleModel
import qs.Commons

Item {
  id: root

  // Injected by omarchy-shell (the first-party service loader).
  property var shell: null

  readonly property string stayAwakeStateDir: Paths.omarchyState + "/indicators"
  readonly property string stayAwakeStatePath: stayAwakeStateDir + "/stay-awake"
  readonly property int defaultScreenOffSeconds: 0
  readonly property int defaultLockSeconds: 300
  readonly property int defaultSuspendSeconds: 0
  readonly property var idleConfig: shell && shell.shellConfig && shell.shellConfig.idle ? shell.shellConfig.idle : ({})

  // Each stage is seconds of inactivity before it fires, or 0 for never. They
  // are independent rather than nested: a lock at 300 and a screen off at 600
  // is a legitimate choice, and so is a screen off with no lock at all.
  readonly property int screenOffTimeoutSeconds: secondsFromConfig(idleConfig.screenOff, defaultScreenOffSeconds)
  readonly property int lockTimeoutSeconds: secondsFromConfig(idleConfig.lock, defaultLockSeconds)
  readonly property int suspendTimeoutSeconds: secondsFromConfig(idleConfig.suspend, defaultSuspendSeconds)

  // The compositor's idle monitor carries one timeout, so it waits out the
  // earliest enabled stage and the rest run as timers relative to it.
  readonly property var enabledTimeouts: IdleModel.enabledTimeouts([
    root.screenOffTimeoutSeconds, root.lockTimeoutSeconds, root.suspendTimeoutSeconds
  ])
  readonly property int firstIdleTimeoutSeconds: enabledTimeouts.length > 0 ? enabledTimeouts[0] : 0
  readonly property bool idleEnabled: stayAwakeStateLoaded && !stayAwake && firstIdleTimeoutSeconds > 0

  property bool stayAwake: false
  property bool stayAwakeStateLoaded: false
  property bool hasPendingStayAwakePersist: false
  property bool pendingStayAwakePersist: false
  property bool idledThisCycle: false
  property bool screenOffThisCycle: false
  property bool lockedThisCycle: false
  property bool suspendedThisCycle: false
  property real idleStartedAt: 0
  property bool displayDesiredOff: false
  property bool displayOff: false
  property bool displayPowerActive: false
  property bool stayAwakeWriteActive: false
  property int stayAwakeGeneration: 0
  property bool stayAwakeProbeQueued: false
  property string lastEvent: "starting"
  property string lastEventAt: ""

  function secondsFromConfig(value, fallback) {
    return IdleModel.secondsFromConfig(value, fallback)
  }

  function nowIso() {
    return new Date().toISOString()
  }

  function logEvent(event, details) {
    var suffix = details === undefined || details === null || details === "" ? "" : ": " + String(details)
    root.lastEventAt = nowIso()
    root.lastEvent = event + suffix
    console.log("omarchy idle " + root.lastEventAt + " " + root.lastEvent)
  }

  function runProcess(process, label, command) {
    if (process.running) {
      logEvent("process-skip", label + " already running")
      return false
    }
    logEvent("process-start", label + " " + command.join(" "))
    if (process === screenOffProcess || process === wakeProcess) process.startConfirmed = false
    process.command = command
    process.running = true
    return true
  }

  function screenOff(reason) {
    logEvent("screen-off", reason || "requested")
    root.screenOffThisCycle = true
    root.displayDesiredOff = true
    root.pumpDisplayPower()
  }

  function pumpDisplayPower() {
    if (root.displayPowerActive || screenOffProcess.running || wakeProcess.running) return
    if (root.displayDesiredOff === root.displayOff) return
    var off = root.displayDesiredOff
    var started = off
      ? runProcess(screenOffProcess, "screen-off", ["omarchy-brightness-display", "off"])
      : runProcess(wakeProcess, "wake", ["omarchy-system-wake"])
    if (started) {
      root.displayPowerActive = true
      root.displayOff = off
    }
  }

  function lockSystem(reason) {
    if (root.lockedThisCycle) return
    root.lockedThisCycle = true
    logEvent("lock-system", reason || "requested")
    runProcess(lockProcess, "lock", ["omarchy-system-lock"])
  }

  function suspendSystem(reason) {
    if (root.suspendedThisCycle) return
    root.suspendedThisCycle = true
    logEvent("suspend-system", reason || "requested")
    runProcess(suspendProcess, "suspend", ["systemctl", "suspend"])
  }

  // A stage whose timeout equals the one the idle monitor already waited out
  // fires now; the rest wait the difference.
  function scheduleStage(timer, timeoutSeconds, fire, reason) {
    if (timeoutSeconds <= 0) return

    var elapsed = root.idleStartedAt > 0 ? (Date.now() - root.idleStartedAt) / 1000 : root.firstIdleTimeoutSeconds
    var delay = timeoutSeconds - elapsed
    if (delay <= 0) fire(reason + "-immediate")
    else {
      timer.interval = Math.ceil(delay * 1000)
      timer.restart()
    }
  }

  function startIdleCycle() {
    if (root.idledThisCycle) {
      logEvent("idle-cycle-already-running")
      return
    }

    logEvent("idle-cycle-start", "screenOff=" + root.screenOffTimeoutSeconds
      + " lock=" + root.lockTimeoutSeconds + " suspend=" + root.suspendTimeoutSeconds)
    root.idledThisCycle = true
    root.screenOffThisCycle = false
    root.lockedThisCycle = false
    root.suspendedThisCycle = false
    root.idleStartedAt = Date.now() - root.firstIdleTimeoutSeconds * 1000

    scheduleStage(screenOffTimer, root.screenOffTimeoutSeconds, root.screenOff, "screen-off-timeout")
    scheduleStage(lockTimer, root.lockTimeoutSeconds, root.lockSystem, "lock-timeout")
    scheduleStage(suspendTimer, root.suspendTimeoutSeconds, root.suspendSystem, "suspend-timeout")
  }

  function cancelIdleCycle(reason) {
    logEvent("idle-cycle-cancel", reason || "requested")

    screenOffTimer.stop()
    lockTimer.stop()
    suspendTimer.stop()

    // Waking restores the display and the keyboard backlight, so it is only
    // worth running when this cycle actually turned something off.
    if (root.idledThisCycle && root.screenOffThisCycle) {
      root.displayDesiredOff = false
      root.pumpDisplayPower()
    }

    root.idledThisCycle = false
    root.screenOffThisCycle = false
    root.idleStartedAt = 0
  }

  function reconfigureStages() {
    if (!root.idledThisCycle) return
    screenOffTimer.stop()
    lockTimer.stop()
    suspendTimer.stop()
    if (!root.idleEnabled) { root.cancelIdleCycle("configuration"); return }
    if (!root.screenOffThisCycle) scheduleStage(screenOffTimer, root.screenOffTimeoutSeconds, root.screenOff, "screen-off-timeout")
    if (!root.lockedThisCycle) scheduleStage(lockTimer, root.lockTimeoutSeconds, root.lockSystem, "lock-timeout")
    if (!root.suspendedThisCycle) scheduleStage(suspendTimer, root.suspendTimeoutSeconds, root.suspendSystem, "suspend-timeout")
  }

  onIdleConfigChanged: Qt.callLater(root.reconfigureStages)
  onIdleEnabledChanged: if (!idleEnabled && idledThisCycle) root.cancelIdleCycle("disabled")

  function handleActiveSignal() {
    if (!root.idledThisCycle) return
    cancelIdleCycle("activity")
  }

  function handleIdleChanged() {
    logEvent("idle-monitor", idleMonitor.isIdle ? "idle" : "active")
    if (!root.idleEnabled) return

    if (idleMonitor.isIdle) startIdleCycle()
    else handleActiveSignal()
  }

  function statusJson() {
    return JSON.stringify({
      enabled: root.idleEnabled,
      stayAwake: root.stayAwake,
      stayAwakeStateLoaded: root.stayAwakeStateLoaded,
      stayAwakeStatePath: root.stayAwakeStatePath,
      idle: idleMonitor.isIdle,
      inIdleCycle: root.idledThisCycle,
      screenOffThisCycle: root.screenOffThisCycle,
      screenOff: root.screenOffTimeoutSeconds,
      lock: root.lockTimeoutSeconds,
      suspend: root.suspendTimeoutSeconds,
      firstTimeout: root.firstIdleTimeoutSeconds,
      timers: {
        screenOff: screenOffTimer.running,
        lock: lockTimer.running,
        suspend: suspendTimer.running
      },
      processes: {
        screenOff: screenOffProcess.running,
        lock: lockProcess.running,
        suspend: suspendProcess.running,
        wake: wakeProcess.running
      },
      lastEvent: root.lastEvent,
      lastEventAt: root.lastEventAt
    })
  }

  function persistStayAwake(value) {
    root.stayAwakeGeneration++
    root.pendingStayAwakePersist = !!value
    root.hasPendingStayAwakePersist = true
    root.pumpStayAwakeWrites()
  }

  function pumpStayAwakeWrites() {
    if (root.stayAwakeWriteActive || stayAwakeStateWriter.running || !root.hasPendingStayAwakePersist) return
    var enabled = root.pendingStayAwakePersist
    root.hasPendingStayAwakePersist = false
    root.stayAwakeWriteActive = true
    stayAwakeStateWriter.startConfirmed = false
    stayAwakeStateWriter.command = ["bash", "-c", enabled
      ? 'mkdir -p -- "$1" && touch -- "$2"' : 'rm -f -- "$2"',
      "omarchy-idle-state", root.stayAwakeStateDir, root.stayAwakeStatePath]
    stayAwakeStateWriter.running = true
  }

  function refreshStayAwakeState() {
    root.stayAwakeProbeQueued = true
    root.pumpStayAwakeProbe()
  }

  function pumpStayAwakeProbe() {
    if (!root.stayAwakeProbeQueued || root.stayAwakeWriteActive || root.hasPendingStayAwakePersist
        || stayAwakeStateProbe.running || stayAwakeStateProbe.pendingResult) return
    root.stayAwakeProbeQueued = false
    stayAwakeStateProbe.startConfirmed = false
    stayAwakeStateProbe.serial = root.stayAwakeGeneration
    stayAwakeStateProbe.pendingResult = true
    stayAwakeStateProbe.outDone = false
    stayAwakeStateProbe.resultExited = false
    stayAwakeStateProbe.output = ""
    stayAwakeStateProbe.running = true
  }

  function finishStayAwakeProbe() {
    if (!stayAwakeStateProbe.pendingResult || !stayAwakeStateProbe.outDone || !stayAwakeStateProbe.resultExited) return
    stayAwakeStateProbe.pendingResult = false
    if (stayAwakeStateProbe.serial === root.stayAwakeGeneration && !root.stayAwakeWriteActive && !root.hasPendingStayAwakePersist
        && stayAwakeStateProbe.code === 0)
      root.applyStayAwake(stayAwakeStateProbe.output.trim() === "yes", false, "state-file")
    stayAwakeStateDirWatcher.reload()
    Qt.callLater(root.pumpStayAwakeProbe)
  }

  function applyStayAwake(value, persist, reason) {
    var enabled = !!value
    var changed = !root.stayAwakeStateLoaded || root.stayAwake !== enabled

    if (persist) persistStayAwake(enabled)

    root.stayAwake = enabled
    root.stayAwakeStateLoaded = true

    if (!changed) return enabled ? "disabled" : "enabled"

    logEvent("stay-awake", (enabled ? "enabled" : "disabled") + (reason ? " " + reason : ""))
    if (enabled) cancelIdleCycle("stay-awake")
    else Qt.callLater(root.handleIdleChanged)

    return enabled ? "disabled" : "enabled"
  }

  function setIdleEnabled(value) {
    return applyStayAwake(!value, true, "ipc")
  }

  IdleMonitor {
    id: idleMonitor
    enabled: root.idleEnabled
    timeout: root.firstIdleTimeoutSeconds
    respectInhibitors: true
    onIsIdleChanged: root.handleIdleChanged()
  }

  Timer {
    id: screenOffTimer
    repeat: false
    onTriggered: if (root.idleEnabled && root.idledThisCycle) root.screenOff("screen-off-timeout")
  }

  Timer {
    id: lockTimer
    repeat: false
    onTriggered: if (root.idleEnabled && root.idledThisCycle) root.lockSystem("lock-timeout")
  }

  Timer {
    id: suspendTimer
    repeat: false
    onTriggered: if (root.idleEnabled && root.idledThisCycle) root.suspendSystem("suspend-timeout")
  }

  Process {
    id: screenOffProcess
    property bool startConfirmed: false
    onStarted: startConfirmed = true
    onExited: function(exitCode, exitStatus) {
      root.logEvent("process-exit", "screen-off exitCode=" + exitCode + " status=" + exitStatus)
      root.displayPowerActive = false
      Qt.callLater(root.pumpDisplayPower)
    }
    onRunningChanged: if (!running) Qt.callLater(function() {
      if (!screenOffProcess.startConfirmed && !screenOffProcess.running) root.displayPowerActive = false
      root.pumpDisplayPower()
    })
  }

  Process {
    id: suspendProcess
    onExited: function(exitCode, exitStatus) { root.logEvent("process-exit", "suspend exitCode=" + exitCode + " status=" + exitStatus) }
  }

  Process {
    id: lockProcess
    onExited: function(exitCode, exitStatus) { root.logEvent("process-exit", "lock exitCode=" + exitCode + " status=" + exitStatus) }
  }
  Process {
    id: wakeProcess
    property bool startConfirmed: false
    onStarted: startConfirmed = true
    onExited: function(exitCode, exitStatus) {
      root.logEvent("process-exit", "wake exitCode=" + exitCode + " status=" + exitStatus)
      root.displayPowerActive = false
      Qt.callLater(root.pumpDisplayPower)
    }
    onRunningChanged: if (!running) Qt.callLater(function() {
      if (!wakeProcess.startConfirmed && !wakeProcess.running) root.displayPowerActive = false
      root.pumpDisplayPower()
    })
  }

  Process {
    id: stayAwakeStateProbe
    property bool startConfirmed: false
    onStarted: startConfirmed = true
    property int serial: -1
    property bool pendingResult: false
    property bool outDone: false
    property bool resultExited: false
    property string output: ""
    property int code: 0
    command: ["bash", "-c", 'mkdir -p -- "$1" && { if [[ -f "$2" ]]; then echo yes; else echo no; fi; }',
      "omarchy-idle-state", root.stayAwakeStateDir, root.stayAwakeStatePath]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        stayAwakeStateProbe.output = text
        stayAwakeStateProbe.outDone = true
        root.finishStayAwakeProbe()
      }
    }
    onExited: function(exitCode) {
      stayAwakeStateProbe.code = exitCode
      stayAwakeStateProbe.resultExited = true
      root.finishStayAwakeProbe()
    }
    onRunningChanged: if (!running) Qt.callLater(function() {
      if (stayAwakeStateProbe.pendingResult && !stayAwakeStateProbe.startConfirmed && !stayAwakeStateProbe.running) {
        stayAwakeStateProbe.code = 127
        stayAwakeStateProbe.resultExited = true
        stayAwakeStateProbe.outDone = true
        root.finishStayAwakeProbe()
      }
      root.pumpStayAwakeProbe()
    })
  }

  Process {
    id: stayAwakeStateWriter
    property bool startConfirmed: false
    onStarted: startConfirmed = true
    onExited: function() {
      root.stayAwakeWriteActive = false
      root.refreshStayAwakeState()
      Qt.callLater(root.pumpStayAwakeWrites)
    }
    onRunningChanged: if (!running) Qt.callLater(function() {
      if (!stayAwakeStateWriter.startConfirmed && !stayAwakeStateWriter.running) {
        root.stayAwakeWriteActive = false
        root.refreshStayAwakeState()
      }
      root.pumpStayAwakeWrites()
    })
  }

  FileView {
    id: stayAwakeStateDirWatcher
    path: root.stayAwakeStateDir
    watchChanges: true
    printErrors: false
    onFileChanged: root.refreshStayAwakeState()
  }

  Component.onCompleted: {
    logEvent("service-ready")
    refreshStayAwakeState()
  }

  IpcHandler {
    target: "idle"

    function status(): string {
      return root.statusJson()
    }

    function debug(): string {
      return root.statusJson()
    }

    function enable(): string {
      return root.setIdleEnabled(true)
    }

    function disable(): string {
      return root.setIdleEnabled(false)
    }

    function toggle(): string {
      return root.setIdleEnabled(!root.idleEnabled)
    }
  }
}
