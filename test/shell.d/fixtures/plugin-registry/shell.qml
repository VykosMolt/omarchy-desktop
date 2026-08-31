import QtQuick
import Quickshell
import "services"

ShellRoot {
  id: root

  readonly property string resultPath: Quickshell.env("OMARCHY_QML_TEST_RESULT")
  property var failures: []
  property int changeCount: 0
  property var config: ({
    version: 1,
    bar: { layout: { left: [], center: [], right: [] } },
    plugins: []
  })

  function fail(message) {
    failures.push(String(message))
  }

  function assertTrue(condition, message) {
    if (!condition) fail(message)
  }

  function assertEqual(actual, expected, message) {
    if (actual !== expected) fail(message + " expected=" + expected + " actual=" + actual)
  }

  function assertDeepEqual(actual, expected, message) {
    var actualJson = JSON.stringify(actual)
    var expectedJson = JSON.stringify(expected)
    if (actualJson !== expectedJson) fail(message + " expected=" + expectedJson + " actual=" + actualJson)
  }

  function shellQuote(value) {
    return "'" + String(value).replace(/'/g, "'\\''") + "'"
  }

  function writeResult() {
    var payload = JSON.stringify({
      ok: failures.length === 0,
      failures: failures,
      changeCount: changeCount,
      config: config,
      ids: Object.keys(registry.installedPlugins).sort()
    })

    if (resultPath) {
      Quickshell.execDetached(["bash", "-lc", "printf '%s' " + shellQuote(payload) + " > " + shellQuote(resultPath)])
    }
  }

  function manifest(id, kinds, entryPoints, barWidget) {
    var value = {
      schemaVersion: 1,
      id: id,
      name: id,
      version: "1.0.0",
      kinds: kinds,
      entryPoints: entryPoints
    }
    if (barWidget) value.barWidget = barWidget
    return value
  }

  function block(kind, source, payload) {
    return "===" + kind + "::" + source + "===\n"
      + (typeof payload === "string" ? payload : JSON.stringify(payload))
      + "\n=== EOM ===\n"
  }

  function has(id) {
    return registry.installedPlugins[String(id)] !== undefined
  }

  function pluginIds() {
    return Object.keys(registry.installedPlugins).sort()
  }

  function runChecks() {
    var scan = ""
    scan += block("firstparty", "/first/widgets/clock", manifest("omarchy.first-widget", ["bar-widget"], { barWidget: "Widget.qml" }))
    scan += block("firstparty", "/first/bar", manifest("omarchy.bar", ["bar"], { bar: "Bar.qml" }))
    scan += block("firstparty", "/first/panels/grouped", manifest("omarchy.grouped-panel", ["panel"], { panel: "Panel.qml" }))
    scan += block("firstparty", "/first/hybrid", manifest("omarchy.hybrid", ["menu", "bar-widget"], { menu: "Menu.qml", barWidget: "Widget.qml" }))
    scan += block("firstparty", "/third/panel", manifest("third.panel", ["panel"], { panel: "Panel.qml" }))
    scan += block("firstparty", "/third/widget", manifest("third.widget", ["bar-widget"], { barWidget: "Widget.qml" }, { defaultSection: "left" }))
    scan += block("firstparty", "/third/center-widget", manifest("third.center-widget", ["bar-widget"], { barWidget: "Widget.qml" }))
    scan += block("firstparty", "/third/right-widget", manifest("third.right-widget", ["bar-widget"], { barWidget: "Widget.qml" }, { defaultSection: "right" }))
    scan += block("firstparty", "/third/bar", manifest("third.bar", ["bar"], { bar: "Bar.qml" }))
        scan += block("firstparty", "/third/unsafe", manifest("third.unsafe", ["panel"], { panel: "../Panel.qml" }))
    scan += block("firstparty", "/third/missing", { schemaVersion: 1, id: "third.missing", name: "missing", version: "1.0.0", kinds: ["panel"] })
    scan += block("firstparty", "/third/bad-section", manifest("third.bad-section", ["bar-widget"], { barWidget: "Widget.qml" }, { defaultSection: "bottom" }))
    scan += block("firstparty", "/third/schema", { schemaVersion: 2, id: "third.schema", name: "schema", version: "1.0.0", kinds: ["panel"], entryPoints: { panel: "Panel.qml" } })
    scan += block("firstparty", "/third/bad-json", "{")

    registry.parseScanOutput(scan)

    root.assertDeepEqual(pluginIds(), [
      "omarchy.bar",
      "omarchy.first-widget",
      "omarchy.grouped-panel",
      "omarchy.hybrid",
      "third.bar",
      "third.center-widget",
      "third.panel",
      "third.right-widget",
      "third.widget"
    ], "registry lists every valid manifest it scanned")

    root.assertEqual(registry.installedPlugins["omarchy.grouped-panel"].__sourceDir, "/first/panels/grouped", "grouped plugin source paths are preserved")
    root.assertEqual(registry.entryPointUrl(registry.installedPlugins["third.panel"], "panel"), "file:///third/panel/Panel.qml", "entryPointUrl resolves plugin-relative paths")
    root.assertEqual(registry.entryPointUrl(registry.installedPlugins["third.widget"], "barWidget"), "file:///third/widget/Widget.qml", "entryPointUrl resolves bar widget paths")

    root.assertTrue(!has("third.unsafe"), "unsafe entry points are rejected")
    root.assertTrue(!has("third.missing"), "incomplete manifests are rejected")
    root.assertTrue(!has("third.bad-section"), "invalid default bar widget sections are rejected")
    root.assertTrue(!has("third.schema"), "unsupported schema versions are rejected")

    root.assertTrue(registry.isEnabled("omarchy.first-widget"), "first-party plugins are implicitly enabled")
    root.assertTrue(registry.isEnabled("omarchy.bar"), "built-in bar option is active by default")
    root.assertTrue(!registry.isEnabled("third.bar"), "third-party bar options start inactive")
    root.assertTrue(registry.isEnabled("third.panel"), "a scanned panel is enabled without a plugins[] entry")
    root.assertEqual(registry.resolveEnabledId("omarchy.first-widget"), "omarchy.first-widget", "an id resolves to itself")

    registry.setEnabled("third.bar", true)
    root.assertEqual(root.config.bar.id, "third.bar", "enabling third-party bar options writes bar id")
    root.assertTrue(registry.isEnabled("third.bar"), "selected third-party bar options are enabled")
    root.assertTrue(!registry.isEnabled("omarchy.bar"), "selecting third-party bar options deactivates built-in bar")
    registry.setEnabled("third.bar", false)
    root.assertTrue(root.config.bar.id === undefined, "disabling active bar options resets to built-in")
    root.assertTrue(registry.isEnabled("omarchy.bar"), "built-in bar option returns after reset")

    registry.setEnabled("third.panel", false)
    root.assertDeepEqual(root.config.disabledPlugins, ["third.panel"], "disabling a panel records it in disabledPlugins")
    root.assertTrue(!registry.isEnabled("third.panel"), "a disabled panel is not enabled")
    registry.setEnabled("third.panel", true)
    root.assertTrue(root.config.disabledPlugins === undefined, "re-enabling a panel clears the disabled record")

    registry.setEnabled("third.widget", true)
    root.assertDeepEqual(root.config.bar.layout.left, [{ id: "third.widget" }], "enabling bar widgets uses their default section")
    root.assertTrue(registry.isEnabled("third.widget"), "enabled bar widgets are found")
    registry.setEnabled("third.widget", false)
    root.assertDeepEqual(root.config.bar.layout.left, [], "disabling bar widgets removes layout entry")

    root.config = {
      version: 1,
      bar: {
        layout: {
          left: [{ id: "omarchy.workspaces" }, { id: "omarchy.menu" }],
          center: [{ id: "omarchy.weather" }, { id: "omarchy.clock" }],
          right: [{ id: "omarchy.sensors" }]
        }
      },
      plugins: []
    }
    registry.setEnabled("third.widget", true)
    root.assertDeepEqual(
      root.config.bar.layout.left,
      [{ id: "omarchy.workspaces" }, { id: "third.widget" }, { id: "omarchy.menu" }],
      "enabling a widget inserts it after its section anchor"
    )
    registry.setEnabled("third.center-widget", true)
    root.assertDeepEqual(
      root.config.bar.layout.center,
      [{ id: "omarchy.weather" }, { id: "third.center-widget" }, { id: "omarchy.clock" }],
      "widgets without a default section use the center anchor"
    )
    registry.setEnabled("third.right-widget", true)
    root.assertDeepEqual(
      root.config.bar.layout.right,
      [{ id: "omarchy.sensors" }, { id: "third.right-widget" }],
      "right widgets use the right anchor"
    )

    root.config = { version: 1, bar: { layout: { left: [], center: [], right: [] } }, plugins: [] }
    registry.setEnabled("third.right-widget", true)
    root.assertDeepEqual(root.config.bar.layout.right, [{ id: "third.right-widget" }], "widgets append when their section anchor is absent")

    root.config = {
      version: 1,
      bar: { layout: { left: [{ id: "third.widget", size: 3 }], center: [], right: [] } },
      plugins: []
    }
    root.assertEqual(registry.moveBarWidget("third.widget", { section: "right" }), "", "registry moves widgets")
    root.assertDeepEqual(root.config.bar.layout.right, [{ id: "third.widget", size: 3 }], "registry move preserves widget settings")
    root.assertEqual(registry.setBarWidget("third.widget", "size", 7, {}), "", "registry sets widget options")
    root.assertEqual(root.config.bar.layout.right[0].size, 7, "registry persists widget options")

    root.config = { version: 1, bar: { layout: { left: [], center: [], right: [] } }, plugins: [] }
    registry.setEnabled("third.widget", true, { section: "right", index: 0 })
    root.assertDeepEqual(root.config.bar.layout.right, [{ id: "third.widget" }], "enabling with placement is one registry transition")

    // A bar the placement's neighbour is not on still gets the widget.
    root.config = {
      version: 1,
      bar: { layout: { left: [], center: [{ id: "omarchy.weather" }], right: [] } },
      plugins: []
    }
    root.assertTrue(
      !registry.setEnabled("third.center-widget", true, { after: "omarchy.first-widget" }),
      "enabling against a widget the bar does not carry is refused"
    )
    root.assertEqual(
      registry.lastEnableError,
      "could not find target widget omarchy.first-widget",
      "a refused enable names the target it could not find"
    )
    root.assertDeepEqual(root.config.bar.layout.center, [{ id: "omarchy.weather" }], "a refused enable places nothing")
    root.assertEqual(
      registry.putBarWidget("third.center-widget", { after: "omarchy.first-widget" }),
      "",
      "put accepts a placement target the bar does not carry"
    )
    root.assertDeepEqual(
      root.config.bar.layout.center,
      [{ id: "omarchy.weather" }, { id: "third.center-widget" }],
      "put falls back to the section anchor when its target is missing"
    )

    root.config = {
      version: 1,
      bar: { layout: { left: [{ id: "third.center-widget", size: 2 }], center: [], right: [] } },
      plugins: []
    }
    root.assertEqual(registry.putBarWidget("third.center-widget", { section: "right" }), "", "put accepts a widget that is already on the bar")
    root.assertDeepEqual(
      root.config.bar.layout.left,
      [{ id: "third.center-widget", size: 2 }],
      "put leaves a widget that is already on the bar where its owner put it"
    )
    root.assertDeepEqual(root.config.bar.layout.right, [], "put adds no second entry for a widget already on the bar")
    root.assertEqual(registry.putBarWidget("third.absent", {}), "unknown", "put reports a widget it does not know")

    // Refusing an id the scan has not reached would fail the migration.
    root.config = { version: 1, bar: { layout: { left: [], center: [], right: [] } }, plugins: [] }
    registry.scanning = true
    root.assertEqual(registry.putBarWidget("third.absent", {}), "not ready", "put waits for a scan that has not reached its widget")
    root.assertDeepEqual(root.config.bar.layout.center, [], "put places nothing while it is still waiting")
    root.assertEqual(registry.putBarWidget("third.center-widget", {}), "", "put places a widget the scan has already read")
    registry.scanning = false

    root.config = {
      version: 1,
      bar: { layout: { left: [], center: [{ id: "third.widget", size: 4 }], right: [] } },
      plugins: []
    }
    root.assertTrue(registry.isEnabled("third.widget"), "existing layout entries enable bar widgets")
    registry.setEnabled("third.widget", false)
    root.assertDeepEqual(root.config.bar.layout.center, [], "disabling existing bar widgets removes the original layout entry")

    // A panel enables without writing anything, so the repair is shown with a
    // widget: the sections it is placed into have to exist first.
    root.config = { version: 1 }
    registry.setEnabled("third.widget", true)
    root.assertDeepEqual(root.config.bar.layout.left, [{ id: "third.widget" }], "setEnabled repairs missing config shape and places the widget")
    root.assertDeepEqual(root.config.plugins, [], "the repaired shape carries an empty plugins array")

    // A built-in loads by default, so switching one off is recorded the other
    // way round and has to survive round-tripping back on.
    root.config = { version: 1, bar: { layout: { left: [], center: [], right: [] } }, plugins: [] }
    registry.setEnabled("omarchy.grouped-panel", false)
    root.assertDeepEqual(root.config.disabledPlugins, ["omarchy.grouped-panel"], "disabling a first-party plugin records it")
    root.assertTrue(!registry.isEnabled("omarchy.grouped-panel"), "a recorded first-party plugin is disabled")
    root.assertDeepEqual(root.config.plugins, [], "disabling a first-party plugin leaves the plugins array alone")
    registry.setEnabled("omarchy.grouped-panel", true)
    root.assertTrue(root.config.disabledPlugins === undefined, "re-enabling drops the disabled record entirely")
    root.assertTrue(registry.isEnabled("omarchy.grouped-panel"), "a first-party plugin returns to enabled")
    root.assertDeepEqual(root.config.plugins, [], "re-enabling a first-party plugin adds no redundant entry")

    // A widget's place in the bar is its on/off switch. Loadability must not
    // follow it down, or a plugin that is both widget and menu (omarchy.menu)
    // would be locked out of the shell by taking its button off the bar.
    root.config = {
      version: 1,
      bar: { layout: { left: [], center: [], right: [{ id: "omarchy.first-widget" }] } },
      plugins: []
    }
    root.assertTrue(registry.inBar("omarchy.first-widget"), "inBar sees a widget in the layout")
    registry.setEnabled("omarchy.first-widget", false)
    root.assertDeepEqual(root.config.bar.layout.right, [], "disabling a first-party widget removes its layout entry")
    root.assertTrue(root.config.disabledPlugins === undefined, "disabling a first-party widget records nothing else")
    root.assertTrue(!registry.inBar("omarchy.first-widget"), "inBar follows the widget out of the layout")
    root.assertTrue(registry.isEnabled("omarchy.first-widget"), "a first-party widget stays loadable off the bar")
    registry.setEnabled("omarchy.first-widget", true)
    root.assertDeepEqual(root.config.bar.layout.center, [{ id: "omarchy.first-widget" }], "a widget without a default section falls back to center")

    root.config = {
      version: 1,
      bar: { layout: { left: [{ id: "omarchy.hybrid" }], center: [], right: [] } },
      plugins: []
    }
    registry.setEnabled("omarchy.hybrid", false)
    root.assertDeepEqual(root.config.bar.layout.left, [], "disabling a multi-kind built-in removes its widget")
    root.assertTrue(root.config.disabledPlugins === undefined, "disabling a multi-kind widget records nothing else")
    root.assertTrue(registry.isEnabled("omarchy.hybrid"), "a multi-kind built-in remains loadable without its widget")

    root.assertTrue(changeCount > 0, "registry emits change notifications")
    writeResult()
  }

  PluginRegistry {
    id: registry
    firstPartyDir: ""
    shellConfigProvider: function() { return root.config }
    shellConfigMutator: function(mutator) {
      var next = JSON.parse(JSON.stringify(root.config || {}))
      mutator(next)
      root.config = next
    }
    onPluginsChanged: root.changeCount++
  }

  Timer {
    interval: 100
    running: true
    repeat: false
    onTriggered: root.runChecks()
  }
}
