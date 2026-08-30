#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
export OMARCHY_PATH="$ROOT"
export PATH="$tmp/stub-bin:$ROOT/bin:$PATH"

mkdir -p "$HOME/.config" "$tmp/stub-bin"

config_home="$HOME/.config"
icons="$HOME/.icons"
data_icons="$HOME/.local/share/icons"

# A real icon theme, the same theme installed twice, and two cursor themes: one
# that lists only cursors and one that lists no directories at all.
install_theme() {
  local root="$1"
  local name="$2"
  local directories="$3"
  local subdir="$4"

  mkdir -p "$root/$name/$subdir"
  {
    printf '[Icon Theme]\n'
    printf 'Name=%s\n' "$name"
    if [[ -n $directories ]]; then
      printf 'Directories=%s\n' "$directories"
    fi
  } >"$root/$name/index.theme"
}

install_theme "$icons" "Fixture-Icons" "16x16/apps,32x32/apps" "16x16/apps"
install_theme "$icons" "Fixture-Cursors" "cursors" "cursors"
install_theme "$icons" "Fixture-Bare-Cursors" "" "cursors"
install_theme "$data_icons" "Fixture-Icons" "16x16/apps" "16x16/apps"
install_theme "$data_icons" "Fixture-Extra" "48x48/places" "48x48/places"

# A directory without an index.theme is not a theme.
mkdir -p "$icons/Fixture-No-Index/16x16"

cat >"$tmp/stub-bin/gsettings" <<'STUB'
#!/bin/bash

if [[ $1 == "set" ]]; then
  printf '%s\n' "$4" >"$GSETTINGS_STORE"
elif [[ $1 == "get" ]]; then
  printf "'%s'\n" "$(cat "$GSETTINGS_STORE" 2>/dev/null)"
fi
STUB
chmod +x "$tmp/stub-bin/gsettings"

export GSETTINGS_STORE="$tmp/gsettings-icon-theme"
export DBUS_SESSION_BUS_ADDRESS="unix:path=$tmp/bus"

mapfile -t themes < <(omarchy-icon-theme list)
printf '%s\n' "${themes[@]}" | grep -qxF "Fixture-Icons" || fail "an installed icon theme is listed"
printf '%s\n' "${themes[@]}" | grep -qxF "Fixture-Extra" || fail "every icon root is scanned"
pass "installed icon themes are listed"

(( $(printf '%s\n' "${themes[@]}" | grep -cxF "Fixture-Icons") == 1 )) ||
  fail "a theme installed under two roots is listed once"
pass "themes are de-duplicated across roots"

diff <(printf '%s\n' "${themes[@]}") <(printf '%s\n' "${themes[@]}" | sort) >/dev/null ||
  fail "themes are listed in sorted order"
pass "themes are listed in sorted order"

for cursor_theme in Fixture-Cursors Fixture-Bare-Cursors; do
  if printf '%s\n' "${themes[@]}" | grep -qxF "$cursor_theme"; then
    fail "a cursor-only theme is not offered as an icon theme: $cursor_theme"
  fi
done
if printf '%s\n' "${themes[@]}" | grep -qxF "Fixture-No-Index"; then
  fail "a directory without an index.theme is not a theme"
fi
pass "cursor-only themes and index-less directories are excluded"

if omarchy-icon-theme set "Fixture-Not-Installed" 2>/dev/null; then
  fail "an uninstalled icon theme is refused"
fi
[[ ! -e $config_home/gtk-3.0/settings.ini ]] || fail "a refused theme writes nothing"
pass "an uninstalled icon theme is refused"

for traversal in "../Fixture-Icons" ".Fixture-Icons"; do
  if omarchy-icon-theme set "$traversal" 2>/dev/null; then
    fail "a theme name that climbs out of the icon roots is refused: $traversal"
  fi
done
pass "a theme name that climbs out of the icon roots is refused"

# Neighbouring keys, other sections, and a comment all have to survive.
mkdir -p "$config_home/gtk-3.0" "$config_home/qt6ct"
{
  printf '[Settings]\n'
  printf 'gtk-theme-name=Adwaita\n'
  printf 'gtk-icon-theme-name=Old-Icons\n'
  printf 'gtk-font-name=Cantarell 11\n'
} >"$config_home/gtk-3.0/settings.ini"
{
  printf '[Appearance]\n'
  printf 'color_scheme_path=/usr/share/qt6ct/colors/darker.conf\n'
  printf 'style=Fusion\n'
  printf '\n'
  printf '[Fonts]\n'
  printf 'general="Cantarell,11"\n'
} >"$config_home/qt6ct/qt6ct.conf"
{
  printf '[General]\n'
  printf 'ColorScheme=BreezeDark\n'
} >"$config_home/kdeglobals"

updated=$(omarchy-icon-theme set "Fixture-Icons")

[[ $(<"$GSETTINGS_STORE") == "Fixture-Icons" ]] || fail "set tells gsettings about the icon theme"
grep -q 'gsettings' <<<"$updated" || fail "set reports the gsettings source"
pass "set applies the icon theme through gsettings"

for file in \
  "$config_home/gtk-3.0/settings.ini" \
  "$config_home/gtk-4.0/settings.ini"; do
  grep -qx 'gtk-icon-theme-name=Fixture-Icons' "$file" || fail "set writes the GTK icon theme: $file"
  grep -qx '\[Settings\]' "$file" || fail "the GTK settings section is present: $file"
  grep -qF "$file" <<<"$updated" || fail "set reports the source it wrote: $file"
done
pass "set writes the icon theme into both GTK configs"

