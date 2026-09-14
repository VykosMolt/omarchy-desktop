#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"


run_node_test <<'JS'
const fs = require('fs')
const vm = require('vm')
const hostSource = fs.readFileSync(path.join(root, 'shell/shell.qml'), 'utf8')
const components = []
let nextInstance = 0
const enabled = { svc: true, 'omarchy.lock': true }
const registry = {
  installedPlugins: {
    svc: { kinds: ['service'], entryPoints: { service: 'Service.qml' } },
    'omarchy.lock': { kinds: ['service'], entryPoints: { service: 'Lock.qml' } }
  },
  isEnabled(id) { return enabled[id] === true },
  entryPointUrl(manifest, key) { return manifest.entryPoints[key] || '' },
  pluginLoadFailed() {}
}
const widgets = new Map()
const host = {
  _services: {}, _serviceUrls: {}, _serviceLoads: {}, pluginWidgetComponents: {}, pluginRegistry: registry,
  pluginReloading: false, omarchyPath: '/fixture', serviceHost: {}, console: { warn() {} },
  Component: { Loading: 0, Ready: 1, Error: 2 },
  barWidgetRegistry: {
    register(id, component) { widgets.set(id, component) },
    unregister(id) { widgets.delete(id) }
  },
  Qt: { createComponent(url) {
    let callbacks = []
    const component = {
      status: 0, url, destroyed: 0,
      statusChanged: {
        connect(fn) { callbacks.push(fn) },
        disconnect(fn) { callbacks = callbacks.filter(callback => callback !== fn) }
      },
      finish(status = 1) { this.status = status; for (const callback of [...callbacks]) callback() },
      get listeners() { return callbacks.length },
      errorString() { return 'fixture failure' },
      createObject() {
        const instance = { number: ++nextInstance, destroyed: 0, destroy() { this.destroyed++ } }
        Object.defineProperty(instance, 'shell', { set(value) { if (host.onInject) host.onInject(instance) } })
        if (host.onCreate) host.onCreate(instance)
        return instance
      },
      destroy() { this.destroyed++ }
    }
    components.push(component)
    return component
  } }
}
host.shell = host
vm.createContext(host)
for (const name of ['setServiceLoad', 'serviceUrlFor', 'setServiceInstance', 'unregisterPanelLoader', 'ensureService', '_syncServices', 'unloadPluginServices', 'setPluginWidgetComponent', 'unregisterPluginWidget', 'loadPluginWidget', 'unloadPluginWidgets']) {
  const match = hostSource.match(new RegExp('^  function ' + name + '\\([^]*?^  }', 'm'))
  assert(match, 'shell host exposes ' + name)
  vm.runInContext(match[0], host)
}
host.ensureService('svc')
host.ensureService('svc')
assertEqual(components.length, 1, 'concurrent requests share a service load')
host.unloadPluginServices()
host.ensureService('svc')
components[0].finish()
assert(!host._services.svc && host._serviceLoads.svc, 'a stale service completion cannot steal a newer pending load')
assertEqual(components[0].destroyed, 1, 'discarded service components are released')
components[1].finish()
assertEqual(nextInstance, 1, 'only the current service load creates an instance')
assertEqual(components[1].destroyed, 1, 'a successful service releases its source component')
assertEqual(components[1].listeners, 0, 'a completed service disconnects its asynchronous callback')
const instance = host._services.svc
enabled.svc = false
host._syncServices()
assertEqual(instance.destroyed, 1, 'disabling a service destroys its instance')
const lockComponent = components[2]
lockComponent.finish()
const lock = host._services['omarchy.lock']
lock.locked = true
enabled['omarchy.lock'] = false
host._syncServices()
assertEqual(lock.destroyed, 0, 'an active session lock remains loaded while disabled')
lock.locked = false
host._syncServices()
assertEqual(lock.destroyed, 1, 'the disabled lock service unloads after unlock')
host.loadPluginWidget('widget', 'old.qml', {})
const old = components.at(-1)
host.loadPluginWidget('widget', 'new.qml', {})
const current = components.at(-1)
old.finish()
assert(!widgets.has('widget'), 'an obsolete widget load cannot register over a new request')
current.finish()
assertEqual(widgets.get('widget'), current, 'the current widget source is registered')
assertEqual(current.listeners, 0, 'loaded widget components disconnect their callbacks')
host.loadPluginWidget('widget', 'replacement.qml', {})
const replacement = components.at(-1)
assertEqual(current.destroyed, 0, 'a source replacement retains the active widget until compilation completes')
replacement.finish()
assertEqual(current.destroyed, 1, 'a replaced widget component is released')
host.unloadPluginWidgets()
assertEqual(replacement.destroyed, 1, 'unregistering releases the loaded widget component')
assertEqual(widgets.size, 0, 'unload removes widget registry entries')
host.loadPluginWidget('widget', 'pending.qml', {})
const pending = components.at(-1)
host.unloadPluginWidgets()
pending.finish()
assertEqual(pending.destroyed, 1, 'unloaded pending widgets discard their later component completion')
assertEqual(widgets.size, 0, 'late widget completion cannot restore an unloaded entry')
enabled.svc = true
host.onCreate = () => host.ensureService('svc')
host.onInject = () => host.ensureService('svc')
const countBeforeReentry = components.length
host.ensureService('svc')
components.at(-1).finish()
assertEqual(components.length, countBeforeReentry + 1, 'reentrant creation and shell injection share the original service claim')
host.onCreate = null
host.onInject = null
const original = host._services.svc
registry.installedPlugins.svc.entryPoints.service = 'Changed.qml'
host._syncServices()
assertEqual(original.destroyed, 1, 'a changed service URL releases the previous instance')
components.at(-1).finish()
assertEqual(host._serviceUrls.svc, 'Changed.qml', 'the replacement service records its current source')
const changed = host._services.svc
registry.installedPlugins.svc.kinds = []
host._syncServices()
assertEqual(changed.destroyed, 1, 'removing the service kind unloads the instance even while the plugin stays enabled')
registry.installedPlugins.svc.kinds = ['service']
host.ensureService('svc')
const removedKindPending = components.at(-1)
registry.installedPlugins.svc.kinds = []
host._syncServices()
removedKindPending.finish()
assert(!host._services.svc, 'removing the service kind invalidates an in-flight load')
assertEqual(removedKindPending.destroyed, 1, 'an ineligible pending service releases its component')
registry.installedPlugins.svc.kinds = ['service']
host.onInject = () => host.unloadPluginServices()
host.ensureService('svc')
const invalidatedDuringInjection = components.at(-1)
invalidatedDuringInjection.finish()
assert(!host._services.svc, 'a reload during property injection cannot publish the obsolete service')
host.onInject = null
const oldPanel = {}, newPanel = {}
host.panelLoaders = { panel: newPanel }
host.unregisterPanelLoader('panel', oldPanel)
assertEqual(host.panelLoaders.panel, newPanel, 'destroying an old panel loader preserves its replacement')
host.unregisterPanelLoader('panel', newPanel)
assert(!host.panelLoaders.panel, 'destroying the registered panel loader removes its entry')

