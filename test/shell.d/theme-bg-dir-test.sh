#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
export OMARCHY_PATH="$ROOT"
export PATH="$tmp/stub-bin:$ROOT/bin:$PATH"

mkdir -p "$HOME" "$tmp/stub-bin"

config_file="$HOME/.config/omarchy/backgrounds.conf"
state_home="$HOME/.local/state/omarchy"
walls="$tmp/walls"

mkdir -p "$walls/nature/close-ups/macro/too-deep" "$walls/.git/objects"
mkdir -p "$state_home/current/theme/backgrounds" "$HOME/.config/omarchy/backgrounds/nord"
printf 'nord\n' >"$state_home/current/theme.name"

[[ -z $(omarchy-theme-bg-dir list) ]] || fail "no configured folders without a config file"
pass "listing without a config file reports no folders"

omarchy-theme-bg-dir add "$walls" >/dev/null || fail "adding a folder succeeds"
[[ $(omarchy-theme-bg-dir list) == "$walls" ]] || fail "an added folder is listed"
pass "a folder can be added and listed"

[[ $(<"$config_file") == "$walls" ]] || fail "the folder is stored one absolute path per line"
pass "folders are stored one absolute path per line"

if omarchy-theme-bg-dir add "$walls" 2>/dev/null; then
  fail "adding the same folder twice is refused"
fi
[[ $(grep -c . "$config_file") == "1" ]] || fail "a refused duplicate is not appended"
pass "a duplicate folder is refused"

printf 'not a directory' >"$tmp/wallpaper.png"
if omarchy-theme-bg-dir add "$tmp/wallpaper.png" 2>/dev/null; then
  fail "adding a file instead of a directory is refused"
fi
if omarchy-theme-bg-dir add "$tmp/missing" 2>/dev/null; then
  fail "adding a missing path is refused"
fi
[[ $(grep -c . "$config_file") == "1" ]] || fail "a refused path is not appended"
pass "a non-directory and a missing path are refused"

# A relative path and a traversal both have to land on the same stored entry.
if (cd "$walls/nature" && omarchy-theme-bg-dir add ".." >/dev/null 2>&1); then
  fail "a relative path resolving to a configured folder is a duplicate"
fi
pass "paths are compared after being resolved"

{
  printf '\n'
  printf '# a comment line\n'
  printf '  %s  \n' "$tmp/gone"
} >>"$config_file"

