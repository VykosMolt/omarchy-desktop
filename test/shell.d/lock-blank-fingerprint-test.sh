#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

run_node_test <<'JS'
const fs = require('fs')
const serviceQml = fs.readFileSync(path.join(root, 'shell/plugins/lock/Service.qml'), 'utf8')

// The fingerprint PAM stays armed for the whole lock waiting for a finger, so
// `authenticating` is true from lock until unlock on every machine with a
// reader enrolled. Gating the blank on it leaves the panel lit all night.
assert(
  /if \(root\.lockRequested && !root\.authenticatingPassword\) root\.runBlank\(\)/.test(serviceQml),
  'only a password check in flight stops the blank timer from blanking'
)

assert(
  !/idleBlankTimer[\s\S]*?!root\.authenticating\)/.test(serviceQml),
  'the blank timer never gates on the combined authenticating state'
)

assert(
  /onAuthenticatingPasswordChanged: \{\s*if \(!lockRequested\) return\s*if \(authenticatingPassword\) idleBlankTimer\.stop\(\)\s*else armBlankTimer\(\)/.test(serviceQml),
  'the blank timer is held off by password entry and re-armed when it finishes'
)

assert(
  !/onAuthenticatingChanged:/.test(serviceQml),
  'the combined authenticating state no longer drives the blank timer'
)

// The lock screen animates and plays a video. Decoding sixty frames a second
// into a panel that is switched off is battery for nothing.
const viewQml = fs.readFileSync(path.join(root, 'shell/plugins/lock/LockView.qml'), 'utf8')
const videoQml = fs.readFileSync(path.join(root, 'shell/plugins/lock/LockVideo.qml'), 'utf8')

assert(/displayBlanked = true/.test(serviceQml), 'blanking the display records that it is blanked')
assert(/displayBlanked = false/.test(serviceQml), 'waking it records that it is not')
assert(/paused: root\.displayBlanked/.test(serviceQml), 'the blanked display pauses the lock view')
assert(/running: root\.loadBackground && !root\.paused/.test(viewQml), 'the animations stop with the display')
assert(/player\.pause\(\)/.test(videoQml), 'so does the video')

// A lock screen is the one surface that has to come up. QtMultimedia is behind
// a Loader reached by URL, so a machine without it loses the video and keeps
// the password field.
assert(/import QtMultimedia/.test(videoQml), 'the video component is the one that imports QtMultimedia')
assert(!/import QtMultimedia/.test(viewQml), 'the lock view itself does not')
assert(/source: "LockVideo\.qml"/.test(viewQml), 'the video is loaded by URL so a load error is containable')
assert(/if \(status === Loader\.Error\) root\.videoFailed = true/.test(viewQml), 'a video that will not load falls back to the still background')

// Playback starts with the media. A play() issued before the source was bound
// left the player sitting on nothing and the still image up forever.
assert(/autoPlay: !root\.paused/.test(videoQml), 'playback starts with the media rather than from a completion handler')
assert(!/MediaPlayer\.NoMedia/.test(videoQml), 'a player with nothing loaded yet is not a failed one')
JS
