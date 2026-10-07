# Read or update one INI-style key while retaining neighbouring settings.
# Host GTK/Qt/KDE files are read-only defaults; desktop controls write through
# the confined private preference wrappers at the end of this file.
#
# Source lib/omarchy-paths.sh before this file.

omarchy_ini_get() {
  local file="$1"
  local section="$2"
  local key="$3"

  [[ -r $file ]] || return 1

  awk -v section="$section" -v key="$key" '
    /^[[:space:]]*\[/ {
      in_section = ($0 ~ "^[[:space:]]*\\[" section "\\][[:space:]]*$")
      next
    }
    in_section && index($0, key) == 1 {
      line = $0
      sub("^" key "[[:space:]]*=[[:space:]]*", "", line)
      if (line != $0) {
        print line
        exit
      }
    }
  ' "$file"
}

omarchy_ini_set() {
  local file="$1"
  local section="$2"
  local key="$3"
  local value="$4"
  local temp_file

  # A config kept in a dotfiles repo is a symlink; writing the file it points at
  # keeps the link, where replacing the link with a regular file would quietly
  # detach the user's config from the repo that manages it.
  if [[ -L $file ]]; then
    file=$(readlink -f "$file") || return 1
    [[ -n $file ]] || return 1
  fi

  mkdir -p "${file%/*}" || return 1
  temp_file=$(mktemp "$file.XXXXXX") || return 1

  if [[ -f $file ]]; then
    chmod --reference="$file" "$temp_file" 2>/dev/null
    awk -v section="$section" -v key="$key" -v value="$value" '
      /^[[:space:]]*\[/ {
        if (in_section && !done) {
          print key "=" value
          done = 1
        }
        in_section = ($0 ~ "^[[:space:]]*\\[" section "\\][[:space:]]*$")
        print
        next
      }
      in_section && index($0, key) == 1 && $0 ~ "^" key "[[:space:]]*=" {
        if (!done) {
          print key "=" value
          done = 1
        }
        next
      }
      { print }
      END {
        if (!done) {
          if (!in_section) print "[" section "]"
          print key "=" value
        }
      }
    ' "$file" >"$temp_file" || {
      rm -f "$temp_file"
      return 1
    }
  else
    printf '[%s]\n%s=%s\n' "$section" "$key" "$value" >"$temp_file" || {
      rm -f "$temp_file"
      return 1
    }
  fi

  mv -f "$temp_file" "$file"
}

# Desktop preferences belong to this session. Host toolkit files are useful
# read-only defaults, but a picker must never modify them.
omarchy_preference_get() {
  omarchy_ini_get "$OMARCHY_CONFIG_HOME/appearance.ini" "$1" "$2"
}

omarchy_preference_set() {
  local file lock preference_fd
  [[ $3 != *[[:cntrl:]]* ]] || return 1
  file=$(omarchy_private_path "$OMARCHY_CONFIG_HOME" "$OMARCHY_CONFIG_HOME/appearance.ini") || return 1
  lock=$(omarchy_private_path "$OMARCHY_CONFIG_HOME" "$OMARCHY_CONFIG_HOME/appearance.ini.lock") || return 1
  mkdir -p -- "$OMARCHY_CONFIG_HOME" || return 1
  exec {preference_fd}>"$lock" || return 1
  flock "$preference_fd" || return 1
  omarchy_ini_set "$file" "$1" "$2" "$3"
  local status=$?
  exec {preference_fd}>&-
  return "$status"
}
