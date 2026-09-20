# Read and write one key in one section of an INI-style file, leaving every
# other line exactly as it was. The GTK, Qt and KDE configs the desktop has to
# touch are all this shape, and they belong to the user: a setter that rewrote
# the file would take their unrelated keys with it.
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
