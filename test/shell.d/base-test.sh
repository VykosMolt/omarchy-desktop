#!/bin/bash

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  echo "source test/shell.d/base-test.sh from a shell test; do not run it directly" >&2
  exit 1
fi

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
SHELL_TEST_DIR="$ROOT/test/shell.d"

export ROOT

# Tests redirect a command's state by handing it a throwaway HOME. That only
# works while nothing above HOME is already pointing somewhere real: the roots
# in lib/omarchy-paths.sh are derived from OMARCHY_*_HOME first and XDG_*_HOME
# second, and a test run from inside a live session inherits both. Left set,
# they send a test's writes into the session's own config and state -- which is
# how a fixture plugin and a fixture theme once landed in a real one. Drop them
# here so every suite starts from HOME and nothing it runs can escape the
# directory it was given.
# Every OMARCHY_* variable goes, not a fixed list: a session exports the unit
# names and OMARCHY_PATH too, and a test that forgets to set one should fail
# loudly rather than quietly pick up the live session's.
mapfile -t __inherited < <(compgen -e | grep '^OMARCHY_' || true)
(( ${#__inherited[@]} == 0 )) || unset "${__inherited[@]}"
unset __inherited
unset XDG_CONFIG_HOME XDG_STATE_HOME XDG_CACHE_HOME XDG_DATA_HOME

# Nothing here may draw on the user's screen. The shell's IPC reaches the
# running desktop over its own socket and ignores HOME, so the sandbox above
# does not cover it: a summon from a test lands on the real display.
export OMARCHY_NO_UI=1

# The session also puts this checkout's bin/ on PATH. Tests that want it say so;
# leaving it here lets a test that means to hide a command still find it.
# Dropping this checkout alone was not enough: any other Omarchy bin/ on PATH
# offers the same command names under different code, so a test that hides a
# command still finds one and a test that means to exercise this checkout runs
# the other's copy instead. Running the suite from a second worktree, with the
# first one's bin/ still on PATH, is all it takes -- theme-install-guards-test.sh
# hides omarchy-git-url-check to check that a missing checker refuses the URL,
# found the sibling's, and reported a failure this checkout did not have.
# An Omarchy bin/ holds nothing but omarchy commands, and that is what
# identifies one here: a system directory that merely happens to carry an
# omarchy command keeps its place rather than taking coreutils off PATH with it.
omarchy_test_is_omarchy_bin() {
  local dir=$1 entry found=1

  # Judge the directory by its executables only. Anything else that lands in
  # bin/ -- a __pycache__ from running python on a command, a README, an editor
  # swapfile -- used to disqualify the whole directory, which left the real
  # commands on PATH for every test meant to hide one. That failure is silent:
  # the suite still passes, it just stops testing what it says it tests. A
  # stray file should not be able to switch off the isolation.
  for entry in "$dir"/*; do
    [[ -f $entry && -x $entry ]] || continue
    [[ ${entry##*/} == omarchy* ]] || return 1
    found=0
  done

  return $found
}

__kept_path=()
while IFS= read -r __path_entry; do
  if ! omarchy_test_is_omarchy_bin "$__path_entry"; then
    __kept_path+=("$__path_entry")
  fi
done < <(printf '%s' "$PATH" | tr ':' '\n')
PATH=$(IFS=:; printf '%s' "${__kept_path[*]}")
export PATH
unset __kept_path __path_entry

# Unsetting the roots is not enough on its own. With them gone the roots are
# derived from HOME, so a test that forgets to hand a command a throwaway HOME
# falls back to the real one and writes into the live session anyway -- one run
# of this suite appended to a running desktop's monitor-scaling audit log that
# way. Give HOME itself a scratch directory, so the fallback is a sandbox rather
# than the user's session. The roots stay derived rather than pinned, so a test
# that sets its own HOME still gets roots under it.
OMARCHY_TEST_SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/omarchy-test.XXXXXX")
export OMARCHY_TEST_SANDBOX
export HOME="$OMARCHY_TEST_SANDBOX/home"
mkdir -p "$HOME"

