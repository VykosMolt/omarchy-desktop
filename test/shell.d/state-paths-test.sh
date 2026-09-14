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

runtime_tmp=$(mktemp -d)
trap 'rm -rf "$runtime_tmp"' EXIT
source "$ROOT/lib/omarchy-paths.sh"
OMARCHY_CACHE_HOME="$runtime_tmp/cache"
unset XDG_RUNTIME_DIR
runtime=$(omarchy_runtime_dir)
[[ $runtime == "$OMARCHY_CACHE_HOME/runtime" && -d $runtime ]] || fail "runtime fallback is scoped to the session cache"
[[ $(stat -c %a "$runtime") == 700 ]] || fail "runtime fallback is private"
[[ $(omarchy_runtime_dir) == "$runtime" ]] || fail "runtime fallback is stable across calls"
pass "runtime fallback is private and stable"

mkdir "$runtime_tmp/session"
[[ $(XDG_RUNTIME_DIR="$runtime_tmp/session" omarchy_runtime_dir) == "$runtime_tmp/session" ]] || fail "runtime helper honors the session directory"
chmod 777 "$runtime_tmp/session"
if XDG_RUNTIME_DIR="$runtime_tmp/session" omarchy_runtime_dir >/dev/null 2>&1; then
  fail "runtime helper refuses a directory writable by other users"
fi
chmod 700 "$runtime_tmp/session"
if XDG_RUNTIME_DIR="$runtime_tmp/missing" omarchy_runtime_dir >/dev/null 2>&1; then
  fail "runtime helper refuses an invalid explicit directory"
fi
mkdir "$runtime_tmp/other-cache"
ln -s "$runtime_tmp/session" "$runtime_tmp/other-cache/runtime"
if OMARCHY_CACHE_HOME="$runtime_tmp/other-cache" omarchy_runtime_dir >/dev/null 2>&1; then
  fail "runtime fallback refuses symlinks"
fi
pass "runtime helper rejects invalid and redirected directories"
