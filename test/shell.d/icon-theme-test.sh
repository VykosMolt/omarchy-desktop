#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
export OMARCHY_PATH="$ROOT"
export PATH="$tmp/stub-bin:$ROOT/bin:$PATH"

mkdir -p "$HOME/.config" "$tmp/stub-bin"

export OMARCHY_SESSION_CONFIG_HOME="$HOME/.config/omarchy-arch"
export OMARCHY_CONFIG_HOME="$OMARCHY_SESSION_CONFIG_HOME/omarchy"
export OMARCHY_STATE_HOME="$HOME/.local/state/omarchy-arch/omarchy"
export KITTY_CONFIG_DIRECTORY="$OMARCHY_SESSION_CONFIG_HOME/kitty"

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

# Host desktop files and the account-wide settings database are read-only.
mkdir -p "$config_home/gtk-3.0" "$config_home/gtk-4.0" "$config_home/qt6ct" "$config_home/fontconfig" "$config_home/kitty" "$HOME/.icons/default"
printf '[Settings]\ngtk-theme-name=Breeze\ngtk-icon-theme-name=Host-Icons\n' >"$config_home/gtk-3.0/settings.ini"
printf '[Settings]\ngtk-icon-theme-name=Host-Icons\n' >"$config_home/gtk-4.0/settings.ini"
printf '[Appearance]\nstyle=Fusion\nicon_theme=Host-Icons\n' >"$config_home/qt6ct/qt6ct.conf"
printf '[Icons]\nTheme=Host-Icons\n' >"$config_home/kdeglobals"
printf '<fontconfig>host settings</fontconfig>\n' >"$config_home/fontconfig/fonts.conf"
printf 'font_family Host Font\nfont_size 10.0\n' >"$config_home/kitty/kitty.conf"
printf '[Icon Theme]\nInherits=Host-Cursor\n' >"$HOME/.icons/default/index.theme"
printf 'Host-Icons\n' >"$GSETTINGS_STORE"
cp -a "$config_home" "$tmp/host-before"
cp -a "$HOME/.icons/default" "$tmp/cursor-before"

[[ $(omarchy-icon-theme get) == Host-Icons ]] || fail "new sessions read the host icon default"
omarchy-icon-theme set Fixture-Icons >/dev/null
[[ $(omarchy-icon-theme get) == Fixture-Icons ]] || fail "private icon preference round-trips"
[[ $(cat "$GSETTINGS_STORE") == Host-Icons ]] || fail "icon selection never writes gsettings"
pass "icon selection stays private"

# Offline writes use the same preference and must not depend on a session bus.
env -u DBUS_SESSION_BUS_ADDRESS omarchy-icon-theme set Fixture-Extra >/dev/null
[[ $(omarchy-icon-theme get) == Fixture-Extra ]] || fail "private selection takes precedence over the host"
pass "icon preferences work without a desktop bus"

cat >"$tmp/stub-bin/omarchy-menu-select" <<'STUB'
#!/bin/bash
shift
printf '%s\n' "$@" >"$MENU_SELECT_OPTIONS"
printf '%s\n' "$MENU_SELECT_PICK"
STUB
cat >"$tmp/stub-bin/omarchy-notification-send" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$NOTIFICATIONS"
STUB
chmod +x "$tmp/stub-bin/omarchy-menu-select" "$tmp/stub-bin/omarchy-notification-send"
export MENU_SELECT_OPTIONS="$tmp/menu-options" MENU_SELECT_PICK=Fixture-Icons NOTIFICATIONS="$tmp/notifications"
omarchy-menu-icon-theme
grep -qxF "✓"$'\t'"Fixture-Extra" "$MENU_SELECT_OPTIONS" || fail "picker marks the private icon selection"
[[ $(omarchy-icon-theme get) == Fixture-Icons ]] || fail "picker changes the private preference"
pass "picker marks and changes the private icon theme"

# A symlinked preference cannot redirect a write into Plasma or GTK config.
cp "$OMARCHY_CONFIG_HOME/appearance.ini" "$tmp/appearance.saved"
rm "$OMARCHY_CONFIG_HOME/appearance.ini"
ln -s "$config_home/kdeglobals" "$OMARCHY_CONFIG_HOME/appearance.ini"
if omarchy-icon-theme set Fixture-Extra >/dev/null 2>&1; then
  fail "external preference symlink is refused"
fi
rm "$OMARCHY_CONFIG_HOME/appearance.ini"
cp "$tmp/appearance.saved" "$OMARCHY_CONFIG_HOME/appearance.ini"
mv "$OMARCHY_CONFIG_HOME" "$OMARCHY_CONFIG_HOME.saved"
ln -s "$config_home/qt6ct" "$OMARCHY_CONFIG_HOME"
if omarchy-icon-theme set Fixture-Extra >/dev/null 2>&1; then
  fail "symlinked private root is refused"
fi
rm "$OMARCHY_CONFIG_HOME"
mv "$OMARCHY_CONFIG_HOME.saved" "$OMARCHY_CONFIG_HOME"
pass "preference files and roots cannot escape through symlinks"

# Font and text-size controls update the actual private terminal and shell
# preferences while global fontconfig, Kitty and GTK files stay identical.
mkdir -p "$KITTY_CONFIG_DIRECTORY"
printf 'font_family Host Font\nfont_size 10.0\nbackground #123456\n' >"$KITTY_CONFIG_DIRECTORY/kitty.conf"
cat >"$tmp/stub-bin/fc-list" <<'STUB'
#!/bin/bash
printf 'Fixture Mono\n'
STUB
for command in omarchy-restart-terminal omarchy-hook; do
  printf '#!/bin/bash\nexit 0\n' >"$tmp/stub-bin/$command"
done
chmod +x "$tmp/stub-bin/"*
omarchy-font-set 'Fixture Mono'
[[ $(omarchy-font-current) == 'Fixture Mono' ]] || fail "shell reads the private font preference"
grep -qxF 'font_family Fixture Mono' "$KITTY_CONFIG_DIRECTORY/kitty.conf" || fail "private Kitty uses the selected font"
omarchy-display-text-size 16
grep -qxF 'font_size 12.0' "$KITTY_CONFIG_DIRECTORY/kitty.conf" || fail "text size reaches private Kitty"
grep -qxF 'base-size = 16' "$OMARCHY_CONFIG_HOME/shell.toml" || fail "text size reaches private shell"
omarchy-display-text-size reset
grep -qxF 'font_size 9.0' "$KITTY_CONFIG_DIRECTORY/kitty.conf" || fail "reset restores private terminal size"
if env KITTY_CONFIG_DIRECTORY="$config_home/kitty" omarchy-font-set 'Fixture Mono' >/dev/null 2>&1; then
  fail "font setter refuses a host terminal destination"
fi
if env KITTY_CONFIG_DIRECTORY="$config_home/kitty" omarchy-display-text-size 15 >/dev/null 2>&1; then
  fail "text-size setter refuses a host terminal destination"
fi
for entry in gtk-3.0 gtk-4.0 qt6ct kdeglobals fontconfig kitty; do
  diff -r "$tmp/host-before/$entry" "$config_home/$entry" >/dev/null || fail "host $entry is unchanged"
done
diff -r "$tmp/cursor-before" "$HOME/.icons/default" >/dev/null || fail "host cursor defaults are unchanged"
[[ $(cat "$GSETTINGS_STORE") == Host-Icons ]] || fail "all appearance controls leave global gsettings unchanged"
pass "font and text sizing change only private shell and Kitty preferences"
