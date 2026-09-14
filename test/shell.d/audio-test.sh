#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

run_node_test <<'JS'
const audio = requireFromRoot('shell/plugins/panels/audio/Model.js')

assert(audio.isPlaybackStream({ isStream: true, isSink: true }), 'audio detects sink-backed playback streams')
assert(audio.isPlaybackStream({ isStream: true, type: 'Stream/Output/Audio' }), 'audio detects typed playback streams')
assert(!audio.isPlaybackStream({ isStream: false, isSink: true }), 'audio rejects non-stream playback nodes')
assert(audio.isAudioSource({ audio: {} }), 'audio detects nodes with audio as sources')
assert(audio.isAudioSource({ type: 'Audio/Source' }), 'audio detects typed source nodes')

assertEqual(audio.outputVolumeName(0, false), 'Silenced', 'audio labels silent output')
assertEqual(audio.outputVolumeName(0.9, false), 'Party mode', 'audio labels loud output')
assertEqual(audio.outputVolumeName(0.5, true), 'Muted', 'audio labels muted output')
assertEqual(audio.outputVolumeName(1, false), 'Concert hall', 'audio labels full output')
assertEqual(audio.outputVolumeName(1.3, false), 'Overdrive', 'audio labels output raised past 100%')
assertEqual(audio.outputVolumeName(2, false), 'Ear splitter', 'audio labels output at the raised ceiling')

assertEqual(audio.RAISED_MAXIMUM_VOLUME, 2, 'audio raised ceiling is 200%')
assertEqual(audio.maximumVolume(true), 2, 'audio raised maximum runs to 200%')
assertEqual(audio.maximumVolume(false), 1, 'audio maximum stops at 100% when not raised')
assertEqual(audio.maximumVolume(undefined), 1, 'audio maximum treats an unset switch as not raised')
assertEqual(audio.clampVolume(1.7, 2), 1.7, 'audio keeps a raised volume inside the raised ceiling')
assertEqual(audio.clampVolume(2.4, 2), 2, 'audio clamps to the raised ceiling')
assertEqual(audio.clampVolume(1.7, 1), 1, 'audio clamps to 100% when not raised')
assertEqual(audio.clampVolume(-0.2, 2), 0, 'audio clamps below zero')
assertEqual(audio.clampVolume('nope', 2), 0, 'audio treats a non-number as silence')
assertEqual(audio.clampVolume(0.5, 0), 0.5, 'audio falls back to a 100% ceiling for a bad maximum')

assertDeepEqual(audio.parseSinkAvailability('alsa_output\t1\nhdmi_output\t0\n'), { alsa_output: true, hdmi_output: false }, 'audio parses sink availability')
assertEqual(audio.friendlyDeviceLabel('Built-in Audio Speakers Output'), 'Speakers', 'audio cleans device labels')
assertEqual(
  audio.nodeLabel({ ready: true, properties: { 'node.nick': 'Built-in Audio Microphones Input' }, name: 'alsa_input' }),
  'Microphone',
  'audio chooses friendly node labels'
)

const headphones = { ready: true, name: 'bluez_output.airpods', properties: { 'device.product.name': 'AirPods Headphones' } }
assert(audio.isHeadphones(headphones), 'audio detects headphone devices')
assertEqual(audio.sinkGlyph(headphones), '󰋋', 'audio uses headphone sink glyph')
assert(audio.sourceGlyph({ ready: true, properties: { 'device.icon-name': 'camera-webcam' } }).length > 0, 'audio maps webcam source glyph')

assertEqual(audio.friendlyStreamLabel('spotify'), 'Spotify', 'audio normalizes known stream labels')
assert(audio.streamRepresentsMprisPlayer('Chromium', 'Chromium Browser'), 'audio matches related stream and MPRIS labels')