const registrySource = fs.readFileSync(path.join(root, 'shell/services/PluginRegistry.qml'), 'utf8')
const scan = {
  scanning: true, scanStarted: true, scanExited: true, scanOutputDone: false,
  scanExitCode: 0, scanOutput: 'new', installedPlugins: { old: true }, scanProcess: { running: false },
  parsed: [], finished: 0, console: { warn() {} },
  parseScanOutput(raw) { scan.parsed.push(raw); scan.scanning = false },
  scanFinished() { scan.finished++ }
}
scan.registry = scan
vm.createContext(scan)
for (const name of ['finishScan', 'scanStopped']) vm.runInContext(registrySource.match(new RegExp('^  function ' + name + '\\([^]*?^  }', 'm'))[0], scan)
scan.finishScan()
assertEqual(scan.parsed.length, 0, 'registry does not publish until stdout drains after process exit')
scan.scanOutputDone = true
scan.finishScan()
assertDeepEqual(scan.parsed, ['new'], 'registry publishes the completed scan output once')
scan.scanning = true
scan.scanExitCode = 1
scan.finishScan()
assert(scan.installedPlugins.old && scan.finished === 1, 'a failed scan retains the registry and releases reload waiters')
scan.scanning = true
scan.scanStarted = false
scan.scanExited = false
scan.scanOutputDone = false
scan.scanStopped()
assert(!scan.scanning && scan.finished === 2, 'a failed exec releases the registry scan without waiting for absent stream signals')

JS

TMPDIR=""
QS_PID=""

cleanup() {
  if [[ -n $QS_PID ]] && kill -0 "$QS_PID" 2>/dev/null; then
    kill "$QS_PID" 2>/dev/null || true
    wait "$QS_PID" 2>/dev/null || true
  fi
  if [[ -n $TMPDIR && -d $TMPDIR ]]; then
    rm -rf "$TMPDIR"
  fi
}
trap cleanup EXIT

export QT_QPA_PLATFORM=offscreen

if ! command -v quickshell >/dev/null 2>&1; then
  pass "quickshell not installed; skipping plugin registry contract test"
  exit 0
fi

require_command jq

TMPDIR=$(mktemp -d)
result="$TMPDIR/result.json"
log="$TMPDIR/quickshell.log"
config_dir="$TMPDIR/plugin-registry"
mkdir -p "$config_dir" "$TMPDIR/home"
cp "$SHELL_TEST_DIR/fixtures/plugin-registry/shell.qml" "$config_dir/shell.qml"
ln -s "$ROOT/shell/services" "$config_dir/services"
ln -s "$ROOT/shell/Commons" "$config_dir/Commons"

OMARCHY_PATH="$ROOT" \
OMARCHY_QML_TEST_RESULT="$result" \
HOME="$TMPDIR/home" \
XDG_CONFIG_HOME="$TMPDIR/home/.config" \
XDG_CACHE_HOME="$TMPDIR/home/.cache" \
XDG_STATE_HOME="$TMPDIR/home/.local/state" \
QML2_IMPORT_PATH="$ROOT/shell${QML2_IMPORT_PATH:+:$QML2_IMPORT_PATH}" \
QML_IMPORT_PATH="$ROOT/shell${QML_IMPORT_PATH:+:$QML_IMPORT_PATH}" \
PATH="$ROOT/bin:$PATH" \
  quickshell -p "$config_dir" --no-color >"$log" 2>&1 &
QS_PID=$!

for _ in {1..50}; do
  [[ -s $result ]] && break
  if ! kill -0 "$QS_PID" 2>/dev/null; then
    sed -n '1,180p' "$log" >&2
    fail "plugin registry quickshell exited before writing result"
  fi
  sleep 0.1
done

[[ -s $result ]] || {
  sed -n '1,180p' "$log" >&2
  fail "plugin registry contract test timed out"
}

if ! jq -e '.ok == true' "$result" >/dev/null; then
  printf 'Plugin registry result:\n' >&2
  jq . "$result" >&2
  printf 'Plugin registry log:\n' >&2
  sed -n '1,180p' "$log" >&2
  fail "plugin registry contract checks pass"
fi

pass "plugin registry contract checks pass"