# qt6ct is configured on this fixture machine, qt5ct is not: the one that is
# gets the icon theme, and no config is invented for the one that is not.
qt6ct_conf="$config_home/qt6ct/qt6ct.conf"
grep -qx 'icon_theme=Fixture-Icons' "$qt6ct_conf" || fail "set writes the Qt icon theme: $qt6ct_conf"
grep -qx '\[Appearance\]' "$qt6ct_conf" || fail "the Qt appearance section is present: $qt6ct_conf"
grep -qx 'style=Fusion' "$qt6ct_conf" || fail "set keeps the Qt keys it found: $qt6ct_conf"
grep -qF "$qt6ct_conf" <<<"$updated" || fail "set reports the source it wrote: $qt6ct_conf"
[[ ! -e $config_home/qt5ct/qt5ct.conf ]] ||
  fail "set invents a qt5ct config for a machine that has no qt5ct"
pass "set writes the Qt icon theme only where that toolkit is configured"

grep -qx 'Theme=Fixture-Icons' "$config_home/kdeglobals" || fail "set writes the KDE icon theme"
grep -qx '\[Icons\]' "$config_home/kdeglobals" || fail "set creates the KDE icons section"
grep -qx 'ColorScheme=BreezeDark' "$config_home/kdeglobals" || fail "set keeps the KDE section it found"
pass "set writes the icon theme into kdeglobals"

grep -qx 'gtk-theme-name=Adwaita' "$config_home/gtk-3.0/settings.ini" || fail "set keeps neighbouring GTK keys"
grep -qx 'gtk-font-name=Cantarell 11' "$config_home/gtk-3.0/settings.ini" || fail "set keeps neighbouring GTK keys"
(( $(grep -c 'gtk-icon-theme-name' "$config_home/gtk-3.0/settings.ini") == 1 )) ||
  fail "set replaces the GTK icon theme key instead of appending another"
grep -qx 'style=Fusion' "$config_home/qt6ct/qt6ct.conf" || fail "set keeps neighbouring Qt keys"
grep -qx 'general="Cantarell,11"' "$config_home/qt6ct/qt6ct.conf" || fail "set keeps other Qt sections"
grep -qx '\[Fonts\]' "$config_home/qt6ct/qt6ct.conf" || fail "set keeps other Qt sections"
pass "set preserves every key it was not asked to change"

[[ $(omarchy-icon-theme get) == "Fixture-Icons" ]] || fail "get reports the icon theme in effect"
[[ $(omarchy-icon-theme) == "Fixture-Icons" ]] || fail "get is the default subcommand"
pass "get reports the icon theme in effect"

# Without a session bus there is nothing to ask gsettings, and nothing to tell
# it either; the files still carry the answer.
env -u DBUS_SESSION_BUS_ADDRESS omarchy-icon-theme set "Fixture-Extra" >/dev/null
[[ $(<"$GSETTINGS_STORE") == "Fixture-Icons" ]] || fail "set skips gsettings without a session bus"
grep -qx 'gtk-icon-theme-name=Fixture-Extra' "$config_home/gtk-3.0/settings.ini" ||
  fail "set writes the config files without a session bus"
[[ $(env -u DBUS_SESSION_BUS_ADDRESS omarchy-icon-theme get) == "Fixture-Extra" ]] ||
  fail "get falls back to the GTK config without a session bus"
pass "set and get work without a session bus"

cat >"$tmp/stub-bin/omarchy-menu-select" <<'STUB'
#!/bin/bash

shift
printf '%s\n' "$@" >"$MENU_SELECT_OPTIONS"
printf '%s\n' "$MENU_SELECT_PICK"
STUB
chmod +x "$tmp/stub-bin/omarchy-menu-select"

cat >"$tmp/stub-bin/omarchy-notification-send" <<'STUB'
#!/bin/bash

printf '%s\n' "$*" >>"$NOTIFICATIONS"
STUB
chmod +x "$tmp/stub-bin/omarchy-notification-send"

export MENU_SELECT_OPTIONS="$tmp/menu-options"
# gsettings is what get asks first, so the theme in effect is the one the last
# set with a session bus put there, not the one the files were left holding.
export MENU_SELECT_PICK="Fixture-Extra"
export NOTIFICATIONS="$tmp/notifications"

omarchy-menu-icon-theme

# The picker marks the theme in effect the way the menu's own provider rows do.
grep -qxF "✓"$'\t'"Fixture-Icons" "$MENU_SELECT_OPTIONS" || fail "the picker marks the icon theme in effect"
grep -qxF $'\t'"Fixture-Extra" "$MENU_SELECT_OPTIONS" || fail "the picker offers every installed icon theme"
pass "the icon theme picker marks the theme in effect"

[[ $(<"$GSETTINGS_STORE") == "Fixture-Extra" ]] || fail "the picker applies the selected icon theme"
grep -qF "Fixture-Extra" "$NOTIFICATIONS" || fail "the picker names the theme it applied"
pass "the icon theme picker applies and announces the selection"

# A config kept in a dotfiles repo is a symlink, and it has to stay one.
mkdir -p "$tmp/dotfiles"
printf '[Icons]\nTheme=Fixture-Extra\nOther=kept\n' >"$tmp/dotfiles/kdeglobals"
rm -f "$config_home/kdeglobals"
ln -s "$tmp/dotfiles/kdeglobals" "$config_home/kdeglobals"

omarchy-icon-theme set "Fixture-Icons" >/dev/null
[[ -L $config_home/kdeglobals ]] || fail "a symlinked config is still a symlink"
grep -qx 'Theme=Fixture-Icons' "$tmp/dotfiles/kdeglobals" || fail "a symlinked config is written through"
grep -qx 'Other=kept' "$tmp/dotfiles/kdeglobals" || fail "a symlinked config keeps its other keys"
pass "a config kept as a symlink is written through, not replaced"
