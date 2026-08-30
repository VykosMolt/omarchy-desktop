#!/bin/bash

set -euo pipefail

# omarchy-dns used to own two files in /etc and rewrite every saved wifi and
# ethernet profile. That put a whole-file overwrite of
# /etc/systemd/resolved.conf -- no backup, taking any Domains=, DNSSEC= or
# search domain with it -- and a rewrite of fifteen unrelated NetworkManager
# profiles two clicks away in the network panel. What it may touch is the
# connections that are actually up, so that is what this pins: the connections
# it modifies, and the fact that nothing it runs goes near /etc.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
mkdir -p "$stub_bin"

# Two connections up, plus a bridge and loopback that are up but are not
# networks the user chose, plus three saved profiles for networks we are not on.
cat >"$stub_bin/nmcli" <<'STUB'
#!/bin/bash
if [[ "$*" == "-t -f UUID,TYPE connection show --active" ]]; then
  printf 'uuid-wifi:802-11-wireless\nuuid-eth:802-3-ethernet\nuuid-br:bridge\nuuid-lo:loopback\n'
  exit 0
fi
if [[ "$*" == "-t -f UUID,TYPE connection show" ]]; then
  printf 'uuid-wifi:802-11-wireless\nuuid-cafe:802-11-wireless\nuuid-office:802-3-ethernet\n'
  exit 0
fi
if [[ "$*" == "-t -f DEVICE,TYPE,STATE device status" ]]; then
  printf 'wlan0:wifi:connected\neth0:ethernet:connected\nwlan1:wifi:disconnected\n'
  exit 0
fi
if [[ $1 == -g ]]; then
  printf '%s\n' "${NMCLI_STUB_DNS:-}"
  exit 0
fi
printf '%s\n' "$*" >>"$NMCLI_LOG"
STUB
chmod +x "$stub_bin/nmcli"

export NMCLI_LOG="$test_tmp/nmcli.log"

run_dns() {
  : >"$NMCLI_LOG"
  PATH="$stub_bin:/usr/bin:/bin" OMARCHY_PATH="$ROOT" \
    bash "$ROOT/bin/omarchy-dns" "$@" >"$test_tmp/out" 2>&1
}

for provider in Cloudflare Google DHCP; do
  run_dns "$provider" || fail "omarchy-dns $provider succeeds against a stubbed NetworkManager"

  modified=$(grep -c '^connection modify ' "$NMCLI_LOG" || true)
  (( modified == 2 )) ||
    fail "omarchy-dns $provider modifies only the two connections that are up (modified $modified)"

  ! grep -qE 'uuid-(cafe|office|br|lo)' "$NMCLI_LOG" ||
    fail "omarchy-dns $provider leaves idle profiles, bridges and loopback alone"
done
pass "a provider change touches only the wifi and ethernet connections that are up"

run_dns Cloudflare
grep -q '^connection modify uuid-wifi ipv4.ignore-auto-dns yes ipv4.dns 1.1.1.1 1.0.0.1 ' "$NMCLI_LOG" ||
  fail "Cloudflare pins its servers and stops taking the network's"
pass "a named provider pins its servers on the live connections"

run_dns DHCP
grep -q '^connection modify uuid-wifi ipv4.ignore-auto-dns no ipv4.dns  ipv6' "$NMCLI_LOG" ||
  fail "DHCP goes back to taking the network's DNS rather than pinning an empty list"
pass "DHCP restores automatic DNS instead of pinning nothing"

grep -q '^device reapply wlan0$' "$NMCLI_LOG" && grep -q '^device reapply eth0$' "$NMCLI_LOG" ||
  fail "the change is applied to the connected devices"
! grep -q '^device reapply wlan1$' "$NMCLI_LOG" ||
  fail "a disconnected device is left alone"
pass "the change is reapplied to connected devices only"

# The read path classifies from what the connection actually pins.
for probe in "1.1.1.1,1.0.0.1|Cloudflare" "8.8.8.8,8.8.4.4|Google" "|DHCP" "192.168.1.1|Custom"; do
  NMCLI_STUB_DNS=${probe%%|*}
  want=${probe##*|}
  got=$(NMCLI_STUB_DNS="$NMCLI_STUB_DNS" PATH="$stub_bin:/usr/bin:/bin" bash "$ROOT/bin/omarchy-dns")
  [[ $got == "$want" ]] || fail "omarchy-dns reports $want for '${NMCLI_STUB_DNS}' (got '$got')"
done
pass "the reported provider comes from what the connection pins"

# The whole point: no path under /etc appears anywhere in the command.
! grep -vE '^[[:space:]]*#' "$ROOT/bin/omarchy-dns" | grep -q '/etc/' ||
  fail "omarchy-dns names no file under /etc outside its comments"
! grep -vE '^[[:space:]]*#' "$ROOT/bin/omarchy-dns" | grep -qE '(^|[^[:alnum:]_.-])(sudo|pkexec|tee)[[:space:]]' ||
  fail "omarchy-dns escalates through NetworkManager's polkit action, not sudo, pkexec or a root tee"
pass "omarchy-dns owns nothing in /etc and escalates nothing itself"
