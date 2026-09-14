#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command jq

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export OMARCHY_PATH="$ROOT"
export PATH="$tmp/stub-bin:$ROOT/bin:$PATH"
export OMARCHY_NET_SYSFS="$tmp/sys"

mkdir -p "$tmp/stub-bin" "$tmp/sys"

# A link the kernel calls a tunnel, one it calls wireless, and one it says
# nothing about -- which is what a plain ethernet port looks like in sysfs.
mkdir -p "$tmp/sys/wg0" "$tmp/sys/wlan0/wireless" "$tmp/sys/eth0" "$tmp/sys/tun0"
printf 'DEVTYPE=wireguard\nINTERFACE=wg0\n' >"$tmp/sys/wg0/uevent"
printf 'DEVTYPE=wlan\nINTERFACE=wlan0\n' >"$tmp/sys/wlan0/uevent"
printf 'INTERFACE=eth0\n' >"$tmp/sys/eth0/uevent"
printf '0x1002\n' >"$tmp/sys/tun0/tun_flags"

# ROUTE_DEV is what carries the internet, DEFAULT_DEV what the default route
# names. A VPN makes those differ, which is the case under test.
cat >"$tmp/stub-bin/ip" <<'STUB'
#!/bin/bash
case "$*" in
  "route get "*)
    [[ -n ${ROUTE_DEV:-} ]] && echo "1.1.1.1 dev $ROUTE_DEV table 200 src 10.0.0.2 uid 1000"
    ;;
  "route show default")
    [[ -n ${DEFAULT_DEV:-} ]] && echo "default via 192.168.1.1 dev $DEFAULT_DEV proto static metric 100"
    ;;
  "route show default dev "*)
    echo "default via 192.168.1.1 proto static metric 100"
    ;;
  "-j addr show "*)
    echo '[{"addr_info":[{"family":"inet","local":"192.168.1.100","prefixlen":24}]}]'
    ;;
esac
exit 0
STUB

cat >"$tmp/stub-bin/omarchy-notification-send" <<'STUB'
#!/bin/bash
exit 0
STUB

chmod +x "$tmp/stub-bin/ip" "$tmp/stub-bin/omarchy-notification-send"

network_type() {
  ROUTE_DEV="$1" DEFAULT_DEV="${2:-}" omarchy-network-status --type
}

# The bug this fixes: with a VPN up the internet route names the tunnel, and
# classifying "not wireless" as ethernet reported a Wi-Fi laptop as wired.
[[ $(network_type wg0 wlan0) == "wifi" ]] ||
  fail "a wireguard tunnel over Wi-Fi reports the Wi-Fi underneath it"
pass "a wireguard tunnel over Wi-Fi reports the Wi-Fi underneath it"

[[ $(network_type tun0 wlan0) == "wifi" ]] ||
  fail "a tun device over Wi-Fi reports the Wi-Fi underneath it"
pass "a tun device over Wi-Fi reports the Wi-Fi underneath it"

[[ $(network_type wg0 eth0) == "ethernet" ]] ||
  fail "a tunnel over a wired link still reports ethernet"
pass "a tunnel over a wired link still reports ethernet"

# No physical default route to credit: saying "vpn" is honest where the old
# code said "ethernet" about a WireGuard interface.
[[ $(network_type wg0) == "vpn" ]] ||
  fail "a tunnel with no link under it reports itself as a VPN"
pass "a tunnel with no link under it reports itself as a VPN"

[[ $(network_type wlan0 wlan0) == "wifi" ]] || fail "plain Wi-Fi is unchanged"
pass "plain Wi-Fi is unchanged"

[[ $(network_type eth0 eth0) == "ethernet" ]] || fail "plain ethernet is unchanged"
pass "plain ethernet is unchanged"

[[ $(network_type "" "") == "disconnected" ]] || fail "no route reports disconnected"
pass "no route reports disconnected"

status_line=$(ROUTE_DEV=wg0 omarchy-network-status)
[[ $status_line == $'vpn\twg0\t\t' ]] ||
  fail "the status line names a bare tunnel as a VPN" "got: $(printf '%q' "$status_line")"
pass "the status line names a bare tunnel as a VPN"

