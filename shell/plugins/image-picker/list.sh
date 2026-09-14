#!/bin/bash

source "$OMARCHY_PATH/lib/omarchy-paths.sh" || exit 1

image_dirs=${1:-}
cache_dir="$OMARCHY_CACHE_HOME/image-selector"

thumbnail_for() {
  local image="$1"
  local signature hash thumbnail

  signature=$(stat -Lc '%s:%Y' "$image") || return
  hash=$(printf '%s\t%s' "$image" "$signature" | md5sum | cut -d ' ' -f 1)

  thumbnail="$cache_dir/$hash.jpg"

  if [[ -f $thumbnail ]]; then
    printf '%s' "$thumbnail"
  else
    printf '%s' "$image"
  fi
}

while IFS= read -r dir; do
  [[ -n $dir && -d $dir ]] || continue
  find -L "$dir" -maxdepth 1 -type f \
    \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.gif' -o -iname '*.bmp' -o -iname '*.webp' \) \
    -print0 2>/dev/null
done <<<"$image_dirs" | sort -z | while IFS= read -r -d '' image; do
  thumbnail=$(thumbnail_for "$image")
  [[ -n $thumbnail ]] || continue
  printf '%s\t%s\n' "$image" "$thumbnail"
done
