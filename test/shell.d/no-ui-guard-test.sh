#!/bin/bash

set -euo pipefail

# A sandboxed HOME does not stop a command from drawing on the real screen. The
# shell's IPC reaches the running desktop over its own socket and never consults
# HOME, so `omarchy-menu-select` summoning a chooser lands on the user's display
# whatever roots the caller set -- which is how a bare omarchy-menu-keybindings,
# run during development only to read what it did, left the keybindings chooser
# waiting on the user's screen behind their lock screen.
#
# OMARCHY_NO_UI=1 is what closes that, and both suites export it. This pins that
# every command which summons or toggles the shell honours it, and that the
# commands with a headless mode keep working under it.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_err=$(mktemp)
trap 'rm -f "$test_err"' EXIT

# Whatever summons or toggles the running shell must ask first. Discovered
# rather than listed, so a new one cannot be added without a guard.
mapfile -t summoners < <(
  grep -rln 'omarchy-shell shell \(summon\|toggle\)' "$ROOT/bin" |
    xargs -r -n1 basename | sort
)

(( ${#summoners[@]} > 0 )) || fail "the check found the commands that summon the shell"

for command in "${summoners[@]}"; do
  # omarchy-shell is the transport itself, not a command a user points at a menu.
  [[ $command == omarchy-shell ]] && continue
  grep -q 'omarchy_require_ui' "$ROOT/bin/$command" ||
    fail "$command asks omarchy_require_ui before it summons the shell"
done
pass "every command that summons the shell honours OMARCHY_NO_UI"

for command in omarchy-menu-select omarchy-menu omarchy-menu-emoji \
  omarchy-menu-clipboard omarchy-menu-input; do
  case "$command" in
    omarchy-menu-select) args=(Prompt option) ;;
    omarchy-menu-input) args=(Prompt) ;;
    *) args=() ;;
  esac

  if OMARCHY_NO_UI=1 OMARCHY_PATH="$ROOT" PATH="$ROOT/bin:$PATH" \
    "$ROOT/bin/$command" "${args[@]}" >/dev/null 2>"$test_err"; then
    fail "$command refuses to open a window under OMARCHY_NO_UI=1"
  fi

  grep -q 'OMARCHY_NO_UI' "$test_err" ||
    fail "$command says why it refused rather than failing silently"
done
pass "each one refuses under OMARCHY_NO_UI=1 and says why"

# A notification is not a window, but it lands on the user's screen just the
# same and goes over the session bus rather than through anything HOME can
# sandbox. The action that asked for it still succeeded, so this one is
# suppressed rather than failed -- a guard that made every caller exit non-zero
# would be switched off within the week.
if ! OMARCHY_NO_UI=1 OMARCHY_PATH="$ROOT" PATH="$ROOT/bin:$PATH" \
  "$ROOT/bin/omarchy-notification-send" "Headline" "Body" >/dev/null 2>"$test_err"; then
  fail "a suppressed notification does not fail the action that asked for it"
fi
grep -q 'OMARCHY_NO_UI' "$test_err" ||
  fail "omarchy-notification-send says why it did not notify"

# -p hands back the id of a toast a caller can update. There is no toast, so
# there is no id, and inventing one would have the caller replace a stranger's.
printed=$(OMARCHY_NO_UI=1 OMARCHY_PATH="$ROOT" PATH="$ROOT/bin:$PATH" \
  "$ROOT/bin/omarchy-notification-send" -p "Headline" 2>/dev/null)
[[ -z $printed ]] || fail "a suppressed notification has no id to print" "$printed"
pass "a notification is suppressed under OMARCHY_NO_UI=1 without failing its caller"

# This used to check that omarchy-reminder show, the one guarded command with a
# non-drawing mode, still worked under the guard -- a guard that broke the
# headless paths would just get switched off. Reminders are gone and every
# guarded command now does nothing but draw, so there is no such path left to
# protect. Restore an equivalent check if one gains one.

# The suites themselves run under it, so a test can never summon by accident.
for suite in "$ROOT/test/shell.d/base-test.sh" "$ROOT/test/cli"; do
  grep -q '^export OMARCHY_NO_UI=1$' "$suite" ||
    fail "$(basename "$suite") exports OMARCHY_NO_UI=1"
done
pass "both suites run under the guard"
