import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import "AppSearch.js" as AppSearch

// Shared desktop-application library: the sorted entry list with hidden-entry
// filtering, the icon fallback index, launch feedback, and entry removal.
// Injected as shell.appLibrary; the menu's Apps submenu is the consumer.
Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")

  property var configuredHiddenEntryIds: ({})
  property var desktopHiddenEntryIds: ({})

  // Maps an icon name to a file on disk (e.g. "omacut" -> ".../apps/omacut.svg").
  // Used as a fallback for icons that Qt's themed lookup misses because they were
  // installed after this process started (its icon cache never re-scans). Refreshed
  // whenever the app list changes, so newly installed apps get their icon live.
  property var iconIndex: ({})
  property var pendingIconIndex: ({})
  // The names a desktop entry actually asks for. The launcher's app rows are the
  // only consumer of iconIndex — notifications resolve their own icons — so a
  // name no entry names is a key that is written once and never read. On this
  // machine the icon roots hold 19,371 distinct names and the 214 installed
  // entries between them ask for 154.
  property var wantedIconNames: ({})

  property int launchSerial: 0
  property int launchToplevelCount: 0
  property var launchActiveToplevel: null
  // True while the launch OSD is on screen. It outlives the launch that opened
  // it: the OSD shows with duration 0, so only closeLaunchFeedback() takes it
  // down.
  property bool launchOsdOpen: false
  property string launchOsdMessage: ""

  // Emitted whenever the visible application set may have changed: desktop
  // entries appeared or vanished, or the hidden-entry filters reloaded.
  signal appsChanged()

  function entryName(entry) {
    return AppSearch.entryName(entry)
  }

  function entrySubtext(entry) {
    return AppSearch.entrySubtext(entry)
  }

  function isHiddenEntry(entry) {
    var id = String((entry && entry.id) || "")
    return root.configuredHiddenEntryIds[id] === true || root.desktopHiddenEntryIds[id] === true
  }

  function sortedEntries(query) {
    var values = DesktopEntries.applications.values || []
    return AppSearch.sortedEntries(values, query, function(entry) { return root.isHiddenEntry(entry) })
  }

  function iconSource(icon) {
    var value = String(icon || "")
    if (value.length === 0) return Quickshell.iconPath("application-x-executable", true)
    if (value.indexOf("file://") === 0 || value.indexOf("image://") === 0) return value
    if (value.charAt(0) === "/") return Util.fileUrl(value)
    // Prefer the context-limited app/device index. An unconstrained themed
    // lookup can resolve an app name such as "zoom" to an action icon instead.
    var found = root.iconIndex[value]
    if (found) return Util.fileUrl(found)
    var themed = Quickshell.iconPath(value, true)
    if (themed.length > 0) return themed
    return Quickshell.iconPath("application-x-executable", true)
  }

  // When the index was last rebuilt, so a caller asking to refresh does not
  // start a full rescan every time.
  property real lastIconScan: 0
  readonly property int iconScanMinIntervalMs: 60000

  // The shell may start before first-install packages have finished placing
  // their icons; consumers call this when they open so icons appear live.
  //
  // The menu calls it on every open, and the scan walks every icon root -- two
  // seconds of work, and it follows symlinks in the theme passes now, which is
  // most of that. Icons do not appear that often. A package install already
  // reaches the index the reliable way, through appsChanged and its debounce,
  // so this path only exists for icons that land without the desktop entry
  // list changing. Rate-limit it: still live, no longer a rescan per keypress.
  function refreshIcons(force) {
    if (iconIndexScan.running) return
    var now = Date.now()
    if (!force && root.lastIconScan > 0 && now - root.lastIconScan < root.iconScanMinIntervalMs) return

    // The resolver takes the wanted names as arguments, so they have to be
    // settled before it starts rather than in onStarted.
    var wanted = root.collectWantedIconNames()
    var names = []
    for (var name in wanted) names.push(name)
    if (names.length === 0) return

    root.lastIconScan = now
    root.wantedIconNames = wanted
    iconIndexScan.command = root.iconIndexScanCommand(names)
    iconIndexScan.running = true
  }

  function launch(desktopId, name) {
    var id = String(desktopId || "")
    if (!id) return
    root.beginLaunchFeedback(name)
    // Start gtk-launch inside a scope under app-graphical.slice so apps do not
    // inherit wayland-wm@.service. Keeping gtk-launch as the desktop-entry
    // resolver supports IDs with spaces and entries that UWSM rejects.
    // Keep the .desktop suffix or ids like org.telegram.desktop won't resolve.
    Util.execDetached("uwsm-app -- gtk-launch " + Util.shellQuote(id + ".desktop"))
  }

  function remove(desktopId, name) {
    var id = String(desktopId || "")
    if (!id) return
    Util.execDetached(Util.shellQuote(root.omarchyPath + "/bin/omarchy-remove-launcher-entry") + " " + Util.shellQuote(id) + " " + Util.shellQuote(String(name || id)))
  }

  function normalizeDesktopId(id) {
    var value = String(id || "").trim()
    if (value.slice(-8) === ".desktop") value = value.slice(0, -8)
    return value
  }

  function loadConfiguredHides(rawText) {
    var next = ({})
    var lines = String(rawText || "").split(/\n/)
    for (var i = 0; i < lines.length; i++) {
      var id = root.normalizeDesktopId(lines[i])
      if (id.length > 0) next[id] = true
    }
    root.configuredHiddenEntryIds = next
    root.appsChanged()
  }

  function loadDesktopHiddenEntries(rawText) {
    var next = ({})
    var lines = String(rawText || "").split(/\n/)
    for (var i = 0; i < lines.length; i++) {
      var id = root.normalizeDesktopId(lines[i])
      if (id.length > 0) next[id] = true
    }
    root.desktopHiddenEntryIds = next
    root.appsChanged()
  }

  function iconIndexScanCommand(names) {
    // The resolver is a script rather than a here-string: it reads index.theme
    // and ranks directories per theme, and none of that survives being escaped
    // through a QML string. shell/services/icon-index.sh carries the reasoning,
    // the way hidden-entries.sh already does for the hidden-entry scan.
    return [root.omarchyPath + "/shell/services/icon-index.sh"].concat(names)
  }

  function collectWantedIconNames() {
    var wanted = {}
    var values = DesktopEntries.applications.values || []
    for (var i = 0; i < values.length; i++) {
      var icon = String((values[i] && values[i].icon) || "")
      // An absolute path or a URL needs no index entry: iconSource returns it
      // directly without ever consulting one.
      if (icon.length === 0 || icon.charAt(0) === "/" || icon.indexOf("://") !== -1) continue
      wanted[icon] = true
    }
    return wanted
  }

  function indexIconLine(path) {
    var value = String(path || "").trim()
    if (value.length === 0) return
    var slash = value.lastIndexOf("/")
    var file = slash >= 0 ? value.slice(slash + 1) : value
    var dot = file.lastIndexOf(".")
    var name = dot > 0 ? file.slice(0, dot) : file
    if (name.length === 0) return
    // Ordering still decides which path wins for a name; this only decides
    // which names are worth keeping. A name nothing asks for falls through to
    // Quickshell.iconPath if it is ever requested after all.
    if (root.wantedIconNames[name] !== true) return
    if (root.pendingIconIndex[name] === undefined)
      root.pendingIconIndex[name] = value
  }

  function hiddenEntryScanCommand() {
    var desktop = [Quickshell.env("XDG_CURRENT_DESKTOP"), Quickshell.env("XDG_SESSION_DESKTOP"), Quickshell.env("DESKTOP_SESSION")].filter(function(v) { return String(v || "").length > 0 }).join(":")
    var script = root.omarchyPath + "/shell/services/hidden-entries.sh"
    return Util.shellQuote(script) + " " + Util.shellQuote(desktop)
  }

  function toplevelCount() {
    try { return ToplevelManager.toplevels.values.length } catch (e) { return 0 }
  }

  function beginLaunchFeedback(name) {
    root.launchSerial++
    root.launchToplevelCount = root.toplevelCount()
    root.launchActiveToplevel = ToplevelManager.activeToplevel
    root.launchOsdMessage = "Launching " + String(name || "application") + "…"
    launchDelay.restart()
    launchTimeout.restart()
  }

  function closeLaunchFeedback(serial) {
    if (serial !== root.launchSerial) return
    launchDelay.stop()
    launchTimeout.stop()
    if (root.launchOsdOpen) {
      Quickshell.execDetached(["omarchy-shell", "osd", "close"])
      root.launchOsdOpen = false
    }
  }

  function maybeFinishLaunchFeedback() {
    if (!launchDelay.running && !launchTimeout.running && !root.launchOsdOpen) return
    if (root.toplevelCount() <= root.launchToplevelCount && ToplevelManager.activeToplevel === root.launchActiveToplevel) return
    root.closeLaunchFeedback(root.launchSerial)
  }

  QtObject {
    id: hiddenEntryOutput
    property string text: ""
  }

  // Both scans must run in non-login shells. A login shell sources the user's
  // profile, and tools like mise touch ~/.local/share on activation — a
  // directory the desktop-entry watcher monitors — so every scan would
  // trigger the next one, pinning a core at idle.
  Process {
    id: hiddenEntryScan
    command: ["bash", "-c", root.hiddenEntryScanCommand()]
    stdout: SplitParser { onRead: function(line) { hiddenEntryOutput.text += line + "\n" } }
    onStarted: hiddenEntryOutput.text = ""
    onExited: root.loadDesktopHiddenEntries(hiddenEntryOutput.text)
  }

  Process {
    id: iconIndexScan
    stdout: SplitParser { onRead: function(line) { root.indexIconLine(line) } }
    onStarted: root.pendingIconIndex = ({})
    // Swapping the property re-evaluates every iconSource() binding, so
    // newly found icons appear without rebuilding the list.
    onExited: root.iconIndex = root.pendingIconIndex
  }

  // Coalesces bursts of app-list changes (a package install touches many
  // entries) into a single rescan.
  Timer {
    id: iconIndexDebounce
    interval: 750
    onTriggered: root.refreshIcons(true)
  }

  FileView {
    path: root.omarchyPath + "/default/omarchy/launcher.hides"
    watchChanges: true
    printErrors: false
    onLoaded: root.loadConfiguredHides(text())
    onFileChanged: root.loadConfiguredHides(text())
    onLoadFailed: root.loadConfiguredHides("")
  }

  Connections {
    target: ToplevelManager.toplevels
    function onValuesChanged() { root.maybeFinishLaunchFeedback() }
  }

  Connections {
    target: ToplevelManager
    function onActiveToplevelChanged() { root.maybeFinishLaunchFeedback() }
  }

  Timer {
    id: launchDelay
    interval: 2000
    onTriggered: {
      if (root.toplevelCount() > root.launchToplevelCount || ToplevelManager.activeToplevel !== root.launchActiveToplevel) return
      root.launchOsdOpen = true
      Quickshell.execDetached(["omarchy-shell", "osd", "show", JSON.stringify({ icon: "󱓞", message: root.launchOsdMessage, duration: 0 })])
    }
  }

  Timer {
    id: launchTimeout
    interval: 15000
    onTriggered: root.closeLaunchFeedback(root.launchSerial)
  }

  Connections {
    target: DesktopEntries.applications
    function onValuesChanged() {
      hiddenEntryScan.running = true
      iconIndexDebounce.restart()
      root.appsChanged()
    }
  }

  Component.onCompleted: {
    hiddenEntryScan.running = true
    root.refreshIcons(true)
  }
}
