#!/bin/bash

set -euo pipefail

# The wallpaper rendered nothing for as long as this port has existed, and
# nothing caught it. Background.qml built its own path:
#
#   readonly property string stateHome: home + "/.local/state"
#   readonly property string currentBackgroundLink: stateHome + "/omarchy/current/background"
#
# That is stock Omarchy's location. The isolated session keeps state wherever
# OMARCHY_STATE_HOME points, so the lookup read a directory that does not exist,
# the Image had no source, and a transparent panel showed the compositor's fill.
# No error, no warning, and every geometry-based check still passed.
#
# Paths already resolves this correctly and every one of these files already
# imported it. Four had built the path by hand anyway: the wallpaper, the lock
# screen background, the image picker's fallback directory, and the bar watching
# the wrong current/ for theme changes.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

offenders=$(grep -rn '"/omarchy/current\|"/\.local/state\|"/\.config/omarchy' \
  "$ROOT/shell" --include='*.qml' --include='*.js' 2>/dev/null |
  grep -v 'Commons/Paths.qml' || true)

[[ -z $offenders ]] ||
  fail "no shell surface builds an Omarchy state or config path by hand" "$offenders"
pass "no shell surface builds an Omarchy state or config path by hand"

# Paths is the only place allowed to read the roots from the environment.
env_readers=$(grep -rln 'Quickshell.env("OMARCHY_\(STATE\|CONFIG\|CACHE\|DATA\)_HOME")' \
  "$ROOT/shell" --include='*.qml' --include='*.js' 2>/dev/null |
  grep -v 'Commons/Paths.qml' || true)

[[ -z $env_readers ]] ||
  fail "the state roots are read through Paths, not from the environment directly" "$env_readers"
pass "the state roots are read through Paths, not from the environment directly"

for f in shell/plugins/background/Background.qml shell/plugins/lock/Service.qml; do
  grep -q 'Paths.omarchyState' "$ROOT/$f" ||
    fail "$(basename "$(dirname "$f")")/$(basename "$f") resolves its background through Paths"
done
pass "the wallpaper and the lock screen both resolve their background through Paths"
