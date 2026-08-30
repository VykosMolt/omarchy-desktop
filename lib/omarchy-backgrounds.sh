# Which directories the background pickers scan, shared so the switcher and the
# thumbnail warmer always ask for the same list. omarchy-menu-images keys its
# row cache on the exact directory list it is given, so a warmer that scanned a
# different list would fill a cache the switcher never reads.
#
# Source lib/omarchy-paths.sh before this file.

# omarchy-menu-images scans one level, so a registered folder contributes its
# subdirectories too. Bounded so pointing the picker at a home directory stays
# a picker: three levels below the folder, and hidden trees are never entered.
OMARCHY_BACKGROUND_DIR_MAX_DEPTH=3

omarchy_background_dirs() {
  local theme_name dir

  theme_name=$(cat "$OMARCHY_STATE_HOME/current/theme.name" 2>/dev/null)

  {
    # The theme's own backgrounds stay first, so a theme's wallpapers keep the
    # top of the grid however many folders the user has registered.
    printf '%s\n' "$OMARCHY_STATE_HOME/current/theme/backgrounds"
    printf '%s\n' "$OMARCHY_CONFIG_HOME/backgrounds/$theme_name"

    while IFS= read -r dir; do
      [[ -n $dir ]] || continue
      printf '%s\n' "$dir"
      find -L "$dir" -mindepth 1 -maxdepth "$OMARCHY_BACKGROUND_DIR_MAX_DEPTH" -type d \
        \( -name '.*' -prune -o -print \) 2>/dev/null | sort
    done < <(omarchy-theme-bg-dir list)
  } | awk 'length > 0 && !seen[$0]++'
}
