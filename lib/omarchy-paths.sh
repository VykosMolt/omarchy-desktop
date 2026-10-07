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

# A private preference must stay inside its owned directory, even when a
# directory or the destination is a symlink into the host's configuration.
omarchy_private_path() {
  local root=$1 path=$2 resolved_root lexical_root resolved
  lexical_root=$(realpath -ms -- "$root") || return 1
  resolved_root=$(realpath -m -- "$root") || return 1
  resolved=$(realpath -m -- "$path") || return 1
  if [[ $lexical_root != "$resolved_root" || $resolved != "$resolved_root"/* ]]; then
    echo "Refusing a preference outside its private directory: $path" >&2
    return 1
  fi
  printf '%s\n' "$resolved"
}

omarchy_write_private_file() {
  local root=$1 path temp
  path=$(omarchy_private_path "$root" "$2") || return 1
  mkdir -p -- "${path%/*}" || return 1
  temp=$(mktemp "$path.XXXXXX") || return 1
  if cat >"$temp" && mv -f -- "$temp" "$path"; then
    return 0
  fi
  rm -f -- "$temp"
  return 1
}

omarchy_kitty_config() {
  local host_config=${XDG_CONFIG_HOME:-$HOME/.config}
  if [[ $(realpath -m -- "$OMARCHY_SESSION_CONFIG_HOME") == "$(realpath -m -- "$host_config")" ]]; then
    echo "Omarchy requires a private session directory for Kitty settings." >&2
    return 1
  fi
  omarchy_private_path "$OMARCHY_SESSION_CONFIG_HOME" \
    "${KITTY_CONFIG_DIRECTORY:-$OMARCHY_SESSION_CONFIG_HOME/kitty}/kitty.conf"
}

# Runtime locks and handshakes must not fall back to predictable files directly
# in /tmp. Respect the session runtime directory, or create a private fallback
# under this session's cache when running from a stripped environment.
omarchy_runtime_dir() {
  local directory=${XDG_RUNTIME_DIR:-}
  local mode

  if [[ -n $directory ]]; then
    if [[ ! -d $directory || ! -O $directory || ! -w $directory ]]; then
      echo "Invalid session runtime directory: $directory" >&2
      return 1
    fi
    mode=$(stat -Lc '%a' -- "$directory") || return 1
    if (( (8#$mode & 0022) != 0 )); then
      echo "Session runtime directory is writable by other users: $directory" >&2
      return 1
    fi
  else
    directory="$OMARCHY_CACHE_HOME/runtime"
    if [[ -L $directory ]]; then
      echo "Refusing a symlink for the runtime directory: $directory" >&2
      return 1
    fi
    (umask 077; mkdir -p -- "$directory") || return 1
    [[ -O $directory ]] || return 1
    chmod 700 -- "$directory" || return 1
  fi

  printf '%s\n' "$directory"
}

# One rule for an argument that becomes a single component of one of those
# roots. omarchy-toggle, omarchy-hyprland-toggle, omarchy-state and omarchy-hook
# each join a caller-supplied name into a path they then write, delete or
# execute, and each did it unchecked: `omarchy-hook
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
