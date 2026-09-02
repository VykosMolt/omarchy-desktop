#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command jq

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

stub_dir="$tmpdir/bin"
config_home="$tmpdir/omarchy"
state_file="$tmpdir/pactl-state"
osd_log="$tmpdir/osd.log"
mkdir -p "$stub_dir" "$config_home"

# pactl reads and writes one number in a file; get-sink-volume prints the
# line shape the script parses, set-sink-volume records the percentage it
# was handed.
cat >"$stub_dir/pactl" <<'STUB'
#!/bin/bash
case $1 in
  get-sink-volume)
    percent=$(<"$PACTL_STATE")
    printf 'Volume: front-left: 65536 / %s%% / 0.00 dB,   front-right: 65536 / %s%% / 0.00 dB\n' "$percent" "$percent"
    ;;
  set-sink-volume)
    printf '%s\n' "${3%\%}" >"$PACTL_STATE"
    ;;
  get-sink-mute) echo "Mute: no" ;;
  set-sink-mute) : ;;
esac
STUB
chmod +x "$stub_dir/pactl"

cat >"$stub_dir/omarchy-audio-output-sink" <<'STUB'
#!/bin/bash
echo alsa_output.test.analog-stereo
STUB
chmod +x "$stub_dir/omarchy-audio-output-sink"

cat >"$stub_dir/omarchy-osd" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$OSD_LOG"
STUB
chmod +x "$stub_dir/omarchy-osd"

write_config() {
  local entry=$1
  cat >"$config_home/shell.json" <<JSON
{
  "version": 1,
  "bar": { "layout": { "left": [], "center": [], "right": [ $entry ] } },
  "plugins": []
}
JSON
}

run_volume() {
  : >"$osd_log"
  OMARCHY_PATH="$ROOT" \
    OMARCHY_CONFIG_HOME="$config_home" \
    PACTL_STATE="$state_file" \
    OSD_LOG="$osd_log" \
    PATH="$stub_dir:$ROOT/bin:$PATH" \
    "$ROOT/bin/omarchy-audio-output-volume" "$@"
}

assert_volume() {
  local expected=$1 description=$2
  [[ $(<"$state_file") == "$expected" ]] || fail "$description" "expected $expected, got $(<"$state_file")"
  pass "$description"
}

assert_osd_max() {
  local expected=$1 description=$2
  [[ $(<"$osd_log") == *"-x $expected"* ]] || fail "$description" "$(<"$osd_log")"
  pass "$description"
}

# The audio panel's switch is on unless it has been turned off, so an entry
# that never mentions it, and no config at all, both raise the ceiling.
rm -f "$config_home/shell.json"
echo 95 >"$state_file"
run_volume +10
assert_volume 105 "volume keys run past 100% with no shell.json"
assert_osd_max 200 "OSD draws on a 200% bar with no shell.json"

write_config '{ "id": "omarchy.audio" }'
echo 95 >"$state_file"
run_volume +10
assert_volume 105 "volume keys run past 100% when the panel entry leaves the switch alone"

write_config '{ "id": "omarchy.audio", "raiseMaximumVolume": true }'
echo 195 >"$state_file"
run_volume raise
assert_volume 200 "volume keys stop at the 200% ceiling"
assert_osd_max 200 "OSD draws on a 200% bar when raised"

echo 200 >"$state_file"
run_volume lower
assert_volume 195 "volume keys step down from the ceiling"

write_config '{ "id": "omarchy.audio", "raiseMaximumVolume": false }'
echo 95 >"$state_file"
run_volume +10
assert_volume 100 "volume keys stop at 100% when the switch is off"
assert_osd_max 100 "OSD draws on a 100% bar when the switch is off"

# Absent from the layout but present under plugins still counts as the panel's entry.
cat >"$config_home/shell.json" <<'JSON'
{ "version": 1, "bar": { "layout": { "left": [], "center": [], "right": [] } }, "plugins": [ { "id": "omarchy.audio", "raiseMaximumVolume": false } ] }
JSON
echo 98 >"$state_file"
run_volume +5
assert_volume 100 "volume keys honour the switch from the plugins list"

echo 3 >"$state_file"
run_volume -5
assert_volume 0 "volume keys stop at zero"