const players = [
  { identity: 'Spotify', canPlay: true, isPlaying: true, dbusName: 'org.mpris.MediaPlayer2.spotify' },
  { identity: 'Chromium', canPlay: true, isPlaying: false, dbusName: 'org.mpris.MediaPlayer2.chromium' }
]
const streams = [
  { ready: true, properties: { 'application.name': 'Chromium' } },
  { ready: true, properties: { 'application.name': 'audio-src' } }
]

assertEqual(audio.matchingMprisStreamLabel('Chromium', players), 'Chromium', 'audio finds matching MPRIS labels')
assertEqual(audio.unmatchedMprisStreamLabel('audio-src', players, streams), 'Spotify', 'audio uses unmatched MPRIS player for generic streams')
assertEqual(audio.streamLabel(streams[1], players, streams), 'Spotify', 'audio labels generic streams from MPRIS')
assert(audio.streamRepresentsPlayer(streams[1], players[0], players, streams), 'audio links generic streams to active player')
JS

run_node_test <<'JS'
const fs = require('fs')
const vm = require('vm')
const source = fs.readFileSync(root + '/shell/plugins/panels/audio/Panel.qml', 'utf8')
const state = { nodes: [{ id: 7 }] }
state.root = state
vm.createContext(state)
for (const name of ['nodeIds', 'nodeForId']) vm.runInContext(source.match(new RegExp('  function ' + name + '\\([^]*?\\n  }'))[0], state)
const snapshot = state.nodeIds(state.nodes)
state.nodes = []
assertDeepEqual(snapshot, [7], 'audio display snapshots contain primitive node IDs')
assertEqual(state.nodeForId(snapshot[0]), null, 'a removed PipeWire node resolves to no action before deferred repaint')
JS

# Exercise privilege selection with PTY/non-PTY stdin. Both escalation tools
# are stubs; no USB device or privileged operation is touched.
ROOT="$ROOT" python3 - <<'PYTHON'
import os, pty, subprocess, tempfile
from pathlib import Path
root = Path(os.environ["ROOT"])
source = (root / "bin/omarchy-restart-audio").read_text()
function = source.split("run_usb_reset() {", 1)[1].split("\n}\n", 1)[0]
script = "run_usb_reset() {" + function + "\n}\n" + 'run_usb_reset "1-2.3" "001/007"\n'
with tempfile.TemporaryDirectory() as directory:
    fixture = Path(directory)
    for command in ("sudo", "pkexec", "usbreset"):
        stub = fixture / command
        stub.write_text('#!/bin/bash\nprintf "%s\\n" "${0##*/}" "$@" >"$AUDIO_RESET_LOG"\n')
        stub.chmod(0o755)
    env = os.environ.copy()
    env.update(PATH=directory + ":" + env["PATH"], SCRIPT_PATH=str(root / "bin/omarchy-restart-audio"), AUDIO_RESET_LOG=str(fixture / "argv"))
    subprocess.run(["bash", "-c", script], input=b"", env=env, check=True)
    args = (fixture / "argv").read_text().splitlines()
    if os.geteuid() == 0:
        assert args == ["usbreset", "001/007"], args
    else:
        assert args == ["pkexec", str(root / "bin/omarchy-restart-audio"), "--reset-usb", "1-2.3"], args
        master, slave = pty.openpty()
        try:
            subprocess.run(["bash", "-c", script], stdin=slave, env=env, check=True)
        finally:
            os.close(master)
            os.close(slave)
        args = (fixture / "argv").read_text().splitlines()
        assert args == ["sudo", "--", str(root / "bin/omarchy-restart-audio"), "--reset-usb", "1-2.3"], args
    # Invalid internal requests must stop before any host discovery/reset.
    proc = subprocess.run([str(root / "bin/omarchy-restart-audio"), "--reset-usb", "../../other"], env=env, capture_output=True)
    assert proc.returncode != 0
PYTHON
pass "USB audio recovery chooses terminal or graphical escalation for one verified device"
