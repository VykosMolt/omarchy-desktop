#!/bin/bash

# Resolve the icon names the launcher asks for, printing one path per line in
# the order the names were given. Names that resolve to nothing are skipped.
#
# This replaced a full traversal of every icon root: 227,100 files and 413ms on
# a machine whose launcher wanted 153 names, piped line by line into a QML
# parser that discarded almost all of it. The icon theme specification already
# has each theme list its own directories in index.theme, so the tree does not
# have to be rediscovered by walking it.
#
# Ranking happens per theme and never across themes. The configured theme
# outranks hicolor whatever sizes each ships: rank the two together and
# hicolor's scalable/ beats Papirus's 128x128/, which is how the launcher came
# to show one theme's artwork while another was configured.

set -uo pipefail

# Every argument is an icon name to resolve.
(( $# )) || exit 0

theme=$(omarchy-icon-theme 2>/dev/null)
[[ -n $theme ]] || theme=hicolor

roots=("$HOME/.icons" "$HOME/.local/share/icons")
IFS=":" read -ra data_dirs <<<"${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
for d in "${data_dirs[@]}"; do roots+=("$d/icons"); done

dirs=()

add_theme() {
  local name=$1 base index line rel_line d
  local -a rel found=()

  for base in "${roots[@]}"; do
    [[ -d $base/$name ]] || continue
    index="$base/$name/index.theme"

    if [[ -r $index ]]; then
      # Directories= holds the ordinary sizes; the spec puts the @2x variants
      # under ScaledDirectories=, and Papirus ships plenty of them. Reading only
      # the first key would silently drop the higher-resolution artwork.
      while IFS= read -r line; do
        case $line in
          Directories=*) rel_line=${line#Directories=} ;;
          ScaledDirectories=*) rel_line=${line#ScaledDirectories=} ;;
          *) continue ;;
        esac
        IFS="," read -ra rel <<<"$rel_line"
        for d in "${rel[@]}"; do
          [[ $d == */apps || $d == */devices || $d == apps || $d == devices ]] || continue
          found+=("$base/$name/$d")
        done
      done <"$index"
    else
      # A theme that does not list its directories still has to be found: the
      # user-local hicolor tree, where Steam drops its game icons, ships no
      # index.theme. Those trees are small, so walking them costs little.
      while IFS= read -r d; do
        found+=("$d")
      done < <(find -L "$base/$name" -mindepth 1 -maxdepth 3 -type d \
        \( -name apps -o -name devices \) 2>/dev/null)
    fi
  done

  (( ${#found[@]} )) || return 0

  # scalable first, then by the pixels a directory actually draws: 32x32@2x
  # holds 64px of artwork, so it outranks 32x32 rather than tying with it and
  # letting directory order decide.
  while IFS= read -r d; do
    dirs+=("$d")
  done < <(printf '%s\n' "${found[@]}" | awk '{
    path = $0
    rank = 0
    if (path ~ /\/scalable\//) {
      rank = 999999
    } else if (match(path, /\/([0-9]+)x[0-9]+(@([0-9]+)x)?\//, m)) {
      rank = m[1] * (m[3] == "" ? 1 : m[3])
    }
    printf "%d\t%s\n", rank, path
  }' | sort -rn -s -k1,1 | cut -f2-)
}

add_theme "$theme"
[[ $theme == hicolor ]] || add_theme hicolor
dirs+=(/usr/share/pixmaps)

for name in "$@"; do
  for dir in "${dirs[@]}"; do
    for ext in svg png; do
      if [[ -f $dir/$name.$ext ]]; then
        printf '%s\n' "$dir/$name.$ext"
        continue 3
      fi
    done
  done
done

exit 0
