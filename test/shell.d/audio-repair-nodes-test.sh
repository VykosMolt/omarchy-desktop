#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command jq

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

stub_dir="$tmpdir/bin"
systemctl_log="$tmpdir/systemctl.log"
dump_file="$tmpdir/pw-dump.json"
mkdir -p "$stub_dir"

cat >"$stub_dir/pw-dump" <<'STUB'
#!/bin/bash
[[ -r $PW_DUMP_FILE ]] || exit 1
cat "$PW_DUMP_FILE"
STUB
chmod +x "$stub_dir/pw-dump"

cat >"$stub_dir/systemctl" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$SYSTEMCTL_LOG"
STUB
chmod +x "$stub_dir/systemctl"

cat >"$stub_dir/logger" <<'STUB'
#!/bin/bash
:
STUB
chmod +x "$stub_dir/logger"

run_repair() {
  : >"$systemctl_log"
  PW_DUMP_FILE="$dump_file" \
    SYSTEMCTL_LOG="$systemctl_log" \
    PATH="$stub_dir:$ROOT/bin:$PATH" \
    "$ROOT/bin/omarchy-audio-repair-nodes" "$@"
}

assert_no_restart() {
  [[ ! -s $systemctl_log ]] || fail "$1" "$(<"$systemctl_log")"
  pass "$1"
}

assert_restart() {
  [[ $(<"$systemctl_log") == "--user restart wireplumber.service" ]] || fail "$1" "$(<"$systemctl_log")"
  pass "$1"
}

# One card, one sink on it, one stream with no device: nothing to repair.
cat >"$dump_file" <<'JSON'
[
  { "id": 49, "type": "PipeWire:Interface:Device", "info": { "props": { "device.name": "alsa_card.pci" } } },
  { "id": 59, "type": "PipeWire:Interface:Node", "info": { "props": { "node.name": "alsa_output.pci.analog-stereo", "device.id": 49 } } },
  { "id": 142, "type": "PipeWire:Interface:Node", "info": { "props": { "node.name": "spotify" } } }
]
JSON
run_repair
assert_no_restart "repair leaves a consistent graph alone"
output=$(run_repair --check)
[[ $output == "No leaked audio nodes." ]] || fail "check reports a clean graph" "$output"
pass "check reports a clean graph"

# The card came back as 49 after the login screen; 59 still names the old 48.
cat >"$dump_file" <<'JSON'
[
  { "id": 49, "type": "PipeWire:Interface:Device", "info": { "props": { "device.name": "alsa_card.pci" } } },
  { "id": 59, "type": "PipeWire:Interface:Node", "info": { "props": { "node.name": "alsa_output.pci.analog-stereo", "device.id": 48 } } },
  { "id": 72, "type": "PipeWire:Interface:Node", "info": { "props": { "node.name": "alsa_output.pci.analog-stereo", "device.id": "50" } } },
  { "id": 124, "type": "PipeWire:Interface:Node", "info": { "props": { "node.name": "alsa_output.pci.analog-stereo", "device.id": 49 } } }
]
JSON
status=0
output=$(run_repair --check) || status=$?
(( status == 1 )) || fail "check exits 1 when nodes point at missing devices" "status $status"
pass "check exits 1 when nodes point at missing devices"
[[ $output == *"2 node(s)"* && $output == *$'59\talsa_output.pci.analog-stereo'* && $output == *$'72\t'* ]] ||
  fail "check lists the leaked nodes" "$output"
pass "check lists the leaked nodes"
assert_no_restart "check never restarts anything"

output=$(run_repair)
assert_restart "repair restarts WirePlumber when nodes point at missing devices"
[[ $output == *"2 leaked node(s)"* ]] || fail "repair says how many nodes it dropped" "$output"
pass "repair says how many nodes it dropped"

# No PipeWire to ask is nothing to repair, not an error.
rm -f "$dump_file"
run_repair
assert_no_restart "repair stays quiet without PipeWire"

status=0
run_repair --wat 2>/dev/null || status=$?
(( status == 1 )) || fail "repair rejects unknown arguments" "status $status"
pass "repair rejects unknown arguments"
