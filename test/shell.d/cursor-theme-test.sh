#!/bin/bash

# Cursor choices persist privately and reach the active Hyprland compositor.
# Host GTK/KDE/Xcursor defaults must remain unchanged.

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

config_home="$HOME/.config"
icons="$HOME/.icons"
data_icons="$HOME/.local/share/icons"

# A cursor theme is a theme with a cursors directory. An icon theme is not one,
# however complete its index.theme looks.
install_theme() {
  local root="$1"
  local name="$2"
  local subdir="$3"

  mkdir -p "$root/$name/$subdir"
  printf '[Icon Theme]\nName=%s\n' "$name" >"$root/$name/index.theme"
}

install_theme "$icons" "Fixture-Cursors" "cursors"
install_theme "$icons" "Fixture-Icons" "16x16/apps"
install_theme "$data_icons" "Fixture-Cursors" "cursors"
install_theme "$data_icons" "Fixture-Other-Cursors" "cursors"

# A cursors directory with no index.theme beside it is still a cursor theme;
# plenty of them ship that way.
mkdir -p "$icons/Fixture-Indexless/cursors"

cat >"$tmp/stub-bin/gsettings" <<'STUB'
#!/bin/bash

store="$GSETTINGS_STORE.$3"
if [[ $1 == "set" ]]; then
  printf '%s\n' "$4" >"$store"
elif [[ $1 == "get" ]]; then
  if [[ -f $store ]]; then
    printf "'%s'\n" "$(cat "$store")"
  fi
fi
STUB
chmod +x "$tmp/stub-bin/gsettings"

export GSETTINGS_STORE="$tmp/gsettings"
export DBUS_SESSION_BUS_ADDRESS="unix:path=$tmp/bus"

listed=$(omarchy-cursor-theme list)

grep -qxF "Fixture-Cursors" <<<"$listed" || fail "a theme with cursors in it is offered" "$listed"
grep -qxF "Fixture-Other-Cursors" <<<"$listed" || fail "every cursor root is scanned" "$listed"
grep -qxF "Fixture-Indexless" <<<"$listed" || fail "a cursor theme without an index.theme is still offered" "$listed"
grep -qxF "Fixture-Icons" <<<"$listed" && fail "an icon theme is not offered as a cursor theme" "$listed"
(( $(grep -cxF "Fixture-Cursors" <<<"$listed") == 1 )) || fail "a theme installed in two roots is offered once" "$listed"
[[ $listed == "$(sort <<<"$listed")" ]] || fail "cursor themes are listed in sorted order" "$listed"
pass "a cursor theme is a theme with cursors in it, listed once and in order"

omarchy-cursor-theme set Fixture-Icons >/dev/null 2>&1 &&
  fail "a theme with no cursors is refused"
omarchy-cursor-theme set ../../etc >/dev/null 2>&1 &&
  fail "a name that climbs out of the cursor roots is refused"
pass "only an installed cursor theme can be set"

mkdir -p "$config_home/gtk-3.0" "$config_home/gtk-4.0" "$HOME/.icons/default"
printf '[Settings]\ngtk-theme-name=Breeze\ngtk-cursor-theme-name=Host-Cursor\ngtk-cursor-theme-size=18\n' >"$config_home/gtk-3.0/settings.ini"
printf '[Settings]\ngtk-cursor-theme-name=Host-Cursor\n' >"$config_home/gtk-4.0/settings.ini"
printf '[Mouse]\ncursorTheme=Host-Cursor\ncursorSize=18\n' >"$config_home/kcminputrc"
printf '[Icon Theme]\nInherits=Host-Cursor\n' >"$HOME/.icons/default/index.theme"
cp -a "$config_home" "$tmp/host-before"
cp -a "$HOME/.icons/default" "$tmp/cursor-before"
printf 'Host-Cursor\n' >"$GSETTINGS_STORE.cursor-theme"
printf '18\n' >"$GSETTINGS_STORE.cursor-size"
[[ $(omarchy-cursor-theme get) == Host-Cursor ]] || fail "new session reads host cursor theme"
[[ $(omarchy-cursor-theme size) == 18 ]] || fail "new session reads host cursor size"

cat >"$tmp/stub-bin/hyprctl" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$CURSOR_IPC"
STUB
chmod +x "$tmp/stub-bin/hyprctl"
export HYPRLAND_INSTANCE_SIGNATURE=fixture CURSOR_IPC="$tmp/ipc"
omarchy-cursor-theme set Fixture-Cursors >/dev/null
omarchy-cursor-theme size 32 >/dev/null
[[ $(omarchy-cursor-theme get) == Fixture-Cursors ]] || fail "private cursor theme round-trips"
[[ $(omarchy-cursor-theme size) == 32 ]] || fail "private cursor size round-trips"
grep -qxF 'setcursor Fixture-Cursors 32' "$CURSOR_IPC" || fail "cursor change reaches Hyprland"
[[ $(cat "$GSETTINGS_STORE.cursor-theme") == Host-Cursor ]] || fail "cursor setter leaves gsettings theme unchanged"
[[ $(cat "$GSETTINGS_STORE.cursor-size") == 18 ]] || fail "cursor setter leaves gsettings size unchanged"
for entry in gtk-3.0 gtk-4.0 kcminputrc; do
  diff -r "$tmp/host-before/$entry" "$config_home/$entry" >/dev/null || fail "host $entry remains identical"
done
diff -r "$tmp/cursor-before" "$HOME/.icons/default" >/dev/null || fail "Xcursor defaults remain identical"
pass "cursor settings change Hyprland without changing host appearance"

for bad in 4 200 huge ""; do
  omarchy-cursor-theme size "$bad" >/dev/null 2>&1 && fail "invalid cursor size is refused" "$bad"
done
[[ $(omarchy-cursor-theme size) == 32 ]] || fail "invalid size changes nothing"

env -u DBUS_SESSION_BUS_ADDRESS -u HYPRLAND_INSTANCE_SIGNATURE omarchy-cursor-theme set Fixture-Other-Cursors >/dev/null
[[ $(omarchy-cursor-theme get) == Fixture-Other-Cursors ]] || fail "offline cursor preference persists"
pass "cursor preferences also work outside a running compositor"