# The address block describes the link, not the tunnel: a /32 with no gateway
# says nothing about the network the machine is on.
verbose=$(ROUTE_DEV=wg0 DEFAULT_DEV=wlan0 omarchy-network-status --verbose)
grep -qx $'iface\twlan0' <<<"$verbose" || fail "verbose output names the underlying link"
grep -qx $'ip\t192.168.1.100' <<<"$verbose" || fail "verbose output carries the link's own address"
grep -qx $'gateway\t192.168.1.1' <<<"$verbose" || fail "verbose output carries the link's own gateway"
pass "verbose output describes the link rather than the tunnel"

# VPN status, against a stubbed daemon.
write_mullvad_stub() {
  cat >"$tmp/stub-bin/mullvad" <<STUB
#!/bin/bash
if [[ \$1 == "status" ]]; then
  cat <<'JSON'
$1
JSON
  exit 0
fi
printf '%s\n' "\$*" >>"$tmp/mullvad-calls"
exit 0
STUB
  chmod +x "$tmp/stub-bin/mullvad"
}

write_mullvad_stub '{"state":"connected","details":{"endpoint":{"tunnel_interface":"wg0-mullvad"},"location":{"hostname":"il-tlv-wg-103","city":"Tel Aviv","country":"Israel"}}}'

vpn_status=$(omarchy-network-vpn-status)
grep -qx $'backend\tmullvad' <<<"$vpn_status" || fail "a mullvad daemon is reported as the backend"
grep -qx $'active\ttrue' <<<"$vpn_status" || fail "a connected tunnel reports active"
grep -qx $'busy\tfalse' <<<"$vpn_status" || fail "a settled tunnel is not busy"
grep -qx $'name\til-tlv-wg-103' <<<"$vpn_status" || fail "the relay hostname is reported"
grep -qx $'location\tTel Aviv, Israel' <<<"$vpn_status" || fail "the exit location is reported"
pass "a connected VPN reports its relay and location"

write_mullvad_stub '{"state":"disconnected"}'
vpn_status=$(omarchy-network-vpn-status)
grep -qx $'active\tfalse' <<<"$vpn_status" || fail "a disconnected VPN is not active"
grep -qx $'backend\tmullvad' <<<"$vpn_status" ||
  fail "a disconnected daemon still owns the backend, so the switch stays on screen"
pass "a disconnected VPN keeps its switch on screen"

write_mullvad_stub '{"state":"connecting","details":{"endpoint":{"tunnel_interface":"wg0-mullvad"}}}'
vpn_status=$(omarchy-network-vpn-status)
grep -qx $'busy\ttrue' <<<"$vpn_status" || fail "a VPN mid-handshake reports busy"
grep -qx $'active\tfalse' <<<"$vpn_status" || fail "a VPN mid-handshake is not yet active"
pass "a VPN mid-handshake reports busy rather than connected"

# Removing the stub is not enough to make the daemon absent: this machine may
# have a real one on PATH, and these cases would then run against a live VPN.
rm -f "$tmp/stub-bin/mullvad"
mkdir -p "$tmp/slim-bin"
ln -sf "$(command -v jq)" "$tmp/slim-bin/jq"

without_mullvad() {
  PATH="$tmp/stub-bin:$ROOT/bin:$tmp/slim-bin" "$@"
}

without_mullvad command -v mullvad >/dev/null &&
  fail "the slim PATH hides a real daemon"
pass "the slim PATH hides a real daemon"

vpn_status=$(without_mullvad omarchy-network-vpn-status)
grep -qx $'backend\tnone' <<<"$vpn_status" || fail "no daemon reports nothing to show"
grep -qx $'active\tfalse' <<<"$vpn_status" || fail "no daemon is not active"
pass "no VPN reports nothing to show"

without_mullvad omarchy-network-vpn-toggle >/dev/null 2>&1 &&
  fail "toggling without a daemon fails rather than doing nothing quietly"
pass "toggling without a daemon fails loudly"

# Toggle direction, read back from what the stub was asked to do.
: >"$tmp/mullvad-calls"
write_mullvad_stub '{"state":"connected","details":{}}'
omarchy-network-vpn-toggle >/dev/null
grep -qx 'disconnect' "$tmp/mullvad-calls" || fail "a connected VPN toggles off"
pass "a connected VPN toggles off"