mapfile -t listed < <(omarchy-theme-bg-dir list)
(( ${#listed[@]} == 1 )) || fail "blank lines, comments, and vanished folders are skipped" "${listed[*]}"
pass "blank lines, comments, and vanished folders are skipped"

source "$ROOT/lib/omarchy-paths.sh"
source "$ROOT/lib/omarchy-backgrounds.sh"
mapfile -t dirs < <(omarchy_background_dirs)

[[ ${dirs[0]} == "$state_home/current/theme/backgrounds" ]] || fail "the theme's backgrounds come first" "${dirs[*]}"
[[ ${dirs[1]} == "$HOME/.config/omarchy/backgrounds/nord" ]] || fail "the theme's user backgrounds come second" "${dirs[*]}"
pass "theme directories keep the top of the picker"

printf '%s\n' "${dirs[@]}" | grep -qxF "$walls" || fail "a configured folder is scanned"
printf '%s\n' "${dirs[@]}" | grep -qxF "$walls/nature/close-ups/macro" || fail "a configured folder's subdirectories are scanned"
pass "a configured folder and its subdirectories are scanned"

if printf '%s\n' "${dirs[@]}" | grep -qxF "$walls/nature/close-ups/macro/too-deep"; then
  fail "expansion stops after three levels"
fi
if printf '%s\n' "${dirs[@]}" | grep -F "$walls/" | grep -q '/\.'; then
  fail "hidden directories are never scanned"
fi
pass "expansion is capped at three levels and skips hidden directories"

cat >"$tmp/stub-bin/omarchy-menu-images" <<'STUB'
#!/bin/bash

printf '%s\n' "$@" >>"$MENU_IMAGES_ARGS"
STUB
chmod +x "$tmp/stub-bin/omarchy-menu-images"

export MENU_IMAGES_ARGS="$tmp/switcher-args"
"$ROOT/bin/omarchy-theme-bg-switcher" >/dev/null
grep -qxF -- "--selected" "$MENU_IMAGES_ARGS" || fail "the switcher still marks the current background"
grep -qxF "$walls" "$MENU_IMAGES_ARGS" || fail "the switcher passes configured folders to the picker"
grep -qxF "$walls/nature" "$MENU_IMAGES_ARGS" || fail "the switcher passes a configured folder's subdirectories"
pass "the background switcher shows configured folders"

MENU_IMAGES_ARGS="$tmp/cache-args" "$ROOT/bin/omarchy-theme-bg-cache" >/dev/null
# omarchy-menu-images keys its row cache on the directory list, so the warmer
# has to ask for exactly the list the switcher opens with.
# The flags and the value --selected carries are not part of the list the row
# cache is keyed on.
picker_dirs() {
  sed -e '/^--selected$/{N;d}' -e '/^--cache-only$/d' "$1"
}
diff <(picker_dirs "$tmp/switcher-args") <(picker_dirs "$tmp/cache-args") >/dev/null ||
  fail "the thumbnail warmer scans the same folders as the switcher"
pass "the thumbnail warmer scans the same folders as the switcher"

omarchy-theme-bg-dir remove "$walls" >/dev/null || fail "removing a configured folder succeeds"
[[ -z $(omarchy-theme-bg-dir list) ]] || fail "a removed folder is gone from the listing"
if omarchy-theme-bg-dir remove "$walls" 2>/dev/null; then
  fail "removing a folder that is not configured fails"
fi
pass "a folder can be removed"

grep -qF "$tmp/gone" "$config_file" || fail "removing one folder keeps the other entries"
pass "removing one folder keeps the other entries"

cat >"$tmp/stub-bin/omarchy-file-select" <<'STUB'
#!/bin/bash

printf '%s\n' "$*" >>"$FILE_SELECT_ARGS"
[[ -n $FILE_SELECT_PICK ]] || exit 1
printf '%s\n' "$FILE_SELECT_PICK"
STUB

cat >"$tmp/stub-bin/omarchy-menu-select" <<'STUB'
#!/bin/bash

shift
printf '%s\n' "$@" >"$MENU_SELECT_OPTIONS"
[[ -n $MENU_SELECT_PICK ]] || exit 1
printf '%s\n' "$MENU_SELECT_PICK"
STUB

cat >"$tmp/stub-bin/omarchy-notification-send" <<'STUB'
#!/bin/bash

printf '%s\n' "$*" >>"$NOTIFICATIONS"
STUB

chmod +x "$tmp/stub-bin/omarchy-file-select" "$tmp/stub-bin/omarchy-menu-select" "$tmp/stub-bin/omarchy-notification-send"

export FILE_SELECT_ARGS="$tmp/file-select-args"
export MENU_SELECT_OPTIONS="$tmp/menu-options"
export NOTIFICATIONS="$tmp/notifications"

FILE_SELECT_PICK="$walls" omarchy-menu-theme-bg-dir add
grep -qF -- "--directory" "$FILE_SELECT_ARGS" || fail "the folder picker asks the file chooser for a directory"
[[ $(omarchy-theme-bg-dir list) == "$walls" ]] || fail "the folder picker adds the chosen folder"
grep -qF "$walls" "$NOTIFICATIONS" || fail "the folder picker names the folder it added"
pass "the folder picker adds a folder through the file chooser"

MENU_SELECT_PICK="$walls" omarchy-menu-theme-bg-dir remove
grep -qxF "$walls" "$MENU_SELECT_OPTIONS" || fail "the folder picker offers the configured folders"
[[ -z $(omarchy-theme-bg-dir list) ]] || fail "the folder picker removes the chosen folder"
pass "the folder picker removes a configured folder"

if MENU_SELECT_PICK="" omarchy-menu-theme-bg-dir remove 2>/dev/null; then
  fail "removing with nothing configured is not treated as a removal"
fi
pass "the folder picker refuses to remove when nothing is configured"