omarchy_test_sandbox_cleanup() {
  [[ -n ${OMARCHY_TEST_SANDBOX:-} && -d $OMARCHY_TEST_SANDBOX ]] || return 0
  rm -rf "$OMARCHY_TEST_SANDBOX"
}
trap omarchy_test_sandbox_cleanup EXIT

# Bash keeps one EXIT trap, so a test installing its own -- and 74 of them do,
# to remove a scratch directory of their own -- silently replaced that cleanup
# and the sandbox stayed behind. Five hundred of them had piled up in /tmp.
# Intercepting the builtin here chains the sandbox cleanup onto whatever a test
# installs, rather than asking 74 files to remember, and keeps a new test
# correct by default.
trap() {
  if (( $# >= 2 )) && [[ ${*: -1} == EXIT ]]; then
    if [[ $1 == - ]]; then
      builtin trap omarchy_test_sandbox_cleanup EXIT
    else
      builtin trap "$1; omarchy_test_sandbox_cleanup" "${@:2}"
    fi
  else
    builtin trap "$@"
  fi
}

pass() {
  printf 'ok - %s\n' "$1"
}

fail() {
  local description="$1"
  local detail="${2:-}"

  [[ -n $detail ]] && printf '%s\n' "$detail" >&2
  printf 'not ok - %s\n' "$description" >&2
  exit 1
}

require_command() {
  local command="$1"

  command -v "$command" >/dev/null || fail "required command is available: $command"
}

# WAYLAND_DISPLAY proves the variable was inherited, not that the compositor
# answers. Sandboxes pass the environment through while blocking
# $XDG_RUNTIME_DIR, so Quickshell clears a bare variable check and then aborts
# inside QGuiApplication, before any QML loads: a core dump per launch where a
# skip belonged. Probe the socket, then Hyprland itself, since a compositor that
# died mid-session can leave its socket behind.
compositor_reachable() {
  local socket=${WAYLAND_DISPLAY:-}

  [[ -n $socket ]] || return 1
  [[ $socket == /* ]] || socket=${XDG_RUNTIME_DIR:-}/$socket
  [[ -S $socket ]] || return 1

  # A compositor that died can leave its socket behind, so ask Hyprland whether
  # it is still answering. Only when it can be asked: hyprctl needs
  # HYPRLAND_INSTANCE_SIGNATURE, and treating a missing signature as a dead
  # compositor would skip tests that would have run fine.
  [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]] || return 0

  # Hyprland can miss a query while it reconfigures outputs, and one miss is not
  # a dead compositor; retry the way omarchy-launch-shell does rather than
  # discard a whole file's runtime coverage. Only a leftover socket gets this
  # far, so the waiting is rare.
  local attempt
  for attempt in 1 2 3; do
    hyprctl -j monitors >/dev/null 2>&1 && return 0
    (( attempt < 3 )) && sleep 0.5
  done

  return 1
}

require_compositor() {
  local description="$1"

  if compositor_reachable; then
    # No probe outruns a compositor that dies mid-run, and Quickshell leaves
    # through qFatal() when its connection drops. Keep that abort from writing a
    # core; the test still fails, just without the debris.
    ulimit -c 0 2>/dev/null || true
    return 0
  fi

  pass "no Wayland compositor; skipping $description"
  exit 0
}

run_node_test() {
  require_command node

  {
    cat <<'JS_PRELUDE'
const path = require('path')
const root = process.env.ROOT

function fail(description, detail) {
  if (detail) console.error(detail)
  console.error(`not ok - ${description}`)
  process.exit(1)
}

function pass(description) {
  console.log(`ok - ${description}`)
}

function assert(condition, description, detail) {
  if (!condition) fail(description, detail)
  pass(description)
}

function assertEqual(actual, expected, description) {
  assert(
    actual === expected,
    description,
    `expected: ${expected}\nactual:   ${actual}`
  )
}

function assertDeepEqual(actual, expected, description) {
  const actualJson = JSON.stringify(actual)
  const expectedJson = JSON.stringify(expected)
  assert(
    actualJson === expectedJson,
    description,
    `expected: ${expectedJson}\nactual:   ${actualJson}`
  )
}

function requireFromRoot(relativePath) {
  return require(path.join(root, relativePath))
}

JS_PRELUDE
    cat
  } | node
}
