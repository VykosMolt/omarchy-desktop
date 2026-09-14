#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

run_node_test <<'JS'
const wifiqr = requireFromRoot('shell/plugins/panels/wifiqr/Model.js')

assertDeepEqual(
  wifiqr.parseQrOutput('meta\twlan0\tWPA\tCafe WiFi\n010\n111\n010\n'),
  { meta: { iface: 'wlan0', security: 'WPA', ssid: 'Cafe WiFi' }, matrix: { rows: ['010', '111', '010'], size: 3 } },
  'wifiqr parses the meta header and a square matrix'
)
assertDeepEqual(
  wifiqr.parseQrOutput('meta\twlan0\tnopass\tTab\tName\n010\n111\n010\n').meta.ssid,
  'Tab\tName',
  'wifiqr keeps tabs inside the SSID field'
)
assertDeepEqual(
  wifiqr.parseQrOutput('010\n111\n010\n'),
  { meta: { iface: '', security: '', ssid: '' }, matrix: { rows: ['010', '111', '010'], size: 3 } },
  'wifiqr tolerates output without a meta header'
)
assertDeepEqual(wifiqr.parseQrOutput('meta\twlan0\tWPA\tCafe\n01\n111\n').matrix, { rows: [], size: 0 }, 'wifiqr rejects ragged QR rows')
assertDeepEqual(wifiqr.parseQrOutput('010\n101\n').matrix, { rows: [], size: 0 }, 'wifiqr rejects a non-square QR matrix')
assertDeepEqual(wifiqr.parseQrOutput('010\n1x1\n010\n').matrix, { rows: [], size: 0 }, 'wifiqr rejects invalid QR modules')

// Run the actual panel completion functions with every event order, without
// connecting to NetworkManager or revealing any real wireless credentials.
const fs = require('fs')
const vm = require('vm')
const source = fs.readFileSync(root + '/shell/plugins/panels/wifiqr/Panel.qml', 'utf8')
function panelState() {
  const deferred = []
  const state = { requestSerial: 1, opened: true, pendingShow: false, pendingIface: '', qrSize: 0, qrRows: [], error: '', loading: true, iface: 'wlan0', ssid: '', password: '', passwordVisible: false, passwordError: '', Model: wifiqr,
    qrProc: { serial: 1, pendingResult: true, resultExited: false, outDone: false, errDone: false, output: '', errorOutput: '', exitCode: 0, running: false },
    pwProc: { serial: 1, pendingResult: true, resultExited: false, outDone: false, output: '', exitCode: 0, running: false },
    Qt: { callLater: fn => deferred.push(fn) }, deferred }
  state.root = state
  vm.createContext(state)
  for (const name of ['clearContents', 'close', 'generate', 'settleQr', 'updateQr', 'settlePassword']) {
    const fn = source.match(new RegExp('  function ' + name + '\\([^]*?\\n  }'))
    assert(fn, 'panel function is available for executable regression: ' + name)
    vm.runInContext(fn[0], state)
  }
  return state
}
for (const order of ['eos', 'eso', 'oes', 'ose', 'seo', 'soe']) {
  const state = panelState()
  for (const event of order) {
    if (event === 'e') state.qrProc.resultExited = true
    if (event === 'o') { state.qrProc.output = 'meta\twlan0\tWPA\tCafe\n01\n10\n'; state.qrProc.outDone = true }
    if (event === 's') state.qrProc.errDone = true
    state.settleQr()
  }
  assertEqual(state.qrSize, 2, 'QR succeeds regardless of exit and collector ordering: ' + order)
  assertEqual(state.error, '', 'no premature empty-output error: ' + order)
}
for (const order of ['eo', 'oe']) {
  const state = panelState()
  for (const event of order) {
    if (event === 'e') state.pwProc.resultExited = true
    else { state.pwProc.output = '  keep edge spaces  \n'; state.pwProc.outDone = true }
    state.settlePassword()
  }
  assertEqual(state.password, '  keep edge spaces  ', 'password whitespace survives: ' + order)
  assertEqual(state.passwordVisible, true, 'reveal waits for successful exit and output: ' + order)
}
const stale = panelState()
stale.close()
stale.opened = true
stale.pwProc.output = 'old secret\n'
stale.pwProc.outDone = stale.pwProc.resultExited = true
stale.settlePassword()
assertEqual(stale.password, '', 'a closed and reopened card rejects a previous password lookup')
const queued = panelState()
queued.pendingShow = true
queued.pendingIface = 'wlan1'
queued.qrProc.resultExited = queued.qrProc.outDone = queued.qrProc.errDone = true
queued.settleQr()
queued.close()
queued.deferred.forEach(fn => fn())
assertEqual(queued.qrProc.running, false, 'a queued replacement cannot start after dismissal')
assertEqual(queued.qrSize, 0, 'dismissal keeps the QR contents cleared')

JS