: >"$tmp/mullvad-calls"
write_mullvad_stub '{"state":"disconnected"}'
omarchy-network-vpn-toggle >/dev/null
grep -qx 'connect' "$tmp/mullvad-calls" || fail "a disconnected VPN toggles on"
pass "a disconnected VPN toggles on"

# Mid-handshake counts as on, so a second click backs out rather than re-asking
# for the connect that is already running.
: >"$tmp/mullvad-calls"
write_mullvad_stub '{"state":"connecting","details":{}}'
omarchy-network-vpn-toggle >/dev/null
grep -qx 'disconnect' "$tmp/mullvad-calls" || fail "a connecting VPN toggles off"
pass "a connecting VPN toggles off"

: >"$tmp/mullvad-calls"
write_mullvad_stub '{"state":"connected","details":{}}'
omarchy-network-vpn-toggle on >/dev/null
grep -qx 'connect' "$tmp/mullvad-calls" || fail "an explicit on connects regardless of state"
pass "an explicit direction overrides the current state"

run_node_test <<'JS'
const fs = require('fs')
const network = requireFromRoot('shell/plugins/panels/network/Model.js')
const panelSource = fs.readFileSync(root + '/shell/plugins/panels/network/Panel.qml', 'utf8')

const connected = network.parseVpnStatus(
  'backend\tmullvad\nstate\tconnected\nactive\ttrue\nbusy\tfalse\n' +
  'iface\twg0-mullvad\nname\til-tlv-wg-103\nlocation\tTel Aviv, Israel\n'
)

assert(connected.active === true && connected.busy === false, 'network parses VPN booleans as booleans')
assertEqual(network.vpnStatusLabel(connected), 'TEL AVIV, ISRAEL', 'network labels a connected VPN with where it surfaces')
assertEqual(network.vpnTooltip(connected), 'Disconnect from il-tlv-wg-103', 'network names the relay in the switch tooltip')

const off = network.parseVpnStatus('backend\tmullvad\nstate\tdisconnected\nactive\tfalse\nbusy\tfalse\n')
assertEqual(network.vpnStatusLabel(off), 'OFF', 'network labels a disconnected VPN off')
assertEqual(network.vpnTooltip(off), 'Turn VPN on', 'network offers to turn a disconnected VPN on')

const connecting = network.parseVpnStatus('backend\tmullvad\nstate\tconnecting\nactive\tfalse\nbusy\ttrue\n')
assertEqual(network.vpnStatusLabel(connecting), 'CONNECTING', 'network labels a VPN mid-handshake')

// The panel starts with no status at all and must not throw laying out.
assertEqual(network.vpnStatusLabel({}), 'OFF', 'network labels an unread VPN status off')

// The bar is driven by the native NetworkManager service and polls nothing. A
// VPN poll left running behind a closed panel would put a subprocess every
// 1.5s behind a bar that is only showing an icon.
const vpnPoll = panelSource.match(/id: vpnPoll[\s\S]*?\n {2}\}/)
assert(vpnPoll, 'network has a VPN poll timer')
assert(/running: root\.opened/.test(vpnPoll[0]), 'network only polls VPN status while its panel is open')

// The hold spans the click and the request that confirms it. Releasing it on a
// poll that landed first would flip the switch back for a tick.
const updateFn = panelSource.match(/function updateVpn\(raw\) \{[\s\S]*?\n {2}\}/)
assert(updateFn, 'network has a VPN status handler')
assert(
  /vpnPending && !vpnActionProc\.running/.test(updateFn[0]),
  'network holds the VPN switch until the toggle request itself has returned'
)

const toggleFn = panelSource.match(/function toggleVpn\(\) \{[\s\S]*?\n {2}\}/)
assert(toggleFn, 'network has a VPN toggle function')
assert(/vpnPending = true/.test(toggleFn[0]), 'network marks the VPN switch busy on click')
assert(/if \(!vpnAvailable \|\| vpnBusy\) return/.test(toggleFn[0]), 'network ignores a second click while the VPN is moving')
JS
