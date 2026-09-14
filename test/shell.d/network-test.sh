#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

run_node_test <<'JS'
const fs = require('fs')
const network = requireFromRoot('shell/plugins/panels/network/Model.js')
const panelSource = fs.readFileSync(root + '/shell/plugins/panels/network/Panel.qml', 'utf8')

assert(/IpcHandler[\s\S]*?function toggleNetwork\(\) \{ root\.toggleNetwork\(\) \}/.test(panelSource), 'network exposes the Wi-Fi radio toggle over IPC')
assert(/manageIpc: false/.test(panelSource), 'network owns its IPC handler so it can extend the target methods')

// Opening from the bar must call open() and nothing else. open() runs
// refresh(true), which defers the PHY scan; a second bare refresh() defaults
// scanWifi to false, sets scannerEnabled synchronously, and stalls the open on
// NetworkManager's access-point flood.
const barPress = panelSource.match(/onPressed: function\(b\) \{[\s\S]*?\n {4}\}/)
assert(barPress, 'network bar button has an onPressed handler')
const barPressCode = barPress[0].replace(/\/\/.*$/gm, '')
assert(!/refresh\(/.test(barPressCode), 'network bar click opens the panel without a second refresh that would undo the deferred scan')

// A closed panel has no nearby-network list to fill. Quickshell's scanner
// re-arms RequestScan on its own timer, and every sweep takes the radio off
// the operating channel, so a scanner left enabled behind a closed panel keeps
// degrading the connection it is scanning from.
const refreshFn = panelSource.match(/function refresh\(scanWifi\)[\s\S]*?\n {2}\}/)
assert(refreshFn, 'network has a refresh() function')
assert(/if \(opened && wifiDevice\)/.test(refreshFn[0]), 'network only touches the scanner from refresh() while its panel is open')

// The 100ms deferral can outlive the panel: closing inside the window would
// otherwise re-enable scanning from a timer nobody is watching.
const scanRestart = panelSource.match(/id: scanRestart[\s\S]*?onTriggered: \{[\s\S]*?\n {4}\}/)
assert(scanRestart, 'network has the deferred scan restart timer')
assert(/root\.opened/.test(scanRestart[0]), 'network re-checks the panel before the deferred restart re-enables scanning')
assert(/scanRestart\.stop\(\)/.test(panelSource), 'network cancels a pending scan restart when the panel closes')

// scannerEnabled lives on a shared WifiDevice with no reference counting, so
// the panel has to own what it enabled. Run the helper's own JavaScript against
// stand-in devices: the two invariants it carries are that a closed panel never
// takes a device, and that adopting a new one releases the previous.
const scannerHelper = panelSource.match(/function setScannerEnabled\(enabled\) \{[\s\S]*?\n {2}\}/)
assert(scannerHelper, 'network has a scanner ownership helper')

var opened = false
var wifiDevice = { scannerEnabled: false }
var scannerDevice = null
eval(scannerHelper[0])

setScannerEnabled(true)
assert(
  scannerDevice === null && wifiDevice.scannerEnabled === false,
  'network does not let a closed panel claim or enable a scanner device'
)

var previousScannerDevice = { scannerEnabled: true }
var replacementScannerDevice = { scannerEnabled: false }
opened = true
scannerDevice = previousScannerDevice
wifiDevice = replacementScannerDevice
setScannerEnabled(true)
assert(
  previousScannerDevice.scannerEnabled === false &&
    scannerDevice === replacementScannerDevice &&
    replacementScannerDevice.scannerEnabled === true,
  'network releases the previous scanner device before enabling its replacement'
)

// Destruction is the case a guard-only fix misses: the widget dies with the
// panel still open, as a bar reload does, and nothing else would release it.
assert(
  /Component\.onDestruction[\s\S]{0,140}scannerDevice\.scannerEnabled = false/.test(panelSource),
  'network releases the scanner it owns when the widget is destroyed'
)
assert(!/wifiDevice\.scannerEnabled\s*=/.test(panelSource), 'network writes scanner state through its owned device reference rather than the moving wifiDevice reference')

