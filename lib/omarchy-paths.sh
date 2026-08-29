# Shared path contract for Omarchy and the Arch port.
#
# Stock Omarchy behavior is preserved when OMARCHY_*_HOME variables are
# unset. The Arch port sets them only inside its dedicated session.

: "${OMARCHY_CONFIG_HOME:=${XDG_CONFIG_HOME:-$HOME/.config}/omarchy}"
: "${OMARCHY_STATE_HOME:=${XDG_STATE_HOME:-$HOME/.local/state}/omarchy}"
: "${OMARCHY_CACHE_HOME:=${XDG_CACHE_HOME:-$HOME/.cache}/omarchy}"
: "${OMARCHY_DATA_HOME:=${XDG_DATA_HOME:-$HOME/.local/share}/omarchy}"

export \
  OMARCHY_CONFIG_HOME \
  OMARCHY_STATE_HOME \
  OMARCHY_CACHE_HOME \
  OMARCHY_DATA_HOME
