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

  readonly property string home: Quickshell.env("HOME")
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
    logEvent("process-start", label + " " + command)
    process.command = ["bash", "-lc", command]
    process.running = true
    return true
  }

  function screenOff(reason) {
    logEvent("screen-off", reason || "requested")
    root.screenOffThisCycle = true
    runProcess(screenOffProcess, "screen-off", "omarchy-brightness-display off")
  }

  function lockSystem(reason) {
    logEvent("lock-system", reason || "requested")
    runProcess(lockProcess, "lock", "omarchy-system-lock")
  }

  function suspendSystem(reason) {
    logEvent("suspend-system", reason || "requested")
    runProcess(suspendProcess, "suspend", "systemctl suspend")
  }

  // A stage whose timeout equals the one the idle monitor already waited out
  // fires now; the rest wait the difference.
  function scheduleStage(timer, timeoutSeconds, fire, reason) {
    if (timeoutSeconds <= 0) return

    var delay = timeoutSeconds - root.firstIdleTimeoutSeconds
    if (delay <= 0) fire(reason + "-immediate")
    else {
      timer.interval = delay * 1000
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
      runProcess(wakeProcess, "wake", "omarchy-system-wake")
    }

    root.idledThisCycle = false
    root.screenOffThisCycle = false
  }

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
    var command = value
      ? "STATE=\"${OMARCHY_STATE_HOME:-${XDG_STATE_HOME:-$HOME/.local/state}/omarchy}\"; mkdir -p \"$STATE/indicators\" && touch \"$STATE/indicators/stay-awake\""
      : "STATE=\"${OMARCHY_STATE_HOME:-${XDG_STATE_HOME:-$HOME/.local/state}/omarchy}\"; rm -f \"$STATE/indicators/stay-awake\""

    if (stayAwakeStateWriter.running) {
      root.pendingStayAwakePersist = !!value
      root.hasPendingStayAwakePersist = true
      return
    }

    stayAwakeStateWriter.command = ["bash", "-lc", command]
    stayAwakeStateWriter.running = true
  }

  function refreshStayAwakeState() {
    if (!stayAwakeStateProbe.running) stayAwakeStateProbe.running = true
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
    onExited: function(exitCode, exitStatus) { root.logEvent("process-exit", "screen-off exitCode=" + exitCode + " status=" + exitStatus) }
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
    onExited: function(exitCode, exitStatus) { root.logEvent("process-exit", "wake exitCode=" + exitCode + " status=" + exitStatus) }
  }

  Process {
    id: stayAwakeStateProbe
    command: ["bash", "-c", "STATE=\"${OMARCHY_STATE_HOME:-${XDG_STATE_HOME:-$HOME/.local/state}/omarchy}\"; mkdir -p \"$STATE/indicators\"; if [[ -f \"$STATE/indicators/stay-awake\" ]]; then echo yes; else echo no; fi"]
    stdout: SplitParser {
      onRead: function(line) { root.applyStayAwake(String(line).trim() === "yes", false, "state-file") }
    }
    onExited: function() { stayAwakeStateDirWatcher.reload() }
  }

  Process {
    id: stayAwakeStateWriter
    onExited: function() {
      if (root.hasPendingStayAwakePersist) {
        var pending = root.pendingStayAwakePersist
        root.hasPendingStayAwakePersist = false
        root.persistStayAwake(pending)
        return
      }

      root.refreshStayAwakeState()
    }
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