// A row is a primitive snapshot that can outlive its WifiNetwork, and
// disconnect() falls back to the live connection when handed null, so row
// activation must go through the guarded disconnectRow().
assert(
  /function disconnectRow\(ssid\) \{\s*var network = networkForSsid\(ssid\)\s*if \(network\) disconnect\(network\)/.test(panelSource),
  'network guards row disconnects so a stale row cannot drop an unrelated connection'
)
assert(!/disconnect\(\s*(root\.)?networkForSsid\(/.test(panelSource), 'network never passes an unguarded networkForSsid() lookup to disconnect()')

assertDeepEqual(
  network.parseNetworkStatus('wifi\tCafe WiFi\t78\t5200\n'),
  { kind: 'wifi', label: 'Cafe WiFi', signalStrength: 78, frequency: '5200' },
  'network parses bar status'
)
assertEqual(network.connectionIcon('wifi', 80), network.wifiIconFor(80), 'network maps wifi icon from signal')
assertEqual(network.formatHeaderSpeed('1000'), '1gbit', 'network formats gigabit speed')
assertEqual(network.formatHeaderSpeed('2500'), '2.5gbit', 'network formats fractional gigabit speed')
assertEqual(network.formatHeaderFreq('2462'), '2.4ghz', 'network formats 2.4GHz wifi band')
assertEqual(network.formatHeaderFreq('5200'), '5ghz', 'network formats 5GHz wifi band')
assertEqual(network.formatHeaderFreq('6455.0'), '6ghz', 'network formats 6GHz wifi band')
assertEqual(network.formatHeaderFreq('18300'), '18.3ghz', 'network falls back to exact GHz for unknown bands')
assertEqual(network.headerDetail({ type: 'ethernet', speed: '100' }), '100mbit', 'network header uses ethernet speed')

assertDeepEqual(
  network.parseKeyValue('iface\twlan0\nrx_bytes\t100\ntx_bytes\t50\n'),
  { iface: 'wlan0', rx_bytes: '100', tx_bytes: '50' },
  'network parses detail key values'
)
assertEqual(network.decodeIwSsid('Cafe\\xe2\\x80\\x99'), 'Cafe’', 'network decodes UTF-8 SSID bytes')
assertEqual(network.decodeIwSsid('Smile \\xf0\\x9f\\x98\\x80'), 'Smile 😀', 'network decodes emoji SSID bytes')
assertEqual(network.decodeIwSsid('\\x20Cafe\\x20'), ' Cafe ', 'network preserves edge spaces in SSIDs')
assertEqual(network.decodeIwSsid('slash\\x5cname'), 'slash\\name', 'network decodes SSID backslashes once')
assertEqual(network.decodeIwSsid('invalid\\xff'), 'invalid\\xff', 'network preserves invalid UTF-8 escapes')
assertEqual(network.decodeIwSsid('already 😀'), 'already 😀', 'network safely preserves unexpected non-BMP input')
assertDeepEqual(
  network.parseKeyValue('ssid\tline\\x0abreak\\x09tab\\x00nul\nsignal_dbm\t-40\n'),
  { ssid: 'line\\x0abreak\\x09tab\\x00nul', signal_dbm: '-40' },
  'network leaves control-byte escapes safe for single-line display'
)
assertDeepEqual(
  network.throughputState({ prevIface: '', prevSampleTime: 0 }, { iface: 'wlan0', rx_bytes: '100', tx_bytes: '50' }, 10),
  { prevIface: 'wlan0', prevRxBytes: 100, prevTxBytes: 50, prevSampleTime: 10, downloadRate: 0, uploadRate: 0 },
  'network seeds throughput state on first sample'
)
assertDeepEqual(
  network.throughputState({ prevIface: 'wlan0', prevRxBytes: 100, prevTxBytes: 50, prevSampleTime: 10 }, { iface: 'wlan0', rx_bytes: '300', tx_bytes: '90' }, 12),
  { prevIface: 'wlan0', prevRxBytes: 300, prevTxBytes: 90, prevSampleTime: 12, downloadRate: 100, uploadRate: 20 },
  'network computes throughput deltas'
)

let ping = network.pingLatencyState(
  { pingIface: '', routerPingSamples: [], internetPingSamples: [] },
  { iface: 'wlan0', router_ping_ms: '2.0', internet_ping_ms: '20.0' },
  4
)
assertDeepEqual(
  ping,
  { pingIface: 'wlan0', routerPingSamples: [2], internetPingSamples: [20], routerPingLatency: 2, internetPingLatency: 20, internetPingPacketLoss: 0 },
  'network seeds ping latency samples'
)

ping = network.pingLatencyState(ping, { iface: 'wlan0', router_ping_ms: '4.0', internet_ping_ms: '' }, 4)
assertDeepEqual(
  ping,
  { pingIface: 'wlan0', routerPingSamples: [2, 4], internetPingSamples: [20, null], routerPingLatency: 3, internetPingLatency: 20, internetPingPacketLoss: 50 },
  'network averages recent successful ping samples'
)

assertDeepEqual(
  network.pingLatencyState(ping, { iface: 'eth0', router_ping_ms: '1.5', internet_ping_ms: '10.0' }, 4),
  { pingIface: 'eth0', routerPingSamples: [1.5], internetPingSamples: [10], routerPingLatency: 1.5, internetPingLatency: 10, internetPingPacketLoss: 0 },
  'network resets ping samples when interface changes'
)

assertDeepEqual(
  network.pingLatencyState(ping, { iface: 'wlan0', internet_ping_ms: '22.0' }, 4),
  { pingIface: 'wlan0', routerPingSamples: [], internetPingSamples: [20, null, 22], routerPingLatency: -1, internetPingLatency: 21, internetPingPacketLoss: 33 },
  'network clears ping samples when a target is unavailable'
)

assertEqual(network.formatBytes(1536), '1.5 KB', 'network formats bytes')
assertEqual(network.formatRate(1536), '1.5 KB/s', 'network formats rates')
assertEqual(network.formatPingLatency('2.54'), '2.5 ms', 'network formats low ping with precision')
assertEqual(network.formatPingLatency('25.4'), '25 ms', 'network formats ping')
assertEqual(network.formatPingLatency(''), 'Timeout', 'network formats missing ping as timeout')
assertEqual(network.formatPingLatency(-1, false), '--', 'network holds the ping row before the first sample')
assertEqual(network.formatPingLatency('25.4', true), '25 ms', 'network formats ping once samples exist')
assertEqual(network.formatPingLatency('', true), 'Timeout', 'network still reports a timeout among real samples')
assertEqual(network.formatPacketLoss(2), '2%', 'network formats packet loss')
assertEqual(network.formatPacketLoss(0), '0%', 'network formats zero packet loss')
assertEqual(network.formatPacketLoss(0, false), '--', 'network holds the packet loss row before the first sample')
assertEqual(network.formatPacketLoss(0, true), '0%', 'network reports zero loss once samples exist')

const rows = network.sortWifiRows([
  { ssid: 'Open', connected: false, known: false, signal: 95 },
  { ssid: 'Known', connected: false, known: true, signal: 10 },
  { ssid: 'Connected', connected: true, known: true, signal: 20 }
])
assertDeepEqual(rows.map(row => row.ssid), ['Connected', 'Known', 'Open'], 'network sorts wifi rows by connection and known state')
assertEqual(network.wifiSectionTitle(rows, 0), 'KNOWN NETWORKS', 'network labels known wifi section')
assertEqual(network.wifiSectionTitle(rows, 2), 'OTHER NETWORKS', 'network labels other wifi section')

const wifiRow = network.wifiRow({ connected: true, known: true, name: 'Home', signalStrength: 0.8, security: 1 })
assertDeepEqual(
  wifiRow,
  { connected: true, known: true, ssid: 'Home', signal: 80, security: 1 },
  'network projects wifi rows with primitives so delegates never hold the live WifiNetwork object'
)
assertDeepEqual(
  Object.keys(wifiRow).sort(),
  ['connected', 'known', 'security', 'signal', 'ssid'],
  'network wifi rows project exactly the primitive fields, so each delegate stores no live QObject'
)

const security = {
  Wpa3SuiteB192: 0,
  Sae: 1,
  Wpa2Eap: 2,
  Wpa2Psk: 3,
  WpaEap: 4,
  WpaPsk: 5,
  StaticWep: 6,
  DynamicWep: 7,
  Leap: 8,
  Owe: 9,
  Open: 10,
  Unknown: 11
}
for (const name of ['Wpa3SuiteB192', 'Sae', 'Wpa2Eap', 'Wpa2Psk', 'WpaEap', 'WpaPsk', 'StaticWep', 'DynamicWep', 'Leap', 'Unknown']) {
  assertEqual(network.requiresCredentials(security[name], security.Open, security.Owe), true, 'network asks for ' + name + ' credentials')
}
assertEqual(network.requiresCredentials(security.Owe, security.Open, security.Owe), false, 'network does not ask for OWE credentials')
assertEqual(network.requiresCredentials(security.Open, security.Open, security.Owe), false, 'network does not ask for open-network credentials')

assert(
  /Model\.requiresCredentials\(security, WifiSecurityType\.Open, WifiSecurityType\.Owe\)/.test(panelSource),
  'network wires the Quickshell OWE enum into credential detection'
)
assert(
  /if \(requiresCredentials\(net\.security\) && !net\.known\)/.test(panelSource),
  'network keyboard activation gates unknown-network prompts on credential requirements'
)
assert(
  /if \(row\.requiresCredentials && !row\.isKnown\)/.test(panelSource),
  'network row clicks gate unknown-network prompts on credential requirements'
)
assert(
  /shouldRepromptPassphrase\(reason, root\.requiresCredentials\(network\.security\)\)/.test(panelSource),
  'network failure reprompts use the live credential requirement independently of row delegates'
)
assert(
  /networkFailureReason\(reason, requiresCredentials\(network\.security\)\)/.test(panelSource),
  'network failure copy uses the live network credential requirement'
)
assert(
  /readonly property bool canForget: root\.canForgetNetwork\(net\)/.test(panelSource),
  'network rows derive forget eligibility from the tested model helper'
)
const rightAction = panelSource.match(/Item \{\s*id: rightAction\b[\s\S]*?\n {6}\}/)
assert(rightAction, 'network has a right-edge action target')
assert(
  /visible: row\.requiresCredentials \|\| row\.canForget/.test(rightAction[0]),
  'network keeps a forget target for known passwordless networks'
)
const lockIndicator = panelSource.match(/Text \{\s*id: lockIndicator\b[\s\S]*?\n {8}\}/)
assert(lockIndicator, 'network has a lock/forget indicator')
assert(
  /visible: row\.requiresCredentials \|\| row\.forgetVisible/.test(lockIndicator[0]),
  'network hides the lock on passwordless networks until showing their forget action'
)
assert(
  /forgetVisible: canForget && \(!requiresCredentials \|\| forgetFocused \|\| rightMouse\.containsMouse\)/.test(panelSource),
  'network shows the forget action directly for known passwordless networks'
)

const reasons = { NoSecrets: 1, WifiAuthTimeout: 2, WifiNetworkLost: 3, WifiClientDisconnected: 4, WifiClientFailed: 5 }
assertEqual(network.networkFailureReason(reasons.NoSecrets, true, reasons), 'Passphrase required', 'network maps missing credential failures')
assertEqual(network.networkFailureReason(reasons.WifiAuthTimeout, true, reasons), 'Wrong password', 'network maps credentialed auth timeouts')
assertEqual(network.networkFailureReason(reasons.NoSecrets, false, reasons), 'Failed to connect', 'network gives passwordless missing-secret failures generic copy')
assertEqual(network.networkFailureReason(reasons.WifiAuthTimeout, false, reasons), 'Failed to connect', 'network gives passwordless auth timeouts generic copy')
assertEqual(network.networkFailureReason(99, true, reasons), 'Failed to connect', 'network maps unknown failures')

assertEqual(network.canForgetNetwork({ known: true, connected: false, security: security.Owe }), true, 'network can forget known disconnected OWE networks')
assertEqual(network.canForgetNetwork({ known: true, connected: false, security: security.Open }), true, 'network can forget known disconnected open networks')
assertEqual(network.canForgetNetwork({ known: false, connected: false, security: security.Owe }), false, 'network cannot forget unknown networks')
assertEqual(network.canForgetNetwork({ known: true, connected: true, security: security.Owe }), false, 'network cannot forget the connected network')

assertEqual(network.shouldRepromptPassphrase(reasons.NoSecrets, true, reasons), true, 'network reprompts when required credentials are missing')
assertEqual(network.shouldRepromptPassphrase(reasons.NoSecrets, false, reasons), false, 'network does not ask a passwordless network for missing secrets')
assertEqual(network.shouldRepromptPassphrase(reasons.WifiAuthTimeout, true, reasons), true, 'network reprompts a credentialed network after a wrong password')
assertEqual(network.shouldRepromptPassphrase(reasons.WifiAuthTimeout, false, reasons), false, 'network does not reprompt an open network on auth timeout')
assertEqual(network.shouldRepromptPassphrase(reasons.WifiClientFailed, true, reasons), false, 'network does not reprompt on generic connection failures')


assertEqual(network.bandLabel('2.4'), '2.4ghz', 'network labels the 2.4GHz band')
assertEqual(network.bandLabel('6'), '6ghz', 'network labels the 6GHz band')
assertEqual(network.bandLabel('auto'), 'Auto', 'network labels the automatic band choice')

assertEqual(network.bandSectionTitle('auto', '2.4'), 'WI-FI BAND: 2.4GHZ', 'network names the live band in the header under automatic')
assertEqual(network.bandSectionTitle('auto', ''), 'WI-FI BAND', 'network omits an unknown band from the header')
assertEqual(network.bandSectionTitle('5', '5'), 'WI-FI BAND', 'network drops the header band once the pills are showing')
assertEqual(network.bandSectionTitle('5', '2.4'), 'WI-FI BAND', 'network keeps a plain header while a pin is settling')

assertDeepEqual(
  network.parseBandStatus('band\t5\navailable\t2.4 5 6\nselected\tauto\n'),
  { band: '5', selected: 'auto', available: ['2.4', '5', '6'] },
  'network parses band status'
)
assertDeepEqual(
  network.parseBandStatus(''),
  { band: '', selected: 'auto', available: [] },
  'network parses empty band status without a wifi connection'
)



assertEqual(network.headerDetail({ type: 'wifi', freq: '5745' }), '', 'network keeps wifi band state out of the hero')
assertEqual(network.headerDetail({ type: 'ethernet', speed: '100' }), '100mbit', 'network keeps ethernet speed in the hero')
JS

run_node_test <<'JS'
const fs = require('fs')
const vm = require('vm')
const source = fs.readFileSync(root + '/shell/plugins/panels/network/Panel.qml', 'utf8')
const selected = { wifiNetworks: [{ ssid: 'A' }, { ssid: 'B' }], selectedIndex: 1, wifiNetworkObjects: [], wifiRowsSnapshot: [{ ssid: 'B' }, { ssid: 'A' }], passwordSsid: '', wifiDevice: {}, checkActionCompletion: () => {} }
selected.root = selected
vm.createContext(selected)
for (const name of ['wifiIndexForSsid', 'syncWifiNetworks']) vm.runInContext(source.match(new RegExp('  function ' + name + '\\([^]*?\\n  }'))[0], selected)
selected.syncWifiNetworks()
assertEqual(selected.selectedIndex, 0, 'Wi-Fi selection follows its SSID when signal changes reorder rows')

// QML emits property-change handlers before all var initializers have run.
// Reproduce the live startup order: device first, then snapshot, then rows.
// A setter delivers the actual list handler synchronously as QML does.
const initial = {
  Model: requireFromRoot('shell/plugins/panels/network/Model.js'),
  wifiRowsSnapshot: undefined, wifiNetworkObjects: undefined, wifiDevice: {},
  selectedIndex: -1, wifiActionFocused: true, focusSection: 'wifi', passwordSsid: '',
  opened: false, setScannerEnabled() {}, checkActionCompletion() {},
  canForgetNetwork(net) { return !!(net && net.known && !net.connected) }
}
initial.root = initial
vm.createContext(initial)
for (const name of ['wifiIndexForSsid', 'syncWifiNetworks']) vm.runInContext(source.match(new RegExp('  function ' + name + '\\([^]*?\\n  }'))[0], initial)
const changedRows = source.match(/  onWifiNetworksChanged: (\{[^]*?\n  \})/)[1]
const changedDevice = source.match(/  onWifiDeviceChanged: (\{[^]*?\n  \})/)[1]
const snapshotBinding = source.match(/  readonly property var wifiRowsSnapshot: (\{[^]*?\n  \})/)[1]
vm.runInContext('rowsChanged = function() ' + changedRows + '\ndeviceChanged = function() ' + changedDevice + '\nbuildSnapshot = function() ' + snapshotBinding, initial)
let initialRows
Object.defineProperty(initial, 'wifiNetworks', {
  get() { return initialRows },
  set(value) { initialRows = value; initial.rowsChanged() }
})
initial.rowsChanged()
assertEqual(initial.selectedIndex, -1, 'an early row-change event tolerates an uninitialized model')
assertEqual(initial.focusSection, 'dns', 'an early empty row event leaves keyboard focus in a valid section')
initial.deviceChanged()
assertDeepEqual(initial.wifiNetworks, [], 'the initial device event never publishes an undefined snapshot')
assertDeepEqual(initial.buildSnapshot(), [], 'the snapshot binding tolerates an uninitialized backend list')
initial.wifiNetworkObjects = [{ name: 'Initial Wi-Fi', known: true, connected: false, security: 3, signalStrength: 0.8 }]
initial.wifiRowsSnapshot = initial.buildSnapshot()
vm.runInContext(source.match(/  onWifiRowsSnapshotChanged: (.*)/)[1], initial)
assertEqual(initial.wifiNetworks[0].ssid, 'Initial Wi-Fi', 'the first completed snapshot reaches the list after early initialization events')
assertEqual(initial.wifiIndexForSsid('Initial Wi-Fi'), 0, 'the first completed snapshot is available to row actions')
initial.wifiNetworks = undefined
initial.syncWifiNetworks()
assertEqual(initial.wifiNetworks[0].ssid, 'Initial Wi-Fi', 'a later refresh repairs an undefined list instead of failing before publication')

// Enterprise authentication belongs to the native editor, which exposes the
// certificate/server settings absent from a simple identity/password prompt.
// Exercise the panel's actual entry points, including stale PSK submissions.
const networkModel = requireFromRoot('shell/plugins/panels/network/Model.js')
const securityNames = ['Wpa3SuiteB192', 'Sae', 'Wpa2Eap', 'Wpa2Psk', 'WpaEap', 'WpaPsk', 'StaticWep', 'DynamicWep', 'Leap', 'Owe', 'Open', 'Unknown']
const security = Object.fromEntries(securityNames.map((name, index) => [name, index]))
const calls = []
const enterprise = {
  Model: networkModel, WifiSecurityType: security,
  wifiNetworkObjects: [], wifiNetworks: [], selectedIndex: 0, wifiActionFocused: false,
  actionSsid: '', actionKind: '', failureSsid: '', failureReason: '',
  passwordSsid: '', passwordText: '', opened: true,
  enterpriseEditor: { pendingResult: false, startConfirmed: false, running: false, ssid: '', command: [] },
  actionTimeout: { restart() {}, stop() {} }, refresh() {},
  connectionFailReasons: { NoSecrets: 1, WifiAuthTimeout: 2, WifiClientFailed: 3 },
  controller: { hide() { enterprise.opened = false } }
}
Object.defineProperty(enterprise, 'busy', { get() { return this.actionKind !== '' || this.enterpriseEditor.pendingResult } })
enterprise.root = enterprise
vm.createContext(enterprise)
for (const name of ['cancelPasswordPrompt', 'close', 'requiresCredentials', 'isEnterpriseSecurity', 'openPasswordPrompt', 'networkForSsid', 'runNetworkAction', 'connectDirectly', 'connectWithPassphrase', 'openEnterpriseEditor', 'finishEnterpriseEditor', 'enterpriseEditorPending', 'canForgetNetwork', 'activateSelected', 'failNetworkAction', 'networkFailureReason', 'shouldRepromptPassphrase']) {
  vm.runInContext(source.match(new RegExp('  function ' + name + '\\([^]*?\\n  }'))[0], enterprise)
}
function networkFixture(name, known = false) {
  const net = {
    name: 'Campus " ; $(literal)', security: security[name], known, connected: false,
    connect() { calls.push(['connect', name]) },
    connectWithPsk(secret) { calls.push(['psk', secret]) }
  }
  enterprise.actionSsid = enterprise.actionKind = ''
  enterprise.failureSsid = enterprise.failureReason = ''
  enterprise.passwordSsid = enterprise.passwordText = ''
  enterprise.enterpriseEditor.pendingResult = enterprise.enterpriseEditor.running = false
  enterprise.enterpriseEditor.startConfirmed = false
  enterprise.wifiNetworkObjects = [net]
  enterprise.wifiNetworks = [{ ssid: net.name, security: net.security, known, connected: false }]
  enterprise.opened = true
  calls.length = 0
  return net
}
const enterpriseNames = ['Wpa3SuiteB192', 'Wpa2Eap', 'WpaEap', 'DynamicWep', 'Leap']
for (const name of enterpriseNames) {
  const net = networkFixture(name)
  enterprise.activateSelected()
  assertDeepEqual(enterprise.enterpriseEditor.command, ['nm-connection-editor', '--create', '--type=802-11-wireless'], name + ' opens the native creation dialog without network-derived arguments')
  assertEqual(enterprise.passwordSsid, '', name + ' never opens an inline credential prompt')
  assertEqual(calls.length, 0, name + ' does not create or activate a profile from the panel')
  assertEqual(enterprise.enterpriseEditorPending(net.name), true, name + ' keeps the editor launch bound to its selected SSID')
  enterprise.finishEnterpriseEditor(0)
  net.known = true
  enterprise.connectDirectly(net.name)
  assertDeepEqual(calls, [['connect', name]], name + ' saved profiles continue through the normal connection path')
  enterprise.actionKind = ''
  calls.length = 0
  enterprise.passwordText = 'must not reach an enterprise backend'
  enterprise.connectWithPassphrase(net.name, enterprise.passwordText)
  assertDeepEqual(enterprise.enterpriseEditor.command, ['nm-connection-editor', '--show', '--type=802-11-wireless'], name + ' reconfiguration selects from saved profiles without changing them')
  assertEqual(calls.length, 0, name + ' rejects stale PSK submissions')
  assertEqual(enterprise.passwordText, '', name + ' clears any obsolete inline secret before native setup')
}
for (const name of ['Sae', 'Wpa2Psk', 'WpaPsk', 'StaticWep']) {
  const net = networkFixture(name)
  enterprise.openPasswordPrompt(net.name)
  assertEqual(enterprise.passwordSsid, net.name, name + ' retains the inline passphrase prompt')
  enterprise.connectWithPassphrase(net.name, ' psk secret ')
  assertDeepEqual(calls, [['psk', ' psk secret ']], name + ' retains exact passphrase submission')
}
const reauth = source.match(/    function onConnectionFailed\(reason\) \{[^]*?\n    }/)
vm.runInContext(reauth[0], enterprise)
for (const reason of [1, 2]) {
  const net = networkFixture('Wpa2Eap', true)
  enterprise.connectDirectly(net.name)
  enterprise.onConnectionFailed(reason)
  assertDeepEqual(enterprise.enterpriseEditor.command, ['nm-connection-editor', '--show', '--type=802-11-wireless'], 'saved enterprise authentication failure ' + reason + ' opens the native editor')
  assertEqual(enterprise.passwordSsid, '', 'saved enterprise authentication failure ' + reason + ' does not collect a password')
}
const failedNet = networkFixture('Wpa2Eap')
enterprise.openPasswordPrompt(failedNet.name)
enterprise.enterpriseEditor.running = false
const editorSource = source.match(/  Process \{\n    id: enterpriseEditor[^]*?\n  }/)[0]
const failedStart = editorSource.match(/onRunningChanged: if \(!running\) Qt\.callLater\((function\(\) \{[^]*?\n    \})\)/)
vm.runInContext('editorFailedStart = ' + failedStart[1], enterprise)
enterprise.editorFailedStart()
assertEqual(enterprise.busy, false, 'a missing native editor releases the Wi-Fi action guard')
assertEqual(enterprise.failureSsid, failedNet.name, 'a missing native editor reports failure on its original row')
assertEqual(enterprise.failureReason, 'Install nm-connection-editor', 'a missing native editor produces actionable feedback')
assertEqual(enterprise.opened, true, 'a missing native editor leaves the panel visible')
enterprise.finishEnterpriseEditor(0)
assertEqual(enterprise.failureReason, 'Install nm-connection-editor', 'duplicate completion cannot erase a native-editor startup failure')
networkFixture('Wpa2Eap')
enterprise.wifiNetworkObjects = []
enterprise.openPasswordPrompt('vanished')
assertEqual(enterprise.enterpriseEditor.pendingResult, false, 'a vanished enterprise network cannot launch a stale setup request')
assert(!/enterpriseConnectScript|connectEnterprise|802-1x\.|nmcli connection (?:add|edit)|identityText|Identity \(user@domain\)/.test(source + fs.readFileSync(root + '/shell/plugins/panels/network/Model.js', 'utf8')), 'the panel contains no inline enterprise credential collection or profile creation path')
assert(!/stdinEnabled|write\(/.test(editorSource), 'the native editor process never receives credentials on stdin')

// Speed-test phases reuse one child, so completion has to drain both streams
// before upload or a new summon can start.
const speedSource = fs.readFileSync(root + '/shell/plugins/panels/speedtest/Panel.qml', 'utf8')
const deferred = []
const speed = { opened: true, requestSerial: 1, phase: 'down', pendingPhase: '', running: true, expectedStop: true, stderrText: '', error: '', Qt: { callLater: fn => deferred.push(fn) }, speedTestProc: { running: false, pendingResult: true, serial: 1, resultExited: true, outDone: false, errDone: false, code: 0, startConfirmed: true }, phaseTimer: { stop: () => {}, restart: () => {} } }
speed.root = speed
vm.createContext(speed)
for (const name of ['settleSpeedTest', 'finishPhase', 'pumpPhase', 'startPhase']) vm.runInContext(speedSource.match(new RegExp('  function ' + name + '\\([^]*?\\n  }'))[0], speed)
speed.settleSpeedTest()
assertEqual(speed.pendingPhase, '', 'exit alone cannot advance a speed-test phase')
speed.speedTestProc.outDone = speed.speedTestProc.errDone = true
speed.settleSpeedTest()
assertEqual(speed.pendingPhase, 'up', 'upload is queued only after both streams finish')
speed.opened = false
deferred.splice(0).forEach(fn => fn())
assertEqual(speed.speedTestProc.running, false, 'a queued upload cannot start after dismissal')
speed.opened = true
speed.pendingPhase = ''
speed.expectedStop = false
speed.running = true
speed.speedTestProc.pendingResult = true
speed.speedTestProc.startConfirmed = false
speed.speedTestProc.resultExited = speed.speedTestProc.outDone = speed.speedTestProc.errDone = false
const recovery = speedSource.slice(speedSource.indexOf('    id: speedTestProc')).match(/onRunningChanged: if \(!running\) Qt\.callLater\((function\(\) \{[^]*?\n    \})\)/)
vm.runInContext('recover = ' + recovery[1], speed)
speed.recover()
assertEqual(speed.running, false, 'a helper that cannot start releases the speed-test busy state')
assertEqual(speed.speedTestProc.pendingResult, false, 'failed startup settles without nonexistent exit or stream signals')
assertEqual(speed.error, 'Speed test failed', 'failed startup reaches visible speed-test feedback')
JS
