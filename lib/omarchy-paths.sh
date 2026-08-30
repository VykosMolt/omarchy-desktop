# Shared path contract for Omarchy and the Arch port.
#
# Stock Omarchy behavior is preserved when OMARCHY_*_HOME variables are
# unset. The Arch port sets them only inside its dedicated session.

: "${OMARCHY_SESSION_CONFIG_HOME:=${XDG_CONFIG_HOME:-$HOME/.config}}"
: "${OMARCHY_SESSION_STATE_HOME:=${XDG_STATE_HOME:-$HOME/.local/state}}"
: "${OMARCHY_SESSION_CACHE_HOME:=${XDG_CACHE_HOME:-$HOME/.cache}}"
: "${OMARCHY_SESSION_DATA_HOME:=${XDG_DATA_HOME:-$HOME/.local/share}}"

: "${OMARCHY_CONFIG_HOME:=$OMARCHY_SESSION_CONFIG_HOME/omarchy}"
: "${OMARCHY_STATE_HOME:=$OMARCHY_SESSION_STATE_HOME/omarchy}"
: "${OMARCHY_CACHE_HOME:=$OMARCHY_SESSION_CACHE_HOME/omarchy}"
: "${OMARCHY_DATA_HOME:=$OMARCHY_SESSION_DATA_HOME/omarchy}"

export \
  OMARCHY_SESSION_CONFIG_HOME \
  OMARCHY_SESSION_STATE_HOME \
  OMARCHY_SESSION_CACHE_HOME \
  OMARCHY_SESSION_DATA_HOME \
  OMARCHY_CONFIG_HOME \
  OMARCHY_STATE_HOME \
  OMARCHY_CACHE_HOME \
  OMARCHY_DATA_HOME

# One rule for an argument that becomes a single component of one of those
# roots. omarchy-toggle, omarchy-hyprland-toggle, omarchy-state, omarchy-hook
# and omarchy-done each join a caller-supplied name into a path they then write,
# delete or execute, and four of them did it unchecked: `omarchy-hook
# ../../../../pwned` ran a script four directories above the hooks directory,
# `omarchy-hyprland-toggle ../../../../../victim off` deleted a .lua file five
# above the toggles one, and `omarchy-toggle`/`omarchy-state` created files
# outside the state root. A name holding no slash cannot climb at all, and `.`
# and `..` are the only slashless names that reach a directory rather than a
# file inside it -- `...` and `..foo` are ordinary filenames and stay legal, as
# do the glob characters omarchy-state's clear pattern needs.
omarchy_require_flat_name() {
  local name=$1 label=${2:-name}

  if [[ -z $name || $name == */* || $name == "." || $name == ".." ]]; then
    echo "Invalid $label: $name" >&2
    return 1
  fi
}

# Set OMARCHY_NO_UI=1 to make anything that would put a window on the user's
# screen refuse instead of drawing it.
#
# A sandboxed HOME does not stop this. The shell's IPC reaches the running
# desktop over its own socket and never consults HOME, so a command that summons
# a menu draws on the real screen no matter what roots the caller set. During
# this port's development a bare `omarchy-menu-keybindings` -- run only to read
# what it does -- put the keybindings chooser on the user's screen, where it sat
# waiting behind the lock screen until they logged back in. The test suites
# export this, and anything analysing a live session should too.
omarchy_require_ui() {
  if [[ ${OMARCHY_NO_UI:-0} == 1 ]]; then
    echo "${0##*/}: refusing to open a window because OMARCHY_NO_UI=1 is set." >&2
    return 1
  fi
}
