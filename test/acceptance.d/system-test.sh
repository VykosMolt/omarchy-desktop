#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"
source "${OMARCHY_PATH:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)}/lib/omarchy-paths.sh"

status=0

# This checks that the desktop this repository ships is in working order. It
# does not check how the machine underneath it was provisioned: this is a
# session that runs on an existing Arch install, so which packages are present,
# which browser opened last, and how CUPS or Docker are configured are the
# user's business and not something the session arranges or may assert.

verify_defaults() {
  # Which programs these resolve to is the user's choice. That they resolve at
  # all is not: the menu and half the bar widgets shell out to them.
  [[ -n $(omarchy-default-terminal) ]] || fail "a default terminal is configured"
  [[ -n $(omarchy-default-editor) ]] || fail "a default editor is configured"
  [[ -n $(omarchy-default-browser) ]] || fail "a default browser is configured"
  pass "the default terminal, editor and browser all resolve"

  [[ $(omarchy-theme-current) != "Unknown" ]] || fail "a current theme is configured"
  [[ $(omarchy-theme-bg-current) != "Unknown" ]] || fail "a current background is configured"
  [[ -n $(omarchy-font-current) ]] || fail "a monospace font is configured"
  pass "a theme, background and font are configured"
}

verify_services() {
  # Only what the desktop itself talks to. NetworkManager and the audio stack
  # back bar widgets directly, so a widget is dead without them.
  systemctl is-active --quiet NetworkManager.service ||
    fail "NetworkManager is running" "the network widget reads it directly"
  pass "NetworkManager is running"

  systemctl --user is-active --quiet pipewire.service pipewire-pulse.service wireplumber.service ||
    fail "user audio services are running"
  pass "user audio services are running"
}

verify_session_state() {
  local directory

  for directory in DESKTOP DOCUMENTS DOWNLOAD PICTURES; do
    [[ -d $(xdg-user-dir "$directory") ]] || fail "XDG user directories exist" "$directory is missing"
  done
  pass "XDG user directories exist"

  # The isolated roots, not ~/.config/omarchy and ~/.local/state/omarchy. This
  # session keeps its own config, state, cache and data so it can run beside
  # another Hyprland session without either overwriting the other.
  [[ -e $OMARCHY_STATE_HOME/current/theme ]] || fail "current theme state exists" "$OMARCHY_STATE_HOME/current/theme"
  [[ -e $OMARCHY_STATE_HOME/current/background ]] || fail "current background state exists" "$OMARCHY_STATE_HOME/current/background"
  [[ -s $OMARCHY_CONFIG_HOME/shell.json ]] || fail "shell configuration exists" "$OMARCHY_CONFIG_HOME/shell.json"
  jq empty "$OMARCHY_CONFIG_HOME/shell.json" || fail "shell configuration is valid JSON"
  pass "session state and shell configuration live under the isolated roots"
}

for check in verify_defaults verify_services verify_session_state; do
  if ! ("$check"); then
    status=1
  fi
done

exit $status
